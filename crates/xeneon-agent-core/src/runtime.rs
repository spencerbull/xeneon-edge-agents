use std::{
    collections::HashMap,
    env, fs,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, RwLock, mpsc, watch},
    task::JoinHandle,
    time::{MissedTickBehavior, interval},
};
use uuid::Uuid;

use crate::{
    Config,
    desktop::DesktopController,
    health::HealthCollector,
    herdr::{AgentTarget, HerdrClient, SessionDescriptor},
    model::{
        ActionKind, ActionResult, AgentActions, AgentStatus, ConnectionState, PortalCommand,
        PortalSnapshot, SCHEMA_VERSION, ServerMessage, SessionState, SessionView, sort_agents,
    },
    protocol::{command_capability_matches, validate_command},
};

#[derive(Debug)]
struct RuntimeState {
    snapshot: PortalSnapshot,
    targets: HashMap<String, AgentTarget>,
    observed: HashMap<String, (AgentStatus, u64, Instant)>,
}

#[derive(Debug)]
struct Subscription {
    pane_ids: Vec<String>,
    handle: JoinHandle<()>,
}

#[derive(Clone)]
pub struct DaemonRuntime {
    config: Config,
    herdr: HerdrClient,
    state: Arc<RwLock<RuntimeState>>,
    desktop: Arc<Mutex<DesktopController>>,
    updates: watch::Sender<String>,
    invalidations: mpsc::Sender<String>,
}

impl DaemonRuntime {
    pub fn new(config: Config) -> Result<(Self, mpsc::Receiver<String>)> {
        config.validate()?;
        let epoch = Uuid::new_v4().to_string();
        let snapshot = PortalSnapshot::empty(epoch);
        let encoded = encode_snapshot(&snapshot)?;
        let (updates, _) = watch::channel(encoded);
        let (invalidations, invalidation_rx) = mpsc::channel(64);
        let desktop = DesktopController::new(config.desktop.clone());
        Ok((
            Self {
                herdr: HerdrClient::new(config.herdr_bin.clone()),
                config,
                state: Arc::new(RwLock::new(RuntimeState {
                    snapshot,
                    targets: HashMap::new(),
                    observed: HashMap::new(),
                })),
                desktop: Arc::new(Mutex::new(desktop)),
                updates,
                invalidations,
            },
            invalidation_rx,
        ))
    }

    pub async fn run(self, path: &Path, invalidation_rx: mpsc::Receiver<String>) -> Result<()> {
        let listener = bind_socket(path)?;
        tracing::info!(socket = %path.display(), "xeneon agent daemon listening");

        let collector_runtime = self.clone();
        let collector = tokio::spawn(async move {
            collector_runtime.collect_loop(invalidation_rx).await;
        });

        loop {
            let (stream, _) = listener.accept().await.context("accepting portal client")?;
            let client_runtime = self.clone();
            tokio::spawn(async move {
                if let Err(error) = client_runtime.handle_client(stream).await {
                    tracing::warn!(%error, "portal client disconnected");
                }
            });
            if collector.is_finished() {
                bail!("state collector stopped unexpectedly");
            }
        }
    }

    async fn collect_loop(&self, mut invalidation_rx: mpsc::Receiver<String>) {
        let mut health = HealthCollector::default();
        let mut health_tick = interval(self.config.health_refresh_interval());
        let mut herdr_tick = interval(self.config.herdr_refresh_interval());
        health_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
        herdr_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let mut subscriptions: HashMap<String, Subscription> = HashMap::new();

        loop {
            tokio::select! {
                _ = health_tick.tick() => {
                    let sample = health.sample();
                    {
                        let mut state = self.state.write().await;
                        state.snapshot.health = sample;
                        state.snapshot.generated_at_ms = now_ms();
                    }
                    self.publish().await;
                    self.desktop.lock().await.remember_non_edge_focus().await;
                }
                _ = herdr_tick.tick() => {
                    self.refresh_herdr(&mut subscriptions).await;
                }
                invalidation = invalidation_rx.recv() => {
                    if invalidation.is_none() {
                        tracing::error!("Herdr invalidation channel closed");
                        return;
                    }
                    self.refresh_herdr(&mut subscriptions).await;
                }
            }
        }
    }

