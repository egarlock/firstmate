#!/usr/bin/env bash
# tests/fm-backend-cmux-smoke.test.sh - real cmux smoke test for the cmux
# session-provider adapter (bin/backends/cmux.sh), verified against the real
# cmux 0.64.17 binary (docs/cmux-backend.md). Mirrors
# tests/fm-backend-zellij-smoke.test.sh's/fm-backend-herdr-smoke.test.sh's
# structure: every other suite fakes the CLI, this one talks to the REAL app -
# but unlike herdr/zellij there is no isolated throwaway SESSION to spin up:
# cmux is one shared, GUI-first, macOS-only instance (the same posture as
# Orca). So this test creates ONLY `fm-test-`-prefixed task labels, touches and
# closes ONLY what it created, never enumerates-and-closes, never quits or
# relaunches the app, and cleans up every artifact via
# tests/cmux-test-safety.sh's guarded closes. The adapter turns those plain
# labels into home-scoped cmux workspace titles internally.
#
# Tab-mode coverage: the tab leg hosts its task tab inside a workspace this
# test itself creates, never the captain's own, and exercises the real
# focused-create + transactional focus restore end to end - expect one brief
# focus flicker while it runs, the same flicker a real tab-mode spawn
# produces (docs/cmux-backend.md "Tab creation requires focus at birth").
#
# Skips cleanly when cmux (or jq) is not installed/reachable, so CI/dev
# machines without cmux, or without the one-time password-mode setup
# (docs/cmux-backend.md "Setup"), are unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source cmux || { echo "skip: could not source the cmux adapter"; exit 0; }

fm_backend_cmux_tool_check >/dev/null 2>&1 || { echo "skip: cmux CLI not found on PATH or at the bundle path"; exit 0; }
fm_backend_cmux_version_check >/dev/null 2>&1 || { echo "skip: installed cmux is older than the verified minimum"; exit 0; }
PING_STATE=$(fm_backend_cmux_ping_state)
[ "$PING_STATE" = ok ] || { echo "skip: cmux socket not reachable/authenticated (state=$PING_STATE) - see docs/cmux-backend.md 'Setup'"; exit 0; }

# shellcheck source=tests/cmux-test-safety.sh
. "$ROOT/tests/cmux-test-safety.sh"

WS1=""
WS2=""
WS_H=""
TAB_SF=""
WS_M=""
WS_M_TITLE=""
SM_SCRATCH=""
cleanup_all() {
  [ -z "$TAB_SF" ] || cmux_safe_close_surface "$WS_H" "$TAB_SF" "fm-test-tabtask"
  [ -z "$WS_H" ] || cmux_safe_close_workspace "$WS_H" "fm-test-tabhost"
  [ -z "$WS1" ] || cmux_safe_close_workspace "$WS1" "fm-test-smoke1"
  [ -z "$WS2" ] || cmux_safe_close_workspace "$WS2" "fm-test-smoke2"
  [ -z "$WS_M" ] || cmux_safe_close_secondmate_workspace "$WS_M" "$WS_M_TITLE"
  [ -z "$SM_SCRATCH" ] || rm -rf "$SM_SCRATCH"
}
trap cleanup_all EXIT

# --- create_task + duplicate refusal -----------------------------------------

LABEL="fm-test-smoke1"
TASK_IDS=$(fm_backend_cmux_create_task workspace "$LABEL" /tmp) || fail "create_task failed"
read -r WS1 SF1 <<EOF
$TASK_IDS
EOF
if [ -z "$WS1" ] || [ -z "$SF1" ]; then
  fail "create_task did not return workspace/surface ids"
fi
TARGET="$WS1:$SF1"

if fm_backend_cmux_create_task workspace "$LABEL" /tmp >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate workspace title (cmux itself does not enforce uniqueness)"
fi
pass "real cmux: create_task creates a workspace/surface and refuses a duplicate title"

fm_backend_cmux_send_key "$TARGET" Escape "$LABEL" \
  || fail "send_key with a matching expected task label should succeed"
if fm_backend_cmux_send_key "$TARGET" Escape "fm-test-not-$LABEL" >/dev/null 2>&1; then
  fail "send_key with a mismatched expected task label should fail"
fi
pass "real cmux: expected task label verification accepts the matching workspace and rejects a mismatch"

