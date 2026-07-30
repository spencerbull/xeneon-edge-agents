# XENEON EDGE commissioning

## Safety model

There are three distinct modes:

1. Fixture preview creates one ordinary window on the current display.
2. Simulator installation writes user-owned files but creates no production
   portal surface and enables no service.
3. Production activation requires a connected display identity, a per-device
   touch mapping, successful offline validation, and explicit `--activate`.

No mode edits `/usr/share/omarchy`. Production staging writes the generated
module without changing the active Hyprland entrypoint. Explicit activation
adds one `require("hypr.xeneon_edge_agents")` immediately after the existing
`require("hypr.input")` in the user entrypoint. It does not modify
`monitors.lua`.

## Capture identity

Run:

```bash
scripts/detect-hardware.sh
```

Record:

- the exact DRM connector;
- the SHA-256 of that connector's non-empty EDID;
- the exact serial and model exposed to Hyprland/Qt;
- the normalized exact touchscreen name from `hyprctl -j devices`;
- the touchscreen's kernel bus, vendor, product, and stable `phys` or `uniq`;
- the observed 2560x720 logical and physical touch coordinate behavior.

Do not infer an identity from the Corsair brand alone. Multiple or missing
matches keep the gate closed.

## Stage production files

Use the captured values:

```bash
scripts/install.sh \
  --apply-production \
  --connector '<DRM-CONNECTOR>' \
  --edid-sha256 '<64-CHARACTER-EDID-SHA256>' \
  --screen-serial '<EXACT-EDID-SERIAL>' \
  --screen-model '<EXACT-SCREEN-MODEL>' \
  --touch-device '<EXACT-HYPRLAND-DEVICE-NAME>' \
  --touch-bustype '0003' \
  --touch-vendor '1b1c' \
  --touch-product '<EXACT-USB-PRODUCT-ID>' \
  --touch-phys '<EXACT-KERNEL-PHYS>'
```

Use `--touch-uniq` instead of `--touch-phys` when the device exposes a stable
non-empty `uniq`; both may be supplied to require both matches. The USB bus
must be `0003` and the vendor must be Corsair's `1b1c`; the product ID is
captured from the actual touchscreen and is not guessed.

On a live user installation, the script first builds the candidate files in an
isolated temporary root and checks the requested identity against real DRM,
Hyprland, and input-device inventories. If any identity is absent or ambiguous,
it exits before changing a user file. Without `--activate`, a passing install
stages configuration and the generated Hyprland module, but does not add its
require or alter either service state. Inspect and verify it:

```bash
scripts/check.sh
luac -p "$HOME/.config/hypr/xeneon_edge_agents.lua"
```

The portal service receives connector, serial, and model independently of the
daemon config. Quickshell requires all three to match one screen before it
creates a layer surface. Its managed launcher reruns the exact production,
hardware, and active Hyprland checks on every service start, so staged
configuration cannot become a live portal after a login or restart.

## Activate and verify

Activation is explicit:

```bash
scripts/install.sh \
  --apply-production \
  --activate \
  --connector '<DRM-CONNECTOR>' \
  --edid-sha256 '<64-CHARACTER-EDID-SHA256>' \
  --screen-serial '<EXACT-EDID-SERIAL>' \
  --screen-model '<EXACT-SCREEN-MODEL>' \
  --touch-device '<EXACT-HYPRLAND-DEVICE-NAME>' \
  --touch-bustype '0003' \
  --touch-vendor '1b1c' \
  --touch-product '<EXACT-USB-PRODUCT-ID>' \
  --touch-phys '<EXACT-KERNEL-PHYS>'
```

Then verify:

```bash
systemctl --user status xeneon-agentd.service xeneon-edge-portal.service
xeneon-agentctl doctor
hyprctl configerrors
```

Activation validates the candidate files, reloads Hyprland, and starts new
services or restarts already-active services so the commissioned identity is
effective immediately.

Physical acceptance requires all of the following:

- only the EDGE receives the portal surface;
- unplugging the EDGE creates no laptop fallback surface;
- touch maps to the complete EDGE and never another output;
- tapping passive UI restores the previously active non-EDGE window;
- open and zoom intentionally focus the exact Herdr session;
- guarded actions cancel on drag/release and fire once after an 800 ms hold;
- lock, DPMS, hotplug, and suspend/resume do not leak or relocate the surface;
- DDC probing is read-only and any future write can restore the exact prior
  value.

## Remove

```bash
scripts/uninstall.sh
```

The uninstaller disables installer-owned services, removes unchanged
installer-recorded files, and removes the Hyprland require only when the
installer recorded inserting it. It refuses to proceed when a managed service
unit was modified, so a live service cannot be left running after its
dependencies are removed. Modified non-service files and pre-existing requires
are preserved. When the entrypoint changes, the live path reloads Hyprland and
checks `hyprctl configerrors`.
