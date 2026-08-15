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
  "agent_order": {"available": true, "mode": "grouped"},
  "voice": {"state": "unavailable", "owned": false},
  "usage": {
    "providers": [
      {
        "id": "codex",
        "label": "CODEX",
        "kind": "quota",
        "available": true,
        "stale": false,
        "source": "rpc",
        "status": "allowed",
        "plan": "pro",
        "primary": {"label": "WEEKLY", "utilization": 0.74},
        "today_tokens": 53960987620,
        "tokens_per_hour": 1778512401
      }
    ]
  },
  "micro": {"connected": true, "battery": 45, "charging": false},
  "health": {}
}
```

Agent statuses are exactly `blocked`, `done`, `working`, `idle`, or `unknown`.
`review_ready` is a separate attention latch: explicit `done` and
`working`→`idle` set it, authoritative `blocked`, `working`, or `unknown`
clear it, and `idle` otherwise preserves it. A new Herdr focus transition to
that agent or a successful portal `open` acknowledges it.

Agent `display_name` comes from the matching nonblank Herdr tab label, then the
safe `display_agent`, agent `name`, and canonical agent identifier fallbacks.
Terminal titles and prompt-derived content are never display-name sources.
Optional `repository` and `worktree` values are sanitized checkout identity,
not terminal content. `launch_pending` means Herdr has observed a launch request
without yet observing a live agent; it is not treated as an agent state.
`state_change_seq` is Herdr's monotonic state-change ordering scalar. Priority
mode uses it descending within the same attention bucket so the EDGE and Herdr
panels retain the same tie ordering; grouped mode continues to use Space order.

Voice state is exactly `idle`, `recording`, `processing`, `error`, or
`unavailable`. `owned` says only whether this daemon instance owns the private
dictation marker; snapshots never carry transcripts, tooltips, command output,
or voice errors from stderr.

`usage` exposes only normalized provider capacity and coarse aggregate
activity. Utilization is a fraction from 0 through 1; reset timestamps, plan,
model, `today_tokens`, and `tokens_per_hour` are optional bounded metadata.
The aggregate token fields are provider-wide local activity totals, not
per-request records. Usage never includes credentials, prompts, message
contents, per-model history, cache/database contents, or provider response
bodies. `micro` is a
read-only normalized view of the local Codex Micro connection and optional
device status. It never exposes the Micro socket protocol to QML.

These additive v1 fields are optional for compatibility with older recorded
fixtures. Clients default voice to unavailable, review-ready and launch-pending
to false (except a legacy raw `done` agent), usage to an empty provider list,
Micro to disconnected, and ordering to unavailable. When ordering is available,
`grouped` preserves Herdr Space order and `priority` promotes attention states.
Connection and action failures are separate fields, not invented agent states.
Unavailable health metrics use `available: false` and omit `value`; they are
never encoded as a false zero.

The Herdr adapter accepts protocol 20 from the Omarchy Herdr v0.8.0.r13 base.
A different value from `ping` produces
an `incompatible` session with no agents, targets, actions, snapshot request,
or event subscription; the daemon does not guess compatibility across a Herdr
protocol boundary.

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
`session_disconnected`, `target_unavailable`, `voice_unavailable`,
`voice_busy`, `voice_not_owned`, and `command_error`.

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
- `voice_start`: takes no agent or capability, requires Voxtype to report
  `idle`, claims the daemon's private ownership marker, and starts typed
  dictation without automatic submission.
- `voice_stop`: takes no agent or capability and stops only a recording owned
  by this daemon instance.
- `voice_cancel`: takes no agent or capability and discards only a recording
  owned by this daemon instance.
- `chatgpt_desktop`: takes no agent or capability and focuses the single exact
  ChatGPT Desktop compositor client, or launches its fixed desktop entry when
  none exists.
- `claude_desktop`: takes no agent or capability and applies the same
  focus-or-launch policy to the fixed Claude Desktop identity.
- `order_grouped` and `order_priority`: take no agent or capability and apply
  one typed, idempotent ordering value through Herdr's public API. The daemon
  polls the same authoritative Herdr setting, so changes made in either UI
  converge without a portal-owned preference.

There is no method, key, text, shell-command, prompt, close, or server-control
passthrough. Desktop actions do not accept a desktop ID, executable, title,
class, or argument from QML, and ambiguous compositor matches fail closed.
Voice actions are single-attempt operations and return only
bounded static result messages. Host commands have a ten-second ceiling; a
failed or timed-out start may issue one distinct cancel cleanup attempt but is
never retried. Their `sequence` field is carried for one
command shape but is not used as a stale gate: a press/release hold may span
unrelated snapshots, and ownership plus live Voxtype state are authoritative.
