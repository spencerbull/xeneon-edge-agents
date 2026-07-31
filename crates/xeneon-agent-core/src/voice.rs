use std::{
    env, fs,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use thiserror::Error;
use tokio::process::Command;
use tokio::time::timeout;

use crate::{
    Config,
    model::{ActionKind, VoiceSnapshot, VoiceState},
};

const STATE_FILE_NAME: &str = "voxtype/state";
const MARKER_FILE_NAME: &str = "xeneon-edge-agents/dictation-active";
const VOICE_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Copy, Error, PartialEq, Eq)]
pub enum VoiceActionError {
    #[error("voice input is unavailable")]
    Unavailable,
    #[error("voice input is not idle")]
    NotIdle,
    #[error("voice recording is not owned by the portal")]
    NotOwned,
    #[error("voice action failed")]
    CommandFailed,
    #[error("voice ownership could not be updated")]
    Ownership,
}

#[derive(Debug)]
pub struct VoiceController {
    binary: PathBuf,
    state_path: PathBuf,
    marker_path: PathBuf,
    owner_token: String,
}

impl VoiceController {
    pub fn from_config(config: &Config, owner_token: impl Into<String>) -> Result<Self> {
        Ok(Self::new(
            config.voxtype_bin.clone(),
            default_voice_state_path(),
            default_dictation_marker_path()?,
            owner_token,
        ))
    }

    pub(crate) fn new(
        binary: PathBuf,
        state_path: PathBuf,
        marker_path: PathBuf,
        owner_token: impl Into<String>,
    ) -> Self {
        Self {
            binary,
            state_path,
            marker_path,
            owner_token: owner_token.into(),
        }
    }

    pub async fn snapshot(&self) -> VoiceSnapshot {
        VoiceSnapshot {
            state: read_voice_state(&self.state_path).await,
            owned: self.owns_marker(),
        }
    }

    pub async fn perform(
        &self,
        action: ActionKind,
    ) -> std::result::Result<VoiceSnapshot, VoiceActionError> {
        match action {
            ActionKind::VoiceStart => self.start().await,
            ActionKind::VoiceStop => self.finish("stop", VoiceState::Processing).await,
            ActionKind::VoiceCancel => self.finish("cancel", VoiceState::Idle).await,
            _ => Err(VoiceActionError::CommandFailed),
        }
    }

    async fn start(&self) -> std::result::Result<VoiceSnapshot, VoiceActionError> {
        match read_voice_state(&self.state_path).await {
            VoiceState::Idle => {}
            VoiceState::Unavailable => return Err(VoiceActionError::Unavailable),
            VoiceState::Recording | VoiceState::Processing | VoiceState::Error => {
                return Err(VoiceActionError::NotIdle);
            }
        }

        self.claim_marker()?;
        if !run_voxtype(
            &self.binary,
            &[
                "record",
                "start",
                "--type",
                "--no-auto-submit",
                "--no-smart-auto-submit",
            ],
        )
        .await
        {
            let _ = run_voxtype(&self.binary, &["record", "cancel"]).await;
            let _ = self.remove_owned_marker();
            return Err(VoiceActionError::CommandFailed);
        }

        Ok(VoiceSnapshot {
            state: VoiceState::Recording,
            owned: true,
        })
    }

    async fn finish(
        &self,
        action: &'static str,
        resulting_state: VoiceState,
    ) -> std::result::Result<VoiceSnapshot, VoiceActionError> {
        if !self.owns_marker() {
            return Err(VoiceActionError::NotOwned);
        }
        if !run_voxtype(&self.binary, &["record", action]).await {
            return Err(VoiceActionError::CommandFailed);
        }
        self.remove_owned_marker()?;
        Ok(VoiceSnapshot {
            state: resulting_state,
            owned: false,
        })
    }

