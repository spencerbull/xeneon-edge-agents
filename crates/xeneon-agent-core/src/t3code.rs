//! Read-only T3 Code agent adapter.
//!
//! T3 Code keeps its orchestration state in a local SQLite projection under
//! its data directory. This adapter reads only the bounded thread, session,
//! turn, and project projections needed to build portal cards. It never reads
//! messages, activities, prompts, checkpoints, secrets, or provider payloads,
//! and it never writes to T3 Code state.
//!
//! Liveness is derived from T3 Code's own `server-runtime.json` descriptor plus
//! the recorded server process. A readable database never proves that T3 Code
//! is running.

use std::{
    collections::HashMap,
    env, fs,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::Deserialize;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::model::{AgentActions, AgentStatus, AgentView, SessionState, SessionView};

/// Session name reported for the single local T3 Code server.
pub const SESSION_NAME: &str = "t3code";
/// `server-runtime.json` descriptor versions this adapter understands.
const SUPPORTED_RUNTIME_VERSION: u32 = 1;
const BUSY_TIMEOUT: Duration = Duration::from_millis(250);
/// Upper bound on projection rows inspected per reconciliation.
const MAX_CANDIDATES: usize = 512;
/// Upper bound on cards produced per reconciliation.
const MAX_ROSTER: usize = 64;
const MAX_TITLE_CHARS: usize = 120;
const MAX_LABEL_CHARS: usize = 96;

#[derive(Debug, Clone)]
pub struct T3codeClient {
    userdata: PathBuf,
    expected_comm: Option<String>,
    status_file: Option<PathBuf>,
}

/// Private action-routing state for one T3 Code thread card.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct T3codeTarget {
    pub thread_id: String,
    pub state_change_seq: u64,
    /// T3 Code recorded the human settling this thread, which acknowledges a
    /// completed turn the same way a Herdr focus transition does.
    pub acknowledged: bool,
}

