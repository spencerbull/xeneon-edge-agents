# Portal protocol v1

The daemon socket and QML bridge exchange one JSON object per line. Unknown
fields must be ignored within schema version 1. Unknown message types or schema
versions must be rejected.

## Server messages

`snapshot` is a complete, keyed replacement:

```json
{
  "type": "snapshot",
  "schema_version": 1,
  "sequence": 8,
  "daemon_epoch": "2dc2c8f0-47db-4806-b8d8-a45baa7d47d6",
  "generated_at_ms": 1785384000000,
  "connection": "connected",
  "sessions": [],
  "agents": [],
  "health": {}
}
```

Agent statuses are exactly `blocked`, `done`, `working`, `idle`, or `unknown`.
Connection and action failures are separate fields, not invented agent states.
Unavailable health metrics use `available: false` and omit `value`; they are
never encoded as a false zero.

`action_result` acknowledges one command:

```json
{
  "type": "action_result",
  "schema_version": 1,
  "request_id": "touch-42",
  "ok": false,
  "code": "stale_snapshot",
  "message": "the portal snapshot changed before the action"
}
```

Stable failure codes include `invalid_command`, `stale_snapshot`,
`capability_expired`, `agent_state_changed`, `unsupported_protocol`,
`session_disconnected`, `target_unavailable`, and `command_error`.

## Client commands

```json
{
  "type": "command",
  "schema_version": 1,
  "request_id": "touch-42",
  "sequence": 8,
  "agent_id": "3e676d4c-4bbb-5d14-bc88-e040c176a84a",
  "action": "open"
}
```

The only actions are:

- `open`: focus the fresh agent target and activate its exact Herdr client.
- `zoom`: toggle the fresh pane's Herdr zoom state.
- `approve` and `interrupt`: require the capability ID present in the same
  current snapshot. The daemon forwards only that opaque ID.
- `restore_focus`: takes no agent or capability and restores a previously
  observed non-EDGE window if it still exists.

There is no method, key, text, shell-command, prompt, close, or server-control
passthrough.
