#!/usr/bin/env bash
# Form automation template: locate -> fill -> submit -> verify
# Usage: Adapt this pattern — do not execute directly
set -euo pipefail

URL="${1:?Usage: provide form URL}"

# Cleanup on exit
trap 'agent-browser close 2>/dev/null' EXIT

agent-browser open "$URL"
agent-browser wait --load networkidle
agent-browser snapshot -i

# Find inputs by semantic locators (preferred over @e refs for forms)
agent-browser find label "Email"       # -> @e3
agent-browser find label "Password"    # -> @e4
agent-browser find role/button "Submit" # -> @e5

# Fill and submit
# SEC-003 fix: use env vars for credentials — NEVER commit real credentials
agent-browser fill @e3 "${TEST_EMAIL:-test@example.com}"
agent-browser fill @e4 "${TEST_PASSWORD:?Set TEST_PASSWORD env var}"
agent-browser click @e5

# Wait for submission and verify
agent-browser wait --load networkidle
agent-browser snapshot -i

# Check for success indicator or error messages
agent-browser find text "Welcome"  # success -> found
# agent-browser find text "Invalid" # error -> found = test failure

agent-browser close
echo "Form automation complete"