# --- send_literal + send_key(Enter), the two-step submit form ---------------

fm_backend_cmux_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.3
fm_backend_cmux_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.5
out=$(fm_backend_cmux_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real cmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real cmux: send_literal (unsubmitted) + send_key Enter submit as two steps and the output is capturable"

# --- send_text_line (the composed form) --------------------------------------

fm_backend_cmux_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.5
out=$(fm_backend_cmux_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real cmux: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real cmux: send_text_line composes send+Enter and its output is capturable"

# --- current_path: verified zellij-shape frozen cwd --------------------------

fm_backend_cmux_send_text_line "$TARGET" "cd /tmp"
sleep 0.3
p=$(fm_backend_cmux_current_path "$TARGET") || fail "current_path failed"
case "$p" in
  */tmp) : ;;
  *) fail "real cmux: current_path did not report the surface's cwd after a direct cd, got '$p'" ;;
esac
pass "real cmux: current_path reads the surface's live cwd after a direct cd"

# The load-bearing case: a NESTED SUBSHELL's own cd (exactly what `treehouse
# get` does). Verified real finding (docs/cmux-backend.md finding #2):
# current_directory stays frozen at wherever the surface's shell was when it
# launched the subshell as a foreground command - it never follows the
# subshell's own cd. fm_backend_cmux_current_path's active pwd-probe is what
# fm-spawn.sh's worktree-discovery poll actually depends on, so this must be
# proven against a real subshell, not just a plain cd in the top-level shell.
fm_backend_cmux_send_text_line "$TARGET" 'cd / && bash'
sleep 0.5
fm_backend_cmux_send_text_line "$TARGET" "cd /private/tmp"
sleep 0.3
p2=$(fm_backend_cmux_current_path "$TARGET") || fail "current_path failed inside a nested subshell"
case "$p2" in
  */private/tmp|*/tmp) : ;;
  *) fail "real cmux: current_path did not track a nested subshell's own cd (the treehouse-get-shaped case), got '$p2'" ;;
esac
pass "real cmux: current_path tracks a NESTED SUBSHELL's own cd (the treehouse-get-shaped case a bare cwd read cannot see)"
fm_backend_cmux_send_text_line "$TARGET" 'exit'
sleep 0.3

# --- key names: Escape and Ctrl-C, verified names --------------------------

fm_backend_cmux_send_key "$TARGET" Escape || fail "send_key Escape failed"
pass "real cmux: send_key Escape (natively supported, unlike Orca) succeeds"

fm_backend_cmux_send_key "$TARGET" C-c || fail "send_key C-c (normalized to 'ctrl-c') failed"
pass "real cmux: send_key C-c (normalized to the verified 'ctrl-c' name) succeeds"

# --- busy_state: always unknown (no native agent-state primitive) -----------

bs=$(fm_backend_busy_state cmux "$TARGET")
[ "$bs" = unknown ] || fail "fm_backend_busy_state should report unknown for cmux (no native primitive), got '$bs'"
pass "real cmux: fm_backend_busy_state reports unknown (watcher falls back to pane-regex, same as tmux/zellij/orca)"

# --- window_of_workspace: real-cmux window/count detection -------------------
# The last-workspace-in-a-window teardown fix (docs/cmux-backend.md "Closing the
# last workspace in a window") pivots on window_of_workspace reading the live
# `list-windows` / `workspace list --window` JSON correctly (the version-fragile
# part the fake-CLI suite cannot prove). This task workspace shares its window
# with at least the app's own workspace, so it reports "<window_id> <count>"
# with a count of two or more. The last-in-window branch itself is proven end to
# end in the fake-CLI suite and in this document's manual verification record;
# it is not driven live here because closing the last workspace inherently
# leaves a window cmux cannot close over the control socket.
WININFO=$(fm_backend_cmux_window_of_workspace "$WS1")
case "$WININFO" in
  *' '[0-9]*) : ;;
  *) fail "window_of_workspace did not report '<window_id> <count>' for a live task workspace, got '$WININFO'" ;;
