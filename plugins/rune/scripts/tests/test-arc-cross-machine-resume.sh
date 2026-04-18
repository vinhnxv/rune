#!/usr/bin/env bash
# test-arc-cross-machine-resume.sh (AC-1)
#
# Scenario: checkpoint present, state file absent. Skill --resume invokes
# rune-arc-init-state.sh create --source skill, which hydrates the state
# file from the owned checkpoint.
#
# Expected outcome: state file exists after skill resume bootstrap call,
# with identity fields matching the checkpoint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR=$(mktemp -d "$TEST_HOME/rune-ac1-XXXXXX")
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

# Source platform helpers
# shellcheck source=../lib/platform.sh
source "$PLUGIN_ROOT/scripts/lib/platform.sh"

# Set up sandbox
export CLAUDE_CONFIG_DIR="$TEST_DIR/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
cd "$TEST_DIR" || { echo "FAIL: cannot cd to $TEST_DIR"; exit 1; }
git init -q 2>/dev/null || true
mkdir -p .rune/arc/arc-1234567890

# Create a valid checkpoint owned by current session
ARC_ID="arc-1234567890"
SID="test-session-$$"
cat > ".rune/arc/$ARC_ID/checkpoint.json" <<EOF
{
  "id": "$ARC_ID",
  "schema_version": 29,
  "plan_file": "plans/test-plan.md",
  "config_dir": "$CLAUDE_CONFIG_DIR",
  "owner_pid": "$$",
  "session_id": "$SID",
  "session_nonce": "abcdef012345",
  "started_at": "2026-04-18T00:00:00Z",
  "phases": { "forge": { "status": "pending" } }
}
EOF

# Sanity: state file must NOT exist
[[ ! -f ".rune/arc-phase-loop.local.md" ]] || { echo "FAIL: state file exists before test"; exit 1; }

# Act: simulate skill resume bootstrap
export RUNE_SESSION_ID="$SID"
bash "$PLUGIN_ROOT/scripts/rune-arc-init-state.sh" create \
  --source skill \
  --kind phase \
  --checkpoint "$(pwd)/.rune/arc/$ARC_ID/checkpoint.json" 2>/dev/null || true

# Assert: state file exists with matching identity within 2 seconds
for _i in 1 2 3 4; do
  [[ -f ".rune/arc-phase-loop.local.md" ]] && break
  sleep 0.5
done

if [[ ! -f ".rune/arc-phase-loop.local.md" ]]; then
  echo "FAIL: state file not created by skill resume bootstrap"
  exit 1
fi

# Verify identity fields match checkpoint
_state_sid=$(sed -n 's/^session_id: //p' ".rune/arc-phase-loop.local.md" | head -1)
_state_pid=$(sed -n 's/^owner_pid: //p' ".rune/arc-phase-loop.local.md" | head -1)

if [[ "$_state_sid" != "$SID" ]]; then
  echo "FAIL: state session_id '$_state_sid' != checkpoint session_id '$SID'"
  exit 1
fi

if [[ "$_state_pid" != "$$" ]]; then
  echo "FAIL: state owner_pid '$_state_pid' != current PID '$$'"
  exit 1
fi

echo "PASS: AC-1 cross-machine resume hydrates state file with matching identity"
