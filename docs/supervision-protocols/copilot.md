Mode: Copilot attached async background supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: arm with Copilot's `bash` tool, as its own call, in the background:

   `bash` with `mode: "async"`, `detach` omitted, and its own `shellId`, on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

3. The arming call must return at once so the turn can end.
   Copilot queues everything the captain types while a turn is active, and `bin/fm-watch-arm.sh` blocks for the whole watcher cycle, so never arm it with the default synchronous mode or an `initial_wait`: either holds the turn open and silently queues the captain's chat.
4. Never set `detach: true` for the arm.
   An attached async shell keeps running across later turns and ends with the session, which is the arm's own contract that ending the arm tears its watcher down too; a detached arm outlives the session.
5. Never use shell `&` for firstmate supervision.
6. Never bundle the arm onto another command.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`), which Copilot runs from this project's tracked Claude settings.
7. Trust only the arm's one-line status.
   Collect it with exactly one `read_bash` on the arm's `shellId` with `delay: __FM_COPILOT_READ_DELAY__`, just past the arm's confirmation budget.
   Do not poll in a loop or use a longer delay: `read_bash` holds the turn open the same way a synchronous call does.
   If that single read still shows no `watcher:` line, treat supervision as unconfirmed, say so, and re-arm rather than assuming either success or failure.
8. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
9. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
10. After a successful start or attach status, end the turn.
    The background arm remains the live wait until it returns an actionable wake or failure.
11. Waiting is silent.
12. Run the drain and every other supervision command synchronously with an `initial_wait` long enough for it to finish, such as 120.
    A synchronous call that outlives its `initial_wait` keeps running in the background, and a turn that ends before it finishes and before the arm is re-armed ends blind.

Copilot submits a follow-up turn of its own when the background arm exits.
When that turn reports the arm's shell completed:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally read the arm's remaining output with `read_bash` on its `shellId` for the reason line.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same async arm call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The primary project `agentStop` hook runs `bin/fm-turnend-guard-copilot.sh` as a backstop, not the normal wake path.
When it finds no live watcher it keeps the turn going with one typed turn-end-guard prompt; arm the watcher with the async protocol above before ending that turn.
Copilot holds that prompt in its queue while any background shell is still running and delivers it when the shell ends, so it can arrive after the watcher is already healthy; re-arming then attaches to the live cycle, and the prompt needs nothing else.
[`turnend-guard.md`](../turnend-guard.md) owns its loop bounds.

Interactive sessions are the supported Copilot primary surface, started in a trusted home folder so its hooks load.
Do not run the primary firstmate as a one-shot `copilot -p` process, which ends before a background arm can deliver a wake.