esac
WCOUNT=${WININFO##* }
[ "$WCOUNT" -ge 2 ] 2>/dev/null \
  || fail "task workspace shares its window with the app default, so the count should be >= 2, got '$WININFO'"
pass "real cmux: window_of_workspace locates a task workspace's window and counts its workspaces"

# --- kill: whole-workspace close ----------------------------------------------

fm_backend_cmux_kill "$TARGET"
sleep 0.5
STILL_LIVE=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$WS1" '.workspaces[]? | select(.id == $id) | .id' 2>/dev/null)
[ -z "$STILL_LIVE" ] || fail "kill did not remove the whole task workspace"
WS1=""
# Best-effort contract: killing an already-gone target must not error.
fm_backend_cmux_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real cmux: kill removes the whole workspace and is idempotent/best-effort"

# --- list_live (title-based recovery discovery) ------------------------------

LABEL2="fm-test-smoke2"
TASK_IDS2=$(fm_backend_cmux_create_task workspace "$LABEL2" /tmp) || fail "second create_task failed"
read -r WS2 _SF2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_cmux_list_live)
case "$live" in
  *"$LABEL2"*) : ;;
  *) fail "list_live did not report the freshly created task workspace by title"$'\n'"--- got ---"$'\n'"$live" ;;
esac
pass "real cmux: list_live discovers a live task workspace by fm-<id> title"

# --- tab mode: focused create + transactional restore, ops, kill --------------
# The tab is created in a HOST workspace this test itself creates (never in
# the captain's own workspace), so every artifact stays fm-test- scoped. The
# create still exercises the real focus machinery end to end: it captures the
# captain's live focused context, creates the tab focused (the 0.64.18+
# unfocused-surface realization workaround), and transactionally restores the
# prior focus - expect one brief focus flicker, exactly what a real tab-mode
# spawn produces.

LABEL_H="fm-test-tabhost"
TASK_IDS_H=$(fm_backend_cmux_create_task workspace "$LABEL_H" /tmp) || fail "tab-host create_task failed"
read -r WS_H SF_H <<EOF
$TASK_IDS_H
EOF
[ -n "$WS_H" ] && [ -n "$SF_H" ] || fail "tab-host create_task did not return workspace/surface ids"

LABEL_T="fm-test-tabtask"
TAB_IDS=$(fm_backend_cmux_create_task "$WS_H" "$LABEL_T" /tmp) || fail "tab-mode create_task failed"
read -r TAB_WS TAB_SF <<EOF
$TAB_IDS
EOF
[ "$TAB_WS" = "$WS_H" ] || fail "tab-mode create_task should create the tab inside the given container workspace (got ws '$TAB_WS')"
[ -n "$TAB_SF" ] && [ "$TAB_SF" != "$SF_H" ] || fail "tab-mode create_task did not return a distinct new surface id"
TARGET_T="$TAB_WS:$TAB_SF"
pass "real cmux: tab-mode create_task creates a focused tab in the container, restores focus, and returns '<ws> <surface>'"

TAB_TITLE=$(fm_backend_cmux_scoped_title "$LABEL_T")
listed=$(fm_backend_cmux_cli list-pane-surfaces --workspace "$WS_H" --json --id-format uuids 2>/dev/null \
  | jq -r --arg id "$TAB_SF" '.surfaces[]? | select(.id == $id) | .title')
[ "$listed" = "$TAB_TITLE" ] || fail "the new tab is not carrying its scoped title (got '${listed:-<none>}', want '$TAB_TITLE')"
pass "real cmux: the task tab carries its scoped fm-<home>-<id> title (sticky rename)"

if fm_backend_cmux_create_task "$WS_H" "$LABEL_T" /tmp >/dev/null 2>&1; then
  fail "tab-mode create_task should refuse a duplicate scoped tab title"
fi
pass "real cmux: tab-mode create_task refuses a duplicate scoped tab title"

fm_backend_cmux_send_text_line "$TARGET_T" 'echo tab-probe-on-deck' "$LABEL_T" \
  || fail "send_text_line into the task tab (with label verification) failed"
sleep 0.5
out_t=$(fm_backend_cmux_capture "$TARGET_T" 20 "$LABEL_T") || fail "capture from the task tab failed"
case "$out_t" in
  *tab-probe-on-deck*) : ;;
  *) fail "real cmux: the tab's send_text_line output was not capturable"$'\n'"$out_t" ;;
esac
pass "real cmux: label-verified send and capture work against the task tab"

p_t=$(fm_backend_cmux_current_path "$TARGET_T" "$LABEL_T") || fail "current_path failed for the task tab"
case "$p_t" in
  */tmp) : ;;
  *) fail "real cmux: tab current_path should report the tab's own cwd (cd'd to /tmp at create), got '$p_t'" ;;
