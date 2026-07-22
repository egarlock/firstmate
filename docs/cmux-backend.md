# Cmux runtime backend (experimental)

This document records the verification behind `bin/backends/cmux.sh`, the cmux session-provider adapter.
It is the cmux equivalent of `docs/herdr-backend.md`, following the same "empirical adapter notes" contract from CONTRIBUTING.md.

Cmux ([cmux.com](https://cmux.com), [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)) is a native macOS terminal built for running AI coding agents in parallel, controlled through a Unix-socket CLI (`cmux`).
The original adapter was verified against cmux 0.64.17 (build 97); the tab focus-at-birth workaround below was verified against cmux 0.64.20 (build 100), macOS aarch64.
Caveat: `FM_BACKEND_CMUX_MIN_VERSION` was later lowered to 0.63.1 without re-verification on that build; in particular the screen-cwd fallback (`fm_backend_cmux_screen_cwd`) depends on the block-header screen format only observed on 0.64.17. Re-verify or re-raise the pin before relying on 0.63.x.

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

## Task container shape: tab-per-task by default, workspace-per-task by config

The shape is configurable via `FM_CMUX_CONTAINER` (env), then the local gitignored `config/cmux-container` file, then the default `tab`:

- **`tab` (default)** - one cmux SURFACE (tab) per task, titled `fm-<id>`, inside one container workspace: the workspace firstmate itself runs in (`CMUX_WORKSPACE_ID`, auto-set in every cmux-managed terminal) when firstmate is inside cmux, else a find-or-create shared workspace named `firstmate`.
  This mirrors `bin/backends/tmux.sh`'s container behavior exactly (crewmate windows join the captain's own session when firstmate runs inside tmux, else a detached `firstmate` session): the captain watches every task as a tab in the tab bar of the workspace they already have open.
- **`workspace`** - one cmux workspace per task, named `fm-<id>`.
  Each task gets its own sidebar row with cmux's native per-workspace status (working directory, git branch, linked-PR status, notifications), for captains who prefer a sidebar row per task.

In tab mode, teardown closes only the task's tab; the container workspace (the captain's own, or the shared `firstmate` one) stays, exactly as tmux leaves the session.

## Tab creation requires focus at birth on cmux 0.64.18+

Cmux 0.64.18 introduced a regression in which a terminal surface created with `--focus false` can remain renderer-unrealized and later paint black when selected.
The live signature is `inWindow=0` with a zero-sized `frame={0.0,0.0 0.0x0.0}` in `cmux debug-terminals`.
The behavior was not present in 0.64.17; the focus-at-birth workaround was verified on 0.64.20.

Cmux has no mount-without-focus primitive, so tab mode creates the terminal with `--focus true`, then restores the full prior focus context.

Restoring only the surface is not enough: focusing a surface does **not** reactivate its workspace or window (verified 0.64.20), so tab mode captures the complete focused context before creating the tab: `.focused.{window_ref, workspace_ref, pane_ref, surface_ref}` from `cmux identify --no-caller`.
A destination-less `cmux move-surface --surface <prior> --focus true` must **not** be used to restore: with no `--before`/`--after`/`--index` it reorders (appends) the tab within its pane (verified 0.64.20), disturbing the pre-existing tab order.

The verified order-preserving restore sequence (cmux 0.64.20) is:

1. `cmux focus-window --window <window>` (best-effort; harmless no-op on a single-window app or a missing window ref).
2. `cmux select-workspace --workspace <workspace> [--window <window>]` (essential: brings the prior workspace, and its window, back to the foreground).
3. `cmux focus-pane --pane <pane> --workspace <workspace> [--window <window>]` (best-effort refinement).
4. `cmux reorder-surface --surface <surface> --workspace <workspace> [--window <window>] --index <its-own-current-index> --focus true` (essential: re-selects the tab **at the index it currently occupies**, a no-op move that only changes focus, so pre-existing order is preserved).

The surface's current index is re-read (`list-pane-surfaces --json --id-format both`) at restore time because creating the new tab focused shifts indices.
Reactivating the workspace and the order-preserving refocus are the two steps that must succeed; a missing window/pane ref or a single-window app makes steps 1 and 3 harmless no-ops.
Restoration causes a brief focus flicker while the new terminal's drawable is realized.
If cmux reports no focused surface, restoration is skipped; if it reports a context whose workspace cannot be reactivated, or whose surface has since vanished, task creation fails explicitly.

