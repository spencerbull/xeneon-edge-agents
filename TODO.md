# XENEON EDGE Agent Command Center Ledger

## Goal

Implement a simulator-first, touch-oriented XENEON EDGE portal for all running
local Herdr sessions, with host health, fail-closed output placement, and
guarded quick actions. Complete every software gate and commission the
connected physical display without weakening exact output or touch identity.

The current UX checkpoint corrects Herdr agent naming and brings the existing
Codex Micro state language to the portal: shared state colors, observable
Omarchy voice states, and a dynamic ambient perimeter treatment. This work is
isolated from the package-review checkout and must not weaken the production
output or action boundaries.

The current visual checkpoint uses `herdr-xeneon-edge-concept.mp4` as a motion
reference: an opaque dashboard crossfade, center-out radar reveal, quiet
constellation hold, and bounded state-colored orbital trails. The exact
storyboard and product boundaries are recorded in `docs/concept-motion.md`.

The active home-command checkpoint replaces the host-health footer with
agent-command information: adaptive Herdr cards, normalized AI provider
capacity, fixed native desktop launch/focus actions, and a read-only Codex
Micro projection. QML remains presentation-only; cache parsing, socket reads,
and desktop actions stay in `xeneon-agentd`.

The completed AI-detail follow-up expands that footer with both reported capacity
windows, reset timing, plan/freshness state, and bounded aggregate today/hour
token activity. Prompt text, per-model history, credentials, and raw provider
payloads remain outside the portal protocol.

The completed review checkpoint audited the complete tracked repository with Claude
Fable 5 over a persistent ACP session. Any verified findings are fixed only on
`claude-fable-review`, revalidated through the required software gates, and
returned to the same reviewer until no substantive findings remained.

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
- [x] Portal cards use the same public agent names as Herdr's Agents section.
- [x] Agent colors, voice states, and ambient perimeter behavior match the
      reviewed Codex Micro state contract with reduced-motion support.
- [x] Ambient transition and orbital motion match the concept timing and
      hierarchy without changing portal action authority.
- [x] Revised live laptop preview is visually compared with rectified concept
      frames at the same 1280x360 viewport.
- [x] One native perimeter halo uses two opposing clockwise runners while an
      agent is working or blocked, and disappears for idle or empty rosters.
- [x] The perimeter runners render as a Gaussian-style GPU bloom with bounded
      particle motes instead of stacked moving bars.
- [x] Agent-card status accents use bounded Gaussian blooms with no visible
      hard core: a state-colored left aura on every card and a moving blue top
      glint only while the agent is working.
- [x] Shared persistent Motion and Screen controls remain available in both
      control-center and Ambient views; reduced motion uses an evenly spaced
      static constellation with no trails/runners, and Screen minimum remains
      visibly reversible above a near-black portal veil.
- [x] The control-center header uses the uppercase live hostname, removes the
      redundant connection pill, and replaces the AI Capacity label tile with
      authoritative Herdr agent/session/focus counts.
- [x] Control-center cards expose only authoritative Herdr lifecycle,
      repository/worktree, focus, and state-age metadata.
- [x] Each ordinary agent card is one full-surface Herdr focus target; the
      redundant Open and Zoom controls are removed while capability-gated hold
      actions remain isolated when present.
- [x] The footer shows normalized Claude, Codex, and OpenCode usage with
      freshness and quota/local-budget semantics.
- [x] The footer shows both reported windows, reset timing, plan/freshness
      state, and bounded today/hour token activity without exposing raw data.
- [x] ChatGPT and Claude buttons focus or launch only their fixed native
      desktop IDs through daemon-owned actions.
- [x] A right-side read-only Micro drawer shows fresh device status, projected
      agent slots, and the shared voice/aggregate state language.
- [x] Focused Rust/QML tests, live laptop interaction, visual QA, and an
      independent review pass complete for the home-command checkpoint.
- [ ] Physical EDGE display/touch/focus/privacy/power checks pass (display,
      exact touch mapping, Ambient wake, and card focus are now confirmed).

## Streams

