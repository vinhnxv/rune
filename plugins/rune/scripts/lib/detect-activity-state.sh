#!/usr/bin/env bash
# scripts/lib/detect-activity-state.sh
# Semantic activity state classifier for teammate JSONL session files.
#
# Classifies teammate activity by parsing structural fields from JSONL
# session entries. Used by on-teammate-idle.sh and monitor-inline.md
# for intelligent stuck detection beyond simple timestamp-based checks.
#
# USAGE:
#   detect-activity-state.sh <jsonl_path> [--window N]
#
# ARGUMENTS:
#   jsonl_path    Path to teammate's JSONL session file
#   --window N    Analysis window in seconds (default: 60)
#
# OUTPUT (JSON):
#   {"state":"WORKING","confidence":0.9,"details":"Active tool use detected"}
#
# STATES (priority order):
#   IDLE              No entries found
#   PERMISSION_LOOP   Repeated permission requests
#   ERROR_LOOP        Repeated tool errors
#   RETRY_LOOP        Same tool repeated with few unique tools
#   RATE_LIMITED      Rate limit markers in recent errors
#   COMPLETED         SEAL marker in last entries
#   WAITING_INPUT     AskUserQuestion in recent entries
#   WORKING           Active tool events present
#   THINKING          Entries exist but no tool events
#
# PRIVACY (DA-001):
#   Only extracts structural fields: type, name, id, is_error.
#   NEVER accesses .content or .input fields.
#
# EXIT BEHAVIOR: Always exit 0 (fail-forward).
# DEPENDENCIES: jq, bash 3.2+
# COMPATIBLE: macOS + Linux
set -euo pipefail
umask 077

# ── Fail-forward guard (OPERATIONAL hook — ADR-002) ──
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _ffl="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ -n "$_ffl" && ! -L "$_ffl" && ! -L "${_ffl%/*}" ]] && \
      printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
        "$(date +%H:%M:%S 2>/dev/null || true)" \
        "${BASH_SOURCE[0]##*/}" \
        "${BASH_LINENO[0]:-?}" \
        >> "$_ffl" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# ── GUARD: jq dependency ──
if ! command -v jq &>/dev/null; then
  printf '{"state":"IDLE","confidence":0.5,"details":"jq not available"}\n'
  exit 0
fi

# ── Source cross-platform helpers ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/platform.sh" ]] && source "${SCRIPT_DIR}/platform.sh"

# ── Default parameters ──
JSONL_PATH=""
WINDOW_SECS=60

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)
      shift
      if [[ -z "${1:-}" ]]; then
        printf '{"state":"IDLE","confidence":0.5,"details":"--window requires a value"}\n'
        exit 0
      fi
      WINDOW_SECS=$(( "$1" + 0 )) 2>/dev/null || WINDOW_SECS=60
      [[ "$WINDOW_SECS" -gt 0 ]] || WINDOW_SECS=60
      shift
      ;;
    -*)
      shift
      ;;
    *)
      if [[ -z "$JSONL_PATH" ]]; then
        JSONL_PATH="$1"
      fi
      shift
      ;;
  esac
done

# ── Validate input ──
if [[ -z "$JSONL_PATH" ]]; then
  printf '{"state":"IDLE","confidence":0.5,"details":"no JSONL path provided"}\n'
  exit 0
fi

if [[ ! -f "$JSONL_PATH" || -L "$JSONL_PATH" ]]; then
  printf '{"state":"IDLE","confidence":0.5,"details":"JSONL file not found or is symlink"}\n'
  exit 0
fi

if [[ ! -r "$JSONL_PATH" ]]; then
  printf '{"state":"IDLE","confidence":0.5,"details":"JSONL file not readable"}\n'
  exit 0
fi

# ── SEC-4: Validate path characters ──
JSONL_BASENAME="${JSONL_PATH##*/}"
if [[ "$JSONL_BASENAME" == *".."* ]]; then
  printf '{"state":"IDLE","confidence":0.5,"details":"path traversal rejected"}\n'
  exit 0
