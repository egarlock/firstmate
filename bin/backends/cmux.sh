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
# Container shape - CONFIGURABLE, default tab-per-task:
#
#   tab (default)   ONE cmux SURFACE (tab) per task, titled "fm-<id>", inside
#                   one container workspace: the workspace firstmate itself is
#                   running in (CMUX_WORKSPACE_ID) when inside cmux, else a
#                   shared workspace named "firstmate". This mirrors the tmux
#                   adapter exactly (crewmate windows join YOUR session when
#                   firstmate runs inside tmux, else a detached "firstmate"
#                   session): the captain watches every task as a tab in the
#                   tab bar of the workspace they already have open.
#   workspace       ONE cmux WORKSPACE per task, named "fm-<id>". Each task
#                   gets its own sidebar row with cmux's native per-workspace
#                   status (cwd, git branch, notifications) - the herdr-doc
#                   "human-watching axis" argument, for captains who prefer a
#                   row per task over a tab per task.
#
# Selection: FM_CMUX_CONTAINER env, then the first word of the local
# gitignored config/cmux-container, then the default "tab"
# (fm_backend_cmux_container_mode).
#
# Target string shapes, stored in a cmux task's meta window= field:
#   tab mode        "cmux:<workspace-uuid>:<surface-uuid>"
#   workspace mode  "cmux:<workspace-uuid>"
# The literal "cmux" prefix keeps the target colon-containing (so
# fm_backend_of_selector's explicit-target matching and
# fm_backend_resolve_selector's pass-through both work unchanged) and makes
# the string self-describing; only UUIDs are stored (short refs like
# "workspace:2"/"surface:9" are index-based and can shift, so they are never
# stored).
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
FM_BACKEND_CMUX_MIN_VERSION="0.63.1"
FM_BACKEND_CMUX_SHARED_WORKSPACE="firstmate"

# Every cmux invocation goes through fm_backend_cmux_cli so legacy-alias
# notices ("'list-workspaces' is now an alias for ...") can never contaminate
# parsed output: CMUX_QUIET=1 silences them.
fm_backend_cmux_cli() {
  CMUX_QUIET=1 cmux "$@"
}

# fm_backend_cmux_focused_surface: the currently focused surface ref, or empty
# when cmux cannot report one (for example from a headless/socket-only caller).
fm_backend_cmux_focused_surface() {
  local snapshot
  snapshot=$(fm_backend_cmux_cli identify --no-caller 2>/dev/null) || return 0
  [ -n "$snapshot" ] || return 0
  printf '%s' "$snapshot" | jq -r '.focused.surface_ref // empty' 2>/dev/null | head -1
}

# fm_backend_cmux_restore_surface: return focus to a surface captured before a
# task tab was created. An empty ref is a supported no-op; a reported ref that
# cmux cannot restore is an explicit spawn failure.
fm_backend_cmux_restore_surface() {  # <surface-ref>
  local surface=${1:-}
  [ -n "$surface" ] || return 0
  if ! fm_backend_cmux_cli move-surface --surface "$surface" --focus true >/dev/null 2>&1; then
    echo "error: created cmux task tab but could not restore previously focused surface $surface" >&2
    return 1
  fi
}

