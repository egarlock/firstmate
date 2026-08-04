# cmux runtime backend

cmux is an experimental macOS GUI terminal backend.
It provides task workspaces and surfaces while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick cmux when you already use the app as your terminal and want task workspaces in its sidebar.
cmux is macOS-only, GUI-first, and unsuitable for a headless or SSH-only Firstmate session.

Prerequisites:

- cmux 0.64 or newer, installed from [cmux.com](https://cmux.com) or with `brew install --cask cmux`.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The CLI is not always installed on `PATH` with the app.
The adapter prefers `command -v cmux` and otherwise uses `/Applications/cmux.app/Contents/Resources/bin/cmux`.

### Required socket access

cmux defaults to a control mode that rejects external shells, while Firstmate always controls it from an external process.
Open Settings > Automation and choose a viable Socket Control Mode before the first cmux-backed spawn.

| Setting | Value | Firstmate support | Security boundary |
| --- | --- | --- | --- |
| Off | `off` | No | The socket listener is disabled. |
| cmux processes only | `cmuxOnly` | No | Only descendants of the cmux app can connect. |
| Automation mode | `automation` | Yes, recommended | The owner-only 0600 socket admits processes of the current macOS user. |
| Password mode | `password` | Yes | The 0600 socket also requires an auth handshake. |
| Full open access | `allowAll` | Yes, not recommended | The 0666 socket admits every local user without authentication. |

Automation mode is the recommended same-user boundary.
`allowAll` can execute commands through a world-writable control socket and should be selected only as an explicit security tradeoff.

For Password mode, store the password as the first line of local gitignored `config/cmux-socket-password` or provide `CMUX_SOCKET_PASSWORD` in Firstmate's environment.
The adapter reads the file fresh from the effective config directory and does not overwrite an ambient password when the file is absent.
Configure the mode and password through the cmux UI rather than editing `cmux.json`; the app does not retain a hand-added password key, and socket-based reload cannot fix a socket that is rejecting the caller.

Select cmux with local `config/backend` containing `cmux`, `FM_BACKEND=cmux` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate itself runs inside cmux.
A spawn stops with an actionable setup message when the app, minimum version, `jq`, socket access, or password is unavailable.
The adapter may launch the app with `open -a cmux` only when the socket is down; it does not relaunch the app for access-denied or authentication errors.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without bringing the cmux window forward.
Task and secondmate endpoints are created focused and the previously focused window/workspace/pane/tab context is then restored, because a surface created unfocused on cmux 0.64.18+ can stay renderer-unrealized and later paint black once it hosts a full-screen TUI agent.
Expect one brief cmux-internal focus flicker per spawn; the restore cannot move macOS app-level focus to another application.

Verify setup by spawning a small task and confirming metadata contains `backend=cmux`, `cmux_workspace_id=`, and `cmux_surface_id=`.

## Runtime detection

`CMUX_WORKSPACE_ID` is the primary cmux runtime marker.
`CMUX_SOCKET_PATH` is not sufficient because operators may set it outside cmux.
Detection checks tmux first, then Herdr, then cmux, so a multiplexer nested inside cmux remains the active backend.

cmux's bundled Claude wrapper can remove every `CMUX_*` variable when its internal socket probe fails, including in Password mode.
On macOS only, detection therefore falls back first to `__CFBundleIdentifier=com.cmuxterm.app`, then to process ancestry reaching the running cmux app.
Those fallbacks are consulted only when neither tmux nor Herdr already won.
An environment-scrubbed or launchd-reparented process with no reliable marker is not auto-detected.

Auto-detection selects only the backend.
It never changes socket access or grants credentials.
The spawn refusal explains how to finish cmux setup or opt back into tmux.

## Task shape and metadata

The task-container shape is configurable: `FM_CMUX_CONTAINER`, then the first word of local gitignored `config/cmux-container`, then the default `workspace`.

- `workspace` (default): each task owns one cmux workspace with one surface, giving it its own sidebar row.
- `tab`: each task is one surface (tab) inside a container workspace - the workspace Firstmate itself runs in when inside cmux, else a find-or-create shared per-home workspace titled `fm-<home-label>`.

The caller-facing label remains `fm-<id>`, while the visible scoped title `fm-<home-label>-<id>` lands on the workspace in workspace mode or on the task's tab (a sticky `rename-tab`) in tab mode.
The home label is `firstmate` or `2ndmate-<id>` plus a stable short hash of the resolved Firstmate root.
cmux does not enforce title uniqueness, so create, recovery, list, and cleanup paths all validate this scoped title.
Which mode a live task is in is derived from where its scoped title sits, never a stored flag, so recovery and cleanup keep working across a container-mode config change.
Relocating the Firstmate installation changes the hash and leaves old titles unmatched, consistent with recorded worktree paths also becoming stale.

```text
backend=cmux
window=<workspace-uuid>:<surface-uuid>
cmux_workspace_id=<workspace-uuid>
cmux_surface_id=<surface-uuid>
```

The same `<workspace>:<surface>` target shape serves both modes: in tab mode the workspace is the container and the surface is the task's tab.
The UUID pair is the active endpoint authority within one app run.
Workspace UUIDs are not stable across an app relaunch, so recovery searches by the scoped title and then resolves the current surface id, app-globally in tab mode when the recorded container workspace id went stale.

## Current operation and safety

A genuinely fresh surface returns an internal error from `read-screen` until something has been written.
Target readiness therefore uses the structural `list-panes` response instead of a content read.
Capture remains bounded and locally trimmed after `read-screen` becomes available.

A fresh unfocused tab starts its terminal lazily; sends are queued into the pty and execute once it starts, and the tab-mode create wakes it (`fm_backend_cmux_wait_ready`) so its setup command lands at a visible prompt.

`current_directory` follows a top-level shell `cd` but not the foreground subshell opened by `treehouse get`.
Worktree discovery tries passive tiers first so the common case never types into the captain-visible terminal: the surface tty's foreground process cwd (`cmux tree` + `ps` + `lsof`), then the on-screen block-header cwd, then the workspace's `current_directory` only when the workspace is provably task-owned.
Only as a last resort does it send begin and end markers around `pwd`, capture the marked block, and join wrapped path lines.

Literal send and Enter are separate calls.
Enter, Escape, and Ctrl-C are supported.
The composer verifier locates the last bordered composer row and delegates the content decision to `bin/fm-composer-lib.sh`.
A bare shell prompt is `unknown`, and a slash-popup placeholder remains `pending`, so only Enter is retried and text is never retyped.
cmux exposes no native generic agent busy signal, so supervision uses capture/hash polling for screen changes and each harness adapter's semantic lifecycle for worker state.
A forward-compatible probe reads a future `agent_status` field from the workspace list, reports `unknown` on every verified version today, and is consulted only for a provably task-owned workspace so a tab-mode container's state is never attributed to a task.
Grok alone retains its isolated rendered-tail fallback.

A task workspace's last surface cannot be closed directly.
Cleanup owns the whole workspace and uses `close-workspace`.
A tab-mode task closes only its own surface; when that tab is the container's last surface, Firstmate reclaims its own now-task-free shared container whole, while a captain-owned container gets a throwaway default surface first so the close lands.
cmux also refuses to remove the only workspace in a macOS window while returning a misleading success response.
When the task is last in its window, Firstmate creates one unfocused unnamed sibling workspace in that same window, closes the task workspace, and leaves the window with cmux's fresh default workspace.
The sibling never carries an `fm-` title and is ignored by recovery.

The exact window membership is re-read before this operation.
A selected workspace that is not last closes normally; selection itself is not the trigger.
Firstmate does not attempt to close the macOS window because cmux's socket cannot close a window holding a live terminal.

Real tests share the captain's running app rather than creating an isolated cmux session.
`tests/cmux-test-safety.sh` permits cleanup only for an exact currently listed `fm-test-` workspace and never enumerates and closes unrelated workspaces or relaunches the app.

## Secondmate support

`--secondmate` spawns are supported through a dedicated-workspace-per-mate design.
A cmux secondmate gets one workspace of its own, created at the mate's home directory with the mate's tab inside it, in every task-container mode, so a tab-mode primary never lands a mate as a tab in the primary's own workspace.
The workspace's initial title is the mate home's own `fm-<home-label>`, so the mate's workspace doubles as that home's tab-mode shared container; the mate's tab is renamed to the primary's scoped task title.

Identity is id-primary with synced-title recovery.
The captain may retitle the mate's workspace freely; the recorded UUIDs are the operational handle while the app is alive, and the meta's `cmux_workspace_title=` records the last-synced title.
Every label-gated operation and the session-start liveness sweep resolve the mate through `fm_backend_cmux_secondmate_resolve`: recorded ids first, then the synced recorded title across every window, then the scoped tab title, then a home-cwd fingerprint read only through passive tiers.
Each rung requires exactly one candidate; multiple candidates refuse loudly and no candidate at all is the definitively-gone verdict.
The resolver re-records refreshed ids and a captain retitle into the meta as a supervision side effect.

Agent liveness uses the shared six-state `fm_backend_agent_state` contract (`bin/fm-backend.sh`): the resolved surface's tty processes are classified with the shared harness policy, a shells-plus-`login`-only tty is confidently dead, a down socket is an authoritatively missing endpoint, and auth failures, unattributable processes, or multi-candidate resolutions never license recovery.
Mate cleanup closes the whole dedicated workspace only through the resolver's identity checks (`fm_backend_cmux_secondmate_kill`).
Backend selection for new mates honors `config/secondmate-backend`, and a respawn reuses the backend recorded in the mate's meta ([`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend)).

## Active limits

- cmux is experimental, macOS-only, GUI-first, and requires the app running.
- Socket access requires a one-time manual Settings change.
- There is no native busy or push-event signal; the `agent_status` probe is forward-compatible only.
- A target can disappear after structural readiness and before the operation.
- The only-workspace cleanup path leaves a fresh default workspace and cannot close the window.
- Ordinary-task label lookup is scoped to the current cmux window, so a task moved to a non-current window is a known recovery blind spot; secondmate resolution scans every window.
- Workspace ids do not survive app relaunch and are never recovery authority.
- Spawns cause one brief focus flicker from the focus-at-birth rule.

## Regression entry points

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
tests/fm-secondmate-liveness.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) records the active source and live evidence, including socket modes and last-in-window cleanup.
