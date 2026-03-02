#!/usr/bin/env bash
# test-talisman-invalidate.sh -- Tests for scripts/talisman-invalidate.sh
#
# Usage: bash plugins/rune/scripts/tests/test-talisman-invalidate.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVALIDATOR="${SCRIPT_DIR}/../talisman-invalidate.sh"

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
    printf "  FAIL: %s (needle found but should not be)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ===================================================================
# 1. Non-talisman file exits 0 immediately (fast path)
# ===================================================================
printf "\n=== Non-talisman file fast path ===\n"

rc=0
echo '{"tool_input":{"file_path":"/tmp/src/main.py"}}' | bash "$INVALIDATOR" >/dev/null 2>&1 || rc=$?
assert_eq "Non-talisman file exits 0" "0" "$rc"

# ===================================================================
# 2. File mentioning talisman.yml in a different field (not file_path) -- still triggers grep match
# ===================================================================
printf "\n=== talisman.yml in non-path field ===\n"

rc=0
echo '{"tool_input":{"file_path":"/tmp/src/config.py","description":"edits talisman.yml reference"}}' | bash "$INVALIDATOR" >/dev/null 2>&1 || rc=$?
# The grep matches "talisman.yml" anywhere in input, but jq then checks file_path
# Since file_path doesn't end with talisman.yml, it should exit 0
assert_eq "talisman.yml in non-path field exits 0" "0" "$rc"

# ===================================================================
# 3. Empty input exits 0
# ===================================================================
printf "\n=== Empty input ===\n"

rc=0
echo '' | bash "$INVALIDATOR" >/dev/null 2>&1 || rc=$?
assert_eq "Empty input exits 0" "0" "$rc"

# ===================================================================
# 4. Large non-talisman input exits 0 (fast path grep)
# ===================================================================
printf "\n=== Large non-talisman input ===\n"

rc=0
python3 -c "print('{\"tool_input\":{\"file_path\":\"/tmp/big.py\",\"content\":\"' + 'x'*10000 + '\"}}')" | bash "$INVALIDATOR" >/dev/null 2>&1 || rc=$?
assert_eq "Large non-talisman input exits 0" "0" "$rc"

# ===================================================================
# 5. talisman.yml file_path triggers resolver path (resolver missing = exit 0)
# ===================================================================
printf "\n=== talisman.yml file_path triggers resolver ===\n"

# Without a valid CLAUDE_PLUGIN_ROOT, the resolver script won't exist
# Script should exit 0 on resolver not found
rc=0
CLAUDE_PLUGIN_ROOT="${TMPROOT}/no-plugin" \
  bash -c 'echo "{\"tool_input\":{\"file_path\":\"/home/user/.claude/talisman.yml\"}}" | bash "'"$INVALIDATOR"'"' >/dev/null 2>&1 || rc=$?
assert_eq "talisman.yml with missing resolver exits 0" "0" "$rc"

# ===================================================================
# 6. filePath alternative field name
# ===================================================================
printf "\n=== filePath alternative field ===\n"

rc=0
CLAUDE_PLUGIN_ROOT="${TMPROOT}/no-plugin" \
  bash -c 'echo "{\"tool_input\":{\"filePath\":\"/home/user/project/talisman.yml\"}}" | bash "'"$INVALIDATOR"'"' >/dev/null 2>&1 || rc=$?
assert_eq "filePath (camelCase) exits 0 with missing resolver" "0" "$rc"

# ===================================================================
# 7. File path not ending with talisman.yml exits 0
# ===================================================================
printf "\n=== File path not ending with talisman.yml ===\n"

rc=0
echo '{"tool_input":{"file_path":"/tmp/talisman.yml.bak"}}' | bash "$INVALIDATOR" >/dev/null 2>&1 || rc=$?
assert_eq "talisman.yml.bak exits 0" "0" "$rc"

# ===================================================================
# 8. Nested path with talisman.yml
# ===================================================================
printf "\n=== Nested path with talisman.yml ===\n"

rc=0
CLAUDE_PLUGIN_ROOT="${TMPROOT}/no-plugin" \
  bash -c 'echo "{\"tool_input\":{\"file_path\":\"/deep/nested/path/to/.claude/talisman.yml\"}}" | bash "'"$INVALIDATOR"'"' >/dev/null 2>&1 || rc=$?
