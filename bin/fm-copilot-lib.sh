# shellcheck shell=bash
# GitHub Copilot CLI worker adapter: the ONE owner of the configured launch
# command and the spawn-time version gate.
#
# Usage: . bin/fm-copilot-lib.sh   (sourced; no side effects on source)
#
# Launch command (config/copilot-cmd). The optional local, gitignored file holds
# one command line whose words replace the executable prefix of every Copilot
# worker launch; absent means plain `copilot`. Blank lines and lines starting
# with `#` are ignored, and exactly one command line must remain. Words are
# split on spaces and tabs and never evaluated by a shell: each word may carry
# only letters, digits, and . _ / @ % + = : , -, so quoting, expansion, and
# redirection cannot ride the file. The first word must resolve to an
# executable, through PATH or as an absolute path, and is recorded as that
# absolute path so a pane whose PATH differs from the spawner's still runs the
# same program. The command is opaque: Firstmate appends its own flags and the
# brief after it and never interprets what it runs.
#
# Version gate. The verified launch shape (a per-task --plugin-dir carrying the
# lifecycle hooks, COPILOT_ALLOW_ALL=true workspace trust, -i brief submission,
# --reasoning-effort, --no-ask-user) is refused on a CLI older than
# FM_COPILOT_MIN_VERSION or whose `--version` output names no GitHub Copilot CLI
# version, so an incompatible install fails before any endpoint exists rather
# than parking a worker. The probe runs the configured command under the shared
# hard bound (bin/fm-timeout-lib.sh) with stdin detached; FM_COPILOT_VERSION_TIMEOUT
# overrides the default 30 seconds.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

FM_COPILOT_MIN_VERSION='1.0.68'

# fm_copilot_launch_words <config-dir>: print the launch command's words, one
# per line, with the first resolved to an absolute executable path. Returns 1
# with a reason on stderr for a malformed file or an unresolvable executable.
fm_copilot_launch_words() {  # <config-dir>
  local file=${1:?config directory required}/copilot-cmd line cmd='' count=0 word first=1 resolved
  local -a words
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      echo "error: config/copilot-cmd must be a readable regular file" >&2
      return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case "$line" in
        *[![:space:]]*) ;;
        *) continue ;;
      esac
      line=${line#"${line%%[![:space:]]*}"}
      case "$line" in \#*) continue ;; esac
      count=$((count + 1))
      cmd=$line
    done <"$file"
    if [ "$count" -ne 1 ]; then
      echo "error: config/copilot-cmd must contain exactly one command line (found $count); for example: copilot" >&2
      return 1
    fi
  else
    cmd=copilot
  fi
  read -r -a words <<<"$cmd"
  for word in "${words[@]}"; do
    case "$word" in
      *[!A-Za-z0-9._/@%+=:,-]*)
        echo "error: config/copilot-cmd word '$word' carries a character outside letters, digits, and . _ / @ % + = : , - (the line is split on whitespace, never run through a shell)" >&2
        return 1
        ;;
    esac
    if [ "$first" -eq 1 ]; then
      first=0
      resolved=$(type -P -- "$word" 2>/dev/null) || resolved=
      case "$resolved" in
        /*) ;;
        ?*) resolved="$(cd "$(dirname -- "$resolved")" 2>/dev/null && pwd -P)/${resolved##*/}" ;;
      esac
      if [ -z "$resolved" ] || [ ! -x "$resolved" ] || [ -d "$resolved" ]; then
        echo "error: Copilot launch command '$word' is not an executable on PATH; install GitHub Copilot CLI or set config/copilot-cmd" >&2
        return 1
      fi
      word=$resolved
    fi
    printf '%s\n' "$word"
  done
}

# fm_copilot_launch_prefix <config-dir>: the launch command as one line of
# single-quoted words, ready to splice into a launch command.
fm_copilot_launch_prefix() {  # <config-dir>
  local words word out=''
  words=$(fm_copilot_launch_words "$1") || return 1
  while IFS= read -r word; do
    out="$out${out:+ }'$(printf '%s' "$word" | sed "s/'/'\\\\''/g")'"
  done <<EOF
$words
EOF
  printf '%s\n' "$out"
}

# fm_copilot_version <word>...: print the GitHub Copilot CLI version X.Y.Z the
# command reports for --version, or return 1. Only the CLI's own
# `GitHub Copilot CLI X.Y.Z` line counts; any other output is ignored.
fm_copilot_version() {  # <word>...
  local bound=${FM_COPILOT_VERSION_TIMEOUT:-30} out
  case "$bound" in ''|*[!0-9]*|0*) bound=30 ;; esac
  out=$(fm_run_timed "$bound" "$@" --version 2>/dev/null </dev/null) || [ -n "$out" ] || return 1
  printf '%s\n' "$out" \
    | sed -nE 's/.*GitHub Copilot CLI ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 | grep . || return 1
}

# fm_copilot_version_supported <X.Y.Z>: succeed iff the version is at least
# FM_COPILOT_MIN_VERSION, compared numerically field by field.
fm_copilot_version_supported() {  # <X.Y.Z>
  local have=$1 min=$FM_COPILOT_MIN_VERSION h m i
  for i in 1 2 3; do
    h=$(printf '%s' "$have" | cut -d. -f"$i")
    m=$(printf '%s' "$min" | cut -d. -f"$i")
    case "$h" in ''|*[!0-9]*) return 1 ;; esac
    [ "$((10#$h))" -gt "$((10#$m))" ] && return 0
    [ "$((10#$h))" -lt "$((10#$m))" ] && return 1
  done
  return 0
}
