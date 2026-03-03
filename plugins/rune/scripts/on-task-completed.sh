#!/bin/bash
# scripts/on-task-completed.sh
# Writes signal files for Rune task completion detection.
# Called by Claude Code's TaskCompleted hook for EVERY task completion —
# including non-Rune tasks (TodoWrite, etc.). Must be fast and safe to no-op.

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
# VEIL-002: Always warn on stderr (signal file loss causes 30-60 min orchestrator stalls).
# Also write a .crash-detected marker so the orchestrator can distinguish "hook crashed"
# from "hook never ran" — prevents silent polling until maxIterations.
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-?}"
  # Always emit warning — signal file loss is operationally significant
  printf 'WARN: on-task-completed.sh ERR trap at line %s — signal file may not have been written\n' \
    "$_crash_line" >&2
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  # Best-effort crash marker — if SIGNAL_DIR and TASK_ID are set, write a marker
  # the orchestrator can check to detect "hook ran but crashed before signal write"
  if [[ -n "${SIGNAL_DIR:-}" && -d "${SIGNAL_DIR:-}" && -n "${TASK_ID:-}" ]]; then
    # SEC-003 FIX: Sanitize TASK_ID for JSON — fail-forward runs before input validation
    _safe_tid=$(printf '%s' "${TASK_ID}" | tr -cd 'a-zA-Z0-9_-')
    printf '{"task_id":"%s","crash_line":%s,"timestamp":"%s"}\n' \
      "$_safe_tid" "$_crash_line" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
      > "${SIGNAL_DIR}/${TASK_ID}.crash-detected" 2>/dev/null || true
  fi
  _ERR_ACTIVE=1  # QUAL-002 FIX: Signal EXIT trap to skip cleanup
  exit 0
}
trap '_rune_fail_forward' ERR

# RUNE_TRACE: opt-in trace logging (off by default, zero overhead in production)
# NOTE(QUAL-007): _trace() is intentionally duplicated in on-teammate-idle.sh — each script
# must be self-contained for hook execution. Sharing via source would add a dependency.
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] on-task-completed: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# Cleanup trap — remove temp files on exit (BACK-002)
# QUAL-002 FIX: Guard against ERR→EXIT trap interaction. When _rune_fail_forward fires,
# skip cleanup to avoid operating on inconsistent SIGNAL_DIR state.
_ERR_ACTIVE=0
cleanup() { [[ "$_ERR_ACTIVE" -eq 1 ]] && return; [[ -z "${SIGNAL_DIR:-}" ]] && return; rm -f "${SIGNAL_DIR}/${TASK_ID:-unknown}.done.tmp.$$" "${SIGNAL_DIR}/.all-done.tmp.$$" 2>/dev/null; }
trap cleanup EXIT

# Pre-flight: jq is required for safe JSON parsing and construction.
# If missing, exit 0 (non-blocking) with a warning on stderr.
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — signal files will not be written. Install jq for Phase 2 event-driven sync." >&2
  exit 0
fi

# Read hook input from stdin
INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read
_trace "ENTER"

# BACK-101: Validate JSON before attempting field extraction
if ! printf '%s\n' "$INPUT" | jq empty 2>/dev/null; then
  echo "WARN: Hook input is not valid JSON — signal file will not be written" >&2
  exit 0
fi

# Extract fields with safe defaults via single jq call (BACK-204)
# Uses tab-separated output to avoid eval — each field is read into its own variable.
IFS=$'\t' read -r TEAM_NAME TASK_ID TEAMMATE_NAME TASK_SUBJECT <<< "$(printf '%s\n' "$INPUT" | jq -r '[.team_name // "", .task_id // "", .teammate_name // "", .task_subject // ""] | @tsv' 2>/dev/null)" || true
# SEC-C05: Truncate subject to prevent oversized values in signal files
TASK_SUBJECT="${TASK_SUBJECT:0:256}"
# BACK-012: Default empty subject
[[ -z "$TASK_SUBJECT" ]] && TASK_SUBJECT="Task $TASK_ID"

# Guard: skip non-team tasks (TodoWrite, etc. have no team_name)
_trace "PARSED team=$TEAM_NAME task=$TASK_ID teammate=$TEAMMATE_NAME"
if [[ -z "$TEAM_NAME" || -z "$TASK_ID" ]]; then
  _trace "SKIP empty team_name or task_id"
  exit 0
fi

# Guard: only process Rune teams (rune-review-*, rune-work-*, rune-plan-*, arc-*, etc.)
if [[ "$TEAM_NAME" != rune-* && "$TEAM_NAME" != arc-* ]]; then
  exit 0
fi

