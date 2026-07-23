#!/usr/bin/env bash
# tests/fm-session-lock.test.sh - the per-home firstmate SESSION lock
# (bin/fm-lock.sh, state/.lock). These are safety-critical concurrency and
# identity invariants: acquisition must be atomic (no check-then-write race) and
# a contended holder is trusted only when it is genuinely alive AND its recorded
# pid-identity still matches AND it is a firstmate harness - so a reused/recycled
# pid never reads as a live holder, and a provably-dead lock is reclaimable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FMLOCK="$ROOT/bin/fm-lock.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-tests)

# Install a fake `ps` that DELEGATES to the real ps but rewrites the reported
# command so the harness-ancestor walk resolves deterministically: any live
# process EXCEPT the fm-lock.sh invocation itself is reported as a "claude"
# harness, while the fm-lock.sh process keeps its real command (a plain shell,
# which the harness regex does not match) so harness_pid() walks past it to its
# ancestor. lstart/command (pid-identity), state and ppid pass straight through to
# the real ps, so identities are genuine and differ per pid.
#
# FM_TEST_ZOMBIE_PID makes one pid render the way LINUX procps renders an unreaped
# process: state Z, comm still the harness name, args `[claude] <defunct>`. That
# shape is the point - a name-only liveness check MATCHES it, so a defunct harness
# would read as a live holder. (macOS happens to render both comm and args as
# `<defunct>`, so the real local ps cannot exercise the hazard.)
write_delegating_ps() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
realps=
for p in /bin/ps /usr/bin/ps; do
  [ -x "$p" ] && { realps=$p; break; }
done
[ -n "$realps" ] || exit 1
pid=""; want_comm=0; want_args=0; want_ppid=0; want_ident=0; want_state=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) pid="${2:-}"; shift 2 ;;
    -o)
      case "${2:-}" in
        comm=) want_comm=1 ;;
        args=) want_args=1 ;;
        ppid=) want_ppid=1 ;;
        state=) want_state=1 ;;
        lstart=) want_ident=1 ;;
        command=) want_ident=1 ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$pid" ] || exit 1
zombie=0
[ -n "${FM_TEST_ZOMBIE_PID:-}" ] && [ "$pid" = "$FM_TEST_ZOMBIE_PID" ] && zombie=1
if [ "$want_ppid" = 1 ]; then "$realps" -o ppid= -p "$pid"; exit $?; fi
if [ "$want_state" = 1 ]; then
  [ "$zombie" = 1 ] && { printf 'Z\n'; exit 0; }
  "$realps" -o state= -p "$pid"; exit $?
fi
if [ "$want_ident" = 1 ]; then "$realps" -p "$pid" -o lstart= -o command=; exit $?; fi
if [ "$want_comm" = 1 ] || [ "$want_args" = 1 ]; then
  ra=$("$realps" -o args= -p "$pid" 2>/dev/null) || exit 1
  if [ "$zombie" = 1 ]; then
    [ "$want_comm" = 1 ] && printf 'claude\n' || printf '[claude] <defunct>\n'
    exit 0
  fi
  case "$ra" in
    *fm-lock.sh*) "$realps" -o comm= -p "$pid"; exit $? ;;   # the fm-lock process itself
    *) [ "$want_comm" = 1 ] && printf 'claude\n' || printf 'claude --session\n'; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$fakebin/ps"
}

# A /proc entry whose cmdline is EMPTY: what an unreaped process reports while
# `kill -0` still succeeds, so fm_pid_identity's /proc parse fails for that pid
# and must fall through to ps.
write_unparseable_proc_entry() {  # <proc-root> <pid>
  mkdir -p "$1/$2"
  printf '%s (claude) Z 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 20 21 22\n' "$2" > "$1/$2/stat"
  : > "$1/$2/cmdline"
}

# fm_pid_identity for <pid> as fm-lock.sh will compute it (via the delegating ps).
seed_identity() {  # <fakebin> <pid>
  local fakebin=$1 pid=$2
  PATH="$fakebin:$PATH" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid"
}

# A NON-matching identity in the CURRENT format: the genuine reused/recycled-pid
# case, which must still be reclaimable. The tag is taken from a REAL identity for
# the same pid rather than from a constant, because the tag names the payload
# SOURCE (/proc or ps) as well as the version - so the fixture can never drift
# from the form fm-lock.sh will actually compute for that pid on this host.
current_format_identity() {  # <fakebin> <pid> <payload>
  local fakebin=$1 pid=$2 payload=$3 ident
  ident=$(seed_identity "$fakebin" "$pid")
  printf '%s %s\n' "${ident%% *}" "$payload"
}

