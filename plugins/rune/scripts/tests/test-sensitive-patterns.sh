#!/usr/bin/env bash
# test-sensitive-patterns.sh — Tests for scripts/lib/sensitive-patterns.sh
#
# Usage: bash plugins/rune/scripts/tests/test-sensitive-patterns.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Source the library under test ──
# shellcheck source=../lib/sensitive-patterns.sh
source "$LIB_DIR/sensitive-patterns.sh"

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

# ═══════════════════════════════════════════════════════════════
# 1. _SPAT_LIST population and structure
# ═══════════════════════════════════════════════════════════════
printf "\n=== _SPAT_LIST population ===\n"

# 1a. _SPAT_LIST has 16 entries
assert_eq "_SPAT_LIST has 16 entries" "16" "${#_SPAT_LIST[@]}"

# 1b. Each entry has label:regex format (contains at least one colon)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
all_have_colon=true
for entry in "${_SPAT_LIST[@]}"; do
  if [[ "$entry" != *":"* ]]; then
    all_have_colon=false
    break
  fi
done
if $all_have_colon; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: All _SPAT_LIST entries have label:regex format\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Some _SPAT_LIST entries missing label:regex format\n"
fi

# 1c. Known labels are present in _SPAT_LIST
for expected_label in openai_key anthropic_key aws_access_key aws_secret bearer_token github_pat pem_key ssh_key password_assign db_url api_key_assign jwt slack_token stripe_key google_api hex_token; do
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  found=false
  for entry in "${_SPAT_LIST[@]}"; do
    label="${entry%%:*}"
    if [[ "$label" == "$expected_label" ]]; then
      found=true
      break
    fi
  done
  if $found; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Label '%s' found in _SPAT_LIST\n" "$expected_label"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Label '%s' NOT found in _SPAT_LIST\n" "$expected_label"
  fi
done

# 1d. Labels are alphanumeric + underscore only (BACK-005 validation requirement)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
all_safe=true
for entry in "${_SPAT_LIST[@]}"; do
  label="${entry%%:*}"
  if [[ ! "$label" =~ ^[A-Za-z0-9_]+$ ]]; then
    all_safe=false
    printf "    Unsafe label found: %s\n" "$label"
    break
  fi
done
if $all_safe; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: All labels match safe pattern ^[A-Za-z0-9_]+$\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Some labels fail safe pattern validation\n"
fi

# 1e. Each regex is non-empty after the label
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
all_have_regex=true
for entry in "${_SPAT_LIST[@]}"; do
  regex="${entry#*:}"
  if [[ -z "$regex" ]]; then
    all_have_regex=false
    break
  fi
done
if $all_have_regex; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: All entries have non-empty regex\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Some entries have empty regex\n"
fi

# 1f. No duplicate labels
labels=()
for entry in "${_SPAT_LIST[@]}"; do
  labels+=("${entry%%:*}")
done
unique_count=$(printf '%s\n' "${labels[@]}" | sort -u | wc -l | tr -d ' ')
assert_eq "No duplicate labels in _SPAT_LIST" "16" "$unique_count"

# ═══════════════════════════════════════════════════════════════
# 2. Regex pattern validation (patterns compile under python3)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Regex pattern compilation ===\n"

# 2a. Each regex compiles individually in python3
for entry in "${_SPAT_LIST[@]}"; do
  label="${entry%%:*}"
  regex="${entry#*:}"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if python3 -c "import re; re.compile($(python3 -c "import sys; print(repr(sys.argv[1]))" "$regex"), re.IGNORECASE)" 2>/dev/null; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Regex compiles for '%s'\n" "$label"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Regex fails to compile for '%s'\n" "$label"
  fi
done

# ═══════════════════════════════════════════════════════════════
# 3. Regex patterns match expected targets (tested via python3)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Regex pattern matching ===\n"

