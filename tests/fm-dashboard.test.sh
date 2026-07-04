#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh - the read-only fleet dashboard.
#
# The generator joins state/*.meta with the current state reported by
# fm-crew-state.sh and the latest state/<id>.status line, groups by project,
# surfaces parked/blocked/needs-decision/PR-ready work in a "Needs attention"
# band, and renders data/backlog.md. These cases pin, hermetically over fixture
# meta/status/backlog files plus a deterministic fake crew-state command:
#   (a) empty fleet                 -> "No active work", clean exit
#   (b) busy fleet                  -> a row per task, backlog rendered
#   (c) attention band              -> parked/blocked/PR-ready in, plain working out
#   (d) PR awaiting merge           -> "PR ready" pill + clickable link
#   (e) meta attributes             -> harness/kind/mode/yolo chips
#   (f) HTML escaping               -> status markup is neutralized
#   (g) strictly read-only          -> state/ and data/ are never mutated
#   (h) --stdout                    -> HTML to stdout, no file written, lavish untouched
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

# A fake fm-crew-state.sh that maps a fixed id -> a canonical crew-state line,
# so the generator's state join is exercised without a live no-mistakes/tmux.
make_fake_crew_state() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1" in
  fix-login-k3) echo "state: working · source: run-step · validating (running)" ;;
  add-cache-p9) echo "state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: captain decision)" ;;
  audit-db-z1)  echo "state: done · source: run-step · checks green: PR ready for review" ;;
  ship-green-n5) echo "state: done · source: run-step · checks green: PR ready for review" ;;
  wedged-x2)    echo "state: blocked · source: status-log · stuck on migration" ;;
  *)            echo "state: unknown · source: none · no metadata" ;;
esac
SH
  chmod +x "$1"
}

# Build a populated FM_HOME fixture (state/*.meta, *.status, data/backlog.md).
build_busy_home() {  # <home>
  local home=$1
  mkdir -p "$home/state" "$home/data"

  cat > "$home/state/fix-login-k3.meta" <<EOF
window=firstmate:fm-fix-login-k3
worktree=/x/wt/fix-login-k3
project=/home/projects/webapp
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
  cat > "$home/state/add-cache-p9.meta" <<EOF
window=firstmate:fm-add-cache-p9
worktree=/x/wt/add-cache-p9
project=/home/projects/webapp
harness=codex
kind=ship
mode=no-mistakes
yolo=on
model=gpt-5.5
effort=high
EOF
  cat > "$home/state/audit-db-z1.meta" <<EOF
window=firstmate:fm-audit-db-z1
worktree=/x/wt/audit-db-z1
project=/home/projects/api
harness=claude
kind=ship
mode=direct-PR
yolo=off
model=default
effort=default
pr=https://github.com/acme/api/pull/42
EOF
  cat > "$home/state/ship-green-n5.meta" <<EOF
window=firstmate:fm-ship-green-n5
worktree=/x/wt/ship-green-n5
project=/home/projects/api
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
pr=https://github.com/acme/api/pull/57
EOF
  cat > "$home/state/wedged-x2.meta" <<EOF
window=firstmate:fm-wedged-x2
worktree=/x/wt/wedged-x2
project=/home/projects/api
harness=claude
kind=scout
mode=no-mistakes
yolo=off
EOF

  echo "working: implementing login fix" >> "$home/state/fix-login-k3.status"
  printf 'working: started\nneeds-decision: two lint findings need a call\n' >> "$home/state/add-cache-p9.status"
  echo "done: PR https://github.com/acme/api/pull/42 checks green" >> "$home/state/audit-db-z1.status"
  echo "done: PR https://github.com/acme/api/pull/57 checks green" >> "$home/state/ship-green-n5.status"
  echo "blocked: migration tool missing" >> "$home/state/wedged-x2.status"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] fix-login-k3 - fix broken login redirect (repo: webapp, since 2026-07-02)

