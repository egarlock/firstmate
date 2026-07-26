#!/usr/bin/env bash
# Behavior tests for bin/fm-harbor-watch.sh - harbor watch wave 1
# (observe-and-escalate supervision of the captain's own opted-in cmux tabs).
#
# Covers: the pure screen classifier against captured pane fixtures (permission
# dialog, picker, busy-beats-stale-notification, credential, waiting, error),
# watch-file schema and atomic writes, identity-mismatch deactivation, dedupe
# re-arm behavior, credential redaction in event lines, the check contract
# (one line per event, silent otherwise, budget-bounded), arm/disarm shim
# registration, and the wave-1 read-only guarantee (no mutating cmux verb is
# ever invoked by the sweep).
#
# The `cmux` fake here is verb-keyed (responses come from fixture files by
# subcommand, with every invocation logged), unlike fm-backend-cmux.test.sh's
# ordered-response fake: the sweep's call count per run varies with the watch
# list, so ordered responses would make every assertion brittle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HW="$ROOT/bin/fm-harbor-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-harbor-watch-tests)

# The auto-derived id for fixture surface SF-1 (hash-based; see hw_add).
SF1_ID="hw-$(printf '%s' SF-1 | shasum -a 256 | awk '{print $1}' | cut -c -8)"

# --- fake cmux ----------------------------------------------------------------

FB="$TMP_ROOT/fakebin"
mkdir -p "$FB"
cat > "$FB/cmux" <<'SH'
#!/usr/bin/env bash
set -u
FX="${FM_HW_FX:?}"
LOG="${FM_HW_LOG:?}"
printf '%s\n' "$*" >> "$LOG"
case "${1:-}" in
  ping) cat "$FX/ping.txt" 2>/dev/null || echo PONG ;;
  version) echo "cmux 0.64.20 (100) [abc]" ;;
  list-windows) cat "$FX/windows.json" ;;
  workspace) cat "$FX/workspaces.json" ;;
  list-pane-surfaces) cat "$FX/surfaces.json" ;;
  list-panes) cat "$FX/panes.json" ;;
  list-notifications) cat "$FX/notifs.txt" 2>/dev/null || true ;;
  read-screen) printf '{"text":%s}' "$(jq -Rs . < "$FX/screen.txt")" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FB/cmux"

# --- fixtures -----------------------------------------------------------------

FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX"

cat > "$FIX/permission.txt" <<'TXT'
 Bash command
   bin/fm-peek.sh fm-tab-watch-s7 2>&1 | tail -8
   Peek scout pane for trust dialog / processing
 This command requires approval
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for: bin/fm-peek.sh fm-tab-watch-s7 *
   3. No
TXT

cat > "$FIX/picker.txt" <<'TXT'
  Which approach should we take?
  ❯ 1. Option A
    2. Option B
  Enter to select · ↑/↓ to navigate · Esc to cancel
TXT

cat > "$FIX/busy.txt" <<'TXT'
some earlier output
✻ Cogitating… (27s · ↑ 960 tokens · esc to interrupt)
TXT

cat > "$FIX/credential.txt" <<'TXT'
 git push origin main
 Password for 'https://github.com': SECRETMARKER
TXT

cat > "$FIX/idle.txt" <<'TXT'
finished the earlier request
  ❯
TXT

cat > "$FIX/error.txt" <<'TXT'
Error: build failed with exit code 1
  ❯
TXT

cat > "$FIX/typing.txt" <<'TXT'
finished the earlier request
│ > drafting a reply to the agent │
TXT

# --- per-test environment -----------------------------------------------------