    fn claim_marker(&self) -> std::result::Result<(), VoiceActionError> {
        let parent = self
            .marker_path
            .parent()
            .ok_or(VoiceActionError::Ownership)?;
        fs::create_dir_all(parent).map_err(|_| VoiceActionError::Ownership)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .map_err(|_| VoiceActionError::Ownership)?;

        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true).mode(0o600);
        let mut marker = options
            .open(&self.marker_path)
            .map_err(|_| VoiceActionError::Ownership)?;
        use std::io::Write;
        if marker.write_all(self.owner_token.as_bytes()).is_err() {
            let _ = fs::remove_file(&self.marker_path);
            return Err(VoiceActionError::Ownership);
        }
        Ok(())
    }

    fn owns_marker(&self) -> bool {
        is_regular_file(&self.marker_path)
            && fs::read_to_string(&self.marker_path)
                .is_ok_and(|contents| contents == self.owner_token)
    }

    fn remove_owned_marker(&self) -> std::result::Result<(), VoiceActionError> {
        if !self.owns_marker() {
            return Err(VoiceActionError::NotOwned);
        }
        fs::remove_file(&self.marker_path).map_err(|_| VoiceActionError::Ownership)
    }
}

pub async fn cleanup_owned_dictation(config: &Config) -> Result<()> {
    cleanup_owned_dictation_at(
        &config.voxtype_bin,
        &default_voice_state_path(),
        &default_dictation_marker_path()?,
    )
    .await
}

async fn cleanup_owned_dictation_at(
    binary: &Path,
    state_path: &Path,
    marker_path: &Path,
) -> Result<()> {
    match fs::symlink_metadata(marker_path) {
        Ok(metadata) if metadata.file_type().is_file() => {}
        Ok(_) => return Err(anyhow!("voice ownership marker is not a regular file")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(anyhow!("voice ownership marker is unreadable")),
    }

    if read_voice_state(state_path).await != VoiceState::Idle
        && !run_voxtype(binary, &["record", "cancel"]).await
    {
        return Err(anyhow!("voice cleanup failed"));
    }
    fs::remove_file(marker_path).context("removing voice ownership marker")
}

async fn read_voice_state(path: &Path) -> VoiceState {
    match tokio::fs::read_to_string(path).await {
        Ok(contents) => normalize_voice_state(&contents),
        Err(_) => VoiceState::Unavailable,
    }
}

fn normalize_voice_state(value: &str) -> VoiceState {
    match value.trim() {
        "idle" => VoiceState::Idle,
        "recording" => VoiceState::Recording,
        "streaming" | "transcribing" => VoiceState::Processing,
        _ => VoiceState::Unavailable,
    }
}

async fn run_voxtype(binary: &Path, args: &[&str]) -> bool {
    run_voxtype_with_timeout(binary, args, VOICE_COMMAND_TIMEOUT).await
}

async fn run_voxtype_with_timeout(binary: &Path, args: &[&str], duration: Duration) -> bool {
    let mut command = Command::new(binary);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    timeout(duration, command.status())
        .await
        .is_ok_and(|result| result.is_ok_and(|status| status.success()))
}

fn default_voice_state_path() -> PathBuf {
    if let Some(runtime) = env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime).join(STATE_FILE_NAME);
    }
    if let Some(uid) = env::var_os("UID") {
        return PathBuf::from("/run/user").join(uid).join(STATE_FILE_NAME);
    }
    PathBuf::from("/run/user/xeneon-unavailable").join(STATE_FILE_NAME)
}

fn default_dictation_marker_path() -> Result<PathBuf> {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .map(|state_home| state_home.join(MARKER_FILE_NAME))
        .ok_or_else(|| anyhow!("XDG_STATE_HOME and HOME are not set"))
}

