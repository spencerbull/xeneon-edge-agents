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
Usage: scripts/migrate-package.sh --package-prefix DIR [options]
  --root DIR
  --config-home DIR
  --data-home DIR
  --state-home DIR
  --bin-home DIR
  --package-prefix DIR
  --systemctl-command FILE
                      Isolated-test service-manager stub (requires --root)

Migrate from the repository installer to package-owned static assets. Only
unchanged manifest-recorded user service units and QML files are removed.
TOML commissioning, Hyprland integration, and modified user files are
preserved. Migrated legacy services are stopped and disabled; an established
package unit's existing service state is preserved.
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

[[ -n "$package_prefix" ]] || die "--package-prefix is required"
validate_path_argument "--package-prefix" "$package_prefix"
package_prefix=$(canonical_dir "$package_prefix")
resolve_xdg_paths "$root_arg" "$config_arg" "$data_arg" "$state_arg" "$bin_arg"
preflight_installer_state

use_systemctl=0
if [[ -n "$systemctl_command" ]]; then
  ((isolated_root)) ||
    die "--systemctl-command is available only with isolated test paths"
  validate_path_argument "--systemctl-command" "$systemctl_command"
  systemctl_command=$(canonical_dir "$systemctl_command")
  [[ -f "$systemctl_command" && -x "$systemctl_command" && ! -L "$systemctl_command" ]] ||
    die "--systemctl-command must be an executable regular file"
  use_systemctl=1
elif ((!isolated_root)); then
  systemctl_command=$(command -v systemctl) ||
    die "systemctl is required to migrate live user services"
  use_systemctl=1
fi

if ((!isolated_root)) && [[ "$package_prefix" != /usr ]]; then
  die "live package migration requires the canonical /usr prefix"
fi

package_share=$package_prefix/share/$project_name
package_systemd_dir=$package_prefix/lib/systemd/user
required_package_files=(
  "$package_share/quickshell/shell.qml"
  "$package_systemd_dir/xeneon-agentd.service"
  "$package_systemd_dir/xeneon-edge-portal.service"
  "$package_prefix/lib/$project_name/scripts/check.sh"
  "$package_prefix/lib/$project_name/scripts/launch-package-portal.sh"
  "$package_prefix/lib/$project_name/scripts/lib.sh"
)
for required_file in "${required_package_files[@]}"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] ||
    die "package asset is missing or not a regular file: $required_file"
done
for executable in xeneon-agentd xeneon-agentctl; do
  [[ -x "$package_prefix/bin/$executable" && ! -L "$package_prefix/bin/$executable" ]] ||
    die "package executable is missing or not a regular file: $package_prefix/bin/$executable"
done
for executable in check.sh launch-package-portal.sh lib.sh; do
  package_executable=$package_prefix/lib/$project_name/scripts/$executable
  [[ -x "$package_executable" && ! -L "$package_executable" ]] ||
    die "package executable is missing or not a regular file: $package_executable"
done

service_units=(xeneon-agentd.service xeneon-edge-portal.service)
legacy_service_targets=(
  "$systemd_dir/xeneon-agentd.service"
  "$systemd_dir/xeneon-edge-portal.service"
)
removable_service_targets=()
removable_service_units=()
removable_service_by_index=(0 0)
missing_service_manifest_targets=()

# Preflight all masking user units before changing service or filesystem state.
for index in "${!legacy_service_targets[@]}"; do
  target=${legacy_service_targets[$index]}
  installed_hash=$(manifest_hash "$target" 2>/dev/null || true)
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    [[ -z "$installed_hash" ]] ||
      missing_service_manifest_targets+=("$target")
    continue
  fi
  if [[ -n "$installed_hash" && ! -L "$target" && -f "$target" ]] &&
    [[ "$(sha256_file "$target")" == "$installed_hash" ]]; then
    removable_service_targets+=("$target")
    removable_service_units+=("${service_units[$index]}")
    removable_service_by_index[index]=1
  else
    die "preserving user service override that masks the package unit: $target"
  fi
done

