#!/bin/bash
# scripts/validate-discipline-proofs.sh
# TaskCompleted hook: validates discipline proof evidence before allowing task completion.
# Exit 2 to BLOCK task completion if proofs fail AND block_on_fail is true.
# Exit 0 to allow (non-blocking, WARN mode, or discipline disabled).
#
# Runs BEFORE validate-test-evidence.sh (position 0 in TaskCompleted hooks).
# Scoped to rune-work-* and arc-work-* teams only.
#
# NOTE: 30s hook timeout may be insufficient for complex proof sets containing
# test_passes proofs (which have 60s individual timeouts). Fail-forward ERR trap
# ensures timeout silently allows — this is intentional for rollout safety.

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook — see ADR-002) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    # SEC-007: reject symlink to prevent log redirection attacks
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Read hook input (1MB cap — sufficient for TaskCompleted JSON payloads)
INPUT=$(head -c 1048576 2>/dev/null || true)

# Pre-flight: jq required
if ! command -v jq &>/dev/null; then
  exit 0  # Non-blocking if jq missing
fi

# Validate JSON
if ! printf '%s\n' "$INPUT" | jq empty 2>/dev/null; then
  exit 0
fi

# Extract fields
IFS=$'\t' read -r TEAM_NAME TASK_ID TEAMMATE_NAME <<< \
  "$(printf '%s\n' "$INPUT" | jq -r '[.team_name // "", .task_id // "", .teammate_name // ""] | @tsv' 2>/dev/null)" || true

# Guard: only process Rune teams with valid fields
if [[ -z "$TEAM_NAME" || -z "$TASK_ID" ]]; then
  exit 0
fi

# Scope: only worker teams (rune-work-* and arc-work-*)
if [[ "$TEAM_NAME" != rune-work-* && "$TEAM_NAME" != arc-work-* ]]; then
  exit 0
fi

# Guard: validate ALL identifiers (SEC-001)
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! "$TEAMMATE_NAME" =~ ^[a-zA-Z0-9_:-]+$ ]]; then
  exit 0
fi

CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0

# --- Source platform helpers for portable timestamp comparison ---
SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR_EARLY}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh
  source "${SCRIPT_DIR_EARLY}/lib/platform.sh"
  source "${SCRIPT_DIR_EARLY}/lib/rune-state.sh"
fi

# --- Resolve config dir for talisman config lookup ---
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Check talisman config for discipline settings
DISCIPLINE_ENABLED=true
# Default block_on_fail=true (BLOCK mode). Opt out: discipline.block_on_fail: false in talisman.
BLOCK_ON_FAIL=true
for TALISMAN_PATH in "${CWD}/${RUNE_STATE}/talisman.yml" "${CHOME}/talisman.yml"; do
  if [[ -f "$TALISMAN_PATH" ]]; then
    if command -v yq &>/dev/null; then
      DISCIPLINE_ENABLED=$(yq -r 'if .discipline.enabled == false then "false" else "true" end' "$TALISMAN_PATH" 2>/dev/null) || DISCIPLINE_ENABLED="true"
      BLOCK_ON_FAIL=$(yq -r 'if .discipline.block_on_fail == false then "false" else "true" end' "$TALISMAN_PATH" 2>/dev/null) || BLOCK_ON_FAIL="true"
      # VEIL-004: If yq returned empty (v3/v4 mismatch), default to safe values
      [[ -z "$DISCIPLINE_ENABLED" ]] && DISCIPLINE_ENABLED="true"
      [[ -z "$BLOCK_ON_FAIL" ]] && BLOCK_ON_FAIL="true"
    else
      echo "Discipline: yq not found — cannot read talisman config, defaulting to BLOCK mode (block_on_fail=true)" >&2
    fi
    break
  fi
done

# If discipline is disabled globally, skip
if [[ "$DISCIPLINE_ENABLED" == "false" ]]; then
  exit 0
