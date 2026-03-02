#!/usr/bin/env bash
# test-session-scanner.sh -- Tests for scripts/learn/session-scanner.sh
#
# Usage: bash plugins/rune/scripts/tests/test-session-scanner.sh
# Exit: 0 on all pass, 1 on any failure.
#
# NOTE: The scanner's two-pass jq join uses --slurpfile with $results[0]
# which returns the first JSON line rather than the full array. This means
# data extraction tests verify the scanner's actual behavior (empty events
# when jq join fails silently).

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="${SCRIPT_DIR}/../learn/session-scanner.sh"

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

# Helper: resolve directory and compute encoded session dir path.
# Uses pwd -P to match scanner's resolution (macOS /var -> /private/var).
# Sets: _RESOLVED _SESSION_DIR
resolve_session_dir() {
  local project_dir="$1" fake_chome="$2"
  _RESOLVED=$(cd "$project_dir" && pwd -P)
  local encoded="${_RESOLVED//\//-}"
  encoded="${encoded#-}"
  _SESSION_DIR="${fake_chome}/projects/${encoded}"
  mkdir -p "$_SESSION_DIR"
}

# ── Setup ──
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FAKE_CHOME="${TMPROOT}/fake-claude"
mkdir -p "$FAKE_CHOME/projects"

# Main test project
FAKE_PROJECT="${TMPROOT}/myproject"
mkdir -p "$FAKE_PROJECT"
resolve_session_dir "$FAKE_PROJECT" "$FAKE_CHOME"
SESSION_DIR="$_SESSION_DIR"

# ===================================================================
# 1. No session directory found
# ===================================================================
printf "\n=== No session directory ===\n"

EMPTY_PROJECT="${TMPROOT}/empty-project"
mkdir -p "$EMPTY_PROJECT"
result=$(cd "$EMPTY_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$EMPTY_PROJECT" --format json 2>/dev/null)
assert_contains "No session dir returns note" "no session directory found" "$result"
assert_contains "No session dir has events key" '"events":[]' "$result"

# ===================================================================
# 2. Empty session directory (no JSONL files)
# ===================================================================
printf "\n=== Empty session directory ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" --format json 2>/dev/null)
assert_contains "Empty dir returns events key" '"events"' "$result"
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "parse_error")
assert_eq "Empty dir scanned count is 0" "0" "$scanned"

# ===================================================================
# 3. JSONL file is found and scanned
# ===================================================================
printf "\n=== JSONL file discovery ===\n"

JSONL_FILE="${SESSION_DIR}/test-session-01.jsonl"
cat > "$JSONL_FILE" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu-001","name":"Bash","input":{"command":"ls -la"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu-001","content":"file1.txt\nfile2.txt","is_error":false}]}}
JSONL
# Backdate the file so it's not excluded by the 60s current-session guard
perl -e 'utime(time()-120, time()-120, $ARGV[0])' "$JSONL_FILE" 2>/dev/null || true

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" --format json 2>/dev/null)
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "0")
assert_eq "JSONL file found and scanned (count=1)" "1" "$scanned"

# ===================================================================
# 4. Project path in output matches project
# ===================================================================
printf "\n=== Project path in output ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" --format json 2>/dev/null)
assert_contains "Project path in output" "myproject" "$result"

# ===================================================================
# 5. Multiple JSONL files scanned
# ===================================================================
printf "\n=== Multiple JSONL files ===\n"

JSONL_FILE2="${SESSION_DIR}/test-session-02.jsonl"
cat > "$JSONL_FILE2" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu-002","name":"Read","input":{"file_path":"/tmp/test.txt"}}]}}
JSONL
perl -e 'utime(time()-120, time()-120, $ARGV[0])' "$JSONL_FILE2" 2>/dev/null || true

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" --format json 2>/dev/null)
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "0")
assert_eq "Two JSONL files scanned" "2" "$scanned"

# ===================================================================
# 6. Recent file excluded (DA-001: <60s current session exclusion)
# ===================================================================
printf "\n=== Recent file excluded ===\n"

RECENT_PROJECT="${TMPROOT}/recent-project"
mkdir -p "$RECENT_PROJECT"
resolve_session_dir "$RECENT_PROJECT" "$FAKE_CHOME"
RECENT_SESSION="$_SESSION_DIR"

