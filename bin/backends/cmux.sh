#!/usr/bin/env bash
# bin/backends/cmux.sh - the cmux session-provider adapter (EXPERIMENTAL).
#
# Design: data/cmux-backend-feasibility-c7/report.md (adapter design sketch,
# section 4) plus the live-app verification pass recorded in
# docs/cmux-backend.md (real cmux 0.64.17, macOS aarch64, 2026-07-03). cmux is
# a session provider ONLY, exactly like herdr/zellij: the worktree provider
# stays treehouse. Sourced only through bin/fm-backend.sh's fm_backend_source
# in normal operation; the unit tests source it directly.
#
# Container shape - CONFIGURABLE, default workspace-per-task: cmux has no
# "session" layer to multiplex the way tmux/herdr/zellij do - there is just
# "the app" (one running GUI instance).
#
#   workspace (default)  ONE cmux workspace PER TASK (mirrors tmux's
#                        one-window-per-task / zellij's one-tab-per-task),
#                        with exactly one surface inside it. Each task gets
#                        its own sidebar row with cmux's native per-workspace
#                        status (cwd, git branch, notifications).
#   tab                  ONE cmux SURFACE (tab) per task inside one container
#                        workspace: the workspace firstmate itself is running
#                        in (CMUX_WORKSPACE_ID) when inside cmux, else a
#                        find-or-create shared per-home workspace. Mirrors the
#                        tmux adapter's shape (crewmate windows join YOUR
#                        session when firstmate runs inside tmux, else a
#                        detached "firstmate" session): the captain watches
#                        every task as a tab in the workspace they already
#                        have open.
#
# Selection: FM_CMUX_CONTAINER env, then the first word of the local
# gitignored config/cmux-container, then the default "workspace"
# (fm_backend_cmux_container_mode). cmux has no session layer, so workspace
# titles (workspace mode), surface/tab titles (tab mode), and the shared
# container workspace's own title are all scoped by firstmate home and
# installation path inside this adapter.
#
# Target string shape: "<workspace_uuid>:<surface_uuid>" - both bare UUIDs
# with no embedded colon, so splitting on the FIRST colon is trivially
# correct (mirrors herdr's/zellij's target-string convention). The SAME shape
# serves both container modes: in workspace mode the workspace is task-owned
# with its single surface, in tab mode the workspace is the container and the
# surface is the task's tab. Which mode a live task is in is derived from the
# home-scoped TITLES (a task-owned workspace is titled fm-<home>-<id>; a
# task tab carries that title on the surface instead), never from a stored
# mode flag, so recovery and teardown keep working across a container-mode
# config change.
#
# GUI-first, macOS-only (docs/cmux-backend.md "Setup"): explicit selection or
# runtime auto-detection when firstmate itself is already running inside a
# cmux-spawned terminal (primary CMUX_WORKSPACE_ID marker, with documented
# macOS fallback signals for wrapper-stripped claude). Unlike Orca, cmux is a
# pure session provider (treehouse still owns the worktree) and Escape IS
# natively supported.
#
# Empirical findings from the live verification pass (docs/cmux-backend.md has
# the full evidence log) that shaped this adapter, several of which diverge
# from the original design sketch's speculation:
#
#   1. `send` (literal) does NOT auto-submit - confirmed, matches every other
#      backend's "literal-then-separate-Enter" contract.
#   2. Surface cwd is CREATION-TIME-FROZEN (zellij-shape), not live-tracking
#      (herdr-shape): `workspace list`'s `current_directory` field reflects a
#      `cd` run directly in the surface's own top-level shell, but stays
#      frozen at wherever that shell was when it launched a foreground
#      subshell (exactly what `treehouse get` does) - verified live: a nested
#      `bash -c 'cd /Users && exec bash'` left `current_directory` reporting
#      the PARENT shell's last cwd, never following into the subshell. Fixed
#      with zellij's own pwd-marker-probe workaround, reused verbatim in
#      spirit (fm_backend_cmux_current_path below).
#   3. `read-screen --lines N` has NO herdr-style small-N empty-result bug -
#      verified N=1..10 all return correctly-clamped, non-empty content. The
#      "fetch generous, trim locally" pattern is still used for consistency
#      and because the actual viewport height (not a bug - real behavior) can
#      still cap a single `read-screen` call below a caller's requested bound.
#      A DIFFERENT, unanticipated read-screen pitfall surfaced only once real
#      spawn-shaped call sequences were exercised (not caught by the original
#      Phase 1 pass, which happened to test against surfaces that already had
#      output): read-screen against a genuinely FRESH surface that has never
#      been written to yet fails outright with `internal_error: Failed to
#      read terminal text`, for every --lines value and no matter how long
#      you wait, until at least one `send` actually writes to it - after
#      which it becomes reliably readable forever. This ruled out read-screen
#      as fm_backend_cmux_target_ready's liveness probe (the design sketch's
#      original suggestion): the very first send on a freshly created task
#      would fail its own pre-flight readiness check. `list-panes` has no such
#      gap and is used instead (fm_backend_cmux_surface_exists), mirroring
#      zellij's own structural pane_exists check.
#   4. Closing a workspace's LAST surface is a THIRD shape, matching neither
#      herdr (auto-closes the workspace) nor zellij (leaves a ghost tab):
#      `close-surface` REFUSES outright with a typed error
#      (`invalid_state: Cannot close the last surface`), leaving both the
#      surface and the workspace untouched. `close-workspace` removes the
#      whole workspace (surface included) only when it is not the last
#      workspace in its window. `fm_backend_cmux_kill` handles the documented
#      last-in-window exception below, while still reclaiming every surface in
#      the task workspace.
#   5. Workspace ids do NOT survive an app relaunch - verified via source
#      (`Sources/Workspace.swift`'s only initializer unconditionally sets
#      `self.id = UUID()`, with no restored-id parameter, unlike surfaces'
#      `restoredSurfaceId ?? UUID()` path scoped to same-run object reuse).
#      No live app restart of the captain's own content was performed to
#      confirm this; see docs/cmux-backend.md for the reasoning. Recovery
#      therefore uses scoped-title matching from the caller-facing fm-<id>
#      label, never a stored uuid, mirroring herdr's/zellij's own recovery
#      posture.
#   6. NO title uniqueness enforcement for workspaces OR surfaces/tabs -
#      verified live (two workspaces, and two surfaces in one workspace, all
#      created successfully sharing one title). The duplicate check below is
#      ours, mirroring every other adapter, and uses home-scoped titles so a
#      shared cmux app cannot cross-match another firstmate home's task.
#
#   Unanticipated finding, load-bearing for this adapter: the control socket
#   defaults to `socketControlMode=cmuxOnly`, which REJECTS any CLI process
#   not spawned inside cmux itself ("Access denied - only processes started
#   inside cmux can connect"). Since firstmate always drives cmux from an
#   external shell, `automation.socketControlMode` must be one of the three
#   externally-viable modes (docs/cmux-backend.md "Setup" owns the full
#   matrix, verified from cmux source): `automation` (RECOMMENDED - same-user
#   external clients, no shared secret), `password` (works, needs
#   config/cmux-socket-password or CMUX_SOCKET_PASSWORD supplied on every
#   invocation), or `allowAll` (works, but opens the socket to every local
#   user - not recommended). `off` and `cmuxOnly` can never work externally.
#   A configured password is harmless under non-password modes: cmux's own
#   CLI sends `auth` preemptively and tolerates the server's "Unknown
#   command 'auth'" reply (cli/cmux.swift, authenticateSocketClientIfNeeded).
#
# Requires: cmux (CLI, bundled inside cmux.app - not guaranteed to be on PATH;
# see fm_backend_cmux_bin), jq (JSON parsing). Bootstrap detects these through
# fm_backend_required_tools only when cmux is the resolved backend; this adapter
# also gates them again before spawning.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/zellij.sh's identical fallback.
FM_BACKEND_CMUX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_CMUX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_CMUX_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_CMUX_ROOT/bin/fm-composer-lib.sh"

# Verified minimum: the version the live pass ran against (docs/cmux-backend.md).
FM_BACKEND_CMUX_MIN_MAJOR=0
FM_BACKEND_CMUX_MIN_MINOR=64

