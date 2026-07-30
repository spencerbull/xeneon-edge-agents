use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    process::Command,
    sync::{mpsc, oneshot},
    time::timeout,
};
use uuid::Uuid;

use crate::model::{
    ActionCapability, ActionKind, AgentActions, AgentStatus, AgentView, SessionState, SessionView,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone)]
pub struct HerdrClient {
    binary: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionDescriptor {
    pub name: String,
    pub running: bool,
    pub socket_path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct AgentTarget {
    pub session: String,
    pub socket_path: PathBuf,
    pub pane_id: String,
    pub terminal_id: String,
    pub state_change_seq: u64,
    pub revision: u64,
}

#[derive(Debug)]
pub struct SessionObservation {
    pub session: SessionView,
    pub agents: Vec<AgentView>,
    pub targets: HashMap<String, AgentTarget>,
    pub pane_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct SessionList {
    sessions: Vec<SessionDescriptor>,
}

#[derive(Debug, Deserialize)]
struct PingResult {
    result: Pong,
}

#[derive(Debug, Deserialize)]
struct Pong {
    version: String,
    protocol: u32,
}

#[derive(Debug, Deserialize)]
struct SnapshotResponse {
    result: SnapshotResult,
}

#[derive(Debug, Deserialize)]
struct SnapshotResult {
    snapshot: HerdrSnapshot,
}

#[derive(Debug, Deserialize)]
struct HerdrSnapshot {
    #[serde(default)]
    workspaces: Vec<HerdrWorkspace>,
    #[serde(default)]
    agents: Vec<HerdrAgent>,
}

#[derive(Debug, Deserialize)]
struct HerdrWorkspace {
    workspace_id: String,
    number: u32,
    label: String,
}

#[derive(Debug, Deserialize)]
struct HerdrAgent {
    terminal_id: String,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    display_agent: Option<String>,
    #[serde(default)]
    terminal_title_stripped: Option<String>,
    #[serde(default)]
    agent_status: AgentStatus,
    workspace_id: String,
    #[serde(default)]
    tab_id: String,
    pane_id: String,
    #[serde(default)]
    focused: bool,
    #[serde(default)]
    state_change_seq: u64,
    #[serde(default)]
    cwd: Option<PathBuf>,
    #[serde(default)]
    foreground_cwd: Option<PathBuf>,
    #[serde(default)]
    revision: u64,
    #[serde(flatten)]
    extra: HashMap<String, Value>,
}

impl HerdrClient {
    pub fn new(binary: impl Into<PathBuf>) -> Self {
        Self {
            binary: binary.into(),
        }
    }

    pub async fn discover(&self) -> Result<Vec<SessionDescriptor>> {
        let output = Command::new(&self.binary)
            .args(["session", "list", "--json"])
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .await
            .with_context(|| format!("running {} session list", self.binary.display()))?;
        if !output.status.success() {
            bail!(
                "herdr session list failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        let mut sessions: SessionList =
            serde_json::from_slice(&output.stdout).context("parsing Herdr session list")?;
        sessions.sessions.retain(|session| session.running);
        Ok(sessions.sessions)
    }

    pub async fn observe_session(
        &self,
        descriptor: &SessionDescriptor,
        daemon_epoch: &str,
        source_offset: usize,
        now_ms: u64,
    ) -> Result<SessionObservation> {
        let ping: PingResult = request(
            &descriptor.socket_path,
            json!({"id": request_id(), "method": "ping", "params": {}}),
        )
        .await?;
        let response: SnapshotResponse = request(
            &descriptor.socket_path,
            json!({"id": request_id(), "method": "session.snapshot", "params": {}}),
        )
        .await?;

        let workspaces: HashMap<_, _> = response
            .result
            .snapshot
            .workspaces
            .into_iter()
            .map(|workspace| (workspace.workspace_id.clone(), workspace))
            .collect();
        let mut targets = HashMap::new();
        let mut pane_ids = Vec::new();
        let mut agents = Vec::new();

        for (index, raw) in response.result.snapshot.agents.into_iter().enumerate() {
            let id = opaque_agent_id(daemon_epoch, &descriptor.name, &raw.terminal_id);
            let workspace = workspaces.get(&raw.workspace_id);
            let workspace_label = workspace.map_or_else(
                || raw.workspace_id.clone(),
                |workspace| format!("{} · {}", workspace.number, workspace.label),
            );
            let agent_name = raw.agent.clone().unwrap_or_else(|| "agent".into());
            let display_name = raw
                .display_agent
                .clone()
                .or(raw.title.clone())
                .or(raw.terminal_title_stripped.clone())
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| agent_name.clone());
            let cwd = raw.foreground_cwd.as_ref().or(raw.cwd.as_ref());
            let repository = cwd
                .and_then(|path| path.file_name())
                .map(|name| name.to_string_lossy().into_owned());
            let actions = actions_from_extra(&raw.extra, raw.revision);

            targets.insert(
                id.clone(),
                AgentTarget {
                    session: descriptor.name.clone(),
                    socket_path: descriptor.socket_path.clone(),
                    pane_id: raw.pane_id.clone(),
                    terminal_id: raw.terminal_id,
                    state_change_seq: raw.state_change_seq,
                    revision: raw.revision,
                },
            );
            pane_ids.push(raw.pane_id);
            agents.push(AgentView {
                id,
                display_name,
                agent: agent_name,
                status: raw.agent_status,
                workspace: workspace_label,
                repository,
                worktree: raw
                    .extra
                    .get("worktree")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                session: descriptor.name.clone(),
                focused: raw.focused,
                observed_for_seconds: 0,
                source_order: source_offset + index,
                actions: AgentActions {
                    open: true,
                    zoom: true,
                    ..actions
                },
            });

            let _ = &raw.tab_id;
        }

        Ok(SessionObservation {
            session: SessionView {
                name: descriptor.name.clone(),
                state: SessionState::Connected,
                version: Some(ping.result.version),
                protocol: Some(ping.result.protocol),
                last_sync_ms: Some(now_ms),
                message: None,
            },
            agents,
            targets,
            pane_ids,
        })
    }

    pub async fn perform(
        &self,
        target: &AgentTarget,
        action: ActionKind,
        capability_id: Option<&str>,
    ) -> Result<()> {
        let payload = match action {
            ActionKind::Open => {
                json!({"id": request_id(), "method": "agent.focus", "params": {"target": target.pane_id}})
            }
            ActionKind::Zoom => {
                json!({"id": request_id(), "method": "pane.zoom", "params": {"pane_id": target.pane_id, "mode": "toggle"}})
            }
            ActionKind::Approve | ActionKind::Interrupt => {
                let capability_id = capability_id.ok_or_else(|| anyhow!("missing capability"))?;
                json!({"id": request_id(), "method": "agent.perform_action", "params": {"capability_id": capability_id}})
            }
            ActionKind::RestoreFocus => bail!("restore focus is a desktop action"),
        };
        let response: Value = request(&target.socket_path, payload).await?;
        if let Some(error) = response.get("error") {
            bail!("Herdr action failed: {error}");
        }
        Ok(())
    }

    pub fn spawn_subscription(
        &self,
        descriptor: SessionDescriptor,
        pane_ids: Vec<String>,
        invalidations: mpsc::Sender<String>,
    ) -> (
        tokio::task::JoinHandle<()>,
        oneshot::Receiver<Result<(), String>>,
    ) {
        let (ready_tx, ready_rx) = oneshot::channel();
        let handle = tokio::spawn(async move {
            if let Err(error) = watch_events(&descriptor, &pane_ids, &invalidations, ready_tx).await
            {
                tracing::warn!(session = %descriptor.name, %error, "Herdr event subscription ended");
            }
            let _ = invalidations.try_send(descriptor.name);
        });
        (handle, ready_rx)
    }
}

fn actions_from_extra(extra: &HashMap<String, Value>, revision: u64) -> AgentActions {
    let values = extra.get("actions").and_then(Value::as_array);
    let Some(values) = values else {
        return AgentActions::default();
    };

    let mut actions = AgentActions::default();
    for value in values {
        let Some(kind) = value.get("action").and_then(Value::as_str) else {
            continue;
        };
        let Some(capability_id) = value.get("capability_id").and_then(Value::as_str) else {
            continue;
        };
        let Some(action_kind) = (match kind {
            "approve" => Some(ActionKind::Approve),
            "interrupt" => Some(ActionKind::Interrupt),
            _ => None,
        }) else {
            continue;
        };
        let capability = ActionCapability {
            capability_id: capability_id.to_owned(),
            kind: action_kind,
            expires_at_ms: value
                .get("expires_at_unix_ms")
                .and_then(Value::as_u64)
                .unwrap_or_default(),
            expected_revision: value
                .get("revision")
                .and_then(Value::as_u64)
                .unwrap_or(revision),
        };
        match action_kind {
            ActionKind::Approve => actions.approve = Some(capability),
            ActionKind::Interrupt => actions.interrupt = Some(capability),
            _ => {}
        }
    }
    actions
}

async fn watch_events(
    descriptor: &SessionDescriptor,
    pane_ids: &[String],
    invalidations: &mpsc::Sender<String>,
    ready: oneshot::Sender<Result<(), String>>,
) -> Result<()> {
    let mut subscriptions = vec![
        json!({"type": "workspace.created"}),
        json!({"type": "workspace.updated"}),
        json!({"type": "workspace.renamed"}),
        json!({"type": "workspace.moved"}),
        json!({"type": "workspace.closed"}),
        json!({"type": "workspace.focused"}),
        json!({"type": "tab.created"}),
        json!({"type": "tab.closed"}),
        json!({"type": "tab.focused"}),
        json!({"type": "tab.renamed"}),
        json!({"type": "tab.moved"}),
        json!({"type": "pane.created"}),
        json!({"type": "pane.closed"}),
        json!({"type": "pane.focused"}),
        json!({"type": "pane.moved"}),
        json!({"type": "pane.exited"}),
        json!({"type": "pane.agent_detected"}),
    ];
    subscriptions.extend(
        pane_ids
            .iter()
            .map(|pane_id| json!({"type": "pane.agent_status_changed", "pane_id": pane_id})),
    );

    let stream = match timeout(
        REQUEST_TIMEOUT,
        UnixStream::connect(&descriptor.socket_path),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            let message = format!(
                "connecting subscription {}: {error}",
                descriptor.socket_path.display()
            );
            let _ = ready.send(Err(message.clone()));
            bail!(message);
        }
        Err(_) => {
            let message = "timed out connecting subscription".to_owned();
            let _ = ready.send(Err(message.clone()));
            bail!(message);
        }
    };
    let (read, mut write) = stream.into_split();
    let request = json!({
        "id": request_id(),
        "method": "events.subscribe",
        "params": {"subscriptions": subscriptions}
    });
    write
        .write_all(serde_json::to_string(&request)?.as_bytes())
        .await?;
    write.write_all(b"\n").await?;
    write.flush().await?;

    let mut lines = BufReader::new(read).lines();
    let acknowledgement = match timeout(REQUEST_TIMEOUT, lines.next_line()).await {
        Ok(Ok(Some(line))) => line,
        Ok(Ok(None)) => {
            let message = "subscription closed before acknowledgement".to_owned();
            let _ = ready.send(Err(message.clone()));
            bail!(message);
        }
        Ok(Err(error)) => {
            let message = format!("reading subscription acknowledgement: {error}");
            let _ = ready.send(Err(message.clone()));
            bail!(message);
        }
        Err(_) => {
            let message = "timed out waiting for subscription acknowledgement".to_owned();
            let _ = ready.send(Err(message.clone()));
            bail!(message);
        }
    };
    let acknowledgement: Value = match serde_json::from_str(&acknowledgement) {
        Ok(value) => value,
        Err(error) => {
            let message = format!("parsing subscription acknowledgement: {error}");
            let _ = ready.send(Err(message.clone()));
            bail!(message);
        }
    };
    if acknowledgement["result"]["type"] != "subscription_started" {
        let message = format!("unexpected subscription acknowledgement: {acknowledgement}");
        let _ = ready.send(Err(message.clone()));
        bail!(message);
    }
    let _ = ready.send(Ok(()));

    while let Some(line) = lines.next_line().await? {
        if serde_json::from_str::<Value>(&line).is_ok() {
            let _ = invalidations.try_send(descriptor.name.clone());
        }
    }
    bail!("Herdr subscription reached EOF")
}

async fn request<T: for<'de> Deserialize<'de>>(socket: &Path, request: Value) -> Result<T> {
    let stream = timeout(REQUEST_TIMEOUT, UnixStream::connect(socket))
        .await
        .context("timed out connecting to Herdr")?
        .with_context(|| format!("connecting to Herdr socket {}", socket.display()))?;
    let (read, mut write) = stream.into_split();
    let encoded = serde_json::to_vec(&request)?;
    write.write_all(&encoded).await?;
    write.write_all(b"\n").await?;
    write.flush().await?;

    let mut lines = BufReader::new(read).lines();
    let response = timeout(REQUEST_TIMEOUT, lines.next_line())
        .await
        .context("timed out waiting for Herdr response")??
        .ok_or_else(|| anyhow!("Herdr closed without a response"))?;
    serde_json::from_str(&response).with_context(|| format!("parsing Herdr response: {response}"))
}

fn opaque_agent_id(epoch: &str, session: &str, terminal_id: &str) -> String {
    Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        format!("{epoch}\0{session}\0{terminal_id}").as_bytes(),
    )
    .to_string()
}

fn request_id() -> String {
    format!("xeneon-{}", Uuid::new_v4())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::UnixListener,
        sync::{mpsc, oneshot},
    };

    #[test]
    fn opaque_ids_change_with_daemon_epoch() {
        let first = opaque_agent_id("one", "default", "terminal");
        let second = opaque_agent_id("two", "default", "terminal");
        assert_ne!(first, second);
        assert_eq!(first, opaque_agent_id("one", "default", "terminal"));
    }

    #[test]
    fn legacy_capability_shapes_never_surface_guarded_actions() {
        let mut extra = HashMap::new();
        extra.insert(
            "action_capabilities".into(),
            json!([{"id":"unsafe","kind":"approve","expires_at_ms":99}]),
        );
        let actions = actions_from_extra(&extra, 1);
        assert!(actions.approve.is_none());
        assert!(actions.interrupt.is_none());
    }

    #[test]
    fn public_actions_parse_only_known_capabilities() {
        let mut extra = HashMap::new();
        extra.insert(
            "actions".into(),
            json!([
                {"capability_id":"approve-1","action":"approve","expires_at_unix_ms":99,"revision":7},
                {"capability_id":"interrupt-1","action":"interrupt","expires_at_unix_ms":101,"revision":8},
                {"capability_id":"other","action":"shell","expires_at_unix_ms":99}
            ]),
        );
        let actions = actions_from_extra(&extra, 3);
        assert_eq!(
            actions
                .approve
                .as_ref()
                .map(|value| value.capability_id.as_str()),
            Some("approve-1")
        );
        assert_eq!(
            actions.interrupt.as_ref().map(|value| (
                value.capability_id.as_str(),
                value.expires_at_ms,
                value.expected_revision
            )),
            Some(("interrupt-1", 101, 8))
        );
    }

    #[tokio::test]
    async fn subscription_acknowledges_before_forwarding_invalidations() {
        let temp = tempdir().unwrap();
        let socket = temp.path().join("herdr.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], "events.subscribe");
            let subscription_types = request["params"]["subscriptions"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|subscription| subscription["type"].as_str())
                .collect::<Vec<_>>();
            assert!(subscription_types.contains(&"pane.agent_status_changed"));
            assert!(!subscription_types.contains(&"pane.updated"));
            assert!(!subscription_types.contains(&"layout.updated"));
            assert!(!subscription_types.contains(&"workspace.metadata_updated"));
            write
                .write_all(b"{\"id\":\"sub\",\"result\":{\"type\":\"subscription_started\"}}\n")
                .await
                .unwrap();
            write
                .write_all(
                    b"{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"w1:p1\"}}\n",
                )
                .await
                .unwrap();
        });
        let descriptor = SessionDescriptor {
            name: "default".into(),
            running: true,
            socket_path: socket,
        };
        let (invalidations_tx, mut invalidations_rx) = mpsc::channel(2);
        let (ready_tx, ready_rx) = oneshot::channel();
        let watcher = tokio::spawn(async move {
            watch_events(&descriptor, &["w1:p1".into()], &invalidations_tx, ready_tx).await
        });

        assert_eq!(ready_rx.await.unwrap(), Ok(()));
        assert_eq!(invalidations_rx.recv().await.as_deref(), Some("default"));
        server.await.unwrap();
        assert!(watcher.await.unwrap().is_err());
    }

    #[tokio::test]
    async fn bad_subscription_ack_never_becomes_ready() {
        let temp = tempdir().unwrap();
        let socket = temp.path().join("herdr.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let _ = lines.next_line().await.unwrap();
            write
                .write_all(b"{\"id\":\"sub\",\"error\":{\"code\":\"invalid\"}}\n")
                .await
                .unwrap();
        });
        let descriptor = SessionDescriptor {
            name: "default".into(),
            running: true,
            socket_path: socket,
        };
        let (invalidations_tx, _) = mpsc::channel(1);
        let (ready_tx, ready_rx) = oneshot::channel();
        let result = watch_events(&descriptor, &[], &invalidations_tx, ready_tx).await;
        assert!(result.is_err());
        assert!(ready_rx.await.unwrap().is_err());
        server.await.unwrap();
    }
}