test_atomic_single_winner_under_concurrency() {
  local dir state fakebin results sim n i pids pid winners
  dir="$TMP_ROOT/concurrency"
  state="$dir/state"
  fakebin="$dir/fakebin"
  results="$dir/results"
  sim="$dir/harness-sim.sh"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  : > "$results"
  # A stand-in "harness" ancestor: runs one fm-lock acquire, then stays alive so
  # the lock it records names a LIVE pid for the whole contention window. The path
  # is passed via env (never an argv token) so this process's own command line does
  # NOT contain fm-lock.sh - otherwise the fake ps would classify it as fm-lock and
  # the ancestry walk could not resolve it as the harness.
  cat > "$sim" <<'SH'
#!/usr/bin/env bash
"$FMLOCK" >> "$RESULTS" 2>&1
sleep 10
SH
  chmod +x "$sim"
  n=20
  pids=
  i=1
  while [ "$i" -le "$n" ]; do
    FMLOCK="$FMLOCK" RESULTS="$results" PATH="$fakebin:$PATH" FM_HOME="$dir" "$sim" &
    pids="$pids $!"
    i=$((i + 1))
  done
  # Wait until every acquire has reported (a winner line or a refusal line).
  i=0
  while [ "$i" -lt 150 ]; do
    [ "$(awk 'NF' "$results" | wc -l | tr -d ' ')" -ge "$n" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  winners=$(grep -c '^lock acquired: harness pid' "$results" 2>/dev/null || true)
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [ "$(awk 'NF' "$results" | wc -l | tr -d ' ')" -ge "$n" ] || fail "not all acquirers reported: $(cat "$results")"
  [ "$winners" -eq 1 ] || fail "expected exactly one atomic winner, got $winners: $(cat "$results")"
  pass "concurrent fm-lock acquirers yield exactly one atomic winner"
}

test_atomic_single_winner_vs_live_impostor() {
  # The hard case the plain fresh-lock concurrency test misses: the lock is
  # already held by a LIVE impostor (a reused/recycled pid whose recorded identity
  # no longer matches). fm_lock_try_acquire's atomic steal covers only DEAD
  # holders, so the identity-based reclaim must itself be atomic - two concurrent
  # sessions must NOT both delete-and-claim. Exactly one winner.
  local dir state fakebin results sim lock impostor n i pids pid winners
  dir="$TMP_ROOT/impostor-concurrency"
  state="$dir/state"
  fakebin="$dir/fakebin"
  results="$dir/results"
  sim="$dir/harness-sim.sh"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  : > "$results"
  # A live process holds the lock, but the recorded identity is a since-gone
  # process: a live impostor that pid-liveness alone would wrongly honor.
  sleep 300 &
  impostor=$!
  mkdir "$lock"
  printf '%s\n' "$impostor" > "$lock/pid"
  current_format_identity "$fakebin" "$impostor" "identity of a since-exited process" > "$lock/pid-identity"
  cat > "$sim" <<'SH'
#!/usr/bin/env bash
"$FMLOCK" >> "$RESULTS" 2>&1
sleep 10
SH
  chmod +x "$sim"
  n=20
  pids=
  i=1
  while [ "$i" -le "$n" ]; do
    FMLOCK="$FMLOCK" RESULTS="$results" PATH="$fakebin:$PATH" FM_HOME="$dir" "$sim" &
    pids="$pids $!"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(awk 'NF' "$results" | wc -l | tr -d ' ')" -ge "$n" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  winners=$(grep -c '^lock acquired: harness pid' "$results" 2>/dev/null || true)
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  kill "$impostor" 2>/dev/null || true
  wait "$impostor" 2>/dev/null || true
  [ "$(awk 'NF' "$results" | wc -l | tr -d ' ')" -ge "$n" ] || fail "not all acquirers reported: $(cat "$results")"
  [ "$winners" -eq 1 ] || fail "expected exactly one winner reclaiming a live-impostor lock, got $winners: $(cat "$results")"
  pass "concurrent acquirers vs a live-impostor lock yield exactly one atomic winner"
}

test_live_holder_refuses() {
  local dir state fakebin lock holder ident status out
  dir="$TMP_ROOT/live-holder"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  sleep 300 &
  holder=$!
  ident=$(seed_identity "$fakebin" "$holder")
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  printf '%s\n' "$ident" > "$lock/pid-identity"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ] || fail "acquire did not refuse a genuinely live firstmate holder (status $status): $out"
  assert_contains "$out" "another live firstmate session holds the lock" "refusal did not name the live holder"
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] || fail "live holder's lock pid was clobbered"
  pass "a genuinely live, identity-matched harness holder is refused"
}

