#!/usr/bin/env bash
# scripts/validate-task-contract.sh
# TEAM-002: Validates Agent Teams Task Contract integrity.
# Detects: agents spawned without TaskCreate, agents missing TaskUpdate tools,
# wrong waitForCompletion signatures.
#
# Usage: bash plugins/rune/scripts/validate-task-contract.sh
# Exit: 0 if clean, 1 if violations found.
#
# Supports # TEAM-002-IGNORE: reason annotation in first 5 lines of any file
# to exempt it from checks. Use for reference docs that document Agent() patterns
# but delegate TaskCreate to their parent skill.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VIOLATIONS=0
CHECKED=0
WARNINGS=0
IGNORED=0

# --- Helpers ---

has_team002_ignore() {
  local file="$1"
  head -5 "$file" 2>/dev/null | grep -qE 'TEAM-002-IGNORE:' 2>/dev/null
}

violation() {
  local code="$1"
  shift
  printf "  [%s] %s\n" "$code" "$*"
  VIOLATIONS=$((VIOLATIONS + 1))
}

warning() {
  printf "  [WARN] %s\n" "$*"
  WARNINGS=$((WARNINGS + 1))
}

section() {
  printf "\n=== Check %s: %s ===\n" "$1" "$2"
}

# --- Check 1: Arc phase files — TaskCreate + waitForCompletion signature ---
section "1" "TaskCreate + waitForCompletion in arc phase orchestration files"

# Only scan arc-phase-*.md files (actual orchestration algorithms).
# Sub-reference files (worker-prompts.md, forge-gaze.md, etc.) contain Agent()
# patterns as templates but TaskCreate lives in their parent skill.
while IFS= read -r file; do
  CHECKED=$((CHECKED + 1))
  basename_file="$(basename "$file")"

  if has_team002_ignore "$file"; then
    IGNORED=$((IGNORED + 1))
    continue
  fi

  # Check if file has Agent() with team_name (pseudocode pattern)
  has_agent_team=false
  if grep -qE 'Agent\(\{' "$file" 2>/dev/null && grep -qE 'team_name:' "$file" 2>/dev/null; then
    has_agent_team=true
  fi

  if [ "$has_agent_team" = true ]; then
    # Check if TaskCreate appears in the file
    has_task_create=false
    if grep -qE 'TaskCreate\(' "$file" 2>/dev/null; then
      has_task_create=true
    fi

    if [ "$has_task_create" = false ]; then
      violation "TEAM-002-A" "$basename_file: Agent() with team_name but NO TaskCreate — monitoring will fail"
    fi

    # Check waitForCompletion signature — should be (teamName, count, opts) not ([names], opts)
    if grep -qE 'waitForCompletion\(\[' "$file" 2>/dev/null; then
      violation "TEAM-002-B" "$basename_file: Wrong waitForCompletion signature — uses array instead of (teamName, expectedCount, opts)"
    fi
  fi
done < <(find "$PLUGIN_DIR/skills/arc/references" -name "arc-phase-*.md" -type f 2>/dev/null)

# --- Check 1b: SKILL.md files that use Agent Teams directly ---
section "1b" "TaskCreate in SKILL.md files with Agent Teams"

while IFS= read -r file; do
  CHECKED=$((CHECKED + 1))
  skill_name="$(basename "$(dirname "$file")")"

  if has_team002_ignore "$file"; then
    IGNORED=$((IGNORED + 1))
    continue
  fi

  has_agent_team=false
  if grep -qE 'Agent\(\{' "$file" 2>/dev/null && grep -qE 'team_name:' "$file" 2>/dev/null; then
    has_agent_team=true
  fi

  if [ "$has_agent_team" = true ]; then
    has_task_create=false
    if grep -qE 'TaskCreate\(' "$file" 2>/dev/null; then
      has_task_create=true
    fi

    if [ "$has_task_create" = false ]; then
      # Skills may delegate TaskCreate to reference files — warn, not violation
      warning "$skill_name/SKILL.md: Agent() with team_name but no TaskCreate — verify it's in a reference file"
    fi

    if grep -qE 'waitForCompletion\(\[' "$file" 2>/dev/null; then
      violation "TEAM-002-B" "$skill_name/SKILL.md: Wrong waitForCompletion signature"
    fi
  fi
