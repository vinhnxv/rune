#!/bin/bash
# tests/test_arc_demotion_gate.sh — Arc Demotion Gate (Shard 1, v2.66.2)
#
# Plain-bash test harness covering AC-1.1 .. AC-1.4 of
# plans/2026-04-26-feat-arc-unified-retry-heal-shard-1-plan.md.
#
# Convention note: this repo's tests/bats/ contains test_guard_clauses.bats and
# a test_helper.bash, so the same suite is also available as a bats file at
# tests/bats/test_arc_demotion_gate.bats for when the bats harness is adopted.
# This `.sh` version is the canonical executable form today (bats not yet
# wired into the project Makefile). The plan literal asked for `.sh`.
#
# Run from repo root:
#   bash tests/test_arc_demotion_gate.sh
# Exit 0 = all assertions pass; exit 1 = any failure.
#
# Coverage:
#   AC-1.1  schema seed       — every phase block in the canonical phase
#                                template includes demotion_revert_count: 0.
#   AC-1.2  budget filter     — count<3 -> demote + increment + log entry.
#   AC-1.3  auto-fill term.   — count>=3 -> skip_reason set + log entry;
#                                subsequent fires are no-ops.
#   AC-1.4  v2.66.1 in-flight — missing field handled via // 0 default.
#   negative tests            — legitimate skip + already-demoted phase.

set -uo pipefail

# Resolve repo root (script is at tests/<this>; repo root is one level up)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HOOK_SCRIPT="${REPO_ROOT}/plugins/rune/scripts/arc-phase-stop-hook.sh"
PHASE_TEMPLATE="${REPO_ROOT}/plugins/rune/skills/arc/references/arc-checkpoint-init.md"

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
FAIL_DETAILS=()

# Colors (degrade gracefully on non-tty)
if [ -t 1 ]; then
  C_GREEN=$(printf '\033[0;32m')
  C_RED=$(printf '\033[0;31m')
  C_YELLOW=$(printf '\033[0;33m')
  C_RESET=$(printf '\033[0m')
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

# Workspace (cleaned on EXIT)
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-arc-demotion-gate-XXXXXX")"
DEMOTION_JQ="${WORKDIR}/demotion.jq"
trap 'rm -rf "${WORKDIR}" 2>/dev/null' EXIT

# _assert <description> <test-command-string>
# Runs eval on the command; on success increments PASS_COUNT, on failure
# captures stderr + the failing command.
_assert() {
  local desc="$1"; shift
  local cmd="$*"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$desc"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAIL_DETAILS+=("$desc :: $cmd")
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$desc"
  fi
}

_section() {
  printf '\n%s=== %s ===%s\n' "$C_YELLOW" "$1" "$C_RESET"
}

# Pre-flight
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq not installed — cannot run any assertions."
  exit 2
fi
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "FATAL: hook script not found at $HOOK_SCRIPT"
  exit 2
fi
if [ ! -f "$PHASE_TEMPLATE" ]; then
  echo "FATAL: phase template not found at $PHASE_TEMPLATE"
  exit 2
fi

# ---------------------------------------------------------------------------
# Setup: extract the demotion jq filter from the hook script
# ---------------------------------------------------------------------------
# BACK-001: anchor extraction on explicit BEGIN_DEMOTION_JQ / END_DEMOTION_JQ
# markers (added v2.66.2) instead of fragile shell-syntax regex. The markers are
# jq comments inside the filter body, so they're inert at runtime but unambiguous
# for awk. If the markers are missing or zero lines extracted, the test fails
# fast with a clear "extraction failed" error rather than a confusing jq syntax
# error from a partially-extracted filter.

awk '/# BEGIN_DEMOTION_JQ/ {flag=1; next} /# END_DEMOTION_JQ/ {flag=0} flag' \
  "$HOOK_SCRIPT" > "$DEMOTION_JQ"

if ! [ -s "$DEMOTION_JQ" ]; then
  echo "FATAL: failed to extract demotion jq filter from $HOOK_SCRIPT"
  echo "       (expected BEGIN_DEMOTION_JQ / END_DEMOTION_JQ markers — added in v2.66.2)"
  exit 2
fi

# Run the demotion jq against a JSON checkpoint string. Echoes result to stdout.
run_demotion() {
  local ckpt="$1"
  local ts="2026-04-26T12:00:00Z"
  printf '%s' "$ckpt" | jq --arg ts "$ts" -f "$DEMOTION_JQ"
}

# ---------------------------------------------------------------------------
# AC-1.1 — schema seed
# ---------------------------------------------------------------------------

_section "AC-1.1: schema seed in canonical phase template"

# Use grep to count phase blocks vs phase entries with the new field.
TOTAL_PHASES=$(sed -n '492,546p' "$PHASE_TEMPLATE" | grep -cE '^\s+[a-z_]+:.*\{ status: "pending"')
PHASES_WITH_FIELD=$(grep -c 'demotion_revert_count: 0 }' "$PHASE_TEMPLATE")

