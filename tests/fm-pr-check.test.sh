#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's PR-URL validation.
#
# fm-pr-check.sh generates state/<id>.check.sh, a script the watcher later
# EXECUTES, by interpolating the PR URL into it. That URL originates in
# crewmate-authored status text ("done: PR <url> checks green"), so an
# unvalidated URL is a command-injection vector: anything able to write a status
# line could run code in firstmate's context. The script must validate the URL to
# the exact https://github.com/<owner>/<repo>/pull/<n> shape - mirroring
# fm-pr-merge.sh's parser - before recording it or writing the check shim.
#
# Matrix:
#   (a) a well-formed PR URL is accepted, records pr=, and arms the check shim
#   (b) a URL carrying a shell command-substitution is REJECTED before any write
#   (c) an unknown-forge URL is REJECTED before any write
#   (d) an Azure DevOps PR URL is accepted, records pr= and pr_head= from
#       `az repos pr show`'s lastMergeSourceCommit, and arms an az status poll
#       whose shim is silent on active, wakes "merged" on completed, and wakes a
#       distinguishable note on abandoned
#   (e) an ADO URL without a usable az CLI (azure-devops extension missing) is
#       REJECTED before any write, with the actionable remedy
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# Build a sandbox with a task meta and a fakebin whose gh mock would answer a
# pr_head lookup. A fresh watcher beacon keeps fm-guard quiet.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  mkdir -p "$case_dir/wt"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_wellformed_url_accepted() {
  local case_dir rc
  case_dir=$(make_case wellformed)

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "wellformed: fm-pr-check should accept a valid PR URL"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "wellformed: pr= was not recorded"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "wellformed: check shim was not armed"
  pass "fm-pr-check accepts a well-formed PR URL and arms the merge poll"
}

test_injection_url_rejected_before_any_write() {
  local case_dir rc canary
  case_dir=$(make_case injection)
  canary="$case_dir/pwned"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_check "$case_dir" task-x1 "https://github.com/x/x/pull/1\$(touch $canary)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "injection: fm-pr-check should reject a URL carrying a shell command"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "injection: refusal did not explain the expected URL shape"
  assert_absent "$canary" \
    "injection: the malicious command executed - the generated check shim ran attacker code"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "injection: a check shim was armed for a malicious URL"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'touch' "$case_dir/state/task-x1.meta" \
    "injection: malicious URL was recorded into meta"
  pass "fm-pr-check rejects a command-injection PR URL before recording or arming anything"
}

test_non_github_url_rejected() {
  local case_dir rc
  case_dir=$(make_case non-github)

  set +e
  run_pr_check "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "non-github: fm-pr-check should reject a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "non-github: refusal did not explain the expected URL shape"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "non-github: a check shim was armed for a non-GitHub URL"
  pass "fm-pr-check rejects a non-GitHub PR URL before arming the merge poll"
}

test_missing_args_print_usage() {
  local case_dir rc out
  case_dir=$(make_case missing-args)

  # No args at all: usage on stderr, exit 1, never the set -u unbound crash.
  set +e
  out=$(run_pr_check "$case_dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-args: fm-pr-check with no args should exit 1"
  assert_contains "$out" "usage: fm-pr-check.sh <task-id> <pr-url>" "no-arg run did not print usage"
  assert_not_contains "$out" "unbound variable" "no-arg run crashed on an unbound positional"

  # Task id only (the missing-URL shape): same usage guard.
  set +e
  out=$(run_pr_check "$case_dir" task-x1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-args: fm-pr-check with only a task id should exit 1"
  assert_contains "$out" "usage: fm-pr-check.sh <task-id> <pr-url>" "id-only run did not print usage"
  assert_not_contains "$out" "unbound variable" "id-only run crashed on an unbound positional"
  assert_absent "$case_dir/state/task-x1.check.sh" "usage-guarded run still armed a check shim"
  pass "fm-pr-check prints usage and exits 1 on missing required args instead of an unbound-variable crash"
}

# az mock answering the azure-devops extension probe, the pr_head lookup
# (lastMergeSourceCommit.commitId), and the status poll. Args: case_dir head_sha status
add_az_mock() {
  local case_dir=$1 head=$2 status=$3
  cat > "$case_dir/fakebin/az" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-} \${3:-}" in
  "extension show --name") exit 0 ;;
  "repos pr show")
    case " \$* " in
      *" --query lastMergeSourceCommit.commitId "*) printf '%s\n' '$head' ; exit 0 ;;
      *" --query status "*) printf '%s\n' '$status' ; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/az"
}

