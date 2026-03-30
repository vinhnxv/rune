#!/bin/bash
# scripts/track-teammate-activity.sh
# PostToolUse:Bash|Write|Edit hook — per-teammate activity tracker.
#
# Fires on matched tool calls. Fast-path exit when no active Rune team exists.
# Writes epoch timestamp + tool name to activity signal files for stuck detection.
#
# Writes: tmp/.rune-signals/{team_name}/.activity-{agent_name}
# Read by: monitor-utility polling loop (stuck-teammate detection)
#
# EXIT BEHAVIOR: Always exit 0 (non-blocking PostToolUse — fail-open).
# TIMEOUT: 2s (fast — single file stat + optional atomic write).
# DEPENDENCIES: jq
set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# ── Fail-forward guard (OPERATIONAL hook — ADR-002) ──
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _ffl="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
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

# ── GUARD 0: jq dependency ──
command -v jq &>/dev/null || exit 0

# ── Source shared libraries ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/lib/platform.sh" ]] && source "${SCRIPT_DIR}/lib/platform.sh"

# ── Read stdin (PostToolUse hook input) ──
INPUT=$(head -c 1048576 2>/dev/null || true)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -n "$CWD" && "$CWD" == /* ]] || exit 0

# ── GUARD 1: Fast-path — is there an active Rune team? ──
# Check CHOME/teams/ for rune-* or arc-* team directories.
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TEAM_NAME=""
if [[ -d "${CHOME}/teams" ]]; then
  for d in "${CHOME}/teams/"rune-* "${CHOME}/teams/"arc-*; do
    if [[ -d "$d" && ! -L "$d" ]]; then
      TEAM_NAME=$(basename "$d")
      break
    fi
  done
fi
[[ -n "$TEAM_NAME" ]] || exit 0

# ── GUARD 2: Teammate check — only track subagent tool calls ──
TRANSCRIPT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" == */subagents/* ]] || exit 0

# ── Extract agent context ──
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
AGENT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.agent_name // empty' 2>/dev/null || true)
[[ -n "$AGENT_NAME" ]] || exit 0

# ── SEC-4: Validate agent_name before using in file path ──
if [[ ! "$AGENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# ── Resolve activity file path ──
SIGNAL_DIR="${CWD}/tmp/.rune-signals/${TEAM_NAME}"
ACTIVITY_FILE="${SIGNAL_DIR}/.activity-${AGENT_NAME}"

# ── GUARD 3: Throttle — only write if file mtime is >15 seconds old ──
# Prevents I/O storm from rapid tool call sequences.
# 15s chosen to give ~12 samples per 3-minute stuck detection window.
if [[ -f "$ACTIVITY_FILE" ]]; then
  ACT_MTIME=$(_stat_mtime "$ACTIVITY_FILE" 2>/dev/null || echo "0")
  ACT_MTIME="${ACT_MTIME:-0}"
  [[ -z "$ACT_MTIME" || ! "$ACT_MTIME" =~ ^[0-9]+$ ]] && ACT_MTIME=0
  ACT_NOW=$(date +%s)
  ACT_AGE=$(( ACT_NOW - ACT_MTIME ))
  [[ $ACT_AGE -lt 0 ]] && ACT_AGE=0
  [[ $ACT_AGE -lt 15 ]] && exit 0
fi

# ── Atomic write (mktemp + mv) ──
mkdir -p "$SIGNAL_DIR" 2>/dev/null || exit 0
ACT_TMP=$(mktemp "${ACTIVITY_FILE}.XXXXXX" 2>/dev/null) || exit 0
printf '%s %s\n' "$(date +%s)" "${TOOL_NAME:-unknown}" > "$ACT_TMP" 2>/dev/null || {
  rm -f "$ACT_TMP" 2>/dev/null
  exit 0
}
mv -f "$ACT_TMP" "$ACTIVITY_FILE" 2>/dev/null || rm -f "$ACT_TMP" 2>/dev/null
exit 0
