use std::{
    collections::{HashMap, HashSet},
    env, fs,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, RwLock, mpsc, watch},
    task::{JoinHandle, spawn_blocking},
    time::{MissedTickBehavior, interval, sleep},
};
use uuid::Uuid;

use crate::{
    Config,
    desktop::{DesktopApp, DesktopAppOutcome, DesktopController},
    health::HealthCollector,
    herdr::{HerdrClient, HerdrTarget, SessionDescriptor},
    micro::MicroCollector,
    model::{
        ActionKind, ActionResult, AgentActions, AgentBackend, AgentBackendSnapshot, AgentOrderMode,
        AgentOrderSnapshot, AgentStatus, ConnectionState, PortalCommand, PortalSnapshot,
        SCHEMA_VERSION, ServerMessage, SessionState, SessionView, VoiceState, sort_agents,
    },
    protocol::{command_capability_matches, validate_command},
    t3code::{self, T3codeClient, T3codeTarget},
    usage::UsageCollector,
    voice::{VoiceActionError, VoiceController},
};

const INVALIDATION_COALESCE: Duration = Duration::from_millis(200);
const BACKEND_STATE_FILE_NAME: &str = "xeneon-edge-agents/agent-backend.toml";
/// Invalidation key used when the portal switches agent managers.
const BACKEND_SWITCH_INVALIDATION: &str = "\0backend";

/// Private action-routing state for one portal card, owned by whichever agent
/// manager produced it.
#[derive(Debug, Clone)]
pub enum AgentTarget {
    Herdr(HerdrTarget),
    T3code(T3codeTarget),
}

impl AgentTarget {
    fn session(&self) -> &str {
        match self {
            Self::Herdr(target) => &target.session,
            Self::T3code(_) => t3code::SESSION_NAME,
        }
    }

    fn state_change_seq(&self) -> u64 {
        match self {
            Self::Herdr(target) => target.state_change_seq,
            Self::T3code(target) => target.state_change_seq,
        }
    }

    /// Whether the agent manager itself recorded a human acknowledgement of
    /// the current state. Herdr acknowledges through focus transitions only.
    fn acknowledged(&self) -> bool {
        match self {
            Self::Herdr(_) => false,
            Self::T3code(target) => target.acknowledged,
        }
    }
}

/// Portal-owned agent-manager selection persisted across daemon restarts.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
struct PersistedBackend {
    backend: AgentBackend,
    t3code_order: AgentOrderMode,
}

fn load_persisted_backend(path: &Path) -> Option<PersistedBackend> {
    let contents = fs::read_to_string(path).ok()?;
    match toml::from_str(&contents) {
        Ok(persisted) => Some(persisted),
        Err(error) => {
            tracing::warn!(path = %path.display(), %error, "ignoring invalid agent backend state");
            None
        }
    }
}

