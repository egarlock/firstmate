#!/usr/bin/env bash
# Write a private per-task GitHub Copilot CLI plugin carrying the worker's
# lifecycle hooks.
# Usage: fm-copilot-plugin.sh <state-dir> <task-id> <busy-gen>
# Output: <state-dir>/<task-id>.copilot-plugin/ holding plugin.json and
# hooks.json, private to the user and replaced whole on every call. The launch
# mounts it with --plugin-dir, so no user, project, or global Copilot config is
# edited and the hooks exist only for this worker's process.
# userPromptSubmitted opens a turn; agentStop closes it and touches the task's
# turn-ended marker; sessionEnd closes it. Copilot emits no hook when Ctrl+C
# cancels a running turn, so fm-control invalidates the state to unknown after
# delivering that interrupt, never fabricating idle. Every event is bound to
# the generation armed at spawn, so a hook that outlives its incarnation is
# rejected as stale and emits no notification.
# fm-control-lib.sh owns retirement of the two files.
set -eu
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory required}
ID=${2:?task id required}
GEN=${3:?busy generation required}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source copilot-hook"
submit="$prefix busy $suffix --event user-prompt-submitted >/dev/null 2>&1 || true"
stop="$prefix idle $suffix --event agent-stop >/dev/null 2>&1 && touch $(quote "$STATE/$ID.turn-ended"); true"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true"
DEST="$STATE/$ID.copilot-plugin"
umask 077
temp=$(mktemp -d "$STATE/.$ID.copilot-plugin.XXXXXX")
trap 'rm -rf "$temp"' EXIT
jq -n '{name: "firstmate-worker", version: "1.0.0", description: "Firstmate worker lifecycle hooks", hooks: "hooks.json"}' > "$temp/plugin.json"
jq -n --arg submit "$submit" --arg stop "$stop" --arg end "$end" '
  def hook($cmd): [{type: "command", bash: $cmd, timeoutSec: 10}];
  {version: 1, hooks: {userPromptSubmitted: hook($submit), agentStop: hook($stop), sessionEnd: hook($end)}}
' > "$temp/hooks.json"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  [ -d "$DEST" ] && [ ! -L "$DEST" ] || { echo "error: $DEST is not a plugin directory" >&2; exit 1; }
  rm -f "$DEST/plugin.json" "$DEST/hooks.json"
  rmdir "$DEST"
fi
mv "$temp" "$DEST"
trap - EXIT
