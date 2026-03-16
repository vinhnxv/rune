#!/bin/bash
# scripts/validate-inner-flame.sh
# TaskCompleted hook: validates Inner Flame self-review was performed.
# Exit 2 to BLOCK task completion if self-review is missing AND block_on_fail is true.
# Exit 0 to allow (non-blocking or soft enforcement).

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# BACK-004 FIX: Removed early yq guard (was: exit 0 before stdin read).
# yq is only needed for talisman config parsing (lines 68-81), guarded there.

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

# Guard: only process Rune teams
if [[ -z "$TEAM_NAME" || -z "$TASK_ID" ]]; then
  exit 0
fi
if [[ "$TEAM_NAME" != rune-* && "$TEAM_NAME" != arc-* ]]; then
  exit 0
fi

# Guard: validate ALL identifiers (SEC-001: TEAMMATE_NAME was missing)
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! "$TEAMMATE_NAME" =~ ^[a-zA-Z0-9_:-]+$ ]]; then
  exit 0
fi

CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0

# Check talisman config for inner_flame settings (QUAL-001/SEC-002)
# CHOME: CLAUDE_CONFIG_DIR pattern for multi-account support (user-level talisman)
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# QUAL-007 FIX: BLOCK_ON_FAIL defaults to false (soft enforcement) but talisman's
# inner_flame.block_on_fail defaults to true via yq fallback — so if talisman exists
# with inner_flame section, blocking is ON unless explicitly set to false.
BLOCK_ON_FAIL=false
INNER_FLAME_ENABLED=true
for TALISMAN_PATH in "${CWD}/.claude/talisman.yml" "${CHOME}/talisman.yml"; do
  if [[ -f "$TALISMAN_PATH" ]]; then
    if command -v yq &>/dev/null; then
      # NOTE: Checks YAML boolean false only. String "false" is not treated as disabled (standard YAML convention).
      INNER_FLAME_ENABLED=$(yq -r 'if .inner_flame.enabled == false then "false" else "true" end' "$TALISMAN_PATH" 2>/dev/null) || INNER_FLAME_ENABLED="true"
      BLOCK_ON_FAIL=$(yq -r 'if .inner_flame.block_on_fail == false then "false" else "true" end' "$TALISMAN_PATH" 2>/dev/null) || BLOCK_ON_FAIL="true"
      # VEIL-004: If yq returned empty (v3/v4 mismatch), default to safe values
      [[ -z "$INNER_FLAME_ENABLED" ]] && INNER_FLAME_ENABLED="true"
      [[ -z "$BLOCK_ON_FAIL" ]] && BLOCK_ON_FAIL="true"
    else
      echo "Inner Flame: yq not found — cannot read talisman config, defaulting to soft enforcement" >&2
    fi
    break
  fi
done

# If Inner Flame is disabled globally, skip
if [[ "$INNER_FLAME_ENABLED" == "false" ]]; then
  exit 0
fi

# Determine output directory based on team name pattern (QUAL-005: added arc-* patterns)
OUTPUT_DIR=""
if [[ "$TEAM_NAME" == rune-review-* ]]; then
  REVIEW_ID="${TEAM_NAME#rune-review-}"
  # SEC-008 FIX: Guard against empty ID after prefix strip
  [[ -z "$REVIEW_ID" ]] && exit 0
  OUTPUT_DIR="${CWD}/tmp/reviews/${REVIEW_ID}"
elif [[ "$TEAM_NAME" == arc-review-* ]]; then
  REVIEW_ID="${TEAM_NAME#arc-review-}"
  [[ -z "$REVIEW_ID" ]] && exit 0
  OUTPUT_DIR="${CWD}/tmp/reviews/${REVIEW_ID}"
elif [[ "$TEAM_NAME" == rune-audit-* ]]; then
  AUDIT_ID="${TEAM_NAME#rune-audit-}"
  [[ -z "$AUDIT_ID" ]] && exit 0
  OUTPUT_DIR="${CWD}/tmp/audit/${AUDIT_ID}"
