#!/usr/bin/env bash
# test-session-start.sh — Tests for scripts/session-start.sh
#
# Usage: bash plugins/rune/scripts/tests/test-session-start.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/session-start.sh"

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$expected" = "$actual" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s\n" "$test_name"
    printf "    expected: %q\n" "$expected"
    printf "    actual:   %q\n" "$actual"
  fi
}

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle not found)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

assert_not_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle was found but should not be)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

# ── Setup ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Create a mock plugin structure
MOCK_PLUGIN="$TMP_DIR/mock-plugin"
mkdir -p "$MOCK_PLUGIN/skills/using-rune"
mkdir -p "$MOCK_PLUGIN/scripts"

# Copy session-start.sh to mock plugin scripts dir
cp "$UNDER_TEST" "$MOCK_PLUGIN/scripts/session-start.sh"

# ═══════════════════════════════════════════════════════════════
# 1. Basic output structure
# ═══════════════════════════════════════════════════════════════
printf "\n=== Basic Output Structure ===\n"

# 1a. Exit 0 when skill file is missing
MISSING_PLUGIN="$TMP_DIR/no-skill-plugin"
mkdir -p "$MISSING_PLUGIN/scripts"
cp "$UNDER_TEST" "$MISSING_PLUGIN/scripts/session-start.sh"

result_code=0
echo '{}' | CLAUDE_PLUGIN_ROOT="$MISSING_PLUGIN" bash "$MISSING_PLUGIN/scripts/session-start.sh" >/dev/null 2>&1 || result_code=$?
assert_eq "Exit 0 when skill file missing" "0" "$result_code"

# 1b. Produces valid JSON when skill file exists
cat > "$MOCK_PLUGIN/skills/using-rune/SKILL.md" <<'SKILL_EOF'
---
name: using-rune
description: Workflow routing
---
Hello from using-rune skill content.
SKILL_EOF

result=$(echo '{}' | CLAUDE_PLUGIN_ROOT="$MOCK_PLUGIN" bash "$MOCK_PLUGIN/scripts/session-start.sh" 2>/dev/null)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if echo "$result" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Output is valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Output is not valid JSON\n"
  printf "    output: %s\n" "$result"
fi

# 1c. Output has hookSpecificOutput.hookEventName = SessionStart
assert_contains "hookEventName is SessionStart" '"hookEventName":"SessionStart"' "$result"

# 1d. Output has additionalContext field
assert_contains "Has additionalContext" '"additionalContext"' "$result"

# ═══════════════════════════════════════════════════════════════
# 2. Frontmatter stripping
# ═══════════════════════════════════════════════════════════════
printf "\n=== Frontmatter Stripping ===\n"

# 2a. YAML frontmatter is stripped from skill content
assert_not_contains "Frontmatter name not in output" "name: using-rune" "$result"
assert_not_contains "Frontmatter description not in output" "description: Workflow routing" "$result"

# 2b. Skill body content is present
assert_contains "Skill body content present" "Hello from using-rune skill content" "$result"

# 2c. Rune Plugin Active prefix
assert_contains "Rune Plugin Active prefix" "[Rune Plugin Active]" "$result"

# ═══════════════════════════════════════════════════════════════
# 3. Multi-line skill content
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multi-line Skill Content ===\n"

cat > "$MOCK_PLUGIN/skills/using-rune/SKILL.md" <<'SKILL_EOF'
---
name: using-rune
description: Test multi-line
---
Line one of content.
Line two with special chars: "quotes" and backslash\.
Line three.
SKILL_EOF

result=$(echo '{}' | CLAUDE_PLUGIN_ROOT="$MOCK_PLUGIN" bash "$MOCK_PLUGIN/scripts/session-start.sh" 2>/dev/null)

# 3a. Output is still valid JSON with multi-line content
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if echo "$result" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Multi-line content produces valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Multi-line content produces invalid JSON\n"
  printf "    output: %s\n" "$result"
fi

# 3b. Content includes all lines
assert_contains "Multi-line: line one present" "Line one" "$result"
assert_contains "Multi-line: line three present" "Line three" "$result"

# ═══════════════════════════════════════════════════════════════
# 4. Empty input handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Input Handling ===\n"

# 4a. Empty stdin still produces output (graceful degradation)
result=$(printf '' | CLAUDE_PLUGIN_ROOT="$MOCK_PLUGIN" bash "$MOCK_PLUGIN/scripts/session-start.sh" 2>/dev/null)
result_code=$?
assert_eq "Exit 0 on empty stdin" "0" "$result_code"
assert_contains "Still produces hookSpecificOutput on empty input" "hookSpecificOutput" "$result"

# ═══════════════════════════════════════════════════════════════
# 5. Fail-forward guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-forward Guard ===\n"

# 5a. Exit 0 even with non-existent CLAUDE_PLUGIN_ROOT
result_code=0
echo '{}' | CLAUDE_PLUGIN_ROOT="/nonexistent/path/plugin" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Exit 0 with nonexistent plugin root" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════
printf "\n═══════════════════════════════════════════════════\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "═══════════════════════════════════════════════════\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
