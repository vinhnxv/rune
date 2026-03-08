#!/usr/bin/env bash
# test-platform.sh — Tests for scripts/lib/platform.sh cross-platform helpers
#
# Usage: bash plugins/rune/scripts/tests/test-platform.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Source platform.sh ──
source "${LIB_DIR}/platform.sh"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-platform-XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

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
    printf "  FAIL: %s (expected='%s', actual='%s')\n" "$test_name" "$expected" "$actual"
  fi
}

assert_nonzero() {
  local test_name="$1"
  local actual="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -n "$actual" && "$actual" != "0" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (got '%s')\n" "$test_name" "$actual"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected nonzero, got '%s')\n" "$test_name" "$actual"
  fi
}

assert_numeric() {
  local test_name="$1"
  local actual="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$actual" =~ ^[0-9]+$ ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (got '%s')\n" "$test_name" "$actual"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected numeric, got '%s')\n" "$test_name" "$actual"
  fi
}

assert_gt() {
  local test_name="$1"
  local threshold="$2"
  local actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -gt "$threshold" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (%s > %s)\n" "$test_name" "$actual" "$threshold"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected > %s, got '%s')\n" "$test_name" "$threshold" "$actual"
  fi
}

assert_lt() {
  local test_name="$1"
  local threshold="$2"
  local actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -lt "$threshold" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s (%s < %s)\n" "$test_name" "$actual" "$threshold"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected < %s, got '%s')\n" "$test_name" "$threshold" "$actual"
  fi
}

assert_startswith() {
  local test_name="$1"
  local prefix="$2"
  local actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$actual" == "$prefix"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (expected prefix='%s', actual='%s')\n" "$test_name" "$prefix" "$actual"
  fi
}

# ═══════════════════════════════════════════════════════════
echo "=== _RUNE_PLATFORM detection ==="
# ═══════════════════════════════════════════════════════════

os_name="$(uname -s 2>/dev/null)"
if [[ "$os_name" == "Darwin" ]]; then
  assert_eq "Platform detected as darwin on macOS" "darwin" "$_RUNE_PLATFORM"
else
  assert_eq "Platform detected as linux on Linux" "linux" "$_RUNE_PLATFORM"
fi

# Verify it's one of the two valid values
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$_RUNE_PLATFORM" == "darwin" || "$_RUNE_PLATFORM" == "linux" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Platform is valid enum value\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Platform is unexpected value '%s'\n" "$_RUNE_PLATFORM"
fi

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _stat_mtime ==="
# ═══════════════════════════════════════════════════════════

touch "$TMP_DIR/testfile"
mtime=$(_stat_mtime "$TMP_DIR/testfile")
assert_numeric "stat_mtime returns numeric epoch" "$mtime"
assert_nonzero "stat_mtime returns nonzero for existing file" "$mtime"

# mtime should be recent (within last 60 seconds)
now_s=$(date +%s)
mtime_diff=$(( now_s - mtime ))
[[ $mtime_diff -lt 0 ]] && mtime_diff=$(( -mtime_diff ))
assert_lt "stat_mtime is recent (within 60s of now)" 60 "$mtime_diff"

# Non-existent file returns empty
mtime_bad=$(_stat_mtime "$TMP_DIR/nonexistent" || true)
assert_eq "stat_mtime returns empty for missing file" "" "$mtime_bad"

# Directory mtime
mkdir -p "$TMP_DIR/testdir"
mtime_dir=$(_stat_mtime "$TMP_DIR/testdir")
assert_numeric "stat_mtime works on directories" "$mtime_dir"

# File with spaces in name
touch "$TMP_DIR/file with spaces.txt"
mtime_spaces=$(_stat_mtime "$TMP_DIR/file with spaces.txt")
assert_numeric "stat_mtime handles spaces in filename" "$mtime_spaces"

# File with special characters
touch "$TMP_DIR/file-with-dashes_and_underscores.txt"
mtime_special=$(_stat_mtime "$TMP_DIR/file-with-dashes_and_underscores.txt")
assert_numeric "stat_mtime handles dashes and underscores" "$mtime_special"