# fm_backend_cmux_bin: resolve the cmux CLI binary. cmux does not reliably
# land on PATH after a plain app install - it ships an OPTIONAL "install CLI"
# action (`Sources/App/CmuxCLIPathInstaller.swift`, symlinking
# /usr/local/bin/cmux -> the bundled binary) that a fresh install has not
# necessarily run. Prefer PATH (respects an operator's own setup, e.g. after
# running that install action), fall back to the well-known bundle path.
FM_BACKEND_CMUX_BUNDLE_BIN="${FM_BACKEND_CMUX_BUNDLE_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
fm_backend_cmux_bin() {
  if command -v cmux >/dev/null 2>&1; then
    printf 'cmux'
    return 0
  fi
  if [ -x "$FM_BACKEND_CMUX_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_CMUX_BUNDLE_BIN"
    return 0
  fi
  return 1
}

fm_backend_cmux_tool_check() {
  fm_backend_cmux_bin >/dev/null 2>&1 || { echo "error: backend=cmux selected but the 'cmux' CLI was not found on PATH or at $FM_BACKEND_CMUX_BUNDLE_BIN (https://cmux.com)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=cmux selected but 'jq' is not installed (required to parse cmux's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_cmux_password: the optional socket password from
# config/cmux-socket-password (first non-empty line), or empty. Read fresh
# from the effective config dir on every call, mirroring the rest of backend
# config resolution.
# Never overrides an operator's own ambient CMUX_SOCKET_PASSWORD when the file
# is absent - fm_backend_cmux_cli only exports this when it resolves non-empty.
fm_backend_cmux_password() {
  local config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" f line
  f="$config_dir/cmux-socket-password"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
  done < "$f"
}

# fm_backend_cmux_cli: run `cmux <args...>`, quieted (suppresses legacy-alias
# notices) and with the configured socket password exported only when one is
# actually configured, so an operator's own ambient CMUX_SOCKET_PASSWORD is
# never clobbered with an empty value.
fm_backend_cmux_cli() {  # <cmux-subcommand-and-args...>
  local bin pw
  bin=$(fm_backend_cmux_bin) || return 1
  pw=$(fm_backend_cmux_password)
  if [ -n "$pw" ]; then
    CMUX_QUIET=1 CMUX_SOCKET_PASSWORD="$pw" "$bin" "$@"
  else
    CMUX_QUIET=1 "$bin" "$@"
  fi
}

# fm_backend_cmux_version_check: refuse loudly on a missing/incompatible cmux
# client. `cmux version` needs no socket (verified: works even when the
# control socket is unreachable), so this is a pure client-version gate,
# separate from reachability/auth (fm_backend_cmux_ping_state below).
fm_backend_cmux_version_check() {
  fm_backend_cmux_tool_check || return 1
  local raw ver major rest minor
  raw=$(fm_backend_cmux_cli version 2>/dev/null) || { echo "error: 'cmux version' failed; is cmux installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a cmux version from '$raw'; refusing to use an unverified cmux build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_CMUX_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_CMUX_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_CMUX_MIN_MINOR" ]; }; then
    echo "error: cmux $ver is older than the verified minimum $FM_BACKEND_CMUX_MIN_MAJOR.$FM_BACKEND_CMUX_MIN_MINOR; update cmux before using backend=cmux" >&2
    return 1
  fi
  return 0
}

# fm_backend_cmux_ping_state: classify socket reachability/auth from `cmux
# ping`'s own text, since a missing/rejected connection is a normal, expected
# outcome here (never treated as a scripting bug) - ok|denied|unauth|down|error.
# The three auth-shaped server replies (verified from cmux source,
# Sources/TerminalController.swift): "Authentication required" (password mode,
# no password presented), "Password mode is enabled but no socket password"
# (password mode, app side has no password configured), and "Invalid password"
# (password mode, wrong password presented) all classify as unauth - each is a
# password-configuration problem on one side or the other, never fixable by
# relaunching the app.
fm_backend_cmux_ping_state() {
  local out
  out=$(fm_backend_cmux_cli ping 2>&1)
  if [ "$out" = "PONG" ]; then
    printf 'ok'
    return 0
  fi
  case "$out" in
    *'only processes started inside cmux can connect'*) printf 'denied' ;;
    *'Password mode is enabled but no socket password'*|*'Authentication required'*|*'Invalid password'*) printf 'unauth' ;;
    *'Socket not found'*) printf 'down' ;;
    *) printf 'error' ;;
  esac
}

# fm_backend_cmux_refuse_denied / fm_backend_cmux_refuse_unauth: the two
# fail-fast auth refusals, factored so the pre-launch and post-launch checks
# cannot drift. Each names every externally-viable socket mode (automation
# RECOMMENDED, password, allowAll - docs/cmux-backend.md "Setup" owns the
# matrix) plus the config/backend opt-out for a caller who only landed on
# cmux via auto-detection.
fm_backend_cmux_refuse_denied() {
  echo "error: backend=cmux socket rejected the connection (automation.socketControlMode is cmuxOnly, the default, which never admits an external CLI like firstmate). In cmux Settings > Automation set Socket Control Mode to 'Automation mode' (recommended - same-user external clients, no password), or 'Password mode' plus config/cmux-socket-password/CMUX_SOCKET_PASSWORD, or 'Full open access' (NOT recommended - admits every local user) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
}

fm_backend_cmux_refuse_unauth() {
  echo "error: backend=cmux socket requires a password (automation.socketControlMode=password) but none is configured for this caller, or the configured one was rejected. Set config/cmux-socket-password or export CMUX_SOCKET_PASSWORD to the password from cmux Settings > Automation, or switch Socket Control Mode to 'Automation mode' (recommended - no password needed) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux." >&2
}

# fm_backend_cmux_ensure_running: launch cmux (mirrors the CLI's own
# `connectClient`/`launchApp` `open -a cmux` fallback) only when the socket is
# simply not up yet (`down`); an auth failure (`denied`/`unauth`) is a
# configuration problem a relaunch cannot fix, so it fails fast with an
# actionable pointer to docs/cmux-backend.md instead of retry-looping. A
# launch that never becomes reachable also names the `off` mode (socket
# listener disabled entirely - no listener ever comes up, no matter how long
# the app has been running), since that is indistinguishable from a slow
# launch on the wire.
fm_backend_cmux_ensure_running() {
  local state i
  state=$(fm_backend_cmux_ping_state)
  case "$state" in
    ok) return 0 ;;
    denied)
      fm_backend_cmux_refuse_denied
      return 1
      ;;
    unauth)
      fm_backend_cmux_refuse_unauth
      return 1
      ;;
  esac
  open -a cmux >/dev/null 2>&1 || { echo "error: failed to launch cmux ('open -a cmux' failed)" >&2; return 1; }
  for i in $(seq 1 20); do
    state=$(fm_backend_cmux_ping_state)
    case "$state" in
      ok) return 0 ;;
      denied)
        fm_backend_cmux_refuse_denied
        return 1
        ;;
      unauth)
        fm_backend_cmux_refuse_unauth
        return 1
        ;;
    esac
    sleep 0.5
  done
  echo "error: cmux did not become reachable within 10s of launch. If the app is already running, its Socket Control Mode may be 'Off' (no control socket at all) - set it to 'Automation mode' (recommended) in Settings > Automation, see docs/cmux-backend.md 'Setup'." >&2
  return 1
}

# fm_backend_cmux_container_ensure: the full spawn-time container-ensure
# sequence (version gate, reachability/launch-if-needed) plus container-mode
# resolution. Echoes the container token fm_backend_cmux_create_task consumes:
#   workspace mode   the literal token "workspace" - each task is its own
#                    top-level workspace, so there is no container to stand
#                    up beyond the app itself.
#   tab mode         the container WORKSPACE UUID - the workspace firstmate
#                    itself runs in (CMUX_WORKSPACE_ID, injected into every
#                    cmux-managed terminal) when inside cmux, else the
#                    find-or-create shared per-home workspace (created in
#                    <cwd>, titled fm_backend_cmux_shared_container_title).
#                    Mirrors bin/backends/tmux.sh's container_ensure (reuse
#                    own session, else a detached "firstmate" session).
fm_backend_cmux_container_ensure() {  # [<cwd-for-a-fresh-shared-workspace>]
  local cwd=${1:-$PWD} mode title wsid out
  fm_backend_cmux_version_check || return 1
  fm_backend_cmux_ensure_running || return 1
  mode=$(fm_backend_cmux_container_mode)
  if [ "$mode" = workspace ]; then
    printf 'workspace'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    printf '%s' "$CMUX_WORKSPACE_ID"
    return 0
  fi
  title=$(fm_backend_cmux_shared_container_title)
  wsid=$(fm_backend_cmux_workspace_id_for_label "$title")
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  out=$(fm_backend_cmux_cli new-workspace --name "$title" --cwd "$cwd" --focus false --id-format uuids 2>&1) || {
    echo "error: cmux new-workspace failed for the shared container '$title': $out" >&2
    return 1
  }
  wsid=$(fm_backend_cmux_workspace_id_for_label "$title")
  [ -n "$wsid" ] || { echo "error: could not resolve a cmux workspace id for the shared container '$title' after creation" >&2; return 1; }
  printf '%s' "$wsid"
}

# fm_backend_cmux_home_label: readable home prefix plus a short hash of the
# resolved FM_ROOT path. cmux has one app-global workspace namespace, so the
# path hash distinguishes every firstmate installation, including multiple
# primary homes. Moving an installation changes this tag and old cmux titles
# stop matching; task meta already records absolute worktree paths, so repo
# relocation is already outside the supported recovery contract. Derivation
# itself lives in bin/fm-backend-hometag-lib.sh, shared with zellij's
# identical shared-namespace collision fix (docs/zellij-backend.md
# "Home-scoped tab titles").
fm_backend_cmux_home_label() {
  fm_backend_hometag
}

fm_backend_cmux_scoped_title() {  # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_cmux_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

# fm_backend_cmux_container_mode: resolve the task-container shape. Precedence:
# FM_CMUX_CONTAINER env, then the first non-empty word of the local gitignored
# config/cmux-container (read fresh from the effective config dir, mirroring
# fm_backend_cmux_password), then the default "workspace" - upstream's
# original, verified shape stays the default; "tab" is the opt-in restoration
# of the tab-per-task capability. Any unknown value falls back to "workspace"
# with a stderr warning rather than failing a spawn.
fm_backend_cmux_container_mode() {
  local config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" mode="" line
  if [ -n "${FM_CMUX_CONTAINER:-}" ]; then
    mode=$FM_CMUX_CONTAINER
  elif [ -f "$config_dir/cmux-container" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$line" ]; then
        mode=$line
        break
      fi
    done < "$config_dir/cmux-container"
  fi
  case "$mode" in
    tab|workspace) printf '%s' "$mode" ;;
    '') printf 'workspace' ;;
    *)
      echo "warning: unknown cmux container mode '$mode' (known: tab, workspace); using workspace" >&2
      printf 'workspace'
      ;;
  esac
}

# fm_backend_cmux_shared_container_title: the home-scoped title of the shared
# container workspace tab-mode tasks join when firstmate is NOT itself running
# inside cmux. "fm-<home-label>" with no trailing task segment: it never
# matches the task-title prefix "fm-<home-label>-", so list_live, recovery,
# and the kill mode-detection below can never mistake the container for a
# task workspace, and two firstmate homes sharing one cmux app get distinct
# containers for free (the home label embeds the FM_ROOT path hash).
fm_backend_cmux_shared_container_title() {
  printf 'fm-%s' "$(fm_backend_cmux_home_label)"
}

# fm_backend_cmux_workspace_id_for_label: the live workspace id whose title
# equals <label>, or empty. cmux enforces no title uniqueness (finding #6),
# so this adopts the FIRST match `jq` returns, mirroring herdr's/zellij's own
# duplicate-check posture.
fm_backend_cmux_workspace_id_for_label() {  # <label>
  local label=$1
  fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
    | jq -r --arg want "$label" '.workspaces[]? | select(.title == $want) | .id' 2>/dev/null | head -1
}

fm_backend_cmux_surface_id_for_workspace() {  # <workspace_id>
  local wsid=$1
  fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null \
    | jq -r '.panes[0] // {} | .selected_surface_id // (.surface_ids[0] // empty)' 2>/dev/null
}

