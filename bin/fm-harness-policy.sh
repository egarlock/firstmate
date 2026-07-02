#!/usr/bin/env bash
# fm-harness-policy.sh - the SINGLE source of truth for firstmate's executable
# harness policy: the verified-adapter allowlist and each adapter's model/effort
# launch capability. Source this; do not execute it.
#
# Consumers:
#   bin/fm-harness.sh    detection + the `adapters`/`efforts` query verbs
#   bin/fm-spawn.sh      launch-flag construction and adapter validation
#   bin/fm-bootstrap.sh  crew-dispatch.json validation (allowlist + effort matrix)
#   bin/fm-lock.sh       harness process recognition (fm_harness_process_re)
#
# Adding a verified adapter touches THIS file for the policy axes (allowlist,
# accepted efforts, flag syntax, process-name matching), plus the genuinely
# adapter-specific mechanics that cannot be tabled: the launch template and
# turn-end hook in bin/fm-spawn.sh, any env marker in bin/fm-harness.sh's
# detect_own, the busy signature in bin/fm-watch.sh + bin/fm-tmux-lib.sh, and
# the knowledge section in the harness-adapters skill. AGENTS.md stays human
# documentation; the executable lists live only here.
#
# Effort capability notes (why some adapters omit values):
#   claude   accepts low|medium|high|xhigh|max via --effort (Claude Code 2.1.196).
#   codex    catalog advertises only low|medium|high|xhigh for
#            model_reasoning_effort; max is omitted rather than guessed (0.142.1).
#   grok     --reasoning-effort rejects max, so max is omitted (0.2.73).
#   pi       --thinking warns on max as invalid, so max is omitted (0.80.2).
#   opencode no verified effort flag for the interactive `opencode --prompt`
#            launch (`opencode run --variant` is a different mode), so no effort
#            value is ever passed (1.17.6).
#   copilot  accepts low|medium|high|xhigh|max via --effort (choices verified on
#            GitHub Copilot CLI 1.0.68; the CLI also accepts "none", which is
#            not part of firstmate's effort vocabulary and is never passed).

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

# fm_harness_efforts <harness>: print the effort values the installed CLI was
# verified to accept at launch, space-separated; print nothing when the adapter
# has no verified effort flag. This is the ONE effort matrix.
fm_harness_efforts() {
  case "$1" in
    claude|copilot) printf '%s\n' 'low medium high xhigh max' ;;
    codex|grok|pi) printf '%s\n' 'low medium high xhigh' ;;
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
