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
# Identity strings are format-tagged (fm_pid_identity_format), because a recorded
# identity outlives the firstmate version that wrote it, and because the same live
# pid can be described by either identity SOURCE (/proc or ps). An identity
# recorded in a DIFFERENT format is UNVERIFIABLE, not mismatched: a live harness
# holding it is refused (and its identity healed in place) rather than treated as
# a recycled pid, since stealing would put two sessions on one home while refusing
# only delays one. A same-format mismatch is still the reused-pid case and
# reclaims. Refusing is safe but must not become "refuse forever", so the
# unverifiable branch still requires a live HARNESS - and a defunct process is not
# one, so an unreaped holder stays reclaimable instead of wedging the home.
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

# A ZOMBIE is not a live harness, and the process STATE is the portable way to say
# so. `kill -0` succeeds for an unreaped process, and Linux ps still reports its
# comm as the harness name (`claude`, args `[claude] <defunct>`), so a name-only
# check reads a defunct harness as a live holder and refuses the lock until
# someone reaps it - the home goes permanently read-only. (macOS renders both comm
# and args as `<defunct>`, which happens not to match, but that is a coincidence
# of formatting, not a check.) State `Z` is reported by both.
pid_is_defunct() {
  local state
  state=$(ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$state" in
    Z*) return 0 ;;
  esac
  return 1
}

holder_is_harness_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  fm_pid_alive "$pid" || return 1
  pid_is_defunct "$pid" && return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

lock_pid() { cat "$LOCK/pid" 2>/dev/null || true; }
lock_identity() { cat "$LOCK/pid-identity" 2>/dev/null || true; }

# True when a recorded identity cannot be compared to a freshly computed one
# because they were written in different formats (fm_pid_identity_verdict 2).
identity_unverifiable() {  # <stored> <current>
  fm_pid_identity_verdict "$1" "$2"
  [ $? -eq 2 ]
}

# classify_holder <pid>: echo one of live|impostor|wait for the current holder pid.
#   live     - alive, recorded identity still matches (or is unverifiable across a
#              format change), genuinely a harness: refuse.
#   impostor - dead, a SAME-FORMAT mismatched pid, no identity past the grace, or
#              not a harness: safe to reclaim.
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
  fm_pid_identity_verdict "$stored" "$current"
  case $? in
    1) echo impostor; return ;;   # same format, different process: reused pid
    2)
      # UNVERIFIABLE: the identity was recorded in an older format, because a
      # firstmate update landed while this session was live. A format change is
      # NOT evidence of a reused pid, and comparing across formats would read
      # every pre-update holder as an impostor and steal the lock - two sessions
      # on one home, exactly what the identity check exists to prevent. Refusing
      # at worst delays one session, so a live harness keeps the lock; only a
      # non-harness process holding it stays reclaimable, so a genuinely recycled
      # pid still cannot wedge the home.
      ;;
  esac
  if holder_is_harness_alive "$pid"; then echo live; else echo impostor; fi
}

# upgrade_holder_identity <pid>: rewrite a live holder's older-format identity in
# the current format, so the unverifiable window closes after one contended
# acquire instead of recurring on every later one. Called for a holder classified
# `live`; it re-derives the stale-format condition itself rather than trusting a
# flag, because classify_holder runs in a command substitution and cannot hand
# state back. It no-ops unless a heal is genuinely needed, so the `.steal` mutex
# is taken only for the one transitional acquire. The write happens only under
# that mutex with the pid, the stored identity, and the stale format re-verified
# there - so a contender that swapped the lock under us never receives our write
# into ITS owner dir (the split-brain hazard record_holder is built around).
# Best-effort: a lost mutex or a changed holder simply leaves the identity alone.
upgrade_holder_identity() {
  local pid=$1 steal="$LOCK.steal" current stored
  stored=$(lock_identity)
  [ -n "$stored" ] || return 0
  current=$(fm_pid_identity "$pid" 2>/dev/null || true)
  [ -n "$current" ] || return 0
  identity_unverifiable "$stored" "$current" || return 0
  fm_lock_try_acquire "$steal" || return 0
  stored=$(lock_identity)
  if [ "$(lock_pid)" = "$pid" ] && identity_unverifiable "$stored" "$current" &&
     holder_is_harness_alive "$pid"; then
    { printf '%s\n' "$current" > "$LOCK/pid-identity"; } 2>/dev/null || true
  fi
  fm_lock_release "$steal"
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
      # Heal a pre-update identity once, while we have the holder confirmed live.
      upgrade_holder_identity "$held"
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
