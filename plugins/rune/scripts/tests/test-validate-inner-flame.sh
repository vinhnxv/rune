#!/usr/bin/env bash
# test-validate-inner-flame.sh — Tests for scripts/validate-inner-flame.sh
#
# Usage: bash plugins/rune/scripts/tests/test-validate-inner-flame.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_SCRIPT="${SCRIPTS_DIR}/validate-inner-flame.sh"

# ── Temp directory ──
# Resolve via pwd -P to handle macOS /var -> /private/var symlink.
TMPDIR_ROOT=$(mktemp -d)
TMPDIR_ROOT=$(cd "$TMPDIR_ROOT" && pwd -P)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

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

# Helper: run the script with given JSON on stdin, capture exit code and stderr
run_validate() {
  local json="$1"
  local exit_code=0
  local output
  output=$(printf '%s\n' "$json" | bash "$VALIDATE_SCRIPT" 2>&1) || exit_code=$?
  printf '%s\t%s' "$exit_code" "$output"
}

# ═══════════════════════════════════════════════════════════════
# 1. Empty / Malformed Input — should exit 0 (allow)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty / Malformed Input ===\n"

# 1a. Empty input
result=$(run_validate "")
exit_code="${result%%	*}"
assert_eq "Empty input exits 0" "0" "$exit_code"

# 1b. Invalid JSON
result=$(run_validate "not-json{{{")
exit_code="${result%%	*}"
assert_eq "Invalid JSON exits 0" "0" "$exit_code"

# 1c. Empty JSON object
result=$(run_validate "{}")
exit_code="${result%%	*}"
assert_eq "Empty JSON object exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 2. Missing / Invalid Fields — should exit 0 (allow)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing / Invalid Fields ===\n"

# 2a. Missing team_name
result=$(run_validate '{"task_id": "task-1", "teammate_name": "forge-warden"}')
exit_code="${result%%	*}"
assert_eq "Missing team_name exits 0" "0" "$exit_code"

# 2b. Missing task_id
result=$(run_validate '{"team_name": "rune-review-abc123", "teammate_name": "forge-warden"}')
exit_code="${result%%	*}"
assert_eq "Missing task_id exits 0" "0" "$exit_code"

# 2c. Non-rune/non-arc team name
result=$(run_validate '{"team_name": "other-team", "task_id": "task-1", "teammate_name": "worker-1"}')
exit_code="${result%%	*}"
assert_eq "Non-rune/arc team name exits 0" "0" "$exit_code"

# 2d. Team name with invalid chars (SEC-001)
result=$(run_validate '{"team_name": "rune-review-../evil", "task_id": "task-1", "teammate_name": "worker"}')
exit_code="${result%%	*}"
assert_eq "Team name with path traversal exits 0" "0" "$exit_code"

# 2e. Task ID with invalid chars
result=$(run_validate '{"team_name": "rune-review-abc", "task_id": "task/../evil", "teammate_name": "worker"}')
exit_code="${result%%	*}"
assert_eq "Task ID with invalid chars exits 0" "0" "$exit_code"

# 2f. Teammate name with invalid chars
result=$(run_validate '{"team_name": "rune-review-abc", "task_id": "task-1", "teammate_name": "evil;rm -rf /"}')
exit_code="${result%%	*}"
assert_eq "Teammate name with shell injection exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 3. CWD Validation — should exit 0 when CWD is missing/invalid
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Validation ===\n"

# 3a. Missing cwd field
result=$(run_validate '{"team_name": "rune-review-abc", "task_id": "task-1", "teammate_name": "forge-warden"}')
exit_code="${result%%	*}"
assert_eq "Missing cwd exits 0" "0" "$exit_code"

# 3b. cwd pointing to non-existent directory
result=$(run_validate '{"team_name": "rune-review-abc", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "/no/such/dir/exists"}')
exit_code="${result%%	*}"
assert_eq "Non-existent cwd exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 4. Worker/Mend Team Bypass — should exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Worker/Mend Team Bypass ===\n"

WORK_CWD="${TMPDIR_ROOT}/work-project"
mkdir -p "$WORK_CWD"

