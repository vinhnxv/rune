#!/bin/bash
# scripts/track-tool-failure.sh — PostToolUseFailure hook
# FAIL-001: Escalating retry guidance for repeated tool failures.
# Classification: OPERATIONAL (fail-forward)
# Timeout: 3s
#
# Tracks per-session, per-tool failure counts. Provides escalating
# guidance after repeated failures of the same tool:
#   - Failures 1-2: Silent (let Claude retry naturally)
#   - Failures 3-4: Advisory — "analyze the error, try a different approach"
#   - Failures 5+:  Strong advisory — "STOP RETRYING, try these alternatives"
#
# State file: ${TMPDIR:-/tmp}/rune-tool-failures-{session_id}.json
# Talisman gate: tool_failure_tracking.enabled (default: true)
# Reset: reset-tool-failure.sh (PostToolUse success companion)
# Exit code: 0 always (advisory, never blocks)

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# --- Guard: jq dependency (fail-open without jq) ---
command -v jq >/dev/null 2>&1 || exit 0

# --- Cross-platform stat helpers ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh"

# --- Guard: Input size cap (SEC-2: 1MB DoS protection) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Extract fields from PostToolUseFailure hook input ---
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

[[ -z "$TOOL_NAME" || -z "$SESSION_ID" ]] && exit 0

# --- Talisman gate (project → system fallback; symlink-safe via helper) ---
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
# shellcheck source=lib/talisman-shard-path.sh
source "${SCRIPT_DIR}/lib/talisman-shard-path.sh" 2>/dev/null || true
if type _rune_resolve_talisman_shard &>/dev/null; then
  TALISMAN_SHARD=$(_rune_resolve_talisman_shard "tool_failure_tracking" "${CWD:-}")
else
  # WORKTREE-FIX: Prefer CWD (worktree) over CLAUDE_PROJECT_DIR (may point to main repo per #27343)
  TALISMAN_SHARD="${CWD:-${CLAUDE_PROJECT_DIR:-.}}/tmp/.talisman-resolved/tool_failure_tracking.json"
fi
SILENT_THRESHOLD=2
ESCALATION_THRESHOLD=5
STALENESS_MIN=30
# FLAW-009 FIX: Add symlink rejection to match other scripts
if [[ -f "$TALISMAN_SHARD" ]] && [[ ! -L "$TALISMAN_SHARD" ]]; then
  ENABLED=$(jq -r 'if .enabled == null then true else .enabled end' "$TALISMAN_SHARD" 2>/dev/null || echo "true")
  [[ "$ENABLED" == "false" ]] && exit 0
  # QUAL-002 FIX: Flat key access — shard file is the dedicated tool_failure_tracking object
  SILENT_THRESHOLD=$(jq -r '.silent_threshold // 2' "$TALISMAN_SHARD" 2>/dev/null || echo "2")
  ESCALATION_THRESHOLD=$(jq -r '.escalation_threshold // 5' "$TALISMAN_SHARD" 2>/dev/null || echo "5")
  STALENESS_MIN=$(jq -r '.staleness_minutes // 30' "$TALISMAN_SHARD" 2>/dev/null || echo "30")
fi

# --- SEC-4: Session ID validation (prevent path injection) ---
SAFE_SESSION=$(printf '%s' "$SESSION_ID" | sed 's/[^a-zA-Z0-9_-]//g')
[[ -z "$SAFE_SESSION" ]] && exit 0

# --- State file (per-session failure tracking) ---
FAILURE_FILE="${TMPDIR:-/tmp}/rune-tool-failures-${SAFE_SESSION}.json"

# --- Read existing failure count for this tool ---
COUNT=0
NOW=$(date +%s)
if [[ -f "$FAILURE_FILE" ]]; then
  # Staleness check — ignore failure records older than STALENESS_MIN minutes
  FILE_MTIME=$(_stat_mtime "$FAILURE_FILE"); FILE_MTIME="${FILE_MTIME:-$NOW}"
  FILE_AGE=$(( NOW - FILE_MTIME ))
  if (( FILE_AGE > STALENESS_MIN * 60 )); then
    rm -f "$FAILURE_FILE" 2>/dev/null || true
  else
    COUNT=$(jq -r --arg t "$TOOL_NAME" '.[$t].count // 0' "$FAILURE_FILE" 2>/dev/null || echo "0")
  fi
fi

# --- Increment counter ---
COUNT=$(( COUNT + 1 ))

# --- Write updated state (atomic: tmp file + mv) ---
if [[ -f "$FAILURE_FILE" ]]; then
  _tmp_fail=$(mktemp "${FAILURE_FILE}.XXXXXX" 2>/dev/null) || { exit 0; }  # SEC-001 fix: no predictable fallback
  jq --arg t "$TOOL_NAME" --argjson c "$COUNT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$t] = { count: $c, last_error_at: $ts }' "$FAILURE_FILE" > "$_tmp_fail" 2>/dev/null \
    && mv "$_tmp_fail" "$FAILURE_FILE" 2>/dev/null || { rm -f "$_tmp_fail" 2>/dev/null; true; }
else
  jq -n --arg t "$TOOL_NAME" --argjson c "$COUNT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ ($t): { count: $c, last_error_at: $ts } }' > "$FAILURE_FILE" 2>/dev/null || true
fi

# --- Escalation logic ---
if (( COUNT > ESCALATION_THRESHOLD )); then
  ADVICE="[FAIL-001] STOP RETRYING. The \"${TOOL_NAME}\" operation has failed ${COUNT} times in this session. Instead: (1) Try a completely different command or approach, (2) Check if the environment/dependencies are correct, (3) Break down the task differently, (4) Ask the user for guidance. Retrying the same failing command wastes tokens."
elif (( COUNT > SILENT_THRESHOLD )); then
  ADVICE="[FAIL-001] The \"${TOOL_NAME}\" operation has failed ${COUNT} times. Analyze the error and try a different approach before retrying."
else
  # Silent — let Claude retry naturally
  printf '{"continue":true,"suppressOutput":true}\n'
  exit 0
fi

jq -n --arg ctx "$ADVICE" '{
  hookSpecificOutput: { hookEventName: "PostToolUseFailure", additionalContext: $ctx }
}'
exit 0