# QUAL-002: Validation order is intentional — emptiness checks first (cheap bail-out),
# then prefix match, then character-set and length validation.
# Guard: validate team name against safe characters (prevent path traversal)
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# Guard: validate team name length
if [[ ${#TEAM_NAME} -gt 128 ]]; then
  exit 0
fi

# Guard: validate task ID against safe characters
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# Derive absolute path from hook input CWD (not relative — CWD is not guaranteed)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
# BACK-009: Add warning when CWD is missing
if [[ -z "$CWD" ]]; then
  echo "WARN: TaskCompleted hook input missing 'cwd' field" >&2
  exit 0
fi

# SEC-002: Canonicalize CWD after extraction
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { echo "WARN: Cannot canonicalize CWD: $CWD" >&2; exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then
  exit 0
fi

# Signal directory — created by orchestrator before spawning agents
SIGNAL_DIR="${CWD}/tmp/.rune-signals/${TEAM_NAME}"

# Guard: if signal dir doesn't exist, orchestrator didn't set up signals
# (e.g., Phase 1 monitor utility without Phase 2 hooks). Exit silently.
if [[ ! -d "$SIGNAL_DIR" ]]; then
  _trace "SKIP signal_dir missing: $SIGNAL_DIR"
  exit 0
fi

# Write signal file — atomic via temp + mv, safe JSON via jq
SIGNAL_FILE="${SIGNAL_DIR}/${TASK_ID}.done"
TEMP_FILE="${SIGNAL_FILE}.tmp.$$"

# SEC-001: Extract date command to shell variable before passing to jq
COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# BACK-002: Wrap jq+mv in error handler
if ! jq -n --arg tid "$TASK_ID" --arg tn "$TEAMMATE_NAME" --arg ts "$TASK_SUBJECT" \
  --arg ca "$COMPLETED_AT" \
  '{task_id: $tid, teammate: $tn, subject: $ts, completed_at: $ca}' > "$TEMP_FILE" 2>/dev/null; then
  echo "ERROR: Failed to write signal file for task ${TASK_ID}" >&2
  rm -f "$TEMP_FILE" 2>/dev/null
  exit 0
fi

# SEC-003: Use mv -n (noclobber)
mv -n "$TEMP_FILE" "$SIGNAL_FILE" 2>/dev/null || { rm -f "$TEMP_FILE"; exit 0; }
_trace "WRITING signal file: $SIGNAL_FILE"

# Clean up file lock signal (F7: use TEAMMATE_NAME, not WORKER_NAME)
# File lock signals are written by workers to claim file ownership during execution.
# Once a task completes, the lock signal is no longer needed.
if [[ -n "${TEAMMATE_NAME:-}" ]]; then
  worker_signal="${SIGNAL_DIR}/${TEAMMATE_NAME}-files.json"
  [ -f "$worker_signal" ] && rm -f "$worker_signal"
  _trace "CLEANUP file lock signal: $worker_signal"
fi

# Check if all expected tasks are complete
EXPECTED_FILE="${SIGNAL_DIR}/.expected"
if [[ ! -f "$EXPECTED_FILE" ]]; then
  exit 0
fi

# BACK-005: Strengthen .expected validation
# SEC-004: .expected is write-once by the orchestrator before agents spawn — no real TOCTOU risk.
EXPECTED=$(head -c 4 "$EXPECTED_FILE" 2>/dev/null | tr -d '[:space:]')
if [[ ! "$EXPECTED" =~ ^[1-9][0-9]*$ ]]; then
  echo "WARN: .expected file contains invalid count: ${EXPECTED}" >&2
  exit 0
fi

# Count .done files (excluding .tmp files)
DONE_COUNT=$(find "$SIGNAL_DIR" -maxdepth 1 -type f -name "*.done" -not -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')

# BACK-001: Add existence check before writing .all-done to prevent double-write race.
# Note: total is a lower bound — concurrent completions may increment .done count between
# our find and the jq write (TOCTOU), but mv -n prevents double-write so this is benign.
_trace "DONE_COUNT=$DONE_COUNT EXPECTED=$EXPECTED"
if [[ "$DONE_COUNT" -ge "$EXPECTED" ]] && [[ ! -f "${SIGNAL_DIR}/.all-done" ]]; then
  ALL_DONE_TEMP="${SIGNAL_DIR}/.all-done.tmp.$$"

  # SEC-001: Extract date command to shell variable (same as above)
  COMPLETED_AT_ALL=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # BACK-002: Wrap jq+mv in error handler (mirrors lines 88-94)
  if ! jq -n --argjson total "$DONE_COUNT" --argjson expected "$EXPECTED" \
    --arg ca "$COMPLETED_AT_ALL" \
    '{total: $total, expected: $expected, completed_at: $ca}' > "$ALL_DONE_TEMP" 2>/dev/null; then
    rm -f "$ALL_DONE_TEMP" 2>/dev/null
    exit 0
  fi

  # SEC-003: Use mv -n (noclobber)
  mv -n "$ALL_DONE_TEMP" "${SIGNAL_DIR}/.all-done" 2>/dev/null || rm -f "$ALL_DONE_TEMP"
  _trace "WRITING all-done sentinel: ${SIGNAL_DIR}/.all-done"
fi

exit 0
