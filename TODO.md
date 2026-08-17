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

The completed source theme-sync checkpoint makes portal chrome follow Omarchy's current
runtime palette without copying a named theme. The project-owned QML reader
watches Omarchy's stable theme-name beacon, reloads the atomically replaced
`colors.toml`, validates an allowlisted palette, and retains the fixed agent
state meanings while mapping their hues to the active theme's blue, yellow,
green, and red roles.
Installation and a physical theme switch remain a separate live gate.

The active hotplug checkpoint replaces connector-pinned autostart with an
event-driven lifecycle. The commissioned EDID, serial/model, and USB touch
identity remain authoritative while the current connector becomes runtime
state; the daemon and portal run only while that exact hardware is present.

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
- [x] Agent colors, voice states, and ambient perimeter behavior retain the
      reviewed Codex Micro meanings, use active Omarchy hue roles, and support
      reduced motion.
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
- [x] Exact XENEON hotplug starts and maps the stack on its current connector;
      unplug stops both application services without touching other displays.

## Streams

| Stream | Branch/worktree | Files to own | Status |
| --- | --- | --- | --- |
| Foundation and Rust adapter | `main` | Rust workspace, schemas, fixtures | Complete through `c32b5cd` |
| Herdr safe actions | `agent/xeneon-safe-actions` in the Herdr repository | Public Herdr API, PTY guard, tests, next docs | Installed from reviewed v0.8.0 head `fd53378d`; not pushed |
| Shared agent ordering | `xeneon-order-mode-sync` in `herdr-worktrees/xeneon-order-mode-sync` plus `omarchy-theme-sync` here | Herdr `agent.order.get/set`, adapter snapshot/action, QML toggle, ordering and motion tests | XENEON follow-up installed and independently reviewed; Herdr live handoff is blocked by the running server's 64-pane limit (67 panes present), so ordering remains unavailable |
| Quickshell portal | `main` | `quickshell/`, QML tests | Complete through `34e6037` |
| Live naming, voice, and ambient ring UX | `agent/portal-voice-ring` in `portal-voice-ring` worktree | normalized public protocol fields, `quickshell/`, fixtures, UX docs/tests | Live on the physical EDGE; remaining power/privacy checks are open |
| Concept motion parity | `agent/portal-voice-ring` in `portal-voice-ring` worktree | ambient presentation, preview timing, visual QA | Live on the physical EDGE; remaining power/privacy checks are open |
| Agent-command home redesign | `agent/portal-voice-ring` in `portal-voice-ring` worktree | normalized safe metadata, usage/Micro collectors, fixed app actions, control-center QML | Software complete, live-previewed, and independently reviewed |
| AI usage detail expansion | `main` | bounded usage protocol, AI dock, tests/docs | Complete, installed, and physically verified |
| Full Claude Fable 5 review | `claude-fable-review` | complete tracked repository; preserve untracked `packaging/` artifacts | Complete: all 14 findings fixed and ACP re-review clean |
| Desktop launcher | `desktop-launcher` | managed XDG desktop entry, helper, icon, installer lifecycle, tests | Complete, installed, and launched through Omarchy |
| Omarchy runtime theme sync | `omarchy-theme-sync` | project-owned QML palette reader, semantic chrome and state tokens, theme reload/fallback tests | Theme sync and semantic state roles installed, reviewed, and physically verified |
| Herdr v0.8 compatibility | `herdr-v0.8-compat` in `herdr-v0.8-compat` worktree | Herdr protocol gate, adapter fixture, protocol docs | Installed from `6edfcd3`; live handoff, protocol 19 connection, services, and production checker passed |
| Hotplug lifecycle | `hotplug-lifecycle` in `hotplug-lifecycle` worktree | lifecycle reconciler, user units, Hyprland event hook, runtime connector override, installer/tests | Installed and independently reviewed; exact `DP-2` unplug stopped both services and replug restored the stack and touch mapping; burst and mid-settle races are covered by regression tests |
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

- [x] Hotplug lifecycle software gate: Rust config tests, shell/static checks,
      31 isolated installer/reconciler scenarios, generated Lua syntax, and
      independent review with no remaining substantive findings.
- [ ] Hotplug lifecycle physical gate: reviewed live install, actual
      `/dev/input` path activation, display/USB unplug-replug ordering, and real
      touch disable/re-enable mapping pass. DPMS, suspend/resume, focus/privacy,
      and coordinate validation on the XENEON remain open.

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
- [x] Physical EDGE display and touch QA verified the exact commissioned EDID,
      model, serial, USB identity, and touch device; enabled native 2560x720 at
      2x scale; captured a real touch sequence; woke Ambient; focused an agent;
      and observed Herdr report that exact agent focused. Host-specific hardware
      identifiers remain in the local commissioning file rather than this
      repository.
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
      the reconciler exclusively owns and preserves the systemd runtime
      directory needed for connector handoff, Quickshell receives narrowly
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
- [x] Historical Herdr v0.8 compatibility gate: protocol-19 adapter fixture and
      full repository software checks passed against that earlier rebased API
      contract; the current protocol-20 checkpoint below supersedes it.
