# Concept motion design QA

final result: passed

## Evidence

- Source visual truth: a local concept capture that is intentionally not
  committed to the repository.
- Rectified transition sheets, implementation captures, and tail comparisons
  were generated as ephemeral local QA artifacts.
- Viewport: 1280x360 logical pixels.
- Source: photographed 1280x720 frame perspective-rectified and normalized to
  1280x360 at density 1.
- Implementation: compositor capture at 2048x576 physical pixels, normalized
  to the same 1280x360 density-1 comparison size.
- States compared: operational cards, dashboard-to-radar transition, quiet
  constellation, and energetic orbit.

This is explicitly ephemeral local QA evidence, not a durable repository
artifact. Regenerate it from an authorized source capture before a later
release or review.

The full view keeps all critical detail legible at the native 1280x360
comparison size. Focused regions were evaluated through the active card grid
and the ambient center/trails in the same combined image; separate crops were
not necessary.

## Fidelity review

- Fonts and typography: passed. Both surfaces use a narrow technical
  monospaced hierarchy, uppercase labels, and tracked display copy. The
  concept's synthetic/blurred copy is not treated as literal product text.
- Spacing and layout rhythm: passed. The active 3x2 grid, compact header, and
  bottom telemetry preserve the source proportions. Ambient rings fill panel
  height, the center remains dominant, and nodes use nearby radii without
  rotating their labels.
- Colors and visual tokens: passed. The background, structural rings, and ice
  text match the concept family. State accents intentionally use live Codex
  Micro semantics rather than the concept's decorative rainbow.
- Image quality and asset fidelity: passed. The target contains procedural UI
  geometry rather than photographic app assets. Rings and trails remain sharp
  at the target viewport, with no placeholder images or substituted logos.
- Copy and content: passed. Live Herdr display labels and bounded health/voice
  enums replace the concept's synthetic names and telemetry.
- Motion: passed. Entry uses an opaque staged crossfade, center-out ring
  expansion, delayed node reveal, a 2.8-second quiet hold, and a gradual
  transition into independent clockwise orbits. Each agent now has one
  visually continuous tapered after-image built from eight bounded nested
  arcs. The authored one-second reverse drains velocity without rewinding,
  contracts the radar, and restores the control center in stages. Reduced
  motion renders the final static hierarchy.

## Intentional deviations

- The concept's left icon rail is omitted. The portal has no typed destinations
  for those controls, and copying it as dead navigation would imply unsupported
  authority.
- The source shows several unrelated decorative hues simultaneously. The
  implementation instead keys every node and trail to authoritative live agent
  state, so a mostly-working snapshot is correctly blue.
- The perimeter treatment was subsequently refined into one shadowed halo with
  two opposing clockwise runners. It now represents active agent execution
  only and disappears when every agent is idle or no agent is present; voice
  and review remain explicit elsewhere.

## Comparison history

### Pass 1

- P2: the ambient center read as a wide control capsule instead of a radar
  core.
- P2: orbital trails became prominent immediately, missing the concept's quiet
  hold before acceleration.
- P2: ambient capsules were too shallow compared with the reference.

Fixes:

- Replaced the wide center treatment with a 330x330 circular radar core.
- Added a 2.8-second hold and 1.6-second energy ramp, separating slow drift
  from the faster orbit/trail phase.
- Increased node height from 66 to 80 design pixels.

Post-fix evidence:
`/tmp/xeneon-concept-analysis.K0X10y/design-comparison-final.png`.

### Pass 2

- P2: the first trail revision read as discrete rail or bead segments rather
  than the source's broad comet-like after-image.
- P1: the first reverse implementation could visually rewind boosted orbit
  phase while draining motion.
- P1: the first easing compressed most control-center restoration into the
  final portion of the one-second exit.
- P1: visually hidden controls remained reachable through accessibility press
  actions during the transition.

Fixes:

- Rebuilt each trail as nested, same-head arcs: long layers are thin and dim,
  short layers thicken near the moving pill, producing one continuous tapered
  ribbon without a full-surface blur.
- Froze accumulated boost phase at exit and added a short forward coast.
- Switched the exit driver to linear time while preserving staged reveal
  windows across the full second.
- Hid transition controls from the accessibility tree and added enabled
  guards to page, agent, voice, health, and hold action paths.

Post-fix evidence:
`/tmp/xeneon-final-motion.1roWWj/tail-comparison-final.png`.
No actionable P0, P1, or P2 differences remain.

## Interaction and runtime checks

- The live preview consumed current Herdr labels and health state.
- The 1280x360 window remained mapped, opaque, and constrained to the explicit
  laptop preview path.
- The shortened preview-only timer exercised the transition and both ambient
  motion phases; production remains at 60 seconds.
- Computer Use resolved the correct Quickshell window, but Wayland denied its
  screenshot and synthetic-click paths. Direct compositor captures supplied
  the visual evidence instead. The source video itself ends in ambient and
  does not show an ambient-to-control-center transition, so the reverse is an
  authored inference rather than copied footage. Automated QML tests cover its
  temporal staging, clockwise exit coast, wake signaling, and accessibility
  shield until the fade is complete; physical touch remains a hardware gate.

## Follow-up polish

- P3: evaluate orbit brightness and GPU cost on the physical 2560x720 XENEON.
- P3: add a real left mode rail only if typed destinations and product behavior
  are designed for it.
