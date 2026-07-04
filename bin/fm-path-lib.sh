# shellcheck shell=bash
# fm-path-lib.sh — shared path predicates for firstmate.
# Usage: . bin/fm-path-lib.sh
#
# ONE definition of path_is_ancestor_of, the containment predicate at the core of
# the secondmate-home validation logic. Five scripts (fm-backlog-handoff,
# fm-ff-lib, fm-home-seed, fm-spawn, fm-teardown) carried a byte-identical copy;
# they now all source this file. The higher-level secondmate-home validators
# (validate_secondmate_home / validate_operational_dirs / resolved_existing_dir)
# are deliberately NOT folded here: their copies have diverged in their
# error-reporting contract (inline stderr vs the VALIDATION_ERROR global), so
# unifying them would change observable behavior rather than being a pure dedup.
#
# Idempotent: safe to source more than once.

if [ -z "${FM_PATH_LIB_SOURCED:-}" ]; then
  FM_PATH_LIB_SOURCED=1

  # path_is_ancestor_of <ancestor> <path>: 0 iff <path> is a strict descendant of
  # <ancestor> (both must be non-empty and unequal). Purely lexical over already
  # -resolved absolute paths; no filesystem access.
  path_is_ancestor_of() {
    local ancestor=$1 path=$2
    [ -n "$ancestor" ] || return 1
    [ -n "$path" ] || return 1
    [ "$ancestor" != "$path" ] || return 1
    case "$path" in
      "$ancestor"/*) return 0 ;;
    esac
    return 1
  }
fi
