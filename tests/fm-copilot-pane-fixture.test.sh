#!/usr/bin/env bash
# Copilot pane busy/idle detection (TUI-drift lock).
#
# firstmate's stale-pane watcher decides a copilot crewmate is still working from
# its pane's busy signature (bin/fm-tmux-lib.sh: fm_pane_is_busy, and the ONE
# consolidated FM_TMUX_BUSY_REGEX_DEFAULT). copilot's working footer carries the
# ASCII cancel hint "esc cancel" (e.g. "◉ Working · 275 B esc cancel"); its idle
# footer is "/ commands · ? help · → next tab" with a bare "❯" composer. If a
# copilot release changes that footer, this fixture test breaks loudly instead of
# the watcher silently mistaking a live turn for a stall (or vice versa).
#
# These are captured-shape fixtures (real glyphs, incl. the Unicode ◉/·/→/❯) fed
# through the detector: busy -> true, idle -> false. It mirrors the busy-regex
# footer check in fm-shared-libs.test.sh, but exercises the whole multi-line
# capture path (tail-of-pane scan) rather than a single footer string.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-pane)

# A fake tmux that serves a pane fixture for capture-pane. fm_pane_is_busy calls
# `tmux capture-pane -p -t <win> -S -40`; this returns $FM_FAKE_PANE verbatim, the
# same way a real captured copilot pane would look.
make_fake_tmux() {  # <dir>
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane) cat "${FM_FAKE_PANE:-/dev/null}" 2>/dev/null; exit 0 ;;
  display-message) printf 'fakepane\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A copilot pane mid-turn: the working footer with the "esc cancel" hint on the
# last non-blank line.
write_busy_fixture() {  # <path>
  cat > "$1" <<'PANE'
❯ /no-mistakes

● Working on it — driving the no-mistakes pipeline.
  Running review step…

◉ Working · 275 B (esc cancel)
PANE
}

# A copilot pane at rest: the idle footer plus a bare "❯" composer, no cancel hint.
write_idle_fixture() {  # <path>
  cat > "$1" <<'PANE'
● Done — the change is committed on the branch.

❯
/ commands · ? help · → next tab
PANE
}

test_busy_pane_detected() {
  local fb busy
  fb=$(make_fake_tmux "$TMP_ROOT/busy")
  busy="$TMP_ROOT/busy.pane"
  write_busy_fixture "$busy"
  FM_FAKE_PANE="$busy" PATH="$fb:$PATH" \
    bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_pane_is_busy fake:win' \
    || fail "copilot busy pane (esc cancel footer) should read as busy"
  pass "fm_pane_is_busy: copilot working footer reads as busy"
}

test_idle_pane_not_busy() {
  local fb idle
  fb=$(make_fake_tmux "$TMP_ROOT/idle")
  idle="$TMP_ROOT/idle.pane"
  write_idle_fixture "$idle"
  FM_FAKE_PANE="$idle" PATH="$fb:$PATH" \
    bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_pane_is_busy fake:win' \
    && fail "copilot idle pane (commands/help footer) should NOT read as busy"
  pass "fm_pane_is_busy: copilot idle footer/composer reads as idle"
}

# Also lock the two footers directly against the ONE consolidated busy regex, so a
# drift in the source regex (not just the detector wiring) is caught here too.
test_footers_against_consolidated_regex() {
  local re=$FM_TMUX_BUSY_REGEX_DEFAULT
  printf '%s\n' '◉ Working · 275 B (esc cancel)' | grep -qiE "$re" \
    || fail "consolidated busy regex should match copilot's working footer"
  printf '%s\n' '/ commands · ? help · → next tab' | grep -qiE "$re" \
    && fail "consolidated busy regex must NOT match copilot's idle footer"
  pass "FM_TMUX_BUSY_REGEX_DEFAULT: matches copilot busy footer, not its idle footer"
}

test_busy_pane_detected
test_idle_pane_not_busy
test_footers_against_consolidated_regex
