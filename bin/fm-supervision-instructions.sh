#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-harness-policy.sh
. "$SCRIPT_DIR/fm-harness-policy.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

# A verified adapter renders its own protocol; everything else, including a
# verified adapter whose snippet is missing, falls back to unknown.md with a
# matching heading. The allowlist lives only in bin/fm-harness-policy.sh, so
# adding an adapter there cannot silently leave it on the generic fallback.
# pi-signed shares pi's engine and reuses pi's protocol snippet.
if [ "$HARNESS" = pi-signed ] && [ -f "$DOC_DIR/pi.md" ]; then
  SNIPPET="$DOC_DIR/pi.md"
elif fm_harness_is_verified "$HARNESS" && [ -f "$DOC_DIR/$HARNESS.md" ]; then
  SNIPPET="$DOC_DIR/$HARNESS.md"
else
  HARNESS=unknown
  SNIPPET="$DOC_DIR/unknown.md"
fi

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
# Copilot's arming tool call must outlive fm-watch-arm.sh's confirmation budget
# so the model sees the honest started/attached/FAILED line, and must return
# immediately after it so the turn can end and captain chat stays responsive.
# FM_ARM_CONFIRM_TIMEOUT is owned by bin/fm-watch-arm.sh; this only adds margin.
# The result is then capped. FM_ARM_CONFIRM_TIMEOUT is an operator knob for slow
# hosts, and propagating a large value uncapped would render a multi-minute
# attached call into the protocol, the repair line, and the wake line, which is
# exactly the blocked-chat incident this protocol exists to prevent. Past the cap
# the arm's status line may not have printed when the call returns, so the
# protocol tells the model to read it rather than assume a result.
COPILOT_MAX_INITIAL_WAIT=30
copilot_confirm=${FM_ARM_CONFIRM_TIMEOUT:-10}
case "$copilot_confirm" in
  # Anything that is not a plain, small, base-10 integer is unusable, and each
  # rejected shape escapes the cap below in its own way. A leading zero is read
  # as octal, so "08" aborts this whole script under `set -eu` and takes the
  # supervision block for EVERY harness with it, not just copilot. A value long
  # enough to overflow the addition wraps negative, and a negative value passes
  # the -le test and renders as the wait verbatim.
  ''|*[!0-9]*) copilot_confirm=10 ;;
  0[0-9]*) copilot_confirm=10 ;;
  ??????????*) copilot_confirm=10 ;;
esac
copilot_initial_wait=$((copilot_confirm + 5))
[ "$copilot_initial_wait" -le "$COPILOT_MAX_INITIAL_WAIT" ] \
  || copilot_initial_wait=$COPILOT_MAX_INITIAL_WAIT
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_COPILOT_INITIAL_WAIT__/$copilot_initial_wait}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    printf '%s\n' "$line"
  done < "$SNIPPET"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    copilot)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own attached Copilot shell call with initial_wait ' "$copilot_initial_wait" ', never detached and never shell &.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
      ;;
    copilot)
      printf '%s%s%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh attached Copilot shell call with initial_wait ' "$copilot_initial_wait" ' as directed below; the call must return promptly so the turn can end.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
ordinary_wake_line
printf '\n'
render_snippet
printf '\n'