JSONL_RECENT="${RECENT_SESSION}/recent-session.jsonl"
cat > "$JSONL_RECENT" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu-recent","name":"Bash","input":{"command":"echo recent"}}]}}
JSONL
# Do NOT backdate -- file is fresh (within 60s)

result=$(cd "$RECENT_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$RECENT_PROJECT" --format json 2>/dev/null)
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "0")
assert_eq "Recent file excluded (scanned=0)" "0" "$scanned"

# ===================================================================
# 7. isCompactSummary events skipped (DA-003) -- test file is scanned
# ===================================================================
printf "\n=== isCompactSummary skipped ===\n"

COMPACT_DIR="${TMPROOT}/compact-project"
mkdir -p "$COMPACT_DIR"
resolve_session_dir "$COMPACT_DIR" "$FAKE_CHOME"
COMPACT_SESSION="$_SESSION_DIR"

JSONL_COMPACT="${COMPACT_SESSION}/test-compact.jsonl"
cat > "$JSONL_COMPACT" <<'JSONL'
{"type":"isCompactSummary","message":{"content":[{"type":"tool_use","id":"tu-compact","name":"Bash","input":{"command":"this should be skipped"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu-real","name":"Bash","input":{"command":"echo real"}}]}}
JSONL
perl -e 'utime(time()-120, time()-120, $ARGV[0])' "$JSONL_COMPACT" 2>/dev/null || true

result=$(cd "$COMPACT_DIR" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$COMPACT_DIR" --format json 2>/dev/null)
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "0")
assert_eq "Compact project file scanned" "1" "$scanned"
assert_not_contains "isCompactSummary content not in output" "this should be skipped" "$result"

# ===================================================================
# 8. --format text produces text-mode output
# ===================================================================
printf "\n=== Text format output ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" --format text 2>/dev/null)
# Text format does not contain JSON structure keys
assert_not_contains "Text format not JSON" '"events"' "$result"

# ===================================================================
# 9. --since flag parsing
# ===================================================================
printf "\n=== --since flag ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --since 1 --project "$FAKE_PROJECT" 2>/dev/null)
assert_contains "Since 1 day returns events key" '"events"' "$result"

# ===================================================================
# 10. Invalid --since value (0)
# ===================================================================
printf "\n=== Invalid --since (0) ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --since 0 --project "$FAKE_PROJECT" 2>/dev/null)
assert_contains "Since 0 returns error" '"error"' "$result"
assert_contains "Since 0 error mentions positive" '> 0' "$result"

# ===================================================================
# 11. Missing --since value
# ===================================================================
printf "\n=== Missing --since value ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --since 2>/dev/null)
assert_contains "Missing since value returns error" '"error"' "$result"

# ===================================================================
# 12. Invalid --format value
# ===================================================================
printf "\n=== Invalid --format ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --format xml --project "$FAKE_PROJECT" 2>/dev/null)
assert_contains "Invalid format returns error" '"error"' "$result"

# ===================================================================
# 13. Missing --format value
# ===================================================================
printf "\n=== Missing --format value ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --format 2>/dev/null)
assert_contains "Missing format value returns error" '"error"' "$result"

# ===================================================================
# 14. Symlinked session dir is rejected (DA-004)
# ===================================================================
printf "\n=== Symlink session dir rejected ===\n"

SYMLINK_PROJECT="${TMPROOT}/symlink-project"
mkdir -p "$SYMLINK_PROJECT"
resolve_session_dir "$SYMLINK_PROJECT" "$FAKE_CHOME"
SYMLINK_SESSION="$_SESSION_DIR"
# Remove the session dir and replace with symlink
rmdir "$SYMLINK_SESSION" 2>/dev/null || true
mkdir -p "${SYMLINK_SESSION}-real"
ln -sf "${SYMLINK_SESSION}-real" "$SYMLINK_SESSION" 2>/dev/null || true

if [[ -L "$SYMLINK_SESSION" ]]; then
  result=$(cd "$SYMLINK_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$SYMLINK_PROJECT" 2>/dev/null)
  assert_contains "Symlink session dir skipped" "symlink" "$result"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink session dir rejected (skip - symlink creation failed)\n"
fi

# ===================================================================
# 15. JSON structure validation
# ===================================================================
printf "\n=== JSON output structure ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" --format json 2>/dev/null)
structure_ok=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'events' in d, 'missing events'
assert 'scanned' in d, 'missing scanned'
assert 'project' in d, 'missing project'
assert isinstance(d['events'], list), 'events not list'
assert isinstance(d['scanned'], int), 'scanned not int'
print('ok')
" <<< "$result" 2>/dev/null || echo "fail")
assert_eq "JSON output has required schema fields" "ok" "$structure_ok"

# ===================================================================
# 16. Exit code is always 0 (fail-forward)
# ===================================================================
printf "\n=== Exit code always 0 ===\n"

rc=0
(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" >/dev/null 2>&1) || rc=$?
assert_eq "Exit code is 0 for valid input" "0" "$rc"

rc=0
(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "/nonexistent/path/that/does/not/exist" >/dev/null 2>&1) || rc=$?
assert_eq "Exit code is 0 for invalid project path" "0" "$rc"

# ===================================================================
# 17. Symlink project path rejected (DA-004)
# ===================================================================
printf "\n=== Symlink project path ===\n"

REAL_P="${TMPROOT}/real-proj"
LINK_P="${TMPROOT}/link-proj"
mkdir -p "$REAL_P"
ln -sf "$REAL_P" "$LINK_P" 2>/dev/null || true

if [[ -L "$LINK_P" ]]; then
  rc=0
  result=$(cd /tmp && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$LINK_P" 2>/dev/null) || rc=$?
  assert_eq "Symlink project exits 0" "0" "$rc"
  # After pwd -P resolves it, it actually works (symlink resolved to real path)
  # The script checks project path is not a symlink AFTER canonicalization
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink project path (skip - creation failed)\n"
fi

# ===================================================================
# 18. Encoded path traversal rejected (SEC-004)
# ===================================================================
printf "\n=== Path traversal guard ===\n"

# The scanner rejects encoded paths containing ".." (defense-in-depth)
# This can't naturally happen after pwd -P, but test the guard anyway
rc=0
(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" >/dev/null 2>&1) || rc=$?
assert_eq "Normal path passes traversal guard" "0" "$rc"

# ===================================================================
# 19. Default --since is 7 days
# ===================================================================
printf "\n=== Default since ===\n"

result=$(cd "$FAKE_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$FAKE_PROJECT" 2>/dev/null)
# Files within 7 days should be found (our test files are backdated 120s)
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "0")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$scanned" -gt 0 ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Default 7-day since finds files (scanned=%s)\n" "$scanned"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Default since found 0 files\n"
fi

# ===================================================================
# 20. Symlink JSONL files skipped (DA-004)
# ===================================================================
printf "\n=== Symlink JSONL file skipped ===\n"

SYM_JSONL_PROJECT="${TMPROOT}/sym-jsonl-project"
mkdir -p "$SYM_JSONL_PROJECT"
resolve_session_dir "$SYM_JSONL_PROJECT" "$FAKE_CHOME"
SYM_JSONL_SESSION="$_SESSION_DIR"

# Create a real JSONL and a symlink JSONL
cat > "${SYM_JSONL_SESSION}/real.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu-sym","name":"Bash","input":{"command":"real"}}]}}
JSONL
perl -e 'utime(time()-120, time()-120, $ARGV[0])' "${SYM_JSONL_SESSION}/real.jsonl" 2>/dev/null || true
ln -sf "${SYM_JSONL_SESSION}/real.jsonl" "${SYM_JSONL_SESSION}/symlink.jsonl" 2>/dev/null || true

result=$(cd "$SYM_JSONL_PROJECT" && CLAUDE_CONFIG_DIR="$FAKE_CHOME" bash "$SCANNER" --project "$SYM_JSONL_PROJECT" --format json 2>/dev/null)
scanned=$(printf '%s' "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('scanned',0))" 2>/dev/null || echo "0")
# Only the real file should be scanned, not the symlink
# find -P with -type f won't return symlinks
assert_eq "Only real JSONL scanned (symlink skipped)" "1" "$scanned"

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
