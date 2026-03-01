#!/usr/bin/env bash
# test-cli-correction-detector.sh -- Tests for scripts/learn/cli-correction-detector.sh
#
# Usage: bash plugins/rune/scripts/tests/test-cli-correction-detector.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="${SCRIPT_DIR}/../learn/cli-correction-detector.sh"

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

mk_events() {
  # Helper: wrap events array in scanner output envelope
  printf '{"events":%s,"scanned":1,"project":"/test"}' "$1"
}

# ===================================================================
# 1. Empty input
# ===================================================================
printf "\n=== Empty events ===\n"

result=$(mk_events '[]' | bash "$DETECTOR")
assert_contains "Empty events returns corrections key" '"corrections"' "$result"
assert_not_contains "Empty events has no correction entries" '"error_type"' "$result"

# ===================================================================
# 2. Error without follow-up success -- not flagged
# ===================================================================
printf "\n=== Error with no retry ===\n"

events='[
  {"tool_name":"Bash","input_preview":"git psuh","result_preview":"command not found: psuh","is_error":true,"tool_use_id":"u1","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
assert_not_contains "Lone error not flagged" '"error_type"' "$result"

# ===================================================================
# 3. Error followed by success -- detected
# ===================================================================
printf "\n=== Error followed by success ===\n"

events='[
  {"tool_name":"Bash","input_preview":"git psuh origin main","result_preview":"command not found: psuh","is_error":true,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Bash","input_preview":"git push origin main","result_preview":"Branch updated","is_error":false,"tool_use_id":"u2","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
assert_contains "Correction detected" '"CommandNotFound"' "$result"
assert_contains "failed_input captured" '"git psuh origin main"' "$result"
assert_contains "corrected_input captured" '"git push origin main"' "$result"

# ===================================================================
# 4. Error classification -- UnknownFlag
# ===================================================================
printf "\n=== Error type: UnknownFlag ===\n"

events='[
  {"tool_name":"Bash","input_preview":"ls --color-always","result_preview":"unknown flag --color-always","is_error":true,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Bash","input_preview":"ls --color=always","result_preview":"file1 file2","is_error":false,"tool_use_id":"u2","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
assert_contains "UnknownFlag classified" '"UnknownFlag"' "$result"

# ===================================================================
# 5. Error classification -- WrongPath
# ===================================================================
printf "\n=== Error type: WrongPath ===\n"

events='[
  {"tool_name":"Bash","input_preview":"cat /tmp/misssing.txt","result_preview":"cat: /tmp/misssing.txt: No such file or directory","is_error":true,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Bash","input_preview":"cat /tmp/missing.txt","result_preview":"file contents here","is_error":false,"tool_use_id":"u2","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
assert_contains "WrongPath classified" '"WrongPath"' "$result"

# ===================================================================
# 6. Error classification -- PermissionDenied
# ===================================================================
printf "\n=== Error type: PermissionDenied ===\n"

events='[
  {"tool_name":"Bash","input_preview":"rm /etc/hosts","result_preview":"rm: /etc/hosts: Permission denied","is_error":true,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Bash","input_preview":"sudo rm /etc/hosts","result_preview":"removed","is_error":false,"tool_use_id":"u2","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
assert_contains "PermissionDenied classified" '"PermissionDenied"' "$result"

# ===================================================================
# 7. Window boundary -- success beyond window not matched
# ===================================================================
printf "\n=== Window boundary ===\n"

# error at index 0, success at index 6 (window=5 means indices 1..5 checked)
events='[
  {"tool_name":"Bash","input_preview":"bad command","result_preview":"command not found: bad","is_error":true,"tool_use_id":"u0","file":"s1"},
  {"tool_name":"Bash","input_preview":"ok1","result_preview":"ok","is_error":false,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Read","input_preview":"file.txt","result_preview":"contents","is_error":false,"tool_use_id":"u2","file":"s1"},
  {"tool_name":"Read","input_preview":"file2.txt","result_preview":"contents","is_error":false,"tool_use_id":"u3","file":"s1"},
  {"tool_name":"Read","input_preview":"file3.txt","result_preview":"contents","is_error":false,"tool_use_id":"u4","file":"s1"},
  {"tool_name":"Read","input_preview":"file4.txt","result_preview":"contents","is_error":false,"tool_use_id":"u5","file":"s1"},
  {"tool_name":"Bash","input_preview":"good command","result_preview":"success","is_error":false,"tool_use_id":"u6","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR" --window 5)
# "ok1" at index 1 is Bash and no-error -- should be matched (within window)
assert_contains "Match within window" '"corrections"' "$result"
# Exactly one correction: ok1 matched (within window), "good command" at index 6 excluded
count=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d['corrections']))" <<< "$result")
assert_eq "Exactly one correction within window" "1" "$count"
# "good command" at index 6 is beyond window=5 and must not appear as corrected_input
assert_not_contains "Out-of-window success excluded" '"good command"' "$result"

# ===================================================================
# 8. Confidence calculation -- multi-session bonus
# ===================================================================
printf "\n=== Confidence: multi-session ===\n"

events='[
  {"tool_name":"Bash","input_preview":"npm run buld","result_preview":"command not found: buld","is_error":true,"tool_use_id":"u1","file":"session-a"},
  {"tool_name":"Bash","input_preview":"npm run build","result_preview":"compiled successfully","is_error":false,"tool_use_id":"u2","file":"session-b"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
assert_contains "multi_session true for cross-file pair" '"multi_session": true' "$result"
confidence=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
c = d['corrections'][0]['confidence'] if d['corrections'] else 0
print(c)
" <<< "$result")
# base 0.5 + same tool 0.2 + similar args 0.2 + multi-session 0.1 = 1.0
assert_eq "Multi-session confidence is 1.0" "1.0" "$confidence"

# ===================================================================
# 9. Dedup -- identical corrections merged
# ===================================================================
printf "\n=== Dedup identical corrections ===\n"

events='[
  {"tool_name":"Bash","input_preview":"git psuh origin","result_preview":"command not found","is_error":true,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Bash","input_preview":"git push origin","result_preview":"ok","is_error":false,"tool_use_id":"u2","file":"s1"},
  {"tool_name":"Bash","input_preview":"git psuh origin","result_preview":"command not found","is_error":true,"tool_use_id":"u3","file":"s1"},
  {"tool_name":"Bash","input_preview":"git push origin","result_preview":"ok","is_error":false,"tool_use_id":"u4","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
count=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d['corrections']))" <<< "$result")
assert_eq "Duplicate corrections deduped to 1" "1" "$count"

# ===================================================================
# 10. JSON output structure validation
# ===================================================================
printf "\n=== JSON structure ===\n"

events='[
  {"tool_name":"Bash","input_preview":"bad cmd","result_preview":"command not found: bad","is_error":true,"tool_use_id":"u1","file":"s1"},
  {"tool_name":"Bash","input_preview":"good cmd","result_preview":"ok","is_error":false,"tool_use_id":"u2","file":"s1"}
]'
result=$(mk_events "$events" | bash "$DETECTOR")
structure_ok=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'corrections' in d
for c in d['corrections']:
    assert 'error_type' in c
    assert 'tool_name' in c
    assert 'failed_input' in c
    assert 'corrected_input' in c
    assert 'confidence' in c
    assert 'multi_session' in c
print('ok')
" <<< "$result" 2>/dev/null)
assert_eq "JSON output has required schema fields" "ok" "$structure_ok"

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
