use std::{
    collections::{HashMap, HashSet},
    fs,
    path::Path,
    process::Stdio,
};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use tokio::process::Command;

use crate::config::DesktopConfig;

#[derive(Debug, Clone)]
pub struct DesktopController {
    config: DesktopConfig,
    remembered_window: Option<String>,
}

#[derive(Debug, Deserialize)]
struct HyprClient {
    address: String,
    #[serde(default)]
    class: String,
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
            remembered_window: None,
        }
    }

    pub async fn remember_non_edge_focus(&mut self) {
        let Ok((clients, monitors)) = hypr_state().await else {
            return;
        };
        let Some(focused_monitor) = monitors.iter().find(|monitor| monitor.focused) else {
            return;
        };
        if self
            .config
            .edge_output
            .as_deref()
            .is_some_and(|edge| edge == focused_monitor.name)
        {
            return;
        }
        let Some(client) = clients
            .iter()
            .find(|client| client.monitor == focused_monitor.id)
            .filter(|client| !client.address.is_empty())
        else {
            return;
        };
        self.remembered_window = Some(client.address.clone());
    }

    pub async fn restore_focus(&self) -> Result<()> {
        let address = self
            .remembered_window
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("no non-EDGE window has been observed"))?;
        let (clients, _) = hypr_state().await?;
        if !clients.iter().any(|client| client.address == address) {
            bail!("remembered window no longer exists");
        }
        dispatch_focus(address).await
    }

    pub async fn activate_herdr(&self, session: &str, socket_path: &Path) -> Result<()> {
        let (clients, _) = hypr_state().await?;
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
        dispatch_focus(&candidates[0].address).await
    }
}

async fn hypr_state() -> Result<(Vec<HyprClient>, Vec<HyprMonitor>)> {
    let clients = hypr_json(&["clients", "-j"]).await?;
    let monitors = hypr_json(&["monitors", "-j"]).await?;
    Ok((clients, monitors))
}

async fn hypr_json<T: for<'de> Deserialize<'de>>(args: &[&str]) -> Result<T> {
    let output = Command::new("hyprctl")
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

async fn dispatch_focus(address: &str) -> Result<()> {
    let output = Command::new("hyprctl")
        .args(["dispatch", "focuswindow", &format!("address:{address}")])
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .context("restoring Hyprland focus")?;
    if !output.status.success() {
        bail!(
            "Hyprland focus dispatch failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
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
            .any(|value| value.starts_with("HERDR_SESSION="));
    !names_other_session || session_argument || session_environment || socket_environment
}

#[cfg(test)]
mod tests {
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
    }
}
