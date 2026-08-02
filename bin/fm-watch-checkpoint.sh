#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# The bound comes from timeout(1), gtimeout(1), or a self-contained perl
# process-group alarm, in that order. macOS ships none of the GNU coreutils
# timeouts by default, so the perl fallback is the real path there and is not a
# rarely-taken branch. FM_CHECKPOINT_TIMEOUT_IMPL pins the implementation to
# auto (default), timeout, gtimeout, or perl, so each one can be exercised on a
# host that happens to have the others; an explicitly named implementation that
# is not installed, and auto on a host with none of the three, are both errors
# rather than a silent downgrade or an opaque 127 from the missing binary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}
TIMEOUT_IMPL=${FM_CHECKPOINT_TIMEOUT_IMPL:-auto}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.

FM_CHECKPOINT_TIMEOUT_IMPL=auto|timeout|gtimeout|perl selects how the bound is
enforced. auto prefers timeout, then gtimeout, then the built-in perl fallback
that macOS hosts normally use. A named implementation that is not installed,
and auto on a host with none of the three, both exit 2.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

case "$TIMEOUT_IMPL" in
  auto)
    if command -v timeout >/dev/null 2>&1; then
      TIMEOUT_IMPL=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
      TIMEOUT_IMPL=gtimeout
    elif command -v perl >/dev/null 2>&1; then
      TIMEOUT_IMPL=perl
    else
      echo "error: no bounded-wait implementation available (need timeout, gtimeout, or perl)" >&2
      exit 2
    fi
    ;;
  perl|timeout|gtimeout)
    command -v "$TIMEOUT_IMPL" >/dev/null 2>&1 || {
      echo "error: FM_CHECKPOINT_TIMEOUT_IMPL=$TIMEOUT_IMPL but $TIMEOUT_IMPL is not installed" >&2
      exit 2
    }
    ;;
  *) echo "error: FM_CHECKPOINT_TIMEOUT_IMPL must be auto, timeout, gtimeout, or perl" >&2; exit 2 ;;
esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh"
}

set +e
case "$TIMEOUT_IMPL" in
  timeout) timeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR" ;;
  gtimeout) gtimeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR" ;;
  perl) run_with_perl_timeout >"$OUT" 2>"$ERR" ;;
esac
RC=$?
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