if ((use_systemctl)); then
  "$systemctl_command" --user daemon-reload
  service_active_before=()
  service_enabled_before=()
  for index in "${!service_units[@]}"; do
    unit=${service_units[$index]}
    legacy_fragment=${legacy_service_targets[$index]}
    package_fragment=$package_systemd_dir/$unit
    fragment=$(
      "$systemctl_command" --user show --property=FragmentPath --value "$unit"
    )
    drop_ins=$(
      "$systemctl_command" --user show --property=DropInPaths --value "$unit"
    )
    if [[ "$fragment" != "$legacy_fragment" && "$fragment" != "$package_fragment" ]]; then
      die "$unit resolves to an unknown override before migration: ${fragment:-<missing>}"
    fi
    if [[ "$drop_ins" =~ [^[:space:]] ]]; then
      die "$unit has unsupported systemd drop-ins before migration: $drop_ins"
    fi
    active_state=$(
      "$systemctl_command" --user is-active "$unit" 2>/dev/null || true
    )
    case "$active_state" in
      active|inactive|failed) ;;
      *) die "could not determine stable active state for $unit: ${active_state:-<missing>}" ;;
    esac
    service_active_before+=("$active_state")

    enabled_state=$(
      "$systemctl_command" --user is-enabled "$unit" 2>/dev/null || true
    )
    case "$enabled_state" in
      enabled|enabled-runtime|disabled) ;;
      *) die "could not determine stable enabled state for $unit: ${enabled_state:-<missing>}" ;;
    esac
    service_enabled_before+=("$enabled_state")
  done
  if ((removable_service_by_index[0] && !removable_service_by_index[1])) &&
    [[ "${service_active_before[1]}" == active ]]; then
    die "cannot migrate the legacy daemon while the package portal is active; stop xeneon-edge-portal.service first"
  fi
  disable_user_services_all_scopes \
    "$systemctl_command" \
    "${removable_service_units[@]}" ||
    die "could not stop and disable the legacy user services; no files were removed"
fi

for target in "${missing_service_manifest_targets[@]}"; do
  remove_manifest_entry "$target"
  note "Removed stale legacy unit manifest entry: $target"
done

for target in "${removable_service_targets[@]}"; do
  rm -f -- "$target"
  remove_manifest_entry "$target"
  note "Removed unchanged legacy user unit: $target"
done

legacy_quickshell_root=$config_home/quickshell/$project_name
legacy_portal_scripts_root=$data_home/$project_name/scripts
legacy_static_roots=("$legacy_quickshell_root" "$legacy_portal_scripts_root")
legacy_static_labels=("QML copy" "portal helper")
for index in "${!legacy_static_roots[@]}"; do
  legacy_root=${legacy_static_roots[$index]}
  legacy_label=${legacy_static_labels[$index]}
  if [[ -f "$manifest_path" ]]; then
    while IFS=$'\t' read -r target installed_hash; do
      [[ "$target" == "$legacy_root/"* ]] || continue
      if [[ ! -e "$target" && ! -L "$target" ]]; then
        remove_manifest_entry "$target"
      elif [[ ! -L "$target" && -f "$target" ]] &&
        [[ "$(sha256_file "$target")" == "$installed_hash" ]]; then
        rm -f -- "$target"
        remove_manifest_entry "$target"
        note "Removed unchanged legacy $legacy_label: $target"
      else
        warn "preserving modified legacy $legacy_label (the package unit does not load it): $target"
      fi
    done < <(cp "$manifest_path" /dev/stdout)
  fi
done
find "$legacy_quickshell_root" -depth -type d -empty -delete 2>/dev/null || true
rmdir "$config_home/quickshell" 2>/dev/null || true
find "$legacy_portal_scripts_root" -depth -type d -empty -delete 2>/dev/null || true
rmdir "$data_home/$project_name" 2>/dev/null || true

if ((use_systemctl)); then
  "$systemctl_command" --user daemon-reload
  for index in "${!service_units[@]}"; do
    unit=${service_units[$index]}
    expected_fragment=$package_systemd_dir/$unit
    fragment=$(
      "$systemctl_command" --user show --property=FragmentPath --value "$unit"
    )
    drop_ins=$(
      "$systemctl_command" --user show --property=DropInPaths --value "$unit"
    )
    [[ "$fragment" == "$expected_fragment" ]] ||
      die "$unit resolves to $fragment instead of $expected_fragment"
    if [[ "$drop_ins" =~ [^[:space:]] ]]; then
      die "$unit has unsupported systemd drop-ins after migration: $drop_ins"
    fi
    active_state=$(
      "$systemctl_command" --user is-active "$unit" 2>/dev/null || true
    )
    enabled_state=$(
      "$systemctl_command" --user is-enabled "$unit" 2>/dev/null || true
    )
    case "$active_state" in
      active|inactive|failed) ;;
      *) die "could not determine stable active state for $unit after migration: ${active_state:-<missing>}" ;;
    esac
    case "$enabled_state" in
      enabled|enabled-runtime|disabled) ;;
      *) die "could not determine stable enabled state for $unit after migration: ${enabled_state:-<missing>}" ;;
    esac
    if ((removable_service_by_index[index])); then
      [[ "$active_state" != active ]] ||
        die "$unit remained active after migration"
      [[ "$enabled_state" == disabled ]] ||
        die "$unit remained enabled after migration: $enabled_state"
      note "Resolved disabled package unit: $fragment"
    else
      [[ "$active_state" == "${service_active_before[$index]}" ]] ||
        die "$unit active state changed during idempotent migration"
      [[ "$enabled_state" == "${service_enabled_before[$index]}" ]] ||
        die "$unit enabled state changed during idempotent migration"
      note "Resolved package unit without changing service state: $fragment"
    fi
  done
fi

note "Package migration complete. Commissioning and Hyprland files were preserved."
