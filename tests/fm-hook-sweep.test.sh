#!/usr/bin/env bash
# Orphaned turn-end hook registry sweep (bin/fm-hook-sweep.sh).
#
# grok/copilot install ONE global turn-end hook whose per-task registry tokens
# live under hooks/fm-turn-end.d/<token>. A clean teardown removes a task's token;
# a task that dies without teardown leaves it behind. These tests pin the sweep
# that removes such orphans while never touching a live token, an in-flight
# (empty) token, or another home's live token.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-hook-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-hook-sweep)

# make_case <name> <harness> -> echoes "case_dir|home_dir|hooks_dir"
# harness is grok or copilot; sets up the harness home dir the sweep reads via
# GROK_HOME/COPILOT_HOME and a firstmate home with a state dir.
make_case() {
  local name=$1 h=$2 case_dir hooks_dir
  case_dir="$TMP_ROOT/$name"
  hooks_dir="$case_dir/$h/hooks/fm-turn-end.d"
  mkdir -p "$hooks_dir" "$case_dir/home/state"
  printf '%s|%s|%s\n' "$case_dir" "$case_dir/home" "$hooks_dir"
}

# add_token <hooks_dir> <token-name> <turnend-path-or-empty>
add_token() {
  local hooks_dir=$1 name=$2 content=$3
  if [ -n "$content" ]; then
    printf '%s\n' "$content" > "$hooks_dir/$name"
  else
    : > "$hooks_dir/$name"
  fi
}

# add_live_task <home> <id> <harness> <hooks_dir> <token-name>: create a live
# task record (meta + worktree + pointer) whose registry token is <token-name>.
add_live_task() {
  local home=$1 id=$2 h=$3 hooks_dir=$4 token=$5 wt
  wt="$home/wt-$id"
  mkdir -p "$wt"
  printf 'worktree=%s\n' "$wt" > "$home/state/$id.meta"
  printf 'token=%s\n' "$token" > "$wt/.fm-$h-turnend"
  add_token "$hooks_dir" "$token" "$home/state/$id.turn-ended"
}

# Point the target harness's HOME at the case dir and the other harness's HOME at
# a nonexistent dir, so a copilot case never scans the same tree as grok.
run_sweep() {  # <case_dir> <harness> [min-age]
  local case_dir=$1 h=$2 min_age=${3:-0} grok_home copilot_home
  grok_home="$case_dir/none-grok"
  copilot_home="$case_dir/none-copilot"
  if [ "$h" = grok ]; then grok_home="$case_dir/grok"; else copilot_home="$case_dir/copilot"; fi
  env FM_HOOK_SWEEP_MIN_AGE_MINS="$min_age" \
    GROK_HOME="$grok_home" COPILOT_HOME="$copilot_home" \
    "$SWEEP" 2>&1
}

test_removes_orphans_keeps_live_and_empty() {
  local rec case_dir home hooks out
  rec=$(make_case orphans copilot)
  IFS='|' read -r case_dir home hooks <<EOF
$rec
EOF
  add_live_task "$home" live-x1 copilot "$hooks" fm.LIVELIVELIVE
  # Orphan: meta gone.
  add_token "$hooks" fm.GONEGONEGONE "$home/state/gone-x2.turn-ended"
  # Orphan: worktree gone (meta present, dir missing).
  printf 'worktree=%s\n' "$home/dead-wt" > "$home/state/dead-x3.meta"
  add_token "$hooks" fm.DEADDEADDEAD "$home/state/dead-x3.turn-ended"
  # Orphan: superseding respawn (pointer names a different token).
  mkdir -p "$home/super-wt"
  printf 'worktree=%s\n' "$home/super-wt" > "$home/state/super-x4.meta"
  printf 'token=%s\n' fm.NEWNEWNEWNEW > "$home/super-wt/.fm-copilot-turnend"
  add_token "$hooks" fm.SUPERSUPERXX "$home/state/super-x4.turn-ended"
  # In-flight spawn: empty token file, must be left.
  add_token "$hooks" fm.EMPTYEMPTYXX ''
  # Not-ours: wrong filename shape, must be left.
  add_token "$hooks" other.txt "$home/state/whatever.turn-ended"

  out=$(run_sweep "$case_dir" copilot 0)
  assert_contains "$out" "removed 3 orphaned copilot" "sweep should report 3 removed orphans"
  assert_present "$hooks/fm.LIVELIVELIVE" "live token was removed"
  assert_present "$hooks/fm.EMPTYEMPTYXX" "in-flight empty token was removed"
  assert_present "$hooks/other.txt" "non-token file was removed"
  assert_absent "$hooks/fm.GONEGONEGONE" "meta-missing orphan survived"
  assert_absent "$hooks/fm.DEADDEADDEAD" "worktree-missing orphan survived"
  assert_absent "$hooks/fm.SUPERSUPERXX" "superseded orphan survived"
  pass "sweep removes orphans, keeps live/empty/non-token entries"
}