# fm_backend_cmux_surface_ids: every surface UUID in <workspace>, one per
# line. Read-only; used by the tab-mode create to diff out a just-created
# surface's UUID (new-surface's acknowledgment carries only unstable short
# refs) and by the tab-mode kill's last-surface count.
fm_backend_cmux_surface_ids() {  # <workspace_id>
  fm_backend_cmux_cli list-pane-surfaces --workspace "$1" --json --id-format uuids 2>/dev/null \
    | jq -r '.surfaces[]? | .id' 2>/dev/null
}

# fm_backend_cmux_surface_by_title: the UUID of the surface titled <title> in
# <workspace>, or empty. Verified (0.64.20): rename-tab sets a sticky title
# that a running shell's own auto-retitling (cwd tracking) does not
# overwrite, so the scoped fm-<home>-<id> tab title is a stable match key.
# cmux enforces no surface-title uniqueness either, so like the workspace
# lookup this adopts the FIRST match.
fm_backend_cmux_surface_by_title() {  # <workspace_id> <title>
  fm_backend_cmux_cli list-pane-surfaces --workspace "$1" --json --id-format uuids 2>/dev/null \
    | jq -r --arg t "$2" '.surfaces[]? | select(.title == $t) | .id' 2>/dev/null | head -1
}

# fm_backend_cmux_surface_for_title_anywhere: search EVERY live workspace for
# a surface titled <title>; echoes "<workspace_id> <surface_id>" for the
# first match, or fails. The tab-mode analogue of
# fm_backend_cmux_workspace_id_for_label's title-based recovery: workspace
# ids do not survive an app relaunch (finding #5), so a tab-mode task whose
# stored container-workspace id went stale is re-found by its scoped surface
# title, wherever that container now lives.
fm_backend_cmux_surface_for_title_anywhere() {  # <title>
  local title=$1 wsid sfid
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    sfid=$(fm_backend_cmux_surface_by_title "$wsid" "$title")
    if [ -n "$sfid" ]; then
      printf '%s %s' "$wsid" "$sfid"
      return 0
    fi
  done < <(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r '.workspaces[]? | .id' 2>/dev/null)
  return 1
}

# fm_backend_cmux_focus_context: the FULL focused-UI context captured before a
# task tab is created, as a single space-separated line
# "<window> <workspace> <pane> <surface>" of cmux short refs. Empty when cmux
# reports no focused surface or cannot answer (headless/socket-only caller),
# which callers treat as a supported "skip restoration" no-op.
#
# Restoring only the surface is not enough (verified 0.64.20): a surface ref
# alone does NOT reactivate its workspace or window, so the window, workspace,
# and pane are captured too. Short refs are stable for a session's lifetime
# (only the positional index shifts), so they are captured directly from
# `identify`. A missing window or pane ref is recorded as "-" so the four
# positions stay fixed; the surface ref is required (its absence yields empty
# output, the safe skip-restoration signal).
fm_backend_cmux_focus_context() {
  local snapshot
  snapshot=$(fm_backend_cmux_cli identify --no-caller 2>/dev/null) || return 0
  [ -n "$snapshot" ] || return 0
  printf '%s' "$snapshot" | jq -r '
    (.focused // {}) as $f
    | ($f.surface_ref // "") as $s
    | if $s == "" then empty
      else [($f.window_ref // "-"), ($f.workspace_ref // "-"), ($f.pane_ref // "-"), $s] | join(" ")
      end' 2>/dev/null | head -1
}

# fm_backend_cmux_surface_index: the current positional index of surface
# <surface-ref-or-uuid> within workspace <ws>, or empty when the surface is not
# present. Read-only. The index is what an order-preserving focus needs:
# re-placing a surface at its OWN current index is a no-op move that only
# changes focus (verified 0.64.20), whereas a destination-less `move-surface`
# APPENDS it to the pane (verified reorder), which is why the latter is never
# used for restoration.
fm_backend_cmux_surface_index() {  # <workspace> <surface>
  fm_backend_cmux_cli list-pane-surfaces --workspace "$1" --json --id-format both 2>/dev/null \
    | jq -r --arg s "$2" '.surfaces[]? | select(.id == $s or .ref == $s) | .index' 2>/dev/null | head -1
}

# fm_backend_cmux_restore_focus: return the full UI focus to the context
# captured by fm_backend_cmux_focus_context before a task tab was created. An
# empty context is a supported no-op; a reported context that cannot be
# restored is an explicit failure (the caller closes the new tab and fails the
# spawn).
#
# Verified sequence (cmux 0.64.20):
#   - `move-surface --surface <s> --focus true` with no destination REORDERS
#     the tab (appends it to its pane), so it is never used here.
#   - Focusing a surface alone does NOT reactivate its workspace, so
#     `select-workspace` is required to bring the prior workspace (and its
#     window) back to the foreground before the tab is re-selected.
#   - `reorder-surface --surface <s> --index <its-own-current-index>
#     --focus true` re-selects the tab WITHOUT moving it (order-preserving).
# focus-window and focus-pane are best-effort refinements: a missing window or
# pane ref, or a single-window app, makes them harmless no-ops. Reactivating
# the workspace and the order-preserving tab focus are the two steps that must
# succeed for the restoration to count.
fm_backend_cmux_restore_focus() {  # <context: "window workspace pane surface">
  local ctx=${1:-} window workspace pane surface idx win_flag=""
  [ -n "$ctx" ] || return 0
  # shellcheck disable=SC2086
  set -- $ctx
  window=${1:-} workspace=${2:-} pane=${3:-} surface=${4:-}
  if [ -z "$workspace" ] || [ "$workspace" = "-" ] || [ -z "$surface" ] || [ "$surface" = "-" ]; then
    echo "error: created the cmux endpoint but the captured focus context is incomplete ($ctx)" >&2
    return 1
  fi
  # Reused window context so a workspace/pane/surface ref resolves in the right
  # window on a multi-window app (refs contain no whitespace, so the unquoted
  # split is safe).
  if [ -n "$window" ] && [ "$window" != "-" ]; then
    win_flag="--window $window"
    fm_backend_cmux_cli focus-window --window "$window" >/dev/null 2>&1 || true
  fi
  # shellcheck disable=SC2086
  if ! fm_backend_cmux_cli select-workspace --workspace "$workspace" $win_flag >/dev/null 2>&1; then
    echo "error: created the cmux endpoint but could not reactivate the previously focused workspace $workspace" >&2
    return 1
  fi
  if [ -n "$pane" ] && [ "$pane" != "-" ]; then
    # shellcheck disable=SC2086
    fm_backend_cmux_cli focus-pane --pane "$pane" --workspace "$workspace" $win_flag >/dev/null 2>&1 || true
  fi
  idx=$(fm_backend_cmux_surface_index "$workspace" "$surface")
  if [ -z "$idx" ]; then
    echo "error: created the cmux endpoint but the previously focused surface $surface is no longer present to restore" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  if ! fm_backend_cmux_cli reorder-surface --surface "$surface" --workspace "$workspace" $win_flag --index "$idx" --focus true >/dev/null 2>&1; then
    echo "error: created the cmux endpoint but could not restore focus to the previously focused surface $surface" >&2
    return 1
  fi
  return 0
}

# fm_backend_cmux_abandon_new_workspace: unwind a focused-at-birth workspace
# create that cannot be completed. Every creation path that passes
# --focus true owns the captain's view until it restores it, so ANY
# pre-return failure must both reclaim the half-built workspace (when its id
# is already known - an unknown id is never guessed, so nothing pre-existing
# can be closed) and put the captain back where they were. The restore is
# best-effort here: the caller has already reported the primary failure and
# returns non-zero regardless.
fm_backend_cmux_abandon_new_workspace() {  # <prior-context> [<workspace_id>]
  local ctx=${1:-} wsid=${2:-}
  [ -z "$wsid" ] || fm_backend_cmux_close_workspace_safely "$wsid"
  fm_backend_cmux_restore_focus "$ctx" || true
}

# fm_backend_cmux_create_task: create the task's endpoint in <container>
# (from fm_backend_cmux_container_ensure), refusing an existing live <label>
# (finding #6: cmux enforces no title uniqueness itself, for workspaces OR
# surfaces). Echoes "<workspace_id> <surface_id>" on success in BOTH modes,
# so callers see one shape.
#
# Workspace mode (<container> = "workspace"): one workspace per task.
# Resolves the fresh workspace's default surface via one list-panes call
# (finding: a freshly created workspace already has exactly one surface, so
# no separate new-surface call is needed). The workspace is created
# --focus true and the FULL previously focused context is then restored
# (fm_backend_cmux_restore_focus), for the same reason as tab mode and
# secondmate create: an unfocused-created surface that later hosts a
# full-screen TUI agent can stay black forever after a late resize.
#
# CORRECTION (0.64.20 build 100, observed on a real secondmate launch): the
# earlier claim here - that a fresh WORKSPACE needs no focus-restore dance
# because the 0.64.18+ regression only affects surfaces created into an
# existing workspace's tab bar - is WRONG for any surface that then hosts a
# full-screen TUI agent. A bare shell in an unfocused default surface does
# render (which is what the original re-check saw), but the surface never
# resolves its SIZE until first displayed, and copilot CLI cannot recover
# from that late resize, so its pane stays black forever. The secondmate
# create path was corrected to focus-at-birth plus restore for this reason
# (fm_backend_cmux_create_secondmate). Task WORKSPACE mode now uses the same
# focus-at-birth plus restore pattern, so all three task/secondmate creation
# paths follow one renderer-safe rule (docs/cmux-backend.md "Task and
# secondmate creation requires focus at birth on cmux 0.64.18+").
# Transactional like tab mode: once the workspace is created focused, every
# fallible pre-return step (id/surface resolution and the focus restoration)
# unwinds through fm_backend_cmux_abandon_new_workspace, so a failed create
# never leaves an orphan workspace or the captain parked on it.
#
# Tab mode (<container> = the container workspace UUID): one surface (tab)
# per task in the container workspace, titled with the scoped task title.
# Verified (0.64.20): surfaces created unfocused can remain renderer-
# unrealized on cmux 0.64.18+ and later paint black when selected, so the
# tab is created --focus true and the FULL previously focused context is then
# restored (fm_backend_cmux_restore_focus). `new-surface` prints only short
# refs ("OK surface:<n> pane:<m> workspace:<k>"), and it inserts the new tab
# ADJACENT to the focused tab rather than at the end, so the new surface's
# stable UUID is resolved by diffing the surface list around the create,
# never by position.
#
# Transactional: the new surface's exact UUID is resolved and the create is
# acknowledged BEFORE the fallible focus restoration runs, so any pre-return
# failure (restoration, the rename, or the post-create cwd setup) can close
# ONLY that new surface, leaving no orphan terminal and never touching a
# pre-existing tab. The rename to the scoped title is FATAL on failure
# (unlike the fork's warning): every downstream op verifies the task by that
# surface title (fm_backend_cmux_target_ready's tab arm), so an untitled tab
# would fail every send/capture/kill anyway - better to fail the spawn while
# cleanup is still one targeted close-surface.
fm_backend_cmux_create_task() {  # <container> <label> <cwd>
  local container=$1 label=$2 cwd=$3 title dup out wsid sfid before after pair prior_context
  title=$(fm_backend_cmux_scoped_title "$label")
  if [ "$container" = workspace ]; then
    dup=$(fm_backend_cmux_workspace_id_for_label "$title")
    if [ -n "$dup" ]; then
      echo "error: cmux workspace '$title' already exists" >&2
      return 1
    fi
    prior_context=$(fm_backend_cmux_focus_context)
    out=$(fm_backend_cmux_cli new-workspace --name "$title" --cwd "$cwd" --focus true --id-format uuids 2>&1) || {
      echo "error: cmux new-workspace failed for '$title': $out" >&2
      return 1
    }
    wsid=$(fm_backend_cmux_workspace_id_for_label "$title")
    if [ -z "$wsid" ]; then
      echo "error: could not resolve a cmux workspace id for '$title' after creation" >&2
      fm_backend_cmux_abandon_new_workspace "$prior_context"
      return 1
    fi
    sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
    if [ -z "$sfid" ]; then
      echo "error: could not resolve the default surface for cmux workspace '$title' ($wsid)" >&2
      fm_backend_cmux_abandon_new_workspace "$prior_context" "$wsid"
      return 1
    fi
    if ! fm_backend_cmux_restore_focus "$prior_context"; then
      fm_backend_cmux_close_workspace_safely "$wsid"
      return 1
    fi
    printf '%s %s' "$wsid" "$sfid"
    return 0
  fi
  # Tab mode. The duplicate check is app-global (any workspace), mirroring the
  # workspace-mode check's app-global workspace list: a task tab must be
  # unique per home wherever its container currently lives.
  wsid=$container
  if pair=$(fm_backend_cmux_surface_for_title_anywhere "$title"); then
    echo "error: cmux tab '$title' already exists (${pair% *})" >&2
    return 1
  fi
  prior_context=$(fm_backend_cmux_focus_context)
  before=$(fm_backend_cmux_surface_ids "$wsid")
  out=$(fm_backend_cmux_cli new-surface --type terminal --workspace "$wsid" --focus true 2>&1) || {
    echo "error: cmux new-surface failed for '$title': $out" >&2
    return 1
  }
  case "$out" in
    *OK\ surface*) : ;;
    *)
      echo "error: cmux new-surface did not acknowledge creating a tab for '$title' (got: $out)" >&2
      return 1
      ;;
  esac
  after=$(fm_backend_cmux_surface_ids "$wsid")
  if [ -n "$before" ]; then
    sfid=$(printf '%s\n' "$after" | grep -vxF -f <(printf '%s\n' "$before") | head -1)
  else
    sfid=$(printf '%s\n' "$after" | head -1)
  fi
  if [ -z "$sfid" ]; then
    # No resolvable new UUID: cannot safely target a cleanup close, so leave
    # the surface list untouched rather than risk closing a pre-existing tab.
    echo "error: created a cmux tab for '$title' but could not resolve its surface UUID" >&2
    return 1
  fi
  # From here the new surface UUID is known, so every fallible pre-return step
  # closes ONLY that surface on failure.
  if ! fm_backend_cmux_restore_focus "$prior_context"; then
    fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$sfid" >/dev/null 2>&1 || true
    return 1
  fi
  if ! fm_backend_cmux_cli rename-tab --workspace "$wsid" --surface "$sfid" "$title" >/dev/null 2>&1; then
    echo "error: could not rename cmux tab $sfid to '$title'; closing the new tab (the scoped title is what every later op verifies the task by)" >&2
    fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$sfid" >/dev/null 2>&1 || true
    return 1
  fi
  fm_backend_cmux_wait_ready "$wsid:$sfid"
  # A new tab starts in the container workspace's directory, not the task's
  # project, so move it there before fm-spawn.sh's `treehouse get`.
  if ! fm_backend_cmux_send_text_line "$wsid:$sfid" "cd \"$cwd\""; then
    echo "error: could not set the new cmux tab's working directory to '$cwd'; closing the new tab" >&2
    fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$sfid" >/dev/null 2>&1 || true
    return 1
  fi
  printf '%s %s' "$wsid" "$sfid"
}

# fm_backend_cmux_parse_target: split "<workspace_uuid>:<surface_uuid>" on the
# FIRST colon (neither UUID contains a colon, so this is unambiguous). Sets
# FM_BACKEND_CMUX_WORKSPACE and FM_BACKEND_CMUX_SURFACE for the caller.
fm_backend_cmux_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_CMUX_WORKSPACE=${target%%:*}
  FM_BACKEND_CMUX_SURFACE=${target#*:}
  [ -n "$FM_BACKEND_CMUX_WORKSPACE" ] && [ -n "$FM_BACKEND_CMUX_SURFACE" ] && [ "$FM_BACKEND_CMUX_SURFACE" != "$target" ]
}

# fm_backend_cmux_surface_exists: does <surface_id> currently appear as one of
# <workspace_id>'s surfaces, per list-panes? Structural existence check, never
# a content read.
#
# Verified real-cmux pitfall NOT anticipated by the design sketch: read-screen
# against a genuinely fresh surface that has never been written to yet fails
# with a typed `internal_error: Failed to read terminal text` - EVERY
# read-screen call fails this way (with or without --lines, any value,
# regardless of how long you wait) until at least one `send` has actually
# written to the surface, at which point it becomes reliably readable. This
# would make read-screen unusable as fm_backend_cmux_target_ready's liveness
# probe: the very first send_literal on a freshly created task's surface
# would fail its own readiness pre-check before ever getting to write
# anything. list-panes has no such gap (verified: correct, immediate output
# on a completely untouched fresh surface), so it is the liveness primitive
# instead - mirroring zellij's own pane_exists check
# (fm_backend_zellij_pane_exists) rather than the design sketch's original
# read-screen-based suggestion.
fm_backend_cmux_surface_exists() {  # <workspace_id> <surface_id>
  local wsid=$1 sfid=$2
  fm_backend_cmux_cli list-panes --workspace "$wsid" --json --id-format uuids 2>/dev/null \
    | jq -e --arg s "$sfid" '[.panes[]? | select(.surface_ids // [] | index($s))] | length > 0' >/dev/null 2>&1
}

# fm_backend_cmux_secondmate_meta_for_label: the task meta behind
# <expected-label> when (and only when) it records kind=secondmate in this
# home's state dir. Echoes the meta path; echoes nothing (rc 0) for an
# ordinary task, an unrecorded label, or a non-label. Lets the label-gated ops
# funnel (fm_backend_cmux_target_ready) recognize a secondmate target and
# delegate its identity to the id-primary resolver instead of the scoped-title
# gate. Uses the same state-dir resolution as the callers that produce
# expected labels (fm-send.sh/fm-peek.sh/fm-crew-state.sh).
fm_backend_cmux_secondmate_meta_for_label() {  # <expected-label>
  local label=$1 meta
  case "$label" in fm-?*) : ;; *) return 0 ;; esac
  meta="${FM_STATE_OVERRIDE:-$FM_HOME/state}/${label#fm-}.meta"
  [ -f "$meta" ] || return 0
  [ "$(fm_meta_get "$meta" kind 2>/dev/null)" = secondmate ] || return 0
  printf '%s' "$meta"
}

