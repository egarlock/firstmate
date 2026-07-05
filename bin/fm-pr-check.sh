#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and the forge's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR reached a terminal state
# (the watcher's check contract: output = wake firstmate, silence = keep
# sleeping).
#
# Accepts a GitHub PR URL (https://github.com/<owner>/<repo>/pull/<n>, polled
# via gh) or an Azure DevOps PR URL
# (https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<n>, legacy
# <org>.visualstudio.com host tolerated, polled via the az CLI's azure-devops
# extension; status `completed` wakes as merged, `abandoned` wakes with its own
# note, `active` stays silent).
#
# The PR URL is validated against the exact per-forge shapes in
# bin/fm-pr-url-lib.sh before it is used, because the generated
# state/<id>.check.sh is later EXECUTED by the watcher. The URL originates in
# crewmate-authored status text ("done: PR <url> checks green"), so an
# unvalidated URL interpolated into that script is a command-injection vector:
# anything able to write a status line could run code in firstmate's context.
# fm-pr-merge.sh sources the same lib, so the two paths cannot diverge.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# shellcheck source=bin/fm-pr-url-lib.sh
. "$SCRIPT_DIR/fm-pr-url-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
[ $# -ge 2 ] || { echo "usage: fm-pr-check.sh <task-id> <pr-url>" >&2; exit 1; }
ID=$1
URL=$2

# Validate/classify the PR URL before it is recorded into meta or interpolated
# into the generated, watcher-executed state/<id>.check.sh (see header).
fm_pr_url_parse "$URL" || exit 1

# An Azure DevOps URL is driven entirely through the az CLI; fail fast with a
# remedy before recording anything if the CLI or its extension is absent.
if [ "$FM_PR_KIND" = azuredevops ]; then
  fm_ado_preflight || exit 1
fi

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  PR_HEAD=
  case "$FM_PR_KIND" in
    github)
      WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
      if [ -n "$WT" ] && [ -d "$WT" ]; then
        if command -v gh >/dev/null 2>&1; then
          if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
            PR_HEAD=$REMOTE_HEAD
          fi
        fi
      fi
      ;;
    azuredevops)
      # The PR's source-branch head is in the show JSON already; needs no repo
      # context, so no worktree cd. Tolerate lookup failure like the gh path.
      if REMOTE_HEAD=$(az repos pr show --id "$FM_PR_NUMBER" --organization "$FM_PR_ADO_ORG_URL" --query lastMergeSourceCommit.commitId -o tsv 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
      # az tsv renders a missing field as empty, but be defensive about a
      # literal None leaking in from other output modes.
      [ "$PR_HEAD" = None ] && PR_HEAD=
      ;;
  esac
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

case "$FM_PR_KIND" in
  github)
    cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
    ;;
  azuredevops)
    # Same contract and structure as the GitHub shim: one bounded CLI call,
    # print only on a terminal state. `abandoned` is ADO's closed-without-merge,
    # so it wakes with a distinguishable note instead of a false "merged".
    cat > "$STATE/$ID.check.sh" <<EOF
status=\$(az repos pr show --id $FM_PR_NUMBER --organization $FM_PR_ADO_ORG_URL --query status -o tsv 2>/dev/null)
[ "\$status" = "completed" ] && echo "merged"
[ "\$status" = "abandoned" ] && echo "abandoned: PR closed without merging"
EOF
    ;;
esac
echo "armed: state/$ID.check.sh polls $URL"
