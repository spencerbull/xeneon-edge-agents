# XENEON EDGE concept motion study

## Source

- File: local concept capture, intentionally not committed.
- Media: H.264, 1280x720, 24 fps, 240 frames, 10.083 seconds
- The photographed EDGE content was perspective-rectified to 1280x360 for
  comparison with the portal preview. The synthetic names and telemetry in the
  concept are visual hierarchy only; live portal copy remains daemon-owned.

## Storyboard

| Time | Visible behavior | Implementation consequence |
| --- | --- | --- |
| 0.00-2.25 s | Stable compact header, 3x2 cards, and slim telemetry strip | Keep the operational portal and real Herdr data path unchanged |
| 2.25-2.75 s | Dashboard globally dims while the first center reticle appears | Use an opaque staged crossfade, not a card-to-node identity morph |
| 2.75-3.75 s | Concentric radar rings expand outward with a smooth ease-out | Reveal structural rings from the center on entry |
| 3.75-4.25 s | Center label and up to fourteen neutral capsules fade and scale in, then colorize | Stage center before nodes and derive node color from normalized state |
| 4.25-7.25 s | Quiet ambient hold with subtle drift and breathing | Preserve a glanceable low-power hierarchy before stronger motion |
| 7.25-10.08 s | Upright capsules orbit clockwise while soft, tapered colored after-images intensify | Preserve the original independent speeds, angles, and radii exactly through six agents, then extend that advancing-and-crossing multi-lane character with smaller capsules and fourteen bounded radii through fourteen agents |

The source ends in ambient mode and does not show the reverse transition. The
implemented ambient-to-control-center path deliberately mirrors its visual
grammar: nodes and their tails recede first, rings contract into the center,
then the dark curtain lifts while the header, cards, and health strip resolve
back into place. This is an implementation inference, not a frame copied from
the source.

## Visual contract

- Near-black navy canvas with dim slate/cyan structural geometry.
- Narrow uppercase monospaced display type with generous tracking.
- Bright ice/cyan system copy and low-contrast blue-gray metadata.
- Agent color retains the reviewed Codex Micro semantic meaning while taking
  its blue/yellow/green/error hues from the active Omarchy palette. Capsule
  strokes, quiet glow layers, and their trail segments share the same state
  accent.
- The strong halo is an on-canvas tapered after-image. Overlapping segments
  share one path, fall off quadratically, and leave a small gap behind the
  capsule so the tail reads as motion instead of parallel orbit rails.
- The dense seven-to-fourteen-agent composition keeps every capsule and halo
  inside the constellation while independent integer-rate lanes intentionally
  advance, cross, and sometimes overlap. Reduced motion alone uses static,
  evenly spaced nodes.
- The perimeter light is one GPU-blurred status bloom with two opposing
  clockwise runners, short soft glints, and six bounded trailing motes per
  runner. It represents active agent execution only: working is blue, blocked
  is amber, and the halo disappears when every agent is idle or no agent is
  present. Voice and review-ready state remain explicit in the center/header
  treatments instead of creating unrelated edge motion.
- Voice can override the center and ambient treatment through the existing
  bounded `idle`, `recording`, `processing`, `error`, and `unavailable`
  protocol states. QML does not infer audio level or transcript content.
- Reduced motion renders the final centered constellation at fixed positions,
  removes the agent trails and the two perimeter runners, and disables
  continuous orbit.
- The global Motion and Screen controls remain reachable in the upper-right
  corner in both Ambient and control-center views. Their state persists across
  view changes and portal restarts.

## Product boundaries

- The reference's left icon rail is not copied because the portal has no typed
  destinations for those controls. Decorative dead navigation would imply
  capabilities that do not exist.
- Agent nodes remain passive during ambient mode; the whole surface wakes the
  operational dashboard. Safe Herdr actions remain on the cards.
- The concept's roughly 2.25-second transition point is presentation timing,
  not the production inactivity policy. Production remains 60 seconds. The
  explicit preview supports a shorter bounded timeout for animation review.
- `SCREEN // MINIMUM` is a reversible near-black portal veil. It deliberately
  does not claim to change panel hardware brightness; DDC/CI remains gated on
  an exact read/restore validation for this display.
- Physical XENEON touch, GPU cost, and perceived brightness remain hardware
  gates.
