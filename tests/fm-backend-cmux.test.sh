#!/usr/bin/env bash
# tests/fm-backend-cmux.test.sh - fake-cmux-CLI unit tests for the cmux
# session-provider adapter (bin/backends/cmux.sh). Mirrors
# tests/fm-backend-herdr.test.sh's fakebin/command-log convention: direct
# behavior assertions against a small, LOG-based, canned-response fake `cmux`
# + real `jq`. Real-binary verification lives in docs/cmux-backend.md and the
# E2E pass recorded there; these tests pin the adapter's call shapes and
# verdict vocabulary without needing the app.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-cmux-tests)

# make_cmux_fakebin: a `cmux` stub that logs every invocation (one line,
# unit-separated args, to $FM_CMUX_LOG) and returns the canned response for
# that call read from $FM_CMUX_RESPONSES/<n>.out, consumed IN ORDER. A missing
# response file means "succeed with empty stdout" (send/send-key/close are
# silent on success). `cmux version` is answered inline (like the herdr fake's
# status) unless FM_CMUX_SCRIPT_VERSION=1 scripts it through the sequence.
make_cmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUX_LOG:?}"
RESP="${FM_CMUX_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'CMUX_QUIET=%s' "${CMUX_QUIET:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = version ] && [ "${FM_CMUX_SCRIPT_VERSION:-0}" != 1 ]; then
  printf 'cmux 0.64.17 (97) [9ed29d81a]\n'
  exit 0
fi
if [ "${1:-}" = ping ] && [ "${FM_CMUX_SCRIPT_PING:-0}" != 1 ]; then
  printf 'pong\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  [ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

# Verified 0.64.17 list-workspaces shape: the CLI-set name lives in
# custom_title (title mirrors it but can be rewritten by opt-in auto-naming),
# and the live working directory is current_directory.
WS_LIST_ONE='{"workspaces":[{"id":"11111111-aaaa-bbbb-cccc-000000000001","title":"fm-task1","custom_title":"fm-task1","current_directory":"/tmp/fake-worktree"}]}'

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_version() {
  local dir log resp fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'cmux 0.64.17 (97) [9ed29d81a]\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" FM_CMUX_SCRIPT_VERSION=1 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept 0.64.17 (== the verified minimum)"
  assert_contains "$(cat "$log")" $'\x1f''version' "version_check did not call cmux version"
  pass "fm_backend_cmux_version_check: accepts the verified minimum version"
}

test_version_check_accepts_newer_version() {
  local dir log resp fb status
  dir="$TMP_ROOT/version-newer"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'cmux 0.65.2 (103) [deadbeef]\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" FM_CMUX_SCRIPT_VERSION=1 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT"
  expect_code 0 $? "version_check should accept a newer version"
  pass "fm_backend_cmux_version_check: accepts a newer version"
}

test_version_check_refuses_old_version() {
  local dir log resp fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'cmux 0.60.1 (80) [cafe]\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" FM_CMUX_SCRIPT_VERSION=1 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse 0.60.1 (below min)"
  assert_contains "$out" "0.60.1" "version_check error did not name the rejected version"
  pass "fm_backend_cmux_version_check: refuses an old version loudly"
}

test_version_check_refuses_missing_cmux() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when cmux is not installed"
  assert_contains "$out" "not installed" "version_check did not report cmux as missing"
  pass "fm_backend_cmux_version_check: refuses loudly when cmux is not installed"
}

# --- socket_check / container_ensure ------------------------------------------

test_socket_check_reports_auth_fix() {
  local dir log resp fb out status
  dir="$TMP_ROOT/socket-auth"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'Error: ERROR: Authentication required - send auth <password> first\n' > "$resp/1.out"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" FM_CMUX_SCRIPT_PING=1 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_socket_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "socket_check should fail when ping is refused"
  assert_contains "$out" "CMUX_SOCKET_PASSWORD" "socket_check auth error did not name the operator fix"
  pass "fm_backend_cmux_socket_check: an auth refusal names the socket-mode/password fix"
}

test_container_ensure_gates_and_echoes_token() {
  local dir log resp fb out
  dir="$TMP_ROOT/container"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_container_ensure' "$ROOT" )
  [ "$out" = "cmux" ] || fail "container_ensure should echo the constant container token 'cmux', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''version' "container_ensure did not version-gate"
  assert_contains "$(cat "$log")" $'\x1f''ping' "container_ensure did not verify the live socket"
  pass "fm_backend_cmux_container_ensure: version-gates, checks the socket, echoes 'cmux'"
}

# --- create_task ----------------------------------------------------------------

test_create_task_refuses_duplicate_name() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"workspaces":[{"id":"11111111-aaaa-bbbb-cccc-000000000009","custom_title":"fm-dup1","current_directory":"/tmp"}]}\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing workspace name (cmux does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate name"
  pass "fm_backend_cmux_create_task: refuses a duplicate workspace name"
}

