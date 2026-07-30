#!/usr/bin/env bash

set -euo pipefail

project_name=xeneon-edge-agents

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

note() {
  printf '%s\n' "$*"
}

disable_user_services_all_scopes() {
  local systemctl_command=$1
  shift
  (($#)) || return 0

  "$systemctl_command" --user disable --runtime "$@"
  "$systemctl_command" --user disable --now "$@"
}

canonical_dir() {
  local value=$1
  realpath -m -- "$value"
}

canonical_isolated_test_command() {
  local label=$1
  local value=$2
  local explicit_root=$3
  local command_path root_path

  ((isolated_root)) ||
    die "$label is available only with isolated test paths"
  [[ -n "$explicit_root" ]] ||
    die "$label requires --root"
  validate_path_argument "$label" "$value"
  [[ ! -L "$value" ]] ||
    die "$label must be an executable regular file"
  command_path=$(canonical_dir "$value")
  root_path=$(canonical_dir "$explicit_root")
  [[ "$command_path" == "$root_path/"* ]] ||
    die "$label must be located below --root"
  [[ -f "$command_path" && -x "$command_path" && ! -L "$command_path" ]] ||
    die "$label must be an executable regular file"
  printf '%s\n' "$command_path"
}

paths_overlap() {
  local left=${1%/}
  local right=${2%/}
  [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

path_is_within() {
  local base=${1%/}
  local candidate=${2%/}
  if [[ -z "$base" ]]; then
    [[ "$candidate" == /* ]]
  else
    [[ "$candidate" == "$base" || "$candidate" == "$base/"* ]]
  fi
}

validate_path_argument() {
  local label=$1
  local value=$2
  [[ "$value" == /* ]] || die "$label must be an absolute path"
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*|*'%'*|*'$'*|*'"'*|*'\'*)
      die "$label may not contain control characters, %, $, quotes, or backslashes"
      ;;
  esac
}

resolve_xdg_paths() {
  local root_arg=${1:-}
  local config_arg=${2:-}
  local data_arg=${3:-}
  local state_arg=${4:-}
  local bin_arg=${5:-}

  local live_config_home live_data_home live_state_home live_bin_home
  live_config_home=$(canonical_dir "${XDG_CONFIG_HOME:-$HOME/.config}")
  live_data_home=$(canonical_dir "${XDG_DATA_HOME:-$HOME/.local/share}")
  live_state_home=$(canonical_dir "${XDG_STATE_HOME:-$HOME/.local/state}")
  live_bin_home=$(canonical_dir "${XDG_BIN_HOME:-$HOME/.local/bin}")

  if [[ -n "$root_arg" ]]; then
    validate_path_argument "--root" "$root_arg"
    root_arg=$(canonical_dir "$root_arg")
    for live_path in \
      "$live_config_home" "$live_data_home" "$live_state_home" "$live_bin_home"; do
      paths_overlap "$root_arg" "$live_path" &&
        die "--root must be disjoint from live user paths: $live_path"
    done
    config_home=${config_arg:-"$root_arg/.config"}
    data_home=${data_arg:-"$root_arg/.local/share"}
    state_home=${state_arg:-"$root_arg/.local/state"}
    bin_home=${bin_arg:-"$root_arg/.local/bin"}
    isolated_root=1
  else
    config_home=${config_arg:-"$live_config_home"}
    data_home=${data_arg:-"$live_data_home"}
    state_home=${state_arg:-"$live_state_home"}
    bin_home=${bin_arg:-"$live_bin_home"}
    isolated_root=0
  fi

  for pair in \
    "config home:$config_home" "data home:$data_home" \
    "state home:$state_home" "bin home:$bin_home"; do
    label=${pair%%:*}
    value=${pair#*:}
    validate_path_argument "$label" "$value"
  done
  config_home=$(canonical_dir "$config_home")
  data_home=$(canonical_dir "$data_home")
  state_home=$(canonical_dir "$state_home")
  bin_home=$(canonical_dir "$bin_home")
  if [[ -n "$root_arg" ]]; then
    [[ -n "$config_arg" || "$config_home" == "$root_arg/"* ]] ||
      die "default config home resolves outside --root: $config_home"
    [[ -n "$data_arg" || "$data_home" == "$root_arg/"* ]] ||
      die "default data home resolves outside --root: $data_home"
    [[ -n "$state_arg" || "$state_home" == "$root_arg/"* ]] ||
      die "default state home resolves outside --root: $state_home"
    [[ -n "$bin_arg" || "$bin_home" == "$root_arg/"* ]] ||
      die "default bin home resolves outside --root: $bin_home"
  fi
  for pair in \
    "canonical config home:$config_home" "canonical data home:$data_home" \
    "canonical state home:$state_home" "canonical bin home:$bin_home"; do
    label=${pair%%:*}
    value=${pair#*:}
    validate_path_argument "$label" "$value"
  done
  [[ "$bin_home" != *:* ]] || die "bin home may not contain ':'"

  if [[ -z "$root_arg" ]] &&
    [[ "$config_home" != "$live_config_home" ||
      "$data_home" != "$live_data_home" ||
      "$state_home" != "$live_state_home" ||
      "$bin_home" != "$live_bin_home" ]]; then
    isolated_root=1
    for configured_path in "$config_home" "$data_home" "$state_home" "$bin_home"; do
      for live_path in \
        "$live_config_home" "$live_data_home" "$live_state_home" "$live_bin_home"; do
        paths_overlap "$configured_path" "$live_path" &&
          die "isolated XDG paths must be disjoint from live user paths: $live_path"
      done
    done
  fi
  if ((isolated_root)) && [[ -n "$root_arg" ]]; then
    for configured_path in "$config_home" "$data_home" "$state_home" "$bin_home"; do
      for live_path in \
        "$live_config_home" "$live_data_home" "$live_state_home" "$live_bin_home"; do
        paths_overlap "$configured_path" "$live_path" &&
          die "isolated XDG paths must be disjoint from live user paths: $live_path"
      done
    done
  fi

  config_dir=$config_home/$project_name
  systemd_dir=$config_home/systemd/user
  hypr_dir=$config_home/hypr
  project_state_dir=$state_home/$project_name
  install_state_dir=$project_state_dir/install
  manifest_path=$install_state_dir/managed.tsv
  hypr_marker_path=$install_state_dir/hypr-require-injected
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

manifest_hash() {
  local target=$1
  [[ -f "$manifest_path" ]] || return 1
  awk -F '\t' -v target="$target" '$1 == target { value=$2 } END { if (value != "") print value; else exit 1 }' "$manifest_path"
}

write_manifest_entry() {
  local target=$1
  local hash=$2
  local temp
  mkdir -p "$install_state_dir"
  temp=$(mktemp "$install_state_dir/managed.XXXXXX")
  if [[ -f "$manifest_path" ]]; then
    awk -F '\t' -v target="$target" '$1 != target' "$manifest_path" >"$temp"
  fi
  printf '%s\t%s\n' "$target" "$hash" >>"$temp"
  mv "$temp" "$manifest_path"
}

remove_manifest_entry() {
  local target=$1
  local temp
  [[ -f "$manifest_path" ]] || return 0
  temp=$(mktemp "$install_state_dir/managed.XXXXXX")
  awk -F '\t' -v target="$target" '$1 != target' "$manifest_path" >"$temp"
  if [[ -s "$temp" ]]; then
    mv "$temp" "$manifest_path"
  else
    rm -f "$temp" "$manifest_path"
  fi
}

preflight_managed_target() {
  local source=$1
  local target=$2
  local current_hash previous_hash source_hash

  preflight_target_parent "$target"
  [[ -e "$target" || -L "$target" ]] || return 0
  [[ ! -L "$target" ]] || die "refusing to replace symlink target: $target"
  [[ -f "$target" ]] || die "refusing to replace non-file target: $target"

  source_hash=$(sha256_file "$source")
  current_hash=$(sha256_file "$target")
  previous_hash=$(manifest_hash "$target" 2>/dev/null || true)
  if [[ "$current_hash" == "$source_hash" ]]; then
    [[ -n "$previous_hash" && "$previous_hash" == "$current_hash" ]] &&
      return 0
    die "refusing to claim pre-existing identical user file: $target"
  fi
  [[ -n "$previous_hash" && "$current_hash" == "$previous_hash" ]] && return 0

  die "refusing to overwrite user-owned or modified file: $target"
}

preflight_target_parent() {
  local target=$1
  local parent authorized_home='' resolved_parent home

  if ((isolated_root)); then
    for home in "$config_home" "$data_home" "$state_home" "$bin_home"; do
      if path_is_within "$home" "$target" &&
        ((${#home} > ${#authorized_home})); then
        authorized_home=$home
      fi
    done
    [[ -n "$authorized_home" ]] ||
      die "refusing isolated target outside configured XDG homes: $target"
  fi

  parent=$(dirname "$target")
  if ((isolated_root)); then
    resolved_parent=$(canonical_dir "$parent")
    path_is_within "$authorized_home" "$resolved_parent" ||
      die "refusing target whose parent resolves outside configured XDG home: $target -> $resolved_parent"
  fi
  while [[ ! -e "$parent" && ! -L "$parent" ]]; do
    [[ "$parent" != / ]] || break
    parent=$(dirname "$parent")
  done
  [[ -d "$parent" ]] ||
    die "refusing to create a target below a non-directory path: $parent"
}

preflight_seed_user_file() {
  local target=$1

  preflight_target_parent "$target"
  [[ -L "$target" ]] && return 0
  [[ -e "$target" ]] || return 0
  [[ -f "$target" ]] ||
    die "refusing to replace non-file target: $target"
}

preflight_directory_target() {
  local target=$1

  preflight_target_parent "$target"
  [[ -e "$target" || -L "$target" ]] || return 0
  [[ -d "$target" ]] ||
    die "refusing to replace non-directory target: $target"
}

preflight_installer_state() {
  preflight_target_parent "$project_state_dir"
  if [[ -e "$project_state_dir" || -L "$project_state_dir" ]]; then
    [[ ! -L "$project_state_dir" ]] ||
      die "refusing to use symlink project state directory: $project_state_dir"
    [[ -d "$project_state_dir" ]] ||
      die "refusing to replace non-directory target: $project_state_dir"
  fi
  if [[ -e "$install_state_dir" || -L "$install_state_dir" ]]; then
    [[ ! -L "$install_state_dir" ]] ||
      die "refusing to use symlink installer state directory: $install_state_dir"
    [[ -d "$install_state_dir" ]] ||
      die "refusing to replace non-directory target: $install_state_dir"
  fi
  if [[ -e "$manifest_path" || -L "$manifest_path" ]]; then
    [[ ! -L "$manifest_path" ]] ||
      die "refusing to replace symlink installer manifest: $manifest_path"
    [[ -f "$manifest_path" ]] ||
      die "refusing to replace non-file installer manifest: $manifest_path"
  fi
  if [[ -e "$hypr_marker_path" || -L "$hypr_marker_path" ]]; then
    [[ ! -L "$hypr_marker_path" ]] ||
      die "refusing to use symlink installer marker: $hypr_marker_path"
    [[ -f "$hypr_marker_path" ]] ||
      die "refusing to use non-file installer marker: $hypr_marker_path"
  fi
}

preflight_manifest_targets() {
  local target installed_hash
  [[ -f "$manifest_path" ]] || return 0
  while IFS=$'\t' read -r target installed_hash; do
    [[ -n "$target" ]] || continue
    preflight_target_parent "$target"
  done <"$manifest_path"
}

install_managed_file() {
  local source=$1
  local target=$2
  local mode=${3:-0644}
  local source_hash

  source_hash=$(sha256_file "$source")
  if [[ -f "$target" ]] && [[ "$(sha256_file "$target")" == "$source_hash" ]]; then
    [[ "$(manifest_hash "$target" 2>/dev/null || true)" == "$source_hash" ]] ||
      die "refusing to claim pre-existing identical user file: $target"
    write_manifest_entry "$target" "$source_hash"
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  install -m "$mode" "$source" "$target"
  write_manifest_entry "$target" "$source_hash"
}

seed_user_file() {
  local source=$1
  local target=$2
  local mode=${3:-0600}

  if [[ -L "$target" ]]; then
    note "Preserved existing user config symlink: $target"
    return 0
  fi
  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] || die "refusing to replace non-file target: $target"
    note "Preserved existing user config: $target"
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  install -m "$mode" "$source" "$target"
  write_manifest_entry "$target" "$(sha256_file "$target")"
}

render_template() {
  local source=$1
  local target=$2
  shift 2
  local key value escaped

  cp "$source" "$target"
  while (($#)); do
    key=$1
    value=$2
    shift 2
    escaped=${value//\\/\\\\}
    escaped=${escaped//&/\\&}
    escaped=${escaped//|/\\|}
    sed -i "s|@$key@|$escaped|g" "$target"
  done
}

toml_value() {
  local file=$1
  local section=$2
  local key=$3
  awk -v wanted_section="$section" -v wanted_key="$key" '
    /^[[:space:]]*\[/ {
      current=$0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
      next
    }
    current == wanted_section {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      if (line ~ "^[[:space:]]*" wanted_key "[[:space:]]*=") {
        sub("^[[:space:]]*" wanted_key "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line ~ /^".*"$/) {
          sub(/^"/, "", line)
          sub(/"$/, "", line)
        }
        print line
        exit
      }
    }
  ' "$file"
}

top_level_toml_value() {
  local file=$1
  local key=$2
  awk -v wanted_key="$key" '
    /^[[:space:]]*\[/ { in_section=1 }
    !in_section {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      if (line ~ "^[[:space:]]*" wanted_key "[[:space:]]*=") {
        sub("^[[:space:]]*" wanted_key "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line ~ /^".*"$/) {
          sub(/^"/, "", line)
          sub(/"$/, "", line)
        }
        print line
        exit
      }
    }
  ' "$file"
}

validate_portal_env() {
  local file=$1
  local connector=$2
  local serial=$3
  local model=$4

  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk -v connector="$connector" -v serial="$serial" -v model="$model" '
    /^[[:space:]]*($|#)/ { next }
    $0 == "XENEON_EDGE_OUTPUT=\"" connector "\"" { output++; next }
    $0 == "XENEON_EDGE_SERIAL=\"" serial "\"" { screen_serial++; next }
    $0 == "XENEON_EDGE_MODEL=\"" model "\"" { screen_model++; next }
    { invalid=1 }
    END {
      exit !(!invalid && output == 1 && screen_serial == 1 && screen_model == 1)
    }
  ' "$file"
}

portal_env_value() {
  local file=$1
  local key=$2
  awk -v key="$key" '
    index($0, key "=\"") == 1 && substr($0, length($0), 1) == "\"" {
      print substr($0, length(key) + 3, length($0) - length(key) - 3)
      exit
    }
  ' "$file"
}

validate_commissioning_values() {
  local connector=$1
  local edid_sha=$2
  local output_serial=$3
  local output_model=$4
  local touch_device=$5
  local touch_bustype=$6
  local touch_vendor=$7
  local touch_product=$8
  local touch_uniq=$9
  local touch_phys=${10}

  [[ "$connector" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
    die "connector must be an exact connector name such as DP-1"
  [[ "$edid_sha" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "EDID identity must be a 64-character SHA-256 value"
  [[ "$output_serial" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
    die "screen serial must be the exact non-empty EDID serial"
  [[ "$output_model" =~ ^[A-Za-z0-9_.:\ -]+$ ]] ||
    die "screen model must be the exact non-empty display model"
  [[ "$touch_device" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
    die "touch device must be the normalized exact name from hyprctl devices"
  [[ "${touch_bustype,,}" == 0003 ]] ||
    die "touch bustype must be 0003 (USB)"
  [[ "${touch_vendor,,}" == 1b1c ]] ||
    die "touch vendor must be 1b1c (Corsair)"
  [[ "$touch_product" =~ ^[0-9a-fA-F]{4}$ ]] ||
    die "touch product must be a four-character hexadecimal input product ID"
  if [[ -z "$touch_uniq" && -z "$touch_phys" ]]; then
    die "touch identity requires --touch-uniq or --touch-phys"
  fi
  for value in "$touch_uniq" "$touch_phys"; do
    [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_.:/@+-]+$ ]] ||
      die "touch uniq/phys may contain only stable kernel-identity characters"
  done
}

normalize_hypr_device_name() {
  local value=${1,,}
  value=${value// /-}
  printf '%s\n' "$value"
}

drm_connector_name() {
  local path=$1
  local base prefix
  base=$(basename "$(dirname "$path")")
  prefix=${base%%-*}
  printf '%s\n' "${base#"$prefix"-}"
}
