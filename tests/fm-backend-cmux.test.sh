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
# shellcheck source=tests/cmux-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/cmux-fake-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-cmux-tests)

# A run from inside cmux (or a shell that inherited its markers) must not leak
# the operator's own workspace or container choice into these fakes.
unset CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID FM_CMUX_CONTAINER

# make_cmux_fakebin: a `cmux` stub that logs every invocation (one line,
# unit-separated args, to $FM_CMUX_LOG) and returns the canned response for
# that call read from $FM_CMUX_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...), mirroring
# tests/fm-backend-zellij.test.sh's make_zellij_fakebin. A missing response
# file means "succeed with empty stdout" (send/send-key/close-* print
# little on success on the real CLI; create_task tests supply
# new-workspace's printed `OK workspace:<n>` ref explicitly). `version` and `ping` are
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

# cmux_ref_panes_response: list-panes for a workspace named by ref, which
# carries the workspace uuid alongside the pane's surfaces.
cmux_ref_panes_response() {  # <dir> <n> <workspace_id> <surface_id>
  printf '{"workspace_id":"%s","panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}' "$3" "$4" "$4" > "$1/responses/$2.out"
}

cmux_panes_empty_response() {  # <dir> <n>
  printf '{"panes":[]}' > "$1/responses/$2.out"
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
  # shellcheck source=/dev/null
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
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯'
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
    FM_CMUX_FAKE_PING="Error: Socket not found at /home/x/.local/state/cmux/cmux.sock" \
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
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
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
  # 2: new-workspace prints the created ref
  printf 'OK workspace:31\n' > "$dir/responses/2.out"
  # 3: list-panes --workspace workspace:31 -> workspace uuid + default surface
  cmux_ref_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111" "cccccccc-2222-2222-2222-222222222222"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "bbbbbbbb-1111-1111-1111-111111111111 cccccccc-2222-2222-2222-222222222222" ] \
    || fail "create_task should echo '<workspace_id> <surface_id>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--name'$'\x1f'"$title"$'\x1f''--cwd'$'\x1f''/tmp/proj' \
    "create_task did not call new-workspace with the right name/cwd"
  assert_contains "$(cat "$dir/log")" $'\x1f''--focus'$'\x1f''false' \
    "create_task did not pass --focus false"
  assert_contains "$(cat "$dir/log")" $'\x1f''list-panes'$'\x1f''--workspace'$'\x1f''workspace:31' \
    "create_task did not resolve the new workspace from its printed ref"
  [ "$(grep -c $'\x1f''workspace'$'\x1f''list' "$dir/log")" = 1 ] \
    || fail "create_task looked the new workspace up by title after creating it: $(cat "$dir/log")"
  pass "fm_backend_cmux_create_task: resolves the new workspace and its surface from the printed ref, never a title lookup"
}

# The printed ref can lag right after creation; the ref lookup is retried
# within its bound.
test_create_task_retries_printed_ref_lookup_after_creation() {
  local dir fb out
  dir="$TMP_ROOT/create-task-retry"; mkdir -p "$dir/responses"
  printf '{"workspaces":[]}' > "$dir/responses/1.out"
  printf 'OK workspace:33\n' > "$dir/responses/2.out"
  # 3: first ref lookup -> not found yet
  printf '1' > "$dir/responses/3.exit"
  # 4: retried ref lookup -> found
  cmux_ref_panes_response "$dir" 4 "bbbbbbbb-1111-1111-1111-111111111111" "cccccccc-2222-2222-2222-222222222222"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-retrytask /tmp/proj' "$ROOT" )
  [ "$out" = "bbbbbbbb-1111-1111-1111-111111111111 cccccccc-2222-2222-2222-222222222222" ] \
    || fail "create_task should retry a failed post-create ref lookup, got '$out'"
  pass "fm_backend_cmux_create_task: retries the printed ref lookup right after creation"
}

# Printed ref never resolves: the spawn fails after a best-effort close of the
# printed ref, never touching anything by title. <close-exit> is the close's
# exit code; the leftover title is named only when that close does not report
# success.
cmux_run_create_task_ref_never_resolves() {  # <dir> <close-exit> -> sets out/status/title
  local dir=$1 fb n
  mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-lost)
  printf '{"workspaces":[]}' > "$dir/responses/1.out"
  printf 'OK workspace:41\n' > "$dir/responses/2.out"
  n=3
  while [ "$n" -le 17 ]; do
    printf '1' > "$dir/responses/$n.exit"
    n=$((n + 1))
  done
  # 18: close-workspace --workspace workspace:41
  printf '%s' "$2" > "$dir/responses/18.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-lost /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should fail when the printed ref never resolves"
  assert_contains "$out" "could not resolve a cmux workspace id" "create_task did not report the resolution failure"
  cmux_assert_call_order "$dir/log" $'\x1f''new-workspace' \
    $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''workspace:41' \
    "create_task did not close the unresolved workspace by its printed ref"
  [ "$(wc -l < "$dir/log" | tr -d ' ')" = 18 ] \
    || fail "create_task made unexpected calls after the ref close: $(cat "$dir/log")"
}

