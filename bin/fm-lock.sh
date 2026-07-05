#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# The lock records the harness (agent) process PID found by walking the shell's
# ancestry, which lives as long as the firstmate session - unlike the transient
# subshell PID of any one tool call, which is dead moments after it is written.
#
# Acquisition is atomic and identity-verified, using the SAME portable lock
# primitive the watcher/queue locks use (fm_lock_try_acquire in fm-wake-lib.sh;
# a symlink-to-owner-dir claim that is atomic on POSIX and works on macOS bash
# 3.2 without flock). There is no check-then-write window: the winner is whoever
# atomically creates the lock, and every contender sees it held. A contended
# holder is trusted only when it is genuinely alive AND its recorded pid-identity
# (start time + command, via fm_pid_identity) still matches the live process -
# so a reused/recycled pid never reads as a live holder - AND it is genuinely a
# firstmate harness process. A holder that fails any of those is stale and is
# reclaimed atomically, the same way the watcher lock reclaims a dead holder.
#
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# Portable atomic-lock + pid-identity helpers (fm_lock_try_acquire,
# fm_lock_remove_path, fm_pid_alive, fm_pid_identity, fm_path_age,
# FM_LOCK_STALE_AFTER). Sourced after fm_env_init so it reuses the resolved STATE.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names, derived from the verified-adapter allowlist in
# bin/fm-harness-policy.sh (the single policy source; a newly verified adapter
# is recognized here without another edit).
# shellcheck source=bin/fm-harness-policy.sh
. "$SCRIPT_DIR/fm-harness-policy.sh"
HARNESS_RE=$(fm_harness_process_re)

# Grace for a holder that is mid-acquire (lock present, identity not yet written).
# Mirrors fm_lock_mid_acquire_is_fresh's floor so a genuine concurrent acquirer
# is waited out rather than stolen; a numeric-pid holder with a recorded identity
# never depends on it.
GRACE=${FM_LOCK_STALE_AFTER:-2}
[ "$GRACE" -ge 2 ] 2>/dev/null || GRACE=2

harness_pid() {  # the session-stable harness ancestor of this invocation
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_is_harness_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  fm_pid_alive "$pid" || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }
lock_identity() { cat "$LOCK/pid-identity" 2>/dev/null || true; }

# classify_holder <pid>: echo one of live|impostor|wait for the current holder pid.
#   live     - alive, recorded identity still matches, genuinely a harness: refuse.
#   impostor - dead, a reused/mismatched pid, no identity past the grace, or not a
#              harness: safe to reclaim.
#   wait     - alive but no identity recorded yet and the lock is fresh: another
#              session is mid-acquire; retry rather than steal or refuse.
classify_holder() {
  local pid=$1 stored current
  fm_pid_alive "$pid" || { echo impostor; return; }
  stored=$(lock_identity)
  if [ -z "$stored" ]; then
    if [ "$(fm_path_age "$LOCK")" -lt "$GRACE" ]; then echo wait; else echo impostor; fi
    return
  fi
  current=$(fm_pid_identity "$pid" 2>/dev/null || true)
  # A live pid whose identity cannot be read is treated as a live holder (refuse),
  # never stolen: we only reclaim on a proven-dead or proven-mismatched holder.
  [ -n "$current" ] || { echo live; return; }
  [ "$current" = "$stored" ] || { echo impostor; return; }   # reused/recycled pid
  if holder_is_harness_alive "$pid"; then echo live; else echo impostor; fi
}

