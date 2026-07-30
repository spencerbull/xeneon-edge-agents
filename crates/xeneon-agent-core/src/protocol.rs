use thiserror::Error;

use crate::model::{ActionKind, AgentView, PortalCommand, SCHEMA_VERSION};

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CommandError {
    #[error("unsupported portal schema version {0}")]
    UnsupportedSchema(u32),
    #[error("request_id is required")]
    MissingRequestId,
    #[error("agent_id is required for this action")]
    MissingAgentId,
    #[error("capability_id is required for guarded actions")]
    MissingCapability,
    #[error("capability_id is not accepted for this action")]
    UnexpectedCapability,
}

pub fn validate_command(command: &PortalCommand) -> Result<(), CommandError> {
    if command.schema_version != SCHEMA_VERSION {
        return Err(CommandError::UnsupportedSchema(command.schema_version));
    }
    if command.request_id.trim().is_empty() {
        return Err(CommandError::MissingRequestId);
    }

    match command.action {
        ActionKind::RestoreFocus => {
            if command.capability_id.is_some() {
                return Err(CommandError::UnexpectedCapability);
            }
        }
        ActionKind::Open | ActionKind::Zoom => {
            if command.agent_id.is_none() {
                return Err(CommandError::MissingAgentId);
            }
            if command.capability_id.is_some() {
                return Err(CommandError::UnexpectedCapability);
            }
        }
        ActionKind::Approve | ActionKind::Interrupt => {
            if command.agent_id.is_none() {
                return Err(CommandError::MissingAgentId);
            }
            if command.capability_id.is_none() {
                return Err(CommandError::MissingCapability);
            }
        }
    }

    Ok(())
}

pub fn command_capability_matches(command: &PortalCommand, agent: &AgentView) -> bool {
    let expected = match command.action {
        ActionKind::Approve => agent.actions.approve.as_ref(),
        ActionKind::Interrupt => agent.actions.interrupt.as_ref(),
        _ => return true,
    };

    expected
        .zip(command.capability_id.as_ref())
        .is_some_and(|(capability, supplied)| capability.capability_id == *supplied)
}

#[cfg(test)]
mod tests {
    use crate::model::{AgentActions, AgentStatus};

    use super::*;

    fn command(action: ActionKind) -> PortalCommand {
        PortalCommand {
            schema_version: SCHEMA_VERSION,
            request_id: "request".into(),
            sequence: 7,
            agent_id: Some("agent".into()),
            action,
            capability_id: None,
        }
    }

    #[test]
    fn raw_approve_without_capability_is_rejected() {
        assert_eq!(
            validate_command(&command(ActionKind::Approve)),
            Err(CommandError::MissingCapability)
        );
    }

    #[test]
    fn restore_focus_does_not_require_agent() {
        let mut command = command(ActionKind::RestoreFocus);
        command.agent_id = None;
        assert_eq!(validate_command(&command), Ok(()));
    }

    #[test]
    fn capability_must_match_current_agent_snapshot() {
        let mut command = command(ActionKind::Approve);
        command.capability_id = Some("stale".into());
        let agent = AgentView {
            id: "agent".into(),
            display_name: "Agent".into(),
            agent: "codex".into(),
            status: AgentStatus::Blocked,
            workspace: "workspace".into(),
            repository: None,
            worktree: None,
            session: "default".into(),
            focused: false,
            observed_for_seconds: 0,
            source_order: 0,
            actions: AgentActions {
                open: true,
                zoom: true,
                approve: Some(crate::model::ActionCapability {
                    capability_id: "current".into(),
                    kind: ActionKind::Approve,
                    expires_at_ms: u64::MAX,
                    expected_revision: 2,
                }),
                interrupt: None,
            },
        };

        assert!(!command_capability_matches(&command, &agent));
    }
}
