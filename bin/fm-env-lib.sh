# shellcheck shell=bash
# fm-env-lib.sh — resolve firstmate's operational environment.
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/fm-env-lib.sh"
#   fm_env_init            # sets FM_ROOT, FM_HOME, STATE
#
# ONE definition of the FM_ROOT / FM_HOME / STATE resolution that every firstmate
# executable used to open with, honoring the same override precedence:
#   FM_ROOT  = FM_ROOT_OVERRIDE, else the repo root (this lib's own bin/..).
#   FM_HOME  = FM_HOME, else FM_ROOT_OVERRIDE, else FM_ROOT.
#   STATE    = FM_STATE_OVERRIDE, else $FM_HOME/state.
#
# The result is byte-for-byte what the old per-script block produced: because this
# lib lives in bin/ alongside every caller, its own location (bin/..) is exactly
# the FM_ROOT each caller derived from its own $SCRIPT_DIR/.. — so callers need not
# pass anything in. FM_DATA_OVERRIDE / FM_PROJECTS_OVERRIDE / FM_CONFIG_OVERRIDE
# stay where they are used (they are per-script and reference $FM_HOME, which this
# function sets first).
#
# Idempotent: safe to source more than once.

if [ -z "${FM_ENV_LIB_SOURCED:-}" ]; then
  FM_ENV_LIB_SOURCED=1
  # This lib's own bin/ dir, resolved at source time. bin/.. is the repo root,
  # identical to the $SCRIPT_DIR/.. each caller computed for itself.
  _FM_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  fm_env_init() {
    FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_ENV_LIB_DIR/.." && pwd)}"
    FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
    # shellcheck disable=SC2034 # Read by the sourcing script after fm_env_init returns.
    STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  }
fi
