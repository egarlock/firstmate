#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety check.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. The oracle is a dirty gate then three
# allow-conditions (ANY one lands it), in order:
#   (a) a dirty worktree (uncommitted changes) -> always REFUSE;
#   (b) a recorded landed=<sha> in state/<id>.meta -> ALLOW (the merge already
#       happened; bin/fm-pr-merge.sh / bin/fm-merge-local.sh write it on success);
#   (c) HEAD reachable from a publishing remote-tracking branch (a fork counts, the
#       local no-mistakes gate remote excluded) -> ALLOW (already published);
#   (d) with none of the above, one fallback: is the branch's content already in the
#       up-to-date default branch? -> ALLOW, else REFUSE.
# This replaced a ~100-line heuristic oracle (PR-head ancestor + patch-id replay) with
# the recorded verdict, a direct reachability check, and the single content fallback.
# The recorded verdict is what makes teardown robust to a no-mistakes run that advanced
# origin past the local worktree HEAD.
#
# Matrix:
#   (a) landed= recorded, content NOT in default, no PR      -> ALLOW  (recorded verdict wins)
#   (b) dirty worktree, even when landed= recorded            -> REFUSE (dirty always wins)
#   (c) real content, no landed=, content not in default      -> REFUSE (safety)
#   (d) HEAD pushed to a fork remote, no landed=, not in default -> ALLOW (reachability)
#   (e) HEAD pushed only to the no-mistakes gate remote        -> REFUSE (gate is excluded)
#   (f) no landed=, content already in default                -> ALLOW  (content fallback)
#   (g) content fallback fetches a fresh origin default        -> ALLOW  (stale ref refreshed)
#   (h) local-only + landed= recorded (local merge)           -> ALLOW  (local merge verdict)
#   (i) local-only + no landed=, content not in default       -> REFUSE (safety)
#   (j) --force bypasses the landed-work check                 -> ALLOW  (escape hatch)
#   (k) scout with no report                                   -> REFUSE (report is the product)
#   (l) scout with a report                                    -> ALLOW  (scratch carve-out)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/data/         - firstmate data dir (scout report deliverables land here)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # The simplified oracle never calls gh/gh-axi (no PR-head heuristics remain), but
  # keep hermetic mocks so any stray GitHub call fails locally rather than reaching
  # the network. Any invocation is a bug.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi must not be called by the teardown oracle" >&2
exit 1
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh must not be called by the teardown oracle" >&2
exit 1
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