test_create_task_closes_unresolved_workspace_by_printed_ref() {
  local out status title
  cmux_run_create_task_ref_never_resolves "$TMP_ROOT/create-task-unresolved" 0
  assert_not_contains "$out" "by hand" \
    "create_task asked for a manual close although the ref close reported success"
  pass "fm_backend_cmux_create_task: an unresolved printed ref is closed by that ref, with no manual-cleanup note"
}

test_create_task_names_leftover_title_when_ref_close_fails() {
  local out status title
  cmux_run_create_task_ref_never_resolves "$TMP_ROOT/create-task-unresolved-close-fails" 1
  assert_contains "$out" "close the leftover cmux workspace '$title' by hand" \
    "create_task did not name the leftover workspace title after the ref close failed"
  pass "fm_backend_cmux_create_task: when the printed-ref close fails, the error names the leftover workspace title"
}

# No ref printed: the spawn fails at once without any lookup or close, and
# names the leftover title.
test_create_task_names_leftover_title_without_ref() {
  local dir fb out status title
  dir="$TMP_ROOT/create-task-no-ref-lost"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-gone)
  printf '{"workspaces":[]}' > "$dir/responses/1.out"
  # 2: new-workspace prints no ref; 3: a title match that must not be used
  cmux_workspace_list_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111" "$title"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-gone /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should fail when new-workspace prints no ref"
  assert_contains "$out" "close the leftover cmux workspace '$title' by hand" \
    "create_task did not name the leftover workspace title"
  [ "$(wc -l < "$dir/log" | tr -d ' ')" = 2 ] \
    || fail "create_task looked up or closed a workspace after creation without a printed ref: $(cat "$dir/log")"
  pass "fm_backend_cmux_create_task: without a printed ref, fails at once, closes nothing, and names the leftover title"
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

test_send_text_line_clears_partial_input_when_enter_fails() {
  local dir fb status log
  dir="$TMP_ROOT/sendline-enter-failure"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  printf '1\n' > "$dir/responses/4.exit"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")

  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_line "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "export TRACEPARENT=carrier"' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should report a failed Enter"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''export TRACEPARENT=carrier' \
    "send_text_line did not send the trace export before the simulated Enter failure"
  assert_contains "$log" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''ctrl-c' \
    "send_text_line did not clear the partial input after Enter failed"
  pass "fm_backend_cmux_send_text_line: clears partial input when Enter fails"
}

test_send_text_line_reports_unsafe_input_when_cleanup_fails() {
  local dir fb status log
  dir="$TMP_ROOT/sendline-cleanup-failure"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  printf '1\n' > "$dir/responses/4.exit"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  printf '1\n' > "$dir/responses/6.exit"
  fb=$(make_cmux_fakebin "$dir")

  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_line "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "export TRACEPARENT=carrier"' "$ROOT"
  status=$?
  expect_code 2 "$status" "send_text_line should distinguish uncleared input"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''ctrl-c' \
    "send_text_line did not attempt cleanup after Enter failed"
  pass "fm_backend_cmux_send_text_line: reports unsafe input when cleanup also fails"
}

# --- current_path: pwd-marker-probe (zellij-shape) ---------------------------

# --- composer_state: structural border-row classification (adapted from herdr) ----

test_composer_state_bare_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via capture)
  # 2: read-screen --scrollback --lines <N> --json (composer capture)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_cmux_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_borderless_claude_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'────────────────────────\n❯\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless Claude '❯' row bounded by horizontal rules should read empty, got '$out'"
  pass "fm_backend_cmux_composer_state: a borderless Claude '❯' composer row reads empty"
}

test_composer_state_borderless_claude_prompt_outranks_stale_bordered_row() {
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude-after-bordered"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'│ ❯ stale input │\n────────────────────────\n❯\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a current borderless Claude row should outrank stale bordered scrollback, got '$out'"
  pass "fm_backend_cmux_composer_state: a borderless Claude row outranks stale bordered scrollback"
}

test_composer_state_borderless_claude_nbsp_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude-nbsp"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'────────────────────────\n❯\302\240\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( LC_ALL=C PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless Claude '❯'+NBSP row bounded by horizontal rules should read empty under LC_ALL=C, got '$out'"
  pass "fm_backend_cmux_composer_state: a borderless Claude '❯'+NBSP composer row reads empty under LC_ALL=C"
}

test_composer_state_borderless_claude_text_is_unknown_plain() {
  # Capability degradation (the consolidated classifier's styled=0 rule): on
  # cmux's plain-text capture, text after a bare agent glyph is unreadable -
  # it may be the harness's own idle suggestion (claude's rotating dim hint,
  # codex's "Use /skills ..."), which a plain read cannot tell from typed
  # input. The verdict is `unknown` (defer, loud refusal at fm-send), never a
  # false `pending` that would misreport an idle pane as holding unsent text.
  # The same bytes on a styled backend (tmux/herdr/zellij) classify pending
  # when bright and empty when ghost - pinned in tests/fm-composer-lib.test.sh.
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude-text"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'────────────────────────\n❯ retain this message\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = unknown ] || fail "plain-capture text after a bare glyph must degrade to unknown, got '$out'"
  pass "fm_backend_cmux_composer_state: plain-capture text after a bare glyph degrades to unknown (never false pending)"
}