# fm_backend_cmux_target_ready: parse the target and verify it is live via
# fm_backend_cmux_surface_exists (never read-screen - see that function's
# header for the fresh-surface pitfall this avoids). When the caller knows
# the owning firstmate task label, refresh stale workspace/surface ids by
# label, covering BOTH container shapes:
#   workspace mode  the workspace's own title carries the scoped task title
#                   (upstream's original arm, unchanged);
#   tab mode        the SURFACE's title carries it instead, so when the
#                   workspace's title does not match, the task is looked up
#                   by surface title - first inside the (live) stored
#                   container workspace, then app-globally
#                   (fm_backend_cmux_surface_for_title_anywhere), covering a
#                   relaunch-stale container workspace id.
# A live target whose workspace AND surface titles both fail to match the
# expected label still fails - ops can never route to another task's endpoint.
#
# SECONDMATE exception (id-primary identity, docs/cmux-backend.md "Secondmate
# support"): a mate's workspace title is FREE-FORM (the captain may retitle it
# at will) and its tab title can be overwritten by the agent's own
# terminal-title updates, so the scoped-title rungs below would wrongly refuse
# the mate's own live endpoint after a rename (live evidence 2026-07-28).
# When the expected label's task meta records kind=secondmate, identity is
# delegated to fm_backend_cmux_secondmate_resolve instead - recorded ids
# first, then synced recorded title, scoped tab title, and home-cwd
# fingerprint, with loud ambiguity refusal - and ONLY its resolved endpoint is
# adopted, never the caller's unverified target, so the anti-misroute property
# is preserved. Ordinary task targets keep the scoped-title gate unchanged.
fm_backend_cmux_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} expected_title title wsid sfid pair meta
  fm_backend_cmux_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    meta=$(fm_backend_cmux_secondmate_meta_for_label "$expected_label")
    if [ -n "$meta" ]; then
      pair=$(fm_backend_cmux_secondmate_resolve "$meta") || return 1
      FM_BACKEND_CMUX_WORKSPACE=${pair%%:*}
      FM_BACKEND_CMUX_SURFACE=${pair#*:}
      return 0
    fi
    expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
    title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$FM_BACKEND_CMUX_WORKSPACE" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
    if [ "$title" = "$expected_title" ]; then
      fm_backend_cmux_surface_exists "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE" && return 0
      wsid=$FM_BACKEND_CMUX_WORKSPACE
    elif [ -n "$title" ]; then
      # Live workspace, non-matching title: the tab-mode container (or a
      # foreign workspace). The task is its scoped SURFACE title.
      sfid=$(fm_backend_cmux_surface_by_title "$FM_BACKEND_CMUX_WORKSPACE" "$expected_title")
      if [ -n "$sfid" ]; then
        FM_BACKEND_CMUX_SURFACE=$sfid
        return 0
      fi
      pair=$(fm_backend_cmux_surface_for_title_anywhere "$expected_title") || return 1
      FM_BACKEND_CMUX_WORKSPACE=${pair% *}
      FM_BACKEND_CMUX_SURFACE=${pair#* }
      return 0
    else
      wsid=$(fm_backend_cmux_workspace_id_for_label "$expected_title")
      if [ -z "$wsid" ]; then
        pair=$(fm_backend_cmux_surface_for_title_anywhere "$expected_title") || return 1
        FM_BACKEND_CMUX_WORKSPACE=${pair% *}
        FM_BACKEND_CMUX_SURFACE=${pair#* }
        return 0
      fi
    fi
    sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || return 1
    FM_BACKEND_CMUX_WORKSPACE=$wsid
    FM_BACKEND_CMUX_SURFACE=$sfid
    return 0
  fi
  fm_backend_cmux_surface_exists "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE"
}

# fm_backend_cmux_surface_tty: the tty name (e.g. "ttys011") of the task
# surface's terminal, from `cmux tree`, or empty when the terminal has not
# started yet (an unfocused fresh surface starts its terminal LAZILY - no
# tty, and failing read-screen, until it first receives input or is viewed;
# docs/cmux-backend.md "Lazy terminal start"). The tty is taken from the tree
# line carrying the surface's UUID (`--id-format both`, verified to print
# both handle forms per line). Verified on 0.64.20 (build 100): tree DOES
# report tty= for a started terminal - the 0.64.17 (build 97) all-surfaces
# `tty: null` bug that starved this tier on some builds is gone; the tiers
# below still cover any build where it is not.
fm_backend_cmux_surface_tty() {  # <workspace_id> <surface_id>
  fm_backend_cmux_cli tree --workspace "$1" --id-format both 2>/dev/null \
    | grep -F "$2" | sed -n 's/.*tty=\([a-zA-Z0-9]*\).*/\1/p' | head -1
}

# fm_backend_cmux_screen_cwd: the task terminal's live working directory read
# from its on-screen shell block-header prompt, or empty when none is present.
# tty-free passive ground truth: cmux renders every command block with a
# header line "| [<tag>] <ABSOLUTE_CWD> @ <host> (<user>)" and updates it on
# each `cd`, so the LAST such header is the current directory (shape
# re-verified on 0.64.20, including the trailing space). read-screen returns
# unwrapped logical lines, so an absolute path is never split. Only absolute
# paths are accepted.
fm_backend_cmux_screen_cwd() {  # <target> [expected-label]
  fm_backend_cmux_capture "$1" 200 "${2:-}" 2>/dev/null \
    | sed -nE 's/^\| \[[^]]*\] (\/.+) @ [^ ]+ \([^)]*\) *$/\1/p' | tail -1
}

# fm_backend_cmux_current_path: the task terminal's live working directory,
# or empty on any error. Mirrors tmux's pane_current_path poll used for
# worktree-path discovery after `treehouse get`.
#
# Verified pitfall (finding #2 above): cmux's `current_directory` field DOES
# reflect a `cd` run directly in the surface's own top-level shell, but stays
# FROZEN at whatever directory that shell was in when it launched `treehouse
# get` as a foreground command - it never follows that command's own internal
# `cd` into the acquired worktree. cmux's control socket exposes no
# live-process cwd field either (unlike herdr's `foreground_cwd`).
#
# PASSIVE tiers first, cheapest-and-truest ordering, so the common case never
# types into the captain-visible task terminal:
#   1. The surface's tty (from `cmux tree`) plus the OS: the foreground
#      process group on that tty via `ps`, its cwd via `lsof` - exactly the
#      OS-level semantics tmux's #{pane_current_path} provides.
#   2. The on-screen block-header cwd (fm_backend_cmux_screen_cwd), tty-free
#      and correct in both container modes.
#   3. The workspace list's `current_directory` field - ONLY when the
#      workspace is provably task-owned (its title matches the expected
#      label's scoped title, i.e. workspace mode). In tab mode it would be
#      the WRONG answer (the container workspace's directory), and with no
#      expected label ownership cannot be proven, so it is skipped.
#   4. The active pwd-marker probe (upstream's original strategy, zellij's
#      own workaround shape): print the surface's `$PWD` with a unique marker
#      (atomically submitted via send_text_line), briefly settle, then
#      capture and read only that marker line. Kept as the fallback for a
#      terminal whose tty is unreported and whose screen shows no block
#      header. Scoped to fm-spawn.sh's own worktree-discovery poll loop.
fm_backend_cmux_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} tty pid cwd screen expected_title ws_title wsdir out line marker_begin="__FM_CMUX_CWD_BEGIN__" marker_end="__FM_CMUX_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 0
  # target_ready refreshed the parsed ids; address the refreshed pair
  # directly so every tier reads the same, re-resolved endpoint.
  target="$FM_BACKEND_CMUX_WORKSPACE:$FM_BACKEND_CMUX_SURFACE"
  tty=$(fm_backend_cmux_surface_tty "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE")
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
  screen=$(fm_backend_cmux_screen_cwd "$target")
  if [ -n "$screen" ]; then
    printf '%s' "$screen"
    return 0
  fi
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
    ws_title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$FM_BACKEND_CMUX_WORKSPACE" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
    if [ "$ws_title" = "$expected_title" ]; then
      wsdir=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$FM_BACKEND_CMUX_WORKSPACE" '.workspaces[]? | select(.id == $id) | .current_directory // empty' 2>/dev/null | head -1)
      if [ -n "$wsdir" ]; then
        printf '%s' "$wsdir"
        return 0
      fi
    fi
  fi
  fm_backend_cmux_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" || return 0
  sleep 0.3
  out=$(fm_backend_cmux_capture "$target" 200) || return 0
  while IFS= read -r line; do
    if [ "$line" = "$marker_begin" ]; then
      in_block=1
      chunk=""
      continue
    fi
    if [ "$line" = "$marker_end" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

# fm_backend_cmux_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Verified live (finding #1): `send` does NOT
# auto-submit, matching every other backend's contract exactly.
fm_backend_cmux_send_literal() {  # <target> <text> [expected-label]
  fm_backend_cmux_target_ready "$1" "${3:-}" || return 1
  fm_backend_cmux_cli send --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" -- "$2" >/dev/null 2>&1
}

# fm_backend_cmux_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c) onto cmux's `send-key` names. Verified empirically: enter,
# escape, and ctrl-c all work directly (lowercase, hyphenated). cmux's own
# key vocabulary is genuinely richer (ctrl-d/ctrl-z/ctrl-\\, semantic aliases
# sigint/sigtstp/sigquit - `TerminalSurface+Input.swift`), but firstmate's
# shared vocabulary across backends only needs these three today.
fm_backend_cmux_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl-c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_cmux_send_key: one named special key. Escape IS natively
# supported here (unlike Orca, docs/orca-backend.md), so it is wired directly.
fm_backend_cmux_send_key() {  # <target> <key> [expected-label]
  fm_backend_cmux_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_cmux_normalize_key "$2")
  fm_backend_cmux_cli send-key --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" "$key" >/dev/null 2>&1
}

# fm_backend_cmux_send_text_line: send one line of TEXT then submit. cmux has
# no single-call atomic "run and submit" primitive (like herdr's `pane run`),
# so this composes send (literal) + send-key enter, exactly like zellij's
# equivalent - used for the fixed spawn-time commands (treehouse get, the
# GOTMPDIR export).
fm_backend_cmux_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_cmux_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_cmux_send_key "$1" Enter "${3:-}"
}

