#!/usr/bin/env bash
# fm-harbor-watch.sh - harbor watch wave 1: observe-and-escalate supervision of
# the captain's own opted-in cmux tabs. ZERO keystrokes: this script never
# sends input to, focuses, renames, or otherwise mutates any tab or
# notification state; every cmux call it makes is a read-only listing or
# screen capture, and only opted-in surfaces are ever captured.
#
# Usage:
#   fm-harbor-watch.sh sweep
#       Run one detection sweep over the active watch-list entries for this
#       machine. Prints ONE line per newly actionable event and nothing
#       otherwise, so it is safe as a registered custom watcher check
#       (state/harbor-watch.check.sh -> this script; see `arm`). Event line:
#         <class> watch=<id> tab="<workspace> › <surface>" detail="<evidence>"
#       Classes: permission, decision, waiting, error, credential (evidence
#       withheld), mismatch (identity re-confirmation needed), unreadable,
#       cmux-unreachable, config-error, sweep-truncated.
#   fm-harbor-watch.sh add --workspace <title> --surface <uuid> [--id <id>]
#       Opt one live tab in: verifies the surface exists in the named
#       workspace right now, captures its identity (machine, workspace title,
#       surface title, surface uuid, addedAt), and appends the entry
#       atomically. Refuses a surface uuid that is already watched.
#   fm-harbor-watch.sh remove <id>
#       Opt out instantly: deletes the entry and cancels its pending
#       escalation dedupe state so a re-add starts clean.
#   fm-harbor-watch.sh list [--json]
#       Print the watch list (human table, or the raw JSON document).
#   fm-harbor-watch.sh arm
#       Idempotently (re)write the byte-static sweep shim
#       state/harbor-watch.check.sh and bind it via bin/fm-check-register.sh
#       so the home's existing watcher runs the sweep every FM_CHECK_INTERVAL.
#   fm-harbor-watch.sh disarm
#       Remove the shim, its trust binding, and the dedupe state.
#   fm-harbor-watch.sh classify [--notif-kind <kind>] [--notif-unread <0|1>]
#       Classify captured screen text from stdin (the test and diagnostic
#       surface for the sweep's classifier; no cmux calls).
#
# Data contract:
#   config/harbor-watch.json  the two-writer watch list (this script for chat
#       ops, the cmux-dashboard toggle as the second writer); the schema is
#       owned by docs/configuration.md "Harbor watch". Writes are atomic
#       (mktemp in the config dir + rename); last write wins, and the sweep
#       re-reads and re-validates the file on every run regardless of writer.
#   state/.harbor-watch-reported  dedupe ledger: "<sha256> <watch-id>" lines
#       for events already escalated and still present on screen. An event
#       line fires once and is re-armed automatically when the prompt clears
#       or changes; `remove` and `disarm` drop a watch's lines immediately.
#   state/harbor-watch.log  append-only audit log: one timestamped line per
#       add, remove, arm, disarm, escalated event, and deactivation.
#
# Identity rule (captain-approved design, data/fm-tab-watch-s7 in the primary
# home): a watch is resolved ONLY by its recorded surface uuid, confirmed
# against its recorded workspace title. cmux surface titles auto-retitle and
# workspace/surface uuids do not survive an app relaunch, so on any mismatch -
# uuid gone, or uuid found under a different workspace title - the entry is
# set inactive and a `mismatch` event escalates for captain re-confirmation
# (remove + add via the harbor-watch skill). A watch never silently migrates
# to a different tab. When cmux itself is unreachable the sweep reports
# `cmux-unreachable` once and deactivates nothing.
#
# Detection (ported from the proven cmux-dashboard classify() heuristics):
# the screen is ground truth and a notification only corroborates, because
# cmux notifications persist after their prompt is resolved. Precedence:
# a live spinner/elapsed-timer/busy footer beats everything (a visibly
# working tab never escalates, however stale its notifications); then a
# credential prompt (never quoted - the event carries no screen text); then
# an on-screen permission dialog; then an AskUserQuestion/plan-mode picker
# (`decision`); then an UNREAD Waiting notification with an idle screen and
# an empty composer (a captain mid-typing suppresses it); then a visible
# error beside an idle prompt. An unread Permission notification with no
# dialog on screen is stale and reports nothing.
#
# Wave-1 hard contract: observe only. The `classes` array in each entry is
# recorded for forward compatibility and IGNORED by this wave's sweep; no
# verb of this script emits keystrokes of any kind.
#
# Env knobs: FM_HARBOR_MACHINE (identity override, default `hostname`),
# FM_HARBOR_TAIL_LINES (classify window, default 16, capture is 40),
# FM_HARBOR_BUDGET_SECS (sweep soft budget, default 20 - keeps the check
# inside FM_CHECK_TIMEOUT; unscanned watches keep their dedupe state and a
# `sweep-truncated` event escalates the overflow once).
# Unknown verbs are an error, never a silent no-op.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

