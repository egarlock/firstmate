Mode: Copilot attached short-wait background supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: arm with Copilot's shell tool, as its own call, with a short `initial_wait` and its own `shellId`:

   `bash` with `initial_wait: __FM_COPILOT_INITIAL_WAIT__` and `detach` omitted, on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. The arming call MUST return promptly so the turn can end.
   Copilot queues everything the captain types while a model turn is active, and an attached shell call holds the turn open for its entire `initial_wait`.
   `bin/fm-watch-arm.sh` blocks for the whole watcher cycle, which is unbounded, so a long `initial_wait` pins the turn open and the captain's chat silently queues until the call ends.
   `initial_wait: __FM_COPILOT_INITIAL_WAIT__` is the confirmation budget only: it is just past `FM_ARM_CONFIRM_TIMEOUT` so the arm's honest status line is visible, and short enough that chat stays responsive.
   It is capped at 30 seconds, so raising `FM_ARM_CONFIRM_TIMEOUT` past 25 no longer widens it; past the cap the status line may not have printed when the call returns.
   Some Copilot builds enforce a minimum `initial_wait` and silently raise a smaller value, which is harmless here because the hold stays short and bounded either way.
   Never raise it to cover the watcher cycle.
5. Never set `detach: true` for the arm.
   A detached arm outlives this session, which breaks the arm's own contract that killing the arm tears its watcher down too.
6. Never use shell `&` for firstmate supervision.
7. Never bundle the arm onto another command.
   Copilot has no tracked PreToolUse seatbelt, so nothing rejects a bundled or backgrounded arm before it runs.
8. Trust only the arm's one-line status.
   If the call returns before any `watcher:` line appears, read the arm's output with `read_bash` on its `shellId` until one does; never treat a silent return as either success or failure.
9. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
10. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
11. After a successful start or attach status, end the turn.
    The arm keeps running in the background as the live wait until it returns an actionable wake or failure.
12. Waiting is silent.

Copilot raises a shell-completion notification when the backgrounded arm exits, and that notification starts a new turn.
When you see the arm's completion notification:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally read the arm's remaining output with `read_bash` on the arm's `shellId` for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same short-`initial_wait` arm call if work remains in flight or X mode still needs polling.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

Copilot has no tracked primary integration: no turn-end guard, no session-start nudge, and no PreToolUse seatbelt.
Its hook surface is `${COPILOT_HOME:-$HOME/.copilot}/hooks`, outside this repository, so wiring those backstops is a global-file trust decision the captain has not made; [`turnend-guard.md`](../turnend-guard.md) records the current gap.
The only push backstop other harnesses get is therefore absent here, so this protocol plus the pull-based `bin/fm-guard.sh` warning is the whole safety net.
The firstmate-owned `agentStop` hook that a copilot crewmate spawn installs is the crewmate turn-end token hook and does not supervise a copilot primary.