test_sweeps_grok_registry_too() {
  local rec case_dir home hooks out
  rec=$(make_case grok-orphans grok)
  IFS='|' read -r case_dir home hooks <<EOF
$rec
EOF
  add_live_task "$home" glive-x1 grok "$hooks" fm.GLIVEGLIVEXX
  add_token "$hooks" fm.GORPHANORPHX "$home/state/ggone-x2.turn-ended"
  out=$(run_sweep "$case_dir" grok 0)
  assert_contains "$out" "removed 1 orphaned grok" "grok registry should be swept too"
  assert_present "$hooks/fm.GLIVEGLIVEXX" "live grok token was removed"
  assert_absent "$hooks/fm.GORPHANORPHX" "orphaned grok token survived"
  pass "sweep cleans grok's fm-turn-end.d the same way"
}

test_age_guard_protects_fresh_orphans() {
  local rec case_dir home hooks out
  rec=$(make_case age-guard copilot)
  IFS='|' read -r case_dir home hooks <<EOF
$rec
EOF
  # Fresh orphan (just created) - default 2-min guard must keep it.
  add_token "$hooks" fm.FRESHFRESHXX "$home/state/gone.turn-ended"
  # Old orphan - must be removed.
  add_token "$hooks" fm.OLDOLDOLDXXX "$home/state/gone2.turn-ended"
  touch -t 202001010000 "$hooks/fm.OLDOLDOLDXXX"
  # Default age guard (FM_HOOK_SWEEP_MIN_AGE_MINS unset -> 2 minutes). GROK_HOME is
  # pinned to a nonexistent dir so the real ~/.grok is never scanned.
  out=$(env -u FM_HOOK_SWEEP_MIN_AGE_MINS \
    GROK_HOME="$case_dir/none-grok" COPILOT_HOME="$case_dir/copilot" "$SWEEP" 2>&1)
  assert_contains "$out" "removed 1 orphaned copilot" "only the aged orphan should be removed"
  assert_present "$hooks/fm.FRESHFRESHXX" "age guard did not protect the fresh token"
  assert_absent "$hooks/fm.OLDOLDOLDXXX" "aged orphan survived"
  pass "sweep age guard protects in-flight tokens, removes aged orphans"
}

test_other_homes_live_token_untouched() {
  local rec case_dir home hooks out other
  rec=$(make_case cross-home copilot)
  IFS='|' read -r case_dir home hooks <<EOF
$rec
EOF
  # A live task belonging to a DIFFERENT firstmate home; its token content points
  # into that other home's state, whose meta+worktree still exist. The sweep must
  # leave it, proving home-agnostic safety.
  other="$case_dir/other-home"
  mkdir -p "$other/state" "$other/wt-a"
  printf 'worktree=%s\n' "$other/wt-a" > "$other/state/a-x1.meta"
  printf 'token=%s\n' fm.OTHEROTHERXX > "$other/wt-a/.fm-copilot-turnend"
  add_token "$hooks" fm.OTHEROTHERXX "$other/state/a-x1.turn-ended"
  out=$(run_sweep "$case_dir" copilot 0)
  assert_not_contains "$out" "removed" "no token should be removed"
  assert_present "$hooks/fm.OTHEROTHERXX" "another home's live token was removed"
  pass "sweep never removes another home's live token"
}

test_removes_orphans_keeps_live_and_empty
test_sweeps_grok_registry_too
test_age_guard_protects_fresh_orphans
test_other_homes_live_token_untouched