WATCH_FILE="$CONFIG_DIR/harbor-watch.json"
REPORTED="$STATE/.harbor-watch-reported"
AUDIT="$STATE/harbor-watch.log"
SHIM="$STATE/harbor-watch.check.sh"
CHECK_ID=harbor-watch

# Busy-footer set (FM_TMUX_BUSY_REGEX_DEFAULT) and the shared composer
# classifier; the cmux adapter supplies read-only listing/capture primitives
# and fm_backend_cmux_composer_state. Both are pure definition files.
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/backends/cmux.sh
. "$SCRIPT_DIR/backends/cmux.sh"

TAIL_LINES=${FM_HARBOR_TAIL_LINES:-16}
BUDGET_SECS=${FM_HARBOR_BUDGET_SECS:-20}

# Classifier regexes, ported from projects/cmux-dashboard server.py classify()
# (the shapes that survived contact with live claude tabs) plus the shared
# busy-footer set. `requires approval` is added from the live-verified claude
# dialog ("This command requires approval"). Word boundaries use POSIX
# classes, not \b, for BSD grep.
HW_TIMER_RE='\([0-9]+m [0-9]+s|\([0-9]+s *·'
HW_PERMISSION_RE=${FM_HARBOR_PERMISSION_RE:-'do you want to (proceed|allow|make this edit|create)|would you like to proceed|permission to use|command requires approval'}
HW_PICKER_RE=${FM_HARBOR_PICKER_RE:-'enter to select.*(navigate|cancel)|↑/↓ to navigate'}
HW_ERROR_RE=${FM_HARBOR_ERROR_RE:-'(^|[^[:alnum:]])(error|failed|exception|traceback)([^[:alnum:]]|$)'}
HW_CREDENTIAL_RE=${FM_HARBOR_CREDENTIAL_RE:-"(password|passphrase|security key|verification code|one-time code|otp|api key)[^:]{0,24}:|'s password"}
HW_SPINNER_CHARS='✢ ✣ ✤ ✥ ✦ ✧ ✶ ✷ ✸ ✹ ✺ ✻ ✼ ✽ ◐ ◓ ◑ ◒ ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'

hw_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

hw_machine() {
  if [ -n "${FM_HARBOR_MACHINE:-}" ]; then
    printf '%s' "$FM_HARBOR_MACHINE"
  else
    hostname
  fi
}

hw_audit() {
  [ -d "$STATE" ] || return 0
  if [ ! -e "$AUDIT" ]; then
    : > "$AUDIT" && chmod 0600 "$AUDIT" 2>/dev/null
  fi
  printf '%s %s\n' "$(hw_now)" "$*" >> "$AUDIT"
}

hw_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# hw_sanitize: fold arbitrary captured text into one safe event-line field -
# control characters dropped, whitespace collapsed, double quotes swapped for
# single so the quoted field cannot be broken, bounded length.
hw_sanitize() {
  printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | tr '\n' ' ' | tr '"' "'" \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c -220
}