# Helper: test a regex against text using python3 directly
# NOTE: Patterns use POSIX ERE syntax (designed for grep -E / sed -E).
# Python's re module does not support POSIX classes like [[:space:]].
# This helper auto-converts [[:space:]] to \s for Python compatibility.
_test_regex_match() {
  local label="$1" text="$2" should_match="$3"
  local regex=""
  for entry in "${_SPAT_LIST[@]}"; do
    if [[ "${entry%%:*}" == "$label" ]]; then
      regex="${entry#*:}"
      break
    fi
  done
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  local py_result
  py_result=$(python3 -c "
import re, sys
regex = sys.argv[1]
text = sys.argv[2]
# Convert POSIX classes to Python equivalents
regex = regex.replace('[[:space:]]', r'\s')
regex = regex.replace('[^[:space:]', r'[^\s')
try:
    m = re.search(regex, text, re.IGNORECASE)
    print('match' if m else 'no_match')
except re.error:
    print('error')
" "$regex" "$text" 2>/dev/null)

  if [[ "$should_match" == "yes" ]]; then
    if [[ "$py_result" == "match" ]]; then
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      printf "  PASS: '%s' matches expected target\n" "$label"
    else
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      printf "  FAIL: '%s' did NOT match expected target\n" "$label"
    fi
  else
    if [[ "$py_result" == "no_match" ]]; then
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      printf "  PASS: '%s' correctly rejects non-target\n" "$label"
    else
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      printf "  FAIL: '%s' incorrectly matched non-target\n" "$label"
    fi
  fi
}

# 3a. OpenAI key pattern
_test_regex_match "openai_key" "sk-abcdefghij1234567890extradata" "yes"
_test_regex_match "openai_key" "sk-short" "no"

# 3b. Anthropic key pattern
_test_regex_match "anthropic_key" "sk-ant-abcdefghij1234567890extra" "yes"
_test_regex_match "anthropic_key" "sk-ant-short" "no"

# 3c. AWS access key pattern
_test_regex_match "aws_access_key" "AKIAIOSFODNN7EXAMPLE" "yes"
_test_regex_match "aws_access_key" "NOTAKEY1234567890AB" "no"

# 3d. GitHub PAT pattern
_test_regex_match "github_pat" "ghp_ABCDEFGHIJklmnopqrstuvwxyz" "yes"
_test_regex_match "github_pat" "gho_ABCDEFGHIJklmnopqrstuvwxyz" "yes"
_test_regex_match "github_pat" "ghp_short" "no"

# 3e. PEM key header
_test_regex_match "pem_key" "-----BEGIN RSA PRIVATE KEY-----" "yes"
_test_regex_match "pem_key" "-----BEGIN EC PRIVATE KEY-----" "yes"
_test_regex_match "pem_key" "-----BEGIN PUBLIC KEY-----" "no"

# 3f. JWT token
_test_regex_match "jwt" "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL" "yes"
_test_regex_match "jwt" "not.a.jwt" "no"

# 3g. Slack token (runtime construction avoids GitHub Push Protection false positives)
_pfx_slack="xoxb-"
_sfx_slack="123456789012-abcdefghijklmnopqrstuvwxyz"
_test_regex_match "slack_token" "${_pfx_slack}${_sfx_slack}" "yes"
_test_regex_match "slack_token" "xoxb-short" "no"

# 3h. Stripe key (runtime construction avoids GitHub Push Protection false positives)
_pfx_stripe_live="sk_live_"
_pfx_stripe_test="sk_test_"
_sfx_stripe="abcdefghijklmnopqrstuvwxyz1234"
_test_regex_match "stripe_key" "${_pfx_stripe_live}${_sfx_stripe}" "yes"
_test_regex_match "stripe_key" "${_pfx_stripe_test}${_sfx_stripe}" "yes"
_test_regex_match "stripe_key" "sk_invalid_abc" "no"

# 3i. Google API key
_test_regex_match "google_api" "AIzaSyA1234567890abcdefghijklmnopqrstuv" "yes"
_test_regex_match "google_api" "AIzaShort" "no"

# 3j. Database URL
_test_regex_match "db_url" "postgres://admin:s3cr3t@db.example.com" "yes"
_test_regex_match "db_url" "mongodb://user:pass@mongo.host.com" "yes"
_test_regex_match "db_url" "http://example.com" "no"

# 3k. Password assignment
_test_regex_match "password_assign" "password=MySuperSecret123" "yes"
_test_regex_match "password_assign" "pwd: longpassword1234" "yes"
_test_regex_match "password_assign" "password=short" "no"

# ═══════════════════════════════════════════════════════════════
# 4. rune_strip_sensitive — truncation behavior
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_strip_sensitive — truncation ===\n"

# 4a. Default max_chars (2000) truncation
long_input=$(python3 -c "print('x' * 3000)")
result=$(printf '%s' "$long_input" | rune_strip_sensitive)
result_len=${#result}
assert_eq "Default max_chars truncation to 2000" "2000" "$result_len"

# 4b. Custom max_chars truncation
result=$(printf 'abcdefghij' | rune_strip_sensitive 5)
assert_eq "Custom max_chars truncation to 5" "abcde" "$result"

# 4c. Text shorter than max_chars is not truncated
result=$(printf 'short' | rune_strip_sensitive 100)
assert_eq "Short text not truncated" "short" "$result"

# 4d. Exact length text not truncated
result=$(printf '12345' | rune_strip_sensitive 5)
assert_eq "Exact-length text not truncated" "12345" "$result"

# 4e. max_chars=1 truncation
result=$(printf 'abcdefghij' | rune_strip_sensitive 1)
assert_eq "max_chars=1 truncation" "a" "$result"

# ═══════════════════════════════════════════════════════════════
# 5. rune_strip_sensitive — passthrough and edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_strip_sensitive — passthrough and edge cases ===\n"

# 5a. Normal text passes through unchanged
result=$(printf 'Hello world, this is safe text.' | rune_strip_sensitive)
assert_eq "Normal text passes through" "Hello world, this is safe text." "$result"

# 5b. Code snippet without secrets passes through
result=$(printf 'function add(a, b) { return a + b; }' | rune_strip_sensitive)
assert_eq "Code without secrets passes through" "function add(a, b) { return a + b; }" "$result"

# 5c. Empty input returns empty
result=$(printf '' | rune_strip_sensitive)
assert_eq "Empty input returns empty" "" "$result"

# 5d. Whitespace-only input passes through
result=$(printf '   ' | rune_strip_sensitive)
assert_eq "Whitespace-only input passes through" "   " "$result"

# 5e. Newlines in input preserved
result=$(printf 'line1\nline2\nline3' | rune_strip_sensitive)
assert_contains "Newlines preserved: line1" "line1" "$result"
assert_contains "Newlines preserved: line3" "line3" "$result"

# 5f. Special characters in safe text pass through
result=$(printf 'Hello! @#$%% ^&*()' | rune_strip_sensitive)
assert_contains "Special chars preserved" "Hello!" "$result"

# 5g. Unicode text passes through
result=$(printf 'Hello \xc3\xa9\xc3\xa0\xc3\xbc world' | rune_strip_sensitive)
assert_contains "Unicode text preserved" "Hello" "$result"

# 5h. Return code is 0 for successful invocations
printf 'safe text' | rune_strip_sensitive >/dev/null 2>&1
rc=$?
assert_eq "Exit code 0 on success" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 6. SENSITIVE_PATTERNS removal verification (CLD-DEAD-001)
# ═══════════════════════════════════════════════════════════════
printf "\n=== SENSITIVE_PATTERNS removal verification ===\n"

# 6a. Verify SENSITIVE_PATTERNS associative array does NOT exist (removed in CLD-DEAD-001)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if declare -p SENSITIVE_PATTERNS &>/dev/null; then
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: SENSITIVE_PATTERNS still exists — should have been removed (CLD-DEAD-001)\n"
else
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: SENSITIVE_PATTERNS removed (CLD-DEAD-001 verified)\n"
fi

# 6b. Verify _SPAT_LIST is readonly (CLD-SEC-003)
# declare -p shows "declare -ar" for readonly arrays (the 'r' flag)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if declare -p _SPAT_LIST 2>/dev/null | grep -q -- '-[a-zA-Z]*r'; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: _SPAT_LIST is readonly\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: _SPAT_LIST is not readonly\n"
fi

# 6c. Verify source guard works (XVER-001) — double-source should not error
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if source "$SCRIPT_DIR/../lib/sensitive-patterns.sh" 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Double-source does not error (XVER-001 verified)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Double-source causes error\n"
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
