#!/usr/bin/env bash
# test-stop-hook-self-heal.sh (AC-2 positive)
#
# Scenario: owned checkpoint present, state file absent. Stop hook GUARD 4
# self-heals by calling rune-arc-init-state.sh create --source hook --force
# and replays itself via exec to resume the arc loop.
#
# Expected outcome: state file exists after self-heal path; single-fire
# watchdog env var prevents infinite loops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Use $HOME-based tmp dir to avoid macOS /var/folders/... symlink rejection
# in rune-arc-init-state.sh's SEC symlink guard (it walks parent dirs for
# symlink components and /var/folders is a symlink to /private/var/folders).
TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR=$(mktemp -d "$TEST_HOME/rune-ac2pos-XXXXXX")
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

export CLAUDE_CONFIG_DIR="$TEST_DIR/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
cd "$TEST_DIR" || exit 1
git init -q 2>/dev/null || true
mkdir -p .rune/arc/arc-9876543210

ARC_ID="arc-9876543210"
SID="test-session-selfheal-$$"
cat > ".rune/arc/$ARC_ID/checkpoint.json" <<EOF
{
  "id": "$ARC_ID",
  "schema_version": 29,
  "plan_file": "plans/test.md",
  "config_dir": "$CLAUDE_CONFIG_DIR",
  "owner_pid": "$$",
  "session_id": "$SID",
  "session_nonce": "deadbeef1234",
  "started_at": "2026-04-18T00:00:00Z",
  "phases": { "forge": { "status": "pending" } }
}
EOF

# Sanity: state file absent
[[ ! -f ".rune/arc-phase-loop.local.md" ]] || { echo "FAIL: state file present at start"; exit 1; }

# Act: invoke resolve-owned-checkpoint subcommand (what Stop hook GUARD 4 uses)
export RUNE_SESSION_ID="$SID"
_resolved=$(bash "$PLUGIN_ROOT/scripts/rune-arc-init-state.sh" resolve-owned-checkpoint 2>/dev/null || true)

if [[ -z "$_resolved" ]]; then
  echo "FAIL: resolve-owned-checkpoint returned empty for owned checkpoint"
  exit 1
fi

# Verify it found OUR checkpoint
if [[ "$_resolved" != *"$ARC_ID"* ]]; then
  echo "FAIL: resolved checkpoint '$_resolved' does not contain arc ID '$ARC_ID'"
  exit 1
fi

# Simulate the self-heal: create --source hook --force
bash "$PLUGIN_ROOT/scripts/rune-arc-init-state.sh" create \
  --source hook \
  --kind phase \
  --checkpoint "$_resolved" \
  --force 2>/dev/null || { echo "FAIL: create --source hook --force failed"; exit 1; }

# Assert: state file exists
[[ -f ".rune/arc-phase-loop.local.md" ]] || { echo "FAIL: self-heal did not create state file"; exit 1; }

echo "PASS: AC-2 positive — Stop hook self-heal recreates state file from owned checkpoint"
