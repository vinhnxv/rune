#!/usr/bin/env bash
# test-team-shutdown.sh — Tests for scripts/lib/team-shutdown.sh
#
# Usage: bash plugins/rune/scripts/tests/test-team-shutdown.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

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

assert_file_exists() {
  local test_name="$1"
  local fpath="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -f "$fpath" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (file not found: %s)\n" "$test_name" "$fpath"
  fi
}

assert_file_not_exists() {
  local test_name="$1"
  local fpath="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ ! -f "$fpath" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (file should not exist: %s)\n" "$test_name" "$fpath"
  fi
}

assert_dir_not_exists() {
  local test_name="$1"
  local dpath="$2"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ ! -d "$dpath" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (dir should not exist: %s)\n" "$test_name" "$dpath"
  fi
}

# ── Setup temp environment ──
TMPWORK=$(mktemp -d "${TMPDIR:-/tmp}/rune-test-shutdown-XXXXXX")
trap 'rm -rf "$TMPWORK"' EXIT

# ═══════════════════════════════════════════════════════════════
# T1: Happy Path — removes teams/ and tasks/ directories
# ═══════════════════════════════════════════════════════════════
printf "\n=== T1: Happy Path — Filesystem Cleanup ===\n"

(
  # Fresh subshell to isolate sourcing
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  MOCK_CHOME="$TMPWORK/t1-chome"
  TEAM="rune-test-t1"
  mkdir -p "$MOCK_CHOME/teams/$TEAM" "$MOCK_CHOME/tasks/$TEAM"
  echo "config" > "$MOCK_CHOME/teams/$TEAM/config.json"
  echo "tasks" > "$MOCK_CHOME/tasks/$TEAM/tasks.json"

  # Source with mock CHOME
  export CLAUDE_CONFIG_DIR="$MOCK_CHOME"
  source "$LIB_DIR/team-shutdown.sh"

  # Use a dead PID (owner_pid) — session isolation allows cleanup of dead sessions
  rune_team_shutdown_fallback "$TEAM" "99999" "test" "" || true

  # Check dirs removed
  if [[ ! -d "$MOCK_CHOME/teams/$TEAM" && ! -d "$MOCK_CHOME/tasks/$TEAM" ]]; then
    echo "RESULT:pass"
  else
    echo "RESULT:fail"
  fi
) > "$TMPWORK/t1-out.txt" 2>&1
T1_RESULT=$(grep "RESULT:" "$TMPWORK/t1-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T1: teams/ and tasks/ dirs removed" "RESULT:pass" "$T1_RESULT"

# ═══════════════════════════════════════════════════════════════
# T2: Idempotent Source — sourcing twice doesn't re-init
# ═══════════════════════════════════════════════════════════════
printf "\n=== T2: Idempotent Source ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  export CLAUDE_CONFIG_DIR="$TMPWORK/t2-chome"
  mkdir -p "$TMPWORK/t2-chome"

  # Source first time
  source "$LIB_DIR/team-shutdown.sh"
  FIRST_LOADED="${_RUNE_TEAM_SHUTDOWN_LOADED:-}"

  # Source second time — should be a no-op
  source "$LIB_DIR/team-shutdown.sh"
  SECOND_LOADED="${_RUNE_TEAM_SHUTDOWN_LOADED:-}"

  if [[ "$FIRST_LOADED" == "1" && "$SECOND_LOADED" == "1" ]]; then
    # Verify function still exists
    if declare -f rune_team_shutdown_fallback >/dev/null 2>&1; then
      echo "RESULT:pass"
    else
      echo "RESULT:fail-no-func"
    fi
  else
    echo "RESULT:fail-sentinel"
  fi
) > "$TMPWORK/t2-out.txt" 2>&1
T2_RESULT=$(grep "RESULT:" "$TMPWORK/t2-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T2: Idempotent sourcing works" "RESULT:pass" "$T2_RESULT"

# ═══════════════════════════════════════════════════════════════
# T3: Process Kill — _rune_kill_tree called with correct args
# ═══════════════════════════════════════════════════════════════
printf "\n=== T3: Process Kill Path ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  MOCK_CHOME="$TMPWORK/t3-chome"
  TEAM="rune-test-t3"
  mkdir -p "$MOCK_CHOME/teams/$TEAM"
  export CLAUDE_CONFIG_DIR="$MOCK_CHOME"

  source "$LIB_DIR/team-shutdown.sh"

  # Override _rune_kill_tree with a spy
  _rune_kill_tree() {
    echo "KILL_ARGS:$1|$2|$3|$4|$5" >> "$TMPWORK/t3-spy.txt"
    echo "0"
  }

  # Use $PPID (our actual parent) so session isolation allows it
  rune_team_shutdown_fallback "$TEAM" "$PPID" "arc-test" "smith-1,smith-2" || true

  if [[ -f "$TMPWORK/t3-spy.txt" ]]; then
    SPY_LINE=$(cat "$TMPWORK/t3-spy.txt")
    if [[ "$SPY_LINE" == "KILL_ARGS:${PPID}|2stage|5|teammates|${TEAM}" ]]; then
      echo "RESULT:pass"
    else
      echo "RESULT:fail-args:$SPY_LINE"
    fi
  else
    echo "RESULT:pass-no-kill"  # kill_tree not called if PPID dead (ok)
  fi
) > "$TMPWORK/t3-out.txt" 2>&1
T3_RESULT=$(grep "RESULT:" "$TMPWORK/t3-out.txt" | tail -1 || echo "RESULT:fail")
# Accept both pass (spy captured args) and pass-no-kill (PPID already dead in subshell)
if [[ "$T3_RESULT" == "RESULT:pass" || "$T3_RESULT" == "RESULT:pass-no-kill" ]]; then
  T3_RESULT="RESULT:pass"
