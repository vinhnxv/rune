#!/usr/bin/env bash
# test-advise-mcp-untrusted.sh — Tests for scripts/advise-mcp-untrusted.sh
#
# Usage: bash plugins/rune/scripts/tests/test-advise-mcp-untrusted.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/advise-mcp-untrusted.sh"

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

# ── Setup temp environment ──
TMPWORK=$(mktemp -d)
trap 'rm -rf "$TMPWORK"' EXIT

# Use a dedicated rate-limit dir to avoid interference with real state
RATE_TMPDIR="$TMPWORK/rate-tmp"
mkdir -p "$RATE_TMPDIR"

# Helper: run the hook with given JSON input, using isolated TMPDIR for rate limiting
run_hook() {
  local input="$1"
  local exit_code=0
  local stdout stderr
  stdout=$(printf '%s' "$input" | \
    RUNE_TRACE="" \
    TMPDIR="$RATE_TMPDIR" \
    bash "$HOOK_SCRIPT" 2>"$TMPWORK/stderr.tmp") || exit_code=$?
  stderr=$(cat "$TMPWORK/stderr.tmp" 2>/dev/null || true)
  printf '%s' "$exit_code" > "$TMPWORK/exit_code.tmp"
  printf '%s' "$stdout" > "$TMPWORK/stdout.tmp"
  printf '%s' "$stderr" > "$TMPWORK/stderr_out.tmp"
}

get_exit_code() { cat "$TMPWORK/exit_code.tmp" 2>/dev/null || echo "999"; }
get_stdout() { cat "$TMPWORK/stdout.tmp" 2>/dev/null || true; }
get_stderr() { cat "$TMPWORK/stderr_out.tmp" 2>/dev/null || true; }

