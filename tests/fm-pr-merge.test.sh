#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr=, pr_head=, and landed= (the PR head sha) on success
#   (a2) merge records landed=pr-<n> when no pr_head is available
#   (b) merge is refused when gh-axi pr merge itself fails (no landed= recorded)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) an Azure DevOps PR URL merges via `az repos pr update --status completed`
#       and records landed= from the completed PR's lastMergeCommit
#   (j) ADO landed= falls back to pr-<n> when az yields no merge commit sha
#   (k) extra `--` merge args are refused for ADO URLs (branch policy governs)
#   (l) an ADO URL without a usable az CLI is refused with the remedy
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

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
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
  # The authoritative landed verdict is recorded once the merge succeeds; it uses the
  # PR head sha when fm-pr-check captured one, so bin/fm-teardown.sh can allow teardown
  # from the recorded fact alone.
  assert_grep 'landed=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: landed= was not recorded with the PR head sha after a successful merge"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr=, pr_head=, and landed= before/after invoking gh-axi pr merge"
}

test_records_landed_pr_number_when_no_head_available() {
  local case_dir rc
  case_dir=$(make_case landed-no-head)
  # No worktree on disk, so fm-pr-check.sh skips the pr_head lookup and records no
  # pr_head=. The merge must still record a non-empty landed= verdict, derived from
  # the PR number, so teardown has the recorded fact to act on.
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/11 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "landed-no-head: fm-pr-merge should succeed"
  assert_no_grep '^pr_head=' "$case_dir/state/task-x1.meta" \
    "landed-no-head: pr_head= should be absent when no worktree resolves the head"
  assert_grep 'landed=pr-11' "$case_dir/state/task-x1.meta" \
    "landed-no-head: landed= should fall back to the PR number marker"
  pass "fm-pr-merge records landed=pr-<n> when no PR head sha is available"
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
  # A failed merge must NOT record a landed verdict: nothing landed, so teardown must
  # keep refusing until a real merge succeeds.
  assert_no_grep '^landed=' "$case_dir/state/task-x1.meta" \
    "merge-fails: landed= was recorded despite the merge failing"
  pass "fm-pr-merge propagates a real merge failure without recording a landed verdict"
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
  assert_grep 'no meta for task missing-x1' "$case_dir/stderr" \
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

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
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
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
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

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# az mock recording every invocation, answering the extension probe, completing
# `repos pr update`, and serving the two `repos pr show` queries fm-pr-check /
# fm-pr-merge issue (lastMergeSourceCommit head, lastMergeCommit landed sha).
# Args: case_dir head_sha merge_sha  (empty merge_sha = no sha available)
add_az_mock() {
  local case_dir=$1 head=$2 merged=$3
  cat > "$case_dir/fakebin/az" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_AZ_LOG"
case "\${1:-} \${2:-} \${3:-}" in
  "extension show --name") exit 0 ;;
  "repos pr update") printf '%s\n' '{"status": "completed"}' ; exit 0 ;;
  "repos pr show")
    case " \$* " in
      *" --query lastMergeSourceCommit.commitId "*) printf '%s\n' '$head' ; exit 0 ;;
      *" --query lastMergeCommit.commitId "*) printf '%s\n' '$merged' ; exit 0 ;;
      *" --query status "*) printf '%s\n' 'active' ; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/az"
}

run_pr_merge_ado() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_AZ_LOG="$case_dir/az.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_ado_merge_happy_path_records_landed() {
  local case_dir rc
  case_dir=$(make_case ado-happy)
  add_az_mock "$case_dir" aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111 bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222
  : > "$case_dir/az.log"

  set +e
  run_pr_merge_ado "$case_dir" task-x1 https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ado-happy: fm-pr-merge should succeed on an ADO PR URL"
  assert_grep 'pr=https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/42' "$case_dir/state/task-x1.meta" \
    "ado-happy: pr= was not recorded"
  assert_grep 'pr_head=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111' "$case_dir/state/task-x1.meta" \
    "ado-happy: pr_head= was not recorded from lastMergeSourceCommit"
  grep -qxF 'repos pr update --id 42 --status completed --organization https://dev.azure.com/exampleorg' "$case_dir/az.log" \
    || fail "ado-happy: az repos pr update was not invoked with --status completed and the org URL"
  assert_grep 'landed=bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222' "$case_dir/state/task-x1.meta" \
    "ado-happy: landed= was not recorded from the completed PR's lastMergeCommit"
  pass "fm-pr-merge completes an ADO PR via az and records pr=, pr_head=, and landed="
}

