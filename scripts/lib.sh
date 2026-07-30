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

canonical_dir() {
  local value=$1
  realpath -m -- "$value"
}

resolve_xdg_paths() {
  local root_arg=${1:-}
  local config_arg=${2:-}
  local data_arg=${3:-}
  local state_arg=${4:-}
  local bin_arg=${5:-}

  if [[ -n "$root_arg" ]]; then
    root_arg=$(canonical_dir "$root_arg")
    config_home=${config_arg:-"$root_arg/.config"}
    data_home=${data_arg:-"$root_arg/.local/share"}
    state_home=${state_arg:-"$root_arg/.local/state"}
    bin_home=${bin_arg:-"$root_arg/.local/bin"}
    isolated_root=1
  else
    config_home=${config_arg:-"${XDG_CONFIG_HOME:-$HOME/.config}"}
    data_home=${data_arg:-"${XDG_DATA_HOME:-$HOME/.local/share}"}
    state_home=${state_arg:-"${XDG_STATE_HOME:-$HOME/.local/state}"}
    bin_home=${bin_arg:-"${XDG_BIN_HOME:-$HOME/.local/bin}"}
    if [[ -n "$config_arg$data_arg$state_arg$bin_arg" ]]; then
      isolated_root=1
    else
      isolated_root=0
    fi
  fi

  case "$config_home$data_home$state_home$bin_home" in
    *$'\n'*|*$'\t'*) die "XDG paths may not contain tabs or newlines" ;;
  esac

  config_dir=$config_home/$project_name
  systemd_dir=$config_home/systemd/user
  hypr_dir=$config_home/hypr
  install_state_dir=$state_home/$project_name/install
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

  [[ -e "$target" ]] || return 0
  [[ -f "$target" ]] || die "refusing to replace non-file target: $target"

  source_hash=$(sha256_file "$source")
  current_hash=$(sha256_file "$target")
  [[ "$current_hash" == "$source_hash" ]] && return 0

  previous_hash=$(manifest_hash "$target" 2>/dev/null || true)
  [[ -n "$previous_hash" && "$current_hash" == "$previous_hash" ]] && return 0

  die "refusing to overwrite user-owned or modified file: $target"
}

install_managed_file() {
  local source=$1
  local target=$2
  local mode=${3:-0644}
  local source_hash

  source_hash=$(sha256_file "$source")
  if [[ -f "$target" ]] && [[ "$(sha256_file "$target")" == "$source_hash" ]]; then
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

validate_commissioning_values() {
  local connector=$1
  local edid_sha=$2
  local output_serial=$3
  local output_model=$4
  local touch_device=$5

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
}

drm_connector_name() {
  local path=$1
  local base prefix
  base=$(basename "$(dirname "$path")")
  prefix=${base%%-*}
  printf '%s\n' "${base#"$prefix"-}"
}