hw_id_valid() {
  case "${1-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# --- watch-list document access ---------------------------------------------

# hw_config_rows: one TSV row per entry:
#   id, machine, workspace_title, surface_title, surface_uuid, active(1|0)
# Fails (rc 1) when the file is unreadable as the version-1 schema, so the
# sweep can escalate a config-error instead of misreading a foreign document.
hw_config_rows() {
  # Schema gate first (jq -e on a boolean: 0 valid, 1 false, 2+ unparseable),
  # because -e on the row stream itself cannot tell an empty watch list (no
  # output, exit 4) apart from a truncated or foreign document.
  jq -e '(.version == 1) and ((.watches // null) | type == "array")' \
    "$WATCH_FILE" >/dev/null 2>&1 || return 1
  jq -r '
    .watches[]
    | [(.id // ""), (.machine // ""), (.workspace_title // ""),
       (.surface_title // ""), (.surface_uuid // ""),
       (if .active == true then "1" else "0" end)]
    | @tsv
  ' "$WATCH_FILE" 2>/dev/null
}

# hw_config_write <jq-filter> [jq args...]: atomically rewrite the watch file
# through a jq filter, starting from an empty version-1 document when the
# file does not exist yet. Refuses to install output jq could not produce.
hw_config_write() {
  local filter=$1 tmp failed=0
  shift
  [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR" || return 1
  tmp=$(mktemp "$CONFIG_DIR/.harbor-watch.XXXXXX") || return 1
  if [ -f "$WATCH_FILE" ]; then
    jq "$@" "$filter" "$WATCH_FILE" > "$tmp" 2>/dev/null || failed=1
  else
    jq -n "$@" "{\"version\":1,\"watches\":[]} | $filter" > "$tmp" 2>/dev/null || failed=1
  fi
  if [ "$failed" -ne 0 ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$WATCH_FILE"
}

# --- read-only cmux views -----------------------------------------------------

# hw_enumerate: every live surface as TSV:
#   ws_uuid, ws_title, sf_uuid, sf_title
# Walks list-windows because `workspace list` without --window is scoped to
# the current window only (bin/backends/cmux.sh fm_backend_cmux_window_of_workspace).
# This LISTING is the only read un-opted tabs are ever part of.
hw_enumerate() {
  local wins wid ws_json
  wins=$(fm_backend_cmux_cli list-windows --json --id-format uuids 2>/dev/null) || return 1
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    ws_json=$(fm_backend_cmux_cli workspace list --json --id-format uuids --window "$wid" 2>/dev/null) || continue
    while IFS=$'\t' read -r wsid wstitle; do
      [ -n "$wsid" ] || continue
      fm_backend_cmux_cli list-pane-surfaces --workspace "$wsid" --json --id-format uuids 2>/dev/null \
        | jq -r --arg wsid "$wsid" --arg wstitle "$wstitle" \
            '.surfaces[]? | [$wsid, $wstitle, .id, (.title // "")] | @tsv' 2>/dev/null
    done < <(printf '%s' "$ws_json" | jq -r '.workspaces[]? | [.id, (.title // "")] | @tsv' 2>/dev/null)
  done < <(printf '%s' "$wins" | jq -r '.[]? | .id' 2>/dev/null)
}

# hw_notifs: latest notification per surface as TSV, preferring unread:
#   sf_uuid, unread(1|0), kind, message
# Wire line: idx:notifID|wsUUID|surfaceUUID|read|App|Kind|Message|ts|pct:title
# (verified live, cmux 0.64.20).
hw_notifs() {
  fm_backend_cmux_cli list-notifications 2>/dev/null | awk -F'|' '
    NF >= 7 {
      sf = $3; read = $4; kind = $6; msg = $7
      unread = (read == "unread") ? 1 : 0
      if (!(sf in best) || (unread && !bestun[sf])) {
        best[sf] = unread "\t" kind "\t" msg
        bestun[sf] = unread
      }
    }
    END { for (sf in best) print sf "\t" best[sf] }
  '
}

# --- classification -----------------------------------------------------------

hw_screen_busy() {  # <tail-text>
  local tail_text=$1 c
  printf '%s' "$tail_text" | grep -qiE "$HW_TIMER_RE" && return 0
  printf '%s' "$tail_text" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}" && return 0
  # shellcheck disable=SC2086  # word splitting over the space-separated glyph list is deliberate
  for c in $HW_SPINNER_CHARS; do
    case "$tail_text" in *"$c"*) return 0 ;; esac
  done
  return 1
}

# hw_classify: the pure classifier. Screen tail on stdin; notification kind
# and unread flag as args. Prints exactly one of:
#   working permission decision waiting error credential idle
hw_classify() {  # [notif_kind] [notif_unread]
  local notif_kind=${1:-} notif_unread=${2:-0} text tail_text
  text=$(cat)
  tail_text=$(printf '%s\n' "$text" | tail -n "$TAIL_LINES")
  if hw_screen_busy "$tail_text"; then printf 'working'; return 0; fi
  if printf '%s' "$tail_text" | grep -qiE "$HW_CREDENTIAL_RE"; then printf 'credential'; return 0; fi
  if printf '%s' "$tail_text" | grep -qiE "$HW_PERMISSION_RE"; then printf 'permission'; return 0; fi
  if printf '%s' "$tail_text" | grep -qiE "$HW_PICKER_RE"; then printf 'decision'; return 0; fi
  if [ "$notif_unread" = 1 ] && [ "$notif_kind" = Waiting ]; then printf 'waiting'; return 0; fi
  if printf '%s' "$tail_text" | grep -qiE "$HW_ERROR_RE"; then
    case "$tail_text" in *'❯'*) printf 'error'; return 0 ;; esac
  fi
  printf 'idle'
}

# hw_detail: the evidence snippet for an event - the last matched line plus up
# to three preceding non-blank lines, joined with ' · '. Credential prompts
# never quote the screen (design 5.4: surrounding buffer may hold secrets).
hw_detail() {  # <class> <full-capture> <notif_msg>
  local class=$1 text=$2 notif_msg=$3 re out
  case "$class" in
    credential) printf 'credential prompt detected (screen text withheld)'; return 0 ;;
    waiting) hw_sanitize "${notif_msg:-agent is waiting for input}"; return 0 ;;
    permission) re=$HW_PERMISSION_RE ;;
    decision) re=$HW_PICKER_RE ;;
    error) re=$HW_ERROR_RE ;;
    *) printf '%s' "$class"; return 0 ;;
  esac
  out=$(printf '%s\n' "$text" | awk -v re="$re" '
    { lines[NR] = $0; low = tolower($0); if (low ~ re) last = NR }
    END {
      if (!last) exit
      start = last - 3; if (start < 1) start = 1
      out = ""
      for (i = start; i <= last; i++) {
        t = lines[i]
        gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t != "") out = out (out == "" ? "" : " · ") t
      }
      print out
    }')
  hw_sanitize "${out:-$class}"
}

