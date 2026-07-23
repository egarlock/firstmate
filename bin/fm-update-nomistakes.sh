#!/usr/bin/env bash
# Adopt the latest of the captain's no-mistakes fork into the RUNNING gate.
#
# Mechanical half of the /updatenomistakes skill. no-mistakes is compiled Go,
# so — unlike firstmate — a pull alone changes nothing: the canonical checkout
# must be pulled, rebuilt, and reinstalled for the running gate to change.
# Flow: locate the canonical checkout (sibling no-mistakes.git, FM_NM_CANONICAL
# override, shared with fm-show-dev-setup.sh via fm-nm-lib.sh); refuse if it is
# dirty (never clobber WIP — not bypassable); refuse if a pipeline run is
# active anywhere, because `make install` restarts the daemon and would kill a
# crew mid-validation; `git pull --ff-only origin main` with EXPLICIT origin
# (the checkout's main may track a different remote; pulling the fork must
# never depend on the tracking ref); `make install` (build, install to GOPATH,
# daemon restart); then verify the CLI on PATH, the GOPATH binary, and the
# symlink target all report the new HEAD commit.
#
# Active-run detection: the installed CLI's `runs`/`axi status` are
# per-repository, so this reads the daemon's sqlite run database read-only
# (fm_nm_active_runs in fm-nm-lib.sh) — any run not in a terminal status
# (completed/cancelled/failed), in any repo, counts as active. If the count
# cannot be determined (sqlite3 missing, db absent, schema drift), the script
# refuses with a loud warning naming the daemon-restart risk and requires
# --force to proceed. --force also overrides a positively detected active run,
# for the captain who explicitly accepts killing it; the dirty refusal is
# never overridden.
#
# FAST-FORWARD ONLY: never force, never stash, never discard work. The only
# things touched are the canonical no-mistakes checkout, the GOPATH binary,
# and the daemon — never anything under projects/.
#
# Usage: fm-update-nomistakes.sh [--force] [--dry-run] [--help]
#   --force    proceed despite an active (or undeterminable) pipeline run
#   --dry-run  run every check, then print the pull/install commands instead
#              of executing them (nothing is modified)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# shellcheck source=bin/fm-nm-lib.sh
. "$SCRIPT_DIR/fm-nm-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update-nomistakes.sh [--force] [--dry-run] [--help]" >&2; }

FORCE=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) usage; exit 0 ;;
    *)         usage; exit 1 ;;
  esac
done

# --- locate the canonical checkout -------------------------------------------

NM_DIR=$(fm_nm_canonical_dir)
if [ ! -d "$NM_DIR" ]; then
  echo "error: canonical no-mistakes checkout not found at $NM_DIR (set FM_NM_CANONICAL to override)" >&2
  exit 1
fi
if ! git -C "$NM_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $NM_DIR is not a git repository" >&2
  exit 1
fi

# --- refuse on a dirty checkout (never bypassable) ---------------------------

if [ -n "$(git -C "$NM_DIR" status --porcelain)" ]; then
  echo "error: $NM_DIR has uncommitted changes — refusing to touch it." >&2
  echo "       Commit or clean that work first; this script never stashes or discards WIP." >&2
  exit 1
fi

# --- refuse while on the wrong branch ----------------------------------------
# The pull below fast-forwards the CURRENT branch from origin/main; on any
# other branch that would silently advance a feature branch with main.

