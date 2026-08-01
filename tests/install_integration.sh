#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
install_script=$repo_root/scripts/install.sh
check_script=$repo_root/scripts/check.sh
uninstall_script=$repo_root/scripts/uninstall.sh
detect_script=$repo_root/scripts/detect-hardware.sh
production_touch_args=(
  --touch-device wch.cn-touchscreen-1
  --touch-bustype 0003
  --touch-vendor 27c0
  --touch-product 0859
  --touch-uniq 9LQ0172005164
  --touch-phys usb-0000:00:14.0-2.4/input0
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
  local uniq=${3:-9LQ0172005164}
  local phys=${4:-usb-0000:00:14.0-2.4/input0}
  local directory=$sys_root/devices/mock-input/$event_name
  mkdir -p "$directory/device/id" "$directory/device/capabilities" \
    "$sys_root/class/input"
  printf 'wch.cn TouchScreen\n' >"$directory/device/name"
  printf '0003\n' >"$directory/device/id/bustype"
  printf '27c0\n' >"$directory/device/id/vendor"
  printf '0859\n' >"$directory/device/id/product"
  printf '%s\n' "$uniq" >"$directory/device/uniq"
  printf '%s\n' "$phys" >"$directory/device/phys"
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
  assert_count 2 \
    'xeneon-agentd.*--config .*--cleanup-dictation' \
    "$root/.config/systemd/user/xeneon-agentd.service"
  assert_contains "$root/.config/systemd/user/xeneon-agentd.service" 'UMask=0077'
  assert_contains "$root/.config/systemd/user/xeneon-agentd.service" \
    'RuntimeDirectory=xeneon-edge-agents'
  assert_contains "$root/.config/systemd/user/xeneon-agentd.service" \
    'RuntimeDirectoryMode=0700'
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    'ReadWritePaths=%t/quickshell %t/dconf'
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    "Environment=\"XDG_STATE_HOME=$root/.local/state\""
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    "Environment=\"XENEON_EDGE_SETTINGS_PATH=$root/.local/state/xeneon-edge-agents/portal/preferences.ini\""
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    'StateDirectory=xeneon-edge-agents/portal'
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    'StateDirectoryMode=0700'
  assert_contains "$root/.config/systemd/user/xeneon-edge-portal.service" \
    'UMask=0077'
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
  local marker
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
  write_hypr_devices "$hypr_devices" wch.cn-touchscreen-1
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
  assert_contains "$root/.config/hypr/xeneon_edge_agents.lua" 'name = "wch.cn-touchscreen-1"'
  assert_contains "$root/.config/hypr/xeneon_edge_agents.lua" 'output = "DP-1"'
  assert_count 0 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
  assert_no_file "$root/.config/hypr/monitors.lua"
  luac -p "$root/.config/hypr/xeneon_edge_agents.lua"
  if ! "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$root/check.log" 2>&1; then
    sed -n '1,160p' "$root/check.log" >&2
    fail "production check rejected exact fixture identity"
  fi
  assert_contains "$root/check.log" \
    'Hyprland integration is staged but not active'

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

  # Simulate the explicit activation transaction so the uninstaller's marker,
  # adjacency, and original-mode handling are covered without touching a live
  # service manager from an isolated test root.
  sed -i '/require("hypr.input")/a require("hypr.xeneon_edge_agents")' \
    "$root/.config/hypr/hyprland.lua"
  marker=$root/.local/state/xeneon-edge-agents/install/hypr-require-injected
  : >"$marker"
  chmod 0600 "$root/.config/hypr/hyprland.lua"
  printf '\n-- unrelated user line\n' >>"$root/.config/hypr/hyprland.lua"
  "$uninstall_script" --root "$root" >/dev/null
  assert_count 0 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
  assert_contains "$root/.config/hypr/hyprland.lua" '-- unrelated user line'
  assert_file "$root/.config/hypr/hyprland.lua"
  [[ "$(stat -c '%a' "$root/.config/hypr/hyprland.lua")" == 600 ]] ||
    fail "uninstall changed the Hyprland entrypoint mode"
}

