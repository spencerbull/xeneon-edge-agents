#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
install_script=$repo_root/scripts/install.sh
check_script=$repo_root/scripts/check.sh
uninstall_script=$repo_root/scripts/uninstall.sh
detect_script=$repo_root/scripts/detect-hardware.sh

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
  local directory=$sys_root/class/drm/$card-$connector
  mkdir -p "$directory"
  cp "$edid_source" "$directory/edid"
  printf 'connected\n' >"$directory/status"
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

test_production_commissioning_and_exact_check() {
  local root fixture sha sys_root quickshell_source
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  sys_root=$root/sys
  quickshell_source=$root/quickshell-source
  printf 'CORSAIR XENEON EDGE deterministic EDID fixture\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"
  make_runtime_stubs "$root" "$quickshell_source"
  make_sysfs_match "$sys_root" card0 DP-1 "$fixture"

  "$install_script" --root "$root" --quickshell-source "$quickshell_source" \
    --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    --touch-device corsair-xeneon-edge-touchscreen >/dev/null
  "$install_script" --root "$root" --quickshell-source "$quickshell_source" \
    --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    --touch-device corsair-xeneon-edge-touchscreen >/dev/null

  assert_contains "$root/.config/xeneon-edge-agents/config.toml" 'serial = "CX123456"'
  assert_contains "$root/.config/xeneon-edge-agents/commissioning.toml" 'mode = "production"'
  assert_contains "$root/.config/xeneon-edge-agents/commissioning.toml" 'allow_primary_fallback = false'
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    'Environment="XENEON_EDGE_SERIAL=CX123456"'
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
  "$check_script" --root "$root" --sys-root "$sys_root" >/dev/null

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
    --touch-device corsair-xeneon-edge-touchscreen >/dev/null

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
    --touch-device corsair-xeneon-edge-touchscreen >/dev/null
  "$uninstall_script" --root "$root" >/dev/null
  assert_count 1 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
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
run_test 'preflight collision rolls back without a partial install' \
  test_preflight_rollback_on_collision
run_test 'production commissioning is exact, per-device, and reversible' \
  test_production_commissioning_and_exact_check
run_test 'missing and ambiguous production outputs fail closed' \
  test_missing_and_ambiguous_output_fail_closed
run_test 'missing commissioning identity installs nothing' \
  test_missing_commissioning_values_do_not_install
run_test 'preexisting Hyprland require remains user-owned' \
  test_preexisting_hypr_require_is_preserved
run_test 'explicit XDG directories are supported' test_explicit_xdg_paths
run_test 'read-only detection reports the absent-hardware gate' \
  test_read_only_detection_reports_physical_gate
printf '1..%d\n' "$tests_run"
