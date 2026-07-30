#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
install_script=$repo_root/scripts/install.sh
check_script=$repo_root/scripts/check.sh
uninstall_script=$repo_root/scripts/uninstall.sh
detect_script=$repo_root/scripts/detect-hardware.sh
production_touch_args=(
  --touch-device corsair-xeneon-edge-touchscreen
  --touch-bustype 0003
  --touch-vendor 1b1c
  --touch-product 1d0d
  --touch-phys usb-0000:00:14.0-1/input0
)

tests_run=0
suite_root=$(mktemp -d)
trap 'rm -rf "$suite_root"' EXIT

new_temp_dir() {
  mktemp -d "$suite_root/test.XXXXXX"
}

fail() {
  printf 'not ok: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "expected no file: $1"
}

assert_contains() {
  local path=$1
  local expected=$2
  grep -Fq -- "$expected" "$path" || fail "expected '$expected' in $path"
}

assert_count() {
  local expected=$1
  local pattern=$2
  local path=$3
  local actual
  actual=$(grep -Ec "$pattern" "$path" || true)
  [[ "$actual" == "$expected" ]] ||
    fail "expected $expected match(es) for '$pattern' in $path; got $actual"
}

run_test() {
  local name=$1
  shift
  "$@"
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$name"
}

write_hyprland() {
  local root=$1
  mkdir -p "$root/.config/hypr"
  cat >"$root/.config/hypr/hyprland.lua" <<'EOF'
require("default.hypr.omarchy")
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
EOF
}

make_sysfs_match() {
  local sys_root=$1
  local card=$2
  local connector=$3
  local edid_source=$4
  local directory=$sys_root/devices/mock-drm/$card-$connector
  mkdir -p "$directory"
  cp "$edid_source" "$directory/edid"
  printf 'connected\n' >"$directory/status"
  mkdir -p "$sys_root/class/drm"
  ln -s "$directory" "$sys_root/class/drm/$card-$connector"
}

make_touchscreen_match() {
  local sys_root=$1
  local event_name=${2:-event90}
  local directory=$sys_root/devices/mock-input/$event_name
  mkdir -p "$directory/device/id" "$directory/device/capabilities" \
    "$sys_root/class/input"
  printf 'Corsair XENEON EDGE Touchscreen\n' >"$directory/device/name"
  printf '0003\n' >"$directory/device/id/bustype"
  printf '1b1c\n' >"$directory/device/id/vendor"
  printf '1d0d\n' >"$directory/device/id/product"
  printf '\n' >"$directory/device/uniq"
  printf 'usb-0000:00:14.0-1/input0\n' >"$directory/device/phys"
  printf '00000000000000000000000000000001\n' \
    >"$directory/device/capabilities/abs"
  printf 'ID_INPUT=1\nID_INPUT_TOUCHSCREEN=1\n' \
    >"$directory/device/properties"
  ln -s "$directory" "$sys_root/class/input/$event_name"
}

make_runtime_stubs() {
  local root=$1
  local quickshell_source=$2
  mkdir -p "$root/.local/bin" "$quickshell_source/components"
  : >"$root/.local/bin/xeneon-agentd"
  : >"$root/.local/bin/xeneon-agentctl"
  chmod +x "$root/.local/bin/xeneon-agentd" "$root/.local/bin/xeneon-agentctl"
  printf 'import Quickshell\nShellRoot {}\n' >"$quickshell_source/shell.qml"
  printf 'import QtQuick\nItem {}\n' >"$quickshell_source/components/Stub.qml"
}

write_hypr_devices() {
  local target=$1
  local touch_name=$2
  cat >"$target" <<EOF
{"mice":[],"keyboards":[],"tablets":[],"touch":[{"address":"0x1","name":"$touch_name"}],"switches":[]}
EOF
}

write_hypr_monitors() {
  local target=$1
  cat >"$target" <<'EOF'
[{"id":1,"name":"DP-1","model":"XENEON EDGE","serial":"CX123456","width":2560,"height":720}]
EOF
}