# hw_env <name>: build a fresh home + fixture dir with the default healthy
# topology (one window, workspace WS-1 "OpenCode", live surface SF-1 "OC tab"),
# no notifications, and the permission screen. Exports HOME_DIR/FX/LOG.
hw_env() {
  local name=$1
  HOME_DIR="$TMP_ROOT/$name/home"
  FX="$TMP_ROOT/$name/fx"
  LOG="$TMP_ROOT/$name/cmux.log"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$FX"
  : > "$LOG"
  echo '[{"id":"WIN-1"}]' > "$FX/windows.json"
  echo '{"workspaces":[{"id":"WS-1","title":"OpenCode"}]}' > "$FX/workspaces.json"
  echo '{"surfaces":[{"id":"SF-1","title":"OC tab"},{"id":"SF-2","title":"Other tab"}]}' > "$FX/surfaces.json"
  echo '{"panes":[{"surface_ids":["SF-1","SF-2"],"selected_surface_id":"SF-1"}]}' > "$FX/panes.json"
  : > "$FX/notifs.txt"
  cp "$FIX/permission.txt" "$FX/screen.txt"
}

# hw_run <verb-and-args...>: run fm-harbor-watch.sh in the current hw_env.
hw_run() {
  PATH="$FB:$PATH" FM_HW_FX="$FX" FM_HW_LOG="$LOG" \
    FM_HOME="$HOME_DIR" FM_HARBOR_MACHINE=testmac \
    "$HW" "$@"
}

hw_classify() {  # <fixture> [classify args...] -> class
  local fixture=$1
  shift
  "$HW" classify "$@" < "$FIX/$fixture"
}

# --- classifier fixtures --------------------------------------------------------

test_classify_permission_dialog() {
  local out
  out=$(hw_classify permission.txt)
  [ "$out" = permission ] || fail "permission dialog classified as '$out'"
  pass "classify: live claude permission dialog -> permission"
}

test_classify_picker_is_decision() {
  local out
  out=$(hw_classify picker.txt)
  [ "$out" = decision ] || fail "picker classified as '$out'"
  pass "classify: AskUserQuestion picker -> decision"
}

test_classify_busy_beats_stale_notification() {
  local out
  out=$(hw_classify busy.txt --notif-kind Permission --notif-unread 1)
  [ "$out" = working ] || fail "busy screen with stale Permission notif classified as '$out'"
  pass "classify: visibly-working tab beats an unread Permission notification"
}

test_classify_credential_prompt() {
  local out
  out=$(hw_classify credential.txt)
  [ "$out" = credential ] || fail "credential prompt classified as '$out'"
  pass "classify: password prompt -> credential"
}

test_classify_waiting_needs_unread_notif() {
  local out
  out=$(hw_classify idle.txt --notif-kind Waiting --notif-unread 1)
  [ "$out" = waiting ] || fail "idle + unread Waiting notif classified as '$out'"
  out=$(hw_classify idle.txt --notif-kind Waiting --notif-unread 0)
  [ "$out" = idle ] || fail "idle + read Waiting notif classified as '$out'"
  pass "classify: waiting only on an UNREAD Waiting notification"
}

test_classify_error_beside_idle_prompt() {
  local out
  out=$(hw_classify error.txt)
  [ "$out" = error ] || fail "error screen classified as '$out'"
  pass "classify: visible error beside an idle prompt -> error"
}

# --- watch-file schema and chat ops ---------------------------------------------

test_add_writes_schema_atomically() {
  hw_env add-schema
  local out rc file
  out=$(hw_run add --workspace OpenCode --surface SF-1)
  rc=$?
  expect_code 0 "$rc" "add"
  assert_contains "$out" "watching: ${SF1_ID}" "add confirms the watch"
  file="$HOME_DIR/config/harbor-watch.json"
  assert_present "$file" "watch file created"
  jq -e '.version == 1' "$file" >/dev/null || fail "version is not 1"
  jq -e --arg id "$SF1_ID" '.watches[0] | (.id == $id) and (.machine == "testmac")
    and (.workspace_title == "OpenCode") and (.surface_title == "OC tab")
    and (.surface_uuid == "SF-1") and (.active == true)
    and (.classes == []) and (.addedAt | length > 0)' "$file" >/dev/null \
    || fail "entry fields wrong: $(cat "$file")"
  [ -z "$(find "$HOME_DIR/config" -name '.harbor-watch.*' 2>/dev/null)" ] \
    || fail "temp file littered the config dir"
  pass "add: captures identity into the version-1 schema atomically"
}

