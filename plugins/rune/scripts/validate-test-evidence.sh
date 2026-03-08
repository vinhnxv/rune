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
#
# ════════════════════════════════════════════════════════════════════════════════
# EVIDENCE TIMING CONTRACT (DOC-001)
# ════════════════════════════════════════════════════════════════════════════════
# Workers MUST write evidence files BEFORE calling TaskUpdate(status: completed).
#
# WHY: The TaskCompleted hook fires IMMEDIATELY when TaskUpdate(status: completed)
# is called. This hook validates evidence existence at that instant. If evidence
# is written AFTER TaskUpdate, validation will fail and block task completion.
#
# REQUIRED ORDER:
#   1. Perform work (code changes, tests, etc.)
#   2. Write evidence files (*.test-evidence, ward-results-*.md, worker logs)
#   3. Call TaskUpdate(status: completed) ← Hook fires HERE, validates step 2
#
# Evidence locations (checked in order):
#   - tmp/.rune-signals/{team}/*.test-evidence
#   - tmp/work/{timestamp}/worker-logs/*.md (with test markers)
#   - tmp/work/{timestamp}/ward-results-*.md
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
STATE_FILE="$CWD/tmp/.rune-work-*.json"
STATE_FILES=$(find "$CWD/tmp" -maxdepth 1 -name '.rune-work-*.json' 2>/dev/null | head -1)
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

# ── Step 2.1: Read test_evidence configuration from talisman.yml (BACK-002) ──
# Configuration options:
#   test_evidence.enabled: false  — disable check entirely
#   test_evidence.block_on_fail: false — warn instead of block
#   test_evidence.skip_patterns: ["**/*.md", "docs/**"] — skip for matching files
BLOCK_ON_FAIL=true  # Default: hard-block (backward compatible)
SKIP_PATTERNS=()    # Default: no patterns
TEST_EVIDENCE_ENABLED=true

for TALISMAN_PATH in "${CWD}/.claude/talisman.yml" "${CHOME}/talisman.yml"; do
  if [[ -f "$TALISMAN_PATH" ]]; then
    if command -v yq &>/dev/null; then
      # Read enabled flag
      TEST_EVIDENCE_ENABLED=$(yq -r 'if .test_evidence.enabled == false then "false" else "true" end' "$TALISMAN_PATH" 2>/dev/null) || TEST_EVIDENCE_ENABLED="true"
      [[ -z "$TEST_EVIDENCE_ENABLED" ]] && TEST_EVIDENCE_ENABLED="true"

      # Read block_on_fail (default true for backward compatibility)
      BLOCK_ON_FAIL=$(yq -r 'if .test_evidence.block_on_fail == false then "false" else "true" end' "$TALISMAN_PATH" 2>/dev/null) || BLOCK_ON_FAIL="true"
      [[ -z "$BLOCK_ON_FAIL" ]] && BLOCK_ON_FAIL="true"

      # Read skip_patterns as JSON array, then parse into bash array
      SKIP_PATTERNS_JSON=$(yq -r '.test_evidence.skip_patterns // [] | @json' "$TALISMAN_PATH" 2>/dev/null) || SKIP_PATTERNS_JSON="[]"
      if [[ "$SKIP_PATTERNS_JSON" != "[]" && -n "$SKIP_PATTERNS_JSON" ]]; then
        # Parse JSON array into bash array (safe: only alphanum, dash, underscore, star, dot, slash)
        while IFS= read -r pattern; do
          [[ -n "$pattern" ]] && SKIP_PATTERNS+=("$pattern")
        done < <(printf '%s' "$SKIP_PATTERNS_JSON" | jq -r '.[]' 2>/dev/null || true)
      fi
    fi
    break
  fi
done

# If test_evidence check is disabled, skip
if [[ "$TEST_EVIDENCE_ENABLED" == "false" ]]; then
  exit 0
fi

