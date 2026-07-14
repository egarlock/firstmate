#!/usr/bin/env bash
# Behavior tests for the firstmate local task board (bin/fm-board-server.py and
# bin/fm-board.sh).
#
# The board is a read-mostly UI over firstmate's existing backlog: Queued /
# In flight / Done come from data/backlog.md (the tasks-axi markdown backend),
# and a local data/board-suggestions.json backs the Suggested lane. The server
# doubles as a CLI so every code path is testable without HTTP; one HTTP leg
# proves the same logic over the wire and the loopback-only bind.
#
# Cases:
#   (a) parse            -> board JSON == backlog sections (id/title/repo/kind/
#                           blocked_by/links/notes), suggestions read cleanly
#   (b) empty/missing    -> empty lanes, no crash
#   (c) task detail      -> gathers status/brief/report; missing sources = null
#   (d) reorder valid    -> Queued blocks reordered (notes move too);
#                           In flight / Done untouched; persists to backlog.md
#   (e) reorder invalid  -> rejected, backlog file byte-for-byte unchanged
#   (f) add-suggestion   -> suggestion persisted to the local JSON store
#   (g) promote          -> tasks-axi add creates a Queued item, suggestion
#                           removed only after the add succeeds
#   (h) promote fallback -> with tasks-axi absent, a canonical Queued line is
#                           appended and the suggestion still removed
#   (i) launcher/bind    -> serve refuses a non-loopback host
#   (j) HTTP smoke       -> GET /api/board and POST /api/reorder over 127.0.0.1
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-board-server.py"

command -v python3 >/dev/null 2>&1 || { echo "1..0 # SKIP python3 not available"; exit 0; }

# Build a populated data/ fixture under a temp FM_HOME.
build_home() {  # <home>
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fix-login-k3 - Fix the login redirect (repo: webapp) (kind: ship) (since 2026-07-10)

## Queued
- [ ] add-cache-p9 - Add a response cache (repo: webapp) (kind: ship) (since 2026-07-11)
  First queued note line.
  Second queued note line.
- [ ] audit-db-z1 - Audit the slow query blocked-by: fix-login-k3 (repo: dataapp) (kind: scout) (since 2026-07-12)

## Done
- [x] ship-green-n5 - Shipped the banner https://github.com/o/r/pull/7 (repo: webapp) (kind: ship) (merged 2026-07-09)
EOF
  printf '[{"title":"Add dark mode","project":"webapp","kind":"ship","note":"nice to have"}]\n' \
    > "$home/data/board-suggestions.json"
  # Extra sources for the modal on an active task.
  mkdir -p "$home/data/add-cache-p9"
  printf 'Brief for add-cache-p9.\n' > "$home/data/add-cache-p9/brief.md"
  printf 'working: setup done\nworking: cache wired\n' > "$home/state/add-cache-p9.status"
}

# Run the server CLI with a fixture home; echo stdout, set global RC.
run_cli() {  # <home> <args...>
  local home=$1; shift
  FM_HOME="$home" FM_DATA="$home/data" FM_STATE="$home/state" \
    python3 "$SERVER" "$@"
}

json_get() {  # <python-expr over stdin as `d`>
  python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"
}