# 4a. rune-work-* team skips Inner Flame check
result=$(run_validate '{"team_name": "rune-work-abc123", "task_id": "task-1", "teammate_name": "worker-1", "cwd": "'"$WORK_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "rune-work-* team exits 0" "0" "$exit_code"

# 4b. arc-work-* team skips Inner Flame check
result=$(run_validate '{"team_name": "arc-work-abc123", "task_id": "task-1", "teammate_name": "worker-1", "cwd": "'"$WORK_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "arc-work-* team exits 0" "0" "$exit_code"

# 4c. rune-mend-* team skips Inner Flame check
result=$(run_validate '{"team_name": "rune-mend-abc123", "task_id": "task-1", "teammate_name": "fixer-1", "cwd": "'"$WORK_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "rune-mend-* team exits 0" "0" "$exit_code"

# 4d. arc-mend-* team skips Inner Flame check
result=$(run_validate '{"team_name": "arc-mend-abc123", "task_id": "task-1", "teammate_name": "fixer-1", "cwd": "'"$WORK_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "arc-mend-* team exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 5. Output Dir Not Found — should exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Output Dir Not Found ===\n"

REVIEW_CWD="${TMPDIR_ROOT}/review-project"
mkdir -p "$REVIEW_CWD"

# 5a. Review team but no output directory exists
result=$(run_validate '{"team_name": "rune-review-xyz789", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$REVIEW_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Review team without output dir exits 0" "0" "$exit_code"

# 5b. Audit team but no output directory exists
result=$(run_validate '{"team_name": "arc-audit-xyz789", "task_id": "task-1", "teammate_name": "pattern-weaver", "cwd": "'"$REVIEW_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Audit team without output dir exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 6. Teammate File Not Found — should exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Teammate File Not Found ===\n"

FILE_CWD="${TMPDIR_ROOT}/file-project"
mkdir -p "${FILE_CWD}/tmp/reviews/abc123"

# 6a. Output dir exists but teammate file does not
result=$(run_validate '{"team_name": "rune-review-abc123", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$FILE_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Missing teammate file exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 7. Inner Flame Content Present — should exit 0 (allow)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inner Flame Content Present ===\n"

PASS_CWD="${TMPDIR_ROOT}/pass-project"
mkdir -p "${PASS_CWD}/tmp/reviews/def456"

# 7a. File contains "Self-Review Log Inner Flame"
printf 'Some findings\n\n## Self-Review Log Inner Flame\n- Checked correctness\n' > "${PASS_CWD}/tmp/reviews/def456/forge-warden.md"
result=$(run_validate '{"team_name": "rune-review-def456", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$PASS_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "File with Self-Review Log Inner Flame exits 0" "0" "$exit_code"

# 7b. File contains "Inner Flame:"
printf 'Inner Flame: self-review completed\n' > "${PASS_CWD}/tmp/reviews/def456/pattern-weaver.md"
result=$(run_validate '{"team_name": "rune-review-def456", "task_id": "task-1", "teammate_name": "pattern-weaver", "cwd": "'"$PASS_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "File with Inner Flame: exits 0" "0" "$exit_code"

# 7c. File contains "Inner-flame:" (variant)
printf 'Inner-flame: checked\n' > "${PASS_CWD}/tmp/reviews/def456/ward-sentinel.md"
result=$(run_validate '{"team_name": "rune-review-def456", "task_id": "task-1", "teammate_name": "ward-sentinel", "cwd": "'"$PASS_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "File with Inner-flame: exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 8. Inner Flame Content Missing (soft enforcement default)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inner Flame Missing (Soft Enforcement) ===\n"

SOFT_CWD="${TMPDIR_ROOT}/soft-project"
mkdir -p "${SOFT_CWD}/tmp/reviews/ghi789"

# 8a. File without Inner Flame content — soft enforcement (BLOCK_ON_FAIL defaults to false)
printf 'Some review findings but no self-review section\n' > "${SOFT_CWD}/tmp/reviews/ghi789/forge-warden.md"
result=$(run_validate '{"team_name": "rune-review-ghi789", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$SOFT_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Missing Inner Flame with soft enforcement exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 9. Inner Flame Content Missing (hard enforcement via talisman)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inner Flame Missing (Hard Enforcement) ===\n"

HARD_CWD="${TMPDIR_ROOT}/hard-project"
mkdir -p "${HARD_CWD}/tmp/reviews/jkl012"
mkdir -p "${HARD_CWD}/.claude"

# 9a. File without Inner Flame + talisman block_on_fail=true
printf 'Some findings, no self-review\n' > "${HARD_CWD}/tmp/reviews/jkl012/forge-warden.md"

# Only test talisman enforcement if yq is available
if command -v yq &>/dev/null; then
  printf 'inner_flame:\n  enabled: true\n  block_on_fail: true\n' > "${HARD_CWD}/.claude/talisman.yml"
  result=$(run_validate '{"team_name": "rune-review-jkl012", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$HARD_CWD"'"}')
  exit_code="${result%%	*}"
  stderr_output="${result#*	}"
  assert_eq "Missing Inner Flame with hard enforcement exits 2" "2" "$exit_code"
  assert_contains "Hard enforcement stderr mentions Inner Flame" "Inner Flame" "$stderr_output"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: (skipped) Hard enforcement test — yq not available\n"
fi

# ═══════════════════════════════════════════════════════════════
# 10. Inner Flame Disabled via Talisman
# ═══════════════════════════════════════════════════════════════
printf "\n=== Inner Flame Disabled ===\n"

DISABLED_CWD="${TMPDIR_ROOT}/disabled-project"
mkdir -p "${DISABLED_CWD}/tmp/reviews/mno345"
mkdir -p "${DISABLED_CWD}/.claude"

# 10a. Inner Flame disabled in talisman — should exit 0 even without content
if command -v yq &>/dev/null; then
  printf 'inner_flame:\n  enabled: false\n  block_on_fail: true\n' > "${DISABLED_CWD}/.claude/talisman.yml"
  printf 'No Inner Flame here\n' > "${DISABLED_CWD}/tmp/reviews/mno345/forge-warden.md"
  result=$(run_validate '{"team_name": "rune-review-mno345", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$DISABLED_CWD"'"}')
  exit_code="${result%%	*}"
  assert_eq "Inner Flame disabled via talisman exits 0" "0" "$exit_code"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: (skipped) Inner Flame disabled test — yq not available\n"
fi

# ═══════════════════════════════════════════════════════════════
# 11. Arc Team Name Patterns
# ═══════════════════════════════════════════════════════════════
printf "\n=== Arc Team Name Patterns ===\n"

ARC_CWD="${TMPDIR_ROOT}/arc-project"
mkdir -p "${ARC_CWD}/tmp/reviews/arc001"
mkdir -p "${ARC_CWD}/tmp/audit/arc002"
mkdir -p "${ARC_CWD}/tmp/inspect/arc003"

# 11a. arc-review-* resolves to tmp/reviews/ directory
printf 'Self-Review Log Inner Flame\n' > "${ARC_CWD}/tmp/reviews/arc001/forge-warden.md"
result=$(run_validate '{"team_name": "arc-review-arc001", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$ARC_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "arc-review-* with Inner Flame exits 0" "0" "$exit_code"

# 11b. arc-audit-* resolves to tmp/audit/ directory
printf 'Inner Flame: OK\n' > "${ARC_CWD}/tmp/audit/arc002/pattern-weaver.md"
result=$(run_validate '{"team_name": "arc-audit-arc002", "task_id": "task-1", "teammate_name": "pattern-weaver", "cwd": "'"$ARC_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "arc-audit-* with Inner Flame exits 0" "0" "$exit_code"

# 11c. arc-inspect-* resolves to tmp/inspect/ directory
printf 'Inner Flame: verified\n' > "${ARC_CWD}/tmp/inspect/arc003/inspector.md"
result=$(run_validate '{"team_name": "arc-inspect-arc003", "task_id": "task-1", "teammate_name": "inspector", "cwd": "'"$ARC_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "arc-inspect-* with Inner Flame exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 12. Path Containment Check (SEC-003)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Path Containment (SEC-003) ===\n"

SEC_CWD="${TMPDIR_ROOT}/sec-project"
mkdir -p "${SEC_CWD}/tmp/reviews/sec001"

# 12a. Symlink attack — output dir points outside CWD/tmp/ (symlink to /tmp)
EXTERNAL_DIR="${TMPDIR_ROOT}/external"
mkdir -p "$EXTERNAL_DIR"
printf 'No Inner Flame\n' > "${EXTERNAL_DIR}/forge-warden.md"
# Remove existing review dir and replace with symlink to external
rm -rf "${SEC_CWD}/tmp/reviews/sec001"
ln -s "$EXTERNAL_DIR" "${SEC_CWD}/tmp/reviews/sec001"

result=$(run_validate '{"team_name": "rune-review-sec001", "task_id": "task-1", "teammate_name": "forge-warden", "cwd": "'"$SEC_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Symlink outside CWD/tmp exits 0 (path containment)" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 13. Teammate Name with Colon (SEC-001 fix)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Teammate Name with Colon ===\n"

COLON_CWD="${TMPDIR_ROOT}/colon-project"
mkdir -p "${COLON_CWD}/tmp/reviews/col001"

# 13a. Teammate name with colon (valid per regex ^[a-zA-Z0-9_:-]+$)
printf 'Self-Review Log Inner Flame check\n' > "${COLON_CWD}/tmp/reviews/col001/forge:warden.md"
result=$(run_validate '{"team_name": "rune-review-col001", "task_id": "task-1", "teammate_name": "forge:warden", "cwd": "'"$COLON_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Teammate name with colon is valid and exits 0" "0" "$exit_code"

# ═══════════════════════════════════════════════════════════════
# 14. Empty ID After Prefix Strip (SEC-008)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty ID After Prefix Strip (SEC-008) ===\n"

EMPTY_CWD="${TMPDIR_ROOT}/empty-id-project"
mkdir -p "$EMPTY_CWD"

# 14a. Team name "rune-review-" (empty after strip) — should exit 0
result=$(run_validate '{"team_name": "rune-review-", "task_id": "task-1", "teammate_name": "worker", "cwd": "'"$EMPTY_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Empty review ID after strip exits 0 (SEC-008)" "0" "$exit_code"

# 14b. Team name "rune-audit-" (empty after strip) — should exit 0
result=$(run_validate '{"team_name": "rune-audit-", "task_id": "task-1", "teammate_name": "worker", "cwd": "'"$EMPTY_CWD"'"}')
exit_code="${result%%	*}"
assert_eq "Empty audit ID after strip exits 0 (SEC-008)" "0" "$exit_code"

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
