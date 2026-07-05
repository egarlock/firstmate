#!/usr/bin/env bash
# Orphaned per-task watcher/daemon marker sweep (bin/fm-marker-sweep.sh).
#
# fm-watch.sh and fm-supervise-daemon.sh keep per-task suppression sidecars in
# state/ (.seen-*, .hb-surfaced-*, .subsuper-seen-status-*, .subsuper-stale-*,
# and the window-keyed .hash-/.count-/.stale-/.stale-since-*). fm-teardown.sh
# removes a task's markers on a clean teardown; a task that died without
# teardown (or was torn down before that change) leaves them behind. These
# tests pin the sweep that removes such orphans while never touching a live
# task's markers, a fresh (age-guarded) marker, or the global non-per-task
# state files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-marker-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-marker-sweep)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  printf '%s\n' "$case_dir"
}

# write_markers <state> <id> <window>: create every marker family for one task,
# using the same key derivations the writers use.
write_markers() {
  local state=$1 id=$2 window=$3 task_key window_key
  task_key=$(printf '%s' "$id" | tr ':/.' '___')
  window_key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'sig' > "$state/.seen-$(printf '%s.status' "$id" | tr '.' '_')"
  printf 'sig' > "$state/.seen-$(printf '%s.turn-ended' "$id" | tr '.' '_')"
  printf 'done: x' > "$state/.hb-surfaced-$task_key"
  printf 'done: x' > "$state/.subsuper-seen-status-$task_key"
  printf '123' > "$state/.subsuper-stale-$task_key"
  printf 'hash' > "$state/.hash-$window_key"
  printf '2' > "$state/.count-$window_key"
  printf 'hash' > "$state/.stale-$window_key"
  printf '123' > "$state/.stale-since-$window_key"
}

# marker_count <state> <id> <window>: how many of the task's markers exist.
marker_count() {
  local state=$1 id=$2 window=$3 task_key window_key n=0 f
  task_key=$(printf '%s' "$id" | tr ':/.' '___')
  window_key=$(printf '%s' "$window" | tr ':/.' '___')
  for f in \
    "$state/.seen-$(printf '%s.status' "$id" | tr '.' '_')" \
    "$state/.seen-$(printf '%s.turn-ended' "$id" | tr '.' '_')" \
    "$state/.hb-surfaced-$task_key" \
    "$state/.subsuper-seen-status-$task_key" \
    "$state/.subsuper-stale-$task_key" \
    "$state/.hash-$window_key" \
    "$state/.count-$window_key" \
    "$state/.stale-$window_key" \
    "$state/.stale-since-$window_key"; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

run_sweep() {  # <case_dir> [min-age]
  local case_dir=$1 min_age=${2:-0}
  FM_MARKER_SWEEP_MIN_AGE_MINS="$min_age" FM_STATE_OVERRIDE="$case_dir/state" \
    "$SWEEP" 2>&1
}

test_removes_orphans_keeps_live_and_globals() {
  local case_dir state out
  case_dir=$(make_case orphans); state="$case_dir/state"
  # Live task: meta present -> every marker must survive.
  fm_write_meta "$state/live-x1.meta" "window=sess:fm-live-x1" "kind=ship"
  write_markers "$state" live-x1 "sess:fm-live-x1"
  # Orphan: no meta -> every marker family must be removed (9 files).
  write_markers "$state" gone-x2 "sess:fm-gone-x2"
  # Global non-per-task state files must never be touched.
  printf '3' > "$state/.heartbeat-streak"
  touch "$state/.last-heartbeat" "$state/.last-watcher-beat"
  printf 'q' > "$state/.wake-queue"

  out=$(run_sweep "$case_dir" 0)
  assert_contains "$out" "removed 9 orphaned watcher marker(s)" "sweep should report 9 removed orphan markers"
  [ "$(marker_count "$state" live-x1 "sess:fm-live-x1")" = 9 ] || fail "a live task's marker was removed"
  [ "$(marker_count "$state" gone-x2 "sess:fm-gone-x2")" = 0 ] || fail "an orphaned marker survived"
  assert_present "$state/.heartbeat-streak" ".heartbeat-streak was removed"
  assert_present "$state/.last-heartbeat" ".last-heartbeat was removed"
  assert_present "$state/.last-watcher-beat" ".last-watcher-beat was removed"
  assert_present "$state/.wake-queue" ".wake-queue was removed"
  pass "sweep removes orphaned marker families, keeps live markers and global state files"
}

test_age_guard_protects_fresh_orphans() {
  local case_dir state out
  case_dir=$(make_case age-guard); state="$case_dir/state"
  # Fresh orphan (just created) - the default 2-min guard must keep it.
  printf 'done: x' > "$state/.hb-surfaced-fresh-x1"
  # Old orphan - must be removed.
  printf 'done: x' > "$state/.hb-surfaced-old-x2"
  touch -t 202001010000 "$state/.hb-surfaced-old-x2"
  out=$(env -u FM_MARKER_SWEEP_MIN_AGE_MINS FM_STATE_OVERRIDE="$state" "$SWEEP" 2>&1)
  assert_contains "$out" "removed 1 orphaned watcher marker(s)" "only the aged orphan should be removed"
  assert_present "$state/.hb-surfaced-fresh-x1" "age guard did not protect the fresh marker"
  assert_absent "$state/.hb-surfaced-old-x2" "aged orphan marker survived"
  # Idempotent: a second sweep finds nothing and stays quiet.
  out=$(env -u FM_MARKER_SWEEP_MIN_AGE_MINS FM_STATE_OVERRIDE="$state" "$SWEEP" 2>&1)
  assert_not_contains "$out" "removed" "second sweep should remove nothing"
  pass "sweep age guard protects fresh markers, removes aged orphans, and is idempotent"
}

test_shared_window_key_of_live_task_survives() {
  local case_dir state out
  case_dir=$(make_case window-keys); state="$case_dir/state"
  # A live task whose window target carries backend punctuation (herdr-style
  # opaque target): the window-keyed markers must be matched through the same
  # tr ':/.' '___' derivation and survive.
  fm_write_meta "$state/herdr-x1.meta" "window=default:w1.p2" "kind=ship" "backend=herdr"
  write_markers "$state" herdr-x1 "default:w1.p2"
  out=$(run_sweep "$case_dir" 0)
  assert_not_contains "$out" "removed" "live herdr task's markers should all survive"
  [ "$(marker_count "$state" herdr-x1 "default:w1.p2")" = 9 ] || fail "a live herdr task's marker was removed"
  pass "sweep derives window keys exactly as the watcher does (punctuated backend targets survive)"
}

test_removes_orphans_keeps_live_and_globals
test_age_guard_protects_fresh_orphans
test_shared_window_key_of_live_task_survives
