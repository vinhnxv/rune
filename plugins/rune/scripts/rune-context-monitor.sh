#!/bin/bash
# Rune Context Monitor — Consumer half of context monitoring pipeline
# PostToolUse hook: reads bridge file, injects warnings when context runs low
set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  local _ff_exit=$?
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    # OBSV-002 FIX: Include failing command and exit code for error diagnosis
    printf '[%s] %s: ERR trap — fail-forward activated (line %s, exit %s, cmd: %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      "$_ff_exit" \
      "${BASH_COMMAND:-unknown}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR    # fail-open — monitor must never exit non-zero
umask 077

# Session identity — resolved config_dir for cross-session isolation (Core Rule 11)
# GAP-2 FIX: Source shared resolver instead of inlining (matches all 5 ownership-check scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/resolve-session-identity.sh"
source "${SCRIPT_DIR}/lib/platform.sh"
source "${SCRIPT_DIR}/lib/rune-state.sh"

# Trace logging (match all Rune hooks)
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] rune-context-monitor: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

# Constants (overridable via talisman — see Phase 1.2)
WARNING_THRESHOLD=35    # remaining_percentage
CRITICAL_THRESHOLD=25   # remaining_percentage
STALE_SECONDS=60        # bridge file max age
DEBOUNCE_CALLS=5        # tool uses between repeated same-level warnings

# --- Dependencies ---
if ! command -v jq &>/dev/null; then
  exit 0
fi

# --- Read stdin (1MB cap) ---
INPUT=$(head -c 1048576 2>/dev/null || true)

