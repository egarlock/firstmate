#!/usr/bin/env bash
# Show a live, read-only snapshot of the captain's dev setup.
#
# Mechanical half of the /showdevsetup skill. Scans the real repos on every
# invocation — nothing is cached and NOTHING is written anywhere (no state/,
# no data/, no projects/, no fetches), so the printout is always the current
# truth. For each repo it reports the origin remote (flagging the captain's
# egarlock/* fork), the branch and its upstream tracking ref, the HEAD
# one-line, and a dirty flag. Repos covered: the operating firstmate
# ($FM_ROOT), every clone under $FM_HOME/projects/, the canonical no-mistakes
# checkout (sibling no-mistakes.git, overridable via FM_NM_CANONICAL — also
# flagged when behind its local origin/main tracking ref), and a treehouse
# sibling checkout when present.
#
# The no-mistakes binary wiring section is the load-bearing part: no-mistakes
# is compiled Go, so the CLI on PATH (often a symlink into the canonical
# checkout's bin/), the GOPATH binary the daemon runs, and the symlink target
# can silently drift apart after a partial rebuild. It prints each binary's
# --version commit plus the running daemon pid, and ends with an explicit
# PASS/DRIFT verdict on whether they all report the same commit.
#
# Missing pieces (a repo absent, no daemon, no CLI on PATH) print a clear
# "(absent)"/"(not running)" instead of erroring out.
#
# Usage: fm-show-dev-setup.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
fm_env_init            # FM_ROOT, FM_HOME, STATE
# shellcheck source=bin/fm-nm-lib.sh
. "$SCRIPT_DIR/fm-nm-lib.sh"

usage() { echo "usage: fm-show-dev-setup.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# Print one repo's block: origin (+fork flag), branch -> upstream, HEAD
# one-line, dirty flag. <indent> prefixes every detail line.
report_repo() {
  local dir=$1 indent=$2
  local url fork branch upstream head dirty

  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "${indent}(not a git repo)"
    return 0
  fi

  url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ -z "$url" ]; then
    echo "${indent}origin:  (no origin remote)"
  else
    case "$url" in
      *github.com[:/]egarlock/*) fork="captain's fork" ;;
      *)                         fork="not the captain's fork" ;;
    esac
    echo "${indent}origin:  $url  ($fork)"
  fi

  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    echo "${indent}branch:  $branch -> ${upstream:-(no upstream)}"
  else
    echo "${indent}branch:  detached @ $(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
  fi

  head=$(git -C "$dir" log -1 --oneline 2>/dev/null | head -1 || true)
  echo "${indent}HEAD:    ${head:-(no commits)}"

  # --no-optional-locks: plain `git status` may opportunistically rewrite
  # .git/index; this scan promises to write nothing at all.
  if [ -n "$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    dirty="yes (uncommitted changes)"
  else
    dirty="no"
  fi
  echo "${indent}dirty:   $dirty"
}

echo "dev setup"
echo

# --- operating firstmate -----------------------------------------------------

echo "firstmate (operating): $FM_ROOT"
report_repo "$FM_ROOT" "  "
echo

# --- project clones ----------------------------------------------------------

echo "projects/: $PROJECTS_DIR"
found_project=false
if [ -d "$PROJECTS_DIR" ]; then
  for proj in "$PROJECTS_DIR"/*/; do
    [ -d "$proj" ] || continue
    found_project=true
    proj=${proj%/}
    echo "  $(basename "$proj"): $proj"
    report_repo "$proj" "    "
  done
fi
$found_project || echo "  (none)"
echo

# --- canonical no-mistakes checkout ------------------------------------------

NM_DIR=$(fm_nm_canonical_dir)
echo "no-mistakes (canonical): $NM_DIR"
if [ -d "$NM_DIR" ]; then
  report_repo "$NM_DIR" "  "
  if git -C "$NM_DIR" rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1; then
    behind=$(git -C "$NM_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo '?')
    if [ "$behind" = "0" ]; then
      echo "  behind origin/main: no (as of last fetch)"
    else
      echo "  behind origin/main: yes, $behind commit(s) (as of last fetch)"
    fi
  else
    echo "  behind origin/main: (no origin/main tracking ref)"
  fi
else
  echo "  (absent — set FM_NM_CANONICAL to point at the checkout)"
fi
echo

# --- treehouse sibling checkout ----------------------------------------------

TH_DIR=""
for cand in "$(dirname "$FM_ROOT")/treehouse.git" "$(dirname "$FM_ROOT")/treehouse"; do
  if [ -d "$cand" ]; then TH_DIR=$cand; break; fi
done
if [ -n "$TH_DIR" ]; then
  echo "treehouse: $TH_DIR"
  report_repo "$TH_DIR" "  "
else
  echo "treehouse: (absent — no sibling checkout)"
fi
echo

# --- no-mistakes binary wiring -----------------------------------------------
# The split-binary drift check: the CLI on PATH, its symlink target, and the
# GOPATH binary (what the daemon runs) must all report the same commit.

echo "no-mistakes binary wiring"

cli_commit="" target_commit="" gopath_commit=""
cli_path=$(command -v no-mistakes 2>/dev/null || true)
if [ -n "$cli_path" ]; then
  echo "  CLI on PATH:    $cli_path"
  cli_commit=$(fm_nm_version_commit "$cli_path")
  echo "    version:      $("$cli_path" --version 2>/dev/null | head -1 || echo '(unreadable)')"
  if [ -L "$cli_path" ]; then
    target_path=$(fm_nm_resolve_link "$cli_path")
    echo "    symlink ->    $target_path"
    target_commit=$(fm_nm_version_commit "$target_path")
    echo "    target ver:   $("$target_path" --version 2>/dev/null | head -1 || echo '(unreadable)')"
  fi
else
  echo "  CLI on PATH:    (absent — no no-mistakes on PATH)"
fi

gopath_bin=$(fm_nm_gopath_bin)
if [ -n "$gopath_bin" ] && [ -x "$gopath_bin" ]; then
  echo "  GOPATH binary:  $gopath_bin"
  gopath_commit=$(fm_nm_version_commit "$gopath_bin")
  echo "    version:      $("$gopath_bin" --version 2>/dev/null | head -1 || echo '(unreadable)')"
elif [ -n "$gopath_bin" ]; then
  echo "  GOPATH binary:  (absent — nothing at $gopath_bin)"
else
  echo "  GOPATH binary:  (absent — go is not installed)"
fi

daemon_line=$(fm_nm_daemon_procs | head -1)
if [ -n "$daemon_line" ]; then
  echo "  daemon:         running (pid ${daemon_line%% *})"
else
  echo "  daemon:         (not running)"
fi

# Verdict: PASS iff the CLI and GOPATH binaries are both present and every
# commit we could read (CLI, GOPATH, symlink target) is the same one.
verdict_detail=""
if [ -z "$cli_commit" ]; then
  verdict_detail="CLI on PATH is missing or reports no commit"
elif [ -z "$gopath_commit" ]; then
  verdict_detail="GOPATH binary is missing or reports no commit"
elif [ "$cli_commit" != "$gopath_commit" ]; then
  verdict_detail="CLI reports $cli_commit but GOPATH binary reports $gopath_commit"
elif [ -n "$target_commit" ] && [ "$target_commit" != "$cli_commit" ]; then
  verdict_detail="symlink target reports $target_commit but CLI reports $cli_commit"
fi
if [ -z "$verdict_detail" ]; then
  echo "  verdict:        PASS — CLI, GOPATH binary, and symlink target all report commit $cli_commit"
else
  echo "  verdict:        DRIFT — $verdict_detail"
fi
