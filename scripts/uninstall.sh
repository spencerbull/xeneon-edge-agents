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

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [options]
  --root DIR
  --config-home DIR
  --data-home DIR
  --state-home DIR
  --bin-home DIR
  --package-prefix DIR
                      Trusted static package prefix (package wrapper only)
  --systemctl-command FILE
                      Isolated-test service-manager stub (requires --root)

Only unchanged files recorded by the installer are removed. Modified user
files are preserved. The Hyprland require is removed only if this installer
recorded inserting it.
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
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"

package_mode=0
if [[ -n "$package_prefix" ]]; then
  validate_path_argument "--package-prefix" "$package_prefix"
  package_prefix=$(canonical_dir "$package_prefix")
  if ((!isolated_root)) && [[ "$package_prefix" != /usr ]]; then
    die "live package uninstall requires the canonical /usr prefix"
  fi
  package_mode=1
fi

use_systemctl=0
if [[ -n "$systemctl_command" ]]; then
  ((isolated_root)) ||
    die "--systemctl-command is available only with isolated test paths"
  validate_path_argument "--systemctl-command" "$systemctl_command"
  systemctl_command=$(canonical_dir "$systemctl_command")
  [[ -f "$systemctl_command" && -x "$systemctl_command" && ! -L "$systemctl_command" ]] ||
    die "--systemctl-command must be an executable regular file"
  use_systemctl=1
elif ((!isolated_root)) && command -v systemctl >/dev/null 2>&1; then
  systemctl_command=$(command -v systemctl)
  use_systemctl=1
fi

daemon_target=$systemd_dir/xeneon-agentd.service
portal_target=$systemd_dir/xeneon-edge-portal.service
preflight_installer_state
owned_units=()
service_units=(xeneon-edge-portal.service xeneon-agentd.service)
service_targets=("$portal_target" "$daemon_target")
if ((package_mode)); then
  if ((!use_systemctl && !isolated_root)); then
    die "systemctl is required to uninstall live package services"
  fi
  if ((use_systemctl)); then
    "$systemctl_command" --user daemon-reload ||
      die "could not contact the user service manager; no files were removed"
    for unit in "${service_units[@]}"; do
      expected_fragment=$package_prefix/lib/systemd/user/$unit
      fragment=$(
        "$systemctl_command" --user show \
          --property=FragmentPath --value "$unit"
      )
      drop_ins=$(
        "$systemctl_command" --user show \
          --property=DropInPaths --value "$unit"
      )
      [[ "$fragment" == "$expected_fragment" ]] ||
        die "refusing to uninstall while $unit resolves outside the package: ${fragment:-<missing>}"
      if [[ "$drop_ins" =~ [^[:space:]] ]]; then
        die "refusing to uninstall while $unit has systemd drop-ins: $drop_ins"
      fi
    done
  fi
  owned_units=("${service_units[@]}")
else
  for index in "${!service_units[@]}"; do
    unit=${service_units[$index]}
    target=${service_targets[$index]}
    installed_hash=$(manifest_hash "$target" 2>/dev/null || true)
    [[ -n "$installed_hash" ]] || continue
    if [[ ! -e "$target" && ! -L "$target" ]]; then
      owned_units+=("$unit")
    elif [[ ! -L "$target" && -f "$target" &&
      "$(sha256_file "$target")" == "$installed_hash" ]]; then
      owned_units+=("$unit")
    else
      die "refusing to uninstall while a managed service unit is modified: $target"
    fi
  done
fi

if ((use_systemctl)) && ((${#owned_units[@]})); then
  "$systemctl_command" --user daemon-reload ||
    die "could not contact the user service manager; no files were removed"
  for unit in "${owned_units[@]}"; do
    enabled_state=$(
      "$systemctl_command" --user is-enabled "$unit" 2>/dev/null || true
    )
    case "$enabled_state" in
      enabled|enabled-runtime|disabled) ;;
      *) die "could not determine stable enabled state for $unit: ${enabled_state:-<missing>}" ;;
    esac
  done
  disable_user_services_all_scopes \
    "$systemctl_command" \
    "${owned_units[@]}" ||
    die "could not stop and disable XENEON services; no files were removed"
  for unit in "${owned_units[@]}"; do
    if "$systemctl_command" --user is-active --quiet "$unit"; then
      die "refusing to remove unit files while $unit is still active"
    fi
    enabled_state=$(
      "$systemctl_command" --user is-enabled "$unit" 2>/dev/null || true
    )
    [[ "$enabled_state" == disabled ]] ||
      die "refusing to remove unit files while $unit remains enabled: ${enabled_state:-<missing>}"
  done
fi

hyprland_target=$hypr_dir/hyprland.lua
module_target=$hypr_dir/xeneon_edge_agents.lua
preserve_module=0
hypr_entrypoint_changed=0
if [[ -f "$hypr_marker_path" && ! -L "$hypr_marker_path" ]]; then
  if [[ -L "$hyprland_target" ]]; then
    warn "preserving replaced Hyprland symlink: $hyprland_target"
    preserve_module=1
  elif [[ -f "$hyprland_target" ]]; then
    input_count=$(grep -Ec '^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$' "$hyprland_target" || true)
    module_count=$(grep -Ec '^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$' "$hyprland_target" || true)
    adjacent_count=$(awk '
      previous ~ /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ &&
        $0 ~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/ { count++ }
      { previous=$0 }
      END { print count+0 }
    ' "$hyprland_target")

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
      warn "preserving changed Hyprland entrypoint: $hyprland_target"
      preserve_module=1
    fi
  else
    rm -f "$hypr_marker_path"
  fi
fi

if ((!preserve_module)); then
  if [[ -L "$hyprland_target" ]]; then
    warn "preserving module because the Hyprland entrypoint is a symlink"
    preserve_module=1
  elif [[ -f "$hyprland_target" ]] &&
    grep -Eq '^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$' \
      "$hyprland_target"; then
    warn "preserving module referenced by a user-owned Hyprland require"
    preserve_module=1
  fi
fi

if [[ -f "$manifest_path" ]]; then
  while IFS=$'\t' read -r target installed_hash; do
    [[ -n "$target" ]] || continue
    if ((preserve_module)) && [[ "$target" == "$module_target" ]]; then
      warn "preserving Hyprland module referenced by a changed entrypoint: $target"
    elif [[ ! -e "$target" && ! -L "$target" ]]; then
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

for directory in \
  "$config_home/quickshell/xeneon-edge-agents" "$config_home/quickshell" \
  "$data_home/$project_name/scripts" "$data_home/$project_name" \
  "$config_dir" "$systemd_dir" "$hypr_dir" \
  "$install_state_dir" "$state_home/$project_name"; do
  rmdir "$directory" 2>/dev/null || true
done

if ((use_systemctl)) && ((${#owned_units[@]})); then
  "$systemctl_command" --user daemon-reload ||
    warn "user service files were removed but daemon-reload failed"
fi

note "Uninstall complete. Modified user files, if any, were preserved."