test_composer_state_ghost_placeholder_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-ghost"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ Type a message...    │\n  ╰──────── Composer ──────╯'
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
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
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
  cmux_read_screen_response "$dir" 2 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send'
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
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯'
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
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
  cmux_read_screen_response "$dir" 10 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
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
  cmux_read_screen_response "$dir" 6 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send'
  # 7: list-panes (target_ready via send_key Enter #2)
  # 8: send-key enter (#2) - actually submits
  # 9: list-panes (target_ready via composer_state capture)
  # 10: composer now reads empty
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 10 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯'
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

# --- kill: close the task workspace, adding a sibling when it is the last one -

# The common case: the task workspace shares its window with at least one other
# workspace, so cmux closes it directly with no sibling dance.
test_close_workspace_closes_directly_when_not_last() {
  local dir fb
  dir="$TMP_ROOT/kill-workspace"; mkdir -p "$dir/responses"
  # 1: list-windows -> the owning window has 2 workspaces (target is NOT last)
  cmux_windows_response "$dir" 1 "eeeeeeee-0000-0000-0000-000000000000" 2
  # 2: workspace list --window eeeeeeee -> contains the target
  cmux_workspace_list_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" "the-task" "ffffffff-0000-0000-0000-000000000000" "other"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_close_workspace "aaaaaaaa-0000-0000-0000-000000000000"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "close_workspace did not close the task workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-workspace' \
    "close_workspace should not add a sibling workspace when the target is not the last one in its window"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "close_workspace should close the whole workspace directly"
  pass "fm_backend_cmux_close_workspace: closes the task workspace directly when it is not the last in its window"
}

# The selected-workspace teardown bug: cmux refuses to close the only workspace
# in a window (returns OK but no-ops), so kill first creates a throwaway sibling
# and only then closes the target - which now succeeds.
test_close_workspace_adds_sibling_when_last_in_window() {
  local dir fb
  dir="$TMP_ROOT/kill-last-in-window"; mkdir -p "$dir/responses"
  cmux_windows_response "$dir" 1 "eeeeeeee-0000-0000-0000-000000000000" 2
  # 2: workspace list --window eeeeeeee -> contains the target
  cmux_workspace_list_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" "the-task"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_close_workspace "aaaaaaaa-0000-0000-0000-000000000000"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--window'$'\x1f''eeeeeeee-0000-0000-0000-000000000000'$'\x1f''--focus'$'\x1f''false' \
    "close_workspace did not add a throwaway sibling in the target's own window before closing the last workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--name' \
    "the throwaway sibling must stay an unnamed default workspace, never an fm- task title"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "close_workspace did not close the target workspace after adding the sibling"
  cmux_assert_call_order "$dir/log" $'\x1f''new-workspace'$'\x1f''--window' $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "close_workspace must add the sibling BEFORE closing the last workspace, or the close still no-ops"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "close_workspace should not call close-surface"
  pass "fm_backend_cmux_close_workspace: adds a throwaway sibling then closes the target when it is the last workspace in its window"
}

