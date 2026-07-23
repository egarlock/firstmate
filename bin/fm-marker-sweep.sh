#!/usr/bin/env bash
# fm-marker-sweep.sh - remove orphaned per-task watcher/daemon marker sidecars.
#
# bin/fm-watch.sh and bin/fm-supervise-daemon.sh keep per-task suppression
# sidecars in state/. The families, re-derived from the writers on this tree:
#   task-keyed (id through `tr ':/.' '___'`):
#     .hb-surfaced-, .subsuper-seen-status-, .subsuper-stale-, .subsuper-paused-
#   signal-file-keyed (id.status / id.turn-ended through `tr '.' '_'`):
#     .seen-
#   window-keyed (the recorded window= through `tr ':/.' '___'`):
#     .hash-, .count-, .stale-, .stale-since-, .wedge-escalations-,
#     .paused-, .paused-rechecked-, .paused-resurfaced-
# fm-teardown.sh removes a task's markers as part of a clean teardown, but tasks
# torn down before that change (or that died without teardown) left theirs
# behind, so state/ slowly accumulates markers no live task owns.
#
# This sweep removes such orphans from THIS home's state dir. A marker is
# orphaned iff no state/<id>.meta derives its exact filename: for each live meta
# the sweep recomputes every marker name that task can own (the same key
# derivations the writers use) and keeps only those.
#
# A marker being created by an in-flight spawn/wake race is protected by the same
# age-guard pattern as bin/fm-hook-sweep.sh: only markers older than
# FM_MARKER_SWEEP_MIN_AGE_MINS (default 2; set <= 0 to disable, e.g. in tests)
# are considered. Global runtime sidecars (.heartbeat-streak, .last-*, .wake-queue,
# locks, .subsuper-escalations, .subsuper-last-*, .subsuper-inject-*, ...) are never
# matched by the family globs, so they are never touched.
#
# Prints one summary line only when it removed something. Always exits 0 so
# callers (bootstrap) can run it best-effort. Bash 3.2 safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# fm_backend_target_of_meta resolves the SAME window key the watcher writes (the
# window= value, or an orca task's terminal=), so the derived marker names match.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

MIN_AGE=${FM_MARKER_SWEEP_MIN_AGE_MINS:-2}

# Every marker filename a live task may own, one per line. Mirrors the writers in
# bin/fm-watch.sh (scan_signals, _hb_surfaced_path, the stale-loop key=, and the
# pause markers) and bin/fm-supervise-daemon.sh (mark_status_seen,
# stale_marker_record, pause_marker_record).
live_marker_names() {
  local meta id window task_key window_key
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    task_key=$(printf '%s' "$id" | tr ':/.' '___')
    printf '.seen-%s\n' "$(printf '%s.status' "$id" | tr '.' '_')"
    printf '.seen-%s\n' "$(printf '%s.turn-ended' "$id" | tr '.' '_')"
    printf '.hb-surfaced-%s\n' "$task_key"
    printf '.subsuper-seen-status-%s\n' "$task_key"
    printf '.subsuper-stale-%s\n' "$task_key"
    printf '.subsuper-paused-%s\n' "$task_key"
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || continue
    window_key=$(printf '%s' "$window" | tr ':/.' '___')
    printf '.hash-%s\n' "$window_key"
    printf '.count-%s\n' "$window_key"
    printf '.stale-%s\n' "$window_key"
    printf '.stale-since-%s\n' "$window_key"
    printf '.wedge-escalations-%s\n' "$window_key"
    printf '.paused-%s\n' "$window_key"
    printf '.paused-rechecked-%s\n' "$window_key"
    printf '.paused-resurfaced-%s\n' "$window_key"
  done
}

main() {
  local removed=0 live f name find_age=()
  [ -d "$STATE" ] || return 0
  live=$(live_marker_names)
  # Age guard: only consider markers older than MIN_AGE minutes (protect an
  # in-flight spawn/wake race). MIN_AGE <= 0 disables it. Same pattern as
  # bin/fm-hook-sweep.sh.
  case "$MIN_AGE" in
    ''|*[!0-9-]*) find_age=(-mmin +2) ;;
    *) [ "$MIN_AGE" -gt 0 ] && find_age=(-mmin "+$MIN_AGE") ;;
  esac
  # The family globs. `.stale-*` also matches `.stale-since-*`, and `.paused-*`
  # also matches `.paused-rechecked-*`/`.paused-resurfaced-*`; the task-keyed
  # `.subsuper-*` families need their own patterns because `.stale-*`/`.paused-*`
  # do not match the `.subsuper-` prefix.
  # bash 3.2 + set -u: expanding an empty array as "${a[@]}" is an
  # unbound-variable error, so guard with ${a[@]+...}.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=${f##*/}
    case "$live" in
      "$name"|"$name"$'\n'*|*$'\n'"$name"$'\n'*|*$'\n'"$name") continue ;;
    esac
    rm -f "$f" && removed=$((removed + 1))
  done <<EOF
$(find "$STATE" -maxdepth 1 -type f \( \
    -name '.seen-*' -o -name '.hb-surfaced-*' \
    -o -name '.subsuper-seen-status-*' -o -name '.subsuper-stale-*' \
    -o -name '.subsuper-paused-*' \
    -o -name '.hash-*' -o -name '.count-*' \
    -o -name '.stale-*' -o -name '.paused-*' \
    -o -name '.wedge-escalations-*' \
  \) ${find_age[@]+"${find_age[@]}"} 2>/dev/null)
EOF
  [ "$removed" -gt 0 ] && echo "MARKER_SWEEP: removed $removed orphaned watcher marker(s)"
  return 0
}

main "$@"
