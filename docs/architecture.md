# Architecture

## Trust boundary

Herdr owns terminal identity, agent detection, and agent actions.
`xeneon-agentd` owns aggregation, reconnects, host health, normalized AI
capacity, desktop routing, read-only Codex Micro status, and the portal's
narrow action policy. It also owns the optional Voxtype start/stop/cancel
boundary and a private per-daemon dictation marker.
Quickshell owns rendering and touch gesture state only.

The portal's project-owned theme reader consumes only Omarchy's current
presentation palette under `$XDG_STATE_HOME/omarchy/current`. Omarchy replaces
the theme directory atomically, so QML watches the stable `theme.name` beacon
and then reopens `theme/colors.toml`. Parsing is allowlisted and fail-soft:
invalid or absent colors use bundled presentation defaults. Working, blocked,
review, and error meaning maps respectively to the active theme's blue,
yellow, green, and red roles. Theme selection never changes daemon state,
Herdr actions, output identity, or touch mapping.
Light desktop palettes are mapped to a dark-adaptive command surface and small
semantic text roles are normalized to at least 4.5:1 contrast against their
surface; primary text targets 7:1.

```text
Herdr public sockets     /proc, /sys, Hyprland
AI usage records/DB        Voxtype, microd
          \                    /
                 xeneon-agentd
                       |
       0600 Unix socket, schema-v1 NDJSON
                       |
             xeneon-agentctl qml-bridge
                       |
           standalone Quickshell portal
```

The daemon has no network listener. It discovers all running local Herdr
sessions with `herdr session list --json`, uses one-shot public socket requests
for reads and actions, and keeps one acknowledged event subscription per
session. It subscribes to lifecycle, focus, and agent-state events, omitting
high-volume pane-content, layout, and metadata updates. Related event bursts
are coalesced for 200 ms before one authoritative reconciliation; a five-second
reconciliation remains as the repair path.

## Identity and stale-state handling

Portal agent IDs are UUIDv5 values derived from the daemon epoch, Herdr session,
and live terminal identity. The current pane ID remains private action-routing
state. Restarting the daemon invalidates every ID. Herdr disconnects immediately
remove action targets and guarded capabilities.

The adapter reads Herdr's durable `grouped`/`priority` agent-order mode on each
normal reconciliation. The portal can request only those two typed values;
the daemon applies them through `agent.order.set` and reorders the normalized
cards from the returned authoritative state. An older Herdr without that API
keeps agent telemetry working but exposes ordering as unavailable.

Card names use Herdr's tab identity rather than terminal or prompt text. The
daemon joins an agent's `tab_id` to the snapshot's tab label, with only
`display_agent`, agent `name`, and canonical agent fallbacks.

The review-ready latch follows the Codex Micro contract. A working agent that
becomes idle remains review-ready until a new Herdr focus transition selects it
or a portal open succeeds. Merely remaining focused does not acknowledge it.

Snapshots carry an action-state sequence. Host-health refreshes do not advance
that sequence, so an 800 ms hold is not invalidated by an unrelated CPU sample.
Agent topology or state reconciliation does advance it.

AI capacity and Micro refreshes do not advance the action sequence or count as
portal interaction, so they cannot invalidate a guarded action or wake the
ambient surface. Usage collection prefers the bounded schema-v1 Claude/Codex
records produced by Omarchy, retains the former cache contract for transition
compatibility, and reads only bounded aggregate input, output, reasoning, and
cache-write counters from OpenCode's local
SQLite message ledger to derive its soft-budget windows. The daemon allowlists
provider IDs, record versions, status values, and safe metadata, clamps
utilization and aggregate token activity, rejects oversized files and scans,
and never forwards credentials, prompts, message contents, per-model history,
or raw provider payloads.

Micro collection uses one fixed read-only `device.status` request on the
user-private local microd socket. Connected state requires a valid device
status object with the device firmware identity; a socket or malformed response
never proves hardware presence. QML receives only bounded battery, firmware,
layer, and profile fields and has no method for sending Micro commands.

Input actions are never queued or replayed. Focus and zoom are resolved against
the latest private pane target. Approval and interruption require an opaque,
single-use capability issued and revalidated by a compatible Herdr server.

## Voice boundary

The low-cost voice collector reads only
`$XDG_RUNTIME_DIR/voxtype/state`. `recording` stays recording,
`streaming`/`transcribing` normalize to processing, and a missing or unreadable
file is unavailable. Voice commands execute only the typed `voxtype record`
operations. They are never retried and their output is discarded. Each process
is bounded to ten seconds and killed on timeout; an ambiguous failed start gets
one conservative cancel attempt before ownership is released.

Before start, the daemon requires idle state and atomically creates
`$XDG_STATE_HOME/xeneon-edge-agents/dictation-active`. Stop and cancel require
the exact current daemon token. The service's start/stop cleanup path cancels a
stale portal-owned recording before removing its marker. QML cannot execute
Voxtype or arbitrary host commands.

The production layer surface is non-focusable, so dictation keeps the
previously focused application as its typing target. The explicit floating
live preview restores the daemon's last exact non-portal focus before both
voice start and stop, allowing laptop testing without making the preview
window the transcription target.

## Desktop boundary

The production QML process creates no window unless one configured output
identity matches. It does not use a primary-screen fallback.

Hyprland activation is session-specific. The daemon considers only compositor
clients whose process trees contain the exact Herdr session or socket identity;
ambiguous matches fail instead of focusing a generic window title.

ChatGPT Desktop and Claude Desktop use separate fixed action kinds. The daemon
matches exact known compositor classes: one match is focused, no match launches
the corresponding fixed desktop entry through `uwsm-app`, and multiple matches
fail closed. Launches are coalesced per app while the daemon waits a bounded
time for exactly one mapped client, then focuses it before reporting success.
QML cannot choose an executable, desktop entry, class, title, or arguments.

Passive EDGE gestures may request restoration of the last observed non-EDGE
window. The daemon first confirms that the exact window address still exists.
This behavior remains a physical-touch validation gate because Hyprland changes
its focused monitor on touchscreen contact.