fn save_persisted_backend(path: &Path, persisted: &PersistedBackend) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("agent backend state path has no parent"))?;
    fs::create_dir_all(parent)
        .with_context(|| format!("creating state directory {}", parent.display()))?;
    let encoded = toml::to_string(persisted).context("encoding agent backend state")?;
    let temporary = parent.join(".agent-backend.toml.tmp");
    fs::write(&temporary, encoded).with_context(|| format!("writing {}", temporary.display()))?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(&temporary, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

pub fn default_backend_state_path() -> Option<PathBuf> {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .map(|state_home| state_home.join(BACKEND_STATE_FILE_NAME))
}

fn apply_agent_order(agents: &mut [crate::model::AgentView], order: &AgentOrderSnapshot) {
    if order.available && order.mode == AgentOrderMode::Grouped {
        agents.sort_by(|left, right| {
            left.source_order
                .cmp(&right.source_order)
                .then_with(|| left.id.cmp(&right.id))
        });
    } else {
        sort_agents(agents);
    }
}

#[derive(Debug)]
struct RuntimeState {
    snapshot: PortalSnapshot,
    backend: AgentBackend,
    t3code_order: AgentOrderMode,
    t3code_sequence: Option<u64>,
    targets: HashMap<String, AgentTarget>,
    observed: HashMap<String, ObservedAgent>,
    focused_agents: HashMap<String, Option<String>>,
    voice_error_latched: bool,
    voice_client_owner: Option<Uuid>,
}

#[derive(Debug, Clone)]
struct ObservedAgent {
    status: AgentStatus,
    state_change_seq: u64,
    since: Instant,
    review_ready: bool,
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
    t3code: T3codeClient,
    backend_state_path: Option<PathBuf>,
    state: Arc<RwLock<RuntimeState>>,
    desktop: Arc<DesktopController>,
    voice: Arc<Mutex<VoiceController>>,
    order_operation: Arc<Mutex<()>>,
    updates: watch::Sender<String>,
    invalidations: mpsc::Sender<String>,
}

impl DaemonRuntime {
    /// Builds a runtime that starts on the configured agent manager and does
    /// not persist portal backend switches.
    pub fn new(config: Config) -> Result<(Self, mpsc::Receiver<String>)> {
        Self::new_with_state_path(config, None)
    }

    /// Builds a runtime whose portal-selected agent manager is restored from
    /// and persisted to `backend_state_path` when it is provided.
    pub fn new_with_state_path(
        config: Config,
        backend_state_path: Option<PathBuf>,
    ) -> Result<(Self, mpsc::Receiver<String>)> {
        config.validate()?;
        let epoch = Uuid::new_v4().to_string();
        let mut snapshot = PortalSnapshot::empty(epoch);
        let persisted = backend_state_path
            .as_deref()
            .and_then(load_persisted_backend)
            .unwrap_or(PersistedBackend {
                backend: config.agent_backend,
                t3code_order: AgentOrderMode::default(),
            });
        snapshot.backend = AgentBackendSnapshot {
            mode: persisted.backend,
            switchable: true,
        };
        let encoded = encode_snapshot(&snapshot)?;
        let (updates, _) = watch::channel(encoded);
        let (invalidations, invalidation_rx) = mpsc::channel(64);
        let desktop = DesktopController::new(config.desktop.clone());
        let voice = VoiceController::from_config(&config, snapshot.daemon_epoch.clone())?;
        let t3code = T3codeClient::from_config(config.t3code.home.as_deref())?;
        Ok((
            Self {
                herdr: HerdrClient::new(config.herdr_bin.clone()),
                t3code,
                backend_state_path,
                config,
                state: Arc::new(RwLock::new(RuntimeState {
                    snapshot,
                    backend: persisted.backend,
                    t3code_order: persisted.t3code_order,
                    t3code_sequence: None,
                    targets: HashMap::new(),
                    observed: HashMap::new(),
                    focused_agents: HashMap::new(),
                    voice_error_latched: false,
                    voice_client_owner: None,
                })),
                desktop: Arc::new(desktop),
                voice: Arc::new(Mutex::new(voice)),
                order_operation: Arc::new(Mutex::new(())),
                updates,
                invalidations,
            },
            invalidation_rx,
        ))
    }

    pub async fn run(self, path: &Path, invalidation_rx: mpsc::Receiver<String>) -> Result<()> {
        let listener = bind_socket(path)?;
        tracing::info!(socket = %path.display(), "xeneon agent daemon listening");

        let auxiliary_runtime = self.clone();
        let mut auxiliary_collector = tokio::spawn(async move {
            auxiliary_runtime.collect_auxiliary_loop().await;
        });
        let usage_runtime = self.clone();
        let mut usage_collector = tokio::spawn(async move {
            usage_runtime.collect_usage_loop().await;
        });
        let agent_runtime = self.clone();
        let mut agent_collector = tokio::spawn(async move {
            agent_runtime.collect_agent_loop(invalidation_rx).await;
        });

        loop {
            tokio::select! {
                result = &mut auxiliary_collector => {
                    result.context("joining auxiliary state collector")?;
                    bail!("auxiliary state collector stopped unexpectedly");
                }
                result = &mut agent_collector => {
                    result.context("joining agent state collector")?;
                    bail!("agent state collector stopped unexpectedly");
                }
                result = &mut usage_collector => {
                    result.context("joining usage state collector")?;
                    bail!("usage state collector stopped unexpectedly");
                }
                accepted = listener.accept() => {
                    let (stream, _) = accepted.context("accepting portal client")?;
                    let client_runtime = self.clone();
                    tokio::spawn(async move {
                        if let Err(error) = client_runtime.handle_client(stream).await {
                            tracing::warn!(%error, "portal client disconnected");
                        }
                    });
                }
            }
        }
    }

    async fn collect_auxiliary_loop(&self) {
        let mut health = HealthCollector::default();
        let micro = MicroCollector::default();
        let mut health_tick = interval(self.config.health_refresh_interval());
        let mut voice_tick = interval(self.config.voice_refresh_interval());
        let mut micro_tick = interval(self.config.micro_refresh_interval());
        health_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
        voice_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
        micro_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

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
                    self.desktop.remember_non_edge_focus().await;
                }
                _ = voice_tick.tick() => {
                    self.refresh_voice().await;
                }
                _ = micro_tick.tick() => {
                    let sample = micro.sample().await;
                    let mut state = self.state.write().await;
                    if state.snapshot.micro != sample {
                        state.snapshot.micro = sample;
                        state.snapshot.generated_at_ms = now_ms();
                        drop(state);
                        self.publish().await;
                    }
                }
            }
        }
    }

    async fn collect_usage_loop(&self) {
        let usage = UsageCollector::default();
        let mut usage_tick = interval(self.config.usage_refresh_interval());
        usage_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

        loop {
            usage_tick.tick().await;
            let collector = usage.clone();
            let sample = match spawn_blocking(move || collector.sample()).await {
                Ok(sample) => sample,
                Err(error) => {
                    tracing::warn!(%error, "usage collector task failed");
                    continue;
                }
            };
            let mut state = self.state.write().await;
            if state.snapshot.usage != sample {
                state.snapshot.usage = sample;
                state.snapshot.generated_at_ms = now_ms();
                drop(state);
                self.publish().await;
            }
        }
    }

    async fn collect_agent_loop(&self, mut invalidation_rx: mpsc::Receiver<String>) {
        let mut repair_tick = interval(self.config.herdr_refresh_interval());
        let mut t3code_tick = interval(self.config.t3code_refresh_interval());
        repair_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
        t3code_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let mut subscriptions: HashMap<String, Subscription> = HashMap::new();

        loop {
            tokio::select! {
                _ = repair_tick.tick() => {
                    self.refresh_agents(&mut subscriptions).await;
                }
                _ = t3code_tick.tick() => {
                    // T3 Code has no public event socket; its projection
                    // sequence is a cheap change signal between repairs.
                    if self.state.read().await.backend == AgentBackend::T3code
                        && self.t3code_sequence_changed().await
                    {
                        self.refresh_agents(&mut subscriptions).await;
                    }
                }
                invalidation = invalidation_rx.recv() => {
                    if invalidation.is_none() {
                        tracing::error!("agent invalidation channel closed");
                        return;
                    }
                    // A single terminal operation can emit several related
                    // workspace, tab, pane, and agent events. Reconcile one
                    // complete snapshot for the burst instead of invoking the
                    // full Herdr API once per event.
                    sleep(INVALIDATION_COALESCE).await;
                    while invalidation_rx.try_recv().is_ok() {}
                    self.refresh_agents(&mut subscriptions).await;
                }
            }
        }
    }

    async fn refresh_agents(&self, subscriptions: &mut HashMap<String, Subscription>) {
        // Copy the mode out before dispatching: a `match` scrutinee guard would
        // stay alive across the refresh and deadlock its own write lock.
        let backend = self.state.read().await.backend;
        match backend {
            AgentBackend::Herdr => self.refresh_herdr(subscriptions).await,
            AgentBackend::T3code => {
                for (_, subscription) in subscriptions.drain() {
                    subscription.handle.abort();
                }
                self.refresh_t3code().await;
            }
        }
    }

    async fn t3code_sequence_changed(&self) -> bool {
        let client = self.t3code.clone();
        let current = match spawn_blocking(move || client.projection_sequence()).await {
            Ok(Ok(sequence)) => sequence,
            Ok(Err(error)) => {
                tracing::debug!(%error, "T3 Code projection sequence unavailable");
                None
            }
            Err(error) => {
                tracing::warn!(%error, "T3 Code sequence poll task failed");
                return false;
            }
        };
        self.state.read().await.t3code_sequence != current
    }

    async fn refresh_t3code(&self) {
        let _order_guard = self.order_operation.lock().await;
        let observation_time_ms = now_ms();
        let epoch = self.state.read().await.snapshot.daemon_epoch.clone();
        let client = self.t3code.clone();
        let observation =
            match spawn_blocking(move || client.observe(&epoch, observation_time_ms)).await {
                Ok(observation) => observation,
                Err(error) => {
                    tracing::warn!(%error, "T3 Code observation task failed");
                    return;
                }
            };

        let mut state = self.state.write().await;
        if state.backend != AgentBackend::T3code {
            return;
        }
        let session_state = observation.session.state;
        let mut agents = observation.agents;
        let mut targets: HashMap<String, AgentTarget> = observation
            .targets
            .into_iter()
            .map(|(id, target)| (id, AgentTarget::T3code(target)))
            .collect();
        if session_state == SessionState::Stale {
            // Keep the last roster visible without action targets while the
            // state file is transiently unreadable, mirroring a stale Herdr
            // session.
            agents = state.snapshot.agents.clone();
            for agent in &mut agents {
                agent.actions = AgentActions::default();
            }
            targets.clear();
        }
        let now = Instant::now();
        let RuntimeState {
            observed,
            focused_agents,
            ..
        } = &mut *state;
        apply_agent_observations(&mut agents, &targets, observed, focused_agents, now);
        let agent_order = AgentOrderSnapshot {
            available: session_state == SessionState::Connected,
            mode: state.t3code_order,
        };
        apply_agent_order(&mut agents, &agent_order);
        state.snapshot.connection = match session_state {
            SessionState::Connected => ConnectionState::Connected,
            SessionState::Offline => ConnectionState::Offline,
            SessionState::Stale | SessionState::Incompatible => ConnectionState::Reconnecting,
        };
        state.snapshot.sessions = vec![observation.session];
        state.snapshot.agents = agents;
        state.snapshot.agent_order = agent_order;
        state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
        state.snapshot.generated_at_ms = now_ms();
        state.targets = targets;
        state.t3code_sequence = observation.projection_sequence;
        drop(state);
        self.publish().await;
    }

    async fn refresh_voice(&self) {
        let mut voice = self.voice.lock().await.snapshot().await;
        let mut state = self.state.write().await;
        if state.voice_error_latched {
            voice.state = VoiceState::Error;
        }
        if state.snapshot.voice == voice {
            return;
        }
        state.snapshot.voice = voice;
        state.snapshot.generated_at_ms = now_ms();
        drop(state);
        self.publish().await;
    }

    async fn refresh_herdr(&self, subscriptions: &mut HashMap<String, Subscription>) {
        // Keep a collected ordering snapshot from publishing after a completed
        // ordering mutation, and serialize collection with compensating writes.
        let _order_guard = self.order_operation.lock().await;
        // A switch may have completed between the dispatch decision and this
        // guard; Herdr state must never be committed over another manager.
        if self.state.read().await.backend != AgentBackend::Herdr {
            return;
        }
        let observation_time_ms = now_ms();
        let descriptors = match self.herdr.discover().await {
            Ok(descriptors) => descriptors,
            Err(error) => {
                tracing::warn!(%error, "Herdr discovery failed");
                let mut state = self.state.write().await;
                if state.backend != AgentBackend::Herdr {
                    return;
                }
                state.snapshot.connection = ConnectionState::Offline;
                for session in &mut state.snapshot.sessions {
                    session.state = SessionState::Stale;
                    session.message = Some("Herdr discovery is unavailable".into());
                }
                for agent in &mut state.snapshot.agents {
                    agent.actions = AgentActions::default();
                }
                state.snapshot.agent_order = AgentOrderSnapshot::default();
                sort_agents(&mut state.snapshot.agents);
                state.targets.clear();
                state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
                state.snapshot.generated_at_ms = now_ms();
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
        let mut order_modes = Vec::new();
        let mut source_offset = 0usize;
        let mut active_names = Vec::new();

        for descriptor in &descriptors {
            active_names.push(descriptor.name.clone());
            match self
                .herdr
                .observe_session(descriptor, &epoch, source_offset, observation_time_ms)
                .await
            {
                Ok(mut observation) => {
                    if observation.session.state == SessionState::Incompatible {
                        if let Some(subscription) = subscriptions.remove(&descriptor.name) {
                            subscription.handle.abort();
                        }
                        sessions.push(observation.session);
                        continue;
                    }
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
                                .observe_session(
                                    descriptor,
                                    &epoch,
                                    source_offset,
                                    observation_time_ms,
                                )
                                .await
                            {
                                Ok(reconciled) => {
                                    if reconciled.session.state == SessionState::Incompatible {
                                        if let Some(subscription) =
                                            subscriptions.remove(&descriptor.name)
                                        {
                                            subscription.handle.abort();
                                        }
                                        sessions.push(reconciled.session);
                                        continue;
                                    }
                                    observation = reconciled;
                                }
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
                                        message: Some(
                                            "Herdr post-subscription reconciliation failed".into(),
                                        ),
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
                                message: Some("Herdr event subscription is unavailable".into()),
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
                    if let Some(mode) = observation.agent_order {
                        order_modes.push(mode);
                    }
                    source_offset += observation.agents.len();
                    sessions.push(observation.session);
                    targets.extend(
                        observation
                            .targets
                            .into_iter()
                            .map(|(id, target)| (id, AgentTarget::Herdr(target))),
                    );
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
                        message: Some("Herdr session snapshot is unavailable".into()),
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
        let mut state = self.state.write().await;
        if state.backend != AgentBackend::Herdr {
            return;
        }
        let now = Instant::now();
        let RuntimeState {
            observed,
            focused_agents,
            ..
        } = &mut *state;
        apply_agent_observations(&mut agents, &targets, observed, focused_agents, now);
        let agent_order = if !descriptors.is_empty()
            && connected == descriptors.len()
            && order_modes.len() == connected
            && order_modes.iter().all(|mode| *mode == order_modes[0])
        {
            AgentOrderSnapshot {
                available: true,
                mode: order_modes[0],
            }
        } else {
            AgentOrderSnapshot::default()
        };
        apply_agent_order(&mut agents, &agent_order);
        state.snapshot.sessions = sessions;
        state.snapshot.agents = agents;
        state.snapshot.agent_order = agent_order;
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
        state.snapshot.generated_at_ms = now_ms();
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
        let client_id = Uuid::new_v4();
        let result = self.handle_client_inner(stream, client_id).await;
        self.cancel_voice_for_disconnected_client(client_id).await;
        result
    }

    async fn handle_client_inner(&self, stream: UnixStream, client_id: Uuid) -> Result<()> {
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
                    let result = self.process_command(&line, client_id).await;
                    write.write_all(serde_json::to_string(&ServerMessage::ActionResult { result })?.as_bytes()).await?;
                    write.write_all(b"\n").await?;
                    write.flush().await?;
                }
            }
        }
    }

    async fn process_command(&self, line: &str, client_id: Uuid) -> ActionResult {
        let parsed: Result<PortalCommand, _> = serde_json::from_str(line);
        let command = match parsed {
            Ok(command) => command,
            Err(error) => {
                tracing::debug!(%error, "invalid portal command JSON");
                return action_error("", "invalid_command", "command is not valid JSON");
            }
        };
        if let Err(error) = validate_command(&command) {
            return action_error(&command.request_id, "invalid_command", error.to_string());
        }

        if command.action == ActionKind::RestoreFocus {
            return match self.desktop.restore_focus().await {
                Ok(()) => action_ok(&command.request_id, "focus_restored"),
                Err(error) => {
                    tracing::warn!(%error, "focus restoration failed");
                    action_error(
                        &command.request_id,
                        "target_unavailable",
                        "focus restoration failed",
                    )
                }
            };
        }

        if matches!(
            command.action,
            ActionKind::ChatgptDesktop | ActionKind::ClaudeDesktop
        ) {
            let app = match command.action {
                ActionKind::ChatgptDesktop => DesktopApp::ChatGpt,
                ActionKind::ClaudeDesktop => DesktopApp::Claude,
                _ => unreachable!("desktop command filtered before dispatch"),
            };
            return match self.desktop.focus_or_launch(app).await {
                Ok(DesktopAppOutcome::Focused) => {
                    action_ok(&command.request_id, "desktop_app_focused")
                }
                Ok(DesktopAppOutcome::LaunchedAndFocused) => {
                    action_ok(&command.request_id, "desktop_app_launched")
                }
                Err(error) => {
                    tracing::warn!(%error, action = ?command.action, "desktop app action failed");
                    action_error(
                        &command.request_id,
                        "target_unavailable",
                        "desktop app could not be focused or launched",
                    )
                }
            };
        }

        if matches!(
            command.action,
            ActionKind::VoiceStart | ActionKind::VoiceStop | ActionKind::VoiceCancel
        ) {
            return self.process_voice_command(&command, client_id).await;
        }

        if matches!(
            command.action,
            ActionKind::OrderGrouped | ActionKind::OrderPriority
        ) {
            return self.process_agent_order_command(&command).await;
        }

        if matches!(
            command.action,
            ActionKind::BackendHerdr | ActionKind::BackendT3code
        ) {
            return self.process_backend_command(&command).await;
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
        let enabled = match command.action {
            ActionKind::Open => agent.actions.open,
            ActionKind::Zoom => agent.actions.zoom,
            ActionKind::Approve
            | ActionKind::Interrupt
            | ActionKind::RestoreFocus
            | ActionKind::ChatgptDesktop
            | ActionKind::ClaudeDesktop
            | ActionKind::VoiceStart
            | ActionKind::VoiceStop
            | ActionKind::VoiceCancel
            | ActionKind::OrderGrouped
            | ActionKind::OrderPriority
            | ActionKind::BackendHerdr
            | ActionKind::BackendT3code => true,
        };
        if !enabled {
            return action_error(
                &command.request_id,
                "target_unavailable",
                "action is not available for the current agent",
            );
        }
        if !command_capability_matches(&command, &agent) {
            return action_error(
                &command.request_id,
                "capability_expired",
                "guarded action does not match the current agent capability",
            );
        }

        let herdr_target = match target {
            AgentTarget::Herdr(target) => target,
            AgentTarget::T3code(_) => {
                // T3 Code exposes no public thread-focus API on Linux; the
                // only agent action is activating its exact desktop window.
                if command.action != ActionKind::Open {
                    return action_error(
                        &command.request_id,
                        "target_unavailable",
                        "action is not available for T3 Code threads",
                    );
                }
                return match self.desktop.focus_existing(DesktopApp::T3code).await {
                    Ok(()) => {
                        self.acknowledge_review_ready(&agent.id).await;
                        let _ = self.invalidations.try_send(t3code::SESSION_NAME.to_owned());
                        action_ok(&command.request_id, "action_completed")
                    }
                    Err(error) => {
                        tracing::warn!(%error, "T3 Code window activation failed");
                        action_error(
                            &command.request_id,
                            "target_unavailable",
                            "T3 Code window is not available",
                        )
                    }
                };
            }
        };
        match self
            .herdr
            .perform(
                &herdr_target,
                command.action,
                command.capability_id.as_deref(),
            )
            .await
        {
            Ok(()) => {
                if command.action == ActionKind::Open {
                    self.acknowledge_review_ready(&agent.id).await;
                }
                // Herdr already committed the focus/zoom operation. Refresh
                // authoritative state even if compositor activation then
                // fails, so the portal never retains a stale review badge.
                let _ = self.invalidations.try_send(herdr_target.session.clone());
                if matches!(command.action, ActionKind::Open | ActionKind::Zoom)
                    && let Err(error) = self
                        .desktop
                        .activate_herdr(&herdr_target.session, &herdr_target.socket_path)
                        .await
                {
                    tracing::warn!(%error, "Herdr window activation failed after agent focus");
                    return action_error(
                        &command.request_id,
                        "target_unavailable",
                        "agent focused, but its Herdr window was not activated",
                    );
                }
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
                tracing::warn!(%error, action = ?command.action, "Herdr action failed");
                let public_message = match code {
                    "unsupported_protocol" => "Herdr protocol is unsupported",
                    "agent_state_changed" => "agent state changed before the action",
                    _ => "agent action failed",
                };
                action_error(&command.request_id, code, public_message)
            }
        }
    }

    async fn process_agent_order_command(&self, command: &PortalCommand) -> ActionResult {
        let _order_guard = self.order_operation.lock().await;
        let authoritative = self.state.read().await.snapshot.agent_order.clone();
        let sequence = self.state.read().await.snapshot.sequence;
        if command.sequence != sequence || !authoritative.available {
            return action_error(
                &command.request_id,
                "stale_snapshot",
                "the authoritative agent ordering changed before the action",
            );
        }
        let mode = match command.action {
            ActionKind::OrderGrouped => AgentOrderMode::Grouped,
            ActionKind::OrderPriority => AgentOrderMode::Priority,
            _ => unreachable!("ordering command filtered before dispatch"),
        };
        if self.state.read().await.backend == AgentBackend::T3code {
            // T3 Code has no ordering preference of its own, so the daemon
            // owns this typed setting for T3 Code rosters.
            let mut state = self.state.write().await;
            state.t3code_order = mode;
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode,
            };
            let ordering = state.snapshot.agent_order.clone();
            apply_agent_order(&mut state.snapshot.agents, &ordering);
            state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
            state.snapshot.generated_at_ms = now_ms();
            let persisted = PersistedBackend {
                backend: state.backend,
                t3code_order: state.t3code_order,
            };
            drop(state);
            self.persist_backend(persisted).await;
            self.publish().await;
            return action_ok(&command.request_id, "agent_order_updated");
        }
        let descriptors = match self.herdr.discover().await {
            Ok(descriptors) if !descriptors.is_empty() => descriptors,
            Ok(_) => {
                return action_error(
                    &command.request_id,
                    "session_disconnected",
                    "no running Herdr session can change agent ordering",
                );
            }
            Err(error) => {
                tracing::warn!(%error, "Herdr discovery failed for agent ordering");
                return action_error(
                    &command.request_id,
                    "session_disconnected",
                    "Herdr agent ordering is unavailable",
                );
            }
        };

        let mut prior_modes = Vec::with_capacity(descriptors.len());
        for descriptor in &descriptors {
            match self.herdr.get_agent_order(descriptor).await {
                Ok(prior) => prior_modes.push((descriptor.clone(), prior)),
                Err(error) => {
                    tracing::warn!(session = %descriptor.name, %error, "Herdr agent ordering preflight failed");
                    let _ = self.invalidations.try_send(descriptor.name.clone());
                    return action_error(
                        &command.request_id,
                        "target_unavailable",
                        "Herdr could not verify agent ordering",
                    );
                }
            }
        }
        if prior_modes
            .iter()
            .any(|(_, prior)| *prior != authoritative.mode)
        {
            for (descriptor, _) in &prior_modes {
                let _ = self.invalidations.try_send(descriptor.name.clone());
            }
            return action_error(
                &command.request_id,
                "stale_snapshot",
                "Herdr ordering changed before the action",
            );
        }

        let mut attempted = Vec::new();
        for (descriptor, prior) in &prior_modes {
            if *prior == mode {
                continue;
            }
            // A failed response is ambiguous: Herdr may have persisted the
            // idempotent SET before the socket closed. Compensate every
            // attempted descriptor, including the one returning the error.
            attempted.push((descriptor.clone(), *prior));
            if let Err(error) = self.herdr.set_agent_order(descriptor, mode).await {
                tracing::warn!(session = %descriptor.name, %error, "Herdr agent ordering failed");
                let mut compensated = true;
                for (changed_descriptor, changed_prior) in attempted.iter().rev() {
                    if let Err(compensation_error) = self
                        .herdr
                        .set_agent_order(changed_descriptor, *changed_prior)
                        .await
                    {
                        compensated = false;
                        tracing::error!(
                            session = %changed_descriptor.name,
                            %compensation_error,
                            "Herdr agent ordering compensation failed"
                        );
                    }
                }
                for (checked_descriptor, checked_prior) in &prior_modes {
                    match self.herdr.get_agent_order(checked_descriptor).await {
                        Ok(actual) if actual == *checked_prior => {}
                        Ok(actual) => {
                            compensated = false;
                            tracing::error!(
                                session = %checked_descriptor.name,
                                ?actual,
                                expected = ?checked_prior,
                                "Herdr ordering differs after compensation"
                            );
                        }
                        Err(check_error) => {
                            compensated = false;
                            tracing::error!(
                                session = %checked_descriptor.name,
                                %check_error,
                                "Herdr ordering compensation could not be verified"
                            );
                        }
                    }
                    let _ = self.invalidations.try_send(checked_descriptor.name.clone());
                }
                if !compensated {
                    let mut state = self.state.write().await;
                    state.snapshot.agent_order = AgentOrderSnapshot::default();
                    state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
                    state.snapshot.generated_at_ms = now_ms();
                    drop(state);
                    self.publish().await;
                }
                return action_error(
                    &command.request_id,
                    "target_unavailable",
                    "Herdr could not synchronize agent ordering",
                );
            }
        }

        let mut state = self.state.write().await;
        state.snapshot.agent_order = AgentOrderSnapshot {
            available: true,
            mode,
        };
        let ordering = state.snapshot.agent_order.clone();
        apply_agent_order(&mut state.snapshot.agents, &ordering);
        state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
        state.snapshot.generated_at_ms = now_ms();
        drop(state);
        self.publish().await;
        for descriptor in &descriptors {
            let _ = self.invalidations.try_send(descriptor.name.clone());
        }
        action_ok(&command.request_id, "agent_order_updated")
    }

    async fn process_backend_command(&self, command: &PortalCommand) -> ActionResult {
        let _order_guard = self.order_operation.lock().await;
        let mode = match command.action {
            ActionKind::BackendHerdr => AgentBackend::Herdr,
            ActionKind::BackendT3code => AgentBackend::T3code,
            _ => unreachable!("backend command filtered before dispatch"),
        };
        let mut state = self.state.write().await;
        if command.sequence != state.snapshot.sequence {
            return action_error(
                &command.request_id,
                "stale_snapshot",
                "the portal snapshot changed before the action",
            );
        }
        if state.backend == mode {
            return action_ok(&command.request_id, "agent_backend_unchanged");
        }
        // The previous manager's cards, private targets, latches, and focus
        // history must never survive into the next manager's roster.
        state.backend = mode;
        state.targets.clear();
        state.observed.clear();
        state.focused_agents.clear();
        state.t3code_sequence = None;
        state.snapshot.sessions.clear();
        state.snapshot.agents.clear();
        state.snapshot.agent_order = AgentOrderSnapshot::default();
        state.snapshot.connection = ConnectionState::Reconnecting;
        state.snapshot.backend = AgentBackendSnapshot {
            mode,
            switchable: true,
        };
        state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
        state.snapshot.generated_at_ms = now_ms();
        let persisted = PersistedBackend {
            backend: state.backend,
            t3code_order: state.t3code_order,
        };
        drop(state);
        self.persist_backend(persisted).await;
        self.publish().await;
        let _ = self
            .invalidations
            .try_send(BACKEND_SWITCH_INVALIDATION.to_owned());
        action_ok(&command.request_id, "agent_backend_updated")
    }

    async fn persist_backend(&self, persisted: PersistedBackend) {
        let Some(path) = self.backend_state_path.clone() else {
            return;
        };
        let result = spawn_blocking({
            let path = path.clone();
            move || save_persisted_backend(&path, &persisted)
        })
        .await;
        match result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::warn!(path = %path.display(), %error, "agent backend state was not persisted");
            }
            Err(error) => {
                tracing::warn!(path = %path.display(), %error, "agent backend persistence task failed");
            }
        }
    }

    async fn process_voice_command(
        &self,
        command: &PortalCommand,
        client_id: Uuid,
    ) -> ActionResult {
        let voice_controller = self.voice.lock().await;
        let result = voice_controller.perform(command.action).await;
        match result {
            Ok(voice) => {
                let mut state = self.state.write().await;
                state.snapshot.voice = voice;
                state.voice_error_latched = false;
                state.voice_client_owner = if command.action == ActionKind::VoiceStart {
                    Some(client_id)
                } else {
                    None
                };
                state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
                state.snapshot.generated_at_ms = now_ms();
                drop(state);
                drop(voice_controller);
                self.publish().await;
                let message = match command.action {
                    ActionKind::VoiceStart => "voice_recording_started",
                    ActionKind::VoiceStop => "voice_recording_stopped",
                    ActionKind::VoiceCancel => "voice_recording_cancelled",
                    _ => unreachable!("voice command filtered before dispatch"),
                };
                action_ok(&command.request_id, message)
            }
            Err(error) => {
                let mut voice = voice_controller.snapshot().await;
                voice.state = VoiceState::Error;
                let mut state = self.state.write().await;
                state.snapshot.voice = voice;
                state.voice_error_latched = true;
                state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
                state.snapshot.generated_at_ms = now_ms();
                drop(state);
                drop(voice_controller);
                self.publish().await;
                voice_action_error(&command.request_id, error)
            }
        }
    }

    async fn cancel_voice_for_disconnected_client(&self, client_id: Uuid) {
        let voice_controller = self.voice.lock().await;
        if self.state.read().await.voice_client_owner != Some(client_id) {
            return;
        }

        let result = voice_controller.perform(ActionKind::VoiceCancel).await;
        let mut state = self.state.write().await;
        state.voice_client_owner = None;
        match result {
            Ok(voice) => {
                state.snapshot.voice = voice;
                state.voice_error_latched = false;
            }
            Err(error) => {
                let mut voice = voice_controller.snapshot().await;
                voice.state = VoiceState::Error;
                state.snapshot.voice = voice;
                state.voice_error_latched = true;
                tracing::warn!(
                    %error,
                    "failed to cancel voice recording after portal disconnect"
                );
            }
        }
        state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
        state.snapshot.generated_at_ms = now_ms();
        drop(state);
        drop(voice_controller);
        self.publish().await;
    }

    async fn acknowledge_review_ready(&self, agent_id: &str) {
        let mut state = self.state.write().await;
        let Some(agent) = state
            .snapshot
            .agents
            .iter_mut()
            .find(|agent| agent.id == agent_id)
        else {
            return;
        };
        if !agent.review_ready {
            return;
        }
        agent.review_ready = false;
        if let Some(observed) = state.observed.get_mut(agent_id) {
            observed.review_ready = false;
        }
        state.snapshot.sequence = state.snapshot.sequence.saturating_add(1);
        state.snapshot.generated_at_ms = now_ms();
        drop(state);
        self.publish().await;
    }
}

