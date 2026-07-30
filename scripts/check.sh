#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$script_dir/lib.sh"

root_arg=
config_arg=
data_arg=
state_arg=
bin_arg=
package_prefix=
systemctl_command=
require_production=0
sys_root=/sys
hypr_devices_json=
hypr_monitors_json=

usage() {
  cat <<'EOF'
Usage: scripts/check.sh [options]
  --root DIR
  --config-home DIR
  --data-home DIR
  --state-home DIR
  --bin-home DIR
  --package-prefix DIR
                      Trusted static package prefix (package wrapper only)
  --systemctl-command FILE
                      Isolated-test service-manager stub (requires --root)
  --require-production
                      Fail unless exact production commissioning is active
  --sys-root DIR      Alternate read-only sysfs tree for tests
  --hypr-devices-json FILE
                      Alternate `hyprctl -j devices` payload for tests
  --hypr-monitors-json FILE
                      Alternate `hyprctl -j monitors all` payload for tests
EOF
}

while (($#)); do
  case "$1" in
    --root) root_arg=${2:?missing value for --root}; shift 2 ;;
    --config-home) config_arg=${2:?missing value for --config-home}; shift 2 ;;
    --data-home) data_arg=${2:?missing value for --data-home}; shift 2 ;;
    --state-home) state_arg=${2:?missing value for --state-home}; shift 2 ;;
    --bin-home) bin_arg=${2:?missing value for --bin-home}; shift 2 ;;
    --package-prefix)
      package_prefix=${2:?missing value for --package-prefix}
      shift 2
      ;;
    --systemctl-command)
      systemctl_command=${2:?missing value for --systemctl-command}
      shift 2
      ;;
    --require-production) require_production=1; shift ;;
    --sys-root) sys_root=${2:?missing value for --sys-root}; shift 2 ;;
    --hypr-devices-json)
      hypr_devices_json=${2:?missing value for --hypr-devices-json}
      shift 2
      ;;
    --hypr-monitors-json)
      hypr_monitors_json=${2:?missing value for --hypr-monitors-json}
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"

package_mode=0
runtime_bin_home=$bin_home
package_share=
package_systemd_dir=
if [[ -n "$package_prefix" ]]; then
  validate_path_argument "--package-prefix" "$package_prefix"
  package_prefix=$(canonical_dir "$package_prefix")
  if ((!isolated_root)) && [[ "$package_prefix" != /usr ]]; then
    die "live package checks require the canonical /usr prefix"
  fi
  package_mode=1
  runtime_bin_home=$package_prefix/bin
  package_share=$package_prefix/share/$project_name
  package_systemd_dir=$package_prefix/lib/systemd/user
fi

use_systemctl=0
if [[ -n "$systemctl_command" ]]; then
  ((package_mode)) ||
    die "--systemctl-command requires --package-prefix"
  ((isolated_root)) ||
    die "--systemctl-command is available only with isolated test paths"
  validate_path_argument "--systemctl-command" "$systemctl_command"
  systemctl_command=$(canonical_dir "$systemctl_command")
  [[ -f "$systemctl_command" && -x "$systemctl_command" && ! -L "$systemctl_command" ]] ||
    die "--systemctl-command must be an executable regular file"
  use_systemctl=1
elif ((package_mode && !isolated_root)) &&
  command -v systemctl >/dev/null 2>&1; then
  systemctl_command=$(command -v systemctl)
  use_systemctl=1
fi

failures=0
check_file() {
  local label=$1
  local path=$2
  if [[ -f "$path" ]]; then
    printf 'ok: %s: %s\n' "$label" "$path"
  else
    printf 'missing: %s: %s\n' "$label" "$path"
    failures=$((failures + 1))
  fi
}

config_target=$config_dir/config.toml
commissioning_target=$config_dir/commissioning.toml
module_target=$hypr_dir/xeneon_edge_agents.lua
hyprland_target=$hypr_dir/hyprland.lua

