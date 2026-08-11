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

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [options]
  --root DIR
  --config-home DIR
  --data-home DIR
  --state-home DIR
  --bin-home DIR

Only unchanged files recorded by the installer are removed. Modified user
files are preserved. The Hyprland require is removed only if this installer
recorded inserting it. Uninstall refuses to proceed while another active
Hyprland require would retain the managed module without its dependencies.
EOF
}

while (($#)); do
  case "$1" in
    --root) root_arg=${2:?missing value for --root}; shift 2 ;;
    --config-home) config_arg=${2:?missing value for --config-home}; shift 2 ;;
    --data-home) data_arg=${2:?missing value for --data-home}; shift 2 ;;
    --state-home) state_arg=${2:?missing value for --state-home}; shift 2 ;;
    --bin-home) bin_arg=${2:?missing value for --bin-home}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"

daemon_target=$systemd_dir/xeneon-agentd.service
portal_target=$systemd_dir/xeneon-edge-portal.service
reconcile_target=$systemd_dir/xeneon-edge-reconcile.service
input_path_target=$systemd_dir/xeneon-edge-input.path
owned_units=()
reconcile_owned=0
runtime_dir=
uninstall_gate=
uninstall_gate_active=0
service_units=(
  xeneon-edge-input.path
  xeneon-edge-reconcile.service
  xeneon-edge-portal.service
  xeneon-agentd.service
)
service_targets=(
  "$input_path_target"
  "$reconcile_target"
  "$portal_target"
  "$daemon_target"
)
for index in "${!service_units[@]}"; do
  unit=${service_units[$index]}
  target=${service_targets[$index]}
  installed_hash=$(manifest_hash "$target" 2>/dev/null || true)
  [[ -n "$installed_hash" ]] || continue
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    owned_units+=("$unit")
    if [[ "$unit" == xeneon-edge-reconcile.service ]]; then
      reconcile_owned=1
    fi
  elif [[ ! -L "$target" && -f "$target" &&
    "$(sha256_file "$target")" == "$installed_hash" ]]; then
    owned_units+=("$unit")
    if [[ "$unit" == xeneon-edge-reconcile.service ]]; then
      reconcile_owned=1
    fi
  else
    die "refusing to uninstall while a managed service unit is modified: $target"
  fi
done

remove_uninstall_gate() {
  if ((uninstall_gate_active)); then
    if rmdir -- "$uninstall_gate"; then
      uninstall_gate_active=0
    else
      warn "could not remove uninstall gate: $uninstall_gate"
    fi
  fi
}
trap remove_uninstall_gate EXIT

