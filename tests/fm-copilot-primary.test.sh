#!/usr/bin/env bash
# Behavior tests for GitHub Copilot CLI as a firstmate PRIMARY
# (docs/turnend-guard.md, docs/sessionstart-nudge.md,
# docs/supervision-protocols/copilot.md).
#
# Hermetic over temp dirs with real processes and NO Copilot installed, so CI
# enforces them everywhere:
#   HOST GUARD   - bin/fm-hook-host-lib.sh's structural Copilot predicate, and
#                  each tracked Claude-shaped entrypoint Copilot also runs
#                  standing down when Copilot itself started it, while the
#                  PreToolUse seatbelt keeps denying there.
#   TURN END     - bin/fm-turnend-guard-copilot.sh rendering the shared guard's
#                  block as Copilot's agentStop decision object.
#   SESSION      - bin/fm-sessionstart-copilot.sh carrying the digest as
#                  additionalContext.
#   REGISTRATION - the tracked .github/hooks commands, run as Copilot runs them.
#   LOCK         - the session lock resolving to the Copilot process.
#
# Hooks run as children of a fake harness: a compiled executable whose own
# canonical name is copilot (or claude, for the controls), because a symlink to
# bash reads as bash on Linux. It runs its command through bash -c exactly as
# Copilot starts a hook command, so an `exec` in that command leaves the fake
# harness as the entrypoint's parent. Every stand-down case runs the same input
# under a non-Copilot parent as well and asserts the verdicts diverge, so the
# case cannot pass because the entrypoint was inert anyway.
# tests/fm-copilot-primary-live-e2e.test.sh is the opt-in guard against a real
# Copilot CLI. Neither replaces the other.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  COPILOT_CLI COPILOT_PROJECT_DIR FM_SUPERVISION_ACTOR FM_SUPERVISION_PRIMARY_HARNESS \
  FM_ARM_CONFIRM_TIMEOUT

TMP_ROOT=$(fm_test_tmproot fm-copilot-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake harness processes"
cat > "$TMP_ROOT/fake-harness.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
mkdir -p "$FAKEBIN/decoy"
"$CC_BIN" -o "$FAKEBIN/copilot" "$TMP_ROOT/fake-harness.c" \
  || fail "could not build the fake Copilot process"
cp "$FAKEBIN/copilot" "$FAKEBIN/claude"
cp "$FAKEBIN/copilot" "$FAKEBIN/decoy/copilot-language-server"
FAKE_COPILOT="$FAKEBIN/copilot"
FAKE_CLAUDE="$FAKEBIN/claude"
FAKE_DECOY="$FAKEBIN/decoy/copilot-language-server"

# The Claude-shaped Stop payload Copilot delivers to the tracked Claude
# settings, and its own native agentStop payload (both verified live, Copilot
# CLI 1.0.88).
CLAUDE_SHAPED_STOP='{"hook_event_name":"Stop","session_id":"sess-copilot","timestamp":"2026-09-26T15:02:13.102Z","cwd":"/x","transcript_path":"/x/.copilot/session-state/sess-copilot/events.jsonl","stop_reason":"end_turn","stop_hook_active":false}'
native_stop() {  # <stop_hook_active>
  printf '{"sessionId":"sess-copilot","timestamp":1790434884519,"cwd":"/x","transcriptPath":"/x/events.jsonl","stopReason":"end_turn","stop_hook_active":%s}' "$1"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  cp -R "$ROOT/.github" "$dir/.github"
  printf '%s\n' "$dir"
}

# One code root shared by the read-only cases; cases that rewrite a script get
# their own copy.
SHARED=$(make_primary_dir "$TMP_ROOT/shared")

need_supervision() {  # <dir>
  : > "$1/state/task1.meta"
}

# An arm fixture standing in for bin/fm-watch-arm.sh that records every run.
write_arm_fixture() {  # <dir>
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win needs a look\n'
exit 0
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

# Run <command> through bash -c as a child of <harness>, holding the home lock
# as that harness process first, the way a live session does.
under() {  # <harness-bin> <dir> <command>
  local bin=$1 dir=$2 command=$3
  FM_HOME="$dir" "$bin" -c "printf '%s\\n' \"\$PPID\" > \"\$FM_HOME/state/.lock\"; $command"
}

# --- HOST GUARD --------------------------------------------------------------

test_turnend_guard_stands_down_when_copilot_runs_the_claude_entry() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-turnend")
  need_supervision "$dir"

  out=$(printf '%s' "$CLAUDE_SHAPED_STOP" | under "$FAKE_COPILOT" "$dir" \
    'exec "$FM_HOME/bin/fm-turnend-guard.sh" --claude' 2>&1); status=$?
  expect_code 0 "$status" "the Claude Stop entry Copilot runs must not act on Copilot's turn end"
  [ -z "$out" ] || fail "the Copilot-run Claude entry produced output: $out"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "the Copilot-run Claude entry charged the Claude block budget"

  out=$(printf '%s' "$CLAUDE_SHAPED_STOP" | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 under "$FAKE_CLAUDE" "$dir" \
    'exec "$FM_HOME/bin/fm-turnend-guard.sh" --claude' 2>&1); status=$?
  expect_code 2 "$status" "the same payload under a Claude parent must still block (the stand-down is otherwise vacuous)"

  out=$(native_stop false | under "$FAKE_COPILOT" "$dir" \
    'exec "$FM_HOME/bin/fm-turnend-guard.sh" --copilot' 2>&1); status=$?
  expect_code 2 "$status" "--copilot must reach the shared block decision when Copilot is the parent"
  assert_contains "$out" 'TURN WOULD END BLIND' "the --copilot block lost the shared banner"
  pass "fm-turnend-guard: the Claude entry stands down under Copilot, and --copilot still blocks"
}

test_autoarm_stands_down_when_copilot_runs_the_claude_entry() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/host-autoarm")
  need_supervision "$dir"
  write_arm_fixture "$dir"
  printf '%s' "$CLAUDE_SHAPED_STOP" | under "$FAKE_COPILOT" "$dir" \
    'exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "the Claude auto-arm must stay inert under Copilot"
  [ ! -e "$dir/state/arm-ran" ] \
    || fail "the Claude auto-arm armed under Copilot, which awaits it and would hold the turn open for its multi-hour timeout"

  # Control: under a Claude parent that owns the lock, the same entry arms.
  printf '%s' "$CLAUDE_SHAPED_STOP" | under "$FAKE_CLAUDE" "$dir" \
    'exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1
  [ -e "$dir/state/arm-ran" ] \
    || fail "the auto-arm never armed under its own Claude parent either, so the Copilot case proves nothing"
  pass "fm-claude-stop-autoarm: inert under Copilot, arming under Claude"
}