    async fn refresh_herdr(&self, subscriptions: &mut HashMap<String, Subscription>) {
        let now_ms = now_ms();
        let descriptors = match self.herdr.discover().await {
            Ok(descriptors) => descriptors,
            Err(error) => {
                tracing::warn!(%error, "Herdr discovery failed");
                let mut state = self.state.write().await;
                state.snapshot.connection = ConnectionState::Offline;
                for session in &mut state.snapshot.sessions {
                    session.state = SessionState::Stale;
                    session.message = Some(error.to_string());
                }
                for agent in &mut state.snapshot.agents {
                    agent.actions = AgentActions::default();
                }
                state.targets.clear();
                state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
                state.snapshot.generated_at_ms = now_ms;
                drop(state);
                self.publish().await;
                return;
            }
        };

        let epoch = self.state.read().await.snapshot.daemon_epoch.clone();
        let previous_agents = self.state.read().await.snapshot.agents.clone();
        let mut sessions = Vec::new();
        let mut agents = Vec::new();
        let mut targets = HashMap::new();
        let mut connected = 0usize;
        let mut source_offset = 0usize;
        let mut active_names = Vec::new();

        for descriptor in &descriptors {
            active_names.push(descriptor.name.clone());
            match self
                .herdr
                .observe_session(descriptor, &epoch, source_offset, now_ms)
                .await
            {
                Ok(mut observation) => {
                    match update_subscription(
                        subscriptions,
                        &self.herdr,
                        descriptor,
                        observation.pane_ids.clone(),
                        self.invalidations.clone(),
                    )
                    .await
                    {
                        Ok(true) => {
                            match self
                                .herdr
                                .observe_session(descriptor, &epoch, source_offset, now_ms)
                                .await
                            {
                                Ok(reconciled) => observation = reconciled,
                                Err(error) => {
                                    tracing::warn!(
                                        session = %descriptor.name,
                                        %error,
                                        "post-subscription Herdr snapshot failed"
                                    );
                                    if let Some(subscription) =
                                        subscriptions.remove(&descriptor.name)
                                    {
                                        subscription.handle.abort();
                                    }
                                    sessions.push(SessionView {
                                        name: descriptor.name.clone(),
                                        state: SessionState::Stale,
                                        version: observation.session.version.clone(),
                                        protocol: observation.session.protocol,
                                        last_sync_ms: observation.session.last_sync_ms,
                                        message: Some(format!(
                                            "post-subscription reconciliation failed: {error}"
                                        )),
                                    });
                                    let mut stale = observation.agents;
                                    for agent in &mut stale {
                                        agent.actions = AgentActions::default();
                                    }
                                    source_offset += stale.len();
                                    agents.extend(stale);
                                    continue;
                                }
                            }
                        }
                        Ok(false) => {}
                        Err(error) => {
                            tracing::warn!(
                                session = %descriptor.name,
                                %error,
                                "Herdr subscription setup failed"
                            );
                            sessions.push(SessionView {
                                name: descriptor.name.clone(),
                                state: SessionState::Stale,
                                version: observation.session.version.clone(),
                                protocol: observation.session.protocol,
                                last_sync_ms: observation.session.last_sync_ms,
                                message: Some(error.to_string()),
                            });
                            let mut stale = observation.agents;
                            for agent in &mut stale {
                                agent.actions = AgentActions::default();
                            }
                            source_offset += stale.len();
                            agents.extend(stale);
                            continue;
                        }
                    }
                    connected += 1;
                    source_offset += observation.agents.len();
                    sessions.push(observation.session);
                    targets.extend(observation.targets);
                    agents.extend(observation.agents);
                }
                Err(error) => {
                    tracing::warn!(session = %descriptor.name, %error, "Herdr snapshot failed");
                    if let Some(subscription) = subscriptions.remove(&descriptor.name) {
                        subscription.handle.abort();
                    }
                    sessions.push(SessionView {
                        name: descriptor.name.clone(),
                        state: SessionState::Stale,
                        version: None,
                        protocol: None,
                        last_sync_ms: None,
                        message: Some(error.to_string()),
                    });
                    let mut stale: Vec<_> = previous_agents
                        .iter()
                        .filter(|agent| agent.session == descriptor.name)
                        .cloned()
                        .collect();
                    for agent in &mut stale {
                        agent.actions = AgentActions::default();
                        agent.source_order = source_offset;
                        source_offset += 1;
                    }
                    agents.extend(stale);
                }
            }
        }

        subscriptions.retain(|name, subscription| {
            let keep = active_names.contains(name);
            if !keep {
                subscription.handle.abort();
            }
            keep
        });
        sort_agents(&mut agents);

        let mut state = self.state.write().await;
        let now = Instant::now();
        for agent in &mut agents {
            let target = targets.get(&agent.id);
            let change_seq = target.map_or(0, |target| target.state_change_seq);
            let entry =
                state
                    .observed
                    .entry(agent.id.clone())
                    .or_insert((agent.status, change_seq, now));
            if entry.0 != agent.status || entry.1 != change_seq {
                *entry = (agent.status, change_seq, now);
            }
            agent.observed_for_seconds = now.duration_since(entry.2).as_secs();
        }
        state
            .observed
            .retain(|id, _| agents.iter().any(|agent| &agent.id == id));
        state.snapshot.sessions = sessions;
        state.snapshot.agents = agents;
        state.snapshot.connection = if descriptors.is_empty() {
            ConnectionState::Offline
        } else if connected == descriptors.len() {
            ConnectionState::Connected
        } else if connected > 0 {
            ConnectionState::Degraded
        } else {
            ConnectionState::Reconnecting
        };
        state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
        state.snapshot.generated_at_ms = now_ms;
        state.targets = targets;
        drop(state);
        self.publish().await;
    }

