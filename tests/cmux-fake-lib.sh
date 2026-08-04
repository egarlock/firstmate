#!/usr/bin/env bash
# tests/cmux-fake-lib.sh - a STATEFUL fake `cmux` CLI plus fake `ps`/`lsof`
# for tests that drive multi-phase cmux flows (secondmate create -> resolve ->
# kill -> respawn), where fm-backend-cmux.test.sh's ordered canned-response
# fake would need every call hand-counted across phases. State lives in
# $FM_CMUX_STATE as small TSV files the fake reads and MUTATES per call, so a
# workspace created by one phase is visible to the next, exactly like the real
# app. The fake still honors the ordered fake's env contract for version/ping
# (FM_CMUX_FAKE_VERSION, FM_CMUX_FAKE_PING, FM_CMUX_FAKE_PING_EXIT) and logs
# every invocation to FM_CMUX_LOG in the same unit-separated format.
#
# State files under $FM_CMUX_STATE:
#   workspaces.tsv  <workspace_id>\t<title>\t<current_directory>
#   surfaces.tsv    <workspace_id>\t<surface_id>\t<title>\t<index>
#   ttys.tsv        <surface_id>\t<tty>   (optional; else FM_CMUX_FAKE_TTY)
#   counter         monotonically increasing id suffix for new-workspace
#
# FM_CMUX_FAKE_FOCUSED holds the raw `identify --no-caller` JSON the fake
# answers with (default: empty, i.e. no focused surface, so focus restoration
# is a supported no-op).

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# cmux_expected_root_hash / cmux_expected_home_label / cmux_expected_scoped_title:
# test-side mirrors of bin/fm-backend-hometag-lib.sh's derivation, shared by
# every cmux suite that asserts on scoped titles.
cmux_expected_root_hash() {  # <root>
  local root real
  root=$1
  real=$(cd "$root" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

cmux_expected_home_label() {  # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  printf '%s-%s' "$prefix" "$(cmux_expected_root_hash "$root")"
}

cmux_expected_scoped_title() {  # <fm-task-label> [home] [root]
  local label=$1 home=${2:-$ROOT} root=${3:-$ROOT} rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(cmux_expected_home_label "$home" "$root")" "$rest"
}

# cmux_state_init <state-dir>: create the empty state files.
cmux_state_init() {
  local sdir=$1
  mkdir -p "$sdir"
  : > "$sdir/workspaces.tsv"
  : > "$sdir/surfaces.tsv"
  printf '0\n' > "$sdir/counter"
}

# cmux_state_add_workspace <state-dir> <id> <title> <cwd> [<surface_id> [<surface_title>]]
cmux_state_add_workspace() {
  local sdir=$1 wsid=$2 title=$3 cwd=$4 sfid=${5:-} sftitle=${6:-zsh}
  printf '%s\t%s\t%s\n' "$wsid" "$title" "$cwd" >> "$sdir/workspaces.tsv"
  [ -z "$sfid" ] || printf '%s\t%s\t%s\t0\n' "$wsid" "$sfid" "$sftitle" >> "$sdir/surfaces.tsv"
}

# cmux_state_set_tty <state-dir> <surface_id> <tty>
cmux_state_set_tty() {
  printf '%s\t%s\n' "$2" "$3" >> "$1/ttys.tsv"
}

# make_cmux_state_fakebin <dir>: write the stateful fake cmux plus fake
# ps/lsof into <dir>/fakebin and echo that path. The ps fake answers ONLY the
# two tty-scoped query shapes the cmux adapter uses (`-t <tty> -o comm=` from
# FM_FAKE_PS_TTY_COMMS, `-t <tty> -o pid=,stat=` from FM_FAKE_PS_TTY_PIDSTAT,
# both printf %b-expanded so tests can embed \n) and EXECS the real ps for
# every other query, so harness detection and other ps consumers keep working.
# The lsof fake answers the adapter's `-a -p <pid> -d cwd -Fn` cwd read from
# FM_FAKE_LSOF_CWD and fails when it is unset.
make_cmux_state_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
SDIR="${FM_CMUX_STATE:?}"
{
  printf 'CMUX_SOCKET_PASSWORD=%s' "${CMUX_SOCKET_PASSWORD:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_CMUX_LOG:-/dev/null}"

argval() {  # <flag> <args...> -> value after flag
  local want=$1 prev=
  shift
  for a in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s' "$a"; return 0; }
    prev=$a
  done
  return 1
}

emit_workspaces_json() {
  awk -F'\t' 'BEGIN { printf "{\"workspaces\":[" ; first=1 }
    NF >= 2 { if (!first) printf ","; first=0
      printf "{\"id\":\"%s\",\"title\":\"%s\",\"current_directory\":\"%s\"}", $1, $2, $3 }
    END { printf "]}" }' "$SDIR/workspaces.tsv"
}

case "${1:-}" in
  version)
    printf 'cmux %s (100) [abcdef1]\n' "${FM_CMUX_FAKE_VERSION:-0.64.20}"
    exit 0 ;;
  ping)
    printf '%s\n' "${FM_CMUX_FAKE_PING:-PONG}"
    exit "${FM_CMUX_FAKE_PING_EXIT:-0}" ;;
  list-windows)
    printf '[{"id":"WIN-1"}]'
    exit 0 ;;
  workspace)
    [ "${2:-}" = list ] || exit 0
    emit_workspaces_json
    exit 0 ;;
  list-panes)
    ws=$(argval --workspace "$@") || ws=
    awk -F'\t' -v ws="$ws" 'BEGIN { printf "{\"panes\":[" ; n=0 }
      $1 == ws { ids[n++]=$2 }
      END { if (n) { printf "{\"selected_surface_id\":\"%s\",\"surface_ids\":[", ids[0]
              for (i=0;i<n;i++) { if (i) printf ","; printf "\"%s\"", ids[i] }
              printf "]}" }
            printf "]}" }' "$SDIR/surfaces.tsv"
    exit 0 ;;
  list-pane-surfaces)
    ws=$(argval --workspace "$@") || ws=
    awk -F'\t' -v ws="$ws" 'BEGIN { printf "{\"surfaces\":[" ; first=1 }
      $1 == ws { if (!first) printf ","; first=0
        printf "{\"id\":\"%s\",\"title\":\"%s\",\"index\":%s}", $2, $3, $4 }
      END { printf "]}" }' "$SDIR/surfaces.tsv"
    exit 0 ;;
  tree)
    ws=$(argval --workspace "$@") || ws=
    while IFS=$'\t' read -r sws sfid _title _idx; do
      [ "$sws" = "$ws" ] || continue
      tty=""
      [ -f "$SDIR/ttys.tsv" ] && tty=$(awk -F'\t' -v s="$sfid" '$1 == s { print $2; exit }' "$SDIR/ttys.tsv")
      [ -n "$tty" ] || tty="${FM_CMUX_FAKE_TTY:-}"
      if [ -n "$tty" ]; then
        printf '  surface %s tty=%s\n' "$sfid" "$tty"
      else
        printf '  surface %s\n' "$sfid"
      fi
    done < "$SDIR/surfaces.tsv"
    exit 0 ;;
  new-workspace)
    name=$(argval --name "$@") || name="zsh"
    cwd=$(argval --cwd "$@") || cwd="$HOME"
    n=$(( $(cat "$SDIR/counter") + 1 ))
    printf '%s\n' "$n" > "$SDIR/counter"
    printf 'WS-NEW-%s\t%s\t%s\n' "$n" "$name" "$cwd" >> "$SDIR/workspaces.tsv"
    printf 'WS-NEW-%s\tSF-NEW-%s\tzsh\t0\n' "$n" "$n" >> "$SDIR/surfaces.tsv"
    printf 'OK workspace:%s\n' "$n"
    exit 0 ;;
  new-surface)
    ws=$(argval --workspace "$@") || exit 1
    n=$(( $(cat "$SDIR/counter") + 1 ))
    printf '%s\n' "$n" > "$SDIR/counter"
    printf '%s\tSF-NEW-%s\tzsh\t9\n' "$ws" "$n" >> "$SDIR/surfaces.tsv"
    printf 'OK surface:%s pane:1 workspace:1\n' "$n"
    exit 0 ;;
  rename-tab)
    ws=$(argval --workspace "$@") || exit 1
    sf=$(argval --surface "$@") || exit 1
    for title; do :; done
    tmp="$SDIR/surfaces.tsv.tmp"
    awk -F'\t' -v OFS='\t' -v ws="$ws" -v sf="$sf" -v t="$title" \
      '{ if ($1 == ws && $2 == sf) $3 = t; print }' "$SDIR/surfaces.tsv" > "$tmp"
    mv "$tmp" "$SDIR/surfaces.tsv"
    exit 0 ;;
  close-workspace)
    ws=$(argval --workspace "$@") || exit 1
    tmp="$SDIR/workspaces.tsv.tmp"
    awk -F'\t' -v ws="$ws" '$1 != ws' "$SDIR/workspaces.tsv" > "$tmp"
    mv "$tmp" "$SDIR/workspaces.tsv"
    tmp="$SDIR/surfaces.tsv.tmp"
    awk -F'\t' -v ws="$ws" '$1 != ws' "$SDIR/surfaces.tsv" > "$tmp"
    mv "$tmp" "$SDIR/surfaces.tsv"
    exit 0 ;;
  close-surface)
    ws=$(argval --workspace "$@") || exit 1
    sf=$(argval --surface "$@") || exit 1
    tmp="$SDIR/surfaces.tsv.tmp"
    awk -F'\t' -v ws="$ws" -v sf="$sf" '!($1 == ws && $2 == sf)' "$SDIR/surfaces.tsv" > "$tmp"
    mv "$tmp" "$SDIR/surfaces.tsv"
    exit 0 ;;
  read-screen)
    if [ -f "$SDIR/screen.txt" ]; then
      jq -n --rawfile t "$SDIR/screen.txt" '{text:$t}'
      exit 0
    fi
    echo "Error: internal_error: Failed to read terminal text" >&2
    exit 1 ;;
  send|send-key|focus-window|select-workspace|focus-pane|reorder-surface)
    exit 0 ;;
  identify)
    # Empty by default (no focused surface -> restoration is skipped). Tests
    # that need the focused-at-birth restore exercised set FM_CMUX_FAKE_FOCUSED
    # to an `identify --no-caller` JSON payload.
    [ -z "${FM_CMUX_FAKE_FOCUSED:-}" ] || printf '%s\n' "$FM_CMUX_FAKE_FOCUSED"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/cmux"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  *"-t "*"-o comm="*)
    [ -z "${FM_FAKE_PS_TTY_COMMS:-}" ] || printf '%b\n' "$FM_FAKE_PS_TTY_COMMS"
    exit 0 ;;
  *"-t "*"-o pid=,stat="*)
    [ -z "${FM_FAKE_PS_TTY_PIDSTAT:-}" ] || printf '%b\n' "$FM_FAKE_PS_TTY_PIDSTAT"
    exit 0 ;;
esac
exec /bin/ps "$@"
SH
  chmod +x "$fb/ps"
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_LSOF_CWD:-}" ] || exit 1
printf 'p1234\nn%s\n' "$FM_FAKE_LSOF_CWD"
exit 0
SH
  chmod +x "$fb/lsof"
  printf '%s\n' "$fb"
}