test_create_task_creates_and_resolves_uuid() {
  local dir log resp fb out
  # Verified 0.64.17 flow: new-workspace ignores --json and prints only
  # "OK workspace:<n>" (an unstable short ref), so the adapter resolves the
  # stable UUID with a follow-up custom_title lookup.
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"workspaces":[]}\n' > "$resp/1.out"
  printf 'OK workspace:2\n' > "$resp/2.out"
  printf '{"workspaces":[{"id":"22222222-aaaa-bbbb-cccc-000000000002","custom_title":"fm-newtask","current_directory":"/tmp/proj"}]}\n' > "$resp/3.out"
  # 4: the readiness gate's wake Enter (no output); 5/6: its two stable
  # non-empty screen reads.
  printf 'ready prompt\n' > "$resp/5.out"
  printf 'ready prompt\n' > "$resp/6.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    FM_CMUX_READY_ATTEMPTS=3 FM_CMUX_READY_INTERVAL=0.01 FM_CMUX_READY_SETTLE=0.01 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "22222222-aaaa-bbbb-cccc-000000000002" ] || fail "create_task should echo the workspace uuid resolved by name, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''read-screen'$'\x1f''--workspace'$'\x1f''22222222-aaaa-bbbb-cccc-000000000002' \
    "create_task did not run the shell-readiness gate before returning"
  assert_contains "$(cat "$log")" $'\x1f''new-workspace'$'\x1f''--name'$'\x1f''fm-newtask'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--focus'$'\x1f''false' \
    "create_task did not call new-workspace with name/cwd/focus"
  assert_contains "$(cat "$log")" $'\x1f''--id-format'$'\x1f''uuids' \
    "create_task did not request stable uuid handles for the lookup"
  pass "fm_backend_cmux_create_task: creates without focus-stealing and resolves the uuid by custom_title"
}

test_create_task_fails_on_unacknowledged_create() {
  local dir log resp fb out status
  dir="$TMP_ROOT/create-task-noack"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"workspaces":[]}\n' > "$resp/1.out"
  printf 'Error: something else\n' > "$resp/2.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-newtask /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should fail when new-workspace does not acknowledge with 'OK workspace'"
  assert_contains "$out" "did not acknowledge" "create_task did not report the unacknowledged create"
  pass "fm_backend_cmux_create_task: refuses when new-workspace prints no 'OK workspace' acknowledgment"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/cmux.sh"
    fm_backend_cmux_parse_target "cmux:11111111-aaaa-bbbb-cccc-000000000001" || exit 1
    [ "$FM_BACKEND_CMUX_WS" = "11111111-aaaa-bbbb-cccc-000000000001" ] || { echo "ws mismatch: $FM_BACKEND_CMUX_WS" >&2; exit 1; }
    fm_backend_cmux_parse_target "notcmux:x" && exit 1
    fm_backend_cmux_parse_target "bare-no-colon" && exit 1
    exit 0
  ) || fail "fm_backend_cmux_parse_target did not enforce the 'cmux:<workspace>' shape"
  pass "fm_backend_cmux_parse_target: accepts 'cmux:<uuid>', refuses other prefixes and colon-free strings"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/cmux.sh"
    [ "$(fm_backend_cmux_normalize_key Enter)" = enter ] || exit 1
    [ "$(fm_backend_cmux_normalize_key Escape)" = escape ] || exit 1
    [ "$(fm_backend_cmux_normalize_key C-c)" = ctrl+c ] || exit 1
    [ "$(fm_backend_cmux_normalize_key ctrl+c)" = ctrl+c ] || exit 1
  ) || fail "fm_backend_cmux_normalize_key did not map firstmate's key vocabulary"
  pass "fm_backend_cmux_normalize_key: Enter/Escape/C-c map to cmux's names"
}

# --- capture / send_key / kill / current_path --------------------------------

test_capture_calls_read_screen() {
  local dir log resp fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'line one\nline two\nline three\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture cmux:ws-1 250' "$ROOT" )
  [ "$out" = $'line one\nline two\nline three' ] || fail "capture did not pass through read-screen output, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''read-screen'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''--lines'$'\x1f''250' \
    "capture did not call read-screen with the right workspace and line bound"
  pass "fm_backend_cmux_capture: calls 'read-screen --workspace <ws> --lines N'"
}