test_reused_pid_holder_is_reclaimed() {
  local dir state fakebin lock holder status out newpid
  dir="$TMP_ROOT/reused-pid"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  # A LIVE pid, but the recorded identity is from some OTHER, long-gone process:
  # the pid was recycled. pid-alive alone would (wrongly) read this as held; the
  # identity check must see the mismatch and treat it as reclaimable.
  sleep 300 &
  holder=$!
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  current_format_identity "$fakebin" "$holder" "stale identity of a since-exited process" > "$lock/pid-identity"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  newpid=$(cat "$lock/pid" 2>/dev/null || true)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "acquire did not reclaim a reused-pid (identity-mismatched) lock (status $status): $out"
  assert_contains "$out" "lock acquired: harness pid" "reclaim did not report an acquisition"
  [ "$newpid" != "$holder" ] || fail "reused-pid lock still names the recycled holder ($holder)"
  pass "a live pid whose recorded identity no longer matches does not read as a live holder"
}

test_legacy_format_identity_is_not_reclaimed_and_self_heals() {
  # A firstmate update that changes the identity FORMAT lands while a session is
  # live. The next session recomputes the live holder's identity in the new
  # format; comparing that against the older-format recorded string would read a
  # genuinely live holder as a recycled pid and STEAL the lock - two sessions
  # supervising one home, the exact outcome the identity check exists to prevent.
  # A format change is not evidence of pid reuse: the holder must be refused, and
  # its identity healed in place so the unverifiable window does not recur.
  local dir state fakebin lock holder tagged legacy status out healed
  dir="$TMP_ROOT/legacy-identity-format"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  sleep 300 &
  holder=$!
  tagged=$(seed_identity "$fakebin" "$holder")
  # The pre-tag recording of the SAME process: today's payload, no format tag.
  legacy=${tagged#* }
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  printf '%s\n' "$legacy" > "$lock/pid-identity"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  healed=$(cat "$lock/pid-identity" 2>/dev/null || true)
  [ "$status" -eq 1 ] || fail "acquire stole the lock from a live holder whose identity was in the older format (status $status): $out"
  assert_contains "$out" "another live firstmate session holds the lock" \
    "an unverifiable-but-live holder must be refused, not reclaimed"
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] || fail "live holder's lock pid was clobbered across the format change"
  [ "$healed" = "$tagged" ] || fail "the older-format identity was not healed to the current format (got '$healed', want '$tagged')"
  # Healed, so the next contender takes the ordinary same-format match path.
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "acquire did not refuse the same live holder after the identity was healed (status $status): $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" status)
  assert_contains "$out" "lock: held by live harness pid $holder" \
    "status did not report the live holder across the identity format change"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "an older-format recorded identity reads unverifiable (refuse, then heal), never as a recycled pid"
}

