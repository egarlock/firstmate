#!/usr/bin/env bash
# tests/fm-backend-cmux.test.sh - fake-cmux-CLI unit tests for the cmux
# session-provider adapter (bin/backends/cmux.sh), verified against the real
# cmux 0.64.17 binary (docs/cmux-backend.md). Mirrors
# tests/fm-backend-zellij.test.sh's/tests/fm-backend-herdr.test.sh's
# fakebin/command-log convention: a small, LOG-based, canned-response fake
# `cmux` + real `jq` (jq is a real required tool for this backend, not
# faked). The real-binary smoke test lives in
# tests/fm-backend-cmux-smoke.test.sh, gated on the cmux binary actually
# being installed and reachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-cmux-tests)

# make_cmux_fakebin: a `cmux` stub that logs every invocation (one line,
# unit-separated args, to $FM_CMUX_LOG) and returns the canned response for
# that call read from $FM_CMUX_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...), mirroring
# tests/fm-backend-zellij.test.sh's make_zellij_fakebin. A missing response
# file means "succeed with empty stdout" (new-workspace/send/send-key/
# close-* are silent on success on the real CLI). `version` and `ping` are
# handled specially (not call-counted, not consuming the ordered response
# queue) since fm_backend_cmux_version_check/fm_backend_cmux_ping_state are
# called at points a test may not want to hand-count, exactly mirroring
# zellij's --version/list-sessions special-casing.
make_cmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUX_LOG:?}"
RESP="${FM_CMUX_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'CMUX_SOCKET_PASSWORD=%s' "${CMUX_SOCKET_PASSWORD:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = version ]; then
  printf 'cmux %s (97) [abcdef1]\n' "${FM_CMUX_FAKE_VERSION:-0.64.17}"
  exit 0
fi
if [ "${1:-}" = ping ]; then
  printf '%s\n' "${FM_CMUX_FAKE_PING:-PONG}"
  exit "${FM_CMUX_FAKE_PING_EXIT:-0}"
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

cmux_workspace_list_response() {  # <dir> <n> <id1> <title1> [<id2> <title2> ...]
  local dir=$1 n=$2 json first=1
  shift 2
  json='{"workspaces":['
  while [ $# -ge 2 ]; do
    [ "$first" -eq 1 ] || json="$json,"
    json="$json{\"id\":\"$1\",\"title\":\"$2\"}"
    first=0
    shift 2
  done
  json="$json]}"
  printf '%s' "$json" > "$dir/responses/$n.out"
}

cmux_panes_response() {  # <dir> <n> <surface_id>
  printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}' "$3" "$3" > "$1/responses/$2.out"
}

cmux_windows_response() {  # <dir> <n> <window_id1> <count1> [<window_id2> <count2> ...]
  local dir=$1 n=$2 json first=1
  shift 2
  json='['
  while [ $# -ge 2 ]; do
    [ "$first" -eq 1 ] || json="$json,"
    json="$json{\"id\":\"$1\",\"workspace_count\":$2}"
    first=0
    shift 2
  done
  json="$json]"
  printf '%s' "$json" > "$dir/responses/$n.out"
}

cmux_panes_empty_response() {  # <dir> <n>
  printf '{"panes":[]}' > "$1/responses/$2.out"
}

cmux_surfaces_response() {  # <dir> <n> <id1> <title1> <index1> [<id2> <title2> <index2> ...]
  local dir=$1 n=$2 json first=1
  shift 2
  json='{"surfaces":['
  while [ $# -ge 3 ]; do
    [ "$first" -eq 1 ] || json="$json,"
    json="$json{\"id\":\"$1\",\"title\":\"$2\",\"index\":$3}"
    first=0
    shift 3
  done
  json="$json]}"
  printf '%s' "$json" > "$dir/responses/$n.out"
}

cmux_read_screen_response() {  # <dir> <n> <text>
  jq -n --arg t "$3" '{text:$t}' > "$1/responses/$2.out"
}

cmux_expected_root_hash() {  # <root>
  local root real
  root=$1
  real=$(cd "$root" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

cmux_expected_home_label() {  # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  printf '%s-%s' "$prefix" "$(cmux_expected_root_hash "$root")"
}

cmux_expected_scoped_title() {  # <fm-task-label> [home] [root]
  local label=$1 home=${2:-$ROOT} root=${3:-$ROOT} rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(cmux_expected_home_label "$home" "$root")" "$rest"
}

cmux_assert_call_order() {
  local log=$1 before=$2 after=$3 msg=$4 before_line after_line
  before_line=$(grep -anF -- "$before" "$log" | head -1 | cut -d: -f1)
  after_line=$(grep -anF -- "$after" "$log" | head -1 | cut -d: -f1)
  [ -n "$before_line" ] || fail "$msg (missing before call: '$before')"
  [ -n "$after_line" ] || fail "$msg (missing after call: '$after')"
  [ "$before_line" -lt "$after_line" ] || fail "$msg"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_version() {
  local dir fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_VERSION=0.64.17 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept 0.64.17 (the verified minimum)"
  pass "fm_backend_cmux_version_check: accepts the verified minimum (0.64.17)"
}

test_version_check_accepts_newer_version() {
  local dir fb status
  dir="$TMP_ROOT/version-newer"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_VERSION=0.70.0 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept a newer minor (0.70.0)"
  pass "fm_backend_cmux_version_check: accepts a newer version (0.70.0)"
}

test_version_check_refuses_old_version() {
  local dir fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_VERSION=0.50.0 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse 0.50.0 (below the 0.64 minimum)"
  assert_contains "$out" "0.50.0" "version_check error did not name the rejected version"
  pass "fm_backend_cmux_version_check: refuses an old version loudly"
}

test_version_check_refuses_missing_cmux() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  # FM_BACKEND_CMUX_BUNDLE_BIN must also be overridden to a nonexistent path:
  # this test may run on a machine (like the one that verified this adapter)
  # where cmux really is installed at the real bundle path, which the plain
  # PATH-emptying above would not hide.
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" FM_BACKEND_CMUX_BUNDLE_BIN="$dir/no-such-cmux" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when cmux is not installed"
  assert_contains "$out" "not found" "version_check did not report cmux as missing"
  pass "fm_backend_cmux_version_check: refuses loudly when cmux is not found on PATH or at the bundle path"
}

# --- password resolution -------------------------------------------------

test_password_reads_from_config_file() {
  local dir out
  dir="$TMP_ROOT/password-file"; mkdir -p "$dir/config"
  printf 'sekret-pw\n' > "$dir/config/cmux-socket-password"
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ "$out" = "sekret-pw" ] || fail "password should be read from config/cmux-socket-password, got '$out'"
  pass "fm_backend_cmux_password: reads the first non-empty line of config/cmux-socket-password"
}

test_password_preserves_config_file_whitespace() {
  local dir out
  dir="$TMP_ROOT/password-file-whitespace"; mkdir -p "$dir/config"
  printf '\nsek ret\t pw  \n' > "$dir/config/cmux-socket-password"
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ "$out" = $'sek ret\t pw  ' ] || fail "password should preserve spaces and tabs from config/cmux-socket-password, got '$out'"
  pass "fm_backend_cmux_password: preserves spaces and tabs in config/cmux-socket-password"
}

test_password_respects_config_override() {
  local dir home_cfg override_cfg out
  dir="$TMP_ROOT/password-config-override"; home_cfg="$dir/home/config"; override_cfg="$dir/override-config"
  mkdir -p "$home_cfg" "$override_cfg"
  printf 'home-pw\n' > "$home_cfg/cmux-socket-password"
  printf 'override-pw\n' > "$override_cfg/cmux-socket-password"
  out=$( FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$override_cfg" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ "$out" = "override-pw" ] || fail "password should be read from FM_CONFIG_OVERRIDE, got '$out'"
  pass "fm_backend_cmux_password: respects FM_CONFIG_OVERRIDE"
}

test_password_empty_when_config_absent() {
  local dir out
  dir="$TMP_ROOT/password-absent"; mkdir -p "$dir/config"
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ -z "$out" ] || fail "password should be empty when config/cmux-socket-password is absent, got '$out'"
  pass "fm_backend_cmux_password: empty when config/cmux-socket-password is absent"
}

test_cli_exports_password_only_when_configured() {
  local dir fb
  dir="$TMP_ROOT/password-export"; mkdir -p "$dir/config" "$dir/responses"
  printf 'sekret-pw\n' > "$dir/config/cmux-socket-password"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_HOME="$dir" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_cli ping' "$ROOT" >/dev/null
  assert_contains "$(cat "$dir/log")" "CMUX_SOCKET_PASSWORD=sekret-pw" \
    "fm_backend_cmux_cli did not export the configured password"
  pass "fm_backend_cmux_cli: exports CMUX_SOCKET_PASSWORD when config/cmux-socket-password is set"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/cmux.sh"
    fm_backend_cmux_parse_target "11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222" || exit 1
    [ "$FM_BACKEND_CMUX_WORKSPACE" = "11111111-1111-1111-1111-111111111111" ] || { echo "workspace mismatch: $FM_BACKEND_CMUX_WORKSPACE" >&2; exit 1; }
    [ "$FM_BACKEND_CMUX_SURFACE" = "22222222-2222-2222-2222-222222222222" ] || { echo "surface mismatch: $FM_BACKEND_CMUX_SURFACE" >&2; exit 1; }
  ) || fail "fm_backend_cmux_parse_target did not split workspace:surface correctly"
  pass "fm_backend_cmux_parse_target: splits '<workspace_uuid>:<surface_uuid>' on the first colon"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/cmux.sh"
    [ "$(fm_backend_cmux_normalize_key Enter)" = enter ] || { echo "Enter failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key Escape)" = escape ] || { echo "Escape failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key Esc)" = escape ] || { echo "Esc failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key C-c)" = ctrl-c ] || { echo "C-c failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key ctrl+c)" = ctrl-c ] || { echo "ctrl+c failed" >&2; exit 1; }
  ) || fail "fm_backend_cmux_normalize_key did not map firstmate's key vocabulary to cmux's verified names"
  pass "fm_backend_cmux_normalize_key: Enter/Escape/C-c map to cmux's verified enter/escape/ctrl-c"
}

