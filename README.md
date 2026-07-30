# XENEON EDGE Agent Command Center

A native Omarchy command center for the Corsair XENEON EDGE. It keeps Herdr as
the session and interaction authority while providing a dedicated 2560x720
touch surface for agent status, safe triage, and compact system health.

The project is intentionally simulator-first because the physical display is
not currently connected. Production output matching is fail-closed: the portal
will not appear on the laptop display when the configured XENEON is absent.

## Components

- `xeneon-agentd`: Rust user daemon for Herdr state, host health, safe actions,
  reconnects, and output/focus integration.
- `xeneon-agentctl qml-bridge`: NDJSON bridge used by Quickshell.
- `quickshell/`: standalone touch portal and deterministic fixture preview.
- `config/` and `scripts/`: reversible user-service and Omarchy integration.

See `TODO.md` for the active implementation ledger and verification gates.
