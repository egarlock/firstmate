#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree or retire a
# secondmate home, kill the recorded runtime endpoint, clear volatile
# state, refresh/prune the project's clone for PR-based ship tasks, then print a backlog-refresh
# reminder.
# REFUSES if the worktree holds work that has not LANDED, because treehouse return
# hard-resets the worktree and kills its processes. The landed-work oracle is a
# dirty gate followed by three allow-conditions (ANY one lands it), in order:
#   (a) a dirty worktree (uncommitted changes) is never landed -> always REFUSE,
#       because the reset would discard those changes;
#   then ALLOW when ANY of the following holds, else REFUSE:
#   (b) a recorded landed=<sha> in state/<id>.meta that COVERS HEAD (HEAD is an
#       ancestor of the recorded sha). This is the authoritative verdict written at
#       merge time by bin/fm-pr-merge.sh and bin/fm-merge-local.sh: the merge
#       already happened, so teardown does not re-derive it. This is what makes
#       teardown robust to a no-mistakes run that advanced origin past the local
#       worktree HEAD (local HEAD is an ancestor of the recorded merged head, so
#       the verdict still covers it). Covering HEAD is required because the
#       verdict is about the commits that were merged, not the task: commits made
#       AFTER the merge (late review feedback, a follow-up steer) are not landed,
#       so a landed= that no longer covers HEAD falls through to (c)/(d) instead
#       of allowing. An unresolvable landed= (the pr-<n> placeholder recorded when
#       GitHub returned no head sha) likewise falls through to (c)/(d).
#   (c) HEAD is reachable from a publishing remote-tracking branch (a fork counts).
#       This is the base "landed" definition of prime directive #3: the work is
#       already published, so the reset discards nothing. It is a direct reachability
#       check, cheap and local, NOT a return of the old PR-head-ancestor or patch-id
#       heuristics. The local no-mistakes gate remote (refs/remotes/no-mistakes/*) is
#       excluded, so a branch pushed there during a failed validation run does not
#       count as landed.
#   (d) with no landed= recorded and no publishing remote reachable, the single
#       content fallback: is the branch's content already present in the up-to-date
#       default branch? After any merge (squash, rebase, ff, or a local-only fast-
#       forward) the change is in the default branch regardless of whether the
#       branch's own commits survived. content_in_default fetches the default branch
#       fresh and refuses when inconclusive, so genuinely unlanded work still REFUSES.
# The evaluation order is deliberate: (b) and (c) are cheap and local, and only (d)
# does a network fetch, so a fetch is attempted only when it is actually needed.
# Uncommitted changes are never landed. The local-only path needs no special case:
# bin/fm-merge-local.sh records landed= on the approved local merge, and the (d)
# content check also recognizes a purely local default branch (refs/heads/<default>)
# when there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-git-lib.sh
. "$SCRIPT_DIR/fm-git-lib.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(fm_backend_of_meta "$META")
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

# Bounded network run. The only network reach left in the landed-work check is the
# content fallback's git fetch of the default branch; a hung remote must never
# foreground-block teardown, which the supervision doctrine forbids. Prefer
# timeout/gtimeout, then a perl watchdog (same fallback chain as
# bin/fm-crew-state.sh), and only run unbounded when no timeout mechanism exists at
# all - never silently skip the call, since the content check depends on its result.
# On timeout the wrapped command exits non-zero, so the content check is inconclusive
# and teardown refuses rather than false-allowing.
NET_TIMEOUT=${FM_TEARDOWN_NET_TIMEOUT:-30}
case "$NET_TIMEOUT" in ''|*[!0-9]*) NET_TIMEOUT=30 ;; esac
if command -v timeout >/dev/null 2>&1; then NET_TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then NET_TIMEOUT_CMD=gtimeout
elif command -v perl >/dev/null 2>&1; then NET_TIMEOUT_CMD=perl
else NET_TIMEOUT_CMD=none
fi
fm_net() {  # <cmd> <args...> — run a single network command time-bounded, preserving stdout + exit code
  case "$NET_TIMEOUT_CMD" in
    timeout)  timeout "$NET_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$NET_TIMEOUT" "$@" ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NET_TIMEOUT" "$@" ;;
    *)        "$@" ;;
  esac
}

# The content-in-default landed check relies on `git merge-tree --write-tree`,
# which git gained in 2.38. On older git the merge-tree call would fail silently
# and teardown would false-refuse landed work with no explanation; probe once so
# the operator gets a clear diagnostic instead.
git_supports_merge_tree_write_tree() {
  local v major minor
  v=$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  [ -n "$v" ] || return 1
  major=${v%%.*}
  minor=${v#*.}
  [ "$major" -gt 2 ] && return 0
  [ "$major" -eq 2 ] && [ "$minor" -ge 38 ] && return 0
  return 1
}


meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" | cut -d= -f2- || true
}

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

remove_copilot_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.copilot-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${COPILOT_HOME:-$HOME/.copilot}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  if ! git_supports_merge_tree_write_tree; then
    echo "error: content-in-default landed check needs git >= 2.38 for 'git merge-tree --write-tree' (got: $(git --version 2>/dev/null)); upgrade git or verify the merge manually before teardown." >&2
    return 1
  fi
  name=$(fm_default_branch "$PROJ") || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    fm_net git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Is HEAD reachable from a publishing remote-tracking branch? The work is landed in
