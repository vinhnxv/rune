#!/usr/bin/env bash
# test-meta-qa-detector.sh -- Tests for scripts/learn/meta-qa-detector.sh
#
# Usage: bash plugins/rune/scripts/tests/test-meta-qa-detector.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="${SCRIPT_DIR}/../learn/meta-qa-detector.sh"

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

assert_json_field() {
  local test_name="$1" field="$2" expected="$3" json="$4"
  local actual
  actual=$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d${field})" 2>/dev/null || echo "__PARSE_ERROR__")
  assert_eq "$test_name" "$expected" "$actual"
}

# -- Setup temp project structure --
TMP_PROJECT=$(mktemp -d "${TMPDIR:-/tmp}/rune-mqd-test-XXXXXX")
cleanup() { rm -rf "$TMP_PROJECT" "${RUNE_TRACE_LOG:-}" 2>/dev/null; }
trap cleanup EXIT INT TERM

# -- Dependency check --
if ! command -v python3 &>/dev/null; then
  printf "SKIP: python3 not available\n"
  exit 0
fi

# Ensure RUNE_TRACE_LOG points to a valid path (avoids ERR trap on empty redirect)
export RUNE_TRACE_LOG="/tmp/rune-mqd-test-trace-$$.log"

printf "=== meta-qa-detector.sh tests ===\n\n"

# -------------------------------------------------------
# Test 1: No .rune/arc directory -> error: no_arc_dir
# -------------------------------------------------------
printf "Test 1: No arc directory\n"
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" 2>/dev/null)
assert_json_field "error is no_arc_dir" '["error"]' "no_arc_dir" "$OUT"
assert_json_field "patterns is empty" '["patterns"]' "[]" "$OUT"

# -------------------------------------------------------
# Test 2: Empty arc directory -> error: no_checkpoints_found
# -------------------------------------------------------
printf "\nTest 2: Empty arc directory\n"
mkdir -p "$TMP_PROJECT/.rune/arc"
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" 2>/dev/null)
assert_contains "error about checkpoints" "no_checkpoint" "$OUT"

# -------------------------------------------------------
# Test 3: Incomplete arc (no ship/merge completed) -> no_completed_arcs
# -------------------------------------------------------
printf "\nTest 3: Incomplete arc\n"
ARC_DIR="$TMP_PROJECT/.rune/arc/arc-1000000001"
mkdir -p "$ARC_DIR"
cat > "$ARC_DIR/checkpoint.json" << 'EOF'
{
  "phases": {
    "work": {"status": "completed", "retry_count": 0},
    "code_review": {"status": "failed", "retry_count": 2}
  }
}
EOF
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
assert_json_field "error is no_completed_arcs" '["error"]' "no_completed_arcs" "$OUT"

# -------------------------------------------------------
# Test 4: Single completed arc with retries -> patterns detected
# -------------------------------------------------------
printf "\nTest 4: Single completed arc with retries\n"
cat > "$ARC_DIR/checkpoint.json" << 'EOF'
{
  "phases": {
    "work": {"status": "completed", "retry_count": 0, "duration_ms": 120000},
    "code_review": {"status": "completed", "retry_count": 2, "duration_ms": 360000},
    "ship": {"status": "completed", "retry_count": 0, "duration_ms": 30000}
  }
}
EOF
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
TOTAL_ARCS=$(printf '%s' "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_arcs_scanned',0))" 2>/dev/null)
assert_eq "total_arcs_scanned is 1" "1" "$TOTAL_ARCS"
# With only 1 arc, retry_rate for code_review = 1/1 = 100% -> should be flagged
PATTERN_COUNT=$(printf '%s' "$OUT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('patterns',[])))" 2>/dev/null)
assert_eq "patterns detected (retry_rate:code_review)" "1" "$PATTERN_COUNT"
assert_contains "pattern_key includes code_review" "retry_rate:code_review" "$OUT"

# -------------------------------------------------------
# Test 5: Multiple arcs with convergence -> convergence pattern
# -------------------------------------------------------
printf "\nTest 5: Multiple arcs with high convergence\n"
for i in 2 3 4; do
  ARC_N="$TMP_PROJECT/.rune/arc/arc-100000000${i}"
  mkdir -p "$ARC_N"
  cat > "$ARC_N/checkpoint.json" << EOF
{
  "phases": {
    "work": {"status": "completed", "retry_count": 0},
    "code_review": {"status": "completed", "retry_count": 1},
    "ship": {"status": "completed", "retry_count": 0}
  },
  "convergence_rounds": 3
}
EOF
done
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
TOTAL_ARCS=$(printf '%s' "$OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_arcs_scanned',0))" 2>/dev/null)
assert_eq "total_arcs_scanned is 4" "4" "$TOTAL_ARCS"
assert_contains "convergence pattern detected" "convergence:high_rounds" "$OUT"

