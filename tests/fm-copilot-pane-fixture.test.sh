#!/usr/bin/env bash
# Copilot pane busy/idle detection (TUI-drift lock).
#
# firstmate's stale-pane watcher decides a copilot crewmate is still working from
# its pane's busy signature (bin/fm-tmux-lib.sh: fm_pane_is_busy, and the ONE
# consolidated FM_TMUX_BUSY_REGEX_DEFAULT). copilot's working footer carries an
# ASCII cancel hint that changed across CLI versions:
#   1.0.68 (fork's 2026-07-02 verification): "esc cancel"
#       (e.g. "◉ Working · 275 B (esc cancel)"), idle footer
#       "/ commands · ? help · → next tab".
#   1.0.72 (re-verified 2026-07-23): "esc interrupt"
#       (e.g. "◉ Working esc interrupt"), idle footer
#       "/ commands · ? help · tab next tab".
# The spawn version gate floor is 1.0.68, so BOTH generations must read as busy
# and both idle footers as idle. If a copilot release changes the footer again,
# these fixture tests break loudly instead of the watcher silently mistaking a
# live turn for a stall (or vice versa).
#
# These are captured-shape fixtures (real glyphs, incl. the Unicode ◉/·/→/❯) fed
# through the detector: busy -> true, idle -> false. They exercise the whole
# multi-line capture path (tail-of-pane scan), plus the two footers directly
# against the consolidated regex.
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

# A 1.0.68-era copilot pane mid-turn: the working footer with the "esc cancel"
# hint on the last non-blank line (fork's 2026-07-02 capture shape).
write_busy_fixture_10068() {  # <path>
  cat > "$1" <<'PANE'
❯ /no-mistakes

● Working on it — driving the no-mistakes pipeline.
  Running review step…

◉ Working · 275 B (esc cancel)
PANE
}

# A 1.0.72 copilot pane mid-turn: the working footer now reads "esc interrupt"
# (re-verified live 2026-07-23).
write_busy_fixture_10072() {  # <path>
  cat > "$1" <<'PANE'
❯ Run the shell command: env | grep -i copilot ; and after showing the output, stop.

● cmux-msg bridge ready

◉ Working esc interrupt
PANE
}

# A copilot pane at rest: the idle footer plus a bare "❯" composer, no cancel
# hint (1.0.72 shape; the 1.0.68 footer ended "→ next tab" instead).
write_idle_fixture() {  # <path>
  cat > "$1" <<'PANE'
● Done — the change is committed on the branch.

❯
/ commands · ? help · tab next tab
PANE
}

test_busy_pane_detected_10068() {
  local fb busy
  fb=$(make_fake_tmux "$TMP_ROOT/busy68")
  busy="$TMP_ROOT/busy68.pane"
  write_busy_fixture_10068 "$busy"
  FM_FAKE_PANE="$busy" PATH="$fb:$PATH" \
    bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_pane_is_busy fake:win' \
    || fail "copilot 1.0.68 busy pane (esc cancel footer) should read as busy"
  pass "fm_pane_is_busy: copilot 1.0.68 working footer reads as busy"
}

test_busy_pane_detected_10072() {
  local fb busy
  fb=$(make_fake_tmux "$TMP_ROOT/busy72")
  busy="$TMP_ROOT/busy72.pane"
  write_busy_fixture_10072 "$busy"
  FM_FAKE_PANE="$busy" PATH="$fb:$PATH" \
    bash -c '. "'"$ROOT"'/bin/fm-tmux-lib.sh"; fm_pane_is_busy fake:win' \
    || fail "copilot 1.0.72 busy pane (esc interrupt footer) should read as busy"
  pass "fm_pane_is_busy: copilot 1.0.72 working footer reads as busy"
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

# Also lock the footers directly against the ONE consolidated busy regex, so a
# drift in the source regex (not just the detector wiring) is caught here too.
test_footers_against_consolidated_regex() {
  local re=$FM_TMUX_BUSY_REGEX_DEFAULT
  printf '%s\n' '◉ Working · 275 B (esc cancel)' | grep -qiE "$re" \
    || fail "consolidated busy regex should match copilot's 1.0.68 working footer"
  printf '%s\n' '◉ Working esc interrupt' | grep -qiE "$re" \
    || fail "consolidated busy regex should match copilot's 1.0.72 working footer"
  printf '%s\n' '/ commands · ? help · → next tab' | grep -qiE "$re" \
    && fail "consolidated busy regex must NOT match copilot's 1.0.68 idle footer"
  printf '%s\n' '/ commands · ? help · tab next tab' | grep -qiE "$re" \
    && fail "consolidated busy regex must NOT match copilot's 1.0.72 idle footer"
  # The trust dialog's "esc to cancel" nav hint must not read as the busy
  # "esc cancel" (a pending dialog is not a running turn).
  printf '%s\n' '↑/↓ to navigate · enter to select · esc to cancel' | grep -qiE "$re" \
    && fail "consolidated busy regex must NOT match the trust dialog nav hint"
  pass "FM_TMUX_BUSY_REGEX_DEFAULT: matches copilot busy footers, not idle/dialog text"
}

test_busy_pane_detected_10068
test_busy_pane_detected_10072
test_idle_pane_not_busy
test_footers_against_consolidated_regex
