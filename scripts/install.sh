#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
# shellcheck source=scripts/lib.sh
source "$script_dir/lib.sh"

root_arg=
config_arg=
data_arg=
state_arg=
bin_arg=
apply_production=0
activate=0
connector=
edid_sha=
output_serial=
output_model=
touch_device=
quickshell_source=$repo_root/quickshell

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options]

Install user-owned config and service templates without enabling them.

Paths:
  --root DIR          Isolated root using DIR/.config and DIR/.local/*
  --config-home DIR   Explicit XDG config directory
  --data-home DIR     Explicit XDG data directory
  --state-home DIR    Explicit XDG state directory
  --bin-home DIR      Directory containing xeneon-agentd/xeneon-agentctl
  --quickshell-source DIR
                      Source tree containing shell.qml (package/test staging)

Production commissioning (all values required together):
  --apply-production
  --connector NAME
  --edid-sha256 HASH
  --screen-serial SERIAL
  --screen-model MODEL
  --touch-device NAME

Runtime:
  --activate           Enable and start both user services after checks pass

The default is simulator-safe: it seeds a config that matches no production
output, does not edit hyprland.lua, and does not call systemctl.
EOF
}

while (($#)); do
  case "$1" in
    --root) root_arg=${2:?missing value for --root}; shift 2 ;;
    --config-home) config_arg=${2:?missing value for --config-home}; shift 2 ;;
    --data-home) data_arg=${2:?missing value for --data-home}; shift 2 ;;
    --state-home) state_arg=${2:?missing value for --state-home}; shift 2 ;;
    --bin-home) bin_arg=${2:?missing value for --bin-home}; shift 2 ;;
    --quickshell-source) quickshell_source=${2:?missing value for --quickshell-source}; shift 2 ;;
    --apply-production) apply_production=1; shift ;;
    --connector) connector=${2:?missing value for --connector}; shift 2 ;;
    --edid-sha256) edid_sha=${2:?missing value for --edid-sha256}; shift 2 ;;
    --screen-serial) output_serial=${2:?missing value for --screen-serial}; shift 2 ;;
    --screen-model) output_model=${2:?missing value for --screen-model}; shift 2 ;;
    --touch-device) touch_device=${2:?missing value for --touch-device}; shift 2 ;;
    --activate) activate=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"

if ((activate && isolated_root)); then
  die "--activate is not available with --root"
fi

if ((apply_production)); then
  validate_commissioning_values \
    "$connector" "$edid_sha" "$output_serial" "$output_model" "$touch_device"
elif [[ -n "$connector$edid_sha$output_serial$output_model$touch_device" ]]; then
  die "hardware identity options require --apply-production"
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

daemon_unit=$temp_dir/xeneon-agentd.service
portal_unit=$temp_dir/xeneon-edge-portal.service
render_template \
  "$repo_root/config/systemd/user/xeneon-agentd.service.in" "$daemon_unit" \
  CONFIG_HOME "$config_home" STATE_HOME "$state_home" BIN_HOME "$bin_home"
render_template \
  "$repo_root/config/systemd/user/xeneon-edge-portal.service.in" "$portal_unit" \
  CONFIG_HOME "$config_home" BIN_HOME "$bin_home" \
  OUTPUT_CONNECTOR "$connector" OUTPUT_SERIAL "$output_serial" OUTPUT_MODEL "$output_model"

daemon_target=$systemd_dir/xeneon-agentd.service
portal_target=$systemd_dir/xeneon-edge-portal.service
config_target=$config_dir/config.toml
commissioning_target=$config_dir/commissioning.toml
module_target=$hypr_dir/xeneon_edge_agents.lua
hyprland_target=$hypr_dir/hyprland.lua
quickshell_target=$config_home/quickshell/xeneon-edge-agents

# Preflight every managed overwrite before making any change. A collision
# therefore leaves no partial installation to roll back.
preflight_managed_target "$daemon_unit" "$daemon_target"
preflight_managed_target "$portal_unit" "$portal_target"

quickshell_sources=()
quickshell_targets=()
if [[ -f "$quickshell_source/shell.qml" ]]; then
  while IFS= read -r -d '' source; do
    relative=${source#"$quickshell_source"/}
    quickshell_sources+=("$source")
    quickshell_targets+=("$quickshell_target/$relative")
    preflight_managed_target "$source" "$quickshell_target/$relative"
  done < <(
    find "$quickshell_source" -type f \
      ! -path "$quickshell_source/tests/*" -print0 | sort -z
  )
else
  warn "Quickshell source is absent; named config was not installed: $quickshell_source"
fi

production_config=
production_commissioning=
production_module=
if ((apply_production)); then
  production_config=$temp_dir/config.toml
  render_template \
    "$repo_root/config/xeneon-edge-agents/config.toml.production.in" "$production_config" \
    OUTPUT_CONNECTOR "$connector" OUTPUT_SERIAL "$output_serial" \
    OUTPUT_MODEL "$output_model" TOUCH_DEVICE "$touch_device"
  production_commissioning=$temp_dir/commissioning.toml
  sed \
    -e 's/^mode = "simulation"$/mode = "production"/' \
    -e "s|^connector = \"\"$|connector = \"$connector\"|" \
    -e "s|^serial = \"\"$|serial = \"$output_serial\"|" \
    -e "s|^model = \"\"$|model = \"$output_model\"|" \
    -e "s|^edid_sha256 = \"\"$|edid_sha256 = \"${edid_sha,,}\"|" \
    -e "s|^device = \"\"$|device = \"$touch_device\"|" \
    -e "s|^output = \"\"$|output = \"$connector\"|" \
    -e 's/^enabled = false$/enabled = true/' \
    "$repo_root/config/xeneon-edge-agents/commissioning.toml.example" >"$production_commissioning"
  render_template \
    "$repo_root/config/hypr/xeneon_edge_agents.lua.in" "$temp_dir/xeneon_edge_agents.lua" \
    TOUCH_DEVICE "$touch_device" OUTPUT_CONNECTOR "$connector"
  production_module=$temp_dir/xeneon_edge_agents.lua

  if [[ -e "$config_target" ]]; then
    preflight_managed_target "$production_config" "$config_target"
  fi
  if [[ -e "$commissioning_target" ]]; then
    preflight_managed_target "$production_commissioning" "$commissioning_target"
  fi
  preflight_managed_target "$production_module" "$module_target"

  [[ -f "$hyprland_target" ]] ||
    die "--apply-production requires an existing user-owned $hyprland_target"
  command -v luac >/dev/null 2>&1 ||
    die "--apply-production requires luac for offline syntax validation"
  luac -p "$hyprland_target" ||
    die "existing Hyprland entrypoint has invalid Lua syntax"
  luac -p "$production_module" ||
    die "generated Hyprland module has invalid Lua syntax"

  input_count=$(grep -Ec '^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$' "$hyprland_target" || true)
  module_count=$(grep -Ec '^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$' "$hyprland_target" || true)
  ((input_count == 1)) ||
    die "expected exactly one require(\"hypr.input\") in $hyprland_target"
  ((module_count <= 1)) ||
    die "ambiguous XENEON require lines in $hyprland_target"
  if ((module_count == 1)); then
    adjacent_count=$(awk '
      previous ~ /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ &&
        $0 ~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/ { count++ }
      { previous=$0 }
      END { print count+0 }
    ' "$hyprland_target")
    ((adjacent_count == 1)) ||
      die "existing XENEON require must immediately follow require(\"hypr.input\")"
  fi
fi

install_managed_file "$daemon_unit" "$daemon_target"
install_managed_file "$portal_unit" "$portal_target"
for index in "${!quickshell_sources[@]}"; do
  install_managed_file \
    "${quickshell_sources[$index]}" "${quickshell_targets[$index]}"
done

if ((apply_production)); then
  install_managed_file "$production_config" "$config_target" 0600
  install_managed_file "$production_commissioning" "$commissioning_target" 0600
  install_managed_file "$production_module" "$module_target"

  if ((module_count == 0)); then
    hypr_temp=$temp_dir/hyprland.lua
    awk '
      { print }
      /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ {
        print "require(\"hypr.xeneon_edge_agents\")"
      }
    ' "$hyprland_target" >"$hypr_temp"
    install -m 0644 "$hypr_temp" "$hyprland_target"
    mkdir -p "$install_state_dir"
    : >"$hypr_marker_path"
  else
    if [[ -f "$hypr_marker_path" ]]; then
      note "Hyprland require is already installer-managed."
    else
      note "Preserved existing Hyprland require (not claimed by installer)."
    fi
  fi
else
  seed_user_file \
    "$repo_root/config/xeneon-edge-agents/config.toml.example" \
    "$config_target"
  seed_user_file \
    "$repo_root/config/xeneon-edge-agents/commissioning.toml.example" \
    "$commissioning_target"
fi

mkdir -p "$state_home/$project_name"

if ((activate)); then
  "$script_dir/check.sh" \
    --config-home "$config_home" --data-home "$data_home" \
    --state-home "$state_home" --bin-home "$bin_home"
  if ((apply_production)); then
    command -v hyprctl >/dev/null 2>&1 ||
      die "production activation requires a running Hyprland session"
    hyprctl reload
    config_errors=$(hyprctl configerrors)
    [[ -z "$config_errors" ]] ||
      die "Hyprland reported config errors: $config_errors"
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now xeneon-agentd.service xeneon-edge-portal.service
fi

note "Installed XENEON EDGE user integration."
note "Config: $config_target"
if ((!activate)); then
  note "Services were not enabled."
fi
if ((!apply_production)); then
  note "Physical gate remains closed; run detect-hardware.sh before production commissioning."
fi
