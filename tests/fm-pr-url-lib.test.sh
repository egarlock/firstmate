#!/usr/bin/env bash
# Tests for bin/fm-pr-url-lib.sh: the ONE PR-URL classifier/parser shared by
# fm-pr-check.sh and fm-pr-merge.sh. Its accepted character classes are a
# security boundary (the URL is interpolated into the watcher-EXECUTED
# state/<id>.check.sh), so classification and extraction are pinned here.
#
# Matrix:
#   (a) GitHub PR URL -> kind=github with owner/repo/number extracted
#   (b) dev.azure.com PR URL -> kind=azuredevops with org/project/repo/number
#       and the normalized https://dev.azure.com/<org> organization URL
#   (c) legacy <org>.visualstudio.com PR URL -> same azuredevops extraction
#   (d) unknown forge (gitlab) -> refused with the shared shape error
#   (e) garbage / command-substitution URLs -> refused
#   (f) trailing-hyphen GitHub owner -> refused (historical parser rule)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-pr-url-lib.sh
. "$ROOT/bin/fm-pr-url-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-url-lib-tests)
# fm_test_tmproot runs in a command-substitution subshell whose EXIT cleanup
# already fired; recreate the root like the other suites' make_case mkdirs do.
mkdir -p "$TMP_ROOT"

test_github_url_classified() {
  fm_pr_url_parse https://github.com/my-org/my.repo/pull/126/ 2>"$TMP_ROOT/err" \
    || fail "github: well-formed URL was refused"
  [ "$FM_PR_KIND" = github ] || fail "github: kind was $FM_PR_KIND, not github"
  [ "$FM_PR_OWNER" = my-org ] || fail "github: owner was $FM_PR_OWNER"
  [ "$FM_PR_REPO" = my.repo ] || fail "github: repo was $FM_PR_REPO"
  [ "$FM_PR_NUMBER" = 126 ] || fail "github: number was $FM_PR_NUMBER"
  pass "fm_pr_url_parse classifies a GitHub PR URL and extracts owner/repo/number"
}

test_dev_azure_url_classified() {
  fm_pr_url_parse https://dev.azure.com/exampleorg/Example.Project/_git/example-repo/pullrequest/42 2>"$TMP_ROOT/err" \
    || fail "ado: well-formed dev.azure.com URL was refused"
  [ "$FM_PR_KIND" = azuredevops ] || fail "ado: kind was $FM_PR_KIND, not azuredevops"
  [ "$FM_PR_ADO_ORG" = exampleorg ] || fail "ado: org was $FM_PR_ADO_ORG"
  [ "$FM_PR_ADO_PROJECT" = Example.Project ] || fail "ado: project was $FM_PR_ADO_PROJECT"
  [ "$FM_PR_ADO_REPO" = example-repo ] || fail "ado: repo was $FM_PR_ADO_REPO"
  [ "$FM_PR_NUMBER" = 42 ] || fail "ado: number was $FM_PR_NUMBER"
  [ "$FM_PR_ADO_ORG_URL" = https://dev.azure.com/exampleorg ] \
    || fail "ado: org URL was $FM_PR_ADO_ORG_URL"
  pass "fm_pr_url_parse classifies a dev.azure.com PR URL and extracts org/project/repo/number"
}

test_visualstudio_host_classified() {
  fm_pr_url_parse 'https://exampleorg.visualstudio.com/My%20Project/_git/example-repo/pullrequest/7/' 2>"$TMP_ROOT/err" \
    || fail "vsts: legacy visualstudio.com URL was refused"
  [ "$FM_PR_KIND" = azuredevops ] || fail "vsts: kind was $FM_PR_KIND, not azuredevops"
  [ "$FM_PR_ADO_ORG" = exampleorg ] || fail "vsts: org was $FM_PR_ADO_ORG"
  [ "$FM_PR_ADO_PROJECT" = 'My%20Project' ] || fail "vsts: project was $FM_PR_ADO_PROJECT"
  [ "$FM_PR_ADO_REPO" = example-repo ] || fail "vsts: repo was $FM_PR_ADO_REPO"
  [ "$FM_PR_NUMBER" = 7 ] || fail "vsts: number was $FM_PR_NUMBER"
  # The az CLI wants the modern organization URL either way.
  [ "$FM_PR_ADO_ORG_URL" = https://dev.azure.com/exampleorg ] \
    || fail "vsts: org URL was not normalized to dev.azure.com ($FM_PR_ADO_ORG_URL)"
  pass "fm_pr_url_parse classifies a legacy visualstudio.com PR URL and normalizes the org URL"
}

# Refusal helper: URL must be refused (rc 1, kind unknown, shared shape error).
expect_refused() {
  local label=$1 url=$2 rc
  set +e
  fm_pr_url_parse "$url" 2>"$TMP_ROOT/refuse-err"
  rc=$?
  set -e
  expect_code 1 "$rc" "$label: URL should be refused"
  [ "$FM_PR_KIND" = unknown ] || fail "$label: kind was $FM_PR_KIND, not unknown"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$TMP_ROOT/refuse-err" \
    "$label: refusal did not name the GitHub shape"
  assert_grep 'https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<number>' "$TMP_ROOT/refuse-err" \
    "$label: refusal did not name the Azure DevOps shape"
}

test_unknown_and_garbage_urls_refused() {
  expect_refused gitlab 'https://gitlab.com/example/repo/-/merge_requests/1'
  # shellcheck disable=SC2016  # Literal command substitution probes parsing safety.
  expect_refused injection 'https://github.com/x/x/pull/1$(touch pwned)'
  # shellcheck disable=SC2016  # Literal command substitution probes parsing safety.
  expect_refused ado-injection 'https://dev.azure.com/org/proj$(touch pwned)/_git/repo/pullrequest/1'
  expect_refused garbage 'not a url at all'
  expect_refused ado-missing-repo 'https://dev.azure.com/org/proj/pullrequest/1'
  pass "fm_pr_url_parse refuses unknown forges, injection attempts, and garbage"
}

test_trailing_hyphen_github_owner_refused() {
  expect_refused trailing-hyphen 'https://github.com/bad-/repo/pull/3'
  pass "fm_pr_url_parse keeps the historical trailing-hyphen GitHub owner refusal"
}

test_github_url_classified
test_dev_azure_url_classified
test_visualstudio_host_classified
test_unknown_and_garbage_urls_refused
test_trailing_hyphen_github_owner_refused
