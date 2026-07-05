#!/usr/bin/env bash
# Tests for bin/fm-brief.sh's argument handling.
#
# fm-brief.sh runs under set -eu, and its positionals are collected into POS
# after flag filtering, so a missing <task-id> or <repo-name> used to die with a
# raw "POS[n]: unbound variable" instead of usage. These tests pin the usage
# guards (no args; id-only for the ship/scout shapes that need a repo name) and
# a scout happy path so the guard never over-rejects a valid invocation.
# Hermetic: state/data override dirs only; no git, tmux, or network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"
  printf '%s\n' "$case_dir"
}

run_brief() {  # <case_dir> [args...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$BRIEF" "$@"
}

test_no_args_prints_usage() {
  local case_dir rc out
  case_dir=$(make_case no-args)
  set +e
  out=$(run_brief "$case_dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "no-args: fm-brief with no args should exit 1"
  assert_contains "$out" "usage: fm-brief.sh <task-id> <repo-name> [--scout]" "no-arg run did not print usage"
  assert_not_contains "$out" "unbound variable" "no-arg run crashed on an unbound positional"
  pass "fm-brief prints usage and exits 1 with no args instead of an unbound-variable crash"
}

test_id_only_prints_usage() {
  local case_dir rc out
  case_dir=$(make_case id-only)
  # A ship (and --scout) brief needs the repo name; id-only must print usage,
  # not die on POS[1].
  set +e
  out=$(run_brief "$case_dir" onlyid 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "id-only: fm-brief with only a task id should exit 1"
  assert_contains "$out" "usage: fm-brief.sh <task-id> <repo-name> [--scout]" "id-only run did not print usage"
  assert_not_contains "$out" "unbound variable" "id-only run crashed on an unbound positional"
  set +e
  out=$(run_brief "$case_dir" onlyid --scout 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "id-only: fm-brief --scout with only a task id should exit 1"
  assert_contains "$out" "usage: fm-brief.sh" "id-only --scout run did not print usage"
  pass "fm-brief prints usage and exits 1 when the repo name is missing"
}

test_scout_brief_still_scaffolds() {
  local case_dir out
  case_dir=$(make_case scout-ok)
  out=$(run_brief "$case_dir" fix-login-k3 myrepo --scout) \
    || fail "scout-ok: a valid scout invocation was rejected by the usage guard"
  assert_contains "$out" "scaffolded:" "scout brief did not report scaffolding"
  assert_present "$case_dir/data/fix-login-k3/brief.md" "scout brief file was not written"
  assert_grep "disposable git worktree of myrepo" "$case_dir/data/fix-login-k3/brief.md" \
    "scout brief does not name the repo"
  pass "a valid scout invocation still scaffolds (the usage guard does not over-reject)"
}

test_no_args_prints_usage
test_id_only_prints_usage
test_scout_brief_still_scaffolds