test_scoped_title_uses_primary_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-title-primary"; mkdir -p "$dir"
  expected=$(cmux_expected_scoped_title fm-task1 "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  [ "$out" = "$expected" ] || fail "primary scoped title should be $expected, got '$out'"
  pass "fm_backend_cmux_scoped_title: scopes a primary task title with firstmate plus root hash"
}

test_scoped_title_uses_secondmate_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-title-secondmate"; mkdir -p "$dir"
  printf 'sm-one\n' > "$dir/.fm-secondmate-home"
  expected=$(cmux_expected_scoped_title fm-task1 "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  [ "$out" = "$expected" ] || fail "secondmate scoped title should be $expected, got '$out'"
  pass "fm_backend_cmux_scoped_title: scopes a secondmate task title with the home marker plus root hash"
}

test_scoped_title_changes_with_root_path() {
  local dir home root_one root_two out_one out_two expected_one expected_two
  dir="$TMP_ROOT/scoped-title-root-hash"; home="$dir/home"; root_one="$dir/root-one"; root_two="$dir/root-two"
  mkdir -p "$home" "$root_one" "$root_two"
  expected_one=$(cmux_expected_scoped_title fm-task1 "$home" "$root_one")
  expected_two=$(cmux_expected_scoped_title fm-task1 "$home" "$root_two")
  out_one=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_one" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  out_two=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_two" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  [ "$out_one" = "$expected_one" ] || fail "scoped title should include root-one hash as $expected_one, got '$out_one'"
  [ "$out_two" = "$expected_two" ] || fail "scoped title should include root-two hash as $expected_two, got '$out_two'"
  [ "$out_one" != "$out_two" ] || fail "scoped titles should differ for distinct FM_ROOT paths"
  pass "fm_backend_cmux_scoped_title: includes the resolved FM_ROOT hash in the home label"
}

# --- dispatch wiring (fm-backend.sh) ------------------------------------------

test_dispatch_routes_cmux_backend() {
  fm_backend_validate cmux 2>/dev/null || fail "fm_backend_validate should accept cmux"
  pass "fm_backend_validate: cmux is a known backend"
}

test_dispatch_busy_state_unknown_for_cmux() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state cmux '11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for cmux (no native agent-state primitive)"
  pass "fm_backend_busy_state: cmux (no native primitive) always reports unknown, same as tmux/zellij/orca"
}

test_dispatch_composer_state_routes_cmux() {
  local dir fb out target
  dir="$TMP_ROOT/dispatch-composer"; mkdir -p "$dir/responses"
  target="aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain         │\n  ╰──────── Composer ─────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state cmux "$1"' "$ROOT" "$target" )
  [ "$out" = pending ] || fail "fm_backend_composer_state should route cmux to its classifier, got '$out'"
  pass "fm_backend_composer_state: routes cmux to the cmux composer classifier"
}

# --- ping_state / ensure_running ---------------------------------------------

test_ping_state_ok() {
  local dir fb out
  dir="$TMP_ROOT/ping-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING=PONG \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = ok ] || fail "ping_state should report ok on PONG, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'ok' on PONG"
}

test_ping_state_denied() {
  local dir fb out
  dir="$TMP_ROOT/ping-denied"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Access denied - only processes started inside cmux can connect" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = denied ] || fail "ping_state should report denied on the cmuxOnly rejection text, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'denied' when socketControlMode=cmuxOnly rejects the connection"
}

test_ping_state_unauth() {
  local dir fb out
  dir="$TMP_ROOT/ping-unauth"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Authentication required - send auth <password> first" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = unauth ] || fail "ping_state should report unauth when no password was presented, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'unauth' when password mode rejects a missing/wrong password"
}

test_ping_state_invalid_password() {
  local dir fb out
  dir="$TMP_ROOT/ping-invalid-pw"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Invalid password" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = unauth ] || fail "ping_state should report unauth on the wrong-password rejection text, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'unauth' when password mode rejects a wrong password (Invalid password)"
}

test_ping_state_down() {
  local dir fb out
  dir="$TMP_ROOT/ping-down"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: Socket not found at /Users/x/.local/state/cmux/cmux.sock" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = down ] || fail "ping_state should report down when the socket does not exist yet, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'down' when the app is not running yet"
}

test_ensure_running_returns_immediately_when_already_ok() {
  local dir fb status
  dir="$TMP_ROOT/ensure-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/open" <<'SH'
#!/usr/bin/env bash
echo "open should not be called when cmux is already reachable" >&2
exit 1
SH
  chmod +x "$fb/open"
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING=PONG \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ensure_running' "$ROOT"
  status=$?
  expect_code 0 "$status" "ensure_running should succeed immediately when already reachable"
  pass "fm_backend_cmux_ensure_running: returns immediately when cmux is already reachable"
}

test_ensure_running_fails_fast_on_denied_without_launching() {
  local dir fb out status
  dir="$TMP_ROOT/ensure-denied"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/open" <<'SH'
#!/usr/bin/env bash
echo "LAUNCHED" >> "${FM_CMUX_LAUNCH_MARKER:?}"
exit 0
SH
  chmod +x "$fb/open"
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Access denied - only processes started inside cmux can connect" \
    FM_CMUX_LAUNCH_MARKER="$dir/launched" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ensure_running' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "ensure_running should refuse when the socket is denied (relaunching cannot fix a config problem)"
  [ ! -f "$dir/launched" ] || fail "ensure_running should not attempt to launch cmux on a denied socket"
  assert_contains "$out" "docs/cmux-backend.md" "ensure_running's denied error did not point at the setup docs"
  assert_contains "$out" "Automation mode" "ensure_running's denied error did not name the recommended Automation mode"
  assert_contains "$out" "Password mode" "ensure_running's denied error did not name the Password mode alternative"
  assert_contains "$out" "Full open access" "ensure_running's denied error did not name (and caveat) Full open access"
  pass "fm_backend_cmux_ensure_running: fails fast on a denied socket without attempting to launch, naming every viable mode"
}

test_ensure_running_fails_fast_on_unauth_without_launching() {
  local dir fb out status
  dir="$TMP_ROOT/ensure-unauth"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/open" <<'SH'
#!/usr/bin/env bash
echo "LAUNCHED" >> "${FM_CMUX_LAUNCH_MARKER:?}"
exit 0
SH
  chmod +x "$fb/open"
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Authentication required - send auth <password> first" \
    FM_CMUX_LAUNCH_MARKER="$dir/launched" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ensure_running' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "ensure_running should refuse when the socket is unauthenticated (relaunching cannot fix a password problem)"
  [ ! -f "$dir/launched" ] || fail "ensure_running should not attempt to launch cmux on an unauthenticated socket"
  assert_contains "$out" "config/cmux-socket-password" "ensure_running's unauth error did not name the password config file"
  assert_contains "$out" "Automation mode" "ensure_running's unauth error did not name the recommended no-password Automation mode"
  assert_contains "$out" "docs/cmux-backend.md" "ensure_running's unauth error did not point at the setup docs"
  pass "fm_backend_cmux_ensure_running: fails fast on an unauthenticated socket, naming the password config and the Automation mode alternative"
}

# --- create_task: duplicate refusal, id resolution ---------------------------

test_create_task_refuses_duplicate_label() {
  local dir fb out status title
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-dup1)
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task workspace fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing workspace title (cmux itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate name"
  pass "fm_backend_cmux_create_task: refuses a duplicate workspace title (cmux's own new-workspace has no uniqueness check)"
}

test_create_task_creates_and_parses_ids() {
  local dir fb out title
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-newtask)
  # 1: workspace list --json (pre-create duplicate check) -> no match
  printf '{"workspaces":[]}' > "$dir/responses/1.out"
  # 2: new-workspace (silent on success)
  # 3: workspace list --json (post-create id resolution) -> match
  cmux_workspace_list_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111" "$title"
  # 4: list-panes --json --id-format uuids -> default surface id
  cmux_panes_response "$dir" 4 "cccccccc-2222-2222-2222-222222222222"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task workspace fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "bbbbbbbb-1111-1111-1111-111111111111 cccccccc-2222-2222-2222-222222222222" ] \
    || fail "create_task should echo '<workspace_id> <surface_id>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--name'$'\x1f'"$title"$'\x1f''--cwd'$'\x1f''/tmp/proj' \
    "create_task did not call new-workspace with the right name/cwd"
  assert_contains "$(cat "$dir/log")" $'\x1f''--focus'$'\x1f''false' \
    "create_task did not pass --focus false"
  pass "fm_backend_cmux_create_task: creates a workspace and parses workspace_id/surface_id from list responses"
}

# --- target_ready / capture ---------------------------------------------------

test_target_ready_fails_when_target_absent() {
  local dir fb status
  dir="$TMP_ROOT/ready-absent"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids -> no panes at all (surface absent)
  cmux_panes_empty_response "$dir" 1
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_target_ready "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should fail when list-panes reports the surface not found"
  pass "fm_backend_cmux_target_ready: fails when the workspace/surface is not found (list-panes structural check)"
}

test_target_ready_checks_expected_label() {
  local dir fb title
  dir="$TMP_ROOT/ready-label-ok"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-label)
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  # 2: list-panes --json --id-format uuids -> matching surface
  cmux_panes_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_target_ready "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" fm-label' "$ROOT"
  expect_code 0 $? "target_ready should succeed when the workspace title matches the expected label"
  cmux_assert_call_order "$dir/log" $'\x1f''workspace'$'\x1f''list' $'\x1f''list-panes' \
    "target_ready did not check the label before list-panes"
  pass "fm_backend_cmux_target_ready: verifies the workspace title against the expected label first"
}