# fm_backend_cmux_container_mode: resolve the task-container shape. Precedence:
# FM_CMUX_CONTAINER env, then the first non-empty word of the local gitignored
# config/cmux-container, then the default "tab". Any unknown value falls back
# to "tab" with a stderr warning rather than failing a spawn.
fm_backend_cmux_container_mode() {
  local mode="" line
  if [ -n "${FM_CMUX_CONTAINER:-}" ]; then
    mode=$FM_CMUX_CONTAINER
  elif [ -f "${FM_BACKEND_CONFIG_DIR:-}/cmux-container" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$line" ]; then
        mode=$line
        break
      fi
    done < "$FM_BACKEND_CONFIG_DIR/cmux-container"
  fi
  case "$mode" in
    tab|workspace) printf '%s' "$mode" ;;
    '') printf 'tab' ;;
    *)
      echo "warning: unknown cmux container mode '$mode' (known: tab, workspace); using tab" >&2
      printf 'tab'
      ;;
  esac
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
# auto-launching the captain's app. Verified sharp edge: a socket-control-mode
# change applies only at app restart (docs/cmux-backend.md).
fm_backend_cmux_socket_check() {
  local out
  if out=$(fm_backend_cmux_cli ping 2>&1); then
    return 0
  fi
  case "$out" in
    *[Aa]uth*)
      echo "error: cmux socket refused auth. Set Settings > Automation > socket control mode to allow local automation (then RESTART cmux - the mode applies at app start), or export CMUX_SOCKET_PASSWORD." >&2
      ;;
    *)
      echo "error: cmux socket is unreachable (is the cmux app running?): $out" >&2
      ;;
  esac
  return 1
}

# fm_backend_cmux_workspace_by_name: the UUID of the workspace whose
# custom_title is <name>, or empty. Read-only. Verified: `new-workspace
# --name` sets custom_title (title mirrors it until something else retitles
# the row - cmux's opt-in AI auto-naming rewrites `title` from conversation
# content, so custom_title is the ONLY stable match key; manual/custom titles
# always win over auto-naming per cmux's own settings docs).
fm_backend_cmux_workspace_by_name() {  # <name>
  local list
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r --arg name "$1" \
    '.workspaces[]? | select(.custom_title == $name) | .id' 2>/dev/null | head -1
}

# fm_backend_cmux_workspace_create: create a workspace named <name> in <cwd>
# without stealing focus and echo its UUID. Verified (0.64.17):
# `new-workspace` IGNORES --json and prints a text acknowledgment
# ("OK workspace:<n>") carrying only the index-based short ref, which is
# unstable and never stored; the stable UUID is resolved by an immediate
# custom_title lookup, made unambiguous by the caller's duplicate check.
fm_backend_cmux_workspace_create() {  # <name> <cwd>
  local name=$1 cwd=$2 out wsid
  out=$(fm_backend_cmux_cli new-workspace --name "$name" --cwd "$cwd" --focus false 2>/dev/null) || return 1
  case "$out" in
    *OK\ workspace*) : ;;
    *)
      echo "error: cmux new-workspace did not acknowledge creating '$name' (got: $out)" >&2
      return 1
      ;;
  esac
  wsid=$(fm_backend_cmux_workspace_by_name "$name")
  if [ -z "$wsid" ]; then
    echo "error: created cmux workspace '$name' but could not resolve its UUID from the workspace list" >&2
    return 1
  fi
  printf '%s' "$wsid"
}

# fm_backend_cmux_container_ensure: spawn-time gate (version + live socket)
# plus container resolution. Echoes the container token create_task consumes:
#   tab mode        the container WORKSPACE UUID - the workspace firstmate
#                   itself runs in (CMUX_WORKSPACE_ID, verified auto-set in
#                   every cmux-managed terminal) when inside cmux, else the
#                   find-or-create shared "firstmate" workspace (created in
#                   <cwd>). Mirrors bin/backends/tmux.sh's
#                   container_ensure (reuse own session, else a detached
#                   "firstmate" session).
#   workspace mode  the constant "cmux" - each task is its own top-level
#                   workspace, so there is no container to create beyond the
#                   app itself.
fm_backend_cmux_container_ensure() {  # <cwd-for-a-fresh-shared-workspace>
  local cwd=${1:-$PWD} mode wsid
  fm_backend_cmux_version_check || return 1
  fm_backend_cmux_socket_check || return 1
  mode=$(fm_backend_cmux_container_mode)
  if [ "$mode" = workspace ]; then
    printf 'cmux'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    printf '%s' "$CMUX_WORKSPACE_ID"
    return 0
  fi
  wsid=$(fm_backend_cmux_workspace_by_name "$FM_BACKEND_CMUX_SHARED_WORKSPACE")
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  fm_backend_cmux_workspace_create "$FM_BACKEND_CMUX_SHARED_WORKSPACE" "$cwd"
}

