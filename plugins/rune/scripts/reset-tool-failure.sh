#!/bin/bash
# scripts/reset-tool-failure.sh — PostToolUse success reset
# FAIL-001 RESET: Clears failure counter when a tool succeeds.
# Classification: OPERATIONAL (fail-forward)
# Timeout: 2s
#
# Companion to track-tool-failure.sh. On successful PostToolUse,
# removes the failure entry for that tool name from the session state file.
# This prevents stale failure counts from triggering escalation guidance
# on unrelated future failures of the same tool.
#
# State file: ${TMPDIR:-/tmp}/rune-tool-failures-{session_id}.json
# Exit code: 0 always (non-blocking, best-effort reset)

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
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

# --- Guard: jq dependency (fail-open without jq) ---
command -v jq >/dev/null 2>&1 || exit 0

# --- Guard: Input size cap (SEC-2: 1MB DoS protection) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Extract fields from PostToolUse hook input ---
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

[[ -z "$TOOL_NAME" || -z "$SESSION_ID" ]] && exit 0

# --- SEC-4: Session ID validation (prevent path injection) ---
SAFE_SESSION=$(printf '%s' "$SESSION_ID" | sed 's/[^a-zA-Z0-9_-]//g')
[[ -z "$SAFE_SESSION" ]] && exit 0

# --- State file ---
FAILURE_FILE="${TMPDIR:-/tmp}/rune-tool-failures-${SAFE_SESSION}.json"

# Nothing to reset if state file doesn't exist
[[ -f "$FAILURE_FILE" ]] || exit 0

# --- Remove failure entry for this tool (atomic: tmp file + mv) ---
_tmp_reset=$(mktemp "${FAILURE_FILE}.XXXXXX" 2>/dev/null || echo "${FAILURE_FILE}.tmp.$$")
jq --arg t "$TOOL_NAME" 'del(.[$t])' "$FAILURE_FILE" > "$_tmp_reset" 2>/dev/null \
  && mv "$_tmp_reset" "$FAILURE_FILE" 2>/dev/null || { rm -f "$_tmp_reset" 2>/dev/null; true; }

exit 0
