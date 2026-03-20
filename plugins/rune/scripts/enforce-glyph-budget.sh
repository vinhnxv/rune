#!/bin/bash
# scripts/enforce-glyph-budget.sh
# GLYPH-BUDGET-001: Advisory enforcement for teammate message size.
# PostToolUse:SendMessage hook — injects additionalContext when a teammate
# sends a message exceeding the glyph budget (default: 300 words).
#
# Non-blocking: PostToolUse cannot block tool execution. This hook injects
# advisory context only, informing the orchestrator of the violation.
#
# Guard: Only active during Rune workflows (state files present).
# Concern C3: Uses explicit file paths with [[ -f ]] guards (no globs).

set -euo pipefail
umask 077  # PAT-005 FIX: Consistent secure file creation

# PAT-001 FIX: Use canonical _rune_fail_forward instead of _fail_open
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  echo "WARN: ${BASH_SOURCE[0]##*/} crashed at line $_crash_line — fail-forward." >&2
  exit 0
}
trap '_rune_fail_forward' ERR

# PAT-009 FIX: Add _trace() for observability
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] enforce-glyph-budget: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# Guard: jq required
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — glyph budget enforcement skipped." >&2  # PAT-008 FIX
  exit 0
fi

# Read hook input from stdin (max 1MB — PAT-002 FIX: standardized cap)
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Guard 1: Only active during Rune workflows ---
# Check for active rune workflow state files (explicit paths — Concern C3)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
[[ -n "$CWD" && "$CWD" == /* ]] || exit 0

PROJECT_DIR="$CWD"
HAS_RUNE_WORKFLOW=false

# Explicit state file pattern check (Concern C3: [[ -f "$sf" ]] || continue)
shopt -s nullglob
for sf in \
  "$PROJECT_DIR/tmp/.rune-review-"*.json \
  "$PROJECT_DIR/tmp/.rune-work-"*.json \
  "$PROJECT_DIR/tmp/.rune-forge-"*.json \
  "$PROJECT_DIR/tmp/.rune-plan-"*.json \
  "$PROJECT_DIR/tmp/.rune-arc-"*.json \
  "$PROJECT_DIR/tmp/.rune-audit-"*.json \
  "$PROJECT_DIR/tmp/.rune-mend-"*.json \
  "$PROJECT_DIR/tmp/.rune-inspect-"*.json \
  "$PROJECT_DIR/tmp/.rune-goldmask-"*.json \
  "$PROJECT_DIR/tmp/.rune-brainstorm-"*.json \
  "$PROJECT_DIR/tmp/.rune-debug-"*.json \
  "$PROJECT_DIR/tmp/.rune-design-sync-"*.json; do
  [[ -f "$sf" ]] || continue
  HAS_RUNE_WORKFLOW=true
  break
done

shopt -u nullglob
[[ "$HAS_RUNE_WORKFLOW" == "true" ]] || exit 0

# --- Guard 2: Extract message content ---
CONTENT=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
[[ -z "$CONTENT" ]] && exit 0

# --- Step 3: Count words ---
WORD_COUNT=$(echo "$CONTENT" | wc -w | tr -d ' ')

# --- Step 4: Configurable threshold (default 300 words) ---
BUDGET="${RUNE_GLYPH_BUDGET:-300}"
# Reads RUNE_GLYPH_BUDGET env var only (talisman context_weaving.glyph_budget.word_limit not read — hooks are fast-path)

# Validate budget is numeric
[[ "$BUDGET" =~ ^[0-9]+$ ]] || BUDGET=300

# --- Step 5: Check compliance and inject advisory if over budget ---
if [[ "$WORD_COUNT" -gt "$BUDGET" ]]; then
  jq -n \
    --arg ctx "GLYPH-BUDGET-VIOLATION: Teammate message was ${WORD_COUNT} words (budget: ${BUDGET}). The Glyph Budget protocol requires teammates to write verbose output to tmp/ files and send only a file path + 50-word summary via SendMessage. Consider redirecting this teammate to file-based output for future messages." \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}' 2>/dev/null || true
fi

# --- Step 6: Stateful trend tracking (silent backpressure detection) ---
# Track response length trend across the session to detect declining output quality.
# State file is PPID-scoped for session isolation. Uses atomic write (tmp+mv).
# Limit to 20 data points to bound state file size.
TREND_FILE="${TMPDIR:-/tmp}/rune-glyph-trend-${PPID}.json"
TREND_ADVISORY=""

if [[ -f "$TREND_FILE" ]]; then
  # Read existing trend data
  TREND_DATA=$(cat "$TREND_FILE" 2>/dev/null || echo '{"lengths":[]}')
  LENGTHS=$(printf '%s\n' "$TREND_DATA" | jq -r '.lengths // []' 2>/dev/null || echo '[]')
  COUNT=$(printf '%s\n' "$LENGTHS" | jq 'length' 2>/dev/null || echo '0')

  # Compute session average from existing data points
  if [[ "$COUNT" -gt 0 ]]; then
    SESSION_AVG=$(printf '%s\n' "$LENGTHS" | jq 'add / length | floor' 2>/dev/null || echo '0')

    # Warn when current response length falls below 50% of session average
    if [[ "$SESSION_AVG" -gt 0 ]]; then
      HALF_AVG=$(( SESSION_AVG / 2 ))
      if [[ "$WORD_COUNT" -lt "$HALF_AVG" ]]; then
        TREND_ADVISORY="BACKPRESSURE-WARNING: Response length declining — ${WORD_COUNT} words is below 50% of session average (${SESSION_AVG} words). This may indicate context pressure causing truncated or superficial output. "
      fi
    fi
  fi

  # Append current data point (cap at 20)
  UPDATED=$(printf '%s\n' "$TREND_DATA" | jq --argjson wc "$WORD_COUNT" \
    '.lengths = (.lengths + [$wc]) | .lengths = .lengths[-20:]' 2>/dev/null || echo "$TREND_DATA")
else
  # First invocation — initialize baseline
  UPDATED=$(jq -n --argjson wc "$WORD_COUNT" '{"lengths": [$wc]}')
fi

# Atomic write: tmp file + mv (prevents partial reads)
TREND_TMP=$(mktemp "${TMPDIR:-/tmp}/rune-glyph-XXXXXX") || true
if [[ -n "$TREND_TMP" ]]; then
  trap 'rm -f "$TREND_TMP"' EXIT
  printf '%s\n' "$UPDATED" > "$TREND_TMP" 2>/dev/null && mv -f "$TREND_TMP" "$TREND_FILE" 2>/dev/null || true
fi

# --- Step 7: Evidence quality heuristic ---
# Flag evidence fields shorter than 20 characters as potentially superficial.
# Checks for common evidence patterns in structured teammate output.
EVIDENCE_ADVISORY=""
EVIDENCE_FIELDS=$(printf '%s\n' "$CONTENT" | grep -iE '^\s*(evidence|proof|verification|result)\s*:' 2>/dev/null || true)
if [[ -n "$EVIDENCE_FIELDS" ]]; then
  while IFS= read -r line; do
    # Extract the value after the colon
    VALUE="${line#*:}"
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"  # trim leading whitespace
    VALUE_LEN=${#VALUE}
    if [[ "$VALUE_LEN" -gt 0 && "$VALUE_LEN" -lt 20 ]]; then
      EVIDENCE_ADVISORY="EVIDENCE-QUALITY-WARNING: Evidence field appears superficial (${VALUE_LEN} chars, minimum recommended: 20). Short evidence like 'checked' or 'done' does not constitute verifiable proof. "
      break
    fi
  done <<< "$EVIDENCE_FIELDS"
fi

# --- Step 8: Emit combined advisory if any warnings triggered ---
COMBINED_ADVISORY="${TREND_ADVISORY}${EVIDENCE_ADVISORY}"
if [[ -n "$COMBINED_ADVISORY" ]]; then
  jq -n \
    --arg ctx "$COMBINED_ADVISORY" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}' 2>/dev/null || true
fi

exit 0