# --- sweep --------------------------------------------------------------------

# One dedupe-aware event emission. Prints the line only when its fingerprint
# was not already escalated and still pending; every currently-present event
# fingerprint is recorded for the next tick.
hw_emit() {  # <fingerprint-key> <line> <watch-id>
  local fp
  fp=$(hw_hash "$1")
  NEW_REPORTED="$NEW_REPORTED$fp $3
"
  case "$OLD_REPORTED" in
    *"$fp"*) return 0 ;;
  esac
  printf '%s\n' "$2"
  hw_audit "event $2"
}

hw_sweep() {
  local machine rows active_rows enum notifs deact_args
  local wid wmachine wstitle sftitle sfuuid wactive
  local live_ws live_wstitle live_sftitle target tail_text
  local notif_kind notif_unread notif_msg class detail line tab
  local scanned=0 total=0 truncated=0
  OLD_REPORTED=$(cat "$REPORTED" 2>/dev/null || true)
  NEW_REPORTED=""
  deact_args=()

  [ -f "$WATCH_FILE" ] || return 0
  if ! rows=$(hw_config_rows); then
    hw_emit "config-error" \
      "config-error watch=- tab=\"-\" detail=\"config/harbor-watch.json is not a valid version-1 watch list; fix or regenerate it\"" -
    hw_write_reported
    return 0
  fi

  machine=$(hw_machine)
  active_rows=""
  while IFS=$'\t' read -r wid wmachine wstitle sftitle sfuuid wactive; do
    [ -n "$wid" ] || continue
    if ! hw_id_valid "$wid" || [ -z "$sfuuid" ]; then
      hw_emit "config-entry|$wid|$sfuuid" \
        "config-error watch=- tab=\"-\" detail=\"a watch-list entry is missing a valid id or surface uuid; fix config/harbor-watch.json\"" -
      continue
    fi
    [ "$wactive" = 1 ] || continue
    [ "$wmachine" = "$machine" ] || continue
    active_rows="$active_rows$(printf '%s\t%s\t%s\t%s' "$wid" "$wstitle" "$sftitle" "$sfuuid")
"
    total=$((total + 1))
  done <<< "$rows"

  if [ "$total" -eq 0 ]; then
    hw_write_reported
    return 0
  fi

  if [ "$(fm_backend_cmux_ping_state)" != ok ]; then
    # Never treat an unreachable cmux as every tab vanishing: no mismatch, no
    # deactivation, one escalation. Pending prompts stay deduped for later.
    NEW_REPORTED=$OLD_REPORTED$'\n'
    hw_emit "cmux-unreachable" \
      "cmux-unreachable watch=- tab=\"-\" detail=\"cmux is not reachable; $total watched tab(s) cannot be observed\"" -
    hw_write_reported
    return 0
  fi

  enum=$(hw_enumerate) || enum=""
  if [ -z "$enum" ]; then
    NEW_REPORTED=$OLD_REPORTED$'\n'
    hw_emit "cmux-unreachable" \
      "cmux-unreachable watch=- tab=\"-\" detail=\"cmux answered but listed no surfaces; $total watched tab(s) cannot be observed\"" -
    hw_write_reported
    return 0
  fi
  notifs=$(hw_notifs)

  SECONDS=0
  while IFS=$'\t' read -r wid wstitle sftitle sfuuid; do
    [ -n "$wid" ] || continue
    if [ "$SECONDS" -ge "$BUDGET_SECS" ]; then
      truncated=1
      # Keep the unscanned watch's dedupe lines so nothing re-fires spuriously.
      NEW_REPORTED="$NEW_REPORTED$(printf '%s\n' "$OLD_REPORTED" | awk -v id="$wid" '$2 == id')
"
      continue
    fi
    scanned=$((scanned + 1))

    live_ws=""; live_wstitle=""; live_sftitle=""
    while IFS=$'\t' read -r e_ws e_wstitle e_sf e_sftitle; do
      if [ "$e_sf" = "$sfuuid" ]; then
        live_ws=$e_ws; live_wstitle=$e_wstitle; live_sftitle=$e_sftitle
        break
      fi
    done <<< "$enum"

    tab=$(hw_sanitize "$wstitle › $sftitle")
    if [ -z "$live_ws" ]; then
      hw_emit "$wid|mismatch|gone" \
        "mismatch watch=$wid tab=\"$tab\" detail=\"watched tab not found (closed, or identities reset by an app relaunch); watch set inactive - re-confirm to resume\"" "$wid"
      deact_args+=("$wid")
      continue
    fi
    if [ "$live_wstitle" != "$wstitle" ]; then
      hw_emit "$wid|mismatch|moved|$live_wstitle" \
        "mismatch watch=$wid tab=\"$tab\" detail=\"watched tab now sits in workspace '$(hw_sanitize "$live_wstitle")' instead of '$(hw_sanitize "$wstitle")'; watch set inactive - re-confirm to resume\"" "$wid"
      deact_args+=("$wid")
      continue
    fi

    target="$live_ws:$sfuuid"
    tab=$(hw_sanitize "$live_wstitle › ${live_sftitle:-$sftitle}")
    if ! tail_text=$(fm_backend_cmux_capture "$target" 40); then
      hw_emit "$wid|unreadable" \
        "unreadable watch=$wid tab=\"$tab\" detail=\"watched tab's screen could not be read\"" "$wid"
      continue
    fi

    notif_kind=""; notif_unread=0; notif_msg=""
    while IFS=$'\t' read -r n_sf n_unread n_kind n_msg; do
      if [ "$n_sf" = "$sfuuid" ]; then
        notif_unread=$n_unread; notif_kind=$n_kind; notif_msg=$n_msg
        break
      fi
    done <<< "$notifs"

    class=$(printf '%s\n' "$tail_text" | hw_classify "$notif_kind" "$notif_unread")
    case "$class" in
      working|idle) continue ;;
      waiting)
        # A captain mid-typing in that tab is engaged; do not escalate at him.
        if [ "$(fm_backend_cmux_composer_state "$target")" = pending ]; then
          continue
        fi
        ;;
    esac
    detail=$(hw_detail "$class" "$tail_text" "$notif_msg")
    line="$class watch=$wid tab=\"$tab\" detail=\"$detail\""
    hw_emit "$wid|$class|$detail" "$line" "$wid"
  done <<< "$active_rows"

  if [ "$truncated" -eq 1 ]; then
    hw_emit "truncated|$scanned|$total" \
      "sweep-truncated watch=- tab=\"-\" detail=\"sweep budget of ${BUDGET_SECS}s reached after $scanned of $total watches; remaining tabs are observed next tick\"" -
  fi

  if [ "${#deact_args[@]}" -gt 0 ]; then
    local ids_json
    ids_json=$(printf '%s\n' "${deact_args[@]}" | jq -R . | jq -cs .)
    # shellcheck disable=SC2016  # the single-quoted string is a jq filter, not shell expansion
    if hw_config_write '.watches |= map(if (.id as $i | $ids | index($i)) then .active = false else . end)' \
        --argjson ids "$ids_json"; then
      hw_audit "deactivated ${deact_args[*]} (identity mismatch)"
    else
      hw_audit "deactivation write failed for ${deact_args[*]}"
    fi
  fi

  hw_write_reported
  return 0
}

