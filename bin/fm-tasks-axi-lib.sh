# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.

# The version probe and compare live in the shared policy lib
# (fm_harness_version_parts / fm_version_ge), the ONE parser for every
# version-gated tool. The probe this replaced took the LAST dotted triple on
# the version line, so a trailing build or runtime stamp won the match and
# `tasks-axi 0.0.9 build 2026.1.15` parsed as 6.1.15 - an incompatible CLI
# passing the gate. The shared parser anchors to the FIRST triple.
_FM_TASKS_AXI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-harness-policy.sh
. "$_FM_TASKS_AXI_LIB_DIR/fm-harness-policy.sh"

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_harness_version_parts tasks-axi) || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  fm_version_ge "$major" "$minor" "$patch" 0 1 1 || return 1
  fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