test_ado_merge_landed_falls_back_to_pr_number() {
  local case_dir rc
  case_dir=$(make_case ado-landed-fallback)
  # No merge-commit sha from az (empty tsv), and no head either: landed= must
  # still be recorded, as the pr-<n> placeholder, mirroring the GitHub path.
  add_az_mock "$case_dir" '' ''
  : > "$case_dir/az.log"

  set +e
  run_pr_merge_ado "$case_dir" task-x1 https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/11 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ado-landed-fallback: fm-pr-merge should succeed"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "ado-landed-fallback: pr_head= should be absent when az yields no head sha"
  assert_grep 'landed=pr-11' "$case_dir/state/task-x1.meta" \
    "ado-landed-fallback: landed= should fall back to the pr-<n> placeholder"
  pass "fm-pr-merge records landed=pr-<n> when az yields no merge commit sha"
}

test_ado_extra_merge_args_refused() {
  local case_dir rc
  case_dir=$(make_case ado-extra-args)
  add_az_mock "$case_dir" cccc3333cccc3333cccc3333cccc3333cccc3333 dddd4444dddd4444dddd4444dddd4444dddd4444
  : > "$case_dir/az.log"

  set +e
  run_pr_merge_ado "$case_dir" task-x1 https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/5 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ado-extra-args: fm-pr-merge should refuse -- args for an ADO PR URL"
  assert_grep 'governed by ADO branch policy' "$case_dir/stderr" \
    "ado-extra-args: refusal did not explain that ADO branch policy governs the merge strategy"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "ado-extra-args: pr= was recorded despite the refusal"
  assert_no_grep 'repos pr update' "$case_dir/az.log" \
    "ado-extra-args: az repos pr update was invoked despite the refusal"
  assert_no_grep 'landed=' "$case_dir/state/task-x1.meta" \
    "ado-extra-args: landed= was recorded despite the refusal"
  pass "fm-pr-merge refuses extra -- merge args for ADO PR URLs before any state write"
}

test_ado_preflight_missing_extension_refused() {
  local case_dir rc
  case_dir=$(make_case ado-no-extension)
  cat > "$case_dir/fakebin/az" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_AZ_LOG"
case "${1:-} ${2:-}" in
  "extension show") echo "The extension azure-devops is not installed." >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/az"
  : > "$case_dir/az.log"

  set +e
  run_pr_merge_ado "$case_dir" task-x1 https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/6 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ado-no-extension: fm-pr-merge should refuse without the azure-devops extension"
  assert_grep 'az extension add --name azure-devops' "$case_dir/stderr" \
    "ado-no-extension: refusal did not give the actionable remedy"
  assert_no_grep 'repos pr update' "$case_dir/az.log" \
    "ado-no-extension: az repos pr update was invoked despite the failed preflight"
  assert_no_grep 'landed=' "$case_dir/state/task-x1.meta" \
    "ado-no-extension: landed= was recorded despite the failed preflight"
  pass "fm-pr-merge refuses an ADO PR URL with a clear remedy when the azure-devops extension is missing"
}

test_records_pr_and_head_before_merging
test_records_landed_pr_number_when_no_head_available
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_ado_merge_happy_path_records_landed
test_ado_merge_landed_falls_back_to_pr_number
test_ado_extra_merge_args_refused
test_ado_preflight_missing_extension_refused
