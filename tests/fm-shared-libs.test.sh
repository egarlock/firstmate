#!/usr/bin/env bash
# tests/fm-shared-libs.test.sh - equivalence tests for the shared helper libs
# that consolidate what used to be copy-pasted across bin/:
#   fm-git-lib.sh   fm_default_branch      (was 6 byte-identical copies)
#   fm-path-lib.sh  path_is_ancestor_of    (was 5 byte-identical copies)
#   fm-env-lib.sh   fm_env_init            (FM_ROOT/FM_HOME/STATE resolution)
#   fm-tmux-lib.sh  FM_TMUX_BUSY_REGEX_DEFAULT (busy regex, now consumed by fm-watch)
#   fm-tmux-lib.sh  fm_tmux_pane_exists    (the tmux pane-liveness probe)
#
# Each case pins the behavior the old duplicated bodies had, and an invariant
# block asserts each helper is now defined exactly once and every former
# duplicate site sources the lib. Pure refactor: these prove no behavior change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-shared-libs)
fm_git_identity fmtest fmtest@example.invalid

# --- fm-git-lib.sh: fm_default_branch ---------------------------------------

# The old copies: prefer origin/HEAD (stripped of "origin/"), else local main,
# else local master, else return 1. Pin each branch of that fallback.
test_default_branch() {
  # shellcheck source=bin/fm-git-lib.sh
  . "$ROOT/bin/fm-git-lib.sh"

  # (a) origin/HEAD wins and is stripped of the origin/ prefix.
  local r="$TMP_ROOT/db-origin"
  git init -q -b main "$r"; git -C "$r" commit -q --allow-empty -m init
  git -C "$r" update-ref refs/remotes/origin/trunk "$(git -C "$r" rev-parse HEAD)"
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  [ "$(fm_default_branch "$r")" = trunk ] || fail "default_branch: origin/HEAD should win as 'trunk'"

  # (b) no origin/HEAD, local main present -> main.
  local m="$TMP_ROOT/db-main"
  git init -q -b main "$m"; git -C "$m" commit -q --allow-empty -m init
  [ "$(fm_default_branch "$m")" = main ] || fail "default_branch: should fall back to main"

  # (c) no origin/HEAD, no main, local master present -> master.
  local s="$TMP_ROOT/db-master"
  git init -q -b master "$s"; git -C "$s" commit -q --allow-empty -m init
  [ "$(fm_default_branch "$s")" = master ] || fail "default_branch: should fall back to master"

  # (d) neither main nor master -> return 1, no output.
  local n="$TMP_ROOT/db-none"
  git init -q -b dev "$n"; git -C "$n" commit -q --allow-empty -m init
  local out; out=$(fm_default_branch "$n") && fail "default_branch: should return non-zero with no main/master"
  [ -z "$out" ] || fail "default_branch: should print nothing on failure, got '$out'"

  pass "fm_default_branch: origin/HEAD > main > master fallback, else non-zero"
}

# --- fm-path-lib.sh: path_is_ancestor_of ------------------------------------

test_path_is_ancestor_of() {
  # shellcheck source=bin/fm-path-lib.sh
  . "$ROOT/bin/fm-path-lib.sh"

  path_is_ancestor_of /a /a/b            || fail "ancestor: /a should be ancestor of /a/b"
  path_is_ancestor_of /a /a/b/c/d        || fail "ancestor: /a should be ancestor of /a/b/c/d"
  path_is_ancestor_of /a /b              && fail "ancestor: unrelated paths are not ancestors"
  path_is_ancestor_of /a /a              && fail "ancestor: equal paths are not strict ancestors"
  path_is_ancestor_of /a/bc /a/b         && fail "ancestor: prefix-but-not-path-boundary is not an ancestor"
  path_is_ancestor_of "" /a              && fail "ancestor: empty ancestor is false"
  path_is_ancestor_of /a ""              && fail "ancestor: empty path is false"
  pass "path_is_ancestor_of: strict lexical descendant only; equal/empty/prefix are false"
}

# --- fm-env-lib.sh: fm_env_init ---------------------------------------------

# Run fm_env_init in a clean subshell with the given environment and echo the
# resolved triple, so each precedence case is independent.
env_probe() {  # env assignments passed as args, e.g. FM_HOME=/h
  # shellcheck disable=SC2016  # the bash -c body is deliberately unexpanded here
  env -i PATH="$PATH" "$@" bash -c '
    SCRIPT_DIR="'"$ROOT"'/bin"
    . "'"$ROOT"'/bin/fm-env-lib.sh"
    fm_env_init
    printf "%s|%s|%s\n" "$FM_ROOT" "$FM_HOME" "$STATE"
  '
}

