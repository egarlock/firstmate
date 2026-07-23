#!/usr/bin/env bash
# Copilot spawn-time version gate (drift-proofing).
#
# copilot's supervised launch shape (agentStop turn-end hook, --allow-all,
# --model/--effort) is verified against GitHub Copilot CLI 1.0.68+. An older or
# absent CLI can lack the hook event or a launch flag and fail opaquely mid-run.
# These tests pin the gate that catches that up front:
#   1. fm_version_ge does correct three-field numeric ordering.
#   2. fm_harness_version_parts extracts "<maj> <min> <pat>" from --version.
#   3. fm_copilot_compatible accepts >= 1.0.68 and rejects older/absent CLIs.
#   4. fm-spawn.sh aborts a copilot launch with a clear message on an incompatible
#      CLI, before any worktree side effects.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-harness-policy.sh
. "$ROOT/bin/fm-harness-policy.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-version)

# fake_copilot <dir> <version-line>: drop a copilot stub onto a fresh fakebin that
# prints <version-line> for `copilot --version`. Empty version-line omits the stub
# entirely (models an absent CLI).
fake_copilot() {  # <dir> <version-line-or-empty>
  local dir=$1 ver=$2 fb
  fb=$(fm_fakebin "$dir")
  if [ -n "$ver" ]; then
    cat > "$fb/copilot" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf '%s\n' '$ver'; exit 0 ;;
esac
exit 0
SH
    chmod +x "$fb/copilot"
  fi
  printf '%s\n' "$fb"
}

test_version_ge_orders_numerically() {
  fm_version_ge 1 0 68 1 0 68 || fail "1.0.68 should be >= 1.0.68"
  fm_version_ge 1 0 69 1 0 68 || fail "1.0.69 should be >= 1.0.68"
  fm_version_ge 1 1 0 1 0 68 || fail "1.1.0 should be >= 1.0.68"
  fm_version_ge 2 0 0 1 0 68 || fail "2.0.0 should be >= 1.0.68"
  fm_version_ge 1 0 67 1 0 68 && fail "1.0.67 should be < 1.0.68"
  fm_version_ge 0 9 99 1 0 68 && fail "0.9.99 should be < 1.0.68"
  # Numeric, not lexicographic: 1.0.9 < 1.0.68 lexically but > numerically.
  fm_version_ge 1 0 100 1 0 68 || fail "1.0.100 should be >= 1.0.68 numerically"
  pass "fm_version_ge: three-field numeric ordering"
}

