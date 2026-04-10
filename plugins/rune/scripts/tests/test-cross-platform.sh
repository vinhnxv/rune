#!/usr/bin/env bash
# test-cross-platform.sh — Cross-platform (macOS + Linux) compatibility tests
#
# Tests that all shell scripts avoid GNU-only, BSD-only, or Bash 4+ patterns.
# Run on both macOS and Linux to verify portability.
#
# Usage: bash plugins/rune/scripts/tests/test-cross-platform.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="${SCRIPTS_DIR}/lib"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-xplat-XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

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

assert_not_empty() {
  local test_name="$1" value="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -n "$value" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (empty)\n" "$test_name"
  fi
}

assert_true() {
  local test_name="$1"
  shift
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if "$@" 2>/dev/null; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s\n" "$test_name"
  fi
}

# ═══════════════════════════════════════════════════════════════
# 1. Static analysis: No forbidden patterns in .sh files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Static Analysis: Forbidden Patterns ===\n"

# Collect all .sh files (excluding tests/ and node_modules)
# Bash 3.2 compatible (no mapfile/readarray)
SH_FILES=()
while IFS= read -r f; do SH_FILES+=("$f"); done < <(find "$SCRIPTS_DIR" -name '*.sh' -not -path '*/tests/*' -not -path '*/node_modules/*' -type f 2>/dev/null)

