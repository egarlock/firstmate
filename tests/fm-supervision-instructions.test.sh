#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

# shellcheck source=bin/fm-harness-policy.sh
. "$ROOT/bin/fm-harness-policy.sh"

# Structural coverage: the renderer maps harness names through
# fm_harness_is_verified, so a newly verified adapter that never got its own
# protocol would silently render the generic unknown fallback. That is exactly
# how a verified copilot primary ended up on unknown.md, was told to arm
# bin/fm-watch-arm.sh with no call-shape constraint, and blocked captain chat.
test_every_verified_adapter_renders_its_own_protocol() {
  local harness out ordinary repair
  for harness in $FM_VERIFIED_ADAPTERS; do
    [ -f "$ROOT/docs/supervision-protocols/$harness.md" ] \
      || fail "verified adapter $harness has no docs/supervision-protocols/$harness.md"
    out=$("$RENDER" --harness "$harness")
    assert_contains "$out" "primary harness: $harness" "renderer did not keep the $harness heading"
    assert_not_contains "$out" "Mode: Unknown harness fallback." "verified adapter $harness fell back to the unknown protocol"
    assert_not_contains "$out" "__FM_" "renderer leaked a placeholder in the $harness snippet"
    ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
    assert_not_contains "$ordinary" "follow the continuation in the harness protocol below" \
      "verified adapter $harness has no ordinary-wake continuation of its own"
    repair=$("$RENDER" --harness "$harness" --repair-line)
    assert_not_contains "$repair" "according to the session-start block for this harness" \
      "verified adapter $harness has no missing-cycle repair line of its own"
  done
  pass "every verified adapter renders its own protocol, ordinary-wake line, and repair line"
}

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude background-notify supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension background wake." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" 'Mode: Codex foreground checkpoint.' "codex snippet missing"
  assert_not_contains "$out" "Source \`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "Claude Code background task" "claude repair line missing background-task mechanism"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' first" "x-mode repair line did not source the effective cadence config"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "x-mode codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "extension command /fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_cross_harness_ordinary_continuation_and_repair_matrix() {
  local ordinary out

  out=$("$RENDER" --harness pi)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" "pi ordinary-wake line does not leave continuity to the extension"
  assert_not_contains "$ordinary" "fm_watch_arm_pi" "pi ordinary-wake line incorrectly calls the recovery tool"
  out=$("$RENDER" --harness pi --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness opencode)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "plugin already owns watcher continuity" "opencode ordinary-wake line does not leave continuity to the plugin"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "opencode ordinary-wake line incorrectly calls the recovery probe"
  out=$("$RENDER" --harness opencode --repair-line)
  assert_contains "$out" "manual recovery probe" "opencode recovery line lost its manual probe"

  out=$("$RENDER" --harness claude)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "claude ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "Claude Code background task" "claude ordinary-wake line lost tracked background ownership"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "claude ordinary-wake line lost the background arm command"
  out=$("$RENDER" --harness claude --repair-line)
  assert_contains "$out" "Claude Code background task" "claude recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "claude recovery line lost the arm command"

  out=$("$RENDER" --harness grok)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "grok ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "Grok tracked background task" "grok ordinary-wake line lost tracked background ownership"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "grok ordinary-wake line lost the background arm command"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok recovery line lost the arm command"

  out=$("$RENDER" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "next foreground" "codex ordinary-wake line lost its foreground checkpoint"
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "codex ordinary-wake line lost the checkpoint command"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codex ordinary-wake line incorrectly uses a background arm"
  out=$("$RENDER" --harness codex --repair-line)
  assert_contains "$out" "foreground checkpoint" "codex recovery line lost its checkpoint repair"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex recovery line lost the checkpoint command"

  out=$("$RENDER" --harness copilot)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "copilot ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "attached Copilot shell call" "copilot ordinary-wake line lost its attached short-wait shape"
  assert_contains "$ordinary" "return promptly" "copilot ordinary-wake line lost the return-promptly invariant"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "copilot ordinary-wake line lost the arm command"
  assert_not_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "copilot ordinary-wake line incorrectly uses a foreground checkpoint"
  out=$("$RENDER" --harness copilot --repair-line)
  assert_contains "$out" "attached Copilot shell call" "copilot recovery line lost its attached short-wait repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "copilot recovery line lost the arm command"

  pass "renderer preserves every harness ordinary-continuation and missing-cycle repair path"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Mode: Grok background-notify supervision." "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "foreground checkpoint" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok repair line is not background-notify shaped"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_grok_command_sources_effective_config() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; exec bin/fm-watch-arm.sh" "grok arm command did not use the effective x-mode config path"
  pass "grok rendered command sources the effective x-mode config"
}

test_copilot_is_attached_short_wait_background_notify() {
  local home config out
  home="$TMP_ROOT/copilot-home"
  config="$TMP_ROOT/copilot-config"
  mkdir -p "$home/state" "$config"
  out=$("$RENDER" --harness copilot)
  assert_contains "$out" "Mode: Copilot attached short-wait background supervision." "copilot snippet missing its mode line"
  assert_contains "$out" "bin/fm-watch-arm.sh" "copilot snippet missing the watcher arm"
  assert_contains "$out" "initial_wait: 15" "copilot snippet did not render the derived confirmation budget"
  assert_contains "$out" "MUST return promptly" "copilot snippet lost the return-promptly invariant"
  assert_contains "$out" "queues everything the captain types while a model turn is active" \
    "copilot snippet does not explain why a long initial_wait blocks chat"
  # shellcheck disable=SC2016
  assert_contains "$out" 'Never set `detach: true`' "copilot snippet does not forbid a detached arm"
  assert_contains "$out" "Never use shell \`&\`" "copilot snippet does not forbid shell backgrounding"
  assert_not_contains "$out" "foreground checkpoint" "copilot snippet must not be Codex-style foreground checkpoint"
  assert_not_contains "$out" "__FM_" "renderer leaked a placeholder in the copilot snippet"

  out=$(FM_ARM_CONFIRM_TIMEOUT=20 "$RENDER" --harness copilot)
  assert_contains "$out" "initial_wait: 25" "copilot wait budget is not derived from FM_ARM_CONFIRM_TIMEOUT"
  assert_not_contains "$out" "initial_wait: 15" "copilot wait budget kept the default while FM_ARM_CONFIRM_TIMEOUT was overridden"

  # FM_ARM_CONFIRM_TIMEOUT is an operator knob for slow hosts. Propagating it
  # uncapped would render a multi-minute attached call and reopen the exact
  # blocked-chat incident this protocol exists to prevent, in text that
  # simultaneously tells the model the call must return promptly.
  out=$(FM_ARM_CONFIRM_TIMEOUT=300 "$RENDER" --harness copilot)
  assert_contains "$out" "initial_wait: 30" "copilot wait budget was not capped for a large FM_ARM_CONFIRM_TIMEOUT"
  assert_contains "$out" "initial_wait 30 as directed below" "copilot wake line was not capped for a large FM_ARM_CONFIRM_TIMEOUT"
  assert_not_contains "$out" "305" "copilot snippet propagated a multi-minute attached call"

  out=$(FM_ARM_CONFIRM_TIMEOUT=300 "$RENDER" --harness copilot --repair-line)
  assert_contains "$out" "initial_wait 30" "copilot repair line was not capped for a large FM_ARM_CONFIRM_TIMEOUT"
  assert_not_contains "$out" "305" "copilot repair line propagated a multi-minute attached call"

  out=$(FM_ARM_CONFIRM_TIMEOUT=not-a-number "$RENDER" --harness copilot)
  assert_contains "$out" "initial_wait: 15" "copilot wait budget did not fall back to the default confirmation budget"

  # A leading zero is all digits but bash reads it as octal, so an unhardened
  # guard lets it reach the arithmetic and abort the renderer under `set -eu`.
  # That takes down the supervision block for EVERY harness, so assert the
  # blast radius, not just the copilot render.
  local status
  status=0
  out=$(FM_ARM_CONFIRM_TIMEOUT=08 "$RENDER" --harness copilot 2>&1) || status=$?
  expect_code 0 "$status" "octal-looking FM_ARM_CONFIRM_TIMEOUT aborted the renderer"
  assert_contains "$out" "initial_wait: 15" "octal-looking FM_ARM_CONFIRM_TIMEOUT was not normalized"
  assert_not_contains "$out" "value too great for base" "renderer leaked a bash arithmetic error"
  status=0
  out=$(FM_ARM_CONFIRM_TIMEOUT=08 "$RENDER" --harness claude 2>&1) || status=$?
  expect_code 0 "$status" "octal-looking FM_ARM_CONFIRM_TIMEOUT broke an unrelated harness render"

  # Large enough to overflow the addition and wrap negative, which would pass
  # the cap's -le test and render a negative wait.
  out=$(FM_ARM_CONFIRM_TIMEOUT=9223372036854775807 "$RENDER" --harness copilot)
  assert_contains "$out" "initial_wait: 15" "overflowing FM_ARM_CONFIRM_TIMEOUT was not normalized"
  assert_not_contains "$out" "initial_wait: -" "copilot wait budget rendered a negative value"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness copilot --x-mode 1)
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; exec bin/fm-watch-arm.sh" \
    "copilot arm command did not use the effective x-mode config path"

  out=$("$RENDER" --harness copilot --repair-line)
  assert_contains "$out" "attached Copilot shell call with initial_wait 15" "copilot repair line is not attached short-wait shaped"
  assert_contains "$out" "never detached" "copilot repair line does not forbid a detached arm"
  pass "copilot supervision is an attached short-wait arm that returns before the turn ends"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

test_selected_harness_block_only
test_unknown_fallback
test_every_verified_adapter_renders_its_own_protocol
test_conditional_stanzas
test_repair_lines
test_cross_harness_ordinary_continuation_and_repair_matrix
test_grok_is_background_notify
test_grok_command_sources_effective_config
test_copilot_is_attached_short_wait_background_notify
test_pi_snippet_uses_effective_extension_path
