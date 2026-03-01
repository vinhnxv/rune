#!/usr/bin/env bash
# test-review-recurrence-detector.sh — Tests for scripts/learn/review-recurrence-detector.sh
#
# Usage: bash plugins/rune/scripts/tests/test-review-recurrence-detector.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="${SCRIPT_DIR}/../learn/review-recurrence-detector.sh"

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

# ── Fixture setup ──
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

setup_tome() {
  local dir="$1"
  local name="$2"
  local content="$3"
  mkdir -p "${TMPDIR_TEST}/${dir}/${name}"
  printf '%s\n' "$content" > "${TMPDIR_TEST}/${dir}/${name}/TOME.md"
}

setup_echo() {
  local role="$1"
  local content="$2"
  mkdir -p "${TMPDIR_TEST}/.claude/echoes/${role}"
  printf '%s\n' "$content" > "${TMPDIR_TEST}/.claude/echoes/${role}/MEMORY.md"
}

# ═══════════════════════════════════════════════════════════════
# 1. Basic invocation — no TOME files
# ═══════════════════════════════════════════════════════════════
printf "\n=== No TOME files ===\n"

EMPTY_PROJECT=$(mktemp -d)
trap 'rm -rf "$EMPTY_PROJECT"' EXIT
result=$(bash "$DETECTOR" --project "$EMPTY_PROJECT")
assert_contains "No TOMEs returns empty recurrences" '"recurrences"' "$result"
# Validate JSON structure
valid=$(python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); assert "recurrences" in d' <<< "$result" 2>/dev/null && echo "yes" || echo "no")
assert_eq "Output is valid JSON with recurrences key" "yes" "$valid"

# ═══════════════════════════════════════════════════════════════
# 2. Single TOME — below min-count threshold
# ═══════════════════════════════════════════════════════════════
printf "\n=== Single TOME (below threshold) ===\n"

setup_tome "tmp/reviews" "review-001" "## Findings

- **SEC-001**: SQL injection in query builder
- **QUAL-002**: Missing error handling
"

result=$(bash "$DETECTOR" --project "$TMPDIR_TEST" --min-count 2)
assert_not_contains "Single TOME below threshold: no finding_id" '"finding_id"' "$result"
assert_not_contains "SEC-001 not flagged (single TOME)" '"SEC-001"' "$result"

# ═══════════════════════════════════════════════════════════════
# 3. Two TOMEs with the same finding — should be flagged
# ═══════════════════════════════════════════════════════════════
printf "\n=== Two TOMEs with shared finding ===\n"

setup_tome "tmp/reviews" "review-002" "## Findings

- **SEC-001**: SQL injection via string interpolation in user query
- **QUAL-005**: Unused imports in module
"

result=$(bash "$DETECTOR" --project "$TMPDIR_TEST" --min-count 2)
assert_contains "SEC-001 found in 2 TOMEs" '"SEC-001"' "$result"
assert_contains "count is 2" '"count": 2' "$result"
assert_contains "severity high for SEC prefix" '"severity": "high"' "$result"
assert_not_contains "QUAL-005 not flagged (single TOME)" '"QUAL-005"' "$result"

# ═══════════════════════════════════════════════════════════════
# 4. Finding already in echo — should NOT be flagged
# ═══════════════════════════════════════════════════════════════
printf "\n=== Finding echoed — skip ===\n"

setup_echo "reviewer" "## Inscribed — Security Review

SEC-001 was already captured and addressed in the echo system.
"

result=$(bash "$DETECTOR" --project "$TMPDIR_TEST" --min-count 2)
assert_not_contains "SEC-001 skipped (already echoed)" '"SEC-001"' "$result"

# ═══════════════════════════════════════════════════════════════
# 5. Severity inference
# ═══════════════════════════════════════════════════════════════
printf "\n=== Severity inference ===\n"

# Add new project with BACK and QUAL findings in 2 TOMEs each
SEV_PROJECT=$(mktemp -d)
trap 'rm -rf "$SEV_PROJECT"' EXIT
mkdir -p "${SEV_PROJECT}/tmp/reviews/rev-a" "${SEV_PROJECT}/tmp/reviews/rev-b"
printf '%s\n' "- **BACK-003**: Unsafe use of eval in template processor" > "${SEV_PROJECT}/tmp/reviews/rev-a/TOME.md"
printf '%s\n' "- **QUAL-007**: Missing docstring" >> "${SEV_PROJECT}/tmp/reviews/rev-a/TOME.md"
printf '%s\n' "- **BACK-003**: Eval injection risk" > "${SEV_PROJECT}/tmp/reviews/rev-b/TOME.md"
printf '%s\n' "- **QUAL-007**: No docstrings in module" >> "${SEV_PROJECT}/tmp/reviews/rev-b/TOME.md"

