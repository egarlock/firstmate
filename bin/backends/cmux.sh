#!/usr/bin/env bash
# bin/backends/cmux.sh - the cmux session-provider adapter (EXPERIMENTAL).
#
# cmux (https://cmux.com, manaflow-ai/cmux) is a native macOS terminal built
# for running AI coding agents, controlled through a Unix-socket CLI. This
# adapter follows the same P2 pattern as bin/backends/herdr.sh: cmux is a
# session provider ONLY - the worktree provider stays treehouse, exactly like
# tmux. Sourced only through bin/fm-backend.sh's fm_backend_source, never
# directly. Empirical verification lives in docs/cmux-backend.md.
#
# Container shape: ONE cmux WORKSPACE per task, named "fm-<id>", in the
# app's current window. cmux workspaces are the tab-like unit of its sidebar
# (each shows cwd, git branch, notifications), so workspace-per-task gives the
# captain the same at-a-glance fleet view a tmux session's window list does -
# and unlike herdr, cmux's own sidebar is workspace-first, so this shape IS
# the native human-watching surface.
#
# Target string shape: "cmux:<workspace-uuid>", stored in a cmux task's meta
# window= field. The literal "cmux" prefix keeps the target colon-containing
# (so fm_backend_of_selector's explicit-target matching and
# fm_backend_resolve_selector's pass-through both work unchanged) and makes
# the string self-describing; the remainder after the FIRST colon is the
# workspace UUID (UUIDs are stable handles; short refs like "workspace:2" are
# index-based and can shift, so they are never stored).
#
# Socket auth: the cmux CLI itself resolves auth from --password, then
# CMUX_SOCKET_PASSWORD, then the app-saved password. This adapter passes
# nothing extra; if the socket refuses (mode "password" with no reachable
# password, or mode "off"/"cmuxOnly" from outside a cmux terminal), every op
# fails and fm_backend_cmux_socket_check reports the actionable fix.
#
# Requires: cmux (CLI + running app), jq (JSON parsing). Both are gated
# behind selecting this backend; bin/fm-bootstrap.sh's core tool list is
# unaffected.

# Minimum verified cmux version (see docs/cmux-backend.md). `cmux version`
# works without the socket, so the gate never needs auth.
FM_BACKEND_CMUX_MIN_VERSION="0.64.17"

# Every cmux invocation goes through fm_backend_cmux_cli so legacy-alias
# notices ("'list-workspaces' is now an alias for ...") can never contaminate
# parsed output: CMUX_QUIET=1 silences them.
fm_backend_cmux_cli() {
  CMUX_QUIET=1 cmux "$@"
}

# fm_backend_cmux_tool_check: refuse loudly if cmux or jq is missing.
fm_backend_cmux_tool_check() {
  command -v cmux >/dev/null 2>&1 || { echo "error: backend=cmux selected but the 'cmux' CLI is not installed (https://cmux.com)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=cmux selected but 'jq' is not installed (required to parse cmux's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_cmux_version_check: refuse loudly on a missing/old cmux client.
# `cmux version` prints "cmux <semver> (<build>) [<sha>]" and needs no socket.
fm_backend_cmux_version_check() {
  fm_backend_cmux_tool_check || return 1
  local raw version
  raw=$(fm_backend_cmux_cli version 2>/dev/null) || { echo "error: 'cmux version' failed; is cmux installed correctly?" >&2; return 1; }
  version=$(printf '%s' "$raw" | awk '{print $2}' | head -1)
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *)
      echo "error: could not parse a cmux version from '$raw'; refusing to use an unverified cmux build" >&2
      return 1
      ;;
  esac
  # Lowest-first semver compare: refuse iff installed < minimum.
  if [ "$(printf '%s\n%s\n' "$version" "$FM_BACKEND_CMUX_MIN_VERSION" | sort -V | head -1)" != "$FM_BACKEND_CMUX_MIN_VERSION" ]; then
    echo "error: cmux $version is older than the verified minimum $FM_BACKEND_CMUX_MIN_VERSION; update cmux before using backend=cmux" >&2
    return 1
  fi
  return 0
}

# fm_backend_cmux_socket_check: one cheap authenticated round-trip. cmux is a
# GUI app, not a headless server firstmate can start itself (the tmux/herdr
# `server ensure` step has no safe cmux analogue), so an unreachable or
# unauthorized socket refuses with the exact operator fix instead of
# auto-launching the captain's app.
fm_backend_cmux_socket_check() {
  local out
  if out=$(fm_backend_cmux_cli ping 2>&1); then
    return 0
  fi
  case "$out" in
    *[Aa]uth*)
      echo "error: cmux socket refused auth. Set Settings > Automation > socket control mode to allow local automation, or export CMUX_SOCKET_PASSWORD." >&2
      ;;
    *)
      echo "error: cmux socket is unreachable (is the cmux app running?): $out" >&2
      ;;
  esac
  return 1
}

