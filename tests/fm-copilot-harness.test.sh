#!/usr/bin/env bash
# Portable GitHub Copilot CLI worker adapter regression. Vendor facts are
# refreshed by fm-copilot-signals-live-e2e.test.sh; this suite needs no Copilot
# install or credentials.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-copilot-lib.sh
. "$ROOT/bin/fm-copilot-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

# A fake Copilot executable: answers --version with the version in its
# FAKE_COPILOT_VERSION file (or prints nothing when that file is absent) and
# records every other invocation.
make_fake_copilot() {  # <path> <version-or-empty>
  local path=$1
  mkdir -p "$(dirname "$path")"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$path.version"; fi
  cat > "$path" <<EOF
#!/bin/sh
if [ "\$1" = --version ] || [ "\$2" = --version ]; then
  printf 'Launcher banner 9.9.9\n'
  [ -f '$path.version' ] && printf 'GitHub Copilot CLI %s.\n' "\$(cat '$path.version')"
  exit 0
fi
exit 0
EOF
  chmod +x "$path"
}

[ "$(fm_agent_process_classify_name /Users/x/.copilot-cli/1.0.88/copilot)" = agent ] || fail 'liveness lost the native Copilot executable'
[ "$(fm_agent_process_classify_name /opt/homebrew/bin/copilot)" = agent ] || fail 'liveness lost an installed copilot path'
[ "$(fm_agent_process_classify_name copilot-helper)" = other ] || fail 'liveness claims an unrelated copilot-prefixed name'
[ "$(fm_agent_process_classify_name mycopilot)" = other ] || fail 'liveness claims an unrelated copilot-suffixed name'
pass "anchored Copilot liveness"

[ "$(fm_control_interrupt_key copilot)" = C-c ] || fail 'Copilot cancels on Ctrl+C'
[ "$(fm_control_interrupt_repeat copilot)" = 1 ] || fail 'a second Ctrl+C on an idle Copilot exits it; one press only'
[ -z "$(fm_control_interrupt_clear_key copilot)" ] || fail 'Copilot leaves an empty composer after a cancel'
[ -z "$(fm_control_interrupt_arm_signal copilot)" ] || fail 'Copilot interrupt is a single press'
[ "$(fm_control_exit_command copilot)" = /exit ] || fail 'wrong exit command'
[ "$(fm_control_harness_family copilot)" = copilot ] || fail 'recorded harness does not resolve to the adapter'
! fm_control_harness_family copilot-helper >/dev/null || fail 'a copilot-prefixed raw command claimed the adapter'
fm_control_harness_supports_kind copilot ship || fail 'ship refused'
fm_control_harness_supports_kind copilot scout || fail 'scout refused'
fm_control_harness_supports_kind copilot secondmate || fail 'secondmate refused'
for backend in tmux herdr zellij cmux orca; do
  fm_control_backend_supports_key "$backend" C-c || fail "$backend cannot deliver the Copilot interrupt"
done
pass "adapter resolution, task kinds, and lifecycle capabilities"

for signal in ' ◉ Working · 97 B esc interrupt' ' ◎ Working esc interrupt'; do
  printf '%s\n' "$signal" | fm_busy_lines_match copilot || fail "busy row not acknowledged: $signal"
done
# Each independent signal carries the verdict alone.
printf ' ○ Working · 76 B\n' | fm_busy_lines_match copilot || fail 'Working row alone lost'
printf 'esc interrupt\n' | fm_busy_lines_match copilot || fail 'interrupt hint alone lost'
! printf ' ← open sidebar · / commands · ? help · tab next tab\n' | fm_busy_lines_match copilot || fail 'idle row read busy'
# A yielded agent waiting on its own background shell answers a prompt at once,
# so that row is not busy, while a Working row beside it still is.
! printf ' ○ Waiting for background shells · 1.4 KiB esc interrupt\n' | fm_busy_lines_match copilot \
  || fail 'the background-shell row of a yielded agent read busy'
printf ' ○ Waiting for background shells · 1 KiB esc interrupt\n ◎ Working · 9 B esc interrupt\n' \
  | fm_busy_lines_match copilot || fail 'a Working row beside the background-shell row lost'
! printf '   echo Working · x\n' | fm_busy_lines_match copilot || fail 'worker output faked the Working row'
! printf 'esc to cancel\n' | fm_busy_lines_match copilot || fail 'borrowed another harness signal'
[ "$(fm_composer_classify_content 0 '❯')" = empty ] || fail 'Copilot composer glyph not recognized'
[ "$(fm_composer_classify_content 0 '❯ unsubmitted draft')" = pending ] || fail 'typed draft not preserved'
trust=$'│ Confirm folder trust │\n│ Do you trust the files in this folder? │\n│ ❯ 1. Yes │\n│   2. Yes, and remember this folder for future sessions │\n│   3. No (Esc) │'
printf '%s\n' "$trust" | fm_busy_launch_prompt_parked copilot || fail 'folder-trust dialog not recognized'
! printf 'Confirm folder trust is what the docs call it\n' | fm_busy_launch_prompt_parked copilot || fail 'dialog heading alone matched'
! printf '%s\n' "$trust" | fm_busy_launch_prompt_parked devin || fail 'Copilot dialog classified another harness'
pass "delivery signals, composer draft safety, and trust-dialog backstop"