# Symlink (stat follows symlinks by default)
ln -sf "$TMP_DIR/testfile" "$TMP_DIR/symlink"
mtime_sym=$(_stat_mtime "$TMP_DIR/symlink")
assert_numeric "stat_mtime works on symlinks" "$mtime_sym"

# Broken symlink — behavior varies by platform
# Linux stat follows the symlink (fails) OR stats the symlink itself (succeeds)
# macOS stat -f follows the symlink (fails on broken)
# Both are valid — just verify it doesn't crash
ln -sf "$TMP_DIR/does-not-exist" "$TMP_DIR/broken-symlink"
mtime_broken=$(_stat_mtime "$TMP_DIR/broken-symlink" || true)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -z "$mtime_broken" || "$mtime_broken" =~ ^[0-9]+$ ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: stat_mtime on broken symlink returns empty or numeric (got '%s')\n" "$mtime_broken"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: stat_mtime on broken symlink returned non-numeric non-empty '%s'\n" "$mtime_broken"
fi

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _stat_uid ==="
# ═══════════════════════════════════════════════════════════

uid=$(_stat_uid "$TMP_DIR/testfile")
assert_numeric "stat_uid returns numeric uid" "$uid"

# UID should match current user
my_uid=$(id -u)
assert_eq "stat_uid matches current user" "$my_uid" "$uid"

uid_bad=$(_stat_uid "$TMP_DIR/nonexistent" || true)
assert_eq "stat_uid returns empty for missing file" "" "$uid_bad"

# Directory uid
uid_dir=$(_stat_uid "$TMP_DIR/testdir")
assert_eq "stat_uid works on directories" "$my_uid" "$uid_dir"

# File with spaces
uid_spaces=$(_stat_uid "$TMP_DIR/file with spaces.txt")
assert_eq "stat_uid handles spaces in filename" "$my_uid" "$uid_spaces"

# Symlink uid
uid_sym=$(_stat_uid "$TMP_DIR/symlink")
assert_numeric "stat_uid works on symlinks" "$uid_sym"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch — basic timestamps ==="
# ═══════════════════════════════════════════════════════════

# Unix epoch zero
result=$(_parse_iso_epoch "1970-01-01T00:00:00Z")
assert_eq "parse_iso_epoch Unix epoch" "0" "$result"

# Known timestamp: 2024-01-01T00:00:00Z = 1704067200
result=$(_parse_iso_epoch "2024-01-01T00:00:00Z")
assert_eq "parse_iso_epoch 2024-01-01T00:00:00Z" "1704067200" "$result"

# Another known: 2026-03-08T12:30:00Z = 1772973000
result=$(_parse_iso_epoch "2026-03-08T12:30:00Z")
assert_eq "parse_iso_epoch 2026-03-08T12:30:00Z" "1772973000" "$result"

# Year 2000 boundary
result=$(_parse_iso_epoch "2000-01-01T00:00:00Z")
assert_eq "parse_iso_epoch Y2K boundary" "946684800" "$result"

# Midnight vs noon same day
midnight=$(_parse_iso_epoch "2024-06-15T00:00:00Z")
noon=$(_parse_iso_epoch "2024-06-15T12:00:00Z")
assert_numeric "parse_iso_epoch midnight is numeric" "$midnight"
assert_numeric "parse_iso_epoch noon is numeric" "$noon"
diff_hours=$(( (noon - midnight) / 3600 ))
assert_eq "parse_iso_epoch noon - midnight = 12 hours" "12" "$diff_hours"

# End of day
eod=$(_parse_iso_epoch "2024-06-15T23:59:59Z")
assert_numeric "parse_iso_epoch end-of-day is numeric" "$eod"
diff_eod=$(( eod - midnight ))
assert_eq "parse_iso_epoch 23:59:59 - 00:00:00 = 86399s" "86399" "$diff_eod"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch — fractional seconds ==="
# ═══════════════════════════════════════════════════════════

# JavaScript toISOString() format: .000Z
result=$(_parse_iso_epoch "2024-01-01T00:00:00.000Z")
assert_eq "parse_iso_epoch strips .000Z" "1704067200" "$result"