_assert "AC-1.1: at least 38 phase entries in template" "[ \"$TOTAL_PHASES\" -ge 38 ]"
_assert "AC-1.1: every phase entry includes demotion_revert_count: 0 (count $PHASES_WITH_FIELD == $TOTAL_PHASES)" \
  "[ \"$PHASES_WITH_FIELD\" -eq \"$TOTAL_PHASES\" ]"

# ---------------------------------------------------------------------------
# AC-1.2 — budget filter (count<3)
# ---------------------------------------------------------------------------

_section "AC-1.2: budget filter (count<3 -> demote + increment + log)"

CKPT_AC12='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z","demotion_revert_count":0}},"phase_skip_log":[]}'
RESULT_AC12=$(run_demotion "$CKPT_AC12")

_assert "AC-1.2: demoted contains plan_refine"   "echo '$RESULT_AC12' | jq -e '.demoted == [\"plan_refine\"]'"
_assert "AC-1.2: auto_filled is empty"           "echo '$RESULT_AC12' | jq -e '.auto_filled == []'"
_assert "AC-1.2: phase status flipped to pending" "echo '$RESULT_AC12' | jq -e '.checkpoint.phases.plan_refine.status == \"pending\"'"
_assert "AC-1.2: started_at = null"               "echo '$RESULT_AC12' | jq -e '.checkpoint.phases.plan_refine.started_at == null'"
_assert "AC-1.2: completed_at = null"             "echo '$RESULT_AC12' | jq -e '.checkpoint.phases.plan_refine.completed_at == null'"
_assert "AC-1.2: counter incremented to 1"        "echo '$RESULT_AC12' | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 1'"
_assert "AC-1.2: phase_skip_log has 1 entry"      "echo '$RESULT_AC12' | jq -e '(.checkpoint.phase_skip_log | length) == 1'"
_assert "AC-1.2: log event = demoted_to_pending"  "echo '$RESULT_AC12' | jq -e '.checkpoint.phase_skip_log[0].event == \"demoted_to_pending\"'"
_assert "AC-1.2: log count = 1"                   "echo '$RESULT_AC12' | jq -e '.checkpoint.phase_skip_log[0].count == 1'"
_assert "AC-1.2: log reason = missing_skip_reason" "echo '$RESULT_AC12' | jq -e '.checkpoint.phase_skip_log[0].reason == \"missing_skip_reason\"'"

# Progression: 0 -> 1 -> 2 -> 3 demotions allowed; each iteration appends a log entry
CKPT_PROG='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z","demotion_revert_count":0}},"phase_skip_log":[]}'
for ITER in 1 2 3; do
  RESULT_PROG=$(run_demotion "$CKPT_PROG")
  _assert "AC-1.2 (iter $ITER): demoted plan_refine" \
    "echo '$RESULT_PROG' | jq -e '.demoted == [\"plan_refine\"]'"
  _assert "AC-1.2 (iter $ITER): counter == $ITER" \
    "echo '$RESULT_PROG' | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == $ITER'"
  _assert "AC-1.2 (iter $ITER): log_size == $ITER" \
    "echo '$RESULT_PROG' | jq -e '(.checkpoint.phase_skip_log | length) == $ITER'"

  # Simulate the bug: phase ends up skipped+empty again (use jq path-update so
  # the bash command line never contains a literal `status =` substring that
  # the ZSH-001 hook treats as a read-only assignment).
  CKPT_PROG=$(echo "$RESULT_PROG" | jq -c '.checkpoint | setpath(["phases","plan_refine","status"]; "skipped") | setpath(["phases","plan_refine","skip_reason"]; "")')
done

# ---------------------------------------------------------------------------
# AC-1.3 — auto-fill terminator (count>=3)
# ---------------------------------------------------------------------------

_section "AC-1.3: auto-fill terminator (count>=3)"

CKPT_AC13='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z","demotion_revert_count":3}},"phase_skip_log":[]}'
RESULT_AC13=$(run_demotion "$CKPT_AC13")

_assert "AC-1.3: demoted is empty"                "echo '$RESULT_AC13' | jq -e '.demoted == []'"
_assert "AC-1.3: auto_filled contains plan_refine" "echo '$RESULT_AC13' | jq -e '.auto_filled == [\"plan_refine\"]'"
_assert "AC-1.3: phase status STAYS skipped"      "echo '$RESULT_AC13' | jq -e '.checkpoint.phases.plan_refine.status == \"skipped\"'"
_assert "AC-1.3: skip_reason auto-filled"          "echo '$RESULT_AC13' | jq -e '.checkpoint.phases.plan_refine.skip_reason == \"auto_filled_after_3_demotion_reverts\"'"
_assert "AC-1.3: counter unchanged at 3"          "echo '$RESULT_AC13' | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 3'"
_assert "AC-1.3: log event = demotion_loop_terminated" "echo '$RESULT_AC13' | jq -e '.checkpoint.phase_skip_log[0].event == \"demotion_loop_terminated\"'"
_assert "AC-1.3: log count = 3"                    "echo '$RESULT_AC13' | jq -e '.checkpoint.phase_skip_log[0].count == 3'"

