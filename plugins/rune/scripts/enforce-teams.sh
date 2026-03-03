#!/bin/bash
# scripts/enforce-teams.sh
# ATE-1: Enforce Agent Teams usage during active Rune multi-agent workflows.
# Blocks bare Agent/Task calls (without team_name) when an arc/review/audit/work
# workflow is active. Prevents context explosion from subagent output flowing
# into the orchestrator's context window.
#
# NOTE: Claude Code 2.1.63 renamed the "Task" tool to "Agent". This script
# handles both names for backward compatibility.
#
# Detection strategy:
#   1. Check if tool_name is "Task" or "Agent" (only tools this hook targets)
#   2. Check for active Rune workflow via state files:
#      - .claude/arc/*/checkpoint.json with "in_progress" phase
#      - tmp/.rune-review-*.json with "active" status
#      - tmp/.rune-audit-*.json with "active" status
#      - tmp/.rune-work-*.json with "active" status
#      - tmp/.rune-inspect-*.json with "active" status
#      - tmp/.rune-mend-*.json with "active" status
#      - tmp/.rune-plan-*.json with "active" status
#      - tmp/.rune-forge-*.json with "active" status
#      - tmp/.rune-brainstorm-*.json with "active" status
#   3. If active workflow found, verify Task input includes team_name
#   4. Block if team_name missing — output deny JSON
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  # BACK-003 FIX: Always emit stderr warning for enforcement hooks.
  # Silent fail-forward in a security-adjacent hook masks mid-validation crashes.
  printf 'WARNING: %s: ERR trap — fail-forward activated (line %s). ATE-1 check skipped.\n' \
    "${BASH_SOURCE[0]##*/}" \
    "${BASH_LINENO[0]:-?}" \
    >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    # SEC-004 FIX: Use ${UID} shell builtin to avoid subprocess fork
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Pre-flight: jq is required for JSON parsing.
# If missing, exit 0 (non-blocking) — allow rather than crash.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — enforce-teams.sh hook is inactive" >&2
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read

# Fast path: if caller is team-lead (not subagent), check for team_name in input.
# Team leads MUST also use team_name — this is the whole point of ATE-1.
# Note: Claude Code 2.1.63 renamed Task → Agent. Both are checked below.

# BACK-003 FIX: Use printf instead of echo to avoid flag interpretation if $INPUT starts with '-'
# Claude Code 2.1.63+ renamed "Task" → "Agent". Match both for backward compat.
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Task" && "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

# QUAL-5: Canonicalize CWD to resolve symlinks (matches on-task-completed.sh pattern)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# Check for active Rune workflows
# NOTE: File-based state detection has inherent TOCTOU window (SEC-3). A workflow
# could start between this check and the Task executing. Claude Code processes tool
# calls sequentially within a session, making the race window effectively zero.
#
# STALENESS GUARD (v1.61.0): Skip files older than 30 minutes (mtime-based).
# Stale checkpoints from crashed/interrupted sessions should not block new work.
# Mirrors the 30-min threshold from enforce-team-lifecycle.sh (TLC-001).
STALE_THRESHOLD_MIN=30
active_workflow=""

# ── Session identity for cross-session ownership filtering ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-session-identity.sh
# SEC-001/VEIL-005 FIX: Guard against missing resolve-session-identity.sh.
# Without this guard, a missing file triggers the ERR trap which exits 0,
# leaving RUNE_CURRENT_CFG unset and silently allowing bare Agent/Task calls.
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  # File missing — log warning and set safe defaults
  printf '[%s] enforce-teams.sh: resolve-session-identity.sh not found at %s — ownership filtering disabled\n' \
    "$(date +%H:%M:%S 2>/dev/null || true)" "${SCRIPT_DIR}" >&2
  RUNE_CURRENT_CFG=""
  rune_pid_alive() { return 1; }  # treat all PIDs as dead (conservative: own everything)
fi

