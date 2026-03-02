#!/usr/bin/env bash
# test-codex-exec.sh — Tests for scripts/codex-exec.sh
#
# Tests validation logic, option parsing, and security guards.
# Does NOT test actual codex execution (requires codex CLI + API key).
#
# Usage: bash plugins/rune/scripts/tests/test-codex-exec.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/codex-exec.sh"

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

# Create a mock workspace
MOCK_WORKSPACE="$TMP_DIR/workspace"
mkdir -p "$MOCK_WORKSPACE"

# Create a valid prompt file
echo "Analyze this code for bugs" > "$TMP_DIR/prompt.txt"

# Create .codexignore
echo "node_modules/" > "$MOCK_WORKSPACE/.codexignore"

# ═══════════════════════════════════════════════════════════════
# 1. Missing prompt file argument
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing Prompt File ===\n"

result_code=0
stderr=$(bash "$UNDER_TEST" 2>&1) || result_code=$?
assert_eq "No prompt file → exit 2" "2" "$result_code"
assert_contains "Error mentions PROMPT_FILE" "PROMPT_FILE" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 2. Nonexistent prompt file
# ═══════════════════════════════════════════════════════════════
printf "\n=== Nonexistent Prompt File ===\n"

result_code=0
stderr=$(bash "$UNDER_TEST" "/nonexistent/prompt.txt" 2>&1) || result_code=$?
assert_eq "Nonexistent prompt → exit 2" "2" "$result_code"
assert_contains "Prompt not found error" "not found" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 3. Symlink prompt file rejection
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Prompt Rejected ===\n"

ln -sf "$TMP_DIR/prompt.txt" "$TMP_DIR/symlink-prompt.txt"

result_code=0
stderr=$(bash "$UNDER_TEST" "$TMP_DIR/symlink-prompt.txt" 2>&1) || result_code=$?
assert_eq "Symlink prompt → exit 2" "2" "$result_code"
assert_contains "Symlink rejection message" "symlink" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 4. Path traversal rejection
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Traversal Rejection ===\n"

result_code=0
stderr=$(bash "$UNDER_TEST" "$TMP_DIR/../prompt.txt" 2>&1) || result_code=$?
assert_eq "Path traversal → exit 2" "2" "$result_code"
assert_contains "Traversal rejection" ".." "$stderr"

# ═══════════════════════════════════════════════════════════════
# 5. Prompt file size limit (>1MB)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Prompt Size Limit ===\n"

# Create a file larger than 1MB
python3 -c "print('x' * 1100000)" > "$TMP_DIR/huge-prompt.txt"

result_code=0
stderr=$(bash "$UNDER_TEST" "$TMP_DIR/huge-prompt.txt" 2>&1) || result_code=$?
assert_eq "Huge prompt → exit 2" "2" "$result_code"
assert_contains "Size limit error" "1MB" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 6. Model allowlist validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Model Allowlist ===\n"

# Create mock codex CLI that just echoes its args
MOCK_BIN="$TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

# Mock codex that exits immediately (we're testing pre-flight, not execution)
# But we need codex to exist for the pre-flight check
cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
# Capture the model arg for inspection
for i in "${!@}"; do
  [[ "${!i}" == "-m" ]] && {
    j=$((i+1))
    echo "MODEL=${!j}" >&2
  }
done
exit 0
EOF
chmod +x "$MOCK_BIN/codex"