# --- (a) parse -------------------------------------------------------------
(
  home=$(fm_test_tmproot fm-board-a); build_home "$home"
  out=$(run_cli "$home" board); RC=$?; expect_code 0 "$RC" "(a) board exits 0"

  q_ids=$(printf '%s' "$out" | json_get "[i['id'] for i in d['queued']]")
  [ "$q_ids" = "['add-cache-p9', 'audit-db-z1']" ] || fail "(a) queued ids wrong: $q_ids"

  f_ids=$(printf '%s' "$out" | json_get "[i['id'] for i in d['in_flight']]")
  [ "$f_ids" = "['fix-login-k3']" ] || fail "(a) in_flight ids wrong: $f_ids"

  done_ids=$(printf '%s' "$out" | json_get "[i['id'] for i in d['done']]")
  [ "$done_ids" = "['ship-green-n5']" ] || fail "(a) done ids wrong: $done_ids"

  title=$(printf '%s' "$out" | json_get "d['queued'][0]['title']")
  [ "$title" = "Add a response cache" ] || fail "(a) title wrong: $title"
  repo=$(printf '%s' "$out" | json_get "d['queued'][0]['repo']")
  [ "$repo" = "webapp" ] || fail "(a) repo wrong: $repo"
  kind=$(printf '%s' "$out" | json_get "d['queued'][1]['kind']")
  [ "$kind" = "scout" ] || fail "(a) kind wrong: $kind"
  blk=$(printf '%s' "$out" | json_get "d['queued'][1]['blocked_by']")
  [ "$blk" = "['fix-login-k3']" ] || fail "(a) blocked_by wrong: $blk"
  notes=$(printf '%s' "$out" | json_get "d['queued'][0]['notes']")
  case "$notes" in *"First queued note line."*"Second queued note line."*) : ;; *) fail "(a) notes wrong: $notes" ;; esac
  link=$(printf '%s' "$out" | json_get "d['done'][0]['links'][0]")
  [ "$link" = "https://github.com/o/r/pull/7" ] || fail "(a) done link wrong: $link"
  sug=$(printf '%s' "$out" | json_get "d['suggested'][0]['id']")
  [ "$sug" = "add-dark-mode" ] || fail "(a) suggestion id wrong: $sug"
  pass "(a) parse: board JSON matches backlog sections and suggestions"
) || exit 1

# --- (b) empty / missing ---------------------------------------------------
(
  home=$(fm_test_tmproot fm-board-b); mkdir -p "$home/data"
  out=$(run_cli "$home" board); RC=$?; expect_code 0 "$RC" "(b) empty exits 0"
  counts=$(printf '%s' "$out" | json_get "{k:len(v) for k,v in d.items()}")
  [ "$counts" = "{'suggested': 0, 'queued': 0, 'in_flight': 0, 'done': 0}" ] \
    || fail "(b) empty board not all-zero: $counts"
  pass "(b) missing backlog/suggestions -> empty lanes, no crash"
) || exit 1

# --- (c) task detail (missing sources are clean) ---------------------------
(
  home=$(fm_test_tmproot fm-board-c); build_home "$home"
  # Active task with brief + status present, report absent.
  out=$(run_cli "$home" task add-cache-p9); RC=$?; expect_code 0 "$RC" "(c) task exits 0"
  found=$(printf '%s' "$out" | json_get "d['found']")
  [ "$found" = "True" ] || fail "(c) task not found"
  brief=$(printf '%s' "$out" | json_get "d['brief']")
  case "$brief" in *"Brief for add-cache-p9."*) : ;; *) fail "(c) brief missing: $brief" ;; esac
  status=$(printf '%s' "$out" | json_get "d['status']")
  case "$status" in *"cache wired"*) : ;; *) fail "(c) status missing: $status" ;; esac
  report=$(printf '%s' "$out" | json_get "repr(d['report'])")
  [ "$report" = "None" ] || fail "(c) absent report should be null, got: $report"

  # Completed task: still resolves, no brief/status.
  out2=$(run_cli "$home" task ship-green-n5); RC=$?; expect_code 0 "$RC" "(c) done task exits 0"
  sect=$(printf '%s' "$out2" | json_get "d['card']['section']")
  [ "$sect" = "Done" ] || fail "(c) done section wrong: $sect"
  dl=$(printf '%s' "$out2" | json_get "d['links'][0]")
  [ "$dl" = "https://github.com/o/r/pull/7" ] || fail "(c) done link wrong: $dl"
  pass "(c) task detail: gathers present sources, nulls missing ones cleanly"
) || exit 1