test_default_idempotence_and_uninstall() {
  local root before after
  root=$(new_temp_dir)
  write_hyprland "$root"
  before=$(sha256sum "$root/.config/hypr/hyprland.lua")

  "$install_script" --root "$root" >/dev/null
  "$install_script" --root "$root" >/dev/null

  assert_file "$root/.config/xeneon-edge-agents/config.toml"
  assert_file "$root/.config/xeneon-edge-agents/commissioning.toml"
  assert_file "$root/.config/systemd/user/xeneon-agentd.service"
  assert_file "$root/.config/systemd/user/xeneon-edge-portal.service"
  assert_no_file "$root/.config/hypr/xeneon_edge_agents.lua"
  assert_count 0 'hypr\.xeneon_edge_agents' "$root/.config/hypr/hyprland.lua"
  after=$(sha256sum "$root/.config/hypr/hyprland.lua")
  [[ "$before" == "$after" ]] || fail "default install changed Hyprland config"

  "$uninstall_script" --root "$root" >/dev/null
  assert_no_file "$root/.config/xeneon-edge-agents/config.toml"
  assert_no_file "$root/.config/systemd/user/xeneon-agentd.service"
  assert_file "$root/.config/hypr/hyprland.lua"
}

test_user_config_preserved() {
  local root config before after
  root=$(new_temp_dir)
  config=$root/.config/xeneon-edge-agents/config.toml
  mkdir -p "$(dirname "$config")"
  printf 'user_owned = true\n' >"$config"
  before=$(sha256sum "$config")

  "$install_script" --root "$root" >/dev/null
  after=$(sha256sum "$config")
  [[ "$before" == "$after" ]] || fail "installer changed existing user config"

  "$uninstall_script" --root "$root" >/dev/null 2>&1
  assert_file "$config"
  assert_contains "$config" 'user_owned = true'
}

test_user_config_symlink_is_preserved() {
  local root config user_config
  root=$(new_temp_dir)
  config=$root/.config/xeneon-edge-agents/config.toml
  user_config=$root/user-config.toml
  mkdir -p "$(dirname "$config")"
  printf 'user_symlink = true\n' >"$user_config"
  ln -s "$user_config" "$config"

  "$install_script" --root "$root" >/dev/null
  [[ -L "$config" ]] || fail "installer replaced a user config symlink"
  assert_contains "$config" 'user_symlink = true'

  "$uninstall_script" --root "$root" >/dev/null 2>&1
  [[ -L "$config" ]] || fail "uninstaller removed a user config symlink"
  assert_contains "$user_config" 'user_symlink = true'
}

test_preflight_rollback_on_collision() {
  local root portal log
  root=$(new_temp_dir)
  portal=$root/.config/systemd/user/xeneon-edge-portal.service
  log=$root/install.log
  mkdir -p "$(dirname "$portal")"
  printf 'user service\n' >"$portal"

  if "$install_script" --root "$root" >"$log" 2>&1; then
    fail "install unexpectedly overwrote a conflicting user service"
  fi
  assert_contains "$log" 'refusing to overwrite user-owned or modified file'
  assert_no_file "$root/.config/systemd/user/xeneon-agentd.service"
  assert_no_file "$root/.config/xeneon-edge-agents/config.toml"
  assert_contains "$portal" 'user service'
}

test_identical_user_file_is_not_claimed() {
  local source_root root service log
  source_root=$(new_temp_dir)
  root=$(new_temp_dir)
  "$install_script" --root "$source_root" >/dev/null
  service=$root/.config/systemd/user/xeneon-agentd.service
  log=$root/install.log
  mkdir -p "$(dirname "$service")"
  cp "$source_root/.config/systemd/user/xeneon-agentd.service" "$service"
  sed -i "s|$source_root|$root|g" "$service"

  if "$install_script" --root "$root" >"$log" 2>&1; then
    fail "installer unexpectedly claimed an identical user file"
  fi
  assert_contains "$log" 'refusing to claim pre-existing identical user file'
  assert_file "$service"
  assert_no_file "$root/.config/systemd/user/xeneon-edge-portal.service"
}