test_add_refuses_duplicate_and_wrong_workspace() {
  hw_env add-dup
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  local out rc
  out=$(hw_run add --workspace OpenCode --surface SF-1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate add succeeded"
  assert_contains "$out" "already in the watch list" "duplicate add names the existing entry"
  out=$(hw_run add --workspace Wrong --surface SF-2 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "wrong-workspace add succeeded"
  assert_contains "$out" "lives in workspace 'OpenCode'" "wrong-workspace add names the real workspace"
  pass "add: refuses a duplicate surface and a wrong workspace title"
}

test_usage_guards() {
  hw_env usage
  local rc
  hw_run add --workspace OpenCode >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "add without --surface"
  hw_run remove >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "remove without id"
  hw_run sweep extra >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "sweep with an argument"
  hw_run bogus >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "unknown verb"
  pass "usage: missing args and unknown verbs error instead of no-oping"
}

# --- sweep detection, dedupe, and redaction --------------------------------------

test_sweep_escalates_once_and_rearms() {
  hw_env sweep-dedupe
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "permission watch=${SF1_ID} tab=\"OpenCode › OC tab\"" "first sweep emits the permission event"
  assert_contains "$out" "Do you want to proceed?" "event carries the dialog's own text"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "expected exactly one event line: $out"
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "second sweep re-fired a still-pending prompt: $out"
  cp "$FIX/idle.txt" "$FX/screen.txt"
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "cleared prompt still produced output: $out"
  cp "$FIX/permission.txt" "$FX/screen.txt"
  out=$(hw_run sweep)
  assert_contains "$out" "permission watch=${SF1_ID}" "a prompt that cleared and returned re-fires"
  pass "sweep: one line per new event, deduped while pending, re-armed after clearing"
}

test_sweep_busy_tab_stays_silent_despite_notification() {
  hw_env sweep-busy
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  cp "$FIX/busy.txt" "$FX/screen.txt"
  printf '0:N-1|WS-1|SF-1|unread|Claude Code|Permission|Claude needs your permission|2026-07-25T00:00:00Z|pct:OpenCode\n' > "$FX/notifs.txt"
  local out
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "busy tab with stale notification escalated: $out"
  pass "sweep: a visibly-working tab never escalates on a stale notification"
}

test_sweep_waiting_from_unread_notification() {
  hw_env sweep-waiting
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  cp "$FIX/idle.txt" "$FX/screen.txt"
  printf '0:N-1|WS-1|SF-1|unread|Claude Code|Waiting|Claude is waiting for your input|2026-07-25T00:00:00Z|pct:OpenCode\n' > "$FX/notifs.txt"
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "waiting watch=${SF1_ID}" "unread Waiting notification escalates an idle tab"
  assert_contains "$out" "waiting for your input" "waiting event carries the notification message"
  pass "sweep: unread Waiting notification + idle screen -> waiting event"
}

test_sweep_waiting_suppressed_while_captain_types() {
  hw_env sweep-typing
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  cp "$FIX/typing.txt" "$FX/screen.txt"
  printf '0:N-1|WS-1|SF-1|unread|Claude Code|Waiting|Claude is waiting for your input|2026-07-25T00:00:00Z|pct:OpenCode\n' > "$FX/notifs.txt"
  local out
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "waiting escalated at a captain mid-typing: $out"
  pass "sweep: a pending composer suppresses the waiting escalation"
}

test_sweep_redacts_credential_prompts() {
  hw_env sweep-cred
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  cp "$FIX/credential.txt" "$FX/screen.txt"
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "credential watch=${SF1_ID}" "credential prompt escalates"
  assert_contains "$out" "withheld" "credential event says the text is withheld"
  assert_not_contains "$out" "SECRETMARKER" "credential event never quotes the screen"
  assert_not_contains "$out" "github.com" "credential event carries no surrounding buffer"
  pass "sweep: credential prompts escalate with the screen text withheld"
}

# --- identity rule -----------------------------------------------------------------

test_sweep_mismatch_on_moved_workspace() {
  hw_env mismatch-moved
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  echo '{"workspaces":[{"id":"WS-1","title":"Renamed"}]}' > "$FX/workspaces.json"
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "mismatch watch=${SF1_ID}" "moved tab escalates a mismatch"
  assert_contains "$out" "re-confirm" "mismatch asks for re-confirmation"
  jq -e '.watches[0].active == false' "$HOME_DIR/config/harbor-watch.json" >/dev/null \
    || fail "entry not deactivated after mismatch"
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "inactive entry still produced output: $out"
  pass "identity: workspace-title mismatch deactivates and escalates once"
}

test_sweep_mismatch_on_vanished_surface() {
  hw_env mismatch-gone
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  echo '{"surfaces":[{"id":"SF-2","title":"Other tab"}]}' > "$FX/surfaces.json"
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "mismatch watch=${SF1_ID}" "vanished surface escalates a mismatch"
  assert_contains "$out" "not found" "mismatch names the tab as gone"
  jq -e '.watches[0].active == false' "$HOME_DIR/config/harbor-watch.json" >/dev/null \
    || fail "entry not deactivated after vanish"
  pass "identity: a vanished surface uuid deactivates instead of migrating"
}

test_sweep_unreachable_cmux_deactivates_nothing() {
  hw_env unreachable
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  echo 'Socket not found' > "$FX/ping.txt"
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "cmux-unreachable" "unreachable cmux escalates"
  jq -e '.watches[0].active == true' "$HOME_DIR/config/harbor-watch.json" >/dev/null \
    || fail "unreachable cmux deactivated a watch"
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "unreachable escalation not deduped: $out"
  pass "identity: an unreachable cmux never reads as every watched tab vanishing"
}

# --- machine scoping, removal, config validation -------------------------------------

test_sweep_ignores_other_machines() {
  hw_env machine
  PATH="$FB:$PATH" FM_HW_FX="$FX" FM_HW_LOG="$LOG" \
    FM_HOME="$HOME_DIR" FM_HARBOR_MACHINE=othermac \
    "$HW" add --workspace OpenCode --surface SF-1 >/dev/null
  local out
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "another machine's watch produced output here: $out"
  pass "machine: entries recorded on another machine are not observed here"
}

test_remove_cancels_pending_escalation_state() {
  hw_env remove
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  hw_run sweep >/dev/null
  assert_grep "${SF1_ID}" "$HOME_DIR/state/.harbor-watch-reported" "dedupe entry recorded"
  local out
  out=$(hw_run remove "${SF1_ID}")
  assert_contains "$out" "removed: ${SF1_ID}" "remove confirms"
  assert_no_grep "${SF1_ID}" "$HOME_DIR/state/.harbor-watch-reported" "dedupe entry cancelled"
  jq -e '.watches | length == 0' "$HOME_DIR/config/harbor-watch.json" >/dev/null \
    || fail "entry survived removal"
  out=$(hw_run list)
  assert_contains "$out" "no watches" "list reads the emptied file"
  pass "remove: instant, and pending escalation state is cancelled with it"
}

test_sweep_escalates_invalid_config_once() {
  hw_env bad-config
  echo 'not json' > "$HOME_DIR/config/harbor-watch.json"
  local out
  out=$(hw_run sweep)
  assert_contains "$out" "config-error" "invalid watch file escalates"
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "config-error not deduped: $out"
  pass "config: an invalid watch file escalates once instead of being misread"
}

# --- check contract: arm, disarm, budget, read-only ------------------------------------

test_arm_registers_and_shim_sweeps() {
  hw_env arm
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  local out mode
  out=$(hw_run arm)
  assert_contains "$out" "registered: state/harbor-watch.check.sh" "arm registers the check"
  assert_present "$HOME_DIR/state/harbor-watch.check.sh" "shim exists"
  assert_present "$HOME_DIR/state/harbor-watch.check-trust" "trust binding exists"
  mode=$(stat -f '%Lp' "$HOME_DIR/state/harbor-watch.check.sh" 2>/dev/null \
    || stat -c '%a' "$HOME_DIR/state/harbor-watch.check.sh")
  [ "$mode" = 700 ] || fail "shim mode is $mode, not 700"
  out=$(hw_run arm)
  assert_contains "$out" "registered:" "arm is idempotent"
  out=$(PATH="$FB:$PATH" FM_HW_FX="$FX" FM_HW_LOG="$LOG" \
    FM_HOME="$HOME_DIR" FM_HARBOR_MACHINE=testmac \
    "$HOME_DIR/state/harbor-watch.check.sh")
  assert_contains "$out" "permission watch=${SF1_ID}" "the registered shim runs the sweep"
  hw_run disarm >/dev/null
  assert_absent "$HOME_DIR/state/harbor-watch.check.sh" "disarm removes the shim"
  assert_absent "$HOME_DIR/state/harbor-watch.check-trust" "disarm removes the trust binding"
  assert_absent "$HOME_DIR/state/.harbor-watch-reported" "disarm removes the dedupe ledger"
  pass "check contract: arm registers a mode-0700 shim, disarm unwinds it"
}

test_sweep_budget_truncates_loudly_and_keeps_dedupe() {
  hw_env budget
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  hw_run sweep >/dev/null
  local out
  out=$(FM_HARBOR_BUDGET_SECS=0 hw_run sweep)
  assert_contains "$out" "sweep-truncated" "over-budget sweep says so"
  assert_contains "$out" "of 1 watches" "truncation names the coverage"
  assert_not_contains "$out" "permission watch=" "no per-tab event was scanned over budget"
  out=$(hw_run sweep)
  [ -z "$out" ] || fail "dedupe lost across a truncated sweep: $out"
  pass "check contract: the sweep bounds its own runtime and keeps dedupe across truncation"
}

test_sweep_never_mutates_cmux() {
  hw_env readonly
  hw_run add --workspace OpenCode --surface SF-1 >/dev/null
  hw_run sweep >/dev/null
  cp "$FIX/idle.txt" "$FX/screen.txt"
  printf '0:N-1|WS-1|SF-1|unread|Claude Code|Waiting|Claude is waiting for your input|2026-07-25T00:00:00Z|pct:OpenCode\n' > "$FX/notifs.txt"
  hw_run sweep >/dev/null
  echo '{"workspaces":[{"id":"WS-1","title":"Renamed"}]}' > "$FX/workspaces.json"
  hw_run sweep >/dev/null
  if grep -qE '^(send|send-key|send-text|focus|select|rename|close|dismiss|mark|clear)' "$LOG"; then
    fail "the sweep invoked a mutating cmux verb: $(grep -E '^(send|send-key|send-text|focus|select|rename|close|dismiss|mark|clear)' "$LOG")"
  fi
  pass "read-only: no sweep path ever invokes a mutating cmux verb"
}

# --- run ------------------------------------------------------------------------

test_classify_permission_dialog
test_classify_picker_is_decision
test_classify_busy_beats_stale_notification
test_classify_credential_prompt
test_classify_waiting_needs_unread_notif
test_classify_error_beside_idle_prompt
test_add_writes_schema_atomically
test_add_refuses_duplicate_and_wrong_workspace
test_usage_guards
test_sweep_escalates_once_and_rearms
test_sweep_busy_tab_stays_silent_despite_notification
test_sweep_waiting_from_unread_notification
test_sweep_waiting_suppressed_while_captain_types
test_sweep_redacts_credential_prompts
test_sweep_mismatch_on_moved_workspace
test_sweep_mismatch_on_vanished_surface
test_sweep_unreachable_cmux_deactivates_nothing
test_sweep_ignores_other_machines
test_remove_cancels_pending_escalation_state
test_sweep_escalates_invalid_config_once
test_arm_registers_and_shim_sweeps
test_sweep_budget_truncates_loudly_and_keeps_dedupe
test_sweep_never_mutates_cmux