# --- (d) reorder valid -----------------------------------------------------
(
  home=$(fm_test_tmproot fm-board-d); build_home "$home"
  out=$(run_cli "$home" reorder "audit-db-z1,add-cache-p9"); RC=$?
  expect_code 0 "$RC" "(d) reorder exits 0"

  # Queued order flipped in the durable file.
  q_ids=$(run_cli "$home" board | json_get "[i['id'] for i in d['queued']]")
  [ "$q_ids" = "['audit-db-z1', 'add-cache-p9']" ] || fail "(d) queued not reordered: $q_ids"
  # Notes moved with their item.
  notes=$(run_cli "$home" board | json_get "d['queued'][1]['notes']")
  case "$notes" in *"First queued note line."*) : ;; *) fail "(d) notes lost on reorder: $notes" ;; esac
  # In flight and Done untouched.
  assert_grep "fix-login-k3 - Fix the login redirect" "$home/data/backlog.md" "(d) in-flight preserved"
  assert_grep "ship-green-n5 - Shipped the banner" "$home/data/backlog.md" "(d) done preserved"
  # The note line must still be indented under its item (block integrity).
  assert_grep "  First queued note line." "$home/data/backlog.md" "(d) note stays indented"
  pass "(d) reorder: Queued blocks reordered with notes; In flight/Done intact"
) || exit 1

# --- (e) reorder invalid (not a permutation) -------------------------------
(
  home=$(fm_test_tmproot fm-board-e); build_home "$home"
  before=$(cat "$home/data/backlog.md")
  # Missing an id -> not a permutation -> must be rejected.
  run_cli "$home" reorder "add-cache-p9" >/dev/null 2>&1; RC=$?
  [ "$RC" -ne 0 ] || fail "(e) invalid reorder should exit non-zero"
  after=$(cat "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "(e) invalid reorder mutated the backlog file"
  # An id not in Queued -> rejected too.
  run_cli "$home" reorder "add-cache-p9,audit-db-z1,fix-login-k3" >/dev/null 2>&1; RC=$?
  [ "$RC" -ne 0 ] || fail "(e) reorder with foreign id should be rejected"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "(e) foreign-id reorder mutated backlog"
  pass "(e) reorder invalid: rejected, backlog file unchanged"
) || exit 1

# --- (f) add-suggestion ----------------------------------------------------
(
  home=$(fm_test_tmproot fm-board-f); mkdir -p "$home/data"
  out=$(run_cli "$home" add-suggestion --title "Cache the avatars" --project webapp --kind scout --note "later"); RC=$?
  expect_code 0 "$RC" "(f) add-suggestion exits 0"
  sid=$(printf '%s' "$out" | json_get "d['suggestion']['id']")
  [ "$sid" = "cache-the-avatars" ] || fail "(f) suggestion id wrong: $sid"
  assert_present "$home/data/board-suggestions.json" "(f) suggestions file created"
  assert_grep "Cache the avatars" "$home/data/board-suggestions.json" "(f) suggestion persisted"
  # A second suggestion with the same title gets a unique id.
  out2=$(run_cli "$home" add-suggestion --title "Cache the avatars")
  sid2=$(printf '%s' "$out2" | json_get "d['suggestion']['id']")
  [ "$sid2" != "$sid" ] || fail "(f) duplicate-title suggestion id not made unique: $sid2"
  pass "(f) add-suggestion: persisted to local JSON store, ids unique"
) || exit 1

# --- (g) promote via tasks-axi ---------------------------------------------
if command -v tasks-axi >/dev/null 2>&1; then
(
  home=$(fm_test_tmproot fm-board-g); build_home "$home"
  sid=$(run_cli "$home" board | json_get "d['suggested'][0]['id']")
  out=$(FM_HOME="$home" FM_DATA="$home/data" FM_STATE="$home/state" \
        FM_BOARD_TASKS_FILE="$home/data/backlog.md" \
        python3 "$SERVER" promote "$sid"); RC=$?
  [ "$RC" -eq 0 ] || fail "(g) promote exited non-zero"
  via=$(printf '%s' "$out" | json_get "d['promoted']['via']")
  [ "$via" = "tasks-axi" ] || fail "(g) promote should use tasks-axi, got: $via"
  # New item is in Queued.
  q_ids=$(run_cli "$home" board | json_get "[i['id'] for i in d['queued']]")
  case "$q_ids" in *"add-dark-mode"*) : ;; *) fail "(g) promoted item not in Queued: $q_ids" ;; esac
  # Suggestion removed.
  sug_n=$(run_cli "$home" board | json_get "len(d['suggested'])")
  [ "$sug_n" = "0" ] || fail "(g) suggestion not removed after promote: $sug_n"
  pass "(g) promote: tasks-axi add creates Queued item, suggestion removed"
) || exit 1
else
  pass "(g) promote via tasks-axi SKIPPED (tasks-axi not installed)"