#[derive(Debug)]
pub struct T3codeObservation {
    pub session: SessionView,
    pub agents: Vec<AgentView>,
    pub targets: HashMap<String, T3codeTarget>,
    /// Highest projection sequence applied by T3 Code, used as a cheap change
    /// signal between full reconciliations.
    pub projection_sequence: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ServerRuntime {
    version: u32,
    pid: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Liveness {
    Missing,
    Unsupported(u32),
    Stopped,
    Running(u32),
}

#[derive(Debug, Clone, Default)]
struct ThreadRow {
    thread_id: String,
    title: String,
    branch: Option<String>,
    worktree_path: Option<String>,
    pending_approval_count: i64,
    pending_user_input_count: i64,
    has_actionable_proposed_plan: bool,
    settled_at: Option<String>,
    snoozed_until: Option<String>,
    created_at: String,
    session_status: Option<String>,
    provider_name: Option<String>,
    project_title: Option<String>,
    workspace_root: Option<String>,
    last_turn: Option<TurnRow>,
    active_work: bool,
    visited_at: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct TurnRow {
    state: String,
    requested_at: String,
    started_at: Option<String>,
    completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Classification {
    status: AgentStatus,
    launch_pending: bool,
    state_change_seq: u64,
    acknowledged: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct StatusSnapshot {
    schema_version: u32,
    environment_id: String,
    generated_at_ms: u64,
    threads: Vec<StatusThread>,
}

#[derive(Debug, Clone, Deserialize)]
struct StatusThread {
    thread_id: String,
    title: String,
    project_title: String,
    workspace_root: String,
    branch: Option<String>,
    worktree_path: Option<String>,
    provider: String,
    status: String,
    settled: bool,
    snoozed: bool,
    pending_input: bool,
    background_work: bool,
    updated_at: String,
    latest_run_completed_at: Option<String>,
    last_visited_at: Option<String>,
}

impl StatusSnapshot {
    fn rows(&self) -> Vec<ThreadRow> {
        self.threads
            .iter()
            .map(|thread| {
                let active = thread.background_work
                    || matches!(
                        thread.status.as_str(),
                        "working" | "running" | "preparing" | "starting" | "waiting" | "queued"
                    );
                ThreadRow {
                    thread_id: thread.thread_id.clone(),
                    title: thread.title.clone(),
                    project_title: Some(thread.project_title.clone()),
                    workspace_root: Some(thread.workspace_root.clone()),
                    branch: thread.branch.clone(),
                    worktree_path: thread.worktree_path.clone(),
                    provider_name: Some(thread.provider.clone()),
                    pending_user_input_count: i64::from(thread.pending_input),
                    active_work: active,
                    created_at: thread.updated_at.clone(),
                    visited_at: thread.last_visited_at.clone(),
                    settled_at: thread.settled.then(|| thread.updated_at.clone()),
                    snoozed_until: thread.snoozed.then(|| "2999-01-01T00:00:00Z".into()),
                    session_status: Some("ready".into()),
                    last_turn: if thread.status == "idle"
                        && thread.latest_run_completed_at.is_none()
                    {
                        None
                    } else {
                        Some(TurnRow {
                            state: match thread.status.as_str() {
                                "failed" | "error" => "error",
                                "blocked" => "error",
                                "working" | "running" | "preparing" | "starting" | "waiting" => {
                                    "running"
                                }
                                "completed" | "idle" | "done" => "completed",
                                "interrupted" | "cancelled" => "interrupted",
                                "queued" => "pending",
                                _ => "unknown",
                            }
                            .into(),
                            requested_at: thread.updated_at.clone(),
                            started_at: None,
                            completed_at: thread.latest_run_completed_at.clone(),
                        })
                    },
                    ..ThreadRow::default()
                }
            })
            .collect()
    }
}

impl T3codeClient {
    pub async fn open_native(&self, bin: &Path, thread_id: &str) -> Result<()> {
        let environment = fs::read_to_string(self.userdata.join("environment-id"))?;
        let mut child = tokio::process::Command::new(bin)
            .args([
                "app",
                "--thread",
                thread_id,
                "--environment",
                environment.trim(),
                "--base-dir",
            ])
            .arg(
                self.userdata
                    .parent()
                    .ok_or_else(|| anyhow!("T3 home is missing"))?,
            )
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let status = tokio::time::timeout(Duration::from_secs(20), child.wait()).await??;
        anyhow::ensure!(status.success(), "native T3 thread activation failed");
        Ok(())
    }
    fn read_status_feed(&self, now_ms: u64) -> Result<StatusSnapshot> {
        let path = self
            .status_file
            .as_ref()
            .ok_or_else(|| anyhow!("T3 feed is not configured"))?;
        anyhow::ensure!(
            fs::metadata(path)?.len() <= 4_194_304,
            "T3 metadata frame is too large"
        );
        let feed: StatusSnapshot =
            serde_json::from_reader(std::io::Read::take(fs::File::open(path)?, 4_194_305))?;
        let environment = fs::read_to_string(self.userdata.join("environment-id"))?;
        anyhow::ensure!(
            feed.schema_version == 1
                && feed.threads.len() <= MAX_ROSTER
                && feed.environment_id == environment.trim()
                && now_ms.abs_diff(feed.generated_at_ms) < 10_000,
            "invalid or stale T3 feed"
        );
        Ok(feed)
    }

    pub fn thread_url(&self, thread_id: &str) -> Result<String> {
        let runtime: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(self.runtime_path())?)?;
        let origin = runtime
            .get("origin")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| anyhow!("T3 runtime has no origin"))?;
        let environment = fs::read_to_string(self.userdata.join("environment-id"))?;
        thread_url(origin, environment.trim(), thread_id)
    }
    /// Builds a client for a T3 Code data directory (the parent of `userdata`).
    pub fn new(home: impl Into<PathBuf>) -> Self {
        Self {
            userdata: home.into().join("userdata"),
            expected_comm: Some("t3code".into()),
            status_file: None,
        }
    }

    pub fn from_config(configured_home: Option<&Path>, status_file: Option<&Path>) -> Result<Self> {
        let home = match configured_home {
            Some(home) => home.to_path_buf(),
            None => default_home()?,
        };
        let mut client = Self::new(home);
        client.status_file = status_file.map(Path::to_path_buf);
        Ok(client)
    }

    /// Tests run without a T3 Code server process, so they observe their own
    /// process id without a command-name requirement.
    #[cfg(test)]
    fn without_process_identity(mut self) -> Self {
        self.expected_comm = None;
        self
    }

    fn database_path(&self) -> PathBuf {
        let current = self.userdata.join("statev2.sqlite");
        if current.exists() {
            current
        } else {
            self.userdata.join("state.sqlite")
        }
    }

    fn runtime_path(&self) -> PathBuf {
        self.userdata.join("server-runtime.json")
    }

    fn liveness(&self) -> Liveness {
        let Ok(contents) = fs::read_to_string(self.runtime_path()) else {
            return Liveness::Missing;
        };
        let Ok(runtime) = serde_json::from_str::<ServerRuntime>(&contents) else {
            return Liveness::Missing;
        };
        if runtime.version != SUPPORTED_RUNTIME_VERSION {
            return Liveness::Unsupported(runtime.version);
        }
        if process_alive(runtime.pid, self.expected_comm.as_deref()) {
            Liveness::Running(runtime.version)
        } else {
            Liveness::Stopped
        }
    }

    fn open(&self) -> Result<Connection> {
        let path = self.database_path();
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .with_context(|| format!("opening T3 Code state {}", path.display()))?;
        connection
            .busy_timeout(BUSY_TIMEOUT)
            .context("configuring T3 Code busy timeout")?;
        Ok(connection)
    }

    /// Cheap change signal: the highest projection sequence T3 Code applied.
    pub fn projection_sequence(&self) -> Result<Option<u64>> {
        if self.status_file.is_some() {
            return Ok(self
                .read_status_feed(crate::runtime::now_ms())
                .ok()
                .map(|feed| feed.generated_at_ms));
        }
        let connection = self.open()?;
        read_projection_sequence(&connection)
    }

    /// Observes the live T3 Code roster. Failures are reported as session
    /// states rather than errors so the caller can publish them safely.
    pub fn observe(&self, daemon_epoch: &str, now_ms: u64) -> T3codeObservation {
        if self.status_file.is_some() {
            return match self.read_status_feed(now_ms) {
                Ok(feed) => observation_from_rows(
                    feed.rows(),
                    daemon_epoch,
                    now_ms,
                    Some(1),
                    Some(feed.generated_at_ms),
                ),
                Err(_) => T3codeObservation {
                    session: SessionView {
                        name: SESSION_NAME.into(),
                        state: SessionState::Stale,
                        version: None,
                        protocol: Some(1),
                        last_sync_ms: Some(now_ms),
                        message: Some("T3 metadata feed is unavailable".into()),
                    },
                    agents: Vec::new(),
                    targets: HashMap::new(),
                    projection_sequence: None,
                },
            };
        }

        let (protocol, offline_message) = match self.liveness() {
            Liveness::Running(version) => (Some(version), None),
            Liveness::Missing => (None, Some("T3 Code server is not running")),
            Liveness::Stopped => (
                Some(SUPPORTED_RUNTIME_VERSION),
                Some("T3 Code server process has exited"),
            ),
            Liveness::Unsupported(version) => {
                return T3codeObservation {
                    session: SessionView {
                        name: SESSION_NAME.into(),
                        state: SessionState::Incompatible,
                        version: None,
                        protocol: Some(version),
                        last_sync_ms: Some(now_ms),
                        message: Some(format!(
                            "T3 Code runtime descriptor {version} is unsupported; expected {SUPPORTED_RUNTIME_VERSION}"
                        )),
                    },
                    agents: Vec::new(),
                    targets: HashMap::new(),
                    projection_sequence: None,
                };
            }
        };
        if let Some(message) = offline_message {
            return T3codeObservation {
                session: SessionView {
                    name: SESSION_NAME.into(),
                    state: SessionState::Offline,
                    version: None,
                    protocol,
                    last_sync_ms: Some(now_ms),
                    message: Some(message.into()),
                },
                agents: Vec::new(),
                targets: HashMap::new(),
                projection_sequence: None,
            };
        }

        let connection = match self.open() {
            Ok(connection) => connection,
            Err(error) => {
                tracing::warn!(%error, "T3 Code state is unavailable");
                return T3codeObservation {
                    session: SessionView {
                        name: SESSION_NAME.into(),
                        state: SessionState::Stale,
                        version: None,
                        protocol,
                        last_sync_ms: Some(now_ms),
                        message: Some("T3 Code state is unavailable".into()),
                    },
                    agents: Vec::new(),
                    targets: HashMap::new(),
                    projection_sequence: None,
                };
            }
        };
        let projection_sequence = read_projection_sequence(&connection).ok().flatten();
        let rows = match read_threads(&connection) {
            Ok(rows) => rows,
            Err(error) => {
                tracing::warn!(%error, "T3 Code state schema is unsupported");
                return T3codeObservation {
                    session: SessionView {
                        name: SESSION_NAME.into(),
                        state: SessionState::Incompatible,
                        version: None,
                        protocol,
                        last_sync_ms: Some(now_ms),
                        message: Some("T3 Code state schema is unsupported".into()),
                    },
                    agents: Vec::new(),
                    targets: HashMap::new(),
                    projection_sequence,
                };
            }
        };

        observation_from_rows(rows, daemon_epoch, now_ms, protocol, projection_sequence)
    }
}

fn observation_from_rows(
    rows: Vec<ThreadRow>,
    daemon_epoch: &str,
    now_ms: u64,
    protocol: Option<u32>,
    projection_sequence: Option<u64>,
) -> T3codeObservation {
    let mut agents = Vec::new();
    let mut targets = HashMap::new();
    for row in rows {
        if agents.len() >= MAX_ROSTER {
            break;
        }
        let Some(classification) = classify(&row, now_ms) else {
            continue;
        };
        let id = opaque_agent_id(daemon_epoch, &row.thread_id);
        let source_order = agents.len();
        targets.insert(
            id.clone(),
            T3codeTarget {
                thread_id: row.thread_id.clone(),
                state_change_seq: classification.state_change_seq,
                acknowledged: classification.acknowledged,
            },
        );
        agents.push(AgentView {
            id,
            display_name: display_name(&row),
            agent: agent_kind(row.provider_name.as_deref()),
            status: classification.status,
            review_ready: false,
            launch_pending: classification.launch_pending,
            workspace: workspace_label(&row),
            repository: row
                .workspace_root
                .as_deref()
                .and_then(path_leaf)
                .map(|leaf| sanitize(leaf, MAX_LABEL_CHARS)),
            worktree: row
                .worktree_path
                .as_deref()
                .and_then(path_leaf)
                .map(|leaf| sanitize(leaf, MAX_LABEL_CHARS)),
            session: SESSION_NAME.into(),
            focused: false,
            observed_for_seconds: 0,
            state_change_seq: classification.state_change_seq,
            source_order,
            actions: AgentActions {
                open: true,
                zoom: false,
                approve: None,
                interrupt: None,
            },
        });
    }

    T3codeObservation {
        session: SessionView {
            name: SESSION_NAME.into(),
            state: SessionState::Connected,
            version: None,
            protocol,
            last_sync_ms: Some(now_ms),
            message: None,
        },
        agents,
        targets,
        projection_sequence,
    }
}

fn thread_url(origin: &str, environment: &str, thread_id: &str) -> Result<String> {
    let address = origin
        .strip_prefix("http://")
        .ok_or_else(|| anyhow!("T3 local origin must use HTTP"))?;
    let (host, port) = address
        .rsplit_once(':')
        .ok_or_else(|| anyhow!("T3 local origin has no port"))?;
    anyhow::ensure!(
        matches!(host, "127.0.0.1" | "localhost" | "[::1]")
            && port.parse::<u16>().is_ok_and(|port| port != 0),
        "T3 local origin is not loopback"
    );
    anyhow::ensure!(
        !environment.is_empty()
            && !thread_id.is_empty()
            && environment.len() <= 256
            && thread_id.len() <= 256,
        "invalid thread target"
    );
    fn component(value: &str) -> String {
        value
            .bytes()
            .map(|byte| {
                if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
                    char::from(byte).to_string()
                } else {
                    format!("%{byte:02X}")
                }
            })
            .collect()
    }
    Ok(format!(
        "{origin}/{}/{}",
        component(environment),
        component(thread_id)
    ))
}

fn default_home() -> Result<PathBuf> {
    if let Some(home) = env::var_os("T3CODE_HOME").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(home));
    }
    env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".t3"))
        .ok_or_else(|| anyhow!("T3CODE_HOME and HOME are not set"))
}

