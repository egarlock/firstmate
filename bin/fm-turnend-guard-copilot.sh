#!/usr/bin/env bash
# GitHub Copilot CLI agentStop adapter for the firstmate PRIMARY turn-end guard.
#
# Registered in tracked .github/hooks/fm-primary-turnend-guard.json, which
# Copilot loads from the git root of a trusted folder. Copilot awaits the hook
# at every turn end and reads one decision object from stdout: a
# `{"decision":"block","reason":...}` object keeps the agent working and
# submits the reason as the next prompt, while a bare exit 2 is ignored
# (verified live, Copilot CLI 1.0.88). This adapter therefore asks the shared
# guard with --copilot and renders its exit 2 as that object, carrying the
# guard's banner as a typed turn-end-guard operational input so the forced
# turn is never read as a captain message.
#
# Loop bounds: the payload's own `stop_hook_active` is true on the stop that
# follows a forced continuation, and the shared guard always allows that stop,
# so one turn yields at most one continuation; Copilot itself also ends the
# turn after 8 consecutive blocks.
#
# Every path exits 0 and prints nothing or one JSON object: no payload, no jq,
# an allowing guard, or an unreadable result lets the turn end.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-copilot.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --copilot >/dev/null 2>"$ERR"
[ "$?" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
fm_operational_input_encode turn-end-guard "$REASON" PROMPT || exit 0
jq -n --arg reason "$PROMPT" '{decision: "block", reason: $reason}' 2>/dev/null || true
exit 0
