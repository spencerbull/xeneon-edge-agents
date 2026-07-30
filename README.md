# XENEON EDGE Agent Command Center

A native Omarchy command center for the Corsair XENEON EDGE. It keeps Herdr as
the session and interaction authority while providing a dedicated 2560x720
touch surface for agent status, safe triage, and compact system health.

The software path is implemented and simulator-tested. Physical display and
touch commissioning is still intentionally open because the XENEON EDGE was
not connected during development. Production output matching is fail-closed:
the portal creates no surface unless connector, model, and serial all match
exactly and uniquely.

## Components

- `xeneon-agentd`: Rust user daemon for Herdr state, host health, safe actions,
  reconnects, and output/focus integration.
- `xeneon-agentctl qml-bridge`: NDJSON bridge used by Quickshell.
- `quickshell/`: standalone touch portal and deterministic fixture preview.
- `config/` and `scripts/`: reversible user-service and Omarchy integration.

Herdr remains authoritative. The portal can never send arbitrary text, keys,
or shell commands. Open and zoom are narrow public Herdr API calls. Interrupt
requires a short-lived capability issued and revalidated by a compatible Herdr
server; approval is deliberately unavailable until a current prompt can be
grounded safely.

## Develop and preview

Requirements on Omarchy are Rust, Quickshell, Qt 6 QML tooling, Lua's `luac`,
Python 3, Herdr, and `just` through mise.

```bash
mise install
mise exec -- just check
mise run preview
```

The preview is a normal 1280x360 window on the current display and uses a
deterministic fixture. It is the only path that may use the primary display.
Other fixture states can be selected explicitly:

```bash
scripts/preview health.ndjson
scripts/preview disconnected.ndjson
```

## Install without activating

Install the two local binaries, then seed simulator-safe user configuration:

```bash
cargo install --path crates/xeneon-agentd --root "$HOME/.local" --force
cargo install --path crates/xeneon-agentctl --root "$HOME/.local" --force
scripts/install.sh
```

The default installer copies the named Quickshell configuration and rendered
user units but does not enable either service, edit Hyprland, or match any
production output. Existing user-owned or modified files are refused or
preserved.

```bash
scripts/check.sh
scripts/uninstall.sh
```

`check.sh` reports the physical gate as blocked in simulation mode. Uninstall
removes only installer-recorded files whose content is unchanged.

## Commission the physical EDGE

First capture the connected hardware identity without changing anything:

```bash
scripts/detect-hardware.sh
```

Production installation requires all five values together:

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
non-empty `uniq`; providing both is allowed and requires both to match. A live
production install performs the full output and touchscreen check before
changing any user file. Add `--activate` only after that exact identity passes
while the device is connected. The generated Hyprland module uses a per-device
output mapping and leaves Omarchy's `monitors.lua` ownership untouched.

The remaining physical checklist covers touch coordinates, focus restoration,
hotplug, DPMS, suspend/resume, lock-screen privacy, and read-only DDC discovery.
Brightness control stays disabled until exact read/restore is proven.

See [architecture](docs/architecture.md), [protocol](docs/protocol.md), and
[commissioning](docs/commissioning.md) for the boundaries and verification
details. `TODO.md` is the resumable implementation ledger.