# 3-digit millis
result=$(_parse_iso_epoch "2024-01-01T00:00:00.123Z")
assert_eq "parse_iso_epoch strips .123Z" "1704067200" "$result"

# 6-digit micros
result=$(_parse_iso_epoch "2024-01-01T00:00:00.123456Z")
assert_eq "parse_iso_epoch strips .123456Z (microseconds)" "1704067200" "$result"

# 9-digit nanos
result=$(_parse_iso_epoch "2024-01-01T00:00:00.123456789Z")
assert_eq "parse_iso_epoch strips .123456789Z (nanoseconds)" "1704067200" "$result"

# Single digit fractional
result=$(_parse_iso_epoch "2024-01-01T00:00:00.1Z")
assert_eq "parse_iso_epoch strips .1Z (single digit)" "1704067200" "$result"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch — timezone offsets ==="
# ═══════════════════════════════════════════════════════════

# +00:00 offset
result=$(_parse_iso_epoch "2024-01-01T00:00:00+00:00")
assert_numeric "parse_iso_epoch with +00:00 is numeric" "$result"

# The function strips the offset and treats as UTC-ish
# Just verify it returns a reasonable epoch (within a day of known value)
diff_tz=$(( result - 1704067200 ))
[[ $diff_tz -lt 0 ]] && diff_tz=$(( -diff_tz ))
assert_lt "parse_iso_epoch +00:00 within 1 day of expected" 86400 "$diff_tz"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch — invalid/edge inputs ==="
# ═══════════════════════════════════════════════════════════

# Empty string
result=$(_parse_iso_epoch "")
assert_eq "parse_iso_epoch empty string → 0" "0" "$result"

# Null string
result=$(_parse_iso_epoch "null")
assert_eq "parse_iso_epoch 'null' → 0" "0" "$result"

# Random garbage
result=$(_parse_iso_epoch "not-a-date")
assert_eq "parse_iso_epoch garbage → 0" "0" "$result"

# Partial timestamp
result=$(_parse_iso_epoch "2024-01-01")
# May parse or may not — just verify it returns something numeric or 0
assert_numeric "parse_iso_epoch partial date is numeric" "$result"

# Only time, no date
result=$(_parse_iso_epoch "12:30:00Z")
assert_numeric "parse_iso_epoch time-only is numeric (may be 0)" "$result"

# Empty Z
result=$(_parse_iso_epoch "Z")
assert_numeric "parse_iso_epoch bare Z is numeric (expect 0)" "$result"

# Very long string (potential injection — should not crash)
long_str=$(printf 'A%.0s' {1..200})
result=$(_parse_iso_epoch "$long_str")
assert_eq "parse_iso_epoch very long string → 0" "0" "$result"

# String with newlines (should not crash)
result=$(_parse_iso_epoch $'2024-01-01T00:00:00Z\ninjection')
assert_numeric "parse_iso_epoch with embedded newline is numeric" "$result"

# String with shell metacharacters
result=$(_parse_iso_epoch '$(echo pwned)')
assert_eq "parse_iso_epoch shell injection attempt → 0" "0" "$result"

result=$(_parse_iso_epoch '`echo pwned`')
assert_eq "parse_iso_epoch backtick injection attempt → 0" "0" "$result"

# Negative year (should return 0 or fail gracefully)
result=$(_parse_iso_epoch "-0001-01-01T00:00:00Z")
assert_numeric "parse_iso_epoch negative year is numeric" "$result"

# Far future
result=$(_parse_iso_epoch "2099-12-31T23:59:59Z")
assert_numeric "parse_iso_epoch far future is numeric" "$result"
assert_gt "parse_iso_epoch far future > current epoch" "$(date +%s)" "$result"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch — consistency ==="
# ═══════════════════════════════════════════════════════════

# Same input called twice should return same result
r1=$(_parse_iso_epoch "2024-06-15T10:30:00Z")
r2=$(_parse_iso_epoch "2024-06-15T10:30:00Z")
assert_eq "parse_iso_epoch deterministic (same input → same output)" "$r1" "$r2"