fi

# --- (h) promote fallback (tasks-axi absent) -------------------------------
(
  home=$(fm_test_tmproot fm-board-h); build_home "$home"
  fakebin=$(fm_fakebin "$home")   # empty fakebin (no tasks-axi inside)
  sid=$(run_cli "$home" board | json_get "d['suggested'][0]['id']")
  # Point the server at a tasks-axi that does not exist, forcing the fallback.
  out=$(FM_HOME="$home" FM_DATA="$home/data" FM_STATE="$home/state" \
        FM_BOARD_TASKS_AXI="$fakebin/tasks-axi-missing" \
        python3 "$SERVER" promote "$sid"); RC=$?
  [ "$RC" -eq 0 ] || fail "(h) fallback promote exited non-zero"
  via=$(printf '%s' "$out" | json_get "d['promoted']['via']")
  [ "$via" = "markdown" ] || fail "(h) fallback should be markdown, got: $via"
  assert_grep "add-dark-mode - Add dark mode" "$home/data/backlog.md" "(h) markdown item appended to Queued"
  sug_n=$(run_cli "$home" board | json_get "len(d['suggested'])")
  [ "$sug_n" = "0" ] || fail "(h) suggestion not removed on fallback: $sug_n"
  pass "(h) promote fallback: canonical Queued line appended, suggestion removed"
) || exit 1

# --- (i) serve refuses a non-loopback bind ---------------------------------
(
  home=$(fm_test_tmproot fm-board-i); build_home "$home"
  err=$(FM_HOME="$home" FM_DATA="$home/data" \
        python3 "$SERVER" serve --host 8.8.8.8 --port 8799 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "(i) serve should refuse a non-loopback host"
  case "$err" in *loopback*) : ;; *) fail "(i) refusal message unclear: $err" ;; esac
  pass "(i) serve: refuses to bind a non-loopback host"
) || exit 1

# --- (j) HTTP smoke over 127.0.0.1 -----------------------------------------
if command -v curl >/dev/null 2>&1; then
(
  home=$(fm_test_tmproot fm-board-j); build_home "$home"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  FM_HOME="$home" FM_DATA="$home/data" FM_STATE="$home/state" \
    python3 "$SERVER" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  srv_pid=$!
  # Ensure the server is reaped even if an assertion aborts this subshell.
  trap 'kill "$srv_pid" 2>/dev/null' EXIT

  # Wait for readiness.
  ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -sf "http://127.0.0.1:$port/api/board" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.3
  done
  [ "$ready" = 1 ] || fail "(j) server did not become ready"

  # GET the board.
  b=$(curl -s "http://127.0.0.1:$port/api/board")
  qn=$(printf '%s' "$b" | json_get "len(d['queued'])")
  [ "$qn" = "2" ] || fail "(j) HTTP board queued count wrong: $qn"

  # POST a valid reorder and confirm it persisted.
  curl -s -X POST "http://127.0.0.1:$port/api/reorder" \
    -H 'Content-Type: application/json' \
    -d '{"order":["audit-db-z1","add-cache-p9"]}' >/dev/null
  first=$(curl -s "http://127.0.0.1:$port/api/board" | json_get "d['queued'][0]['id']")
  [ "$first" = "audit-db-z1" ] || fail "(j) HTTP reorder did not persist: $first"

  # POST an invalid reorder -> 400, backlog unchanged order.
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$port/api/reorder" \
    -H 'Content-Type: application/json' -d '{"order":["add-cache-p9"]}')
  [ "$code" = "400" ] || fail "(j) HTTP invalid reorder should be 400, got: $code"

  kill "$srv_pid" 2>/dev/null
  trap - EXIT
  pass "(j) HTTP smoke: board GET + reorder POST over 127.0.0.1"
) || exit 1
else
  pass "(j) HTTP smoke SKIPPED (curl not installed)"
fi

echo "# fm-board: all cases passed"
