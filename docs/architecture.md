# Architecture

## Trust boundary

Herdr owns terminal identity, agent detection, and agent actions.
`xeneon-agentd` owns aggregation, reconnects, host health, desktop routing, and
the portal's narrow action policy. Quickshell owns rendering and touch gesture
state only.

```text
Herdr public sockets        /proc, /sys, Hyprland
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

Snapshots carry an action-state sequence. Host-health refreshes do not advance
that sequence, so an 800 ms hold is not invalidated by an unrelated CPU sample.
Agent topology or state reconciliation does advance it.

Input actions are never queued or replayed. Focus and zoom are resolved against
the latest private pane target. Approval and interruption require an opaque,
single-use capability issued and revalidated by a compatible Herdr server.

## Desktop boundary

The production QML process creates no window unless one configured output
identity matches. It does not use a primary-screen fallback.

Hyprland activation is session-specific. The daemon considers only compositor
clients whose process trees contain the exact Herdr session or socket identity;
ambiguous matches fail instead of focusing a generic window title.

Passive EDGE gestures may request restoration of the last observed non-EDGE
window. The daemon first confirms that the exact window address still exists.
This behavior remains a physical-touch validation gate because Hyprland changes
its focused monitor on touchscreen contact.