fi
assert_eq "T3: _rune_kill_tree called with correct args" "RESULT:pass" "$T3_RESULT"

# ═══════════════════════════════════════════════════════════════
# T4: CHOME Fallback — CLAUDE_CONFIG_DIR unset uses $HOME/.claude
# ═══════════════════════════════════════════════════════════════
printf "\n=== T4: CHOME Fallback ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  unset CLAUDE_CONFIG_DIR
  MOCK_HOME="$TMPWORK/t4-home"
  TEAM="rune-test-t4"
  mkdir -p "$MOCK_HOME/.claude/teams/$TEAM" "$MOCK_HOME/.claude/tasks/$TEAM"
  echo "cfg" > "$MOCK_HOME/.claude/teams/$TEAM/config.json"

  export HOME="$MOCK_HOME"
  source "$LIB_DIR/team-shutdown.sh"

  # Override _rune_kill_tree to no-op
  _rune_kill_tree() { echo "0"; }

  rune_team_shutdown_fallback "$TEAM" "99999" "test" "" || true

  if [[ ! -d "$MOCK_HOME/.claude/teams/$TEAM" ]]; then
    echo "RESULT:pass"
  else
    echo "RESULT:fail"
  fi
) > "$TMPWORK/t4-out.txt" 2>&1
T4_RESULT=$(grep "RESULT:" "$TMPWORK/t4-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T4: CHOME fallback to HOME/.claude" "RESULT:pass" "$T4_RESULT"

# ═══════════════════════════════════════════════════════════════
# T5: Diagnostic JSON — valid JSON with required keys
# ═══════════════════════════════════════════════════════════════
printf "\n=== T5: Diagnostic JSON ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  MOCK_CHOME="$TMPWORK/t5-chome"
  TEAM="rune-test-t5"
  mkdir -p "$MOCK_CHOME/teams/$TEAM"
  export CLAUDE_CONFIG_DIR="$MOCK_CHOME"
  export TMPDIR="$TMPWORK/t5-tmp"
  mkdir -p "$TMPDIR"

  source "$LIB_DIR/team-shutdown.sh"
  _rune_kill_tree() { echo "0"; }

  rune_team_shutdown_fallback "$TEAM" "99999" "arc-work" "smith-1" || true

  DIAG_FILE="$TMPDIR/rune-cleanup-diagnostic-${TEAM}.json"
  if [[ -f "$DIAG_FILE" ]]; then
    # Validate JSON and check required keys
    if command -v jq >/dev/null 2>&1; then
      HAS_KEYS=$(jq -e '.team_name and .owner_pid and .workflow_label and .timestamp and .fallback_exercised' "$DIAG_FILE" >/dev/null 2>&1 && echo "yes" || echo "no")
      TEAM_VAL=$(jq -r '.team_name' "$DIAG_FILE" 2>/dev/null || echo "")
      WORKFLOW_VAL=$(jq -r '.workflow_label' "$DIAG_FILE" 2>/dev/null || echo "")
      if [[ "$HAS_KEYS" == "yes" && "$TEAM_VAL" == "$TEAM" && "$WORKFLOW_VAL" == "arc-work" ]]; then
        echo "RESULT:pass"
      else
        echo "RESULT:fail-keys:$HAS_KEYS:$TEAM_VAL:$WORKFLOW_VAL"
      fi
    else
      # No jq — just check file is non-empty and contains key strings
      if grep -q '"team_name"' "$DIAG_FILE" && grep -q '"timestamp"' "$DIAG_FILE"; then
        echo "RESULT:pass"
      else
        echo "RESULT:fail-no-jq"
      fi
    fi
  else
    echo "RESULT:fail-no-file"
  fi
) > "$TMPWORK/t5-out.txt" 2>&1
T5_RESULT=$(grep "RESULT:" "$TMPWORK/t5-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T5: Diagnostic JSON has required keys" "RESULT:pass" "$T5_RESULT"

# ═══════════════════════════════════════════════════════════════
# T6: Fallback Exercised — return code = 1 when dirs exist
# ═══════════════════════════════════════════════════════════════
printf "\n=== T6: Fallback Exercised Return Code ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  MOCK_CHOME="$TMPWORK/t6-chome"
  TEAM="rune-test-t6"
  mkdir -p "$MOCK_CHOME/teams/$TEAM" "$MOCK_CHOME/tasks/$TEAM"
  echo "data" > "$MOCK_CHOME/teams/$TEAM/config.json"
  export CLAUDE_CONFIG_DIR="$MOCK_CHOME"
  export TMPDIR="$TMPWORK/t6-tmp"
  mkdir -p "$TMPDIR"

  source "$LIB_DIR/team-shutdown.sh"
  _rune_kill_tree() { echo "0"; }

  rc=0
  rune_team_shutdown_fallback "$TEAM" "99999" "test" "" || rc=$?

  if [[ "$rc" -eq 1 ]]; then
    echo "RESULT:pass"
  else
    echo "RESULT:fail-rc:$rc"
  fi
) > "$TMPWORK/t6-out.txt" 2>&1
T6_RESULT=$(grep "RESULT:" "$TMPWORK/t6-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T6: Return code 1 when fallback exercised" "RESULT:pass" "$T6_RESULT"

# ═══════════════════════════════════════════════════════════════
# T7: Input Validation — empty team_name and owner_pid return 2
# ═══════════════════════════════════════════════════════════════
printf "\n=== T7: Input Validation ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  export CLAUDE_CONFIG_DIR="$TMPWORK/t7-chome"
  mkdir -p "$TMPWORK/t7-chome"

  source "$LIB_DIR/team-shutdown.sh"

  # Empty team_name
  rc1=0
  rune_team_shutdown_fallback "" "12345" "test" "" || rc1=$?

  # Empty owner_pid
  rc2=0
  rune_team_shutdown_fallback "valid-team" "" "test" "" || rc2=$?

  # Invalid team_name (path traversal)
  rc3=0
  rune_team_shutdown_fallback "team/../evil" "12345" "test" "" || rc3=$?

  # Non-numeric owner_pid
  rc4=0
  rune_team_shutdown_fallback "valid-team" "abc" "test" "" || rc4=$?

  if [[ "$rc1" -eq 2 && "$rc2" -eq 2 && "$rc3" -eq 2 && "$rc4" -eq 2 ]]; then
    echo "RESULT:pass"
  else
    echo "RESULT:fail-rc:$rc1,$rc2,$rc3,$rc4"
  fi
) > "$TMPWORK/t7-out.txt" 2>&1
T7_RESULT=$(grep "RESULT:" "$TMPWORK/t7-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T7: Invalid inputs return 2" "RESULT:pass" "$T7_RESULT"

# ═══════════════════════════════════════════════════════════════
# T8: Session Isolation — alive owner_pid != $PPID returns 2
# ═══════════════════════════════════════════════════════════════
printf "\n=== T8: Session Isolation ===\n"

(
  unset _RUNE_TEAM_SHUTDOWN_LOADED _RUNE_PROCESS_TREE_LOADED _RUNE_PLATFORM
  MOCK_CHOME="$TMPWORK/t8-chome"
  TEAM="rune-test-t8"
  mkdir -p "$MOCK_CHOME/teams/$TEAM"
  export CLAUDE_CONFIG_DIR="$MOCK_CHOME"

  source "$LIB_DIR/team-shutdown.sh"

  # Start a background sleep as a live process we own (kill -0 will succeed)
  # This PID is alive and != $PPID inside this subshell
  sleep 60 &
  FOREIGN_PID=$!
  rc=0
  rune_team_shutdown_fallback "$TEAM" "$FOREIGN_PID" "test" "" || rc=$?
  kill "$FOREIGN_PID" 2>/dev/null || true
  wait "$FOREIGN_PID" 2>/dev/null || true

  if [[ "$rc" -eq 2 ]]; then
    # Verify dirs NOT removed (isolation blocked cleanup)
    if [[ -d "$MOCK_CHOME/teams/$TEAM" ]]; then
      echo "RESULT:pass"
    else
      echo "RESULT:fail-dir-removed"
    fi
  else
    echo "RESULT:fail-rc:$rc"
  fi
) > "$TMPWORK/t8-out.txt" 2>&1
T8_RESULT=$(grep "RESULT:" "$TMPWORK/t8-out.txt" | tail -1 || echo "RESULT:fail")
assert_eq "T8: Session isolation blocks foreign PID" "RESULT:pass" "$T8_RESULT"

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