## Queued
- [ ] new-navbar-q4 - redesign navbar (repo: webapp) blocked-by: fix-login-k3 - overlapping files

## Done
- [x] old-task-a1 - earlier fix - https://github.com/acme/webapp/pull/12 (merged 2026-07-01)
EOF
}

run_dash() {  # <home> <crew-state-cmd> [args...]
  local home=$1 cs=$2
  shift 2
  FM_HOME="$home" FM_DASHBOARD_CREW_STATE_CMD="$cs" "$DASH" "$@"
}

# Print only the "Needs attention" <section> of an HTML file.
attention_section() {  # <html-file>
  awk '/Needs attention/{f=1} f{print} f&&/<\/section>/{exit}' "$1"
}

# Print the task-row line for a given id (emit_task_row prints one <tr> per line).
task_row() {  # <html-file> <id>
  grep "c-id[^>]*>.*$2<" "$1" | head -1
}

# ---------------------------------------------------------------------------
# (a) empty fleet
# ---------------------------------------------------------------------------
EMPTY="$TMP_ROOT/empty"
mkdir -p "$EMPTY/state" "$EMPTY/data"
FAKE_CS="$TMP_ROOT/fake-crew-state.sh"
make_fake_crew_state "$FAKE_CS"

out=$(run_dash "$EMPTY" "$FAKE_CS" --stdout)
rc=$?
expect_code 0 "$rc" "empty fleet exits 0"
assert_contains "$out" "No active work" "empty fleet shows empty state"
assert_contains "$out" "</html>" "empty fleet renders a complete document"
pass "(a) empty fleet renders a clean empty state"

# ---------------------------------------------------------------------------
# (b)-(f) busy fleet
# ---------------------------------------------------------------------------
BUSY="$TMP_ROOT/busy"
build_busy_home "$BUSY"
HTML="$TMP_ROOT/busy.html"
run_dash "$BUSY" "$FAKE_CS" --out "$HTML" --no-open >/dev/null
[ -f "$HTML" ] || fail "(b) --out did not write the HTML file"

body=$(cat "$HTML")
assert_not_contains "$body" "No active work" "busy fleet does not show empty state"
for id in fix-login-k3 add-cache-p9 audit-db-z1 ship-green-n5 wedged-x2; do
  assert_contains "$body" "$id" "busy fleet includes task $id"