# Migrate a legacy plain-file lock (the pre-directory format: $STATE/.lock holding
# just a pid) so the atomic directory primitive can take over. Returns 1 (refuse)
# when it names a different live harness session, 0 after clearing a reclaimable
# one (or after leaving it to a concurrent migrator; the acquire loop re-classifies
# whatever remains).
migrate_legacy_lock() {
  local legacy steal="$LOCK.steal"
  [ -e "$LOCK" ] && [ ! -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 0
  legacy=$(cat "$LOCK" 2>/dev/null || true)
  if [ -n "$legacy" ] && [ "$legacy" != "${1:-}" ] && holder_is_harness_alive "$legacy"; then
    return 1
  fi
  # Test-only fault injection: hold the gate->removal window open so the migration
  # race regression test can interleave a full migrate-and-acquire into it.
  [ -n "${FM_LOCK_TEST_STALL_BEFORE_MIGRATE_RM:-}" ] && sleep "$FM_LOCK_TEST_STALL_BEFORE_MIGRATE_RM"
  # Remove the legacy file only under the `.steal` mutex, re-verifying the
  # plain-file shape there. Every remover of the directory/symlink lock already
  # serializes on `.steal`; without this, a session that passed the plain-file
  # gate just before a concurrent session migrated AND acquired would `rm -f` that
  # session's freshly created symlink lock and both would end up holding it.
  # On mutex contention, remove nothing: the concurrent holder is mid-migration
  # or mid-steal, and the acquire loop handles whatever it leaves behind.
  if fm_lock_try_acquire "$steal"; then
    if [ -e "$LOCK" ] && [ ! -d "$LOCK" ] && [ ! -L "$LOCK" ]; then
      rm -f "$LOCK" 2>/dev/null || true
    fi
    fm_lock_release "$steal"
  fi
  return 0
}

record_holder() {  # stamp the session-stable harness identity into a freshly held lock
  local pid=$1 owner=${FM_LOCK_OWNER_DIR:-}
  [ -n "$owner" ] || return 1
  # Write into the owner dir captured at acquire, NEVER through the $LOCK symlink:
  # a contender that swapped the symlink while we stalled would otherwise receive
  # our writes into ITS owner dir (both sessions then verify their own clobber and
  # both stay live - split brain). pid FIRST (so a contender in the window sees an
  # empty identity + fresh lock and waits, never a pid/identity mismatch that would
  # look like a reused pid), then the identity, then the home; finally confirm the
  # symlink still names our owner dir. A stalled winner's late writes land in its
  # own already-discarded owner dir, its verify fails, and it backs off.
  { printf '%s\n' "$pid" > "$owner/pid"; } 2>/dev/null || return 1
  { fm_pid_identity "$pid" > "$owner/pid-identity"; } 2>/dev/null || true
  { printf '%s\n' "$FM_HOME" > "$owner/fm-home"; } 2>/dev/null || true
  [ -s "$owner/pid-identity" ] || return 1
  fm_lock_points_to_owner "$LOCK" "$owner"
}

# Atomically reclaim a LIVE-but-impostor lock (a reused/recycled pid or a
# non-harness process holding it). fm_lock_try_acquire's own steal is guarded by
# a `.steal` sub-lock and re-verification, but it engages ONLY for a DEAD holder;
# it bails at its pid-alive check for a live impostor. So we run the SAME dance
# ourselves: take the `.steal` mutex, and only under it re-classify the holder -
# removing and recreating the lock solely while it is STILL an impostor. Two
# concurrent sessions therefore cannot both delete-and-claim: the mutex
# serializes them, and the loser re-classifies the just-recorded winner as a live
# match and backs off instead of deleting it. Returns 0 iff we now hold the lock
# with our identity recorded; 1 if we backed off (someone else legitimately holds
# it, it changed under us, or the recreate lost a race).
reclaim_live_impostor() {
  local steal="$LOCK.steal" steal_owner held rc=1
  fm_lock_try_acquire "$steal" || return 1
  steal_owner=${FM_LOCK_OWNER_DIR:-}
  held=$(lock_pid)
  # Re-verify under the mutex. If the holder is no longer an impostor - another
  # session reclaimed and its live identity now matches, or it is mid-record and
  # fresh - do NOT remove it. Only a still-impostor holder is reclaimable.
  if [ "$(classify_holder "$held")" = impostor ]; then
    fm_lock_remove_path "$LOCK" 2>/dev/null || true
    # Pass our own steal owner so our held `.steal` does not block the claim.
    if fm_lock_try_create "$LOCK" "$steal_owner" && record_holder "$me"; then
      rc=0
    fi
  fi
  fm_lock_release "$steal"
  return "$rc"
}

if [ "${1:-}" = "status" ]; then
  if [ -e "$LOCK" ] && [ ! -d "$LOCK" ] && [ ! -L "$LOCK" ]; then
    old=$(cat "$LOCK" 2>/dev/null || true)
    if holder_is_harness_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
    exit 0
  fi
  if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(lock_pid)
  if [ -z "$old" ]; then
    echo "lock: stale (no holder pid recorded)"
  elif [ "$(classify_holder "$old")" = live ]; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead, reused, or not a harness)"
  fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }

if ! migrate_legacy_lock "$me"; then
  echo "error: another live firstmate session holds the lock; operate read-only until resolved" >&2
  exit 1
fi

# Atomic acquire loop. fm_lock_try_acquire itself reclaims a dead-pid holder
# atomically; this loop adds the identity verdict on a live-pid holder, waiting
# out a genuine concurrent mid-acquire and reclaiming a reused/mismatched or
# non-harness impostor. Bounded so a wedged mid-acquire can never hang forever.
tries=0
while [ "$tries" -lt 120 ]; do
  if fm_lock_try_acquire "$LOCK"; then
    # Test-only fault injection: hold the acquire->record window open past the
    # steal grace so the split-brain regression test can race a stealer into it.
    [ -n "${FM_LOCK_TEST_STALL_BEFORE_RECORD:-}" ] && sleep "$FM_LOCK_TEST_STALL_BEFORE_RECORD"
    if record_holder "$me"; then
      echo "lock acquired: harness pid $me"
      exit 0
    fi
    # Lost a record race (a contender reclaimed during the fresh window); retry.
    tries=$((tries + 1))
    continue
  fi
  held=${FM_LOCK_HELD_PID:-$(lock_pid)}
  case "$(classify_holder "$held")" in
    live)
      if [ -n "$held" ] && [ "$held" = "$me" ]; then
        echo "lock acquired: harness pid $me (already held by this session)"
        exit 0
      fi
      echo "error: another live firstmate session holds the lock (pid $held); operate read-only until resolved" >&2
      exit 1
      ;;
    wait)
      sleep 0.1
      ;;
    impostor)
      if reclaim_live_impostor; then
        echo "lock acquired: harness pid $me"
        exit 0
      fi
      # Backed off (another session reclaimed first, or a lost recreate race);
      # loop and re-classify - it is now most likely a live holder to refuse.
      sleep 0.1
      ;;
  esac
  tries=$((tries + 1))
done

echo "error: could not acquire the session lock under contention; operate read-only until resolved" >&2
exit 1
