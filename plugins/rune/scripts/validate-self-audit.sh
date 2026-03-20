#!/usr/bin/env bash
# scripts/validate-self-audit.sh
# Validates self-audit infrastructure integrity with 6 deterministic checks.
# Detects: missing agents, orphaned echo role, broken talisman config,
# missing frontmatter fields, TRUTHBINDING gaps, and CLAUDE.md drift.
#
# Usage: bash plugins/rune/scripts/validate-self-audit.sh
# Exit: 0 if clean, 1 if violations found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"

VIOLATIONS=0
CHECKED=0
PASSED=0

# --- Helpers ---

violation() {
  local code="$1"
  shift
  printf "  [%s] FAIL: %s\n" "$code" "$*"
  VIOLATIONS=$((VIOLATIONS + 1))
}

pass() {
  local code="$1"
  shift
  printf "  [%s] PASS: %s\n" "$code" "$*"
  PASSED=$((PASSED + 1))
}

section() {
  printf "\n=== Check %s: %s ===\n" "$1" "$2"
}

# --- Check 1: Required meta-qa agents exist ---
section "1" "Meta-QA agent existence"

REQUIRED_AGENTS=(
  "workflow-auditor"
  "prompt-linter"
  "rule-consistency-auditor"
  "hook-integrity-auditor"
)

for agent in "${REQUIRED_AGENTS[@]}"; do
  CHECKED=$((CHECKED + 1))
  agent_file="$PLUGIN_DIR/agents/meta-qa/${agent}.md"
  if [[ -f "$agent_file" ]]; then
    pass "SA-EXIST-${CHECKED}" "Agent ${agent}.md exists"
  else
    violation "SA-EXIST-${CHECKED}" "Required agent missing: agents/meta-qa/${agent}.md"
  fi
done

# --- Check 2: Agent frontmatter completeness ---
section "2" "Agent frontmatter required fields"

REQUIRED_FIELDS=("name" "description" "tools" "maxTurns" "source" "priority" "primary_phase" "categories" "tags")

