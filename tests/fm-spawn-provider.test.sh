#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's provider-env axis (--provider,
# config/providers/<name>.env; grammar owned by docs/configuration.md
# "Provider environment files").
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree, mirroring
# tests/fm-spawn-dispatch-profile.test.sh: the fake tmux captures the literal
# launch command sent with `tmux send-keys -l`, so assertions pin the exact env
# prefix firstmate would launch with, without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-provider)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config/providers"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

# The captain's reference kimi provider set, values matching the live 2026-08-03
# verification. $MOONSHOT_API_KEY stays a reference, resolved only in the pane.
write_kimi_provider() {
  local home=$1
  cat > "$home/config/providers/kimi.env" <<'ENV'
# Kimi / Moonshot Anthropic-compatible endpoint
ANTHROPIC_BASE_URL=https://api.kimi.com/coding
ANTHROPIC_AUTH_TOKEN="$MOONSHOT_API_KEY"
ANTHROPIC_MODEL=kimi-k3
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k2.6
CLAUDE_CODE_EFFORT_LEVEL=max
ENV
}

# shellcheck disable=SC2016  # $MOONSHOT_API_KEY stays a literal, unexpanded reference by design
KIMI_PREFIX='ANTHROPIC_BASE_URL=https://api.kimi.com/coding ANTHROPIC_AUTH_TOKEN="$MOONSHOT_API_KEY" ANTHROPIC_MODEL=kimi-k3 ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k2.6 CLAUDE_CODE_EFFORT_LEVEL=max'

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    MOONSHOT_API_KEY='test-secret-never-printed' \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  # shellcheck disable=SC2034  # CASE_DIR keeps the record shape shared with the dispatch-profile suite
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_valid_provider_prefixes_env_and_records_meta() {
  local rec id out status launch expected
  id=provider-kimi-p1
  rec=$(make_spawn_case provider-kimi claude "$id")
  read_case_record "$rec"
  write_kimi_provider "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider kimi)
  status=$?
  expect_code 0 "$status" "claude spawn with a valid provider should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_grep "harness=claude" "$HOME_DIR/state/$id.meta" "meta missing harness=claude"
  assert_grep "provider=kimi" "$HOME_DIR/state/$id.meta" "meta missing provider=kimi"

  launch=$(cat "$LAUNCH_LOG")
  expected="$KIMI_PREFIX CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "provider launch env prefix did not match the file"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_not_contains "$launch" "test-secret-never-printed" "provider launch must never expand the secret value"
  pass "valid provider prepends the file's env assignments and records provider= in meta"
}

test_unknown_provider_refused() {
  local rec id out status
  id=provider-unknown-p2
  rec=$(make_spawn_case provider-unknown claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider nosuch)
  status=$?
  expect_code 1 "$status" "unknown provider should refuse the spawn"
  assert_contains "$out" "no provider file at config/providers/nosuch.env" "refusal did not name the missing provider file"
  assert_absent "$HOME_DIR/state/$id.meta" "unknown provider refusal should happen before meta is written"
  pass "unknown provider name refuses loudly before any side effect"
}

test_bad_provider_name_refused() {
  local rec id out status
  id=provider-badname-p3
  rec=$(make_spawn_case provider-badname claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider 'Bad_Name')
  status=$?
  expect_code 1 "$status" "non-slug provider name should refuse the spawn"
  assert_contains "$out" "not slug-safe" "refusal did not explain the slug constraint"
  assert_absent "$HOME_DIR/state/$id.meta" "bad provider name refusal should happen before meta is written"
  pass "non-slug provider name refuses loudly"
}

test_malformed_provider_lines_refused() {
  local rec id out status bad n
  n=0
  # shellcheck disable=SC2016  # the literal $()/backtick/$VAR bodies are the fixtures under test
  for bad in \
    'EVIL=$(rm -rf /)' \
    'EVIL=`whoami`' \
    'EVIL=a;b' \
    'EVIL=a b' \
    "EVIL='literal \$NOPE'" \
    '3BAD=value' \
    'EVIL=trailing$' \
    'not an assignment'
  do
    n=$((n + 1))
    id="provider-malformed-p4-$n"
    rec=$(make_spawn_case "provider-malformed-$n" claude "$id")
    read_case_record "$rec"
    printf '%s\n' "$bad" > "$HOME_DIR/config/providers/bad.env"

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider bad)
    status=$?
    expect_code 1 "$status" "malformed provider line should refuse the spawn: $bad"
    assert_contains "$out" "line 1" "refusal did not point at the offending line for: $bad"
    assert_absent "$HOME_DIR/state/$id.meta" "malformed provider refusal should happen before meta is written: $bad"
  done
  pass "malformed provider lines (substitution, backticks, semicolons, unquoted space, quoted \$, bad name, stray \$) refuse loudly"
}

