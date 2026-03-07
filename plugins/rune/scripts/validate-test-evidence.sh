#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════════
# validate-test-evidence.sh — TaskCompleted hook for test evidence validation
# ════════════════════════════════════════════════════════════════════════════════
# VERIFICATION-HARDENING Task 1: Deterministic test evidence check
# Ensures workers produce test execution evidence before completing tasks.
#
# Contract:
#   Input: TaskCompleted hook JSON via stdin (team_name, task_id, teammate_name, cwd)
#   Output: Exit 0 (allow) or exit 2 + stderr feedback (block)
#   Position: BEFORE on-task-completed.sh (signal writer)
#   Scope: Only rune-work-* and arc-work-* teams (workers)
#
# Exit codes:
#   0 = Allow (pass or skip)
#   2 = Block (missing test evidence)
# ════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
umask 077

# ── Fail-forward ERR trap (operational hook per ADR-002) ──
_rune_fail_forward() {
  echo "[validate-test-evidence] WARN: Hook failed, failing forward (exit 0)" >&2
  exit 0
}
trap '_rune_fail_forward' ERR

# ── Constants ──
SCRIPT_NAME="validate-test-evidence.sh"
MIN_FILE_SIZE=50  # Minimum bytes for evidence file (per BACK-007 pattern)

# ── Read stdin (capped to 1MB per SEC-003) ──
INPUT=$(head -c 1048576)
if [[ -z "$INPUT" ]]; then
  exit 0  # No input, skip
fi

# ── Parse JSON input ──
# Requires jq - validated at session start
TEAM_NAME=$(echo "$INPUT" | jq -r '.team_name // empty' 2>/dev/null || echo "")
TASK_ID=$(echo "$INPUT" | jq -r '.task_id // empty' 2>/dev/null || echo "")
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")

# ── GUARD: Only process worker teams ──
if [[ -z "$TEAM_NAME" ]] || [[ ! "$TEAM_NAME" =~ ^(rune|arc)-work- ]]; then
  exit 0  # Not a worker team, skip
fi

# ── SEC-001: Validate team_name and teammate_name ──
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_:-]+$ ]]; then
  echo "[validate-test-evidence] Invalid team_name format: $TEAM_NAME" >&2
  exit 0  # Fail-forward
fi
if [[ -n "$TEAMMATE_NAME" ]] && [[ ! "$TEAMMATE_NAME" =~ ^[a-zA-Z0-9_:-]+$ ]]; then
  echo "[validate-test-evidence] Invalid teammate_name format: $TEAMMATE_NAME" >&2
  exit 0  # Fail-forward
fi

# ── SEC-002: Canonicalize CWD ──
if [[ -n "$CWD" ]] && [[ -d "$CWD" ]]; then
  CWD=$(cd "$CWD" && pwd -P 2>/dev/null || echo "$CWD")
fi

# ── Session isolation check ──
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CURRENT_CFG=$(cd "$CHOME" 2>/dev/null && pwd -P || echo "$CHOME")
CURRENT_PID="$PPID"

# Check team state file for session ownership
STATE_FILE="tmp/.rune-work-*.json"
STATE_FILES=$(find . -maxdepth 2 -name '.rune-work-*.json' 2>/dev/null | head -1)
if [[ -n "$STATE_FILES" ]]; then
  STATE_CFG=$(jq -r '.config_dir // empty' "$STATE_FILES" 2>/dev/null || echo "")
  STATE_PID=$(jq -r '.owner_pid // empty' "$STATE_FILES" 2>/dev/null || echo "")

  if [[ -n "$STATE_CFG" ]] && [[ "$STATE_CFG" != "$CURRENT_CFG" ]]; then
    exit 0  # Different installation, skip
  fi
  if [[ -n "$STATE_PID" ]] && [[ "$STATE_PID" =~ ^[0-9]+$ ]] && [[ "$STATE_PID" != "$CURRENT_PID" ]]; then
    # Check if owner is still alive
    if kill -0 "$STATE_PID" 2>/dev/null; then
      exit 0  # Different live session, skip
    fi
  fi
fi

# ── Step 1: Discover test framework from project manifest ──
discover_test_commands() {
  local cwd="$1"
  local commands=()

  # Check package.json for npm/yarn/pnpm test
  if [[ -f "$cwd/package.json" ]]; then
    if jq -e '.scripts.test' "$cwd/package.json" >/dev/null 2>&1; then
      commands+=("npm test")
    fi
  fi

  # Check pyproject.toml for pytest
  if [[ -f "$cwd/pyproject.toml" ]]; then
    if grep -qE '\[tool\.pytest\]' "$cwd/pyproject.toml" 2>/dev/null; then
      commands+=("pytest")
    fi
  fi

  # Check Makefile for test target
  if [[ -f "$cwd/Makefile" ]]; then
    if grep -qE '^test:' "$cwd/Makefile" 2>/dev/null; then
      commands+=("make test")
    fi
  fi

  # Check Cargo.toml for Rust tests
  if [[ -f "$cwd/Cargo.toml" ]]; then
    commands+=("cargo test")
  fi

  echo "${commands[@]}"
}