| Stream | Branch/worktree | Files to own | Status |
| --- | --- | --- | --- |
| Foundation and Rust adapter | `main` | Rust workspace, schemas, fixtures | Complete through `c32b5cd` |
| Herdr safe actions | `agent/xeneon-safe-actions` in the Herdr repository | Public Herdr API, PTY guard, tests, next docs | Complete locally at `8298f46`; not installed or pushed |
| Quickshell portal | `main` | `quickshell/`, QML tests | Complete through `34e6037` |
| Live naming, voice, and ambient ring UX | `agent/portal-voice-ring` in `portal-voice-ring` worktree | normalized public protocol fields, `quickshell/`, fixtures, UX docs/tests | Live on the physical EDGE; remaining power/privacy checks are open |
| Concept motion parity | `agent/portal-voice-ring` in `portal-voice-ring` worktree | ambient presentation, preview timing, visual QA | Live on the physical EDGE; remaining power/privacy checks are open |
| Agent-command home redesign | `agent/portal-voice-ring` in `portal-voice-ring` worktree | normalized safe metadata, usage/Micro collectors, fixed app actions, control-center QML | Software complete, live-previewed, and independently reviewed |
| AI usage detail expansion | `main` | bounded usage protocol, AI dock, tests/docs | Complete, installed, and physically verified |
| Full Claude Fable 5 review | `claude-fable-review` | complete tracked repository; preserve untracked `packaging/` artifacts | Complete: all 14 findings fixed and ACP re-review clean |
| Desktop launcher | `desktop-launcher` | managed XDG desktop entry, helper, icon, installer lifecycle, tests | Complete, installed, and launched through Omarchy |
| Global display controls | `agent/portal-voice-ring` in `portal-voice-ring` worktree | persistent presentation settings, reduced-motion composition, dim veil | Live on the physical EDGE; default full-motion/normal-screen state restored |
| Omarchy integration | `agent/portal-voice-ring` in `portal-voice-ring` worktree | `config/`, `scripts/`, services, install tests | Production user integration installed and active on the physical EDGE |

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

- [x] Foundation focused tests: 24 core plus 1 CLI test and strict clippy.
- [x] Herdr gates: 2,825 unit, 213 integration, 86 maintenance, 17
      integration-asset, and 12 marketplace tests; strict Linux all-target and
      Windows-bin clippy.
- [x] QML gate: `qmllint`, 21 Python contract/fixture tests, 37 Qt tests,
      exact 1280x360 mapped preview, and inspected 1280x360 offscreen render.
- [x] Installer gate: 25 temporary-XDG scenarios plus installed-unit
      `systemd-analyze verify`.
- [x] Independent Rust/API and PTY concurrency review.
- [x] Independent QML/UX review.
- [x] Independent packaging/safety review with no remaining high/medium
      findings.
- [x] Naming/voice/ring focused Rust and QML tests: 43 core plus 1 CLI, strict
      clippy/fmt, 22 Python contracts/fixtures, and 51 Qt tests.
- [x] Live laptop preview using real Herdr agents and observable voice-state
      transitions, without installing or activating production display config.
- [x] Independent review of the naming/privacy boundary, voice-state
      ownership, animation lifecycle, and reduced-motion behavior.
- [x] Concept-motion QML gate: 22 Python contract/fixture tests and 65 Qt tests,
      with `qmllint`, reduced-motion, bounded trails, reverse-transition,
      accessibility-shield, and live-state coverage.
- [x] Visual QA against four perspective-rectified concept states at 1280x360;
      post-fix result is recorded as passed in `design-qa.md`.
- [x] Independent concept-motion re-review approved after phase-wrap and
      fade-shield lifecycle fixes; no actionable findings remain.
- [x] Independent reverse-transition re-review approved after forward-coast,
      full-duration staging, bounded trail-cost, and accessibility action
      shielding fixes; no P0, P1, or P2 findings remain.
- [x] Integrated local simulator smoke: one Herdr 0.7.5/protocol-17 session,
      two active Codex agents, versioned snapshot, and expected open/zoom-only
      actions from the unchanged stable Herdr.
- [x] Agent-command home gates: 52 core plus 1 CLI test, strict fmt/clippy,
      23 Python contracts/fixtures, 72 Qt tests with `qmllint`, schema parse,
      shell syntax, and the isolated installer suite.