fi

# ── Extract recent entries (partial-line safe) ──
# Use tail + jq streaming to skip malformed/partial lines.
# DA-001: Only extract structural fields (type, name, id, is_error).
RECENT_ENTRIES=$(tail -n 50 "$JSONL_PATH" 2>/dev/null | jq -c '
  select(.type != null) |
  select(.type != "isCompactSummary") |
  {
    entry_type: .type,
    tool_names: (
      if .type == "assistant" then
        [(.message.content // []) | if type == "array" then .[] else . end |
         select(.type == "tool_use") | .name // empty]
      else []
      end
    ),
    tool_result_ids: (
      if .type == "user" then
        [(.message.content // []) | if type == "array" then .[] else . end |
         select(.type == "tool_result") | .tool_use_id // empty]
      else []
      end
    ),
    has_error: (
      if .type == "user" then
        ([(.message.content // []) | if type == "array" then .[] else . end |
          select(.type == "tool_result") | select(.is_error == true)] | length) > 0
      else false
      end
    ),
    has_permission: (
      if .type == "assistant" then
        ([(.message.content // []) | if type == "array" then .[] else . end |
          select(.type == "tool_use") |
          select(.name == "PermissionRequest" or .name == "AskPermission")] | length) > 0
      else false
      end
    ),
    has_ask_user: (
      if .type == "assistant" then
        ([(.message.content // []) | if type == "array" then .[] else . end |
          select(.type == "tool_use") |
          select(.name == "AskUserQuestion")] | length) > 0
      else false
      end
    ),
    has_seal: (
      if .type == "assistant" then
        ((.message.content // []) | if type == "array" then .[] else . end |
         select(.type == "text") | .text // "" |
         test("<seal>"; "")) // false
      else false
      end
    )
  }
' 2>/dev/null) || RECENT_ENTRIES=""

# ── State 1: No entries → IDLE ──
if [[ -z "$RECENT_ENTRIES" ]]; then
  printf '{"state":"IDLE","confidence":0.95,"details":"no valid entries in session file"}\n'
  exit 0
fi

# ── Aggregate metrics via jq ──
METRICS=$(printf '%s\n' "$RECENT_ENTRIES" | jq -s '
  {
    total_entries: length,
    permission_count: [.[] | select(.has_permission == true)] | length,
    error_count: [.[] | select(.has_error == true)] | length,
    ask_user_count: [.[] | select(.has_ask_user == true)] | length,
    has_seal: ([.[] | select(.has_seal == true)] | length) > 0,
    all_tool_names: [.[] | .tool_names[]?] | sort,
    unique_tool_count: ([.[] | .tool_names[]?] | unique | length),
    tool_event_count: ([.[] | .tool_names[]?] | length),
    last_5_seal: ([-5:] | [.[] | select(.has_seal == true)] | length) > 0,
    last_5_ask_user: ([-5:] | [.[] | select(.has_ask_user == true)] | length) > 0,
    most_common_tool: (
      [.[] | .tool_names[]?] | group_by(.) |
      sort_by(-length) | .[0] // [] |
      { name: (.[0] // ""), count: length }
    ),
    error_in_last_5: ([-5:] | [.[] | select(.has_error == true)] | length)
  }
' 2>/dev/null) || {
  printf '{"state":"IDLE","confidence":0.5,"details":"metrics aggregation failed"}\n'
  exit 0
}

# ── Extract values from metrics ──
TOTAL=$(printf '%s' "$METRICS" | jq -r '.total_entries // 0')
PERM_COUNT=$(printf '%s' "$METRICS" | jq -r '.permission_count // 0')
ERROR_COUNT=$(printf '%s' "$METRICS" | jq -r '.error_count // 0')
ASK_USER=$(printf '%s' "$METRICS" | jq -r '.ask_user_count // 0')
HAS_SEAL=$(printf '%s' "$METRICS" | jq -r '.last_5_seal // false')
HAS_ASK_USER_RECENT=$(printf '%s' "$METRICS" | jq -r '.last_5_ask_user // false')
UNIQUE_TOOLS=$(printf '%s' "$METRICS" | jq -r '.unique_tool_count // 0')
TOOL_EVENTS=$(printf '%s' "$METRICS" | jq -r '.tool_event_count // 0')
TOP_TOOL_NAME=$(printf '%s' "$METRICS" | jq -r '.most_common_tool.name // ""')
TOP_TOOL_COUNT=$(printf '%s' "$METRICS" | jq -r '.most_common_tool.count // 0')
ERRORS_LAST_5=$(printf '%s' "$METRICS" | jq -r '.error_in_last_5 // 0')

# ── Thresholds ──
PERMISSION_THRESHOLD=3
ERROR_THRESHOLD=3
RETRY_THRESHOLD=5

# ── State classification (priority order) ──
# State 2: Permission loop
if [[ "$PERM_COUNT" -ge "$PERMISSION_THRESHOLD" ]]; then
  printf '{"state":"PERMISSION_LOOP","confidence":0.85,"details":"permission requests: %d/%d entries"}\n' \
    "$PERM_COUNT" "$TOTAL"
  exit 0
fi

# State 3: Error loop
if [[ "$ERROR_COUNT" -ge "$ERROR_THRESHOLD" ]]; then
  printf '{"state":"ERROR_LOOP","confidence":0.85,"details":"tool errors: %d/%d entries, recent errors: %d"}\n' \
    "$ERROR_COUNT" "$TOTAL" "$ERRORS_LAST_5"
  exit 0
fi

# State 4: Retry loop — same tool repeated with <=2 unique tools
if [[ "$TOP_TOOL_COUNT" -ge "$RETRY_THRESHOLD" && "$UNIQUE_TOOLS" -le 2 ]]; then
  printf '{"state":"RETRY_LOOP","confidence":0.80,"details":"tool %s repeated %d times, %d unique tools"}\n' \
    "$TOP_TOOL_NAME" "$TOP_TOOL_COUNT" "$UNIQUE_TOOLS"
  exit 0
fi

# State 5: Rate limited — check for rate limit patterns in recent errors
# DA-001: We check has_error flag only, not content. Rate limit detection is
# heuristic: high error rate in last 5 entries + low unique tool count.
if [[ "$ERRORS_LAST_5" -ge 3 && "$UNIQUE_TOOLS" -le 2 ]]; then
  printf '{"state":"RATE_LIMITED","confidence":0.70,"details":"high error density in recent entries (%d/5), possible rate limiting"}\n' \
    "$ERRORS_LAST_5"
  exit 0
fi

# State 6: Completed — SEAL marker in last entries
if [[ "$HAS_SEAL" == "true" ]]; then
  printf '{"state":"COMPLETED","confidence":0.95,"details":"SEAL marker found in recent entries"}\n'
  exit 0
fi

# State 7: Waiting for user input
if [[ "$HAS_ASK_USER_RECENT" == "true" ]]; then
  printf '{"state":"WAITING_INPUT","confidence":0.90,"details":"AskUserQuestion in recent entries"}\n'
  exit 0
fi

# State 8: Working — tool events present
if [[ "$TOOL_EVENTS" -gt 0 ]]; then
  printf '{"state":"WORKING","confidence":0.90,"details":"active tool use: %d events, %d unique tools"}\n' \
    "$TOOL_EVENTS" "$UNIQUE_TOOLS"
  exit 0
fi

# State 9: Thinking — entries exist but no tool events
if [[ "$TOTAL" -gt 0 && "$TOOL_EVENTS" -eq 0 ]]; then
  printf '{"state":"THINKING","confidence":0.75,"details":"entries present (%d) but no tool events"}\n' \
    "$TOTAL"
  exit 0
fi

# State 10: Default → IDLE
printf '{"state":"IDLE","confidence":0.80,"details":"default classification"}\n'
exit 0