# fm_backend_cmux_container_ensure: spawn-time gate (version + live socket).
# cmux has no named-session/workspace container to create - the app itself is
# the container and tasks are top-level workspaces - so this only verifies the
# environment and echoes the constant container token "cmux".
fm_backend_cmux_container_ensure() {
  fm_backend_cmux_version_check || return 1
  fm_backend_cmux_socket_check || return 1
  printf 'cmux'
}

# fm_backend_cmux_workspace_by_name: the UUID of the workspace whose
# custom_title is <name>, or empty. Read-only; used by the duplicate check,
# bare-selector fallback, and list_live. Verified: `new-workspace --name` sets
# custom_title (title mirrors it until something else retitles the row -
# cmux's opt-in AI auto-naming rewrites `title` from conversation content, so
# custom_title is the ONLY stable match key; manual/custom titles always win
# over auto-naming per cmux's own settings docs).
fm_backend_cmux_workspace_by_name() {  # <name>
  local list
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r --arg name "$1" \
    '.workspaces[]? | select(.custom_title == $name) | .id' 2>/dev/null | head -1
}

# fm_backend_cmux_create_task: create the task's workspace named <label> in
# <cwd>, refusing an existing <label> (cmux does not enforce workspace-name
# uniqueness, so the duplicate check is ours). --focus false keeps the spawn
# from yanking the captain's focus. Echoes the new workspace UUID.
#
# Verified (0.64.17): `new-workspace` IGNORES --json and prints a text
# acknowledgment ("OK workspace:<n>") carrying only the index-based short ref,
# which is unstable and never stored. The stable UUID is resolved by an
# immediate custom_title lookup instead; the just-refused-duplicates check
# above makes that lookup unambiguous.
fm_backend_cmux_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 dup out wsid
  dup=$(fm_backend_cmux_workspace_by_name "$label")
  if [ -n "$dup" ]; then
    echo "error: cmux workspace '$label' already exists ($dup)" >&2
    return 1
  fi
  out=$(fm_backend_cmux_cli new-workspace --name "$label" --cwd "$cwd" --focus false 2>/dev/null) || return 1
  case "$out" in
    *OK\ workspace*) : ;;
    *)
      echo "error: cmux new-workspace did not acknowledge creating '$label' (got: $out)" >&2
      return 1
      ;;
  esac
  wsid=$(fm_backend_cmux_workspace_by_name "$label")
  if [ -z "$wsid" ]; then
    echo "error: created cmux workspace '$label' but could not resolve its UUID from the workspace list" >&2
    return 1
  fi
  fm_backend_cmux_wait_ready "cmux:$wsid"
  printf '%s' "$wsid"
}