# fm_backend_cmux_wait_ready: wake a fresh endpoint's lazily-started terminal
# and block until its shell shows stable screen content, then settle. An
# unfocused fresh workspace/tab does not start its terminal process at all -
# read-screen fails and `cmux tree` shows no tty - until the surface first
# receives input or is viewed (docs/cmux-backend.md "Lazy terminal start").
# So this sends one harmless Enter to trigger the start, then polls for
# stable non-empty screen content (the login banner + prompt). Bounded; on
# timeout it returns anyway and the spawn's own worktree-discovery poll
# surfaces any real failure loudly.
#
# Re-verified on 0.64.20 (build 100): a send to a never-started surface is
# QUEUED into the pty and executes once the terminal starts - it is not lost
# - so this wait is not needed for send correctness. The tab-mode create
# still uses it before its `cd <cwd>` setup so that command lands at a
# visible prompt instead of being echoed raw above the login banner in the
# captain-visible tab, and so the immediately following read-screen-based
# steps (worktree discovery tiers) see a readable surface.
fm_backend_cmux_wait_ready() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} prev="" cur i
  local attempts=${FM_CMUX_READY_ATTEMPTS:-30} interval=${FM_CMUX_READY_INTERVAL:-0.5} settle=${FM_CMUX_READY_SETTLE:-1}
  fm_backend_cmux_send_key "$target" Enter "$expected_label" || true
  for i in $(seq 1 "$attempts"); do
    cur=$(fm_backend_cmux_capture "$target" 10 "$expected_label" 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
      sleep "$settle"
      return 0
    fi
    prev=$cur
    sleep "$interval"
  done
  return 0
}

