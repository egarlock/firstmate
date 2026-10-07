#!/usr/bin/env bash
# tests/cmux-fake-lib.sh - a STATEFUL fake `cmux` CLI plus fake `ps`/`lsof`
# for tests that drive multi-step cmux flows (container ensure -> create ->
# resolve -> kill), where fm-backend-cmux.test.sh's ordered canned-response
# fake would need every call hand-counted. State lives in $FM_CMUX_STATE as
# small TSV files the fake reads and MUTATES per call, so a workspace or tab
# created by one step is visible to the next, like the real app. The fake
# honors the canned fake's env contract for version/ping (FM_CMUX_FAKE_VERSION,
# FM_CMUX_FAKE_PING, FM_CMUX_FAKE_PING_EXIT) and logs every invocation to
# FM_CMUX_LOG in the same unit-separated format.
#
# State files under $FM_CMUX_STATE:
#   workspaces.tsv  <workspace_id>\t<ref>\t<title>\t<current_directory>
#   surfaces.tsv    <workspace_id>\t<surface_id>\t<ref>\t<title>\t<tty>
#   counter         monotonically increasing ref/id suffix for creates
#
# Modelled real-app behaviors (verified on cmux 0.64.25):
#   - new-workspace prints `OK workspace:<n>` and new-surface prints
#     `OK surface:<n> pane:1 workspace:<k>`, whatever --id-format says.
#   - `workspace list` lags a fresh workspace: with FM_CMUX_FAKE_LIST_LAG=<k>
#     the first <k> lists after each new-workspace omit it, while list-panes
#     and tree see it at once.
#   - close-surface refuses a workspace's last surface (invalid_state).
#   - read-screen fails until screen.txt exists (fresh-surface pitfall).
# Knobs: FM_CMUX_FAKE_NO_REF=1 drops the printed ref from creates;
# FM_CMUX_FAKE_RENAME_EXIT makes rename-tab fail; FM_CMUX_FAKE_NEW_SURFACE_EXTRA=1
# makes new-surface also add a second (concurrent) surface.

# cmux_state_init <state-dir>: create the empty state files.
cmux_state_init() {
  local sdir=$1
  mkdir -p "$sdir"
  : > "$sdir/workspaces.tsv"
  : > "$sdir/surfaces.tsv"
  printf '100\n' > "$sdir/counter"
}

# cmux_state_add_workspace <state-dir> <id> <ref> <title> <cwd>
cmux_state_add_workspace() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1/workspaces.tsv"
}

# cmux_state_add_surface <state-dir> <workspace_id> <surface_id> <ref> <title> [tty]
cmux_state_add_surface() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "${6:-}" >> "$1/surfaces.tsv"
}

# make_cmux_state_fakebin <dir>: write the stateful fake cmux plus fake
# ps/lsof into <dir>/fakebin and echo that path. The ps fake answers ONLY the
# tty-scoped shapes the cmux adapter uses: `-t <tty> -o pid=,comm=` from
# FM_FAKE_PS_TTY_PROCS, `-t <tty> -o pid=,stat=` from FM_FAKE_PS_TTY_PIDSTAT
# (both printf %b-expanded so tests can embed \n), and `-p <pid> -o args=`
# from FM_FAKE_PS_ARGS_<pid> when set. Every other query execs the real ps.
# The lsof fake answers the adapter's cwd read from FM_FAKE_LSOF_CWD and
# fails when it is unset.
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

# ws_id <uuid-or-ref>: the workspace uuid, or empty.
ws_id() {
  awk -F'\t' -v k="$1" '$1 == k || $2 == k { print $1; exit }' "$SDIR/workspaces.tsv"
}

# sf_id <workspace_id> <uuid-or-ref>: the surface uuid in that workspace, or empty.
sf_id() {
  awk -F'\t' -v w="$1" -v k="$2" '$1 == w && ($2 == k || $3 == k) { print $2; exit }' "$SDIR/surfaces.tsv"
}

