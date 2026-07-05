---
name: showdevsetup
description: Show a live, read-only snapshot of the captain's dev setup. Use when the captain invokes /showdevsetup (e.g. "/showdevsetup", "show my dev setup", "what state are my repos and no-mistakes in"). Re-scans the operating firstmate repo, every project clone, the canonical no-mistakes checkout, and the treehouse sibling on every invocation, then checks the no-mistakes binary wiring (CLI on PATH, GOPATH binary, symlink target) with an explicit PASS/DRIFT verdict. Writes nothing anywhere.
user-invocable: true
---

# showdevsetup

Show the captain a live snapshot of their dev setup.
This is a pure read: every invocation re-scans the real repos and binaries, so the printout is always the current truth - there is no cache to go stale and nothing is ever written (no state/, no data/, no projects/, no fetches).
The load-bearing part is the no-mistakes binary wiring check: no-mistakes is compiled Go, so the CLI on PATH, its symlink target in the canonical checkout, and the GOPATH binary the daemon runs can silently drift apart after a partial rebuild - this skill catches that split at a glance.

## What it does

1. **Run the scanner:**
   ```sh
   bin/fm-show-dev-setup.sh
   ```
   It prints a readable tree covering:
   - the operating firstmate repo (`$FM_ROOT`),
   - every clone under `projects/`,
   - the canonical no-mistakes checkout (the `no-mistakes.git` sibling of the firstmate root, overridable via `FM_NM_CANONICAL`), flagged when behind its `origin/main` tracking ref,
   - the treehouse sibling checkout when present.

   Each repo shows its origin URL (flagging whether it is the captain's `egarlock/*` fork), its branch and upstream tracking ref, the HEAD one-line, and a dirty flag.
   It ends with the no-mistakes binary wiring section: the CLI on PATH (and its resolved symlink target), the GOPATH binary, the running daemon pid, each binary's version, and a `PASS`/`DRIFT` verdict on whether they all report the same commit.
   Missing pieces print `(absent)`/`(not running)` instead of erroring.

2. **Relay the snapshot to the captain.**
   The tree itself is the deliverable - show it as printed.
   Lead with anything that needs attention in plain outcome language: a `DRIFT` verdict (the installed gate binaries disagree - suggest `/updatenomistakes` to reconverge), a dirty or behind checkout, or a repo whose origin is not the expected fork.
   When everything is `PASS` and clean, one line saying so is enough.

## Safety

- **Strictly read-only.**
  The script writes nothing anywhere - no `state/`, no `data/`, no `projects/`, no fetches, stdout only - so it is safe to run at any time, including while crewmates are live.
- The "behind origin/main" flag is as of the last fetch; the scan never fetches to refresh it.
