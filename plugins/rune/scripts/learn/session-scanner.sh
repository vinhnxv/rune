#!/bin/bash
# scripts/learn/session-scanner.sh
# Scans Claude Code session JSONL files and extracts tool_use + tool_result
# event pairs for session self-learning.
#
# USAGE:
#   session-scanner.sh [--since DAYS] [--project PATH] [--format json|text]
#
# Options:
#   --since DAYS      Scan files modified within last DAYS days (default: 7)
#   --project PATH    Project directory to scan (default: current directory)
#   --format FORMAT   Output format: json or text (default: json)
#
# Output (JSON format):
#   Array of objects: {tool_name, input_preview, result_preview, is_error, soft_error, tool_use_id, file}
#
# Privacy:
#   - Default: current project only (DA-001 privacy boundary)
#   - Current session excluded (mtime < 60s ago) — DA-001
#   - isCompactSummary events skipped — DA-003
#   - Content truncated to 500 chars — DA-001
#   - No symlink following (find -P) — DA-004
#
# Requirements: jq, bash 3.2+
# Compatible: macOS + Linux

set -euo pipefail
umask 077  # Secure temp file creation

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] %s: %s\n' "$(date +%H:%M:%S)" "${BASH_SOURCE[0]##*/}" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# ── Fail-forward trap (OPERATIONAL hook pattern) ──
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

# ── Source cross-platform stat helpers ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "${SCRIPT_DIR}/../lib" && pwd)/platform.sh"

# ── Guard: jq required ──
if ! command -v jq &>/dev/null; then
  printf '{"error":"jq not found","events":[]}\n'
  exit 0
fi

# ── Default parameters ──
SINCE_DAYS=7
PROJECT_PATH=""
OUTPUT_FORMAT="json"

# ── Named flag parsing ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      shift
      [[ -z "${1:-}" ]] && { printf '{"error":"--since requires a value","events":[]}\n'; exit 0; }
      SINCE_DAYS=$(( "$1" + 0 )) 2>/dev/null || { printf '{"error":"--since must be a number","events":[]}\n'; exit 0; }
      [[ "$SINCE_DAYS" -gt 0 ]] || { printf '{"error":"--since must be > 0","events":[]}\n'; exit 0; }
      shift
      ;;
    --project)
      shift
      [[ -z "${1:-}" ]] && { printf '{"error":"--project requires a value","events":[]}\n'; exit 0; }
      PROJECT_PATH="$1"
      shift
      ;;
    --format)
      shift
      [[ -z "${1:-}" ]] && { printf '{"error":"--format requires a value","events":[]}\n'; exit 0; }
      case "$1" in
        json|text) OUTPUT_FORMAT="$1" ;;
        *) printf '{"error":"--format must be json or text","events":[]}\n'; exit 0 ;;
      esac
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ── Resolve project directory ──
if [[ -z "$PROJECT_PATH" ]]; then
  PROJECT_PATH="$(pwd -P)"
fi

