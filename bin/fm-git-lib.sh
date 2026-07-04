# shellcheck shell=bash
# fm-git-lib.sh — shared git helpers for firstmate.
# Usage: . bin/fm-git-lib.sh
#
# ONE definition of "what is this repo's default branch". Six scripts used to
# carry a byte-identical copy of this fallback (fm-teardown, fm-merge-local,
# fm-review-diff, fm-fleet-sync, fm-ff-lib, fm-tangle-lib); they now all source
# this file. This is also the natural home for any future per-VCS default-branch
# quirks (e.g. an Azure DevOps adapter), so the fallback lives in exactly one place.
#
# Idempotent: safe to source more than once (fm-bootstrap sources both fm-ff-lib
# and fm-tangle-lib, each of which sources this).

if [ -z "${FM_GIT_LIB_SOURCED:-}" ]; then
  FM_GIT_LIB_SOURCED=1

  # Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
  # then fall back to a local main/master. Echoes the name, or returns 1.
  fm_default_branch() {
    local dir=$1 ref branch
    ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$ref" ]; then
      printf '%s\n' "${ref#origin/}"
      return 0
    fi
    for branch in main master; do
      if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
        printf '%s\n' "$branch"
        return 0
      fi
    done
    return 1
  }
fi
