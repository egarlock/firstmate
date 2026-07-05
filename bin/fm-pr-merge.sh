#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, then recording landed=<sha> once
# the merge itself succeeds. That landed= line is the authoritative verdict
# bin/fm-teardown.sh consults - the merge already happened, so teardown need not
# re-derive "is this work landed?" from remote/PR-head heuristics.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` or `az repos pr update` directly.
#
# The PR URL may be GitHub or Azure DevOps; bin/fm-pr-url-lib.sh classifies it.
#
# GitHub: gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does
# not parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Azure DevOps: merges by completing the PR via
# `az repos pr update --id <n> --status completed --organization <org url>`
# (default merge strategy - the strategy is governed by ADO branch policy, so
# the `--` extra-args passthrough is refused for ADO URLs), then records
# landed= from the completed PR's lastMergeCommit, falling back to the pr-<n>
# placeholder exactly like the GitHub path when no sha is available.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args, GitHub only>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args, GitHub only>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args, GitHub only>]}
shift 2
[ "${1:-}" = "--" ] && shift

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# shellcheck source=bin/fm-pr-url-lib.sh
. "$SCRIPT_DIR/fm-pr-url-lib.sh"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

fm_pr_url_parse "$URL" || exit 1

case "$FM_PR_KIND" in
  github)
    reject_repo_overrides "$@" || exit 1
    ;;
  azuredevops)
    if [ $# -gt 0 ]; then
      echo "error: extra merge args (a merge method after --) are not supported for Azure DevOps PRs; the merge strategy is governed by ADO branch policy (got: $*)" >&2
      exit 1
    fi
    fm_ado_preflight || exit 1
    ;;
esac

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

case "$FM_PR_KIND" in
  github)
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    # ${merge_args[@]+"..."} guards the empty-array case: when the caller passed an
    # explicit merge method, merge_args stays empty, and a bare "${merge_args[@]}"
    # under `set -u` is an "unbound variable" error on bash < 4.4 (stock /bin/bash on
    # macOS is 3.2). "$@" is a special parameter and is always safe empty.
    gh-axi pr merge "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
    ;;
  azuredevops)
    # Completing the PR prints the whole PR JSON on success; keep stdout quiet
    # and report one line instead. Failures still surface on stderr and abort
    # via set -e before any landed= is recorded.
    az repos pr update --id "$FM_PR_NUMBER" --status completed --organization "$FM_PR_ADO_ORG_URL" >/dev/null
    echo "completed: ADO PR $FM_PR_NUMBER in $FM_PR_ADO_ORG_URL/$FM_PR_ADO_PROJECT"
    ;;
esac

# The merge succeeded (set -e would have exited above otherwise). Record the
# authoritative "this task's work reached its destination" fact so bin/fm-teardown.sh
# can allow teardown without re-deriving it from remote/PR heuristics. GitHub records
# the merged PR head when fm-pr-check.sh captured it; ADO records the completed PR's
# merge commit. Either falls back to the PR number as a non-empty presence marker -
# teardown only needs the field to be present, but the sha is the better breadcrumb.
case "$FM_PR_KIND" in
  github)
    LANDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
    ;;
  azuredevops)
    LANDED=$(az repos pr show --id "$FM_PR_NUMBER" --organization "$FM_PR_ADO_ORG_URL" --query lastMergeCommit.commitId -o tsv 2>/dev/null || true)
    # az tsv renders a missing field as empty; be defensive about a literal None.
    [ "$LANDED" = None ] && LANDED=
    ;;
esac
[ -n "$LANDED" ] || LANDED="pr-$FM_PR_NUMBER"
grep -qxF "landed=$LANDED" "$META" || echo "landed=$LANDED" >> "$META"
