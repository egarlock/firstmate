---
name: updatenomistakes
description: Adopt the latest of the captain's no-mistakes fork into the running gate. Use when the captain invokes /updatenomistakes (e.g. "/updatenomistakes", "update no-mistakes", "pull the latest no-mistakes"). Fast-forwards the canonical no-mistakes checkout from origin/main (fast-forward only, never forced, never stashed), rebuilds and reinstalls the compiled binary via make install (which restarts the daemon), and verifies the CLI, GOPATH binary, and symlink target all report the new commit. Refuses on a dirty checkout or while a pipeline run is active.
user-invocable: true
metadata:
  internal: true
---

# updatenomistakes

Update the running no-mistakes gate to the latest of the captain's fork.
Unlike firstmate, no-mistakes is compiled Go, so a pull alone changes nothing: the canonical checkout must be pulled, rebuilt, and reinstalled before the running gate actually changes.
This skill performs that whole adopt - pull, `make install`, and a three-way binary verification - refusing up front in the situations where it could destroy work.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update-nomistakes.sh
   ```
   It locates the canonical no-mistakes checkout (the `no-mistakes.git` sibling of the firstmate root, overridable via `FM_NM_CANONICAL` - the same resolution `/showdevsetup` uses), then:
   - **refuses** if that checkout has uncommitted changes (never bypassable);
   - **refuses** if it is on any branch other than `main`;
   - **refuses** if a no-mistakes pipeline run is active anywhere, because `make install` restarts the daemon and would kill a crew mid-validation (detected by a read-only query of the daemon's run database; if the state cannot be determined it also refuses, and `--force` is the explicit opt-in for both cases);
   - pulls with `git pull --ff-only origin main` - explicit `origin`, never the tracking ref, never forced, never stashed;
   - stops with "already current" when the checkout did not advance and the installed binaries already report HEAD; otherwise runs `make install` (build, install to GOPATH, daemon restart);
   - verifies the CLI on PATH, its symlink target, and the GOPATH binary all report the new HEAD commit, and fails loudly if they disagree.

   `--dry-run` runs every check and prints the pull/install commands without executing them.

2. **Report to the captain in plain outcomes.**
   On success: one line saying the gate is now on the new version, e.g. "Captain, no-mistakes is updated - the gate is now running `<short-sha>` (`<subject>`)."
   On a refusal, relay the reason as the captain's decision to make: work in progress in the checkout, or a validation currently running that the update would kill (offer to retry once it finishes, or `--force` only on the captain's explicit say-so).
   On a verify failure, the gate may be split across binaries - run `/showdevsetup` and show the captain the wiring section.

## Safety

- **Fast-forward only.**
  The pull is `--ff-only` from an explicit `origin main`; it never forces, never stashes, never creates a merge commit, and never discards work.
- **A dirty checkout always refuses.**
  Uncommitted work in the canonical checkout is never touched, and no flag overrides that.
- **An active pipeline run refuses.**
  `make install` restarts the daemon, which kills any in-flight validation run in any repo; the script checks for active runs first and requires an explicit `--force` to knowingly proceed (also when the run state cannot be determined).
- **Narrow blast radius.**
  Only the canonical no-mistakes checkout, the installed binary, and the daemon are touched - never anything under `projects/` and never the firstmate repo.