test_production_reinstall_requires_explicit_identity() {
  local root fixture sha portal before after log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  portal=$root/.config/systemd/user/xeneon-edge-portal.service
  log=$root/reinstall.log
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"

  "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null
  before=$(sha256sum "$portal")

  if "$install_script" --root "$root" >"$log" 2>&1; then
    fail "implicit production-to-simulation reinstall unexpectedly passed"
  fi
  assert_contains "$log" \
    'existing production commissioning requires --apply-production'
  after=$(sha256sum "$portal")
  [[ "$before" == "$after" ]] ||
    fail "refused production reinstall changed the portal identity"
  assert_contains "$portal" 'Environment="XENEON_EDGE_SERIAL=CX123456"'
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

test_invalid_touch_vendor_does_not_install() {
  local root fixture sha log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  log=$root/install.log
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')

  if "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    --touch-device wch.cn-touchscreen-1 \
    --touch-bustype 0003 --touch-vendor zzzz --touch-product 0859 \
    --touch-uniq 9LQ0172005164 >"$log" 2>&1; then
    fail "non-hexadecimal touch vendor unexpectedly passed"
  fi
  assert_contains "$log" \
    'touch vendor must be a four-character hexadecimal input vendor ID'
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

  : >"$hypr_devices"
  : >"$hypr_monitors"
  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "empty Hyprland inventories unexpectedly passed"
  fi
  assert_contains "$log" 'Hyprland monitor inventory is invalid JSON'
  assert_contains "$log" 'Hyprland touch-device inventory is invalid JSON'

  write_hypr_devices "$hypr_devices" internal-touchscreen
  write_hypr_monitors "$hypr_monitors"
  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "wrong Hyprland touch name unexpectedly passed"
  fi
  assert_contains "$log" 'configured Hyprland touch device is absent'

  write_hypr_devices "$hypr_devices" wch.cn-touchscreen-1
  make_touchscreen_match "$sys_root" event91
  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "duplicate kernel touch identity unexpectedly passed"
  fi
  assert_contains "$log" 'touchscreen identity is ambiguous'

  rm -f "$sys_root/class/input/event91"
  make_touchscreen_match \
    "$sys_root" event92 OTHER-CONTROLLER usb-0000:00:14.0-9/input0
  cat >"$hypr_devices" <<'EOF'
{"mice":[],"keyboards":[],"tablets":[],"touch":[{"address":"0x1","name":"wch.cn-touchscreen"},{"address":"0x2","name":"wch.cn-touchscreen-1"}],"switches":[]}
EOF
  if "$check_script" --root "$root" --sys-root "$sys_root" \
    --hypr-devices-json "$hypr_devices" \
    --hypr-monitors-json "$hypr_monitors" >"$log" 2>&1; then
    fail "same-base Hyprland touchscreen ambiguity unexpectedly passed"
  fi
  assert_contains "$log" 'Hyprland touchscreen name family is ambiguous'

  rm -f "$sys_root/class/input/event92"
  write_hypr_devices "$hypr_devices" wch.cn-touchscreen-1
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

test_hyprctl_query_failures_fail_closed() {
  local root fixture sha sys_root stub_bin hypr_devices hypr_monitors log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  sys_root=$root/sys
  stub_bin=$root/stub-bin
  hypr_devices=$root/hypr-devices.json
  hypr_monitors=$root/hypr-monitors.json
  log=$root/check.log
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"
  make_runtime_stubs "$root" "$root/quickshell-source"
  make_sysfs_match "$sys_root" card0 DP-1 "$fixture"
  make_touchscreen_match "$sys_root"
  write_hypr_devices "$hypr_devices" wch.cn-touchscreen-1
  write_hypr_monitors "$hypr_monitors"

  "$install_script" --root "$root" \
    --quickshell-source "$root/quickshell-source" \
    --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null

  mkdir -p "$stub_bin"
  cat >"$stub_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"monitors all"* ]]; then
  cat "$STUB_MONITORS"
else
  cat "$STUB_DEVICES"
fi
exit 1
EOF
  chmod +x "$stub_bin/hyprctl"

  if env \
    STUB_MONITORS="$hypr_monitors" \
    STUB_DEVICES="$hypr_devices" \
    PATH="$stub_bin:/usr/bin" \
    "$check_script" --root "$root" --sys-root "$sys_root" \
      >"$log" 2>&1; then
    fail "failed hyprctl queries with valid output unexpectedly passed"
  fi
  assert_contains "$log" 'hyprctl monitor query failed'
  assert_contains "$log" 'hyprctl touch-device query failed'
}

test_preexisting_hypr_require_is_preserved() {
  local root fixture sha module
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"

  "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null
  module=$root/.config/hypr/xeneon_edge_agents.lua
  sed -i '/require("hypr.input")/a require("hypr.xeneon_edge_agents")' \
    "$root/.config/hypr/hyprland.lua"
  "$uninstall_script" --root "$root" >/dev/null
  assert_count 1 'require\("hypr\.xeneon_edge_agents"\)' "$root/.config/hypr/hyprland.lua"
  assert_file "$module"
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
  sed -i '/require("hypr.input")/a require("hypr.xeneon_edge_agents")' \
    "$root/.config/hypr/hyprland.lua"
  : >"$root/.local/state/xeneon-edge-agents/install/hypr-require-injected"
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
  local base spaced log resolved_hazard safe_symlink
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

  resolved_hazard=$base/resolved%h
  safe_symlink=$base/safe-symlink
  mkdir -p "$resolved_hazard"
  ln -s "$resolved_hazard" "$safe_symlink"
  if "$install_script" --root "$safe_symlink" >"$log" 2>&1; then
    fail "symlink-resolved systemd specifier path unexpectedly passed"
  fi
  assert_contains "$log" 'config home may not contain'

  if "$install_script" --root "$base/dollar\$root" >"$log" 2>&1; then
    fail "systemd environment-expansion path unexpectedly passed"
  fi
  assert_contains "$log" 'may not contain'

  if "$install_script" --root "$HOME" >"$log" 2>&1; then
    fail "live home unexpectedly passed as an isolated root"
  fi
  assert_contains "$log" 'must be disjoint from live user paths'
}

test_uninstall_does_not_touch_unowned_services() {
  local root systemctl_log
  root=$(new_temp_dir)
  systemctl_log=$root/systemctl.log
  mkdir -p "$root/bin" "$root/config" "$root/data" "$root/state"
  cat >"$root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$SYSTEMCTL_LOG"
exit 0
EOF
  chmod +x "$root/bin/systemctl"

  env \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_BIN_HOME="$root/bin" \
    SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$root/bin:/usr/bin" \
    "$uninstall_script" >/dev/null

  assert_no_file "$systemctl_log"
}

test_modified_managed_unit_aborts_uninstall() {
  local root daemon config log
  root=$(new_temp_dir)
  daemon=$root/.config/systemd/user/xeneon-agentd.service
  config=$root/.config/xeneon-edge-agents/config.toml
  log=$root/uninstall.log
  "$install_script" --root "$root" >/dev/null
  printf '\n# user modification\n' >>"$daemon"

  if "$uninstall_script" --root "$root" >"$log" 2>&1; then
    fail "uninstall with a modified managed service unit unexpectedly passed"
  fi
  assert_contains "$log" \
    'refusing to uninstall while a managed service unit is modified'
  assert_file "$daemon"
  assert_file "$config"
  assert_file "$root/.config/quickshell/xeneon-edge-agents/shell.qml"
}

test_activation_restarts_active_services() {
  local root stub_bin systemctl_log
  root=$(new_temp_dir)
  stub_bin=$root/stub-bin
  systemctl_log=$root/systemctl.log
  mkdir -p \
    "$root/config" "$root/data" "$root/state" "$root/bin" "$stub_bin"
  : >"$root/bin/xeneon-agentd"
  : >"$root/bin/xeneon-agentctl"
  chmod +x "$root/bin/xeneon-agentd" "$root/bin/xeneon-agentctl"
  cat >"$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
  *" is-active "*) printf 'active\n' ;;
  *" is-enabled "*) printf 'enabled\n' ;;
esac
exit 0
EOF
  chmod +x "$stub_bin/systemctl"

  env \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_BIN_HOME="$root/bin" \
    SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$stub_bin:/usr/bin" \
    "$install_script" --activate >/dev/null

  grep -Fxq -- '--user restart xeneon-agentd.service' "$systemctl_log" ||
    fail "activation did not restart the active daemon"
  grep -Fxq -- '--user restart xeneon-edge-portal.service' "$systemctl_log" ||
    fail "activation did not restart the active portal"
  grep -Fxq -- \
    '--user enable xeneon-agentd.service xeneon-edge-portal.service' \
    "$systemctl_log" ||
    fail "activation did not enable both services"
}

