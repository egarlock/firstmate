#!/usr/bin/env bash
# The watcher arm's default confirmation budget, shared by bin/fm-watch-arm.sh,
# which waits that long for a freshly forked watcher to acquire the lock and
# beat, and bin/fm-supervision-instructions.sh, which renders a harness's status
# read to land just after it. Sourced by both; no side effects on source.

# fm_arm_confirm_default
# Print the default confirmation budget in seconds for this platform. Git
# Bash/MSYS pays a much higher fork cost while the watcher completes its
# required pre-lock migration, so its bounded default covers that cold start.
fm_arm_confirm_default() {
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*) printf '30\n' ;;
    *) printf '10\n' ;;
  esac
}
