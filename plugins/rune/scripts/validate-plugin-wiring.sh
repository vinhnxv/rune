#!/usr/bin/env bash
# scripts/validate-plugin-wiring.sh
# Validates plugin wiring integrity with 4 deterministic checks.
# Detects sediment: orphaned agents, unwired skills, missing SKILL.md,
# and disconnected scripts.
#
# Usage: bash plugins/rune/scripts/validate-plugin-wiring.sh
# Exit: 0 if clean, 1 if violations found.
#
# Supports # SDMT-IGNORE: reason annotation in first 5 lines of any file
# to exempt it from checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VIOLATIONS=0
CHECKED=0
IGNORED=0

# --- Helpers ---

# Check if a file has SDMT-IGNORE annotation in first 5 lines
has_sdmt_ignore() {
  local file="$1"
  head -5 "$file" | grep -qE '^#\s*SDMT-IGNORE:' 2>/dev/null
}

# Print violation with SDMT code
violation() {
  local code="$1"
  shift
  printf "  [%s] %s\n" "$code" "$*"
  VIOLATIONS=$((VIOLATIONS + 1))
}

# Print section header
section() {
  printf "\n=== Check %s: %s ===\n" "$1" "$2"
}

# --- Check 1: SDMT-001 — Every agent has >=1 reference in skills/ ---
section "1" "SDMT-001 — Agent references in skills"

check1_total=0
check1_pass=0

while IFS= read -r agent_file; do
  [ -z "$agent_file" ] && continue
  agent_name="$(basename "$agent_file" .md)"

  # Check for SDMT-IGNORE
  if has_sdmt_ignore "$agent_file"; then
    IGNORED=$((IGNORED + 1))
    continue
  fi

  check1_total=$((check1_total + 1))

  # Search for agent name in skills/ (SKILL.md files and reference files)
  if grep -rql "$agent_name" "$PLUGIN_DIR/skills/" >/dev/null 2>&1; then
    check1_pass=$((check1_pass + 1))
  else
    # Also check CLAUDE.md (some agents are only referenced there)
    if grep -ql "$agent_name" "$PLUGIN_DIR/CLAUDE.md" >/dev/null 2>&1; then
      check1_pass=$((check1_pass + 1))
    else
      violation "SDMT-001" "Agent '$agent_name' has no reference in skills/ or CLAUDE.md"
    fi
  fi
done < <(find "$PLUGIN_DIR/agents" -name '*.md' -not -path '*/references/*' 2>/dev/null | sort)

CHECKED=$((CHECKED + check1_total))
printf "  Checked %d agents, %d referenced, %d orphaned\n" "$check1_total" "$check1_pass" "$((check1_total - check1_pass))"

# --- Check 2: SDMT-005 — User-invocable skills in routing tables ---
section "2" "SDMT-005 — User-invocable skills in routing tables"

check2_total=0
check2_pass=0

# Read routing tables once
USING_RUNE_FILE="$PLUGIN_DIR/skills/using-rune/SKILL.md"
TARNISHED_FILE="$PLUGIN_DIR/skills/tarnished/SKILL.md"

routing_content=""
if [ -f "$USING_RUNE_FILE" ]; then
  routing_content="$(cat "$USING_RUNE_FILE")"
fi
if [ -f "$TARNISHED_FILE" ]; then
  routing_content="${routing_content}
$(cat "$TARNISHED_FILE")"
fi

while IFS= read -r skill_dir; do
  [ -z "$skill_dir" ] && continue
  skill_md="$skill_dir/SKILL.md"
  [ -f "$skill_md" ] || continue

  # Check if user-invocable (default is true if not specified)
  # Extract user-invocable value from YAML frontmatter
  user_invocable="true"
  if head -30 "$skill_md" | grep -qE '^user-invocable:\s*false' 2>/dev/null; then
    user_invocable="false"
  fi

  [ "$user_invocable" = "false" ] && continue

  skill_name="$(basename "$skill_dir")"

  # Check for SDMT-IGNORE in SKILL.md
  if has_sdmt_ignore "$skill_md"; then
    IGNORED=$((IGNORED + 1))
    continue
  fi

  check2_total=$((check2_total + 1))

  # Check if skill appears in routing tables (as /rune:<name> or rune:<name> or just the name in a table row)
  if echo "$routing_content" | grep -qE "(rune:${skill_name}|/${skill_name}\b)" 2>/dev/null; then
    check2_pass=$((check2_pass + 1))
  else
    # Also accept the skill name appearing as a beginner alias target
    if echo "$routing_content" | grep -qF "$skill_name" 2>/dev/null; then
      check2_pass=$((check2_pass + 1))
    else
      violation "SDMT-005" "User-invocable skill '$skill_name' not in using-rune or tarnished routing table"
    fi
  fi