hw_write_reported() {
  local tmp
  [ -d "$STATE" ] || return 0
  tmp=$(mktemp "$STATE/.harbor-watch-reported.XXXXXX") || return 0
  printf '%s' "$NEW_REPORTED" | grep -E '^[0-9a-f]{64} ' | sort -u > "$tmp" || true
  chmod 0600 "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$REPORTED"
}

# --- chat-ops verbs -----------------------------------------------------------

hw_add() {
  local workspace="" surface="" id="" machine sftitle found_ws=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) workspace=${2-}; shift 2 || { echo "error: --workspace needs a value" >&2; return 2; } ;;
      --surface) surface=${2-}; shift 2 || { echo "error: --surface needs a value" >&2; return 2; } ;;
      --id) id=${2-}; shift 2 || { echo "error: --id needs a value" >&2; return 2; } ;;
      *) echo "error: unknown add argument '$1'" >&2; return 2 ;;
    esac
  done
  if [ -z "$workspace" ] || [ -z "$surface" ]; then
    echo "usage: fm-harbor-watch.sh add --workspace <title> --surface <uuid> [--id <id>]" >&2
    return 2
  fi
  if [ -z "$id" ]; then
    # Hash-derived so two surfaces can never collide on a shared uuid prefix.
    id="hw-$(hw_hash "$surface" | cut -c -8)"
  fi
  hw_id_valid "$id" || { echo "error: watch id '$id' is not path-safe" >&2; return 2; }

  if [ -f "$WATCH_FILE" ]; then
    local existing
    existing=$(jq -r --arg s "$surface" --arg i "$id" \
      '.watches[]? | select(.surface_uuid == $s or .id == $i) | .id' "$WATCH_FILE" 2>/dev/null | head -1)
    if [ -n "$existing" ]; then
      echo "error: that surface or id is already in the watch list as '$existing'; remove it first to re-confirm" >&2
      return 1
    fi
  fi

  if [ "$(fm_backend_cmux_ping_state)" != ok ]; then
    echo "error: cmux is not reachable; cannot verify the tab before opting it in" >&2
    return 1
  fi
  local enum
  enum=$(hw_enumerate) || enum=""
  sftitle=""
  while IFS=$'\t' read -r e_ws e_wstitle e_sf e_sftitle; do
    if [ "$e_sf" = "$surface" ]; then
      found_ws=$e_wstitle; sftitle=$e_sftitle
      break
    fi
  done <<< "$enum"
  if [ -z "$found_ws" ]; then
    echo "error: no live surface with uuid $surface; list tabs first and pass the exact surface uuid" >&2
    return 1
  fi
  if [ "$found_ws" != "$workspace" ]; then
    echo "error: surface $surface lives in workspace '$found_ws', not '$workspace'; pass the workspace it is actually in" >&2
    return 1
  fi

  machine=$(hw_machine)
  # shellcheck disable=SC2016  # the single-quoted string is a jq filter, not shell expansion
  hw_config_write '.watches += [$entry]' --argjson entry "$(jq -n \
      --arg id "$id" --arg machine "$machine" --arg ws "$workspace" \
      --arg st "$sftitle" --arg su "$surface" --arg at "$(hw_now)" \
      '{id: $id, machine: $machine, workspace_title: $ws, surface_title: $st,
        surface_uuid: $su, addedAt: $at, active: true, classes: []}')" \
    || { echo "error: could not write config/harbor-watch.json" >&2; return 1; }
  hw_audit "add $id machine=$machine workspace=$workspace surface=$surface title=$(hw_sanitize "$sftitle")"
  printf 'watching: %s (%s › %s)\n' "$id" "$workspace" "$(hw_sanitize "${sftitle:-$surface}")"
}