test_capture_overfetches_small_n_and_trims() {
  local dir log resp fb out
  # Defensive over-fetch (the herdr small-N read bug motivated this shared
  # pattern): never pass a small caller bound straight to the CLI; fetch >=200
  # and trim locally.
  dir="$TMP_ROOT/capture-small"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'a\nb\nc\nd\ne\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture cmux:ws-1 2' "$ROOT" )
  [ "$out" = $'d\ne' ] || fail "a small line request should return the last N lines (trimmed locally), got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''--lines'$'\x1f''200' \
    "capture should request a generous fetch (>=200), never the caller's small N"
  pass "fm_backend_cmux_capture: over-fetches and trims locally for small N"
}

test_capture_preserves_read_failure() {
  local dir log resp fb status
  dir="$TMP_ROOT/capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture cmux:ws-1 2' "$ROOT" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when read-screen fails"
  pass "fm_backend_cmux_capture: preserves read-screen failure"
}

test_send_key_normalizes_and_targets_workspace() {
  local dir log resp fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key cmux:ws-1 Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''escape' "send_key did not normalize Escape to escape"
  pass "fm_backend_cmux_send_key: normalizes the key and targets the right workspace"
}

test_send_text_line_composes_send_and_enter() {
  local dir log resp fb
  dir="$TMP_ROOT/sendline"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_line cmux:ws-1 "treehouse get"' "$ROOT"
  expect_code 0 $? "send_text_line should succeed"
  assert_contains "$(cat "$log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''treehouse get' "send_text_line did not type the literal text"
  assert_contains "$(cat "$log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''enter' "send_text_line did not submit with enter"
  pass "fm_backend_cmux_send_text_line: composes literal send + enter (no atomic run primitive)"
}

test_kill_is_best_effort() {
  local dir log resp fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_kill cmux:ws-1' "$ROOT"
  expect_code 0 $? "kill must be best-effort (never fail even when close-workspace fails)"
  assert_contains "$(cat "$log")" $'\x1f''close-workspace'$'\x1f''--workspace'$'\x1f''ws-1' "kill did not call close-workspace on the right workspace"
  pass "fm_backend_cmux_kill: calls close-workspace and stays best-effort on failure"
}

test_current_path_falls_back_to_workspace_list() {
  local dir log resp fb out
  # Call 1 is the tty probe (`tree`); an empty response means the terminal
  # has not started (no tty), so current_path falls back to the workspace
  # list's current_directory. The tty+ps+lsof fast path is real-binary-only
  # behavior, covered by the live E2E pass in docs/cmux-backend.md.
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' "$WS_LIST_ONE" > "$resp/2.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path cmux:11111111-aaaa-bbbb-cccc-000000000001' "$ROOT" )
  [ "$out" = "/tmp/fake-worktree" ] || fail "current_path should fall back to the workspace list's current_directory, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tree'$'\x1f''--workspace'$'\x1f''11111111-aaaa-bbbb-cccc-000000000001' \
    "current_path did not probe the surface tty first"
  assert_contains "$(cat "$log")" $'\x1f''list-workspaces'$'\x1f''--json' "current_path did not fall back to the workspace list"
  pass "fm_backend_cmux_current_path: probes the surface tty, falls back to the workspace list cwd"
}

# --- busy_state ----------------------------------------------------------------

test_busy_state_maps_agent_status() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-working"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"workspaces":[{"id":"ws-1","custom_title":"fm-t1","agent_status":"working"}]}\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_busy_state cmux:ws-1' "$ROOT" )
  [ "$out" = busy ] || fail "agent_status=working should map to busy, got '$out'"

  dir="$TMP_ROOT/busy-waiting"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"workspaces":[{"id":"ws-1","custom_title":"fm-t1","agent_status":"waiting"}]}\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_busy_state cmux:ws-1' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=waiting should map to idle (stuck on the human, not grinding), got '$out'"
  pass "fm_backend_cmux_busy_state: working -> busy, waiting -> idle (surfaced, not suppressed)"
}

test_busy_state_unknown_without_field() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' "$WS_LIST_ONE" > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_busy_state cmux:11111111-aaaa-bbbb-cccc-000000000001' "$ROOT" )
  [ "$out" = unknown ] || fail "an absent agent-status field should report unknown (the regex-fallback cue), got '$out'"
  pass "fm_backend_cmux_busy_state: absent/unparseable agent state reports unknown, the regex-fallback cue"
}

# --- send_text_submit: delta-based verify-and-retry --------------------------

test_send_text_submit_detects_landed_send() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send (literal, no output)
  # 2: capture right after typing (the "typed" baseline)
  printf '%s' $'> hello captain' > "$resp/2.out"
  # 3: send-key enter
  # 4: capture after Enter - CHANGED (submitted)
  printf '%s' $'hello captain\n>' > "$resp/4.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit cmux:ws-1 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once the screen visibly changes, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''hello captain' "send_text_submit did not type the literal text first"
  pass "fm_backend_cmux_send_text_submit: reports 'empty' once the screen content changes after Enter"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s' $'> hello captain' > "$resp/2.out"
  printf '%s' $'> hello captain' > "$resp/4.out"
  printf '%s' $'> hello captain' > "$resp/6.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit cmux:ws-1 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with no visible change, got '$out'"
  pass "fm_backend_cmux_send_text_submit: reports 'pending' when the screen never changes after retried Enters"
}

