#!/usr/bin/env bash
# fm-dashboard.sh - live, read-only fleet dashboard for firstmate.
#
# Peeking panes one at a time is the only way to see fleet status today. This
# script reads firstmate's own live state and emits a single self-contained HTML
# view of everything in flight, then hands it to lavish-axi as a review surface.
#
# It joins two sources:
#   1. In-flight tasks from state/*.meta (id, project, harness, model, kind,
#      mode, yolo, window, pr) joined with the current state reported by
#      bin/fm-crew-state.sh <id> (working / parked / done / blocked / failed /
#      unknown) and the latest line of state/<id>.status.
#   2. The backlog from data/backlog.md (In flight / Queued / Done sections).
#      data/backlog.md IS the tasks-axi markdown backend's on-disk file, so we
#      read it directly: dependency-free, canonical, and always present.
#
# Tasks that are parked, blocked, needing a decision, failed, or holding a PR
# awaiting merge are surfaced in a "Needs attention" band at the top. Rows are
# grouped by project.
#
# STRICTLY READ-ONLY with respect to fleet state: it never writes under state/,
# data/, or projects/. The only file it writes is the HTML artifact (default
# under .lavish/, which is gitignored), and it reads the wall clock for the
# generated-at stamp. Use --stdout to emit the HTML without touching disk at all.
#
# Usage:
#   bin/fm-dashboard.sh                 # render + open via lavish-axi
#   bin/fm-dashboard.sh --out <path>    # render to <path>, open via lavish-axi
#   bin/fm-dashboard.sh --no-open       # render to default path, do not open
#   bin/fm-dashboard.sh --stdout        # emit HTML to stdout, do not open
#
# Bash 3.2 compatible (stock macOS /bin/bash).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# The crew-state helper is injectable so tests can substitute a deterministic
# fake without a live no-mistakes/tmux environment.
CREW_STATE_CMD="${FM_DASHBOARD_CREW_STATE_CMD:-$SCRIPT_DIR/fm-crew-state.sh}"

# Field separator packed into each in-flight task record (ASCII unit separator);
# never appears in the meta/status text we render.
US=$(printf '\037')

usage() {
  cat <<'USAGE'
fm-dashboard.sh - live, read-only fleet dashboard for firstmate.

  bin/fm-dashboard.sh                 render + open via lavish-axi
  bin/fm-dashboard.sh --out <path>    render to <path>, open via lavish-axi
  bin/fm-dashboard.sh --no-open       render to default path, do not open
  bin/fm-dashboard.sh --stdout        emit HTML to stdout, do not open (read-only)
USAGE
  exit "${1:-0}"
}

OUT=""
OPEN=1
TO_STDOUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT="${1:-}"; [ -n "$OUT" ] || { echo "fm-dashboard: --out needs a path" >&2; exit 2; } ;;
    --no-open) OPEN=0 ;;
    --stdout) TO_STDOUT=1; OPEN=0 ;;
    -h|--help) usage 0 ;;
    *) echo "fm-dashboard: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$OUT" ] || OUT="$FM_HOME/.lavish/fleet-dashboard.html"

# --- helpers ---------------------------------------------------------------

# HTML-escape stdin (order matters: & first).
html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}
# HTML-escape a single argument, echoed.
esc() { printf '%s' "${1:-}" | html_escape; }

# Read a meta key's last value from a meta file.
meta_value() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Last non-empty line of a status file.
status_last_line() {  # <file>
  [ -f "$1" ] || return 0
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 || true
}

# Parse the "state:" and detail out of a fm-crew-state.sh line, which looks like:
#   state: working · source: run-step · validating (running)
crew_field() {  # <line> <field: state|source|detail>
  local line=$1 field=$2 rest
  case "$field" in
    state)  printf '%s' "$line" | sed -n 's/^state:[[:space:]]*\([^ ]*\).*/\1/p' ;;
    source) printf '%s' "$line" | sed -n 's/.*source:[[:space:]]*\([^ ]*\).*/\1/p' ;;
    detail)
      # Everything after the last " · " separator, when there are 3+ segments.
      rest=${line##* · }
      case "$rest" in
        state:*|source:*) printf '' ;;
        "$line") printf '' ;;
        *) printf '%s' "$rest" ;;
      esac ;;
  esac
}

# CSS class for a canonical state.
state_class() {  # <state>
  case "$1" in
    working) echo s-working ;;
    done)    echo s-done ;;
    parked)  echo s-parked ;;
    blocked) echo s-blocked ;;
    failed)  echo s-failed ;;
    *)       echo s-unknown ;;
  esac
}