# Ordering: earlier date should have smaller epoch
early=$(_parse_iso_epoch "2024-01-01T00:00:00Z")
late=$(_parse_iso_epoch "2024-12-31T23:59:59Z")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$early" -lt "$late" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: parse_iso_epoch preserves chronological order\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: parse_iso_epoch order wrong (early=%s >= late=%s)\n" "$early" "$late"
fi

# Difference between Jan 1 and Dec 31 should be ~365 days
diff_days=$(( (late - early) / 86400 ))
assert_eq "parse_iso_epoch 2024 full year ≈ 365 days" "365" "$diff_days"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch_ms — basic ==="
# ═══════════════════════════════════════════════════════════

result=$(_parse_iso_epoch_ms "2024-01-01T00:00:00Z")
assert_numeric "parse_iso_epoch_ms returns numeric" "$result"

# Seconds component should match _parse_iso_epoch
expected_s=1704067200
actual_s=$(( result / 1000 ))
assert_eq "parse_iso_epoch_ms seconds component matches epoch" "$expected_s" "$actual_s"

# Result should be 13 digits (milliseconds since epoch for dates after ~2001)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ${#result} -eq 13 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: parse_iso_epoch_ms has 13 digits\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: parse_iso_epoch_ms expected 13 digits, got %d ('%s')\n" "${#result}" "$result"
fi

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _parse_iso_epoch_ms — edge cases ==="
# ═══════════════════════════════════════════════════════════

# Null
result=$(_parse_iso_epoch_ms "null")
assert_eq "parse_iso_epoch_ms null → 0" "0" "$result"

# Empty
result=$(_parse_iso_epoch_ms "")
assert_eq "parse_iso_epoch_ms empty → 0" "0" "$result"

# Invalid
result=$(_parse_iso_epoch_ms "garbage")
assert_numeric "parse_iso_epoch_ms garbage is numeric" "$result"

# Fractional seconds stripped
result=$(_parse_iso_epoch_ms "2024-01-01T00:00:00.999Z")
actual_s=$(( result / 1000 ))
assert_eq "parse_iso_epoch_ms strips fractional seconds" "$expected_s" "$actual_s"

# Ordering preserved in ms
early_ms=$(_parse_iso_epoch_ms "2024-01-01T00:00:00Z")
late_ms=$(_parse_iso_epoch_ms "2024-01-01T00:00:01Z")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$late_ms" -gt "$early_ms" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: parse_iso_epoch_ms preserves 1-second ordering\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: parse_iso_epoch_ms 1s ordering wrong (%s vs %s)\n" "$early_ms" "$late_ms"
fi

# Difference should be ~1000ms
diff_ms=$(( late_ms - early_ms ))
assert_eq "parse_iso_epoch_ms 1-second diff = 1000ms" "1000" "$diff_ms"

# Consistency with _parse_iso_epoch
epoch_s=$(_parse_iso_epoch "2024-06-15T12:00:00Z")
epoch_ms=$(_parse_iso_epoch_ms "2024-06-15T12:00:00Z")
epoch_ms_to_s=$(( epoch_ms / 1000 ))
assert_eq "parse_iso_epoch_ms / 1000 == parse_iso_epoch" "$epoch_s" "$epoch_ms_to_s"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _now_epoch_ms ==="
# ═══════════════════════════════════════════════════════════

now_ms=$(_now_epoch_ms)
assert_numeric "now_epoch_ms returns numeric" "$now_ms"

# Should be > 1700000000000 (Nov 2023)
assert_gt "now_epoch_ms is recent (> Nov 2023)" 1700000000000 "$now_ms"

