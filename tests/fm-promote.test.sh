#!/usr/bin/env bash
# tests/fm-promote.test.sh - bin/fm-promote.sh, which promotes a scout task to a
# ship task IN PLACE by flipping kind=scout to kind=ship in state/<id>.meta. That
# flip is safety-relevant: it restores fm-teardown.sh's full ship-task landed-work
# protection to a worktree that, as a scout, teardown treated as scratch. So these
# tests assert the real post-condition on the meta file, not just exit codes:
#   - a scout task's meta flips to exactly one kind=ship line, every other meta
#     line preserved, and the crewmate ship-instructions hint is printed;
#   - a non-scout (already ship) task is refused and its meta is left untouched;
#   - a task with no meta is refused.
# Hermetic: a state dir with a hand-written meta; no git, tmux, or network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote-tests)

# Build a sandbox with a state dir (fresh watcher beacon) and a no-op fm-guard.sh
# under a throwaway FM_ROOT so the script's `"$FM_ROOT/bin/fm-guard.sh" || true`
# stays silent (the guard is not under test here). Echoes $CASE.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fmroot/bin"
  touch "$case_dir/state/.last-watcher-beat"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fmroot/bin/fm-guard.sh"
  chmod +x "$case_dir/fmroot/bin/fm-guard.sh"
  printf '%s\n' "$case_dir"
}

# Write task meta. Args: case_dir kind
write_meta() {
  local case_dir=$1 kind=$2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=$kind" \
    "mode=no-mistakes"
}

run_promote() {  # <case_dir> [id]
  local case_dir=$1 id=${2:-task-x1}
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$PROMOTE" "$id"
}

test_scout_is_promoted_to_ship() {
  local case_dir out meta kind_lines
  case_dir=$(make_case promote-scout)
  write_meta "$case_dir" scout
  meta="$case_dir/state/task-x1.meta"

  out=$(run_promote "$case_dir") || fail "promote-scout: promotion should succeed for a scout task"

  # The kind flipped to ship, and to EXACTLY ONE kind= line (no leftover scout).
  assert_grep "kind=ship" "$meta" "promote-scout: meta not flipped to kind=ship"
  assert_no_grep "kind=scout" "$meta" "promote-scout: stale kind=scout left in meta"
  kind_lines=$(grep -c '^kind=' "$meta")
  [ "$kind_lines" = 1 ] || fail "promote-scout: expected exactly one kind= line, found $kind_lines"
  # Every other meta field is preserved.
  assert_grep "window=fm-task-x1" "$meta" "promote-scout: window= line lost"
  assert_grep "worktree=$case_dir/wt" "$meta" "promote-scout: worktree= line lost"
  assert_grep "project=$case_dir/project" "$meta" "promote-scout: project= line lost"
  assert_grep "harness=claude" "$meta" "promote-scout: harness= line lost"
  assert_grep "mode=no-mistakes" "$meta" "promote-scout: mode= line lost"
  # Operator guidance is printed.
  printf '%s\n' "$out" | grep -F "promoted task-x1 to ship" >/dev/null \
    || fail "promote-scout: success line missing: $out"
  printf '%s\n' "$out" | grep -F "bin/fm-send.sh fm-task-x1" >/dev/null \
    || fail "promote-scout: crewmate ship-instructions hint missing: $out"
  pass "a scout task is promoted to ship (kind flipped, other meta preserved, hint printed)"
}

test_non_scout_is_refused_and_meta_untouched() {
  local case_dir before rc after
  case_dir=$(make_case promote-non-scout)
  write_meta "$case_dir" ship
  before=$(cat "$case_dir/state/task-x1.meta")

  set +e
  run_promote "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "promote-non-scout: promotion should refuse a task that is not a scout"
  grep -q "not a scout task" "$case_dir/stderr" \
    || fail "promote-non-scout: stderr did not explain the refusal: $(cat "$case_dir/stderr")"
  after=$(cat "$case_dir/state/task-x1.meta")
  [ "$after" = "$before" ] || fail "promote-non-scout: meta was modified despite the refusal"
  pass "a non-scout task is refused and its meta is left untouched"
}

test_missing_meta_is_refused() {
  local case_dir rc
  case_dir=$(make_case promote-missing-meta)
  # No meta written.

  set +e
  run_promote "$case_dir" nope-x9 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "promote-missing-meta: promotion should refuse a task with no meta"
  grep -q "no meta for task" "$case_dir/stderr" \
    || fail "promote-missing-meta: stderr did not report the missing meta: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/nope-x9.meta" "promote-missing-meta: a meta file was created for a missing task"
  pass "a task with no meta is refused"
}

test_scout_is_promoted_to_ship
test_non_scout_is_refused_and_meta_untouched
test_missing_meta_is_refused