# -------------------------------------------------------
# Test 6: Confidence scaling (3+ arcs -> 0.8)
# -------------------------------------------------------
printf "\nTest 6: Confidence scaling\n"
CONV_CONFIDENCE=$(printf '%s' "$OUT" | python3 -c "
import sys,json
patterns = json.load(sys.stdin).get('patterns',[])
conv = [p for p in patterns if p.get('pattern_key') == 'convergence:high_rounds']
print(conv[0]['confidence'] if conv else 'NONE')
" 2>/dev/null)
assert_eq "convergence confidence is 0.8 (3+ arcs)" "0.8" "$CONV_CONFIDENCE"

# -------------------------------------------------------
# Test 7: Dedup against existing echoes
# -------------------------------------------------------
printf "\nTest 7: Dedup against existing echoes\n"
mkdir -p "$TMP_PROJECT/.rune/echoes/meta-qa"
cat > "$TMP_PROJECT/.rune/echoes/meta-qa/MEMORY.md" << 'EOF'
### [2026-03-19] Pattern: code_review retries
- **pattern_key**: retry_rate:code_review
- **confidence**: 0.8
EOF
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
# retry_rate:code_review should be deduplicated (already in echoes)
HAS_RETRY=$(printf '%s' "$OUT" | python3 -c "
import sys,json
patterns = json.load(sys.stdin).get('patterns',[])
print('yes' if any(p['pattern_key'] == 'retry_rate:code_review' for p in patterns) else 'no')
" 2>/dev/null)
assert_eq "retry_rate:code_review deduplicated" "no" "$HAS_RETRY"

# -------------------------------------------------------
# Test 8: QA score below 70 -> qa_score pattern
# -------------------------------------------------------
printf "\nTest 8: QA score below 70\n"
rm -f "$TMP_PROJECT/.rune/echoes/meta-qa/MEMORY.md"
ARC_QA="$TMP_PROJECT/.rune/arc/arc-1000000005"
mkdir -p "$ARC_QA"
cat > "$ARC_QA/checkpoint.json" << 'EOF'
{
  "phases": {
    "work": {"status": "completed"},
    "code_review": {"status": "completed"},
    "ship": {"status": "completed"}
  },
  "qa": {
    "code_review": {"score": 55},
    "work": {"score": 85}
  }
}
EOF
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
assert_contains "qa_score pattern detected" "qa_score:code_review" "$OUT"

# -------------------------------------------------------
# Test 9: Path traversal rejection
# -------------------------------------------------------
printf "\nTest 9: Path traversal rejection\n"
PT_EXIT=0
OUT=$(bash "$DETECTOR" --project "/tmp/../../../etc" 2>&1) || PT_EXIT=$?
assert_eq "path traversal exits non-zero" "1" "$PT_EXIT"

# -------------------------------------------------------
# Test 10: Fail-forward on corrupted checkpoint
# -------------------------------------------------------
printf "\nTest 10: Corrupted checkpoint JSON\n"
CORRUPT_DIR="$TMP_PROJECT/.rune/arc/arc-1000000099"
mkdir -p "$CORRUPT_DIR"
echo "NOT VALID JSON{{{" > "$CORRUPT_DIR/checkpoint.json"
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
# Should still succeed (exit 0) and include valid arcs
EXIT_CODE=$?
assert_eq "exits 0 despite corrupted checkpoint" "0" "$EXIT_CODE"
assert_contains "output is valid JSON" "patterns" "$OUT"

# -------------------------------------------------------
# Test 11: Symlink checkpoint is skipped
# -------------------------------------------------------
printf "\nTest 11: Symlink checkpoint skipped\n"
LINK_DIR="$TMP_PROJECT/.rune/arc/arc-1000000098"
mkdir -p "$LINK_DIR"
ln -sf "/etc/passwd" "$LINK_DIR/checkpoint.json" 2>/dev/null || true
OUT=$(bash "$DETECTOR" --project "$TMP_PROJECT" --since 30 2>/dev/null)
# Should not crash and should not include the symlinked checkpoint
assert_contains "output is valid JSON" "patterns" "$OUT"

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
printf "\n=== Results: %d/%d passed ===\n" "$PASS_COUNT" "$TOTAL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf "FAILURES: %d\n" "$FAIL_COUNT"
  exit 1
fi
exit 0
