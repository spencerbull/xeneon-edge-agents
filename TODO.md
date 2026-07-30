# XENEON EDGE Agent Command Center Ledger

## Goal

Implement a simulator-first, touch-oriented XENEON EDGE portal for all running
local Herdr sessions, with host health, fail-closed output placement, and
guarded quick actions. Complete every software gate now and leave physical
hardware commissioning explicitly pending while the device is unavailable.

The current delivery checkpoint packages that implementation as an unpublished
local Arch package, validates the package-owned installation path, and adds
least-privilege GitHub Actions for continuous checks and private release
artifacts.

## Done criteria

- [x] Rust daemon and QML bridge expose versioned normalized snapshots.
- [x] All running local Herdr sessions reconnect and reconcile safely.
- [x] Standalone Quickshell portal renders six attention-ordered cards and
      deterministic fixture states at 2560x720.
- [x] Direct actions are capability-gated inside Herdr; QML cannot send raw
      input.
- [x] Installer/check/uninstall flows are reversible and preserve Omarchy and
      user-owned configuration.
- [x] Automated checks and completed independent reviews pass.
- [x] An unpublished Arch package builds, installs, verifies, and uninstalls
      without owning user configuration.
- [x] GitHub Actions validate source and package builds with pinned,
      least-privilege dependencies.
- [ ] A private tag workflow can attach the Arch package to a GitHub Release
      without publishing to the AUR.
- [ ] Physical EDGE display/touch/focus/privacy/power checks pass.

## Streams

| Stream | Branch/worktree | Files to own | Status |
| --- | --- | --- | --- |
| Foundation and Rust adapter | `main` | Rust workspace, schemas, fixtures | Complete through `c32b5cd` |
| Herdr safe actions | `agent/xeneon-safe-actions` in the Herdr repository | Public Herdr API, PTY guard, tests, next docs | Complete locally at `8298f46`; not installed or pushed |
| Quickshell portal | `main` | `quickshell/`, QML tests | Complete through `34e6037` |
| Omarchy integration | `main` | `config/`, `scripts/`, services, install tests | Complete at `995d123`; simulator installed |
| Arch packaging | `agent/arch-packaging-ci` | `packaging/arch/`, package helper and tests | Complete through `cdcd8db` |
| GitHub automation | `agent/arch-packaging-ci` | `.github/`, CI documentation | Complete at `58eeb15`; branch-head source and package runs passed |

## Allowed actions

- Create local branches/worktrees and commits.
- Build, test, lint, and run explicit development previews.
- Change files in this repository and the isolated Herdr worktree.
- Install reviewed user-owned files only after isolated installer tests pass.
- Build and install a reviewed local Arch package without enabling services or
  production commissioning.
- Push source branches and create a draft pull request in the private
  repository.

## Forbidden actions

- Production deployment, public AUR publication, secrets, billing, or customer
  data.
- Editing `/usr/share/omarchy`.
- Global touch mapping, primary-monitor fallback, arbitrary key forwarding, or
  automatic replay of input actions.
- Claiming physical success without the connected device.

## Gates and evidence

- [x] Foundation focused tests: 24 core plus 1 CLI test and strict clippy.
- [x] Herdr gates: 2,825 unit, 213 integration, 86 maintenance, 17
      integration-asset, and 12 marketplace tests; strict Linux all-target and
      Windows-bin clippy.
- [x] QML gate: `qmllint`, 21 Python contract/fixture tests, 37 Qt tests,
      exact 1280x360 mapped preview, and inspected 1280x360 offscreen render.
- [x] Installer gate: 33 temporary-XDG scenarios plus installed-unit
      `systemd-analyze verify`.
- [x] Independent Rust/API and PTY concurrency review.
- [x] Independent QML/UX review.
- [x] Independent packaging/safety review with no remaining high/medium
      findings.
- [x] Integrated local simulator smoke: one Herdr 0.7.5/protocol-17 session,
      two active Codex agents, versioned snapshot, and expected open/zoom-only
      actions from the unchanged stable Herdr.
- [x] `makepkg`, source-package, package archive, and `namcap` validation.
- [x] Package install, pacman removal/reinstall, simulator
      install/check/uninstall, and 77-file package integrity verification.
- [x] GitHub Actions syntax, policy, and live private-repository branch runs:
      source `30556299464` and package `30556300158`.
- [x] Independent package and workflow review.
- [ ] Physical hardware gate (blocked: XENEON EDGE unavailable).

## Current local state

- The reviewed implementation through `8578d44` is pushed to private
  `origin/main`.
- Package and workflow work is pushed on `agent/arch-packaging-ci`; repository
  Actions require full-SHA pins.
- Hosted branch-head source and unpublished-package workflows passed at
  `58eeb15`; the package artifact remains private to the repository run.
- `xeneon-edge-agents 0.1.0-1` is installed from the local package. Pacman
  reports 77 package files and zero altered files.
- The simulator-safe package install contains three hash-verified user files;
  QML and user units now resolve from package-owned `/usr` paths.
- `xeneon-agentd.service` and `xeneon-edge-portal.service` are disabled and
  inactive, with no systemd drop-ins.
- The two former manual XENEON binaries are checksum-verified in
  `~/.local/state/xeneon-edge-agents/migration-backup/20260730-before-package`;
  shell resolution is now package-owned `/usr/bin`.
- `hyprland.lua` remains byte-identical to its pre-install hash, with no XENEON
  require or module.
- The stable Herdr installation remains unchanged. Guarded interruption exists
  only on the local Herdr branch; approval and Windows guarded actions remain
  unavailable.

## Open checkpoints

- Capture the real EDID/serial, connector, USB IDs, libinput name, and touch
  coordinates when hardware arrives.
- Verify Hyprland's focused-monitor behavior under a physical finger.
- Probe DDC/CI read-only and expose brightness only after exact restoration
  succeeds.
- Exercise the `v*` private-release job only at an explicit release gate; no
  tag or release was created during local packaging.
- Enable immutable releases and protected tag rules before treating private
  release assets as permanently locked.
- Before proposing the Herdr branch upstream, satisfy its contribution gate
  (accepted issue and maintainer approval when required); do not replace the
  stable Herdr install during physical commissioning without a separate
  reviewed upgrade.