- [x] Omarchy theme-sync base source gate: strict palette parsing and fallback
      tests, repeated atomic theme-directory replacement in a source preview,
      full QML lint/tests, 31 installer scenarios, Rust and ShellCheck gates,
      plus independent review with no P0-P2 findings.
- [x] Install the reviewed theme-sync base and verify its active Omarchy
      palette renders on the physical EDGE.
- [x] Finish review, install the semantic state-role follow-up, and verify the
      theme-derived blue/yellow/green/red meanings on the physical EDGE.
- [ ] Add a top-right persisted Palette pane that shows the current Omarchy
      swatches and maps allowlisted roles onto Ready, Success, Working, Needs
      Help, Review Ready, Error, Unknown, Recording, and Processing. Done requires
      focused and full QML gates, hosted CI, independent review, a reviewed
      reinstall, and physical verification in command-center and Ambient
      views across at least two Omarchy themes.
- [x] Restore Claude, Codex, and OpenCode capacity after Omarchy replaced the
      legacy model-usage caches with schema-v1 agent records. Done requires
      legacy compatibility, fail-closed normalized parsing, a read-only local
      OpenCode fallback, Rust/full-repository gates, independent review, and
      live EDGE verification with all three cards populated.
- [ ] Physical hardware gate (hotplug, DPMS, suspend/resume, privacy,
      guarded-hold behavior, and DDC restore remain).
- [ ] Fit 14 agents per fixed 2560x720 command-center page, keep the full
      Claude/Codex quota-window labels visible, and show each card's Herdr
      space name for dense grouping. Show up to the same 14 agents on a
      bounded independent-lane ambient animation instead of the previous
      six-node cap; full-motion lanes may intentionally cross and overlap,
      while reduced motion stays static and evenly spaced.
      Done requires QML gates,
      independent review, a reviewed reinstall, a temporary 20-agent Herdr
      population proving 14+6 pagination, physical EDGE screenshots, and
      cleanup of only the disposable test tabs.
- [ ] Synchronize the EDGE grouped/priority control with Herdr's authoritative
      persisted ordering and restore the exact original independent ambient
      motion through six agents while extending the same independent-lane
      character through fourteen bounded nodes. Done requires Herdr and XENEON
      tests, independent reviews, a
      reviewed Herdr live handoff, physical toggle verification from both UIs,
      and physical ambient visual QA.

## Current local state

- Active goal (2026-08-13): replace the stock Omarchy Herdr protocol-20
  installation with the reviewed custom fork rebased onto exact packaged commit
  `0766aa57ee0ceb4410ae064e94c0f0557853eee7`, update XENEON for protocol 20,
  and restore guarded actions plus grouped/priority synchronization. Done
  requires focused and broad gates in both repositories, independent review,
  a state-preserving Herdr live handoff, reviewed XENEON reinstall, live API
  and physical EDGE verification, and cleanup of only loop-created resources.
  Visible implementation worker `herdr_p20_impl` (Codex) runs in Herdr pane
  `wW:pF`, tab `wW:t1`, workspace `wW`, cwd/worktree
  `/home/sbull/src/github.com/spencerbull/herdr-worktrees/xeneon-order-mode-sync`,
  branch `xeneon-order-mode-sync`; the orchestrator owns verification and pane
  cleanup. A second visible Codex worker, `herdr_handoff_cap`, owns only the
  bounded 79-pane live-handoff prerequisite in pane `wW:pG`, tab `wW:t1`,
  workspace `wW`, cwd/worktree
  `/home/sbull/src/github.com/spencerbull/herdr-worktrees/xeneon-handoff-capacity`,
  branch `xeneon-handoff-capacity`; the orchestrator owns integration, review,
  and cleanup. The XENEON independent pre-install review found three P2
  acceptance/handoff gaps (explicit protocol-19 rejection, rendered degraded
  reason coverage, and stale ledger evidence); all were remediated and the
  final re-review is GO with no P0-P2 findings. XENEON is installed and live;
  the Herdr branch is pushed and its reviewed package is built, but privileged
  package installation remains at the visible sudo prompt. No PR is planned
  against upstream under its external-contributor policy.

- The 14-agent layout source and cleanup gates are complete: QML tests prove
  14+6 pagination, a temporary 20-agent Herdr population physically verified
  the first 14-card page plus the fourteen-node ambient view, and all 11
  disposable tabs were closed. A physical second-page screenshot remains open.