test_env_init() {
  local repo_root out
  repo_root=$(cd "$ROOT" && pwd)

  # (a) no overrides: FM_ROOT is the repo root (bin/..), FM_HOME=FM_ROOT, STATE under it.
  out=$(env_probe)
  [ "$out" = "$repo_root|$repo_root|$repo_root/state" ] \
    || fail "env_init default: expected '$repo_root|$repo_root|$repo_root/state', got '$out'"

  # (b) FM_ROOT_OVERRIDE wins for FM_ROOT and (via the chain) FM_HOME.
  out=$(env_probe FM_ROOT_OVERRIDE=/x)
  [ "$out" = "/x|/x|/x/state" ] || fail "env_init FM_ROOT_OVERRIDE: expected '/x|/x|/x/state', got '$out'"

  # (c) FM_HOME set explicitly wins for FM_HOME (and STATE derives from it).
  out=$(env_probe FM_HOME=/h)
  [ "$out" = "$repo_root|/h|/h/state" ] || fail "env_init FM_HOME: expected '$repo_root|/h|/h/state', got '$out'"

  # (d) FM_STATE_OVERRIDE wins for STATE regardless of FM_HOME.
  out=$(env_probe FM_HOME=/h FM_STATE_OVERRIDE=/y)
  [ "$out" = "$repo_root|/h|/y" ] || fail "env_init FM_STATE_OVERRIDE: expected '$repo_root|/h|/y', got '$out'"

  pass "fm_env_init: FM_ROOT/FM_HOME/STATE resolution honors the same override precedence"
}

# --- fm-tmux-lib.sh: busy regex + pane-exists probe -------------------------

test_busy_regex() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  local re=$FM_TMUX_BUSY_REGEX_DEFAULT footer
  # Each verified per-harness busy footer must match the one canonical regex.
  for footer in "esc to interrupt" "esc interrupt" "Working..." "Ctrl+c:cancel" "esc cancel"; do
    printf '%s\n' "$footer" | grep -qiE "$re" || fail "busy regex should match footer: '$footer'"
  done
  # An idle footer must NOT match.
  printf '%s\n' "/ commands  ? help" | grep -qiE "$re" && fail "busy regex should not match an idle footer"
  pass "FM_TMUX_BUSY_REGEX_DEFAULT: matches every verified busy footer, not idle text"
}

# fm_tmux_pane_exists is literally `tmux display-message -p -t <target> '#{pane_id}'`;
# fake tmux to prove it forwards the target and propagates the exit status.
test_pane_exists() {
  local fake; fake=$(fm_fakebin "$TMP_ROOT")
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
# Fake tmux: succeed only for display-message -t good:pane.
tgt=""; prev=""
for a in "$@"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; done
[ "$tgt" = "good:pane" ] && exit 0 || exit 1
SH
  chmod +x "$fake/tmux"
  PATH="$fake:$PATH" bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_tmux_pane_exists good:pane' \
    || fail "pane_exists: should return 0 when tmux reports the pane exists"
  PATH="$fake:$PATH" bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_tmux_pane_exists bad:pane' \
    && fail "pane_exists: should return non-zero when tmux cannot resolve the pane"
  pass "fm_tmux_pane_exists: forwards the target and propagates tmux's exit status"
}

# --- invariants: one definition each, and former sites source the lib -------

test_single_definitions() {
  local n
  n=$(grep -rlE '^[[:space:]]*(fm_)?default_branch\(\)' "$ROOT"/bin | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "fm_default_branch must be defined once, found in $n files"
  n=$(grep -rlE '^[[:space:]]*path_is_ancestor_of\(\)' "$ROOT"/bin | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "path_is_ancestor_of must be defined once, found in $n files"
  n=$(grep -rlE '^[[:space:]]*fm_env_init\(\)' "$ROOT"/bin | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "fm_env_init must be defined once, found in $n files"
  # The busy regex literal lives in exactly one place (its definition line).
  n=$(grep -rl "esc (to )?interrupt|Working" "$ROOT"/bin | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "busy regex literal must appear once, found in $n files"
  pass "each consolidated helper/literal now has exactly one definition in bin/"
}

test_former_sites_source_libs() {
  local f
  # The six former default_branch sites source fm-git-lib.sh.
  for f in fm-teardown.sh fm-merge-local.sh fm-review-diff.sh fm-fleet-sync.sh fm-ff-lib.sh fm-tangle-lib.sh; do
    grep -q 'fm-git-lib.sh' "$ROOT/bin/$f" || fail "$f should source fm-git-lib.sh"
  done
  # The five former path_is_ancestor_of sites reach fm-path-lib.sh (fm-spawn also
  # gets it transitively via fm-ff-lib, but sources it directly too).
  for f in fm-teardown.sh fm-spawn.sh fm-home-seed.sh fm-backlog-handoff.sh fm-ff-lib.sh; do
    grep -q 'fm-path-lib.sh' "$ROOT/bin/$f" || fail "$f should source fm-path-lib.sh"
  done
  # fm-watch.sh consumes the shared busy regex instead of re-literaling it.
  grep -q 'fm-tmux-lib.sh' "$ROOT/bin/fm-watch.sh" || fail "fm-watch.sh should source fm-tmux-lib.sh"
  # shellcheck disable=SC2016  # matching the literal source line, not expanding it
  grep -q 'BUSY_REGEX=${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}' "$ROOT/bin/fm-watch.sh" \
    || fail "fm-watch.sh should use FM_TMUX_BUSY_REGEX_DEFAULT"
  pass "every former duplicate site sources its shared lib"
}

test_default_branch
test_path_is_ancestor_of
test_env_init
test_busy_regex
test_pane_exists
test_single_definitions
test_former_sites_source_libs

pass "fm-shared-libs: all shared-helper equivalence checks passed"