test_sessionstart_run_stands_down_when_copilot_runs_the_claude_entry() {
  local dir out payload
  dir=$(make_primary_dir "$TMP_ROOT/host-sessionstart")
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/digest-ran"
printf 'DIGEST BODY\n'
SH
  chmod +x "$dir/bin/fm-session-start.sh"
  payload='{"hook_event_name":"SessionStart","session_id":"s","timestamp":"2026-09-26T15:02:08.492Z","cwd":"/x","source":"new"}'
  out=$(printf '%s' "$payload" | under "$FAKE_COPILOT" "$dir" 'exec "$FM_HOME/bin/fm-sessionstart-run.sh"' 2>&1)
  [ -z "$out" ] || fail "the Claude SessionStart entry ran the digest under Copilot: $out"
  [ ! -e "$dir/state/digest-ran" ] || fail "the Claude SessionStart entry took the helm under Copilot"
  out=$(printf '%s' "$payload" | under "$FAKE_CLAUDE" "$dir" 'exec "$FM_HOME/bin/fm-sessionstart-run.sh"' 2>&1)
  assert_contains "$out" 'DIGEST BODY' "the same entry under Claude must still run the digest"
  pass "fm-sessionstart-run: inert under Copilot, unchanged under Claude"
}

test_pretool_seatbelt_keeps_denying_under_copilot() {
  local out status payload
  payload='{"hook_event_name":"PreToolUse","session_id":"s","timestamp":"2026-09-26T15:02:11.278Z","cwd":"/x","tool_name":"Bash","tool_input":{"command":"bin/fm-watch-arm.sh &","description":"arm"}}'
  out=$(printf '%s' "$payload" | under "$FAKE_COPILOT" "$SHARED" \
    'exec "$FM_HOME/bin/fm-arm-pretool-check.sh" --claude' 2>&1); status=$?
  expect_code 2 "$status" "Copilot honors a PreToolUse exit 2, so the seatbelt must keep denying there"
  assert_contains "$out" 'permissionDecision' "the deny lost its Claude-shaped reason object"
  pass "fm-arm-pretool-check: the tracked seatbelt still denies an unsafe arm under Copilot"
}

test_decoy_parent_is_not_copilot() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/host-decoy")
  need_supervision "$dir"
  printf '%s' "$CLAUDE_SHAPED_STOP" | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 under "$FAKE_DECOY" "$dir" \
    'exec "$FM_HOME/bin/fm-turnend-guard.sh" --claude' >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "copilot-language-server as the parent must not stand the Claude entry down"
  pass "fm-hook-host-lib: only an exact copilot parent counts"
}

# --- TURN END ----------------------------------------------------------------

adapter() {  # <dir> <payload>
  printf '%s' "$2" | under "$FAKE_COPILOT" "$1" 'exec "$FM_HOME/bin/fm-turnend-guard-copilot.sh"'
}

