pub mod config;
pub mod desktop;
pub mod health;
pub mod herdr;
pub mod model;
pub mod protocol;
pub mod runtime;

pub use config::Config;
pub use model::{
    ActionCapability, ActionKind, ActionResult, AgentActions, AgentStatus, AgentView,
    ConnectionState, HealthSnapshot, Metric, PortalCommand, PortalSnapshot, ServerMessage,
    SessionState, SessionView,
};
pub use runtime::{DaemonRuntime, socket_path};
