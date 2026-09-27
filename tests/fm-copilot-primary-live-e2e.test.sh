#!/usr/bin/env bash
# Opt-in live guard for GitHub Copilot CLI as a firstmate PRIMARY. Opt in with
# FM_COPILOT_PRIMARY_LIVE_E2E=1; it submits real prompts on the signed-in account.
#
# The Copilot primary integration rests on facts only the real Copilot CLI can
# answer: that the tracked .github/hooks registrations load in a trusted home,
# that a sessionStart hook's additionalContext reaches model context, that the
# session lock resolves to the Copilot process, that an agentStop block decision
# makes Copilot submit its reason as the next prompt with the typed marker
# intact, that an attached async shell survives the turn and its exit starts a
# follow-up turn, that the captain can still chat while it runs, and that an
# away-mode escalation typed into the idle pane is delivered and read as marked.
# A stub can only confirm the assumption written into it, so this drives the
# installed CLI end to end. tests/fm-copilot-primary.test.sh is the portable
# regression; run this after every Copilot upgrade and before trusting refreshed
# evidence in docs/verification/copilot.md.
#
# FM_COPILOT_LIVE_CMD, when set, is the launch command the primary is started
# with (default: the configured copilot from PATH), treated as opaque words.
# FM_COPILOT_MODEL chooses the model (default auto).
#
# Isolation: a throwaway firstmate home under a temp dir and a private tmux
# socket. The primary keeps the operator's real HOME for its sign-in, so Copilot
# records its own session state under ~/.copilot/session-state, keyed to this
# run's session; the guard reads that transcript and writes nothing there. It
# never runs against a live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_COPILOT_PRIMARY_LIVE_E2E copilot tmux jq git

REAL_TMUX=$(command -v tmux)
# shellcheck source=bin/fm-copilot-lib.sh
. "$ROOT/bin/fm-copilot-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-primary.XXXXXX")
# Copilot names its working directory by the physical path, so cleanup matches
# both spellings of this run's lab.
PHYSICAL_LAB=$(cd "$LAB" && pwd -P)
HOME_DIR="$LAB/home"
SOCKET="fm-copilot-primary-$$"
SESSIONS="${COPILOT_HOME:-$HOME/.copilot}/session-state"

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # A launcher that wraps the CLI can outlive its pane, so end every process
  # still running from this run's own throwaway home.
  pkill -f "$LAB/" >/dev/null 2>&1 || true
  [ -z "${PHYSICAL_LAB:-}" ] || pkill -f "$PHYSICAL_LAB/" >/dev/null 2>&1 || true
  sleep 1
  [ -n "${LAB:-}" ] && { rm -rf "$LAB" 2>/dev/null || { sleep 2; rm -rf "$LAB"; }; }
}
trap cleanup_all EXIT

mkdir -p "$LAB/config"
[ -z "${FM_COPILOT_LIVE_CMD:-}" ] || printf '%s\n' "$FM_COPILOT_LIVE_CMD" > "$LAB/config/copilot-cmd"
WORDS=()
while IFS= read -r word; do WORDS+=("$word"); done < <(fm_copilot_launch_words "$LAB/config")
[ "${#WORDS[@]}" -gt 0 ] || fail "the Copilot launch command did not resolve; this guard refuses to pass without the real harness"
COPILOT_VERSION=$(fm_copilot_version "${WORDS[@]}") \
  || fail "the Copilot launch command reported no version; refusing to claim a verified result"
printf 'harness: GitHub Copilot CLI %s\n' "$COPILOT_VERSION"
harness_fail() {  # <message>
  fail "$1 [harness: GitHub Copilot CLI $COPILOT_VERSION]"
}
LAUNCH=''
for word in "${WORDS[@]}"; do LAUNCH="$LAUNCH '$word'"; done

# A plain (non-worktree) checkout of the CURRENT working tree, reached through
# the temp dir's own spelling, which on macOS is a symlink, so the registrations'
# path anchoring is exercised against a real session.
mkdir -p "$HOME_DIR"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || harness_fail "could not stage the working tree into the throwaway home"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true
[ -f "$HOME_DIR/.github/hooks/fm-primary-turnend-guard.json" ] \
  || harness_fail "the working tree ships no Copilot hook registration; there is nothing to verify"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf '# Captain\n\nLive fixture home.\n' > "$HOME_DIR/data/captain.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"
PHYSICAL_HOME=$(cd "$HOME_DIR" && pwd -P)

: > "$LAB/started"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 220 -y 60 -c "$HOME_DIR" \
  "cd '$HOME_DIR' && env -u FM_TASK_ID FM_HOME='$HOME_DIR' COPILOT_ALLOW_ALL=true $LAUNCH --allow-all --no-ask-user --model '${FM_COPILOT_MODEL:-auto}'" \
  || harness_fail "could not start the private tmux server"

pane_text() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t primary 2>/dev/null; }

