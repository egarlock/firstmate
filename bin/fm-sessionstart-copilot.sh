#!/usr/bin/env bash
# GitHub Copilot CLI session-open adapter: the RUN tier transport for Copilot.
#
# Registered in tracked .github/hooks/fm-primary-sessionstart.json for
# Copilot's native `sessionStart` event, which Copilot loads from the git root
# of a trusted folder. It is a thin transport around bin/fm-sessionstart-run.sh,
# which remains the single owner of source routing, eligibility, and the digest
# itself.
#
# Copilot injects a sessionStart hook's `additionalContext` string into model
# context before the model answers the prompt that opened the session (verified
# live, Copilot CLI 1.0.88). An interactive session fires the event when its
# first prompt is submitted, so the helm is taken before the first reply.
#
# Source routing: the payload's `source` is `new` for a fresh session and
# `resume` for a resumed one; anything else, including an unreadable payload,
# is passed through for the run wrapper to treat as a startup.
#
# Every path exits 0 and prints either nothing or one JSON object, so a failed
# session start reaches the agent as digest text rather than a refused session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat 2>/dev/null || true)
SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type == "object" and (.source | type) == "string" then .source else "" end
' 2>/dev/null || true)
case "$SOURCE" in
  new) SOURCE=startup ;;
  ''|*[!a-z]*) SOURCE=startup ;;
esac

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$SOURCE" </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
jq -n --arg c "$DIGEST" '{additionalContext: $c}' 2>/dev/null || true
exit 0