# fm_backend_cmux_surface_ids: every terminal-surface UUID in <workspace>,
# one per line. Read-only; used to diff out a just-created surface's UUID.
fm_backend_cmux_surface_ids() {  # <workspace-uuid>
  fm_backend_cmux_cli list-pane-surfaces --workspace "$1" --json --id-format uuids 2>/dev/null \
    | jq -r '.surfaces[]? | .id' 2>/dev/null
}

# fm_backend_cmux_surface_by_title: the UUID of the surface titled <title> in
# <workspace>, or empty. Verified: rename-tab sets a sticky title that
# running commands do not overwrite.
fm_backend_cmux_surface_by_title() {  # <workspace-uuid> <title>
  fm_backend_cmux_cli list-pane-surfaces --workspace "$1" --json --id-format uuids 2>/dev/null \
    | jq -r --arg t "$2" '.surfaces[]? | select(.title == $t) | .id' 2>/dev/null | head -1
}

# fm_backend_cmux_create_task: create the task's endpoint in <container>
# (from fm_backend_cmux_container_ensure), refusing an existing <label>.
# Echoes the ids fm-spawn.sh turns into the target string:
#   workspace mode ("cmux" container)   "<workspace-uuid>"
#   tab mode (container = ws uuid)      "<workspace-uuid> <surface-uuid>"
fm_backend_cmux_create_task() {  # <container> <label> <cwd>
  local container=$1 label=$2 cwd=$3 dup wsid sfid before after out prior_surface
  if [ "$container" = cmux ]; then
    # workspace-per-task: cmux does not enforce workspace-name uniqueness, so
    # the duplicate check is ours.
    dup=$(fm_backend_cmux_workspace_by_name "$label")
    if [ -n "$dup" ]; then
      echo "error: cmux workspace '$label' already exists ($dup)" >&2
      return 1
    fi
    wsid=$(fm_backend_cmux_workspace_create "$label" "$cwd") || return 1
    fm_backend_cmux_wait_ready "cmux:$wsid"
    printf '%s' "$wsid"
    return 0
  fi
  # tab-per-task in the container workspace. Surface titles are not unique in
  # cmux either, so the duplicate check is ours.
  wsid=$container
  dup=$(fm_backend_cmux_surface_by_title "$wsid" "$label")
  if [ -n "$dup" ]; then
    echo "error: cmux tab '$label' already exists in workspace $wsid ($dup)" >&2
    return 1
  fi
  # Verified (0.64.20): surfaces created unfocused can remain renderer-
  # unrealized on cmux 0.64.18+, so create focused and immediately restore the
  # previously focused surface. `new-surface` still prints only short refs
  # ("OK surface:<n> pane:<m> workspace:<k>"), so the new surface's stable
  # UUID is resolved by diffing the surface list around the create.
  prior_surface=$(fm_backend_cmux_focused_surface)
  before=$(fm_backend_cmux_surface_ids "$wsid")
  out=$(fm_backend_cmux_cli new-surface --type terminal --workspace "$wsid" --focus true 2>/dev/null) || return 1
  after=$(fm_backend_cmux_surface_ids "$wsid")
  fm_backend_cmux_restore_surface "$prior_surface" || return 1
  case "$out" in
    *OK\ surface*) : ;;
    *)
      echo "error: cmux new-surface did not acknowledge creating a tab for '$label' (got: $out)" >&2
      return 1
      ;;
  esac
  if [ -n "$before" ]; then
    sfid=$(printf '%s\n' "$after" | grep -vxF -f <(printf '%s\n' "$before") | head -1)
  else
    sfid=$(printf '%s\n' "$after" | head -1)
  fi
  if [ -z "$sfid" ]; then
    echo "error: created a cmux tab for '$label' but could not resolve its surface UUID" >&2
    return 1
  fi
  fm_backend_cmux_cli rename-tab --workspace "$wsid" --surface "$sfid" "$label" >/dev/null 2>&1 \
    || echo "warning: could not rename cmux tab $sfid to '$label'; recovery-by-name will not find it" >&2
  fm_backend_cmux_wait_ready "cmux:$wsid:$sfid"
  # A new tab starts in the container workspace's directory, not the task's
  # project, so move it there before fm-spawn.sh's `treehouse get`.
  fm_backend_cmux_send_text_line "cmux:$wsid:$sfid" "cd \"$cwd\"" || return 1
  printf '%s %s' "$wsid" "$sfid"
}