# Record a landed=<sha> verdict in the task meta, exactly as bin/fm-pr-merge.sh /
# bin/fm-merge-local.sh do on a successful merge. Args: case_dir [sha]
append_landed_meta() {
  local case_dir=$1 sha=${2:-}
  [ -n "$sha" ] || sha=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf 'landed=%s\n' "$sha" >> "$case_dir/state/task-x1.meta"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Push the worktree's HEAD to a separate publishing remote (a fork) and create its
# remote-tracking branch, so head_reachable_from_publishing_remote sees the work as
# already published even though it never reached origin/main. Args: case_dir remote
push_head_to_publishing_remote() {
  local case_dir=$1 remote=$2
  git init -q --bare "$case_dir/$remote.git"
  git -C "$case_dir/project" remote add "$remote" "$case_dir/$remote.git"
  git -C "$case_dir/wt" push -q "$remote" HEAD:refs/heads/task-x1
  git -C "$case_dir/project" fetch -q "$remote"
}

# Push the worktree's HEAD ONLY to the local no-mistakes gate remote (its tracking
# refs land under refs/remotes/no-mistakes/*), simulating a branch published to the
# gate during a failed validation run. The reachability check excludes this remote,
# so it must NOT count as landed. Args: case_dir
push_head_to_gate_remote() {
  local case_dir=$1
  git init -q --bare "$case_dir/nm-gate.git"
  git -C "$case_dir/project" remote add no-mistakes "$case_dir/nm-gate.git"
  git -C "$case_dir/wt" push -q no-mistakes HEAD:refs/heads/task-x1
  git -C "$case_dir/project" fetch -q no-mistakes
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_landed_recorded_allows() {
  local case_dir rc
  case_dir=$(make_case landed-recorded)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is NOT on origin/main and has no PR: the content fallback
  # (c) would REFUSE this. A recorded landed= must short-circuit and ALLOW,
  # proving the recorded verdict is authoritative and never re-derived.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_landed_meta "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "landed-recorded: teardown should succeed on a recorded landed= verdict"
  ! grep -q REFUSED "$case_dir/stderr" || fail "landed-recorded: teardown printed a REFUSED line"
  pass "recorded landed= verdict allows teardown even when content is not in the default branch"
}

test_dirty_worktree_refuses() {
  local case_dir rc
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  # The committed work is fully landed (landed= recorded), but an uncommitted edit
  # remains. Dirtiness must refuse regardless: the reset would discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_landed_meta "$case_dir"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when landed= is recorded (dirty always wins)"
}

test_unpushed_no_record_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no landed= verdict, and never landed on
  # origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no landed= and content not in default is refused (safety preserved)"
}

test_reachable_from_publishing_remote_allows() {
  local case_dir rc
  case_dir=$(make_case reachable-fork)
  write_meta "$case_dir" no-mistakes ship
  # The upstream-contribution workflow: real content pushed to a fork remote, no
  # landed= recorded, and the same change NOT independently on origin/main. HEAD is
  # reachable from the fork's remote-tracking branch, so the work is already
  # published and teardown must ALLOW via the reachability allow-condition.
  wt_commit_file "$case_dir" feature.txt hello "fork work"
  push_head_to_publishing_remote "$case_dir" fork

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "reachable-fork: teardown should succeed when HEAD is reachable from a publishing remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "reachable-fork: teardown printed a REFUSED line"
  pass "worktree whose HEAD is reachable from a publishing fork remote is torn down (reachability allow)"
}

test_gate_remote_only_refuses() {
  local case_dir rc
  case_dir=$(make_case gate-remote-only)
  write_meta "$case_dir" no-mistakes ship
  # The branch was pushed ONLY to the local no-mistakes gate remote (a failed
  # validation run), no landed= recorded, and its content is not in the default
  # branch. The gate remote is excluded from the reachability check, so this must
  # still REFUSE - a gate push is not a landing.
  wt_commit_file "$case_dir" feature.txt hello "gate-only work"
  push_head_to_gate_remote "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-remote-only: teardown should refuse work reachable only via the excluded gate remote"
  grep -q REFUSED "$case_dir/stderr" || fail "gate-remote-only: no REFUSED line in stderr"
  pass "branch published only to the excluded no-mistakes gate remote is refused (gate is not a landing)"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No landed= recorded (older merge, or a merge that bypassed the helpers). The
  # content check must carry it: the branch adds feature.txt, and the same net
  # change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_local_only_landed_recorded_allows() {
  local case_dir rc
  case_dir=$(make_case local-only-landed)
  write_meta "$case_dir" local-only ship
  # A local-only merge (bin/fm-merge-local.sh) fast-forwards local main and records
  # landed=. Even with no remote-reachable commit, the recorded verdict allows.
  wt_commit_file "$case_dir" feature.txt hello "merged work"
  append_landed_meta "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only-landed: teardown should succeed on a recorded local-merge verdict"
  ! grep -q REFUSED "$case_dir/stderr" || fail "local-only-landed: teardown printed a REFUSED line"
  pass "local-only worktree with a recorded landed= verdict is torn down"
}

test_local_only_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case local-only-unpushed)
  write_meta "$case_dir" local-only ship
  # local-only work that was never merged locally (no landed=) and whose content is
  # not in the default branch: must refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "local-only-unpushed: teardown should refuse unmerged local-only work"
  grep -q REFUSED "$case_dir/stderr" || fail "local-only-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with unmerged, un-landed work is refused (safety preserved)"
}

test_force_overrides_unlanded() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" no-mistakes ship
  # Genuinely unlanded work: no landed=, content not in default. --force must skip
  # the whole oracle and tear down anyway.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the landed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "worktree with unlanded work is torn down under --force (escape hatch)"
}

test_scout_without_report_refuses() {
  local case_dir rc
  case_dir=$(make_case scout-no-report)
  write_meta "$case_dir" no-mistakes scout
  # Scout worktrees are scratch, but only once the deliverable exists. No report yet.
  wt_commit_file "$case_dir" scratch.txt debug "scratch commit"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "scout-no-report: teardown should refuse a scout with no report"
  grep -q REFUSED "$case_dir/stderr" || fail "scout-no-report: no REFUSED line in stderr"
  grep -q "report" "$case_dir/stderr" || fail "scout-no-report: refusal did not cite the missing report"
  pass "scout task with no report is refused (the report is the work product)"
}

test_scout_with_report_allows() {
  local case_dir rc
  case_dir=$(make_case scout-with-report)
  write_meta "$case_dir" no-mistakes scout
  # Scratch commits are fine for a scout once the report deliverable exists.
  wt_commit_file "$case_dir" scratch.txt debug "scratch commit"
  mkdir -p "$case_dir/data/task-x1"
  printf '# findings\n' > "$case_dir/data/task-x1/report.md"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-with-report: teardown should succeed once the report exists"
  ! grep -q REFUSED "$case_dir/stderr" || fail "scout-with-report: teardown printed a REFUSED line"
  pass "scout task with a report is torn down despite scratch commits (scratch carve-out)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  append_landed_meta "$case_dir"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  append_landed_meta "$case_dir"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_landed_recorded_allows
test_dirty_worktree_refuses
test_unpushed_no_record_refuses
test_reachable_from_publishing_remote_allows
test_gate_remote_only_refuses
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_local_only_landed_recorded_allows
test_local_only_unpushed_refuses
test_force_overrides_unlanded
test_scout_without_report_refuses
test_scout_with_report_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