hyprland_target=$hypr_dir/hyprland.lua
input_count=0
module_count=0
module_reference_count=0
adjacent_count=0
if [[ -f "$hyprland_target" ]]; then
  input_count=$(grep -Ec '^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$' "$hyprland_target" || true)
  module_count=$(grep -Ec '^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$' "$hyprland_target" || true)
  module_reference_count=$(grep -c 'xeneon_edge_agents' "$hyprland_target" || true)
  adjacent_count=$(awk '
    previous ~ /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ &&
      $0 ~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/ { count++ }
    { previous=$0 }
    END { print count+0 }
  ' "$hyprland_target")
fi

if ((module_reference_count > 0)); then
  if [[ -L "$hyprland_target" ]]; then
    die "refusing to uninstall while a symlinked Hyprland entrypoint retains the XENEON module"
  elif [[ ! -f "$hypr_marker_path" ]] ||
    ((input_count != 1 || module_count != 1 || adjacent_count != 1 ||
      module_reference_count != 1)); then
    die "refusing to uninstall while a user-owned or changed Hyprland require retains the XENEON module; remove that require first"
  fi
fi

if ((!isolated_root)) && ((${#owned_units[@]})) &&
  command -v systemctl >/dev/null 2>&1; then
  runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  validate_path_argument "runtime directory" "$runtime_dir"
  runtime_dir=$(canonical_dir "$runtime_dir")
  validate_path_argument "canonical runtime directory" "$runtime_dir"
  uninstall_gate=$runtime_dir/xeneon-edge-agents-uninstalling
  mkdir -m 0700 -- "$uninstall_gate" ||
    die "refusing to replace an existing uninstall gate: $uninstall_gate"
  uninstall_gate_active=1
  systemctl --user daemon-reload ||
    die "could not contact the user service manager; no files were removed"
  systemctl --user disable --now "${owned_units[@]}" ||
    die "could not stop and disable XENEON services; no files were removed"
  for unit in "${owned_units[@]}"; do
    if systemctl --user is-active --quiet "$unit"; then
      die "refusing to remove unit files while $unit is still active"
    fi
  done
  if ((reconcile_owned)); then
    systemctl --user clean --what=runtime xeneon-edge-reconcile.service ||
      die "could not clean the XENEON runtime directory; no files were removed"
  fi
fi

hypr_entrypoint_changed=0
if [[ -f "$hypr_marker_path" ]]; then
  if [[ -L "$hyprland_target" ]]; then
    rm -f "$hypr_marker_path"
  elif [[ -f "$hyprland_target" ]]; then
    if ((input_count == 1 && module_count == 1 && adjacent_count == 1)); then
      temp=$(mktemp "$install_state_dir/hyprland.XXXXXX")
      hyprland_mode=$(stat -c '%a' "$hyprland_target")
      awk '
        previous ~ /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ &&
          $0 ~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/ {
            previous=$0
            next
          }
        { print; previous=$0 }
      ' "$hyprland_target" >"$temp"
      install -m "$hyprland_mode" "$temp" "$hyprland_target"
      rm -f "$temp" "$hypr_marker_path"
      hypr_entrypoint_changed=1
      note "Removed installer-owned Hyprland require."
    else
      rm -f "$hypr_marker_path"
    fi
  else
    rm -f "$hypr_marker_path"
  fi
fi

if [[ -f "$manifest_path" ]]; then
  while IFS=$'\t' read -r target installed_hash; do
    [[ -n "$target" ]] || continue
    if [[ ! -e "$target" && ! -L "$target" ]]; then
      remove_manifest_entry "$target"
    elif [[ ! -L "$target" && -f "$target" &&
      "$(sha256_file "$target")" == "$installed_hash" ]]; then
      rm -f "$target"
      remove_manifest_entry "$target"
      note "Removed: $target"
    else
      warn "preserving modified user file: $target"
    fi
  done < <(cp "$manifest_path" /dev/stdout)
fi

if ((hypr_entrypoint_changed && !isolated_root)); then
  if ! command -v hyprctl >/dev/null 2>&1; then
    warn "Hyprland entrypoint changed; run hyprctl reload to apply removal"
  elif ! hyprctl reload >/dev/null; then
    warn "Hyprland reload failed after removal; run hyprctl reload"
  elif ! config_errors=$(hyprctl configerrors 2>/dev/null); then
    warn "could not validate Hyprland configerrors after removal"
  elif [[ -n "$config_errors" ]]; then
    warn "Hyprland reports config errors after removal: $config_errors"
  else
    note "Reloaded and validated Hyprland after removing the integration."
  fi
fi

if ((!isolated_root)) && [[ -d "$data_home/applications" ]] &&
  command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$data_home/applications" ||
    warn "files were removed but the application cache refresh failed"
fi

remove_uninstall_gate

for directory in \
  "$config_home/quickshell/xeneon-edge-agents" "$config_home/quickshell" \
  "$data_home/applications" "$data_home/icons/hicolor/scalable/apps" \
  "$data_home/icons/hicolor/scalable" "$data_home/icons/hicolor" \
  "$data_home/icons" \
  "$config_dir" "$systemd_dir" "$hypr_dir" \
  "$install_state_dir" "$state_home/$project_name"; do
  rmdir "$directory" 2>/dev/null || true
done

if ((!isolated_root)) && ((${#owned_units[@]})) &&
  command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload ||
    warn "user service files were removed but daemon-reload failed"
fi

note "Uninstall complete. Modified user files, if any, were preserved."