test_obsolete_quickshell_files_are_pruned_safely() {
  local root source target log manifest
  root=$(new_temp_dir)
  source=$root/quickshell-source
  target=$root/.config/quickshell/xeneon-edge-agents/components
  log=$root/reinstall.log
  manifest=$root/.local/state/xeneon-edge-agents/install/managed.tsv
  make_runtime_stubs "$root" "$source"
  printf 'import QtQuick\nItem { objectName: "retired" }\n' \
    >"$source/components/Retired.qml"
  printf 'import QtQuick\nItem { objectName: "customized" }\n' \
    >"$source/components/Customized.qml"

  "$install_script" --root "$root" --quickshell-source "$source" >/dev/null
  rm "$source/components/Retired.qml" "$source/components/Customized.qml"
  printf '// user customization\n' >>"$target/Customized.qml"

  "$install_script" --root "$root" --quickshell-source "$source" \
    >"$log" 2>&1

  assert_no_file "$target/Retired.qml"
  assert_file "$target/Customized.qml"
  assert_contains "$target/Customized.qml" '// user customization'
  assert_contains "$log" 'preserving modified obsolete Quickshell file'
  if grep -Fq "$target/Retired.qml"$'\t' "$manifest"; then
    fail "retired unchanged QML file remains in the managed manifest"
  fi
  assert_contains "$manifest" "$target/Customized.qml"$'\t'

  "$uninstall_script" --root "$root" >/dev/null 2>&1
  assert_file "$target/Customized.qml"
}

test_production_commissioning_and_exact_check() {
  local root fixture sha sys_root quickshell_source hypr_devices hypr_monitors
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  sys_root=$root/sys
  quickshell_source=$root/quickshell-source
  hypr_devices=$root/hypr-devices.json
  hypr_monitors=$root/hypr-monitors.json
  printf 'CORSAIR XENEON EDGE deterministic EDID fixture\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"
  make_runtime_stubs "$root" "$quickshell_source"
  make_sysfs_match "$sys_root" card0 DP-1 "$fixture"
  make_touchscreen_match "$sys_root"
  write_hypr_devices "$hypr_devices" corsair-xeneon-edge-touchscreen
  write_hypr_monitors "$hypr_monitors"

  "$install_script" --root "$root" --quickshell-source "$quickshell_source" \
    --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null
  "$install_script" --root "$root" --quickshell-source "$quickshell_source" \
    --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null

  assert_contains "$root/.config/xeneon-edge-agents/config.toml" 'serial = "CX123456"'
  assert_contains "$root/.config/xeneon-edge-agents/commissioning.toml" 'mode = "production"'
  assert_contains "$root/.config/xeneon-edge-agents/commissioning.toml" 'allow_primary_fallback = false'
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    'Environment="XENEON_EDGE_SERIAL=CX123456"'
  assert_contains "$root/.config/systemd/user/xeneon-agentd.service" \
    "Environment=\"PATH=$root/.local/bin:/usr/local/bin:/usr/bin\""
  assert_file "$root/.config/quickshell/xeneon-edge-agents/shell.qml"
  assert_contains "$root/.config/hypr/xeneon_edge_agents.lua" 'name = "corsair-xeneon-edge-touchscreen"'
  assert_contains "$root/.config/hypr/xeneon_edge_agents.lua" 'output = "DP-1"'
  assert_count 1 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
  awk '
    previous == "require(\"hypr.input\")" &&
      $0 == "require(\"hypr.xeneon_edge_agents\")" { found=1 }
    { previous=$0 }
    END { exit(found ? 0 : 1) }
  ' "$root/.config/hypr/hyprland.lua" ||
    fail "XENEON require is not immediately after hypr.input"
  assert_no_file "$root/.config/hypr/monitors.lua"
  luac -p "$root/.config/hypr/xeneon_edge_agents.lua"
  if ! "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$root/check.log" 2>&1; then
    sed -n '1,160p' "$root/check.log" >&2
    fail "production check rejected exact fixture identity"
  fi

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify \
      "$root/.config/systemd/user/xeneon-agentd.service" \
      "$root/.config/systemd/user/xeneon-edge-portal.service"
  fi

  if [[ -n "${XENEON_AGENTD_BIN:-}" ]]; then
    mkdir -p "$root/runtime"
    set +e
    timeout 1 env XDG_RUNTIME_DIR="$root/runtime" \
      "$XENEON_AGENTD_BIN" \
      --config "$root/.config/xeneon-edge-agents/config.toml" \
      >"$root/daemon.log" 2>&1
    daemon_status=$?
    set -e
    [[ "$daemon_status" == 124 ]] || {
      sed -n '1,120p' "$root/daemon.log" >&2
      fail "daemon rejected generated production config"
    }
  fi

  printf '\n-- unrelated user line\n' >>"$root/.config/hypr/hyprland.lua"
  "$uninstall_script" --root "$root" >/dev/null
  assert_count 0 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
  assert_contains "$root/.config/hypr/hyprland.lua" '-- unrelated user line'
  assert_file "$root/.config/hypr/hyprland.lua"
}