fn is_regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn voxtype_states_are_normalized_without_payloads() {
        assert_eq!(normalize_voice_state("idle"), VoiceState::Idle);
        assert_eq!(normalize_voice_state("recording\n"), VoiceState::Recording);
        assert_eq!(normalize_voice_state("streaming"), VoiceState::Processing);
        assert_eq!(
            normalize_voice_state("transcribing"),
            VoiceState::Processing
        );
        assert_eq!(
            normalize_voice_state("transcript: private"),
            VoiceState::Unavailable
        );
    }

    #[tokio::test]
    async fn start_uses_exact_safe_args_once_and_claims_ownership() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        let marker = temp.path().join("owned/dictation-active");
        let log = temp.path().join("args");
        fs::write(&state, "idle").unwrap();
        let binary = fake_voxtype(temp.path(), &log, true);
        let controller = VoiceController::new(binary, state, marker.clone(), "owner");

        let snapshot = controller.perform(ActionKind::VoiceStart).await.unwrap();

        assert_eq!(
            fs::read_to_string(log).unwrap(),
            "record start --type --no-auto-submit --no-smart-auto-submit\n"
        );
        assert_eq!(fs::read_to_string(marker).unwrap(), "owner");
        assert_eq!(
            snapshot,
            VoiceSnapshot {
                state: VoiceState::Recording,
                owned: true
            }
        );
    }

    #[tokio::test]
    async fn failed_start_is_static_not_retried_and_releases_marker() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        let marker = temp.path().join("owned/dictation-active");
        let log = temp.path().join("args");
        fs::write(&state, "idle").unwrap();
        let binary = fake_voxtype(temp.path(), &log, false);
        let controller = VoiceController::new(binary, state, marker.clone(), "owner");

        let error = controller
            .perform(ActionKind::VoiceStart)
            .await
            .unwrap_err();

        assert_eq!(error, VoiceActionError::CommandFailed);
        assert_eq!(error.to_string(), "voice action failed");
        assert_eq!(
            fs::read_to_string(log).unwrap(),
            "record start --type --no-auto-submit --no-smart-auto-submit\nrecord cancel\n"
        );
        assert!(!marker.exists());
    }

    #[tokio::test]
    async fn hung_voice_command_is_killed_after_the_bound() {
        let temp = tempfile::tempdir().unwrap();
        let binary = temp.path().join("voxtype-hangs");
        fs::write(&binary, "#!/bin/sh\nsleep 30\n").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();

        let completed =
            run_voxtype_with_timeout(&binary, &["record", "start"], Duration::from_millis(25))
                .await;

        assert!(!completed);
    }

    #[tokio::test]
    async fn stop_and_cancel_require_the_current_daemon_owner() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        let marker = temp.path().join("owned/dictation-active");
        let log = temp.path().join("args");
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&state, "recording").unwrap();
        fs::write(&marker, "different-owner").unwrap();
        let binary = fake_voxtype(temp.path(), &log, true);
        let controller = VoiceController::new(binary, state, marker, "owner");

        assert_eq!(
            controller.perform(ActionKind::VoiceStop).await,
            Err(VoiceActionError::NotOwned)
        );
        assert!(!log.exists());
    }

    #[tokio::test]
    async fn stale_owned_recording_is_cancelled_before_marker_removal() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("state");
        let marker = temp.path().join("owned/dictation-active");
        let log = temp.path().join("args");
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&state, "recording").unwrap();
        fs::write(&marker, "stale-owner").unwrap();
        let binary = fake_voxtype(temp.path(), &log, true);

        cleanup_owned_dictation_at(&binary, &state, &marker)
            .await
            .unwrap();

        assert_eq!(fs::read_to_string(log).unwrap(), "record cancel\n");
        assert!(!marker.exists());
    }

    fn fake_voxtype(root: &Path, log: &Path, success: bool) -> PathBuf {
        let binary = root.join(if success {
            "voxtype-success"
        } else {
            "voxtype-failure"
        });
        fs::write(
            &binary,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nprintf '%s\\n' 'private transcript stderr' >&2\nexit {}\n",
                log.display(),
                if success { 0 } else { 1 }
            ),
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        binary
    }
}