# --- gather in-flight tasks ------------------------------------------------

TASKS=()          # packed records, one per meta
ATTENTION_COUNT=0
INFLIGHT_COUNT=0

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  INFLIGHT_COUNT=$((INFLIGHT_COUNT + 1))

  project_path=$(meta_value "$meta" project)
  harness=$(meta_value "$meta" harness)
  model=$(meta_value "$meta" model)
  kind=$(meta_value "$meta" kind)
  mode=$(meta_value "$meta" mode)
  yolo=$(meta_value "$meta" yolo)
  window=$(meta_value "$meta" window)
  pr=$(meta_value "$meta" pr)
  [ -n "$kind" ] || kind=ship

  # Project label for grouping: basename of the recorded project/home path.
  if [ -n "$project_path" ]; then
    project=$(basename "$project_path")
  else
    project="(unknown)"
  fi

  # Current state (authoritative) via the shared helper.
  crew_line=$("$CREW_STATE_CMD" "$id" 2>/dev/null || true)
  state=$(crew_field "$crew_line" state)
  detail=$(crew_field "$crew_line" detail)
  [ -n "$state" ] || state=unknown

  status_line=$(status_last_line "$STATE/$id.status")
  status_verb=${status_line%%:*}
  status_verb=$(printf '%s' "$status_verb" | tr -d '[:space:]')

  # Attention: anything a supervisor would act on now.
  attention=0
  case "$state" in parked|blocked|failed) attention=1 ;; esac
  case "$status_verb" in needs-decision|blocked|failed) attention=1 ;; esac
  # A PR awaiting merge is a positive attention item (ready to land).
  ready_merge=0
  if [ -n "$pr" ]; then ready_merge=1; attention=1; fi
  [ "$attention" = 1 ] && ATTENTION_COUNT=$((ATTENTION_COUNT + 1))

  rec="$id$US$project$US$harness$US$model$US$kind$US$mode$US$yolo$US$window"
  rec="$rec$US$state$US$detail$US$status_line$US$pr$US$attention$US$ready_merge"
  TASKS[${#TASKS[@]}]="$rec"
done

# Sorted unique project list across in-flight tasks.
project_list() {
  local t proj
  for t in "${TASKS[@]:-}"; do
    [ -n "$t" ] || continue
    proj=$(printf '%s' "$t" | cut -d"$US" -f2)
    printf '%s\n' "$proj"
  done | sort -u
}

# --- HTML row emitters -----------------------------------------------------

# Emit a badge for a meta attribute when non-empty and not a default.
meta_badge() {  # <label> <value>
  local val=$2
  case "$val" in ''|default) return 0 ;; esac
  printf '<span class="chip"><span class="chip-k">%s</span>%s</span>' \
    "$(esc "$1")" "$(esc "$val")"
}

# Render one in-flight task row from a packed record.
emit_task_row() {  # <record>
  local rec=$1
  local id project harness model kind mode yolo window
  local state detail status_line pr attention ready_merge
  # project is consumed positionally (grouping is done by the caller).
  # shellcheck disable=SC2034
  IFS="$US" read -r id project harness model kind mode yolo window \
    state detail status_line pr attention ready_merge <<EOF
$rec
EOF
  local sclass
  sclass=$(state_class "$state")
  printf '<tr class="task %s">' "$sclass"
  printf '<td class="c-id"><span class="dot"></span>%s</td>' "$(esc "$id")"
  printf '<td><span class="pill %s">%s</span>' "$sclass" "$(esc "$state")"
  [ "$ready_merge" = 1 ] && printf ' <span class="pill s-merge">PR ready</span>'
  printf '</td>'
  # Detail / latest status.
  printf '<td class="c-detail">'
  [ -n "$detail" ] && printf '<div class="detail">%s</div>' "$(esc "$detail")"
  if [ -n "$status_line" ]; then
    printf '<div class="status">%s</div>' "$(esc "$status_line")"
  fi
  if [ -n "$pr" ]; then
    printf '<div class="pr"><a href="%s">%s</a></div>' "$(esc "$pr")" "$(esc "$pr")"
  fi
  printf '</td>'
  # Meta chips.
  printf '<td class="c-meta">'
  meta_badge kind "$kind"
  meta_badge mode "$mode"
  [ "$yolo" = on ] && printf '<span class="chip chip-yolo"><span class="chip-k">yolo</span>on</span>'
  meta_badge harness "$harness"
  meta_badge model "$model"
  meta_badge win "$window"
  printf '</td>'
  printf '</tr>\n'
  return 0
}

# --- backlog parsing (data/backlog.md) -------------------------------------

BACKLOG="$DATA/backlog.md"

# Extract items under a "## <section>" header from the backlog file. Prints one
# raw item line (leading "- " stripped) per matching bullet.
backlog_section() {  # <section-name>
  [ -f "$BACKLOG" ] || return 0
  awk -v want="$1" '
    /^##[[:space:]]+/ {
      line=$0; sub(/^##[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      insect = (line == want) ? 1 : 0
      next
    }
    insect && /^[[:space:]]*-[[:space:]]/ {
      item=$0
      sub(/^[[:space:]]*-[[:space:]]+/, "", item)
      print item
    }
  ' "$BACKLOG"
}

# Render a backlog item line into a table row, extracting a PR/report link.
emit_backlog_row() {  # <raw item line>
  local item=$1 link="" text
  # Pull the first URL out for a clickable link.
  link=$(printf '%s' "$item" | grep -oE 'https?://[^ )]+' | head -1 || true)
  text=$item
  printf '<tr><td class="c-back">%s' "$(esc "$text")"
  if [ -n "$link" ]; then
    printf '<div class="pr"><a href="%s">%s</a></div>' "$(esc "$link")" "$(esc "$link")"
  fi
  printf '</td></tr>\n'
}

backlog_has_any() {
  [ -f "$BACKLOG" ] || return 1
  [ -n "$(backlog_section 'In flight')$(backlog_section 'Queued')$(backlog_section 'Done')" ]
}

# --- assemble the document -------------------------------------------------

now=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)