test_missing_and_ambiguous_output_fail_closed() {
  local root fixture sha empty_sys ambiguous_sys missing_log ambiguous_log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  empty_sys=$root/empty-sys
  ambiguous_sys=$root/ambiguous-sys
  missing_log=$root/missing.log
  ambiguous_log=$root/ambiguous.log
  printf 'CORSAIR XENEON EDGE deterministic EDID fixture\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  mkdir -p "$empty_sys/class/drm"
  write_hyprland "$root"

  "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null

  if "$check_script" --root "$root" --sys-root "$empty_sys" >"$missing_log" 2>&1; then
    fail "missing production output unexpectedly passed"
  fi
  assert_contains "$missing_log" 'physical gate remains closed'

  make_sysfs_match "$ambiguous_sys" card0 DP-1 "$fixture"
  make_sysfs_match "$ambiguous_sys" card1 DP-1 "$fixture"
  if "$check_script" --root "$root" --sys-root "$ambiguous_sys" >"$ambiguous_log" 2>&1; then
    fail "ambiguous production output unexpectedly passed"
  fi
  assert_contains "$ambiguous_log" 'identity is ambiguous'
}

test_missing_commissioning_values_do_not_install() {
  local root log
  root=$(new_temp_dir)
  log=$root/install.log
  if "$install_script" --root "$root" --apply-production \
    --connector DP-1 --screen-serial CX123456 --screen-model "XENEON EDGE" \
    --touch-device touchscreen >"$log" 2>&1; then
    fail "incomplete production identity unexpectedly passed"
  fi
  assert_contains "$log" 'EDID identity must be'
  assert_no_file "$root/.config/systemd/user/xeneon-agentd.service"
}

test_touch_and_monitor_identity_fail_closed() {
  local root fixture sha sys_root hypr_devices hypr_monitors log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  sys_root=$root/sys
  hypr_devices=$root/hypr-devices.json
  hypr_monitors=$root/hypr-monitors.json
  log=$root/check.log
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"
  make_runtime_stubs "$root" "$root/quickshell-source"
  make_sysfs_match "$sys_root" card0 DP-1 "$fixture"
  make_touchscreen_match "$sys_root"
  write_hypr_devices "$hypr_devices" internal-touchscreen
  write_hypr_monitors "$hypr_monitors"

  "$install_script" --root "$root" \
    --quickshell-source "$root/quickshell-source" \
    --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null

  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "wrong Hyprland touch name unexpectedly passed"
  fi
  assert_contains "$log" 'configured Hyprland touch device is absent'

  write_hypr_devices "$hypr_devices" corsair-xeneon-edge-touchscreen
  make_touchscreen_match "$sys_root" event91
  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "duplicate kernel touch identity unexpectedly passed"
  fi
  assert_contains "$log" 'touchscreen identity is ambiguous'

  cat >"$hypr_monitors" <<'EOF'
[{"id":1,"name":"DP-1","model":"XENEON EDGE","serial":"WRONG","width":2560,"height":720}]
EOF
  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "wrong Hyprland monitor serial unexpectedly passed"
  fi
  assert_contains "$log" 'screen serial/model is absent'
}

