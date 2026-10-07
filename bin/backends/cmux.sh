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
#                        with exactly one surface inside it.
#   tab                  ONE cmux SURFACE (tab) per task inside one container
#                        workspace: the live workspace firstmate itself runs
#                        in when inside cmux, else a find-or-create shared
#                        per-home workspace (fm_backend_cmux_container_ensure).
#
# Selection: FM_CMUX_CONTAINER env, then the first word of the local
# gitignored config/cmux-container, then the default "workspace"
# (fm_backend_cmux_container_mode). cmux has no session layer, so workspace
# titles (workspace mode), tab titles (tab mode), and the shared container's
# own title are all scoped by firstmate home and installation path inside
# this adapter.
#
# Target string shape: "<workspace_uuid>:<surface_uuid>" - both bare UUIDs
# with no embedded colon, so splitting on the FIRST colon is trivially
# correct (mirrors herdr's/zellij's target-string convention). The SAME shape
# serves both container modes. Which mode a live task is in is derived from
# the home-scoped TITLES (a task-owned workspace is titled fm-<home>-<id>; a
# task tab carries that title on the surface instead), never from a stored
# mode flag, so recovery and teardown keep working across a mode change.
#
# Creation identity: a new workspace or tab is resolved only from the ref cmux
# prints at creation (`OK workspace:<n>` / `OK surface:<n> ...`), never from a
# title lookup. On 0.64.25 `workspace list` is not read-after-write consistent
# and can omit a just-created workspace for ~100ms, while
# `list-panes --workspace <ref>` answers at once and is not scoped to the
# current window. A failed create closes only what that call created, by
# ref or uuid, never by a title match (cmux titles are not unique).
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
#      the task workspace, and the tab-mode last-surface case.
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

# Shared, backend-neutral harness-process identity, reused by the liveness
# classifier (fm_backend_cmux_agent_state) so cmux cannot drift from tmux/herdr
# about what a given process name means.
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_CMUX_ROOT/bin/fm-agent-process-lib.sh"

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

# fm_backend_cmux_container_mode: resolve the task-container shape. Precedence:
# FM_CMUX_CONTAINER env, then the first non-empty word of the local gitignored
# config/cmux-container (read fresh from the effective config dir, mirroring
# fm_backend_cmux_password), then the default "workspace". An unknown value
# warns on stderr and falls back to "workspace" rather than failing a spawn.
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

# fm_backend_cmux_container_ensure: the full spawn-time container-ensure
# sequence (version gate, reachability/launch-if-needed), then the container
# token fm_backend_cmux_create_task consumes:
#   workspace mode  the literal token "workspace" - each task is its own
#                   top-level workspace, so there is nothing to stand up.
#   tab mode        a container WORKSPACE UUID, first that resolves live:
#                   1. ambient CMUX_WORKSPACE_ID, the workspace firstmate runs
#                      in, only when cmux still lists it (workspace ids are
#                      re-minted on an app relaunch, so an inherited marker
#                      can be stale);
#                   2. the workspace that now holds ambient CMUX_SURFACE_ID
#                      (surface ids survive in more cases than workspace ids);
#                   3. the find-or-create shared per-home workspace titled
#                      fm_backend_cmux_shared_container_title in any window,
#                      created in <cwd> and resolved from its printed ref.
fm_backend_cmux_container_ensure() {  # [<cwd-for-a-fresh-shared-workspace>]
  local cwd=${1:-$PWD} mode title wsid pair
  fm_backend_cmux_version_check || return 1
  fm_backend_cmux_ensure_running || return 1
  mode=$(fm_backend_cmux_container_mode)
  if [ "$mode" = workspace ]; then
    printf 'workspace'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    pair=$(fm_backend_cmux_pane_ids_for_workspace "$CMUX_WORKSPACE_ID")
    if [ -n "$pair" ]; then
      printf '%s' "${pair%% *}"
      return 0
    fi
  fi
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then
    wsid=$(fm_backend_cmux_workspace_of_surface "$CMUX_SURFACE_ID")
    if [ -n "$wsid" ]; then
      printf '%s' "$wsid"
      return 0
    fi
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}${CMUX_SURFACE_ID:-}" ]; then
    echo "note: this firstmate's own cmux workspace is no longer live (stale CMUX_WORKSPACE_ID/CMUX_SURFACE_ID); placing cmux task tabs in the shared container workspace instead" >&2
  fi
  title=$(fm_backend_cmux_shared_container_title)
  # Looked up through the all-window tree, which (unlike `workspace list`)
  # already shows a container a concurrent spawn has just created.
  wsid=$(fm_backend_cmux_tree_surfaces | awk -F'\t' -v t="$title" '$2 == t { print $1; exit }')
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  pair=$(fm_backend_cmux_create_workspace "$title" "$cwd") || return 1
  printf '%s' "${pair%% *}"
}

