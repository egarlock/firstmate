#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh.
#
# fm-promote flips kind=scout to kind=ship in state/<task-id>.meta so
# fm-teardown.sh reapplies the full ship-task landed-work protection to a
# worktree that was declared scratch. That makes two properties load-bearing:
# the refusals must leave the meta byte-identical (a half-promoted task would
# either lose scout teardown's scratch allowance or gain ship protection it was
# never granted), and the argument guard must report a missing task id rather
# than dying on a raw set -u "$1: unbound variable".
#
# Hermetic: an isolated FM_HOME state dir per case, a stub fm-guard.sh in the
# fake FM_ROOT so no real supervision guard runs, no git, tmux, or network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote)

# fm-promote calls "$FM_ROOT/bin/fm-guard.sh" before anything else. Point
# FM_ROOT_OVERRIDE at a fake root holding a no-op guard so the suite never
# depends on this host's live watcher state.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fmroot/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fmroot/bin/fm-guard.sh"
  chmod +x "$case_dir/fmroot/bin/fm-guard.sh"
  printf '%s\n' "$case_dir"
}

run_promote() { # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$case_dir/fmroot" FM_STATE_OVERRIDE="$case_dir/state" \
    "$PROMOTE" "$@"
}

test_scout_is_promoted_to_ship() {
  local case_dir meta out
  case_dir=$(make_case promote-scout)
  meta="$case_dir/state/scout-a1.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-scout-a1" \
    "worktree=$case_dir/wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_promote "$case_dir" scout-a1) || fail "promoting a scout task exited non-zero"
  assert_contains "$out" "promoted scout-a1 to ship" "promote did not report the flip"
  # Whole-line matches: kind= is the one field the flip rewrites, so an exact
  # line check is what distinguishes a promotion from a substring coincidence.
  grep -qx 'kind=ship' "$meta" || fail "meta was not flipped to kind=ship"
  ! grep -qx 'kind=scout' "$meta" || fail "meta still carries the scout kind"
  # Every other recorded field must survive the rewrite untouched.
  grep -qx 'window=firstmate:fm-scout-a1' "$meta" || fail "promote dropped window="
  grep -qx 'harness=claude' "$meta" || fail "promote dropped harness="
  grep -qx 'mode=no-mistakes' "$meta" || fail "promote dropped mode="
  pass "fm-promote flips a scout task to ship and preserves the rest of the meta"
}

test_non_scout_is_refused_with_meta_untouched() {
  local case_dir meta before rc out
  case_dir=$(make_case promote-non-scout)
  meta="$case_dir/state/ship-b1.meta"
  fm_write_meta "$meta" "window=firstmate:fm-ship-b1" "kind=ship" "mode=direct-PR"
  before=$(cat "$meta")

  out=$(run_promote "$case_dir" ship-b1 2>&1)
  rc=$?
  expect_code 1 "$rc" "promoting a non-scout task should exit 1"
  assert_contains "$out" "is not a scout task" "refusal did not explain the kind mismatch"
  [ "$(cat "$meta")" = "$before" ] || fail "refused promote still rewrote the meta"
  assert_absent "$meta.tmp" "refused promote left a temp meta behind"
  pass "fm-promote refuses a non-scout task and leaves its meta byte-identical"
}

test_missing_meta_is_refused() {
  local case_dir rc out
  case_dir=$(make_case promote-missing-meta)
  out=$(run_promote "$case_dir" ghost-c1 2>&1)
  rc=$?
  expect_code 1 "$rc" "promoting a task with no meta should exit 1"
  assert_contains "$out" "no meta for task ghost-c1" "refusal did not name the missing meta"
  assert_absent "$case_dir/state/ghost-c1.meta" "refused promote created a meta"
  pass "fm-promote refuses a task with no meta record"
}

test_no_args_prints_usage() {
  local case_dir rc out
  case_dir=$(make_case promote-no-args)
  out=$(run_promote "$case_dir" 2>&1)
  rc=$?
  expect_code 1 "$rc" "fm-promote with no task id should exit 1"
  assert_contains "$out" "usage: fm-promote.sh <task-id>" "no-arg run did not print usage"
  assert_not_contains "$out" "unbound variable" "no-arg run crashed on an unbound positional"
  pass "fm-promote prints usage and exits 1 with no task id instead of an unbound-variable crash"
}

test_scout_is_promoted_to_ship
test_non_scout_is_refused_with_meta_untouched
test_missing_meta_is_refused
test_no_args_prints_usage