test_target_ready_rejects_label_mismatch() {
  local dir fb status
  dir="$TMP_ROOT/ready-label-mismatch"; mkdir -p "$dir/responses"
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "not-the-task"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_target_ready "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" fm-label' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should reject a workspace whose title does not match the expected label"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''list-panes' \
    "target_ready should not call list-panes after a label mismatch"
  pass "fm_backend_cmux_target_ready: rejects a workspace id reused under a different title"
}

test_capture_trims_locally() {
  local dir fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  # 2: read-screen --scrollback --lines 200 --json (actual fetch)
  cmux_read_screen_response "$dir" 2 $'line one\nline two\nline three\nline four'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" 2' "$ROOT" )
  [ "$out" = $'line three\nline four' ] || fail "capture should trim to the last N lines locally, got '$out'"
  cmux_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    $'\x1f''--scrollback' "capture did not verify readiness before the actual read"
  pass "fm_backend_cmux_capture: fetches generously and trims to N lines locally"
}

test_capture_fails_when_read_screen_fails_empty() {
  local dir fb status
  dir="$TMP_ROOT/capture-read-fail"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  # 2: read-screen exits nonzero with no stdout
  printf '1' > "$dir/responses/2.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" 5' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when read-screen exits nonzero with no stdout"
  assert_contains "$(cat "$dir/log")" $'\x1f''read-screen' \
    "capture should attempt read-screen after readiness succeeds"
  pass "fm_backend_cmux_capture: propagates a read-screen failure even when stdout is empty"
}

test_capture_fails_when_target_not_ready() {
  local dir fb status
  dir="$TMP_ROOT/capture-not-ready"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids -> no matching surface
  cmux_panes_empty_response "$dir" 1
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" 5' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the target is not ready"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''--scrollback' \
    "capture should not fetch after readiness fails"
  pass "fm_backend_cmux_capture: fails when the target surface is absent"
}

# --- send_key / send_literal --------------------------------------------------

test_send_key_normalizes_and_targets() {
  local dir fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''escape' \
    "send_key did not normalize Escape to escape and target the explicit workspace/surface"
  pass "fm_backend_cmux_send_key: normalizes the key (Escape -> escape) and targets the explicit workspace/surface"
}

test_send_key_recovers_stale_target_by_label() {
  local dir fb title
  dir="$TMP_ROOT/sendkey-stale-target"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-label)
  cmux_workspace_list_response "$dir" 1 "cccccccc-2222-2222-2222-222222222222" "$title"
  cmux_workspace_list_response "$dir" 2 "cccccccc-2222-2222-2222-222222222222" "$title"
  cmux_panes_response "$dir" 3 "dddddddd-3333-3333-3333-333333333333"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" Enter fm-label' "$ROOT"
  expect_code 0 $? "send_key should recover a stale cmux target when the expected label is live"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''cccccccc-2222-2222-2222-222222222222'$'\x1f''--surface'$'\x1f''dddddddd-3333-3333-3333-333333333333'$'\x1f''enter' \
    "send_key did not use the refreshed cmux workspace/surface ids"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "send_key should not target the stale cmux workspace id after label recovery"
  pass "fm_backend_cmux_send_key: recovers stale workspace/surface ids by expected label"
}

test_send_literal_uses_separator_for_option_shaped_text() {
  local dir fb
  dir="$TMP_ROOT/sendliteral"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_literal "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "--help"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''--help' \
    "send_literal did not call send with a -- separator before the literal payload"
  pass "fm_backend_cmux_send_literal: calls send with an explicit workspace/surface and a -- separator"
}

# --- current_path: passive tiers first, pwd-marker-probe fallback ------------

test_current_path_falls_back_to_marker_probe() {
  local dir fb out
  # Verified real-cmux pitfall (docs/cmux-backend.md finding #2): the surface's
  # cwd is frozen at creation time (the top-level shell's cwd), never following
  # a foreground subshell (e.g. treehouse get). When every passive tier comes
  # up empty (no tty in the tree, no on-screen block header, no expected
  # label for the workspace-list tier), current_path still actively prints a
  # marked cwd line and reads only that marker from the capture - upstream's
  # original probe, kept as the tier-4 fallback.
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"
  # 1: list-panes (current_path's own target_ready)
  # 2: tree (tier 1) -> empty: no tty
  # 3: list-panes (target_ready, called by capture for tier 2's screen_cwd)
  # 4: read-screen (tier 2) -> no block-header line
  # 5: list-panes (target_ready, called by send_text_line->send_literal)
  # 6: send (literal probe text)
  # 7: list-panes (target_ready, called by send_text_line->send_key)
  # 8: send-key enter
  # 9: list-panes (target_ready, called by capture)
  # 10: read-screen --scrollback --lines 200 --json (actual fetch)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 4 $'/tmp/proj\n❯'
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 10 $'/tmp/proj\n❯ printf marker\n__FM_CMUX_CWD_BEGIN__\n/Users/kunchen/.treehouse/fake-worktree\n__FM_CMUX_CWD_END__\n/Users/kunchen/.treehouse/fake-worktree ❯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = "/Users/kunchen/.treehouse/fake-worktree" ] || fail "current_path should read only the marked cwd line, got '$out'"
  assert_contains "$(cat "$dir/log")" "__FM_CMUX_CWD_BEGIN__" "current_path did not send the cwd begin marker"
  assert_contains "$(cat "$dir/log")" "pwd;" "current_path did not send the pwd probe"
  assert_contains "$(cat "$dir/log")" $'\x1f''tree'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "current_path did not consult the tree (passive tier 1) before probing"
  cmux_assert_call_order "$dir/log" $'\x1f''tree'$'\x1f' $'\x1f''send'$'\x1f' \
    "current_path should try the passive tty tier BEFORE typing the active probe"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''enter' \
    "current_path did not submit the cwd probe with Enter"
  pass "fm_backend_cmux_current_path: falls back to the active marker probe when every passive tier is empty"
}

test_current_path_tier1_tty_ps_lsof() {
  local dir fb out
  # Passive tier 1: the surface's tty from `cmux tree`, the foreground process
  # group on that tty via ps, its cwd via lsof - no typing into the terminal.
  dir="$TMP_ROOT/cwd-tier1"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready); 2: tree -> tty line for the surface
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  printf 'window window:1 W1 [current]\n  surface surface:9 bbbbbbbb-1111-1111-1111-111111111111 [terminal] "x" tty=ttys099\n' > "$dir/responses/2.out"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/ps" <<'SH'
#!/bin/sh
printf '  123 S\n  456 S+\n'
SH
  cat > "$fb/lsof" <<'SH'
#!/bin/sh
printf 'p456\nn/Users/kunchen/.treehouse/tier1-worktree\n'
SH
  chmod +x "$fb/ps" "$fb/lsof"
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = "/Users/kunchen/.treehouse/tier1-worktree" ] \
    || fail "current_path tier 1 should report the lsof cwd of the tty's foreground process, got '$out'"
  case "$(cat "$dir/log")" in
    *$'\x1f'send$'\x1f'*) fail "tier 1 answered; current_path must not type the active probe" ;;
  esac
  pass "fm_backend_cmux_current_path: passive tier 1 (tree tty + ps + lsof) answers without touching the terminal"
}

test_current_path_tier2_screen_block_header() {
  local dir fb out
  # Passive tier 2: the on-screen block-header cwd. cmux renders every command
  # block with "| [<tag>] <ABSOLUTE_CWD> @ <host> (<user>)" (trailing space
  # included - shape re-verified on 0.64.20); the LAST header wins.
  dir="$TMP_ROOT/cwd-tier2"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready); 2: tree -> no tty;
  # 3: list-panes (capture's target_ready); 4: read-screen with block headers
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 4 $'| [arm] /tmp/proj @ host (captain) \n| => treehouse get\n| [arm] /Users/kunchen/.treehouse/tier2-worktree @ host (captain) \n| =>'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = "/Users/kunchen/.treehouse/tier2-worktree" ] \
    || fail "current_path tier 2 should report the LAST on-screen block-header cwd, got '$out'"
  case "$(cat "$dir/log")" in
    *$'\x1f'send$'\x1f'*) fail "tier 2 answered; current_path must not type the active probe" ;;
  esac
  pass "fm_backend_cmux_current_path: passive tier 2 reads the last on-screen block-header cwd"
}

test_current_path_tier3_workspace_dir_only_when_task_owned() {
  local dir fb out title
  # Passive tier 3: the workspace list's current_directory - consulted ONLY
  # when the workspace's title proves it is task-owned (workspace mode). The
  # expected label is what makes that proof possible.
  dir="$TMP_ROOT/cwd-tier3"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-tier3)
  # 1: workspace list (target_ready's label check) -> title matches
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  # 2: list-panes (target_ready surface_exists)
  cmux_panes_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111"
  # 3: tree -> no tty; 4: list-panes (capture); 5: read-screen -> no header
  cmux_panes_response "$dir" 4 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 5 $'no headers here\n❯'
  # 6: workspace list (tier 3 ownership re-check) -> title matches
  cmux_workspace_list_response "$dir" 6 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  # 7: workspace list (tier 3 current_directory read)
  printf '{"workspaces":[{"id":"aaaaaaaa-0000-0000-0000-000000000000","title":"%s","current_directory":"/tmp/tier3-proj"}]}' "$title" > "$dir/responses/7.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" fm-tier3' "$ROOT" )
  [ "$out" = "/tmp/tier3-proj" ] \
    || fail "current_path tier 3 should report the task-owned workspace's current_directory, got '$out'"
  case "$(cat "$dir/log")" in
    *$'\x1f'send$'\x1f'*) fail "tier 3 answered; current_path must not type the active probe" ;;
  esac
  pass "fm_backend_cmux_current_path: passive tier 3 reads current_directory only for a task-owned (workspace-mode) workspace"
}

