#!/usr/bin/env bash
# Shared "which harness delivered this hook payload?" predicate for the tracked
# Claude-shaped hook entries.
# This file is sourced by hook entrypoints and has no side effects on source.
#
# Why it exists: Cursor Agent CLI loads `<project>/.claude/settings.json` in
# addition to its own `<project>/.cursor/hooks.json` (verified live, cursor-agent
# 2026.08.11-e8db854). A Cursor primary running in a Firstmate checkout therefore
# fires BOTH registrations for every event Cursor's Claude-compatibility map
# covers, which would run session start twice and evaluate each PreToolUse
# seatbelt twice. Firstmate's Cursor registration owns those events, so the
# tracked Claude-shaped entry must stand down.
#
# The signal is the PAYLOAD, not the environment, and that choice is
# load-bearing. Cursor exports CURSOR_INVOKED_AS, CURSOR_PROJECT_DIR, and
# CURSOR_VERSION into every child process, so an environment guard would also
# fire inside a Claude session a human started by hand from a Cursor pane and
# would silently disable Claude's own supervision - the exact hazard
# docs/turnend-guard.md records for GROK_SESSION_ID. The delivered payload
# describes THIS event and cannot be inherited: Cursor stamps every hook payload
# with its own `cursor_version`, and Claude never emits that key.
#
# Fail direction: when the host cannot be determined (no payload, no jq), the
# caller RUNS. A redundant run under Cursor wastes work; a skipped run under
# Claude breaks the primary's supervision, which is the worse failure.

# Return 0 when payload $1 was delivered by a foreign host whose own tracked
# Firstmate registration already covers this event.
fm_hook_payload_is_foreign_host() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '
    type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
  ' >/dev/null 2>&1
}

# GitHub Copilot CLI also loads `<project>/.claude/settings.json` beside its own
# `<git root>/.github/hooks/` registrations, and runs each Claude-shaped entry
# with a Claude-shaped payload (verified live, Copilot CLI 1.0.88). It honors a
# PreToolUse exit 2 as a deny, so the tracked seatbelts keep working there, but
# it ignores asyncRewake and a Stop exit 2, so the Stop auto-arm would run
# synchronously inside Copilot's turn end and the Claude guard could never
# block. Firstmate's Copilot registration owns the turn end and session open,
# so the Claude-shaped Stop, SessionStart, and dialog-mirror entries stand down
# there, while the PreToolUse entries keep running.
#
# The signal is STRUCTURAL rather than the payload or the environment: Copilot
# starts every hook command as its own direct child, and each tracked entry
# ends in `exec`, so the entrypoint's parent process is the Copilot executable
# itself. That fact cannot be inherited, unlike COPILOT_CLI, which leaks into a
# Claude session started by hand from a Copilot pane, and it does not depend on
# which payload keys either vendor emits. A hook a test or a Claude session
# delivers has a shell or Claude as its parent and keeps running, including
# when that test itself runs somewhere below a Copilot session. Same fail
# direction as above: an unreadable parent RUNS.
#
# Call this only from the entrypoint process itself, so $PPID is the process
# that started the hook.
fm_hook_delivered_by_copilot() {
  local comm
  comm=$(ps -o comm= -p "$PPID" 2>/dev/null) || return 1
  [ "$(basename -- "$comm" 2>/dev/null)" = copilot ]
}
