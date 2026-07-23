#!/usr/bin/env bash
# fm-harness-policy.sh - the SINGLE source of truth for firstmate's executable
# harness policy: the verified-adapter allowlist and each adapter's model/effort
# launch capability. Source this; do not execute it.
#
# Consumers:
#   bin/fm-harness.sh    detection + the `adapters`/`efforts` query verbs
#   bin/fm-spawn.sh      launch-flag construction and the copilot version gate
#   bin/fm-bootstrap.sh  crew-dispatch.json validation (allowlist + effort matrix)
#   bin/fm-lock.sh       harness process recognition (fm_harness_process_re)
#
# Adding a verified adapter touches THIS file for the policy axes (allowlist,
# accepted efforts, flag syntax, process-name matching), plus the genuinely
# adapter-specific mechanics that cannot be tabled: the launch template and
# turn-end hook in bin/fm-spawn.sh, any env marker in bin/fm-harness.sh's
# detect_own, the busy signature in bin/fm-tmux-lib.sh (consumed by
# bin/fm-watch.sh), and the knowledge section in the harness-adapters skill.
# AGENTS.md stays human documentation; the executable lists live only here.
#
# Effort capability notes (why some adapters omit values):
#   claude   accepts low|medium|high|xhigh|max via --effort (Claude Code 2.1.196).
#   codex    catalog advertises only low|medium|high|xhigh for
#            model_reasoning_effort; max is omitted rather than guessed (0.142.1).
#   grok     --reasoning-effort accepts only low|medium|high as of grok 0.2.99;
#            xhigh and max are omitted rather than passing a known-bad value.
#   pi       --thinking accepts the full shared vocabulary including max (0.80.6).
#   opencode no verified effort flag for the interactive `opencode --prompt`
#            launch (`opencode run --variant` is a different mode), so no effort
#            value is ever passed (1.17.6).
#   copilot  accepts low|medium|high|xhigh|max via --effort (choices verified on
#            GitHub Copilot CLI 1.0.68 and re-verified on 1.0.72; the CLI also
#            accepts "none" and "minimal", which are outside firstmate's effort
#            vocabulary and are never passed).

# Verified adapters, in detection-preference order. Keep this the only
# executable enumeration of adapter names.
FM_VERIFIED_ADAPTERS='claude codex opencode pi grok copilot'

# fm_harness_is_verified <name>: succeed iff <name> is a verified adapter.
fm_harness_is_verified() {
  case " $FM_VERIFIED_ADAPTERS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# --- copilot spawn-time version gate ---------------------------------------
# copilot's supervised launch shape (the agentStop turn-end hook, --allow-all
# autonomy, and the --model/--effort flags) is verified against GitHub Copilot
# CLI 1.0.68 (re-verified on 1.0.72); an older CLI may lack the agentStop hook
# event or a launch flag and fail opaquely mid-run. fm-spawn probes this before
# a copilot launch, mirroring bootstrap's treehouse/no-mistakes version gates,
# so an incompatible CLI is caught up front with a clear message. Keep this the
# ONE place the minimum lives.
FM_COPILOT_MIN_MAJOR=1
FM_COPILOT_MIN_MINOR=0
FM_COPILOT_MIN_PATCH=68

# fm_harness_version_parts <command>: print "<major> <minor> <patch>" parsed from
# the CLI's `--version` output, or return non-zero when the CLI is absent,
# errors, or prints no dotted-numeric version. The anchored ^[^0-9]* locks the
# match onto the FIRST dotted triple on a line - a greedy .* prefix would lock
# onto the LAST one and truncate leading digits, so 'copilot 1.0.50 (node
# v20.11.1)' parsed as 0.11.1 and a trailing build date could make an
# incompatible CLI pass the gate (or a compatible one fail it, or a two-digit
# major truncate). Tools put their own version first; trailing dotted numbers
# are runtimes and build stamps. A line whose first number is not a dotted
# triple simply does not parse (fail closed) rather than mis-parsing.
fm_harness_version_parts() {
  local harness=$1 output parts
  command -v "$harness" >/dev/null 2>&1 || return 1
  output=$("$harness" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" \
    | sed -nE 's/^[^0-9]*([0-9]+)\.([0-9]+)\.([0-9]+).*$/\1 \2 \3/p' | head -n 1)
  [ -n "$parts" ] || return 1
  printf '%s\n' "$parts"
}

# fm_version_ge <maj> <min> <pat> <need_maj> <need_min> <need_pat>: succeed iff
# the first three-field version is >= the second. Integer compares only, so it
# is bash 3.2 safe and locale-independent.
fm_version_ge() {
  local a1=$1 a2=$2 a3=$3 b1=$4 b2=$5 b3=$6
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -ge "$b3" ]
}

# fm_copilot_compatible: succeed iff the installed copilot CLI is >= the verified
# minimum (FM_COPILOT_MIN_*). Fails when copilot is absent or its version is
# unreadable, so the caller reports a clear, actionable spawn error rather than a
# later opaque hook/flag failure.
fm_copilot_compatible() {
  local parts major minor patch
  parts=$(fm_harness_version_parts copilot) || return 1
  # fm_harness_version_parts emits exactly three space-separated fields.
  IFS=' ' read -r major minor patch <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || return 1
  fm_version_ge "$major" "$minor" "$patch" \
    "$FM_COPILOT_MIN_MAJOR" "$FM_COPILOT_MIN_MINOR" "$FM_COPILOT_MIN_PATCH"
}

# fm_harness_efforts <harness>: print the effort values the installed CLI was
# verified to accept at launch, space-separated; print nothing when the adapter
# has no verified effort flag. This is the ONE effort matrix (see the capability
# notes at the top of this file for the per-adapter verification basis).
fm_harness_efforts() {
  case "$1" in
    claude|copilot|pi) printf '%s\n' 'low medium high xhigh max' ;;
    codex) printf '%s\n' 'low medium high xhigh' ;;
    grok) printf '%s\n' 'low medium high' ;;
  esac
}