test_current_path_tier3_skipped_for_tab_container() {
  local dir fb out title
  # In tab mode the workspace is the CONTAINER: its current_directory is the
  # container's dir, never the task's - tier 3 must be skipped (the probe
  # answers instead).
  dir="$TMP_ROOT/cwd-tier3-tab"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-tabtask)
  # 1: workspace list (target_ready) -> container title, not the task's
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "captains-own"
  # 2: list-pane-surfaces (target_ready's tab arm surface-title lookup)
  printf '{"surfaces":[{"id":"bbbbbbbb-1111-1111-1111-111111111111","title":"%s","index":0}]}' "$title" > "$dir/responses/2.out"
  # 3: tree -> no tty; 4: list-panes (capture); 5: read-screen -> no header
  cmux_panes_response "$dir" 4 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 5 $'no headers here\n❯'
  # 6: workspace list (tier 3 ownership check) -> container title, so SKIP
  cmux_workspace_list_response "$dir" 6 "aaaaaaaa-0000-0000-0000-000000000000" "captains-own"
  # 7-12: the active probe's target_ready/send/send-key/capture sequence.
  # The label-checking target_ready inside send/capture re-reads the
  # workspace list + surface list per hop, but tier 4 sends against the
  # REFRESHED raw target (no label), so: 7: list-panes (send_literal), 8:
  # send, 9: list-panes (send_key), 10: send-key, 11: list-panes (capture),
  # 12: read-screen with the marker.
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 11 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 12 $'__FM_CMUX_CWD_BEGIN__\n/Users/kunchen/.treehouse/tab-worktree\n__FM_CMUX_CWD_END__\n❯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" fm-tabtask' "$ROOT" )
  [ "$out" = "/Users/kunchen/.treehouse/tab-worktree" ] \
    || fail "tab-mode current_path should skip tier 3 (container dir) and fall through to the probe, got '$out'"
  pass "fm_backend_cmux_current_path: tier 3 is skipped for a tab-mode container workspace (probe answers instead)"
}

# --- composer_state: structural border-row classification (adapted from herdr) ----

test_composer_state_bare_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via capture)
  # 2: read-screen --scrollback --lines <N> --json (composer capture)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ─────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_cmux_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_ghost_placeholder_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-ghost"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ Type a message...    │\n  ╰──────── Composer ─────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "the known ghost placeholder 'Type a message...' should read as empty, got '$out'"
  pass "fm_backend_cmux_composer_state: the ghost placeholder text reads empty, not pending"
}

test_composer_state_real_text_is_pending() {
  local dir fb out
  dir="$TMP_ROOT/composer-pending"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain         │\n  ╰──────── Composer ─────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text should read as pending, got '$out'"
  pass "fm_backend_cmux_composer_state: real composer text reads pending"
}

# The popup-placeholder/second-Enter regression class (2026-07-03 herdr
# incident, docs/herdr-backend.md): a slash command's first Enter can close a
# completion popup and EXPAND the composer into an argument-hint placeholder
# rather than submitting. A raw content-diff check would misread the popup
# vanishing as "submitted"; the structural composer-row read must still call
# this pending so the caller retries a genuine second Enter.
test_composer_state_popup_placeholder_fill_is_pending() {
  local dir fb out
  dir="$TMP_ROOT/composer-popup-placeholder"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions    │\n  ╰──────────────── Composer ─────────────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_cmux_composer_state: a slash-command popup's argument-hint placeholder still reads pending (the incident fix)"
}

test_composer_state_unknown_on_capture_failure() {
  local dir fb out status
  dir="$TMP_ROOT/composer-capture-fail"; mkdir -p "$dir/responses"
  printf '1\n' > "$dir/responses/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable surface should read as unknown, got '$out'"
  pass "fm_backend_cmux_composer_state: reports unknown when the surface cannot be captured"
}

test_composer_state_unknown_when_no_composer_row_found() {
  local dir fb out
  dir="$TMP_ROOT/composer-no-row"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 'plain-shell-prompt$ '
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = unknown ] || fail "a capture with no recognizable composer row should read as unknown, got '$out'"
  pass "fm_backend_cmux_composer_state: reports unknown when no border-delimited composer row is found"
}

# --- send_text_submit: structural composer-row verify-and-retry --------------

test_send_text_submit_detects_landed_send() {
  local dir fb out
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via send_literal)
  # 2: send (literal text)
  # 3: list-panes (target_ready via send_key Enter)
  # 4: send-key enter
  # 5: list-panes (target_ready via composer_state's capture)
  # 6: read-screen --scrollback --lines N --json -> composer reads empty (submitted)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ─────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once the composer row reads empty, got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''hello captain' \
    "send_text_submit did not type the literal text first"
  enter_count=$(grep -c $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''enter' "$dir/log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should not need a second Enter for a plain message with no popup, sent $enter_count Enter(s)"
  pass "fm_backend_cmux_send_text_submit: reports 'empty' once the composer row reads empty after one Enter"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯ hello captain         │\n  ╰──────── Composer ─────╯\n\n  Enter:send'
  cmux_read_screen_response "$dir" 10 $'  ╭────────────────────────╮\n  │ ❯ hello captain         │\n  ╰──────── Composer ─────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with no visible change, got '$out'"
  pass "fm_backend_cmux_send_text_submit: reports 'pending' when the composer never clears after retried Enters (swallowed)"
}

# The regression test for the popup-placeholder/second-Enter class (mirrors
# herdr's 2026-07-03 incident test): Enter #1 closes the popup and fills an
# argument-hint placeholder (still pending); Enter #2 actually submits. The
# adapter must retry past the first Enter instead of declaring victory on a
# raw content change, and must actually issue the second Enter.
test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local dir fb out
  dir="$TMP_ROOT/submit-popup-autocomplete"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via send_literal)
  # 2: send "/compact"
  # 3: list-panes (target_ready via send_key Enter #1)
  # 4: send-key enter (#1) - closes the popup, fills the placeholder
  # 5: list-panes (target_ready via composer_state capture)
  # 6: composer still reads real (pending) text
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 6 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions    │\n  ╰──────────────── Composer ─────────────╯\n\n  Enter:send'
  # 7: list-panes (target_ready via send_key Enter #2)
  # 8: send-key enter (#2) - actually submits
  # 9: list-panes (target_ready via composer_state capture)
  # 10: composer now reads empty
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 10 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ─────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "/compact" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  enter_count=$(grep -c $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''enter' "$dir/log")
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should have sent exactly 2 Enters (popup-close, then real submit), sent $enter_count"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''/compact compaction instructions' \
    "send_text_submit should never retype - only retry Enter"
  pass "fm_backend_cmux_send_text_submit: retries past a popup-placeholder-fill Enter and lands the real second Enter (the incident fix)"
}

test_send_text_submit_send_failed_when_target_absent() {
  local dir fb out
  dir="$TMP_ROOT/submit-no-target"; mkdir -p "$dir/responses"
  printf '1\n' > "$dir/responses/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the target is absent, got '$out'"
  pass "fm_backend_cmux_send_text_submit: reports 'send-failed' when the target workspace/surface is absent"
}

# --- window_of_workspace: which window holds a workspace, and its count ------

test_window_of_workspace_finds_window_and_count() {
  local dir fb out
  dir="$TMP_ROOT/win-of-ws"; mkdir -p "$dir/responses"
  # 1: list-windows --json -> two windows
  cmux_windows_response "$dir" 1 "e1111111-0000-0000-0000-000000000000" 2 "e2222222-0000-0000-0000-000000000000" 2
  # 2: workspace list --window e1111111 -> does NOT contain the target
  cmux_workspace_list_response "$dir" 2 "ffffffff-0000-0000-0000-000000000000" "other"
  # 3: workspace list --window e2222222 -> contains the target
  cmux_workspace_list_response "$dir" 3 "aaaaaaaa-0000-0000-0000-000000000000" "the-task"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_window_of_workspace "aaaaaaaa-0000-0000-0000-000000000000"' "$ROOT" )
  [ "$out" = "e2222222-0000-0000-0000-000000000000 1" ] \
    || fail "window_of_workspace should echo the owning window and its matched-list count, got '$out'"
  cmux_assert_call_order "$dir/log" $'\x1f''list-windows' $'\x1f''workspace'$'\x1f''list'$'\x1f''--json'$'\x1f''--id-format'$'\x1f''uuids'$'\x1f''--window'$'\x1f''e1111111-0000-0000-0000-000000000000' \
    "window_of_workspace did not list windows before scanning per-window workspaces"
  pass "fm_backend_cmux_window_of_workspace: walks windows and counts the membership-confirming workspace list"
}

test_window_of_workspace_empty_when_not_found() {
  local dir fb out
  dir="$TMP_ROOT/win-of-ws-none"; mkdir -p "$dir/responses"
  cmux_windows_response "$dir" 1 "e1111111-0000-0000-0000-000000000000" 1
  cmux_workspace_list_response "$dir" 2 "ffffffff-0000-0000-0000-000000000000" "other"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_window_of_workspace "aaaaaaaa-0000-0000-0000-000000000000"' "$ROOT" )
  [ -z "$out" ] || fail "window_of_workspace should echo nothing when the workspace is not found, got '$out'"
  pass "fm_backend_cmux_window_of_workspace: echoes nothing when no window holds the workspace"
}

# --- kill: title-driven mode detection; workspace close vs tab close ----------

# The common case: the task-owned workspace (its title carries the home's task
# prefix) shares its window with at least one other workspace, so cmux closes
# it directly with no sibling dance.
test_kill_closes_workspace_directly_when_not_last() {
  local dir fb title
  dir="$TMP_ROOT/kill-workspace"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-task)
  # 1: workspace list -> the target's title carries the task prefix (workspace mode)
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  # 2: list-windows -> the owning window has 2 workspaces (target is NOT last)
  cmux_windows_response "$dir" 2 "eeeeeeee-0000-0000-0000-000000000000" 2
  # 3: workspace list --window eeeeeeee -> contains the target
  cmux_workspace_list_response "$dir" 3 "aaaaaaaa-0000-0000-0000-000000000000" "$title" "ffffffff-0000-0000-0000-000000000000" "other"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill did not close the task workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-workspace' \
    "kill should not add a sibling workspace when the target is not the last one in its window"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "kill should close the whole workspace directly"
  pass "fm_backend_cmux_kill: closes the task workspace directly when it is not the last in its window"
}