hw_remove() {
  local id=${1-}
  [ -n "$id" ] || { echo "usage: fm-harbor-watch.sh remove <id>" >&2; return 2; }
  hw_id_valid "$id" || { echo "error: watch id '$id' is not path-safe" >&2; return 2; }
  [ -f "$WATCH_FILE" ] || { echo "error: no watch list at $WATCH_FILE" >&2; return 1; }
  jq -e --arg i "$id" '.watches[]? | select(.id == $i)' "$WATCH_FILE" >/dev/null 2>&1 \
    || { echo "error: no watch entry with id '$id'" >&2; return 1; }
  # shellcheck disable=SC2016  # the single-quoted string is a jq filter, not shell expansion
  hw_config_write '.watches |= map(select(.id != $i))' --arg i "$id" \
    || { echo "error: could not write config/harbor-watch.json" >&2; return 1; }
  # Cancel pending escalation state instantly so a re-add starts clean.
  if [ -f "$REPORTED" ]; then
    local tmp
    tmp=$(mktemp "$STATE/.harbor-watch-reported.XXXXXX") || true
    if [ -n "${tmp:-}" ]; then
      awk -v id="$id" '$2 != id' "$REPORTED" > "$tmp" 2>/dev/null || true
      chmod 0600 "$tmp" 2>/dev/null
      mv -f -- "$tmp" "$REPORTED"
    fi
  fi
  hw_audit "remove $id"
  local remaining
  remaining=$(jq -r '.watches | length' "$WATCH_FILE" 2>/dev/null || echo '?')
  printf 'removed: %s (%s entr%s remain)\n' "$id" "$remaining" "$([ "$remaining" = 1 ] && echo y || echo ies)"
}