done < <(find "$PLUGIN_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

CHECKED=$((CHECKED + check2_total))
printf "  Checked %d user-invocable skills, %d routed, %d unwired\n" "$check2_total" "$check2_pass" "$((check2_total - check2_pass))"

# --- Check 3: SDMT-007 — Every skill directory has SKILL.md ---
section "3" "SDMT-007 — Skill directories have SKILL.md"

check3_total=0
check3_pass=0

while IFS= read -r skill_dir; do
  [ -z "$skill_dir" ] && continue
  dir_name="$(basename "$skill_dir")"

  check3_total=$((check3_total + 1))

  if [ -f "$skill_dir/SKILL.md" ]; then
    check3_pass=$((check3_pass + 1))
  else
    violation "SDMT-007" "Skill directory '$dir_name' has no SKILL.md"
  fi
done < <(find "$PLUGIN_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

CHECKED=$((CHECKED + check3_total))
printf "  Checked %d skill directories, %d have SKILL.md, %d missing\n" "$check3_total" "$check3_pass" "$((check3_total - check3_pass))"

# --- Check 4: SDMT-004 — Every script is in hooks.json or referenced by a skill ---
section "4" "SDMT-004 — Script references in hooks or skills"

check4_total=0
check4_pass=0

# Read hooks.json once
HOOKS_FILE="$PLUGIN_DIR/hooks/hooks.json"

while IFS= read -r script_file; do
  [ -z "$script_file" ] && continue

  # Get relative script path from plugin root (e.g., scripts/foo.sh)
  script_rel="${script_file#"$PLUGIN_DIR"/}"
  script_basename="$(basename "$script_file")"

  # Check for SDMT-IGNORE
  if has_sdmt_ignore "$script_file"; then
    IGNORED=$((IGNORED + 1))
    continue
  fi

  check4_total=$((check4_total + 1))

  # Check hooks.json (matches scripts/name.sh or scripts/subdir/name.sh)
  found=false
  if [ -f "$HOOKS_FILE" ] && grep -qF "$script_rel" "$HOOKS_FILE" 2>/dev/null; then
    found=true
  fi

  # Check skills/ references (SKILL.md and reference files)
  if [ "$found" = "false" ]; then
    if grep -rqlF "$script_basename" "$PLUGIN_DIR/skills/" --include='*.md' 2>/dev/null; then
      found=true
    fi
  fi

  # Check CLAUDE.md
  if [ "$found" = "false" ]; then
    if [ -f "$PLUGIN_DIR/CLAUDE.md" ] && grep -qF "$script_basename" "$PLUGIN_DIR/CLAUDE.md" 2>/dev/null; then
      found=true
    fi
  fi

  # Check if referenced by other scripts (lib scripts, sourced files)
  if [ "$found" = "false" ]; then
    ref_count=$(grep -rlF "$script_basename" "$PLUGIN_DIR/scripts/" --include='*.sh' 2>/dev/null | grep -vcF "$script_file" || true)
    if [ "$ref_count" -gt 0 ]; then
      found=true
    fi
  fi

  if [ "$found" = "true" ]; then
    check4_pass=$((check4_pass + 1))
  else
    violation "SDMT-004" "Script '$script_rel' not in hooks.json, skills, or other scripts"
  fi
done < <(find "$PLUGIN_DIR/scripts" -name '*.sh' \
  -not -path '*/lib/*' \
  -not -path '*/tests/*' \
  -not -path '*/node_modules/*' \
  2>/dev/null | sort)

CHECKED=$((CHECKED + check4_total))
printf "  Checked %d scripts, %d wired, %d disconnected\n" "$check4_total" "$check4_pass" "$((check4_total - check4_pass))"

# --- Summary ---
printf "\n─────────────────────────────────────\n"
printf "Total checked: %d | Violations: %d | Ignored: %d\n" "$CHECKED" "$VIOLATIONS" "$IGNORED"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf "FAIL: %d wiring violations found\n" "$VIOLATIONS"
  exit 1
else
  printf "PASS: All plugin wiring checks passed\n"
  exit 0
fi
