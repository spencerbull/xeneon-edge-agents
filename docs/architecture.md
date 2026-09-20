# Architecture

## Trust boundary

One agent manager at a time is authoritative for agent identity, detection,
and actions: Herdr through its public sockets, or T3 Code through its
read-only local state. `xeneon-agentd` owns which manager is active,
aggregation, reconnects, host health, normalized AI capacity, desktop routing,
read-only Codex Micro status, and the portal's narrow action policy. It also owns the optional Voxtype start/stop/cancel
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

The user-owned portal preferences persist only allowlisted Omarchy role names
for nine XENEON meanings: Ready, Success, Working, Needs Help, Review Ready,
Error, Unknown, Recording, and Processing. A presentation-only mapped-theme object
resolves those names against the current live palette, so switching the
Omarchy theme preserves the mapping intent while replacing every source hue.
Invalid or missing selections fail closed to the reviewed defaults. The editor
cannot store arbitrary colors or alter background, surface, or text roles.

```text
Herdr public sockets     /proc, /sys, Hyprland
T3 Code read-only state    Voxtype, microd
AI usage records/DB
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

## Agent manager selection

The portal snapshot carries `backend.mode` (`herdr` or `t3code`) and the daemon
accepts two typed, sequence-gated commands, `backend_herdr` and
`backend_t3code`. A switch clears every card, private target, review latch,
focus-history entry, and Herdr event subscription before the next manager is
observed, publishes a reconnecting snapshot, and persists the choice
atomically to `$XDG_STATE_HOME/xeneon-edge-agents/agent-backend.toml` with
mode 0600. On startup the persisted choice wins over the configured
`agent_backend` default. QML renders only the manager's name; it cannot choose
a binary, socket, path, or query.

## T3 Code adapter

T3 Code keeps its orchestration state in a SQLite projection under its data
directory (`$T3CODE_HOME`, then `~/.t3`). The adapter opens
`userdata/state.sqlite` read-only and reads only `projection_threads`,
`projection_thread_sessions`, `projection_turns`, `projection_projects`, and
`projection_state`. It never reads messages, activities, checkpoints, secrets,
proposed-plan text, or provider payloads, and it never writes. Rows are
bounded (512 candidates, 64 cards), titles are control-stripped and capped,
and a schema query failure reports the session as `incompatible` instead of
guessing.

Liveness is T3 Code's own contract: `userdata/server-runtime.json` must be
descriptor version 1 and name a process whose `/proc/<pid>/comm` is `t3code`.
A readable database never proves T3 Code is running; a missing descriptor or
exited process reports the session `offline` with no cards. Between full
reconciliations the daemon polls the projection sequence once per
`t3code.refresh_ms` and reconciles only when it changes.

The roster is every non-deleted, non-archived, non-snoozed thread that has a
`running` or `ready` provider session, or that finished a turn the human has
not settled. Classification, in priority order: a pending approval, pending
user input, or actionable proposed plan is `blocked`; a running session or
turn is `working` (a running session with no turn yet is `launch_pending`); an
`error` session or turn is `blocked`; a completed or interrupted turn is `done`
until T3 Code records `settled_at`, after which it is `idle`; a ready session
with no turn is `idle`; a queued turn whose session is not running is
`unknown` rather than a guessed activity state. `state_change_seq` is the millisecond timestamp of the
classifying event (turn start, completion, or settle), so priority ordering
matches T3 Code's recency and duration counters stay stable within a state.
Settling in T3 Code is reported as an acknowledgement that clears the
review-ready latch exactly like a new Herdr focus transition.

T3 Code exposes no public thread-focus API on Linux: its `t3code://` scheme and
`second-instance` handling only reveal the window, and the CLI control socket
only opens a workspace. Card activation therefore focuses the single exact
`t3code` compositor client using the same narrowing rules as the fixed desktop
apps and never launches it. Zoom is not offered, approve and interrupt
capabilities are never issued, and the grouped/priority Order control is a
daemon-owned preference persisted beside the manager choice.

## Identity and stale-state handling

Portal agent IDs are UUIDv5 values derived from the daemon epoch, Herdr session,
and live terminal identity, or from the daemon epoch and T3 Code thread ID.
The current pane ID or thread ID remains private action-routing state.
Restarting the daemon or switching managers invalidates every ID. Herdr
disconnects immediately remove action targets and guarded capabilities.

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

Hyprland activation is session-specific. Exact interactive Herdr
process/session ownership is authoritative; transient Herdr CLI commands and
unrelated terminals are excluded. A configured native class/title is only a
preference among owning clients. When multiple terminal-hosted views remain,
the unique most-recent Hyprland focus-history entry is selected; missing or
tied history fails closed.

ChatGPT Desktop and Claude Desktop use separate fixed action kinds. The daemon
matches exact known compositor classes: one match is focused, no match launches
the corresponding fixed desktop entry through an `uwsm app` graphical service,
and multiple matches are narrowed by the known initial main title, tiled state,
and unique most-recent focus-history entry before failing closed. Launches are
coalesced per app while the daemon waits a bounded time for a mapped client,
then focuses it before reporting success; every observation failure clears the
coalescing state.
QML cannot choose an executable, desktop entry, class, title, or arguments.

Passive EDGE gestures may request restoration of the last observed non-EDGE
window. The daemon first confirms that the exact window address still exists.
This behavior remains a physical-touch validation gate because Hyprland changes
its focused monitor on touchscreen contact.