# AT-2 FIX: Fast-exit for teammates — they don't have bridge files (lead-only monitoring)
# Pattern from enforce-readonly.sh line 34: transcript_path contains /subagents/ for teammates.
# This avoids wasting jq parse + file stat for every teammate tool call during strive/review.
TRANSCRIPT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
if [[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" == */subagents/* ]]; then
  _trace "SKIP: teammate (subagent) — lead-only monitoring"
  exit 0
fi

SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[[ -z "$SESSION_ID" ]] && exit 0

# Validate session_id
[[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] && exit 0

# P1-1 FIX: Define WARN_STATE and BRIDGE_FILE early (before any reference)
BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"
WARN_STATE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}-warned.json"

# --- Read talisman config (optional) ---
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
# SEC-MON-001: Canonicalize CWD before use in file paths
[[ -n "$CWD" ]] && CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD=""
if [[ -n "$CWD" && "$CWD" == /* ]]; then
  TALISMAN="${CWD}/${RUNE_STATE}/talisman.yml"
  if [[ -f "$TALISMAN" ]] && command -v yq &>/dev/null; then
    # Fast-path: skip yq if context_monitor section doesn't exist
    if grep -q 'context_monitor:' "$TALISMAN" 2>/dev/null; then
      # NOTE: Checks YAML boolean false only. String "false" is not treated as disabled (standard YAML convention).
      ENABLED=$(yq -r 'if .context_monitor.enabled == false then "false" else "true" end' "$TALISMAN" 2>/dev/null || echo "true")
      [[ "$ENABLED" == "false" ]] && exit 0
      _WARN=$(yq -r '.context_monitor.warning_threshold // ""' "$TALISMAN" 2>/dev/null || true)
      _CRIT=$(yq -r '.context_monitor.critical_threshold // ""' "$TALISMAN" 2>/dev/null || true)
      _STALE=$(yq -r '.context_monitor.stale_seconds // ""' "$TALISMAN" 2>/dev/null || true)
      _DEBOUNCE=$(yq -r '.context_monitor.debounce_calls // ""' "$TALISMAN" 2>/dev/null || true)
      [[ -n "$_WARN" && "$_WARN" =~ ^[0-9]+$ ]] && WARNING_THRESHOLD="$_WARN"
      [[ -n "$_CRIT" && "$_CRIT" =~ ^[0-9]+$ ]] && CRITICAL_THRESHOLD="$_CRIT"
      [[ -n "$_STALE" && "$_STALE" =~ ^[0-9]+$ ]] && STALE_SECONDS="$_STALE"
      [[ -n "$_DEBOUNCE" && "$_DEBOUNCE" =~ ^[0-9]+$ ]] && DEBOUNCE_CALLS="$_DEBOUNCE"
    fi
  fi
fi

# --- Read bridge file ---
[[ ! -f "$BRIDGE_FILE" ]] && exit 0
# P1-3 FIX: Symlink guard before reading bridge file
[[ -L "$BRIDGE_FILE" ]] && exit 0

# OS-level UID check (consistent with guard-context-critical.sh EC-H5)
_BRIDGE_UID=$(_stat_uid "$BRIDGE_FILE")
if [[ -n "$_BRIDGE_UID" && "$_BRIDGE_UID" != "$(id -u)" ]]; then
  _trace "SKIP: bridge UID mismatch (file=$_BRIDGE_UID, us=$(id -u))"
  exit 0
fi

# EDGE-MON-008: Cap bridge file read (consistent with stdin 1MB cap pattern)
BRIDGE=$(head -c 4096 "$BRIDGE_FILE" 2>/dev/null) || exit 0
REMAINING=$(echo "$BRIDGE" | jq -r '.remaining_percentage // empty' 2>/dev/null || true)
USED_PCT=$(echo "$BRIDGE" | jq -r '.used_pct // empty' 2>/dev/null || true)
TIMESTAMP=$(echo "$BRIDGE" | jq -r '.timestamp // 0' 2>/dev/null || true)

[[ -z "$REMAINING" || -z "$USED_PCT" ]] && exit 0
# P2-4 FIX: Validate USED_PCT is numeric before interpolation into warning message
[[ ! "$USED_PCT" =~ ^[0-9]+$ ]] && exit 0

# P1-3 FIX: Session isolation — verify bridge ownership (Core Rule 11)
# GAP-1 FIX: $RUNE_CURRENT_CFG from resolve-session-identity.sh (resolved with pwd -P)
B_CFG=$(echo "$BRIDGE" | jq -r '.config_dir // empty' 2>/dev/null || true)
B_PID=$(echo "$BRIDGE" | jq -r '.owner_pid // empty' 2>/dev/null || true)
[[ -n "$B_CFG" && "$B_CFG" != "$RUNE_CURRENT_CFG" ]] && { _trace "SKIP: config_dir mismatch"; exit 0; }
if [[ -n "$B_PID" && "$B_PID" =~ ^[0-9]+$ && "$B_PID" != "${PPID:-0}" ]]; then
  rune_pid_alive "$B_PID" && { _trace "SKIP: bridge owned by live PID $B_PID (EPERM-safe)"; exit 0; }
fi
_trace "BRIDGE read: remaining=$REMAINING used=$USED_PCT age=$(($(date +%s) - TIMESTAMP))s"

# --- Staleness check ---
NOW=$(date +%s)
[[ "$TIMESTAMP" =~ ^[0-9]+$ ]] || exit 0  # Guard: non-integer timestamp
AGE=$((NOW - TIMESTAMP))
[[ "$AGE" -gt "$STALE_SECONDS" ]] && { _trace "SKIP: bridge stale (${AGE}s > ${STALE_SECONDS}s)"; exit 0; }

# --- Threshold evaluation ---
# IMPL-MON-001: Floor truncation instead of printf rounding (platform-dependent)
REM_INT="${REMAINING%%.*}"
[[ -z "$REM_INT" || ! "$REM_INT" =~ ^[0-9]+$ ]] && exit 0

ALERT_LEVEL=""
if [[ "$REM_INT" -le "$CRITICAL_THRESHOLD" ]]; then
  ALERT_LEVEL="critical"
elif [[ "$REM_INT" -le "$WARNING_THRESHOLD" ]]; then
  ALERT_LEVEL="warning"
else
  # EDGE-MON-004: Clear debounce state on recovery so next decline fires immediately
  # P1-1 FIX: WARN_STATE is now defined above — this rm actually works
  [[ -f "$WARN_STATE" ]] && rm -f "$WARN_STATE" 2>/dev/null
  _trace "HEALTHY: remaining=${REM_INT}%, debounce cleared"
  exit 0  # Context is healthy
fi

# --- Debounce ---
FIRE=false

if [[ ! -f "$WARN_STATE" ]]; then
  # First warning ever — fire immediately
  FIRE=true
else
  # SEC-001 FIX: Symlink guard on WARN_STATE read (matches write guards at lines 434, 446)
  # Treat symlink as tampered — delete and fire immediately (safe default)
  if [[ -L "$WARN_STATE" ]]; then
    rm -f "$WARN_STATE" 2>/dev/null
    FIRE=true
  else
    # SEC-002 FIX: Cap WARN_STATE read (matches bridge file cap at line 371)
    WARN_CONTENT=$(head -c 4096 "$WARN_STATE" 2>/dev/null || true)
    PREV_CALLS=$(echo "$WARN_CONTENT" | jq -r '.callsSinceWarn // 0' 2>/dev/null || echo "0")
    PREV_LEVEL=$(echo "$WARN_CONTENT" | jq -r '.lastLevel // ""' 2>/dev/null || echo "")

    if [[ "$PREV_LEVEL" == "warning" && "$ALERT_LEVEL" == "critical" ]]; then
      # Severity escalation — bypass debounce
      FIRE=true
    # P1-5 FIX: Use (DEBOUNCE_CALLS - 1) so warning fires every N tool uses, not N+1
    # Counter: fire(0)→1→2→3→4=fire. 4 >= (5-1) → fire. That's 4 silent + fire = 5 uses total.
    elif [[ "$PREV_CALLS" -ge "$((DEBOUNCE_CALLS - 1))" ]]; then
      # Debounce period expired
      FIRE=true
    else
      # Increment counter, don't fire
      NEW_CALLS=$((PREV_CALLS + 1))
      # Symlink guard on WARN_STATE write
      [[ -L "$WARN_STATE" ]] && rm -f "$WARN_STATE" 2>/dev/null
      _tmp=$(mktemp "${WARN_STATE}.XXXXXX") && \
        jq -n --argjson calls "$NEW_CALLS" --arg level "$PREV_LEVEL" \
          '{callsSinceWarn: $calls, lastLevel: $level}' \
          > "$_tmp" && mv "$_tmp" "$WARN_STATE" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; true; }
      _trace "DEBOUNCE: $ALERT_LEVEL suppressed (${NEW_CALLS}/${DEBOUNCE_CALLS})"
      exit 0
    fi
  fi
fi

# --- Fire warning ---
if [[ "$FIRE" == "true" ]]; then
  # Symlink guard on WARN_STATE write
  [[ -L "$WARN_STATE" ]] && rm -f "$WARN_STATE" 2>/dev/null
  # Reset debounce state
  _tmp=$(mktemp "${WARN_STATE}.XXXXXX") && \
    jq -n --arg level "$ALERT_LEVEL" \
      '{callsSinceWarn: 0, lastLevel: $level}' \
      > "$_tmp" && mv "$_tmp" "$WARN_STATE" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; true; }

  if [[ "$ALERT_LEVEL" == "critical" ]]; then
    MSG="RUNE CONTEXT MONITOR CRITICAL: Context usage at ${USED_PCT}%. Remaining: ${REM_INT}%. STOP new work immediately. Complete current task minimally, write state to files, and inform the user that context is nearly exhausted. Consider /rune:rest to clean up artifacts."
  else
    MSG="RUNE CONTEXT MONITOR WARNING: Context usage at ${USED_PCT}%. Remaining: ${REM_INT}%. Begin wrapping up current task. Do not start new complex work or summon additional agents. If in arc/strive, current phase should complete but avoid spawning new phases."
  fi

  _trace "FIRE: $ALERT_LEVEL at ${USED_PCT}% used, ${REM_INT}% remaining"

  # Inject into agent conversation via hookSpecificOutput
  jq -n --arg msg "$MSG" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
fi

exit 0