- The grouped/priority follow-up is source-complete in isolated Herdr branch
  `xeneon-order-mode-sync`, now rebased onto exact Omarchy protocol-20 commit
  `0766aa57` with a reviewed 128-descriptor handoff prerequisite for the current
  79-pane session, plus the current XENEON branch. The integrated Herdr gate
  passes 3,465 Rust tests, strict Clippy including Windows, UI/integration/
  marketplace suites, and 98 maintenance/schema/docs/vendor tests. The current
  XENEON gate passes 78 Rust core tests, 104 Qt tests, 27 Python contracts, and
  all 31 installer scenarios. The final XENEON re-review is GO; the reviewed
  release binaries and full Quickshell tree are installed. Live validation
  reports one connected protocol-20 session with 18 agents, zero service
  restarts, 0-1% sampled daemon CPU after replacing the stale release artifact,
  clean `scripts/check.sh`/`hyprctl configerrors`, and a visually inspected
  2560x720 EDGE frame with 14 cards on page one. The prior reviewed Herdr
  handoff made no state change because the
  then-running server had 67 panes and v0.8.0 refused more than 64. The retained
  backup remains available. The custom Herdr branch is pushed to the fork at
  `51af53be`; its epoch-1 Arch package is built and reviewed, but awaits the
  user's sudo password. The running stock server remains intentionally intact,
  so ordering is unavailable in the portal until a future controlled cold
  restart activates the installed fork; the stock 64-descriptor exporter cannot
  preserve the current 79-plus-pane session through a live handoff.
  The previously reviewed XENEON side is installed: physical EDGE frames
  with 14 agents confirm the bounded independent lanes change relative order,
  cross, and overlap instead of moving as a rigid revolving formation. Both
  application services remained active with zero restarts during that check.

- `omarchy-theme-sync` is based on current `origin/main` and contains the
  pushed theme integration, semantic state-role follow-up, dense layout,
  protocol-20 adapter, and usage remediation in draft PR #7. A persisted
  allowlisted Palette pane and the hosted font-metric fix are now being added
  before merge; neither incremental change is installed or pushed yet.
  Independent read-only reviewer `xeneon_palette_review` (Claude) completed
  the review/fix/re-review loop with no remaining P0-P2 findings; its Herdr
  pane `wW:pN` was closed after graceful agent exit. Physical pane/two-theme
  QA, push, and hosted CI remain. Final local
  revalidation passes 78 Rust core tests, the CLI test, strict Clippy/rustfmt,
  ShellCheck, 27 Python and 112 Qt QML tests, all 31 installer scenarios, and
  `git diff --check`. The reviewed tree is installed after exact output/touch
  preflight; both services are active with zero restarts, installed Quickshell
  files match source, and Hyprland reports no config errors. A compositor-native
  2560x720 Tokyo Night capture confirms the new Palette button and 14-card
  command-center layout. The installed `cua-driver` 0.7.1 cannot capture this
  multi-monitor Wayland layer surface (`GetImage` Match failure), so opening
  the pane and two-theme physical QA remain human/live gates; no CUA action was
  attempted after capture failed.
- Production reinstall reverified the exact DP-2 EDID, XENEON serial/model,
  and USB touchscreen identity before activation, then correctly followed the
  same hardware after connector drift to live `DP-1`. The deployed Quickshell
  tree matches current source. Both services are active with zero restarts,
  the lifecycle reports `state=running`, and one inspected portal layer
  renders only on the XENEON using the active `rebel-rebel` palette.
- The source preview followed the real `rebel-rebel` palette and an isolated
  atomic purple-to-cyan theme replacement without restart. A final current
  fixture preview was visually inspected and closed cleanly.
- Theme validation passes 27 Python QML contracts, 93 Qt tests, all 31
      installer scenarios, 60 Rust core tests, the CLI fixture test, Clippy,
      rustfmt, ShellCheck, and `git diff --check`.
- The August 11 Omarchy usage migration regression is fixed in the installed
  daemon. Claude and Codex consume fresh fail-closed schema-v1 Omarchy records;
  OpenCode derives its documented local soft-budget signal from bounded scalar
  counters in the read-only message ledger. Two independent final reviews
  reported no P0-P2 findings. Full gates pass: 68 Rust core tests plus the CLI
  fixture, strict Clippy/rustfmt, 27 Python and 93 Qt QML tests, 30 installer
  scenarios, ShellCheck, and `git diff --check`. The live snapshot reports all
  three providers available and fresh, and the physical DP-1 EDGE screenshot
  shows populated Claude 9%/4%, Codex 58%, and OpenCode 1%/0% cards.
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
- The uncommitted remediation isolates Herdr refreshes
  from the privacy-sensitive collector loop, fails closed on non-20 Herdr
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
- Herdr was live-handed off twice without terminating its 48 pane processes:
  first from stable v0.7.5 to reviewed v0.8.0/protocol 19, then from the build
  artifact to the canonical `~/.local/bin/herdr`. The old server exited only
  after the replacement acknowledged PTY ownership. Installed Herdr and XENEON
  binary hashes match their reviewed release artifacts; both user services,
  `xeneon-agentctl doctor`, and `scripts/check.sh` pass. Backups are retained in
  the user-owned Herdr and XENEON state directories. Approval and Windows
  guarded actions remain unavailable.

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