test_close_workspace_is_best_effort_when_close_fails() {
  local dir fb
  dir="$TMP_ROOT/kill-workspace-fail"; mkdir -p "$dir/responses"
  # 1: list-windows (not last), 2: workspace list --window, 3: close-workspace fails
  cmux_windows_response "$dir" 1 "eeeeeeee-0000-0000-0000-000000000000" 2
  cmux_workspace_list_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" "the-task" "ffffffff-0000-0000-0000-000000000000" "other"
  printf '1\n' > "$dir/responses/3.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_close_workspace "aaaaaaaa-0000-0000-0000-000000000000"' "$ROOT"
  expect_code 0 $? "close_workspace must stay best-effort (never fail) even when close-workspace fails"
  assert_contains "$(cat "$dir/log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "close_workspace should still attempt close-workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''close-surface' \
    "close_workspace should not call close-surface"
  pass "fm_backend_cmux_close_workspace: never fails even when close-workspace fails"
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
  # 4 workspace list: kill reads the refreshed workspace's title to pick the
  # shape (task-owned -> close the whole workspace).
  cmux_workspace_list_response "$dir" 4 "cccccccc-2222-2222-2222-222222222222" "$title"
  # window_of_workspace on the REFRESHED id: 5 list-windows (not last), 6 workspace list --window.
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

# --- stateful fake: both container modes (tests/cmux-fake-lib.sh) -----------

# cmux_state_case <name>: a fresh state dir plus fakebin; sets SDIR, SFB, SLOG.
cmux_state_case() {
  local dir="$TMP_ROOT/state-$1"
  mkdir -p "$dir"
  SDIR="$dir/state"
  SLOG="$dir/log"
  cmux_state_init "$SDIR"
  SFB=$(make_cmux_state_fakebin "$dir")
  : > "$SLOG"
}

# cmux_state_run <snippet>: run <snippet> in a fresh bash with the adapter
# sourced against the current stateful case. Environment set by the caller
# (FM_CMUX_CONTAINER, CMUX_WORKSPACE_ID, fake knobs) passes through.
cmux_state_run() {
  PATH="$SFB:$PATH" FM_CMUX_STATE="$SDIR" FM_CMUX_LOG="$SLOG" \
    FM_CMUX_READY_ATTEMPTS="${FM_CMUX_READY_ATTEMPTS:-3}" FM_CMUX_READY_INTERVAL=0 FM_CMUX_READY_SETTLE=0 \
    bash -c '. "$0/bin/backends/cmux.sh"; eval "$1"' "$ROOT" "$1"
}

# The 0.64.25 race: `workspace list` omits a just-created workspace, so a
# title lookup right after creation fails; resolution from the printed ref
# through list-panes does not.
test_state_workspace_create_survives_lagging_workspace_list() {
  local out title
  cmux_state_case ws-lag
  title=$(cmux_expected_scoped_title fm-lag)
  out=$(FM_CMUX_FAKE_LIST_LAG=3 cmux_state_run 'fm_backend_cmux_create_task fm-lag /tmp/proj') \
    || fail "create_task failed against a lagging workspace list"
  [ "$out" = "WS-101 SF-101" ] || fail "create_task should return the printed-ref workspace and its surface, got '$out'"
  assert_contains "$(cat "$SDIR/workspaces.tsv")" "$title" "the task workspace was not created with its scoped title"
  pass "cmux workspace mode: create resolves a new workspace that workspace list still omits (0.64.25 lag)"
}

test_state_container_mode_precedence() {
  local cfg out err
  cmux_state_case mode
  cfg="$TMP_ROOT/state-mode/config"; mkdir -p "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" cmux_state_run 'fm_backend_cmux_container_mode')
  [ "$out" = workspace ] || fail "absent config should default to workspace, got '$out'"
  printf '\n  tab  \n' > "$cfg/cmux-container"
  out=$(FM_CONFIG_OVERRIDE="$cfg" cmux_state_run 'fm_backend_cmux_container_mode')
  [ "$out" = tab ] || fail "config/cmux-container 'tab' should select tab mode, got '$out'"
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_CMUX_CONTAINER=workspace cmux_state_run 'fm_backend_cmux_container_mode')
  [ "$out" = workspace ] || fail "FM_CMUX_CONTAINER should override the config file, got '$out'"
  err=$(FM_CONFIG_OVERRIDE="$cfg" FM_CMUX_CONTAINER=pane cmux_state_run 'fm_backend_cmux_container_mode' 2>&1 >/dev/null)
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_CMUX_CONTAINER=pane cmux_state_run 'fm_backend_cmux_container_mode' 2>/dev/null)
  [ "$out" = workspace ] || fail "an unknown mode should fall back to workspace, got '$out'"
  assert_contains "$err" "unknown cmux container mode 'pane'" "an unknown mode should warn"
  pass "cmux container mode: FM_CMUX_CONTAINER, then config/cmux-container, then workspace; unknown values warn and fall back"
}

test_state_container_ensure_workspace_mode_token() {
  local out
  cmux_state_case ensure-ws
  out=$(FM_CMUX_CONTAINER=workspace cmux_state_run 'fm_backend_cmux_container_ensure /tmp/proj') \
    || fail "container_ensure failed in workspace mode"
  [ "$out" = workspace ] || fail "workspace mode should echo the 'workspace' token, got '$out'"
  [ ! -s "$SDIR/workspaces.tsv" ] || fail "workspace mode container_ensure must create nothing"
  pass "cmux container_ensure: workspace mode echoes the workspace token and creates nothing"
}

test_state_container_ensure_tab_uses_live_own_workspace() {
  local out
  cmux_state_case ensure-own
  cmux_state_add_workspace "$SDIR" WS-OWN workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-OWN SF-OWN surface:7 MATE ttys000
  out=$(FM_CMUX_CONTAINER=tab CMUX_WORKSPACE_ID=WS-OWN cmux_state_run 'fm_backend_cmux_container_ensure /tmp/proj') \
    || fail "container_ensure failed in tab mode"
  [ "$out" = WS-OWN ] || fail "tab mode should use firstmate's own live workspace, got '$out'"
  pass "cmux container_ensure: tab mode uses firstmate's own live workspace"
}

test_state_container_ensure_tab_refinds_stale_own_workspace_by_surface() {
  local out
  cmux_state_case ensure-stale
  cmux_state_add_workspace "$SDIR" WS-NEWID workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-NEWID SF-OWN surface:7 MATE ttys000
  out=$(FM_CMUX_CONTAINER=tab CMUX_WORKSPACE_ID=WS-GONE CMUX_SURFACE_ID=SF-OWN cmux_state_run 'fm_backend_cmux_container_ensure /tmp/proj') \
    || fail "container_ensure failed with a stale workspace marker"
  [ "$out" = WS-NEWID ] || fail "a stale CMUX_WORKSPACE_ID should be re-found from CMUX_SURFACE_ID, got '$out'"
  pass "cmux container_ensure: a stale own-workspace marker is re-found from the surface id"
}

