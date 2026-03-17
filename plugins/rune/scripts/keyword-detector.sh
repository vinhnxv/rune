#!/bin/bash
# scripts/keyword-detector.sh — UserPromptSubmit hook
# KEYWORD-001: Advisory workflow suggestion based on prompt keywords.
# Classification: OPERATIONAL (fail-forward)
# Timeout: 3s (fires on EVERY user prompt — must be fast)
#
# Intercepts user prompts via UserPromptSubmit to suggest Rune workflows
# based on magic keywords. ADVISORY ONLY — never blocks the prompt.
# Returns additionalContext suggesting the matching workflow.
#
# Talisman gate: keyword_detection.enabled (default: true)
# Exit code: 0 always (advisory hook)

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

# --- Guard: Talisman gate (project → system fallback; symlink-safe via helper) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/talisman-shard-path.sh
source "${SCRIPT_DIR}/lib/talisman-shard-path.sh" 2>/dev/null || true
if type _rune_resolve_talisman_shard &>/dev/null; then
  TALISMAN_SHARD=$(_rune_resolve_talisman_shard "keyword_detection" "${CWD:-}")
else
  # WORKTREE-FIX: Prefer CWD (worktree) over CLAUDE_PROJECT_DIR (may point to main repo per #27343)
  TALISMAN_SHARD="${CWD:-${CLAUDE_PROJECT_DIR:-.}}/tmp/.talisman-resolved/keyword_detection.json"
fi
if [[ -f "$TALISMAN_SHARD" ]]; then
  ENABLED=$(jq -r '.enabled // true' "$TALISMAN_SHARD" 2>/dev/null || echo "true")
  [[ "$ENABLED" == "false" ]] && exit 0
fi

# --- Guard: Input size cap (SEC-2: 1MB DoS protection) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Extract prompt from hook input ---
# UserPromptSubmit input format: { "prompt": "...", "session_id": "..." }
PROMPT=$(printf '%s\n' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
[[ -z "$PROMPT" ]] && exit 0

# --- Guard: Skip short prompts (< 3 chars → not a keyword) ---
[[ ${#PROMPT} -lt 3 ]] && exit 0

# --- Guard: Skip if prompt starts with / (already a skill invocation) ---
[[ "$PROMPT" == /* ]] && exit 0

# --- Sanitize: strip code blocks, URLs, file paths, XML tags ---
# Uses sed -E (not -r) for macOS + Linux compatibility
CLEAN=$(printf '%s\n' "$PROMPT" | sed -E \
  -e 's/```[^`]*```//g' \
  -e 's/`[^`]+`//g' \
  -e 's|https?://[^ )*>\]]+||g' \
  -e 's/<[^>]*>//g' \
  -e 's|/?([a-zA-Z0-9._-]+/)+[a-zA-Z0-9._-]+||g')

# Lowercase via tr — Bash 3.2 compatible (no ${var,,})
LOWER=$(printf '%s\n' "$CLEAN" | tr '[:upper:]' '[:lower:]')

# --- Guard: Skip if cleaned prompt is empty ---
[[ -z "${LOWER// /}" ]] && exit 0

# --- Keyword matching (first match wins, priority order) ---
SUGGESTION=""
case "$LOWER" in
  cancelrune*|stoprune*)
    SUGGESTION="[KEYWORD-001] Detected cancel request. Use /rune:cancel-arc, /rune:cancel-review, or /rune:cancel-audit to stop the active workflow." ;;
  review*|"check my code"*|"check this pr"*|"code review"*|"kiểm tra code"*)
    SUGGESTION="[KEYWORD-001] This looks like a code review request. Consider: /rune:appraise (or /rune:review) for multi-agent review of your changes." ;;
  plan*|"design this"*|"how should we"*|"lập kế hoạch"*)
    SUGGESTION="[KEYWORD-001] This looks like a planning request. Consider: /rune:devise (or /rune:plan) for multi-agent planning." ;;
  audit*|"security scan"*|"full review"*|"full codebase"*)
    SUGGESTION="[KEYWORD-001] This looks like a full audit. Consider: /rune:audit for comprehensive codebase analysis." ;;
  brainstorm*|"explore idea"*|"explore "*|"thảo luận"*)
    SUGGESTION="[KEYWORD-001] This looks like brainstorming. Consider: /rune:brainstorm for structured ideation." ;;
  implement*|"build it"*|"execute the plan"*|"ship it"*)
    SUGGESTION="[KEYWORD-001] This looks like implementation. Consider: /rune:strive (or /rune:work) with a plan file." ;;
  debug*|"fix this bug"*|"root cause"*)
    SUGGESTION="[KEYWORD-001] This looks like debugging. Consider: /rune:debug for ACH-based parallel investigation." ;;
  impact*|"blast radius"*|"what changed"*|"what breaks"*)
    SUGGESTION="[KEYWORD-001] This looks like impact analysis. Consider: /rune:goldmask for cross-layer analysis." ;;
  "run everything"*|"end to end"*|"run arc"*)
    SUGGESTION="[KEYWORD-001] This looks like full pipeline execution. Consider: /rune:arc with a plan file." ;;
esac

# --- Output ---
if [[ -n "$SUGGESTION" ]]; then
  jq -n --arg ctx "$SUGGESTION" '{
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $ctx }
  }'
else
  # No match — suppress output, don't add noise
  printf '{"continue":true,"suppressOutput":true}\n'
fi
exit 0