test_preexisting_hypr_require_is_preserved() {
  local root fixture sha
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"
  sed -i '/require("hypr.input")/a require("hypr.xeneon_edge_agents")' \
    "$root/.config/hypr/hyprland.lua"

  "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null
  "$uninstall_script" --root "$root" >/dev/null
  assert_count 1 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
}

test_symlinked_hypr_entrypoint_is_refused() {
  local root fixture sha target log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  target=$root/user-hyprland.lua
  log=$root/install.log
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  mkdir -p "$root/.config/hypr"
  printf 'require("hypr.input")\n' >"$target"
  ln -s "$target" "$root/.config/hypr/hyprland.lua"

  if "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >"$log" 2>&1; then
    fail "symlinked Hyprland entrypoint unexpectedly passed"
  fi
  assert_contains "$log" 'refusing to rewrite symlinked Hyprland entrypoint'
  [[ -L "$root/.config/hypr/hyprland.lua" ]] ||
    fail "installer replaced the Hyprland symlink"
  assert_contains "$target" 'require("hypr.input")'
}

test_changed_injected_require_preserves_module() {
  local root fixture sha module
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  module=$root/.config/hypr/xeneon_edge_agents.lua
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"

  "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null
  sed -i '/require("hypr.xeneon_edge_agents")/d' \
    "$root/.config/hypr/hyprland.lua"
  printf 'require("hypr.xeneon_edge_agents")\n' \
    >>"$root/.config/hypr/hyprland.lua"

  "$uninstall_script" --root "$root" >/dev/null 2>&1
  assert_file "$module"
  assert_count 1 'require\("hypr\.xeneon_edge_agents"\)' \
    "$root/.config/hypr/hyprland.lua"
}

test_explicit_xdg_paths() {
  local base config_home data_home state_home bin_home
  base=$(new_temp_dir)
  config_home=$base/config
  data_home=$base/data
  state_home=$base/state
  bin_home=$base/bin

  "$install_script" \
    --config-home "$config_home" --data-home "$data_home" \
    --state-home "$state_home" --bin-home "$bin_home" >/dev/null
  assert_file "$config_home/xeneon-edge-agents/config.toml"
  assert_contains "$config_home/systemd/user/xeneon-agentd.service" "$bin_home/xeneon-agentd"

  "$uninstall_script" \
    --config-home "$config_home" --data-home "$data_home" \
    --state-home "$state_home" --bin-home "$bin_home" >/dev/null
  assert_no_file "$config_home/systemd/user/xeneon-agentd.service"
}

test_path_boundaries_and_spaces() {
  local base spaced log
  base=$(new_temp_dir)
  spaced=$base/'space root'
  log=$base/install.log
  "$install_script" --root "$spaced" >/dev/null
  assert_file "$spaced/.config/xeneon-edge-agents/config.toml"
  "$uninstall_script" --root "$spaced" >/dev/null

  if "$install_script" --config-home relative/config >"$log" 2>&1; then
    fail "relative XDG path unexpectedly passed"
  fi
  assert_contains "$log" 'must be an absolute path'

  if "$install_script" --root "$base/percent%root" >"$log" 2>&1; then
    fail "systemd specifier path unexpectedly passed"
  fi
  assert_contains "$log" 'may not contain'

  if "$install_script" --root "$base/dollar\$root" >"$log" 2>&1; then
    fail "systemd environment-expansion path unexpectedly passed"
  fi
  assert_contains "$log" 'may not contain'

  if "$install_script" --root "$HOME" >"$log" 2>&1; then
    fail "live home unexpectedly passed as an isolated root"
  fi
  assert_contains "$log" 'must be disjoint from live user paths'
}