hw_list() {
  local as_json=0
  [ "${1-}" = --json ] && as_json=1
  if [ ! -f "$WATCH_FILE" ]; then
    if [ "$as_json" -eq 1 ]; then printf '{"version":1,"watches":[]}\n'; else echo "no watches"; fi
    return 0
  fi
  if [ "$as_json" -eq 1 ]; then
    cat "$WATCH_FILE"
    return 0
  fi
  local rows
  rows=$(hw_config_rows) || { echo "error: config/harbor-watch.json is not a valid version-1 watch list" >&2; return 1; }
  [ -n "$rows" ] || { echo "no watches"; return 0; }
  printf '%s\n' "$rows" | awk -F'\t' \
    '{ printf "%s  %s  %s › %s  surface=%s  %s\n", $1, ($6 == "1" ? "active" : "INACTIVE"), $3, $4, $5, $2 }'
}

# --- arm / disarm -------------------------------------------------------------

hw_arm() {
  [ -d "$STATE" ] || { echo "error: state directory $STATE is unavailable" >&2; return 1; }
  local content tmp
  content="#!/usr/bin/env bash
# harbor-watch sweep shim - registered custom check (bin/fm-harbor-watch.sh arm).
exec \"$FM_ROOT/bin/fm-harbor-watch.sh\" sweep
"
  if [ ! -f "$SHIM" ] || [ "$(cat "$SHIM" 2>/dev/null)" != "$(printf '%s' "$content")" ]; then
    tmp=$(mktemp "$STATE/.harbor-watch-shim.XXXXXX") || return 1
    printf '%s' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$SHIM" || { rm -f -- "$tmp"; return 1; }
  else
    chmod 0700 "$SHIM" 2>/dev/null
  fi
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" || return 1
  hw_audit "arm"
  return 0
}

