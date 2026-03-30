#!/bin/bash
# scripts/arc-heartbeat-writer.sh
# PostToolUse:Read|Write|Edit|Bash|Glob|Grep hook — arc phase heartbeat writer.
#
# Fires on every matched tool call. Fast-path exit (<2ms) when no arc is active.
# Full-path: atomic write heartbeat JSON, throttled to once per 30 seconds.
#
# Writes: tmp/arc/{id}/heartbeat.json
# Read by: session-team-hygiene.sh (Layer 2 crash recovery), rune-status.sh
#
# EXIT BEHAVIOR: Always exit 0 (non-blocking PostToolUse — fail-open).
# TIMEOUT: 5s (fast — single file stat + optional atomic write).
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

# ── GUARD 1: Fast-path — is there an active arc? ──
# stat() on state file is the cheapest possible check (<0.5ms).
# Pattern from arc-result-signal-writer.sh.
# ── Source shared libraries (BEFORE using RUNE_STATE) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/lib/platform.sh" ]] && source "${SCRIPT_DIR}/lib/platform.sh"
source "${SCRIPT_DIR}/lib/rune-state.sh"

INPUT=$(head -c 1048576 2>/dev/null || true)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -n "$CWD" && "$CWD" == /* ]] || exit 0

STATE_FILE="${CWD}/${RUNE_STATE}/arc-phase-loop.local.md"
[[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || exit 0

# ── GUARD 2: Teammate fast-exit (heartbeat only for lead/orchestrator) ──
# Pattern from rune-context-monitor.sh line 48.
TRANSCRIPT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" == */subagents/* ]] && exit 0

# ── Extract tool name ──
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

# ── Extract arc ID from state file ──
# State file is YAML frontmatter with `checkpoint_path: ${RUNE_STATE}/arc/{id}/checkpoint.json`
# Fields: active, iteration, max_iterations, checkpoint_path, plan_file, branch,
#   arc_flags, config_dir, owner_pid, session_id, compact_pending,
#   user_cancelled, cancel_reason, cancelled_at, stop_reason
# NOTE: There is NO `current_phase` field — phase is determined by the Stop hook
#   reading the checkpoint and finding the next pending phase.
ARC_ID=$(grep '^checkpoint_path:' "$STATE_FILE" 2>/dev/null | \
  sed 's|.*arc/\([^/]*\)/.*|\1|' | head -1 || true)
[[ -n "$ARC_ID" && "$ARC_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

HEARTBEAT_DIR="${CWD}/tmp/arc/${ARC_ID}"
HEARTBEAT_FILE="${HEARTBEAT_DIR}/heartbeat.json"

# ── GUARD 3: Throttle — write at most once per 30 seconds ──
# Prevents I/O storm during rapid tool call sequences.
# First write always succeeds (_stat_mtime returns 0 for new files → age is huge).
#
# Rationale: 30 seconds chosen because stuck detection uses 15-minute threshold.
# At 30s intervals, we get ~30 samples per detection window, sufficient to
# distinguish between "working" and "stuck" phases. Lower values increase I/O;
# higher values reduce stuck detection accuracy.
if [[ -f "$HEARTBEAT_FILE" ]]; then
  HB_MTIME=$(_stat_mtime "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
  HB_MTIME="${HB_MTIME:-0}"
  [[ -z "$HB_MTIME" || ! "$HB_MTIME" =~ ^[0-9]+$ ]] && HB_MTIME=0
  HB_NOW=$(date +%s)
  HB_AGE=$(( HB_NOW - HB_MTIME ))
  [[ $HB_AGE -lt 0 ]] && HB_AGE=0
  [[ $HB_AGE -lt 30 ]] && exit 0
fi

# ── Extract current phase from checkpoint ──
# The state file has NO current_phase field. Must read from checkpoint.
# This jq call only runs once per 30 seconds (throttle above), so overhead is acceptable.
CURRENT_PHASE="unknown"
CKPT_PATH="${CWD}/${RUNE_STATE}/arc/${ARC_ID}/checkpoint.json"
if [[ -f "$CKPT_PATH" && ! -L "$CKPT_PATH" ]]; then
  CURRENT_PHASE=$(jq -r '
    [.phases | to_entries[] | select(.value.status == "in_progress")] | first | .key // "unknown"
  ' "$CKPT_PATH" 2>/dev/null || echo "unknown")
fi

# ── GUARD 4: Skip heartbeat for completed arcs ──
# When no phase is in_progress and stop_reason indicates completion, skip heartbeat write.
# This prevents misleading "unknown" phase values in rune-status output.
if [[ -f "$CKPT_PATH" && ! -L "$CKPT_PATH" ]]; then
  ARC_STOP_REASON=$(jq -r '.stop_reason // ""' "$CKPT_PATH" 2>/dev/null || true)
  if [[ "$ARC_STOP_REASON" == "completed" || "$ARC_STOP_REASON" == "user_cancel" ]]; then
    exit 0
  fi
fi

# ── Session nonce (stable per session, truncated to 16 chars) ──
_NONCE="${RUNE_SESSION_ID:-$$-$(date +%s)}"
_NONCE="${_NONCE:0:16}"

# ── Session isolation fields (AC-3.4: config_dir + session_id + owner_pid) ──
_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_SESSION_ID="${RUNE_SESSION_ID:-unknown}"

# ── Atomic write (mktemp + mv) ──
mkdir -p "$HEARTBEAT_DIR" 2>/dev/null || exit 0
HB_TMP=$(mktemp "${HEARTBEAT_FILE}.XXXXXX" 2>/dev/null) || exit 0
jq -n \
  --arg phase "${CURRENT_PHASE}" \
  --arg tool "${TOOL_NAME:-unknown}" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg arc_id "$ARC_ID" \
  --arg nonce "$_NONCE" \
  --argjson owner_pid "${PPID:-0}" \
  --arg config_dir "$_CONFIG_DIR" \
  --arg session_id "$_SESSION_ID" \
  '{arc_id: $arc_id, phase: $phase, last_tool: $tool, last_activity: $ts, nonce: $nonce, owner_pid: $owner_pid, config_dir: $config_dir, session_id: $session_id}' \
  > "$HB_TMP" 2>/dev/null || { rm -f "$HB_TMP" 2>/dev/null; exit 0; }
mv -f "$HB_TMP" "$HEARTBEAT_FILE" 2>/dev/null || rm -f "$HB_TMP" 2>/dev/null
exit 0