**Never** close, move, reorder, or rename a pre-existing surface: restoration only reactivates/refocuses them in place, and the sole `rename-tab` targets the new surface.

Tab creation is transactional after cmux acknowledges the new surface.
The new surface's exact UUID is resolved by diffing `list-pane-surfaces --json --id-format uuids` around the create (the `new-surface` acknowledgment carries only short refs, `OK surface:<n> pane:<m> workspace:<k>`, and it inserts the tab adjacent to the focused tab, not at the end, so position cannot identify it), and the create is acknowledged, **before** the fallible focus restoration runs.
Any pre-return failure after the UUID is known (restoration failure, or the post-create `cd` cwd setup) closes **only** that new surface via `cmux close-surface --workspace <ws> --surface <new>`, so no orphan terminal is left and no pre-existing tab is touched.
If the new UUID cannot be resolved at all, task creation fails **without** closing anything, because a blind close could hit a pre-existing tab.
Workspace mode remains unchanged on `new-workspace --focus false`, because the confirmed regression concerns terminal surfaces.
The CLI can verify the realized in-window frame, but the final painted-versus-black confirmation remains a visual check for the captain after the change is available.

## Target string and meta fields

A cmux task's `window=` meta field holds `cmux:<workspace-uuid>:<surface-uuid>` in tab mode, or `cmux:<workspace-uuid>` in workspace mode.
The literal `cmux` prefix keeps the target colon-containing, so `fm_backend_resolve_selector`'s pass-through and `fm_backend_of_selector`'s meta matching both work with no backend-specific logic, exactly like herdr's `<session>:<pane-id>` shape; the adapter splits the remainder into workspace and optional surface.
UUIDs are requested explicitly (`--id-format uuids`) and stored because they are stable handles; cmux's default short refs (`workspace:2`, `surface:9`) are index-based and shift as things are created, closed, or reordered, so they are never stored.
Operational commands should prefer the bare `fm-<id>` form, which resolves through this home's metadata.

The task name lives in the workspace's `custom_title` field (workspace mode) or the surface's `title` (tab mode):

- Verified: `new-workspace --name fm-<id>` sets `custom_title` (with `title` mirroring it), while cmux's opt-in AI auto-naming rewrites the workspace `title` from conversation content (observed live, including a busy-spinner glyph prefix) but never overrides a custom title.
  Workspace-level name matching therefore uses `custom_title`, never `title`.
- Verified: `rename-tab` sets a sticky surface title that running commands do not overwrite, so tab-level matching uses the surface `title` from `list-pane-surfaces --json`.

Cmux tasks additionally record:

- `cmux_workspace_id=` - the task's workspace UUID (the container workspace in tab mode, the task's own workspace in workspace mode).
- `cmux_surface_id=` - tab mode only: the task tab's surface UUID.

## Verified CLI facts

