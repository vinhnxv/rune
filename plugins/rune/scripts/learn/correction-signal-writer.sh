#!/bin/bash
# scripts/learn/correction-signal-writer.sh
# PostToolUse:Write|Edit hook — lightweight signal writer for file-revert detection.
#
# Fires on EVERY Write/Edit tool call. Fast-path exits in < 1ms when watch marker
# is absent. Only activates when user runs /rune:learn --watch.
#
# Detection: Tracks file edits, writes signal if same file edited 2+ times.
# This indicates a potential correction (wrote code, then rewrote/undid it).
#
# Signal files:
#   tmp/.rune-signals/.learn-edits/{hash}.log  — per-file edit timestamps
#   tmp/.rune-signals/.learn-correction-detected — signal for Stop hook
#
# Marker file: tmp/.rune-learn-watch
#   Contains JSON with config_dir, owner_pid, session_id for session isolation.
#
# EXIT BEHAVIOR: Always exit 0 (non-blocking PostToolUse — fail-open).
# TIMEOUT: 5s (fast — single file read + append).
# DEPENDENCIES: jq, shasum

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
command -v shasum &>/dev/null || exit 0

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
# Check if the process that created the marker is still alive
kill -0 "$MARKER_OWNER_PID" 2>/dev/null || exit 0

# ── GUARD 4: Extract file_path from tool_input ──
FILE_PATH=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -n "$FILE_PATH" ]] || exit 0

# ── GUARD 5: Security — reject path traversal ──
[[ "$FILE_PATH" == *".."* ]] && exit 0

# ── GUARD 6: Symlink guard — skip if file is symlink ──
[[ -L "$FILE_PATH" ]] && exit 0

# ── Create safe filename for edit log (SHA-256 hash, first 16 chars) ──
# This avoids long filenames from absolute paths
SAFE_NAME=$(printf '%s' "$FILE_PATH" | shasum -a 256 | cut -c1-16)
[[ -n "$SAFE_NAME" && "$SAFE_NAME" =~ ^[a-f0-9]+$ ]] || exit 0

# ── Ensure signal directory exists ──
SIGNAL_DIR="${CWD}/tmp/.rune-signals/.learn-edits"
mkdir -p "$SIGNAL_DIR" 2>/dev/null || exit 0
[[ -d "$SIGNAL_DIR" && ! -L "$SIGNAL_DIR" ]] || exit 0

EDIT_LOG="${SIGNAL_DIR}/${SAFE_NAME}.log"

# ── Check: was this file written/edited before in this session? ──
if [[ -f "$EDIT_LOG" && ! -L "$EDIT_LOG" ]]; then
  PREV_COUNT=$(wc -l < "$EDIT_LOG" 2>/dev/null || echo "0")
  PREV_COUNT=$(( PREV_COUNT + 0 )) 2>/dev/null || PREV_COUNT=0
  if [[ "$PREV_COUNT" -ge 1 ]]; then
    # Same file edited 2+ times — potential revert/correction
    # Write signal for Stop hook to detect
    touch "${CWD}/tmp/.rune-signals/.learn-correction-detected" 2>/dev/null || true
    _trace "Correction signal written: $FILE_PATH (edit count: $((PREV_COUNT + 1)))"
  fi
fi

# ── Record this edit ──
echo "$(date +%s) ${FILE_PATH}" >> "$EDIT_LOG" 2>/dev/null || true

exit 0