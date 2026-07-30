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
- [ ] An unpublished Arch package builds, installs, verifies, and uninstalls
      without owning user configuration.
- [ ] GitHub Actions validate source and package builds with pinned,
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
| Arch packaging | `agent/arch-package` worktree | `packaging/arch/`, package helper and tests | In progress |
| GitHub automation | `agent/github-actions` worktree | `.github/`, CI documentation | In progress |

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
- [x] Installer gate: 24 temporary-XDG scenarios plus installed-unit
      `systemd-analyze verify`.
- [x] Independent Rust/API and PTY concurrency review.
- [x] Independent QML/UX review.
- [x] Independent packaging/safety review with no remaining high/medium
      findings.
- [x] Integrated local simulator smoke: one Herdr 0.7.5/protocol-17 session,
      two active Codex agents, versioned snapshot, and expected open/zoom-only
      actions from the unchanged stable Herdr.
- [ ] `makepkg`, source-package, package archive, and `namcap` validation.
- [ ] Package install plus isolated simulator install/check/uninstall.
- [ ] GitHub Actions syntax, policy, and live private-repository runs.
- [ ] Independent package and workflow review.
- [ ] Physical hardware gate (blocked: XENEON EDGE unavailable).

## Current local state

- The reviewed implementation through `8578d44` is pushed to private
  `origin/main`.
- Package and workflow work is isolated on `agent/arch-packaging-ci`.
- The simulator-safe user install contains 23 hash-verified managed files.
- `xeneon-agentd.service` and `xeneon-edge-portal.service` are disabled and
  inactive.
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
- Before proposing the Herdr branch upstream, satisfy its contribution gate
  (accepted issue and maintainer approval when required); do not replace the
  stable Herdr install during physical commissioning without a separate
  reviewed upgrade.