# The selected-workspace teardown bug: cmux refuses to close the only workspace
# in a window (returns OK but no-ops), so kill first creates a throwaway sibling
# and only then closes the target - which now succeeds.
test_kill_adds_sibling_when_last_in_window() {
  local dir fb title
  dir="$TMP_ROOT/kill-last-in-window"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-task)
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  cmux_windows_response "$dir" 2 "eeeeeeee-0000-0000-0000-000000000000" 2
  # 3: workspace list --window eeeeeeee -> contains ONLY the target
  cmux_workspace_list_response "$dir" 3 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--window'$'\x1f''eeeeeeee-0000-0000-0000-000000000000'$'\x1f''--focus'$'\x1f''false' \
    "kill did not add a throwaway sibling in the target's own window before closing the last workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--name' \
    "the throwaway sibling must stay an unnamed default workspace, never an fm- task title"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill did not close the target workspace after adding the sibling"
  cmux_assert_call_order "$dir/log" $'\x1f''new-workspace'$'\x1f''--window' $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill must add the sibling BEFORE closing the last workspace, or the close still no-ops"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "kill should not call close-surface"
  pass "fm_backend_cmux_kill: adds a throwaway sibling then closes the target when it is the last workspace in its window"
}

test_kill_is_best_effort_when_close_workspace_fails() {
  local dir fb title
  dir="$TMP_ROOT/kill-workspace-fail"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-task)
  # 1: workspace list (mode detect), 2: list-windows (not last),
  # 3: workspace list --window, 4: close-workspace fails
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$title"
  cmux_windows_response "$dir" 2 "eeeeeeee-0000-0000-0000-000000000000" 2
  cmux_workspace_list_response "$dir" 3 "aaaaaaaa-0000-0000-0000-000000000000" "$title" "ffffffff-0000-0000-0000-000000000000" "other"
  printf '1\n' > "$dir/responses/4.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  expect_code 0 $? "kill must stay best-effort (never fail) even when close-workspace fails"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill should still attempt close-workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "kill should not call close-surface"
  pass "fm_backend_cmux_kill: never fails even when close-workspace fails"
}

test_kill_recovers_stale_target_by_label() {
  local dir fb title
  dir="$TMP_ROOT/kill-stale-target"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-label)
  # target_ready label recovery: 1 workspace list (title lookup, misses stale id),
  # 2 workspace list (id-for-label -> refreshed id), 3 list-panes (surface id).
  cmux_workspace_list_response "$dir" 1 "cccccccc-2222-2222-2222-222222222222" "$title"
  cmux_workspace_list_response "$dir" 2 "cccccccc-2222-2222-2222-222222222222" "$title"
  cmux_panes_response "$dir" 3 "dddddddd-3333-3333-3333-333333333333"
  # 4: workspace list (kill's title-driven mode detect on the REFRESHED id).
  cmux_workspace_list_response "$dir" 4 "cccccccc-2222-2222-2222-222222222222" "$title"
  # window_of_workspace on the refreshed id: 5 list-windows (not last), 6 workspace list --window.
  cmux_windows_response "$dir" 5 "eeeeeeee-0000-0000-0000-000000000000" 2
  cmux_workspace_list_response "$dir" 6 "cccccccc-2222-2222-2222-222222222222" "$title" "ffffffff-0000-0000-0000-000000000000" "other"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "" fm-label' "$ROOT"
  expect_code 0 $? "kill should recover a stale cmux target when the expected label is live"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''cccccccc-2222-2222-2222-222222222222' \
    "kill did not use the refreshed cmux workspace/surface ids"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill should not target the stale cmux workspace id after label recovery"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "kill should not call close-surface"
  pass "fm_backend_cmux_kill: recovers stale workspace/surface ids by expected label"
}

# Tab mode: the workspace is a container (title does not carry the task
# prefix), so only the task's surface is closed.
test_kill_tab_closes_only_surface() {
  local dir fb
  dir="$TMP_ROOT/kill-tab"; mkdir -p "$dir/responses"
  # 1: workspace list -> container title (not this home's task prefix)
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "captains-own"
  # 2: list-pane-surfaces (surface count) -> the task tab plus another tab
  printf '{"surfaces":[{"id":"bbbbbbbb-1111-1111-1111-111111111111","title":"x","index":0},{"id":"cccccccc-2222-2222-2222-222222222222","title":"y","index":1}]}' > "$dir/responses/2.out"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111' \
    "tab-mode kill did not close the task's surface"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-workspace' \
    "tab-mode kill must never close the container workspace while other tabs remain"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-surface' \
    "tab-mode kill should not add a sibling surface when the task tab is not the last one"
  pass "fm_backend_cmux_kill: tab mode closes only the task's surface, leaving the container workspace alone"
}

# cmux refuses to close a workspace's LAST surface (invalid_state, finding #4).
# In the captain's own workspace, kill creates a throwaway default surface
# first so the close lands.
test_kill_tab_last_surface_adds_sibling_surface() {
  local dir fb
  dir="$TMP_ROOT/kill-tab-last"; mkdir -p "$dir/responses"
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "captains-own"
  # 2: list-pane-surfaces -> ONLY the task tab remains
  printf '{"surfaces":[{"id":"bbbbbbbb-1111-1111-1111-111111111111","title":"x","index":0}]}' > "$dir/responses/2.out"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-surface'$'\x1f''--type'$'\x1f''terminal'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--focus'$'\x1f''false' \
    "tab-mode kill did not add a throwaway sibling surface before closing the last tab"
  cmux_assert_call_order "$dir/log" $'\x1f''new-surface'$'\x1f' $'\x1f''close-surface'$'\x1f' \
    "the sibling surface must be created BEFORE the close, or cmux refuses the last-surface close"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111' \
    "tab-mode kill did not close the task's surface after adding the sibling"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-workspace' \
    "the captain's own workspace must never be closed by a task kill"
  pass "fm_backend_cmux_kill: adds a throwaway sibling surface then closes the last task tab in a captain-owned container"
}

# When the last remaining tab lives in this home's own SHARED container
# workspace, the whole now-task-free container is reclaimed instead.
test_kill_tab_last_surface_in_shared_container_closes_container() {
  local dir fb shared
  dir="$TMP_ROOT/kill-tab-shared"; mkdir -p "$dir/responses"
  shared="fm-$(cmux_expected_home_label)"
  cmux_workspace_list_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "$shared"
  # 2: list-pane-surfaces -> ONLY the task tab remains
  printf '{"surfaces":[{"id":"bbbbbbbb-1111-1111-1111-111111111111","title":"x","index":0}]}' > "$dir/responses/2.out"
  # close_workspace_safely: 3: list-windows (not last), 4: workspace list --window
  cmux_windows_response "$dir" 3 "eeeeeeee-0000-0000-0000-000000000000" 2
  cmux_workspace_list_response "$dir" 4 "aaaaaaaa-0000-0000-0000-000000000000" "$shared" "ffffffff-0000-0000-0000-000000000000" "other"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill did not reclaim this home's now-task-free shared container workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "reclaiming the shared container makes a separate surface close redundant"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-surface' \
    "reclaiming the shared container must not add a throwaway surface first"
  pass "fm_backend_cmux_kill: reclaims this home's shared container workspace when the last task tab in it is killed"
}

# With an expected label, task-ownership is an EXACT scoped-title match: a
# tab living in a container that happens to be ANOTHER task's scoped
# workspace must close only its own surface, never the container.
test_kill_tab_with_label_in_task_titled_container_closes_only_surface() {
  local dir fb c="aaaaaaaa-0000-0000-0000-000000000000" s="bbbbbbbb-1111-1111-1111-111111111111" host_title tab_title
  dir="$TMP_ROOT/kill-tab-labeled"; mkdir -p "$dir/responses"
  host_title=$(cmux_expected_scoped_title fm-hostws)
  tab_title=$(cmux_expected_scoped_title fm-tabx)
  # target_ready (label): 1: workspace list -> the container carries ANOTHER
  # task's scoped title; 2: list-pane-surfaces -> the tab under its own title
  cmux_workspace_list_response "$dir" 1 "$c" "$host_title"
  cmux_surfaces_response "$dir" 2 "$s" "$tab_title" 1
  # kill: 3: workspace list (mode detect - exact match fails), 4:
  # list-pane-surfaces (count 2), then close-surface
  cmux_workspace_list_response "$dir" 3 "$c" "$host_title"
  cmux_surfaces_response "$dir" 4 "dddddddd-3333-3333-3333-333333333333" "zsh" 0 "$s" "$tab_title" 1
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill "'"$c:$s"'" "" fm-tabx' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$s" \
    "the labeled tab kill did not close the task's own surface"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-workspace' \
    "a labeled tab kill must never close a container that is not the label's own scoped workspace"
  pass "fm_backend_cmux_kill: with a label, task-ownership is an exact scoped-title match - a task-titled container survives its tabs"
}

# --- list_live: label-based orphan discovery ---------------------------------

test_list_live_filters_by_title_prefix() {
  local dir fb out title other_title other_root
  dir="$TMP_ROOT/list-live"; mkdir -p "$dir/responses"
  other_root="$dir/other-root"; mkdir -p "$other_root"
  title=$(cmux_expected_scoped_title fm-task1)
  other_title=$(cmux_expected_scoped_title fm-task2 "$ROOT" "$other_root")
  # 1: workspace list --json --id-format uuids -> one in-home task, two unrelated
  cmux_workspace_list_response "$dir" 1 \
    "aaaaaaaa-0000-0000-0000-000000000000" "$title" \
    "dddddddd-8888-8888-8888-888888888888" "$other_title" \
    "cccccccc-9999-9999-9999-999999999999" "zsh"
  # 2: list-panes for this home's task1 workspace
  cmux_panes_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_list_live' "$ROOT" )
  [ "$out" = $'aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111\tfm-task1' ] \
    || fail "list_live should list only the in-home task workspace with its plain label and surface id, got '$out'"
  pass "fm_backend_cmux_list_live: lists only this home's scoped task workspaces using plain fm-<id> labels"
}