test_live_production_preflight_changes_nothing_when_edge_absent() {
  local root fixture sha before after log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  log=$root/install.log
  printf 'CORSAIR XENEON EDGE absent fixture\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  mkdir -p "$root/config/hypr" "$root/bin" "$root/data" "$root/state"
  printf 'require("hypr.input")\n' >"$root/config/hypr/hyprland.lua"
  : >"$root/bin/xeneon-agentd"
  : >"$root/bin/xeneon-agentctl"
  : >"$root/bin/herdr"
  chmod +x \
    "$root/bin/xeneon-agentd" "$root/bin/xeneon-agentctl" "$root/bin/herdr"
  before=$(sha256sum "$root/config/hypr/hyprland.lua")

  if env \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_BIN_HOME="$root/bin" \
    "$install_script" --apply-production \
      --connector DP-99 --edid-sha256 "$sha" \
      --screen-serial CX123456 --screen-model "XENEON EDGE" \
      "${production_touch_args[@]}" >"$log" 2>&1; then
    fail "absent live XENEON identity unexpectedly passed preflight"
  fi
  assert_contains "$log" 'no live files were changed'
  after=$(sha256sum "$root/config/hypr/hyprland.lua")
  [[ "$before" == "$after" ]] || fail "failed live preflight changed Hyprland"
  assert_no_file "$root/config/systemd/user/xeneon-agentd.service"
  assert_no_file "$root/config/hypr/xeneon_edge_agents.lua"
}

test_read_only_detection_reports_physical_gate() {
  local root output
  root=$(new_temp_dir)
  output=$root/detect.log
  mkdir -p "$root/sys/class/drm"
  PATH=/usr/bin:/bin "$detect_script" --sys-root "$root/sys" >"$output"
  assert_contains "$output" 'PHYSICAL GATE BLOCKED'
  assert_contains "$output" 'No configuration was changed'
}

printf 'TAP version 13\n'
run_test 'default install is idempotent and uninstall is reversible' \
  test_default_idempotence_and_uninstall
run_test 'existing user config is preserved' test_user_config_preserved
run_test 'existing user config symlink is preserved' \
  test_user_config_symlink_is_preserved
run_test 'preflight collision rolls back without a partial install' \
  test_preflight_rollback_on_collision
run_test 'identical user file is not claimed by the installer' \
  test_identical_user_file_is_not_claimed
run_test 'obsolete Quickshell files are pruned without deleting modifications' \
  test_obsolete_quickshell_files_are_pruned_safely
run_test 'production commissioning is exact, per-device, and reversible' \
  test_production_commissioning_and_exact_check
run_test 'missing and ambiguous production outputs fail closed' \
  test_missing_and_ambiguous_output_fail_closed
run_test 'missing commissioning identity installs nothing' \
  test_missing_commissioning_values_do_not_install
run_test 'touch and monitor identities fail closed' \
  test_touch_and_monitor_identity_fail_closed
run_test 'preexisting Hyprland require remains user-owned' \
  test_preexisting_hypr_require_is_preserved
run_test 'symlinked Hyprland entrypoint is refused' \
  test_symlinked_hypr_entrypoint_is_refused
run_test 'changed injected require preserves its module' \
  test_changed_injected_require_preserves_module
run_test 'explicit XDG directories are supported' test_explicit_xdg_paths
run_test 'path boundaries reject systemd hazards and allow spaces' \
  test_path_boundaries_and_spaces
run_test 'absent live EDGE preflight changes no live files' \
  test_live_production_preflight_changes_nothing_when_edge_absent
run_test 'read-only detection reports the absent-hardware gate' \
  test_read_only_detection_reports_physical_gate
printf '1..%d\n' "$tests_run"