# the base sense of prime directive #3 when its commits are already published on some
# remote (a fork counts, for the upstream-contribution-on-local-only workflow). List
# HEAD's commits that are NOT reachable from any remote-tracking branch, excluding the
# local no-mistakes gate remote (refs/remotes/no-mistakes/*) so a branch pushed there
# during a failed validation run does not count. An empty result means everything on
# HEAD is already published -> reachable. This is a cheap, local, direct reachability
# check, not a resurrection of the old PR-head-ancestor or patch-id heuristics.
# FAIL CLOSED: a git failure must read as "not reachable", never as the empty
# "everything published" output, so git's own exit status is checked (the commit
# count is bounded inside git with -5 rather than a piped head, which would mask it).
head_reachable_from_publishing_remote() {
  local unpushed
  unpushed=$(git -C "$WT" log --oneline -5 HEAD --not --exclude=no-mistakes/'*' --remotes -- 2>/dev/null) || return 1
  [ -z "$unpushed" ]
}

# Does the recorded landed= verdict cover the worktree's current HEAD? True iff
# the recorded sha resolves to a commit and HEAD is its ancestor (equal counts).
# A landed= that does NOT cover HEAD means commits were made after the merge -
# late review feedback, a follow-up steer, the captain typing into the pane -
# and those commits are NOT landed; the caller falls through to the reachability
# and content checks instead of allowing on the stale verdict. The pr-<n>
# placeholder (recorded when GitHub returned no head sha) never resolves, so it
# also falls through. The no-mistakes-advanced-origin case still allows here:
# local HEAD lags the recorded merged head, so it IS an ancestor of it.
landed_covers_head() {
  git -C "$WT" rev-parse --verify -q "$LANDED^{commit}" >/dev/null 2>&1 || return 1
  git -C "$WT" merge-base --is-ancestor HEAD "$LANDED" 2>/dev/null
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  if fm_tasks_axi_backend_available "$CONFIG"; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      secondmate)
        done_cmd="tasks-axi done $ID --note \"retired\""
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    ( cd "$FM_ROOT" && treehouse return --force "$abs_home_path" ) || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return 1
    }
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_t=$(meta_value "$child_meta" window)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ -n "$child_t" ]; then
      fm_backend_kill "$(fm_backend_of_meta "$child_meta")" "$child_t" 2>/dev/null || true
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home"
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id"
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend" "$child_wt/.fm-copilot-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        ( cd "$child_proj" && treehouse return --force "$child_wt" ) || safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    remove_copilot_turnend_auth "$sub_state" "$child_id"
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.check.sh" "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.grok-turnend-token" "$sub_state/$child_id.copilot-turnend-token"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  cleanup_firstmate_home_children "$HOME_PATH"
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = secondmate ]; then
    :
  elif [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$DATA/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  else
    # The landed-work oracle (see the header comment): a dirty gate, then ALLOW on
    # any one of three conditions, else REFUSE:
    #   (a) dirty worktree              -> always REFUSE (the reset would discard it)
    #   (b) landed=<sha> covering HEAD  -> ALLOW (the merge already happened AND
    #       nothing was committed past it; a stale verdict falls through)
    #   (c) HEAD on a publishing remote -> ALLOW (already published; fork counts)
    #   (d) else content in default     -> ALLOW, else REFUSE (single fallback fetch)
    # FAIL CLOSED before the oracle runs: if git cannot even resolve HEAD in the
    # worktree (broken .git gitfile pointer, corrupted repo, a plain non-git dir),
    # every downstream git read would emit empty output that reads as "clean" and
    # "everything published" - an ALLOW that would destroy whatever the directory
    # holds. Refuse loudly instead.
    if ! git -C "$WT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      echo "REFUSED: worktree $WT is unreadable by git (cannot resolve HEAD)." >&2
      echo "The landed-work oracle cannot run on it, so nothing can be proven landed. Investigate the worktree (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$|\.fm-copilot-turnend$)' | head -1 || true)
    if [ -n "$dirty" ]; then
      # (a) Uncommitted changes are never landed and the reset would discard them;
      # always refuse, regardless of whether the committed work itself has landed.
      echo "REFUSED: worktree $WT has uncommitted changes." >&2
      echo "uncommitted changes present" >&2
      echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
    LANDED=$(grep '^landed=' "$META" | tail -1 | cut -d= -f2- || true)
    # Evaluate the allow-conditions cheapest-first: (b) the recorded verdict and (c)
    # the local reachability check need no network, so only (d) fetches, and only when
    # neither (b) nor (c) already landed the work. (b) allows only when the recorded
    # sha covers HEAD - presence alone would let commits made AFTER the merge be
    # silently destroyed by the reset.
    landed_ok=0
    if [ -n "$LANDED" ] && landed_covers_head; then landed_ok=1; fi
    if [ "$landed_ok" != 1 ] && ! head_reachable_from_publishing_remote && ! content_in_default; then
      echo "REFUSED: worktree $WT has work that has not landed." >&2
      echo "No recorded merge (landed=) covers HEAD, HEAD is not reachable from any publishing remote, and the branch's content is not in the default branch." >&2
      echo "Land its PR (bin/fm-pr-merge.sh), merge it locally (bin/fm-merge-local.sh after the captain approves), push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      exit 1
    fi
  fi
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend" "$WT/.fm-copilot-turnend"
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project.
  ( cd "$PROJ" && treehouse return --force "$WT" )
fi

fm_backend_kill "$BACKEND" "$T" 2>/dev/null || true
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID"
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID"
remove_copilot_turnend_auth "$STATE" "$ID"
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token" "$STATE/$ID.copilot-turnend-token"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_refresh_reminder