# fm_backend_cmux_shared_container_title: the home-scoped title of the shared
# container workspace tab-mode tasks join when firstmate is NOT itself running
# inside a live cmux workspace. "fm-<home-label>" with no trailing task
# segment, so it never matches the task-title prefix "fm-<home-label>-" that
# list_live, recovery, and kill's ownership test use.
fm_backend_cmux_shared_container_title() {
  printf 'fm-%s' "$(fm_backend_cmux_home_label)"
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

# fm_backend_cmux_pane_ids_for_workspace: "<workspace_uuid> <surface_uuid>"
# for a live workspace named by uuid OR short ref, from one list-panes call
# (its first pane's selected surface), or empty. Verified live on 0.64.25:
# `list-panes --workspace <ref>` answers immediately after new-workspace
# (17/17), while `workspace list` can still omit the new workspace, and it is
# not scoped to the current window.
fm_backend_cmux_pane_ids_for_workspace() {  # <workspace-id-or-ref>
  fm_backend_cmux_cli list-panes --workspace "$1" --json --id-format uuids 2>/dev/null \
    | jq -r '(.workspace_id // empty) as $w
      | (.panes[0] // {} | .selected_surface_id // (.surface_ids[0] // empty)) as $s
      | select($w != "" and $s != "") | "\($w) \($s)"' 2>/dev/null | head -1
}

# fm_backend_cmux_created_ref: the `<kind>:<n>` ref a create command printed
# on success (`OK workspace:32`, or `OK surface:41 pane:2 workspace:5` for
# new-surface; verified live on 0.64.25 whatever `--id-format` says), or empty
# when the output has none.
fm_backend_cmux_created_ref() {  # <kind> <create-output>
  printf '%s\n' "$2" | sed -n "s/^OK .*\($1:[0-9][0-9]*\).*\$/\1/p" | tail -1
}

# fm_backend_cmux_resolve_created_workspace: "<workspace_uuid> <surface_uuid>"
# of the workspace just created, resolved only from the ref cmux printed. A
# scoped-title lookup is deliberately not used: cmux does not enforce unique
# titles, so a concurrent client's workspace could match. Retried up to 15
# times, 0.2s apart, as a bound on any registration lag. Fails at once without
# a printed ref.
fm_backend_cmux_resolve_created_workspace() {  # <ref-or-empty>
  local ref=$1 i pair
  [ -n "$ref" ] || return 1
  i=0
  while [ "$i" -lt 15 ]; do
    [ "$i" -eq 0 ] || sleep 0.2
    pair=$(fm_backend_cmux_pane_ids_for_workspace "$ref")
    if [ -n "$pair" ]; then
      printf '%s' "$pair"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# fm_backend_cmux_create_workspace: create one unfocused workspace titled
# <title> in <cwd> and echo "<workspace_uuid> <surface_uuid>". Shared by the
# workspace-mode task create and the tab-mode shared container. When the
# printed ref never resolves, the workspace is closed best-effort by that ref,
# and the error names the leftover title only if that close does not report
# success. Without a printed ref nothing is closed (a title match is never
# trusted for a close) and the error names the leftover title.
fm_backend_cmux_create_workspace() {  # <title> <cwd>
  local title=$1 cwd=$2 out ref pair
  out=$(fm_backend_cmux_cli new-workspace --name "$title" --cwd "$cwd" --focus false --id-format uuids 2>&1) || {
    echo "error: cmux new-workspace failed for '$title': $out" >&2
    return 1
  }
  ref=$(fm_backend_cmux_created_ref workspace "$out")
  pair=$(fm_backend_cmux_resolve_created_workspace "$ref") || {
    if [ -n "$ref" ] && fm_backend_cmux_cli close-workspace --workspace "$ref" >/dev/null 2>&1; then
      echo "error: could not resolve a cmux workspace id for '$title' after creation" >&2
    else
      echo "error: could not resolve a cmux workspace id for '$title' after creation; close the leftover cmux workspace '$title' by hand" >&2
    fi
    return 1
  }
  printf '%s' "$pair"
}

# fm_backend_cmux_tree_surfaces: every surface in every window (or only in
# <workspace> when given), one "<workspace_uuid>\t<workspace_title>\t
# <surface_uuid>\t<surface_ref>\t<surface_title>\t<tty>" line each, from one
# `tree --json` call. Unlike list-pane-surfaces (focused pane only) and
# `workspace list` (current window only), the tree covers every pane and, with
# --all, every window. Read-only; an unreachable cmux prints nothing.
fm_backend_cmux_tree_surfaces() {  # [<workspace_id>]
  local scope
  if [ -n "${1:-}" ]; then
    scope="--workspace $1"
  else
    scope="--all"
  fi
  # shellcheck disable=SC2086  # scope is one or two fixed words
  fm_backend_cmux_cli tree $scope --json --id-format both 2>/dev/null \
    | jq -r '.windows[]?.workspaces[]? as $w | $w.panes[]?.surfaces[]?
      | [$w.id, ($w.title // ""), .id, (.ref // ""), (.title // ""), (.tty // "")] | @tsv' 2>/dev/null
}

# fm_backend_cmux_surface_ids: every surface uuid in <workspace>, one per line.
fm_backend_cmux_surface_ids() {  # <workspace_id>
  fm_backend_cmux_tree_surfaces "$1" | awk -F'\t' '{ print $3 }'
}

# fm_backend_cmux_surface_by_title: the uuid of the first surface titled
# <title> in <workspace>, or empty. Verified (0.64.20 and 0.64.25): rename-tab
# sets a sticky title that a running shell's own retitling does not
# overwrite, so the scoped fm-<home>-<id> tab title is a stable match key.
fm_backend_cmux_surface_by_title() {  # <workspace_id> <title>
  fm_backend_cmux_tree_surfaces "$1" | awk -F'\t' -v t="$2" '$5 == t { print $3; exit }'
}

# fm_backend_cmux_surface_for_title_anywhere: "<workspace_uuid> <surface_uuid>"
# of the first surface titled <title> in ANY window, or fails. Re-finds a
# tab-mode task whose recorded container id went stale after an app relaunch
# (workspace ids are re-minted, finding #5).
fm_backend_cmux_surface_for_title_anywhere() {  # <title>
  local hit
  hit=$(fm_backend_cmux_tree_surfaces | awk -F'\t' -v t="$1" '$5 == t { print $1 " " $3; exit }')
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

# fm_backend_cmux_workspace_of_surface: the uuid of the workspace that holds
# <surface_uuid> in any window, or empty.
fm_backend_cmux_workspace_of_surface() {  # <surface_id>
  fm_backend_cmux_tree_surfaces | awk -F'\t' -v s="$1" '$3 == s { print $1; exit }'
}

# fm_backend_cmux_create_task: create the task's endpoint, refusing an
# existing live <label> (finding #6: cmux enforces no title uniqueness itself,
# for workspaces OR tabs). <container> comes from
# fm_backend_cmux_container_ensure; absent or "workspace" means workspace
# mode. Echoes "<workspace_id> <surface_id>" on success in BOTH modes.
#
# Workspace mode: one unfocused workspace per task, resolved from its printed
# ref (fm_backend_cmux_create_workspace, which owns the failure cleanup).
#
# Tab mode: fm_backend_cmux_create_tab.
fm_backend_cmux_create_task() {  # <label> <cwd> [<container>]
  local label=$1 cwd=$2 container=${3:-workspace} title dup
  title=$(fm_backend_cmux_scoped_title "$label")
  if [ "$container" != workspace ]; then
    fm_backend_cmux_create_tab "$container" "$title" "$cwd"
    return
  fi
  dup=$(fm_backend_cmux_workspace_id_for_label "$title")
  if [ -n "$dup" ]; then
    echo "error: cmux workspace '$title' already exists" >&2
    return 1
  fi
  fm_backend_cmux_create_workspace "$title" "$cwd"
}

# fm_backend_cmux_create_tab: one unfocused terminal tab titled <title> in
# <container>, set to <cwd>. The duplicate check is app-global (every window),
# so a task tab is unique per home wherever its container lives.
#
# Identity: new-surface prints only short refs and inserts the tab next to the
# focused tab, never at the end, so the new uuid comes from diffing the
# container's surfaces around the create (resolved instantly 6/6 live on
# 0.64.25). When concurrent spawns into the same container make the diff hold
# more than one new surface, the printed `surface:<n>` ref picks this call's
# own, and an unresolvable ambiguity fails rather than guessing.
#
# Transactional: once the uuid is known, any later failure (the rename, or the
# cwd setup) closes ONLY that new surface. The rename is fatal because every
# later op re-finds a tab-mode task by that title. Without a resolvable uuid
# the tab is closed best-effort by its printed ref, never by position.
#
# Created --focus false: cmux 0.64.21+ (cmux PR 8540, fixing cmux issue 8526)
# paints a background-born surface correctly when it is first viewed, so no
# focus-steal-and-restore dance is needed (docs/cmux-backend.md).
fm_backend_cmux_create_tab() {  # <container_workspace_id> <title> <cwd>
  local wsid=$1 title=$2 cwd=$3 pair before out ref after fresh sfid i n
  if pair=$(fm_backend_cmux_surface_for_title_anywhere "$title"); then
    echo "error: cmux tab '$title' already exists (${pair% *})" >&2
    return 1
  fi
  before=$(fm_backend_cmux_surface_ids "$wsid")
  out=$(fm_backend_cmux_cli new-surface --type terminal --workspace "$wsid" --focus false 2>&1) || {
    echo "error: cmux new-surface failed for '$title': $out" >&2
    return 1
  }
  ref=$(fm_backend_cmux_created_ref surface "$out")
  sfid=""
  i=0
  while [ "$i" -lt 15 ]; do
    [ "$i" -eq 0 ] || sleep 0.2
    after=$(fm_backend_cmux_tree_surfaces "$wsid")
    fresh=$(awk -F'\t' 'FILENAME == ARGV[1] { old[$0] = 1; next }
      $3 != "" && !($3 in old) { print $3 "\t" $4 }' \
      <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
    n=$(printf '%s' "$fresh" | grep -c . || true)
    if [ "$n" = 1 ]; then
      sfid=${fresh%%$'\t'*}
    elif [ "$n" -gt 1 ] && [ -n "$ref" ]; then
      sfid=$(printf '%s\n' "$fresh" | awk -F'\t' -v r="$ref" '$2 == r { print $1; exit }')
    fi
    [ -z "$sfid" ] || break
    [ "$n" -le 1 ] || break
    i=$((i + 1))
  done
  if [ -z "$sfid" ]; then
    if [ -n "$ref" ] && fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$ref" >/dev/null 2>&1; then
      echo "error: created a cmux tab for '$title' but could not resolve its surface uuid" >&2
    else
      echo "error: created a cmux tab for '$title' but could not resolve its surface uuid; close the leftover cmux tab by hand" >&2
    fi
    return 1
  fi
  if ! fm_backend_cmux_cli rename-tab --workspace "$wsid" --surface "$sfid" -- "$title" >/dev/null 2>&1; then
    echo "error: could not rename cmux tab $sfid to '$title'; closing the new tab" >&2
    fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$sfid" >/dev/null 2>&1 || true
    return 1
  fi
  fm_backend_cmux_wait_ready "$wsid:$sfid"
  # A new tab starts in the container workspace's directory, not the task's
  # project, so move it there before fm-spawn.sh's `treehouse get`.
  if ! fm_backend_cmux_send_text_line "$wsid:$sfid" "cd $(printf '%q' "$cwd")"; then
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

# fm_backend_cmux_target_ready: parse the target and verify it is live via
# fm_backend_cmux_surface_exists (never read-screen - see that function's
# header for the fresh-surface pitfall this avoids). When the caller knows
# the owning firstmate task label, refresh stale workspace/surface ids by
# label, covering BOTH container shapes:
#   workspace mode  the workspace's own title carries the scoped task title;
#   tab mode        the SURFACE's title carries it instead, so when the
#                   workspace title does not match, the task is looked up by
#                   surface title - first inside the live stored container,
#                   then in every window, covering a relaunch-stale container
#                   id.
# A live target whose workspace AND surface titles both fail to match the
# expected label still fails, so ops never route to another task's endpoint.
fm_backend_cmux_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} expected_title title wsid sfid pair
  fm_backend_cmux_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_cmux_scoped_title "$expected_label")
    title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$FM_BACKEND_CMUX_WORKSPACE" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
    if [ "$title" = "$expected_title" ]; then
      fm_backend_cmux_surface_exists "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE" && return 0
      wsid=$FM_BACKEND_CMUX_WORKSPACE
    elif [ -n "$title" ]; then
      # Live workspace, non-matching title: a tab-mode container (or a
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

# fm_backend_cmux_surface_tty: the tty name (e.g. "ttys011") of the surface's
# terminal, from the tree, or empty when the terminal has not started yet (an
# unfocused fresh surface starts its terminal LAZILY - no tty, and failing
# read-screen, until it first receives input or is viewed). Verified on
# 0.64.25: `tree --json` reports tty for every started terminal.
fm_backend_cmux_surface_tty() {  # <workspace_id> <surface_id>
  fm_backend_cmux_tree_surfaces "$1" | awk -F'\t' -v s="$2" '$3 == s { print $6; exit }'
}

# fm_backend_cmux_screen_cwd: the task terminal's working directory from its
# on-screen shell block-header prompt, or empty when none is present. cmux
# renders every command block with a header line
# "| [<tag>] <ABSOLUTE_CWD> @ <host> (<user>)" and updates it on each `cd`, so
# the LAST such header is the current directory. Only absolute paths count.
fm_backend_cmux_screen_cwd() {  # <target> [expected-label]
  fm_backend_cmux_capture "$1" 200 "${2:-}" 2>/dev/null \
    | sed -nE 's/^\| \[[^]]*\] (\/.+) @ [^ ]+ \([^)]*\) *$/\1/p' | tail -1
}

# fm_backend_cmux_current_path: the task terminal's live working directory,
# or empty on any error. Used by fm-spawn.sh's worktree-discovery poll.
#
# Verified pitfall (finding #2 above): cmux's `current_directory` field stays
# FROZEN at the directory the surface's top-level shell was in when it
# launched `treehouse get`, never following that command's own `cd` into the
# acquired worktree, and the socket exposes no live-process cwd field. In tab
# mode it would also describe the container, not the task.
#
# PASSIVE tiers first, so the common case never types into the captain-visible
# task terminal:
#   1. The surface's tty (from the tree) plus the OS: the foreground process
#      on that tty via `ps`, its cwd via `lsof` - the same OS-level semantics
#      tmux's #{pane_current_path} provides.
#   2. The on-screen block-header cwd (fm_backend_cmux_screen_cwd).
#   3. The active pwd-marker probe (zellij's own workaround shape): print the
#      surface's `$PWD` between unique markers (atomically submitted via
#      send_text_line), briefly settle, then capture and read only that block.
fm_backend_cmux_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} tty pid cwd screen out line marker_begin="__FM_CMUX_CWD_BEGIN__" marker_end="__FM_CMUX_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_cmux_target_ready "$target" "$expected_label" || return 0
  # target_ready refreshed the parsed ids; address the refreshed pair
  # directly so every tier reads the same, re-resolved endpoint.
  target="$FM_BACKEND_CMUX_WORKSPACE:$FM_BACKEND_CMUX_SURFACE"
  tty=$(fm_backend_cmux_surface_tty "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE")
  if [ -n "$tty" ]; then
    pid=$(ps -t "$tty" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\+/ { p=$1 } END { if (p) print p }')
    if [ -n "$pid" ]; then
      cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      case "$cwd" in
        /*)
          printf '%s' "$cwd"
          return 0
          ;;
      esac
    fi
  fi
  screen=$(fm_backend_cmux_screen_cwd "$target")
  if [ -n "$screen" ]; then
    printf '%s' "$screen"
    return 0
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

# fm_backend_cmux_wait_ready: wake a fresh endpoint's lazily started terminal
# and wait until its screen shows stable non-empty content, then settle. An
# unfocused fresh tab does not start its terminal until it first receives
# input or is viewed, so this sends one harmless Enter and polls. A send to a
# not-yet-started surface is queued, not lost, so this is not needed for send
# correctness; it makes the tab-mode `cd` land at a visible prompt and lets the
# passive cwd tiers read a started terminal. Bounded; on timeout it returns
# anyway and the spawn's own worktree-discovery poll surfaces any real failure.
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
    # C-u clears a composer line. fm-send.sh's muse interrupt path needs it to
    # drop the prompt muse restores into the composer after Escape.
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl-u' ;;
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

# fm_backend_cmux_send_text_line: send one line of TEXT then submit.
fm_backend_cmux_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_cmux_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_cmux_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_cmux_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
}

# fm_backend_cmux_capture: bounded plain-text surface capture. `--scrollback`
# is this adapter's explicit opt-in to history, so the result can include
# lines that have scrolled out of view - it is not a viewport read, and no
# viewport-only primitive is offered for cmux (see FM_BACKEND_VISIBLE_CAPTURE in
# bin/fm-backend.sh). Finding #3's viewport-height cap was observed on
# read-screen calls; whether a call WITHOUT --scrollback is strictly bounded to
# the viewport is plausible but has not been live-verified. No herdr-style
# small-N empty-result bug was found (finding #3); "fetch generous, trim
# locally" is kept for parity with herdr and so a small caller bound never
# depends on how read-screen clamps a small --lines value.
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

# fm_backend_cmux_composer_capture: the cmux composer screen - a bounded
# plain-text tail of the surface. cmux's `read-screen` is plain text by
# construction (its --help: "Read terminal text from a surface as plain
# text"), which is why the capability descriptor below declares styled=0: the
# shared classifier then degrades a glyph row carrying trailing text to
# `unknown` instead of misreading an idle suggestion as unsent input.
fm_backend_cmux_composer_capture() {  # <target> [expected-label]
  fm_backend_cmux_capture "$1" "$FM_COMPOSER_CAPTURE_LINES" "${2:-}"
}

# fm_backend_cmux_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh).
fm_backend_cmux_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_cmux_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (including the borderless claude row this
# adapter once carried its own NBSP workaround for) lives in
# bin/fm-composer-lib.sh, so a new harness shape is taught there once and
# never here. cmux has no identity probe, so the classifier's identity
# sentinel resolves to unknown.
fm_backend_cmux_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_cmux_composer_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_cmux_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_cmux_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then drive the shared verify-and-retry-Enter
# loop (bin/fm-composer-lib.sh: fm_composer_submit_retry_core) against the
# shared composer verdict. Echoes empty|pending|unknown|send-failed, a subset
# of the proof-carrying submit vocabulary.
fm_backend_cmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_cmux_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_cmux_send_key fm_backend_cmux_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
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

# fm_backend_cmux_kill: remove the task's endpoint, best-effort (mirrors every
# other backend's `kill` `|| true` contract). Which shape to reclaim is derived
# from the resolved workspace's TITLE, never a stored mode flag, so teardown
# keeps working across a container-mode change:
#
#   workspace mode  the workspace's own title IS the task's scoped title (an
#                   EXACT match with an expected label; this home's task-title
#                   prefix without one): the task owns the whole workspace, so
#                   it and all its surfaces are reclaimed through
#                   fm_backend_cmux_close_workspace.
#   tab mode        anything else: the workspace is a container that is not
#                   the task's to reclaim, so only the task's surface is
#                   closed. cmux refuses to close a workspace's LAST surface
#                   (finding #4), so when the task tab is the only surface
#                   left: this home's own shared container
#                   (fm_backend_cmux_shared_container_title) is reclaimed
#                   whole; any other container (the captain's own workspace)
#                   first gets an unfocused throwaway tab so the close lands.
fm_backend_cmux_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} wsid sfid ws_title home scount task_owned=0
  if [ -n "$expected_label" ]; then
    fm_backend_cmux_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_cmux_parse_target "$1" || return 0
  fi
  wsid=$FM_BACKEND_CMUX_WORKSPACE
  sfid=$FM_BACKEND_CMUX_SURFACE
  ws_title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$wsid" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
  if [ -z "$ws_title" ]; then
    # Not in the current window's list: read its title from the all-window
    # tree before deciding the shape, so a task-owned workspace in another
    # window is still reclaimed whole.
    ws_title=$(fm_backend_cmux_tree_surfaces | awk -F'\t' -v w="$wsid" '$1 == w { print $2; exit }')
  fi
  home=$(fm_backend_cmux_home_label)
  if [ -n "$expected_label" ]; then
    [ "$ws_title" != "$(fm_backend_cmux_scoped_title "$expected_label")" ] || task_owned=1
  else
    case "$ws_title" in
      "fm-$home-"*) task_owned=1 ;;
    esac
  fi
  if [ "$task_owned" -eq 1 ]; then
    fm_backend_cmux_close_workspace "$wsid"
    return 0
  fi
  scount=$(fm_backend_cmux_surface_ids "$wsid" | grep -c . || true)
  if [ "$scount" = 1 ]; then
    if [ "$ws_title" = "$(fm_backend_cmux_shared_container_title)" ]; then
      fm_backend_cmux_close_workspace "$wsid"
      return 0
    fi
    fm_backend_cmux_cli new-surface --type terminal --workspace "$wsid" --focus false >/dev/null 2>&1 || true
  fi
  fm_backend_cmux_cli close-surface --workspace "$wsid" --surface "$sfid" >/dev/null 2>&1 || true
}

# fm_backend_cmux_close_workspace: best-effort close of one whole workspace by
# uuid. The selected-workspace teardown bug (docs/cmux-backend.md "Closing the
# last workspace in a window"): cmux keeps every window at >=1 workspace, so
# `close-workspace` on the ONLY workspace in its window silently no-ops while
# still returning `OK`. `close-window` cannot rescue it either: a window
# holding a live terminal cannot be closed over the control socket. The
# reliable primitive is close-workspace on a NON-last workspace, so when the
# target is the last one in its window an unnamed throwaway sibling is created
# first, leaving that window a fresh default workspace (never an fm-<home>-
# title, so recovery/list_live ignore it) - cmux's own "closed the last tab"
# outcome.
fm_backend_cmux_close_workspace() {  # <workspace_id>
  local wsid=$1 wininfo win count
  wininfo=$(fm_backend_cmux_window_of_workspace "$wsid")
  win=${wininfo%% *}
  count=${wininfo##* }
  if [ -n "$win" ] && [ "$count" = 1 ]; then
    fm_backend_cmux_cli new-workspace --window "$win" --focus false --id-format uuids >/dev/null 2>&1 || true
  fi
  fm_backend_cmux_cli close-workspace --workspace "$wsid" >/dev/null 2>&1 || true
}

# fm_backend_cmux_list_live: recovery/orphan discovery. Lists every endpoint
# whose title is scoped to this firstmate home, by TITLE - never by trusting a
# stored uuid, since workspace ids do NOT survive an app relaunch (finding #5).
# Covers BOTH container shapes regardless of the configured mode, so recovery
# after a mode change still finds every live task:
#   workspace mode  workspaces titled "fm-<home>-<id>" in the current window,
#                   with their single default surface;
#   tab mode        surfaces titled "fm-<home>-<id>" in every window.
# A workspace-mode task's own surface is never scoped-titled (nothing renames
# it), so the two scans cannot double-report. One
# "<workspace_id>:<surface_id>\tfm-<id>" line per live task endpoint.
# Read-only: an unreachable cmux simply lists nothing.
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
  fm_backend_cmux_tree_surfaces | awk -F'\t' -v p="$prefix" \
    'index($5, p) == 1 && length($5) > length(p) { print $1 ":" $3 "\tfm-" substr($5, length(p) + 1) }'
}

# fm_backend_cmux_tty_processes: one "<pid>\t<comm>" line per process whose
# controlling terminal is <tty>, or nothing when ps cannot read it.
fm_backend_cmux_tty_processes() {  # <tty>
  LC_ALL=C ps -t "$1" -o pid=,comm= 2>/dev/null \
    | awk '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 != "") print pid "\t" $0 }'
}

# fm_backend_cmux_classify_process: one tty process as agent|shell|other,
# through the shared classifier (bin/fm-agent-process-lib.sh) with ONE
# cmux-specific member: `login`, because cmux parents every tab shell through
# a resident /usr/bin/login wrapper, which must read as part of an idle shell
# stack rather than as an unattributable process.
fm_backend_cmux_classify_process() {  # <pid> <comm>
  local pid=$1 comm=$2 args argv0 base
  base=${comm##*/}
  base=${base#-}
  if [ "$base" = login ]; then
    printf 'shell'
    return 0
  fi
  args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=""
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_agent_process_classify "$comm" "$argv0" "$args" "$pid"
}

# fm_backend_cmux_agent_state: recovery-grade harness-agent state for one
# recorded target, on the shared six-state contract owned by bin/fm-backend.sh's
# fm_backend_agent_state. Only `dead` and `missing` license recovery, so every
# rung errs toward the non-actionable states.
#
# Socket first: `down` (no control socket) reads `missing`, because cmux hosts
# every task pty and no cmux-backed agent can outlive the app; an auth or
# transport failure reads `unreadable`, proving nothing. Identity next: the
# target is re-resolved through fm_backend_cmux_target_ready (by label when
# one is given); when it does not resolve, a readable workspace inventory
# reads `missing` and an unreadable one `unreadable`.
#
# Process attribution last, on the resolved surface's tty: EVERY process on
# the tty is classified, never just the foreground one, because a live agent's
# tool child can transiently be the foreground process:
#   any verified-harness process            -> alive;
#   nothing but shells (and cmux's login)   -> dead;
#   anything else                           -> ambiguous.
# A surface whose lazily started terminal never started has no tty -> ambiguous;
# an empty ps read -> unreadable.
fm_backend_cmux_agent_state() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} tty procs pid comm any=0 only_shells=1
  case "$(fm_backend_cmux_ping_state)" in
    ok) : ;;
    down) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  if ! fm_backend_cmux_target_ready "$target" "$expected_label"; then
    if fm_backend_cmux_cli workspace list --json --id-format uuids >/dev/null 2>&1; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  tty=$(fm_backend_cmux_surface_tty "$FM_BACKEND_CMUX_WORKSPACE" "$FM_BACKEND_CMUX_SURFACE")
  [ -n "$tty" ] || { printf 'ambiguous'; return 0; }
  procs=$(fm_backend_cmux_tty_processes "$tty")
  while IFS=$'\t' read -r pid comm; do
    [ -n "$pid" ] || continue
    any=1
    case "$(fm_backend_cmux_classify_process "$pid" "$comm")" in
      agent) printf 'alive'; return 0 ;;
      shell) : ;;
      *) only_shells=0 ;;
    esac
  done <<EOF
$procs
EOF
  [ "$any" -eq 1 ] || { printf 'unreadable'; return 0; }
  if [ "$only_shells" -eq 1 ]; then printf 'dead'; else printf 'ambiguous'; fi
}