# fm_backend_cmux_wait_ready: wake the new workspace's lazily-started
# terminal and block until its shell shows a stable prompt, then settle.
# Verified (docs/cmux-backend.md "Lazy terminal start"): an unfocused fresh
# workspace does not start its terminal process at all - read-screen stays
# empty and `cmux tree` shows no tty - until the surface first receives input
# or is viewed. So this sends one harmless Enter to trigger the start, then
# polls for stable non-empty screen content (the login banner + prompt).
# Bounded; on timeout it returns anyway and the spawn's own worktree-discovery
# poll surfaces any real failure loudly.
fm_backend_cmux_wait_ready() {  # <target>
  local target=$1 prev="" cur i
  local attempts=${FM_CMUX_READY_ATTEMPTS:-30} interval=${FM_CMUX_READY_INTERVAL:-0.5} settle=${FM_CMUX_READY_SETTLE:-1}
  fm_backend_cmux_send_key "$target" Enter || true
  for i in $(seq 1 "$attempts"); do
    cur=$(fm_backend_cmux_capture "$target" 10 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
      sleep "$settle"
      return 0
    fi
    prev=$cur
    sleep "$interval"
  done
  return 0
}

# fm_backend_cmux_parse_target: split "cmux:<workspace-uuid>" on the FIRST
# colon. Sets FM_BACKEND_CMUX_WS for the caller.
fm_backend_cmux_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_CMUX_WS=${target#*:}
  [ "${target%%:*}" = cmux ] && [ -n "$FM_BACKEND_CMUX_WS" ] && [ "$FM_BACKEND_CMUX_WS" != "$target" ]
}

# fm_backend_cmux_surface_tty: the tty name (e.g. "ttys011") of the
# workspace's selected terminal surface, from `cmux tree`, or empty when the
# terminal has not started yet (verified: an unfocused fresh workspace starts
# its terminal LAZILY - no tty, and zero-byte read-screen, until it first
# receives input or is viewed; docs/cmux-backend.md "Lazy terminal start").
fm_backend_cmux_surface_tty() {  # <workspace-uuid>
  fm_backend_cmux_cli tree --workspace "$1" 2>/dev/null \
    | sed -n 's/.*tty=\([a-zA-Z0-9]*\).*/\1/p' | head -1
}

# fm_backend_cmux_current_path: the workspace terminal's live working
# directory, or empty on any error. Mirrors tmux's pane_current_path poll used
# for worktree-path discovery after `treehouse get`.
#
# Verified pitfall (docs/cmux-backend.md "Live-cwd tracking"): the workspace
# list's `current_directory` field does NOT track the treehouse-get subshell -
# it stays frozen at the top shell's directory - so reading it here would
# starve fm-spawn.sh's worktree-discovery poll into a false timeout (this
# failed live in the first E2E attempt). Ground truth instead: the surface's
# tty (from `cmux tree`) plus the OS - the foreground process group on that
# tty read via `ps`, its cwd via `lsof` - which is exactly the OS-level
# semantics tmux's #{pane_current_path} provides. The JSON field remains the
# fallback for a not-yet-started terminal or an unreadable tty.
fm_backend_cmux_current_path() {  # <target>
  fm_backend_cmux_parse_target "$1" || return 0
  local tty pid cwd list
  tty=$(fm_backend_cmux_surface_tty "$FM_BACKEND_CMUX_WS")
  if [ -n "$tty" ]; then
    pid=$(ps -t "$tty" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\+/ { p=$1 } END { if (p) print p }')
    if [ -n "$pid" ]; then
      cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      if [ -n "$cwd" ]; then
        printf '%s' "$cwd"
        return 0
      fi
    fi
  fi
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r --arg id "$FM_BACKEND_CMUX_WS" \
    '.workspaces[]? | select(.id == $id) | .current_directory // empty' 2>/dev/null | head -1
}

# fm_backend_cmux_capture: bounded plain-text capture of the workspace's
# active terminal surface. Mirrors tmux's `capture-pane -p -S -N`.
# Defensive over-fetch: request a generous floor from cmux and trim locally
# with tail, so a viewport-dependent small-N quirk (herdr had exactly this
# bug) can never silently blank the composer-verification reads.
fm_backend_cmux_capture() {  # <target> <lines>
  fm_backend_cmux_parse_target "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  [ "$fetch" -ge 200 ] || fetch=200
  out=$(fm_backend_cmux_cli read-screen --workspace "$FM_BACKEND_CMUX_WS" --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_cmux_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c - fm-send.sh --key and stuck-crewmate-recovery) onto cmux's
# send-key names (verified set in docs/cmux-backend.md).
fm_backend_cmux_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_cmux_send_key: one named special key.
fm_backend_cmux_send_key() {  # <target> <key>
  fm_backend_cmux_parse_target "$1" || return 1
  local key
  key=$(fm_backend_cmux_normalize_key "$2")
  fm_backend_cmux_cli send-key --workspace "$FM_BACKEND_CMUX_WS" "$key" >/dev/null 2>&1
}

# fm_backend_cmux_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately (verified: `cmux send` does not auto-submit;
# docs/cmux-backend.md).
fm_backend_cmux_send_literal() {  # <target> <text>
  fm_backend_cmux_parse_target "$1" || return 1
  fm_backend_cmux_cli send --workspace "$FM_BACKEND_CMUX_WS" "$2" >/dev/null 2>&1
}

# fm_backend_cmux_send_text_line: send one line of TEXT then submit - the
# fixed spawn-time commands (`treehouse get`, the GOTMPDIR export). cmux has
# no atomic type-and-run primitive, so this composes literal send + enter.
fm_backend_cmux_send_text_line() {  # <target> <text>
  fm_backend_cmux_send_literal "$1" "$2" || return 1
  fm_backend_cmux_send_key "$1" Enter
}

# fm_backend_cmux_send_text_submit: type <text> once (literal), then submit
# with Enter, retried (Enter only, never retyped) until the screen visibly
# changes. Same delta-based verification as the herdr adapter (cmux's CLI
# exposes no ANSI/cursor-row composer read): capture right after typing as
# the TYPED baseline, then after each Enter compare - unchanged means the
# Enter was swallowed (retry), changed means submitted. The <settle> pause
# before the first Enter covers the same slash-command autocomplete-popup
# hazard tmux and herdr both showed. Echoes empty|pending|unknown|send-failed,
# the vocabulary fm-send.sh already branches on.
fm_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 typed after i=0
  fm_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_cmux_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  typed=$(fm_backend_cmux_capture "$target" 6) || { printf 'unknown'; return 0; }
  while :; do
    fm_backend_cmux_send_key "$target" Enter || true
    sleep "$sleep_s"
    after=$(fm_backend_cmux_capture "$target" 6) || { printf 'unknown'; return 0; }
    if [ "$after" != "$typed" ]; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_cmux_kill: remove the task's workspace, best-effort (mirrors
# tmux-kill-window's `|| true` contract).
fm_backend_cmux_kill() {  # <target>
  fm_backend_cmux_parse_target "$1" || return 0
  fm_backend_cmux_cli close-workspace --workspace "$FM_BACKEND_CMUX_WS" >/dev/null 2>&1 || true
}

# fm_backend_cmux_busy_state: semantic busy state. cmux tracks per-workspace
# agent activity through its agent hooks (the sidebar's working/waiting
# indicators), but the verified 0.64.17 workspace list exposes NO stable
# machine-readable agent-state field (the busy cue rides the auto-naming
# title's spinner glyph, which is opt-in and presentation-bound - never
# parsed). So this probes a forward-compatible `agent_status` field and, on
# the verified version, always reports unknown - the caller's cue to fall
# back to pane-regex detection, exactly like tmux.
fm_backend_cmux_busy_state() {  # <target>
  fm_backend_cmux_parse_target "$1" || { printf 'unknown'; return 0; }
  local list status
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$list" | jq -r --arg id "$FM_BACKEND_CMUX_WS" \
    '.workspaces[]? | select(.id == $id) | .agent_status // empty' 2>/dev/null | head -1)
  case "$status" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    # waiting/blocked: stuck on the human, not grinding - surface, don't suppress.
    waiting|blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_cmux_resolve_bare_selector: live-workspace-listing fallback for
# an ad hoc selector with no meta (mirrors tmux's list-windows grep).
fm_backend_cmux_resolve_bare_selector() {  # <name>
  local wsid
  wsid=$(fm_backend_cmux_workspace_by_name "$1")
  if [ -z "$wsid" ]; then
    echo "error: no cmux workspace named $1" >&2
    return 1
  fi
  printf 'cmux:%s' "$wsid"
}

# fm_backend_cmux_list_live: recovery/orphan discovery. Lists every workspace
# whose custom_title looks like a firstmate task window (fm-<id>), by NAME -
# never by trusting a stored id blindly. Read-only. One "cmux:<uuid>\t<name>"
# line per live task workspace.
fm_backend_cmux_list_live() {
  local list
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r \
    '.workspaces[]? | select((.custom_title // "") | startswith("fm-")) | "cmux:\(.id)\t\(.custom_title)"' 2>/dev/null
}
