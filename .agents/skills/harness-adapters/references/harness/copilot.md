# GitHub Copilot CLI

GitHub Copilot CLI's interactive TUI, verified end to end on 2026-09-25 and 2026-09-26 with Copilot CLI 1.0.88 on macOS through the tmux backend, as a crewmate, scout, primary, and secondmate.
[Verification evidence](../../../../../docs/verification/copilot.md) and its live guards refresh the vendor facts below.

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
| Marker | `COPILOT_CLI=1` in every tool and hook process, beside `COPILOT_PROJECT_DIR`; Copilot does not clear an inherited `CLAUDECODE`, so `../../../../../bin/fm-harness.sh` tests it first. |
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

Primary supervision is the attached async background arm in `../../../../../docs/supervision-protocols/copilot.md`: the arm returns at once, one `read_bash` collects its status line, and the arm's exit makes Copilot submit its own `<system_notification>` follow-up turn.
While the arm runs, the idle row reads `Waiting for background shells · <bytes> esc interrupt` and the captain's prompts are answered at once, which is why `../../../../../bin/fm-composer-lib.sh` does not read that row as busy.
Copilot loads the home's tracked `.github/hooks/` registrations only in a trusted folder: trust it when the primary starts, and a secondmate launch trusts its home through `COPILOT_ALLOW_ALL=true`.
Those registrations anchor through `COPILOT_PROJECT_DIR`, preferring the session's own spelling of that directory, and run `agentStop` through `../../../../../bin/fm-turnend-guard-copilot.sh` and `sessionStart` through `../../../../../bin/fm-sessionstart-copilot.sh`; `../../../../../docs/turnend-guard.md` and `../../../../../docs/sessionstart-nudge.md` own their contracts.
Copilot also runs the tracked `.claude/settings.json` entries with Claude-shaped payloads: the Stop, SessionStart, and dialog-mirror entries stand down there, while the PreToolUse seatbelts keep denying because Copilot honors their exit 2.
The session lock resolves to the `copilot` process, which is the direct parent of every tool and hook command.
Do not run a primary as one-shot `copilot -p`.
