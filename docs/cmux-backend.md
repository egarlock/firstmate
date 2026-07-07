# Cmux runtime backend (experimental)

This document records the verification behind `bin/backends/cmux.sh`, the cmux session-provider adapter.
It is the cmux equivalent of `docs/herdr-backend.md`, following the same "empirical adapter notes" contract from CONTRIBUTING.md.

Cmux ([cmux.com](https://cmux.com), [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)) is a native macOS terminal built for running AI coding agents in parallel, controlled through a Unix-socket CLI (`cmux`).
Verified against the real installed binary: cmux 0.64.17 (build 97), macOS aarch64.

## Status: experimental

Cmux is experimental, exactly like every non-tmux backend in this design.
Select it explicitly with `--backend cmux`, `FM_BACKEND=cmux`, or `config/backend` containing `cmux`.
It can also be selected by runtime auto-detection when firstmate itself is running inside a cmux terminal (cmux auto-sets `CMUX_WORKSPACE_ID` in every terminal it manages) and no explicit backend setting exists; `$TMUX` still wins when firstmate runs in a tmux nested inside a cmux workspace, mirroring the herdr innermost-first rule.
An auto-detected cmux spawn prints one loud stderr notice (set `config/backend` or pass `--backend tmux` to opt out).
Absent `backend=` in a task's meta always means `tmux`; only a cmux task ever carries an explicit `backend=cmux` line, plus `cmux_workspace_id=`.
A cmux spawn refuses loudly if `cmux` or `jq` is missing, if the installed cmux is older than the verified minimum (`fm_backend_cmux_version_check`; `cmux version` needs no socket), or if the socket round-trip fails (`fm_backend_cmux_socket_check`).

## Socket auth is a real precondition

Unlike tmux and herdr, cmux's control socket has an auth layer (Settings > Automation > socket control mode).
The CLI resolves auth from `--password`, then `CMUX_SOCKET_PASSWORD`, then the app-saved password - but outside a cmux-managed terminal the app-saved password is not readable, so in `password` mode every external call fails with `auth_required`.
The adapter never handles passwords itself; `fm_backend_cmux_socket_check` performs one `cmux ping` and, on refusal, names the two operator fixes: switch the socket control mode to one that allows local automation, or export `CMUX_SOCKET_PASSWORD` into firstmate's environment.
This check runs at spawn time (through `fm_backend_cmux_container_ensure`), so a misconfigured socket refuses up front with the fix instead of failing opaquely mid-lifecycle.

Verified operator sharp edge: a socket-control-mode change made while the app is running does NOT apply to the live socket - the on-disk setting updated (`defaults read com.cmuxterm.app socketControlMode` -> `allowAll`) while a 5-day-old app process kept enforcing `password`, and `cmux reload-config` did not pick it up either.
Fully quitting and relaunching cmux applied it immediately.

## Worktree provider stays treehouse

Cmux is a session provider only.
Treehouse remains the worktree provider, exactly as it is for tmux and herdr.
Cmux's own worktree/PR features are never used by this adapter.

## Task container shape: workspace-per-task

Firstmate creates ONE cmux workspace per task, named `fm-<id>`, in the app's current window - there is no named-session or per-firstmate container to create first (the app itself is the container), so `fm_backend_cmux_container_ensure` is purely the version + live-socket gate.

Workspace-per-task was chosen over pane-or-surface-per-task inside one shared workspace because cmux's sidebar is workspace-first: each workspace row shows its working directory, git branch, linked PR status, and latest notification, and lights up when an agent is waiting.
That makes the sidebar itself the fleet view - each firstmate task gets its own row with native per-task status - which is exactly the human-watching axis that decided herdr's tab-per-task shape.

## Target string and meta fields

A cmux task's `window=` meta field holds `cmux:<workspace-uuid>`, for example `cmux:11111111-aaaa-bbbb-cccc-000000000001`.
The literal `cmux` prefix keeps the target colon-containing, so `fm_backend_resolve_selector`'s pass-through and `fm_backend_of_selector`'s meta matching both work with no backend-specific logic, exactly like herdr's `<session>:<pane-id>` shape.
Workspace UUIDs are requested explicitly (`--id-format uuids`) and stored because they are stable handles; cmux's default short refs (`workspace:2`) are index-based and shift as workspaces are created, closed, or reordered, so they are never stored.
Operational commands should prefer the bare `fm-<id>` form, which resolves through this home's metadata.

The task name lives in the workspace's `custom_title` field: verified that `new-workspace --name fm-<id>` sets `custom_title` (with `title` mirroring it), while cmux's opt-in AI auto-naming rewrites `title` from conversation content (observed live, including a busy-spinner glyph prefix) but never overrides a custom title.
So every name-based operation (duplicate check, UUID resolution, `fm_backend_cmux_list_live`, bare-selector fallback) matches `custom_title`, never `title`.

Cmux tasks additionally record:

- `cmux_workspace_id=` - the task workspace's UUID (same value as the target's suffix, recorded for symmetry with herdr's id fields).

## Verified CLI facts

| Operation | Verified cmux call | What was verified |
|---|---|---|
| Version gate | `cmux version` -> `cmux 0.64.17 (97) [9ed29d81a]` | Socket-free (works while auth is refused); minimum pinned in `FM_BACKEND_CMUX_MIN_VERSION`. |
| Socket gate | `cmux ping` -> `PONG` | One authenticated round-trip; an auth refusal prints `auth_required`, which the adapter maps to the operator fix. |
| Create task workspace | `cmux new-workspace --name fm-<id> --cwd <proj> --focus false` | Prints a TEXT acknowledgment `OK workspace:<n>` carrying only the unstable index-based short ref; `--json` is IGNORED on this command in 0.64.17. The adapter therefore resolves the stable UUID with an immediate `custom_title` lookup, made unambiguous by its own duplicate check (cmux does not enforce workspace-name uniqueness). `--focus false` verified not to steal the captain's focus. |
| List / recovery | `cmux list-workspaces --json --id-format uuids` | Honors both flags; per-workspace fields verified: `id` (UUID), `title`, `custom_title`, `current_directory`, `index`, `selected`, plus presentation fields. `fm-*` filtering matches `custom_title`. |
| Send literal (unsubmitted) | `cmux send --workspace <ws> <text>` | Verified NOT to auto-submit: a marker command sat unexecuted in the composer until a separate Enter. Behaves exactly like tmux's `send-keys -l`. |
| Send key | `cmux send-key --workspace <ws> <key>` | Verified names: `enter` (submits), `escape` (accepted), `ctrl+c` (interrupts a running foreground `sleep` immediately). Firstmate vocabulary normalized: Enter -> `enter`, Escape -> `escape`, C-c -> `ctrl+c`. |
| Send + submit | literal send + `send-key enter` | Cmux exposes no atomic type-and-run primitive, so the two fixed spawn-time commands compose the two calls. |
| Bounded capture | `cmux read-screen --workspace <ws> --lines N` | Verified to clamp small N correctly (`--lines 5` returned exactly the last 5 lines) - cmux does NOT have herdr's small-N empty-read bug. The adapter still over-fetches (>= 200 lines, trimmed locally with `tail`) as cheap insurance against any future viewport-dependent regression. |
| Current path | surface tty from `cmux tree` + `ps -t <tty>` foreground pid + `lsof -d cwd` | OS-level ground truth, matching tmux's `#{pane_current_path}` semantics; the workspace list's `current_directory` is only the fallback. See "Live-cwd tracking" below - the JSON field alone verifiably fails the treehouse case. |
| Busy state | forward-compatible `agent_status` probe on the workspace list | NO machine-readable agent-state field exists in 0.64.17's workspace list (the sidebar's busy cue rides the opt-in auto-naming title's spinner glyph, which is presentation-bound and never parsed), so busy state reports unknown and the watcher uses its shared tail-regex fallback, exactly like tmux. If a future cmux exposes `agent_status`, the mapping is ready: `working` -> busy; `idle`/`done` -> idle; `waiting`/`blocked` -> idle (stuck on the human - surfaced like a stale pane, not suppressed as busy). |
| Kill | `cmux close-workspace --workspace <ws>` | Verified to close the workspace; closing an already-closed workspace exits non-zero (`not_found`), matching tmux's `kill-window \|\| true` best-effort contract. |

Every invocation goes through `fm_backend_cmux_cli`, which sets `CMUX_QUIET=1` so legacy-alias migration notices (e.g. "'list-workspaces' is now an alias for 'cmux workspace list'") can never contaminate parsed output.

## Live-cwd tracking (the herdr `foreground_cwd` lesson, sharper here)

fm-spawn.sh discovers the acquired treehouse worktree by polling the endpoint's current path until it leaves the project directory.
Herdr verification proved how sharp this edge is: its `pane.cwd` was frozen at creation time and only `foreground_cwd` tracked the live `treehouse get` subshell.

Cmux's workspace-list `current_directory` field verifiably CANNOT be the primary primitive.
The first live E2E spawn failed exactly here: the pane visibly entered the treehouse worktree (`treehouse get` succeeded, prompt in the worktree), while `current_directory` stayed frozen at the project directory through `cd` attempts in that subshell, whether or not the workspace was selected - so the worktree-discovery poll falsely timed out.
The field is fed by cmux's shell-integration reporting from the workspace's top shell in ways that do not cover the treehouse child-shell case; in one isolated probe an `exec zsh -i` subshell did update it, so the behavior is situation-dependent - exactly what a spawn gate must not depend on.

The adapter therefore reads OS ground truth, the same semantics tmux's `#{pane_current_path}` provides: `cmux tree --workspace <ws>` exposes the terminal surface's `tty=`, `ps -t <tty>` yields the foreground process group, and `lsof -d cwd` yields that process's live cwd.
Verified end to end: the E2E spawn's discovery poll found the treehouse worktree through this path on the first attempt after the change.
The JSON `current_directory` remains only a fallback for a terminal that has not started yet (no tty).

## Lazy terminal start and the shell-readiness gate

Verified: an unfocused, freshly created workspace does NOT start its terminal process - `read-screen` returns zero bytes and `cmux tree` shows no `tty=` - until the surface first receives input or is viewed.
Input sent to such a surface is buffered and executes once the shell starts (the first E2E attempt's `treehouse get` ran fine despite being typed before the login banner), but a spawn that races init this way gets nondeterministic shell-integration state.
`fm_backend_cmux_create_task` therefore ends with `fm_backend_cmux_wait_ready`: one harmless Enter to trigger the lazy start, then a bounded poll for stable non-empty screen content (the banner and prompt), then a settle.
Knobs: `FM_CMUX_READY_ATTEMPTS` (default 30), `FM_CMUX_READY_INTERVAL` (default 0.5s), `FM_CMUX_READY_SETTLE` (default 1s).

## End-to-end verification (spawn -> steer -> done -> refuse -> merge -> teardown)

Beyond the fake-CLI unit tests (`tests/fm-backend-cmux.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME`, a scratch `local-only` git project, and workspace-per-task in the captain's running cmux app (scratch workspaces only; the captain's own workspaces were never touched):

1. `FM_HOME=<scratch> FM_BACKEND=cmux bin/fm-spawn.sh cmux-e2e-t1 <scratch-project> claude` - spawned successfully, printing `window=cmux:<uuid>` and writing `backend=cmux` and `cmux_workspace_id=` to the task's meta.
2. `bin/fm-peek.sh fm-cmux-e2e-t1` - routed through the cmux capture and showed the live claude trust dialog.
3. `bin/fm-send.sh fm-cmux-e2e-t1 --key Enter` - accepted the trust dialog.
4. The crewmate created branch `fm/cmux-e2e-t1`, wrote and committed the task file, appended `done: ready in branch fm/cmux-e2e-t1`, and the claude Stop-hook turn-end marker fired in the cmux workspace.
5. `bin/fm-teardown.sh cmux-e2e-t1` REFUSED, exactly as required (no recorded `landed=`, not reachable from a publishing remote, content not in the default branch).
6. `bin/fm-review-diff.sh` showed the one-file diff; `bin/fm-merge-local.sh` fast-forwarded local `main` and recorded `landed=`.
7. `bin/fm-teardown.sh cmux-e2e-t1` then succeeded: returned the treehouse worktree to the pool, closed the cmux workspace, and removed the task's `state/` files.

Two real bugs were caught and fixed by this pass alone, both reflected above and in `bin/backends/cmux.sh`:

- The frozen `current_directory` for the treehouse subshell (see "Live-cwd tracking") - without the tty+`ps`+`lsof` primitive, every cmux spawn false-timed-out at worktree discovery.
- The lazy terminal start (see above) - without the wake-and-wait gate, spawn-time input raced shell init.

## Composer verification: delta-based

Cmux's CLI exposes no ANSI/cursor-row composer-read primitive, so `fm_backend_cmux_send_text_submit` uses the same delta strategy as herdr: capture right after typing (the "typed" baseline, unsubmitted), then after each Enter capture again; unchanged means the Enter was swallowed (bounded retry), changed means submitted.
The `<settle>` pause before the first Enter covers the slash-command autocomplete-popup hazard that tmux and herdr both exhibit with claude/codex composers; the settle-duration decision stays in `fm-send.sh` (harness-aware, backend-independent).
Both send paths echo the identical caller-facing verdict vocabulary (`empty`, `pending`, `unknown`, `send-failed`), so `fm-send.sh` needs no backend-specific branching.

## Known gaps left for a follow-up

- **No native event push consumed yet.** Cmux has a genuinely good event surface - `cmux events` streams reconnectable newline-delimited JSON with categories, sequence cursors, and replay, and every event is also appended to `~/.cmuxterm/events.jsonl` - which maps directly onto the design's "events as the core abstraction" framing.
  The adapter consumes only pull primitives through the existing `fm-watch.sh` poll loop, exactly as herdr does; a push-driven wake source is the natural follow-up and would make cmux the first backend to feed the wake queue natively.
- **No semantic busy state on the verified version.** 0.64.17's workspace list exposes no machine-readable agent-state field, so `fm_backend_cmux_busy_state` always reports unknown and cmux tasks use the shared pane-regex detection, exactly like tmux. Cmux does track agent activity internally (its harness hooks drive the sidebar's working/waiting indicators and notifications), so a queryable field or the notifications/events surface is the natural upgrade path; the adapter's forward-compatible `agent_status` probe and mapping are already in place.
- **`bin/fm-bootstrap.sh`'s required-tools list is unchanged.** It still unconditionally requires `tmux` and does not conditionally add `cmux`/`jq` when the backend resolves to cmux; the spawn-time gate refuses loudly instead, matching the herdr precedent.
- **macOS app lifetime.** The cmux socket lives only while the app runs; firstmate never auto-launches the captain's GUI app, so a task fleet on the cmux backend requires the app to stay open. Workspaces persist across app restarts via cmux's session restore, and recovery re-resolves tasks by `fm-*` workspace name, never by trusting a stored id blindly.
