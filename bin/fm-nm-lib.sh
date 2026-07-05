# shellcheck shell=bash
# fm-nm-lib.sh — shared no-mistakes dev-setup helpers for firstmate.
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/fm-env-lib.sh"
#   fm_env_init
#   . "$SCRIPT_DIR/fm-nm-lib.sh"
#
# ONE definition of "where is the captain's canonical no-mistakes checkout",
# "what commit does a no-mistakes binary report", and "is a pipeline run
# active", shared by fm-show-dev-setup.sh (read-only reporting) and
# fm-update-nomistakes.sh (adopt + rebuild + verify), so the two skills can
# never disagree about which checkout or binary they mean.
#
# Every helper here is read-only and returns 0 (echoing nothing on failure),
# so set -eu callers can capture output without guarding each call.
#
# Idempotent: safe to source more than once.

if [ -z "${FM_NM_LIB_SOURCED:-}" ]; then
  FM_NM_LIB_SOURCED=1

  # Canonical no-mistakes checkout: FM_NM_CANONICAL wins, else the
  # no-mistakes.git sibling of the operating firstmate root. Echoes the path,
  # which may not exist; callers decide how to report absence.
  fm_nm_canonical_dir() {
    printf '%s\n' "${FM_NM_CANONICAL:-$(dirname "$FM_ROOT")/no-mistakes.git}"
  }

  # Commit a no-mistakes binary reports: runs `<binary> --version` and extracts
  # the parenthesized short sha from
  # "no-mistakes version vX.Y.Z-N-gSHA (SHA) DATE". Echoes the sha, or nothing
  # when the binary is missing, not executable, or prints something else.
  fm_nm_version_commit() {
    local bin=$1 out
    [ -n "$bin" ] && [ -x "$bin" ] || return 0
    out=$("$bin" --version 2>/dev/null | head -1) || true
    printf '%s\n' "$out" | sed -n 's/.*(\([0-9a-f]\{7,40\}\)).*/\1/p'
  }

  # GOPATH no-mistakes binary path (what `make install` installs and the
  # daemon runs). Echoes nothing when go is not installed.
  fm_nm_gopath_bin() {
    command -v go >/dev/null 2>&1 || return 0
    printf '%s/bin/no-mistakes\n' "$(go env GOPATH)"
  }

  # Fully resolve a symlink chain (bounded), echoing the final absolute path.
  # A non-symlink echoes itself; a dangling or over-deep chain echoes the last
  # path reached.
  fm_nm_resolve_link() {
    local path=$1 target i=0
    while [ -L "$path" ] && [ "$i" -lt 10 ]; do
      target=$(readlink "$path")
      case "$target" in
        /*) path=$target ;;
        *) path="$(dirname "$path")/$target" ;;
      esac
      i=$((i + 1))
    done
    printf '%s\n' "$path"
  }

  # Running no-mistakes daemon process line(s), "pid cmdline" per line, or
  # nothing when no daemon is running.
  fm_nm_daemon_procs() {
    pgrep -fl 'no-mistakes daemon' 2>/dev/null || true
  }

  # no-mistakes data root: FM_NM_DATA_ROOT wins, else the --root argument of
  # the running daemon, else the CLI default $HOME/.no-mistakes.
  fm_nm_data_root() {
    local line root
    if [ -n "${FM_NM_DATA_ROOT:-}" ]; then
      printf '%s\n' "$FM_NM_DATA_ROOT"
      return 0
    fi
    line=$(fm_nm_daemon_procs | head -1)
    root=$(printf '%s\n' "$line" | sed -n 's/.*--root[= ]\([^ ][^ ]*\).*/\1/p')
    printf '%s\n' "${root:-$HOME/.no-mistakes}"
  }

  # Count active (non-terminal) no-mistakes pipeline runs across ALL repos by
  # reading the daemon's sqlite state read-only; the CLI's `runs`/`axi status`
  # are per-repository, and a `make install` daemon restart would kill an
  # active run in any repo. Anything not in a known terminal status counts as
  # active, so an unknown future status fails safe. sqlite3 runs with
  # -init /dev/null -batch -noheader so ~/.sqliterc can never reshape the
  # output, and anything but a pure non-negative integer is discarded. Echoes
  # the count, or nothing when it cannot be determined (sqlite3 missing, db
  # absent, schema mismatch, non-numeric output) — callers must treat empty as
  # "unknown", not as zero.
  fm_nm_active_runs() {
    local db out
    db="$(fm_nm_data_root)/state.sqlite"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    [ -f "$db" ] || return 0
    out=$(sqlite3 -init /dev/null -batch -noheader -readonly "$db" \
      "SELECT COUNT(*) FROM runs WHERE status NOT IN ('completed','cancelled','failed');" \
      2>/dev/null) || return 0
    case "$out" in
      ''|*[!0-9]*) return 0 ;;
    esac
    printf '%s\n' "$out"
  }

  # One "<status> <branch> (<run-id-prefix>)" line per active run, for refusal
  # messages. Same read-only source, terminal-status set, and config-proof
  # sqlite3 invocation as fm_nm_active_runs; echoes nothing when unavailable.
  fm_nm_active_run_list() {
    local db
    db="$(fm_nm_data_root)/state.sqlite"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    [ -f "$db" ] || return 0
    sqlite3 -init /dev/null -batch -noheader -readonly "$db" \
      "SELECT status || ' ' || branch || ' (' || substr(id,1,8) || ')' FROM runs WHERE status NOT IN ('completed','cancelled','failed');" \
      2>/dev/null || true
  }
fi