test_send_text_submit_send_failed() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit cmux:ws-1 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the literal send itself fails, got '$out'"
  pass "fm_backend_cmux_send_text_submit: reports 'send-failed' when the literal send errors"
}

# --- fm-backend.sh dispatch wiring -------------------------------------------

test_dispatch_routes_cmux_backend() {
  fm_backend_validate cmux 2>/dev/null || fail "fm_backend_validate should accept cmux (FM_BACKEND_KNOWN)"
  pass "fm_backend_validate: cmux is a known backend"
}

test_detect_prefers_tmux_over_cmux() {
  local out
  out=$( TMUX=/tmp/sock CMUX_WORKSPACE_ID=abc HERDR_ENV='' bash -c '. "$0/bin/fm-backend.sh"; fm_backend_detect' "$ROOT" )
  [ "$out" = tmux ] || fail "detect should resolve innermost-first: \$TMUX wins over CMUX_WORKSPACE_ID, got '$out'"
  out=$( TMUX='' HERDR_ENV='' CMUX_WORKSPACE_ID=abc bash -c '. "$0/bin/fm-backend.sh"; fm_backend_detect' "$ROOT" )
  [ "$out" = cmux ] || fail "detect should select cmux from CMUX_WORKSPACE_ID alone, got '$out'"
  pass "fm_backend_detect: CMUX_WORKSPACE_ID selects cmux; \$TMUX still wins when nested"
}

test_scripts_route_explicit_target_through_meta_backend() {
  local dir state log resp fb neutral out
  dir="$TMP_ROOT/script-explicit-target"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/cmux-stale.meta" "window=cmux:ws-77" "backend=cmux"
  touch "$state/.last-watcher-beat"
  printf 'captured cmux workspace\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux should not be used for a metadata-matched cmux target\n' >&2
exit 42
SH
  chmod +x "$fb/tmux"

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    "$ROOT/bin/fm-peek.sh" cmux:ws-77 5 2>/dev/null )
  [ "$out" = "captured cmux workspace" ] || fail "fm-peek did not capture through cmux for an explicit metadata-matched target, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''read-screen'$'\x1f''--workspace'$'\x1f''ws-77' \
    "fm-peek did not route the explicit target through cmux capture"

  : > "$log"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    "$ROOT/bin/fm-send.sh" cmux:ws-77 --key Escape >/dev/null 2>&1
  expect_code 0 $? "fm-send --key should route an explicit metadata-matched target through cmux"
  assert_contains "$(cat "$log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''ws-77'$'\x1f''escape' \
    "fm-send did not route the explicit target through cmux send-key"

  pass "fm-peek/fm-send: explicit targets matching metadata use the recorded cmux backend"
}

test_list_live_filters_fm_names() {
  local dir log resp fb out
  dir="$TMP_ROOT/list-live"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"workspaces":[{"id":"ws-1","custom_title":"fm-task1"},{"id":"ws-2","custom_title":"scratch"},{"id":"ws-3","custom_title":null,"title":"fm-looks-but-no-custom"},{"id":"ws-4","custom_title":"fm-task2"}]}\n' > "$resp/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$log" FM_CMUX_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_list_live' "$ROOT" )
  [ "$out" = $'cmux:ws-1\tfm-task1\ncmux:ws-4\tfm-task2' ] || fail "list_live should list only fm-* custom_titles as 'cmux:<id>\\t<name>', got '$out'"
  pass "fm_backend_cmux_list_live: lists fm-* workspaces by custom_title with cmux:<id> targets"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_version
test_version_check_accepts_newer_version
test_version_check_refuses_old_version
test_version_check_refuses_missing_cmux
test_socket_check_reports_auth_fix
test_container_ensure_gates_and_echoes_token
test_create_task_refuses_duplicate_name
test_create_task_creates_and_resolves_uuid
test_create_task_fails_on_unacknowledged_create
test_parse_target
test_normalize_key
test_capture_calls_read_screen
test_capture_overfetches_small_n_and_trims
test_capture_preserves_read_failure
test_send_key_normalizes_and_targets_workspace
test_send_text_line_composes_send_and_enter
test_kill_is_best_effort
test_current_path_falls_back_to_workspace_list
test_busy_state_maps_agent_status
test_busy_state_unknown_without_field
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_send_failed
test_dispatch_routes_cmux_backend
test_detect_prefers_tmux_over_cmux
test_scripts_route_explicit_target_through_meta_backend
test_list_live_filters_fm_names