test_legacy_format_identity_on_non_harness_is_reclaimed() {
  # The safe direction is refuse, but it must not become "refuse forever": an
  # older-format identity whose pid is now some OTHER, non-harness process is
  # still reclaimable, so a genuinely recycled pid cannot wedge the home.
  local dir state fakebin lock holder status out newpid
  dir="$TMP_ROOT/legacy-identity-non-harness"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  # No delegating ps here: the real ps reports `sleep`, which the harness regex
  # does not match, so the holder is live but not a firstmate harness.
  sleep 300 &
  holder=$!
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  printf '%s\n' "untagged identity of the recycled pid" > "$lock/pid-identity"
  status=0
  out=$(FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  newpid=$(cat "$lock/pid" 2>/dev/null || true)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "acquire did not reclaim an older-format lock held by a non-harness process (status $status): $out"
  [ "$newpid" != "$holder" ] || fail "reclaimed lock still names the non-harness holder ($holder)"
  pass "an older-format identity on a non-harness holder is still reclaimable"
}

test_zombie_holder_does_not_wedge_the_home() {
  # An unreaped harness must never make a home permanently read-only. Two things
  # have to hold at once, and both are on the /proc identity path:
  #
  #  (1) The HOLDER stays reclaimable. Its /proc cmdline is empty, so the /proc
  #      parse fails and the identity falls through to ps - a DIFFERENT payload
  #      source than the recorded /proc-form string, hence unverifiable rather
  #      than "recycled pid". Unverifiable then leans on the harness check, and a
  #      defunct process is not a live harness (Linux still reports its comm as
  #      `claude`), so it reclaims. Without the fall-through the identity would be
  #      empty and classify_holder would read it as a live holder forever.
  #  (2) The ACQUIRER can still record itself. Its own /proc read is unparseable
  #      too, and record_holder demands a non-empty identity - so before the
  #      fall-through every one of the 120 bounded tries failed and the acquire
  #      ended in "could not acquire the session lock under contention".
  local dir state fakebin proc_root lock zombie sim results simpid i status newpid
  dir="$TMP_ROOT/zombie-holder"
  state="$dir/state"
  fakebin="$dir/fakebin"
  proc_root="$dir/proc"
  lock="$state/.lock"
  results="$dir/results"
  sim="$dir/harness-sim.sh"
  mkdir -p "$state" "$fakebin" "$proc_root"
  write_delegating_ps "$fakebin"
  : > "$results"
  sleep 300 &
  zombie=$!
  write_unparseable_proc_entry "$proc_root" "$zombie"
  mkdir "$lock"
  printf '%s\n' "$zombie" > "$lock/pid"
  # What a Linux home records for a live harness: the /proc-form identity.
  printf 'fmid1p linux-starttime=987654 cmdline-hex=636c61756465\n' > "$lock/pid-identity"
  # The acquirer sleeps first so its own unparseable /proc entry can be planted
  # under its (now known) pid before fm-lock.sh computes its identity.
  cat > "$sim" <<'SH'
#!/usr/bin/env bash
sleep 1
"$FMLOCK" >> "$RESULTS" 2>&1
sleep 10
SH
  chmod +x "$sim"
  FMLOCK="$FMLOCK" RESULTS="$results" PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_ZOMBIE_PID="$zombie" "$sim" &
  simpid=$!
  write_unparseable_proc_entry "$proc_root" "$simpid"
  i=0
  while [ "$i" -lt 150 ]; do
    grep -q 'lock acquired\|^error:' "$results" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  newpid=$(cat "$lock/pid" 2>/dev/null || true)
  status=$(cat "$results")
  kill "$simpid" "$zombie" 2>/dev/null || true
  wait "$simpid" 2>/dev/null || true
  wait "$zombie" 2>/dev/null || true
  assert_not_contains "$status" 'another live firstmate session holds the lock' \
    "a defunct holder read as a live session: the home would stay read-only until it is reaped"
  assert_not_contains "$status" 'could not acquire the session lock under contention' \
    "the acquirer could not record its own identity from an unparseable /proc read"
  assert_contains "$status" 'lock acquired: harness pid' \
    "acquire did not reclaim a zombie-held lock"
  [ "$newpid" = "$simpid" ] || fail "zombie-held lock was not reclaimed by the acquirer (pid '$newpid', want '$simpid')"
  pass "an unreaped harness holder is reclaimable and does not wedge the home read-only"
}

test_dead_holder_is_reclaimed() {
  local dir state fakebin lock dead status out newpid
  dir="$TMP_ROOT/dead-holder"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  mkdir "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  printf '%s\n' "identity of the dead holder" > "$lock/pid-identity"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  newpid=$(cat "$lock/pid" 2>/dev/null || true)
  [ "$status" -eq 0 ] || fail "acquire did not reclaim a dead-holder lock (status $status): $out"
  assert_contains "$out" "lock acquired: harness pid" "reclaim did not report an acquisition"
  [ "$newpid" != "$dead" ] || fail "dead-holder lock still names the dead pid ($dead)"
  pass "a provably-dead holder lock is safely reclaimable"
}

test_legacy_plainfile_lock_is_migrated() {
  local dir state fakebin lock dead status out
  dir="$TMP_ROOT/legacy-migrate"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  # Pre-directory format: a plain FILE holding a now-dead pid. It must be migrated
  # (cleared) and re-acquired in the atomic directory format, not left to jam.
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf '%s\n' "$dead" > "$lock"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "acquire did not migrate a dead legacy plain-file lock (status $status): $out"
  assert_contains "$out" "lock acquired: harness pid" "legacy migration did not acquire"
  [ -d "$lock" ] || [ -L "$lock" ] || fail "legacy lock was not upgraded to the directory format"
  pass "a legacy dead plain-file lock is migrated to the atomic directory format"
}

test_stalled_winner_never_splits_brain_with_stealer() {
  # M1 regression: a winner that stalls past the steal grace between acquiring the
  # symlink and recording its identity looks like an identity-less impostor, and a
  # contender legitimately steals the lock. The resumed original must NOT write
  # through the swapped symlink into the stealer's owner dir and verify against
  # its own clobber - that yields TWO live sessions both reporting the lock
  # acquired. Fault-inject the stall via the test-only hook and require exactly
  # one winner: the stealer keeps the lock, the stalled original refuses.
  local dir state fakebin sim lock res_a res_b apid bpid i winners lockpid
  dir="$TMP_ROOT/stalled-winner"
  state="$dir/state"
  fakebin="$dir/fakebin"
  sim="$dir/harness-sim.sh"
  lock="$state/.lock"
  res_a="$dir/result-a"
  res_b="$dir/result-b"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  cat > "$sim" <<'SH'
#!/usr/bin/env bash
"$FMLOCK" >> "$RESULTS" 2>&1
sleep 10
SH
  chmod +x "$sim"
  # A acquires first and stalls 4s (> the 2s steal grace) before recording.
  FMLOCK="$FMLOCK" RESULTS="$res_a" PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_LOCK_TEST_STALL_BEFORE_RECORD=4 "$sim" &
  apid=$!
  # Give A time to win the atomic create and age the identity-less lock past the
  # grace, then start B, which classifies the holder as an impostor and steals.
  sleep 2.5
  FMLOCK="$FMLOCK" RESULTS="$res_b" PATH="$fakebin:$PATH" FM_HOME="$dir" "$sim" &
  bpid=$!
  i=0
  while [ "$i" -lt 120 ]; do
    grep -q 'lock acquired\|^error:' "$res_a" 2>/dev/null \
      && grep -q 'lock acquired\|^error:' "$res_b" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lockpid=$(cat "$lock/pid" 2>/dev/null || true)
  winners=$(cat "$res_a" "$res_b" 2>/dev/null | grep -c '^lock acquired: harness pid' || true)
  kill "$apid" "$bpid" 2>/dev/null || true
  wait "$apid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  if [ ! -s "$res_a" ] || [ ! -s "$res_b" ]; then fail "stalled-winner: contenders did not both report: a='$(cat "$res_a" 2>/dev/null)' b='$(cat "$res_b" 2>/dev/null)'"; fi
  [ "$winners" -eq 1 ] || fail "stalled-winner: expected exactly one winner, got $winners: a='$(cat "$res_a")' b='$(cat "$res_b")'"
  grep -q '^lock acquired: harness pid' "$res_b" || fail "stalled-winner: the stealer (B) should hold the lock: b='$(cat "$res_b")'"
  grep -q 'another live firstmate session holds the lock' "$res_a" || fail "stalled-winner: the stalled original (A) should refuse: a='$(cat "$res_a")'"
  [ "$lockpid" = "$bpid" ] || fail "stalled-winner: lock pid should be the stealer's harness pid $bpid, got '$lockpid' (late write clobbered the stealer?)"
  pass "a winner stalled past the steal grace backs off instead of splitting brain with the stealer"
}

test_legacy_migration_race_single_winner() {
  # S2 regression: with a reclaimable legacy plain-file lock and two sessions
  # starting together, the slower migrator's removal must re-verify the
  # plain-file condition under the .steal mutex - otherwise its unconditional
  # rm -f deletes the faster session's freshly acquired symlink lock and both
  # sessions end up holding it. Fault-inject the gate->removal stall in B and
  # require exactly one winner: A keeps its lock, B refuses.
  local dir state fakebin sim lock dead res_a res_b apid bpid i winners lockpid
  dir="$TMP_ROOT/migration-race"
  state="$dir/state"
  fakebin="$dir/fakebin"
  sim="$dir/harness-sim.sh"
  lock="$state/.lock"
  res_a="$dir/result-a"
  res_b="$dir/result-b"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  # Pre-directory format: a plain FILE holding a now-dead pid (reclaimable).
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf '%s\n' "$dead" > "$lock"
  cat > "$sim" <<'SH'
#!/usr/bin/env bash
"$FMLOCK" >> "$RESULTS" 2>&1
sleep 10
SH
  chmod +x "$sim"
  # B passes the plain-file gate first, then stalls 3s before its removal step.
  FMLOCK="$FMLOCK" RESULTS="$res_b" PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_LOCK_TEST_STALL_BEFORE_MIGRATE_RM=3 "$sim" &
  bpid=$!
  # While B stalls, A migrates the legacy file, acquires, and records.
  sleep 0.5
  FMLOCK="$FMLOCK" RESULTS="$res_a" PATH="$fakebin:$PATH" FM_HOME="$dir" "$sim" &
  apid=$!
  i=0
  while [ "$i" -lt 120 ]; do
    grep -q 'lock acquired\|^error:' "$res_a" 2>/dev/null \
      && grep -q 'lock acquired\|^error:' "$res_b" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lockpid=$(cat "$lock/pid" 2>/dev/null || true)
  winners=$(cat "$res_a" "$res_b" 2>/dev/null | grep -c '^lock acquired: harness pid' || true)
  kill "$apid" "$bpid" 2>/dev/null || true
  wait "$apid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
  if [ ! -s "$res_a" ] || [ ! -s "$res_b" ]; then fail "migration-race: contenders did not both report: a='$(cat "$res_a" 2>/dev/null)' b='$(cat "$res_b" 2>/dev/null)'"; fi
  [ "$winners" -eq 1 ] || fail "migration-race: expected exactly one winner, got $winners: a='$(cat "$res_a")' b='$(cat "$res_b")'"
  grep -q '^lock acquired: harness pid' "$res_a" || fail "migration-race: the fast migrator (A) should hold the lock: a='$(cat "$res_a")'"
  grep -q 'another live firstmate session holds the lock' "$res_b" || fail "migration-race: the stalled migrator (B) should refuse: b='$(cat "$res_b")'"
  [ -L "$lock" ] || [ -d "$lock" ] || fail "migration-race: the winner's directory-format lock was deleted by the stalled migrator"
  [ "$lockpid" = "$apid" ] || fail "migration-race: lock pid should be the fast migrator's harness pid $apid, got '$lockpid'"
  pass "a concurrent legacy migration cannot delete the other session's freshly acquired lock"
}

test_live_legacy_plainfile_holder_refuses() {
  # The pre-directory plain-file lock naming a LIVE harness session must refuse
  # (not migrate), and `status` must report it held; after the holder dies it
  # reads stale. Only the dead-legacy migration path was covered before.
  local dir state fakebin lock holder status out
  dir="$TMP_ROOT/legacy-live-holder"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$lock"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "acquire did not refuse a live legacy plain-file holder (status $status): $out"
  assert_contains "$out" "another live firstmate session holds the lock" "legacy refusal did not name the live holder"
  [ "$(cat "$lock" 2>/dev/null || true)" = "$holder" ] || fail "live legacy plain-file lock was clobbered"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" status)
  assert_contains "$out" "lock: held by live harness pid $holder" "status did not report the live legacy plain-file holder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" status)
  assert_contains "$out" "lock: stale" "status did not report the dead legacy plain-file holder as stale"
  pass "a live legacy plain-file holder is refused and status-visible; a dead one reads stale"
}

