# AGENTS.md

## Project contract

This repository owns the XENEON EDGE agent command center for Omarchy. Herdr is
the agent/session authority, `xeneon-agentd` is the adapter and action authority,
and Quickshell is presentation-only.

## Safety boundaries

- Never send arbitrary terminal text or keys from QML.
- Never retry a non-idempotent agent action.
- Never show terminal or prompt contents on the portal.
- Never fall back to the primary display when the XENEON identity is absent or
  ambiguous.
- Never apply a global touchscreen mapping; this host also has an internal
  touchscreen.
- Never edit packaged Omarchy files under `/usr/share/omarchy`.
- Keep installed files in user-owned XDG locations and make installation
  reversible.
- Preserve unrelated user changes in this repository and in `~/.config`.

## Architecture

- Rust workspace: daemon, bridge CLI, normalized protocol, Herdr adapter, health
  collectors, and deterministic fixtures.
- Quickshell: one standalone named configuration, one state bridge, and
  output-filtered `PanelWindow` delegates.
- Hyprland: one project-owned Lua module loaded after the user's monitor/input
  modules. `hyprmoncfg` continues to own `monitors.lua`.
- Herdr changes live in its own repository and must use the public socket/API
  boundary.

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