for agent_file in "$PLUGIN_DIR"/agents/meta-qa/*.md; do
  [[ -f "$agent_file" ]] || continue
  agent_name="$(basename "$agent_file" .md)"

  for field in "${REQUIRED_FIELDS[@]}"; do
    CHECKED=$((CHECKED + 1))
    # Check within YAML frontmatter (between --- delimiters)
    if head -50 "$agent_file" | grep -qE "^${field}:" 2>/dev/null; then
      pass "SA-FM-${CHECKED}" "${agent_name}: has ${field}"
    else
      violation "SA-FM-${CHECKED}" "${agent_name}: missing frontmatter field '${field}'"
    fi
  done
done

# --- Check 3: TRUTHBINDING anchors in all meta-qa agents ---
section "3" "TRUTHBINDING ANCHOR/RE-ANCHOR presence"

for agent_file in "$PLUGIN_DIR"/agents/meta-qa/*.md; do
  [[ -f "$agent_file" ]] || continue
  agent_name="$(basename "$agent_file" .md)"

  CHECKED=$((CHECKED + 1))
  if grep -q "## ANCHOR" "$agent_file" 2>/dev/null; then
    pass "SA-TRUTH-A-${CHECKED}" "${agent_name}: has ANCHOR"
  else
    violation "SA-TRUTH-A-${CHECKED}" "${agent_name}: missing ## ANCHOR section"
  fi

  CHECKED=$((CHECKED + 1))
  if grep -q "## RE-ANCHOR" "$agent_file" 2>/dev/null; then
    pass "SA-TRUTH-R-${CHECKED}" "${agent_name}: has RE-ANCHOR"
  else
    violation "SA-TRUTH-R-${CHECKED}" "${agent_name}: missing ## RE-ANCHOR section"
  fi
done

# --- Check 4: Self-audit SKILL.md exists and has required sections ---
section "4" "Self-audit skill structure"

SKILL_FILE="$PLUGIN_DIR/skills/self-audit/SKILL.md"
CHECKED=$((CHECKED + 1))
if [[ -f "$SKILL_FILE" ]]; then
  pass "SA-SKILL-1" "SKILL.md exists"
else
  violation "SA-SKILL-1" "Missing: skills/self-audit/SKILL.md"
fi

REQUIRED_REFS=(
  "references/aggregation.md"
)

for ref in "${REQUIRED_REFS[@]}"; do
  CHECKED=$((CHECKED + 1))
  ref_path="$PLUGIN_DIR/skills/self-audit/${ref}"
  if [[ -f "$ref_path" ]]; then
    pass "SA-SKILL-REF-${CHECKED}" "Reference file exists: ${ref}"
  else
    violation "SA-SKILL-REF-${CHECKED}" "Missing reference file: ${ref}"
  fi
done

# --- Check 5: Meta-QA echo role exists ---
section "5" "Echo role infrastructure"

ECHO_FILE="$REPO_DIR/.rune/echoes/meta-qa/MEMORY.md"
CHECKED=$((CHECKED + 1))
if [[ -f "$ECHO_FILE" ]]; then
  pass "SA-ECHO-1" "Meta-QA echo MEMORY.md exists"
else
  violation "SA-ECHO-1" "Missing: .rune/echoes/meta-qa/MEMORY.md"
fi

# Check echo routing in on-task-observation.sh
OBS_SCRIPT="$PLUGIN_DIR/scripts/on-task-observation.sh"
CHECKED=$((CHECKED + 1))
if [[ -f "$OBS_SCRIPT" ]] && grep -q 'meta-qa' "$OBS_SCRIPT" 2>/dev/null; then
  pass "SA-ECHO-2" "Echo routing for meta-qa exists in on-task-observation.sh"
else
  violation "SA-ECHO-2" "Missing meta-qa routing in on-task-observation.sh"
fi

# --- Check 6: CLAUDE.md and talisman references ---
section "6" "CLAUDE.md and talisman integration"

CLAUDE_MD="$PLUGIN_DIR/CLAUDE.md"
CHECKED=$((CHECKED + 1))
if grep -q 'self-audit' "$CLAUDE_MD" 2>/dev/null; then
  pass "SA-INTEG-1" "self-audit referenced in CLAUDE.md Skills table"
else
  violation "SA-INTEG-1" "self-audit missing from CLAUDE.md"
fi

# Check talisman example has self_audit section
TALISMAN_EXAMPLE="$PLUGIN_DIR/talisman.example.yml"
CHECKED=$((CHECKED + 1))
if [[ -f "$TALISMAN_EXAMPLE" ]] && grep -q 'self_audit:' "$TALISMAN_EXAMPLE" 2>/dev/null; then
  pass "SA-INTEG-2" "self_audit section exists in talisman.example.yml"
else
  violation "SA-INTEG-2" "Missing self_audit section in talisman.example.yml"
fi

# Check using-rune routing
USING_RUNE="$PLUGIN_DIR/skills/using-rune/SKILL.md"
CHECKED=$((CHECKED + 1))
if grep -q 'self-audit' "$USING_RUNE" 2>/dev/null; then
  pass "SA-INTEG-3" "self-audit routed in using-rune"
else
  violation "SA-INTEG-3" "self-audit missing from using-rune routing"
fi

# Check self_referential tagging in agents
section "6b" "Self-referential safety"
for agent_file in "$PLUGIN_DIR"/agents/meta-qa/*.md; do
  [[ -f "$agent_file" ]] || continue
  agent_name="$(basename "$agent_file" .md)"
  CHECKED=$((CHECKED + 1))
  if grep -qi 'self.referential' "$agent_file" 2>/dev/null; then
    pass "SA-SELFREF-${CHECKED}" "${agent_name}: has self-referential tagging"
  else
    violation "SA-SELFREF-${CHECKED}" "${agent_name}: missing self_referential tagging instructions"
  fi
done

# --- Summary ---
printf "\n════════════════════════════════════════\n"
printf "Self-Audit Validation Summary\n"
printf "  Checks:     %d\n" "$CHECKED"
printf "  Passed:     %d\n" "$PASSED"
printf "  Violations: %d\n" "$VIOLATIONS"
printf "════════════════════════════════════════\n"

if [[ "$VIOLATIONS" -gt 0 ]]; then
  printf "\n❌ %d violation(s) found. Fix before releasing.\n" "$VIOLATIONS"
  exit 1
else
  printf "\n✅ All checks passed.\n"
  exit 0
fi