esac
pass "real cmux: current_path reports the task tab's own cwd (passive tiers), not the container's"

live2=$(fm_backend_cmux_list_live)
case "$live2" in
  *"$LABEL_T"*) : ;;
  *) fail "list_live did not report the live task tab by scoped surface title"$'\n'"--- got ---"$'\n'"$live2" ;;
esac
pass "real cmux: list_live discovers a live task tab (tab arm) alongside task workspaces"

fm_backend_cmux_kill "$TARGET_T" "" "$LABEL_T"
sleep 0.5
still_tab=$(fm_backend_cmux_cli list-pane-surfaces --workspace "$WS_H" --json --id-format uuids 2>/dev/null \
  | jq -r --arg id "$TAB_SF" '.surfaces[]? | select(.id == $id) | .id')
[ -z "$still_tab" ] || fail "tab-mode kill did not close the task's surface"
host_alive=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
  | jq -r --arg id "$WS_H" '.workspaces[]? | select(.id == $id) | .id')
[ -n "$host_alive" ] || fail "tab-mode kill must close ONLY the surface - the container workspace vanished"
TAB_SF=""
pass "real cmux: tab-mode kill closes only the task's surface and leaves the container workspace alive"

# --- secondmate support: dedicated workspace, title sync, recovery, kill ------
# Everything here is scoped to a scratch home whose marker id carries the
# test- prefix, so the mate workspace's initial title is fm-2ndmate-test-*
# and the guarded secondmate close applies (tests/cmux-test-safety.sh). No
# real agent is launched; the mate's tab holds only its login shell.

SM_SCRATCH=$(mktemp -d /tmp/fm-cmux-sm-smoke.XXXXXX)
SM_ID="test-smk$$"
SM_HOME="$SM_SCRATCH/home"
mkdir -p "$SM_HOME/bin" "$SM_HOME/data" "$SM_HOME/state"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf '# Firstmate\n' > "$SM_HOME/AGENTS.md"
SM_HOME_REAL=$(cd "$SM_HOME" && pwd -P)

SM_IDS=$(fm_backend_cmux_create_secondmate "$SM_HOME_REAL" "fm-$SM_ID") || fail "create_secondmate failed"
read -r WS_M SF_M WS_M_TITLE <<EOF
$SM_IDS
EOF
[ -n "$WS_M" ] && [ -n "$SF_M" ] && [ -n "$WS_M_TITLE" ] \
  || fail "create_secondmate did not return '<ws> <sf> <title>' (got '$SM_IDS')"
case "$WS_M_TITLE" in
  fm-2ndmate-test-*) : ;;
  *) fail "the mate workspace's initial title should derive from the test- marker id, got '$WS_M_TITLE'" ;;
esac
SM_SCOPED=$(fm_backend_cmux_scoped_title "fm-$SM_ID")
sm_tab_title=$(fm_backend_cmux_cli list-pane-surfaces --workspace "$WS_M" --json --id-format uuids 2>/dev/null \
  | jq -r --arg id "$SF_M" '.surfaces[]? | select(.id == $id) | .title')
[ "$sm_tab_title" = "$SM_SCOPED" ] || fail "the mate's tab should carry the scoped title '$SM_SCOPED', got '${sm_tab_title:-<none>}'"
pass "real cmux: create_secondmate makes a dedicated workspace at the mate home with the scoped tab title"

SM_META="$SM_SCRATCH/$SM_ID.meta"
{
  printf 'window=%s:%s\n' "$WS_M" "$SF_M"
  printf 'kind=secondmate\n'
  printf 'harness=claude\n'
  printf 'backend=cmux\n'
  printf 'cmux_workspace_id=%s\n' "$WS_M"
  printf 'cmux_surface_id=%s\n' "$SF_M"
  printf 'cmux_workspace_title=%s\n' "$WS_M_TITLE"
  printf 'home=%s\n' "$SM_HOME_REAL"
} > "$SM_META"

sm_target=$(fm_backend_cmux_secondmate_resolve "$SM_META") || fail "resolve failed on a live recorded id"
[ "$sm_target" = "$WS_M:$SF_M" ] || fail "resolve should return the live recorded target, got '$sm_target'"
pass "real cmux: secondmate_resolve confirms a live recorded endpoint by id"