# ── Step 2.2: Check skip_patterns against task files (BACK-002) ──
# Read task definition to get assigned files, check if all match skip patterns
if [[ ${#SKIP_PATTERNS[@]} -gt 0 ]]; then
  TASK_FILE="$CHOME/tasks/$TEAM_NAME/$TASK_ID.json"
  if [[ -f "$TASK_FILE" ]]; then
    # Get file scope from task_ownership or description
    TASK_FILES=$(jq -r '.task_ownership // .description // empty' "$TASK_FILE" 2>/dev/null || echo "")
    if [[ -n "$TASK_FILES" ]]; then
      # Check if all task files match skip patterns
      ALL_SKIP=true
      while IFS= read -r task_file_path; do
        [[ -z "$task_file_path" ]] && continue
        MATCHES_SKIP=false
        for pattern in "${SKIP_PATTERNS[@]}"; do
          # Use fnmatch-style glob matching via case
          case "$task_file_path" in
            $pattern) MATCHES_SKIP=true; break ;;
          esac
        done
        if [[ "$MATCHES_SKIP" == "false" ]]; then
          ALL_SKIP=false
          break
        fi
      done < <(printf '%s' "$TASK_FILES" | jq -r 'if type == "array" then .[] else . end' 2>/dev/null || echo "$TASK_FILES")

      if [[ "$ALL_SKIP" == "true" ]]; then
        exit 0  # All files match skip patterns, skip test evidence check
      fi
    fi
  fi
fi

# ── Step 2.5: Resolve work directory ──
TIMESTAMP="${TEAM_NAME#rune-work-}"
TIMESTAMP="${TIMESTAMP#arc-work-}"

WORK_DIR=""
if [[ -d "$CWD/tmp/work/$TIMESTAMP" ]]; then
  WORK_DIR="$CWD/tmp/work/$TIMESTAMP"
else
  # Fallback: find most recent work dir using find (zsh-safe, no glob)
  WORK_DIR=$(find "$CWD/tmp/work" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -r | head -1)
fi

if [[ -z "$WORK_DIR" ]] || [[ ! -d "$WORK_DIR" ]]; then
  exit 0  # No work directory, skip
fi

# ── Step 2.7: Last-task-only optimization with atomic counting (FLAW-001 FIX) ──
# Check if this is the last task for this worker using file locking to prevent
# race conditions where concurrent task completions could both skip evidence validation.
#
# FLAW-001 RACE CONDITION: Without locking, two TaskCompleted hooks running concurrently
# for the same worker could both read REMAINING=2 (each counting the other task as
# non-completed) and both exit early, skipping evidence validation entirely.
#
# FIX: Use flock to ensure atomic read-evaluate-decide. Only one hook instance per
# worker can evaluate the "last task" condition at a time.
TASK_DIR="$CHOME/tasks/$TEAM_NAME"
if [[ -d "$TASK_DIR" ]]; then
  # Create lock file specific to this worker (prevents cross-worker contention)
  LOCK_FILE="${TMPDIR:-/tmp}/rune-test-evidence-${TEAM_NAME}-${TEAMMATE_NAME}.lock"
  LOCK_FD=200

  # Use flock with 2-second timeout (fail-open on lock contention)
  # This ensures atomic counting while preventing deadlocks
  (
    flock -w 2 $LOCK_FD 2>/dev/null || exit 0  # Fail-open on lock timeout

    REMAINING=0
    while IFS= read -r -d '' task_file; do
      if [[ -f "$task_file" ]]; then
        OWNER=$(jq -r '.owner // empty' "$task_file" 2>/dev/null || echo "")
        STATUS=$(jq -r '.status // empty' "$task_file" 2>/dev/null || echo "")
        if [[ "$OWNER" == "$TEAMMATE_NAME" ]] && [[ "$STATUS" != "completed" ]]; then
          REMAINING=$((REMAINING + 1))
        fi
      fi
    done < <(find "$TASK_DIR" -maxdepth 1 -name '*.json' -type f -print0 2>/dev/null)

    # Only skip if this is NOT the last task (REMAINING > 1 means current + others)
    if [[ $REMAINING -gt 1 ]]; then
      exit 99  # Signal to outer scope: skip validation
    fi
    exit 0  # Proceed with validation
  ) {LOCK_FD}>"$LOCK_FILE"
  LOCK_EXIT=$?

  # Clean up lock file on success (best effort, ignore errors)
  rm -f "$LOCK_FILE" 2>/dev/null || true

  if [[ $LOCK_EXIT -eq 99 ]]; then
    exit 0  # Worker has more tasks, check evidence at last task only
  fi
  # exit 0 from subshell = proceed with validation
  # exit 0 from flock timeout = fail-open, proceed with validation
fi

# ── Step 3: Check for test evidence files ──
SIGNAL_DIR="$CWD/tmp/.rune-signals/$TEAM_NAME"
WORKER_LOG_DIR="$WORK_DIR/worker-logs"

HAS_EVIDENCE=false

# Check signal directory for test evidence
if [[ -d "$SIGNAL_DIR" ]]; then
  while IFS= read -r -d '' evidence_file; do
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
  done < <(find "$SIGNAL_DIR" -maxdepth 1 -name '*.test-evidence' -type f -print0 2>/dev/null)
fi

# Check worker logs for test results
if [[ "$HAS_EVIDENCE" == "false" ]] && [[ -d "$WORKER_LOG_DIR" ]]; then
  while IFS= read -r -d '' log_file; do
    if [[ -f "$log_file" ]]; then
      SIZE=$(wc -c < "$log_file" 2>/dev/null || echo 0)
      if [[ $SIZE -gt $MIN_FILE_SIZE ]]; then
        if grep -qE '(PASS|FAIL|test|spec|pytest|jest|mocha)' "$log_file" 2>/dev/null; then
          HAS_EVIDENCE=true
          break
        fi
      fi
    fi
  done < <(find "$WORKER_LOG_DIR" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
fi

# ── Step 4: Check ward result files ──
if [[ "$HAS_EVIDENCE" == "false" ]]; then
  WARD_RESULT_COUNT=$(find "$WORK_DIR" -maxdepth 1 -type f -name 'ward-results-*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$WARD_RESULT_COUNT" -gt 0 ]]; then
    HAS_EVIDENCE=true
  fi
fi

# ── Step 5: Decision (BACK-002: respect block_on_fail config) ──
if [[ "$HAS_EVIDENCE" == "false" ]]; then
  FIRST_TEST=$(echo "$TEST_COMMANDS" | cut -d' ' -f1-2)
  if [[ "$BLOCK_ON_FAIL" == "true" ]]; then
    echo "BLOCK: No test evidence found. Tests exist ($FIRST_TEST) but no results detected. Run tests before marking task complete." >&2
    exit 2
  else
    # Soft enforcement: warn but don't block
    echo "[validate-test-evidence] WARN: No test evidence found. Tests exist ($FIRST_TEST) but no results detected. (block_on_fail: false — not blocking)" >&2
    exit 0
  fi
fi

exit 0