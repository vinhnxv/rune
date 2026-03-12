#!/bin/bash
# scripts/guard-context-critical.sh
# CTX-GUARD-001: Blocks TeamCreate and Agent/Task at critical context levels.
# Uses the statusline bridge file (/tmp/rune-ctx-{SESSION_ID}.json) as data source.
# Hard deny at critical threshold (default: 25% remaining / 75% used).
# Explore/Plan agent types exempt (Agent/Task tool only — TeamCreate always checked per EC-4).
# NOTE: Claude Code 2.1.63 renamed "Task" tool to "Agent". Both names are handled.
# Fail-open: any error → exit 0 (allow tool).
#
# BD-2 tension: This hook uses hard-block (deny) but fail-open on dependencies
# (no jq → allow, no bridge → allow, stale bridge → allow). This is intentional:
# blocking on missing data is worse than allowing at critical context.

set -euo pipefail

# --- Fail-open wrapper ---
_fail_open() { exit 0; }
trap '_fail_open' ERR

# --- Guard: jq dependency ---
command -v jq >/dev/null 2>&1 || exit 0

# --- Guard: Input size cap (SEC-2) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Single-pass jq extraction (performance: runs on EVERY TeamCreate/Task) ---
# CDXB-001 FIX: Handle empty subagent_type field correctly
# Previous TSV-based approach collapsed empty middle fields, shifting SESSION_ID
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
SUBAGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

[[ -z "$TOOL_NAME" || -z "$CWD" || -z "$SESSION_ID" ]] && exit 0

# --- Guard: Teammate bypass (subagents can't spawn teams) ---
TRANSCRIPT_PATH=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
if [[ -n "$TRANSCRIPT_PATH" && "$TRANSCRIPT_PATH" == *"/subagents/"* ]]; then
  exit 0
fi

# --- SESSION_ID validation ---
if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# --- Session identity ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/platform.sh"
# shellcheck source=resolve-session-identity.sh
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  # QUAL-002 FIX: EPERM-aware PID liveness check — EPERM means alive (different user)
  rune_pid_alive() {
    local _out _rc
    _out=$(kill -0 "$1" 2>&1) && return 0
    _rc=$?
    case "$_out" in *"Operation not permitted"*|*"EPERM"*|*"permission"*) return 0 ;; esac
    return "$_rc"
  }
fi

# --- Explore/Plan exemption (Agent/Task tool only, NOT TeamCreate per EC-4) ---
# Claude Code 2.1.63+ renamed "Task" → "Agent". Match both for backward compat.
if [[ "$TOOL_NAME" == "Task" || "$TOOL_NAME" == "Agent" ]]; then
  case "$SUBAGENT_TYPE" in
    Explore|Plan) exit 0 ;;  # Read-only agents — minimal context cost
  esac
fi

# --- Read bridge file ---
# SEC-004 NOTE: Bridge path is predictable (/tmp/rune-ctx-{SESSION_ID}.json).
# Mitigated by: (1) symlink guard below, (2) UID ownership check (EC-H5),
# (3) bridge freshness check (30s staleness), (4) umask 077 on writer.
BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${SESSION_ID}.json"

# Bridge must exist
[[ -f "$BRIDGE_FILE" ]] || exit 0

# Symlink guard
[[ -L "$BRIDGE_FILE" ]] && exit 0

# OS-level UID check (EC-H5)
BRIDGE_UID=$(_stat_uid "$BRIDGE_FILE")
if [[ -n "$BRIDGE_UID" && "$BRIDGE_UID" != "$(id -u)" ]]; then
  exit 0  # Not our file
fi

# --- Bridge freshness (30s for blocking guard per EC-1) ---
STALE_SECONDS=30
FILE_MTIME=$(_stat_mtime "$BRIDGE_FILE"); FILE_MTIME="${FILE_MTIME:-0}"
NOW=$(date +%s)
AGE=$(( NOW - FILE_MTIME ))

# Future timestamp guard (spoofed timestamp)
[[ "$AGE" -lt 0 ]] && exit 0

# Stale bridge → allow
[[ "$AGE" -ge "$STALE_SECONDS" ]] && exit 0

# --- Parse bridge data ---
IFS=$'\t' read -r BRIDGE_CFG BRIDGE_PID REM_INT < <(
  jq -r '[.config_dir//"", .owner_pid//"", (.remaining_percentage // -1 | tostring)] | @tsv' "$BRIDGE_FILE" 2>/dev/null || echo ""
) || true

# --- Session ownership check ---
if [[ -n "$BRIDGE_CFG" && "$BRIDGE_CFG" != "$RUNE_CURRENT_CFG" ]]; then
  exit 0  # Foreign bridge
fi

if [[ -n "$BRIDGE_PID" && "$BRIDGE_PID" =~ ^[0-9]+$ && "$BRIDGE_PID" != "$PPID" ]]; then
  if rune_pid_alive "$BRIDGE_PID"; then
    exit 0  # Different live session (EPERM-safe)
  else
    # Orphaned bridge — cleanup and allow
    rm -f "$BRIDGE_FILE" 2>/dev/null
    exit 0
  fi