next_n() {
  local n
  n=$(( $(cat "$SDIR/counter") + 1 ))
  printf '%s\n' "$n" > "$SDIR/counter"
  printf '%s' "$n"
}

rewrite() {  # <file> <awk-program> [awk -v args...]
  local f=$1 prog=$2
  shift 2
  awk -F'\t' -v OFS='\t' "$@" "$prog" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

case "${1:-}" in
  version)
    printf 'cmux %s (106) [abcdef1]\n' "${FM_CMUX_FAKE_VERSION:-0.64.25}"
    exit 0 ;;
  ping)
    printf '%s\n' "${FM_CMUX_FAKE_PING:-PONG}"
    exit "${FM_CMUX_FAKE_PING_EXIT:-0}" ;;
  list-windows)
    printf '[{"id":"WIN-1"}]'
    exit 0 ;;
  workspace)
    [ "${2:-}" = list ] || exit 0
    hide=""
    if [ -f "$SDIR/lag" ]; then
      read -r lag_ws lag_left < "$SDIR/lag"
      if [ "${lag_left:-0}" -gt 0 ]; then
        hide=$lag_ws
        printf '%s %s\n' "$lag_ws" "$((lag_left - 1))" > "$SDIR/lag"
      fi
    fi
    awk -F'\t' -v hide="$hide" 'BEGIN { printf "{\"workspaces\":["; first = 1 }
      NF >= 3 && $1 != hide { if (!first) printf ","; first = 0
        printf "{\"id\":\"%s\",\"ref\":\"%s\",\"title\":\"%s\",\"current_directory\":\"%s\"}", $1, $2, $3, $4 }
      END { printf "]}" }' "$SDIR/workspaces.tsv"
    exit 0 ;;
  list-panes)
    ws=$(ws_id "$(argval --workspace "$@")")
    [ -n "$ws" ] || { echo "Error: not_found: Workspace not found" >&2; exit 1; }
    awk -F'\t' -v ws="$ws" 'BEGIN { n = 0 }
      $1 == ws { ids[n++] = $2 }
      END { printf "{\"workspace_id\":\"%s\",\"panes\":[", ws
            if (n) { printf "{\"selected_surface_id\":\"%s\",\"surface_ids\":[", ids[0]
              for (i = 0; i < n; i++) { if (i) printf ","; printf "\"%s\"", ids[i] }
              printf "]}" }
            printf "]}" }' "$SDIR/surfaces.tsv"
    exit 0 ;;
  tree)
    ws=""
    if w=$(argval --workspace "$@"); then
      ws=$(ws_id "$w")
      [ -n "$ws" ] || { echo "Error: not_found: Workspace not found" >&2; exit 1; }
    fi
    {
      printf '{"windows":[{"id":"WIN-1","workspaces":['
      first=1
      while IFS=$'\t' read -r wid wref wtitle _; do
        [ -n "$wid" ] || continue
        [ -z "$ws" ] || [ "$ws" = "$wid" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"id":"%s","ref":"%s","title":"%s","panes":[{"surfaces":[' "$wid" "$wref" "$wtitle"
        awk -F'\t' -v w="$wid" 'BEGIN { f = 1 }
          $1 == w { if (!f) printf ","; f = 0
            tty = ($5 == "") ? "null" : "\"" $5 "\""
            printf "{\"id\":\"%s\",\"ref\":\"%s\",\"title\":\"%s\",\"tty\":%s}", $2, $3, $4, tty }' "$SDIR/surfaces.tsv"
        printf ']}]}'
      done < "$SDIR/workspaces.tsv"
      printf ']}]}'
    }
    exit 0 ;;
  new-workspace)
    name=$(argval --name "$@") || name="Terminal"
    cwd=$(argval --cwd "$@") || cwd="$HOME"
    n=$(next_n)
    printf 'WS-%s\tworkspace:%s\t%s\t%s\n' "$n" "$n" "$name" "$cwd" >> "$SDIR/workspaces.tsv"
    printf 'WS-%s\tSF-%s\tsurface:%s\tTerminal\t\n' "$n" "$n" "$n" >> "$SDIR/surfaces.tsv"
    [ -z "${FM_CMUX_FAKE_LIST_LAG:-}" ] || printf 'WS-%s %s\n' "$n" "$FM_CMUX_FAKE_LIST_LAG" > "$SDIR/lag"
    if [ -n "${FM_CMUX_FAKE_NO_REF:-}" ]; then echo OK; else printf 'OK workspace:%s\n' "$n"; fi
    exit 0 ;;
  new-surface)
    ws=$(ws_id "$(argval --workspace "$@")")
    [ -n "$ws" ] || { echo "Error: not_found: Workspace not found" >&2; exit 1; }
    n=$(next_n)
    printf '%s\tSF-%s\tsurface:%s\tTerminal\t\n' "$ws" "$n" "$n" >> "$SDIR/surfaces.tsv"
    if [ -n "${FM_CMUX_FAKE_NEW_SURFACE_EXTRA:-}" ]; then
      m=$(next_n)
      printf '%s\tSF-%s\tsurface:%s\tTerminal\t\n' "$ws" "$m" "$m" >> "$SDIR/surfaces.tsv"
    fi
    if [ -n "${FM_CMUX_FAKE_NO_REF:-}" ]; then echo OK; else printf 'OK surface:%s pane:1 workspace:1\n' "$n"; fi
    exit 0 ;;
  rename-tab)
    [ -z "${FM_CMUX_FAKE_RENAME_EXIT:-}" ] || exit "$FM_CMUX_FAKE_RENAME_EXIT"
    ws=$(ws_id "$(argval --workspace "$@")")
    sf=$(sf_id "$ws" "$(argval --surface "$@")")
    [ -n "$sf" ] || exit 1
    for title; do :; done
    rewrite "$SDIR/surfaces.tsv" '{ if ($1 == ws && $2 == sf) $4 = t; print }' -v ws="$ws" -v sf="$sf" -v t="$title"
    exit 0 ;;
  close-workspace)
    ws=$(ws_id "$(argval --workspace "$@")")
    [ -n "$ws" ] || exit 1
    rewrite "$SDIR/workspaces.tsv" '$1 != ws' -v ws="$ws"
    rewrite "$SDIR/surfaces.tsv" '$1 != ws' -v ws="$ws"
    echo OK
    exit 0 ;;
  close-surface)
    ws=$(ws_id "$(argval --workspace "$@")")
    sf=$(sf_id "$ws" "$(argval --surface "$@")")
    [ -n "$sf" ] || exit 1
    if [ "$(awk -F'\t' -v ws="$ws" '$1 == ws' "$SDIR/surfaces.tsv" | grep -c .)" -le 1 ]; then
      echo "Error: invalid_state: Cannot close the last surface" >&2
      exit 1
    fi
    rewrite "$SDIR/surfaces.tsv" '!($1 == ws && $2 == sf)' -v ws="$ws" -v sf="$sf"
    echo OK
    exit 0 ;;
  read-screen)
    if [ -f "$SDIR/screen.txt" ]; then
      jq -n --rawfile t "$SDIR/screen.txt" '{text:$t}'
      exit 0
    fi
    echo "Error: internal_error: Failed to read terminal text" >&2
    exit 1 ;;
  send|send-key)
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
  *"-t "*"-o pid=,comm="*)
    [ -z "${FM_FAKE_PS_TTY_PROCS:-}" ] || printf '%b\n' "$FM_FAKE_PS_TTY_PROCS"
    exit 0 ;;
  *"-t "*"-o pid=,stat="*)
    [ -z "${FM_FAKE_PS_TTY_PIDSTAT:-}" ] || printf '%b\n' "$FM_FAKE_PS_TTY_PIDSTAT"
    exit 0 ;;
  "-p "*" -o args=")
    pid=${2:-}
    var="FM_FAKE_PS_ARGS_$pid"
    if [ -n "${!var:-}" ]; then
      printf '%s\n' "${!var}"
      exit 0
    fi
    exit 1 ;;
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
