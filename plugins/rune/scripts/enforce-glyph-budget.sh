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
  "$PROJECT_DIR/tmp/.rune-resolve-todos-"*.json \
  "$PROJECT_DIR/tmp/.rune-design-sync-"*.json; do
  [[ -f "$sf" ]] || continue
  HAS_RUNE_WORKFLOW=true
  break
done

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

exit 0
