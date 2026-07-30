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
touch_bustype=
touch_vendor=
touch_product=
touch_uniq=
touch_phys=
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
  --touch-bustype HEX
  --touch-vendor HEX
  --touch-product HEX
  --touch-uniq VALUE   Stable kernel uniq (optional when phys is provided)
  --touch-phys VALUE   Stable kernel phys (optional when uniq is provided)

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
    --touch-bustype) touch_bustype=${2:?missing value for --touch-bustype}; shift 2 ;;
    --touch-vendor) touch_vendor=${2:?missing value for --touch-vendor}; shift 2 ;;
    --touch-product) touch_product=${2:?missing value for --touch-product}; shift 2 ;;
    --touch-uniq) touch_uniq=${2:?missing value for --touch-uniq}; shift 2 ;;
    --touch-phys) touch_phys=${2:?missing value for --touch-phys}; shift 2 ;;
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
    "$connector" "$edid_sha" "$output_serial" "$output_model" "$touch_device" \
    "$touch_bustype" "$touch_vendor" "$touch_product" "$touch_uniq" "$touch_phys"
elif [[ -n "$connector$edid_sha$output_serial$output_model$touch_device$touch_bustype$touch_vendor$touch_product$touch_uniq$touch_phys" ]]; then
  die "hardware identity options require --apply-production"
fi

temp_dir=$(mktemp -d)
rollback_hypr=0
rollback_services=0
rollback_artifacts=0
rollback_daemon_reload=0
hyprland_backup=
module_backup=
module_existed=0
module_previous_manifest_hash=
marker_existed=0
hyprland_mode=0644
activation_manifest_backup=
activation_manifest_existed=0
activation_artifact_targets=()
activation_artifact_backups=()
activation_artifact_existed=()
service_units=(xeneon-agentd.service xeneon-edge-portal.service)
service_previous_active=()
service_previous_enabled=()

cleanup() {
  local status=$?
  trap - EXIT
  if ((status != 0 && rollback_artifacts)); then
    warn "restoring prior managed files after failed activation"
    for index in "${!activation_artifact_targets[@]}"; do
      target=${activation_artifact_targets[$index]}
      backup=${activation_artifact_backups[$index]}
      if ((${activation_artifact_existed[$index]})); then
        mkdir -p "$(dirname "$target")"
        cp -p -- "$backup" "$target"
      else
        rm -f -- "$target"
      fi
    done
  fi
  if ((status != 0 && rollback_hypr)); then
    warn "rolling back Hyprland integration after failed commissioning"
    if [[ -n "$hyprland_backup" && -f "$hyprland_backup" ]]; then
      install -m "$hyprland_mode" "$hyprland_backup" "$hyprland_target"
    fi
    if ((module_existed)); then
      install -m 0644 "$module_backup" "$module_target"
      if [[ -n "$module_previous_manifest_hash" ]]; then
        write_manifest_entry "$module_target" "$module_previous_manifest_hash"
      else
        remove_manifest_entry "$module_target"
      fi
    else
      rm -f "$module_target"
      remove_manifest_entry "$module_target"
    fi
    if ((marker_existed)); then
      mkdir -p "$install_state_dir"
      : >"$hypr_marker_path"
    else
      rm -f "$hypr_marker_path"
    fi
    if ((!isolated_root)) && command -v hyprctl >/dev/null 2>&1; then
      hyprctl reload >/dev/null 2>&1 ||
        warn "Hyprland reload failed after rollback; run hyprctl reload"
    fi
  fi
  if ((status != 0 && rollback_artifacts)); then
    if ((activation_manifest_existed)); then
      mkdir -p "$install_state_dir"
      cp -p -- "$activation_manifest_backup" "$manifest_path"
    else
      rm -f -- "$manifest_path"
    fi
  fi
  if ((status != 0 && rollback_daemon_reload)); then
    systemctl --user daemon-reload >/dev/null 2>&1 ||
      warn "user service daemon-reload failed during rollback"
  fi
  if ((status != 0 && rollback_services)); then
    warn "restoring prior user-service state after failed activation"
    for index in "${!service_units[@]}"; do
      unit=${service_units[$index]}
      if [[ "${service_previous_active[$index]}" == active ]]; then
        systemctl --user restart "$unit" >/dev/null 2>&1 ||
          warn "could not restore active state for $unit"
      else
        systemctl --user stop "$unit" >/dev/null 2>&1 ||
          warn "could not stop newly activated $unit"
      fi
      case "${service_previous_enabled[$index]}" in
        enabled|enabled-runtime|linked|linked-runtime|alias)
          systemctl --user enable "$unit" >/dev/null 2>&1 ||
            warn "could not restore enabled state for $unit"
          ;;
        *)
          systemctl --user disable "$unit" >/dev/null 2>&1 ||
            warn "could not remove newly enabled state for $unit"
          ;;
      esac
    done
  fi
  rm -rf "$temp_dir"
  exit "$status"
}
trap cleanup EXIT