hw_disarm() {
  rm -f -- "$SHIM" "$STATE/$CHECK_ID.check-trust" "$REPORTED"
  hw_audit "disarm"
  printf 'disarmed: harbor-watch sweep unregistered\n'
}

# --- dispatch -----------------------------------------------------------------

VERB=${1-}
[ $# -gt 0 ] && shift
case "$VERB" in
  sweep)
    [ $# -eq 0 ] || { echo "error: sweep takes no arguments" >&2; exit 2; }
    hw_sweep
    ;;
  classify)
    NOTIF_KIND=""; NOTIF_UNREAD=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --notif-kind) NOTIF_KIND=${2-}; shift 2 || { echo "error: --notif-kind needs a value" >&2; exit 2; } ;;
        --notif-unread) NOTIF_UNREAD=${2-}; shift 2 || { echo "error: --notif-unread needs a value" >&2; exit 2; } ;;
        *) echo "error: unknown classify argument '$1'" >&2; exit 2 ;;
      esac
    done
    hw_classify "$NOTIF_KIND" "$NOTIF_UNREAD"
    printf '\n'
    ;;
  add) hw_add "$@" ;;
  remove) hw_remove "$@" ;;
  list) hw_list "$@" ;;
  arm)
    [ $# -eq 0 ] || { echo "error: arm takes no arguments" >&2; exit 2; }
    hw_arm
    ;;
  disarm)
    [ $# -eq 0 ] || { echo "error: disarm takes no arguments" >&2; exit 2; }
    hw_disarm
    ;;
  '')
    echo "usage: fm-harbor-watch.sh <sweep|add|remove|list|arm|disarm|classify> [args]" >&2
    exit 2
    ;;
  *)
    echo "error: unknown verb '$VERB' (known: sweep, add, remove, list, arm, disarm, classify)" >&2
    exit 2
    ;;
esac