# The configured launch command: absent, configured wrapper, and refusals.
cfg="$TMP_ROOT/config"
mkdir -p "$cfg" "$TMP_ROOT/path"
make_fake_copilot "$TMP_ROOT/path/copilot" 1.0.88
make_fake_copilot "$TMP_ROOT/path/wrapper" 1.0.88
out=$(PATH="$TMP_ROOT/path:$PATH" fm_copilot_launch_prefix "$cfg") || fail 'absent config refused'
[ "$out" = "'$TMP_ROOT/path/copilot'" ] || fail "absent config must launch plain copilot: $out"
printf '# work laptop\n\nwrapper copilot --flag=a,b\n' > "$cfg/copilot-cmd"
out=$(PATH="$TMP_ROOT/path:$PATH" fm_copilot_launch_prefix "$cfg") || fail 'configured command refused'
[ "$out" = "'$TMP_ROOT/path/wrapper' 'copilot' '--flag=a,b'" ] || fail "configured command not spliced whole: $out"
# shellcheck disable=SC2016 # the literal command substitution is the input under test
for bad in 'wrapper $(touch pwned)' 'wrapper; rm' 'wrapper "copilot"' 'wrapper *'; do
  printf '%s\n' "$bad" > "$cfg/copilot-cmd"
  if PATH="$TMP_ROOT/path:$PATH" fm_copilot_launch_prefix "$cfg" >/dev/null 2>&1; then fail "shell syntax accepted: $bad"; fi
done
printf 'wrapper\nother\n' > "$cfg/copilot-cmd"
! PATH="$TMP_ROOT/path:$PATH" fm_copilot_launch_prefix "$cfg" >/dev/null 2>&1 || fail 'two command lines accepted'
printf '\n# only a comment\n' > "$cfg/copilot-cmd"
! PATH="$TMP_ROOT/path:$PATH" fm_copilot_launch_prefix "$cfg" >/dev/null 2>&1 || fail 'a file with no command accepted'
printf 'no-such-copilot-launcher\n' > "$cfg/copilot-cmd"
! PATH="$TMP_ROOT/path:$PATH" fm_copilot_launch_prefix "$cfg" >/dev/null 2>&1 || fail 'unresolvable executable accepted'
rm "$cfg/copilot-cmd"
[ "$(fm_copilot_version "$TMP_ROOT/path/wrapper" copilot)" = 1.0.88 ] || fail 'version not read through a wrapper banner'
fm_copilot_version_supported 1.0.68 || fail 'the minimum refused'
fm_copilot_version_supported 1.1.0 || fail 'a newer minor refused'
fm_copilot_version_supported 2.0.0 || fail 'a newer major refused'
! fm_copilot_version_supported 1.0.67 || fail 'an older patch accepted'
! fm_copilot_version_supported 0.9.99 || fail 'an older major accepted'
pass "configured launch command is opaque, validated, and version-gated"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
"$ROOT/bin/fm-copilot-plugin.sh" "$state" worker "$gen" || fail 'plugin writer failed'
plugin="$state/worker.copilot-plugin"
jq -e '.hooks == "hooks.json" and (.name | length) > 0' "$plugin/plugin.json" >/dev/null || fail 'plugin manifest malformed'
run_hook() { (cd "$plugin" && bash -c "$(jq -r --arg event "$1" '.hooks[$event][0].bash' "${2:-$plugin/hooks.json}")"); }
run_hook userPromptSubmitted
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy copilot-hook' ] || fail 'prompt did not open busy'
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'agentStop did not settle'
assert_present "$state/worker.turn-ended" 'agentStop notification absent'
run_hook userPromptSubmitted
run_hook sessionEnd
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'sessionEnd did not settle'
[ "$(fm_busy_classify tmux fake:w devin worker "$state")" = 'unknown source-mismatch' ] || fail 'copilot hook classified another harness'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy fm-spawn' ] || fail 'stale agentStop cleared the replacement'
assert_absent "$state/worker.turn-ended" 'stale agentStop woke the replacement'
paths=$(fm_control_harness_wiring_paths copilot /unused "$state" worker)
[ "$paths" = "$plugin/hooks.json"$'\n'"$plugin/plugin.json" ] || fail "plugin retirement paths wrong: $paths"
cp "$plugin/hooks.json" "$TMP_ROOT/retired-hooks.json"
gen2=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
"$ROOT/bin/fm-copilot-plugin.sh" "$state" worker "$gen2" || fail 'plugin rewrite failed'
run_hook agentStop "$TMP_ROOT/retired-hooks.json"
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy fm-spawn' ] || fail 'retired plugin hook cleared the rewritten generation'
assert_absent "$state/worker.turn-ended" 'retired plugin hook woke the rewritten generation'
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'rewritten plugin did not settle the new generation'
assert_present "$state/worker.turn-ended" 'rewritten plugin agentStop notification absent'
pass "private plugin hooks: lifecycle, turn-end, stale-generation rejection, and retirement"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
make_fake_copilot "$fakebin/copilot" 1.0.88
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" copilot
fm_git_worktree "$proj" "$wt" copilot-test
fm_test_spawn_brief "$home" copilot-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-worker "$proj" --scout --harness copilot --model auto --effort xhigh 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" "COPILOT_ALLOW_ALL=true '$fakebin/copilot' --plugin-dir '$home/state/copilot-worker.copilot-plugin' --allow-all --no-ask-user" 'trust, plugin, or autonomy flags missing'
assert_contains "$launch" "--model 'auto'" 'model lost'
assert_contains "$launch" "--reasoning-effort 'xhigh'" 'effort lost'
assert_contains "$launch" "-i \"\$(" 'brief not submitted as the first interactive turn'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
assert_contains "$launch" '-u CLAUDECODE' 'foreign primary marker not cleared'
case "$launch" in *'-u COPILOT_CLI'*) fail 'a Copilot launch cleared its own identity marker' ;; esac
assert_grep 'harness=copilot' "$home/state/copilot-worker.meta" 'harness not recorded'
assert_present "$home/state/copilot-worker.copilot-plugin/hooks.json" 'spawn did not wire hooks'
[ "$(fm_busy_classify tmux fake:w copilot copilot-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
pass "scout launch carries trust, private plugin, autonomy, model, effort, and typed brief"

make_fake_copilot "$fakebin/agency" 1.0.88
fm_test_spawn_brief "$home" copilot-wrapped
printf 'agency copilot\n' > "$home/config/copilot-cmd"
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch-wrapped" fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-wrapped "$proj" --scout --harness copilot 2>&1)
then fail "wrapped spawn failed: $out"; fi
assert_contains "$(cat "$case_dir/launch-wrapped")" "COPILOT_ALLOW_ALL=true '$fakebin/agency' 'copilot' --plugin-dir" 'configured command did not replace the executable prefix'
case "$(cat "$case_dir/launch-wrapped")" in *--reasoning-effort*|*--model*) fail 'unrequested profile axes reached argv' ;; esac
rm "$home/config/copilot-cmd"
pass "configured launch command replaces the executable prefix"