# fm_backend_cmux_capture: bounded plain-text surface capture. No herdr-style
# small-N empty-result bug was found (finding #3), but "fetch generous, trim
# locally" is kept anyway: a single read-screen call is still bounded by the
# surface's actual current viewport height regardless of the requested
# --lines value, so a caller asking for more than the viewport can see would
# otherwise silently get less than it asked for with no way to tell why.
fm_backend_cmux_capture() {  # <target> <lines> [expected-label]
  fm_backend_cmux_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} fetch raw out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  raw=$(fm_backend_cmux_cli read-screen --workspace "$FM_BACKEND_CMUX_WORKSPACE" --surface "$FM_BACKEND_CMUX_SURFACE" --scrollback --lines "$fetch" --json 2>/dev/null) || return 1
  out=$(printf '%s' "$raw" | jq -r '.text // empty' 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_cmux_composer_state: classify the composer's own row as
# empty|pending|unknown. Adapted from the bordered-row branch of herdr's
# structural classifier (fm_backend_herdr_composer_state) per the build task's
# explicit direction - this is the highest-risk piece of a new backend's
# send-and-verify logic, and cmux's `read-screen` gives plain-text capture
# with no cursor-row primitive and no ANSI style channel like herdr's newer
# `pane read --format ansi` path. The cmux classifier intentionally remains
# border-row based: locate the
# composer row as the only captured line whose TRIMMED content both STARTS and
# ENDS with the same border glyph (│, ┃, or a plain ASCII |), scanning forward
# and keeping the LAST match so an earlier border-shaped line (scrollback, a
# popup) never outranks the real bottom-anchored composer row.
FM_BACKEND_CMUX_COMPOSER_LINES=${FM_BACKEND_CMUX_COMPOSER_LINES:-20}
FM_BACKEND_CMUX_IDLE_RE=${FM_BACKEND_CMUX_IDLE_RE:-'^Type a message\.\.\.$'}

fm_backend_cmux_composer_state() {  # <target> [expected-label] -> empty|pending|unknown
  local target=$1 expected_label=${2:-} cap line trimmed stripped="" found=0
  cap=$(fm_backend_cmux_capture "$target" "$FM_BACKEND_CMUX_COMPOSER_LINES" "$expected_label") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') : ;;
      *) continue ;;
    esac
    stripped=$trimmed
    found=1
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A row was found only by the bordered shape above, so content came from a
  # genuine composer box - delegate to the shared owner with bordered=1. A bare
  # dead-shell prompt has no bordered row and already returned 'unknown' above.
  fm_composer_classify_content 1 "$stripped" "$FM_BACKEND_CMUX_IDLE_RE"
}

# fm_backend_cmux_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the composer's own row reads empty.
# Mirrors fm_backend_herdr_send_text_submit's ORIGINAL (composer-row)
# verification strategy: a slash-command popup's first Enter can close the
# popup and fill an argument-hint placeholder into the composer rather than
# submitting, which a raw-diff check would misread as "submitted" -
# classifying the composer row specifically avoids that false positive, so
# the retry loop correctly sends a second Enter when needed. Herdr's adapter
# has since moved its own confirmation to a native agent-state read instead
# (docs/herdr-backend.md "Native agent-state submit confirmation"); cmux has
# no analogous native primitive, so this composer-row approach remains
# cmux's own confirmation strategy. Echoes empty|pending|unknown|send-failed, the
# SAME vocabulary every existing backend already speaks.
fm_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i=0 state
  fm_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_cmux_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_cmux_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$(fm_backend_cmux_composer_state "$target" "$expected_label")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_cmux_window_of_workspace: echo "<window_id> <workspace_count>" for
# the window that contains <workspace_id>, or nothing if it is not found live.
# `workspace list --json` with no `--window` is scoped to the CURRENT window
# only (verified live), so the containing window is found by walking every
# window from `list-windows --json` and asking each for its own scoped list.
# The count comes from the same scoped workspace list that confirms membership.
fm_backend_cmux_window_of_workspace() {  # <workspace_id> -> "<window_id> <count>"
  local wsid=$1 wins wid wss count
  wins=$(fm_backend_cmux_cli list-windows --json --id-format uuids 2>/dev/null) || return 0
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    wss=$(fm_backend_cmux_cli workspace list --json --id-format uuids --window "$wid" 2>/dev/null) || continue
    count=$(printf '%s' "$wss" | jq -er --arg id "$wsid" '
      (.workspaces // []) as $workspaces
      | select(any($workspaces[]?; .id == $id))
      | ($workspaces | length)
    ' 2>/dev/null) || continue
    printf '%s %s' "$wid" "$count"
    return 0
  done < <(printf '%s' "$wins" | jq -r '.[]? | .id' 2>/dev/null)
}

# fm_backend_cmux_close_workspace_safely: close a whole workspace, handling
# the selected-workspace teardown bug (docs/cmux-backend.md "Closing the last
# workspace in a window"): cmux keeps every window at >=1 workspace, so
# `close-workspace` on the ONLY workspace in its window silently no-ops - it
# still returns `OK`, but the workspace stays, which is exactly what left a
# selected task workspace open at teardown (the last workspace in a window is
# always the selected one). `close-window`/`window.close` cannot rescue it
# either: a window holding a live terminal session cannot be closed over the
# control socket (verified: returns success-shaped output, closes nothing).
# The reliable primitive is close-workspace on a NON-last workspace, so when the
# target is the last one in its window a throwaway sibling is created first,
# leaving that window a fresh default workspace (never an fm-<home>- title, so
# recovery/list_live ignore it) - cmux's own "closed the last tab" outcome.
fm_backend_cmux_close_workspace_safely() {  # <workspace_id>
  local wsid=$1 wininfo win count
  wininfo=$(fm_backend_cmux_window_of_workspace "$wsid")
  win=${wininfo%% *}
  count=${wininfo##* }
  if [ -n "$win" ] && [ "$count" = 1 ]; then
    fm_backend_cmux_cli new-workspace --window "$win" --focus false --id-format uuids >/dev/null 2>&1 || true
  fi
  fm_backend_cmux_cli close-workspace --workspace "$wsid" >/dev/null 2>&1 || true
}

# fm_backend_cmux_kill: remove the task's endpoint, best-effort (mirrors
# every other backend's `kill` `|| true` contract). Which shape to reclaim is
# derived from the resolved workspace's TITLE, never a stored mode flag, so
# teardown keeps working across a container-mode config change:
#
#   workspace mode  the workspace's own title IS the task's scoped title:
#                   the task owns the whole workspace, so the workspace and
#                   all its surfaces are reclaimed via
#                   fm_backend_cmux_close_workspace_safely. With an expected
#                   label the match is EXACT (the label's own scoped title) -
#                   a tab whose container merely carries this home's task
#                   prefix (another task's workspace) must not take the
#                   container down with it; with no label the match falls
#                   back to the home's task-title prefix.
#   tab mode        anything else: the workspace is a container that is not
#                   the task's to reclaim, so only the task's surface is
#                   closed. cmux refuses to close a workspace's LAST surface
#                   (`invalid_state`, finding #4), so when the task tab is
#                   the only surface left: if the container is this home's
#                   own shared container workspace
#                   (fm_backend_cmux_shared_container_title), the whole
#                   now-task-free container is reclaimed instead; otherwise
#                   (the captain's own workspace) a throwaway default surface
#                   is created first so the close lands, leaving the
#                   captain's workspace a fresh tab rather than a dead task
#                   tab.
fm_backend_cmux_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} wsid sfid ws_title expected_title home scount task_owned=0
  if [ -n "$expected_label" ]; then
    fm_backend_cmux_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_cmux_parse_target "$1" || return 0
  fi
  wsid=$FM_BACKEND_CMUX_WORKSPACE
  sfid=$FM_BACKEND_CMUX_SURFACE
  ws_title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$wsid" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
  home=$(fm_backend_cmux_home_label)
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
    [ "$ws_title" = "$expected_title" ] && task_owned=1
  else
    case "$ws_title" in
      "fm-$home-"*) task_owned=1 ;;
    esac
  fi
  if [ "$task_owned" -eq 1 ]; then
    fm_backend_cmux_close_workspace_safely "$wsid"
    return 0
  fi
  scount=$(fm_backend_cmux_surface_ids "$wsid" | grep -c . || true)
  if [ "$scount" = 1 ]; then
    if [ "$ws_title" = "$(fm_backend_cmux_shared_container_title)" ]; then
      fm_backend_cmux_close_workspace_safely "$wsid"
      return 0
    fi
    fm_backend_cmux_cli new-surface --type terminal --workspace "$wsid" --focus false >/dev/null 2>&1 || true
  fi
  fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$sfid" >/dev/null 2>&1 || true
}