TEST_COMMANDS=$(discover_test_commands "$CWD")

# ── Step 2: If no test framework discovered, skip ──
if [[ -z "$TEST_COMMANDS" ]]; then
  exit 0  # No tests in project, don't block
fi

# ── Step 2.5: Resolve work directory ──
TIMESTAMP="${TEAM_NAME#rune-work-}"
TIMESTAMP="${TIMESTAMP#arc-work-}"

WORK_DIR=""
if [[ -d "$CWD/tmp/work/$TIMESTAMP" ]]; then
  WORK_DIR="$CWD/tmp/work/$TIMESTAMP"
else
  # Fallback: glob for most recent work dir
  WORK_DIRS=( "$CWD"/tmp/work/*/ 2>/dev/null )
  if [[ ${#WORK_DIRS[@]} -gt 0 ]]; then
    WORK_DIR="${WORK_DIRS[-1]}"
  fi
fi

if [[ -z "$WORK_DIR" ]] || [[ ! -d "$WORK_DIR" ]]; then
  exit 0  # No work directory, skip
fi

# ── Step 2.7: Last-task-only optimization ──
# Check if this is the last task for this worker
TASK_DIR="$CHOME/tasks/$TEAM_NAME"
if [[ -d "$TASK_DIR" ]]; then
  REMAINING=0
  for task_file in "$TASK_DIR"/*.json(N); do
    if [[ -f "$task_file" ]]; then
      OWNER=$(jq -r '.owner // empty' "$task_file" 2>/dev/null || echo "")
      STATUS=$(jq -r '.status // empty' "$task_file" 2>/dev/null || echo "")
      if [[ "$OWNER" == "$TEAMMATE_NAME" ]] && [[ "$STATUS" != "completed" ]]; then
        REMAINING=$((REMAINING + 1))
      fi
    fi
  done

  if [[ $REMAINING -gt 1 ]]; then
    exit 0  # Worker has more tasks, check evidence at last task only
  fi
fi

# ── Step 3: Check for test evidence files ──
SIGNAL_DIR="$CWD/tmp/.rune-signals/$TEAM_NAME"
WORKER_LOG_DIR="$WORK_DIR/worker-logs"

HAS_EVIDENCE=false

# Check signal directory for test evidence
if [[ -d "$SIGNAL_DIR" ]]; then
  for evidence_file in "$SIGNAL_DIR"/*.test-evidence(N); do
    if [[ -f "$evidence_file" ]]; then
      SIZE=$(wc -c < "$evidence_file" 2>/dev/null || echo 0)
      if [[ $SIZE -gt $MIN_FILE_SIZE ]]; then
        # Symlink check (SEC guard)
        if [[ ! -L "$evidence_file" ]]; then
          HAS_EVIDENCE=true
          break
        fi
      fi
    fi
  done
fi

# Check worker logs for test results
if [[ "$HAS_EVIDENCE" == "false" ]] && [[ -d "$WORKER_LOG_DIR" ]]; then
  for log_file in "$WORKER_LOG_DIR"/*.md(N); do
    if [[ -f "$log_file" ]]; then
      SIZE=$(wc -c < "$log_file" 2>/dev/null || echo 0)
      if [[ $SIZE -gt $MIN_FILE_SIZE ]]; then
        if grep -qE '(PASS|FAIL|test|spec|pytest|jest|mocha)' "$log_file" 2>/dev/null; then
          HAS_EVIDENCE=true
          break
        fi
      fi
    fi
  done
fi

# ── Step 4: Check ward result files ──
if [[ "$HAS_EVIDENCE" == "false" ]]; then
  WARD_RESULTS=( "$CWD"/tmp/work/$TIMESTAMP/ward-results-*.md(N) )
  if [[ ${#WARD_RESULTS[@]} -gt 0 ]]; then
    HAS_EVIDENCE=true
  fi
fi

# ── Step 5: Decision ──
if [[ "$HAS_EVIDENCE" == "false" ]]; then
  FIRST_TEST=$(echo "$TEST_COMMANDS" | cut -d' ' -f1-2)
  echo "BLOCK: No test evidence found. Tests exist ($FIRST_TEST) but no results detected. Run tests before marking task complete." >&2
  exit 2
fi

exit 0