fn process_alive(pid: i64, expected_comm: Option<&str>) -> bool {
    if pid <= 0 {
        return false;
    }
    let process = Path::new("/proc").join(pid.to_string());
    match expected_comm {
        Some(expected) => {
            fs::read_to_string(process.join("comm")).is_ok_and(|comm| comm.trim() == expected)
        }
        None => process.is_dir(),
    }
}

fn read_projection_sequence(connection: &Connection) -> Result<Option<u64>> {
    if is_v2(connection)? {
        let sequence: Option<i64> = connection.query_row(
            "SELECT last_sequence FROM orchestration_v2_projection_metadata WHERE projection_name = 'thread-projections' AND schema_version = 2", [], |row| row.get(0)
        ).optional()?;
        return sequence
            .map(|value| u64::try_from(value).context("invalid projection sequence"))
            .transpose();
    }
    let sequence: Option<i64> = connection
        .query_row(
            "SELECT MAX(last_applied_sequence) FROM projection_state",
            [],
            |row| row.get(0),
        )
        .context("reading T3 Code projection sequence")?;
    Ok(sequence.and_then(|value| u64::try_from(value).ok()))
}

fn is_v2(connection: &Connection) -> Result<bool> {
    Ok(connection.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='orchestration_v2_projection_threads')", [], |row| row.get(0))?)
}

