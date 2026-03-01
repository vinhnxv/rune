#!/usr/bin/env bash
# test-sanitize-text.sh — Tests for scripts/lib/sanitize-text.sh
#
# Usage: bash plugins/rune/scripts/tests/test-sanitize-text.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Source the library under test ──
# shellcheck source=../lib/sanitize-text.sh
source "$LIB_DIR/sanitize-text.sh"

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
# 1. sanitize_untrusted_text
# ═══════════════════════════════════════════════════════════════
printf "\n=== sanitize_untrusted_text ===\n"

# 1a. HTML comments stripped
result=$(printf '<!-- evil comment -->safe text' | sanitize_untrusted_text)
assert_eq "HTML comments stripped" "safe text" "$result"

# 1b. Nested HTML comments
result=$(printf '<!-- outer <!-- inner --> end -->still here' | sanitize_untrusted_text)
assert_not_contains "Nested HTML comments stripped" "<!--" "$result"

# 1c. Code fences neutralized
result=$(printf 'before\n```\ncode block\n```\nafter' | sanitize_untrusted_text)
assert_not_contains "Code fences neutralized" '```' "$result"
assert_contains "Text around code fences preserved" "before" "$result"
assert_contains "Text after code fences preserved" "after" "$result"

# 1d. Zero-width characters removed (U+200B zero-width space)
result=$(printf 'hel\xe2\x80\x8blo' | sanitize_untrusted_text)
assert_eq "Zero-width chars removed" "hello" "$result"

# 1e. Unicode directional overrides stripped (U+202E right-to-left override)
result=$(printf 'abc\xe2\x80\xaedef' | sanitize_untrusted_text)
assert_eq "Directional overrides stripped" "abcdef" "$result"

# 1f. HTML entities unescaped
result=$(printf '&lt;script&gt;alert(1)&lt;/script&gt;' | sanitize_untrusted_text)
assert_contains "HTML entities unescaped" "<script>" "$result"
assert_not_contains "No raw &lt; remaining" "&lt;" "$result"

# 1g. max_chars truncation
result=$(printf 'abcdefghij' | sanitize_untrusted_text 5)
assert_eq "max_chars truncation to 5" "abcde" "$result"