printf '1.0.40\n' > "$fakebin/copilot.version"
fm_test_spawn_brief "$home" copilot-old
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-old "$proj" --scout --harness copilot 2>&1)
then fail 'an old Copilot CLI launched'; fi
assert_contains "$out" 'older than the verified minimum' 'wrong old-version refusal'
assert_absent "$home/state/copilot-old.meta" 'refused launch left a task record'
rm "$fakebin/copilot.version"
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-old "$proj" --scout --harness copilot 2>&1)
then fail 'an unversioned launch command launched'; fi
assert_contains "$out" 'reported no GitHub Copilot CLI version' 'wrong unreadable-version refusal'
printf '1.0.88\n' > "$fakebin/copilot.version"
pass "old or unversioned CLIs are refused before launch"

# A secondmate runs its own Copilot primary in its home: the same trusted
# launch, which also loads that home's tracked .github/hooks registrations.
sm="$case_dir/sm-home"
mkdir -p "$sm/bin" "$sm/data"
printf '# Firstmate\n' > "$sm/AGENTS.md"
printf 'copilot-sm\n' > "$sm/.fm-secondmate-home"
printf 'charter\n' > "$sm/data/charter.md"
git -C "$sm" init -q
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch-sm" fm_test_run_spawn "$home" "$sm" "$fakebin" copilot-sm "$sm" --secondmate --harness copilot 2>&1)
then fail "Copilot secondmate launch failed: $out"; fi
assert_contains "$(cat "$case_dir/launch-sm")" "COPILOT_ALLOW_ALL=true '$fakebin/copilot' --plugin-dir '$home/state/copilot-sm.copilot-plugin' --allow-all --no-ask-user" 'secondmate launch lost trust, plugin, or autonomy'
assert_grep 'harness=copilot' "$home/state/copilot-sm.meta" 'secondmate harness not recorded'
assert_grep 'kind=secondmate' "$home/state/copilot-sm.meta" 'secondmate kind not recorded'
pass "a Copilot secondmate launches with the same trusted shape in its home"