    async fn publish(&self) {
        let snapshot = self.state.read().await.snapshot.clone();
        match encode_snapshot(&snapshot) {
            Ok(encoded) => {
                self.updates.send_replace(encoded);
            }
            Err(error) => tracing::error!(%error, "failed to encode portal snapshot"),
        }
    }

    async fn handle_client(&self, stream: UnixStream) -> Result<()> {
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let mut updates = self.updates.subscribe();
        let initial = updates.borrow().clone();
        write.write_all(initial.as_bytes()).await?;
        write.write_all(b"\n").await?;

        loop {
            tokio::select! {
                changed = updates.changed() => {
                    changed.context("snapshot publisher closed")?;
                    let next = updates.borrow_and_update().clone();
                    write.write_all(next.as_bytes()).await?;
                    write.write_all(b"\n").await?;
                    write.flush().await?;
                }
                line = lines.next_line() => {
                    let Some(line) = line? else {
                        return Ok(());
                    };
                    let result = self.process_command(&line).await;
                    write.write_all(serde_json::to_string(&ServerMessage::ActionResult { result })?.as_bytes()).await?;
                    write.write_all(b"\n").await?;
                    write.flush().await?;
                }
            }
        }
    }

    async fn process_command(&self, line: &str) -> ActionResult {
        let parsed: Result<PortalCommand, _> = serde_json::from_str(line);
        let command = match parsed {
            Ok(command) => command,
            Err(error) => {
                return action_error(
                    "",
                    "invalid_command",
                    format!("invalid command JSON: {error}"),
                );
            }
        };
        if let Err(error) = validate_command(&command) {
            return action_error(&command.request_id, "invalid_command", error.to_string());
        }

        if command.action == ActionKind::RestoreFocus {
            return match self.desktop.lock().await.restore_focus().await {
                Ok(()) => action_ok(&command.request_id, "focus_restored"),
                Err(error) => {
                    action_error(&command.request_id, "target_unavailable", error.to_string())
                }
            };
        }

        let (snapshot_sequence, agent, target) = {
            let state = self.state.read().await;
            (
                state.snapshot.sequence,
                command
                    .agent_id
                    .as_ref()
                    .and_then(|id| state.snapshot.agents.iter().find(|agent| &agent.id == id))
                    .cloned(),
                command
                    .agent_id
                    .as_ref()
                    .and_then(|id| state.targets.get(id))
                    .cloned(),
            )
        };
        if command.sequence != snapshot_sequence {
            return action_error(
                &command.request_id,
                "stale_snapshot",
                "the portal snapshot changed before the action",
            );
        }
        let Some(agent) = agent else {
            return action_error(
                &command.request_id,
                "target_unavailable",
                "agent is no longer available",
            );
        };
        let Some(target) = target else {
            return action_error(
                &command.request_id,
                "session_disconnected",
                "agent session is disconnected",
            );
        };
        if !command_capability_matches(&command, &agent) {
            return action_error(
                &command.request_id,
                "capability_expired",
                "guarded action does not match the current agent capability",
            );
        }

        match self
            .herdr
            .perform(&target, command.action, command.capability_id.as_deref())
            .await
        {
            Ok(()) => {
                if matches!(command.action, ActionKind::Open | ActionKind::Zoom)
                    && let Err(error) = self
                        .desktop
                        .lock()
                        .await
                        .activate_herdr(&target.session, &target.socket_path)
                        .await
                {
                    return action_error(
                        &command.request_id,
                        "target_unavailable",
                        format!(
                            "agent focused in Herdr, but its window was not activated: {error}"
                        ),
                    );
                }
                let _ = self.invalidations.try_send(target.session);
                action_ok(&command.request_id, "action_completed")
            }
            Err(error) => {
                let message = error.to_string();
                let code = if message.contains("protocol") {
                    "unsupported_protocol"
                } else if message.contains("state") || message.contains("capability") {
                    "agent_state_changed"
                } else {
                    "command_error"
                };
                action_error(&command.request_id, code, message)
            }
        }
    }
}