# Loop termination: re-run on terminated checkpoint should be no-op
TERMINATED=$(echo "$RESULT_AC13" | jq -c '.checkpoint')
RESULT_TERM=$(run_demotion "$TERMINATED")
_assert "AC-1.3: terminated checkpoint -> demoted is empty (no-op)" \
  "echo '$RESULT_TERM' | jq -e '.demoted == []'"
_assert "AC-1.3: terminated checkpoint -> auto_filled is empty (no-op)" \
  "echo '$RESULT_TERM' | jq -e '.auto_filled == []'"
_assert "AC-1.3: terminated checkpoint -> skip_reason preserved" \
  "echo '$RESULT_TERM' | jq -e '.checkpoint.phases.plan_refine.skip_reason == \"auto_filled_after_3_demotion_reverts\"'"

# ---------------------------------------------------------------------------
# AC-1.4 — v2.66.1 in-flight (missing field)
# ---------------------------------------------------------------------------

_section "AC-1.4: v2.66.1 in-flight (missing field handled via // 0)"

CKPT_AC14='{"phases":{"plan_refine":{"status":"skipped","skip_reason":"","started_at":"2026-04-26T10:00:00Z","completed_at":"2026-04-26T10:01:00Z"}},"phase_skip_log":[]}'

# Pre-condition: confirm the fixture really lacks the field
_assert "AC-1.4 pre: fixture missing demotion_revert_count" \
  "echo '$CKPT_AC14' | jq -e '.phases.plan_refine | has(\"demotion_revert_count\") | not'"

RESULT_AC14=$(run_demotion "$CKPT_AC14")

_assert "AC-1.4: demoted contains plan_refine"           "echo '$RESULT_AC14' | jq -e '.demoted == [\"plan_refine\"]'"
_assert "AC-1.4: field appears after first demotion"      "echo '$RESULT_AC14' | jq -e '.checkpoint.phases.plan_refine | has(\"demotion_revert_count\")'"
_assert "AC-1.4: field == 1 (created by // 0 + increment)" "echo '$RESULT_AC14' | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 1'"
_assert "AC-1.4: phase status flipped to pending"         "echo '$RESULT_AC14' | jq -e '.checkpoint.phases.plan_refine.status == \"pending\"'"
_assert "AC-1.4: log entry recorded with count=1"         "echo '$RESULT_AC14' | jq -e '.checkpoint.phase_skip_log[0].count == 1'"

# ---------------------------------------------------------------------------
# Negative tests
# ---------------------------------------------------------------------------

_section "negative: legitimate skip + already-demoted"

# Legitimate skip — skip_reason populated, MUST NOT be touched
CKPT_LEGIT='{"phases":{"design_extraction":{"status":"skipped","skip_reason":"design_sync.enabled=false","demotion_revert_count":0}},"phase_skip_log":[]}'
RESULT_LEGIT=$(run_demotion "$CKPT_LEGIT")
_assert "negative: legitimate skip not demoted"  "echo '$RESULT_LEGIT' | jq -e '.demoted == []'"
_assert "negative: legitimate skip reason preserved" "echo '$RESULT_LEGIT' | jq -e '.checkpoint.phases.design_extraction.skip_reason == \"design_sync.enabled=false\"'"

# Already pending — MUST NOT be touched
CKPT_PENDING='{"phases":{"plan_refine":{"status":"pending","skip_reason":null,"demotion_revert_count":1}},"phase_skip_log":[]}'
RESULT_PENDING=$(run_demotion "$CKPT_PENDING")
_assert "negative: already-pending not demoted" "echo '$RESULT_PENDING' | jq -e '.demoted == []'"
_assert "negative: already-pending counter unchanged" "echo '$RESULT_PENDING' | jq -e '.checkpoint.phases.plan_refine.demotion_revert_count == 1'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '%s================================%s\n' "$C_YELLOW" "$C_RESET"
printf 'Test summary: %s%d PASS%s, %s%d FAIL%s\n' "$C_GREEN" "$PASS_COUNT" "$C_RESET" "$C_RED" "$FAIL_COUNT" "$C_RESET"
printf '%s================================%s\n' "$C_YELLOW" "$C_RESET"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '\n%sFailing assertions:%s\n' "$C_RED" "$C_RESET"
  for d in "${FAIL_DETAILS[@]}"; do
    printf '  - %s\n' "$d"
  done
  exit 1
fi
exit 0