# Private single-quote shell quoting for flag values threaded into a launch line.
fm_harness_policy_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_harness_model_flag <harness> <model>: print the launch flag text (with a
# trailing space) that selects <model> on <harness>, or nothing when the model
# is empty/default or the adapter is unverified. Every currently verified
# adapter takes `--model <name>`; add a per-adapter case here when one diverges.
fm_harness_model_flag() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  fm_harness_is_verified "$harness" || return 0
  printf -- '--model %s ' "$(fm_harness_policy_quote "$model")"
}

# fm_harness_effort_flag <harness> <effort>: print the launch flag text (with a
# trailing space) that selects <effort> on <harness>, or nothing when the effort
# is empty/default or outside that adapter's verified accepted set
# (fm_harness_efforts). Callers record the requested effort= in meta either way,
# so an omitted flag preserves launch success without losing traceability.
fm_harness_effort_flag() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case " $(fm_harness_efforts "$harness") " in
    *" $effort "*) : ;;
    *) return 0 ;;
  esac
  case "$harness" in
    claude|copilot)
      printf -- '--effort %s ' "$(fm_harness_policy_quote "$effort")"
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort.
      printf -- '-c %s ' "$(fm_harness_policy_quote "model_reasoning_effort=\"$effort\"")"
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob.
      printf -- '--reasoning-effort %s ' "$(fm_harness_policy_quote "$effort")"
      ;;
    pi)
      printf -- '--thinking %s ' "$(fm_harness_policy_quote "$effort")"
      ;;
  esac
}

# fm_harness_process_re: print the extended regex that recognizes a verified
# harness by process command name (fm-lock.sh's holder liveness). pi is anchored
# because a two-letter substring false-positives everywhere; every other adapter
# name is distinctive enough for substring matching.
fm_harness_process_re() {
  local a out=
  for a in $FM_VERIFIED_ADAPTERS; do
    case "$a" in
      pi) a='^pi$' ;;
    esac
    out="${out:+$out|}$a"
  done
  printf '%s\n' "$out"
}

# fm_harness_from_comm <basename>: map a process command basename to the
# verified adapter it belongs to (substring match; pi exact), or fail.
fm_harness_from_comm() {
  local h
  for h in $FM_VERIFIED_ADAPTERS; do
    case "$h" in
      pi) [ "$1" = pi ] && { echo pi; return 0; } ;;
      *) case "$1" in *"$h"*) echo "$h"; return 0 ;; esac ;;
    esac
  done
  return 1
}

# fm_harness_from_args <argv-string>: map a bare-interpreter argv string (e.g.
# "node /path/to/claude") to the verified adapter named in it, or fail. pi is
# matched only as a standalone word or path tail.
fm_harness_from_args() {
  local h
  for h in $FM_VERIFIED_ADAPTERS; do
    case "$h" in
      pi) case "$1" in *' pi '*|*/pi) echo pi; return 0 ;; esac ;;
      *) case "$1" in *"$h"*) echo "$h"; return 0 ;; esac ;;
    esac
  done
  return 1
}
