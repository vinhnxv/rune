#!/usr/bin/env bash
# guard-agent-teams-flag.sh
# ATD-002: Block all team operations when feature flag is not set.
# Matcher: TeamCreate (only)
# Behavior: fail-closed (SECURITY pattern)
set -euo pipefail
trap 'exit 2' ERR  # XVER-SEC-002 FIX: fail-closed from start for SECURITY hook
umask 077

# ERR trap: fail-closed — emit deny JSON on any unexpected error
trap 'cat <<'"'"'ERRDENY'"'"'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "ATD-002: guard-agent-teams-flag.sh crashed — fail-closed."
  }
}
ERRDENY
exit 2' ERR

# Fast path: feature flag is set
if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" == "1" ]]; then
  exit 0
fi

# Deny with clear instructions
cat <<'DENY'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "ATD-002: Agent Teams feature flag not set.",
    "additionalContext": "Agent Teams requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1. Add to .claude/settings.json or .claude/settings.local.json: { \"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" } }. See README.md for setup."
  }
}
DENY