# Test invalid model fallback — need to cd to workspace for .codexignore
result_code=0
stderr=$(cd "$MOCK_WORKSPACE" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" -m "gpt-evil" "$TMP_DIR/prompt.txt" 2>&1) || result_code=$?
assert_contains "Invalid model warns" "not in allowlist" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 7. Reasoning allowlist
# ═══════════════════════════════════════════════════════════════
printf "\n=== Reasoning Allowlist ===\n"

result_code=0
stderr=$(cd "$MOCK_WORKSPACE" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" -r "extreme" "$TMP_DIR/prompt.txt" 2>&1) || result_code=$?
assert_contains "Invalid reasoning warns" "not in" "$stderr"

# Valid reasoning levels should not warn
for level in xhigh high medium low; do
  stderr=$(cd "$MOCK_WORKSPACE" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" -r "$level" "$TMP_DIR/prompt.txt" 2>&1) || true
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if echo "$stderr" | grep -q "not in"; then
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Valid reasoning level '%s' incorrectly warned\n" "$level"
  else
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Reasoning level '%s' accepted\n" "$level"
  fi
done

# ═══════════════════════════════════════════════════════════════
# 8. Timeout clamping
# ═══════════════════════════════════════════════════════════════
printf "\n=== Timeout Clamping ===\n"

# We can test by examining the script's logic: <300 clamps to 300, >900 clamps to 900
# The mock codex won't actually wait, but the option parsing runs before execution

# Test that very low timeout doesn't cause script to fail
result_code=0
cd "$MOCK_WORKSPACE" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" -t 10 "$TMP_DIR/prompt.txt" >/dev/null 2>&1 || result_code=$?
assert_eq "Low timeout clamped → exit 0" "0" "$result_code"

# Test that very high timeout doesn't cause script to fail
result_code=0
cd "$MOCK_WORKSPACE" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" -t 9999 "$TMP_DIR/prompt.txt" >/dev/null 2>&1 || result_code=$?
assert_eq "High timeout clamped → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 9. Missing codex CLI
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing Codex CLI ===\n"

# Use a PATH with no codex
NO_CODEX_BIN="$TMP_DIR/no-codex"
mkdir -p "$NO_CODEX_BIN"
# Need basic tools
for tool in bash cat head wc tr echo printf timeout jq dirname id date cd pwd grep sed awk stat mktemp rm mv command kill; do
  tool_path=$(command -v "$tool" 2>/dev/null || true)
  [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$NO_CODEX_BIN/$tool" 2>/dev/null || true
done

result_code=0
stderr=$(cd "$MOCK_WORKSPACE" && PATH="$NO_CODEX_BIN" bash "$UNDER_TEST" "$TMP_DIR/prompt.txt" 2>&1) || result_code=$?
assert_eq "Missing codex → exit 1" "1" "$result_code"
assert_contains "Codex not found error" "codex CLI not found" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 10. Missing .codexignore
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing .codexignore ===\n"

NO_IGNORE_DIR="$TMP_DIR/no-ignore"
mkdir -p "$NO_IGNORE_DIR"

result_code=0
stderr=$(cd "$NO_IGNORE_DIR" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" "$TMP_DIR/prompt.txt" 2>&1) || result_code=$?
assert_eq "Missing .codexignore → exit 2" "2" "$result_code"
assert_contains "Codexignore error" ".codexignore" "$stderr"

# ═══════════════════════════════════════════════════════════════
# 11. Valid model names
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Model Names ===\n"

for model in "gpt-5.3-codex" "gpt-5-codex" "gpt-5.3-codex-spark" "GPT-5.3-CODEX"; do
  stderr=$(cd "$MOCK_WORKSPACE" && PATH="$MOCK_BIN:$PATH" bash "$UNDER_TEST" -m "$model" "$TMP_DIR/prompt.txt" 2>&1) || true
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if echo "$stderr" | grep -q "not in allowlist"; then
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Valid model '%s' rejected\n" "$model"
  else
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Model '%s' accepted\n" "$model"
  fi
done

# ═══════════════════════════════════════════════════════════════
# 12. JSON mode fallback when jq missing
# ═══════════════════════════════════════════════════════════════
printf "\n=== JSON Mode jq Check ===\n"

# Script checks for jq when -j is passed
# We verify the check exists
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if grep -q 'jq.*not found' "$UNDER_TEST"; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Script has jq fallback for JSON mode\n"
else
  # The check is 'command -v jq' followed by JSON_MODE=0
  if grep -q 'JSON_MODE=0' "$UNDER_TEST"; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Script resets JSON_MODE when jq unavailable\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: No jq fallback for JSON mode\n"
  fi
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
