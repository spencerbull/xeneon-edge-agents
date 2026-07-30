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
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"

if ((!isolated_root)) && command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now xeneon-edge-portal.service xeneon-agentd.service 2>/dev/null || true
fi

hyprland_target=$hypr_dir/hyprland.lua
if [[ -f "$hypr_marker_path" ]]; then
  if [[ -f "$hyprland_target" ]]; then
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
      awk '
        previous ~ /^[[:space:]]*require\("hypr\.input"\)[[:space:]]*$/ &&
          $0 ~ /^[[:space:]]*require\("hypr\.xeneon_edge_agents"\)[[:space:]]*$/ {
            previous=$0
            next
          }
        { print; previous=$0 }
      ' "$hyprland_target" >"$temp"
      install -m 0644 "$temp" "$hyprland_target"
      rm -f "$temp" "$hypr_marker_path"
      note "Removed installer-owned Hyprland require."
    else
      warn "preserving changed Hyprland entrypoint: $hyprland_target"
    fi
  else
    rm -f "$hypr_marker_path"
  fi
fi

if [[ -f "$manifest_path" ]]; then
  while IFS=$'\t' read -r target installed_hash; do
    [[ -n "$target" ]] || continue
    if [[ ! -e "$target" ]]; then
      remove_manifest_entry "$target"
    elif [[ -f "$target" && "$(sha256_file "$target")" == "$installed_hash" ]]; then
      rm -f "$target"
      remove_manifest_entry "$target"
      note "Removed: $target"
    else
      warn "preserving modified user file: $target"
    fi
  done < <(cp "$manifest_path" /dev/stdout)
fi

for directory in \
  "$config_home/quickshell/xeneon-edge-agents" "$config_home/quickshell" \
  "$config_dir" "$systemd_dir" "$hypr_dir" \
  "$install_state_dir" "$state_home/$project_name"; do
  rmdir "$directory" 2>/dev/null || true
done

if ((!isolated_root)) && command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
fi

note "Uninstall complete. Modified user files, if any, were preserved."