# fm_backend_cmux_list_live: recovery/orphan discovery. Lists every endpoint
# whose title is scoped to this firstmate home, by TITLE - never by trusting a
# stored uuid, since workspace ids do NOT survive an app relaunch (finding #5).
# Covers BOTH container shapes regardless of the currently configured mode, so
# recovery after a mode change still finds every live task:
#   workspace mode  workspaces titled "fm-<home>-<id>" (their single default
#                   surface is resolved per row);
#   tab mode        surfaces titled "fm-<home>-<id>" inside EVERY workspace.
# The tab scan deliberately includes task-titled workspaces too: a
# workspace-mode task's own surface is never scoped-titled (nothing renames
# it), so the scans cannot double-report, and a tab that ended up hosted
# inside a task-titled workspace (however it got there) is still found.
# One "<workspace_id>:<surface_id>\tfm-<id>" line per live task endpoint,
# the same shape in both modes. Read-only: an unreachable cmux simply lists
# nothing.
fm_backend_cmux_list_live() {
  local wss wsid title sfid home prefix plain
  home=$(fm_backend_cmux_home_label)
  prefix="fm-$home-"
  wss=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || return 0
  while IFS=$'\t' read -r wsid title; do
    [ -n "$wsid" ] || continue
    plain=${title#"$prefix"}
    [ -n "$plain" ] || continue
    sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
    [ -n "$sfid" ] || continue
    printf '%s:%s\tfm-%s\n' "$wsid" "$sfid" "$plain"
  done < <(printf '%s' "$wss" | jq -r --arg prefix "$prefix" '.workspaces[]? | select(.title | startswith($prefix)) | "\(.id)\t\(.title)"' 2>/dev/null)
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    fm_backend_cmux_cli list-pane-surfaces --workspace "$wsid" --json --id-format uuids 2>/dev/null \
      | jq -r --arg ws "$wsid" --arg prefix "$prefix" \
        '.surfaces[]? | select((.title // "") | startswith($prefix)) | "\($ws):\(.id)\tfm-\(.title | ltrimstr($prefix))"' 2>/dev/null
  done < <(printf '%s' "$wss" | jq -r '.workspaces[]? | .id' 2>/dev/null)
}

# --- secondmate support (docs/cmux-backend.md "Secondmate support") ---------
#
# A cmux secondmate gets ONE dedicated workspace per mate: the mate agent's
# tab inside it, created at the mate's own home directory, in EVERY container
# mode (a tab-mode primary must never land a secondmate as a tab in the
# PRIMARY's own workspace). Identity is ID-PRIMARY with synced-title recovery
# (captain-resolved design, 2026-07-27): the recorded workspace/surface UUIDs
# are the operational handle while the app is alive; the workspace TITLE is
# free-form (the captain may retitle it at will), so the mate's meta records
# the last-seen title (cmux_workspace_title=) and every liveness touch
# re-syncs it by id. After an app relaunch (socket-reported workspace ids are
# re-minted; re-verified against the 0.64.20 source, docs/cmux-backend.md
# "Workspace ids do not survive a relaunch"), recovery matches the mate's OWN
# recorded title, then its scoped tab title, then a home-cwd fingerprint -
# never a broad namespace sweep, and any ambiguity refuses loudly with the
# candidates rather than guessing.

# fm_backend_cmux_workspaces_all_windows: every live workspace across EVERY
# window, one "<id>\t<title>\t<current_directory>" line each, deduplicated by
# id. `workspace list --json` without `--window` is scoped to the CURRENT
# window only (verified live; docs/cmux-backend.md "Closing the last workspace
# in a window"), which is fine for task-title lookups but NOT for secondmate
# recovery - a mate's workspace parked in a non-current window must still be
# findable. Falls back to the current-window list when list-windows yields
# nothing, degrading to the existing scope rather than failing.
fm_backend_cmux_workspaces_all_windows() {
  local wins wid out
  wins=$(fm_backend_cmux_cli list-windows --json --id-format uuids 2>/dev/null) || wins=""
  out=""
  if [ -n "$wins" ]; then
    out=$(while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      fm_backend_cmux_cli workspace list --json --id-format uuids --window "$wid" 2>/dev/null \
        | jq -r '.workspaces[]? | "\(.id)\t\(.title)\t\(.current_directory // "")"' 2>/dev/null
    done < <(printf '%s' "$wins" | jq -r '.[]? | .id' 2>/dev/null) | awk -F'\t' '!seen[$1]++')
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
    | jq -r '.workspaces[]? | "\(.id)\t\(.title)\t\(.current_directory // "")"' 2>/dev/null
}

# fm_backend_cmux_secondmate_initial_title: the mate workspace's DEFAULT title
# at creation, "fm-<mate-home-label>" (e.g. fm-2ndmate-<id>-<8hex>). Derived
# with FM_HOME AND FM_ROOT both pointed at the mate's home: a secondmate home
# is a worktree of this same repo, so its own processes resolve FM_ROOT to the
# home path - shadowing both here makes the primary-computed title
# byte-identical to what the mate's own crew spawns later derive, so the
# mate's workspace doubles as its home's tab-mode shared container. Purely a
# default: the captain may retitle the workspace freely afterward.
fm_backend_cmux_secondmate_initial_title() {  # <home-abs>
  local home=$1
  printf 'fm-%s' "$(FM_HOME="$home" FM_ROOT="$home" fm_backend_hometag)"
}

# fm_backend_cmux_create_secondmate: create a secondmate's dedicated
# workspace at its home directory, in every container mode. The workspace
# gets the initial per-home title above; the mate's single tab is renamed to
# the PRIMARY's scoped task title (fm-<primary-home-label>-<id>), which is
# what fm_backend_cmux_secondmate_resolve's scoped-tab rung recovers the mate
# by after an app relaunch - routine ops on a secondmate label go through
# that same id-primary resolver (fm_backend_cmux_target_ready's secondmate
# delegation), so the workspace title stays free for the captain. The rename
# is FATAL on failure (mirroring the tab-mode create): an untitled mate tab
# would weaken relaunch recovery down to the home-cwd fingerprint of last
# resort, and cleanup is still one targeted workspace close. The workspace is
# created --focus true and the FULL previously focused context is then
# restored (fm_backend_cmux_restore_focus), because an unfocused surface
# never resolves its size until first displayed and copilot CLI cannot
# recover from that late resize - see the CORRECTION note on
# fm_backend_cmux_create_task. Echoes "<workspace_id> <surface_id> <title>".
fm_backend_cmux_create_secondmate() {  # <home-abs> <label>
  local home=$1 label=$2 title scoped out wsid sfid pair dup prior_context
  fm_backend_cmux_version_check || return 1
  fm_backend_cmux_ensure_running || return 1
  title=$(fm_backend_cmux_secondmate_initial_title "$home")
  scoped=$(fm_backend_cmux_scoped_title "$label")
  dup=$(fm_backend_cmux_workspaces_all_windows | awk -F'\t' -v t="$title" '$2 == t { print $1; exit }')
  if [ -n "$dup" ]; then
    echo "error: cmux workspace '$title' already exists ($dup); tear the stale secondmate endpoint down first" >&2
    return 1
  fi
  if pair=$(fm_backend_cmux_surface_for_title_anywhere "$scoped"); then
    echo "error: cmux tab '$scoped' already exists (${pair% *}); tear the stale secondmate endpoint down first" >&2
    return 1
  fi
  prior_context=$(fm_backend_cmux_focus_context)
  out=$(fm_backend_cmux_cli new-workspace --name "$title" --cwd "$home" --focus true --id-format uuids 2>&1) || {
    echo "error: cmux new-workspace failed for secondmate workspace '$title': $out" >&2
    return 1
  }
  wsid=$(fm_backend_cmux_workspace_id_for_label "$title")
  if [ -z "$wsid" ]; then
    echo "error: could not resolve a cmux workspace id for secondmate workspace '$title' after creation" >&2
    fm_backend_cmux_abandon_new_workspace "$prior_context"
    return 1
  fi
  sfid=$(fm_backend_cmux_surface_id_for_workspace "$wsid")
  if [ -z "$sfid" ]; then
    echo "error: could not resolve the default surface for secondmate workspace '$title' ($wsid)" >&2
    fm_backend_cmux_abandon_new_workspace "$prior_context" "$wsid"
    return 1
  fi
  if ! fm_backend_cmux_restore_focus "$prior_context"; then
    fm_backend_cmux_close_workspace_safely "$wsid"
    return 1
  fi
  if ! fm_backend_cmux_cli rename-tab --workspace "$wsid" --surface "$sfid" "$scoped" >/dev/null 2>&1; then
    echo "error: could not rename the secondmate tab to '$scoped'; closing the new workspace (the scoped tab title is what routine ops and relaunch recovery verify the mate by)" >&2
    fm_backend_cmux_close_workspace_safely "$wsid"
    return 1
  fi
  printf '%s %s %s' "$wsid" "$sfid" "$title"
}

# fm_backend_cmux_meta_update: replace (or append) key=value lines in a task
# meta file, atomically via tmp+mv. Small helper for the resolver's title
# sync and post-relaunch id re-recording; every reader uses fm_meta_get
# (last-value-wins) so re-ordering replaced keys to the end is safe.
fm_backend_cmux_meta_update() {  # <meta-file> <key=value>...
  local meta=$1 tmp kv cur
  shift
  [ -f "$meta" ] || return 1
  tmp="$meta.tmp.$$"
  cur=$(cat "$meta")
  for kv in "$@"; do
    cur=$(printf '%s\n' "$cur" | grep -v "^${kv%%=*}=" || true)
  done
  {
    [ -z "$cur" ] || printf '%s\n' "$cur"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta"
}

# fm_backend_cmux_surface_home_cwd_matches: every surface UUID in <workspace>
# whose terminal's PASSIVE tty-derived cwd (tty from `cmux tree`, foreground
# pid via ps, cwd via lsof - fm_backend_cmux_current_path's tier 1) resolves
# to <home>, one per line. Passive tiers ONLY: the fingerprint scan runs
# against workspaces not yet proven to be the mate's, so it must never type
# into a candidate terminal (the active pwd-marker probe is forbidden here).
fm_backend_cmux_surface_home_cwd_matches() {  # <workspace_id> <home-abs>
  local wsid=$1 home=$2 home_real sfid tty pid cwd cwd_real
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || home_real=$home
  while IFS= read -r sfid; do
    [ -n "$sfid" ] || continue
    tty=$(fm_backend_cmux_surface_tty "$wsid" "$sfid")
    [ -n "$tty" ] || continue
    pid=$(ps -t "$tty" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\+/ { p=$1 } END { if (p) print p }')
    [ -n "$pid" ] || continue
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ -n "$cwd" ] || continue
    cwd_real=$(cd "$cwd" 2>/dev/null && pwd -P) || cwd_real=$cwd
    [ "$cwd_real" = "$home_real" ] && printf '%s\n' "$sfid"
  done < <(fm_backend_cmux_surface_ids "$wsid")
}

# fm_backend_cmux_secondmate_resolve: resolve a secondmate meta's endpoint to
# a live "<workspace_id>:<surface_id>", syncing the recorded workspace title
# and re-recording stale ids in the meta as a side effect. The recovery
# ladder, strictly record-driven (this home's OWN recorded identity only):
#   A. Recorded workspace id still live -> use it; re-sync the recorded title
#      when the captain retitled it; re-resolve the mate's tab by id, then by
#      its scoped title, then by home-cwd fingerprint WITHIN that workspace.
#   B. Id gone (relaunch re-mints socket-reported workspace ids) -> match the
#      last-synced recorded title across every window; a unique match is
#      adopted, multiple matches tie-break on the home-cwd fingerprint.
#   C. Scoped tab title (fm-<primary-home-label>-<id>) found anywhere - tab
#      custom titles survive a relaunch via session restore (verified from
#      the 0.64.20 source) - adopts its workspace.
#   D. Fingerprint of last resort for a stale/duplicated title: a workspace
#      whose creation cwd is the mate's home AND holding a surface whose
#      passive tty-derived cwd is that home. Both conditions together keep a
#      captain's stray tab that merely cd'd into the home from matching.
# Exactly one candidate is required at every rung: multiple candidates refuse
# loudly (rc 3) with the candidates on stderr - never guess, never claim
# another home's workspace. No candidate at all is rc 2 (endpoint gone).
# An unreachable/unauthenticated socket is rc 1 (nothing can be inspected).
fm_backend_cmux_secondmate_resolve() {  # <meta-file>
  local meta=$1 id scoped wsid sfid rec_title home window rows row cur_title cands title_cands n line updates
  [ -f "$meta" ] || return 1
  id=$(basename "$meta" .meta)
  scoped=$(fm_backend_cmux_scoped_title "fm-$id")
  wsid=$(fm_meta_get "$meta" cmux_workspace_id)
  sfid=$(fm_meta_get "$meta" cmux_surface_id)
  if [ -z "$wsid" ] || [ -z "$sfid" ]; then
    window=$(fm_meta_get "$meta" window)
    if fm_backend_cmux_parse_target "$window"; then
      wsid=$FM_BACKEND_CMUX_WORKSPACE
      sfid=$FM_BACKEND_CMUX_SURFACE
    fi
  fi
  rec_title=$(fm_meta_get "$meta" cmux_workspace_title)
  home=$(fm_meta_get "$meta" home)
  if [ "$(fm_backend_cmux_ping_state)" != ok ]; then
    echo "error: cmux socket is unreachable; secondmate $id endpoint cannot be inspected" >&2
    return 1
  fi
  rows=$(fm_backend_cmux_workspaces_all_windows)
  row=""
  if [ -n "$wsid" ]; then
    row=$(printf '%s\n' "$rows" | awk -F'\t' -v w="$wsid" '$1 == w { print; exit }')
  fi
  if [ -z "$row" ] && [ -n "$rec_title" ]; then
    cands=$(printf '%s\n' "$rows" | awk -F'\t' -v t="$rec_title" '$2 == t')
    n=$(printf '%s' "$cands" | grep -c . || true)
    if [ "$n" -gt 1 ]; then
      # A duplicated recorded title stays AMBIGUOUS unless the home-cwd
      # fingerprint singles out exactly one candidate: eliminating every
      # candidate is not "gone" - one of them may still be the live mate.
      title_cands=$cands
      cands=$(printf '%s\n' "$cands" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -n "$(fm_backend_cmux_surface_home_cwd_matches "${line%%$'\t'*}" "$home" | head -1)" ]; then
          printf '%s\n' "$line"
        fi
      done)
      n=$(printf '%s' "$cands" | grep -c . || true)
      if [ "$n" -ne 1 ]; then
        echo "error: secondmate $id title '$rec_title' matches multiple cmux workspaces and the home-cwd fingerprint could not single one out; refusing to guess. Candidates:" >&2
        printf '%s\n' "$title_cands" | awk -F'\t' '{ print "  " $1 "  title=" $2 "  cwd=" $3 }' >&2
        return 3
      fi
    fi
    [ "$n" -eq 1 ] && row=$(printf '%s\n' "$cands" | head -1)
  fi
  if [ -z "$row" ]; then
    cands=$(printf '%s\n' "$rows" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ -n "$(fm_backend_cmux_surface_by_title "${line%%$'\t'*}" "$scoped")" ]; then
        printf '%s\n' "$line"
      fi
    done)
    n=$(printf '%s' "$cands" | grep -c . || true)
    if [ "$n" -gt 1 ]; then
      echo "error: secondmate $id scoped tab title '$scoped' matches surfaces in $n cmux workspaces; refusing to guess. Candidates:" >&2
      printf '%s\n' "$cands" | awk -F'\t' '{ print "  " $1 "  title=" $2 "  cwd=" $3 }' >&2
      return 3
    fi
    [ "$n" -eq 1 ] && row=$(printf '%s\n' "$cands" | head -1)
  fi
  if [ -z "$row" ] && [ -n "$home" ]; then
    cands=$(printf '%s\n' "$rows" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ "$(printf '%s\n' "$line" | cut -f3)" = "$home" ] || continue
      if [ -n "$(fm_backend_cmux_surface_home_cwd_matches "${line%%$'\t'*}" "$home" | head -1)" ]; then
        printf '%s\n' "$line"
      fi
    done)
    n=$(printf '%s' "$cands" | grep -c . || true)
    if [ "$n" -gt 1 ]; then
      echo "error: secondmate $id home-cwd fingerprint ($home) matches $n cmux workspaces; refusing to guess. Candidates:" >&2
      printf '%s\n' "$cands" | awk -F'\t' '{ print "  " $1 "  title=" $2 "  cwd=" $3 }' >&2
      return 3
    fi
    [ "$n" -eq 1 ] && row=$(printf '%s\n' "$cands" | head -1)
  fi
  [ -n "$row" ] || return 2
  wsid=${row%%$'\t'*}
  cur_title=$(printf '%s\n' "$row" | cut -f2)
  if ! fm_backend_cmux_surface_exists "$wsid" "$sfid"; then
    sfid=$(fm_backend_cmux_surface_by_title "$wsid" "$scoped")
    [ -n "$sfid" ] || sfid=$(fm_backend_cmux_surface_home_cwd_matches "$wsid" "$home" | head -1)
    if [ -z "$sfid" ]; then
      echo "error: secondmate $id workspace $wsid was identified but the mate's own tab could not be (no recorded id, scoped title '$scoped', or home-cwd match); refusing to guess" >&2
      return 3
    fi
  fi
  updates=""
  [ "$(fm_meta_get "$meta" cmux_workspace_id)" = "$wsid" ] || updates=1
  [ "$(fm_meta_get "$meta" cmux_surface_id)" = "$sfid" ] || updates=1
  [ "$rec_title" = "$cur_title" ] || updates=1
  if [ -n "$updates" ]; then
    fm_backend_cmux_meta_update "$meta" \
      "window=$wsid:$sfid" \
      "cmux_workspace_id=$wsid" \
      "cmux_surface_id=$sfid" \
      "cmux_workspace_title=$cur_title" || {
      echo "error: could not update secondmate $id meta after endpoint resolution" >&2
      return 1
    }
  fi
  printf '%s:%s' "$wsid" "$sfid"
}

