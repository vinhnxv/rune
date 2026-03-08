#!/usr/bin/env bash
# test-arc-issues-preflight.sh — Tests for scripts/arc-issues-preflight.sh
#
# NOTE: Tests that require `gh` API calls are mocked by overriding PATH with a
#       stub script. Tests that validate format/dedup logic run without gh.
#
# Usage: bash plugins/rune/scripts/tests/test-arc-issues-preflight.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/arc-issues-preflight.sh"

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

# ── Setup ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Create mock gh CLI with configurable responses
MOCK_BIN="$TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

# Default mock gh: version 2.50.0, auth ok, issues return valid data
create_mock_gh() {
  cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1" in
  --version)
    echo "gh version 2.50.0 (2025-01-01)"
    ;;
  auth)
    echo "Logged in to github.com as testuser"
    ;;
  issue)
    case "$3" in
      42)
        echo '{"number":42,"state":"OPEN","labels":[]}'
        ;;
      55)
        echo '{"number":55,"state":"OPEN","labels":[]}'
        ;;
      78)
        echo '{"number":78,"state":"OPEN","labels":[{"name":"rune:done"}]}'
        ;;
      99)
        echo '{"number":99,"state":"CLOSED","labels":[]}'
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"
}

create_mock_gh

# ═══════════════════════════════════════════════════════════════
# 1. Valid issues
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Issues ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 42 55 2>/dev/null)
assert_contains "Output has ok:true" '"ok":true' "$(echo "$result" | tr -d ' ')"

valid_count=$(echo "$result" | jq '.valid | length' 2>/dev/null || echo "0")
assert_eq "Two valid issues" "2" "$valid_count"

# ═══════════════════════════════════════════════════════════════
# 2. Skipped issues (rune status label)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Skipped Issues ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 78 2>/dev/null)
skipped_count=$(echo "$result" | jq '.skipped | length' 2>/dev/null || echo "0")
assert_eq "One skipped issue" "1" "$skipped_count"

# ═══════════════════════════════════════════════════════════════
# 3. Invalid issues (closed)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Invalid Issues (Closed) ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 99 2>/dev/null)
invalid_count=$(echo "$result" | jq '.invalid | length' 2>/dev/null || echo "0")
assert_eq "One invalid issue (closed)" "1" "$invalid_count"

# ═══════════════════════════════════════════════════════════════
# 4. Invalid issue number format
# ═══════════════════════════════════════════════════════════════
printf "\n=== Invalid Number Format ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 0 abc 99999999 2>/dev/null)
invalid_count=$(echo "$result" | jq '.invalid | length' 2>/dev/null || echo "0")
assert_eq "Three invalid format issues" "3" "$invalid_count"

# ═══════════════════════════════════════════════════════════════
# 5. Hash prefix stripped (#42 → 42)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Hash Prefix Stripping ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" '#42' 2>/dev/null)
valid_count=$(echo "$result" | jq '.valid | length' 2>/dev/null || echo "0")
assert_eq "Hash prefix stripped → valid" "1" "$valid_count"

# ═══════════════════════════════════════════════════════════════
# 6. Duplicate dedup
# ═══════════════════════════════════════════════════════════════
printf "\n=== Duplicate Dedup ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 42 42 42 2>/dev/null)
valid_count=$(echo "$result" | jq '.valid | length' 2>/dev/null || echo "0")
assert_eq "Duplicates deduped to 1" "1" "$valid_count"

# ═══════════════════════════════════════════════════════════════
# 7. No issues provided
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Issues Provided ===\n"

result=$(echo "" | PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "No issues → error" '"ok":false' "$(echo "$result" | tr -d ' ')"
error_count=$(echo "$result" | jq '.errors | length' 2>/dev/null || echo "0")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$error_count" -gt 0 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Error message present for no issues\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No error message for no issues\n"
fi

# ═══════════════════════════════════════════════════════════════
# 8. gh CLI not found
# ═══════════════════════════════════════════════════════════════
printf "\n=== gh CLI Not Found ===\n"

# Create a bin dir with only jq (no gh) — but keep system paths for bash builtins
NO_GH_BIN="$TMP_DIR/no-gh-bin"
mkdir -p "$NO_GH_BIN"
ln -sf "$(command -v jq)" "$NO_GH_BIN/jq"

# PATH must include system bins (date, head, etc.) but NOT gh
# Create symlinks for essential system tools, excluding gh
for _cmd in bash date head cat sed grep printf tr jq wc mkdir rm id test; do
  _path=$(PATH="/usr/bin:/bin" command -v "$_cmd" 2>/dev/null || true)
  [[ -n "$_path" && -x "$_path" ]] && ln -sf "$_path" "$NO_GH_BIN/$_cmd" 2>/dev/null || true
done
result=$(PATH="$NO_GH_BIN" bash "$UNDER_TEST" 42 2>/dev/null)
assert_contains "gh not found → error" "gh CLI not found" "$result"
assert_contains "gh not found → ok false" '"ok":false' "$(echo "$result" | tr -d ' ')"

# ═══════════════════════════════════════════════════════════════
# 9. gh CLI old version
# ═══════════════════════════════════════════════════════════════
printf "\n=== gh CLI Old Version ===\n"

cat > "$MOCK_BIN/gh-old" <<'GHEOF'
#!/usr/bin/env bash
echo "gh version 1.9.0 (2021-01-01)"
GHEOF
chmod +x "$MOCK_BIN/gh-old"
cp "$MOCK_BIN/gh-old" "$MOCK_BIN/gh"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 42 2>/dev/null)
assert_contains "Old gh → version error" "too old" "$result"

# Restore mock
create_mock_gh

# ═══════════════════════════════════════════════════════════════
# 10. Stdin input
# ═══════════════════════════════════════════════════════════════
printf "\n=== Stdin Input ===\n"

result=$(echo "42 55" | PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 2>/dev/null)
valid_count=$(echo "$result" | jq '.valid | length' 2>/dev/null || echo "0")
assert_eq "Stdin input parsed correctly" "2" "$valid_count"

# ═══════════════════════════════════════════════════════════════
# 11. Mixed valid/invalid/skipped
# ═══════════════════════════════════════════════════════════════
printf "\n=== Mixed Results ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 42 abc 78 99 55 2>/dev/null)

valid_count=$(echo "$result" | jq '.valid | length' 2>/dev/null || echo "0")
invalid_count=$(echo "$result" | jq '.invalid | length' 2>/dev/null || echo "0")
skipped_count=$(echo "$result" | jq '.skipped | length' 2>/dev/null || echo "0")

assert_eq "Mixed: 2 valid" "2" "$valid_count"
assert_eq "Mixed: 2 invalid (abc + 99)" "2" "$invalid_count"
assert_eq "Mixed: 1 skipped" "1" "$skipped_count"

# ═══════════════════════════════════════════════════════════════
# 12. Output is always valid JSON
# ═══════════════════════════════════════════════════════════════
printf "\n=== Output JSON Validity ===\n"

result=$(PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" 42 2>/dev/null)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if echo "$result" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Output is valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Output is NOT valid JSON\n"
  printf "    output: %s\n" "$result"
fi

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