# fm_backend_cmux_parse_target: split "cmux:<workspace-uuid>[:<surface-uuid>]"
# on colons. Sets FM_BACKEND_CMUX_WS and FM_BACKEND_CMUX_SURFACE (empty in
# workspace mode) for the caller.
fm_backend_cmux_parse_target() {  # <target>
  local target=$1 rest
  FM_BACKEND_CMUX_WS=""
  FM_BACKEND_CMUX_SURFACE=""
  [ "${target%%:*}" = cmux ] || return 1
  rest=${target#cmux:}
  [ -n "$rest" ] && [ "$rest" != "$target" ] || return 1
  case "$rest" in
    *:*)
      FM_BACKEND_CMUX_WS=${rest%%:*}
      FM_BACKEND_CMUX_SURFACE=${rest#*:}
      [ -n "$FM_BACKEND_CMUX_WS" ] && [ -n "$FM_BACKEND_CMUX_SURFACE" ]
      ;;
    *)
      FM_BACKEND_CMUX_WS=$rest
      ;;
  esac
}

# fm_backend_cmux_target_flags: set $@-style routing flags for the parsed
# target. Usage in an op, after parse_target:
#   set -- $(fm_backend_cmux_target_flags)
# Emits "--workspace <ws>" plus "--surface <sf>" when the target names one.
# UUIDs contain no whitespace, so word-splitting the emission is safe.
fm_backend_cmux_target_flags() {
  printf -- '--workspace %s' "$FM_BACKEND_CMUX_WS"
  [ -n "$FM_BACKEND_CMUX_SURFACE" ] && printf -- ' --surface %s' "$FM_BACKEND_CMUX_SURFACE"
  return 0
}

# fm_backend_cmux_surface_tty: the tty name (e.g. "ttys011") of the target's
# terminal, from `cmux tree`, or empty when the terminal has not started yet
# (verified: an unfocused fresh workspace starts its terminal LAZILY - no
# tty, and zero-byte read-screen, until it first receives input or is viewed;
# docs/cmux-backend.md "Lazy terminal start"). In tab mode the tty is taken
# from the tree line carrying the surface's UUID (`--id-format both`,
# verified to print both handle forms per line); in workspace mode from the
# workspace's selected surface line.
fm_backend_cmux_surface_tty() {  # (uses parsed FM_BACKEND_CMUX_WS/_SURFACE)
  if [ -n "$FM_BACKEND_CMUX_SURFACE" ]; then
    fm_backend_cmux_cli tree --workspace "$FM_BACKEND_CMUX_WS" --id-format both 2>/dev/null \
      | grep -F "$FM_BACKEND_CMUX_SURFACE" | sed -n 's/.*tty=\([a-zA-Z0-9]*\).*/\1/p' | head -1
  else
    fm_backend_cmux_cli tree --workspace "$FM_BACKEND_CMUX_WS" 2>/dev/null \
      | sed -n 's/.*tty=\([a-zA-Z0-9]*\).*/\1/p' | head -1
  fi
}