test_state_container_ensure_tab_shared_container_find_or_create() {
  local out out2 err title
  cmux_state_case ensure-shared
  title="fm-$(cmux_expected_home_label)"
  # shellcheck disable=SC2016  # expanded by the inner shell
  err=$(FM_CMUX_CONTAINER=tab CMUX_WORKSPACE_ID=WS-GONE FM_CMUX_FAKE_LIST_LAG=3 \
    cmux_state_run 'fm_backend_cmux_container_ensure /tmp/proj >"$FM_CMUX_STATE/out"' 2>&1) \
    || fail "container_ensure failed to create the shared container: $err"
  out=$(cat "$SDIR/out")
  [ "$out" = WS-101 ] || fail "the shared container should resolve from its printed ref despite list lag, got '$out'"
  assert_contains "$err" "no longer live" "a stale own-workspace marker should be reported before falling back"
  assert_contains "$(cat "$SDIR/workspaces.tsv")" "$(printf 'WS-101\tworkspace:101\t%s\t/tmp/proj' "$title")" \
    "the shared container should be titled fm-<home> and created in the given cwd"
  out2=$(FM_CMUX_CONTAINER=tab cmux_state_run 'fm_backend_cmux_container_ensure /tmp/proj')
  [ "$out2" = WS-101 ] || fail "a second ensure should reuse the shared container, got '$out2'"
  [ "$(grep -c . "$SDIR/workspaces.tsv")" = 1 ] || fail "a second ensure must not create another container"
  pass "cmux container_ensure: outside a live cmux workspace, tab mode finds or creates one shared per-home container"
}

# cmux_state_tab_container: the captain's workspace with one pre-existing tab.
cmux_state_tab_container() {
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-CAP surface:7 MATE ttys000
  printf 'user@host %% \n' > "$SDIR/screen.txt"
}

test_state_tab_create_titles_and_moves_new_tab() {
  local out title
  cmux_state_case tab-create
  cmux_state_tab_container
  title=$(cmux_expected_scoped_title fm-tab1)
  out=$(cmux_state_run 'fm_backend_cmux_create_task fm-tab1 "/tmp/my proj" WS-CAP') \
    || fail "tab-mode create_task failed"
  [ "$out" = "WS-CAP SF-101" ] || fail "tab-mode create should return the container and the new surface, got '$out'"
  assert_contains "$(cat "$SDIR/surfaces.tsv")" "$(printf 'WS-CAP\tSF-101\tsurface:101\t%s' "$title")" \
    "the new tab should carry the scoped task title"
  assert_contains "$(cat "$SDIR/surfaces.tsv")" "$(printf 'WS-CAP\tSF-CAP\tsurface:7\tMATE')" \
    "the captain's existing tab must be untouched"
  assert_contains "$(cat "$SLOG")" $'\x1f''new-surface'$'\x1f''--type'$'\x1f''terminal'$'\x1f''--workspace'$'\x1f''WS-CAP'$'\x1f''--focus'$'\x1f''false' \
    "the tab should be created unfocused in the container"
  assert_contains "$(cat "$SLOG")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''WS-CAP'$'\x1f''--surface'$'\x1f''SF-101'$'\x1f''--'$'\x1f''cd /tmp/my\ proj' \
    "the new tab should be moved to the task cwd"
  pass "cmux tab mode: create adds one unfocused tab, titles it, and moves it to the task cwd"
}