branch=$(git -C "$NM_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ "$branch" != "main" ]; then
  echo "error: $NM_DIR is on '${branch:-detached HEAD}', not main — refusing to pull origin/main into it." >&2
  echo "       Check out main in that checkout first." >&2
  exit 1
fi

# --- refuse while a pipeline run is active -----------------------------------

active=$(fm_nm_active_runs)
if [ -z "$active" ]; then
  if ! $FORCE; then
    echo "error: cannot determine whether a no-mistakes pipeline run is active (sqlite3 missing, db absent, or schema changed)." >&2
    echo "       make install RESTARTS THE DAEMON and would kill any crew mid-validation." >&2
    echo "       Re-run with --force only if you are sure no run is active." >&2
    exit 1
  fi
  echo "warning: active-run state is UNKNOWN; proceeding on --force. A daemon restart kills any active run." >&2
elif [ "$active" -gt 0 ]; then
  if ! $FORCE; then
    echo "error: $active no-mistakes pipeline run(s) are active — refusing: make install restarts the daemon and would kill them." >&2
    fm_nm_active_run_list | sed 's/^/       active: /' >&2
    echo "       Wait for them to finish, or re-run with --force to knowingly kill them." >&2
    exit 1
  fi
  echo "warning: killing $active active run(s) on --force via the daemon restart." >&2
fi

# --- fast-forward pull from the fork -----------------------------------------

old_head=$(git -C "$NM_DIR" rev-parse HEAD)

if $DRY_RUN; then
  echo "dry-run: all checks passed; would run:"
  echo "dry-run:   git -C $NM_DIR pull --ff-only origin main"
  echo "dry-run:   make -C $NM_DIR install   (build, install to GOPATH, daemon restart)"
  echo "dry-run:   verify CLI/GOPATH/symlink-target binaries against the new HEAD"
  exit 0
fi

git -C "$NM_DIR" pull --ff-only origin main
new_head=$(git -C "$NM_DIR" rev-parse HEAD)
new_short=$(git -C "$NM_DIR" rev-parse --short HEAD)

# --- decide whether a rebuild is needed --------------------------------------
# Already current means the checkout did not advance AND every installed
# binary already reports HEAD; a checkout that is current with a behind or
# drifted binary still rebuilds.

# Full sha the commit reported by binary <path> resolves to, or nothing.
installed_commit() {
  local c
  c=$(fm_nm_version_commit "$1")
  [ -n "$c" ] || return 0
  git -C "$NM_DIR" rev-parse --verify --quiet "$c^{commit}" 2>/dev/null || true
}

cli_path=$(command -v no-mistakes 2>/dev/null || true)
gopath_bin=$(fm_nm_gopath_bin)

if [ "$new_head" = "$old_head" ]; then
  echo "checkout already current at $new_short"
  if [ -n "$cli_path" ] && [ -n "$gopath_bin" ] && [ -x "$gopath_bin" ] \
    && [ "$(installed_commit "$cli_path")" = "$new_head" ] \
    && [ "$(installed_commit "$gopath_bin")" = "$new_head" ]; then
    echo "already current: installed binaries all report $new_short; nothing to do"
    exit 0
  fi
  echo "installed binary is behind or missing — rebuilding anyway"
else
  echo "pulled $(git -C "$NM_DIR" rev-parse --short "$old_head")..$new_short from origin/main"
fi

# --- rebuild and reinstall ----------------------------------------------------

make -C "$NM_DIR" install

# --- verify every binary now reports the new HEAD -----------------------------

verify_failed=false
verify_bin() {
  local label=$1 path=$2 got
  got=$(installed_commit "$path")
  if [ "$got" = "$new_head" ]; then
    echo "verify: $label ok ($new_short)"
  else
    echo "verify: $label ($path) reports $(fm_nm_version_commit "$path" || true), expected $new_short" >&2
    verify_failed=true
  fi
}

cli_path=$(command -v no-mistakes 2>/dev/null || true)
if [ -n "$cli_path" ]; then
  verify_bin "CLI on PATH" "$cli_path"
  if [ -L "$cli_path" ]; then
    verify_bin "symlink target" "$(fm_nm_resolve_link "$cli_path")"
  fi
else
  echo "verify: no no-mistakes on PATH after install" >&2
  verify_failed=true
fi
if [ -n "$gopath_bin" ]; then
  verify_bin "GOPATH binary" "$gopath_bin"
else
  echo "verify: go not installed; cannot check the GOPATH binary" >&2
  verify_failed=true
fi

if $verify_failed; then
  echo "error: installed no-mistakes binaries disagree with the new HEAD — the gate may be split; run fm-show-dev-setup.sh to inspect" >&2
  exit 1
fi
echo "no-mistakes updated: running gate is now $new_short ($(git -C "$NM_DIR" log -1 --format=%s))"
