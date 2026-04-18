#!/usr/bin/env bash
# test-state-file-compact-survival.sh (AC-7)
#
# Scenario: compact happens mid-arc. pre-compact-checkpoint.sh snapshots
# state file content into arc_state_files field of compact checkpoint.
# session-compact-recovery.sh re-derives missing state file via
# rune-arc-init-state.sh create --source hook --force.
#
# Expected outcome: state file exists post-compact with current session
# identity (re-derived, not blind-copy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR=$(mktemp -d "$TEST_HOME/rune-ac7-XXXXXX")
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

export CLAUDE_CONFIG_DIR="$TEST_DIR/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
cd "$TEST_DIR" || exit 1
git init -q 2>/dev/null || true

# Setup: active arc with state file + checkpoint
ARC_ID="arc-$(date +%s)888"
mkdir -p ".rune/arc/$ARC_ID" tmp
SID="test-compact-session-$$"

cat > ".rune/arc/$ARC_ID/checkpoint.json" <<EOF
{
  "id": "$ARC_ID",
  "schema_version": 29,
  "plan_file": "plans/compact-test.md",
  "config_dir": "$CLAUDE_CONFIG_DIR",
  "owner_pid": "$$",
  "session_id": "$SID",
  "session_nonce": "99aabbccddee",
  "started_at": "2026-04-18T00:00:00Z",
  "phases": { "forge": { "status": "pending" } }
}
EOF

# Step 1: Create initial state file (pre-compact)
cat > ".rune/arc-phase-loop.local.md" <<EOF
---
active: true
iteration: 5
checkpoint_path: .rune/arc/$ARC_ID/checkpoint.json
plan_file: plans/compact-test.md
branch: compact-test
owner_pid: $$
session_id: $SID
config_dir: $CLAUDE_CONFIG_DIR
---
EOF

# Step 2: Simulate pre-compact snapshot — write compact checkpoint with
# arc_state_files containing state file content (this is what
# pre-compact-checkpoint.sh does)
_state_content=$(cat ".rune/arc-phase-loop.local.md")
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

jq -n \
  --arg cfg "$CLAUDE_CONFIG_DIR" \
  --arg pid "$$" \
  --arg sid "$SID" \
  --arg state "$_state_content" \
  '{
    team_name: "",
    saved_at: "2026-04-18T01:00:00Z",
    config_dir: $cfg,
    owner_pid: $pid,
    team_config: {},
    tasks: [],
    workflow_state: {},
    arc_checkpoint: {},
    arc_batch_state: {},
    arc_issues_state: {},
    arc_phase_summaries: {},
    arc_state_files: { phase: $state }
  }' > "tmp/.rune-compact-checkpoint.json"

# Step 3: Delete state file (simulating compaction clearing it)
rm -f ".rune/arc-phase-loop.local.md"
[[ ! -f ".rune/arc-phase-loop.local.md" ]] || { echo "FAIL: couldn't remove pre-state file"; exit 1; }

# Step 4: Simulate re-derivation path from session-compact-recovery.sh
# (invoke create --source hook --force as the recovery script does)
export RUNE_SESSION_ID="$SID"
bash "$PLUGIN_ROOT/scripts/rune-arc-init-state.sh" create \
  --source hook \
  --kind phase \
  --checkpoint "$(pwd)/.rune/arc/$ARC_ID/checkpoint.json" \
  --force 2>/dev/null || { echo "FAIL: re-derivation failed"; exit 1; }

# Step 5: Assert state file exists post-compact
[[ -f ".rune/arc-phase-loop.local.md" ]] || {
  echo "FAIL: state file not restored post-compact"; exit 1
}

# Step 6: Verify identity is CURRENT (not stale blind-copy)
_post_sid=$(sed -n 's/^session_id: //p' ".rune/arc-phase-loop.local.md" | head -1)
_post_pid=$(sed -n 's/^owner_pid: //p' ".rune/arc-phase-loop.local.md" | head -1)

if [[ "$_post_sid" != "$SID" ]]; then
  echo "FAIL: post-compact session_id '$_post_sid' != expected '$SID'"
  exit 1
fi
if [[ "$_post_pid" != "$$" ]]; then
  echo "FAIL: post-compact owner_pid '$_post_pid' != current '$$'"
  exit 1
fi

echo "PASS: AC-7 compaction state file survival via re-derivation with current session identity"