fn apply_agent_observations(
    agents: &mut [crate::model::AgentView],
    targets: &HashMap<String, AgentTarget>,
    observed: &mut HashMap<String, ObservedAgent>,
    focused_agents: &mut HashMap<String, Option<String>>,
    now: Instant,
) {
    let connected_sessions: HashSet<String> = targets
        .values()
        .map(|target| target.session().to_owned())
        .collect();
    let mut current_focus: HashMap<String, Option<String>> = connected_sessions
        .iter()
        .map(|session| (session.clone(), None))
        .collect();
    for agent in agents.iter() {
        let Some(target) = targets.get(&agent.id) else {
            continue;
        };
        if agent.focused {
            current_focus.insert(target.session().to_owned(), Some(agent.id.clone()));
        }
    }

    let mut focus_acknowledgements = HashSet::new();
    for (session, current) in &current_focus {
        if let Some(previous) = focused_agents.get(session)
            && previous != current
            && let Some(agent_id) = current
        {
            focus_acknowledgements.insert(agent_id.clone());
        }
        focused_agents.insert(session.clone(), current.clone());
    }
    focused_agents.retain(|session, _| connected_sessions.contains(session));

    for agent in agents.iter_mut() {
        let Some(target) = targets.get(&agent.id) else {
            if let Some(previous) = observed.get(&agent.id) {
                agent.review_ready = previous.review_ready;
                agent.observed_for_seconds = now.duration_since(previous.since).as_secs();
            }
            continue;
        };
        let previous = observed.get(&agent.id);
        let state_change_seq = target.state_change_seq();
        let state_unchanged = previous.is_some_and(|value| {
            value.status == agent.status && value.state_change_seq == state_change_seq
        });
        let mut review_ready = if state_unchanged {
            previous.is_some_and(|value| value.review_ready)
        } else {
            next_review_ready(
                previous.map(|value| value.status),
                previous.is_some_and(|value| value.review_ready),
                agent.status,
            )
        };
        if focus_acknowledgements.contains(&agent.id) || target.acknowledged() {
            review_ready = false;
        }
        let since = previous
            .filter(|value| {
                value.status == agent.status && value.state_change_seq == state_change_seq
            })
            .map_or(now, |value| value.since);
        agent.review_ready = review_ready;
        agent.observed_for_seconds = now.duration_since(since).as_secs();
        observed.insert(
            agent.id.clone(),
            ObservedAgent {
                status: agent.status,
                state_change_seq,
                since,
                review_ready,
            },
        );
    }
    observed.retain(|id, _| agents.iter().any(|agent| &agent.id == id));
}

