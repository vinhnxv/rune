#!/usr/bin/env bash
# Authenticated browser session template for Rune arc test phase
# Usage: Adapt this pattern — do not execute directly
set -euo pipefail

URL="${1:?Usage: provide URL}"
SESSION="arc-e2e-${2:-$(date +%s)}"
AUTH_PROFILE="${3:-default}"

# Cleanup on exit (ALWAYS — even on failure)
trap 'agent-browser close 2>/dev/null' EXIT

# Auth: restore saved state (fastest) or login via vault
agent-browser --session-name "$SESSION" open "$URL"
if ! agent-browser state restore "auth-${AUTH_PROFILE}.json" 2>/dev/null; then
  agent-browser auth login --name "$AUTH_PROFILE" || {
    echo "ERROR: Auth failed for profile $AUTH_PROFILE" >&2
    exit 1
  }
fi

agent-browser wait --load networkidle
agent-browser snapshot -i

# --- Test interactions go here ---
# agent-browser click @e3
# agent-browser fill @e5 "test data"
# agent-browser wait --load networkidle
# agent-browser snapshot -i
# agent-browser screenshot "evidence.png"

echo "Session $SESSION authenticated and ready"