- [x] Agent-command home live 1280x360 visual QA used real Herdr names, live
      provider capacity, verified Micro status, a real ChatGPT focus result,
      and a real Claude launch plus mapped-client focus result.
- [x] Perimeter halo live QA captured the two runners moving clockwise through
      rounded corners on command-center and ambient views; the native Shape
      implementation remained responsive after the Canvas prototype was
      rejected for excessive paint cost.
- [x] Perimeter bloom live QA captured two frames in both command-center and
      ambient views: the runners remained opposing and clockwise, the blur
      stayed soft at corners, particle trails remained bounded, and the mapped
      preview stayed responsive.
- [x] Independent QML re-review caught and verified the production hostname
      pass-through; the final focused review found no remaining P0/P1/P2
      issues.
- [x] Card-focus QA verified the full-size target contract, the fixed
      `agent.focus` action against the live preview daemon, and the resulting
      authoritative focused-agent update for `seform-codex`.
- [x] Physical EDGE display and touch QA identified `DP-2` / serial
      `066626215698` / EDID SHA-256
      `311920e1e0982803ea7ec8aee0a1688630095944e025ece9bc741ebb8ac70dc5`,
      enabled native 2560x720 at 2x scale, mapped only
      `wch.cn-touchscreen-1` (`0003:27c0:0859`, uniq
      `9LQ0172005164`), captured a real touch sequence, woke Ambient, tapped
      `herdr-xeneon`, and observed Herdr report that exact agent focused.
- [x] Production activation verified both user services active with zero
      restarts, a mode-`0600` daemon socket inside a mode-`0700`
      systemd-owned runtime directory, a connected Herdr protocol-17 snapshot
      with five real agents, live provider/Micro telemetry, and one
      `xeneon-edge-agent-portal` layer surface on `DP-2` only.
- [x] Physical card-accent QA replaced the rigid left and working-state top
      bars with two bounded `MultiEffect` blooms, captured the result at native
      2560x720, and verified zero service restarts or shader warnings.
- [x] Global display-control gate: 52 core plus 1 CLI test, strict fmt/clippy,
      25 Python contracts/fixtures, 80 Qt tests with `qmllint`, and 25 isolated
      installer scenarios.
- [x] Physical display-control QA used real DP-2 taps in both views: Motion
      persisted through a production service restart, suppressed perimeter
      runners and trails, and placed four agents without overlap on an evenly
      spaced static ellipse; Screen minimum dimmed and restored both
      control-center and Ambient views without waking Ambient.
- [x] Independent display-control review approved QML layering, restore
      reachability, reduced-motion coverage, Qt Settings persistence, and the
      narrowly writable systemd StateDirectory with no P0/P1/P2 findings.
- [x] Physical runtime fixes were independently reviewed before reactivation:
      the daemon now uses `RuntimeDirectory=`, Quickshell receives narrowly
      writable shared runtime paths, Qt's unavailable Wayland EDID serial is
      tolerated only after the installer verifies the configured serial
      through Hyprland, and the unique connector/model match remains
      fail-closed.
- [x] Agent-command home independent Rust/QML review resolved launch
      coalescing, collector non-blocking behavior, verified Micro identity, and
      fail-closed usage; final re-review found no remaining P0/P1/P2 issues.
- [x] AI usage detail gate: 53 core plus 1 CLI test, strict fmt/clippy, 25
      Python contracts/fixtures, 85 Qt tests with `qmllint`, and 25 isolated
      installer scenarios.
- [x] AI usage detail physical QA captured the installed native 2560x720 DP-2
      surface with both available usage windows, reset timing, plan/freshness,
      explicit provider status, and bounded today/hour token activity; both
      services remained active with zero restarts.
- [x] Independent AI usage detail review approved the additive schema-v1
      fields, trust clearing, Rust/QML bounds, and 1280x360 composition with no
      substantive findings.
- [x] Claude-review remediation software gate: 56 Rust core plus 1 CLI test,
      strict fmt/clippy, ShellCheck 0.11.0, 26 Python QML contracts/fixtures,
      85 Qt tests with `qmllint`, and 25 isolated installer scenarios.