snapshot_activation_artifact() {
  local target=$1
  local index=${#activation_artifact_targets[@]}
  local backup=$temp_dir/activation-artifact-$index

  activation_artifact_targets+=("$target")
  activation_artifact_backups+=("$backup")
  if [[ -f "$target" && ! -L "$target" ]]; then
    cp -p -- "$target" "$backup"
    activation_artifact_existed+=(1)
  else
    activation_artifact_existed+=(0)
  fi
}

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

if [[ -f "$commissioning_target" ]] &&
  [[ "$(top_level_toml_value "$commissioning_target" mode)" == production ]] &&
  ((!apply_production)); then
  die "existing production commissioning requires --apply-production with its exact identity"
fi

# Preflight every managed overwrite before making any change. A collision
# therefore leaves no partial installation to roll back.
preflight_managed_target "$daemon_unit" "$daemon_target"
preflight_managed_target "$portal_unit" "$portal_target"

quickshell_sources=()
quickshell_targets=()
declare -A current_quickshell_targets=()
if [[ -f "$quickshell_source/shell.qml" ]]; then
  while IFS= read -r -d '' source; do
    relative=${source#"$quickshell_source"/}
    quickshell_sources+=("$source")
    quickshell_targets+=("$quickshell_target/$relative")
    current_quickshell_targets["$quickshell_target/$relative"]=1
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
    -e "s|^bustype = \"\"$|bustype = \"${touch_bustype,,}\"|" \
    -e "s|^vendor = \"\"$|vendor = \"${touch_vendor,,}\"|" \
    -e "s|^product = \"\"$|product = \"${touch_product,,}\"|" \
    -e "s|^uniq = \"\"$|uniq = \"$touch_uniq\"|" \
    -e "s|^phys = \"\"$|phys = \"$touch_phys\"|" \
    -e 's/^enabled = false$/enabled = true/' \
    "$repo_root/config/xeneon-edge-agents/commissioning.toml.example" >"$production_commissioning"
  render_template \
    "$repo_root/config/hypr/xeneon_edge_agents.lua.in" "$temp_dir/xeneon_edge_agents.lua" \
    TOUCH_DEVICE "$touch_device" OUTPUT_CONNECTOR "$connector"
  production_module=$temp_dir/xeneon_edge_agents.lua

  if [[ -e "$config_target" || -L "$config_target" ]]; then
    preflight_managed_target "$production_config" "$config_target"
  fi
  if [[ -e "$commissioning_target" || -L "$commissioning_target" ]]; then
    preflight_managed_target "$production_commissioning" "$commissioning_target"
  fi
  preflight_managed_target "$production_module" "$module_target"

  [[ -f "$hyprland_target" ]] ||
    die "--apply-production requires an existing user-owned $hyprland_target"
  [[ ! -L "$hyprland_target" ]] ||
    die "refusing to rewrite symlinked Hyprland entrypoint: $hyprland_target"
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
    ((activate)) ||
      die "production staging cannot retain an active XENEON require; rerun with --activate"
  fi
fi

if ((apply_production && !isolated_root)); then
  for executable in xeneon-agentd xeneon-agentctl; do
    [[ -x "$bin_home/$executable" ]] ||
      die "production commissioning requires executable $bin_home/$executable"
  done
  PATH="$bin_home:/usr/local/bin:/usr/bin" command -v quickshell >/dev/null 2>&1 ||
    die "production commissioning requires quickshell on the service PATH"
  command -v hyprctl >/dev/null 2>&1 ||
    die "production commissioning requires a running Hyprland session"
  PATH="$bin_home:/usr/local/bin:/usr/bin" command -v herdr >/dev/null 2>&1 ||
    die "production commissioning requires herdr on the service PATH"

  preflight_root=$temp_dir/live-hardware-preflight
  mkdir -p "$preflight_root/.config/hypr" "$preflight_root/.local/bin"
  awk '
    $0 !~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/
  ' "$hyprland_target" >"$preflight_root/.config/hypr/hyprland.lua"
  ln -s "$bin_home/xeneon-agentd" \
    "$preflight_root/.local/bin/xeneon-agentd"
  ln -s "$bin_home/xeneon-agentctl" \
    "$preflight_root/.local/bin/xeneon-agentctl"
  preflight_touch_identity=(
    --touch-bustype "$touch_bustype"
    --touch-vendor "$touch_vendor"
    --touch-product "$touch_product"
  )
  [[ -z "$touch_uniq" ]] ||
    preflight_touch_identity+=(--touch-uniq "$touch_uniq")
  [[ -z "$touch_phys" ]] ||
    preflight_touch_identity+=(--touch-phys "$touch_phys")
  "$script_dir/install.sh" \
    --root "$preflight_root" \
    --quickshell-source "$quickshell_source" \
    --apply-production \
    --connector "$connector" \
    --edid-sha256 "$edid_sha" \
    --screen-serial "$output_serial" \
    --screen-model "$output_model" \
    --touch-device "$touch_device" \
    "${preflight_touch_identity[@]}" >/dev/null
  if ! "$script_dir/check.sh" --root "$preflight_root" \
    >"$preflight_root/check.log" 2>&1; then
    sed -n '1,160p' "$preflight_root/check.log" >&2
    die "live XENEON hardware identity did not pass; no live files were changed"
  fi
  note "Verified live XENEON output and touchscreen identity before installation."
fi

if ((activate)); then
  snapshot_activation_artifact "$daemon_target"
  snapshot_activation_artifact "$portal_target"
  for target in "${quickshell_targets[@]}"; do
    snapshot_activation_artifact "$target"
  done
  if ((apply_production)); then
    snapshot_activation_artifact "$config_target"
    snapshot_activation_artifact "$commissioning_target"
  else
    [[ -e "$config_target" || -L "$config_target" ]] ||
      snapshot_activation_artifact "$config_target"
    [[ -e "$commissioning_target" || -L "$commissioning_target" ]] ||
      snapshot_activation_artifact "$commissioning_target"
  fi
  if [[ -f "$manifest_path" ]]; then
    activation_manifest_backup=$temp_dir/managed.tsv.backup
    cp -p -- "$manifest_path" "$activation_manifest_backup"
    activation_manifest_existed=1
  fi
  rollback_artifacts=1
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

  if ((activate)); then
    hyprland_backup=$temp_dir/hyprland.lua.backup
    cp -p "$hyprland_target" "$hyprland_backup"
    hyprland_mode=$(stat -c '%a' "$hyprland_target")
    if [[ -f "$module_target" ]]; then
      module_existed=1
      module_backup=$temp_dir/xeneon_edge_agents.lua.backup
      cp -p "$module_target" "$module_backup"
      module_previous_manifest_hash=$(manifest_hash "$module_target" 2>/dev/null || true)
    fi
    [[ -f "$hypr_marker_path" ]] && marker_existed=1
    rollback_hypr=1

    install_managed_file "$production_module" "$module_target"

    if ((module_count == 0)); then
      hypr_temp=$temp_dir/hyprland.lua
      awk '
        { print }
        /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ {
          print "require(\"hypr.xeneon_edge_agents\")"
        }
      ' "$hyprland_target" >"$hypr_temp"
      install -m "$hyprland_mode" "$hypr_temp" "$hyprland_target"
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
    install_managed_file "$production_module" "$module_target"
    note "Staged Hyprland module without changing the active entrypoint."
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
  rollback_daemon_reload=1
  systemctl --user daemon-reload
  for unit in "${service_units[@]}"; do
    active_state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    case "$active_state" in
      active|inactive|failed) ;;
      *) die "could not determine stable active state for $unit" ;;
    esac
    service_previous_active+=("$active_state")

    enabled_state=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    case "$enabled_state" in
      enabled|enabled-runtime|linked|linked-runtime|alias|disabled) ;;
      *) die "could not determine stable enabled state for $unit" ;;
    esac
    service_previous_enabled+=("$enabled_state")
  done
  rollback_services=1
  systemctl --user enable "${service_units[@]}"
  for index in "${!service_units[@]}"; do
    unit=${service_units[$index]}
    if [[ "${service_previous_active[$index]}" == active ]]; then
      systemctl --user restart "$unit"
    else
      systemctl --user start "$unit"
    fi
  done
  rollback_services=0
  rollback_daemon_reload=0
  rollback_hypr=0
  rollback_artifacts=0