# --- container mode: FM_CMUX_CONTAINER > config/cmux-container > workspace ---

test_container_mode_resolution() {
  local dir out
  dir="$TMP_ROOT/container-mode"; mkdir -p "$dir/config"
  out=$( FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER='' \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_mode' "$ROOT" )
  [ "$out" = workspace ] || fail "container mode should default to workspace (upstream's original shape), got '$out'"
  printf 'tab\n' > "$dir/config/cmux-container"
  out=$( FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER='' \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_mode' "$ROOT" )
  [ "$out" = tab ] || fail "container mode should read config/cmux-container, got '$out'"
  out=$( FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER=workspace \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_mode' "$ROOT" )
  [ "$out" = workspace ] || fail "FM_CMUX_CONTAINER must win over config/cmux-container, got '$out'"
  printf 'bogus\n' > "$dir/config/cmux-container"
  out=$( FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER='' \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_mode' "$ROOT" 2>"$dir/warn" )
  [ "$out" = workspace ] || fail "an unknown container mode must fall back to workspace, got '$out'"
  assert_contains "$(cat "$dir/warn")" "unknown cmux container mode" \
    "the unknown-mode fallback should warn on stderr"
  pass "fm_backend_cmux_container_mode: env > config file > default workspace, warning on unknown values"
}

test_container_ensure_workspace_mode_echoes_token() {
  local dir fb out
  dir="$TMP_ROOT/container-ws"; mkdir -p "$dir/responses" "$dir/config"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER='' CMUX_WORKSPACE_ID='' \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_ensure /tmp/proj' "$ROOT" )
  [ "$out" = workspace ] || fail "workspace-mode container_ensure should echo the literal token 'workspace', got '$out'"
  pass "fm_backend_cmux_container_ensure: workspace mode echoes the 'workspace' token (no container to stand up)"
}

test_container_ensure_tab_mode_uses_own_workspace() {
  local dir fb out
  dir="$TMP_ROOT/container-own"; mkdir -p "$dir/responses" "$dir/config"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER=tab \
    CMUX_WORKSPACE_ID="99999999-9999-9999-9999-999999999999" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_ensure /tmp/proj' "$ROOT" )
  [ "$out" = "99999999-9999-9999-9999-999999999999" ] \
    || fail "tab-mode container_ensure inside cmux should reuse firstmate's own workspace (CMUX_WORKSPACE_ID), got '$out'"
  [ ! -s "$dir/responses/.count" ] || [ "$(cat "$dir/responses/.count")" = 0 ] \
    || fail "reusing CMUX_WORKSPACE_ID should need no workspace lookup calls"
  pass "fm_backend_cmux_container_ensure: tab mode inside cmux joins firstmate's own workspace"
}

test_container_ensure_tab_mode_finds_shared_workspace() {
  local dir fb out shared
  dir="$TMP_ROOT/container-shared-find"; mkdir -p "$dir/responses" "$dir/config"
  shared="fm-$(cmux_expected_home_label)"
  cmux_workspace_list_response "$dir" 1 "77777777-7777-7777-7777-777777777777" "$shared"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER=tab CMUX_WORKSPACE_ID='' \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_ensure /tmp/proj' "$ROOT" )
  [ "$out" = "77777777-7777-7777-7777-777777777777" ] \
    || fail "tab-mode container_ensure outside cmux should adopt the existing shared per-home workspace, got '$out'"
  pass "fm_backend_cmux_container_ensure: tab mode outside cmux adopts the existing shared per-home workspace"
}

test_container_ensure_tab_mode_creates_shared_workspace() {
  local dir fb out shared
  dir="$TMP_ROOT/container-shared-create"; mkdir -p "$dir/responses" "$dir/config"
  shared="fm-$(cmux_expected_home_label)"
  # 1: workspace list (miss), 2: new-workspace, 3: workspace list (hit)
  printf '{"workspaces":[]}' > "$dir/responses/1.out"
  cmux_workspace_list_response "$dir" 3 "88888888-8888-8888-8888-888888888888" "$shared"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CMUX_CONTAINER=tab CMUX_WORKSPACE_ID='' \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_ensure /tmp/proj' "$ROOT" )
  [ "$out" = "88888888-8888-8888-8888-888888888888" ] \
    || fail "tab-mode container_ensure should create and echo the shared per-home workspace, got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--name'$'\x1f'"$shared"$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--focus'$'\x1f''false' \
    "container_ensure did not create the shared workspace with the scoped title, cwd, and --focus false"
  pass "fm_backend_cmux_container_ensure: tab mode outside cmux creates the shared per-home workspace unfocused"
}

# --- focus context capture and restore (tab mode, cmux 0.64.18+ regression) --

test_focus_context_tolerates_empty_or_unavailable_identify() {
  local dir fb out
  dir="$TMP_ROOT/focus-empty"; mkdir -p "$dir/responses"
  # 1: identify -> no focused surface
  printf '{"focused":{"window_ref":"window:1"}}' > "$dir/responses/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_focus_context' "$ROOT" )
  [ -z "$out" ] || fail "focus_context should be empty when cmux reports no focused surface, got '$out'"
  pass "fm_backend_cmux_focus_context: empty (skip-restoration signal) when no surface is focused"
}

test_focus_context_captures_full_context() {
  local dir fb out
  dir="$TMP_ROOT/focus-full"; mkdir -p "$dir/responses"
  printf '{"focused":{"window_ref":"window:1","workspace_ref":"workspace:5","pane_ref":"pane:2","surface_ref":"surface:9"}}' > "$dir/responses/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_focus_context' "$ROOT" )
  [ "$out" = "window:1 workspace:5 pane:2 surface:9" ] \
    || fail "focus_context should capture window/workspace/pane/surface refs, got '$out'"
  pass "fm_backend_cmux_focus_context: captures the full focused window/workspace/pane/surface context"
}

test_restore_focus_order_preserving_sequence() {
  local dir fb
  dir="$TMP_ROOT/restore-seq"; mkdir -p "$dir/responses"
  # 1: focus-window, 2: select-workspace, 3: focus-pane,
  # 4: list-pane-surfaces --id-format both (surface_index), 5: reorder-surface
  printf '{"surfaces":[{"id":"aaaa","ref":"surface:9","index":3,"title":"x"},{"id":"bbbb","ref":"surface:10","index":4,"title":"y"}]}' > "$dir/responses/4.out"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_restore_focus "window:1 workspace:5 pane:2 surface:9"' "$ROOT" \
    || fail "restore_focus should succeed when every step lands"
  assert_contains "$(cat "$dir/log")" $'\x1f''select-workspace'$'\x1f''--workspace'$'\x1f''workspace:5'$'\x1f''--window'$'\x1f''window:1' \
    "restore_focus did not reactivate the prior workspace in its window"
  assert_contains "$(cat "$dir/log")" $'\x1f''reorder-surface'$'\x1f''--surface'$'\x1f''surface:9'$'\x1f''--workspace'$'\x1f''workspace:5'$'\x1f''--window'$'\x1f''window:1'$'\x1f''--index'$'\x1f''3'$'\x1f''--focus'$'\x1f''true' \
    "restore_focus did not refocus the prior surface at its OWN current index (order-preserving)"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''move-surface' \
    "restore_focus must never use destination-less move-surface (it reorders/appends the tab)"
  cmux_assert_call_order "$dir/log" $'\x1f''select-workspace'$'\x1f' $'\x1f''reorder-surface'$'\x1f' \
    "the workspace must be reactivated before the tab is refocused"
  pass "fm_backend_cmux_restore_focus: focus-window + select-workspace + focus-pane + order-preserving reorder-surface --focus true"
}

test_restore_focus_fails_when_prior_surface_vanished() {
  local dir fb status
  dir="$TMP_ROOT/restore-gone"; mkdir -p "$dir/responses"
  # 1: select-workspace ok (no window ref), 2: list-pane-surfaces -> prior surface missing
  printf '{"surfaces":[{"id":"bbbb","ref":"surface:10","index":0,"title":"y"}]}' > "$dir/responses/2.out"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_restore_focus "- workspace:5 - surface:9"' "$ROOT" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "restore_focus must fail explicitly when the prior surface is no longer present"
  pass "fm_backend_cmux_restore_focus: explicit failure when the previously focused surface has vanished"
}

# --- create_task tab arm: transactional focused create + restore -------------

test_create_task_tab_full_flow() {
  local dir fb out title c="aaaaaaaa-0000-0000-0000-000000000000" sp="bbbbbbbb-1111-1111-1111-111111111111" sn="cccccccc-2222-2222-2222-222222222222"
  dir="$TMP_ROOT/tab-create"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-tabnew)
  # 1: workspace list (app-global dup scan), 2: list-pane-surfaces (dup miss)
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "$sp" "zsh" 0
  # 3: identify (full focused context)
  printf '{"focused":{"window_ref":"window:1","workspace_ref":"workspace:5","pane_ref":"pane:2","surface_ref":"surface:9"}}' > "$dir/responses/3.out"
  # 4: list-pane-surfaces (before-ids), 5: new-surface ack, 6: list-pane-surfaces (after-ids)
  cmux_surfaces_response "$dir" 4 "$sp" "zsh" 0
  printf 'OK surface:10 pane:2 workspace:5\n' > "$dir/responses/5.out"
  cmux_surfaces_response "$dir" 6 "$sp" "zsh" 0 "$sn" "Terminal" 1
  # restore: 7 focus-window, 8 select-workspace, 9 focus-pane (defaults ok),
  # 10: list-pane-surfaces --id-format both (surface_index of surface:9)
  printf '{"surfaces":[{"id":"%s","ref":"surface:9","index":0,"title":"zsh"},{"id":"%s","ref":"surface:10","index":1,"title":"Terminal"}]}' "$sp" "$sn" > "$dir/responses/10.out"
  # 11: reorder-surface, 12: rename-tab (defaults ok)
  # wait_ready (ATTEMPTS=1): 13 list-panes, 14 send-key, 15 list-panes, 16 read-screen (default empty)
  cmux_panes_response "$dir" 13 "$sn"
  cmux_panes_response "$dir" 15 "$sn"
  # cd setup: 17 list-panes, 18 send, 19 list-panes, 20 send-key (defaults ok)
  cmux_panes_response "$dir" 17 "$sn"
  cmux_panes_response "$dir" 19 "$sn"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_CMUX_READY_ATTEMPTS=1 FM_CMUX_READY_INTERVAL=0 FM_CMUX_READY_SETTLE=0 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task "'"$c"'" fm-tabnew /tmp/proj' "$ROOT" )
  [ "$out" = "$c $sn" ] || fail "tab-mode create_task should echo '<container_ws> <new_surface>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-surface'$'\x1f''--type'$'\x1f''terminal'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--focus'$'\x1f''true' \
    "tab creation must be focused at birth (cmux 0.64.18+ unfocused surfaces can stay renderer-unrealized)"
  cmux_assert_call_order "$dir/log" $'\x1f''identify'$'\x1f' $'\x1f''new-surface'$'\x1f' \
    "the focused context must be captured BEFORE the tab is created"
  assert_contains "$(cat "$dir/log")" $'\x1f''reorder-surface'$'\x1f''--surface'$'\x1f''surface:9' \
    "the prior surface's focus was not restored"
  assert_contains "$(cat "$dir/log")" $'\x1f''rename-tab'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sn"$'\x1f'"$title" \
    "the new tab was not renamed to the scoped task title"
  assert_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sn"$'\x1f''--'$'\x1f''cd "/tmp/proj"' \
    "the new tab was not moved to the task's project directory"
  cmux_assert_call_order "$dir/log" $'\x1f''rename-tab'$'\x1f' $'\x1f''send'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sn"$'\x1f''--'$'\x1f' \
    "the rename must land before the cwd setup"
  pass "fm_backend_cmux_create_task: tab mode creates focused, restores the full prior context, renames, wakes, and sets the cwd"
}

test_create_task_tab_refuses_duplicate_title() {
  local dir fb out status c="aaaaaaaa-0000-0000-0000-000000000000"
  dir="$TMP_ROOT/tab-dup"; mkdir -p "$dir/responses"
  # 1: workspace list, 2: list-pane-surfaces -> a surface already carries the scoped title
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111" "$(cmux_expected_scoped_title fm-tabdup)" 0
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task "'"$c"'" fm-tabdup /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "tab-mode create_task should refuse an existing scoped tab title"
  assert_contains "$out" "already exists" "the duplicate-tab refusal should name the conflict"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-surface' \
    "no tab may be created when the scoped title already exists"
  pass "fm_backend_cmux_create_task: tab mode refuses a duplicate scoped tab title app-globally"
}

test_create_task_tab_restore_failure_cleans_up_only_new_surface() {
  local dir fb status c="aaaaaaaa-0000-0000-0000-000000000000" sp="bbbbbbbb-1111-1111-1111-111111111111" sn="cccccccc-2222-2222-2222-222222222222"
  dir="$TMP_ROOT/tab-restore-fail"; mkdir -p "$dir/responses"
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "$sp" "zsh" 0
  # 3: identify with no window ref, so restore has no focus-window call
  printf '{"focused":{"workspace_ref":"workspace:5","pane_ref":"pane:2","surface_ref":"surface:9"}}' > "$dir/responses/3.out"
  cmux_surfaces_response "$dir" 4 "$sp" "zsh" 0
  printf 'OK surface:10 pane:2 workspace:5\n' > "$dir/responses/5.out"
  cmux_surfaces_response "$dir" 6 "$sp" "zsh" 0 "$sn" "Terminal" 1
  # 7: select-workspace FAILS -> transactional cleanup closes only the new surface
  printf '1\n' > "$dir/responses/7.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task "'"$c"'" fm-tabtx /tmp/proj' "$ROOT" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when the focus restoration fails"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sn" \
    "the failed create must close exactly the new surface"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sp" \
    "a pre-existing tab must never be touched by the cleanup"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''rename-tab' \
    "no rename may run after a failed restoration"
  pass "fm_backend_cmux_create_task: a failed focus restoration closes ONLY the new surface (transactional)"
}

test_create_task_tab_rename_failure_cleans_up() {
  local dir fb status c="aaaaaaaa-0000-0000-0000-000000000000" sp="bbbbbbbb-1111-1111-1111-111111111111" sn="cccccccc-2222-2222-2222-222222222222"
  dir="$TMP_ROOT/tab-rename-fail"; mkdir -p "$dir/responses"
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "$sp" "zsh" 0
  # 3: identify empty -> restoration skipped (supported no-op)
  cmux_surfaces_response "$dir" 4 "$sp" "zsh" 0
  printf 'OK surface:10 pane:2 workspace:5\n' > "$dir/responses/5.out"
  cmux_surfaces_response "$dir" 6 "$sp" "zsh" 0 "$sn" "Terminal" 1
  # 7: rename-tab FAILS -> cleanup closes only the new surface
  printf '1\n' > "$dir/responses/7.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task "'"$c"'" fm-tabrn /tmp/proj' "$ROOT" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when the scoped-title rename fails (every later op verifies by that title)"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sn" \
    "the failed rename must close exactly the new surface"
  pass "fm_backend_cmux_create_task: a failed rename is fatal and closes ONLY the new surface"
}

test_create_task_tab_unresolvable_uuid_touches_nothing() {
  local dir fb status c="aaaaaaaa-0000-0000-0000-000000000000" sp="bbbbbbbb-1111-1111-1111-111111111111"
  dir="$TMP_ROOT/tab-no-uuid"; mkdir -p "$dir/responses"
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "$sp" "zsh" 0
  printf '{"focused":{"workspace_ref":"workspace:5","surface_ref":"surface:9"}}' > "$dir/responses/3.out"
  cmux_surfaces_response "$dir" 4 "$sp" "zsh" 0
  printf 'OK surface:10 pane:2 workspace:5\n' > "$dir/responses/5.out"
  # 6: after-ids identical to before -> new UUID unresolvable
  cmux_surfaces_response "$dir" 6 "$sp" "zsh" 0
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task "'"$c"'" fm-tabnx /tmp/proj' "$ROOT" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when the new surface UUID cannot be resolved"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "with no resolvable UUID, no close may be attempted (it could hit a pre-existing tab)"
  pass "fm_backend_cmux_create_task: an unresolvable new-surface UUID fails without touching any surface"
}

# --- target_ready: tab arm (surface-title lookup and recovery) ----------------

test_target_ready_tab_finds_surface_by_title() {
  local dir fb c="aaaaaaaa-0000-0000-0000-000000000000" sr="dddddddd-3333-3333-3333-333333333333"
  dir="$TMP_ROOT/ready-tab"; mkdir -p "$dir/responses"
  # 1: workspace list -> container title; 2: list-pane-surfaces -> the task tab
  # under its scoped title (stored surface id stale); 3: send-key
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "$sr" "$(cmux_expected_scoped_title fm-tabt)" 0
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "'"$c"':bbbbbbbb-1111-1111-1111-111111111111" Enter fm-tabt' "$ROOT" \
    || fail "send_key should succeed after the tab arm re-resolves the surface by title"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$sr"$'\x1f''enter' \
    "ops must route to the surface carrying the scoped tab title, not the stale stored id"
  pass "fm_backend_cmux_target_ready: tab arm re-resolves a stale surface id by scoped tab title inside the container"
}

test_target_ready_tab_global_reresolve_after_relaunch() {
  local dir fb w2="eeeeeeee-4444-4444-4444-444444444444" s2="ffffffff-5555-5555-5555-555555555555"
  dir="$TMP_ROOT/ready-tab-global"; mkdir -p "$dir/responses"
  # Stored workspace id no longer exists (app relaunch): 1: workspace list
  # (title lookup miss), 2: workspace list (workspace-by-label miss), 3:
  # workspace list (global scan), 4: list-pane-surfaces w2 -> the tab, 5: send-key
  cmux_workspace_list_response "$dir" 1 "$w2" "captains-own"
  cmux_workspace_list_response "$dir" 2 "$w2" "captains-own"
  cmux_workspace_list_response "$dir" 3 "$w2" "captains-own"
  cmux_surfaces_response "$dir" 4 "$s2" "$(cmux_expected_scoped_title fm-tabg)" 0
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "00000000-dead-dead-dead-000000000000:bbbbbbbb-1111-1111-1111-111111111111" Enter fm-tabg' "$ROOT" \
    || fail "send_key should succeed after the global tab re-resolve"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f'"$w2"$'\x1f''--surface'$'\x1f'"$s2"$'\x1f''enter' \
    "a relaunch-stale tab target must re-resolve app-globally by scoped surface title"
  pass "fm_backend_cmux_target_ready: tab arm re-resolves a relaunch-stale workspace id app-globally by surface title"
}

test_target_ready_tab_mismatch_still_rejected() {
  local dir fb status c="aaaaaaaa-0000-0000-0000-000000000000"
  dir="$TMP_ROOT/ready-tab-mismatch"; mkdir -p "$dir/responses"
  # The workspace is live but neither it nor any surface anywhere carries the
  # expected scoped title: 1: workspace list, 2: list-pane-surfaces (miss),
  # 3: workspace list (global scan), 4: list-pane-surfaces (miss again)
  cmux_workspace_list_response "$dir" 1 "$c" "captains-own"
  cmux_surfaces_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111" "unrelated" 0
  cmux_workspace_list_response "$dir" 3 "$c" "captains-own"
  cmux_surfaces_response "$dir" 4 "bbbbbbbb-1111-1111-1111-111111111111" "unrelated" 0
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "'"$c"':bbbbbbbb-1111-1111-1111-111111111111" Enter fm-nomatch' "$ROOT" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "an op whose expected label matches no workspace or surface title must fail"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f' \
    "no key may be sent to an endpoint that failed label verification"
  pass "fm_backend_cmux_target_ready: label verification still rejects a target matching no workspace OR surface title"
}

# --- wait_ready: lazy-terminal wake -------------------------------------------

test_wait_ready_wakes_and_settles_on_stable_screen() {
  local dir fb c="aaaaaaaa-0000-0000-0000-000000000000" s="bbbbbbbb-1111-1111-1111-111111111111"
  dir="$TMP_ROOT/wait-ready"; mkdir -p "$dir/responses"
  # 1: list-panes (send_key), 2: send-key enter (the wake), 3: list-panes
  # (capture), 4: read-screen (banner), 5: list-panes, 6: read-screen (same
  # banner -> stable -> settle and return)
  cmux_panes_response "$dir" 1 "$s"
  cmux_panes_response "$dir" 3 "$s"
  cmux_read_screen_response "$dir" 4 $'Last login: today\n❯'
  cmux_panes_response "$dir" 5 "$s"
  cmux_read_screen_response "$dir" 6 $'Last login: today\n❯'
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    FM_CMUX_READY_ATTEMPTS=5 FM_CMUX_READY_INTERVAL=0 FM_CMUX_READY_SETTLE=0 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_wait_ready "'"$c:$s"'"' "$ROOT" \
    || fail "wait_ready should return 0 once the screen is stable"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f'"$c"$'\x1f''--surface'$'\x1f'"$s"$'\x1f''enter' \
    "wait_ready did not send the harmless wake Enter (lazy terminal start)"
  [ "$(grep -c $'\x1f''read-screen'$'\x1f' "$dir/log")" -ge 2 ] \
    || fail "wait_ready should poll the screen until two consecutive reads agree"
  pass "fm_backend_cmux_wait_ready: wakes the lazy terminal with Enter and polls until the screen is stable"
}

# --- busy_state: forward-compatible agent_status probe ------------------------

test_busy_state_maps_agent_status_when_task_owned() {
  local dir fb out title c="aaaaaaaa-0000-0000-0000-000000000000"
  dir="$TMP_ROOT/busy-map"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-busy)
  printf '{"workspaces":[{"id":"%s","title":"%s","agent_status":"working"}]}' "$c" "$title" > "$dir/responses/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_busy_state "'"$c"':bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = busy ] || fail "a future agent_status=working on a task-owned workspace should map to busy, got '$out'"
  pass "fm_backend_cmux_busy_state: forward-compat probe maps a future agent_status=working to busy"
}

test_busy_state_unknown_without_field() {
  local dir fb out title c="aaaaaaaa-0000-0000-0000-000000000000"
  dir="$TMP_ROOT/busy-none"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-busy2)
  cmux_workspace_list_response "$dir" 1 "$c" "$title"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_busy_state "'"$c"':bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = unknown ] || fail "with no agent_status field (every verified cmux) busy_state must report unknown, got '$out'"
  pass "fm_backend_cmux_busy_state: unknown on every verified cmux (no agent_status field) - callers fall back to pane-regex"
}