done < <(find "$PLUGIN_DIR/skills" -name "SKILL.md" -type f 2>/dev/null)

# --- Check 2: Agents used in teams must have TaskUpdate ---
section "2" "TaskUpdate in agent tools (team-context agents)"

# Directories where ALL agents are spawned as teammates
TEAM_AGENT_DIRS=(
  "$PLUGIN_DIR/agents/testing"
  "$PLUGIN_DIR/agents/work"
)

for dir in "${TEAM_AGENT_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then continue; fi

  while IFS= read -r agent_file; do
    CHECKED=$((CHECKED + 1))
    agent_name="$(basename "$agent_file" .md)"

    if has_team002_ignore "$agent_file"; then
      IGNORED=$((IGNORED + 1))
      continue
    fi

    has_task_update=false
    if grep -qE '^\s*-\s*TaskUpdate' "$agent_file" 2>/dev/null; then
      has_task_update=true
    fi

    if [ "$has_task_update" = false ]; then
      violation "TEAM-002-C" "$agent_name: Missing TaskUpdate in tools — cannot mark task completion"
    fi

    has_task_list=false
    if grep -qE '^\s*-\s*TaskList' "$agent_file" 2>/dev/null; then
      has_task_list=true
    fi

    if [ "$has_task_list" = false ]; then
      warning "$agent_name: Missing TaskList in tools — cannot discover assigned tasks"
    fi
  done < <(find "$dir" -name "*.md" -type f 2>/dev/null)
done

# --- Check 2b: Utility agents used in arc plan review Layer 1 ---
section "2b" "Plan review utility agents (arc Phase 2 Layer 1)"

PLAN_REVIEW_AGENTS=(
  "scroll-reviewer"
  "decree-arbiter"
  "knowledge-keeper"
  "veil-piercer-plan"
  "horizon-sage"
  "evidence-verifier"
  "state-weaver"
)

for agent_name in "${PLAN_REVIEW_AGENTS[@]}"; do
  agent_file="$PLUGIN_DIR/agents/utility/${agent_name}.md"
  if [ ! -f "$agent_file" ]; then continue; fi

  CHECKED=$((CHECKED + 1))

  has_task_update=false
  if grep -qE '^\s*-\s*TaskUpdate' "$agent_file" 2>/dev/null; then
    has_task_update=true
  fi

  if [ "$has_task_update" = false ]; then
    violation "TEAM-002-C" "$agent_name (utility, plan-review): Missing TaskUpdate in tools"
  fi
done

# --- Check 3: Inspect agents (plan review Layer 2) ---
section "3" "Inspect agents (plan review Layer 2)"

INSPECT_AGENTS=(
  "grace-warden"
  "ruin-prophet"
  "sight-oracle"
  "vigil-keeper"
)

for agent_name in "${INSPECT_AGENTS[@]}"; do
  agent_file="$PLUGIN_DIR/agents/investigation/${agent_name}.md"
  if [ ! -f "$agent_file" ]; then
    agent_file="$PLUGIN_DIR/agents/utility/${agent_name}.md"
  fi
  if [ ! -f "$agent_file" ]; then continue; fi

  CHECKED=$((CHECKED + 1))

  has_task_update=false
  if grep -qE '^\s*-\s*TaskUpdate' "$agent_file" 2>/dev/null; then
    has_task_update=true
  fi

  if [ "$has_task_update" = false ]; then
    warning "$agent_name (inspect): Missing TaskUpdate — check if needed for Layer 2 team context"
  fi
done

# --- Summary ---
printf "\n─────────────────────────────────────────\n"
printf "Task Contract Validation (TEAM-002)\n"
printf "  Checked: %d files\n" "$CHECKED"
printf "  Violations: %d\n" "$VIOLATIONS"
printf "  Warnings: %d\n" "$WARNINGS"
printf "  Ignored: %d (TEAM-002-IGNORE)\n" "$IGNORED"
printf "─────────────────────────────────────────\n"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf "\nFAILED: %d TEAM-002 violation(s) found.\n" "$VIOLATIONS"
  printf "Fix: See CLAUDE.md Rule 13 (Iron Law TEAM-002) for the 3-component contract.\n"
  printf "Suppress false positives: Add '# TEAM-002-IGNORE: reason' in first 5 lines.\n"
  exit 1
else
  printf "\nPASSED: No TEAM-002 violations.\n"
  exit 0
fi
