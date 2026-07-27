---
name: harbor-watch
description: >-
  Agent-only owner of harbor watch: observe-and-escalate supervision of the captain's own opted-in cmux tabs.
  Load on any check wake from state/harbor-watch.check.sh, before opting one of the captain's tabs in or out of harbor watch or listing watches, and before relaying a harbor-watch escalation to the captain.
user-invocable: false
metadata:
  internal: true
---

# Harbor watch - the captain's own tabs, observed and escalated

Harbor watch lets the captain opt individual tabs of his own cmux terminal into firstmate supervision.
The sweep (`bin/fm-harbor-watch.sh sweep`, run as the registered custom check `state/harbor-watch.check.sh`) detects a blocked watched tab and wakes firstmate; firstmate reads the event and escalates to the captain.
The design and captain decision live in the primary home's `data/fm-tab-watch-s7/` (report and `decision-harbor-watch-adoption.md`); the watch-file schema is owned by `docs/configuration.md` "Harbor watch"; sweep, verb, and file mechanics are owned by `bin/fm-harbor-watch.sh`'s header.

## Hard contract this wave: observe only

Wave 1 sends ZERO keystrokes.
Never send input to, approve, dismiss, focus, rename, or otherwise mutate a watched tab or its notifications - not through `fm-send`, the cmux CLI, or any other path.
Every detected prompt is escalated to the captain; firstmate answers none of them, whatever the prompt says.
Auto-approval (starting with a narrow read-only class) is wave 2, and switching it on is captain-gated on his review of wave-1 evidence; the `classes` array in the watch file exists for that future and is ignored by this wave's sweep.
If the captain asks for auto-approval now, record the request as a captain decision for the wave-2 task instead of improvising it here.

## Opting a tab in ("watch the OpenCode tab")

1. Resolve the phrase to one live tab, read-only: `cmux workspace list --json --id-format uuids --window <id>` per window from `cmux list-windows --json --id-format uuids`, then `cmux list-pane-surfaces --workspace <uuid> --json --id-format uuids` for candidate workspaces.
2. One confident match proceeds; several plausible tabs get one concise question listing them by workspace and title.
3. `bin/fm-harbor-watch.sh add --workspace <workspace title> --surface <surface uuid>` - the script verifies the tab is live, captures identity (machine, titles, uuid, time), and writes the entry atomically.
4. If this is the first watch, arm the sweep (below).
5. Confirm to the captain in his nouns: which tab is now watched and that he will be pinged when it needs him.

`add` refuses a surface that is already watched (active or not); re-confirmation is `remove` then a fresh `add`.

## Opting out ("stop watching X")

`bin/fm-harbor-watch.sh remove <id>` takes effect immediately and also cancels that tab's pending escalation dedupe state.
When the last entry is removed, disarm the sweep (below).
`bin/fm-harbor-watch.sh list` prints the watch list; include it when the captain asks what is being watched (Bearings included).

## Arming and disarming the sweep

The sweep runs as a registered custom check inside the home's existing single supervision cycle - never as a second watcher.
`bin/fm-harbor-watch.sh arm` is idempotent: it (re)writes the byte-static shim `state/harbor-watch.check.sh` and binds it through `bin/fm-check-register.sh`.
Run it after the first `add`, and re-run it any time the shim is reported rejected (an edited shim needs re-binding).
`bin/fm-harbor-watch.sh disarm` removes the shim, its trust binding, and the dedupe ledger; run it when the watch list is empty.
Detection latency is the check cadence (`FM_CHECK_INTERVAL`, default 300s): tell the captain "within about five minutes", never "instantly".

## Handling a harbor-watch wake

A wake reads `check: .../harbor-watch.check.sh: <event lines>`, one event per line:
`<class> watch=<id> tab="<workspace> › <tab title>" detail="<evidence>"`.
Dedupe is already applied - every line is new since the last escalation of that same prompt, so act on each:

- `permission`, `decision`, `credential` - the tab's agent is BLOCKED on the captain; escalate immediately (coalesce several lines from one tab into one message).
- `waiting`, `error` - not blocking a dialog; batch into the next natural reply or heartbeat digest.
- `mismatch` - run the re-confirmation flow below.
- `unreadable`, `cmux-unreachable`, `config-error`, `sweep-truncated` - the watch itself degraded; fix what firstmate can (a broken watch file, a closed cmux) and tell the captain only if his action is needed or a watched tab is going unobserved.

## Escalation payload

Every escalation must let the captain decide at a glance, in his nouns, per AGENTS.md section 9:

1. Which tab: workspace plus tab title, e.g. "your OpenCode tab (OC | Pipeline skill intake)".
2. What the agent is asking, verbatim: the `detail` field carries the dialog's own text - relay it as a quote.
   A `credential` event carries no screen text by design (the surrounding screen may hold secrets); say a login or credential prompt is waiting and never quote or reconstruct it.
3. Why firstmate did not handle it: this wave observes only ("I watch this tab but don't answer prompts for you yet").
4. The consequence of yes/no in one line, and a recommendation when the dialog text supports one.

Do not re-escalate a prompt the captain has already seen unless the event line fired again (the dedupe ledger re-arms only when the prompt clears or changes).

## Identity mismatch and re-confirmation

A watch is bound to its surface uuid under its workspace title; titles auto-retitle and cmux relaunches reset every uuid, so a `mismatch` event means the sweep could not prove the watched tab is still the same tab.
The sweep has already set the entry inactive - observation of that tab has STOPPED and never migrates on a guess.
Escalate it as: which tab was being watched, what changed (closed, moved workspace, or a cmux restart), and ask whether to re-confirm.
On the captain's confirmation, resolve the tab fresh (opt-in steps 1-3: `remove` the stale entry, `add` the newly resolved one).
Never reactivate or re-add without the captain naming the tab again.

## Audit log

`state/harbor-watch.log` is the append-only record of every add, remove, arm, disarm, deactivation, and escalated event, written by the script.
Never rewrite or prune it; read it when the captain asks what harbor watch saw or did.