test_provider_with_non_claude_harness_refused() {
  local rec id out status
  id=provider-codex-p5
  rec=$(make_spawn_case provider-codex codex "$id")
  read_case_record "$rec"
  write_kimi_provider "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex --provider kimi)
  status=$?
  expect_code 1 "$status" "provider with a non-claude harness should refuse the spawn"
  assert_contains "$out" "--provider is only supported with harness" "refusal did not explain the provider-capable harness set"
  assert_absent "$HOME_DIR/state/$id.meta" "non-claude provider refusal should happen before meta is written"
  pass "provider with a non-claude harness refuses loudly"
}

test_provider_with_raw_launch_refused() {
  local rec id out status
  id=provider-raw-p6
  rec=$(make_spawn_case provider-raw claude "$id")
  read_case_record "$rec"
  write_kimi_provider "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 'claude --custom-flag' --provider kimi)
  status=$?
  expect_code 1 "$status" "provider with a raw launch command should refuse the spawn"
  assert_contains "$out" "a raw launch command must carry its own env prefix" "refusal did not explain the raw-launch exclusion"
  assert_absent "$HOME_DIR/state/$id.meta" "raw-launch provider refusal should happen before meta is written"
  pass "provider with a raw launch command refuses loudly"
}

test_unset_secret_var_refused() {
  local rec id out status
  id=provider-unsetvar-p7
  rec=$(make_spawn_case provider-unsetvar claude "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/providers/kimi.env" <<'ENV'
ANTHROPIC_BASE_URL=https://api.kimi.com/coding
ANTHROPIC_AUTH_TOKEN="$FM_TEST_DEFINITELY_UNSET_SECRET"
ENV
  unset FM_TEST_DEFINITELY_UNSET_SECRET 2>/dev/null || true

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider kimi)
  status=$?
  expect_code 1 "$status" "provider referencing an unset variable should refuse the spawn"
  # shellcheck disable=SC2016  # the unexpanded $NAME is the exact expected message text
  assert_contains "$out" 'references $FM_TEST_DEFINITELY_UNSET_SECRET, which is not set' "refusal did not name the missing variable"
  assert_absent "$HOME_DIR/state/$id.meta" "unset-variable refusal should happen before meta is written"
  pass "a referenced-but-unset secret variable refuses the spawn naming only the variable"
}

test_effort_flag_omitted_with_provider() {
  local rec id out status launch
  id=provider-effort-p8
  rec=$(make_spawn_case provider-effort claude "$id")
  read_case_record "$rec"
  write_kimi_provider "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider kimi --effort high)
  status=$?
  expect_code 0 "$status" "provider spawn with --effort should still succeed"
  assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "meta must still record the requested effort"
  assert_grep "provider=kimi" "$HOME_DIR/state/$id.meta" "meta missing provider=kimi"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--effort" "effort launch flag must be omitted while a provider is active (unverified against third-party endpoints)"
  pass "an active provider omits the unverified effort launch flag while meta records effort="
}

test_respawn_reuses_recorded_provider() {
  local rec id out status launch
  id=provider-respawn-p9
  rec=$(make_spawn_case provider-respawn claude "$id")
  read_case_record "$rec"
  write_kimi_provider "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --provider kimi)
  status=$?
  expect_code 0 "$status" "first provider spawn should succeed"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "respawn without --provider should succeed"
  assert_grep "provider=kimi" "$HOME_DIR/state/$id.meta" "respawn meta must retain provider=kimi"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$KIMI_PREFIX" "respawn did not re-apply the recorded provider env prefix"
  pass "a respawn re-applies the provider recorded in existing meta"
}

test_no_provider_stays_byte_identical() {
  local rec id out status launch expected
  id=provider-off-p10
  rec=$(make_spawn_case provider-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without a provider should succeed"
  assert_no_grep "provider=" "$HOME_DIR/state/$id.meta" "meta must not record provider= without an active provider"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "provider-less claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "absent provider keeps the plain claude launch and meta byte-identical"
}

test_valid_provider_prefixes_env_and_records_meta
test_unknown_provider_refused
test_bad_provider_name_refused
test_malformed_provider_lines_refused
test_provider_with_non_claude_harness_refused
test_provider_with_raw_launch_refused
test_unset_secret_var_refused
test_effort_flag_omitted_with_provider
test_respawn_reuses_recorded_provider
test_no_provider_stays_byte_identical

echo "# all fm-spawn-provider tests passed"
