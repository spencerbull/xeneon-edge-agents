use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::Mutex;
use tokio::time::{sleep, timeout};

use crate::config::DesktopConfig;

const PORTAL_PREVIEW_CLASS_PREFIX: &str = "org.xeneon-edge.agent-portal-preview";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DesktopApp {
    ChatGpt,
    Claude,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesktopAppOutcome {
    Focused,
    LaunchedAndFocused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DesktopAppSpec {
    desktop_id: &'static str,
    class: &'static str,
}

#[derive(Debug, Clone)]
pub struct DesktopController {
    config: DesktopConfig,
    remembered_window: Arc<Mutex<Option<String>>>,
    launching_since: Arc<Mutex<HashMap<DesktopApp, Instant>>>,
    hyprctl_bin: PathBuf,
    uwsm_app_bin: PathBuf,
    launch_poll_interval: Duration,
    launch_observation_timeout: Duration,
    launch_coalesce_for: Duration,
}

#[derive(Debug, Deserialize)]
struct HyprClient {
    address: String,
    #[serde(default)]
    class: String,
    #[serde(default, rename = "initialClass")]
    initial_class: String,
    #[serde(default)]
    title: String,
    pid: i32,
    monitor: i64,
}

#[derive(Debug, Deserialize)]
struct HyprMonitor {
    id: i64,
    name: String,
    #[serde(default)]
    focused: bool,
}

impl DesktopController {
    pub fn new(config: DesktopConfig) -> Self {
        Self {
            config,
            remembered_window: Arc::new(Mutex::new(None)),
            launching_since: Arc::new(Mutex::new(HashMap::new())),
            hyprctl_bin: PathBuf::from("hyprctl"),
            uwsm_app_bin: PathBuf::from("uwsm-app"),
            launch_poll_interval: Duration::from_millis(100),
            launch_observation_timeout: Duration::from_secs(12),
            launch_coalesce_for: Duration::from_secs(20),
        }
    }

    pub async fn remember_non_edge_focus(&self) {
        let Ok(active) = hypr_json::<HyprClient>(&self.hyprctl_bin, &["activewindow", "-j"]).await
        else {
            return;
        };
        let Ok(monitors) =
            hypr_json::<Vec<HyprMonitor>>(&self.hyprctl_bin, &["monitors", "-j"]).await
        else {
            return;
        };
        let Some(active_monitor) = monitors
            .iter()
            .find(|monitor| monitor.id == active.monitor)
            .or_else(|| monitors.iter().find(|monitor| monitor.focused))
        else {
            return;
        };
        if self
            .config
            .edge_output
            .as_deref()
            .is_some_and(|edge| edge == active_monitor.name)
        {
            return;
        }
        if active.address.is_empty() {
            return;
        }
        if is_portal_preview_class(&active.class) {
            return;
        }
        *self.remembered_window.lock().await = Some(active.address);
    }

    pub async fn restore_focus(&self) -> Result<()> {
        let address = self
            .remembered_window
            .lock()
            .await
            .clone()
            .ok_or_else(|| anyhow::anyhow!("no non-EDGE window has been observed"))?;
        let (clients, _) = hypr_state(&self.hyprctl_bin).await?;
        if !clients.iter().any(|client| client.address == address) {
            bail!("remembered window no longer exists");
        }
        dispatch_focus(&self.hyprctl_bin, &address).await
    }

    pub async fn focus_or_launch(&self, app: DesktopApp) -> Result<DesktopAppOutcome> {
        let spec = desktop_app_spec(app);
        let clients = hypr_json::<Vec<HyprClient>>(&self.hyprctl_bin, &["clients", "-j"]).await?;
        let candidates = desktop_candidates(&clients, spec);
        match candidates.as_slice() {
            [client] => {
                self.launching_since.lock().await.remove(&app);
                dispatch_focus(&self.hyprctl_bin, &client.address).await?;
                Ok(DesktopAppOutcome::Focused)
            }
            [] => {
                let now = Instant::now();
                let mut launches = self.launching_since.lock().await;
                let launch_in_flight = launches
                    .get(&app)
                    .is_some_and(|started| now.duration_since(*started) < self.launch_coalesce_for);
                if !launch_in_flight {
                    launches.insert(app, now);
                }
                drop(launches);
                if !launch_in_flight
                    && let Err(error) = launch_desktop(&self.uwsm_app_bin, spec).await
                {
                    self.launching_since.lock().await.remove(&app);
                    return Err(error);
                }
                self.wait_for_launched_client(app, spec).await
            }
            _ => bail!(
                "expected at most one {} window, found {}",
                spec.class,
                candidates.len()
            ),
        }
    }

    async fn wait_for_launched_client(
        &self,
        app: DesktopApp,
        spec: DesktopAppSpec,
    ) -> Result<DesktopAppOutcome> {
        let deadline = Instant::now() + self.launch_observation_timeout;
        loop {
            let clients =
                hypr_json::<Vec<HyprClient>>(&self.hyprctl_bin, &["clients", "-j"]).await?;
            let candidates = desktop_candidates(&clients, spec);
            match candidates.as_slice() {
                [client] => {
                    self.launching_since.lock().await.remove(&app);
                    dispatch_focus(&self.hyprctl_bin, &client.address).await?;
                    return Ok(DesktopAppOutcome::LaunchedAndFocused);
                }
                [] if Instant::now() < deadline => sleep(self.launch_poll_interval).await,
                [] => bail!("desktop client did not map before the launch deadline"),
                _ => {
                    self.launching_since.lock().await.remove(&app);
                    bail!(
                        "expected one {} window after launch, found {}",
                        spec.class,
                        candidates.len()
                    );
                }
            }
        }
    }

    pub async fn activate_herdr(&self, session: &str, socket_path: &Path) -> Result<()> {
        let (clients, _) = hypr_state(&self.hyprctl_bin).await?;
        let class = self.config.herdr_class.to_ascii_lowercase();
        let candidates: Vec<_> = clients
            .iter()
            .filter(|client| {
                client.class.to_ascii_lowercase().contains(&class)
                    || client.title.to_ascii_lowercase().contains(&class)
            })
            .filter(|client| client_hosts_session(client.pid, session, socket_path))
            .collect();
        if candidates.len() != 1 {
            bail!(
                "expected one Herdr window for session {session}, found {}",
                candidates.len()
            );
        }
        dispatch_focus(&self.hyprctl_bin, &candidates[0].address).await
    }
}

fn desktop_candidates(clients: &[HyprClient], spec: DesktopAppSpec) -> Vec<&HyprClient> {
    clients
        .iter()
        .filter(|client| {
            client.class.eq_ignore_ascii_case(spec.class)
                || client.initial_class.eq_ignore_ascii_case(spec.class)
        })
        .collect()
}

fn desktop_app_spec(app: DesktopApp) -> DesktopAppSpec {
    match app {
        DesktopApp::ChatGpt => DesktopAppSpec {
            desktop_id: "chatgpt-linux-poc.desktop",
            class: "chatgpt-linux-poc",
        },
        DesktopApp::Claude => DesktopAppSpec {
            desktop_id: "com.anthropic.Claude.desktop",
            class: "com.anthropic.Claude",
        },
    }
}

async fn launch_desktop(uwsm_app_bin: &Path, spec: DesktopAppSpec) -> Result<()> {
    let mut child = Command::new(uwsm_app_bin)
        .args(["--", "gtk-launch", spec.desktop_id])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("launching desktop entry {}", spec.desktop_id))?;

    match timeout(Duration::from_millis(500), child.wait()).await {
        Ok(status) => {
            if status?.success() {
                Ok(())
            } else {
                bail!("desktop launch command failed")
            }
        }
        Err(_) => {
            tokio::spawn(async move {
                if let Ok(status) = child.wait().await
                    && !status.success()
                {
                    tracing::warn!(?status, "desktop application exited unsuccessfully");
                }
            });
            Ok(())
        }
    }
}

fn is_portal_preview_class(class: &str) -> bool {
    class.starts_with(PORTAL_PREVIEW_CLASS_PREFIX)
}

async fn hypr_state(hyprctl_bin: &Path) -> Result<(Vec<HyprClient>, Vec<HyprMonitor>)> {
    let clients = hypr_json(hyprctl_bin, &["clients", "-j"]).await?;
    let monitors = hypr_json(hyprctl_bin, &["monitors", "-j"]).await?;
    Ok((clients, monitors))
}

async fn hypr_json<T: for<'de> Deserialize<'de>>(hyprctl_bin: &Path, args: &[&str]) -> Result<T> {
    let output = Command::new(hyprctl_bin)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .context("running hyprctl")?;
    if !output.status.success() {
        bail!(
            "hyprctl failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    serde_json::from_slice(&output.stdout).context("parsing hyprctl JSON")
}

async fn dispatch_focus(hyprctl_bin: &Path, address: &str) -> Result<()> {
    let expression = focus_expression(address)?;
    let output = Command::new(hyprctl_bin)
        .args(["dispatch", &expression])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .context("restoring Hyprland focus")?;
    if !output.status.success() {
        bail!(
            "Hyprland focus dispatch failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim(),
        );
    }
    Ok(())
}

fn focus_expression(address: &str) -> Result<String> {
    let Some(hex) = address.strip_prefix("0x") else {
        bail!("Hyprland window address lacks 0x prefix");
    };
    if hex.is_empty() || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Hyprland window address is not hexadecimal");
    }
    Ok(format!(
        "hl.dsp.focus({{ window = \"address:{address}\" }})"
    ))
}

fn client_hosts_session(client_pid: i32, session: &str, socket_path: &Path) -> bool {
    let processes = process_table();
    processes.iter().any(|(pid, process)| {
        is_descendant(*pid, client_pid, &processes)
            && command_matches_session(&process.command, &process.environment, session, socket_path)
    })
}

#[derive(Debug)]
struct ProcessInfo {
    parent: i32,
    command: Vec<String>,
    environment: Vec<String>,
}

fn process_table() -> HashMap<i32, ProcessInfo> {
    let mut table = HashMap::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return table;
    };
    for entry in entries.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        let path = entry.path();
        let Some(parent) = process_parent(&path.join("stat")) else {
            continue;
        };
        table.insert(
            pid,
            ProcessInfo {
                parent,
                command: nul_fields(&path.join("cmdline")),
                environment: nul_fields(&path.join("environ")),
            },
        );
    }
    table
}

