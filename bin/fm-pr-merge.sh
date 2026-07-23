#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR URL is parsed by bin/fm-pr-lib.sh; GitHub and Azure
# DevOps are mergeable here, and a GitLab URL is still refused until merge
# parity lands for it.
#
# GitHub: the derived owner/repository and PR number are passed to gh-axi as
# separate arguments. Merge method defaults to --squash when the caller passes
# none of --squash, --merge, --rebase, or --method after the optional --
# separator. Extra args must not include --repo or -R because the repository
# comes only from the URL.
#
# Azure DevOps: the PR is completed via
# `az repos pr update --id <n> --status completed --organization <org-url>`,
# addressed by the canonical organization URL the parser derives (the legacy
# <org>.visualstudio.com spelling completes through dev.azure.com too). The
# merge strategy is governed by ADO branch policy, so extra args after -- are
# refused for an ADO URL rather than silently dropped.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args, GitHub only>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path merges only GitHub and Azure DevOps. The provider check
# holds the GitLab refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github|azuredevops) ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
ADO_ORG_URL=$FM_PR_ADO_ORG_URL
ADO_PROJECT=$FM_PR_ADO_PROJECT
shift 2
[ "${1:-}" = "--" ] && shift

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
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

case "$PROVIDER" in
  github)
    reject_repo_overrides "$@" || exit 1
    ;;
  azuredevops)
    if [ "$#" -gt 0 ]; then
      echo "error: extra merge args are not supported for Azure DevOps PRs; the merge strategy is governed by ADO branch policy" >&2
      exit 1
    fi
    ;;
esac

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# For an ADO URL this also runs fm_ado_preflight, so a missing az CLI or
# azure-devops extension refuses with a remedy before anything merges.
"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

case "$PROVIDER" in
  github)
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  azuredevops)
    # Completing the PR prints the whole PR JSON on success; keep stdout quiet
    # and report one line instead. A failure surfaces on stderr and aborts via
    # set -e.
    az repos pr update --id "$PR_NUMBER" --status completed --organization "$ADO_ORG_URL" >/dev/null
    echo "completed: ADO PR $PR_NUMBER in $ADO_ORG_URL/$ADO_PROJECT"
    ;;
esac

# TODO(wave D): once the teardown landed-verdict oracle lands, record
# landed=<sha> here as part of the merge itself - from the recorded pr_head=
# for GitHub and from the completed PR's lastMergeCommit.commitId
# (az repos pr show --query lastMergeCommit.commitId) for Azure DevOps, with
# the pr-<n> placeholder as the fallback - so teardown reads the verdict
# instead of re-deriving it. Until then teardown keeps using its
# remote-reachability and content checks for both providers.