# Clear rate limit files before each test group
clear_rate_limits() {
  rm -rf "$RATE_TMPDIR/rune-mcp-advise-"* 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# 1. Empty / Invalid Input
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Invalid Input ===\n"

# 1a. Empty stdin exits 0
run_hook ""
assert_eq "Empty stdin exits 0" "0" "$(get_exit_code)"

# 1b. Invalid JSON exits 0
run_hook "not-json"
assert_eq "Invalid JSON exits 0" "0" "$(get_exit_code)"

# 1c. JSON without tool_name exits 0
run_hook '{"some_field": "value"}'
assert_eq "Missing tool_name exits 0" "0" "$(get_exit_code)"

# 1d. Empty tool_name exits 0
run_hook '{"tool_name": ""}'
assert_eq "Empty tool_name exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 2. Non-MCP Tool Names → Silent Exit
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-MCP Tool Filtering ===\n"

clear_rate_limits

# 2a. Regular tool names exit silently
run_hook '{"tool_name": "Read"}'
assert_eq "Read tool exits 0" "0" "$(get_exit_code)"
STDOUT_2A=$(get_stdout)
assert_not_contains "Read tool produces no advisory" "additionalContext" "$STDOUT_2A"

# 2b. Bash tool
run_hook '{"tool_name": "Bash"}'
assert_eq "Bash tool exits 0" "0" "$(get_exit_code)"

# 2c. Edit tool
run_hook '{"tool_name": "Edit"}'
assert_eq "Edit tool exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 3. Context7 MCP Tool → Advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Context7 MCP Advisory ===\n"

clear_rate_limits

run_hook '{"tool_name": "mcp__plugin_rune_context7__resolve-library-id"}'
assert_eq "Context7 tool exits 0" "0" "$(get_exit_code)"

STDOUT_3=$(get_stdout)
assert_contains "Context7 advisory has hookSpecificOutput" "hookSpecificOutput" "$STDOUT_3"
assert_contains "Context7 advisory mentions UNTRUSTED" "UNTRUSTED" "$STDOUT_3"
assert_contains "Context7 advisory has PostToolUse hookEventName" "PostToolUse" "$STDOUT_3"
assert_contains "Context7 advisory mentions Context7" "Context7" "$STDOUT_3"

# ═══════════════════════════════════════════════════════════════
# 4. WebSearch/WebFetch Tool → Advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== WebSearch/WebFetch Advisory ===\n"

clear_rate_limits

run_hook '{"tool_name": "WebSearch"}'
assert_eq "WebSearch exits 0" "0" "$(get_exit_code)"

STDOUT_4=$(get_stdout)
assert_contains "WebSearch advisory mentions web content" "web content" "$STDOUT_4"
assert_contains "WebSearch advisory mentions UNTRUSTED" "UNTRUSTED" "$STDOUT_4"

# WebFetch
clear_rate_limits
run_hook '{"tool_name": "WebFetch"}'
assert_eq "WebFetch exits 0" "0" "$(get_exit_code)"

STDOUT_4B=$(get_stdout)
assert_contains "WebFetch advisory mentions web content" "web content" "$STDOUT_4B"

# ═══════════════════════════════════════════════════════════════
# 5. Figma MCP Tool → Advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Figma MCP Advisory ===\n"

clear_rate_limits

run_hook '{"tool_name": "mcp__plugin_rune_figma-to-react__figma_fetch_design"}'
assert_eq "Figma tool exits 0" "0" "$(get_exit_code)"

STDOUT_5=$(get_stdout)
assert_contains "Figma advisory mentions design data" "design data" "$STDOUT_5"
assert_contains "Figma advisory mentions UNTRUSTED" "UNTRUSTED" "$STDOUT_5"

# ═══════════════════════════════════════════════════════════════
# 6. Echo-Search MCP Tool → Advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Echo-Search MCP Advisory ===\n"

clear_rate_limits

run_hook '{"tool_name": "mcp__plugin_rune_echo-search__echo_search"}'
assert_eq "Echo-search tool exits 0" "0" "$(get_exit_code)"

STDOUT_6=$(get_stdout)
assert_contains "Echo-search advisory mentions echo memory" "echo memory" "$STDOUT_6"

# ═══════════════════════════════════════════════════════════════
# 7. Rate Limiting (Same Tool Class Within 30s)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Rate Limiting ===\n"

clear_rate_limits

# First call — produces advisory
run_hook '{"tool_name": "WebSearch"}'
STDOUT_7A=$(get_stdout)
assert_contains "First WebSearch call produces advisory" "UNTRUSTED" "$STDOUT_7A"

# Rate limiting is per-PPID (session). Each subshell gets a different PPID,
# so we test the mechanism by pre-creating the rate file with the hook's expected path.
# Instead, verify that the rate file was created in the rate dir.
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
RATE_FILES=$(find "$RATE_TMPDIR" -name "web-*" -type f 2>/dev/null | head -1)
if [[ -n "$RATE_FILES" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Rate limit file created for web tool class\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Rate limit file not created\n"
fi

# Different tool class — NOT rate-limited (produces its own advisory)
run_hook '{"tool_name": "mcp__plugin_rune_context7__resolve-library-id"}'
STDOUT_7C=$(get_stdout)
assert_contains "Different tool class not rate-limited" "UNTRUSTED" "$STDOUT_7C"

# ═══════════════════════════════════════════════════════════════
# 8. JSON Output Validity
# ═══════════════════════════════════════════════════════════════
printf "\n=== JSON Output Validity ===\n"

clear_rate_limits

run_hook '{"tool_name": "WebSearch"}'
STDOUT_8=$(get_stdout)

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$STDOUT_8" | jq empty 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Advisory output is valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Advisory output is not valid JSON: %q\n" "$STDOUT_8"
fi

# Validate JSON structure
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$STDOUT_8" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: hookEventName is PostToolUse\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: hookEventName mismatch\n"
fi

# ═══════════════════════════════════════════════════════════════
# 9. Tool Name Sanitization (SEC-003)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Tool Name Sanitization ===\n"

clear_rate_limits

# Tool name with special characters — should be sanitized but still classified
run_hook '{"tool_name": "WebSearch<script>alert(1)</script>"}'
assert_eq "Sanitized tool name exits 0" "0" "$(get_exit_code)"

# Tool name with extreme length
LONG_TOOL=$(python3 -c "print('mcp__plugin_rune_context7__' + 'x' * 500)")
clear_rate_limits
run_hook "{\"tool_name\": \"$LONG_TOOL\"}"
assert_eq "Long tool name exits 0" "0" "$(get_exit_code)"

# ═══════════════════════════════════════════════════════════════
# 10. Tool Name Included in Advisory (P2-FE-001)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Tool Name in Advisory ===\n"

clear_rate_limits

run_hook '{"tool_name": "mcp__plugin_rune_context7__query-docs"}'
STDOUT_10=$(get_stdout)
assert_contains "Advisory includes specific tool name" "mcp__plugin_rune_context7__query-docs" "$STDOUT_10"

# ═══════════════════════════════════════════════════════════════
# 11. Advisory Never Blocks (PostToolUse Cannot Block)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Advisory Never Blocks ===\n"

clear_rate_limits

# All exits should be 0, never 2
run_hook '{"tool_name": "WebSearch"}'
assert_eq "Advisory exit code is 0" "0" "$(get_exit_code)"
assert_not_contains "Advisory never denies" "permissionDecision" "$(get_stdout)"

# ═══════════════════════════════════════════════════════════════
# 12. Fail-Forward on Errors
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-Forward ===\n"

# Providing valid JSON but in a context that might trip up the script
# The script has an ERR trap that exits 0
run_hook '{"tool_name": "WebSearch", "unexpected_field": null}'
assert_eq "Unexpected fields handled gracefully" "0" "$(get_exit_code)"

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