# A captain retitle (simulated with the CLI's own workspace rename verb) must
# sync into the meta on the next supervision touch and never break routing.
WS_M_RETITLE="fm-test-sm-retitled-$$"
fm_backend_cmux_cli workspace rename "$WS_M" --title "$WS_M_RETITLE" >/dev/null 2>&1 \
  || fail "cmux workspace rename failed (needed to simulate a captain retitle)"
WS_M_TITLE=$WS_M_RETITLE
sm_target=$(fm_backend_cmux_secondmate_resolve "$SM_META") || fail "resolve failed after a retitle"
[ "$sm_target" = "$WS_M:$SF_M" ] || fail "resolve should keep the id-primary target after a retitle, got '$sm_target'"
grep -q "^cmux_workspace_title=$WS_M_RETITLE$" "$SM_META" \
  || fail "the retitle was not synced into the meta: $(cat "$SM_META")"
pass "real cmux: a captain retitle is synced into the durable record on the next supervision touch"

# Relaunch-shaped recovery: break the recorded ids and recover by the synced
# title, then re-record the fresh (real) ids.
fm_backend_cmux_meta_update "$SM_META" \
  "window=BOGUS-WS:BOGUS-SF" "cmux_workspace_id=BOGUS-WS" "cmux_surface_id=BOGUS-SF" \
  || fail "meta_update failed"
sm_target=$(fm_backend_cmux_secondmate_resolve "$SM_META") || fail "resolve failed on stale ids"
[ "$sm_target" = "$WS_M:$SF_M" ] || fail "resolve should recover stale ids by the synced title, got '$sm_target'"
grep -q "^cmux_workspace_id=$WS_M$" "$SM_META" || fail "recovery did not re-record the live workspace id"
pass "real cmux: stale recorded ids recover by last-synced title and re-record the live ids"

# Agent liveness: wake the lazily-started terminal, then classify - a bare
# login shell must read as confidently dead (no agent was ever launched).
fm_backend_cmux_send_key "$WS_M:$SF_M" Enter || fail "wake Enter failed"
sleep 2
sm_alive=$(fm_backend_cmux_agent_alive "$WS_M:$SF_M")
[ "$sm_alive" = dead ] || fail "a woken mate tab holding only its shell should classify as dead, got '$sm_alive'"
pass "real cmux: agent_alive reads the surface tty's processes and calls a bare shell confidently dead"

# Fingerprint fallback: lose BOTH the recorded title and the scoped tab title,
# then recover purely by the home-cwd fingerprint (passive tiers).
fm_backend_cmux_cli rename-tab --workspace "$WS_M" --surface "$SF_M" "plain tab" >/dev/null 2>&1 \
  || fail "rename-tab away from the scoped title failed"
fm_backend_cmux_meta_update "$SM_META" \
  "window=BOGUS-WS:BOGUS-SF" "cmux_workspace_id=BOGUS-WS" "cmux_surface_id=BOGUS-SF" \
  "cmux_workspace_title=totally-forgotten-title" \
  || fail "meta_update failed"
sm_target=$(fm_backend_cmux_secondmate_resolve "$SM_META") || fail "fingerprint resolve failed"
[ "$sm_target" = "$WS_M:$SF_M" ] || fail "resolve should recover by the home-cwd fingerprint, got '$sm_target'"
pass "real cmux: the home-cwd fingerprint recovers a mate whose titles were all lost, without typing into any terminal"

# Kill: the meta-driven secondmate kill closes the WHOLE dedicated workspace.
cmux_secondmate_refuse_if_unsafe "$WS_M" "$WS_M_RETITLE" \
  || fail "safety pre-flight refused our own test mate workspace"
fm_backend_cmux_secondmate_kill "$SM_META" || fail "secondmate kill failed"
sleep 0.5
sm_gone=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
  | jq -r --arg id "$WS_M" '.workspaces[]? | select(.id == $id) | .id')
[ -z "$sm_gone" ] || fail "secondmate kill did not close the mate's workspace"
WS_M=""
fm_backend_cmux_secondmate_kill "$SM_META" || fail "a second kill (gone endpoint) must be a successful no-op"
pass "real cmux: secondmate kill closes the mate's whole workspace via identity checks and is idempotent"

cleanup_all
trap - EXIT