render() {
  cat <<'HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Firstmate Fleet</title>
<style>
:root{
  --bg:#0f1115; --panel:#171a21; --panel2:#1e222b; --line:#2a2f3a;
  --fg:#e6e9ef; --muted:#96a0b5; --accent:#5aa9ff;
  --working:#4aa3ff; --done:#3ecf8e; --parked:#f2b544; --blocked:#ff6b6b;
  --failed:#ff5470; --unknown:#7d8798; --merge:#8b7bff;
}
@media (prefers-color-scheme: light){
  :root{
    --bg:#f4f6fa; --panel:#ffffff; --panel2:#f0f2f7; --line:#dce0e8;
    --fg:#1a1e26; --muted:#5b6474; --accent:#2b6fd6;
  }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:24px 20px 60px}
header{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap;margin-bottom:18px}
h1{font-size:20px;margin:0;letter-spacing:.2px}
h1 .anchor{color:var(--accent)}
.gen{color:var(--muted);font-size:12px}
.counts{margin-left:auto;display:flex;gap:8px;flex-wrap:wrap}
.count{background:var(--panel);border:1px solid var(--line);border-radius:20px;
  padding:3px 11px;font-size:12px;color:var(--muted)}
.count b{color:var(--fg)}
section{margin:22px 0}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.8px;color:var(--muted);
  margin:0 0 10px;font-weight:600}