result=$(bash "$DETECTOR" --project "$SEV_PROJECT" --min-count 2)
assert_contains "BACK prefix maps to medium severity" '"severity": "medium"' "$result"
# QUAL-007 appears in 2 TOMEs — should be flagged
assert_contains "QUAL-007 found in 2 TOMEs" '"QUAL-007"' "$result"
qual_severity=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
r = next((x for x in d['recurrences'] if x['finding_id'] == 'QUAL-007'), None)
print(r['severity'] if r else 'missing')
" <<< "$result")
assert_eq "QUAL prefix maps to low severity" "low" "$qual_severity"

# ═══════════════════════════════════════════════════════════════
# 6. Findings from tmp/audit/ directory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Findings from tmp/audit/ ===\n"

AUDIT_PROJECT=$(mktemp -d)
trap 'rm -rf "$AUDIT_PROJECT"' EXIT
mkdir -p "${AUDIT_PROJECT}/tmp/audit/audit-001" "${AUDIT_PROJECT}/tmp/audit/audit-002"
printf '%s\n' "- **VEIL-001**: Sensitive data in log output" > "${AUDIT_PROJECT}/tmp/audit/audit-001/TOME.md"
printf '%s\n' "- **VEIL-001**: Credential logging detected" > "${AUDIT_PROJECT}/tmp/audit/audit-002/TOME.md"

result=$(bash "$DETECTOR" --project "$AUDIT_PROJECT" --min-count 2)
assert_contains "VEIL-001 found across audit TOMEs" '"VEIL-001"' "$result"
assert_contains "VEIL maps to medium severity" '"severity": "medium"' "$result"

# ═══════════════════════════════════════════════════════════════
# 7. JSON output structure validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== JSON output structure ===\n"

result=$(bash "$DETECTOR" --project "$SEV_PROJECT" --min-count 2)
structure_ok=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'recurrences' in d
for r in d['recurrences']:
    assert 'finding_id' in r
    assert 'tome_paths' in r
    assert 'count' in r
    assert 'severity' in r
    assert isinstance(r['tome_paths'], list)
    assert isinstance(r['count'], int)
print('ok')
" <<< "$result" 2>/dev/null)
assert_eq "JSON output has required schema fields" "ok" "$structure_ok"

# ═══════════════════════════════════════════════════════════════
# 8. Sorting — high severity first
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sorting order ===\n"

SORT_PROJECT=$(mktemp -d)
trap 'rm -rf "$SORT_PROJECT"' EXIT
mkdir -p "${SORT_PROJECT}/tmp/reviews/rev-x" "${SORT_PROJECT}/tmp/reviews/rev-y"
printf '%s\n' "- **QUAL-001**: Missing tests" "- **SEC-002**: XSS in template" > "${SORT_PROJECT}/tmp/reviews/rev-x/TOME.md"
printf '%s\n' "- **QUAL-001**: No test coverage" "- **SEC-002**: Cross-site scripting" > "${SORT_PROJECT}/tmp/reviews/rev-y/TOME.md"

result=$(bash "$DETECTOR" --project "$SORT_PROJECT" --min-count 2)
first_id=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d['recurrences'][0]['finding_id'] if d['recurrences'] else 'empty')
" <<< "$result")
assert_eq "SEC finding sorted first (high severity)" "SEC-002" "$first_id"

# ═══════════════════════════════════════════════════════════════
# 9. --min-count override
# ═══════════════════════════════════════════════════════════════
printf "\n=== min-count=3 requires 3 TOMEs ===\n"

MC_PROJECT=$(mktemp -d)
trap 'rm -rf "$MC_PROJECT"' EXIT
mkdir -p "${MC_PROJECT}/tmp/reviews/r1" "${MC_PROJECT}/tmp/reviews/r2"
printf '%s\n' "- **SEC-010**: Buffer overflow" > "${MC_PROJECT}/tmp/reviews/r1/TOME.md"
printf '%s\n' "- **SEC-010**: Memory corruption" > "${MC_PROJECT}/tmp/reviews/r2/TOME.md"

result=$(bash "$DETECTOR" --project "$MC_PROJECT" --min-count 3)
assert_not_contains "SEC-010 not flagged with min-count=3 (only 2 TOMEs)" '"SEC-010"' "$result"

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