async fn update_subscription(
    subscriptions: &mut HashMap<String, Subscription>,
    herdr: &HerdrClient,
    descriptor: &SessionDescriptor,
    mut pane_ids: Vec<String>,
    invalidations: mpsc::Sender<String>,
) -> Result<bool> {
    pane_ids.sort();
    pane_ids.dedup();
    if subscriptions
        .get(&descriptor.name)
        .is_some_and(|subscription| {
            subscription.pane_ids == pane_ids && !subscription.handle.is_finished()
        })
    {
        return Ok(false);
    }
    if let Some(previous) = subscriptions.remove(&descriptor.name) {
        previous.handle.abort();
    }
    let (handle, ready) =
        herdr.spawn_subscription(descriptor.clone(), pane_ids.clone(), invalidations);
    match tokio::time::timeout(Duration::from_secs(3), ready).await {
        Ok(Ok(Ok(()))) => {}
        Ok(Ok(Err(message))) => {
            handle.abort();
            bail!(message);
        }
        Ok(Err(_)) => {
            handle.abort();
            bail!("Herdr subscription exited before acknowledgement");
        }
        Err(_) => {
            handle.abort();
            bail!("timed out establishing Herdr subscription");
        }
    }
    subscriptions.insert(descriptor.name.clone(), Subscription { pane_ids, handle });
    Ok(true)
}

fn bind_socket(path: &Path) -> Result<UnixListener> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("socket path has no parent"))?;
    fs::create_dir_all(parent)
        .with_context(|| format!("creating runtime directory {}", parent.display()))?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;

    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {
            fs::remove_file(path).with_context(|| format!("removing stale {}", path.display()))?;
        }
        Ok(_) => bail!(
            "refusing to replace non-socket runtime path {}",
            path.display()
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }

    let listener = UnixListener::bind(path)
        .with_context(|| format!("binding daemon socket {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

pub fn socket_path(explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(path) = explicit {
        return Ok(path.to_path_buf());
    }
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("XDG_RUNTIME_DIR is not set"))?;
    Ok(runtime.join("xeneon-edge-agents/agentd.sock"))
}

fn encode_snapshot(snapshot: &PortalSnapshot) -> Result<String> {
    serde_json::to_string(&ServerMessage::Snapshot {
        snapshot: Box::new(snapshot.clone()),
    })
    .context("encoding portal snapshot")
}

fn action_ok(request_id: &str, message: impl Into<String>) -> ActionResult {
    ActionResult {
        schema_version: SCHEMA_VERSION,
        request_id: request_id.into(),
        ok: true,
        code: "ok".into(),
        message: message.into(),
    }
}

fn action_error(
    request_id: &str,
    code: impl Into<String>,
    message: impl Into<String>,
) -> ActionResult {
    ActionResult {
        schema_version: SCHEMA_VERSION,
        request_id: request_id.into(),
        ok: false,
        code: code.into(),
        message: message.into(),
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixListener as StdUnixListener;

    use super::*;

    #[test]
    fn socket_binding_refuses_regular_file() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("agentd.sock");
        fs::write(&path, "user data").unwrap();
        assert!(bind_socket(&path).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "user data");
    }

    #[tokio::test]
    async fn socket_binding_replaces_only_stale_socket() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("agentd.sock");
        drop(StdUnixListener::bind(&path).unwrap());
        let listener = bind_socket(&path).unwrap();
        drop(listener);
        let mode = fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn snapshot_envelope_has_one_type_tag() {
        let encoded = encode_snapshot(&PortalSnapshot::empty("epoch")).unwrap();
        let value: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(value["type"], "snapshot");
    }
}
