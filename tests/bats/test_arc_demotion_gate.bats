#!/usr/bin/env bats
# tests/bats/test_arc_demotion_gate.bats — Arc Demotion Gate (Shard 1, v2.66.2)
#
# Convention: Bats was chosen because tests/bats/ already contains
# test_guard_clauses.bats and test_helper.bash; the plan called for a `.sh`
# test, but the repo's bash test convention is bats-style. Plain bash is
# documented as a fallback in task-4.md.
#
# Coverage:
#   AC-1.1 — schema seed: every phase block in the canonical phase template
#            (arc-checkpoint-init.md) includes `demotion_revert_count: 0`.
#   AC-1.2 — budget filter: count<3 -> demote + increment + log.
#   AC-1.3 — auto-fill terminator: count>=3 -> skip_reason auto-filled +
#            breadcrumb-emitting log entry; subsequent fires are no-ops.
#   AC-1.4 — backward compat: in-flight v2.66.1 checkpoint (missing field)
#            handled via jq `// 0` default; first demotion creates the field
#            with value 1.

load test_helper

# ---------------------------------------------------------------------------
# Local fixtures: extract the demotion jq filter from arc-phase-stop-hook.sh
# so tests run in isolation against synthetic checkpoints (no hook side
# effects, no shell environment dependencies).
# ---------------------------------------------------------------------------

DEMOTION_JQ="${BATS_TEST_DIRNAME}/../../tmp/test-arc-demotion-gate-fixtures/demotion.jq"
HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../../plugins/rune/scripts/arc-phase-stop-hook.sh"
PHASE_TEMPLATE="${BATS_TEST_DIRNAME}/../../plugins/rune/skills/arc/references/arc-checkpoint-init.md"

setup() {
  setup_project_dir
  setup_config_dir

  # BACK-001 (v2.66.2): anchor extraction on explicit BEGIN_DEMOTION_JQ /
  # END_DEMOTION_JQ markers (jq comments inside the filter body — inert at runtime,
  # unambiguous for awk). Replaces a fragile shell-syntax regex that could match
  # the skip_map block closer at L1092 if a future edit reordered or expanded the
  # demotion block.
  mkdir -p "$(dirname "$DEMOTION_JQ")"
  awk '/# BEGIN_DEMOTION_JQ/ {flag=1; next} /# END_DEMOTION_JQ/ {flag=0} flag' "$HOOK_SCRIPT" > "$DEMOTION_JQ"
}

teardown() {
  teardown_dirs
  rm -f "$DEMOTION_JQ"
}

# Run the demotion jq filter against a JSON checkpoint string.
# Usage: run_demotion '<json>'
# Sets $output to the jq result.
run_demotion() {
  local ckpt="$1"
  local ts="2026-04-26T12:00:00Z"
  printf '%s' "$ckpt" | jq --arg ts "$ts" -f "$DEMOTION_JQ"
}

# ---------------------------------------------------------------------------
# AC-1.1 — schema seed (canonical phase template includes the field)
# ---------------------------------------------------------------------------

@test "AC-1.1: every phase entry in arc-checkpoint-init.md template includes demotion_revert_count: 0" {
  has_jq || skip "jq not installed"

  # Count phase block lines (each starts with `    PHASE: { status: "pending"`).
  local total_phases
  total_phases=$(sed -n '492,546p' "$PHASE_TEMPLATE" | grep -cE '^\s+[a-z_]+:.*\{ status: "pending"')

  # Count phase entries with the new field at end-of-block.
  local phases_with_field
  phases_with_field=$(grep -c 'demotion_revert_count: 0 }' "$PHASE_TEMPLATE")

  # Total should be 44 (current pipeline phase count) and every entry must
  # carry the new field. Use -ge 38 as a forward-tolerant lower bound for
  # future phases added in v2.67+.
  [ "$total_phases" -ge 38 ]
  [ "$phases_with_field" -eq "$total_phases" ]
}

# ---------------------------------------------------------------------------
# AC-1.2 — budget filter (count<3 -> demote + increment + log)
# ---------------------------------------------------------------------------

@test "AC-1.2: count=0 -> demote, increment to 1, log entry with count=1" {
  has_jq || skip "jq not installed"

  local ckpt='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z","demotion_revert_count":0}},"phase_skip_log":[]}'
  local result
  result=$(run_demotion "$ckpt")

  # Output schema check
  echo "$result" | jq -e '.demoted == ["plan_refine"]'
  echo "$result" | jq -e '.auto_filled == []'

  # Phase mutation check
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.status == "pending"'
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.started_at == null'
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.completed_at == null'
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 1'

  # phase_skip_log entry check
  echo "$result" | jq -e '(.checkpoint.phase_skip_log | length) == 1'
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].event == "demoted_to_pending"'
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].count == 1'
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].reason == "missing_skip_reason"'
}

