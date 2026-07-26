Mode: Copilot background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run `bin/fm-watch-arm.sh` as its own Copilot Bash tool call.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelts (`bin/fm-arm-pretool-check.sh`, `bin/fm-cd-pretool-check.sh`, and `bin/fm-continuity-pretool-check.sh`) configured in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the arm call follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: when the arm call completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, then start exactly one fresh arm call before running other fleet commands to handle the wake.
   Do not invent a wake from an attach-status line alone.
   Drain and act only on real wake records or a real watcher reason line.
9. The continuity PreToolUse gate allows wake drain, session start recovery, watcher arm recovery, and fail-closed teardown, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
10. The existing turn-end guard remains unchanged as the final backstop and is not replaced by this command gate.
11. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Copilot Bash tool mechanism.
12. Do not send idle progress while the arm call is parked.

Copilot CLI keeps the tracked arm call alive across turns and emits a shell-completion notification when that call exits.
The watcher remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Copilot primary sessions currently consume the same PreToolUse hook registration in `.claude/settings.json`.
This repo has no copilot-specific PreToolUse registration path for the primary session.
Copilot-specific hook registration in `bin/fm-spawn.sh` is for spawned copilot crewmates and secondmates, via global `agentStop` hooks under `${COPILOT_HOME:-$HOME/.copilot}/hooks`.

Verification on 2026-07-26 used GitHub Copilot CLI 1.0.75 in this worktree.
Command: `bin/fm-watch-arm.sh`.
Observed output after arm and wake: `watcher: started pid=73799 (beacon fresh)` then `signal: .../state/fix-login-k3.status .../state/copilot-evidence.status`.
Observed harness notification: shell completion arrived as `<system_notification> Shell command "Run watcher arm command as standalone tool call" (shellId: watcharm-live) has completed successfully.`
Command: `bin/fm-watch-arm.sh | head -n 1`.
Observed output: `Denied by preToolUse hook: hook exited with code 2`.
Command: `bin/fm-arm-pretool-check.sh --claude --command 'bin/fm-watch-arm.sh | head -n 1' 2>&1`.
Observed output: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[watcher-pipeline] a protected watcher command must not participate in a pipeline"}`.
Command: `grep -n 'fm-arm-pretool-check\|fm-cd-pretool-check\|fm-continuity-pretool-check' .claude/settings.json`.
Observed output includes lines 20, 24, and 28, each registering those commands.
Command: `grep -n 'COPILOT_HOOKS_DIR\|agentStop\|fm-turn-end.json\|\.fm-copilot-turnend' bin/fm-spawn.sh`.
Observed output includes copilot-specific `agentStop` hook wiring at lines 1221 to 1253, scoped to spawned copilot sessions.
Command: `find . -type f -name '*.json' -path './.copilot/*' -print`.
Observed output: no matches.
Command: `tail -n 3 state/.watch-cycle-exits.log`.
Observed output includes a cycle row with `reason=actionable-signal`, confirming arm-layer lifecycle logging.