fi

# --- Validate remaining_percentage ---
[[ -z "$REM_INT" || ! "$REM_INT" =~ ^[0-9]+$ ]] && exit 0
# Clamp to valid range (bogus bridge data → fail-open)
[[ "$REM_INT" -gt 100 ]] && exit 0

# --- Threshold check ---
# Default: 25% remaining. Configurable via talisman (not read here — hooks are fast).
CRITICAL_THRESHOLD=25

# Clamp threshold to [10, 50] range
[[ "$CRITICAL_THRESHOLD" -lt 10 ]] && CRITICAL_THRESHOLD=10
[[ "$CRITICAL_THRESHOLD" -gt 50 ]] && CRITICAL_THRESHOLD=50

# --- Tier 1: Caution (40%) — advisory only, no block ---
CAUTION_THRESHOLD=40
# Hardcoded (talisman caution_threshold not read — hooks are fast-path)
if [[ "$REM_INT" -le "$CAUTION_THRESHOLD" && "$REM_INT" -gt 35 ]]; then
  jq -n \
    --arg ctx "CTX-CAUTION: Context at $((100 - REM_INT))% used (${REM_INT}% remaining). Consider: (1) compress long messages, (2) avoid deep-reading files already seen, (3) prefer file-based output over inline responses." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}' 2>/dev/null || true
  exit 0
fi

