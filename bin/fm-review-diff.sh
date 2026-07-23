#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
#
# The COMPARE side must be the PR's current head, not the local branch. After a
# no-mistakes fix round pushes to the open PR, the local worktree branch lags,
# and a captain approving that diff approves a change that omits fixes already on
# the PR - unattended under yolo=on. So when state/<id>.meta records pr=, the
# compare ref is resolved from the forge:
#   github       ALWAYS a freshly fetched refs/pull/<n>/head. A recorded pr_head=
#                is only the offline fallback; a stale recorded SHA must never
#                win over a reachable remote PR head.
#   azuredevops  ADO does not publish refs/pull/<n>/head (it publishes
#                refs/pull/<n>/merge, a merge commit into the target branch,
#                which is NOT the PR head and would diff wrong). So ADO re-queries
#                the LIVE head via `az repos pr show ... lastMergeSourceCommit`,
#                which is the analogue of GitHub's re-fetch: the recorded pr_head=
#                is a one-shot snapshot fm-pr-check.sh took when the PR was first
#                recorded and nothing refreshes it, so preferring it would review
#                a pre-fix SHA. A recorded pr_head= is the fallback for when az is
#                absent or the query fails. Either way the resolved commit is
#                fetched when it is not already local.
# If neither can be resolved, fall back to the local branch WITH a warning.
# Without pr=, compare the local branch as before.
# The resolved compare side is always printed alongside the base, so an approval
# (unattended under yolo=on) records exactly what was reviewed.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# shellcheck source=bin/fm-git-lib.sh
. "$SCRIPT_DIR/fm-git-lib.sh"
# shellcheck source=bin/fm-pr-url-lib.sh
. "$SCRIPT_DIR/fm-pr-url-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

DEFAULT=$(fm_default_branch "$PROJ") || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

# fetch_pull_head <n>: GitHub only. Fetch refs/pull/<n>/head into a PRIVATE ref
# so a later base-branch fetch cannot clobber the compare tip via FETCH_HEAD, and
# so a stale local object is never reviewed. Echoes the resolved commit.
# The private ref is deleted once it has been resolved - the caller needs the
# COMMIT, not a permanent ref: project clones are long-lived and reviewed
# repeatedly, so a kept ref would accumulate one entry per reviewed PR and pin
# each PR's whole graph against GC. Deletion also runs on the failure paths, so a
# partial fetch never leaves the ref behind.
fetch_pull_head() {
  local n=$1 resolved rc=1 ref
  ref="refs/fm-review/pull/$n/head"
  if git -C "$WT" remote get-url origin >/dev/null 2>&1 &&
     git -C "$WT" fetch --quiet origin "+refs/pull/$n/head:$ref" >/dev/null 2>&1 &&
     resolved=$(git -C "$WT" rev-parse --verify "$ref^{commit}" 2>/dev/null) &&
     [ -n "$resolved" ]; then
    printf '%s' "$resolved"
    rc=0
  fi
  git -C "$WT" update-ref -d "$ref" >/dev/null 2>&1 || true
  return "$rc"
}

# ado_live_head: Azure DevOps only. Re-query the PR's CURRENT source-branch head,
# the analogue of GitHub's pull-head re-fetch, so a fix round pushed after the PR
# was first recorded is reviewed instead of the one-shot recorded pr_head=.
# Reads the FM_PR_* values a successful fm_pr_url_parse set. Best-effort and
# quiet: no az CLI, no extension, or a failed query just means "fall back".
ado_live_head() {
  local head
  fm_ado_preflight >/dev/null 2>&1 || return 1
  head=$(az repos pr show --id "$FM_PR_NUMBER" --organization "$FM_PR_ADO_ORG_URL" \
    --query lastMergeSourceCommit.commitId -o tsv 2>/dev/null) || return 1
  # az tsv renders a missing field as empty; be defensive about a literal None.
  case "$head" in
    ''|None) return 1 ;;
  esac
  printf '%s' "$head"
}

# recorded_head_commit <sha>: resolve a recorded pr_head= to a usable commit.
# Local objects win (cheap, and keeps the offline path exact); otherwise try to
# fetch that one commit directly, which is how an ADO PR head becomes available
# without a published pull ref. Best-effort: failure just means "unresolvable".
recorded_head_commit() {
  local sha=$1
  [ -n "$sha" ] || return 1
  # Shape-gate first. The value arrives from meta (crewmate-adjacent text) or from
  # an az query, and is handed to git as a revision; anything that is not a plain
  # object name is not a PR head, so reject it rather than let git interpret it.
  case "$sha" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#sha}" -ge 7 ] || return 1
  if git -C "$WT" cat-file -e "$sha^{commit}" 2>/dev/null; then
    printf '%s' "$sha"
    return 0
  fi
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "$sha" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
  printf '%s' "$sha"
}

# resolve_pr_head <pr-url> <recorded-pr_head>: the compare tip for an open PR.
# Echoes "<commit> <how-it-was-resolved>" so the caller can report the compare
# side; the provenance travels with the value because this runs in a subshell.
resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 resolved live
  # Classify the forge; the shape error is this lib's, and an unparseable pr=
  # simply means "no forge-specific lookup to do", so keep it quiet here.
  if fm_pr_url_parse "$pr_url" 2>/dev/null; then
    case "$FM_PR_KIND" in
      github)
        if resolved=$(fetch_pull_head "$FM_PR_NUMBER"); then
          printf '%s refs/pull/%s/head' "$resolved" "$FM_PR_NUMBER"
          return 0
        fi
        ;;
      azuredevops)
        if live=$(ado_live_head) && resolved=$(recorded_head_commit "$live"); then
          printf '%s az lastMergeSourceCommit' "$resolved"
          return 0
        fi
        ;;
    esac
  fi
  # The fallback for both forges: GitHub when the remote is unreachable, ADO when
  # az is absent or its query failed. The recorded SHA beats a lagging local
  # branch, but is never preferred over a successful live lookup above.
  if resolved=$(recorded_head_commit "$recorded_head"); then
    printf '%s recorded pr_head=' "$resolved"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
COMPARE_DESC="local branch $BRANCH"
if [ -n "$PR_URL" ]; then
  if RESOLUTION=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=${RESOLUTION%% *}
    COMPARE_DESC="PR head $COMPARE_REF (via ${RESOLUTION#* })"
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
echo "compare: $COMPARE_DESC"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