wait_for() {  # <seconds> <what> <command...>
  local limit=$1 what=$2 i=0
  shift 2
  while [ "$i" -lt "$((limit * 2))" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  printf 'pane at failure:\n%s\n' "$(pane_text | grep -v '^[[:space:]]*$' | tail -20)" >&2
  harness_fail "$what did not happen within ${limit}s"
}

submit() {  # <text>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t primary -l "$1"
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t primary Enter
}

pane_has() { case "$(pane_text)" in *"$1"*) return 0 ;; esac; return 1; }
tui_ready() { pane_has 'open sidebar'; }

# This run's own transcript: the session whose recorded working directory is
# the throwaway home.
EVENTS=
find_events() {
  local file
  while IFS= read -r file; do
    if jq -e --arg cwd "$PHYSICAL_HOME" 'select(.type == "session.start") | select(.data.context.cwd == $cwd)' \
      "$file" >/dev/null 2>&1; then
      EVENTS=$file
      return 0
    fi
  done < <(find "$SESSIONS" -name events.jsonl -newer "$LAB/started" 2>/dev/null)
  return 1
}
events() { jq -c '.' "$EVENTS" 2>/dev/null; }
count_events() {  # <jq-filter>
  events | jq -s "[.[] | select($1)] | length" 2>/dev/null
}
has_event() {  # <jq-filter>
  [ "$(count_events "$1")" -gt 0 ] 2>/dev/null
}
last_assistant_text() {
  events | jq -rs '[.[] | select(.type == "assistant.message") | .data.content | select(. != "")] | last // ""'
}
# A turn is over once its agentStop hook has answered and no later turn has
# started. The transcript decides this rather than the status row, because a
# continuation Copilot has queued behind a running background shell can keep
# that row busy after the turn itself has ended.
turn_idle() {
  pane_has '❯' || return 1
  [ -n "$EVENTS" ] || return 1
  [ "$(events | jq -rs '
    [.[] | select(.type == "assistant.turn_start" or .type == "user.message"
      or (.type == "hook.end" and .data.hookType == "agentStop"))] | last | .type // ""
  ')" = hook.end ]
}

wait_for 360 "the Copilot TUI" tui_ready

# --- 1. session start, detection, and the session lock -----------------------

submit "Answer from your session-start context. On one line and nothing else, reply with the exact directory path printed in the SESSION START header and the primary harness named in the supervision operating instructions. If the digest was truncated, finish it first as it tells you."
wait_for 30 "this run's Copilot transcript" find_events
wait_for 300 "the sessionStart hook" has_event '.type == "hook.end" and .data.hookType == "sessionStart"'
has_event '.type == "hook.end" and .data.hookType == "sessionStart" and ((.data.output.additionalContext // "") | contains("SESSION START"))' \
  || harness_fail "the sessionStart hook returned no digest as additionalContext; the tracked .github/hooks registration did not load or run"
pass "copilot primary: the tracked sessionStart hook returns the digest as additionalContext"

LOCK_PID=$(head -1 "$HOME_DIR/state/.lock" 2>/dev/null)
[ -n "$LOCK_PID" ] && [ "$(basename -- "$(ps -o comm= -p "$LOCK_PID" 2>/dev/null)")" = copilot ] \
  || harness_fail "the session lock must be held by the Copilot process itself (lock pid '$LOCK_PID')"
pass "copilot primary: the session lock resolves to the Copilot process"

wait_for 420 "the first reply" turn_idle
case "$(last_assistant_text)" in
  *"$HOME_DIR"*copilot* | *copilot*"$HOME_DIR"*) ;;
  *) harness_fail "the reply must quote the digest header and name copilot as the detected primary, got: $(last_assistant_text)" ;;
esac
pass "copilot primary: the digest reaches model context and names copilot as the primary"

# --- 2. the agentStop block and the async arm --------------------------------

# Supervision becomes needed only now, with no watcher running, so the next
# turn end must block.
cat > "$HOME_DIR/state/probe.meta" <<EOF
id=probe
project=probe
harness=copilot
backend=tmux
window=fm-probe-$$
EOF
BLOCKS_BEFORE=$(count_events '.type == "hook.end" and .data.hookType == "agentStop" and .data.output.decision == "block"')
submit "Reply with exactly OK-$$. The probe task is a test fixture: leave it alone, and do not attempt recovery or teardown, but do follow any Firstmate operational instruction that arrives."
wait_for 180 "an agentStop block" has_event '.type == "hook.end" and .data.hookType == "agentStop" and .data.output.decision == "block"'
[ "$(count_events '.type == "hook.end" and .data.hookType == "agentStop" and .data.output.decision == "block"')" -gt "$BLOCKS_BEFORE" ] \
  || harness_fail "the blind turn end did not block"
wait_for 60 "the block reason submitted as the next prompt" \
  has_event '.type == "user.message" and (.data.content | startswith("⁣FIRSTMATE_OP: v1 turn-end-guard: "))'
