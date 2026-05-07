#!/usr/bin/env bash
# scripts/validate-skill-descriptions.sh
# Validates skill and command description hygiene to prevent listing-budget bloat.
#
# Checks:
#   DESC-001: No <example> blocks inside YAML frontmatter description field
#             (examples belong in body — they bloat the listing budget that
#             ships with every session)
#   DESC-002: Description length cap (default: 800 chars trimmed)
#             Long descriptions waste the listing budget without improving
#             routing accuracy
#   DESC-003: Alias skills/commands MUST set disable-model-invocation: true
#             Detected by description starting with "alias for /rune:" or
#             "Beginner-friendly alias for"
#
# Usage: bash plugins/rune/scripts/validate-skill-descriptions.sh
#        DESC_MAX_LEN=600 bash ... # override default cap
# Exit:  0 if clean, 1 if violations found.
#
# Supports # SDMT-IGNORE: reason annotation in first 5 lines of any file
# to exempt it from checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DESC_MAX_LEN="${DESC_MAX_LEN:-800}"

VIOLATIONS=0
CHECKED=0
IGNORED=0

# Skip annotation check (shared with validate-plugin-wiring.sh convention)
has_sdmt_ignore() {
  local file="$1"
  head -5 "$file" | grep -qE '^(#|<!--)\s*SDMT-IGNORE:' 2>/dev/null
}

# Extract the description field block from YAML frontmatter.
# Output: just the description value (multi-line collapsed).
extract_description() {
  local file="$1"
  awk '
    BEGIN { fm=0; in_desc=0 }
    /^---$/ { fm++; if (fm==2) exit; next }
    fm==1 {
      if (/^description:[ ]*\|/) { in_desc=1; next }
      if (/^description:[ ]*/ && !/^description:[ ]*\|/) {
        sub(/^description:[ ]*/, "")
        sub(/^["'"'"']/, ""); sub(/["'"'"']$/, "")
        print
        exit
      }
      if (in_desc) {
        # Stop at next top-level YAML key
        if (/^[a-zA-Z][a-zA-Z0-9_-]*:/) exit
        sub(/^[ ][ ]/, "")
        print
      }
    }
  ' "$file"
}

# Check if description block contains <example> tags
has_example_in_description() {
  extract_description "$1" | grep -qE '<example>|</example>'
}

# Get description length (trimmed of leading/trailing whitespace per line, joined)
description_length() {
  extract_description "$1" | tr -d '\n' | wc -c | tr -d ' '
}

# Check if file has `disable-model-invocation: true` in frontmatter
has_disable_model_invocation() {
  awk '/^---$/{c++; next} c==1' "$1" | grep -qE '^disable-model-invocation:\s*true'
}

# Check if description identifies the skill/command as an alias
is_alias() {
  extract_description "$1" | grep -qiE '(alias for /rune:|beginner-friendly alias)'
}

# Print violation
violation() {
  local code="$1"
  local file="$2"
  local detail="$3"
  printf "  %s: %s — %s\n" "$code" "${file#"$PLUGIN_DIR"/}" "$detail"
  VIOLATIONS=$((VIOLATIONS + 1))
}

# Discover targets (Bash 3.2 compatible — no mapfile)
SKILL_COUNT=$(find "$PLUGIN_DIR/skills" -maxdepth 2 -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
COMMAND_COUNT=$(find "$PLUGIN_DIR/commands" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

printf "Validating %d skills + %d commands (DESC_MAX_LEN=%d)\n" \
  "$SKILL_COUNT" "$COMMAND_COUNT" "$DESC_MAX_LEN"
printf "%s\n\n" "----------------------------------------"

# Stream targets via process substitution to preserve VIOLATIONS counter in parent shell
while IFS= read -r f; do
  [[ -f "$f" ]] || continue

  if has_sdmt_ignore "$f"; then
    IGNORED=$((IGNORED + 1))
    continue
  fi

  CHECKED=$((CHECKED + 1))

  # DESC-001: no <example> in description
  if has_example_in_description "$f"; then
    violation "DESC-001" "$f" "<example> block in description field (move to body)"
  fi

  # DESC-002: description length cap
  desc_len=$(description_length "$f")
  if (( desc_len > DESC_MAX_LEN )); then
    violation "DESC-002" "$f" "description ${desc_len} chars exceeds cap ${DESC_MAX_LEN}"
  fi

  # DESC-003: aliases must hide from model invocation
  if is_alias "$f" && ! has_disable_model_invocation "$f"; then
    violation "DESC-003" "$f" "alias missing 'disable-model-invocation: true' (loads description into context)"
  fi
done < <(
  find "$PLUGIN_DIR/skills" -maxdepth 2 -name 'SKILL.md' 2>/dev/null | sort
  find "$PLUGIN_DIR/commands" -maxdepth 1 -name '*.md' 2>/dev/null | sort
)

printf "\n%s\n" "----------------------------------------"
printf "Checked: %d  Ignored: %d  Violations: %d\n" \
  "$CHECKED" "$IGNORED" "$VIOLATIONS"

if (( VIOLATIONS > 0 )); then
  printf "\nFAIL: skill/command descriptions need cleanup.\n"
  printf "Fix violations or add '# SDMT-IGNORE: <reason>' to first 5 lines.\n"
  exit 1
fi

printf "\nPASS: all descriptions within budget.\n"
exit 0