fi

# --- Evidence discovery ---
# Scan tmp/work/*/evidence/${TASK_ID}/ for evidence files.
# Use most recent timestamp directory first.
EVIDENCE_DIR=""
EVIDENCE_SUMMARY=""

# Find evidence directories matching this task, sorted most recent first
while IFS= read -r candidate; do
  if [[ -d "$candidate" ]]; then
    EVIDENCE_DIR="$candidate"
    if [[ -f "${candidate}/summary.json" ]]; then
      EVIDENCE_SUMMARY="${candidate}/summary.json"
    fi
    break
  fi
done < <(find "${CWD}/tmp/work" -maxdepth 3 -type d -not -type l -name "$TASK_ID" -path "*/evidence/*" 2>/dev/null | sort -r)

# --- Evidence-First Invariant: temporal ordering validation ---
# Evidence MUST be written BEFORE the state transition (task completion).
# This follows the WAL (Write-Ahead Log) pattern: evidence before completion.
# Detects two failure modes:
#   F12 EVIDENCE_FABRICATED: evidence timestamp newer than completion request
#   F3  PROOF_FAILURE: missing evidence at completion time
if [[ -n "$EVIDENCE_DIR" && -n "$EVIDENCE_SUMMARY" ]] && command -v _stat_mtime &>/dev/null; then
  # Get the evidence summary mtime (epoch seconds)
  EVIDENCE_MTIME=$(_stat_mtime "$EVIDENCE_SUMMARY")
  # Current time as the completion request timestamp
  COMPLETION_TIME=$(date +%s 2>/dev/null || true)

  if [[ -n "$EVIDENCE_MTIME" && -n "$COMPLETION_TIME" ]]; then
    # Phantom completion detection: evidence created AFTER completion request
    # A 5-second grace window accounts for filesystem timestamp granularity
    TEMPORAL_GRACE=5
    if [[ "$EVIDENCE_MTIME" -gt $((COMPLETION_TIME + TEMPORAL_GRACE)) ]]; then
      if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
        echo "Discipline: F12 EVIDENCE_FABRICATED — evidence for task ${TASK_ID} has timestamp newer than completion request (evidence_mtime=${EVIDENCE_MTIME}, completion_time=${COMPLETION_TIME}). Evidence must be written BEFORE task completion (WAL invariant)." >&2
        exit 2
      else
        echo "Discipline: F12 EVIDENCE_FABRICATED — evidence for task ${TASK_ID} has suspicious temporal ordering (WARN mode — not blocking)." >&2
      fi
    fi

    # Check for empty evidence (summary exists but no criteria results)
    CRITERIA_COUNT=$(jq '.criteria_results | length' "$EVIDENCE_SUMMARY" 2>/dev/null) || CRITERIA_COUNT=""
    if [[ "$CRITERIA_COUNT" == "0" || -z "$CRITERIA_COUNT" ]]; then
      if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
        echo "Discipline: F3 PROOF_FAILURE — evidence summary for task ${TASK_ID} exists but contains no criteria results. Missing evidence at completion time." >&2
        exit 2
      else
        echo "Discipline: F3 PROOF_FAILURE — evidence summary for task ${TASK_ID} has no criteria results (WARN mode — not blocking)." >&2
      fi
    fi
  fi
fi

# No evidence directory exists -> BLOCK (default) or WARN (if block_on_fail=false)
if [[ -z "$EVIDENCE_DIR" ]]; then
  if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
    echo "Discipline: No evidence directory found for task ${TASK_ID}. Workers must provide proof evidence before completing tasks." >&2
    exit 2
  else
    echo "Discipline: No evidence directory found for task ${TASK_ID} (WARN mode — not blocking)." >&2
    exit 0
  fi
fi

