#!/bin/bash
# scripts/elicitation-logger.sh
# Elicitation hook logger for echo-search and figma-to-react elicitation prompts.
# Appends elicitation requests to a per-user JSONL log for audit and debugging.
#
# Event: Elicitation
# Matcher: echo-search|figma-to-react
# Behavior: OPERATIONAL — fail-forward, exit 0 always
# Max log size: 5MB (512 * 1024 * 10 bytes) — skips append when exceeded

set -euo pipefail

# Fail-forward: crash allows operation (OPERATIONAL hook, not SECURITY)
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Validate TMPDIR is absolute to prevent symlink attacks
_tmp="${TMPDIR:-/tmp}"
[[ "$_tmp" =~ ^/ ]] || _tmp="/tmp"

# Per-user log file (safe for multi-user systems)
LOG_FILE="${_tmp}/rune-elicitation-log-$(id -u).jsonl"

# Max log size: 5MB
MAX_LOG_BYTES=5242880

# Read hook input from stdin (1MB cap)
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# Extract elicitation source (matcher value) from input if available
SOURCE=""
if command -v jq &>/dev/null; then
  SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // .matcher // empty' 2>/dev/null || true)
fi
# SEC-003: Sanitize SOURCE — strip non-alphanumeric chars (except _ - .)
SOURCE=$(printf '%s' "$SOURCE" | tr -dc '[:alnum:]_.-' | head -c 100)

# Check file size before appending — skip if over cap to prevent unbounded growth
if [[ -f "$LOG_FILE" ]]; then
  FILE_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo "0")
  FILE_SIZE="${FILE_SIZE// /}"  # trim whitespace (wc -c may pad)
  if [[ "$FILE_SIZE" -ge "$MAX_LOG_BYTES" ]]; then
    # Log file too large — skip append (do not rotate in hooks, keep it simple)
    exit 0
  fi
fi

# Build log entry as JSONL (one JSON object per line)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)

if command -v jq &>/dev/null; then
  # Append log entry atomically via temp file + cat
  LOG_ENTRY=$(jq -n \
    --arg ts "$TIMESTAMP" \
    --arg src "$SOURCE" \
    --argjson input "$INPUT" \
    '{
      timestamp: $ts,
      source: $src,
      hookEventName: "Elicitation",
      request: $input
    }' 2>/dev/null || true)
  if [[ -n "$LOG_ENTRY" ]]; then
    printf '%s\n' "$LOG_ENTRY" >> "$LOG_FILE" 2>/dev/null || true
  fi
else
  # Fallback: write minimal JSONL entry without full input parsing
  ESCAPED_SRC=$(printf '%s' "$SOURCE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ESCAPED_TS=$(printf '%s' "$TIMESTAMP" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"timestamp":"%s","source":"%s","hookEventName":"Elicitation"}\n' \
    "$ESCAPED_TS" "$ESCAPED_SRC" >> "$LOG_FILE" 2>/dev/null || true
fi

# Output required hookSpecificOutput with hookEventName
if command -v jq &>/dev/null; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "Elicitation"
    }
  }'
else
  printf '{"hookSpecificOutput":{"hookEventName":"Elicitation"}}\n'
fi

exit 0