- [x] Claude Fable 5 full-repository ACP review has no remaining substantive
      findings after verified fixes and required local gates.
- [x] Claude-review live activation passed the exact DP-2/EDID/touch preflight,
      installed release binaries with source-matching hashes, retired the
      obsolete `HealthStrip.qml`, restarted both services with zero failures,
      reported one connected Herdr 0.7.5/protocol-17 session with four agents,
      and rendered one visually inspected portal layer on DP-2 only.
- [x] Desktop-launcher gate: strict ShellCheck, desktop-entry validation, 28
      isolated installer scenarios, and the full Rust/QML/software gates pass;
      independent re-review has no remaining P0/P1/P2 findings.
- [x] Desktop-launcher live QA found the custom entry and icon in Omarchy's
      Apps menu, launched it through that menu, rendered its success
      notification, kept already-running service PIDs stable, and separately
      restored a deliberately stopped portal through `gtk-launch` on DP-1.
- [ ] Physical hardware gate (hotplug, DPMS, suspend/resume, privacy,
      guarded-hold behavior, and DDC restore remain).

## Current local state

- PR #2 is squash-merged on `main` at `7eb773c`, including the reviewed
  physical commissioning, naming/voice/ring UX, card accents, and persistent
  display controls.
- The clean `agent/portal-voice-ring` worktree is retained as historical
  branch context; the merged implementation remains installed in user-owned
  XDG paths on this host.
- The final live preview showed the current Herdr public labels
  `seform-codex`, `wifi7`, `herdr-xeneon`, and `herdr-xeneon-design`; prior
  voice validation observed recording/idle ownership transitions,
  automatically cancelled a recording when its bridge client disconnected,
  and restored the prior ChatGPT window before laptop voice actions.
- `xeneon-agentd.service` and `xeneon-edge-portal.service` are enabled,
  active, and running without restarts after the reviewed AI usage detail
  activation.
- The managed `XENEON EDGE Command Center` desktop entry, icon, and bounded
  helper are installed in user-owned XDG paths. The default action starts the
  two fixed user units without disrupting active services; restart is an
  explicit secondary action.
- The installed physical footer now shows both reported provider windows,
  reset timing, plan/freshness and explicit status, plus bounded aggregate
  today/hour activity when available; no prompts, per-model history,
  credentials, or raw provider payloads cross the protocol.
- The uncommitted `claude-fable-review` remediation isolates Herdr refreshes
  from the privacy-sensitive collector loop, fails closed on non-17 Herdr
  protocols and untrusted usage text, repairs QML recovery behavior, removes
  the retired HealthStrip, and adds ShellCheck plus an Arch/Quickshell CI gate.
- Portal preferences persist at
  `~/.local/state/xeneon-edge-agents/portal/preferences.ini` with mode `0600`;
  physical validation ended in the default full-motion, normal-screen state.
- `hyprland.lua` contains the installer-managed XENEON require, and the
  generated module maps only `wch.cn-touchscreen-1` to `DP-2`.
- The persisted home layout places the 1280x360 logical EDGE at `560,1350`,
  centered below the 2400x1350 logical external display, with the laptop
  immediately to its right at `1840,1350`. The external display is running at
  120 Hz instead of 240 Hz so the third display fits the available link
  bandwidth.
- The stable Herdr installation remains unchanged. Guarded interruption exists
  only on the local Herdr branch; approval and Windows guarded actions remain
  unavailable.

## Open checkpoints

- Complete the Claude Fable 5 ACP review/fix/re-review loop on
  `claude-fable-review`; do not include or modify the pre-existing untracked
  `packaging/` artifacts.
- Capture calibrated corner coordinates and guarded-hold cancellation.
- Verify hotplug, DPMS, suspend/resume, and privacy behavior.
- Probe DDC/CI read-only and expose brightness only after exact restoration
  succeeds.
- Before proposing the Herdr branch upstream, satisfy its contribution gate
  (accepted issue and maintainer approval when required); do not replace the
  stable Herdr install during physical commissioning without a separate
  reviewed upgrade.
