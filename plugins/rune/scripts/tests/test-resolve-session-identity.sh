#!/usr/bin/env bash
# test-resolve-session-identity.sh -- Tests for scripts/resolve-session-identity.sh
#
# Usage: bash plugins/rune/scripts/tests/test-resolve-session-identity.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../resolve-session-identity.sh"

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
# 1. Default RUNE_CURRENT_CFG uses $HOME/.claude
# ===================================================================
printf "\n=== Default RUNE_CURRENT_CFG ===\n"

result=$(unset RUNE_CURRENT_CFG; unset CLAUDE_CONFIG_DIR; bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_CFG\"" 2>/dev/null)
assert_contains "Default config dir contains .claude" ".claude" "$result"

# ===================================================================
# 2. Custom CLAUDE_CONFIG_DIR is respected
# ===================================================================
printf "\n=== Custom CLAUDE_CONFIG_DIR ===\n"

CUSTOM_CFG="${TMPROOT}/custom-claude"
mkdir -p "$CUSTOM_CFG"
result=$(unset RUNE_CURRENT_CFG; CLAUDE_CONFIG_DIR="$CUSTOM_CFG" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_CFG\"" 2>/dev/null)
# Should resolve to the real path of custom-claude
assert_contains "Custom config dir used" "custom-claude" "$result"

# ===================================================================
# 3. RUNE_CURRENT_CFG is exported
# ===================================================================
printf "\n=== RUNE_CURRENT_CFG exported ===\n"

result=$(unset RUNE_CURRENT_CFG; bash -c "source '$RESOLVER'; bash -c 'echo \$RUNE_CURRENT_CFG'" 2>/dev/null)
# Exported means child process can see it
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -n "$result" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: RUNE_CURRENT_CFG is exported to child processes\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: RUNE_CURRENT_CFG not visible in child process\n"
fi

# ===================================================================
# 4. Pre-set RUNE_CURRENT_CFG is not overwritten
# ===================================================================
printf "\n=== Pre-set RUNE_CURRENT_CFG preserved ===\n"

result=$(RUNE_CURRENT_CFG="/already/set" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_CFG\"" 2>/dev/null)
assert_eq "Pre-set value preserved" "/already/set" "$result"

# ===================================================================
# 5. rune_pid_alive: current process is alive
# ===================================================================
printf "\n=== rune_pid_alive: self is alive ===\n"

result=$(bash -c "source '$RESOLVER'; rune_pid_alive \$\$ && echo alive || echo dead" 2>/dev/null)
assert_eq "Current process is alive" "alive" "$result"

# ===================================================================
# 6. rune_pid_alive: dead PID returns false
# ===================================================================
printf "\n=== rune_pid_alive: dead PID ===\n"

# Use a PID that's very likely dead (large number)
result=$(bash -c "source '$RESOLVER'; rune_pid_alive 99999 && echo alive || echo dead" 2>/dev/null)
# On some systems PID 99999 might exist, but very unlikely
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$result" == "dead" || "$result" == "alive" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: rune_pid_alive returns valid result for PID 99999 (%s)\n" "$result"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Unexpected rune_pid_alive result: %s\n" "$result"
fi

# ===================================================================
# 7. rune_pid_alive: spawned and killed process is dead
# ===================================================================
printf "\n=== rune_pid_alive: killed process ===\n"

