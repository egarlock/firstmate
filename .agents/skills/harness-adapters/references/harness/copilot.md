# GitHub Copilot CLI

GitHub Copilot CLI's interactive TUI, verified end to end on 2026-09-25 with Copilot CLI 1.0.88 on macOS through the tmux backend.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported, and `../../../../../bin/fm-spawn.sh` refuses a secondmate launch because `../../../../../docs/supervision-protocols/` carries no copilot wake protocol.
[Verification evidence](../../../../../docs/verification/copilot.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Launch command | The configured launch command (`config/copilot-cmd`, default `copilot`) is an opaque executable prefix; `../../../../../bin/fm-copilot-lib.sh` owns its parsing, resolution, and the version gate. |
| Launch | `COPILOT_ALLOW_ALL=true <launch command> --plugin-dir <private plugin> --allow-all --no-ask-user [--model <id>] [--reasoning-effort <level>] -i "<brief>"`; `-i` submits the brief as the first turn of an interactive session. |
| Busy state | Semantic `copilot-hook` from the private plugin: `userPromptSubmitted` opens a turn, `agentStop` and `sessionEnd` close it; `../../../../../bin/fm-busy-lib.sh` owns trust. |
| Turn end | `agentStop` also touches the task's turn-ended marker after a successful generation-bound apply. |
| Background shells | `agentStop` closes a turn even while Copilot still waits for a background shell the model started; when that shell finishes Copilot submits its own follow-up turn, which fires `userPromptSubmitted` and reopens busy. An idle verdict in that window means the model yielded, not that no further work will run. |
| Rendered tail | Busy status row: a spinner glyph, `Working` or `Waiting for background shells`, an optional ` · <bytes>` counter, and `esc interrupt`; the idle row shows `← open sidebar · / commands · ? help`. `../../../../../bin/fm-composer-lib.sh` owns the delivery-only signals. |
| Composer | Bare `❯` glyph row between horizontal rules, the Claude shape; the live styled idle screen classifies `empty`. |
| Interrupt | One `Ctrl+C` cancels a running turn, marks the running tool `Operation aborted by user`, and leaves an empty composer; no hook fires, so the control plane invalidates busy state to `unknown`. An `Escape` delivered through tmux does not cancel. |
| Idle Ctrl+C | One `Ctrl+C` on an idle agent only arms `ctrl+c again to exit`; a second within that window exits, so never pair presses. |
| Exit | `/exit`, with the shared slash-command settle before Enter; prints `copilot --resume=<session-id>` and fires `sessionEnd`. |
| Resume | `--resume=<session-id>` or `--continue` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Skill | `/<skill>`, for example `/no-mistakes`; `fm-send` types the slash form through its popup settle, and Copilot discovers project `.agents/skills` and personal `~/.agents/skills` at launch. |
| Model | `--model <id>`, including `auto`; discover through the interactive `/model` picker, since the CLI has no model-listing subcommand. |
| Effort | `--reasoning-effort low\|medium\|high\|xhigh\|max`, the full shared vocabulary; 1.0.88 no longer lists the older `--effort` alias. |
| Marker | None verified; own-harness detection is outside this adapter. |
| Process name | The native executable named `copilot` (1.0.88: `ps -o comm=` is its versioned install path ending in `/copilot`); liveness anchors that exact name. |

## Trust and autonomy

Every task worktree is a folder Copilot has never seen, so a launch without `COPILOT_ALLOW_ALL=true` stops on a `Confirm folder trust` dialog even with `--allow-all`.
`COPILOT_ALLOW_ALL=true` trusts the working directory for that process and also loads the directory's own skills, plugins, MCP servers, and hooks, the same trust a worker already extends to the project it edits.
The `../../../../../bin/fm-busy-lib.sh` launch-prompt backstop recognizes the dialog if it renders anyway; never steer into a pane still showing it.
`--no-ask-user` removes the tool that would park an unattended worker on a question.

## Hooks and wiring

`../../../../../bin/fm-copilot-plugin.sh` writes the private per-task plugin directory the launch mounts with `--plugin-dir`, so no user, project, or global Copilot configuration is edited.
Hook commands run with the plugin directory as their working directory and inherit the launch environment.
`../../../../../bin/fm-control-lib.sh` retires the plugin's files on a relaunch that changes harness, and teardown removes the directory.
The per-task git hooks path already strips the `Co-authored-by: Copilot` trailer the CLI adds to worker commits.

## Configured launch command

`config/copilot-cmd` replaces the executable prefix with a configured launch command.
Firstmate treats that command as opaque: it resolves only the first word to an executable, appends its own flags and the brief, and requires only that `--version` report a GitHub Copilot CLI version.
Verify a new launch command with the live guard before relying on it.

## Primary integration

No primary Stop guard, watcher protocol, session lock ancestry, or session-start contract was verified for Copilot.
Do not launch a primary or secondmate with this adapter.