fn next_review_ready(
    previous_status: Option<AgentStatus>,
    previous_review_ready: bool,
    current_status: AgentStatus,
) -> bool {
    match current_status {
        AgentStatus::Done => true,
        AgentStatus::Idle => previous_review_ready || previous_status == Some(AgentStatus::Working),
        AgentStatus::Blocked | AgentStatus::Working | AgentStatus::Unknown => false,
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

fn voice_action_error(request_id: &str, error: VoiceActionError) -> ActionResult {
    let (code, message) = match error {
        VoiceActionError::Unavailable => ("voice_unavailable", "voice input is unavailable"),
        VoiceActionError::NotIdle => ("voice_busy", "voice input is not idle"),
        VoiceActionError::NotOwned => (
            "voice_not_owned",
            "voice recording is not owned by the portal",
        ),
        VoiceActionError::CommandFailed => ("command_error", "voice action failed"),
        VoiceActionError::Ownership => ("command_error", "voice ownership could not be updated"),
    };
    action_error(request_id, code, message)
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
    use std::os::unix::{fs::PermissionsExt, net::UnixListener as StdUnixListener};

    use super::*;
    use crate::model::AgentView;
    use crate::voice::VoiceController;

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
        assert_eq!(value["voice"]["state"], "unavailable");
        assert_eq!(value["agent_order"]["available"], false);
    }

    #[test]
    fn agent_order_uses_source_order_for_grouped_and_attention_for_priority() {
        let mut agents = vec![
            AgentView {
                source_order: 0,
                ..test_agent("workspace-first", AgentStatus::Idle, false)
            },
            AgentView {
                source_order: 1,
                ..test_agent("attention-first", AgentStatus::Blocked, false)
            },
        ];
        apply_agent_order(
            &mut agents,
            &AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            },
        );
        assert_eq!(agents[0].id, "workspace-first");
        apply_agent_order(
            &mut agents,
            &AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Priority,
            },
        );
        assert_eq!(agents[0].id, "attention-first");
    }

    #[tokio::test]
    async fn discovery_failure_clears_stale_ordering_and_restores_fallback_sort() {
        let temp = tempfile::tempdir().unwrap();
        let binary = temp.path().join("herdr");
        fs::write(&binary, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let (runtime, _) = DaemonRuntime::new(Config {
            herdr_bin: binary,
            ..Config::default()
        })
        .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            };
            state.snapshot.agents = vec![
                AgentView {
                    source_order: 0,
                    ..test_agent("workspace-first", AgentStatus::Idle, false)
                },
                AgentView {
                    source_order: 1,
                    ..test_agent("attention-first", AgentStatus::Blocked, false)
                },
            ];
        }

        runtime.refresh_herdr(&mut HashMap::new()).await;

        let state = runtime.state.read().await;
        assert_eq!(state.snapshot.connection, ConnectionState::Offline);
        assert!(!state.snapshot.agent_order.available);
        assert_eq!(state.snapshot.agents[0].id, "attention-first");
    }

    #[tokio::test]
    async fn order_command_updates_herdr_and_the_published_card_order_once() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("herdr.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let request: serde_json::Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], "agent.order.get");
            write
                .write_all(b"{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n")
                .await
                .unwrap();

            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let request: serde_json::Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], "agent.order.set");
            assert_eq!(request["params"], serde_json::json!({"order": "priority"}));
            write
                .write_all(b"{\"result\":{\"type\":\"agent_order\",\"order\":\"priority\"}}\n")
                .await
                .unwrap();
        });
        let binary = temp.path().join("herdr");
        let session_list = serde_json::json!({
            "sessions": [{
                "name": "default",
                "running": true,
                "socket_path": socket
            }]
        });
        fs::write(
            &binary,
            format!("#!/bin/sh\nprintf '%s\\n' '{}'\n", session_list),
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let config = Config {
            herdr_bin: binary,
            ..Config::default()
        };
        let (runtime, _) = DaemonRuntime::new(config).unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 7;
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            };
            state.snapshot.agents = vec![
                AgentView {
                    source_order: 0,
                    ..test_agent("workspace-first", AgentStatus::Idle, false)
                },
                AgentView {
                    source_order: 1,
                    ..test_agent("attention-first", AgentStatus::Blocked, false)
                },
            ];
        }
        let result = runtime
            .process_agent_order_command(&PortalCommand {
                schema_version: SCHEMA_VERSION,
                request_id: "order".into(),
                sequence: 7,
                agent_id: None,
                action: ActionKind::OrderPriority,
                capability_id: None,
            })
            .await;

        assert!(result.ok);
        let state = runtime.state.read().await;
        assert!(state.snapshot.agent_order.available);
        assert_eq!(state.snapshot.agent_order.mode, AgentOrderMode::Priority);
        assert_eq!(state.snapshot.agents[0].id, "attention-first");
        assert_eq!(state.snapshot.sequence, 8);
        drop(state);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn order_command_compensates_a_partial_multi_session_failure() {
        let temp = tempfile::tempdir().unwrap();
        let first_socket = temp.path().join("first.sock");
        let second_socket = temp.path().join("second.sock");
        let first_listener = tokio::net::UnixListener::bind(&first_socket).unwrap();
        let second_listener = tokio::net::UnixListener::bind(&second_socket).unwrap();

        let first = tokio::spawn(async move {
            for (method, order, response) in [
                (
                    "agent.order.get",
                    None,
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n",
                ),
                (
                    "agent.order.set",
                    Some("priority"),
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"priority\"}}\n",
                ),
                (
                    "agent.order.set",
                    Some("grouped"),
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n",
                ),
                (
                    "agent.order.get",
                    None,
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n",
                ),
            ] {
                let (stream, _) = first_listener.accept().await.unwrap();
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                let request: serde_json::Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                assert_eq!(request["method"], method);
                if let Some(order) = order {
                    assert_eq!(request["params"]["order"], order);
                }
                write.write_all(response.as_bytes()).await.unwrap();
            }
        });
        let second = tokio::spawn(async move {
            for (method, order, response) in [
                (
                    "agent.order.get",
                    None,
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n",
                ),
                ("agent.order.set", Some("priority"), ""),
                (
                    "agent.order.set",
                    Some("grouped"),
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n",
                ),
                (
                    "agent.order.get",
                    None,
                    "{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n",
                ),
            ] {
                let (stream, _) = second_listener.accept().await.unwrap();
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                let request: serde_json::Value =
                    serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                assert_eq!(request["method"], method);
                if let Some(order) = order {
                    assert_eq!(request["params"]["order"], order);
                }
                write.write_all(response.as_bytes()).await.unwrap();
            }
        });

        let binary = temp.path().join("herdr");
        let session_list = serde_json::json!({
            "sessions": [
                {"name": "first", "running": true, "socket_path": first_socket},
                {"name": "second", "running": true, "socket_path": second_socket}
            ]
        });
        fs::write(
            &binary,
            format!("#!/bin/sh\nprintf '%s\\n' '{}'\n", session_list),
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let (runtime, _) = DaemonRuntime::new(Config {
            herdr_bin: binary,
            ..Config::default()
        })
        .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 7;
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            };
        }

        let result = runtime
            .process_agent_order_command(&PortalCommand {
                schema_version: SCHEMA_VERSION,
                request_id: "order-partial".into(),
                sequence: 7,
                agent_id: None,
                action: ActionKind::OrderPriority,
                capability_id: None,
            })
            .await;

        assert!(!result.ok);
        assert_eq!(result.code, "target_unavailable");
        let state = runtime.state.read().await;
        assert_eq!(state.snapshot.sequence, 7);
        assert_eq!(state.snapshot.agent_order.mode, AgentOrderMode::Grouped);
        assert!(state.snapshot.agent_order.available);
        drop(state);
        first.await.unwrap();
        second.await.unwrap();
    }

    #[tokio::test]
    async fn concurrent_order_commands_serialize_and_recheck_sequence() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("herdr.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let (preflight_started_tx, preflight_started_rx) = tokio::sync::oneshot::channel();
        let (release_preflight_tx, release_preflight_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let request: serde_json::Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], "agent.order.get");
            preflight_started_tx.send(()).unwrap();
            release_preflight_rx.await.unwrap();
            write
                .write_all(b"{\"result\":{\"type\":\"agent_order\",\"order\":\"grouped\"}}\n")
                .await
                .unwrap();

            let (stream, _) = listener.accept().await.unwrap();
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            let request: serde_json::Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(request["method"], "agent.order.set");
            write
                .write_all(b"{\"result\":{\"type\":\"agent_order\",\"order\":\"priority\"}}\n")
                .await
                .unwrap();
        });
        let binary = temp.path().join("herdr");
        let session_list = serde_json::json!({
            "sessions": [{"name": "default", "running": true, "socket_path": socket}]
        });
        fs::write(
            &binary,
            format!("#!/bin/sh\nprintf '%s\\n' '{}'\n", session_list),
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let (runtime, _) = DaemonRuntime::new(Config {
            herdr_bin: binary,
            ..Config::default()
        })
        .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 7;
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            };
        }
        let command = PortalCommand {
            schema_version: SCHEMA_VERSION,
            request_id: "first".into(),
            sequence: 7,
            agent_id: None,
            action: ActionKind::OrderPriority,
            capability_id: None,
        };
        let first_runtime = runtime.clone();
        let first =
            tokio::spawn(async move { first_runtime.process_agent_order_command(&command).await });
        preflight_started_rx.await.unwrap();
        let second_runtime = runtime.clone();
        let second = tokio::spawn(async move {
            second_runtime
                .process_agent_order_command(&PortalCommand {
                    schema_version: SCHEMA_VERSION,
                    request_id: "second".into(),
                    sequence: 7,
                    agent_id: None,
                    action: ActionKind::OrderPriority,
                    capability_id: None,
                })
                .await
        });
        release_preflight_tx.send(()).unwrap();

        assert!(first.await.unwrap().ok);
        let second = second.await.unwrap();
        assert!(!second.ok);
        assert_eq!(second.code, "stale_snapshot");
        assert_eq!(runtime.state.read().await.snapshot.sequence, 8);
        server.await.unwrap();
    }

    #[test]
    fn codex_micro_review_latch_follows_authoritative_transitions() {
        assert!(!next_review_ready(None, false, AgentStatus::Idle));
        assert!(next_review_ready(
            Some(AgentStatus::Working),
            false,
            AgentStatus::Idle
        ));
        assert!(next_review_ready(
            Some(AgentStatus::Idle),
            true,
            AgentStatus::Idle
        ));
        assert!(next_review_ready(None, false, AgentStatus::Done));
        for status in [
            AgentStatus::Blocked,
            AgentStatus::Working,
            AgentStatus::Unknown,
        ] {
            assert!(!next_review_ready(Some(AgentStatus::Idle), true, status));
        }
    }

    #[test]
    fn only_a_new_focus_transition_acknowledges_review_ready() {
        let now = Instant::now();
        let mut agents = vec![test_agent("agent", AgentStatus::Working, true)];
        let targets = HashMap::from([("agent".into(), test_target("pane", 1))]);
        let mut observed = HashMap::new();
        let mut focused = HashMap::new();
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);

        agents[0].status = AgentStatus::Idle;
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(agents[0].review_ready, "steady focus must not acknowledge");

        agents[0].focused = false;
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(agents[0].review_ready);

        agents[0].focused = true;
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(!agents[0].review_ready, "new focus must acknowledge");
    }

    #[test]
    fn acknowledged_done_stays_clear_until_a_new_authoritative_change() {
        let now = Instant::now();
        let mut agents = vec![test_agent("agent", AgentStatus::Done, false)];
        let mut targets = HashMap::from([("agent".into(), test_target("pane", 1))]);
        let mut observed = HashMap::new();
        let mut focused = HashMap::new();
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(agents[0].review_ready);

        observed.get_mut("agent").unwrap().review_ready = false;
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(!agents[0].review_ready);

        targets.insert("agent".into(), test_target("pane", 2));
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(agents[0].review_ready);
    }

    #[tokio::test]
    async fn successful_portal_open_acknowledges_review_ready() {
        let (runtime, _) = DaemonRuntime::new(Config::default()).unwrap();
        let agent = test_agent("agent", AgentStatus::Idle, false);
        {
            let mut state = runtime.state.write().await;
            state.snapshot.agents = vec![AgentView {
                review_ready: true,
                ..agent
            }];
            state.observed.insert(
                "agent".into(),
                ObservedAgent {
                    status: AgentStatus::Idle,
                    state_change_seq: 1,
                    since: Instant::now(),
                    review_ready: true,
                },
            );
        }

        runtime.acknowledge_review_ready("agent").await;

        let state = runtime.state.read().await;
        assert!(!state.snapshot.agents[0].review_ready);
        assert!(!state.observed["agent"].review_ready);
    }

    #[test]
    fn voice_errors_are_bounded_static_messages() {
        let result = voice_action_error("request", VoiceActionError::CommandFailed);
        assert_eq!(result.code, "command_error");
        assert_eq!(result.message, "voice action failed");
        assert!(!result.message.contains("transcript"));
    }

    #[tokio::test]
    async fn voice_only_refresh_does_not_invalidate_agent_commands() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("voice-state");
        fs::write(&state_path, "recording").unwrap();
        let (mut runtime, _) = DaemonRuntime::new(Config::default()).unwrap();
        runtime.voice = Arc::new(Mutex::new(VoiceController::new(
            temp.path().join("voxtype"),
            state_path,
            temp.path().join("dictation-active"),
            "owner",
        )));
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 42;
        }

        runtime.refresh_voice().await;

        let state = runtime.state.read().await;
        assert_eq!(state.snapshot.sequence, 42);
        assert_eq!(state.snapshot.voice.state, VoiceState::Recording);
    }

    #[tokio::test]
    async fn disconnect_cancels_only_that_clients_owned_recording() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("voice-state");
        let marker_path = temp.path().join("state/dictation-active");
        let log_path = temp.path().join("voice-args");
        let binary = temp.path().join("voxtype");
        fs::write(&state_path, "idle").unwrap();
        fs::write(
            &binary,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n",
                log_path.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();

        let (mut runtime, _) = DaemonRuntime::new(Config::default()).unwrap();
        runtime.voice = Arc::new(Mutex::new(VoiceController::new(
            binary,
            state_path,
            marker_path.clone(),
            "owner",
        )));
        let client_id = Uuid::new_v4();
        let command = PortalCommand {
            schema_version: SCHEMA_VERSION,
            request_id: "voice-start".into(),
            sequence: 0,
            agent_id: None,
            action: ActionKind::VoiceStart,
            capability_id: None,
        };

        assert!(runtime.process_voice_command(&command, client_id).await.ok);
        assert!(marker_path.exists());

        runtime
            .cancel_voice_for_disconnected_client(client_id)
            .await;

        let state = runtime.state.read().await;
        assert_eq!(state.snapshot.voice.state, VoiceState::Idle);
        assert!(!state.snapshot.voice.owned);
        assert!(state.voice_client_owner.is_none());
        assert!(!marker_path.exists());
        assert_eq!(
            fs::read_to_string(log_path).unwrap(),
            "record start --type --no-auto-submit --no-smart-auto-submit\nrecord cancel\n"
        );
    }

    fn test_agent(id: &str, status: AgentStatus, focused: bool) -> AgentView {
        AgentView {
            id: id.into(),
            display_name: id.into(),
            agent: "codex".into(),
            status,
            review_ready: false,
            launch_pending: false,
            workspace: "workspace".into(),
            repository: None,
            worktree: None,
            session: "default".into(),
            focused,
            observed_for_seconds: 0,
            state_change_seq: 0,
            source_order: 0,
            actions: AgentActions::default(),
        }
    }

    fn test_target(pane_id: &str, state_change_seq: u64) -> AgentTarget {
        AgentTarget::Herdr(HerdrTarget {
            session: "default".into(),
            socket_path: PathBuf::from("/tmp/herdr.sock"),
            pane_id: pane_id.into(),
            terminal_id: "terminal".into(),
            state_change_seq,
            revision: 1,
        })
    }

    fn t3code_target(state_change_seq: u64, acknowledged: bool) -> AgentTarget {
        AgentTarget::T3code(T3codeTarget {
            thread_id: "thread".into(),
            state_change_seq,
            acknowledged,
        })
    }

    fn backend_command(action: ActionKind, sequence: u64) -> PortalCommand {
        PortalCommand {
            schema_version: SCHEMA_VERSION,
            request_id: "backend".into(),
            sequence,
            agent_id: None,
            action,
            capability_id: None,
        }
    }

    #[test]
    fn t3code_settle_acknowledges_review_ready_like_a_focus_transition() {
        let now = Instant::now();
        let mut agents = vec![test_agent("agent", AgentStatus::Done, false)];
        let mut targets = HashMap::from([("agent".to_owned(), t3code_target(1, false))]);
        let mut observed = HashMap::new();
        let mut focused = HashMap::new();
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(agents[0].review_ready);

        agents[0].status = AgentStatus::Idle;
        targets.insert("agent".into(), t3code_target(2, true));
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(!agents[0].review_ready, "T3 Code settle must acknowledge");

        agents[0].status = AgentStatus::Done;
        targets.insert("agent".into(), t3code_target(3, false));
        apply_agent_observations(&mut agents, &targets, &mut observed, &mut focused, now);
        assert!(
            agents[0].review_ready,
            "a new completed turn re-arms review"
        );
    }

    #[tokio::test]
    async fn backend_switch_clears_the_previous_roster_and_persists_the_choice() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp
            .path()
            .join("state/xeneon-edge-agents/agent-backend.toml");
        let (runtime, mut invalidations) =
            DaemonRuntime::new_with_state_path(Config::default(), Some(state_path.clone()))
                .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 4;
            state.snapshot.agents = vec![test_agent("herdr-agent", AgentStatus::Working, true)];
            state
                .targets
                .insert("herdr-agent".into(), test_target("pane", 1));
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            };
        }
        assert_eq!(
            runtime.state.read().await.snapshot.backend.mode,
            AgentBackend::Herdr
        );

        let stale = runtime
            .process_backend_command(&backend_command(ActionKind::BackendT3code, 3))
            .await;
        assert!(!stale.ok);
        assert_eq!(stale.code, "stale_snapshot");

        let result = runtime
            .process_backend_command(&backend_command(ActionKind::BackendT3code, 4))
            .await;
        assert!(result.ok);
        assert_eq!(result.message, "agent_backend_updated");
        {
            let state = runtime.state.read().await;
            assert_eq!(state.backend, AgentBackend::T3code);
            assert_eq!(state.snapshot.backend.mode, AgentBackend::T3code);
            assert!(state.snapshot.backend.switchable);
            assert!(state.snapshot.agents.is_empty());
            assert!(state.targets.is_empty());
            assert!(!state.snapshot.agent_order.available);
            assert_eq!(state.snapshot.connection, ConnectionState::Reconnecting);
            assert_eq!(state.snapshot.sequence, 5);
        }
        assert_eq!(
            invalidations.recv().await.as_deref(),
            Some(BACKEND_SWITCH_INVALIDATION)
        );
        let persisted = fs::read_to_string(&state_path).unwrap();
        assert!(persisted.contains("backend = \"t3code\""));
        let mode = fs::metadata(&state_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let repeated = runtime
            .process_backend_command(&backend_command(ActionKind::BackendT3code, 5))
            .await;
        assert!(repeated.ok);
        assert_eq!(repeated.message, "agent_backend_unchanged");
        assert_eq!(runtime.state.read().await.snapshot.sequence, 5);

        let (restored, _) =
            DaemonRuntime::new_with_state_path(Config::default(), Some(state_path)).unwrap();
        assert_eq!(restored.state.read().await.backend, AgentBackend::T3code);
        assert_eq!(
            restored.state.read().await.snapshot.backend.mode,
            AgentBackend::T3code
        );
    }

    #[tokio::test]
    async fn t3code_ordering_is_daemon_owned_and_never_calls_herdr() {
        let temp = tempfile::tempdir().unwrap();
        let binary = temp.path().join("herdr");
        fs::write(&binary, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let (runtime, _) = DaemonRuntime::new(Config {
            herdr_bin: binary,
            agent_backend: AgentBackend::T3code,
            ..Config::default()
        })
        .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 7;
            state.snapshot.agent_order = AgentOrderSnapshot {
                available: true,
                mode: AgentOrderMode::Grouped,
            };
            state.snapshot.agents = vec![
                AgentView {
                    source_order: 0,
                    ..test_agent("workspace-first", AgentStatus::Idle, false)
                },
                AgentView {
                    source_order: 1,
                    ..test_agent("attention-first", AgentStatus::Blocked, false)
                },
            ];
        }

        let result = runtime
            .process_agent_order_command(&PortalCommand {
                schema_version: SCHEMA_VERSION,
                request_id: "order".into(),
                sequence: 7,
                agent_id: None,
                action: ActionKind::OrderPriority,
                capability_id: None,
            })
            .await;

        assert!(result.ok);
        let state = runtime.state.read().await;
        assert_eq!(state.t3code_order, AgentOrderMode::Priority);
        assert!(state.snapshot.agent_order.available);
        assert_eq!(state.snapshot.agent_order.mode, AgentOrderMode::Priority);
        assert_eq!(state.snapshot.agents[0].id, "attention-first");
        assert_eq!(state.snapshot.sequence, 8);
    }

    #[tokio::test]
    async fn t3code_agent_actions_never_reach_herdr_or_launch_applications() {
        let (runtime, _) = DaemonRuntime::new(Config {
            agent_backend: AgentBackend::T3code,
            ..Config::default()
        })
        .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.snapshot.sequence = 3;
            let mut agent = test_agent("thread", AgentStatus::Idle, false);
            agent.actions = AgentActions {
                open: true,
                zoom: false,
                approve: None,
                interrupt: None,
            };
            state.snapshot.agents = vec![agent];
            state
                .targets
                .insert("thread".into(), t3code_target(1, false));
        }
        let command = |action: ActionKind, capability: Option<&str>| {
            serde_json::to_string(&PortalCommand {
                schema_version: SCHEMA_VERSION,
                request_id: "thread-action".into(),
                sequence: 3,
                agent_id: Some("thread".into()),
                action,
                capability_id: capability.map(str::to_owned),
            })
            .unwrap()
        };
        let client = Uuid::new_v4();

        let zoom = runtime
            .process_command(&command(ActionKind::Zoom, None), client)
            .await;
        assert!(!zoom.ok);
        assert_eq!(zoom.code, "target_unavailable");

        let approve = runtime
            .process_command(&command(ActionKind::Approve, Some("forged")), client)
            .await;
        assert!(!approve.ok);
        assert_eq!(approve.code, "capability_expired");
    }

    #[tokio::test]
    async fn refresh_agents_releases_state_locks_before_dispatching() {
        let temp = tempfile::tempdir().unwrap();
        let binary = temp.path().join("herdr");
        fs::write(&binary, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let (runtime, _) = DaemonRuntime::new(Config {
            herdr_bin: binary,
            t3code: crate::config::T3codeConfig {
                home: Some(temp.path().join("t3")),
                ..crate::config::T3codeConfig::default()
            },
            ..Config::default()
        })
        .unwrap();

        let mut subscriptions = HashMap::new();
        tokio::time::timeout(
            Duration::from_secs(5),
            runtime.refresh_agents(&mut subscriptions),
        )
        .await
        .expect("Herdr refresh must not deadlock on the runtime state lock");
        assert_eq!(
            runtime.state.read().await.snapshot.connection,
            ConnectionState::Offline
        );

        runtime.state.write().await.backend = AgentBackend::T3code;
        tokio::time::timeout(
            Duration::from_secs(5),
            runtime.refresh_agents(&mut subscriptions),
        )
        .await
        .expect("T3 Code refresh must not deadlock on the runtime state lock");
        let state = runtime.state.read().await;
        assert_eq!(state.snapshot.connection, ConnectionState::Offline);
        assert_eq!(state.snapshot.sessions.len(), 1);
        assert_eq!(state.snapshot.sessions[0].name, "t3code");
        assert_eq!(state.snapshot.sessions[0].state, SessionState::Offline);
    }

    #[tokio::test]
    async fn late_herdr_refresh_never_commits_over_a_t3code_roster() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("herdr.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            // Any Herdr request after the switch is a contract violation.
            tokio::time::timeout(Duration::from_millis(500), listener.accept())
                .await
                .is_ok()
        });
        let binary = temp.path().join("herdr");
        let session_list = serde_json::json!({
            "sessions": [{"name": "default", "running": true, "socket_path": socket}]
        });
        fs::write(
            &binary,
            format!("#!/bin/sh\nprintf '%s\\n' '{}'\n", session_list),
        )
        .unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let (runtime, _) = DaemonRuntime::new(Config {
            herdr_bin: binary,
            ..Config::default()
        })
        .unwrap();
        {
            let mut state = runtime.state.write().await;
            state.backend = AgentBackend::T3code;
            state.snapshot.backend.mode = AgentBackend::T3code;
            state.snapshot.sequence = 9;
            state.snapshot.connection = ConnectionState::Connected;
            state.snapshot.sessions = vec![SessionView {
                name: t3code::SESSION_NAME.into(),
                state: SessionState::Connected,
                version: None,
                protocol: Some(1),
                last_sync_ms: Some(1),
                message: None,
            }];
            state.snapshot.agents = vec![test_agent("thread", AgentStatus::Working, false)];
            state
                .targets
                .insert("thread".into(), t3code_target(1, false));
        }

        // Simulates a refresh dispatched for Herdr just before the switch.
        runtime.refresh_herdr(&mut HashMap::new()).await;

        let state = runtime.state.read().await;
        assert_eq!(state.backend, AgentBackend::T3code);
        assert_eq!(state.snapshot.sequence, 9);
        assert_eq!(state.snapshot.sessions[0].name, t3code::SESSION_NAME);
        assert_eq!(state.snapshot.agents[0].id, "thread");
        assert!(matches!(state.targets["thread"], AgentTarget::T3code(_)));
        drop(state);
        assert!(
            !server.await.unwrap(),
            "Herdr sockets must not be contacted"
        );
    }

    #[test]
    fn persisted_backend_round_trips_and_rejects_garbage() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("nested/agent-backend.toml");
        let persisted = PersistedBackend {
            backend: AgentBackend::T3code,
            t3code_order: AgentOrderMode::Priority,
        };
        save_persisted_backend(&path, &persisted).unwrap();
        assert_eq!(load_persisted_backend(&path), Some(persisted));
        fs::write(&path, "backend = \"tmux\"\n").unwrap();
        assert_eq!(load_persisted_backend(&path), None);
        assert_eq!(
            load_persisted_backend(&temp.path().join("missing.toml")),
            None
        );
    }
}
