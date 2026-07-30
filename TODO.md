# XENEON EDGE Agent Command Center Ledger

## Goal

Implement a simulator-first, touch-oriented XENEON EDGE portal for all running
local Herdr sessions, with host health, fail-closed output placement, and
guarded quick actions. Complete every software gate now and leave physical
hardware commissioning explicitly pending while the device is unavailable.

## Done criteria

- [ ] Rust daemon and QML bridge expose versioned normalized snapshots.
- [ ] All running local Herdr sessions reconnect and reconcile safely.
- [ ] Standalone Quickshell portal renders six attention-ordered cards and
      deterministic fixture states at 2560x720.
- [ ] Direct actions are capability-gated inside Herdr; QML cannot send raw
      input.
- [ ] Installer/check/uninstall flows are reversible and preserve Omarchy and
      user-owned configuration.
- [ ] Automated checks and independent reviews pass.
- [ ] Physical EDGE display/touch/focus/privacy/power checks pass.

## Streams

| Stream | Branch/worktree | Files to own | Status |
| --- | --- | --- | --- |
| Foundation and Rust adapter | `main` | Rust workspace, schemas, fixtures | In progress |
| Herdr safe actions | `agent/xeneon-safe-actions` in the Herdr repository | Public Herdr API, tests, next docs | In progress |
| Quickshell portal | `agent/quickshell-portal` | `quickshell/`, QML tests | Pending baseline |
| Omarchy integration | `agent/omarchy-integration` | `config/`, `scripts/`, services, install tests | Pending baseline |

## Allowed actions

- Create local branches/worktrees and commits.
- Build, test, lint, and run explicit development previews.
- Change files in this repository and the isolated Herdr worktree.
- Install reviewed user-owned files only after isolated installer tests pass.

## Forbidden actions

- Production deployment, release publication, secrets, billing, or customer
  data.
- Editing `/usr/share/omarchy`.
- Global touch mapping, primary-monitor fallback, arbitrary key forwarding, or
  automatic replay of input actions.
- Claiming physical success without the connected device.

## Gates and evidence

- [ ] Foundation focused tests.
- [ ] Herdr focused tests and `just check`.
- [ ] QML lint, fixture smoke, and visual/runtime review.
- [ ] Installer tests in temporary XDG roots.
- [ ] Independent Rust/API review.
- [ ] Independent QML/UX review.
- [ ] Independent packaging/safety review.
- [ ] Integrated local simulator smoke.
- [ ] Physical hardware gate (blocked: XENEON EDGE unavailable).

## Open checkpoints

- Capture the real EDID/serial, connector, USB IDs, libinput name, and touch
  coordinates when hardware arrives.
- Verify Hyprland's focused-monitor behavior under a physical finger.
- Probe DDC/CI read-only and expose brightness only after exact restoration
  succeeds.