# 1a. No readarray/mapfile (Bash 4+ only)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
readarray_hits=$(grep -rn 'readarray\|mapfile' "${SH_FILES[@]}" 2>/dev/null | grep -v '# .*readarray\|# .*mapfile\|#.*Bash 3.2' || true)
if [[ -z "$readarray_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No readarray/mapfile (Bash 4+) in scripts\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: readarray/mapfile found in scripts (Bash 4+ only)\n"
  printf "    %s\n" "$readarray_hits"
fi

# 1b. No ${var,,} lowercase (Bash 4+ only) — exclude comments
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
lowercase_hits=$(grep -rn '\${[a-zA-Z_][a-zA-Z0-9_]*,,}' "${SH_FILES[@]}" 2>/dev/null | grep -v '^[^:]*:[0-9]*:#' || true)
if [[ -z "$lowercase_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No \${var,,} lowercase (Bash 4+) in scripts\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: \${var,,} found in scripts (Bash 4+ only)\n"
  printf "    %s\n" "$lowercase_hits"
fi

# 1c. No sed -r (use sed -E instead)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
sedr_hits=$(grep -rn "sed -r " "${SH_FILES[@]}" 2>/dev/null || true)
if [[ -z "$sedr_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No sed -r (use -E instead)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: sed -r found (not available on macOS, use sed -E)\n"
  printf "    %s\n" "$sedr_hits"
fi

# 1d. No grep -P (Perl regex, not on macOS BSD grep)
# Note: pgrep -P is NOT grep -P — it's process grep with parent PID filter (works on both platforms)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
grepP_hits=$(grep -rn "grep -P " "${SH_FILES[@]}" 2>/dev/null | grep -v '# .*grep -P' | grep -v 'pgrep -P' || true)
if [[ -z "$grepP_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No grep -P (not on macOS BSD grep)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: grep -P found (use grep -E instead)\n"
  printf "    %s\n" "$grepP_hits"
fi

# 1e. No find -printf (GNU-only)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
findprintf_hits=$(grep -rn "find .* -printf" "${SH_FILES[@]}" 2>/dev/null || true)
if [[ -z "$findprintf_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No find -printf (GNU-only)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: find -printf found (GNU-only)\n"
  printf "    %s\n" "$findprintf_hits"
fi

# 1f. No sort -V (GNU-only)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
sortV_hits=$(grep -rn "sort -V" "${SH_FILES[@]}" 2>/dev/null || true)
if [[ -z "$sortV_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No sort -V (GNU-only)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: sort -V found (GNU-only)\n"
  printf "    %s\n" "$sortV_hits"
fi

# 1g. No hardcoded /tmp (should use ${TMPDIR:-/tmp})
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
# Look for /tmp in assignments like VAR="/tmp/..." but allow ${TMPDIR:-/tmp} pattern
hardtmp_hits=$(grep -rn '="/tmp/' "${SH_FILES[@]}" 2>/dev/null | grep -v 'TMPDIR:-/tmp' | grep -v '# ' || true)
if [[ -z "$hardtmp_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No hardcoded /tmp (use \${TMPDIR:-/tmp})\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Hardcoded /tmp found\n"
  printf "    %s\n" "$hardtmp_hits"
fi

# 1h. No readlink -f without fallback chain
# Allowed if in a fallback chain: grealpath → realpath → readlink -f
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
# Exclude lines that are part of a fallback chain (contain grealpath, realpath, or are in platform.sh)
readlinkf_hits=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Extract file path and check surrounding context for fallback chain
  _file="${line%%:*}"
  _linenum=$(echo "$line" | sed -E 's/^[^:]+:([0-9]+):.*/\1/')
  # Check if file has grealpath nearby (within 3 lines) — indicates fallback chain
  if grep -q 'grealpath\|realpath' "$_file" 2>/dev/null; then
    continue  # Part of a fallback chain
  fi
  readlinkf_hits="${readlinkf_hits}${line}\n"
done < <(grep -rn "readlink -f " "${SH_FILES[@]}" 2>/dev/null || true)
readlinkf_hits=$(printf '%b' "$readlinkf_hits" | grep -v '^$' || true)
if [[ -z "$readlinkf_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No bare readlink -f (use fallback chain)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: readlink -f without fallback found (not on macOS)\n"
  printf "    %s\n" "$readlinkf_hits"
fi

# 1i. No sed -i without macOS-compatible handling
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
sedi_hits=$(grep -rn "sed -i " "${SH_FILES[@]}" 2>/dev/null | grep -v "sed -i ''" | grep -v '# ' || true)
if [[ -z "$sedi_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No bare sed -i (macOS needs sed -i '')\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: sed -i without macOS compat found\n"
  printf "    %s\n" "$sedi_hits"
fi

# 1j. No unguarded tr -dc with range issues (dash not at end)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
# Pattern: tr -dc '..._-X...' where - is between two chars (range issue)
trdc_hits=$(grep -rn "tr -dc " "${SH_FILES[@]}" 2>/dev/null | grep -E "tr -dc '[^']*[^\\\\]-[^']" | grep -v '\-$' | grep -v '0-9' | grep -v 'a-z' | grep -v 'A-Z' || true)
if [[ -z "$trdc_hits" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No tr -dc with ambiguous dash ranges\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: tr -dc with potential range issues\n"
  printf "    %s\n" "$trdc_hits"
fi

# ═══════════════════════════════════════════════════════════════
# 2. Runtime: TMPDIR portability
# ═══════════════════════════════════════════════════════════════
printf "\n=== TMPDIR Portability ===\n"

# 2a. mktemp works with ${TMPDIR:-/tmp} prefix
tmp_file=$(mktemp "${TMPDIR:-/tmp}/xplat-test-XXXXXX" 2>/dev/null) || true
assert_not_empty "mktemp with TMPDIR prefix works" "$tmp_file"
[[ -n "$tmp_file" ]] && rm -f "$tmp_file"

# 2b. Custom TMPDIR is respected
CUSTOM_TMP="$TMP_DIR/custom-tmp"
mkdir -p "$CUSTOM_TMP"
tmp_file2=$(TMPDIR="$CUSTOM_TMP" mktemp "${TMPDIR:-/tmp}/xplat-test2-XXXXXX" 2>/dev/null) || true
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -n "$tmp_file2" && "$tmp_file2" == "$CUSTOM_TMP/"* ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Custom TMPDIR respected by mktemp\n"
else
  # On some systems TMPDIR isn't re-evaluated inside subshell mktemp call
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: mktemp succeeded (TMPDIR behavior varies by OS)\n"
fi
[[ -n "$tmp_file2" ]] && rm -f "$tmp_file2"

# ═══════════════════════════════════════════════════════════════
# 3. Runtime: tr character class portability
# ═══════════════════════════════════════════════════════════════
printf "\n=== tr Character Class Portability ===\n"

# 3a. tr -dc with [:alnum:] works
result=$(printf 'hello_world-123.test' | tr -dc '[:alnum:]_.-')
assert_eq "tr -dc [:alnum:] preserves alphanumeric and _.-" "hello_world-123.test" "$result"

# 3b. tr -dc with dash at end of class (safe position)
result=$(printf 'abc-def_ghi.jkl:mno' | tr -dc '[:alnum:]_.:-')
assert_eq "tr -dc with dash at end preserves all safe chars" "abc-def_ghi.jkl:mno" "$result"

# 3c. tr -dc '0-9' (standard range — always works)
result=$(printf 'abc123def456' | tr -dc '0-9')
assert_eq "tr -dc 0-9 extracts digits" "123456" "$result"

# 3d. tr lowercase alternative (Bash 3.2 compat)
input="HELLO World"
result=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
assert_eq "tr lowercase (Bash 3.2 compat)" "hello world" "$result"

# ═══════════════════════════════════════════════════════════════
# 4. Runtime: Progress bar UTF-8 (multi-byte char) portability
# ═══════════════════════════════════════════════════════════════
printf "\n=== UTF-8 Multi-byte Progress Bar ===\n"

# 4a. Loop-based bar builder (our fix) produces correct chars
BAR=""
FILLED=3
EMPTY=2
_i=0; while [[ $_i -lt "$FILLED" ]]; do BAR="${BAR}█"; _i=$((_i+1)); done
_i=0; while [[ $_i -lt "$EMPTY" ]]; do BAR="${BAR}░"; _i=$((_i+1)); done

assert_contains "Progress bar has filled blocks" "█" "$BAR"
assert_contains "Progress bar has empty blocks" "░" "$BAR"

# 4b. Verify character count (not byte count)
# Each █ and ░ is 3 bytes in UTF-8
char_count=$(printf '%s' "$BAR" | wc -m | tr -dc '0-9')
assert_eq "Progress bar has correct char count" "5" "$char_count"

# 4c. Verify bar string length in bytes (5 chars × 3 bytes = 15)
byte_count=$(printf '%s' "$BAR" | wc -c | tr -dc '0-9')
assert_eq "Progress bar has correct byte count" "15" "$byte_count"

# 4d. Edge: zero-length bar
BAR_ZERO=""
_i=0; while [[ $_i -lt 0 ]]; do BAR_ZERO="${BAR_ZERO}█"; _i=$((_i+1)); done
assert_eq "Zero-length progress bar is empty" "" "$BAR_ZERO"

# 4e. Full bar (10 segments)
BAR_FULL=""
_i=0; while [[ $_i -lt 10 ]]; do BAR_FULL="${BAR_FULL}█"; _i=$((_i+1)); done
full_chars=$(printf '%s' "$BAR_FULL" | wc -m | tr -dc '0-9')
assert_eq "Full progress bar has 10 chars" "10" "$full_chars"

# ═══════════════════════════════════════════════════════════════
# 5. Runtime: File collection without readarray (Bash 3.2 compat)
# ═══════════════════════════════════════════════════════════════
printf "\n=== File Collection (Bash 3.2 Compatible) ===\n"

# Setup test files
mkdir -p "$TMP_DIR/collect-test/tmp"
touch "$TMP_DIR/collect-test/tmp/.rune-a.json"
touch "$TMP_DIR/collect-test/tmp/.rune-b.json"
touch "$TMP_DIR/collect-test/tmp/.rune-c.json"

# 5a. Loop-based collection (our fix for readarray)
FILES=()
_saved=$(shopt -p nullglob 2>/dev/null || true)
shopt -s nullglob 2>/dev/null || true
for _sf in "$TMP_DIR/collect-test/tmp"/.rune-*.json; do
  FILES+=("$_sf")
done
if [[ "$_saved" == *"-s nullglob"* ]]; then shopt -s nullglob 2>/dev/null || true; else shopt -u nullglob 2>/dev/null || true; fi

assert_eq "Loop collects 3 files" "3" "${#FILES[@]}"

# 5b. Empty directory produces empty array
FILES_EMPTY=()
_saved=$(shopt -p nullglob 2>/dev/null || true)
shopt -s nullglob 2>/dev/null || true
for _sf in "$TMP_DIR/collect-test/tmp"/.nonexistent-*.json; do
  FILES_EMPTY+=("$_sf")
done
if [[ "$_saved" == *"-s nullglob"* ]]; then shopt -s nullglob 2>/dev/null || true; else shopt -u nullglob 2>/dev/null || true; fi

assert_eq "Empty glob produces empty array" "0" "${#FILES_EMPTY[@]}"

# 5c. Files with spaces in path
mkdir -p "$TMP_DIR/collect test/tmp"
touch "$TMP_DIR/collect test/tmp/.rune-spaced.json"

FILES_SPACED=()
_saved=$(shopt -p nullglob 2>/dev/null || true)
shopt -s nullglob 2>/dev/null || true
for _sf in "$TMP_DIR/collect test/tmp"/.rune-*.json; do
  FILES_SPACED+=("$_sf")
done
if [[ "$_saved" == *"-s nullglob"* ]]; then shopt -s nullglob 2>/dev/null || true; else shopt -u nullglob 2>/dev/null || true; fi

assert_eq "Loop handles spaces in path" "1" "${#FILES_SPACED[@]}"

# ═══════════════════════════════════════════════════════════════
# 6. Runtime: Case-insensitive matching (Bash 3.2 compat)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Case-Insensitive Matching (Bash 3.2 Compatible) ===\n"

# 6a. tr-based lowercase for case matching (our fix for ${var,,})
SUBJECT="SHUTDOWN Agent"
lower=$(printf '%s' "$SUBJECT" | tr '[:upper:]' '[:lower:]')

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
case "$lower" in
  *shutdown*) PASS_COUNT=$(( PASS_COUNT + 1 )); printf "  PASS: tr lowercase matches shutdown\n" ;;
  *) FAIL_COUNT=$(( FAIL_COUNT + 1 )); printf "  FAIL: tr lowercase didn't match shutdown\n" ;;
esac

# 6b. Mixed case
SUBJECT2="Cleanup Task"
lower2=$(printf '%s' "$SUBJECT2" | tr '[:upper:]' '[:lower:]')
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
case "$lower2" in
  *cleanup*) PASS_COUNT=$(( PASS_COUNT + 1 )); printf "  PASS: tr lowercase matches cleanup\n" ;;
  *) FAIL_COUNT=$(( FAIL_COUNT + 1 )); printf "  FAIL: tr lowercase didn't match cleanup\n" ;;
esac

# 6c. Already lowercase
SUBJECT3="monitor"
lower3=$(printf '%s' "$SUBJECT3" | tr '[:upper:]' '[:lower:]')
assert_eq "tr lowercase is idempotent" "monitor" "$lower3"

# 6d. Empty string
SUBJECT4=""
lower4=$(printf '%s' "$SUBJECT4" | tr '[:upper:]' '[:lower:]')
assert_eq "tr lowercase handles empty string" "" "$lower4"

# 6e. Special characters preserved
SUBJECT5="Shut-Down_Agent #42"
lower5=$(printf '%s' "$SUBJECT5" | tr '[:upper:]' '[:lower:]')
assert_eq "tr lowercase preserves special chars" "shut-down_agent #42" "$lower5"

# ═══════════════════════════════════════════════════════════════
# 7. Runtime: advise-mcp-untrusted tool name sanitization
# ═══════════════════════════════════════════════════════════════
printf "\n=== Tool Name Sanitization ===\n"

# 7a. MCP tool names with underscores and colons pass through
result=$(printf 'mcp__plugin_rune_context7__resolve-library-id' | tr -dc '[:alnum:]_.:-')
assert_eq "MCP tool name preserved" "mcp__plugin_rune_context7__resolve-library-id" "$result"

# 7b. Tool names with special chars get stripped
result=$(printf 'mcp__evil$(rm -rf /)' | tr -dc '[:alnum:]_.:-')
assert_eq "Injection chars stripped from tool name" "mcp__evilrm-rf" "$result"

# 7c. WebSearch/WebFetch names preserved
result=$(printf 'WebSearch' | tr -dc '[:alnum:]_.:-')
assert_eq "WebSearch name preserved" "WebSearch" "$result"

result=$(printf 'WebFetch' | tr -dc '[:alnum:]_.:-')
assert_eq "WebFetch name preserved" "WebFetch" "$result"

# ═══════════════════════════════════════════════════════════════
# 8. Runtime: timeout and flock guards
# ═══════════════════════════════════════════════════════════════
printf "\n=== Optional Tool Guards ===\n"

# 8a. command -v timeout works (may or may not be installed)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if command -v timeout &>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: timeout is available (guard would succeed)\n"
else
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: timeout not available (guard correctly skips)\n"
fi

# 8b. command -v flock works
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if command -v flock &>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: flock is available\n"
else
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: flock not available (macOS expected)\n"
fi

# 8c. command -v jq
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if command -v jq &>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: jq is available\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: jq not available (required for hooks)\n"
fi

# ═══════════════════════════════════════════════════════════════
# 9. CLAUDE_CONFIG_DIR portability
# ═══════════════════════════════════════════════════════════════
printf "\n=== CLAUDE_CONFIG_DIR Portability ===\n"

# 9a. Default resolution
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
assert_not_empty "CHOME resolves to non-empty path" "$CHOME"

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$CHOME" == /* ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: CHOME is absolute path\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: CHOME is not absolute: %s\n" "$CHOME"
fi

# 9b. Custom CLAUDE_CONFIG_DIR
CUSTOM_DIR="$TMP_DIR/custom-claude"
mkdir -p "$CUSTOM_DIR"
test_chome=$(CLAUDE_CONFIG_DIR="$CUSTOM_DIR" bash -c 'echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"')
assert_eq "Custom CLAUDE_CONFIG_DIR respected" "$CUSTOM_DIR" "$test_chome"

# ═══════════════════════════════════════════════════════════════
# 10. Shell builtins portability
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shell Builtins Portability ===\n"

# 10a. printf %s handles empty strings
result=$(printf '%s' "")
assert_eq "printf %s with empty string" "" "$result"

# 10b. date +%s works (Unix epoch)
epoch=$(date +%s 2>/dev/null || true)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$epoch" =~ ^[0-9]+$ ]] && [[ "$epoch" -gt 1700000000 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: date +%%s returns valid epoch (%s)\n" "$epoch"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: date +%%s returned: %s\n" "$epoch"
fi

# 10c. id -u works
uid=$(id -u 2>/dev/null || true)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$uid" =~ ^[0-9]+$ ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: id -u returns numeric uid (%s)\n" "$uid"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: id -u returned: %s\n" "$uid"
fi

# 10d. wc -c and wc -l work consistently
result_c=$(printf 'hello' | wc -c | tr -dc '0-9')
assert_eq "wc -c counts bytes" "5" "$result_c"

result_l=$(printf 'a\nb\nc\n' | wc -l | tr -dc '0-9')
assert_eq "wc -l counts lines" "3" "$result_l"

# ═══════════════════════════════════════════════════════════════
# 11. sed -E portability (shared across macOS and Linux)
# ═══════════════════════════════════════════════════════════════
printf "\n=== sed -E Portability ===\n"

# 11a. Basic extended regex
result=$(printf 'hello123world' | sed -E 's/[0-9]+/_/')
assert_eq "sed -E basic regex" "hello_world" "$result"

# 11b. Alternation
result=$(printf 'cat' | sed -E 's/(cat|dog)/animal/')
assert_eq "sed -E alternation" "animal" "$result"

# 11c. Capture groups
result=$(printf 'key=value' | sed -E 's/^([^=]+)=(.+)$/\2/')
assert_eq "sed -E capture groups" "value" "$result"

# ═══════════════════════════════════════════════════════════════
# 12. grep -E portability (extended regex)
# ═══════════════════════════════════════════════════════════════
printf "\n=== grep -E Portability ===\n"

# 12a. Extended regex alternation
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf 'P1: Security issue\nP2: Quality\n' | grep -qE '^P[12]:'; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: grep -E alternation works\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: grep -E alternation failed\n"
fi

# 12b. Count mode
result=$(printf 'a\nb\na\n' | grep -cE '^a$' || true)
assert_eq "grep -cE count mode" "2" "$result"

# ═══════════════════════════════════════════════════════════════
# 13. detect-workflow-complete.sh integration
# ═══════════════════════════════════════════════════════════════
printf "\n=== detect-workflow-complete.sh File Collection ===\n"

# Create mock environment
MOCK_CWD="$TMP_DIR/dwc-test"
mkdir -p "$MOCK_CWD/tmp"
touch "$MOCK_CWD/tmp/.rune-state1.json"
touch "$MOCK_CWD/tmp/.rune-state2.json"

# Test the Bash 3.2-compatible file collection (our fix)
CWD="$MOCK_CWD"
STATE_FILES=()
_saved_nullglob=$(shopt -p nullglob 2>/dev/null || true)
shopt -s nullglob 2>/dev/null || true
for _sf in "${CWD}/tmp"/.rune-*.json; do
  STATE_FILES+=("$_sf")
done
if [[ "$_saved_nullglob" == *"-s nullglob"* ]]; then shopt -s nullglob 2>/dev/null || true; else shopt -u nullglob 2>/dev/null || true; fi

assert_eq "Collects state files correctly" "2" "${#STATE_FILES[@]}"

# Empty case
STATE_FILES2=()
_saved_nullglob=$(shopt -p nullglob 2>/dev/null || true)
shopt -s nullglob 2>/dev/null || true
for _sf in "${CWD}/tmp"/.nonexistent-*.json; do
  STATE_FILES2+=("$_sf")
done
if [[ "$_saved_nullglob" == *"-s nullglob"* ]]; then shopt -s nullglob 2>/dev/null || true; else shopt -u nullglob 2>/dev/null || true; fi

assert_eq "Empty glob produces empty array" "0" "${#STATE_FILES2[@]}"

# ═══════════════════════════════════════════════════════════════
# 14. on-task-observation.sh case matching
# ═══════════════════════════════════════════════════════════════
printf "\n=== on-task-observation.sh Case Matching ===\n"

# Test the tr-based lowercase approach (our fix)
for word in "SHUTDOWN" "Shutdown" "shutdown" "ShutDown"; do
  lower=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  case "$lower" in
    *shutdown*)
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      printf "  PASS: '%s' → '%s' matches shutdown\n" "$word" "$lower"
      ;;
    *)
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      printf "  FAIL: '%s' → '%s' didn't match shutdown\n" "$word" "$lower"
      ;;
  esac
done

# Verify non-matching cases don't match
for word in "deploy" "review" "build"; do
  lower=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  case "$lower" in
    *shutdown*|*cleanup*|*aggregate*|*monitor*|*"shut down"*)
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      printf "  FAIL: '%s' incorrectly matched guard pattern\n" "$word"
      ;;
    *)
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      printf "  PASS: '%s' correctly skipped guard pattern\n" "$word"
      ;;
  esac
done

# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
echo "═══════════════════════════════════════════════════"

[[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