test_failed_activation_restores_prior_artifacts() {
  local root source stub_bin systemctl_log failure_marker restore_marker
  local target manifest
  local target_before manifest_before log daemon_restarts portal_restarts
  root=$(new_temp_dir)
  source=$root/quickshell-source
  stub_bin=$root/stub-bin
  systemctl_log=$root/systemctl.log
  failure_marker=$root/portal-restart-failed
  restore_marker=$root/prior-artifact-observed
  target=$root/config/quickshell/xeneon-edge-agents/shell.qml
  manifest=$root/state/xeneon-edge-agents/install/managed.tsv
  log=$root/activate.log
  mkdir -p \
    "$root/config" "$root/data" "$root/state" "$root/bin" \
    "$source" "$stub_bin"
  : >"$root/bin/xeneon-agentd"
  : >"$root/bin/xeneon-agentctl"
  chmod +x "$root/bin/xeneon-agentd" "$root/bin/xeneon-agentctl"
  printf 'import QtQuick\nItem { property string version: "v1" }\n' \
    >"$source/shell.qml"
  cat >"$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
  *" is-active "*) printf 'active\n' ;;
  *" is-enabled "*) printf 'enabled\n' ;;
  *" restart xeneon-edge-portal.service")
    if [[ ! -f "$FAILURE_MARKER" ]]; then
      : >"$FAILURE_MARKER"
      exit 1
    fi
    if grep -Fq 'version: "v1"' "$TARGET_PATH"; then
      : >"$RESTORE_MARKER"
    else
      exit 2
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$stub_bin/systemctl"

  env \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_BIN_HOME="$root/bin" \
    PATH="$stub_bin:/usr/bin" \
    "$install_script" --quickshell-source "$source" >/dev/null
  target_before=$(sha256sum "$target")
  manifest_before=$(sha256sum "$manifest")
  printf 'import QtQuick\nItem { property string version: "v2" }\n' \
    >"$source/shell.qml"

  if env \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_BIN_HOME="$root/bin" \
    SYSTEMCTL_LOG="$systemctl_log" \
    FAILURE_MARKER="$failure_marker" \
    RESTORE_MARKER="$restore_marker" \
    TARGET_PATH="$target" \
    PATH="$stub_bin:/usr/bin" \
    "$install_script" --quickshell-source "$source" --activate \
      >"$log" 2>&1; then
    fail "forced portal restart failure unexpectedly passed activation"
  fi

  [[ "$target_before" == "$(sha256sum "$target")" ]] ||
    fail "failed activation did not restore the prior QML artifact"
  [[ "$manifest_before" == "$(sha256sum "$manifest")" ]] ||
    fail "failed activation did not restore the prior manifest"
  assert_contains "$target" 'version: "v1"'
  assert_file "$restore_marker"
  assert_contains "$log" 'restoring prior managed files'
  daemon_restarts=$(
    grep -Fxc -- '--user restart xeneon-agentd.service' "$systemctl_log"
  )
  portal_restarts=$(
    grep -Fxc -- '--user restart xeneon-edge-portal.service' "$systemctl_log"
  )
  [[ "$daemon_restarts" == 2 && "$portal_restarts" == 2 ]] ||
    fail "failed activation did not restart both prior active services"
}