test_ado_url_accepted_and_poll_behaviors() {
  local case_dir rc shim out
  case_dir=$(make_case ado-wellformed)
  add_az_mock "$case_dir" cafebabecafebabecafebabecafebabecafebabe active
  shim="$case_dir/state/task-x1.check.sh"

  set +e
  run_pr_check "$case_dir" task-x1 https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ado-wellformed: fm-pr-check should accept an Azure DevOps PR URL"
  assert_grep 'pr=https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/42' "$case_dir/state/task-x1.meta" \
    "ado-wellformed: pr= was not recorded"
  assert_grep 'pr_head=cafebabecafebabecafebabecafebabecafebabe' "$case_dir/state/task-x1.meta" \
    "ado-wellformed: pr_head= was not recorded from lastMergeSourceCommit.commitId"
  assert_present "$shim" "ado-wellformed: check shim was not armed"
  assert_grep 'az repos pr show --id 42 --organization https://dev.azure.com/exampleorg --query status -o tsv' "$shim" \
    "ado-wellformed: check shim does not poll PR status via az"

  # Poll behavior, driven through the REAL generated shim with a canned az.
  # active: silence (keep sleeping).
  out=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" || true)
  [ -z "$out" ] || fail "ado-poll: active status should print nothing (got: $out)"
  # completed: the one merged wake line.
  add_az_mock "$case_dir" cafebabecafebabecafebabecafebabecafebabe completed
  out=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" || true)
  [ "$out" = merged ] || fail "ado-poll: completed status should print exactly 'merged' (got: $out)"
  # abandoned: wakes too, with a note distinguishable from merged.
  add_az_mock "$case_dir" cafebabecafebabecafebabecafebabecafebabe abandoned
  out=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" || true)
  assert_contains "$out" "abandoned" "ado-poll: abandoned status should wake with an abandoned note"
  assert_not_contains "$out" "merged" "ado-poll: abandoned wake must not read as merged"
  pass "fm-pr-check accepts an ADO PR URL, records pr=/pr_head=, and its poll is silent/merged/abandoned-aware"
}

test_ado_visualstudio_host_accepted() {
  local case_dir rc
  case_dir=$(make_case ado-vsts)
  add_az_mock "$case_dir" '' active

  set +e
  run_pr_check "$case_dir" task-x1 https://exampleorg.visualstudio.com/proj/_git/repo/pullrequest/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ado-vsts: fm-pr-check should accept a legacy visualstudio.com PR URL"
  assert_grep 'pr=https://exampleorg.visualstudio.com/proj/_git/repo/pullrequest/7' "$case_dir/state/task-x1.meta" \
    "ado-vsts: pr= was not recorded"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "ado-vsts: an empty az head lookup must not record pr_head="
  # The generated poll talks to the modern organization URL either way.
  assert_grep 'az repos pr show --id 7 --organization https://dev.azure.com/exampleorg --query status -o tsv' \
    "$case_dir/state/task-x1.check.sh" \
    "ado-vsts: check shim did not normalize the org URL to dev.azure.com"
  pass "fm-pr-check accepts a legacy visualstudio.com PR URL and polls the normalized org URL"
}

test_ado_preflight_missing_extension_rejected() {
  local case_dir rc
  case_dir=$(make_case ado-no-extension)
  # az exists but has no azure-devops extension: the extension probe fails.
  cat > "$case_dir/fakebin/az" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "extension show") echo "The extension azure-devops is not installed." >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/az"

  set +e
  run_pr_check "$case_dir" task-x1 https://dev.azure.com/exampleorg/proj/_git/repo/pullrequest/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ado-no-extension: fm-pr-check should refuse without the azure-devops extension"
  assert_grep 'az extension add --name azure-devops' "$case_dir/stderr" \
    "ado-no-extension: refusal did not give the actionable remedy"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "ado-no-extension: pr= was recorded despite the failed preflight"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "ado-no-extension: a check shim was armed despite the failed preflight"
  pass "fm-pr-check refuses an ADO PR URL with a clear remedy when the azure-devops extension is missing"
}

test_wellformed_url_accepted
test_injection_url_rejected_before_any_write
test_non_github_url_rejected
test_missing_args_print_usage
test_ado_url_accepted_and_poll_behaviors
test_ado_visualstudio_host_accepted
test_ado_preflight_missing_extension_rejected