pass "copilot primary: a blind turn end blocks and the reason arrives as a typed turn-end-guard prompt"

wait_for 180 "an async watcher arm" has_event \
  '.type == "tool.execution_start" and .data.toolName == "bash" and .data.arguments.mode == "async" and (.data.arguments.command | contains("fm-watch-arm.sh"))'
has_event '.type == "tool.execution_start" and .data.toolName == "bash" and (.data.arguments.command | contains("fm-watch-arm.sh")) and .data.arguments.mode != "async"' \
  && harness_fail "the model armed the watcher synchronously, which holds the captain's chat"
wait_for 180 "the forced turn to end" turn_idle
watcher_alive() {
  local pid
  pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}
wait_for 60 "a live watcher after the turn ended" watcher_alive
pass "copilot primary: the forced turn arms the watcher as an attached async shell that outlives the turn"

# --- 3. the captain chats while the arm runs ---------------------------------

wait_for 60 "the background-shell idle row" pane_has 'Waiting for background shells'
WATCHER_PID=$(cat "$HOME_DIR/state/.watch.lock/pid")
! pane_text | grep -v '^[[:space:]]*$' | tail -6 | fm_busy_lines_match copilot \
  || harness_fail "the idle row beside a running background arm read busy"
submit "Reply with exactly PONG-$$ and nothing else, and run no tools."
wait_for 120 "the captain's reply during the background arm" pane_has "PONG-$$"
kill -0 "$WATCHER_PID" 2>/dev/null || harness_fail "answering the captain ended the background watcher"
pass "copilot primary: the captain is answered at once while the arm keeps running"

# --- 4. the arm's exit wakes the session -------------------------------------

# A captain-relevant status line is a real wake the watcher surfaces at once.
printf 'blocked [at=%s]: live fixture needs a decision\n' "$(date +%s)" >> "$HOME_DIR/state/probe.status"
wait_for 240 "Copilot's own follow-up turn when the arm exits" has_event \
  '.type == "system.notification" and (.data.content | contains("<system_notification>")) and (.data.content | contains("completed"))'
wait_for 180 "the wake drain" has_event \
  '.type == "tool.execution_start" and .data.toolName == "bash" and (.data.arguments.command | contains("fm-wake-drain.sh"))'
pass "copilot primary: the arm's exit starts a follow-up turn that drains the wake"

# --- 5. away-mode escalation delivery ----------------------------------------

wait_for 300 "the wake turn to end" turn_idle
: > "$HOME_DIR/state/.afk"
AWAY_TOKEN="AWAY_ACK_$$"
INJECT_RC=0
cat > "$LAB/inject.sh" <<EOS
#!/usr/bin/env bash
set -u
tmux() { command "$REAL_TMUX" -L "$SOCKET" "\$@"; }
export -f tmux 2>/dev/null || true
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_SUPERVISOR_TARGET=primary
export FM_SUPERVISOR_BACKEND=tmux
export FM_DAEMON_PRIMARY_HARNESS=copilot
. "$HOME_DIR/bin/fm-supervise-daemon.sh"
composer=\$(fm_backend_composer_state tmux primary)
printf 'composer=%s\n' "\$composer"
[ "\$composer" = empty ] || exit 3
inject_msg "AWAY PROBE - reply with exactly the token $AWAY_TOKEN and nothing else." "$HOME_DIR/state"
EOS
chmod +x "$LAB/inject.sh"
COMPOSER_OUT=$(bash "$LAB/inject.sh" 2>&1) || INJECT_RC=$?
case "$COMPOSER_OUT" in
  *composer=empty*) ;;
  *) harness_fail "an idle Copilot composer must be provably empty for away mode; got: $COMPOSER_OUT" ;;
esac
[ "$INJECT_RC" -eq 0 ] \
  || harness_fail "the away-mode escalation could not confirm delivery into the Copilot pane (rc=$INJECT_RC): $COMPOSER_OUT"
wait_for 180 "the away-mode escalation processed" pane_has "$AWAY_TOKEN"
has_event '.type == "user.message" and (.data.content | startswith("⁣FIRSTMATE_OP: v1 away-supervisor: "))' \
  || harness_fail "the typed escalation lost its U+2063 marker, so it would read as the captain"
rm -f "$HOME_DIR/state/.afk"
pass "copilot primary: an away-mode escalation is delivered, keeps its marker, and is processed"

# --- 6. ending the session ends its arm --------------------------------------

wait_for 180 "the escalation turn to end" turn_idle
submit "/exit"
arm_gone() { ! pgrep -f "$HOME_DIR/bin/fm-watch-arm.sh" >/dev/null 2>&1; }
wait_for 60 "the attached arm to end with the session" arm_gone
pass "copilot primary: /exit ends the attached background arm with the session"

cleanup_all
trap - EXIT
