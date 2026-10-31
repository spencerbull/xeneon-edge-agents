# AGENTS.md

## Project contract

This repository owns the XENEON EDGE agent command center for Omarchy. One
agent manager at a time, Herdr or T3 Code, is the agent/session authority;
`xeneon-agentd` is the adapter and action authority and owns which manager is
active; Quickshell is presentation-only.

## Safety boundaries

- Never send arbitrary terminal text or keys from QML.
- Never retry a non-idempotent agent action.
- Never show terminal or prompt contents on the portal.
- Never directly write T3 Code orchestration state. Its own host CLI may
  manage its normal authentication session. Never read T3 messages, activities,
  checkpoints, secrets, or provider payloads; only the bounded thread,
  session, turn, and project projections are inputs.
- Never fall back to the primary display when the XENEON identity is absent or
  ambiguous.
- Never apply a global touchscreen mapping; this host also has an internal
  touchscreen.
- Never edit packaged Omarchy files under `/usr/share/omarchy`.
- Keep installed files in user-owned XDG locations and make installation
  reversible.
- Preserve unrelated user changes in this repository and in `~/.config`.

## Architecture

- Rust workspace: daemon, bridge CLI, normalized protocol, Herdr adapter,
  read-only T3 Code adapter, health collectors, and deterministic fixtures.
- Quickshell: one standalone named configuration, one state bridge, and
  output-filtered `PanelWindow` delegates.
- Hyprland: one project-owned Lua module loaded after the user's monitor/input
  modules. `hyprmoncfg` continues to own `monitors.lua`.
- Herdr changes live in its own repository and must use the public socket/API
  boundary.
- T3 mode opens the exact environment/thread URL on the installed nightly.
  A T3 build with `t3 app --thread` can be selected through `t3code.app_bin`.
  Never substitute project activation: it can create a new thread. Zoom,
  approve, and interrupt remain unavailable.
- The opt-in Micro bridge consumes the daemon's ordered roster and typed
  actions. It must share the per-device integration flock with Herdr, restore
  only a previously active Herdr service, and wait for slot and ring ACKs
  before claiming control or routing a changed slot.
- `t3code.status_file` opts into the separate metadata-only T3 helper. Only
  the T3-owned host CLI may manage its normal authentication session; the
  hardware daemon keeps T3 data read-only. Without the file, the
  read-only V2 fallback extracts only allowlisted scalar projection fields;
  it cannot infer all detached background work or silent compaction states.

## Working loop

- Record branches, gates, and evidence in `TODO.md`.
- Use isolated worktrees for parallel streams.
- Run focused tests before broad checks.
- Obtain an independent review for non-trivial Rust, QML, and installation
  changes.
- Distinguish fixture/runtime validation from physical XENEON touch validation.

## Required validation

- Rust formatting, linting, and tests.
- `qmllint` plus the QML contract and fixture smoke tests.
- Shell static checks and installer tests in isolated XDG directories.
- `luac -p` for generated Hyprland Lua.
- Live `hyprctl reload` and `hyprctl configerrors` only after a reviewed,
  user-owned config is installed.
- Real monitor/touch, hotplug, DPMS, suspend, focus, privacy, and DDC checks
  remain blocked until the physical XENEON is connected.
