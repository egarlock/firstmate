#!/usr/bin/env bash
# fm-hook-sweep.sh - remove orphaned turn-end hook registry tokens.
#
# grok and copilot install ONE firstmate-owned global turn-end hook (under
# ${GROK_HOME:-$HOME/.grok}/hooks and ${COPILOT_HOME:-$HOME/.copilot}/hooks). The
# hook fires only for a workspace holding a .fm-<harness>-turnend pointer whose
# token matches a per-task registry entry under hooks/fm-turn-end.d/<token>. Each
# registry token file's content is the absolute path to that task's
# state/<id>.turn-ended. fm-teardown removes the registry token as part of a clean
# teardown, but a task that DIES without teardown (crash, killed pane, discarded
# worktree) leaves its token behind, so the global registry slowly accumulates
# cruft that never fires again.
#
# This sweep removes such orphans. It is home-AGNOSTIC by construction: a token
# describes its own owning home via its content path, so a sweep from any home
# cleans genuine orphans across all homes while never touching another home's LIVE
# token (whose task meta and worktree pointer still exist). A token is orphaned iff
# its owning task no longer exists:
#   - its state/<id>.meta is gone (the task record was removed), OR
#   - its recorded worktree is gone, or that worktree's .fm-<harness>-turnend
#     pointer is missing or now names a different token (a superseding respawn).
#
# A freshly-created token being wired up by an in-flight spawn (mktemp'd, content
# written before meta) is protected two ways: an empty token file is always left
# alone, and only tokens older than FM_HOOK_SWEEP_MIN_AGE_MINS (default 2; set <= 0
# to disable the age guard, e.g. in tests) are considered. Malformed/unreadable
# content is left untouched (conservative: never delete what we cannot classify).
#
# Prints one summary line per harness only when it removed something; silent
# otherwise. Always exits 0 so callers (bootstrap, teardown) can run it
# best-effort. Bash 3.2 safe.
set -u

MIN_AGE=${FM_HOOK_SWEEP_MIN_AGE_MINS:-2}

# _token_is_orphan <registry-token-file> <harness>: 0 iff the token is orphaned.
_token_is_orphan() {
  local f=$1 h=$2 content state_dir base id meta wt ptr ptok tok_name
  tok_name=${f##*/}
  # Registry token filename shape written by fm-spawn (fm.<12 chars>). Anything
  # else is not ours; leave it.
  case "$tok_name" in
    fm.????????????) : ;;
    *) return 1 ;;
  esac
  content=$(head -n 1 "$f" 2>/dev/null) || return 1
  # Empty (spawn wrote the file but not its content yet) -> not an orphan; leave.
  [ -n "$content" ] || return 1
  # Content must be an absolute state/<id>.turn-ended path; else unclassifiable.
  case "$content" in
    /*.turn-ended) : ;;
    *) return 1 ;;
  esac
  state_dir=${content%/*}
  base=${content##*/}
  id=${base%.turn-ended}
  [ -n "$id" ] || return 1
  meta="$state_dir/$id.meta"
  # Task record gone -> orphan.
  [ -f "$meta" ] || return 0
  # Meta files are append-only records, so every reader is LAST-wins (tail -1),
  # matching fm_meta_get and the other meta readers; a first-match read would
  # silently pick a stale value if a key were ever re-appended.
  wt=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
  # No worktree recorded or the worktree directory is gone -> orphan.
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  ptr="$wt/.fm-$h-turnend"
  # Worktree pointer missing -> orphan.
  [ -f "$ptr" ] || return 0
  ptok=$(sed -n 's/^token=//p' "$ptr" | tail -1)
  # Pointer now names a different token (superseded by a respawn) -> orphan.
  [ "$ptok" = "$tok_name" ] || return 0
  return 1
}

# _sweep_harness <hooks-dir> <harness>: remove orphaned tokens in <hooks-dir>,
# echo the count removed.
_sweep_harness() {
  local dir=$1 h=$2 removed=0 f
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  # Age guard: only consider tokens older than MIN_AGE minutes (protect in-flight
  # spawns). MIN_AGE <= 0 disables it.
  local find_age=()
  case "$MIN_AGE" in
    ''|*[!0-9-]*) find_age=(-mmin +2) ;;
    *) [ "$MIN_AGE" -gt 0 ] && find_age=(-mmin "+$MIN_AGE") ;;
  esac
  # NUL-safe iteration is overkill (token names are fm.<alnum>); a simple glob is
  # bash 3.2 fine. Use find so the age predicate applies uniformly.
  # bash 3.2 + set -u: expanding an empty array as "${a[@]}" is an unbound-variable
  # error, so guard with ${a[@]+...}.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if _token_is_orphan "$f" "$h"; then
      rm -f "$f" && removed=$((removed + 1))
    fi
  done <<EOF
$(find "$dir" -maxdepth 1 -type f -name 'fm.*' ${find_age[@]+"${find_age[@]}"} 2>/dev/null)
EOF
  printf '%s\n' "$removed"
}

main() {
  local grok_dir copilot_dir n_grok n_copilot
  grok_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  copilot_dir="${COPILOT_HOME:-$HOME/.copilot}/hooks/fm-turn-end.d"
  n_grok=$(_sweep_harness "$grok_dir" grok)
  n_copilot=$(_sweep_harness "$copilot_dir" copilot)
  [ "$n_grok" -gt 0 ] && echo "HOOK_SWEEP: removed $n_grok orphaned grok turn-end token(s)"
  [ "$n_copilot" -gt 0 ] && echo "HOOK_SWEEP: removed $n_copilot orphaned copilot turn-end token(s)"
  return 0
}

main "$@"