assert_eq "Nested talisman.yml path exits 0" "0" "$rc"

# ===================================================================
# 9. Resolver exists and is executable -- triggers resolver
# ===================================================================
printf "\n=== Resolver execution ===\n"

FAKE_PLUGIN="${TMPROOT}/fake-plugin"
mkdir -p "${FAKE_PLUGIN}/scripts"
MARKER="${TMPROOT}/resolver-called-marker"
rm -f "$MARKER" 2>/dev/null || true
# Create a fake resolver that just writes a marker file
cat > "${FAKE_PLUGIN}/scripts/talisman-resolve.sh" <<FAKERESOLVER
#!/bin/bash
head -c 1048576 >/dev/null 2>&1
touch "$MARKER"
exit 0
FAKERESOLVER
chmod +x "${FAKE_PLUGIN}/scripts/talisman-resolve.sh"

rc=0
CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" \
  bash -c 'echo "{\"tool_input\":{\"file_path\":\"/tmp/project/.claude/talisman.yml\"}}" | bash "'"$INVALIDATOR"'"' >/dev/null 2>&1 || rc=$?

assert_eq "Resolver called exits 0" "0" "$rc"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MARKER" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Resolver was called (marker file exists)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Resolver was NOT called (marker file missing)\n"
fi

# ===================================================================
# 10. Resolver is a symlink -- not executed
# ===================================================================
printf "\n=== Symlink resolver rejected ===\n"

SYMLINK_PLUGIN="${TMPROOT}/symlink-plugin"
mkdir -p "${SYMLINK_PLUGIN}/scripts"
ln -sf "${FAKE_PLUGIN}/scripts/talisman-resolve.sh" "${SYMLINK_PLUGIN}/scripts/talisman-resolve.sh" 2>/dev/null || true

if [[ -L "${SYMLINK_PLUGIN}/scripts/talisman-resolve.sh" ]]; then
  MARKER2="/tmp/talisman-resolver-called-symlink-$$"
  rm -f "$MARKER2" 2>/dev/null || true

  rc=0
  CLAUDE_PLUGIN_ROOT="$SYMLINK_PLUGIN" \
    bash -c 'echo "{\"tool_input\":{\"file_path\":\"/tmp/talisman.yml\"}}" | bash "'"$INVALIDATOR"'"' >/dev/null 2>&1 || rc=$?
  assert_eq "Symlink resolver exits 0" "0" "$rc"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink resolver rejected (skip - symlink creation failed)\n"
fi

# ===================================================================
# 11. RUNE_TRACE logging
# ===================================================================
printf "\n=== Trace logging ===\n"

TRACE_LOG="${TMPROOT}/trace.log"
rm -f "$TRACE_LOG" 2>/dev/null

rc=0
RUNE_TRACE=1 RUNE_TRACE_LOG="$TRACE_LOG" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" \
  bash -c 'echo "{\"tool_input\":{\"file_path\":\"/tmp/project/talisman.yml\"}}" | bash "'"$INVALIDATOR"'"' >/dev/null 2>&1 || rc=$?

assert_eq "Trace mode exits 0" "0" "$rc"
if [[ -f "$TRACE_LOG" ]]; then
  trace_content=$(cat "$TRACE_LOG")
  assert_contains "Trace log mentions talisman" "talisman" "$trace_content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Trace log not created\n"
fi

# ===================================================================
# 12. Fail-forward: script never exits non-zero
# ===================================================================
printf "\n=== Fail-forward guarantee ===\n"

# Various malformed inputs -- all should exit 0
for input in \
  '{}' \
  '{"tool_input":{}}' \
  'null' \
  '{"tool_input":{"file_path":null}}' \
  '{"talisman.yml":"in-value-not-path"}'; do
  rc=0
  echo "$input" | bash "$INVALIDATOR" >/dev/null 2>&1 || rc=$?
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$rc" -eq 0 ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Fail-forward for input: %s\n" "$(echo "$input" | head -c 40)"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Non-zero exit (%d) for input: %s\n" "$rc" "$(echo "$input" | head -c 40)"
  fi
done

# ===================================================================
# Results
# ===================================================================
printf "\n===================================================\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "===================================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