# fm_backend_cmux_screen_cwd: the task terminal's live working directory read
# from its on-screen shell block-header prompt, or empty when none is present.
# This is the tty-free ground truth for cwd: cmux renders every command block
# with a header line "| [<tag>] <ABSOLUTE_CWD> @ <host> (<user>)" and updates it
# on each `cd`, so the LAST such header is the current directory. Needed because
# some cmux builds report `tty: null` for every surface (verified on cmux
# 0.64.17), which starves the tty+ps+lsof path below into a false timeout during
# fm-spawn.sh worktree discovery. read-screen returns unwrapped logical lines,
# so an absolute path is never split. Only absolute paths are accepted.
fm_backend_cmux_screen_cwd() {  # (uses parsed FM_BACKEND_CMUX_WS/_SURFACE)
  # shellcheck disable=SC2046
  fm_backend_cmux_cli read-screen $(fm_backend_cmux_target_flags) --lines 200 2>/dev/null \
    | sed -nE 's/^\| \[[^]]*\] (\/.+) @ [^ ]+ \([^)]*\) *$/\1/p' | tail -1
}

# fm_backend_cmux_current_path: the task terminal's live working directory,
# or empty on any error. Mirrors tmux's pane_current_path poll used for
# worktree-path discovery after `treehouse get`.
#
# Verified pitfall (docs/cmux-backend.md "Live-cwd tracking"): the workspace
# list's `current_directory` field does NOT track the treehouse-get subshell -
# it stays frozen at the top shell's directory - so reading it here would
# starve fm-spawn.sh's worktree-discovery poll into a false timeout (this
# failed live in the first E2E attempt). Ground truth instead: the surface's
# tty (from `cmux tree`) plus the OS - the foreground process group on that
# tty read via `ps`, its cwd via `lsof` - which is exactly the OS-level
# semantics tmux's #{pane_current_path} provides.
#
# tty-null fallback: some cmux builds report `tty: null` for every surface
# (verified on cmux 0.64.17, build 97), which makes the tty+ps+lsof path yield
# nothing. In that case fall back to the on-screen block-header cwd
# (fm_backend_cmux_screen_cwd), which is tty-free and correct in both tab and
# workspace mode. The workspace JSON `current_directory` field remains a last
# resort ONLY in workspace mode for a terminal that has not started yet; in tab
# mode it would be the WRONG answer (the container workspace's directory), so it
# is never used there.
fm_backend_cmux_current_path() {  # <target>
  fm_backend_cmux_parse_target "$1" || return 0
  local tty pid cwd screen list
  tty=$(fm_backend_cmux_surface_tty)
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
  screen=$(fm_backend_cmux_screen_cwd)
  if [ -n "$screen" ]; then
    printf '%s' "$screen"
    return 0
  fi
  [ -z "$FM_BACKEND_CMUX_SURFACE" ] || return 0
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r --arg id "$FM_BACKEND_CMUX_WS" \
    '.workspaces[]? | select(.id == $id) | .current_directory // empty' 2>/dev/null | head -1
}

# fm_backend_cmux_capture: bounded plain-text capture of the task terminal.
# Mirrors tmux's `capture-pane -p -S -N`. Verified: read-screen clamps small
# N correctly (no herdr-style small-N bug); the adapter still over-fetches
# (>= 200 lines, trimmed locally with `tail`) as cheap insurance against any
# future viewport-dependent regression.
fm_backend_cmux_capture() {  # <target> <lines>
  fm_backend_cmux_parse_target "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  [ "$fetch" -ge 200 ] || fetch=200
  # shellcheck disable=SC2046
  out=$(fm_backend_cmux_cli read-screen $(fm_backend_cmux_target_flags) --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_cmux_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c - fm-send.sh --key and stuck-crewmate-recovery) onto cmux's
# send-key names (verified: enter submits, escape is accepted, ctrl+c
# interrupts a running foreground process immediately).
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
  # shellcheck disable=SC2046
  fm_backend_cmux_cli send-key $(fm_backend_cmux_target_flags) "$key" >/dev/null 2>&1
}