# fm_backend_cmux_secondmate_kill: close a secondmate's WHOLE dedicated
# workspace, identified through the resolver above (id-primary, synced title,
# fingerprint), never by title alone and never another home's workspace. A
# gone endpoint (rc 2) is a successful no-op; an ambiguous or uninspectable
# endpoint refuses rather than closing anything.
fm_backend_cmux_secondmate_kill() {  # <meta-file>
  local meta=$1 target rc
  target=$(fm_backend_cmux_secondmate_resolve "$meta")
  rc=$?
  case "$rc" in
    0) fm_backend_cmux_close_workspace_safely "${target%%:*}" ;;
    2) return 0 ;;
    *)
      echo "error: refusing cmux secondmate cleanup for $(basename "$meta" .meta): endpoint could not be safely identified" >&2
      return 1
      ;;
  esac
}

# fm_backend_cmux_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS under <target>, for bin/fm-backend.sh's fm_backend_agent_alive
# (the session-start secondmate-liveness sweep's probe; docs/cmux-backend.md
# "Secondmate support" records the empirical basis). Classification:
#   - socket `down` (app not running) -> dead: cmux hosts every task pty, so
#     no cmux-backed agent process can exist without the app.
#   - denied/unauth/error sockets -> unknown: nothing can be inspected, and
#     an uninspectable endpoint must never read as confidently dead.
#   - live surface with a started terminal: classify EVERY process on the
#     surface's tty (never just the last foreground entry - a live agent's
#     tool child, e.g. a bash it shelled out to, can transiently be the
#     foreground process and must not read as a dead shell):
#       any verified-harness process name -> alive;
#       nothing but bare shells and the resident /usr/bin/login wrapper cmux
#       parents every tab shell through -> dead (the agent exited);
#       anything else (pi's bare "node", an editor, an unreadable ps)
#                                       -> unknown, same posture as tmux's
#     classifier (docs/tmux-backend.md "Agent liveness probe").
#   - a fresh surface whose terminal never started (no tty), or a target that
#     cannot be re-resolved -> unknown: stale ids are a RECOVERY problem
#     (fm_backend_cmux_secondmate_resolve), not proof of death.
fm_backend_cmux_agent_alive() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} state tty comms line base only_shells=1 any=0
  state=$(fm_backend_cmux_ping_state)
  case "$state" in
    ok) : ;;
    down) printf 'dead'; return 0 ;;
    *) printf 'unknown'; return 0 ;;
  esac
  fm_backend_cmux_target_ready "$target" "$expected_label" || { printf 'unknown'; return 0; }
  tty=$(fm_backend_cmux_surface_tty "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE")
  [ -n "$tty" ] || { printf 'unknown'; return 0; }
  comms=$(ps -t "$tty" -o comm= 2>/dev/null)
  while IFS= read -r line; do
    line=${line#-}
    base=${line##*/}
    [ -n "$base" ] || continue
    any=1
    case "$base" in
      *claude*|*codex*|*opencode*|*grok*|*copilot*) printf 'alive'; return 0 ;;
      zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish|login) : ;;
      *) only_shells=0 ;;
    esac
  done <<EOF
$comms
EOF
  [ "$any" -eq 1 ] || { printf 'unknown'; return 0; }
  if [ "$only_shells" -eq 1 ]; then printf 'dead'; else printf 'unknown'; fi
}

# fm_backend_cmux_busy_state: semantic busy state. cmux tracks per-workspace
# agent activity through its agent hooks (the sidebar's working/waiting
# indicators), but the verified workspace list exposes NO stable
# machine-readable agent-state field - re-checked on 0.64.20 (build 100):
# `workspace list --json` still has no agent_status key (the busy cue rides
# the auto-naming title's spinner glyph, which is opt-in and
# presentation-bound - never parsed). So this probes a forward-compatible
# `agent_status` field and, on every verified version, reports unknown - the
# caller's cue to fall back to pane-regex detection, exactly like tmux. The
# probe is consulted only when the workspace is provably task-owned (its
# title carries this home's task prefix): in tab mode the workspace is a
# CONTAINER whose future agent_status would describe the container, not the
# task's tab, so tab-mode targets always report unknown.
fm_backend_cmux_busy_state() {  # <target>
  fm_backend_cmux_parse_target "$1" || { printf 'unknown'; return 0; }
  local list row title status home
  list=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || { printf 'unknown'; return 0; }
  row=$(printf '%s' "$list" | jq -r --arg id "$FM_BACKEND_CMUX_WORKSPACE" \
    '.workspaces[]? | select(.id == $id) | "\(.title)\t\(.agent_status // "")"' 2>/dev/null | head -1)
  title=${row%%$'\t'*}
  status=${row#*$'\t'}
  home=$(fm_backend_cmux_home_label)
  case "$title" in
    "fm-$home-"*) : ;;
    *) printf 'unknown'; return 0 ;;
  esac
  case "$status" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    # waiting/blocked: stuck on the human, not grinding - surface, don't suppress.
    waiting|blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}
