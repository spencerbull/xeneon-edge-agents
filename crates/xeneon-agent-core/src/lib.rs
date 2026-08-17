pub mod config;
pub mod desktop;
pub mod health;
pub mod herdr;
pub mod micro;
pub mod model;
pub mod protocol;
pub mod runtime;
pub mod usage;
pub mod voice;

pub use config::Config;
pub use model::{
    ActionCapability, ActionKind, ActionResult, AgentActions, AgentOrderMode, AgentOrderSnapshot,
    AgentStatus, AgentView, AiUsageSnapshot, ConnectionState, HealthSnapshot, Metric,
    MicroSnapshot, PortalCommand, PortalSnapshot, ProviderUsage, ServerMessage, SessionState,
    SessionView, UsageKind, UsageWindow, VoiceSnapshot, VoiceState,
};
pub use runtime::{DaemonRuntime, socket_path};
pub use voice::cleanup_owned_dictation;