test_status_verifies_identity() {
  local dir state fakebin lock holder ident out
  dir="$TMP_ROOT/status-identity"
  state="$dir/state"
  fakebin="$dir/fakebin"
  lock="$state/.lock"
  mkdir -p "$state" "$fakebin"
  write_delegating_ps "$fakebin"
  sleep 300 &
  holder=$!
  # (1) free.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" status)
  [ "$out" = "lock: free" ] || fail "status did not report a free lock: $out"
  # (2) a live, identity-matched harness -> held.
  ident=$(seed_identity "$fakebin" "$holder")
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  printf '%s\n' "$ident" > "$lock/pid-identity"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" status)
  assert_contains "$out" "lock: held by live harness pid $holder" "status did not report a verified live holder"
  # (3) same live pid, same-format mismatched identity (reused) -> stale, not held.
  current_format_identity "$fakebin" "$holder" "some other identity" > "$lock/pid-identity"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" "$FMLOCK" status)
  assert_contains "$out" "lock: stale" "status treated a reused pid as a live holder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "status verifies holder identity, not just pid-liveness"
}

test_atomic_single_winner_under_concurrency
test_atomic_single_winner_vs_live_impostor
test_live_holder_refuses
test_reused_pid_holder_is_reclaimed
test_legacy_format_identity_is_not_reclaimed_and_self_heals
test_legacy_format_identity_on_non_harness_is_reclaimed
test_zombie_holder_does_not_wedge_the_home
test_dead_holder_is_reclaimed
test_legacy_plainfile_lock_is_migrated
test_stalled_winner_never_splits_brain_with_stealer
test_legacy_migration_race_single_winner
test_live_legacy_plainfile_holder_refuses
test_status_verifies_identity
