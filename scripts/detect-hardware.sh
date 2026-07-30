#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$script_dir/lib.sh"

sys_root=/sys
runtime_tools=1

usage() {
  cat <<'EOF'
Usage: scripts/detect-hardware.sh [--sys-root DIR]

Read-only commissioning report. It reads compositor, DRM/EDID, USB, input, and
DDC capability state. It never installs packages, changes mappings, sets DDC
values, or writes vendor HID features. An alternate --sys-root disables live
compositor, USB, input, and DDC probes so fixture tests stay isolated.
EOF
}

while (($#)); do
  case "$1" in
    --sys-root)
      sys_root=${2:?missing value for --sys-root}
      runtime_tools=0
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

found_identity=0

printf 'XENEON EDGE hardware commissioning report (read-only)\n\n'
printf '[Hyprland monitors]\n'
if ((!runtime_tools)); then
  printf 'skipped: alternate sysfs root selected\n'
elif command -v hyprctl >/dev/null 2>&1; then
  hypr_output=$(hyprctl -j monitors all 2>&1 || true)
  printf '%s\n' "$hypr_output"
  if grep -Eqi 'xeneon[[:space:]_-]*edge|corsair' <<<"$hypr_output"; then
    found_identity=1
  fi
else
  printf 'unavailable: hyprctl is not installed or not on PATH\n'
fi

printf '\n[DRM connectors and EDID]\n'
edid_count=0
while IFS= read -r -d '' edid_path; do
  edid_bytes=$(wc -c <"$edid_path" 2>/dev/null || printf '0')
  ((edid_bytes > 0)) || continue
  edid_count=$((edid_count + 1))
  connector=$(drm_connector_name "$edid_path")
  status_path=$(dirname "$edid_path")/status
  if [[ -r "$status_path" ]]; then
    status=$(<"$status_path")
  else
    status=unknown
  fi
  edid_sha=$(sha256_file "$edid_path")
  printf 'connector=%s status=%s edid_sha256=%s\n' "$connector" "$status" "$edid_sha"

  if command -v edid-decode >/dev/null 2>&1; then
    decoded=$(edid-decode "$edid_path" 2>/dev/null || true)
    printf '%s\n' "$decoded" |
      grep -E 'Manufacturer:|Display Product Name:|Display Product Serial Number:|Product Code:|Serial Number:' ||
      true
    if grep -Eqi 'xeneon[[:space:]_-]*edge|corsair' <<<"$decoded"; then
      found_identity=1
    fi
  else
    printf 'decoder=unavailable (install nothing; edid_sha256 is still usable)\n'
  fi

  if strings "$edid_path" 2>/dev/null | grep -Eqi 'xeneon[[:space:]_-]*edge|corsair'; then
    found_identity=1
  fi
done < <(
  find -L "$sys_root/class/drm" \
    -mindepth 2 -maxdepth 2 -type f -name edid -print0 2>/dev/null
)
((edid_count)) || printf 'none: no connected connector exposed a non-empty EDID\n'

printf '\n[USB]\n'
if ((!runtime_tools)); then
  printf 'skipped: alternate sysfs root selected\n'
elif command -v lsusb >/dev/null 2>&1; then
  usb_output=$(lsusb 2>&1 || true)
  printf '%s\n' "$usb_output"
  if grep -Eqi 'xeneon[[:space:]_-]*edge|corsair' <<<"$usb_output"; then
    found_identity=1
  fi
else
  printf 'unavailable: lsusb is not installed or not on PATH\n'
fi

printf '\n[Touch devices]\n'
if ((!runtime_tools)); then
  printf 'skipped: alternate sysfs root selected\n'
elif command -v hyprctl >/dev/null 2>&1; then
  hyprctl -j devices 2>&1 || true
elif command -v libinput >/dev/null 2>&1; then
  libinput list-devices 2>&1 || true
else
  printf 'unavailable: neither hyprctl nor libinput is on PATH\n'
fi

printf '\n[Touch kernel identities]\n'
kernel_touch_count=0
if ((!runtime_tools)); then
  printf 'skipped: alternate sysfs root selected\n'
else
  while IFS= read -r -d '' event_path; do
    properties=
    if command -v udevadm >/dev/null 2>&1; then
      properties=$(udevadm info --query=property --path="$event_path" 2>/dev/null || true)
    fi
    grep -Fqx 'ID_INPUT_TOUCHSCREEN=1' <<<"$properties" || continue
    for field in name id/bustype id/vendor id/product uniq phys; do
      [[ -r "$event_path/device/$field" ]] || continue 2
    done
    kernel_touch_count=$((kernel_touch_count + 1))
    kernel_name=$(<"$event_path/device/name")
    kernel_bustype=$(<"$event_path/device/id/bustype")
    kernel_vendor=$(<"$event_path/device/id/vendor")
    kernel_product=$(<"$event_path/device/id/product")
    kernel_uniq=$(<"$event_path/device/uniq")
    kernel_phys=$(<"$event_path/device/phys")
    printf 'event=%s hypr_name=%s kernel_name=%s bustype=%s vendor=%s product=%s uniq=%s phys=%s\n' \
      "$(basename "$event_path")" \
      "$(normalize_hypr_device_name "$kernel_name")" \
      "$kernel_name" "$kernel_bustype" "$kernel_vendor" "$kernel_product" \
      "${kernel_uniq:-<empty>}" "${kernel_phys:-<empty>}"
  done < <(
    find -L /sys/class/input \
      -mindepth 1 -maxdepth 1 -type d -name 'event*' -print0 2>/dev/null
  )
  ((kernel_touch_count)) ||
    printf 'none: udev reported no touchscreen input identities\n'
fi

printf '\n[DDC/CI read capability]\n'
if ((!runtime_tools)); then
  printf 'skipped: alternate sysfs root selected\n'
elif command -v ddcutil >/dev/null 2>&1; then
  ddcutil detect --brief 2>&1 || true
  printf 'probe=read-only; brightness writes remain disabled\n'
else
  printf 'unavailable: ddcutil is not installed or not on PATH\n'
fi

printf '\n'
if ((found_identity)); then
  printf 'candidate detected: capture one connector, EDID SHA-256, and exact Hyprland touch-device name.\n'
  printf 'physical gate remains pending until touch, hotplug, DPMS, suspend, focus, privacy, and DDC restore are tested.\n'
else
  printf 'PHYSICAL GATE BLOCKED: no unambiguous Corsair XENEON EDGE identity was detected.\n'
  printf 'No configuration was changed.\n'
fi
