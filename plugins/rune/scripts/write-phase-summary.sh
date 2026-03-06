#!/usr/bin/env bash
# write-phase-summary.sh — Deterministic phase group summary generator
# Usage: write-phase-summary.sh <group_name> <arc_id> <phase_range>
# Reads: .claude/arc/{id}/checkpoint.json, tmp/arc/{id}/*-digest.json
# Writes: tmp/arc/{id}/phase-summary-{group}.md
# Token cost: ZERO (pure shell, no LLM)
set -euo pipefail

GROUP_NAME="${1:?Missing group name (forge|verify|work|review|ship)}"
ARC_ID="${2:?Missing arc ID}"
PHASE_RANGE="${3:?Missing phase range}"

# Validate inputs (SEC-003)
if [[ ! "$ARC_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: Invalid arc ID: $ARC_ID" >&2
  exit 1
fi
if [[ ! "$GROUP_NAME" =~ ^(forge|verify|work|review|ship)$ ]]; then
  echo "ERROR: Invalid group name: $GROUP_NAME" >&2
  exit 1
fi

CHECKPOINT=".claude/arc/${ARC_ID}/checkpoint.json"
ARC_DIR="tmp/arc/${ARC_ID}"
OUTPUT="${ARC_DIR}/phase-summary-${GROUP_NAME}.md"

# Check jq availability
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not installed — phase summary requires jq" >&2
  exit 1
fi

# Check checkpoint exists
if [[ ! -f "$CHECKPOINT" ]]; then
  echo "WARN: Checkpoint not found: $CHECKPOINT" >&2
  exit 1
fi

# Extract plan file from checkpoint
PLAN_FILE=$(jq -r '.plan_file // "unknown"' "$CHECKPOINT" 2>/dev/null || echo "unknown")

# Determine overall status from phase statuses
STATUS="completed"
FAILED_PHASES=$(jq -r '
  .phases // {} | to_entries[] |
  select(.value.status == "failed") |
  .key
' "$CHECKPOINT" 2>/dev/null || true)
if [[ -n "$FAILED_PHASES" ]]; then
  STATUS="partial"
fi

# Collect available digest data
DIGEST_LINES=""
if [[ -f "${ARC_DIR}/tome-digest.json" ]]; then
  # Pick latest tome-digest (handles round-aware naming)
  LATEST_TOME=""
  for f in "${ARC_DIR}"/tome-digest*.json; do
    [[ -f "$f" ]] || continue
    LATEST_TOME="$f"
  done
  if [[ -n "$LATEST_TOME" ]]; then
    TOME_LINE=$(jq -r '"- TOME: P1=\(.p1_count // 0), P2=\(.p2_count // 0), P3=\(.p3_count // 0), total=\(.total_findings // 0)"' "$LATEST_TOME" 2>/dev/null || echo "- TOME: digest parse error")
    DIGEST_LINES="${DIGEST_LINES}${TOME_LINE}\n"
  fi
fi
if [[ -f "${ARC_DIR}/gap-analysis-digest.json" ]]; then
  GAP_LINE=$(jq -r '"- Gap: completion=\(.completion_pct // 0)%, missing=\(.missing_count // 0), partial=\(.partial_count // 0)"' "${ARC_DIR}/gap-analysis-digest.json" 2>/dev/null || echo "- Gap: digest parse error")
  DIGEST_LINES="${DIGEST_LINES}${GAP_LINE}\n"
fi
if [[ -f "${ARC_DIR}/work-summary-digest.json" ]]; then
  WORK_LINE=$(jq -r '"- Work: \(.tasks_completed // 0)/\(.tasks_total // 0) tasks, \(.committed_file_count // 0) files"' "${ARC_DIR}/work-summary-digest.json" 2>/dev/null || echo "- Work: digest parse error")
  DIGEST_LINES="${DIGEST_LINES}${WORK_LINE}\n"
fi
if [[ -f "${ARC_DIR}/verdict-digest.json" ]]; then
  VERDICT_LINE=$(jq -r '"- Verdict: \(.low_scoring | length // 0) low-scoring dimensions"' "${ARC_DIR}/verdict-digest.json" 2>/dev/null || echo "- Verdict: digest parse error")
  DIGEST_LINES="${DIGEST_LINES}${VERDICT_LINE}\n"
fi

# Default if no digests available
if [[ -z "$DIGEST_LINES" ]]; then
  DIGEST_LINES="- No digest data available for this group\n"
fi

# Collect artifact paths from checkpoint
ARTIFACTS=$(jq -r '
  .phases // {} | to_entries[] |
  select(.value.artifact != null) |
  "| \(.key) | \(.value.artifact) | \(.value.status // "ok") |"
' "$CHECKPOINT" 2>/dev/null || echo "| (none) | — | — |")

# Write summary
cat > "$OUTPUT" <<EOF
# Arc Phase Summary: ${GROUP_NAME}

**Plan**: ${PLAN_FILE}
**Arc ID**: ${ARC_ID}
**Phases**: ${PHASE_RANGE}
**Status**: ${STATUS}

## Accomplished

$(printf '%b' "$DIGEST_LINES")

## Artifacts Produced

| Artifact | Path | Status |
|----------|------|--------|
${ARTIFACTS}

## Carry-Forward State

- Phase group: ${GROUP_NAME} (${PHASE_RANGE})
- Status: ${STATUS}

## Decisions Made

- Phase group ${GROUP_NAME} completed with status: ${STATUS}
$(if [[ -n "$FAILED_PHASES" ]]; then echo "- Decision: Continue pipeline despite failures in: ${FAILED_PHASES}"; fi)

## Issues Encountered

$(if [[ -n "$FAILED_PHASES" ]]; then echo "- Failed phases: ${FAILED_PHASES}"; else echo "- No issues encountered"; fi)
EOF

echo "Phase summary written: ${OUTPUT}"