test_adapter_blocks_as_a_typed_decision() {
  local dir out status reason
  dir=$(make_primary_dir "$TMP_ROOT/adapter-block")
  need_supervision "$dir"
  out=$(adapter "$dir" "$(native_stop false)" 2>/dev/null); status=$?
  expect_code 0 "$status" "Copilot reads the decision object, so the adapter always exits 0"
  [ "$(printf '%s' "$out" | jq -r '.decision')" = block ] || fail "expected a block decision object, got: $out"
  reason=$(printf '%s' "$out" | jq -r '.reason')
  [ "$(printf '%s' "$reason" | "$ROOT/bin/fm-operational-input.sh" kind)" = turn-end-guard ] \
    || fail "the forced prompt must be a typed turn-end-guard input so it is never read as the captain: $reason"
  assert_contains "$reason" 'TURN WOULD END BLIND' "the block reason lost the shared banner"
  assert_contains "$reason" 'Copilot bash call in mode async' "the block reason must carry Copilot's own repair line"
  pass "copilot adapter: a blind turn end becomes one typed block decision"
}

test_adapter_bounds_and_fail_open() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/adapter-bounds")
  need_supervision "$dir"
  out=$(adapter "$dir" "$(native_stop true)" 2>&1); status=$?
  expect_code 0 "$status" "the stop after a forced continuation must end"
  [ -z "$out" ] || fail "the adapter blocked a stop that already follows a forced continuation: $out"
  for payload in '' 'not json' '{"stop_hook_active":"yes"}'; do
    out=$(adapter "$dir" "$payload" 2>&1); status=$?
    expect_code 0 "$status" "an unreadable payload must let the turn end ($payload)"
    [ -z "$out" ] || fail "an unreadable payload produced a decision ($payload): $out"
  done
  rm -f "$dir/state/task1.meta"
  out=$(adapter "$dir" "$(native_stop false)" 2>&1)
  [ -z "$out" ] || fail "the adapter blocked a home with nothing to supervise: $out"
  pass "copilot adapter: one continuation per turn, silent without need, fail-open on bad input"
}

# --- SESSION -----------------------------------------------------------------

test_sessionstart_adapter_carries_the_digest() {
  local dir out payload
  dir=$(make_primary_dir "$TMP_ROOT/session")
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'DIGEST %s\n' "$*"
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh"
  for payload in '{"source":"new"}|--source startup' '{"source":"resume"}|--source resume' \
    '{}|--source startup' 'not json|--source startup'; do
    out=$(printf '%s' "${payload%%|*}" | under "$FAKE_COPILOT" "$dir" 'exec "$FM_HOME/bin/fm-sessionstart-copilot.sh"')
    [ "$(printf '%s' "$out" | jq -r '.additionalContext' 2>/dev/null)" = "DIGEST ${payload#*|}" ] \
      || fail "payload ${payload%%|*} must deliver the digest for ${payload#*|} as additionalContext, got: $out"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/fm-sessionstart-run.sh"
  out=$(printf '{"source":"new"}' | under "$FAKE_COPILOT" "$dir" 'exec "$FM_HOME/bin/fm-sessionstart-copilot.sh"')
  [ -z "$out" ] || fail "an empty digest must print nothing, got: $out"
  pass "copilot session start: the digest arrives as additionalContext with the right source"
}

# --- REGISTRATION ------------------------------------------------------------

registered_command() {  # <file> <event>
  jq -r --arg e "$2" '.version as $v | select($v == 1) | .hooks[$e][0].bash' "$ROOT/.github/hooks/$1"
}