test_version_parts_extracts_fields() {
  local fb out
  fb=$(fake_copilot "$TMP_ROOT/parts" 'GitHub Copilot CLI 1.0.68.')
  out=$(PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_harness_version_parts copilot')
  [ "$out" = "1 0 68" ] || fail "fm_harness_version_parts did not parse copilot --version (got '$out')"
  # Absent CLI: no parts, non-zero.
  fb=$(fake_copilot "$TMP_ROOT/parts-absent" '')
  PATH="$fb:/usr/bin:/bin" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_harness_version_parts copilot' \
    && fail "fm_harness_version_parts should fail when copilot is absent"
  pass "fm_harness_version_parts: extracts fields, fails on absent CLI"
}

test_version_parts_anchors_to_first_triple() {
  # Format-drift fixtures: a SECOND dotted number later on the version line (a
  # node runtime, a build stamp) must not win the match. A greedy .* prefix
  # locked onto the LAST triple, parsing '... 1.0.50 (node v20.11.1)' as 0.11.1
  # and '0.9.0 build 2026.1.15' as 6.1.15 - the latter let an incompatible 0.9.0
  # PASS the gate. The parser must anchor to the FIRST triple.
  local fb out
  fb=$(fake_copilot "$TMP_ROOT/first-triple-node" 'GitHub Copilot CLI 1.0.50 (node v20.11.1)')
  out=$(PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_harness_version_parts copilot')
  [ "$out" = "1 0 50" ] || fail "trailing node runtime version won the parse (got '$out', want '1 0 50')"
  fb=$(fake_copilot "$TMP_ROOT/first-triple-build" 'copilot 0.9.0 build 2026.1.15')
  out=$(PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_harness_version_parts copilot')
  [ "$out" = "0 9 0" ] || fail "trailing build stamp won the parse (got '$out', want '0 9 0')"
  # Two-digit major must not truncate (10.2.3 parsed as 0.2.3 under the greedy sed).
  fb=$(fake_copilot "$TMP_ROOT/first-triple-major" 'copilot 10.2.3')
  out=$(PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_harness_version_parts copilot')
  [ "$out" = "10 2 3" ] || fail "two-digit major truncated (got '$out', want '10 2 3')"
  pass "fm_harness_version_parts: anchors to the first dotted triple, full major kept"
}

test_compatible_rejects_old_cli_with_noisy_version_line() {
  # The exact fail-open the anchor fix closes: an incompatible 0.9.0 whose
  # version line carries a later dotted build stamp must NOT pass the gate.
  local fb
  fb=$(fake_copilot "$TMP_ROOT/noisy-old" 'copilot 0.9.0 build 2026.1.15')
  PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_copilot_compatible' \
    && fail "0.9.0 with a trailing build stamp should be incompatible"
  # And a compatible CLI with a noisy line must still pass (no fail-closed drift).
  fb=$(fake_copilot "$TMP_ROOT/noisy-good" 'GitHub Copilot CLI 1.0.68 (node v20.11.1)')
  PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_copilot_compatible' \
    || fail "1.0.68 with a trailing node version should be compatible"
  pass "fm_copilot_compatible: noisy version lines gate on the tool's own version"
}

test_compatible_accepts_and_rejects() {
  local fb
  fb=$(fake_copilot "$TMP_ROOT/good" 'GitHub Copilot CLI 1.0.68.')
  PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_copilot_compatible' \
    || fail "1.0.68 should be compatible"
  fb=$(fake_copilot "$TMP_ROOT/newer" 'GitHub Copilot CLI 1.2.0.')
  PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_copilot_compatible' \
    || fail "1.2.0 should be compatible"
  fb=$(fake_copilot "$TMP_ROOT/old" 'GitHub Copilot CLI 1.0.67.')
  PATH="$fb:$PATH" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_copilot_compatible' \
    && fail "1.0.67 should be incompatible"
  fb=$(fake_copilot "$TMP_ROOT/absent" '')
  PATH="$fb:/usr/bin:/bin" bash -c '. "'"$ROOT"'/bin/fm-harness-policy.sh"; fm_copilot_compatible' \
    && fail "absent copilot should be incompatible"
  pass "fm_copilot_compatible: accepts >= 1.0.68, rejects older/absent"
}

# Integration: an explicit copilot spawn aborts at the gate (before treehouse /
# worktree creation) when the CLI is too old, with an actionable message.
test_spawn_aborts_on_incompatible_copilot() {
  local case_dir home proj fb id out status
  case_dir="$TMP_ROOT/spawn-old"
  home="$case_dir/home"
  proj="$case_dir/project"
  id="copilot-old-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  git init -q "$proj"
  fb=$(fake_copilot "$case_dir/fake" 'GitHub Copilot CLI 1.0.67.')
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fb:$PATH" "$SPAWN" "$id" "$proj" copilot 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should fail on an incompatible copilot"
  assert_contains "$out" "copilot CLI is incompatible" "spawn did not report the incompatible copilot clearly"
  assert_contains "$out" "1.0.68" "spawn error did not mention the required minimum"
  assert_absent "$home/state/$id.meta" "spawn wrote task meta despite failing the version gate"
  pass "fm-spawn aborts an incompatible copilot launch before side effects"
}

# The version-check skip escape hatch lets tests/edge cases bypass the probe.
test_spawn_skip_env_bypasses_gate() {
  local case_dir home proj fb id out
  case_dir="$TMP_ROOT/spawn-skip"
  home="$case_dir/home"
  proj="$case_dir/project"
  id="copilot-skip-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  git init -q "$proj"
  fb=$(fake_copilot "$case_dir/fake" 'GitHub Copilot CLI 1.0.67.')
  # With the skip flag the gate is bypassed; the spawn then fails later (no real
  # tmux/treehouse), so we only assert it did NOT fail with the gate's message.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_SKIP_VERSION_CHECK=1 TMUX="fake,1,0" \
    PATH="$fb:$PATH" "$SPAWN" "$id" "$proj" copilot 2>&1) || true
  assert_not_contains "$out" "copilot CLI is incompatible" "skip flag did not bypass the version gate"
  pass "FM_SPAWN_SKIP_VERSION_CHECK bypasses the copilot version gate"
}

test_version_ge_orders_numerically
test_version_parts_extracts_fields
test_version_parts_anchors_to_first_triple
test_compatible_rejects_old_cli_with_noisy_version_line
test_compatible_accepts_and_rejects
test_spawn_aborts_on_incompatible_copilot
test_spawn_skip_env_bypasses_gate
