#!/bin/bash
# scripts/learn/detect-corrections.sh
# Stop hook — reads correction signals + scans JSONL, suggests Echo persist.
#
# Fires on EVERY Stop event. Fast-path exits in < 1ms when watch marker is absent.
# Only activates when user ran /rune:learn --watch.
#
# Detection sources:
#   1. File-revert signal (from correction-signal-writer.sh PostToolUse hook)
#   2. JSONL scan for error patterns (last 200 lines)
#
# Output: JSON with decision:block + systemMessage for Claude to ask user
# about running /rune:learn to persist corrections as Echo learnings.
#
# Debounce: Max 1 suggestion per session (via .learn-suggested-{PID} marker).
# Active workflow guard: Skips if any tmp/.rune-*.json state files exist.
#
# EXIT BEHAVIOR: Always exit 0 (non-blocking Stop hook — fail-open).
# TIMEOUT: 5s (fast — signal read + bounded JSONL scan).
# DEPENDENCIES: jq

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] %s: %s\n' "$(date +%H:%M:%S)" "${BASH_SOURCE[0]##*/}" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# ── Fail-forward trap (OPERATIONAL hook pattern) ──
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# ── GUARD 0: jq dependency ──
command -v jq &>/dev/null || exit 0

# ── Read stdin (max 1MB) ──
INPUT=$(head -c 1048576 2>/dev/null || true)

# ── GUARD 1: Extract and validate CWD ──
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -n "$CWD" ]] || exit 0
# Canonicalize CWD
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
# Validate CWD is absolute
[[ "$CWD" == /* ]] || exit 0

# ── GUARD 2: Fast-path — skip if watch marker absent ──
MARKER="${CWD}/tmp/.rune-learn-watch"
[[ -f "$MARKER" && ! -L "$MARKER" ]] || exit 0

# ── GUARD 3: Validate session ownership ──
# Read marker JSON to check config_dir + owner_pid
MARKER_DATA=$(cat "$MARKER" 2>/dev/null || true)
[[ -n "$MARKER_DATA" ]] || exit 0

MARKER_CONFIG_DIR=$(printf '%s\n' "$MARKER_DATA" | jq -r '.config_dir // empty' 2>/dev/null || true)
MARKER_OWNER_PID=$(printf '%s\n' "$MARKER_DATA" | jq -r '.owner_pid // empty' 2>/dev/null || true)

# Validate config_dir matches current session
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[[ "$MARKER_CONFIG_DIR" == "$CHOME" ]] || exit 0

# Validate owner_pid is still alive (session isolation)
[[ -n "$MARKER_OWNER_PID" && "$MARKER_OWNER_PID" =~ ^[0-9]+$ ]] || exit 0
kill -0 "$MARKER_OWNER_PID" 2>/dev/null || exit 0

# ── GUARD 4: Skip during active Rune workflows ──
# Avoid interrupting arc/strive/batch/hierarchy/issues pipelines
# shopt is bash-only — safe here because this script has #!/bin/bash shebang.
# The 2>/dev/null || true is defensive but should never trigger under bash.
shopt -s nullglob 2>/dev/null || true
for sf in "${CWD}"/tmp/.rune-*.json; do
  # Active workflow detected — don't suggest learning mid-workflow
  _trace "Active workflow detected, skipping correction suggestion"
  exit 0
done 2>/dev/null || true
# Also check for arc state files
for sf in "${CWD}"/tmp/arc-*/*.json; do
  _trace "Active arc workflow detected, skipping correction suggestion"
  exit 0
done 2>/dev/null || true

# ── GUARD 5: Debounce — max 1 suggestion per session ──
# FLAW-008 FIX: Use session_id for debounce key (PPID unreliable in hooks)
_session_id=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""
_debounce_key="${_session_id:-pid-${PPID}}"
DEBOUNCE="${CWD}/tmp/.rune-signals/.learn-suggested-${_debounce_key}"
[[ -f "$DEBOUNCE" && ! -L "$DEBOUNCE" ]] && exit 0

# ── Signal 1: File-revert detection (from correction-signal-writer.sh) ──
HAS_REVERT=false
[[ -f "${CWD}/tmp/.rune-signals/.learn-correction-detected" && ! -L "${CWD}/tmp/.rune-signals/.learn-correction-detected" ]] && HAS_REVERT=true

# ── Signal 2: Lightweight JSONL scan for error patterns ──
# Claude Code encodes project path: replace / with -, strip leading -
# (matches session-scanner.sh:120-121 encoding)
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ENCODED_PATH="${CWD//\//-}"
ENCODED_PATH="${ENCODED_PATH#-}"
JSONL_DIR="${CHOME}/projects/${ENCODED_PATH}"

HAS_CLI_CORRECTION=false
ERROR_COUNT=0

if [[ -d "$JSONL_DIR" && ! -L "$JSONL_DIR" ]]; then
  # Find latest JSONL file
  LATEST=$(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
  if [[ -n "$LATEST" && -f "$LATEST" && ! -L "$LATEST" ]]; then
    # Check last 200 lines for is_error:true (indicates error→fix pattern)
    # Use grep -c (count) — NOT grep -oP (Perl regex unavailable on macOS)
    ERROR_COUNT=$(tail -200 "$LATEST" 2>/dev/null | grep -c '"is_error":true' 2>/dev/null || echo "0")
    ERROR_COUNT=$(( ERROR_COUNT + 0 )) 2>/dev/null || ERROR_COUNT=0
    [[ "$ERROR_COUNT" -gt 0 ]] && HAS_CLI_CORRECTION=true
  fi
fi

# ── Decision: suggest if any signal detected ──
if [[ "$HAS_REVERT" == "true" || "$HAS_CLI_CORRECTION" == "true" ]]; then
  # Mark as suggested (debounce)
  touch "$DEBOUNCE" 2>/dev/null || true

  # Build summary message
  SUMMARY=""
  [[ "$HAS_REVERT" == "true" ]] && SUMMARY="File revert detected (same file edited multiple times). "
  [[ "$HAS_CLI_CORRECTION" == "true" ]] && SUMMARY="${SUMMARY}CLI error patterns detected (${ERROR_COUNT} errors in recent history). "

  # Clean up signal files after suggesting (prevent accumulation)
  rm -f "${CWD}/tmp/.rune-signals/.learn-correction-detected" 2>/dev/null || true
  rm -rf "${CWD}/tmp/.rune-signals/.learn-edits/" 2>/dev/null || true

  _trace "Correction patterns detected: $SUMMARY"

  # Stop hook output format (PAT-011 compliant)
  # systemMessage becomes Claude's next prompt — phrase as user-facing suggestion
  cat <<STOP_JSON
{"decision":"block","reason":"Correction patterns detected","systemMessage":"I detected correction patterns in this session: ${SUMMARY}Would you like to run /rune:learn to persist these corrections as Echo learnings for future sessions? I can do this now or skip it if you prefer."}
STOP_JSON
  exit 0
fi

# No signals detected — exit silently
exit 0