# Should be 13 digits
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ${#now_ms} -eq 13 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: now_epoch_ms has 13 digits\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: now_epoch_ms expected 13 digits, got %d ('%s')\n" "${#now_ms}" "$now_ms"
fi

# Should be within 2 seconds of date +%s * 1000
now_s=$(date +%s)
now_s_ms=$(( now_s * 1000 ))
drift=$(( now_ms - now_s_ms ))
[[ $drift -lt 0 ]] && drift=$(( -drift ))
assert_lt "now_epoch_ms within 2s of date +%s" 2000 "$drift"

# Calling twice should be monotonically non-decreasing
ms1=$(_now_epoch_ms)
ms2=$(_now_epoch_ms)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$ms2" -ge "$ms1" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: now_epoch_ms is monotonically non-decreasing\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: now_epoch_ms went backwards (%s → %s)\n" "$ms1" "$ms2"
fi

# now_epoch_ms should be greater than a known past timestamp
past_ms=$(_parse_iso_epoch_ms "2024-01-01T00:00:00Z")
assert_gt "now_epoch_ms > 2024-01-01 in ms" "$past_ms" "$now_ms"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _resolve_path — existing paths ==="
# ═══════════════════════════════════════════════════════════

# Existing file should resolve to absolute path
resolved=$(_resolve_path "$TMP_DIR/testfile")
assert_startswith "resolve_path returns absolute path for file" "/" "$resolved"

# Existing directory
resolved=$(_resolve_path "$TMP_DIR/testdir")
assert_startswith "resolve_path returns absolute path for dir" "/" "$resolved"

# Symlink should resolve to target
resolved_sym=$(_resolve_path "$TMP_DIR/symlink")
resolved_real=$(_resolve_path "$TMP_DIR/testfile")
assert_eq "resolve_path symlink resolves to same as target" "$resolved_real" "$resolved_sym"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _resolve_path — non-existent paths ==="
# ═══════════════════════════════════════════════════════════

# Non-existent path should still return something non-empty
resolved=$(_resolve_path "/nonexistent/path/file.txt")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -n "$resolved" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: resolve_path returns non-empty for missing path\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: resolve_path returned empty for missing path\n"
fi

# Should contain the filename at minimum
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$resolved" == *"file.txt"* ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: resolve_path preserves filename in missing path\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: resolve_path lost filename (got '%s')\n" "$resolved"
fi

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _resolve_path — special characters ==="
# ═══════════════════════════════════════════════════════════

# Path with spaces
resolved=$(_resolve_path "$TMP_DIR/file with spaces.txt")
assert_startswith "resolve_path handles spaces" "/" "$resolved"

# Path with dashes and underscores
resolved=$(_resolve_path "$TMP_DIR/file-with-dashes_and_underscores.txt")
assert_startswith "resolve_path handles dashes/underscores" "/" "$resolved"

# Relative path with ..
mkdir -p "$TMP_DIR/a/b"
touch "$TMP_DIR/a/b/deep.txt"
resolved=$(_resolve_path "$TMP_DIR/a/b/../b/deep.txt")
# Should not contain ..
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$resolved" != *".."* ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: resolve_path eliminates .. components\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: resolve_path still contains .. ('%s')\n" "$resolved"
fi

# Path with ./
resolved=$(_resolve_path "$TMP_DIR/./testfile")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$resolved" != *"/./"* ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: resolve_path eliminates ./ components\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: resolve_path still contains ./ ('%s')\n" "$resolved"
fi

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== _stat_mtime — temporal consistency ==="
# ═══════════════════════════════════════════════════════════

# Create two files sequentially — second should have >= mtime
touch "$TMP_DIR/first"
sleep 1
touch "$TMP_DIR/second"

mtime_first=$(_stat_mtime "$TMP_DIR/first")
mtime_second=$(_stat_mtime "$TMP_DIR/second")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$mtime_second" -ge "$mtime_first" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: stat_mtime preserves temporal order\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: stat_mtime temporal order wrong (%s vs %s)\n" "$mtime_first" "$mtime_second"
fi

# Touch a file to update mtime — new mtime should be >= old
old_mtime=$(_stat_mtime "$TMP_DIR/testfile")
sleep 1
touch "$TMP_DIR/testfile"
new_mtime=$(_stat_mtime "$TMP_DIR/testfile")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$new_mtime" -ge "$old_mtime" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: stat_mtime updates after touch\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: stat_mtime didn't update (%s → %s)\n" "$old_mtime" "$new_mtime"
fi

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Idempotent sourcing ==="
# ═══════════════════════════════════════════════════════════

# Source again — should not error (readonly guard)
(source "${LIB_DIR}/platform.sh" 2>/dev/null)
exit_code=$?
assert_eq "Re-sourcing platform.sh does not error" "0" "$exit_code"

# _RUNE_PLATFORM should still be the same after re-source
(
  source "${LIB_DIR}/platform.sh" 2>/dev/null
  echo "$_RUNE_PLATFORM"
) > "$TMP_DIR/platform_check" 2>/dev/null
platform_after=$(cat "$TMP_DIR/platform_check")
assert_eq "Platform value unchanged after re-source" "$_RUNE_PLATFORM" "$platform_after"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== set -euo pipefail safety ==="
# ═══════════════════════════════════════════════════════════

# All functions should be safe under strict mode — run in subshell
(
  set -euo pipefail
  source "${LIB_DIR}/platform.sh" 2>/dev/null || true
  _stat_mtime "/does/not/exist" > /dev/null 2>&1 || true
  _stat_uid "/does/not/exist" > /dev/null 2>&1 || true
  _parse_iso_epoch "" > /dev/null 2>&1
  _parse_iso_epoch "invalid" > /dev/null 2>&1
  _parse_iso_epoch_ms "" > /dev/null 2>&1
  _parse_iso_epoch_ms "invalid" > /dev/null 2>&1
  _now_epoch_ms > /dev/null 2>&1
  _resolve_path "/tmp" > /dev/null 2>&1
  echo "OK"
) > "$TMP_DIR/strict_check" 2>/dev/null
strict_result=$(cat "$TMP_DIR/strict_check")
assert_eq "All functions safe under set -euo pipefail" "OK" "$strict_result"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Subshell isolation ==="
# ═══════════════════════════════════════════════════════════

# Functions should work in subshells (no fd leaks, no env corruption)
sub_result=$(
  source "${LIB_DIR}/platform.sh" 2>/dev/null || true
  _parse_iso_epoch "2024-01-01T00:00:00Z"
)
assert_eq "parse_iso_epoch works in subshell" "1704067200" "$sub_result"

sub_ms=$(
  source "${LIB_DIR}/platform.sh" 2>/dev/null || true
  _now_epoch_ms
)
assert_numeric "now_epoch_ms works in subshell" "$sub_ms"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Pipe safety ==="
# ═══════════════════════════════════════════════════════════

# Functions should work when piped
piped_result=$(_parse_iso_epoch "2024-01-01T00:00:00Z" | cat)
assert_eq "parse_iso_epoch works when piped" "1704067200" "$piped_result"

piped_ms=$(_now_epoch_ms | cat)
assert_numeric "now_epoch_ms works when piped" "$piped_ms"

piped_mtime=$(_stat_mtime "$TMP_DIR/testfile" | cat)
assert_numeric "stat_mtime works when piped" "$piped_mtime"

# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Duration calculation (integration) ==="
# ═══════════════════════════════════════════════════════════

# Simulate the rune-status.sh duration calculation pattern
ep_s=$(_parse_iso_epoch_ms "2024-01-01T00:00:00Z")
ep_e=$(_parse_iso_epoch_ms "2024-01-01T00:05:00Z")
dur_ms=$(( ep_e - ep_s ))
assert_eq "Duration calc: 5 minutes = 300000ms" "300000" "$dur_ms"

# 1 hour
ep_s=$(_parse_iso_epoch_ms "2024-01-01T10:00:00Z")
ep_e=$(_parse_iso_epoch_ms "2024-01-01T11:00:00Z")
dur_ms=$(( ep_e - ep_s ))
assert_eq "Duration calc: 1 hour = 3600000ms" "3600000" "$dur_ms"

# Current time minus a past time (simulates in-progress phase)
ep_s=$(_parse_iso_epoch_ms "2024-01-01T00:00:00Z")
ep_e=$(_now_epoch_ms)
dur_ms=$(( ep_e - ep_s ))
assert_gt "Duration calc: past to now > 0" 0 "$dur_ms"

# ═══════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
printf "Results: %d passed, %d failed, %d total\n" "$PASS_COUNT" "$FAIL_COUNT" "$TOTAL_COUNT"
echo "═══════════════════════════════════════"

[[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
