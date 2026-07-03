#!/usr/bin/env bash
# tests/fm-adapter-consistency.test.sh - cross-consistency check for the verified
# harness-adapter list.
#
# The canonical set of verified adapters lives in exactly one place:
# bin/fm-harness-policy.sh's FM_VERIFIED_ADAPTERS. Prose that enumerates the
# adapters (the README requirements line, docs/configuration.md's harness-support
# section, docs/architecture.md's launch-compatibility note) has repeatedly drifted
# when a new adapter was added to the policy but not the docs - copilot shipped in
# the code while all three docs still said "claude, codex, opencode, pi, grok".
#
# This test greps the policy source for the canonical list, then asserts every doc
# that enumerates adapters names ALL of them, so that drift fails CI instead of
# silently shipping. It is hermetic (only reads tracked files) and runs in the
# normal tests/*.test.sh sweep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLICY="$ROOT/bin/fm-harness-policy.sh"

# The doc files that enumerate the verified adapter set in prose. An enumeration
# line is identified as one naming both `claude` and `codex` together (the stable
# signature of the adapter list); each such line must name every canonical adapter.
DOCS="README.md docs/configuration.md docs/architecture.md"

# --- canonical list ---------------------------------------------------------

test_canonical_extractable() {
  local canon
  canon=$(sed -n "s/^FM_VERIFIED_ADAPTERS='\([^']*\)'.*/\1/p" "$POLICY")
  [ -n "$canon" ] || fail "could not extract FM_VERIFIED_ADAPTERS from $POLICY"
  # Sanity: copilot was the drift-prone late addition; it must be in the source.
  assert_contains " $canon " " copilot " "FM_VERIFIED_ADAPTERS missing copilot"
  pass "canonical adapter list is extractable from bin/fm-harness-policy.sh ($canon)"
}

# --- docs name every canonical adapter --------------------------------------

test_docs_enumerate_all_adapters() {
  local canon adapter doc line found_line
  canon=$(sed -n "s/^FM_VERIFIED_ADAPTERS='\([^']*\)'.*/\1/p" "$POLICY")
  [ -n "$canon" ] || fail "could not extract FM_VERIFIED_ADAPTERS from $POLICY"

  for doc in $DOCS; do
    [ -f "$ROOT/$doc" ] || fail "adapter-enumerating doc not found: $doc"
    found_line=0
    # Each enumeration line (names both claude and codex) must name every adapter.
    # grep -w so each adapter matches as a whole word regardless of surrounding
    # punctuation ("(claude", "codex,", "or copilot") and so "pi" never matches
    # inside "pipeline".
    while IFS= read -r line; do
      found_line=1
      for adapter in $canon; do
        printf '%s' "$line" | grep -qw "$adapter" \
          || fail "$doc enumerates adapters but omits '$adapter': $line"
      done
    done < <(grep -E 'claude' "$ROOT/$doc" | grep -E 'codex')
    [ "$found_line" -eq 1 ] || fail "$doc has no adapter enumeration line (expected one naming claude and codex)"
  done
  pass "README and docs enumerate every adapter in FM_VERIFIED_ADAPTERS"
}

test_canonical_extractable
test_docs_enumerate_all_adapters