fn read_v2_threads(connection: &Connection) -> Result<Vec<ThreadRow>> {
    anyhow::ensure!(
        read_projection_sequence(connection)?.is_some(),
        "unsupported T3 projection schema"
    );
    // Extract only allowlisted metadata scalars: complete JSON records contain private content.
    let mut statement = connection.prepare(
        "SELECT t.thread_id, t.title, json_extract(t.payload_json,'$.branch'),
         json_extract(t.payload_json,'$.worktreePath'),
         EXISTS(SELECT 1 FROM orchestration_v2_projection_runtime_requests q WHERE q.thread_id=t.thread_id AND q.status='pending'),
         json_extract(t.payload_json,'$.settledAt'), json_extract(t.payload_json,'$.snoozedUntil'),
         t.created_at, COALESCE(t.provider_instance_id,t.default_provider), p.title, p.workspace_root,
         r.status, r.requested_at, r.completed_at,
         EXISTS(SELECT 1 FROM orchestration_v2_projection_runs a WHERE a.thread_id=t.thread_id AND (a.status IN ('preparing','starting','running','waiting') OR (a.status='queued' AND json_extract(a.payload_json,'$.queueHeld') IS NOT 1)))
          OR EXISTS(SELECT 1 FROM orchestration_v2_projection_subagents a WHERE a.thread_id=t.thread_id AND a.status IN ('pending','running','waiting')) AS active_work,
         json_extract(t.payload_json,'$.lastVisitedAt'), json_extract(t.payload_json,'$.settledOverride')
         FROM orchestration_v2_projection_threads t
         LEFT JOIN projection_projects p ON p.project_id=t.project_id
         LEFT JOIN orchestration_v2_projection_runs r ON r.run_id=(
          SELECT candidate.run_id FROM orchestration_v2_projection_runs candidate WHERE candidate.thread_id=t.thread_id
          AND NOT(candidate.status='queued' AND json_extract(candidate.payload_json,'$.queueHeld') IS 1)
          ORDER BY candidate.ordinal DESC,candidate.run_id DESC LIMIT 1)
         WHERE t.deleted_at IS NULL AND t.archived_at IS NULL AND (p.project_id IS NULL OR p.deleted_at IS NULL)
         AND (json_extract(t.payload_json,'$.settledOverride') IS NOT 'settled'
           OR EXISTS(SELECT 1 FROM orchestration_v2_projection_runtime_requests q WHERE q.thread_id=t.thread_id AND q.status='pending')
           OR EXISTS(SELECT 1 FROM orchestration_v2_projection_runs a WHERE a.thread_id=t.thread_id AND (a.status IN ('preparing','starting','running','waiting') OR (a.status='queued' AND json_extract(a.payload_json,'$.queueHeld') IS NOT 1)))
           OR EXISTS(SELECT 1 FROM orchestration_v2_projection_subagents a WHERE a.thread_id=t.thread_id AND a.status IN ('pending','running','waiting')))
         AND (json_extract(t.payload_json,'$.lineage.relationshipToParent') IS NOT 'subagent' OR EXISTS(SELECT 1 FROM orchestration_v2_projection_runtime_requests q WHERE q.thread_id=t.thread_id AND q.status='pending'))
         ORDER BY 5 DESC, active_work DESC, t.updated_at DESC, t.thread_id LIMIT ?1"
    )?;
    let rows = statement.query_map([MAX_CANDIDATES as i64], |row| {
        let state: Option<String> = row.get(11)?;
        let requested_at: Option<String> = row.get(12)?;
        let completed_at: Option<String> = row.get(13)?;
        let active_work: bool = row.get(14)?;
        let settled_override: Option<String> = row.get(16)?;
        let settled_at = if settled_override.as_deref() == Some("active") {
            None
        } else {
            row.get(5)?
        };
        Ok(ThreadRow {
            thread_id: row.get(0)?,
            title: row.get(1)?,
            branch: row.get(2)?,
            worktree_path: row.get(3)?,
            pending_approval_count: row.get(4)?,
            settled_at,
            snoozed_until: row.get(6)?,
            created_at: row.get(7)?,
            provider_name: row.get(8)?,
            project_title: row.get(9)?,
            workspace_root: row.get(10)?,
            session_status: Some(if active_work { "running" } else { "ready" }.into()),
            last_turn: state.map(|state| TurnRow {
                state: match state.as_str() {
                    "queued" => "pending".into(),
                    "preparing" | "starting" | "waiting" => "running".into(),
                    "failed" => "error".into(),
                    "cancelled" => "interrupted".into(),
                    _ => state,
                },
                requested_at: requested_at.unwrap_or_default(),
                started_at: None,
                completed_at,
            }),
            active_work,
            visited_at: row.get(15)?,
            ..ThreadRow::default()
        })
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

fn read_threads(connection: &Connection) -> Result<Vec<ThreadRow>> {
    if is_v2(connection)? {
        return read_v2_threads(connection);
    }
    let mut statement = connection
        .prepare(
            "SELECT t.thread_id, t.title, t.branch, t.worktree_path, \
                    t.pending_approval_count, t.pending_user_input_count, \
                    t.has_actionable_proposed_plan, t.settled_at, t.snoozed_until, \
                    t.created_at, s.status, s.provider_name, p.title, p.workspace_root \
             FROM projection_threads t \
             LEFT JOIN projection_thread_sessions s ON s.thread_id = t.thread_id \
             LEFT JOIN projection_projects p ON p.project_id = t.project_id \
             WHERE t.deleted_at IS NULL AND t.archived_at IS NULL \
               AND (p.project_id IS NULL OR p.deleted_at IS NULL) \
             ORDER BY p.updated_at DESC, t.updated_at DESC \
             LIMIT ?1",
        )
        .context("preparing T3 Code thread query")?;
    let rows = statement
        .query_map([MAX_CANDIDATES as i64], |row| {
            Ok(ThreadRow {
                thread_id: row.get(0)?,
                title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                branch: row.get(2)?,
                worktree_path: row.get(3)?,
                pending_approval_count: row.get::<_, Option<i64>>(4)?.unwrap_or_default(),
                pending_user_input_count: row.get::<_, Option<i64>>(5)?.unwrap_or_default(),
                has_actionable_proposed_plan: row.get::<_, Option<i64>>(6)?.unwrap_or_default()
                    != 0,
                settled_at: row.get(7)?,
                snoozed_until: row.get(8)?,
                created_at: row.get::<_, Option<String>>(9)?.unwrap_or_default(),
                session_status: row.get(10)?,
                provider_name: row.get(11)?,
                project_title: row.get(12)?,
                workspace_root: row.get(13)?,
                last_turn: None,
                active_work: false,
                visited_at: None,
            })
        })
        .context("querying T3 Code threads")?;
    let mut threads = Vec::new();
    for row in rows {
        threads.push(row.context("reading T3 Code thread row")?);
    }

    let mut turn_statement = connection
        .prepare(
            "SELECT state, requested_at, started_at, completed_at \
             FROM projection_turns WHERE thread_id = ?1 \
             ORDER BY requested_at DESC LIMIT 1",
        )
        .context("preparing T3 Code turn query")?;
    for thread in &mut threads {
        thread.last_turn = turn_statement
            .query_row([&thread.thread_id], |row| {
                Ok(TurnRow {
                    state: row.get::<_, Option<String>>(0)?.unwrap_or_default(),
                    requested_at: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    started_at: row.get(2)?,
                    completed_at: row.get(3)?,
                })
            })
            .optional()
            .context("reading T3 Code turn row")?;
    }
    Ok(threads)
}

/// Maps T3 Code thread state onto the portal's attention vocabulary. `None`
/// excludes the thread from the roster.
fn classify(row: &ThreadRow, now_ms: u64) -> Option<Classification> {
    if !row.active_work
        && row.pending_approval_count == 0
        && row.pending_user_input_count == 0
        && row
            .snoozed_until
            .as_deref()
            .and_then(timestamp_ms)
            .is_some_and(|until| until > now_ms)
    {
        return None;
    }
    let session_status = row.session_status.as_deref().unwrap_or("stopped");
    let live_session = matches!(session_status, "running" | "ready");
    let settled = row.settled_at.is_some();
    let last_turn = row.last_turn.as_ref();
    if !live_session && (settled || last_turn.is_none()) {
        return None;
    }
    let created_ms = timestamp_ms(&row.created_at).unwrap_or_default();
    let turn_started = last_turn
        .and_then(|turn| {
            turn.started_at
                .as_deref()
                .and_then(timestamp_ms)
                .or_else(|| timestamp_ms(&turn.requested_at))
        })
        .unwrap_or(created_ms);
    let turn_finished = last_turn
        .and_then(|turn| turn.completed_at.as_deref().and_then(timestamp_ms))
        .unwrap_or(turn_started);
    let settled_ms = row
        .settled_at
        .as_deref()
        .and_then(timestamp_ms)
        .unwrap_or(turn_finished);

    let needs_human = row.pending_approval_count > 0
        || row.pending_user_input_count > 0
        || row.has_actionable_proposed_plan;
    if needs_human {
        return Some(Classification {
            status: AgentStatus::Blocked,
            launch_pending: false,
            state_change_seq: turn_started,
            acknowledged: false,
        });
    }

    if row.active_work {
        return Some(Classification {
            status: AgentStatus::Working,
            launch_pending: false,
            state_change_seq: turn_started,
            acknowledged: false,
        });
    }

    let visited = row
        .visited_at
        .as_deref()
        .and_then(timestamp_ms)
        .is_some_and(|visited| visited >= turn_finished);

    let turn_state = last_turn.map(|turn| turn.state.as_str());
    let classification = match (session_status, turn_state) {
        ("running", None) => Classification {
            status: AgentStatus::Working,
            launch_pending: true,
            state_change_seq: created_ms,
            acknowledged: false,
        },
        ("running", Some("running" | "pending")) | (_, Some("running")) => Classification {
            status: AgentStatus::Working,
            launch_pending: false,
            state_change_seq: turn_started,
            acknowledged: false,
        },
        ("error", _) | (_, Some("error")) => Classification {
            status: AgentStatus::Blocked,
            launch_pending: false,
            state_change_seq: turn_finished,
            acknowledged: false,
        },
        (_, Some("completed" | "interrupted")) if settled || visited => Classification {
            status: AgentStatus::Idle,
            launch_pending: false,
            state_change_seq: settled_ms,
            acknowledged: true,
        },
        (_, Some("completed" | "interrupted")) => Classification {
            status: AgentStatus::Done,
            launch_pending: false,
            state_change_seq: turn_finished,
            acknowledged: false,
        },
        ("running", Some(_)) => Classification {
            status: AgentStatus::Working,
            launch_pending: false,
            state_change_seq: turn_started,
            acknowledged: false,
        },
        (_, None) => Classification {
            status: AgentStatus::Idle,
            launch_pending: false,
            state_change_seq: created_ms,
            acknowledged: settled,
        },
        (_, Some(_)) => Classification {
            status: AgentStatus::Unknown,
            launch_pending: false,
            state_change_seq: turn_started,
            acknowledged: false,
        },
    };
    Some(classification)
}

fn timestamp_ms(value: &str) -> Option<u64> {
    let timestamp = OffsetDateTime::parse(value.trim(), &Rfc3339).ok()?;
    let millis = timestamp.unix_timestamp_nanos() / 1_000_000;
    u64::try_from(millis).ok()
}

fn display_name(row: &ThreadRow) -> String {
    let title = sanitize(&row.title, MAX_TITLE_CHARS);
    if title.is_empty() {
        "T3 Code thread".into()
    } else {
        title
    }
}

fn agent_kind(provider: Option<&str>) -> String {
    match provider.map(str::trim) {
        Some("claudeAgent") => "claude".into(),
        Some(value) if !value.is_empty() => {
            let kind: String = value
                .chars()
                .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
                .take(24)
                .collect::<String>()
                .to_ascii_lowercase();
            if kind.is_empty() {
                "agent".into()
            } else {
                kind
            }
        }
        _ => "agent".into(),
    }
}

fn workspace_label(row: &ThreadRow) -> String {
    let project = row
        .project_title
        .as_deref()
        .map(|title| sanitize(title, MAX_LABEL_CHARS))
        .filter(|title| !title.is_empty())
        .or_else(|| {
            row.workspace_root
                .as_deref()
                .and_then(path_leaf)
                .map(|leaf| sanitize(leaf, MAX_LABEL_CHARS))
        })
        .unwrap_or_else(|| "T3 Code".into());
    match row
        .branch
        .as_deref()
        .map(|branch| sanitize(branch, 64))
        .filter(|branch| !branch.is_empty())
    {
        Some(branch) => format!("{project} · {branch}"),
        None => project,
    }
}

fn path_leaf(value: &str) -> Option<&str> {
    Path::new(value.trim())
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
}

fn sanitize(value: &str, limit: usize) -> String {
    value
        .trim()
        .chars()
        .filter(|character| !character.is_control())
        .take(limit)
        .collect::<String>()
        .trim_end()
        .to_owned()
}

fn opaque_agent_id(epoch: &str, thread_id: &str) -> String {
    Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        format!("{epoch}\0{SESSION_NAME}\0{thread_id}").as_bytes(),
    )
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::{TempDir, tempdir};

    const NOW_MS: u64 = 1_788_000_000_000;

    #[test]
    fn metadata_feed_maps_background_waits_and_empty_threads_without_false_review() {
        let snapshot: StatusSnapshot = serde_json::from_value(serde_json::json!({
            "schema_version":1,"environment_id":"env","generated_at_ms":NOW_MS,"threads":[{
                "thread_id":"thread","title":"Thread","project_title":"Project","workspace_root":"/work/project",
                "branch":null,"worktree_path":null,"provider":"codex","status":"idle","settled":false,"snoozed":false,
                "pending_input":false,"background_work":false,"updated_at":"2026-09-11T12:00:00Z",
                "latest_run_completed_at":null,"last_visited_at":null
            }]
        })).unwrap();
        assert_eq!(
            classify(&snapshot.rows()[0], NOW_MS).unwrap().status,
            AgentStatus::Idle
        );
        let mut snapshot = snapshot;
        snapshot.threads[0].status = "waiting".into();
        assert_eq!(
            classify(&snapshot.rows()[0], NOW_MS).unwrap().status,
            AgentStatus::Working
        );
        snapshot.threads[0].pending_input = true;
        assert_eq!(
            classify(&snapshot.rows()[0], NOW_MS).unwrap().status,
            AgentStatus::Blocked
        );
        snapshot.threads[0].pending_input = false;
        snapshot.threads[0].status = "idle".into();
        snapshot.threads[0].background_work = true;
        assert_eq!(
            classify(&snapshot.rows()[0], NOW_MS).unwrap().status,
            AgentStatus::Working
        );
    }

    #[test]
    fn metadata_file_establishes_liveness_without_a_desktop_process_and_expires() {
        let dir = tempdir().unwrap();
        let userdata = dir.path().join("userdata");
        fs::create_dir_all(&userdata).unwrap();
        fs::write(userdata.join("environment-id"), "env").unwrap();
        let path = dir.path().join("metadata.json");
        let frame = serde_json::json!({"schema_version":1,"environment_id":"env","generated_at_ms":NOW_MS,"threads":[]});
        fs::write(&path, frame.to_string()).unwrap();
        let client = T3codeClient::from_config(Some(dir.path()), Some(&path)).unwrap();
        assert_eq!(
            client.observe("epoch", NOW_MS).session.state,
            SessionState::Connected
        );
        assert_eq!(
            client.observe("epoch", NOW_MS + 10_001).session.state,
            SessionState::Stale
        );
        fs::write(
            &path,
            frame
                .to_string()
                .replace("\"env\"", "\"wrong-environment\""),
        )
        .unwrap();
        assert_eq!(
            client.observe("epoch", NOW_MS).session.state,
            SessionState::Stale
        );
        fs::remove_file(&path).unwrap();
        assert!(client.observe("epoch", NOW_MS).targets.is_empty());
    }

    #[test]
    fn current_projection_wins_over_stale_legacy_and_keeps_private_records_out() {
        let fixture = fixture();
        let current = Connection::open(fixture.client.userdata.join("statev2.sqlite")).unwrap();
        current.execute_batch("CREATE TABLE orchestration_v2_projection_metadata(projection_name TEXT,schema_version INTEGER,last_sequence INTEGER);
          INSERT INTO orchestration_v2_projection_metadata VALUES('thread-projections',2,99);
          CREATE TABLE projection_projects(project_id TEXT,title TEXT,workspace_root TEXT,deleted_at TEXT);
          INSERT INTO projection_projects VALUES('p','project','/work/project',NULL);
          CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT,project_id TEXT,title TEXT,provider_instance_id TEXT,default_provider TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,archived_at TEXT,payload_json TEXT);
          CREATE TABLE orchestration_v2_projection_runs(run_id TEXT,thread_id TEXT,status TEXT,ordinal INTEGER,requested_at TEXT,completed_at TEXT,payload_json TEXT);
          CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id TEXT,status TEXT);
          CREATE TABLE orchestration_v2_projection_subagents(thread_id TEXT,status TEXT);
          INSERT INTO orchestration_v2_projection_threads VALUES('current','p','Current thread','codex','codex','2026-09-11T00:00:00Z','2026-09-11T12:00:00Z',NULL,NULL,'{\"branch\":\"main\",\"private\":\"private prompt\"}');
          INSERT INTO orchestration_v2_projection_runs VALUES('run','current','running',1,'2026-09-11T12:00:00Z',NULL,'{\"private\":\"private provider payload\"}');
        ").unwrap();
        let observed = fixture.client.observe("epoch", NOW_MS);
        assert_eq!(observed.session.state, SessionState::Connected);
        assert_eq!(observed.projection_sequence, Some(99));
        assert_eq!(observed.agents.len(), 1);
        assert_eq!(observed.agents[0].status, AgentStatus::Working);
        assert!(
            !serde_json::to_string(&observed.agents)
                .unwrap()
                .contains("private")
        );
        current
            .execute(
                "UPDATE orchestration_v2_projection_runs SET status='queued',payload_json='{}'",
                [],
            )
            .unwrap();
        for payload in [
            "{}",
            r#"{"settledOverride":"settled","settledAt":"2026-09-11T12:06:00Z"}"#,
            r#"{"snoozedUntil":"2099-01-01T00:00:00Z"}"#,
        ] {
            current
                .execute(
                    "UPDATE orchestration_v2_projection_threads SET payload_json=?1",
                    [payload],
                )
                .unwrap();
            assert_eq!(
                fixture.client.observe("epoch", NOW_MS).agents[0].status,
                AgentStatus::Working
            );
        }
        current
            .execute(
                "UPDATE orchestration_v2_projection_runs SET payload_json='{\"queueHeld\":true}'",
                [],
            )
            .unwrap();
        assert!(fixture.client.observe("epoch", NOW_MS).agents.is_empty());
        current
            .execute(
                "UPDATE orchestration_v2_projection_threads SET payload_json='{}'",
                [],
            )
            .unwrap();
        assert_eq!(
            fixture.client.observe("epoch", NOW_MS).agents[0].status,
            AgentStatus::Idle
        );
        current
            .execute(
                "UPDATE orchestration_v2_projection_runs SET status='running',payload_json='{}'",
                [],
            )
            .unwrap();
        current.execute("INSERT INTO orchestration_v2_projection_runtime_requests VALUES('current','pending')",[]).unwrap();
        assert_eq!(
            fixture.client.observe("epoch", NOW_MS).agents[0].status,
            AgentStatus::Blocked
        );
        current
            .execute(
                "DELETE FROM orchestration_v2_projection_runtime_requests",
                [],
            )
            .unwrap();
        current.execute("UPDATE orchestration_v2_projection_runs SET status='completed',completed_at='2026-09-11T12:05:00Z'",[]).unwrap();
        assert_eq!(
            fixture.client.observe("epoch", NOW_MS).agents[0].status,
            AgentStatus::Done
        );
        current.execute("UPDATE orchestration_v2_projection_threads SET payload_json='{\"lastVisitedAt\":\"2026-09-11T12:06:00Z\"}'",[]).unwrap();
        assert_eq!(
            fixture.client.observe("epoch", NOW_MS).agents[0].status,
            AgentStatus::Idle
        );
        current
            .execute(
                "UPDATE orchestration_v2_projection_runs SET status='failed'",
                [],
            )
            .unwrap();
        current.execute("UPDATE orchestration_v2_projection_threads SET payload_json='{\"settledOverride\":\"settled\",\"settledAt\":\"2026-09-11T12:06:00Z\"}'",[]).unwrap();
        assert!(fixture.client.observe("epoch", NOW_MS).agents.is_empty());
        current.execute("INSERT INTO orchestration_v2_projection_runtime_requests VALUES('current','pending')",[]).unwrap();
        assert_eq!(
            fixture.client.observe("epoch", NOW_MS).agents[0].status,
            AgentStatus::Blocked
        );
        current
            .execute(
                "UPDATE orchestration_v2_projection_metadata SET schema_version=999",
                [],
            )
            .unwrap();
        assert_eq!(
            fixture.client.observe("epoch", NOW_MS).session.state,
            SessionState::Incompatible
        );
    }

    #[test]
    fn exact_thread_urls_are_loopback_only_and_escape_target_components() {
        assert_eq!(
            thread_url("http://127.0.0.1:3773", "env", "thread/with?query").unwrap(),
            "http://127.0.0.1:3773/env/thread%2Fwith%3Fquery"
        );
        for origin in [
            "https://evil.test",
            "http://localhost:3773@evil.test:80",
            "http://127.0.0.1:3773/path",
            "http://127.0.0.1:0",
        ] {
            assert!(thread_url(origin, "env", "thread").is_err());
        }
    }

    fn schema() -> &'static str {
        "CREATE TABLE projection_state (projector TEXT PRIMARY KEY, last_applied_sequence INTEGER NOT NULL, updated_at TEXT NOT NULL);
         CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
         CREATE TABLE projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, branch TEXT, worktree_path TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, archived_at TEXT, pending_approval_count INTEGER NOT NULL DEFAULT 0, pending_user_input_count INTEGER NOT NULL DEFAULT 0, has_actionable_proposed_plan INTEGER NOT NULL DEFAULT 0, settled_at TEXT, snoozed_until TEXT);
         CREATE TABLE projection_thread_sessions (thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, provider_name TEXT, active_turn_id TEXT, updated_at TEXT NOT NULL);
         CREATE TABLE projection_turns (row_id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL, turn_id TEXT, state TEXT NOT NULL, requested_at TEXT NOT NULL, started_at TEXT, completed_at TEXT);
         CREATE TABLE projection_thread_messages (message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL);
         INSERT INTO projection_state VALUES ('projection.threads', 41, '2026-09-11T00:00:00.000Z');
         INSERT INTO projection_projects VALUES ('project-a', 'xeneon-edge-agents', '/home/user/src/xeneon-edge-agents', '2026-09-01T00:00:00.000Z', '2026-09-11T10:00:00.000Z', NULL);
         INSERT INTO projection_projects VALUES ('project-b', 'omabot', '/home/user/src/omabot', '2026-09-01T00:00:00.000Z', '2026-09-10T10:00:00.000Z', NULL);"
    }

    struct Fixture {
        _dir: TempDir,
        client: T3codeClient,
        connection: Connection,
    }

    fn fixture() -> Fixture {
        let dir = tempdir().unwrap();
        let userdata = dir.path().join("userdata");
        fs::create_dir_all(&userdata).unwrap();
        let connection = Connection::open(userdata.join("state.sqlite")).unwrap();
        connection.execute_batch(schema()).unwrap();
        write_runtime(&userdata, i64::from(std::process::id()), 1);
        Fixture {
            client: T3codeClient::new(dir.path()).without_process_identity(),
            _dir: dir,
            connection,
        }
    }

    fn write_runtime(userdata: &Path, pid: i64, version: u32) {
        fs::write(
            userdata.join("server-runtime.json"),
            format!("{{\"version\":{version},\"pid\":{pid},\"host\":\"127.0.0.1\",\"port\":3773}}"),
        )
        .unwrap();
    }

    #[allow(clippy::too_many_arguments)]
    fn thread(
        connection: &Connection,
        thread_id: &str,
        project: &str,
        title: &str,
        session_status: Option<&str>,
        turn: Option<(&str, &str, Option<&str>, Option<&str>)>,
        settled_at: Option<&str>,
        pending: (i64, i64, i64),
    ) {
        connection
            .execute(
                "INSERT INTO projection_threads (thread_id, project_id, title, branch, worktree_path, created_at, updated_at, pending_approval_count, pending_user_input_count, has_actionable_proposed_plan, settled_at) VALUES (?1, ?2, ?3, 'main', NULL, '2026-09-11T09:00:00.000Z', '2026-09-11T11:00:00.000Z', ?4, ?5, ?6, ?7)",
                rusqlite::params![thread_id, project, title, pending.0, pending.1, pending.2, settled_at],
            )
            .unwrap();
        if let Some(status) = session_status {
            connection
                .execute(
                    "INSERT INTO projection_thread_sessions VALUES (?1, ?2, 'claudeAgent', NULL, '2026-09-11T11:00:00.000Z')",
                    rusqlite::params![thread_id, status],
                )
                .unwrap();
        }
        if let Some((state, requested, started, completed)) = turn {
            connection
                .execute(
                    "INSERT INTO projection_turns (thread_id, turn_id, state, requested_at, started_at, completed_at) VALUES (?1, 'turn', ?2, ?3, ?4, ?5)",
                    rusqlite::params![thread_id, state, requested, started, completed],
                )
                .unwrap();
        }
    }

    fn agent_by_name<'a>(observation: &'a T3codeObservation, name: &str) -> &'a AgentView {
        observation
            .agents
            .iter()
            .find(|agent| agent.display_name == name)
            .unwrap_or_else(|| panic!("missing agent {name}"))
    }

    #[test]
    fn missing_runtime_descriptor_is_offline_without_reading_state() {
        let dir = tempdir().unwrap();
        let client = T3codeClient::new(dir.path()).without_process_identity();
        let observation = client.observe("epoch", NOW_MS);
        assert_eq!(observation.session.state, SessionState::Offline);
        assert!(observation.agents.is_empty());
        assert_eq!(observation.projection_sequence, None);
    }

    #[test]
    fn exited_server_process_is_offline_even_with_readable_state() {
        let fixture = fixture();
        thread(
            &fixture.connection,
            "thread-1",
            "project-a",
            "Live thread",
            Some("running"),
            Some((
                "running",
                "2026-09-11T10:59:00.000Z",
                Some("2026-09-11T10:59:00.000Z"),
                None,
            )),
            None,
            (0, 0, 0),
        );
        write_runtime(&fixture.client.userdata, i64::MAX - 1, 1);
        let observation = fixture.client.observe("epoch", NOW_MS);
        assert_eq!(observation.session.state, SessionState::Offline);
        assert!(observation.agents.is_empty());
        assert!(observation.targets.is_empty());
    }

    #[test]
    fn unsupported_runtime_descriptor_is_incompatible() {
        let fixture = fixture();
        write_runtime(&fixture.client.userdata, i64::from(std::process::id()), 2);
        let observation = fixture.client.observe("epoch", NOW_MS);
        assert_eq!(observation.session.state, SessionState::Incompatible);
        assert_eq!(observation.session.protocol, Some(2));
        assert!(observation.agents.is_empty());
    }

    #[test]
    fn roster_maps_thread_state_onto_portal_attention() {
        let fixture = fixture();
        let connection = &fixture.connection;
        thread(
            connection,
            "working",
            "project-a",
            "Working turn",
            Some("running"),
            Some((
                "running",
                "2026-09-11T10:59:00.000Z",
                Some("2026-09-11T10:59:30.000Z"),
                None,
            )),
            None,
            (0, 0, 0),
        );
        thread(
            connection,
            "launching",
            "project-a",
            "Launching",
            Some("running"),
            None,
            None,
            (0, 0, 0),
        );
        thread(
            connection,
            "approval",
            "project-a",
            "Needs approval",
            Some("running"),
            Some((
                "running",
                "2026-09-11T10:50:00.000Z",
                Some("2026-09-11T10:50:00.000Z"),
                None,
            )),
            None,
            (1, 0, 0),
        );
        thread(
            connection,
            "question",
            "project-b",
            "Needs answer",
            Some("ready"),
            Some((
                "completed",
                "2026-09-11T10:40:00.000Z",
                Some("2026-09-11T10:40:00.000Z"),
                Some("2026-09-11T10:45:00.000Z"),
            )),
            None,
            (0, 1, 0),
        );
        thread(
            connection,
            "plan",
            "project-b",
            "Plan decision",
            Some("stopped"),
            Some((
                "completed",
                "2026-09-11T10:30:00.000Z",
                Some("2026-09-11T10:30:00.000Z"),
                Some("2026-09-11T10:35:00.000Z"),
            )),
            None,
            (0, 0, 1),
        );
        thread(
            connection,
            "review",
            "project-b",
            "Review me",
            Some("stopped"),
            Some((
                "completed",
                "2026-09-11T10:20:00.000Z",
                Some("2026-09-11T10:20:00.000Z"),
                Some("2026-09-11T10:25:00.000Z"),
            )),
            None,
            (0, 0, 0),
        );
        thread(
            connection,
            "settled-live",
            "project-b",
            "Settled ready",
            Some("ready"),
            Some((
                "completed",
                "2026-09-11T10:10:00.000Z",
                Some("2026-09-11T10:10:00.000Z"),
                Some("2026-09-11T10:15:00.000Z"),
            )),
            Some("2026-09-11T10:16:00.000Z"),
            (0, 0, 0),
        );
        thread(
            connection,
            "settled-stopped",
            "project-b",
            "Settled stopped",
            Some("stopped"),
            Some((
                "completed",
                "2026-09-11T10:00:00.000Z",
                Some("2026-09-11T10:00:00.000Z"),
                Some("2026-09-11T10:05:00.000Z"),
            )),
            Some("2026-09-11T10:06:00.000Z"),
            (0, 0, 0),
        );
        thread(
            connection,
            "failed",
            "project-b",
            "Failed turn",
            Some("stopped"),
            Some((
                "error",
                "2026-09-11T09:50:00.000Z",
                Some("2026-09-11T09:50:00.000Z"),
                Some("2026-09-11T09:51:00.000Z"),
            )),
            None,
            (0, 0, 0),
        );
        thread(
            connection,
            "empty",
            "project-b",
            "Empty thread",
            None,
            None,
            None,
            (0, 0, 0),
        );

        let observation = fixture.client.observe("epoch", NOW_MS);
        assert_eq!(observation.session.state, SessionState::Connected);
        assert_eq!(observation.session.name, "t3code");
        assert_eq!(observation.session.protocol, Some(1));
        assert_eq!(observation.projection_sequence, Some(41));

        let names: Vec<_> = observation
            .agents
            .iter()
            .map(|agent| agent.display_name.as_str())
            .collect();
        assert!(!names.contains(&"Settled stopped"));
        assert!(!names.contains(&"Empty thread"));
        assert_eq!(names.len(), 8);

        let working = agent_by_name(&observation, "Working turn");
        assert_eq!(working.status, AgentStatus::Working);
        assert!(!working.launch_pending);
        assert_eq!(
            working.state_change_seq,
            timestamp_ms("2026-09-11T10:59:30.000Z").unwrap()
        );
        assert_eq!(working.agent, "claude");
        assert_eq!(working.workspace, "xeneon-edge-agents · main");
        assert_eq!(working.repository.as_deref(), Some("xeneon-edge-agents"));
        assert_eq!(working.worktree, None);
        assert_eq!(working.session, "t3code");
        assert!(!working.focused);
        assert!(working.actions.open);
        assert!(!working.actions.zoom);
        assert!(working.actions.approve.is_none());
        assert!(working.actions.interrupt.is_none());

        let launching = agent_by_name(&observation, "Launching");
        assert_eq!(launching.status, AgentStatus::Working);
        assert!(launching.launch_pending);

        for name in [
            "Needs approval",
            "Needs answer",
            "Plan decision",
            "Failed turn",
        ] {
            assert_eq!(
                agent_by_name(&observation, name).status,
                AgentStatus::Blocked,
                "{name}"
            );
        }

        let review = agent_by_name(&observation, "Review me");
        assert_eq!(review.status, AgentStatus::Done);
        assert_eq!(
            review.state_change_seq,
            timestamp_ms("2026-09-11T10:25:00.000Z").unwrap()
        );
        assert!(!observation.targets[&review.id].acknowledged);

        let settled = agent_by_name(&observation, "Settled ready");
        assert_eq!(settled.status, AgentStatus::Idle);
        assert!(observation.targets[&settled.id].acknowledged);
        assert_eq!(
            settled.state_change_seq,
            timestamp_ms("2026-09-11T10:16:00.000Z").unwrap()
        );

        // Project order is newest project first, then newest thread; source
        // order follows the roster index.
        assert_eq!(observation.agents[0].workspace, "xeneon-edge-agents · main");
        assert!(
            observation
                .agents
                .iter()
                .enumerate()
                .all(|(index, agent)| agent.source_order == index)
        );
    }

    #[test]
    fn snoozed_archived_and_deleted_threads_leave_the_roster() {
        let fixture = fixture();
        let connection = &fixture.connection;
        thread(
            connection,
            "snoozed",
            "project-a",
            "Snoozed",
            Some("ready"),
            Some((
                "completed",
                "2026-09-11T10:20:00.000Z",
                None,
                Some("2026-09-11T10:25:00.000Z"),
            )),
            None,
            (0, 0, 0),
        );
        connection
            .execute(
                "UPDATE projection_threads SET snoozed_until = '2999-01-01T00:00:00.000Z' WHERE thread_id = 'snoozed'",
                [],
            )
            .unwrap();
        thread(
            connection,
            "archived",
            "project-a",
            "Archived",
            Some("running"),
            Some(("running", "2026-09-11T10:20:00.000Z", None, None)),
            None,
            (0, 0, 0),
        );
        connection
            .execute(
                "UPDATE projection_threads SET archived_at = '2026-09-11T10:30:00.000Z' WHERE thread_id = 'archived'",
                [],
            )
            .unwrap();
        thread(
            connection,
            "deleted",
            "project-a",
            "Deleted",
            Some("running"),
            Some(("running", "2026-09-11T10:20:00.000Z", None, None)),
            None,
            (0, 0, 0),
        );
        connection
            .execute(
                "UPDATE projection_threads SET deleted_at = '2026-09-11T10:30:00.000Z' WHERE thread_id = 'deleted'",
                [],
            )
            .unwrap();
        thread(
            connection,
            "expired-snooze",
            "project-a",
            "Woke up",
            Some("ready"),
            Some((
                "completed",
                "2026-09-11T10:20:00.000Z",
                None,
                Some("2026-09-11T10:25:00.000Z"),
            )),
            None,
            (0, 0, 0),
        );
        connection
            .execute(
                "UPDATE projection_threads SET snoozed_until = '2020-01-01T00:00:00.000Z' WHERE thread_id = 'expired-snooze'",
                [],
            )
            .unwrap();

        let observation = fixture.client.observe("epoch", NOW_MS);
        let names: Vec<_> = observation
            .agents
            .iter()
            .map(|agent| agent.display_name.as_str())
            .collect();
        assert_eq!(names, ["Woke up"]);
    }

    #[test]
    fn card_identity_is_bounded_and_never_reads_messages() {
        let fixture = fixture();
        let connection = &fixture.connection;
        let hostile_title = format!("  {}\u{7}\n<img src=x>", "x".repeat(400));
        thread(
            connection,
            "hostile",
            "project-a",
            &hostile_title,
            Some("running"),
            Some(("running", "2026-09-11T10:20:00.000Z", None, None)),
            None,
            (0, 0, 0),
        );
        thread(
            connection,
            "blank",
            "project-a",
            "   ",
            Some("running"),
            Some(("running", "2026-09-11T10:20:00.000Z", None, None)),
            None,
            (0, 0, 0),
        );
        connection
            .execute(
                "INSERT INTO projection_thread_messages VALUES ('m1', 'hostile', 'user', 'private prompt text')",
                [],
            )
            .unwrap();

        let observation = fixture.client.observe("epoch", NOW_MS);
        let hostile = observation
            .agents
            .iter()
            .find(|agent| agent.display_name.starts_with('x'))
            .unwrap();
        assert_eq!(hostile.display_name.chars().count(), MAX_TITLE_CHARS);
        assert!(!hostile.display_name.contains('\u{7}'));
        assert!(
            observation
                .agents
                .iter()
                .any(|agent| agent.display_name == "T3 Code thread")
        );
        let encoded = serde_json::to_string(&observation.agents).unwrap();
        assert!(!encoded.contains("private prompt text"));
    }

    #[test]
    fn schema_drift_is_incompatible_rather_than_guessed() {
        let fixture = fixture();
        fixture
            .connection
            .execute_batch("DROP TABLE projection_thread_sessions;")
            .unwrap();
        let observation = fixture.client.observe("epoch", NOW_MS);
        assert_eq!(observation.session.state, SessionState::Incompatible);
        assert!(observation.agents.is_empty());
        assert_eq!(
            observation.session.message.as_deref(),
            Some("T3 Code state schema is unsupported")
        );
    }

    #[test]
    fn projection_sequence_is_a_cheap_change_signal() {
        let fixture = fixture();
        assert_eq!(fixture.client.projection_sequence().unwrap(), Some(41));
        fixture
            .connection
            .execute("UPDATE projection_state SET last_applied_sequence = 42", [])
            .unwrap();
        assert_eq!(fixture.client.projection_sequence().unwrap(), Some(42));
    }

    #[test]
    fn opaque_ids_are_stable_per_epoch_and_thread() {
        let fixture = fixture();
        thread(
            &fixture.connection,
            "thread-1",
            "project-a",
            "Thread",
            Some("running"),
            Some(("running", "2026-09-11T10:20:00.000Z", None, None)),
            None,
            (0, 0, 0),
        );
        let first = fixture.client.observe("epoch-a", NOW_MS);
        let second = fixture.client.observe("epoch-a", NOW_MS + 1_000);
        let other = fixture.client.observe("epoch-b", NOW_MS);
        assert_eq!(first.agents[0].id, second.agents[0].id);
        assert_ne!(first.agents[0].id, other.agents[0].id);
        assert!(!first.agents[0].id.contains("thread-1"));
        assert_eq!(first.targets[&first.agents[0].id].thread_id, "thread-1");
    }

    #[test]
    fn provider_names_become_bounded_agent_kinds() {
        assert_eq!(agent_kind(Some("claudeAgent")), "claude");
        assert_eq!(agent_kind(Some("codex")), "codex");
        assert_eq!(agent_kind(Some("Open Code!")), "opencode");
        assert_eq!(agent_kind(Some("   ")), "agent");
        assert_eq!(agent_kind(None), "agent");
    }
}
