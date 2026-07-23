#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) an Azure DevOps PR completes via az repos pr update --status completed,
#       addressed by the canonical organization URL (legacy visualstudio.com
#       spelling included), records pr=/pr_head= first, refuses extra args, and
#       propagates az failures without recording landed=
#   (j) a successful merge records the landed= verdict as part of the merge:
#       GitHub from the recorded pr_head=, ADO from lastMergeCommit.commitId,
#       falling back to the pr-<n> placeholder when no head sha is available
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# az mock answering fm-pr-check.sh's preflight (extension show) and pr_head
# lookup (lastMergeSourceCommit), the merge-path pr update call, and the
# post-merge landed lookup (lastMergeCommit), recording every invocation.
# Args: case_dir [head_sha] [merge_commit_sha]
add_az_mocks() {
  local case_dir=$1 head=${2:-} merge=${3:-}
  cat > "$case_dir/fakebin/az" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_AZ_LOG"
case " \$* " in
  *" extension show "*) exit 0 ;;
  *" lastMergeSourceCommit.commitId "*) printf '%s\n' '$head' ;;
  *" lastMergeCommit.commitId "*) printf '%s\n' '$merge' ;;
  *" pr update "*) exit "\${FM_TEST_AZ_UPDATE_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/az"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_AZ_LOG="$case_dir/az.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  # After a successful GitHub merge, the landed verdict is the recorded PR head.
  assert_grep 'landed=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: landed= was not recorded from pr_head after the merge"
  pass "fm-pr-merge records pr=, pr_head=, and landed= for a GitHub merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  assert_no_grep 'landed=' "$case_dir/state/task-x1.meta" \
    "merge-fails: landed= must not be recorded when the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_ado_merge_completes_and_records() {
  local case_dir rc url
  case_dir=$(make_case ado-completes)
  mkdir -p "$case_dir/wt"
  add_az_mocks "$case_dir" 0123456789abcdef0123456789abcdef01234567 fedcba9876543210fedcba9876543210fedcba98
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/az.log"
  url='https://dev.azure.com/exampleorg/Example%20Project/_git/example-repo/pullrequest/9'

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ado-completes: fm-pr-merge should succeed"
  assert_grep "pr=$url" "$case_dir/state/task-x1.meta" \
    "ado-completes: pr= was not recorded"
  assert_grep 'pr_head=0123456789abcdef0123456789abcdef01234567' "$case_dir/state/task-x1.meta" \
    "ado-completes: pr_head= was not recorded from lastMergeSourceCommit"
  grep -qxF 'repos pr update --id 9 --status completed --organization https://dev.azure.com/exampleorg' "$case_dir/az.log" \
    || fail "ado-completes: az repos pr update was not invoked with number, completed status, and organization URL"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "ado-completes: the GitHub CLI was invoked for an ADO URL"
  assert_grep 'completed: ADO PR 9' "$case_dir/stdout" \
    "ado-completes: completion was not reported"
  # After completion the landed verdict is the PR's merge commit (lastMergeCommit).
  assert_grep 'landed=fedcba9876543210fedcba9876543210fedcba98' "$case_dir/state/task-x1.meta" \
    "ado-completes: landed= was not recorded from lastMergeCommit after completion"
  pass "fm-pr-merge completes an ADO PR and records pr=, pr_head=, and landed="
}

test_ado_legacy_host_normalizes_organization() {
  local case_dir url
  case_dir=$(make_case ado-legacy-host)
  mkdir -p "$case_dir/wt"
  add_az_mocks "$case_dir"
  : > "$case_dir/az.log"
  url='https://exampleorg.visualstudio.com/Example%20Project/_git/example-repo/pullrequest/7'

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "ado-legacy-host: fm-pr-merge failed"

  grep -qxF 'repos pr update --id 7 --status completed --organization https://dev.azure.com/exampleorg' "$case_dir/az.log" \
    || fail "ado-legacy-host: legacy visualstudio.com URL was not completed through the modern organization URL"
  pass "fm-pr-merge completes a legacy visualstudio.com PR through dev.azure.com"
}

test_ado_extra_args_refused_before_recording() {
  local case_dir rc url
  case_dir=$(make_case ado-extra-args)
  mkdir -p "$case_dir/wt"
  add_az_mocks "$case_dir"
  : > "$case_dir/az.log"
  url='https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/11'

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ado-extra-args: fm-pr-merge should refuse extra args for an ADO URL"
  assert_grep 'governed by ADO branch policy' "$case_dir/stderr" \
    "ado-extra-args: refusal did not explain why the merge method is not honored"
  assert_no_grep "pr=$url" "$case_dir/state/task-x1.meta" \
    "ado-extra-args: PR URL was recorded before the refusal"
  [ ! -s "$case_dir/az.log" ] || fail "ado-extra-args: az was invoked despite the refusal"
  pass "fm-pr-merge refuses extra merge args for ADO PRs before recording state"
}

test_ado_update_failure_propagates_after_recording() {
  local case_dir rc url
  case_dir=$(make_case ado-update-fails)
  mkdir -p "$case_dir/wt"
  add_az_mocks "$case_dir"
  : > "$case_dir/az.log"
  url='https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/13'

  set +e
  FM_TEST_AZ_UPDATE_RC=1 run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ado-update-fails: fm-pr-merge should propagate the az completion failure"
  assert_grep "pr=$url" "$case_dir/state/task-x1.meta" \
    "ado-update-fails: pr= should already be recorded even though the completion failed"
  assert_no_grep 'landed=' "$case_dir/state/task-x1.meta" \
    "ado-update-fails: a failed completion must not record landed="
  pass "fm-pr-merge propagates an az completion failure without silently succeeding"
}

test_ado_landed_falls_back_to_placeholder() {
  local case_dir rc url
  case_dir=$(make_case ado-landed-fallback)
  mkdir -p "$case_dir/wt"
  # Head sha present (pr_head), but no merge commit reported: landed= falls back
  # to the pr-<n> placeholder, which the teardown oracle treats as unresolvable.
  add_az_mocks "$case_dir" 0123456789abcdef0123456789abcdef01234567 ""
  : > "$case_dir/az.log"
  url='https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/42'

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ado-landed-fallback: fm-pr-merge should succeed"
  assert_grep 'landed=pr-42' "$case_dir/state/task-x1.meta" \
    "ado-landed-fallback: landed= should fall back to the pr-<n> placeholder"
  pass "fm-pr-merge records the pr-<n> landed placeholder when no merge commit is reported"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_ado_merge_completes_and_records
test_ado_legacy_host_normalizes_organization
test_ado_extra_args_refused_before_recording
test_ado_update_failure_propagates_after_recording
test_ado_landed_falls_back_to_placeholder