| Operation | Verified cmux call | What was verified |
|---|---|---|
| Version gate | `cmux version` -> `cmux 0.64.17 (97) [9ed29d81a]` | Socket-free (works while auth is refused); minimum pinned in `FM_BACKEND_CMUX_MIN_VERSION` (currently 0.63.1, LOWER than the verified build - see caveat below). |
| Socket gate | `cmux ping` -> `PONG` | One authenticated round-trip; an auth refusal prints `auth_required`, which the adapter maps to the operator fix. |
| Create task workspace (workspace mode) | `cmux new-workspace --name fm-<id> --cwd <proj> --focus false` | Prints a TEXT acknowledgment `OK workspace:<n>` carrying only the unstable index-based short ref; `--json` is IGNORED on this command in 0.64.17. The adapter therefore resolves the stable UUID with an immediate `custom_title` lookup, made unambiguous by its own duplicate check (cmux does not enforce workspace-name uniqueness). `--focus false` verified not to steal the captain's focus. |
| Create task tab (tab mode) | `cmux identify --no-caller` (capture full `window/workspace/pane/surface` context); `cmux new-surface --type terminal --workspace <ws> --focus true`; resolve the new UUID by diffing `list-pane-surfaces --json --id-format uuids`; restore focus with `focus-window` (best-effort) + `select-workspace --workspace <ws> [--window <w>]` + `focus-pane` (best-effort) + `reorder-surface --surface <prior> --workspace <ws> [--window <w>] --index <own-index> --focus true`; rename, readiness, and cwd setup | Cmux 0.64.18+ can leave a surface created with `--focus false` renderer-unrealized. Creating focused realizes its drawable, then restoring the **full prior context** returns focus (a bare surface focus does not reactivate its workspace/window). Restoration is order-preserving: `reorder-surface` at the prior surface's own current index refocuses without moving it, whereas a destination-less `move-surface` would reorder (append) it. Creation is transactional: the new UUID is resolved and the create acknowledged before the fallible restore, and any pre-return failure closes only the new surface (`close-surface --surface <new>`), never a pre-existing tab. |
| Name a task tab | `cmux rename-tab --workspace <ws> --surface <sf> fm-<id>` | Verified sticky: the title survives running commands (unlike auto-titles). Surface titles are not unique either; the adapter's duplicate check runs first. |
| List / recovery | `cmux list-workspaces --json --id-format uuids`, `cmux list-pane-surfaces --workspace <ws> --json --id-format uuids` | Both honor the flags; per-workspace fields verified: `id` (UUID), `title`, `custom_title`, `current_directory`, `index`, `selected`; per-surface fields: `id`, `title`, `type`, `index`, `selected`. `fm-*` filtering matches workspace `custom_title` and surface `title`, covering both container shapes regardless of the configured mode. |
| Send literal (unsubmitted) | `cmux send --workspace <ws> <text>` | Verified NOT to auto-submit: a marker command sat unexecuted in the composer until a separate Enter. Behaves exactly like tmux's `send-keys -l`. |
| Send key | `cmux send-key --workspace <ws> <key>` | Verified names: `enter` (submits), `escape` (accepted), `ctrl+c` (interrupts a running foreground `sleep` immediately). Firstmate vocabulary normalized: Enter -> `enter`, Escape -> `escape`, C-c -> `ctrl+c`. |
| Send + submit | literal send + `send-key enter` | Cmux exposes no atomic type-and-run primitive, so the two fixed spawn-time commands compose the two calls. |
| Bounded capture | `cmux read-screen --workspace <ws> --lines N` | Verified to clamp small N correctly (`--lines 5` returned exactly the last 5 lines) - cmux does NOT have herdr's small-N empty-read bug. The adapter still over-fetches (>= 200 lines, trimmed locally with `tail`) as cheap insurance against any future viewport-dependent regression. |
| Current path | surface tty from `cmux tree` (`--id-format both` in tab mode, verified to print short ref + UUID per line) + `ps -t <tty>` foreground pid + `lsof -d cwd` | OS-level ground truth, matching tmux's `#{pane_current_path}` semantics. The workspace list's `current_directory` is a fallback ONLY in workspace mode; in tab mode there is no per-surface cwd field and the container workspace's directory would be a wrong-but-plausible answer, so tab mode is tty-or-empty. See "Live-cwd tracking" below - the JSON field alone verifiably fails the treehouse case. |
| Busy state | forward-compatible `agent_status` probe on the workspace list | NO machine-readable agent-state field exists in 0.64.17's workspace list (the sidebar's busy cue rides the opt-in auto-naming title's spinner glyph, which is presentation-bound and never parsed), so busy state reports unknown and the watcher uses its shared tail-regex fallback, exactly like tmux. If a future cmux exposes `agent_status`, the mapping is ready: `working` -> busy; `idle`/`done` -> idle; `waiting`/`blocked` -> idle (stuck on the human - surfaced like a stale pane, not suppressed as busy). |
| Kill | `cmux close-surface --workspace <ws> --surface <sf>` (tab mode) / `cmux close-workspace --workspace <ws>` (workspace mode) | Verified for both; closing an already-closed surface or workspace exits non-zero (`not_found`), matching tmux's `kill-window \|\| true` best-effort contract. Tab mode never closes the container workspace. |

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

Beyond the fake-CLI unit tests (`tests/fm-backend-cmux.test.sh`), the full firstmate lifecycle was driven end to end against a real `claude` crewmate through this branch's own scripts, in a scratch `FM_HOME` and a scratch `local-only` git project, ONCE PER CONTAINER SHAPE in the captain's running cmux app:

**Tab mode (default):** spawned with firstmate running inside cmux, so the task became an `fm-<id>` tab in firstmate's own workspace (target `cmux:<ws>:<surface>`; meta recorded both `cmux_workspace_id=` and `cmux_surface_id=`); `fm-peek`/`fm-send` routed through the surface flags; the crewmate branched, committed, and reported `done`; teardown REFUSED the unlanded work, `fm-merge-local.sh` landed it, and the second teardown closed ONLY the task's tab - every other tab in the captain's workspace was verified untouched.

**Workspace mode** (`config/cmux-container` = `workspace`), the original pass:

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