fi

# Retire files removed or renamed in the packaged Quickshell tree. Only paths
# still carrying their installer-recorded hash are deleted. Locally modified
# files remain both on disk and in the manifest so uninstall can preserve them.
if [[ -f "$quickshell_source/shell.qml" && -f "$manifest_path" ]]; then
  while IFS=$'\t' read -r managed_target installed_hash; do
    [[ "$managed_target" == "$quickshell_target/"* ]] || continue
    [[ -z "${current_quickshell_targets["$managed_target"]+x}" ]] || continue
    if [[ ! -e "$managed_target" && ! -L "$managed_target" ]]; then
      remove_manifest_entry "$managed_target"
    elif [[ ! -L "$managed_target" && -f "$managed_target" &&
      "$(sha256_file "$managed_target")" == "$installed_hash" ]]; then
      rm -f "$managed_target"
      remove_manifest_entry "$managed_target"
      note "Removed obsolete managed file: $managed_target"
    else
      warn "preserving modified obsolete Quickshell file: $managed_target"
    fi
  done < <(cp "$manifest_path" /dev/stdout)
  find "$quickshell_target" -depth -type d -empty -delete 2>/dev/null || true
fi

note "Installed XENEON EDGE user integration."
note "Config: $config_target"
if ((!activate)); then
  note "Services were not enabled."
fi
if ((!apply_production)); then
  note "Physical gate remains closed; run detect-hardware.sh before production commissioning."
fi
rollback_hypr=0
rollback_services=0
rollback_artifacts=0
rollback_daemon_reload=0