# Evidence directory exists but no summary.json -> BLOCK (default) or WARN (if block_on_fail=false)
if [[ -z "$EVIDENCE_SUMMARY" ]]; then
  if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
    echo "Discipline: Evidence directory exists for task ${TASK_ID} but summary.json is missing. Complete evidence collection before task completion." >&2
    exit 2
  else
    echo "Discipline: Evidence directory exists for task ${TASK_ID} but summary.json is missing (WARN mode — not blocking)." >&2
    exit 0
  fi
fi

# --- Criteria-based proof execution ---
# Look for criteria.json in evidence directory
CRITERIA_FILE="${EVIDENCE_DIR}/criteria.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXECUTOR="${SCRIPT_DIR}/execute-discipline-proofs.sh"

if [[ -f "$CRITERIA_FILE" ]]; then
  # execute-discipline-proofs.sh not found -> WARN (Shard 3 dependency missing)
  if [[ ! -x "$EXECUTOR" ]]; then
    echo "Discipline: execute-discipline-proofs.sh not found or not executable — cannot validate proofs (WARN)." >&2
    exit 0
  fi

  # Run proof executor — capture exit code separately to distinguish executor failure from pass
  PROOF_OUTPUT=""
  PROOF_EXIT=0
  PROOF_OUTPUT=$("$EXECUTOR" "$CRITERIA_FILE" "$CWD" 2>/dev/null) || PROOF_EXIT=$?
  if [[ "$PROOF_EXIT" -ne 0 && -z "$PROOF_OUTPUT" ]]; then
    echo "Discipline: execute-discipline-proofs.sh failed (exit ${PROOF_EXIT}) with no output — executor failure, not proof pass (WARN)." >&2
    exit 0
  fi

  # Parse output for FAIL results
  if [[ -n "$PROOF_OUTPUT" ]]; then
    # Validate output is a JSON array before processing
    if ! printf '%s\n' "$PROOF_OUTPUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "Discipline: Proof executor output is not a JSON array — skipping validation (WARN)." >&2
      exit 0
    fi
    FAIL_COUNT=$(printf '%s\n' "$PROOF_OUTPUT" | jq '[.[] | select(.result == "FAIL")] | length' 2>/dev/null) || FAIL_COUNT=0
    TOTAL_COUNT=$(printf '%s\n' "$PROOF_OUTPUT" | jq 'length' 2>/dev/null) || TOTAL_COUNT=0

    # Extract failure_codes from FAIL results and aggregate into evidence summary
    FAILURE_CODES_JSON=$(printf '%s\n' "$PROOF_OUTPUT" | jq -c '[.[] | select(.result == "FAIL") | select(.failure_code != null and .failure_code != "") | .failure_code] | unique' 2>/dev/null) || FAILURE_CODES_JSON="[]"

    # Update evidence summary with failure_codes array if summary.json exists
    if [[ -n "$EVIDENCE_SUMMARY" && -f "$EVIDENCE_SUMMARY" ]]; then
      TMP_SUMMARY="${EVIDENCE_SUMMARY}.tmp"
      jq --argjson failure_codes "$FAILURE_CODES_JSON" '. + {failure_codes: $failure_codes}' "$EVIDENCE_SUMMARY" > "$TMP_SUMMARY" 2>/dev/null && mv "$TMP_SUMMARY" "$EVIDENCE_SUMMARY" || rm -f "$TMP_SUMMARY"
    fi

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
      # Extract failed criterion IDs for feedback
      FAILED_IDS=$(printf '%s\n' "$PROOF_OUTPUT" | jq -r '[.[] | select(.result == "FAIL") | .criterion_id] | join(", ")' 2>/dev/null) || FAILED_IDS="unknown"

      # Extract unique failure codes for feedback
      FAILURE_CODE_LIST=$(printf '%s\n' "$PROOF_OUTPUT" | jq -r '[.[] | select(.result == "FAIL") | select(.failure_code != null and .failure_code != "") | .failure_code] | unique | join(", ")' 2>/dev/null) || FAILURE_CODE_LIST=""

      if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
        if [[ -n "$FAILURE_CODE_LIST" ]]; then
          echo "Discipline: ${FAIL_COUNT}/${TOTAL_COUNT} proofs FAILED for task ${TASK_ID}. Failed criteria: ${FAILED_IDS}. Failure codes: ${FAILURE_CODE_LIST}. Fix failing proofs before completing this task." >&2
        else
          echo "Discipline: ${FAIL_COUNT}/${TOTAL_COUNT} proofs FAILED for task ${TASK_ID}. Failed criteria: ${FAILED_IDS}. Fix failing proofs before completing this task." >&2
        fi
        exit 2  # BLOCK — task completion denied
      else
        if [[ -n "$FAILURE_CODE_LIST" ]]; then
          echo "Discipline: ${FAIL_COUNT}/${TOTAL_COUNT} proofs FAILED for task ${TASK_ID}. Failed criteria: ${FAILED_IDS}. Failure codes: ${FAILURE_CODE_LIST} (WARN mode — not blocking)." >&2
        else
          echo "Discipline: ${FAIL_COUNT}/${TOTAL_COUNT} proofs FAILED for task ${TASK_ID}. Failed criteria: ${FAILED_IDS} (WARN mode — not blocking)." >&2
        fi
        exit 0  # WARN only
      fi
    fi
  fi