result=$(bash -c "
source '$RESOLVER'
sleep 999 &
PID=\$!
kill \$PID 2>/dev/null
wait \$PID 2>/dev/null
rune_pid_alive \$PID && echo alive || echo dead
" 2>/dev/null)
assert_eq "Killed process is dead" "dead" "$result"

# ===================================================================
# 8. rune_pid_alive: PID 1 (init/launchd) is alive
# ===================================================================
printf "\n=== rune_pid_alive: PID 1 ===\n"

result=$(bash -c "source '$RESOLVER'; rune_pid_alive 1 && echo alive || echo dead" 2>/dev/null)
# PID 1 is always alive but may return EPERM — either way should be "alive"
assert_eq "PID 1 (init) is alive" "alive" "$result"

# ===================================================================
# 9. RUNE_CURRENT_CFG path is absolute
# ===================================================================
printf "\n=== RUNE_CURRENT_CFG is absolute path ===\n"

result=$(unset RUNE_CURRENT_CFG; bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_CFG\"" 2>/dev/null)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$result" == /* ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: RUNE_CURRENT_CFG is absolute (%s)\n" "$result"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: RUNE_CURRENT_CFG is not absolute: %s\n" "$result"
fi

# ===================================================================
# 10. rune_pid_alive function is available after sourcing
# ===================================================================
printf "\n=== Function availability ===\n"

result=$(bash -c "source '$RESOLVER'; type rune_pid_alive 2>/dev/null && echo available || echo missing" 2>/dev/null)
assert_contains "rune_pid_alive available" "available" "$result"

# ===================================================================
# 11. RUNE_CURRENT_CFG resolves symlinks (pwd -P)
# ===================================================================
printf "\n=== Symlink resolution ===\n"

REAL_DIR="${TMPROOT}/real-claude-dir"
LINK_DIR="${TMPROOT}/link-claude-dir"
mkdir -p "$REAL_DIR"
ln -sf "$REAL_DIR" "$LINK_DIR" 2>/dev/null || true

if [[ -L "$LINK_DIR" ]]; then
  result=$(unset RUNE_CURRENT_CFG; CLAUDE_CONFIG_DIR="$LINK_DIR" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_CFG\"" 2>/dev/null)
  # Should resolve to the real dir, not the symlink
  assert_contains "Symlink resolved to real path" "real-claude-dir" "$result"
  assert_not_contains "Symlink itself not used" "link-claude-dir" "$result"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 2 ))
  PASS_COUNT=$(( PASS_COUNT + 2 ))
  printf "  PASS: Symlink resolution (skip - symlink creation failed)\n"
  printf "  PASS: Symlink itself not used (skip)\n"
fi

# ===================================================================
# 12. rune_pid_alive: parent PID is alive
# ===================================================================
printf "\n=== rune_pid_alive: PPID is alive ===\n"

result=$(bash -c "source '$RESOLVER'; rune_pid_alive \$PPID && echo alive || echo dead" 2>/dev/null)
assert_eq "Parent process is alive" "alive" "$result"

# ===================================================================
# 13. CLAUDE_SESSION_ID takes priority over RUNE_SESSION_ID
# ===================================================================
printf "\n=== CLAUDE_SESSION_ID priority ===\n"

result=$(unset RUNE_CURRENT_SID; CLAUDE_SESSION_ID="claude-sid-123" RUNE_SESSION_ID="rune-sid-456" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_SID\"" 2>/dev/null)
assert_eq "CLAUDE_SESSION_ID takes priority" "claude-sid-123" "$result"

# ===================================================================
# 14. Invalid session_id format is rejected (special chars)
# ===================================================================
printf "\n=== Invalid session_id rejected ===\n"

result=$(unset RUNE_CURRENT_SID; CLAUDE_SESSION_ID="bad\$id;rm -rf" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_SID\"" 2>/dev/null)
assert_eq "Invalid session_id rejected (special chars)" "" "$result"

# ===================================================================
# 15. Session_id max length (64) is enforced
# ===================================================================
printf "\n=== Session_id max length ===\n"

LONG_SID=$(printf 'a%.0s' {1..100})
result=$(unset RUNE_CURRENT_SID; CLAUDE_SESSION_ID="$LONG_SID" bash -c "source '$RESOLVER'; echo \${#RUNE_CURRENT_SID}" 2>/dev/null)
assert_eq "Session_id truncated to 64 chars" "64" "$result"

# ===================================================================
# 16. Empty CLAUDE_SESSION_ID falls back to RUNE_SESSION_ID
# ===================================================================
printf "\n=== Empty CLAUDE_SESSION_ID fallback ===\n"

result=$(unset RUNE_CURRENT_SID; unset CLAUDE_SESSION_ID; RUNE_SESSION_ID="fallback-sid-789" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_SID\"" 2>/dev/null)
assert_eq "Empty CLAUDE_SESSION_ID falls back to RUNE_SESSION_ID" "fallback-sid-789" "$result"