elif [[ "$TEAM_NAME" == arc-audit-* ]]; then
  AUDIT_ID="${TEAM_NAME#arc-audit-}"
  [[ -z "$AUDIT_ID" ]] && exit 0
  OUTPUT_DIR="${CWD}/tmp/audit/${AUDIT_ID}"
elif [[ "$TEAM_NAME" == rune-work-* || "$TEAM_NAME" == arc-work-* ]]; then
  # Workers write evidence to tmp/work/{timestamp}/evidence/{task-id}/summary.json
  # NOTE: Similar evidence discovery in validate-discipline-proofs.sh — keep in sync
  EVIDENCE_FILE=$(find "${CWD}/tmp/work" -maxdepth 4 -path "*/evidence/${TASK_ID}/summary.json" -print -quit 2>/dev/null || true)
  if [[ -n "$EVIDENCE_FILE" && -f "$EVIDENCE_FILE" ]]; then
    # Validate summary.json has result field (basic schema check)
    if jq -e '.result' "$EVIDENCE_FILE" &>/dev/null; then
      exit 0  # Evidence found and valid — allow
    fi
    # Evidence file exists but missing result field — warn
    echo "Inner Flame: Worker evidence at ${EVIDENCE_FILE} missing 'result' field (incomplete evidence)." >&2
    if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
      exit 2  # BLOCK — evidence incomplete
    fi
    exit 0  # WARN only
  fi
  # No evidence found for worker task
  if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
    echo "Inner Flame: No evidence summary found for worker task ${TASK_ID}. Write evidence to tmp/work/*/evidence/${TASK_ID}/summary.json before completing." >&2
    exit 2  # BLOCK — no evidence
  fi
  echo "Inner Flame: No evidence summary found for worker task ${TASK_ID} (soft enforcement — not blocking)." >&2
  exit 0  # WARN only — soft enforcement
elif [[ "$TEAM_NAME" == rune-mend-* || "$TEAM_NAME" == arc-mend-* ]]; then
  # Mend fixers — check is via Seal message
  exit 0
elif [[ "$TEAM_NAME" == rune-inspect-* || "$TEAM_NAME" == arc-inspect-* ]]; then
  INSPECT_ID="${TEAM_NAME#rune-inspect-}"
  [[ "$TEAM_NAME" == arc-inspect-* ]] && INSPECT_ID="${TEAM_NAME#arc-inspect-}"
  OUTPUT_DIR="${CWD}/tmp/inspect/${INSPECT_ID}"
fi

# If no output dir, skip
if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
  exit 0
fi

# Path containment check (SEC-003): verify OUTPUT_DIR is under CWD/tmp/
REAL_OUTPUT_DIR=$(cd "$OUTPUT_DIR" 2>/dev/null && pwd -P) || exit 0
case "$REAL_OUTPUT_DIR" in
  "${CWD}/tmp/"*) ;; # OK — within project tmp/
  *) exit 0 ;; # Outside project — skip
esac

# Check if teammate's output file contains Inner Flame content
TEAMMATE_FILE="${OUTPUT_DIR}/${TEAMMATE_NAME}.md"
if [[ ! -f "$TEAMMATE_FILE" ]]; then
  # Output file not yet written — can't validate
  exit 0
fi

# Check for Inner Flame content (SEC-007/QUAL-010: matches canonical SKILL.md format + Seal variants)
if ! grep -qE "Self-Review Log.*Inner Flame|Inner Flame:|Inner-flame:" "$TEAMMATE_FILE" 2>/dev/null; then
  if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
    echo "Inner Flame: Self-Review Log with Inner Flame content missing from ${TEAMMATE_NAME}'s output. Re-read your work and add Inner Flame self-review before sealing." >&2
    exit 2  # BLOCK — task completion denied
  else
    echo "Inner Flame: Self-Review Log with Inner Flame content missing from ${TEAMMATE_NAME}'s output (soft enforcement — not blocking)." >&2
    exit 0  # WARN only — soft enforcement (default)
  fi
fi

exit 0