# 1h. Default max_chars (2000) — long text
long_input=$(python3 -c "print('x' * 3000)")
result=$(printf '%s' "$long_input" | sanitize_untrusted_text)
result_len=${#result}
assert_eq "Default max_chars truncation to 2000" "2000" "$result_len"

# 1i. Empty input
result=$(printf '' | sanitize_untrusted_text)
assert_eq "Empty input returns empty" "" "$result"

# 1j. Binary input graceful degradation (null bytes)
result=$(printf 'hello\x00world' | sanitize_untrusted_text 2>/dev/null)
exit_code=$?
# Should not crash — either returns sanitized text or [UNSANITIZED] fallback
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ $exit_code -eq 0 ]] || [[ -n "$result" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Binary input graceful degradation\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Binary input graceful degradation (crashed)\n"
fi

# 1k. Image syntax stripped
result=$(printf '![alt text](http://evil.com/img.png)' | sanitize_untrusted_text)
assert_not_contains "Image syntax stripped" "![" "$result"
assert_contains "Image alt text preserved" "alt text" "$result"

# 1l. Heading markers stripped
result=$(printf '## Heading Two\n### Heading Three' | sanitize_untrusted_text)
assert_not_contains "Heading ## stripped" "## " "$result"
assert_contains "Heading text preserved" "Heading Two" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. sanitize_plan_content
# ═══════════════════════════════════════════════════════════════
printf "\n=== sanitize_plan_content ===\n"

# 2a. YAML frontmatter stripped
result=$(printf -- '---\ntitle: Evil Plan\nstatus: draft\n---\nActual content here' | sanitize_plan_content)
assert_not_contains "YAML frontmatter stripped" "title: Evil Plan" "$result"
assert_contains "Content after frontmatter preserved" "Actual content here" "$result"

# 2b. HTML comments stripped (inherited from sanitize_untrusted_text)
result=$(printf '<!-- hidden -->visible' | sanitize_plan_content)
assert_eq "HTML comments stripped in plan" "visible" "$result"

# 2c. Code fences neutralized (inherited)
result=$(printf 'start\n```\nhidden\n```\nend' | sanitize_plan_content)
assert_not_contains "Code fences neutralized in plan" '```' "$result"

# 2d. Zero-width chars removed (inherited)
result=$(printf 'ab\xe2\x80\x8bcd' | sanitize_plan_content)
assert_eq "Zero-width chars removed in plan" "abcd" "$result"

# 2e. NFC normalization applied (e with combining acute -> e-acute)
# U+0065 (e) + U+0301 (combining acute) -> U+00E9 (e-acute) in NFC
decomposed=$(printf '\x65\xcc\x81')  # e + combining acute (NFD)
composed=$(printf '\xc3\xa9')        # e-acute (NFC)
result=$(printf '%s' "$decomposed" | sanitize_plan_content)
assert_eq "NFC normalization applied" "$composed" "$result"

# 2f. max_chars truncation (default 4000)
long_input=$(python3 -c "print('y' * 5000)")
result=$(printf '%s' "$long_input" | sanitize_plan_content)
result_len=${#result}
assert_eq "Plan default max_chars 4000" "4000" "$result_len"

# 2g. Custom max_chars
result=$(printf 'abcdefghij' | sanitize_plan_content 3)
assert_eq "Plan custom max_chars 3" "abc" "$result"

# 2h. Empty input
result=$(printf '' | sanitize_plan_content)
assert_eq "Plan empty input returns empty" "" "$result"

# 2i. Binary input graceful degradation
result=$(printf 'hello\x00world' | sanitize_plan_content 2>/dev/null)
exit_code=$?
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ $exit_code -eq 0 ]] || [[ -n "$result" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Plan binary input graceful degradation\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Plan binary input graceful degradation (crashed)\n"
fi

# ═══════════════════════════════════════════════════════════════
# 3. normalize_unicode_nfc
# ═══════════════════════════════════════════════════════════════
printf "\n=== normalize_unicode_nfc ===\n"

# 3a. Composed vs decomposed equivalence
decomposed=$(printf '\x65\xcc\x81')  # e + combining acute (NFD)
composed=$(printf '\xc3\xa9')        # e-acute (NFC)
result=$(printf '%s' "$decomposed" | normalize_unicode_nfc)
assert_eq "NFD -> NFC normalization" "$composed" "$result"

# 3b. Already-composed passthrough
result=$(printf '%s' "$composed" | normalize_unicode_nfc)
assert_eq "NFC passthrough" "$composed" "$result"

# 3c. ASCII passthrough
result=$(printf 'Hello World 123' | normalize_unicode_nfc)
assert_eq "ASCII passthrough" "Hello World 123" "$result"

# 3d. Mixed ASCII + Unicode
mixed_input=$(printf 'caf\x65\xcc\x81')  # "cafe" with decomposed e-acute
expected=$(printf 'caf\xc3\xa9')          # "cafe" with composed e-acute
result=$(printf '%s' "$mixed_input" | normalize_unicode_nfc)
assert_eq "Mixed ASCII + Unicode NFC" "$expected" "$result"

# 3e. Empty input
result=$(printf '' | normalize_unicode_nfc)
assert_eq "NFC empty input" "" "$result"

# 3f. Binary input graceful degradation
result=$(printf 'test\x00data' | normalize_unicode_nfc 2>/dev/null)
exit_code=$?
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ $exit_code -eq 0 ]] || [[ -n "$result" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: NFC binary input graceful degradation\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: NFC binary input graceful degradation (crashed)\n"
fi

# ═══════════════════════════════════════════════════════════════
# 4. detect_homoglyphs_tier_ab
# ═══════════════════════════════════════════════════════════════
printf "\n=== detect_homoglyphs_tier_ab ===\n"

# 4a. Latin-only returns detected:false
result=$(printf 'Hello World' | detect_homoglyphs_tier_ab)
assert_contains "Latin-only detected:false" '"detected": false' "$result"

# 4b. Mixed Latin+Cyrillic returns detected:true
# U+0410 = Cyrillic A (looks like Latin A)
result=$(printf 'Hello \xd0\x90 World' | detect_homoglyphs_tier_ab)
assert_contains "Latin+Cyrillic detected:true" '"detected": true' "$result"

# 4c. Mixed Latin+Greek returns detected:true
# U+0391 = Greek Alpha (looks like Latin A)
result=$(printf 'Hello \xce\x91 World' | detect_homoglyphs_tier_ab)
assert_contains "Latin+Greek detected:true" '"detected": true' "$result"

# 4d. Empty input
result=$(printf '' | detect_homoglyphs_tier_ab)
assert_contains "Empty input detected:false" '"detected": false' "$result"

# 4e. JSON output format validation — has "detected" key
result=$(printf 'test' | detect_homoglyphs_tier_ab)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
# Validate JSON structure with python3
if printf '%s' "$result" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "detected" in d and "details" in d' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: JSON output has detected and details keys\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: JSON output format (missing detected or details key)\n"
  printf "    output: %s\n" "$result"
fi

# 4f. Cyrillic details include char info
result=$(printf 'abc\xd0\xb0' | detect_homoglyphs_tier_ab)  # Cyrillic small a
assert_contains "Cyrillic details include script field" '"script": "Cyrillic"' "$result"

# 4g. Pure numbers/symbols — no scripts detected
result=$(printf '12345 !@#$%%' | detect_homoglyphs_tier_ab)
assert_contains "Numbers-only detected:false" '"detected": false' "$result"

# 4h. Greek details include char info
result=$(printf 'text\xce\xb1' | detect_homoglyphs_tier_ab)  # Greek small alpha
assert_contains "Greek details include script field" '"script": "Greek"' "$result"

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