done
# Backlog rendered.
assert_contains "$body" "new-navbar-q4" "busy fleet renders the Queued backlog item"
assert_contains "$body" "https://github.com/acme/webapp/pull/12" "backlog Done link rendered"
# The URL appears once as a clickable anchor, not also inline in the raw text.
back_row=$(grep 'old-task-a1' "$HTML" | head -1)
back_text=${back_row%%<div class=\"pr\"*}
assert_not_contains "$back_text" "https://github.com/acme/webapp/pull/12" \
  "backlog inline text drops the URL now rendered as a clickable link"
assert_contains "$back_text" "earlier fix" "backlog inline text keeps the item description"
# Project grouping labels present.
assert_contains "$body" ">webapp<" "project grouping label webapp present"
assert_contains "$body" ">api<" "project grouping label api present"
pass "(b) busy fleet renders every task and the backlog"

# (c) attention band: parked/blocked/PR-ready in; plain working NOT in it.
att=$(attention_section "$HTML")
assert_contains "$att" "Needs attention" "attention band header present"
assert_contains "$att" "add-cache-p9" "parked task surfaced in attention band"
assert_contains "$att" "wedged-x2" "blocked task surfaced in attention band"
assert_contains "$att" "audit-db-z1" "PR-open task surfaced in attention band"
assert_contains "$att" "ship-green-n5" "PR-ready task surfaced in attention band"
assert_not_contains "$att" "fix-login-k3" "plain working task NOT surfaced in attention band"
pass "(c) attention band surfaces only actionable work"

# (d) PR awaiting merge. Mode-aware pill: no-mistakes -> "PR ready" (recorded at
# checks-green), any other mode (direct-PR here) -> "PR open" (recorded at PR-open).
audit_row=$(task_row "$HTML" audit-db-z1)
green_row=$(task_row "$HTML" ship-green-n5)
assert_contains "$green_row" '<span class="pill s-merge">PR ready</span>' \
  "no-mistakes PR pill reads 'PR ready'"
assert_not_contains "$green_row" '<span class="pill s-merge">PR open</span>' \
  "no-mistakes PR pill is not 'PR open'"
assert_contains "$audit_row" '<span class="pill s-merge">PR open</span>' \
  "direct-PR PR pill reads 'PR open'"
assert_not_contains "$audit_row" '<span class="pill s-merge">PR ready</span>' \
  "direct-PR PR pill is not 'PR ready'"
assert_contains "$body" "https://github.com/acme/api/pull/42" "PR link present and clickable"
pass "(d) PR awaiting merge is flagged with a mode-aware pill and link"

# (e) meta attribute chips.
assert_contains "$body" "codex" "harness chip rendered"
assert_contains "$body" "gpt-5.5" "model chip rendered"
assert_contains "$body" "scout" "kind chip rendered for the scout task"
assert_contains "$body" "yolo" "yolo chip rendered for the yolo-on task"
pass "(e) task meta attributes are shown as chips"

# (f) HTML escaping of status text.
ESC="$TMP_ROOT/esc"
build_busy_home "$ESC"
echo 'working: danger <script>alert(1)</script> & "q"' >> "$ESC/state/fix-login-k3.status"
ehtml=$(run_dash "$ESC" "$FAKE_CS" --stdout)
assert_contains "$ehtml" "&lt;script&gt;alert(1)&lt;/script&gt;" "status markup is HTML-escaped"
assert_not_contains "$ehtml" "<script>alert(1)" "raw markup never reaches the document"
pass "(f) untrusted status text is HTML-escaped"

# ---------------------------------------------------------------------------
# (g) strictly read-only: state/ and data/ are never mutated
# ---------------------------------------------------------------------------
RO="$TMP_ROOT/ro"
build_busy_home "$RO"
snapshot() {  # <home>
  ( cd "$1" && find state data -type f 2>/dev/null | sort |
      while IFS= read -r f; do printf '%s %s\n' "$(shasum "$f" | cut -d' ' -f1)" "$f"; done )
}
before=$(snapshot "$RO")
run_dash "$RO" "$FAKE_CS" --stdout >/dev/null
run_dash "$RO" "$FAKE_CS" --out "$RO/.lavish/d.html" --no-open >/dev/null
after=$(snapshot "$RO")
[ "$before" = "$after" ] || fail "(g) dashboard mutated state/ or data/:"$'\n'"$(diff <(printf '%s' "$before") <(printf '%s' "$after"))"
pass "(g) generator never writes under state/ or data/"

# ---------------------------------------------------------------------------
# (h) --stdout writes no file and never invokes lavish
# ---------------------------------------------------------------------------
STDO="$TMP_ROOT/stdo"
build_busy_home "$STDO"
# A fake lavish-axi that would leave a marker if ever called.
FB=$(fm_fakebin "$TMP_ROOT")
cat > "$FB/lavish-axi" <<SH
#!/usr/bin/env bash
touch "$TMP_ROOT/lavish-was-called"
exit 0
SH
chmod +x "$FB/lavish-axi"
sout=$(PATH="$FB:$PATH" run_dash "$STDO" "$FAKE_CS" --stdout)
assert_contains "$sout" "<!DOCTYPE html>" "--stdout emits the HTML document"
assert_absent "$STDO/.lavish/fleet-dashboard.html" "(h) --stdout wrote no default artifact"
assert_absent "$TMP_ROOT/lavish-was-called" "(h) --stdout never invoked lavish-axi"
pass "(h) --stdout is a pure read-only preview"

pass "fm-dashboard: all checks passed"