@test "AC-1.2: progression 0->1->2->3 with each iteration appending log entry" {
  has_jq || skip "jq not installed"

  # Start at count=0, simulate the bug condition each round (re-flip status
  # to skipped + clear skip_reason — that's what triggers the loop in prod).
  local ckpt='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z","demotion_revert_count":0}},"phase_skip_log":[]}'

  for iter in 1 2 3; do
    local result
    result=$(run_demotion "$ckpt")
    # Each iteration MUST demote (count<3 each time)
    echo "$result" | jq -e ".demoted == [\"plan_refine\"]"
    echo "$result" | jq -e ".auto_filled == []"
    echo "$result" | jq -e ".checkpoint.phases.plan_refine.demotion_revert_count == ${iter}"
    echo "$result" | jq -e "(.checkpoint.phase_skip_log | length) == ${iter}"
    echo "$result" | jq -e ".checkpoint.phase_skip_log[${iter}-1].event == \"demoted_to_pending\""
    echo "$result" | jq -e ".checkpoint.phase_skip_log[${iter}-1].count == ${iter}"

    # Simulate the bug: phase ends up skipped with empty skip_reason again.
    # Use jq path-update to avoid bash hooks scanning literal `status =` syntax.
    ckpt=$(echo "$result" | jq -c '.checkpoint | setpath(["phases","plan_refine","status"]; "skipped") | setpath(["phases","plan_refine","skip_reason"]; "")')
  done
}

# ---------------------------------------------------------------------------
# AC-1.3 — auto-fill terminator (count>=3 -> skip_reason set + log)
# ---------------------------------------------------------------------------

@test "AC-1.3: count=3 -> auto-fill skip_reason, status stays skipped, log entry recorded" {
  has_jq || skip "jq not installed"

  local ckpt='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z","demotion_revert_count":3}},"phase_skip_log":[]}'
  local result
  result=$(run_demotion "$ckpt")

  echo "$result" | jq -e '.demoted == []'
  echo "$result" | jq -e '.auto_filled == ["plan_refine"]'

  # Phase MUST stay skipped; skip_reason now populated; counter unchanged.
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.status == "skipped"'
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.skip_reason == "auto_filled_after_3_demotion_reverts"'
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 3'

  # phase_skip_log records the terminator event with count=3
  echo "$result" | jq -e '(.checkpoint.phase_skip_log | length) == 1'
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].event == "demotion_loop_terminated"'
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].reason == "auto_filled_after_3_demotion_reverts"'
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].count == 3'
}

@test "AC-1.3: terminated checkpoint -> subsequent fire is a no-op (loop terminator works)" {
  has_jq || skip "jq not installed"

  # Synthesize a checkpoint that already passed the terminator.
  local ckpt='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"auto_filled_after_3_demotion_reverts","demotion_revert_count":3}},"phase_skip_log":[{"event":"demotion_loop_terminated","count":3}]}'
  local result
  result=$(run_demotion "$ckpt")

  echo "$result" | jq -e '.demoted == []'
  echo "$result" | jq -e '.auto_filled == []'
  # No mutation: skip_reason preserved
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.skip_reason == "auto_filled_after_3_demotion_reverts"'
  # No new log entry (length unchanged)
  echo "$result" | jq -e '(.checkpoint.phase_skip_log | length) == 1'
}

# ---------------------------------------------------------------------------
# AC-1.4 — backward compat (v2.66.1 in-flight: no demotion_revert_count field)
# ---------------------------------------------------------------------------

@test "AC-1.4: in-flight v2.66.1 checkpoint (no field) -> first demotion creates field with value 1" {
  has_jq || skip "jq not installed"

  # Fixture mimics v2.66.1 schema — phase block has no demotion_revert_count.
  local ckpt='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z"}},"phase_skip_log":[]}'

  # Pre-condition: confirm the fixture really lacks the field.
  echo "$ckpt" | jq -e '.phases.plan_refine | has("demotion_revert_count") | not'

  local result
  result=$(run_demotion "$ckpt")

  echo "$result" | jq -e '.demoted == ["plan_refine"]'
  echo "$result" | jq -e '.auto_filled == []'

  # Field MUST appear with value 1 after first demotion (// 0 default + increment)
  echo "$result" | jq -e '.checkpoint.phases.plan_refine | has("demotion_revert_count")'
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 1'
  # Phase mutation also applied
  echo "$result" | jq -e '.checkpoint.phases.plan_refine.status == "pending"'
  # Log entry recorded with count=1 (the new value)
  echo "$result" | jq -e '.checkpoint.phase_skip_log[0].count == 1'
}

# ---------------------------------------------------------------------------
# Negative — legitimate skip MUST NOT be touched
# ---------------------------------------------------------------------------

@test "negative: legitimate skip (skip_reason populated) is NOT demoted" {
  has_jq || skip "jq not installed"

  local ckpt='{"phases":{"design_extraction":{"status":"skipped","skip_reason":"design_sync.enabled=false","demotion_revert_count":0}},"phase_skip_log":[]}'
  local result
  result=$(run_demotion "$ckpt")

  echo "$result" | jq -e '.demoted == []'
  echo "$result" | jq -e '.auto_filled == []'
  echo "$result" | jq -e '.checkpoint.phases.design_extraction.status == "skipped"'
  echo "$result" | jq -e '.checkpoint.phases.design_extraction.skip_reason == "design_sync.enabled=false"'
  echo "$result" | jq -e '.checkpoint.phases.design_extraction.demotion_revert_count == 0'
}

# ---------------------------------------------------------------------------
# Negative — already-demoted phase (status=pending) should not re-fire
# ---------------------------------------------------------------------------

@test "negative: pending phase (already demoted) is NOT touched" {
  has_jq || skip "jq not installed"

  local ckpt='{"phases":{"plan_refine":{"status":"pending","skip_reason":null,"demotion_revert_count":1}},"phase_skip_log":[]}'
  local result
  result=$(run_demotion "$ckpt")

  echo "$result" | jq -e '.demoted == []'
  echo "$result" | jq -e '.auto_filled == []'
}
