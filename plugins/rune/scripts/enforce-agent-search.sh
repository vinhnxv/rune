#!/bin/bash
# scripts/enforce-agent-search.sh
# AGENT-SEARCH-001: Advisory hook that detects when LLM spawns a Rune teammate
# WITHOUT calling agent_search() first. Injects additionalContext reminder.
#
# Detection logic:
#   1. Fast-path: skip if not Agent/Task tool
#   2. Fast-path: skip if no team_name or team_name doesn't start with rune-/arc-
#   3. Fast-path: skip if no active Rune workflow (no inscription.json)
#   4. Check for signal file tmp/.rune-signals/.agent-search-called
#   5. If signal MISSING → inject advisory via additionalContext
#   6. If signal EXISTS → pass through silently
#
# Classification: OPERATIONAL (fail-forward)
# Exit behavior: always exit 0 — NEVER blocks agent spawning.
# Advisory only — if MCP server is down, LLM still uses agents/ enum normally.

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
_rune_fail_forward() {
  printf 'WARNING: %s: ERR trap — fail-forward activated (line %s). Agent search check skipped.\n' \
    "${BASH_SOURCE[0]##*/}" \
    "${BASH_LINENO[0]:-?}" \
    >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Pre-flight: jq required
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap

TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
# Accept both Task (pre-2.1.63) and Agent (2.1.63+)
if [[ "$TOOL_NAME" != "Agent" && "$TOOL_NAME" != "Task" ]]; then
  exit 0
fi

CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi

# Fast-path: Check team_name — only enforce for Rune teams
TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || true)
if [[ -z "$TEAM_NAME" ]]; then
  # No team_name — could be bare subagent (enforce-teams.sh handles that)
  exit 0
fi
if [[ "$TEAM_NAME" != rune-* && "$TEAM_NAME" != arc-* ]]; then
  # Not a Rune team — pass through (plugin coexistence)
  exit 0
fi

# Fast-path: Check for active Rune workflow
# Look for any inscription.json in known output dirs
HAS_WORKFLOW=false
for dir in "$CWD"/tmp/reviews "$CWD"/tmp/audit "$CWD"/tmp/work "$CWD"/tmp/inspect "$CWD"/tmp/mend "$CWD"/tmp/goldmask; do
  if [[ -d "$dir" ]]; then
    # Check for any inscription.json in subdirectories (no subprocess fork)
    shopt -s nullglob
    for f in "$dir"/*/inscription.json; do
      if [[ -f "$f" ]]; then
        HAS_WORKFLOW=true
        break 2
      fi
    done
    shopt -u nullglob
  fi
done

# Also check state files
if [[ "$HAS_WORKFLOW" != "true" ]]; then
  shopt -s nullglob
  for f in "$CWD"/tmp/.rune-*.json; do
    if [[ -f "$f" ]]; then
      HAS_WORKFLOW=true
      break
    fi
  done
  shopt -u nullglob
fi

if [[ "$HAS_WORKFLOW" != "true" ]]; then
  # No active Rune workflow — skip check
  exit 0
fi

# Check signal file — was agent_search() called this phase?
SIGNAL_FILE="$CWD/tmp/.rune-signals/.agent-search-called"
if [[ -f "$SIGNAL_FILE" ]]; then
  # agent_search() was called — pass through
  exit 0
fi

# Check if agent-search MCP server is running
# If not available, suppress warning (LLM can't call it anyway)
AGENT_SEARCH_PID_FILE="${TMPDIR:-/tmp}/rune-agent-search-$(id -u).pid"
if [[ -f "$AGENT_SEARCH_PID_FILE" ]]; then
  AGENT_SEARCH_PID=$(cat "$AGENT_SEARCH_PID_FILE" 2>/dev/null || true)
  if [[ -n "$AGENT_SEARCH_PID" && "$AGENT_SEARCH_PID" =~ ^[0-9]+$ ]] && ! kill -0 "$AGENT_SEARCH_PID" 2>/dev/null; then
    # MCP server not running — suppress warning
    exit 0
  fi
fi

# Signal MISSING + workflow active + Rune team → inject advisory
AGENT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.subagent_type // .tool_input.name // "unknown"' 2>/dev/null || true)

# Emit advisory via additionalContext (non-blocking) — SEC-003: use jq --arg for safe JSON construction
jq -n \
  --arg agent_name "$AGENT_NAME" \
  --arg team_name "$TEAM_NAME" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: ("AGENT-SEARCH-001: You are spawning teammate \u0027" + $agent_name + "\u0027 for team \u0027" + $team_name + "\u0027 without calling agent_search() first. Extended agents (registry/) and user-defined agents (talisman.yml user_agents) will be missed. Consider calling agent_search(query, phase) via the agent-search MCP server to discover the best agents for this task, then spawn from the results. If the MCP server is unavailable, this warning can be ignored.")}}'

exit 0
