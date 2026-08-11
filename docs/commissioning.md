# XENEON EDGE commissioning

## Safety model

There are three distinct modes:

1. Fixture preview creates one ordinary window on the current display.
2. Simulator installation writes user-owned files but creates no production
   portal surface and enables no service.
3. Production activation requires a connected display identity, a per-device
   touch mapping, successful offline validation, and explicit `--activate`.
   Thereafter only the lightweight reconciler autostarts; the daemon and portal
   run while the exact commissioned hardware is present.

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

- the current DRM connector as the commissioning-time hint;
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
  --touch-vendor '<EXACT-USB-VENDOR-ID>' \
  --touch-product '<EXACT-USB-PRODUCT-ID>' \
  --touch-phys '<EXACT-KERNEL-PHYS>'
```

Use `--touch-uniq` when the device exposes a stable non-empty `uniq`; `phys` is
used only as a fallback when `uniq` is empty because USB topology paths can
change across boots. Both may be recorded, but runtime identity prefers the
device-provided `uniq`. The USB bus
must be `0003`; vendor and product IDs are captured from the actual touchscreen
and are not inferred from the display brand. The commissioned XENEON EDGE unit
exposes its touch controller as `wch.cn-touchscreen-1`, USB `27c0:0859`, rather
than through the separate Corsair `1b1c:1d0d` control endpoint.

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

The commissioned EDID hash, serial/model, and USB touchscreen identity remain
stable authority. On each Hyprland start, monitor add, or monitor removal, the
reconciler discovers the connector currently carrying that EDID and verifies
the same connector against Hyprland. It writes that connector to a private
runtime environment consumed by both services. Quickshell then requires
exactly one screen with the resolved connector and model before it creates a
layer surface, and also requires the exact serial when Qt's Wayland backend
exposes that EDID field. Some compositors leave `QScreen.serialNumber` empty
even after the Hyprland gate has succeeded.

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
  --touch-vendor '<EXACT-USB-VENDOR-ID>' \
  --touch-product '<EXACT-USB-PRODUCT-ID>' \
  --touch-phys '<EXACT-KERNEL-PHYS>'
```

Then verify:

```bash
systemctl --user status \
  xeneon-edge-reconcile.service \
  xeneon-agentd.service \
  xeneon-edge-portal.service
xeneon-agentctl doctor
hyprctl configerrors
```

Activation validates the candidate files, reloads Hyprland, disables direct
autostart of the application services, enables the reconciler, and performs an
initial reconciliation. Unplugging the exact display stops the portal and
daemon. Reconnecting it on any connector starts both with the newly resolved
connector only after every identity gate passes. The input path watcher also
reconciles USB-only changes; the commissioned touch device is synchronously
disabled during transitions and re-enabled only with its verified output.

Physical acceptance requires all of the following:

- only the EDGE receives the portal surface;
- unplugging the EDGE creates no laptop fallback surface;
- touch maps to the complete EDGE and never another output;
- tapping passive UI restores the previously active non-EDGE window;
- tapping an ordinary agent card focuses that exact Herdr agent;
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