.proj{font-size:13px;color:var(--accent);font-weight:600;margin:16px 0 6px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
table{width:100%;border-collapse:collapse;table-layout:fixed}
td{padding:10px 12px;border-top:1px solid var(--line);vertical-align:top;
  min-width:0;overflow-wrap:anywhere;word-break:break-word}
tr:first-child td{border-top:0}
.c-id{width:20%;font-weight:600;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
.c-detail{width:44%}
.c-meta{width:22%}
.c-id .dot{display:inline-block;width:8px;height:8px;border-radius:50%;
  margin-right:7px;background:var(--unknown);vertical-align:middle}
.task.s-working .dot{background:var(--working)}
.task.s-done .dot{background:var(--done)}
.task.s-parked .dot{background:var(--parked)}
.task.s-blocked .dot{background:var(--blocked)}
.task.s-failed .dot{background:var(--failed)}
.pill{display:inline-block;padding:2px 9px;border-radius:20px;font-size:11px;
  font-weight:600;letter-spacing:.3px;color:#0c0e12}
.pill.s-working{background:var(--working)} .pill.s-done{background:var(--done)}
.pill.s-parked{background:var(--parked)} .pill.s-blocked{background:var(--blocked)}
.pill.s-failed{background:var(--failed)} .pill.s-unknown{background:var(--unknown);color:#fff}
.pill.s-merge{background:var(--merge);color:#fff}
.detail{color:var(--fg)}
.status{color:var(--muted);font-size:12px;margin-top:3px;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.pr{margin-top:4px;font-size:12px}
.pr a{color:var(--accent);text-decoration:none}
.pr a:hover{text-decoration:underline}
.chip{display:inline-block;background:var(--panel2);border:1px solid var(--line);
  border-radius:6px;padding:1px 7px;margin:2px 4px 2px 0;font-size:11px;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.chip-k{color:var(--muted);margin-right:5px}
.chip-yolo{border-color:var(--failed)}
.chip-yolo .chip-k{color:var(--failed)}
.attention .panel{border-color:var(--parked)}
.attention.has-blocked .panel{border-color:var(--blocked)}
.empty{background:var(--panel);border:1px dashed var(--line);border-radius:12px;
  padding:40px 20px;text-align:center;color:var(--muted)}
.empty b{color:var(--fg);display:block;font-size:16px;margin-bottom:6px}
.c-back{width:100%}
</style>
</head>
<body>
<div class="wrap">
HEAD

  printf '<header><h1><span class="anchor">&#9875;</span> Firstmate Fleet</h1>'
  printf '<span class="gen">generated %s</span>' "$(esc "$now")"
  printf '<div class="counts">'
  printf '<span class="count"><b>%s</b> in flight</span>' "$INFLIGHT_COUNT"
  printf '<span class="count"><b>%s</b> need attention</span>' "$ATTENTION_COUNT"
  printf '</div></header>\n'

  # Empty fleet: no in-flight tasks and no backlog content.
  if [ "$INFLIGHT_COUNT" = 0 ] && ! backlog_has_any; then
    printf '<div class="empty"><b>No active work</b>The fleet is idle &mdash; nothing in flight and the backlog is clear.</div>\n'
    printf '</div></body></html>\n'
    return 0
  fi

  # Needs-attention band.
  if [ "$ATTENTION_COUNT" -gt 0 ]; then
    local has_blocked="" t attn
    for t in "${TASKS[@]:-}"; do
      [ -n "$t" ] || continue
      case "$(printf '%s' "$t" | cut -d"$US" -f9)" in blocked|failed) has_blocked=" has-blocked" ;; esac
    done
    printf '<section class="attention%s"><h2>Needs attention</h2><div class="panel"><table>\n' "$has_blocked"
    for t in "${TASKS[@]:-}"; do
      [ -n "$t" ] || continue
      attn=$(printf '%s' "$t" | cut -d"$US" -f13)
      [ "$attn" = 1 ] && emit_task_row "$t"
    done
    printf '</table></div></section>\n'
  fi

  # In-flight grouped by project.
  if [ "$INFLIGHT_COUNT" -gt 0 ]; then
    printf '<section><h2>In flight</h2>\n'
    local proj t tproj
    while IFS= read -r proj; do
      [ -n "$proj" ] || continue
      printf '<div class="proj">%s</div><div class="panel"><table>\n' "$(esc "$proj")"
      for t in "${TASKS[@]:-}"; do
        [ -n "$t" ] || continue
        tproj=$(printf '%s' "$t" | cut -d"$US" -f2)
        [ "$tproj" = "$proj" ] && emit_task_row "$t"
      done
      printf '</table></div>\n'
    done <<EOF
$(project_list)
EOF
    printf '</section>\n'
  fi

  # Backlog sections.
  if backlog_has_any; then
    local sect item any
    printf '<section><h2>Backlog</h2>\n'
    for sect in "In flight" "Queued" "Done"; do
      any=$(backlog_section "$sect")
      [ -n "$any" ] || continue
      printf '<div class="proj">%s</div><div class="panel"><table>\n' "$(esc "$sect")"
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        emit_backlog_row "$item"
      done <<EOF
$any
EOF
      printf '</table></div>\n'
    done
    printf '</section>\n'
  fi

  printf '</div></body></html>\n'
}

# --- output ----------------------------------------------------------------

if [ "$TO_STDOUT" = 1 ]; then
  render
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
render > "$OUT"
echo "fm-dashboard: wrote $OUT" >&2

if [ "$OPEN" = 1 ]; then
  if command -v lavish-axi >/dev/null 2>&1; then
    lavish-axi "$OUT"
  else
    echo "fm-dashboard: lavish-axi not found; open $OUT manually" >&2
  fi
fi