test_busy_state_unknown_for_tab_container() {
  local dir fb out c="aaaaaaaa-0000-0000-0000-000000000000"
  dir="$TMP_ROOT/busy-tab"; mkdir -p "$dir/responses"
  # Even a future agent_status on a NON-task-owned workspace (tab mode's
  # container) must not be attributed to the task tab.
  printf '{"workspaces":[{"id":"%s","title":"captains-own","agent_status":"working"}]}' "$c" > "$dir/responses/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_busy_state "'"$c"':bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = unknown ] || fail "a container workspace's agent_status must never be attributed to a task tab, got '$out'"
  pass "fm_backend_cmux_busy_state: a tab-mode container's workspace-level agent_status is never attributed to the task"
}

# --- list_live: tab arm --------------------------------------------------------

test_list_live_includes_tab_mode_tasks() {
  local dir fb out title tab_title
  dir="$TMP_ROOT/list-live-tab"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-task1)
  tab_title=$(cmux_expected_scoped_title fm-tab2)
  # 1: workspace list -> one task-owned workspace, one container, one unrelated
  cmux_workspace_list_response "$dir" 1 \
    "aaaaaaaa-0000-0000-0000-000000000000" "$title" \
    "dddddddd-8888-8888-8888-888888888888" "captains-own" \
    "cccccccc-9999-9999-9999-999999999999" "zsh"
  # 2: list-panes for the task-owned workspace (workspace arm)
  cmux_panes_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111"
  # Tab arm scans EVERY workspace: 3: the task-owned workspace's own surface
  # (never scoped-titled, so not double-reported), 4: the container -> one
  # scoped task tab among others, 5: the unrelated workspace -> nothing scoped
  cmux_surfaces_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111" "zsh" 0
  cmux_surfaces_response "$dir" 4 \
    "11111111-aaaa-aaaa-aaaa-111111111111" "$tab_title" 0 \
    "22222222-bbbb-bbbb-bbbb-222222222222" "zsh" 1
  cmux_surfaces_response "$dir" 5 "33333333-cccc-cccc-cccc-333333333333" "vim" 0
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_list_live' "$ROOT" )
  [ "$out" = $'aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111\tfm-task1\ndddddddd-8888-8888-8888-888888888888:11111111-aaaa-aaaa-aaaa-111111111111\tfm-tab2' ] \
    || fail "list_live should report both the task workspace and the task tab with plain fm-<id> labels, got '$out'"
  pass "fm_backend_cmux_list_live: covers both container shapes - task workspaces and scoped task tabs"
}