fi

# --- Task file validation (AC-8, AC-9) ---
# Check task file for required Worker Report sections.
# If task file does NOT exist: warn but don't block (backward compatibility — AC-8).
# If task file exists: check for required sections and [x] checklist items.
TASK_FILE=""
while IFS= read -r candidate; do
  if [[ -f "$candidate" ]]; then
    TASK_FILE="$candidate"
    break
  fi
done < <(find "${CWD}/tmp/work" -maxdepth 3 -type f -not -type l -name "task-${TASK_ID}.md" -path "*/tasks/*" 2>/dev/null | sort -r)

if [[ -z "$TASK_FILE" ]]; then
  # Task file not found — warn only (backward compat for pre-discipline task files)
  echo "Discipline: task file not found for task ${TASK_ID} (tmp/work/*/tasks/task-${TASK_ID}.md) — skipping task file checks (WARN)." >&2
else
  TASK_FILE_ISSUES=""

  # Check for ### Echo-Back section
  if ! grep -q "### Echo-Back" "$TASK_FILE" 2>/dev/null; then
    TASK_FILE_ISSUES="${TASK_FILE_ISSUES} [MISSING: ### Echo-Back section]"
  fi

  # Check for ### Self-Review Checklist section
  if ! grep -q "### Self-Review Checklist" "$TASK_FILE" 2>/dev/null; then
    TASK_FILE_ISSUES="${TASK_FILE_ISSUES} [MISSING: ### Self-Review Checklist section]"
  fi

  # Check for at least one [x] checked item (evidence of completed checklist)
  if ! grep -q "\[x\]" "$TASK_FILE" 2>/dev/null; then
    TASK_FILE_ISSUES="${TASK_FILE_ISSUES} [MISSING: no [x] checked items in checklist]"
  fi

  # Check for ### Evidence section
  if ! grep -q "### Evidence" "$TASK_FILE" 2>/dev/null; then
    TASK_FILE_ISSUES="${TASK_FILE_ISSUES} [MISSING: ### Evidence section]"
  fi

  if [[ -n "$TASK_FILE_ISSUES" ]]; then
    if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
      echo "Discipline: task file ${TASK_FILE} is missing required sections:${TASK_FILE_ISSUES}. Complete Worker Report before marking task complete." >&2
      exit 2  # BLOCK — task completion denied
    else
      echo "Discipline: task file ${TASK_FILE} is missing required sections:${TASK_FILE_ISSUES} (WARN mode — not blocking)." >&2
    fi
  fi
fi

# All proofs passed or no criteria to check
exit 0
