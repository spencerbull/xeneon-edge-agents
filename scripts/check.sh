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
sys_root=/sys

usage() {
  cat <<'EOF'
Usage: scripts/check.sh [options]
  --root DIR
  --config-home DIR
  --data-home DIR
  --state-home DIR
  --bin-home DIR
  --sys-root DIR      Alternate read-only sysfs tree for tests
EOF
}

while (($#)); do
  case "$1" in
    --root) root_arg=${2:?missing value for --root}; shift 2 ;;
    --config-home) config_arg=${2:?missing value for --config-home}; shift 2 ;;
    --data-home) data_arg=${2:?missing value for --data-home}; shift 2 ;;
    --state-home) state_arg=${2:?missing value for --state-home}; shift 2 ;;
    --bin-home) bin_arg=${2:?missing value for --bin-home}; shift 2 ;;
    --sys-root) sys_root=${2:?missing value for --sys-root}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"

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

check_file "daemon service" "$systemd_dir/xeneon-agentd.service"
check_file "portal service" "$systemd_dir/xeneon-edge-portal.service"
check_file "named Quickshell config" "$config_home/quickshell/xeneon-edge-agents/shell.qml"
check_file "config" "$config_target"
check_file "commissioning config" "$commissioning_target"

for executable in xeneon-agentd xeneon-agentctl; do
  if [[ -x "$bin_home/$executable" ]]; then
    printf 'ok: executable: %s\n' "$bin_home/$executable"
  else
    printf 'missing: executable: %s\n' "$bin_home/$executable"
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
      done < <(find "$sys_root/class/drm" -mindepth 2 -maxdepth 2 -type f -name edid -print0 2>/dev/null)

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
    fi

    if [[ "$touch_enabled" != true || -z "$touch_device" ||
      "$touch_output" != "$connector" ]]; then
      printf 'unsafe: per-device touch mapping is incomplete\n'
      failures=$((failures + 1))
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

    portal_unit=$systemd_dir/xeneon-edge-portal.service
    if [[ -f "$portal_unit" ]]; then
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
      if ((adjacent_count != 1 || module_count != 1)); then
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
  fi
fi

if ((failures)); then
  printf 'check failed: %d problem(s)\n' "$failures"
  exit 1
fi

printf 'check passed\n'