if ((package_mode)); then
  check_file "package daemon service" "$package_systemd_dir/xeneon-agentd.service"
  check_file "package portal service" "$package_systemd_dir/xeneon-edge-portal.service"
  check_file "package Quickshell config" "$package_share/quickshell/shell.qml"
  check_file "portal identity environment" "$config_dir/portal.env"
else
  check_file "daemon service" "$systemd_dir/xeneon-agentd.service"
  check_file "portal service" "$systemd_dir/xeneon-edge-portal.service"
  check_file "named Quickshell config" "$config_home/quickshell/xeneon-edge-agents/shell.qml"
fi
check_file "config" "$config_target"
check_file "commissioning config" "$commissioning_target"

for executable in xeneon-agentd xeneon-agentctl; do
  if [[ -x "$runtime_bin_home/$executable" ]]; then
    printf 'ok: executable: %s\n' "$runtime_bin_home/$executable"
  else
    printf 'missing: executable: %s\n' "$runtime_bin_home/$executable"
    failures=$((failures + 1))
  fi
done

if [[ -f "$commissioning_target" ]]; then
  mode=$(top_level_toml_value "$commissioning_target" mode)
  connector=$(toml_value "$commissioning_target" output connector)
  output_serial=$(toml_value "$commissioning_target" output serial)
  output_model=$(toml_value "$commissioning_target" output model)
  edid_sha=$(toml_value "$commissioning_target" output edid_sha256)
  exact=$(toml_value "$commissioning_target" output require_exact_match)
  fallback=$(toml_value "$commissioning_target" output allow_primary_fallback)
  touch_device=$(toml_value "$commissioning_target" touch device)
  touch_output=$(toml_value "$commissioning_target" touch output)
  touch_enabled=$(toml_value "$commissioning_target" touch enabled)
  touch_bustype=$(toml_value "$commissioning_target" touch bustype)
  touch_vendor=$(toml_value "$commissioning_target" touch vendor)
  touch_product=$(toml_value "$commissioning_target" touch product)
  touch_uniq=$(toml_value "$commissioning_target" touch uniq)
  touch_phys=$(toml_value "$commissioning_target" touch phys)

  if ((require_production)) && [[ "$mode" != production ]]; then
    printf 'blocked: production commissioning is required for this launch\n'
    failures=$((failures + 1))
  fi

  if [[ "$mode" == production ]]; then
    if [[ "$exact" != true || "$fallback" != false ]]; then
      printf 'unsafe: production output matching is not fail-closed\n'
      failures=$((failures + 1))
    elif ! [[ "$connector" =~ ^[A-Za-z0-9_.:-]+$ &&
      "$edid_sha" =~ ^[0-9a-fA-F]{64}$ &&
      "$output_serial" =~ ^[A-Za-z0-9_.:-]+$ &&
      "$output_model" =~ ^[A-Za-z0-9_.:\ -]+$ ]]; then
      printf 'unsafe: production output identity is incomplete\n'
      failures=$((failures + 1))
    else
      match_count=0
      while IFS= read -r -d '' edid_path; do
        candidate_connector=$(drm_connector_name "$edid_path")
        candidate_sha=$(sha256_file "$edid_path")
        candidate_status_path=$(dirname "$edid_path")/status
        candidate_status=
        if [[ -r "$candidate_status_path" ]]; then
          candidate_status=$(<"$candidate_status_path")
        fi
        if [[ "$candidate_status" == connected &&
          "$candidate_connector" == "$connector" &&
          "${candidate_sha,,}" == "${edid_sha,,}" ]]; then
          match_count=$((match_count + 1))
        fi
      done < <(
        find -L "$sys_root/class/drm" \
          -mindepth 2 -maxdepth 2 -type f -name edid -print0 2>/dev/null
      )

      case "$match_count" in
        1) printf 'ok: exact production output identity: %s\n' "$connector" ;;
        0)
          printf 'blocked: configured XENEON output is absent; physical gate remains closed\n'
          failures=$((failures + 1))
          ;;
        *)
          printf 'blocked: configured XENEON output identity is ambiguous (%d matches)\n' "$match_count"
          failures=$((failures + 1))
          ;;
      esac

      monitors_payload=
      monitors_inventory_available=0
      if [[ -n "$hypr_monitors_json" ]]; then
        if [[ -r "$hypr_monitors_json" ]]; then
          monitors_payload=$(<"$hypr_monitors_json")
          monitors_inventory_available=1
        else
          printf 'blocked: Hyprland monitor fixture is unreadable\n'
          failures=$((failures + 1))
        fi
      elif command -v hyprctl >/dev/null 2>&1; then
        if monitors_payload=$(hyprctl -j monitors all 2>/dev/null); then
          monitors_inventory_available=1
        else
          printf 'blocked: hyprctl monitor query failed\n'
          failures=$((failures + 1))
        fi
      else
        printf 'blocked: hyprctl is required to prove screen serial and model\n'
        failures=$((failures + 1))
      fi
      if ((monitors_inventory_available)); then
        monitor_match_count=$(
          python3 -c '
import json
import sys

connector, serial, model = sys.argv[1:4]
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    print(-1)
    raise SystemExit
print(sum(
    1
    for monitor in payload
    if monitor.get("name") == connector
    and monitor.get("serial") == serial
    and monitor.get("model") == model
))
' "$connector" "$output_serial" "$output_model" <<<"$monitors_payload"
        )
        case "$monitor_match_count" in
          1) printf 'ok: exact Hyprland screen serial and model\n' ;;
          -1)
            printf 'blocked: Hyprland monitor inventory is invalid JSON\n'
            failures=$((failures + 1))
            ;;
          0)
            printf 'blocked: configured Hyprland screen serial/model is absent\n'
            failures=$((failures + 1))
            ;;
          *)
            printf 'blocked: configured Hyprland screen identity is ambiguous (%d matches)\n' \
              "$monitor_match_count"
            failures=$((failures + 1))
            ;;
        esac
      fi
    fi

    if [[ "$touch_enabled" != true || -z "$touch_device" ||
      "$touch_output" != "$connector" ]]; then
      printf 'unsafe: per-device touch mapping is incomplete\n'
      failures=$((failures + 1))
    elif [[ "${touch_bustype,,}" != 0003 || "${touch_vendor,,}" != 1b1c ||
      ! "$touch_product" =~ ^[0-9a-fA-F]{4}$ ||
      ( -z "$touch_uniq" && -z "$touch_phys" ) ]]; then
      printf 'unsafe: Corsair USB touch identity is incomplete\n'
      failures=$((failures + 1))
    else
      devices_payload=
      devices_inventory_available=0
      if [[ -n "$hypr_devices_json" ]]; then
        if [[ -r "$hypr_devices_json" ]]; then
          devices_payload=$(<"$hypr_devices_json")
          devices_inventory_available=1
        else
          printf 'blocked: Hyprland touch-device fixture is unreadable\n'
          failures=$((failures + 1))
        fi
      elif command -v hyprctl >/dev/null 2>&1; then
        if devices_payload=$(hyprctl -j devices 2>/dev/null); then
          devices_inventory_available=1
        else
          printf 'blocked: hyprctl touch-device query failed\n'
          failures=$((failures + 1))
        fi
      else
        printf 'blocked: hyprctl is required to prove the touch-device identity\n'
        failures=$((failures + 1))
      fi

      if ((devices_inventory_available)); then
        touch_match_count=$(
          python3 -c '
import json
import sys

wanted = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    print(-1)
    raise SystemExit
touch = payload.get("touch", [])
print(sum(1 for device in touch if device.get("name") == wanted))
' "$touch_device" <<<"$devices_payload"
        )
        case "$touch_match_count" in
          1) printf 'ok: exact Hyprland touch device: %s\n' "$touch_device" ;;
          -1)
            printf 'blocked: Hyprland touch-device inventory is invalid JSON\n'
            failures=$((failures + 1))
            ;;
          0)
            printf 'blocked: configured Hyprland touch device is absent\n'
            failures=$((failures + 1))
            ;;
          *)
            printf 'blocked: configured Hyprland touch device is ambiguous (%d matches)\n' \
              "$touch_match_count"
            failures=$((failures + 1))
            ;;
        esac
      fi

      kernel_touch_match_count=0
      while IFS= read -r -d '' event_path; do
        properties=
        if [[ "$sys_root" == /sys ]] && command -v udevadm >/dev/null 2>&1; then
          properties=$(udevadm info --query=property --path="$event_path" 2>/dev/null || true)
        elif [[ -r "$event_path/device/properties" ]]; then
          properties=$(<"$event_path/device/properties")
        fi
        grep -Fqx 'ID_INPUT_TOUCHSCREEN=1' <<<"$properties" || continue

        for field in name id/bustype id/vendor id/product uniq phys; do
          [[ -r "$event_path/device/$field" ]] || continue 2
        done
        kernel_name=$(<"$event_path/device/name")
        kernel_bustype=$(<"$event_path/device/id/bustype")
        kernel_vendor=$(<"$event_path/device/id/vendor")
        kernel_product=$(<"$event_path/device/id/product")
        kernel_uniq=$(<"$event_path/device/uniq")
        kernel_phys=$(<"$event_path/device/phys")

        [[ "$(normalize_hypr_device_name "$kernel_name")" == "$touch_device" ]] ||
          continue
        [[ "${kernel_bustype,,}" == "${touch_bustype,,}" &&
          "${kernel_vendor,,}" == "${touch_vendor,,}" &&
          "${kernel_product,,}" == "${touch_product,,}" ]] ||
          continue
        [[ -z "$touch_uniq" || "$kernel_uniq" == "$touch_uniq" ]] || continue
        [[ -z "$touch_phys" || "$kernel_phys" == "$touch_phys" ]] || continue
        kernel_touch_match_count=$((kernel_touch_match_count + 1))
      done < <(
        find -L "$sys_root/class/input" \
          -mindepth 1 -maxdepth 1 -type d -name 'event*' -print0 2>/dev/null
      )

      case "$kernel_touch_match_count" in
        1)
          printf 'ok: exact Corsair USB touchscreen kernel identity\n'
          ;;
        0)
          printf 'blocked: configured Corsair USB touchscreen identity is absent\n'
          failures=$((failures + 1))
          ;;
        *)
          printf 'blocked: configured Corsair USB touchscreen identity is ambiguous (%d matches)\n' \
            "$kernel_touch_match_count"
          failures=$((failures + 1))
          ;;
      esac
    fi

    if [[ -f "$config_target" ]]; then
      daemon_connector=$(toml_value "$config_target" screen connector)
      daemon_serial=$(toml_value "$config_target" screen serial)
      daemon_model=$(toml_value "$config_target" screen model)
      daemon_touch=$(toml_value "$config_target" screen touch_device)
      daemon_output=$(toml_value "$config_target" desktop edge_output)
      if [[ "$daemon_connector" != "$connector" ||
        "$daemon_serial" != "$output_serial" ||
        "$daemon_model" != "$output_model" ||
        "$daemon_touch" != "$touch_device" ||
        "$daemon_output" != "$connector" ]]; then
        printf 'unsafe: daemon identity does not match commissioning identity\n'
        failures=$((failures + 1))
      fi
    fi

    if ((package_mode)); then
      if validate_portal_env \
        "$config_dir/portal.env" "$connector" "$output_serial" "$output_model"; then
        printf 'ok: package portal environment matches commissioning identity\n'
      else
        printf 'unsafe: package portal environment does not exactly match commissioning identity\n'
        failures=$((failures + 1))
      fi
    else
      portal_unit=$systemd_dir/xeneon-edge-portal.service
      for expected_environment in \
        "Environment=\"XENEON_EDGE_OUTPUT=$connector\"" \
        "Environment=\"XENEON_EDGE_SERIAL=$output_serial\"" \
        "Environment=\"XENEON_EDGE_MODEL=$output_model\""; do
        if ! grep -Fqx "$expected_environment" "$portal_unit"; then
          printf 'unsafe: portal service identity does not match commissioning identity\n'
          failures=$((failures + 1))
          break
        fi
      done
    fi

    check_file "Hyprland module" "$module_target"
    check_file "Hyprland entrypoint" "$hyprland_target"
    if [[ -f "$module_target" ]]; then
      if ! grep -Fqx "  name = \"$touch_device\"," "$module_target" ||
        ! grep -Fqx "  output = \"$connector\"," "$module_target"; then
        printf 'unsafe: Hyprland module does not match commissioning identity\n'
        failures=$((failures + 1))
      fi
      if command -v luac >/dev/null 2>&1; then
        if ! luac -p "$module_target"; then
          printf 'invalid: generated Hyprland module has Lua syntax errors\n'
          failures=$((failures + 1))
        fi
      fi
    fi
    if [[ -f "$hyprland_target" ]]; then
      adjacent_count=$(awk '
        previous ~ /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ &&
          $0 ~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/ { count++ }
        { previous=$0 }
        END { print count+0 }
      ' "$hyprland_target")
      module_count=$(grep -Ec '^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$' "$hyprland_target" || true)
      if ((module_count == 0 && adjacent_count == 0)); then
        printf 'ok: Hyprland integration is staged but not active\n'
      elif ((module_count == 1 && adjacent_count == 1)); then
        printf 'ok: Hyprland integration is active\n'
      else
        printf 'unsafe: expected exactly one XENEON require immediately after hypr.input\n'
        failures=$((failures + 1))
      fi
      if command -v luac >/dev/null 2>&1; then
        if ! luac -p "$hyprland_target"; then
          printf 'invalid: Hyprland entrypoint has Lua syntax errors\n'
          failures=$((failures + 1))
        fi
      fi
    fi
  else
    printf 'blocked: simulation config matches no production output; physical gate remains closed\n'
    if ((package_mode)) &&
      ! validate_portal_env "$config_dir/portal.env" "" "" ""; then
      printf 'unsafe: simulation portal environment is not fail-closed\n'
      failures=$((failures + 1))
    fi
  fi
elif ((require_production)); then
  printf 'blocked: production commissioning file is missing\n'
  failures=$((failures + 1))
fi

if ((package_mode && (!isolated_root || use_systemctl))); then
  if ((!use_systemctl)); then
    printf 'missing: systemctl is required to resolve package user units\n'
    failures=$((failures + 1))
  else
    for unit in xeneon-agentd.service xeneon-edge-portal.service; do
      expected_fragment=$package_systemd_dir/$unit
      fragment=
      drop_ins=
      fragment_query_ok=1
      dropin_query_ok=1
      fragment=$(
        "$systemctl_command" --user show \
          --property=FragmentPath --value "$unit" 2>/dev/null
      ) || fragment_query_ok=0
      drop_ins=$(
        "$systemctl_command" --user show \
          --property=DropInPaths --value "$unit" 2>/dev/null
      ) || dropin_query_ok=0
      if ((fragment_query_ok && dropin_query_ok)) &&
        [[ "$fragment" == "$expected_fragment" ]] &&
        [[ ! "$drop_ins" =~ [^[:space:]] ]]; then
        printf 'ok: package unit resolution: %s\n' "$fragment"
      else
        if ((!fragment_query_ok || !dropin_query_ok)); then
          printf 'unsafe: could not inspect the complete %s unit definition\n' \
            "$unit"
        elif [[ "$fragment" != "$expected_fragment" ]]; then
          printf 'unsafe: %s resolves to %s instead of %s\n' \
            "$unit" "${fragment:-<missing>}" "$expected_fragment"
        else
          printf 'unsafe: %s has unsupported systemd drop-ins: %s\n' \
            "$unit" "$drop_ins"
        fi
        failures=$((failures + 1))
      fi
    done
  fi
fi

if ((failures)); then
  printf 'check failed: %d problem(s)\n' "$failures"
  exit 1
fi

printf 'check passed\n'
