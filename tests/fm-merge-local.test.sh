#!/usr/bin/env bash
# tests/fm-merge-local.test.sh - bin/fm-merge-local.sh, the one sanctioned
# state-changing git write INTO a project (the captain's merge authority applied
# locally for a mode=local-only ship task instead of via a GitHub PR).
#
# The contract this asserts as real post-conditions on the project repo, not just
# exit codes:
#   - a clean fast-forward advances the default branch to the crewmate's fm/<id>
#     branch tip (and only then);
#   - a diverged (non-fast-forward) branch is REFUSED and the default branch is
#     left untouched;
#   - a non-local-only task is refused (wrong merge gate);
#   - a dirty project working tree is refused;
#   - a project not on its default branch is refused;
#   - a missing fm/<id> branch is refused.
# Hermetic: a throwaway local git repo per case, no origin/network, no tmux.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# Build a fresh sandbox. Creates:
#   $CASE/state/            firstmate state dir (fresh watcher beacon so fm-guard is quiet)
#   $CASE/project/          a local git repo on `main` with one baseline commit
# The project has NO origin remote, so default_branch() resolves `main` via
# refs/heads/main - the local-only shape this script is built for. Echoes $CASE.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fmroot/bin"
  touch "$case_dir/state/.last-watcher-beat"
  # A no-op fm-guard.sh so the script's `"$FM_ROOT/bin/fm-guard.sh" || true`
  # stays silent (the real guard is exercised elsewhere; it is not under test here).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fmroot/bin/fm-guard.sh"
  chmod +x "$case_dir/fmroot/bin/fm-guard.sh"

  git init -q -b main "$case_dir/project"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  printf '%s\n' "$case_dir"
}

# Write task meta. Args: case_dir mode
write_meta() {
  local case_dir=$1 mode=$2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/project" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode"
}

commit_on() {  # <project> <branch> <message>
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$3"
}

# Create branch fm/task-x1 with <n> extra commits ahead of main (a clean
# fast-forward), leaving the project checked out back on main. Args: case_dir
add_fast_forward_branch() {
  local case_dir=$1
  git -C "$case_dir/project" checkout -q -b fm/task-x1
  commit_on "$case_dir/project" fm/task-x1 "crew fix"
  git -C "$case_dir/project" checkout -q main
}

# Create a diverged fm/task-x1: branch off the baseline, commit on the branch,
# then advance main with a different commit so neither is an ancestor of the
# other. Leaves the project on main. Args: case_dir
add_diverged_branch() {
  local case_dir=$1
  git -C "$case_dir/project" checkout -q -b fm/task-x1
  commit_on "$case_dir/project" fm/task-x1 "crew fix on branch"
  git -C "$case_dir/project" checkout -q main
  commit_on "$case_dir/project" main "unrelated main commit"
}

run_merge_local() {  # <case_dir> [extra args...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1 "$@"
}

test_fast_forward_merge_advances_default() {
  local case_dir before tip after out
  case_dir=$(make_case ff-merge)
  write_meta "$case_dir" local-only
  add_fast_forward_branch "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)
  tip=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  [ "$before" != "$tip" ] || fail "ff-merge: fixture branch was not ahead of main"

  out=$(run_merge_local "$case_dir") || fail "ff-merge: merge should succeed on a clean fast-forward"

  after=$(git -C "$case_dir/project" rev-parse main)
  [ "$after" = "$tip" ] || fail "ff-merge: main was not fast-forwarded to the branch tip ($after != $tip)"
  # The default branch is still the checked-out branch and the tree is clean.
  [ "$(git -C "$case_dir/project" symbolic-ref --short HEAD)" = main ] \
    || fail "ff-merge: project left off its default branch"
  printf '%s\n' "$out" | grep -F "merged fm/task-x1 into local main" >/dev/null \
    || fail "ff-merge: success line missing: $out"
  pass "a clean fast-forward advances the default branch to the crewmate branch tip"
}

test_diverged_branch_is_refused_and_leaves_default_untouched() {
  local case_dir before rc after
  case_dir=$(make_case diverged-refuse)
  write_meta "$case_dir" local-only
  add_diverged_branch "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "diverged-refuse: merge should refuse a non-fast-forward branch"
  grep -q REFUSED "$case_dir/stderr" || fail "diverged-refuse: no REFUSED line in stderr: $(cat "$case_dir/stderr")"
  after=$(git -C "$case_dir/project" rev-parse main)
  [ "$after" = "$before" ] || fail "diverged-refuse: default branch was modified despite the refusal"
  pass "a diverged (non-fast-forward) branch is refused and the default branch is left untouched"
}

test_non_local_only_mode_is_refused() {
  local case_dir before rc after
  case_dir=$(make_case wrong-mode)
  write_meta "$case_dir" no-mistakes
  add_fast_forward_branch "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "wrong-mode: merge should refuse a non-local-only task"
  grep -q "not local-only" "$case_dir/stderr" || fail "wrong-mode: stderr did not explain the mode gate: $(cat "$case_dir/stderr")"
  after=$(git -C "$case_dir/project" rev-parse main)
  [ "$after" = "$before" ] || fail "wrong-mode: default branch advanced for a non-local-only task"
  pass "a non-local-only task is refused (wrong merge gate)"
}

test_dirty_project_is_refused() {
  local case_dir before rc after
  case_dir=$(make_case dirty-refuse)
  write_meta "$case_dir" local-only
  add_fast_forward_branch "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)
  printf 'uncommitted\n' > "$case_dir/project/dirty.txt"

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-refuse: merge should refuse a dirty project working tree"
  grep -qi "dirty" "$case_dir/stderr" || fail "dirty-refuse: stderr did not mention the dirty tree: $(cat "$case_dir/stderr")"
  after=$(git -C "$case_dir/project" rev-parse main)
  [ "$after" = "$before" ] || fail "dirty-refuse: default branch advanced despite a dirty tree"
  pass "a dirty project working tree is refused"
}

test_project_off_default_branch_is_refused() {
  local case_dir rc
  case_dir=$(make_case off-default)
  write_meta "$case_dir" local-only
  add_fast_forward_branch "$case_dir"
  # Leave the project checked out on the task branch, not the default branch.
  git -C "$case_dir/project" checkout -q fm/task-x1

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "off-default: merge should refuse when the project is not on its default branch"
  grep -q "expected default branch" "$case_dir/stderr" \
    || fail "off-default: stderr did not explain the branch requirement: $(cat "$case_dir/stderr")"
  pass "a project not checked out on its default branch is refused"
}

test_missing_branch_is_refused() {
  local case_dir before rc after
  case_dir=$(make_case missing-branch)
  write_meta "$case_dir" local-only
  # No fm/task-x1 branch created.
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-branch: merge should refuse when fm/task-x1 does not exist"
  grep -q "does not exist" "$case_dir/stderr" || fail "missing-branch: stderr did not report the missing branch: $(cat "$case_dir/stderr")"
  after=$(git -C "$case_dir/project" rev-parse main)
  [ "$after" = "$before" ] || fail "missing-branch: default branch advanced despite the missing branch"
  pass "a missing fm/<id> branch is refused"
}

test_fast_forward_merge_advances_default
test_diverged_branch_is_refused_and_leaves_default_untouched
test_non_local_only_mode_is_refused
test_dirty_project_is_refused
test_project_off_default_branch_is_refused
test_missing_branch_is_refused
