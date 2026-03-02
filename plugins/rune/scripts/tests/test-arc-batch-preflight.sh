#!/usr/bin/env bash
# test-arc-batch-preflight.sh — Tests for scripts/arc-batch-preflight.sh
#
# Usage: bash plugins/rune/scripts/tests/test-arc-batch-preflight.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/arc-batch-preflight.sh"

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
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
  local test_name="$1" needle="$2" haystack="$3"
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
  local test_name="$1" needle="$2" haystack="$3"
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

PLANS_DIR="$TMP_DIR/plans"
mkdir -p "$PLANS_DIR"

# ═══════════════════════════════════════════════════════════════
# 1. Valid plan files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Plan Files ===\n"

echo "# Plan A" > "$PLANS_DIR/plan-a.md"
echo "# Plan B" > "$PLANS_DIR/plan-b.md"

result=$(printf '%s\n' "$PLANS_DIR/plan-a.md" "$PLANS_DIR/plan-b.md" | bash "$UNDER_TEST" 2>/dev/null)
result_code=$?
assert_eq "Two valid plans → exit 0" "0" "$result_code"
assert_contains "Plan A in output" "plan-a.md" "$result"
assert_contains "Plan B in output" "plan-b.md" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. Missing plan file
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing Plan File ===\n"

result_code=0
stderr=$(echo "/nonexistent/plan.md" | bash "$UNDER_TEST" 2>&1 1>/dev/null) || result_code=$?
assert_eq "Missing plan → exit 1" "1" "$result_code"
assert_contains "Error message for missing file" "not found" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 3. Symlink rejected
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Rejected ===\n"

echo "# Real plan" > "$PLANS_DIR/real-plan.md"
ln -sf "$PLANS_DIR/real-plan.md" "$PLANS_DIR/symlink-plan.md"

result_code=0
stderr=$(echo "$PLANS_DIR/symlink-plan.md" | bash "$UNDER_TEST" 2>&1 1>/dev/null) || result_code=$?
assert_eq "Symlink plan → exit 1" "1" "$result_code"
assert_contains "Symlink error message" "Symlink rejected" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 4. Path traversal rejected
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Traversal ===\n"

result_code=0
echo "# Plan" > "$PLANS_DIR/legit.md"
stderr=$(echo "$PLANS_DIR/../plans/legit.md" | bash "$UNDER_TEST" 2>&1 1>/dev/null) || result_code=$?
assert_eq "Path traversal → exit 1" "1" "$result_code"
assert_contains "Traversal error" "traversal" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 5. Empty plan file
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Plan File ===\n"

touch "$PLANS_DIR/empty.md"  # 0 bytes

result_code=0
stderr=$(echo "$PLANS_DIR/empty.md" | bash "$UNDER_TEST" 2>&1 1>/dev/null) || result_code=$?
assert_eq "Empty plan → exit 1" "1" "$result_code"
assert_contains "Empty file error" "Empty plan" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 6. Duplicate plans
# ═══════════════════════════════════════════════════════════════
printf "\n=== Duplicate Plans ===\n"

echo "# Plan C" > "$PLANS_DIR/plan-c.md"
result=$(printf '%s\n' "$PLANS_DIR/plan-c.md" "$PLANS_DIR/plan-c.md" | bash "$UNDER_TEST" 2>/dev/null)
# Count lines — should be exactly 1 (not 2)
line_count=$(echo "$result" | grep -c '.' || true)
assert_eq "Duplicate deduped to 1 line" "1" "$line_count"

# ═══════════════════════════════════════════════════════════════
# 7. Comments and blank lines skipped
# ═══════════════════════════════════════════════════════════════
printf "\n=== Comments and Blank Lines ===\n"

echo "# Plan D" > "$PLANS_DIR/plan-d.md"
result=$(printf '# this is a comment\n\n%s\n\n' "$PLANS_DIR/plan-d.md" | bash "$UNDER_TEST" 2>/dev/null)
result_code=$?
assert_eq "Comments/blanks skipped → exit 0" "0" "$result_code"
assert_contains "Valid plan still output" "plan-d.md" "$result"

# ═══════════════════════════════════════════════════════════════
# 8. Character allowlist (special chars)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Character Allowlist ===\n"

# Create file with spaces in name (will fail char allowlist)
SPACE_DIR="$TMP_DIR/space dir"
mkdir -p "$SPACE_DIR"
echo "# Plan" > "$SPACE_DIR/plan.md"

result_code=0
stderr=$(echo "$SPACE_DIR/plan.md" | bash "$UNDER_TEST" 2>&1 1>/dev/null) || result_code=$?
assert_eq "Space in path → exit 1" "1" "$result_code"
assert_contains "Disallowed chars error" "disallowed characters" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 9. Shard frontmatter warnings
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shard Frontmatter Warnings ===\n"

echo "# Shard plan (no frontmatter)" > "$PLANS_DIR/feature-shard-1-auth.md"
stderr=$(echo "$PLANS_DIR/feature-shard-1-auth.md" | bash "$UNDER_TEST" 2>&1)
assert_contains "Missing shard: warning" "missing 'shard:'" "$stderr"
assert_contains "Missing parent: warning" "missing 'parent:'" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 10. Valid shard with frontmatter
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Shard ===\n"

cat > "$PLANS_DIR/feature-shard-1-valid.md" <<EOF
---
shard: 1
parent: feature-plan.md
---
# Shard 1 content
EOF

result=$(echo "$PLANS_DIR/feature-shard-1-valid.md" | bash "$UNDER_TEST" 2>/dev/null)
result_code=$?
assert_eq "Valid shard → exit 0" "0" "$result_code"
assert_contains "Valid shard in output" "feature-shard-1-valid.md" "$result"

# ═══════════════════════════════════════════════════════════════
# 11. Mixed valid and invalid
# ═══════════════════════════════════════════════════════════════
printf "\n=== Mixed Valid and Invalid ===\n"

echo "# Good plan" > "$PLANS_DIR/good.md"
result_code=0
output=$(printf '%s\n%s\n' "$PLANS_DIR/good.md" "/nonexistent/bad.md" | bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Mixed valid+invalid → exit 1 (errors found)" "1" "$result_code"
assert_contains "Valid plan still in stdout" "good.md" "$output"

# ═══════════════════════════════════════════════════════════════
# 12. Empty input
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Input ===\n"

result_code=0
echo "" | bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Empty input → exit 0" "0" "$result_code"

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