# --- Tier 2: Warning (35%) — advisory with workflow-specific degradation suggestions ---
WARNING_THRESHOLD=35
if [[ "$REM_INT" -le "$WARNING_THRESHOLD" && "$REM_INT" -gt "$CRITICAL_THRESHOLD" ]]; then
  # Detect current workflow from state files (explicit paths — Concern C3)
  WORKFLOW="unknown"
  shopt -s nullglob
  for sf in \
    "$CWD/tmp/.rune-review-"*.json \
    "$CWD/tmp/.rune-audit-"*.json \
    "$CWD/tmp/.rune-work-"*.json \
    "$CWD/tmp/.rune-mend-"*.json \
    "$CWD/tmp/.rune-inspect-"*.json \
    "$CWD/tmp/.rune-forge-"*.json \
    "$CWD/tmp/.rune-plan-"*.json \
    "$CWD/tmp/.rune-goldmask-"*.json \
    "$CWD/tmp/.rune-brainstorm-"*.json \
    "$CWD/tmp/.rune-debug-"*.json \
    "$CWD/tmp/.rune-design-sync-"*.json \
    "$CWD/tmp/.rune-arc-"*.json; do
    [[ -f "$sf" ]] || continue
    # Session ownership check before reading
    SF_CFG=$(jq -r '.config_dir // empty' < "$sf" 2>/dev/null || true)
    SF_PID=$(jq -r '.owner_pid // empty' < "$sf" 2>/dev/null || true)
    # QUAL-004 FIX: Three-way VEIL-007 guard — skip only when BOTH values are non-empty and different
    [[ -n "$SF_CFG" && -n "$RUNE_CURRENT_CFG" && "$SF_CFG" != "$RUNE_CURRENT_CFG" ]] && continue
    if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ && "$SF_PID" != "$PPID" ]]; then
      rune_pid_alive "$SF_PID" && continue
    fi
    WORKFLOW=$(jq -r '.workflow // "unknown"' < "$sf" 2>/dev/null || echo "unknown")
    break
  done
  shopt -u nullglob

  SUGGESTION=""
  case "$WORKFLOW" in
    review|appraise|audit)
      SUGGESTION="Reduce team to 3-4 Ashes. Skip deep review if standard suffices." ;;
    work|strive)
      SUGGESTION="Complete current task, skip optional tasks. Commit what is done." ;;
    arc)
      SUGGESTION="Skip optional phases (forge, codex-gap, test-coverage-critique). Proceed to ship." ;;
    devise|plan)
      SUGGESTION="Skip forge enrichment. Proceed directly to plan review." ;;
    *)
      SUGGESTION="Reduce scope. Prefer file-based output. Consider /compact." ;;
  esac

  # --- Layer 1 Shutdown Signal: Write signal file for orchestrator consumption ---
  # Idempotent — only write once per session (hook fires every tool call)
  # Canonicalize CWD before use in signal file path (SEC-005)
  CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
  [[ "$CWD" == /* ]] || exit 0
  SIGNAL_FILE="${CWD}/tmp/.rune-shutdown-signal-${SESSION_ID}.json"
  if [[ ! -f "$SIGNAL_FILE" ]]; then
    mkdir -p "${CWD}/tmp" 2>/dev/null
    _tmpf=$(mktemp "${CWD}/tmp/.rune-signal-tmp.XXXXXX" 2>/dev/null) || exit 0
    jq -n \
      --arg signal "context_warning" \
      --argjson remaining_pct "$REM_INT" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg config_dir "$RUNE_CURRENT_CFG" \
      --arg owner_pid "$PPID" \
      --arg session_id "$SESSION_ID" \
      '{signal: $signal, remaining_pct: $remaining_pct, timestamp: $timestamp, config_dir: $config_dir, owner_pid: $owner_pid, session_id: $session_id}' \
      > "$_tmpf" 2>/dev/null && mv "$_tmpf" "$SIGNAL_FILE" 2>/dev/null || true
  fi

  jq -n \
    --arg ctx "CTX-WARNING: Context at $((100 - REM_INT))% used (${REM_INT}% remaining). Workflow: ${WORKFLOW}. Suggested: ${SUGGESTION}. SHUTDOWN SIGNAL written to ${SIGNAL_FILE}. Orchestrators: check for this file and initiate early teammate shutdown. Escape: /compact or /rune:rest." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}' 2>/dev/null || true
  exit 0
fi

# --- Tier 3: Critical (25%) — hard DENY ---
# Above critical threshold → allow silently
if [[ "$REM_INT" -gt "$CRITICAL_THRESHOLD" ]]; then
  exit 0
fi

# --- Rune workflow scope check ---
# Only hard-deny TeamCreate/Agent for Rune agents during active Rune workflows.
# Non-Rune agents from other plugins pass through even at critical context.
# Source shared registry for is_known_rune_agent().
SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "${SCRIPT_DIR_LIB}/lib/known-rune-agents.sh" ]]; then
  # shellcheck source=lib/known-rune-agents.sh
  source "${SCRIPT_DIR_LIB}/lib/known-rune-agents.sh"
fi

# For Agent/Task calls: check if the agent name is a known Rune agent.
# If not a Rune agent, allow through (other plugins can manage their own context).
# TeamCreate is always checked (could create a Rune team — but we add a name check).
if [[ "$TOOL_NAME" == "Task" || "$TOOL_NAME" == "Agent" ]]; then
  CTX_AGENT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || true)
  if [[ -n "$CTX_AGENT_NAME" ]]; then
    if type -t is_known_rune_agent &>/dev/null; then
      if ! is_known_rune_agent "$CTX_AGENT_NAME"; then
        exit 0  # Non-Rune agent — allow even at critical context
      fi
    else
      # BACK-104 FIX: Registry unavailable — fail-open for named agents to preserve scope isolation.
      # Without the registry we cannot distinguish Rune from non-Rune agents.
      # Denying all would break other plugins. Allow and log warning.
      printf 'WARN: guard-context-critical: is_known_rune_agent unavailable — allowing agent "%s" (scope isolation degraded)\n' "$CTX_AGENT_NAME" >&2 2>/dev/null || true
      exit 0
    fi
  fi
fi

# For TeamCreate: check if the team name starts with "rune-" prefix.
# Non-Rune teams pass through — other plugins manage their own lifecycle.
if [[ "$TOOL_NAME" == "TeamCreate" ]]; then
  CTX_TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || true)
  if [[ -n "$CTX_TEAM_NAME" && ! "$CTX_TEAM_NAME" =~ ^rune- ]]; then
    exit 0  # Non-Rune team — allow even at critical context
  fi
fi

# --- DENY: Context at critical level (Rune workflow confirmed) ---
USED_PCT=$(( 100 - REM_INT ))

# --- Force Shutdown Signal: Write signal file for orchestrator emergency shutdown ---
# Stronger than context_warning — orchestrators should send shutdown_request to ALL workers.
# Idempotent — only write once per session.
FORCE_SIGNAL="${CWD}/tmp/.rune-force-shutdown-${SESSION_ID}.json"
if [[ ! -f "$FORCE_SIGNAL" ]]; then
  mkdir -p "${CWD}/tmp" 2>/dev/null
  _tmpf=$(mktemp "${CWD}/tmp/.rune-force-tmp.XXXXXX" 2>/dev/null) || exit 0
  jq -n \
    --arg signal "force_shutdown" \
    --argjson remaining_pct "$REM_INT" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg config_dir "$RUNE_CURRENT_CFG" \
    --arg owner_pid "$PPID" \
    --arg session_id "$SESSION_ID" \
    '{signal: $signal, remaining_pct: $remaining_pct, timestamp: $timestamp, config_dir: $config_dir, owner_pid: $owner_pid, session_id: $session_id}' \
    > "$_tmpf" 2>/dev/null && mv "$_tmpf" "$FORCE_SIGNAL" 2>/dev/null || true
fi

jq -n \
  --arg reason "Context at ${USED_PCT}% (${REM_INT}% remaining). Spawning new agents risks session freeze. Finish current work, then start fresh." \
  --arg ctx "BLOCKED by guard-context-critical.sh. FORCE SHUTDOWN SIGNAL written to ${FORCE_SIGNAL}. Escape hatches: (1) /rune:rest to free artifacts, (2) talisman: context_monitor.pretooluse_guard.enabled: false, (3) Explore/Plan agents remain available for read-only research." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason, additionalContext: $ctx}}' 2>/dev/null || true

exit 0
