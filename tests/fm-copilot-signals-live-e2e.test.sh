#!/usr/bin/env bash
# Credentialed GitHub Copilot CLI worker guard. Opt in with
# FM_COPILOT_SIGNALS_LIVE=1. It submits real prompts on the signed-in account.
# FM_COPILOT_LIVE_CMD, when set, is written to the isolated home's
# config/copilot-cmd so the guard exercises that configured launch command;
# otherwise the launch command is plain `copilot` from PATH.
# FM_COPILOT_MODEL chooses the model (default auto).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. Steering, interrupt,
# and exit use the real Firstmate control plane.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_COPILOT_SIGNALS_LIVE copilot tmux jq git
REAL_TMUX=$(command -v tmux)
# shellcheck source=bin/fm-copilot-lib.sh
. "$ROOT/bin/fm-copilot-lib.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cp.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The spawn leaves the per-task git hooks directory read-only.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=copilot-live
fm_test_spawn_home "$H" copilot
[ -z "${FM_COPILOT_LIVE_CMD:-}" ] || printf '%s\n' "$FM_COPILOT_LIVE_CMD" > "$H/config/copilot-cmd"
WORDS=()
while IFS= read -r word; do WORDS+=("$word"); done < <(fm_copilot_launch_words "$H/config")
[ "${#WORDS[@]}" -gt 0 ] || { printf 'not ok - the Copilot launch command did not resolve\n' >&2; exit 1; }
VERSION="Copilot CLI $(fm_copilot_version "${WORDS[@]}" || echo unknown)"
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
fm_git_worktree "$PROJ" "$WT" copilot-live
git -C "$WT" config user.name 'Copilot Live Guard'
git -C "$WT" config user.email copilot-live-guard@example.invalid
mkdir -p "$LAB/bin"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
[ -n "${FM_COPILOT_LIVE_CMD:-}" ] || ln -s "${WORDS[0]}" "$fakebin/copilot"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness copilot --model "${FM_COPILOT_MODEL:-auto}" --effort low > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
# A project skill, discovered from .agents/skills when the agent starts, proves
# the typed /<skill> invocation form Firstmate uses for /no-mistakes. It is
# written after the spawn, which refuses an unclean worktree.
mkdir -p "$WT/.agents/skills/fm-live-probe"
printf '%s\n' '---' 'name: fm-live-probe' 'description: Runtime verification probe. Use only when invoked by name.' '---' '' 'Write exactly the word SKILL-OK into the file skill.txt in the current directory, then stop. Do nothing else.' \
  > "$WT/.agents/skills/fm-live-probe/SKILL.md"
# The pane keeps the operator's real HOME: Copilot's sign-in lives there.
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 160 -y 45 -c "$WT" \
  "/bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
# Styled capture feeds only the composer classifier; the delivery matchers read
# plain text, exactly as the production callers do.
capture() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -e -t "$TARGET"; }
screen_text() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "$TARGET"; }
state_of() { fm_busy_classify tmux "$TARGET" copilot "$ID" "$H/state"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}; screen: $(screen_text | grep -v '^[[:space:]]*$' | tail -8)"
}
wait_idle() {
  local i
  for i in $(seq 1 240); do
    [ "$(state_of)" = 'idle copilot-hook' ] && return 0
    sleep 0.5
  done
  fail "agentStop did not produce semantic idle (state: $(state_of))"
}

wait_file "$WT/answer.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
wait_idle
# The hook touches the marker just after its generation-bound idle apply.
for _ in $(seq 1 20); do [ -f "$H/state/$ID.turn-ended" ] && break; sleep 0.25; done
[ -f "$H/state/$ID.turn-ended" ] || fail 'agentStop did not notify turn end'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'the real Copilot process was not classified alive'
pass "$VERSION: spawn brief, trust, autonomy, private plugin hooks, turn end, and liveness"

for _ in $(seq 1 60); do git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null; [ -s "$LAB/commit.txt" ] && break; sleep 0.5; done
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by' "$LAB/commit.txt" || fail "worker commit carries an agent co-author: $(cat "$LAB/commit.txt")"
pass "$VERSION: the worker commit carries no agent co-author"

# The full styled screen, not an invented glyph-only fixture, must be safe to type into.
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" \
  "$(tmux display-message -p -t "$TARGET" '#{cursor_y}')" copilot)