fn process_parent(path: &Path) -> Option<i32> {
    let stat = fs::read_to_string(path).ok()?;
    let end = stat.rfind(')')?;
    stat.get(end + 2..)?.split_whitespace().nth(1)?.parse().ok()
}

fn nul_fields(path: &Path) -> Vec<String> {
    fs::read(path)
        .unwrap_or_default()
        .split(|byte| *byte == 0)
        .filter(|field| !field.is_empty())
        .map(|field| String::from_utf8_lossy(field).into_owned())
        .collect()
}

fn is_descendant(pid: i32, ancestor: i32, table: &HashMap<i32, ProcessInfo>) -> bool {
    let mut current = pid;
    let mut visited = HashSet::new();
    for _ in 0..32 {
        if current == ancestor {
            return true;
        }
        if !visited.insert(current) {
            return false;
        }
        let Some(process) = table.get(&current) else {
            return false;
        };
        if process.parent <= 1 {
            return false;
        }
        current = process.parent;
    }
    false
}

fn command_matches_session(
    command: &[String],
    environment: &[String],
    session: &str,
    socket_path: &Path,
) -> bool {
    let is_herdr = command
        .first()
        .and_then(|value| Path::new(value).file_name())
        .is_some_and(|name| name == "herdr");
    if !is_herdr {
        return false;
    }

    let session_argument = command
        .windows(2)
        .any(|pair| pair[0] == "--session" && pair[1] == session);
    let session_environment = environment
        .iter()
        .any(|value| value == &format!("HERDR_SESSION={session}"));
    let socket_environment = environment
        .iter()
        .any(|value| value == &format!("HERDR_SOCKET_PATH={}", socket_path.to_string_lossy()));

    if session != "default" {
        return session_argument || session_environment || socket_environment;
    }
    let names_other_session = command.iter().any(|value| value == "--session")
        || environment
            .iter()
            .any(|value| value.starts_with("HERDR_SESSION="))
        || environment
            .iter()
            .any(|value| value.starts_with("HERDR_SOCKET_PATH=") && !socket_environment);
    !names_other_session || session_argument || session_environment || socket_environment
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn named_session_requires_exact_identity() {
        assert!(command_matches_session(
            &["/usr/bin/herdr".into(), "--session".into(), "work".into()],
            &[],
            "work",
            Path::new("/tmp/work.sock")
        ));
        assert!(!command_matches_session(
            &["/usr/bin/herdr".into(), "--session".into(), "other".into()],
            &[],
            "work",
            Path::new("/tmp/work.sock")
        ));
    }

    #[test]
    fn default_does_not_claim_named_client() {
        assert!(!command_matches_session(
            &["herdr".into(), "--session".into(), "work".into()],
            &[],
            "default",
            Path::new("/tmp/default.sock")
        ));
        assert!(command_matches_session(
            &["herdr".into()],
            &[],
            "default",
            Path::new("/tmp/default.sock")
        ));
        assert!(!command_matches_session(
            &["herdr".into()],
            &["HERDR_SOCKET_PATH=/tmp/named.sock".into()],
            "default",
            Path::new("/tmp/default.sock")
        ));
    }

    #[test]
    fn desktop_apps_are_fixed_allowlisted_targets() {
        assert_eq!(
            desktop_app_spec(DesktopApp::ChatGpt),
            DesktopAppSpec {
                desktop_id: "chatgpt-linux-poc.desktop",
                class: "chatgpt-linux-poc",
            }
        );
        assert_eq!(
            desktop_app_spec(DesktopApp::Claude),
            DesktopAppSpec {
                desktop_id: "com.anthropic.Claude.desktop",
                class: "com.anthropic.Claude",
            }
        );
    }

    #[test]
    fn focus_expression_uses_installed_lua_dispatcher_syntax() {
        assert_eq!(
            focus_expression("0x123abc").unwrap(),
            "hl.dsp.focus({ window = \"address:0x123abc\" })"
        );
        assert!(focus_expression("title:herdr").is_err());
        assert!(focus_expression("0x1\" })").is_err());
    }

    #[test]
    fn portal_preview_class_is_never_a_focus_restore_target() {
        assert!(is_portal_preview_class(
            "org.xeneon-edge.agent-portal-preview.123"
        ));
        assert!(!is_portal_preview_class("chatgpt-linux-poc"));
    }

    #[tokio::test]
    async fn concurrent_launch_requests_coalesce_until_one_client_maps() {
        let temp = tempfile::tempdir().unwrap();
        let marker = temp.path().join("mapped");
        let launch_log = temp.path().join("launch.log");
        let focus_log = temp.path().join("focus.log");
        let hyprctl = temp.path().join("hyprctl");
        let uwsm_app = temp.path().join("uwsm-app");
        write_executable(
            &hyprctl,
            &format!(
                r#"#!/bin/sh
if [ "$1" = "clients" ]; then
  if [ -e "{marker}" ]; then
    printf '%s\n' '[{{"address":"0xdef","class":"com.anthropic.Claude","initialClass":"com.anthropic.Claude","title":"Claude","pid":43,"monitor":0}},{{"address":"0xabc","class":"chatgpt-linux-poc","initialClass":"chatgpt-linux-poc","title":"ChatGPT","pid":42,"monitor":0}}]'
  else
    printf '%s\n' '[{{"address":"0xdef","class":"com.anthropic.Claude","initialClass":"com.anthropic.Claude","title":"Claude","pid":43,"monitor":0}}]'
  fi
elif [ "$1" = "dispatch" ]; then
  printf '%s\n' "$*" >> "{focus_log}"
  printf '%s\n' 'ok'
else
  printf '%s\n' '{{}}'
fi
"#,
                marker = marker.display(),
                focus_log = focus_log.display()
            ),
        );
        write_executable(
            &uwsm_app,
            &format!(
                r#"#!/bin/sh
printf '%s\n' "$*" >> "{launch_log}"
( sleep 0.05; : > "{marker}" ) &
sleep 1
"#,
                launch_log = launch_log.display(),
                marker = marker.display()
            ),
        );

        let mut controller = DesktopController::new(DesktopConfig::default());
        controller.hyprctl_bin = hyprctl;
        controller.uwsm_app_bin = uwsm_app;
        controller.launch_poll_interval = Duration::from_millis(10);
        controller.launch_observation_timeout = Duration::from_secs(2);
        controller.launch_coalesce_for = Duration::from_secs(3);
        let controller = Arc::new(controller);

        let first_controller = Arc::clone(&controller);
        let first =
            tokio::spawn(
                async move { first_controller.focus_or_launch(DesktopApp::ChatGpt).await },
            );
        tokio::time::sleep(Duration::from_millis(5)).await;
        let second_controller = Arc::clone(&controller);
        let second =
            tokio::spawn(
                async move { second_controller.focus_or_launch(DesktopApp::ChatGpt).await },
            );
        let other_app_controller = Arc::clone(&controller);
        let other_app = tokio::spawn(async move {
            other_app_controller
                .focus_or_launch(DesktopApp::Claude)
                .await
        });

        assert_eq!(
            tokio::time::timeout(Duration::from_millis(150), other_app)
                .await
                .expect("another app must not wait for ChatGPT mapping")
                .unwrap()
                .unwrap(),
            DesktopAppOutcome::Focused
        );

        assert_eq!(
            first.await.unwrap().unwrap(),
            DesktopAppOutcome::LaunchedAndFocused
        );
        assert_eq!(
            second.await.unwrap().unwrap(),
            DesktopAppOutcome::LaunchedAndFocused
        );
        assert_eq!(fs::read_to_string(launch_log).unwrap().lines().count(), 1);
        assert_eq!(fs::read_to_string(focus_log).unwrap().lines().count(), 3);
    }

    fn write_executable(path: &Path, contents: &str) {
        fs::write(path, contents).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
}
