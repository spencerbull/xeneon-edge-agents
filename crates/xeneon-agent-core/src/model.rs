use std::cmp::Ordering;

use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Blocked,
    Done,
    Working,
    Idle,
    #[default]
    #[serde(other)]
    Unknown,
}

impl AgentStatus {
    pub fn attention_rank(self) -> u8 {
        match self {
            Self::Blocked => 0,
            Self::Done => 1,
            Self::Working => 2,
            Self::Idle => 3,
            Self::Unknown => 4,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    Connected,
    Degraded,
    Reconnecting,
    Offline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Connected,
    Stale,
    Incompatible,
    Offline,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoiceState {
    Idle,
    Recording,
    Processing,
    Error,
    #[default]
    #[serde(other)]
    Unavailable,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceSnapshot {
    pub state: VoiceState,
    #[serde(default)]
    pub owned: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Open,
    Zoom,
    Approve,
    Interrupt,
    RestoreFocus,
    ChatgptDesktop,
    ClaudeDesktop,
    VoiceStart,
    VoiceStop,
    VoiceCancel,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionCapability {
    pub capability_id: String,
    pub kind: ActionKind,
    pub expires_at_ms: u64,
    pub expected_revision: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentActions {
    #[serde(default)]
    pub open: bool,
    #[serde(default)]
    pub zoom: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approve: Option<ActionCapability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interrupt: Option<ActionCapability>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentView {
    pub id: String,
    pub display_name: String,
    pub agent: String,
    pub status: AgentStatus,
    #[serde(default)]
    pub review_ready: bool,
    #[serde(default)]
    pub launch_pending: bool,
    pub workspace: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    pub session: String,
    pub focused: bool,
    pub observed_for_seconds: u64,
    pub source_order: usize,
    pub actions: AgentActions,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageKind {
    #[default]
    Quota,
    LocalBudget,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageWindow {
    pub label: String,
    pub utilization: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_at_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderUsage {
    pub id: String,
    pub label: String,
    pub kind: UsageKind,
    pub available: bool,
    pub stale: bool,
    pub source: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary: Option<UsageWindow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secondary: Option<UsageWindow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub today_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_per_hour: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_updated_ms: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AiUsageSnapshot {
    pub providers: Vec<ProviderUsage>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MicroSnapshot {
    pub connected: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub firmware: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub battery: Option<u8>,
    #[serde(default)]
    pub charging: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layer: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_updated_ms: Option<u64>,
}

pub fn sort_agents(agents: &mut [AgentView]) {
    agents.sort_by(|left, right| {
        agent_attention_rank(left)
            .cmp(&agent_attention_rank(right))
            .then_with(|| left.source_order.cmp(&right.source_order))
            .then_with(|| left.id.cmp(&right.id))
    });
}

fn agent_attention_rank(agent: &AgentView) -> u8 {
    if agent.review_ready && matches!(agent.status, AgentStatus::Done | AgentStatus::Idle) {
        AgentStatus::Done.attention_rank()
    } else if agent.status == AgentStatus::Done {
        AgentStatus::Idle.attention_rank()
    } else {
        agent.status.attention_rank()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionView {
    pub name: String,
    pub state: SessionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_sync_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Metric {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    pub unit: String,
}

impl Metric {
    pub fn unavailable(unit: impl Into<String>) -> Self {
        Self {
            available: false,
            value: None,
            unit: unit.into(),
        }
    }

    pub fn available(value: f64, unit: impl Into<String>) -> Self {
        Self {
            available: true,
            value: Some(value),
            unit: unit.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HealthSnapshot {
    pub cpu: Metric,
    pub cpu_temperature: Metric,
    pub gpu: Metric,
    pub gpu_temperature: Metric,
    pub memory: Metric,
    pub network_down: Metric,
    pub network_up: Metric,
    pub battery: Metric,
}

impl Default for HealthSnapshot {
    fn default() -> Self {
        Self {
            cpu: Metric::unavailable("%"),
            cpu_temperature: Metric::unavailable("°C"),
            gpu: Metric::unavailable("%"),
            gpu_temperature: Metric::unavailable("°C"),
            memory: Metric::unavailable("%"),
            network_down: Metric::unavailable("B/s"),
            network_up: Metric::unavailable("B/s"),
            battery: Metric::unavailable("%"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PortalSnapshot {
    pub schema_version: u32,
    pub sequence: u64,
    pub daemon_epoch: String,
    pub generated_at_ms: u64,
    pub connection: ConnectionState,
    pub sessions: Vec<SessionView>,
    pub agents: Vec<AgentView>,
    pub voice: VoiceSnapshot,
    pub usage: AiUsageSnapshot,
    pub micro: MicroSnapshot,
    pub health: HealthSnapshot,
}

impl PortalSnapshot {
    pub fn empty(epoch: impl Into<String>) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            sequence: 0,
            daemon_epoch: epoch.into(),
            generated_at_ms: 0,
            connection: ConnectionState::Offline,
            sessions: Vec::new(),
            agents: Vec::new(),
            voice: VoiceSnapshot::default(),
            usage: AiUsageSnapshot::default(),
            micro: MicroSnapshot::default(),
            health: HealthSnapshot::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortalCommand {
    pub schema_version: u32,
    #[serde(default)]
    pub request_id: String,
    pub sequence: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub action: ActionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capability_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionResult {
    pub schema_version: u32,
    pub request_id: String,
    pub ok: bool,
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Snapshot {
        #[serde(flatten)]
        snapshot: Box<PortalSnapshot>,
    },
    ActionResult {
        #[serde(flatten)]
        result: ActionResult,
    },
    Notice {
        schema_version: u32,
        level: String,
        code: String,
        message: String,
    },
}

impl PartialOrd for AgentStatus {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for AgentStatus {
    fn cmp(&self, other: &Self) -> Ordering {
        self.attention_rank().cmp(&other.attention_rank())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(id: &str, status: AgentStatus, source_order: usize) -> AgentView {
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
            focused: false,
            observed_for_seconds: 0,
            source_order,
            actions: AgentActions::default(),
        }
    }

    #[test]
    fn attention_sort_preserves_source_order_within_status() {
        let mut done = agent("done", AgentStatus::Done, 1);
        done.review_ready = true;
        let mut agents = vec![
            agent("idle", AgentStatus::Idle, 0),
            agent("working-2", AgentStatus::Working, 3),
            agent("blocked", AgentStatus::Blocked, 9),
            agent("working-1", AgentStatus::Working, 2),
            done,
        ];

        sort_agents(&mut agents);

        let ids: Vec<_> = agents.iter().map(|agent| agent.id.as_str()).collect();
        assert_eq!(ids, ["blocked", "done", "working-1", "working-2", "idle"]);
    }

    #[test]
    fn unknown_status_is_forward_compatible() {
        let status: AgentStatus = serde_json::from_str("\"future_state\"").unwrap();
        assert_eq!(status, AgentStatus::Unknown);
    }

    #[test]
    fn review_ready_idle_sorts_with_done_priority() {
        let mut review = agent("review", AgentStatus::Idle, 1);
        review.review_ready = true;
        let mut agents = vec![
            agent("working", AgentStatus::Working, 0),
            review,
            agent("blocked", AgentStatus::Blocked, 2),
        ];

        sort_agents(&mut agents);

        let ids: Vec<_> = agents.iter().map(|agent| agent.id.as_str()).collect();
        assert_eq!(ids, ["blocked", "review", "working"]);
    }

    #[test]
    fn active_attention_state_wins_an_inconsistent_review_latch() {
        let mut blocked = agent("blocked", AgentStatus::Blocked, 0);
        blocked.review_ready = true;
        let mut agents = vec![
            agent("done", AgentStatus::Done, 1),
            blocked,
            agent("working", AgentStatus::Working, 2),
        ];

        sort_agents(&mut agents);

        let ids: Vec<_> = agents.iter().map(|agent| agent.id.as_str()).collect();
        assert_eq!(ids, ["blocked", "working", "done"]);
    }

    #[test]
    fn acknowledged_done_sorts_as_idle() {
        let mut review = agent("review", AgentStatus::Idle, 2);
        review.review_ready = true;
        let mut agents = vec![
            agent("done", AgentStatus::Done, 0),
            agent("working", AgentStatus::Working, 1),
            review,
        ];

        sort_agents(&mut agents);

        let ids: Vec<_> = agents.iter().map(|agent| agent.id.as_str()).collect();
        assert_eq!(ids, ["review", "working", "done"]);
    }

    #[test]
    fn snapshot_message_is_flat_and_tagged() {
        let value = serde_json::to_value(ServerMessage::Snapshot {
            snapshot: Box::new(PortalSnapshot::empty("epoch")),
        })
        .unwrap();

        assert_eq!(value["type"], "snapshot");
        assert_eq!(value["schema_version"], SCHEMA_VERSION);
        assert_eq!(value["daemon_epoch"], "epoch");
    }
}