# --- fm-spawn.sh: --secondmate refuses backend=cmux --------------------------

test_secondmate_spawn_refuses_cmux_backend() {
  local dir state data config projects out status
  dir="$TMP_ROOT/secondmate-refuse"; state="$dir/state"; data="$dir/data"; config="$dir/config"; projects="$dir/projects"
  mkdir -p "$state" "$data" "$config" "$projects"
  out=$( FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" FM_PROJECTS_OVERRIDE="$projects" \
    "$ROOT/bin/fm-spawn.sh" sm-cmux-test --secondmate --backend cmux 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh should refuse a --secondmate spawn with --backend cmux"
  assert_contains "$out" "does not support --secondmate" "fm-spawn.sh did not report the cmux secondmate refusal"
  pass "fm-spawn.sh: refuses backend=cmux for --secondmate spawns (mirrors Orca's refusal; no secondmate launch design exists yet)"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_version
test_version_check_accepts_newer_version
test_version_check_refuses_old_version
test_version_check_refuses_missing_cmux
test_password_reads_from_config_file
test_password_preserves_config_file_whitespace
test_password_respects_config_override
test_password_empty_when_config_absent
test_cli_exports_password_only_when_configured
test_parse_target
test_normalize_key
test_scoped_title_uses_primary_home_label
test_scoped_title_uses_secondmate_home_label
test_scoped_title_changes_with_root_path
test_dispatch_routes_cmux_backend
test_dispatch_busy_state_unknown_for_cmux
test_dispatch_composer_state_routes_cmux
test_ping_state_ok
test_ping_state_denied
test_ping_state_unauth
test_ping_state_invalid_password
test_ping_state_down
test_ensure_running_returns_immediately_when_already_ok
test_ensure_running_fails_fast_on_denied_without_launching
test_ensure_running_fails_fast_on_unauth_without_launching
test_create_task_refuses_duplicate_label
test_create_task_creates_and_parses_ids
test_target_ready_fails_when_target_absent
test_target_ready_checks_expected_label
test_target_ready_rejects_label_mismatch
test_capture_trims_locally
test_capture_fails_when_read_screen_fails_empty
test_capture_fails_when_target_not_ready
test_send_key_normalizes_and_targets
test_send_key_recovers_stale_target_by_label
test_send_literal_uses_separator_for_option_shaped_text
test_current_path_falls_back_to_marker_probe
test_current_path_tier1_tty_ps_lsof
test_current_path_tier2_screen_block_header
test_current_path_tier3_workspace_dir_only_when_task_owned
test_current_path_tier3_skipped_for_tab_container
test_composer_state_bare_prompt_is_empty
test_composer_state_ghost_placeholder_is_empty
test_composer_state_real_text_is_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_unknown_on_capture_failure
test_composer_state_unknown_when_no_composer_row_found
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_text_submit_send_failed_when_target_absent
test_window_of_workspace_finds_window_and_count
test_window_of_workspace_empty_when_not_found
test_kill_closes_workspace_directly_when_not_last
test_kill_adds_sibling_when_last_in_window
test_kill_is_best_effort_when_close_workspace_fails
test_kill_recovers_stale_target_by_label
test_kill_tab_closes_only_surface
test_kill_tab_last_surface_adds_sibling_surface
test_kill_tab_last_surface_in_shared_container_closes_container
test_kill_tab_with_label_in_task_titled_container_closes_only_surface
test_list_live_filters_by_title_prefix
test_container_mode_resolution
test_container_ensure_workspace_mode_echoes_token
test_container_ensure_tab_mode_uses_own_workspace
test_container_ensure_tab_mode_finds_shared_workspace
test_container_ensure_tab_mode_creates_shared_workspace
test_focus_context_tolerates_empty_or_unavailable_identify
test_focus_context_captures_full_context
test_restore_focus_order_preserving_sequence
test_restore_focus_fails_when_prior_surface_vanished
test_create_task_tab_full_flow
test_create_task_tab_refuses_duplicate_title
test_create_task_tab_restore_failure_cleans_up_only_new_surface
test_create_task_tab_rename_failure_cleans_up
test_create_task_tab_unresolvable_uuid_touches_nothing
test_target_ready_tab_finds_surface_by_title
test_target_ready_tab_global_reresolve_after_relaunch
test_target_ready_tab_mismatch_still_rejected
test_wait_ready_wakes_and_settles_on_stable_screen
test_busy_state_maps_agent_status_when_task_owned
test_busy_state_unknown_without_field
test_busy_state_unknown_for_tab_container
test_list_live_includes_tab_mode_tasks
test_secondmate_spawn_refuses_cmux_backend