# Check arc checkpoints (skip stale files older than STALE_THRESHOLD_MIN)
if [[ -d "${CWD}/.claude/arc" ]]; then
  while IFS= read -r f; do
    if jq -e '(.phase_status // .phase // .status // "none" | . == "in_progress") or ([.phases[]?.status] | any(. == "in_progress"))' "$f" &>/dev/null; then
      # ── Ownership filter: skip checkpoints from other sessions ──
      stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # VEIL-007 FIX: Guard against empty RUNE_CURRENT_CFG — when identity script is missing,
      # "$stored_cfg" != "" is always true for any non-empty stored_cfg → skip ALL files.
      if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        rune_pid_alive "$stored_pid" && continue  # alive = different session
      fi
      active_workflow=1
      break
    fi
  done < <(find "${CWD}/.claude/arc" -name checkpoint.json -maxdepth 2 -type f -mmin -${STALE_THRESHOLD_MIN} 2>/dev/null)
fi

# Check review/audit/work state files (skip stale files)
# SEC-1 FIX: Use nullglob + flattened loop to prevent word splitting on paths with spaces
if [[ -z "$active_workflow" ]]; then
  shopt -s nullglob
  for f in "${CWD}"/tmp/.rune-review-*.json "${CWD}"/tmp/.rune-audit-*.json \
           "${CWD}"/tmp/.rune-work-*.json "${CWD}"/tmp/.rune-inspect-*.json \
           "${CWD}"/tmp/.rune-mend-*.json "${CWD}"/tmp/.rune-plan-*.json \
           "${CWD}"/tmp/.rune-forge-*.json "${CWD}"/tmp/.rune-goldmask-*.json \
           "${CWD}"/tmp/.rune-brainstorm-*.json; do
    # Skip files older than STALE_THRESHOLD_MIN minutes
    if [[ -f "$f" ]] && find "$f" -maxdepth 0 -mmin -${STALE_THRESHOLD_MIN} -print -quit 2>/dev/null | grep -q . && jq -e '.status == "active"' "$f" &>/dev/null; then
      # ── Ownership filter: skip state files from other sessions ──
      stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # VEIL-007 FIX: Guard against empty RUNE_CURRENT_CFG (see arc checkpoint block above)
      if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        rune_pid_alive "$stored_pid" && continue  # alive = different session
      fi
      active_workflow=1
      break
    fi
  done
  shopt -u nullglob
fi

# No active workflow — allow all Agent/Task calls
if [[ -z "$active_workflow" ]]; then
  exit 0
fi

# Active workflow detected — verify Agent/Task input includes team_name
# BACK-2 FIX: Single-pass jq extraction (avoids fragile double-parse of tool_input)
HAS_TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r 'if .tool_input.team_name and (.tool_input.team_name | length > 0) then "yes" else "no" end' 2>/dev/null || echo "no")

if [[ "$HAS_TEAM_NAME" == "yes" ]]; then
  exit 0
fi

# ATE-1 EXEMPTION: Read-only built-in subagent types are safe without team_name.
# Explore (Haiku, read-only) and Plan (read-only) agents produce bounded output
# and cannot modify files — no risk of context explosion. The orchestrator needs
# these for quick codebase queries during workflow phases.
SUBAGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
if [[ "$SUBAGENT_TYPE" == "Explore" || "$SUBAGENT_TYPE" == "Plan" ]]; then
  exit 0
fi

# ATE-1 VIOLATION: Agent/Task call without team_name during active workflow
# Output deny decision with actionable feedback
cat << 'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "ATE-1: Bare Agent call blocked during active Rune workflow. All multi-agent phases MUST use Agent Teams. Add team_name to your Agent call. Example: Agent({ team_name: 'arc-forge-{id}', name: 'agent-name', subagent_type: 'general-purpose', ... }). See arc skill (skills/arc/SKILL.md) 'CRITICAL — Agent Teams Enforcement' section.",
    "additionalContext": "BLOCKED by enforce-teams.sh hook. You MUST create a team with TeamCreate first, then pass team_name to all Agent calls. Using bare subagent types like 'rune:utility:scroll-reviewer' or 'other-plugin:some-agent-type' as subagent_type bypasses Agent Teams and causes context explosion. Always use subagent_type: 'general-purpose' and inject agent identity via the prompt parameter."
  }
}
DENY_JSON
exit 0