case "$verdict" in empty*) ;; *) fail "idle composer was $verdict" ;; esac
! screen_text | fm_busy_lines_match copilot || fail 'the idle screen matched the busy delivery signals'
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: idle composer reads empty; real fm-send doorbell read and acknowledged"

"$ROOT/bin/fm-send.sh" "$ID" '/fm-live-probe' > "$LAB/skill.log" 2>&1 || fail "skill invocation failed: $(cat "$LAB/skill.log")"
wait_file "$WT/skill.txt"
[ "$(tr -d '[:space:]' < "$WT/skill.txt")" = SKILL-OK ] || fail 'the slash skill did not run'
wait_idle
pass "$VERSION: a typed /<skill> invocation loads and runs a project skill"

# One Ctrl+C on an idle Copilot only arms its exit; the interrupt verb must
# leave the agent running.
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'an idle interrupt stopped the agent'
sleep 4
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'the agent exited after an idle interrupt'
pass "$VERSION: an idle interrupt sends one press and leaves the agent running"

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 as a foreground shell command (never a background or async shell) and wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(state_of)" = 'busy copilot-hook' ] && screen_text | fm_busy_lines_match copilot; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'no semantic and rendered busy during the interrupt probe'
sleep 3
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=unconfirmed' "$LAB/interrupt.log" || fail "busy interrupt claim changed: $(cat "$LAB/interrupt.log")"
[ "$(state_of)" = 'unknown fm-interrupt' ] || fail "interrupt did not conservatively invalidate state: $(state_of)"
cancelled=0
for _ in $(seq 1 40); do
  if ! screen_text | fm_busy_lines_match copilot; then cancelled=1; break; fi
  sleep 0.5
done
[ "$cancelled" = 1 ] || fail 'Ctrl+C did not cancel the running turn'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'the interrupt stopped the agent'
pass "$VERSION: one Ctrl+C cancels, preserves the agent, and invalidates busy state"

# agentStop closes the turn even while Copilot still waits for a background
# shell it started; the automatic follow-up when that shell finishes fires
# userPromptSubmitted again and reopens busy.
sleep 4
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime background verification: start the shell command sleep 20 as a background (async) shell, then immediately end your turn by replying STARTED without waiting for it. When it later completes, reply FINISHED.' > "$LAB/send.log" 2>&1 || fail 'could not steer background probe'
phase=submit
for _ in $(seq 1 240); do
  case "$phase:$(state_of)" in
    'submit:busy copilot-hook') phase=yielded ;;
    'yielded:idle copilot-hook') phase=followup ;;
    'followup:busy copilot-hook') phase=reopened; break ;;
  esac
  sleep 0.5
done
[ "$phase" = reopened ] || fail "background-shell follow-up did not reopen busy (reached $phase)"
wait_idle
pass "$VERSION: a turn that yields to a background shell settles, and the automatic follow-up reopens busy"

sleep 4
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail '/exit did not return to the shell'
pass "$VERSION: /exit stops the agent"

# Without COPILOT_ALLOW_ALL=true a fresh folder parks on the trust dialog; the
# backstop signature must recognize it. Nothing is submitted.
mkdir -p "$LAB/untrusted"
printf 'exec env -u COPILOT_ALLOW_ALL' > "$LAB/dialog.sh"
for word in "${WORDS[@]}"; do printf " '%s'" "$word" >> "$LAB/dialog.sh"; done
printf " -i 'Reply with only the word unused.'\n" >> "$LAB/dialog.sh"
"$REAL_TMUX" -S "$SOCKET" new-window -d -t firstmate -n dialog -c "$LAB/untrusted" "/bin/sh '$LAB/dialog.sh'"
parked=0
for _ in $(seq 1 120); do
  if "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t firstmate:dialog | fm_busy_launch_prompt_parked copilot; then parked=1; break; fi
  sleep 0.5
done
"$REAL_TMUX" -S "$SOCKET" kill-window -t firstmate:dialog >/dev/null 2>&1 || true
[ "$parked" = 1 ] || fail 'the folder-trust dialog signature no longer matches'
pass "$VERSION: the folder-trust dialog backstop signature matches the real dialog"