test_state_tab_create_refuses_duplicate_title_anywhere() {
  local out status title
  cmux_state_case tab-dup
  cmux_state_tab_container
  title=$(cmux_expected_scoped_title fm-dup)
  cmux_state_add_workspace "$SDIR" WS-OTHER workspace:3 other /tmp
  cmux_state_add_surface "$SDIR" WS-OTHER SF-X surface:9 "$title"
  out=$(cmux_state_run 'fm_backend_cmux_create_task fm-dup /tmp/proj WS-CAP' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "tab-mode create should refuse a duplicate task tab in another workspace"
  assert_contains "$out" "already exists" "the refusal should name the duplicate"
  assert_not_contains "$(cat "$SLOG")" $'\x1f''new-surface' "a refused duplicate must create nothing"
  pass "cmux tab mode: create refuses a task tab title that already exists in any workspace"
}

test_state_tab_create_picks_own_tab_by_ref_when_concurrent() {
  local out
  cmux_state_case tab-concurrent
  cmux_state_tab_container
  out=$(FM_CMUX_FAKE_NEW_SURFACE_EXTRA=1 cmux_state_run 'fm_backend_cmux_create_task fm-c1 /tmp/proj WS-CAP') \
    || fail "tab-mode create should disambiguate concurrent new tabs by the printed ref"
  [ "$out" = "WS-CAP SF-101" ] || fail "create should pick the tab its own printed ref names, got '$out'"
  assert_contains "$(cat "$SDIR/surfaces.tsv")" "$(printf 'WS-CAP\tSF-102\tsurface:102\tTerminal')" \
    "the concurrent spawn's tab must not be renamed"
  pass "cmux tab mode: when a concurrent spawn adds a tab too, the printed ref picks this call's own"
}

test_state_tab_create_ambiguous_without_ref_closes_nothing() {
  local out status
  cmux_state_case tab-ambiguous
  cmux_state_tab_container
  out=$(FM_CMUX_FAKE_NEW_SURFACE_EXTRA=1 FM_CMUX_FAKE_NO_REF=1 cmux_state_run 'fm_backend_cmux_create_task fm-c2 /tmp/proj WS-CAP' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unresolvable new tab should fail the create"
  assert_contains "$out" "by hand" "the error should ask for a manual close"
  assert_not_contains "$(cat "$SLOG")" $'\x1f''close-surface' "nothing may be closed without knowing which tab is ours"
  assert_not_contains "$(cat "$SLOG")" $'\x1f''rename-tab' "an unresolved tab must not be renamed"
  pass "cmux tab mode: an ambiguous diff with no printed ref fails without closing or renaming any tab"
}

test_state_tab_create_rename_failure_closes_only_new_tab() {
  local out status
  cmux_state_case tab-rename
  cmux_state_tab_container
  out=$(FM_CMUX_FAKE_RENAME_EXIT=1 cmux_state_run 'fm_backend_cmux_create_task fm-r1 /tmp/proj WS-CAP' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a failed rename should fail the create"
  assert_contains "$(cat "$SLOG")" $'\x1f''close-surface'$'\x1f''--workspace'$'\x1f''WS-CAP'$'\x1f''--surface'$'\x1f''SF-101' \
    "a failed rename should close the new tab"
  [ "$(cut -f2 "$SDIR/surfaces.tsv")" = SF-CAP ] || fail "only the captain's tab should remain: $(cat "$SDIR/surfaces.tsv")"
  pass "cmux tab mode: a failed rename closes only the new tab"
}

test_state_tab_target_ready_routes_by_surface_title() {
  local out title
  cmux_state_case tab-target
  cmux_state_tab_container
  title=$(cmux_expected_scoped_title fm-t1)
  cmux_state_add_surface "$SDIR" WS-CAP SF-T1 surface:20 "$title"
  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cmux_state_run 'fm_backend_cmux_target_ready WS-CAP:SF-STALE fm-t1 && printf "%s:%s" "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE"') \
    || fail "target_ready should re-find a tab-mode task by its surface title"
  [ "$out" = WS-CAP:SF-T1 ] || fail "target_ready should route to the titled tab, got '$out'"
  # A relaunch-stale container id: the task is re-found in whatever workspace holds it.
  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cmux_state_run 'fm_backend_cmux_target_ready WS-GONE:SF-T1 fm-t1 && printf "%s:%s" "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE"') \
    || fail "target_ready should re-find a tab-mode task when its container id went stale"
  [ "$out" = WS-CAP:SF-T1 ] || fail "target_ready should re-find the tab anywhere, got '$out'"
  cmux_state_run 'fm_backend_cmux_target_ready WS-CAP:SF-CAP fm-other' \
    && fail "target_ready must refuse a live tab whose title is another task's"
  pass "cmux tab mode: target_ready routes by scoped tab title, survives a stale container id, and refuses a mismatch"
}

test_state_kill_tab_closes_only_task_tab() {
  local title
  cmux_state_case kill-tab
  cmux_state_tab_container
  title=$(cmux_expected_scoped_title fm-k1)
  cmux_state_add_surface "$SDIR" WS-CAP SF-K1 surface:21 "$title"
  cmux_state_run 'fm_backend_cmux_kill WS-CAP:SF-K1 "" fm-k1' || fail "kill should succeed"
  [ "$(cut -f2 "$SDIR/surfaces.tsv")" = SF-CAP ] || fail "kill should close only the task tab: $(cat "$SDIR/surfaces.tsv")"
  grep -q WS-CAP "$SDIR/workspaces.tsv" || fail "kill must never close the captain's container workspace"
  pass "cmux tab mode: kill closes only the task tab and keeps the container"
}

test_state_kill_tab_last_surface_in_captain_workspace() {
  local title
  cmux_state_case kill-last
  title=$(cmux_expected_scoped_title fm-k2)
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-K2 surface:22 "$title"
  cmux_state_run 'fm_backend_cmux_kill WS-CAP:SF-K2 "" fm-k2' || fail "kill should succeed"
  grep -q WS-CAP "$SDIR/workspaces.tsv" || fail "the captain's workspace must survive"
  ! grep -q SF-K2 "$SDIR/surfaces.tsv" || fail "the task tab should be closed even when it was the last one"
  [ "$(grep -c . "$SDIR/surfaces.tsv")" = 1 ] || fail "a throwaway tab should remain in the captain's workspace"
  pass "cmux tab mode: the last tab in the captain's workspace is replaced by a throwaway tab, never closing the workspace"
}

test_state_kill_tab_last_surface_reclaims_shared_container() {
  local title shared
  cmux_state_case kill-shared
  title=$(cmux_expected_scoped_title fm-k3)
  shared="fm-$(cmux_expected_home_label)"
  cmux_state_add_workspace "$SDIR" WS-KEEP workspace:1 other /tmp
  cmux_state_add_surface "$SDIR" WS-KEEP SF-KEEP surface:1 zsh
  cmux_state_add_workspace "$SDIR" WS-SH workspace:5 "$shared" /tmp
  cmux_state_add_surface "$SDIR" WS-SH SF-K3 surface:23 "$title"
  cmux_state_run 'fm_backend_cmux_kill WS-SH:SF-K3 "" fm-k3' || fail "kill should succeed"
  ! grep -q WS-SH "$SDIR/workspaces.tsv" || fail "the task-free shared container should be reclaimed"
  grep -q WS-KEEP "$SDIR/workspaces.tsv" || fail "unrelated workspaces must survive"
  pass "cmux tab mode: the last task tab in this home's shared container reclaims the container"
}

test_state_kill_workspace_mode_closes_task_workspace() {
  local title
  cmux_state_case kill-ws
  title=$(cmux_expected_scoped_title fm-k4)
  cmux_state_add_workspace "$SDIR" WS-KEEP workspace:1 other /tmp
  cmux_state_add_surface "$SDIR" WS-KEEP SF-KEEP surface:1 zsh
  cmux_state_add_workspace "$SDIR" WS-T workspace:6 "$title" /tmp
  cmux_state_add_surface "$SDIR" WS-T SF-T surface:24 Terminal
  cmux_state_run 'fm_backend_cmux_kill WS-T:SF-T "" fm-k4' || fail "kill should succeed"
  ! grep -q WS-T "$SDIR/workspaces.tsv" || fail "a task-owned workspace should be closed whole"
  grep -q WS-KEEP "$SDIR/workspaces.tsv" || fail "unrelated workspaces must survive"
  pass "cmux workspace mode: kill closes the task-owned workspace"
}

test_state_list_live_covers_both_shapes() {
  local out t1 t2 home
  cmux_state_case list-live
  home=$(cmux_expected_home_label)
  t1=$(cmux_expected_scoped_title fm-ws1)
  t2=$(cmux_expected_scoped_title fm-tab2)
  cmux_state_add_workspace "$SDIR" WS-T workspace:6 "$t1" /tmp
  cmux_state_add_surface "$SDIR" WS-T SF-T surface:24 Terminal
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-CAP surface:7 MATE
  cmux_state_add_surface "$SDIR" WS-CAP SF-TAB surface:25 "$t2"
  cmux_state_add_workspace "$SDIR" WS-SH workspace:5 "fm-$home" /tmp
  cmux_state_add_surface "$SDIR" WS-SH SF-SH surface:26 zsh
  out=$(cmux_state_run 'fm_backend_cmux_list_live')
  [ "$out" = "$(printf 'WS-T:SF-T\tfm-ws1\nWS-CAP:SF-TAB\tfm-tab2')" ] \
    || fail "list_live should list the task workspace and the task tab only, got: $out"
  pass "cmux list_live: lists workspace-mode and tab-mode tasks, never the shared container or foreign tabs"
}

test_state_current_path_prefers_passive_tty_tier() {
  local out title
  cmux_state_case cwd-tty
  title=$(cmux_expected_scoped_title fm-p1)
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-P1 surface:30 "$title" ttys044
  out=$(FM_FAKE_PS_TTY_PIDSTAT='999901 Ss\n999902 S+' FM_FAKE_LSOF_CWD=/wt/fake-worktree \
    cmux_state_run 'fm_backend_cmux_current_path WS-CAP:SF-P1 fm-p1')
  [ "$out" = /wt/fake-worktree ] || fail "current_path should read the foreground process cwd, got '$out'"
  assert_not_contains "$(cat "$SLOG")" $'\x1f''send'$'\x1f' "a passive hit must type nothing into the task terminal"
  pass "cmux current_path: the tty/ps/lsof tier answers without typing into the terminal"
}

test_state_current_path_screen_tier() {
  local out title
  cmux_state_case cwd-screen
  title=$(cmux_expected_scoped_title fm-p2)
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-P2 surface:31 "$title"
  printf '| [1] /tmp/proj @ host (me) \n$ treehouse get\n| [2] /wt/from-screen @ host (me) \n$ \n' > "$SDIR/screen.txt"
  out=$(cmux_state_run 'fm_backend_cmux_current_path WS-CAP:SF-P2 fm-p2')
  [ "$out" = /wt/from-screen ] || fail "current_path should read the last on-screen block header, got '$out'"
  assert_not_contains "$(cat "$SLOG")" $'\x1f''send'$'\x1f' "a passive hit must type nothing into the task terminal"
  pass "cmux current_path: the on-screen block-header tier answers when no tty is reported"
}

test_state_current_path_falls_back_to_marker_probe() {
  local out title
  cmux_state_case cwd-marker
  title=$(cmux_expected_scoped_title fm-p3)
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-P3 surface:32 "$title"
  printf '/tmp/proj\n❯ printf marker\n__FM_CMUX_CWD_BEGIN__\n/home/fixture/.treehouse/fake-worktree\n__FM_CMUX_CWD_END__\n❯\n' > "$SDIR/screen.txt"
  out=$(cmux_state_run 'fm_backend_cmux_current_path WS-CAP:SF-P3 fm-p3')
  [ "$out" = /home/fixture/.treehouse/fake-worktree ] || fail "current_path should read only the marked cwd line, got '$out'"
  assert_contains "$(cat "$SLOG")" "__FM_CMUX_CWD_BEGIN__" "current_path did not send the cwd begin marker"
  assert_contains "$(cat "$SLOG")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''WS-CAP'$'\x1f''--surface'$'\x1f''SF-P3'$'\x1f''enter' \
    "current_path did not submit the cwd probe with Enter"
  pass "cmux current_path: with no passive answer, probes with marked begin/end lines (frozen-cwd workaround)"
}

# cmux_state_agent_case: one live task tab on ttys050 for agent_state tests.
cmux_state_agent_case() {
  cmux_state_case "agent-$1"
  cmux_state_add_workspace "$SDIR" WS-CAP workspace:2 AIR-MATE /tmp
  cmux_state_add_surface "$SDIR" WS-CAP SF-A surface:40 "$(cmux_expected_scoped_title fm-a1)" "${2-ttys050}"
}

test_state_agent_state_classifies_tty_processes() {
  local out
  cmux_state_agent_case alive
  out=$(FM_FAKE_PS_TTY_PROCS='999911 login\n999912 -zsh\n999913 zsh\n999914 claude\n999915 bash' \
    cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = alive ] || fail "a harness process anywhere on the tty should read alive, got '$out'"
  out=$(FM_FAKE_PS_TTY_PROCS='999911 /usr/bin/login\n999912 -zsh\n999913 zsh' \
    cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = dead ] || fail "login plus shells only should read dead, got '$out'"
  out=$(FM_FAKE_PS_TTY_PROCS='999911 login\n999912 -zsh\n999916 vim' \
    cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = ambiguous ] || fail "an unattributable process should read ambiguous, got '$out'"
  out=$(cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = unreadable ] || fail "an empty tty process read should read unreadable, got '$out'"
  pass "cmux agent_state: classifies every tty process (login counts as a shell) into alive, dead, ambiguous, unreadable"
}

test_state_agent_state_endpoint_and_socket_rungs() {
  local out
  cmux_state_agent_case rungs ""
  out=$(cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = ambiguous ] || fail "a never-started terminal (no tty) should read ambiguous, got '$out'"
  out=$(cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-GONE')
  [ "$out" = missing ] || fail "a target absent from a readable inventory should read missing, got '$out'"
  out=$(FM_CMUX_FAKE_PING='Error: Socket not found at /tmp/x' FM_CMUX_FAKE_PING_EXIT=1 \
    cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = missing ] || fail "a down cmux socket should read missing, got '$out'"
  out=$(FM_CMUX_FAKE_PING='Access denied - only processes started inside cmux can connect' FM_CMUX_FAKE_PING_EXIT=1 \
    cmux_state_run 'fm_backend_cmux_agent_state WS-CAP:SF-A')
  [ "$out" = unreadable ] || fail "a denied socket should read unreadable, got '$out'"
  out=$(PATH="$SFB:$PATH" FM_CMUX_STATE="$SDIR" FM_CMUX_LOG="$SLOG" FM_FAKE_PS_TTY_PROCS='999912 -zsh' \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state cmux WS-CAP:SF-A' "$ROOT")
  [ "$out" = ambiguous ] || fail "fm_backend_agent_state should dispatch cmux to its classifier (no tty here), got '$out'"
  pass "cmux agent_state: no tty is ambiguous, an absent target or down socket is missing, auth failures are unreadable, and the shared dispatch routes cmux"
}

# shellcheck source=/dev/null
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
test_create_task_retries_printed_ref_lookup_after_creation
test_create_task_closes_unresolved_workspace_by_printed_ref
test_create_task_names_leftover_title_when_ref_close_fails
test_create_task_names_leftover_title_without_ref
test_target_ready_fails_when_target_absent
test_target_ready_checks_expected_label
test_target_ready_rejects_label_mismatch
test_capture_trims_locally
test_capture_fails_when_read_screen_fails_empty
test_capture_fails_when_target_not_ready
test_send_key_normalizes_and_targets
test_send_key_recovers_stale_target_by_label
test_send_literal_uses_separator_for_option_shaped_text
test_send_text_line_clears_partial_input_when_enter_fails
test_send_text_line_reports_unsafe_input_when_cleanup_fails
test_composer_state_bare_prompt_is_empty
test_composer_state_borderless_claude_prompt_is_empty
test_composer_state_borderless_claude_prompt_outranks_stale_bordered_row
test_composer_state_borderless_claude_nbsp_prompt_is_empty
test_composer_state_borderless_claude_text_is_unknown_plain
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
test_close_workspace_closes_directly_when_not_last
test_close_workspace_adds_sibling_when_last_in_window
test_close_workspace_is_best_effort_when_close_fails
test_kill_recovers_stale_target_by_label
test_list_live_filters_by_title_prefix
test_secondmate_spawn_refuses_cmux_backend
test_state_workspace_create_survives_lagging_workspace_list
test_state_container_mode_precedence
test_state_container_ensure_workspace_mode_token
test_state_container_ensure_tab_uses_live_own_workspace
test_state_container_ensure_tab_refinds_stale_own_workspace_by_surface
test_state_container_ensure_tab_shared_container_find_or_create
test_state_tab_create_titles_and_moves_new_tab
test_state_tab_create_refuses_duplicate_title_anywhere
test_state_tab_create_picks_own_tab_by_ref_when_concurrent
test_state_tab_create_ambiguous_without_ref_closes_nothing
test_state_tab_create_rename_failure_closes_only_new_tab
test_state_tab_target_ready_routes_by_surface_title
test_state_kill_tab_closes_only_task_tab
test_state_kill_tab_last_surface_in_captain_workspace
test_state_kill_tab_last_surface_reclaims_shared_container
test_state_kill_workspace_mode_closes_task_workspace
test_state_list_live_covers_both_shapes
test_state_current_path_prefers_passive_tty_tier
test_state_current_path_screen_tier
test_state_current_path_falls_back_to_marker_probe
test_state_agent_state_classifies_tty_processes
test_state_agent_state_endpoint_and_socket_rungs