# Canonicalize and validate
PROJECT_PATH=$(cd "$PROJECT_PATH" 2>/dev/null && pwd -P) || {
  printf '{"error":"project path not accessible","events":[]}\n'
  exit 0
}
[[ -n "$PROJECT_PATH" && "$PROJECT_PATH" == /* ]] || {
  printf '{"error":"project path not absolute","events":[]}\n'
  exit 0
}
[[ -d "$PROJECT_PATH" ]] || {
  printf '{"error":"project path is not a directory","events":[]}\n'
  exit 0
}

# DA-004: Reject symlinked project directories
[[ -L "$PROJECT_PATH" ]] && {
  printf '{"error":"project path is a symlink","events":[]}\n'
  exit 0
}

# ── Locate Claude Code session files ──
# Sessions live in ~/.claude/projects/{encoded-path}/*.jsonl
# Encoded path: CWD with / replaced by -
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Derive encoded project path (replace / with -, strip leading -)
ENCODED_PATH="${PROJECT_PATH//\//-}"
ENCODED_PATH="${ENCODED_PATH#-}"

# SEC-004: reject encoded paths that could enable traversal (should not occur after pwd -P, defensive)
[[ "$ENCODED_PATH" == *".."* ]] && {
  printf '{"error":"encoded path traversal rejected","events":[]}\n'
  exit 0
}

SESSION_DIR="${CHOME}/projects/${ENCODED_PATH}"

# Validate session directory exists
if [[ ! -d "$SESSION_DIR" ]]; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    printf '{"events":[],"scanned":0,"project":"%s","note":"no session directory found"}\n' \
      "$(printf '%s' "$PROJECT_PATH" | sed 's/"/\\"/g')"
  else
    printf 'No sessions found for project: %s\n' "$PROJECT_PATH"
  fi
  exit 0
fi

# DA-004: No symlink following
[[ -L "$SESSION_DIR" ]] && {
  printf '{"events":[],"scanned":0,"project":"%s","note":"session directory is symlink — skipped"}\n' \
    "$(printf '%s' "$PROJECT_PATH" | sed 's/"/\\"/g')"
  exit 0
}

# ── Compute mtime cutoff ──
# DA-002: Use -newermt with macOS perl fallback, NOT -mtime
# DA-001: Skip files modified within last 60s (current session exclusion)
NOW_EPOCH=$(date +%s)
SESSION_EXCLUDE_CUTOFF=$(( NOW_EPOCH - 60 ))
SINCE_CUTOFF=$(( NOW_EPOCH - SINCE_DAYS * 86400 ))

# Format cutoff timestamp for -newermt (cross-platform)
# macOS: date -r; Linux: date -d @
_epoch_to_datetime() {
  local epoch="$1"
  date -r "$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
  date -d "@${epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
  perl -e "use POSIX qw(strftime); print strftime('%Y-%m-%d %H:%M:%S', localtime($epoch));" 2>/dev/null || \
  echo ""
}

SINCE_DATETIME=$(_epoch_to_datetime "$SINCE_CUTOFF")

# ── Collect JSONL files ──
# DA-004: find -P (no symlink follow)
# DA-002: -newermt with perl fallback
JSONL_FILES=()

if [[ -n "$SINCE_DATETIME" ]]; then
  # Primary: -newermt (supported on GNU findutils and BSD find with this syntax)
  while IFS= read -r f; do
    [[ -n "$f" ]] && JSONL_FILES+=("$f")
  done < <(find -P "$SESSION_DIR" -maxdepth 1 -name "*.jsonl" -type f -newermt "$SINCE_DATETIME" 2>/dev/null || true)
fi

# If -newermt failed or returned nothing, perl-based fallback
if [[ ${#JSONL_FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && JSONL_FILES+=("$f")
  done < <(
    find -P "$SESSION_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | while IFS= read -r candidate; do
      # Get mtime via perl (portable macOS+Linux)
      fmtime=$(perl -e 'use File::stat; my $s=stat(shift); print $s->mtime if $s' "$candidate" 2>/dev/null) || continue
      [[ -n "$fmtime" && "$fmtime" -gt "$SINCE_CUTOFF" ]] && printf '%s\n' "$candidate"
    done 2>/dev/null || true
  )
fi

# ── Two-pass join: extract tool_use + tool_result pairs ──
# Pass 1: collect tool_use events (from assistant messages)
# Pass 2: collect tool_result events (from user messages), join on tool_use_id

SCANNED=0
TMPDIR_WORK=$(mktemp -d 2>/dev/null) || exit 0
TOOL_USE_FILE="${TMPDIR_WORK}/tool_uses.jsonl"
TOOL_RESULT_FILE="${TMPDIR_WORK}/tool_results.jsonl"
touch "$TOOL_USE_FILE" "$TOOL_RESULT_FILE"

for JSONL in "${JSONL_FILES[@]}"; do
  # Skip symlinks (DA-004)
  [[ -L "$JSONL" ]] && continue
  # Skip files not readable
  [[ -r "$JSONL" ]] || continue

  # DA-001: Skip files modified within last 60s (current session)
  # FLAW-010: Fallback to stat when perl is unavailable to prevent privacy violation
  fmtime=$(_stat_mtime "$JSONL"); fmtime="${fmtime:-$(date +%s)}"
  if [[ -n "$fmtime" && "$fmtime" -gt "$SESSION_EXCLUDE_CUTOFF" ]]; then
    continue
  fi

  SCANNED=$(( SCANNED + 1 ))

  # Extract filename (safe — no shell eval)
  JSONL_BASENAME="${JSONL##*/}"
  JSONL_STEM="${JSONL_BASENAME%.jsonl}"

  # Validate stem is safe characters
  [[ "$JSONL_STEM" =~ ^[a-zA-Z0-9_-]+$ ]] || JSONL_STEM="session"

  # Pass 1: extract tool_use blocks from assistant messages
  # DA-003: select(.type != "isCompactSummary")
  # JSONL format: top-level .type == "assistant", content at .message.content
  jq -c --arg file "$JSONL_STEM" '
    select(.type != null) |
    select(.type != "isCompactSummary") |
    select(.type == "assistant") |
    (.message.content // []) | if type == "array" then .[] else . end |
    select(.type == "tool_use") |
    select(.id != null and .name != null) |
    {
      tool_use_id: .id,
      tool_name: .name,
      input_preview: (.input | tostring | .[0:500]),
      file: $file
    }
  ' "$JSONL" 2>/dev/null >> "$TOOL_USE_FILE" || true

  # Pass 2: extract tool_result blocks from user messages
  # DA-003: select(.type != "isCompactSummary")
  # JSONL format: top-level .type == "user", content at .message.content
  jq -c --arg file "$JSONL_STEM" '
    select(.type != null) |
    select(.type != "isCompactSummary") |
    select(.type == "user") |
    (.message.content // []) | if type == "array" then .[] else . end |
    select(.type == "tool_result") |
    select(.tool_use_id != null) |
    {
      tool_use_id: .tool_use_id,
      result_preview: (
        if .content == null then ""
        elif (.content | type) == "string" then .content[0:500]
        elif (.content | type) == "array" then (
          [.content[] | select(.type == "text") | .text // ""][0] // ""
        )[0:500]
        else (.content | tostring)[0:500]
        end
      ),
      is_error: (.is_error // false),
      soft_error: (
        if (.is_error // false) then false
        else
          (
            if .content == null then ""
            elif (.content | type) == "string" then .content
            elif (.content | type) == "array" then
              ([.content[] | select(.type == "text") | .text // ""][0] // "")
            else (.content | tostring)
            end
          ) | test("Error:|fatal:|FAILED|command not found|No such file|Permission denied|exit code [1-9]"; "")
        end
      ),
      file: $file
    }
  ' "$JSONL" 2>/dev/null >> "$TOOL_RESULT_FILE" || true

done

# ── Join tool_use with tool_result on tool_use_id ──
EVENTS_JSON=$(jq -r -n --slurpfile uses "$TOOL_USE_FILE" --slurpfile results "$TOOL_RESULT_FILE" '
  # Build lookup map: tool_use_id -> result
  (
    $results[0] // [] |
    reduce .[] as $r ({}; .[$r.tool_use_id] = $r)
  ) as $result_map |

  # Join
  [
    ($uses[0] // [])[] |
    . as $u |
    ($result_map[$u.tool_use_id] // {}) as $r |
    {
      tool_name: $u.tool_name,
      input_preview: $u.input_preview,
      result_preview: ($r.result_preview // ""),
      is_error: ($r.is_error // false),
      soft_error: ($r.soft_error // false),
      tool_use_id: $u.tool_use_id,
      file: $u.file
    }
  ]
' 2>/dev/null) || EVENTS_JSON="[]"

# Cleanup temp dir (SEC-005: guard non-empty and path is within tmp before rm -rf)
if [[ -n "${TMPDIR_WORK:-}" && ( "$TMPDIR_WORK" == /tmp/* || "$TMPDIR_WORK" == "${TMPDIR:-/tmp}"/* ) ]]; then
  rm -rf "$TMPDIR_WORK" 2>/dev/null || true
fi

# ── Output ──
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
  printf '%s' "$EVENTS_JSON" | jq -r '.[] | "[\(.tool_name)] in:\(.input_preview[0:80]) -> out:\(.result_preview[0:80])"' 2>/dev/null || true
else
  printf '%s' "$EVENTS_JSON" | jq -c --arg project "$PROJECT_PATH" --argjson scanned "$SCANNED" '{
    events: .,
    scanned: $scanned,
    project: $project
  }' 2>/dev/null || printf '{"events":[],"scanned":%d,"project":"%s"}\n' "$SCANNED" "$(printf '%s' "$PROJECT_PATH" | sed 's/"/\\"/g')"
fi