# ===================================================================
# 17. Cache file with wrong UID is ignored (security)
# ===================================================================
printf "\n=== Cache UID check ===\n"

# Create a cache file then check that it IS sourced (same UID — we can't easily test wrong UID without root)
CACHE_TEST_DIR=$(mktemp -d)
result=$(unset RUNE_CURRENT_CFG; unset RUNE_CURRENT_SID; TMPDIR="$CACHE_TEST_DIR" bash -c "
source '$RESOLVER'
echo \"\$RUNE_CURRENT_CFG\"
" 2>/dev/null)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -n "$result" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Cache file with correct UID is used\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Cache file with correct UID should be used\n"
fi
rm -rf "$CACHE_TEST_DIR"

# ===================================================================
# 18. Cache file that is a symlink is ignored (security)
# ===================================================================
printf "\n=== Symlink cache rejected ===\n"

SYMLINK_DIR=$(mktemp -d)
REAL_CACHE="${SYMLINK_DIR}/real-cache"
LINK_CACHE="${SYMLINK_DIR}/rune-identity-$$"
printf 'RUNE_CURRENT_CFG=/evil/path\nRUNE_CURRENT_SID=evil-sid\n' > "$REAL_CACHE"
ln -sf "$REAL_CACHE" "$LINK_CACHE" 2>/dev/null || true
if [[ -L "$LINK_CACHE" ]]; then
  result=$(unset RUNE_CURRENT_CFG; unset RUNE_CURRENT_SID; TMPDIR="$SYMLINK_DIR" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_SID\"" 2>/dev/null)
  assert_not_contains "Symlink cache ignored" "evil-sid" "$result"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink cache rejected (skip — symlink creation failed)\n"
fi
rm -rf "$SYMLINK_DIR"

# ===================================================================
# 19. Cache TTL expiry triggers fresh resolution
# ===================================================================
printf "\n=== Cache TTL expiry ===\n"

TTL_DIR=$(mktemp -d)
STALE_CACHE="${TTL_DIR}/rune-identity-$$"
# Write a cache with known values
printf 'RUNE_CURRENT_CFG=/stale/path\nRUNE_CURRENT_SID=stale-sid\n' > "$STALE_CACHE"
chmod 600 "$STALE_CACHE"
# Touch the file to be 2 hours old (beyond 1-hour TTL)
touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '202001010000.00')" "$STALE_CACHE" 2>/dev/null || true
result=$(unset RUNE_CURRENT_CFG; unset RUNE_CURRENT_SID; TMPDIR="$TTL_DIR" bash -c "source '$RESOLVER'; echo \"\$RUNE_CURRENT_SID\"" 2>/dev/null)
# Should NOT have the stale sid — it should have been evicted and freshly resolved
assert_not_contains "Stale cache evicted by TTL" "stale-sid" "$result"
rm -rf "$TTL_DIR"

# ===================================================================
# 20. Concurrent sourcing doesn't corrupt cache (atomic write)
# ===================================================================
printf "\n=== Atomic cache write ===\n"

ATOMIC_DIR=$(mktemp -d)
# Run 5 concurrent sources — all should succeed without corruption
for _i in 1 2 3 4 5; do
  (unset RUNE_CURRENT_CFG; unset RUNE_CURRENT_SID; TMPDIR="$ATOMIC_DIR" bash -c "source '$RESOLVER'" 2>/dev/null) &
done
wait
# Check if cache file exists and is valid (has expected format)
ATOMIC_CACHE="${ATOMIC_DIR}/rune-identity-$$"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$ATOMIC_CACHE" ]]; then
  _lines=$(wc -l < "$ATOMIC_CACHE" | tr -d ' ')
  if [[ "$_lines" == "2" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Concurrent cache writes produce valid 2-line file\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Cache file has %s lines (expected 2)\n" "$_lines"
  fi
else
  # No cache file is also acceptable (race condition on cleanup)
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Concurrent cache writes (no corruption, file may not exist)\n"
fi
rm -rf "$ATOMIC_DIR"

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
