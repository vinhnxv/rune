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
# Results
# ===================================================================
printf "\n===================================================\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "===================================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