test_live_uninstall_reloads_hyprland() {
  local root fixture sha marker stub_bin systemctl_log hyprctl_log
  root=$(new_temp_dir)
  fixture=$root/edid.bin
  marker=$root/.local/state/xeneon-edge-agents/install/hypr-require-injected
  stub_bin=$root/stub-bin
  systemctl_log=$root/systemctl.log
  hyprctl_log=$root/hyprctl.log
  printf 'CORSAIR XENEON EDGE\n' >"$fixture"
  sha=$(sha256sum "$fixture" | awk '{print $1}')
  write_hyprland "$root"
  "$install_script" --root "$root" --apply-production \
    --connector DP-1 --edid-sha256 "$sha" \
    --screen-serial CX123456 --screen-model "XENEON EDGE" \
    "${production_touch_args[@]}" >/dev/null
  sed -i '/require("hypr.input")/a require("hypr.xeneon_edge_agents")' \
    "$root/.config/hypr/hyprland.lua"
  : >"$marker"

  mkdir -p "$stub_bin"
  cat >"$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if [[ "$*" == *" is-active --quiet "* ]]; then
  exit 3
fi
exit 0
EOF
  cat >"$stub_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HYPRCTL_LOG"
exit 0
EOF
  chmod +x "$stub_bin/systemctl" "$stub_bin/hyprctl"

  env \
    HOME="$root" \
    XDG_CONFIG_HOME="$root/.config" \
    XDG_DATA_HOME="$root/.local/share" \
    XDG_STATE_HOME="$root/.local/state" \
    XDG_BIN_HOME="$root/.local/bin" \
    SYSTEMCTL_LOG="$systemctl_log" \
    HYPRCTL_LOG="$hyprctl_log" \
    PATH="$stub_bin:/usr/bin" \
    "$uninstall_script" >/dev/null

  grep -Fxq -- 'reload' "$hyprctl_log" ||
    fail "live uninstall did not reload Hyprland"
  grep -Fxq -- 'configerrors' "$hyprctl_log" ||
    fail "live uninstall did not validate Hyprland config errors"
  assert_count 0 \
    'require\("hypr\.xeneon_edge_agents"\)' \
    "$root/.config/hypr/hyprland.lua"
  assert_no_file "$root/.config/hypr/xeneon_edge_agents.lua"
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
  : >"$root/bin/quickshell"
  : >"$root/bin/hyprctl"
  chmod +x \
    "$root/bin/xeneon-agentd" "$root/bin/xeneon-agentctl" "$root/bin/herdr" \
    "$root/bin/quickshell" "$root/bin/hyprctl"
  before=$(sha256sum "$root/config/hypr/hyprland.lua")

  if env \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_BIN_HOME="$root/bin" \
    PATH="$root/bin:/usr/bin:/bin" \
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
run_test 'production reinstall requires its explicit identity' \
  test_production_reinstall_requires_explicit_identity
run_test 'missing and ambiguous production outputs fail closed' \
  test_missing_and_ambiguous_output_fail_closed
run_test 'missing commissioning identity installs nothing' \
  test_missing_commissioning_values_do_not_install
run_test 'invalid touch vendor installs nothing' \
  test_invalid_touch_vendor_does_not_install
run_test 'touch and monitor identities fail closed' \
  test_touch_and_monitor_identity_fail_closed
run_test 'failed hyprctl inventory queries fail closed' \
  test_hyprctl_query_failures_fail_closed
run_test 'preexisting Hyprland require remains user-owned' \
  test_preexisting_hypr_require_is_preserved
run_test 'symlinked Hyprland entrypoint is refused' \
  test_symlinked_hypr_entrypoint_is_refused
run_test 'changed injected require preserves its module' \
  test_changed_injected_require_preserves_module
run_test 'explicit XDG directories are supported' test_explicit_xdg_paths
run_test 'path boundaries reject systemd hazards and allow spaces' \
  test_path_boundaries_and_spaces
run_test 'uninstall leaves unowned same-name services untouched' \
  test_uninstall_does_not_touch_unowned_services
run_test 'modified managed units abort uninstall before dependency removal' \
  test_modified_managed_unit_aborts_uninstall
run_test 'activation restarts already-active services' \
  test_activation_restarts_active_services
run_test 'failed activation restores prior managed artifacts and services' \
  test_failed_activation_restores_prior_artifacts
run_test 'live uninstall reloads and validates Hyprland' \
  test_live_uninstall_reloads_hyprland
run_test 'absent live EDGE preflight changes no live files' \
  test_live_production_preflight_changes_nothing_when_edge_absent
run_test 'read-only detection reports the absent-hardware gate' \
  test_read_only_detection_reports_physical_gate
printf '1..%d\n' "$tests_run"