test_registrations_run_the_adapters_through_the_logical_path() {
  local real link cmd event file out
  real="$TMP_ROOT/anchor/real-home"
  link="$TMP_ROOT/anchor/link-home"
  mkdir -p "$real/bin" "$real/sub"
  ln -s "$real" "$link"
  for pair in fm-primary-turnend-guard.json:agentStop:fm-turnend-guard-copilot.sh \
    fm-primary-sessionstart.json:sessionStart:fm-sessionstart-copilot.sh; do
    file=${pair%%:*}
    event=${pair#*:}
    event=${event%%:*}
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0"\n' > "$real/bin/${pair##*:}"
    chmod +x "$real/bin/${pair##*:}"
    cmd=$(registered_command "$file" "$event")
    [ -n "$cmd" ] || fail "$file registers no $event command"

    out=$(cd "$link" && COPILOT_PROJECT_DIR=$(cd "$real" && pwd -P) "$FAKE_COPILOT" -c "$cmd")
    [ "$out" = "$link/bin/${pair##*:}" ] \
      || fail "$event must run its adapter through the session's own path spelling $link, got: $out"
    out=$(cd "$link/sub" && COPILOT_PROJECT_DIR=$(cd "$real" && pwd -P) "$FAKE_COPILOT" -c "$cmd")
    [ "$out" = "$(cd "$real" && pwd -P)/bin/${pair##*:}" ] \
      || fail "$event must fall back to Copilot's project dir when its cwd is elsewhere, got: $out"
    out=$(cd "$link" && env -u COPILOT_PROJECT_DIR "$FAKE_COPILOT" -c "$cmd");
    [ -z "$out" ] || fail "$event must stay inert without Copilot's project dir, got: $out"
  done
  pass "copilot registrations: each hook runs its adapter through the session's own path"
}

# The logical spelling matters because the watcher lock records paths as
# strings: a guard anchored on the physical path of a home reached through a
# symlink would read a healthy watcher as down.
test_turnend_registration_sees_a_watcher_armed_through_a_symlink() {
  local real link cmd out control
  real=$(make_primary_dir "$TMP_ROOT/anchor-watch/real")
  link="$TMP_ROOT/anchor-watch/link"
  ln -s "$real" "$link"
  need_supervision "$real"
  mkdir -p "$real/state/.watch.lock"
  # A live stand-in watcher process identity-recorded the way the arm records it.
  sleep 300 &
  local watcher=$!
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  printf '%s\n' "$watcher" > "$real/state/.watch.lock/pid"
  printf '%s\n' "$link" > "$real/state/.watch.lock/fm-home"
  printf '%s\n' "$link/bin/fm-watch.sh" > "$real/state/.watch.lock/watcher-path"
  fm_pid_identity "$watcher" > "$real/state/.watch.lock/pid-identity"
  touch "$real/state/.last-watcher-beat"
  cmd=$(registered_command fm-primary-turnend-guard.json agentStop)
  out=$(native_stop false | (cd "$link" && FM_HOME="$link" COPILOT_PROJECT_DIR=$(cd "$real" && pwd -P) \
    "$FAKE_COPILOT" -c "$cmd") 2>&1)
  # Control: the same guard reached through the physical spelling reads the
  # same healthy watcher as down, which is the failure the anchor prevents.
  control=$(native_stop false | FM_HOME="$link" "$FAKE_COPILOT" -c "exec '$(cd "$real" && pwd -P)/bin/fm-turnend-guard-copilot.sh'" 2>&1)
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  [ -z "$out" ] || fail "a healthy watcher armed through the symlinked home read as down: $out"
  [ "$(printf '%s' "$control" | jq -r '.decision' 2>/dev/null)" = block ] \
    || fail "the physical-path control should have blocked, so this case proves nothing: $control"
  pass "copilot turn end: a watcher armed through a symlinked home is recognized"
}

# --- LOCK --------------------------------------------------------------------

test_session_lock_resolves_to_the_copilot_process() {
  local dir recorded status_line
  dir=$(make_primary_dir "$TMP_ROOT/lock")
  recorded=$(FM_HOME="$dir" "$FAKE_COPILOT" -c '
    "$FM_HOME/bin/fm-lock.sh" >/dev/null 2>&1 || exit 3
    printf "%s|%s" "$PPID" "$(head -1 "$FM_HOME/state/.lock")"
  ')
  [ -n "${recorded%%|*}" ] && [ "${recorded%%|*}" = "${recorded#*|}" ] \
    || fail "the session lock must be held by the Copilot process itself (parent|lock = $recorded)"
  status_line=$(FM_HOME="$dir" "$FAKE_COPILOT" -c '
    printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-lock.sh" status
  ')
  assert_contains "$status_line" 'held by live harness pid' "a live Copilot lock holder must read as a harness"
  recorded=$(FM_HOME="$dir" "$FAKE_DECOY" -c '
    rm -f "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-lock.sh" >/dev/null 2>&1
    printf "%s|%s" "$PPID" "$(head -1 "$FM_HOME/state/.lock" 2>/dev/null)"
  ')
  [ "${recorded%%|*}" != "${recorded#*|}" ] \
    || fail "copilot-language-server must never be taken as the session's harness"
  pass "session lock: a Copilot session holds its own home lock, anchored by exact name"
}

test_turnend_guard_stands_down_when_copilot_runs_the_claude_entry
test_autoarm_stands_down_when_copilot_runs_the_claude_entry
test_sessionstart_run_stands_down_when_copilot_runs_the_claude_entry
test_pretool_seatbelt_keeps_denying_under_copilot
test_decoy_parent_is_not_copilot
test_adapter_blocks_as_a_typed_decision
test_adapter_bounds_and_fail_open
test_sessionstart_adapter_carries_the_digest
test_registrations_run_the_adapters_through_the_logical_path
test_turnend_registration_sees_a_watcher_armed_through_a_symlink
test_session_lock_resolves_to_the_copilot_process
