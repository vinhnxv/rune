#!/usr/bin/env bash
# STRIVE-001: Blocks direct Write/Edit on source files during arc work phase
# when no strive team has been created. Prevents the Tarnished from bypassing
# /rune:strive and implementing directly.
#
# Classification: SECURITY (fail-closed)
# Matcher: PreToolUse:Write|Edit
# Timeout: 5s
#
# Rationale: The Tarnished (orchestrator) must delegate implementation to
# /rune:strive workers. Direct implementation bypasses audit trail, quality
# gates, worker reports, and file ownership enforcement.

set -euo pipefail

# Fail-closed ERR trap (SECURITY classification)
trap 'echo "STRIVE-001: enforce-strive-delegation.sh crashed at line $LINENO" >&2; exit 2' ERR

# ── Fast-path exits ──

# Skip if no arc phase loop active
[ -f ".rune/arc-phase-loop.local.md" ] || exit 0

# Read hook input from stdin
INPUT=$(cat)

# Extract tool input (file path being written)
TARGET_FILE=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('toolInput', {}).get('file_path', '') or data.get('toolInput', {}).get('filePath', ''))
except: print('')
" 2>/dev/null)

# Skip if no target file
[ -z "$TARGET_FILE" ] && exit 0

# Skip if target is in tmp/ (artifacts, reports — not source files)
case "$TARGET_FILE" in
    tmp/*|.rune/*) exit 0 ;;
esac

# ── Check if arc work phase is in_progress ──

# Find the checkpoint path from the state file
CHECKPOINT_PATH=$(grep -o 'checkpoint_path: .*' .rune/arc-phase-loop.local.md 2>/dev/null | head -1 | sed 's/checkpoint_path: //')
[ -z "$CHECKPOINT_PATH" ] && exit 0
[ -f "$CHECKPOINT_PATH" ] || exit 0

# Check work phase status
WORK_STATUS=$(python3 -c "
import json
with open('$CHECKPOINT_PATH') as f:
    cp = json.load(f)
print(cp.get('phases', {}).get('work', {}).get('status', ''))
" 2>/dev/null)

[ "$WORK_STATUS" != "in_progress" ] && exit 0

# ── Work phase is in_progress — check if strive team exists ──

CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STRIVE_TEAM=$(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-work-*" -o -name "arc-work-*" \) 2>/dev/null | head -1)

if [ -z "$STRIVE_TEAM" ]; then
    # No strive team exists — check if target is a source file
    case "$TARGET_FILE" in
        plugins/*|src/*|lib/*|skills/*|agents/*|commands/*)
            # Block: direct write to source file without strive team
            echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"STRIVE-001: Direct implementation blocked during arc work phase. The Tarnished must delegate to /rune:strive — invoke Skill(\"rune:strive\", planPath) instead of writing files directly. No exceptions for documentation, markdown, or simple changes.","additionalContext":"STRIVE-001 DENIED: You are in arc Phase 5 (WORK) but have not invoked /rune:strive. Direct file edits are blocked. Call Skill(\"rune:strive\", ...) to spawn workers."}}'
            exit 0
            ;;
    esac
fi

# Strive team exists or target is not a source file — allow
exit 0