# fm_backend_cmux_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately (verified: `cmux send` does not auto-submit;
# a marker command sat unexecuted in the composer until a separate Enter).
fm_backend_cmux_send_literal() {  # <target> <text>
  fm_backend_cmux_parse_target "$1" || return 1
  # shellcheck disable=SC2046
  fm_backend_cmux_cli send $(fm_backend_cmux_target_flags) "$2" >/dev/null 2>&1
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

# fm_backend_cmux_wait_ready: wake the new endpoint's lazily-started terminal
# and block until its shell shows a stable prompt, then settle. Verified
# (docs/cmux-backend.md "Lazy terminal start"): an unfocused fresh
# workspace/tab does not start its terminal process at all - read-screen
# stays empty and `cmux tree` shows no tty - until the surface first receives
# input or is viewed. So this sends one harmless Enter to trigger the start,
# then polls for stable non-empty screen content (the login banner + prompt).
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

# fm_backend_cmux_kill: remove the task's endpoint, best-effort (mirrors
# tmux-kill-window's `|| true` contract; verified: closing an already-closed
# workspace or surface exits non-zero with not_found). Tab mode closes only
# the task's surface; the container workspace (the captain's own, or the
# shared "firstmate" one) stays, exactly as tmux leaves the session.
fm_backend_cmux_kill() {  # <target>
  fm_backend_cmux_parse_target "$1" || return 0
  if [ -n "$FM_BACKEND_CMUX_SURFACE" ]; then
    fm_backend_cmux_cli close-surface --workspace "$FM_BACKEND_CMUX_WS" --surface "$FM_BACKEND_CMUX_SURFACE" >/dev/null 2>&1 || true
  else
    fm_backend_cmux_cli close-workspace --workspace "$FM_BACKEND_CMUX_WS" >/dev/null 2>&1 || true
  fi
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

# fm_backend_cmux_resolve_bare_selector: live-listing fallback for an ad hoc
# selector with no meta (mirrors tmux's list-windows grep). Checks fm-named
# workspaces first (workspace mode), then fm-titled tabs in every workspace
# (tab mode).
fm_backend_cmux_resolve_bare_selector() {  # <name>
  local name=$1 wsid sfid
  wsid=$(fm_backend_cmux_workspace_by_name "$name")
  if [ -n "$wsid" ]; then
    printf 'cmux:%s' "$wsid"
    return 0
  fi
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    sfid=$(fm_backend_cmux_surface_by_title "$wsid" "$name")
    if [ -n "$sfid" ]; then
      printf 'cmux:%s:%s' "$wsid" "$sfid"
      return 0
    fi
  done < <(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null | jq -r '.workspaces[]? | .id' 2>/dev/null)
  echo "error: no cmux workspace or tab named $name" >&2
  return 1
}

# fm_backend_cmux_list_live: recovery/orphan discovery. Lists every endpoint
# whose name looks like a firstmate task window (fm-<id>), by NAME - never by
# trusting a stored id blindly. Covers BOTH container shapes regardless of
# the currently configured mode, so recovery after a mode change still finds
# every live task. One "cmux:<ids>\t<name>" line per live task endpoint.
fm_backend_cmux_list_live() {
  local list wsid
  list=$(fm_backend_cmux_cli list-workspaces --json --id-format uuids 2>/dev/null) || return 0
  printf '%s' "$list" | jq -r \
    '.workspaces[]? | select((.custom_title // "") | startswith("fm-")) | "cmux:\(.id)\t\(.custom_title)"' 2>/dev/null
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    fm_backend_cmux_cli list-pane-surfaces --workspace "$wsid" --json --id-format uuids 2>/dev/null \
      | jq -r --arg ws "$wsid" \
        '.surfaces[]? | select((.title // "") | startswith("fm-")) | "cmux:\($ws):\(.id)\t\(.title)"' 2>/dev/null
  done < <(printf '%s' "$list" | jq -r '.workspaces[]? | select((.custom_title // "") | startswith("fm-") | not) | .id' 2>/dev/null)
}
