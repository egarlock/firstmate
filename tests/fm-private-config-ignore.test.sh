#!/usr/bin/env bash
# Guards the repo's own privacy boundary for config/.
#
# config/ is captain-private local operating choices (AGENTS.md section 2). The
# ignore used to enumerate one line per known config file, so every new private
# config knob was untracked-but-visible until someone remembered to extend the
# list, and `git add -A` in a hurry could commit it. A directory-wide ignore
# makes the boundary hold for paths that do not exist yet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_ignored() {
  local path="$1" why="$2"
  git -C "$ROOT" check-ignore -q -- "$path" \
    || fail "$why: git does not ignore $path"
}

# The point of the directory-wide ignore: a knob nobody has invented yet is
# private the moment it is written, with no .gitignore edit.
test_future_and_nested_config_paths_are_ignored() {
  assert_ignored 'config/not-invented-yet' 'an arbitrary future config knob must be private'
  assert_ignored 'config/some-future-thing.json' 'a future structured config file must be private'
  assert_ignored 'config/nested/deep/secret.env' 'a nested config path must be private'
  pass "config/: arbitrary future and nested private config paths are ignored"
}

# The documented knobs stay covered, so the directory-wide rule is a
# generalization of the old enumeration rather than a replacement that dropped
# something.
test_documented_config_knobs_remain_ignored() {
  local knob
  for knob in crew-harness crew-dispatch.json secondmate-harness secondmate-backend \
    backlog-backend backend herdr-presentation-spaces cmux-container \
    cmux-socket-password wedge-alarm harbor-watch.json x-mode.env; do
    assert_ignored "config/$knob" "documented private config knob $knob must stay private"
  done
  pass "config/: every documented private knob remains ignored"
}

# The ignore must not be enumerated again: a per-file list is what let new knobs
# slip through, so reintroducing one is the regression.
test_ignore_rule_is_directory_wide() {
  local enumerated
  enumerated=$(grep -nE '^config/.+' "$ROOT/.gitignore") || true
  [ -z "$enumerated" ] \
    || fail ".gitignore enumerates individual config paths again instead of ignoring config/ as a directory: $enumerated"
  grep -qxF 'config/' "$ROOT/.gitignore" \
    || fail ".gitignore lost its directory-wide config/ ignore"
  pass "config/: the ignore is directory-wide, not an enumeration"
}

test_future_and_nested_config_paths_are_ignored
test_documented_config_knobs_remain_ignored
test_ignore_rule_is_directory_wide
