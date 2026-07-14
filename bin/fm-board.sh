#!/usr/bin/env bash
# fm-board.sh - launch firstmate's local task board (localhost web UI).
#
# A rudimentary, Trello-like web board over firstmate's existing backlog:
#   Suggested | Todo/Queued | In Progress | Completed
# It reads data/backlog.md (the tasks-axi markdown backend) as the single source
# of truth for Queued / In flight / Done, and a local, gitignored
# data/board-suggestions.json for the Suggested lane. Reordering the Queued lane
# and promoting a suggestion write back through the same backlog contract.
#
# This launcher is a thin wrapper: it resolves firstmate's environment and execs
# the Python server (bin/fm-board-server.py, standard library only). The server
# binds ONLY to a loopback address (default 127.0.0.1), so the write API is never
# exposed to the network.
#
# Usage:
#   bin/fm-board.sh                 # serve on 127.0.0.1:8787 and open a browser
#   bin/fm-board.sh --port 9000     # choose a port
#   bin/fm-board.sh --no-open       # do not open a browser
#   bin/fm-board.sh --host 127.0.0.1  # loopback host (non-loopback is refused)
#
# Bash 3.2 compatible (stock macOS /bin/bash).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SERVER="$SCRIPT_DIR/fm-board-server.py"

usage() {
  cat <<'USAGE'
fm-board.sh - launch firstmate's local task board (localhost web UI).

  bin/fm-board.sh                 serve on 127.0.0.1:8787 and open a browser
  bin/fm-board.sh --port <n>      choose a port (default 8787)
  bin/fm-board.sh --host <addr>   loopback host only (default 127.0.0.1)
  bin/fm-board.sh --no-open       do not open a browser
USAGE
  exit "${1:-0}"
}

HOST="127.0.0.1"
PORT="8787"
OPEN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; HOST="${1:-}"; [ -n "$HOST" ] || { echo "fm-board: --host needs a value" >&2; exit 2; } ;;
    --port) shift; PORT="${1:-}"; [ -n "$PORT" ] || { echo "fm-board: --port needs a value" >&2; exit 2; } ;;
    --no-open) OPEN=0 ;;
    -h|--help) usage 0 ;;
    *) echo "fm-board: unknown argument: $1" >&2; usage 2 ;;
  esac
  shift
done

case "$PORT" in
  ''|*[!0-9]*) echo "fm-board: --port must be a number" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "fm-board: python3 is required but was not found on PATH" >&2
  exit 1
}
[ -f "$SERVER" ] || { echo "fm-board: server not found: $SERVER" >&2; exit 1; }

# Export the resolved environment for the server to read.
export FM_HOME FM_ROOT
export FM_DATA="$DATA"
export FM_STATE="$STATE"

url="http://$HOST:$PORT/"

# Open a browser shortly after the server comes up, without blocking the server.
if [ "$OPEN" = 1 ]; then
  (
    sleep 1
    if command -v open >/dev/null 2>&1; then
      open "$url" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url" >/dev/null 2>&1 || true
    fi
  ) &
fi

echo "fm-board: open $url (Ctrl-C to stop)" >&2
exec python3 "$SERVER" serve --host "$HOST" --port "$PORT"
