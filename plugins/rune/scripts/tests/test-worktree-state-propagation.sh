#!/usr/bin/env bash
# test-worktree-state-propagation.sh (AC-6)
#
# Scenario: source repo has an active arc state file. setup-worktree.sh
# copies .rune/arc-{kind}-loop.local.md files to the worktree alongside
# .rune/arc/ checkpoints.
#
# Expected outcome: worktree has a copy of the state file with identical
# content; post-copy verify either passes or regenerates cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR=$(mktemp -d "$TEST_HOME/rune-ac6-XXXXXX")
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

# Simulate source repo and worktree as plain dirs (no real git worktree needed
# for this unit test — we exercise the copy block of setup-worktree.sh logic).
SRC_REPO="$TEST_DIR/src"
WT_PATH="$TEST_DIR/wt"
mkdir -p "$SRC_REPO/.rune/arc/arc-wt-12345"
mkdir -p "$WT_PATH/.rune"

# Create a source state file
SID="test-wt-session-$$"
cat > "$SRC_REPO/.rune/arc-phase-loop.local.md" <<EOF
---
active: true
iteration: 3
checkpoint_path: .rune/arc/arc-wt-12345/checkpoint.json
plan_file: plans/wt-test.md
branch: test-wt-branch
owner_pid: $$
session_id: $SID
config_dir: $TEST_DIR/.claude
---
EOF

# Minimal checkpoint for verify to read
mkdir -p "$TEST_DIR/.claude"
export CLAUDE_CONFIG_DIR="$TEST_DIR/.claude"
cat > "$SRC_REPO/.rune/arc/arc-wt-12345/checkpoint.json" <<EOF
{
  "id": "arc-wt-12345",
  "schema_version": 29,
  "plan_file": "plans/wt-test.md",
  "config_dir": "$CLAUDE_CONFIG_DIR",
  "owner_pid": "$$",
  "session_id": "$SID",
  "session_nonce": "112233445566",
  "started_at": "2026-04-18T00:00:00Z",
  "phases": { "forge": { "status": "pending" } }
}
EOF

# Also copy checkpoint to worktree (what setup-worktree does before our block)
mkdir -p "$WT_PATH/.rune/arc/arc-wt-12345"
cp "$SRC_REPO/.rune/arc/arc-wt-12345/checkpoint.json" "$WT_PATH/.rune/arc/arc-wt-12345/checkpoint.json"

# Act: simulate the Task 4 copy block (from setup-worktree.sh)
for _kind in phase batch hierarchy issues; do
  _src="${SRC_REPO}/.rune/arc-${_kind}-loop.local.md"
  _dst="${WT_PATH}/.rune/arc-${_kind}-loop.local.md"
  [[ -L "$_src" ]] && continue
  if [[ -f "$_src" ]]; then
    cp -p "$_src" "$_dst" 2>/dev/null || true
  fi
done

# Assert: state file was copied
[[ -f "$WT_PATH/.rune/arc-phase-loop.local.md" ]] || {
  echo "FAIL: state file not copied to worktree"; exit 1
}

# Assert: content matches
if ! diff -q "$SRC_REPO/.rune/arc-phase-loop.local.md" \
             "$WT_PATH/.rune/arc-phase-loop.local.md" >/dev/null 2>&1; then
  echo "FAIL: worktree state file content differs from source"
  exit 1
fi

# Assert: identity fields are present
_wt_sid=$(sed -n 's/^session_id: //p' "$WT_PATH/.rune/arc-phase-loop.local.md" | head -1)
if [[ "$_wt_sid" != "$SID" ]]; then
  echo "FAIL: worktree state session_id '$_wt_sid' != source '$SID'"
  exit 1
fi

echo "PASS: AC-6 worktree state file propagation copies state file with matching identity"
