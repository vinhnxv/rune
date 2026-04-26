#!/usr/bin/env bash
# test-stop-hook-common.sh — Tests for scripts/lib/stop-hook-common.sh
#
# Usage: bash plugins/rune/scripts/tests/test-stop-hook-common.sh
# Exit: 0 on all pass, 1 on any failure.
#
# NOTE: Many guard functions call `exit 0` on failure (fail-open pattern).
# We test these by running them in subshells and checking exit codes + side effects.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Mock environment ──
export CLAUDE_CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_SESSION_ID="test-session-$$"

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

# Helper: Run a function from the library in a subprocess.
# Guard functions use `exit 0` to bail out (fail-open), so we must use subshells.
# Args: $1 = bash code to run (after sourcing library), $2 = stdin content
_run_in_sub() {
  local code="$1"
  local stdin_content="${2:-}"
  printf '%s' "$stdin_content" | bash -c "
    export CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\"
    export CLAUDE_SESSION_ID=\"$CLAUDE_SESSION_ID\"
    source \"$LIB_DIR/stop-hook-common.sh\"
    $code
  " 2>/dev/null && return 0 || return $?
}

# Like _run_in_sub but captures stdout
_capture_sub() {
  local code="$1"
  local stdin_content="${2:-}"
  printf '%s' "$stdin_content" | bash -c "
    export CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\"
    export CLAUDE_SESSION_ID=\"$CLAUDE_SESSION_ID\"
    source \"$LIB_DIR/stop-hook-common.sh\"
    $code
  " 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# 1. parse_input — stdin guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== parse_input ===\n"

# 1a. Normal JSON input parsed
result=$(_capture_sub '
  parse_input
  echo "INPUT_LEN=${#INPUT}"
' '{"cwd":"/tmp","session_id":"abc"}')
assert_contains "Normal JSON: INPUT populated" "INPUT_LEN=" "$result"

# 1b. Empty stdin results in empty INPUT
result=$(_capture_sub '
  parse_input
  echo "INPUT=[$INPUT]"
' '')
assert_contains "Empty stdin: INPUT is empty" "INPUT=[]" "$result"

# 1c. Large input is capped (1MB)
# Generate 2MB of data (2*1048576 = 2097152 bytes)
large_input=$(python3 -c "print('x' * 2097152)")
result=$(_capture_sub '
  parse_input
  echo "INPUT_LEN=${#INPUT}"
' "$large_input")
assert_contains "Large input capped" "INPUT_LEN=1048576" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. resolve_cwd — CWD extraction and canonicalization
# ═══════════════════════════════════════════════════════════════
printf "\n=== resolve_cwd ===\n"

# 2a. Valid CWD extracted and canonicalized
mkdir -p "$TMP_DIR/test-cwd"
result=$(_capture_sub "
  INPUT='{\"cwd\":\"$TMP_DIR/test-cwd\"}'
  resolve_cwd
  echo \"CWD=\$CWD\"
")
assert_contains "Valid CWD extracted" "CWD=" "$result"
# Should be canonicalized (resolved symlinks, absolute path)
assert_contains "CWD is absolute" "/" "$result"

# 2b. Empty CWD -> exits 0 (bail)
result=$(_capture_sub '
  INPUT="{\"cwd\":\"\"}"
  resolve_cwd
  echo "CONTINUED"
')
assert_not_contains "Empty CWD bails out" "CONTINUED" "$result"

# 2c. Missing CWD field -> exits 0
result=$(_capture_sub '
  INPUT="{\"other_field\":\"value\"}"
  resolve_cwd
  echo "CONTINUED"
')
assert_not_contains "Missing CWD field bails out" "CONTINUED" "$result"

# 2d. Non-existent CWD -> exits 0
result=$(_capture_sub '
  INPUT="{\"cwd\":\"/nonexistent/path/surely\"}"
  resolve_cwd
  echo "CONTINUED"
')
assert_not_contains "Non-existent CWD bails out" "CONTINUED" "$result"

# 2e. Invalid JSON -> exits 0 (jq failure)
result=$(_capture_sub '
  INPUT="not json"
  resolve_cwd
  echo "CONTINUED"
')
assert_not_contains "Invalid JSON bails out" "CONTINUED" "$result"

# ═══════════════════════════════════════════════════════════════
# 3. check_state_file
# ═══════════════════════════════════════════════════════════════
printf "\n=== check_state_file ===\n"

# 3a. Existing file passes
state_file="$TMP_DIR/test-state.json"
printf '{"status":"active"}' > "$state_file"
result=$(_capture_sub "
  check_state_file \"$state_file\"
  echo 'CONTINUED'
")
assert_contains "Existing state file continues" "CONTINUED" "$result"

# 3b. Non-existent file -> exits 0
result=$(_capture_sub '
  check_state_file "/nonexistent/state.json"
  echo "CONTINUED"
')
assert_not_contains "Non-existent state file bails out" "CONTINUED" "$result"

# ═══════════════════════════════════════════════════════════════
# 4. reject_symlink
# ═══════════════════════════════════════════════════════════════
printf "\n=== reject_symlink ===\n"

# 4a. Regular file passes
regular_file="$TMP_DIR/regular.json"
printf '{}' > "$regular_file"
result=$(_capture_sub "
  reject_symlink \"$regular_file\"
  echo 'CONTINUED'
")
assert_contains "Regular file passes symlink check" "CONTINUED" "$result"

# 4b. Symlink -> exits 0 (and cleans up)
real_file="$TMP_DIR/real-state.json"
sym_file="$TMP_DIR/sym-state.json"
printf '{}' > "$real_file"
ln -sf "$real_file" "$sym_file"
result=$(_capture_sub "
  reject_symlink \"$sym_file\"
  echo 'CONTINUED'
")
assert_not_contains "Symlink bails out" "CONTINUED" "$result"

# 4c. Symlink was removed
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -L "$sym_file" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink removed by reject_symlink\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Symlink not removed\n"
fi
rm -f "$real_file" "$sym_file" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# 5. parse_frontmatter
# ═══════════════════════════════════════════════════════════════
printf "\n=== parse_frontmatter ===\n"

# 5a. Valid frontmatter parsed
fm_file="$TMP_DIR/frontmatter.md"
cat > "$fm_file" <<'ENDSTATE'
---
task_status: active
config_dir: /home/user/.claude
owner_pid: 12345
plan_file: plans/feature.md
---
Some body content here
ENDSTATE

result=$(_capture_sub "
  parse_frontmatter \"$fm_file\"
  echo \"FM=[\$FRONTMATTER]\"
")
assert_contains "Frontmatter parsed" "task_status: active" "$result"
assert_contains "Frontmatter contains config_dir" "config_dir:" "$result"

# 5b. Empty file -> exits 0 (corrupted, cleaned up)
empty_fm="$TMP_DIR/empty-fm.md"
printf '' > "$empty_fm"
result=$(_capture_sub "
  parse_frontmatter \"$empty_fm\"
  echo 'CONTINUED'
")
assert_not_contains "Empty file bails out" "CONTINUED" "$result"

# 5c. File without frontmatter delimiters -> exits 0
no_fm="$TMP_DIR/no-fm.md"
printf 'Just plain text without frontmatter' > "$no_fm"
result=$(_capture_sub "
  parse_frontmatter \"$no_fm\"
  echo 'CONTINUED'
")
assert_not_contains "No frontmatter bails out" "CONTINUED" "$result"

# ═══════════════════════════════════════════════════════════════
# 6. get_field
# ═══════════════════════════════════════════════════════════════
printf "\n=== get_field ===\n"

# 6a. Extract existing field
result=$(_capture_sub "
  FRONTMATTER='task_status: active
config_dir: /home/user/.claude
owner_pid: 12345'
  echo \"\$(get_field task_status)\"
")
assert_eq "get_field extracts task_status" "active" "$result"

# 6b. Extract owner_pid field
result=$(_capture_sub "
  FRONTMATTER='owner_pid: 12345
config_dir: /home/.claude'
  echo \"\$(get_field owner_pid)\"
")
assert_eq "get_field extracts owner_pid" "12345" "$result"

# 6c. Missing field returns empty
result=$(_capture_sub '
  FRONTMATTER="task_status: active"
  echo "RESULT=[$(get_field nonexistent)]"
')
assert_contains "Missing field returns empty" "RESULT=[]" "$result"

# 6d. Field with quoted value — quotes stripped
result=$(_capture_sub '
  FRONTMATTER="plan_file: \"plans/feature.md\""
  echo "$(get_field plan_file)"
')
assert_eq "Quoted field value has quotes stripped" "plans/feature.md" "$result"

# 6e. Uppercase field name accepted (PAT-013 FIX: widened to ^[a-zA-Z0-9_-]+$)
result=$(_capture_sub '
  FRONTMATTER="Status: active"
  get_field "Status" && echo "OK" || echo "REJECTED"
')
assert_contains "Uppercase field name accepted" "OK" "$result"

# 6f. Invalid field name with special chars rejected
result=$(_capture_sub '
  FRONTMATTER="field: value"
  get_field "field;rm" && echo "OK" || echo "REJECTED"
')
assert_contains "Special char field name rejected" "REJECTED" "$result"

# ═══════════════════════════════════════════════════════════════
# 7. validate_paths
# ═══════════════════════════════════════════════════════════════
printf "\n=== validate_paths ===\n"

# Source the library directly for validate_paths (it returns, doesn't exit)
source "$LIB_DIR/stop-hook-common.sh"

# 7a. Valid relative path
validate_paths "src/main.ts" && rc=0 || rc=1
assert_eq "Valid relative path accepted" "0" "$rc"

# 7b. Valid path with dots in filename
validate_paths "src/file.test.ts" && rc=0 || rc=1
assert_eq "Dots in filename accepted" "0" "$rc"

# 7c. Path with .. rejected
validate_paths "src/../evil.ts" && rc=0 || rc=1
assert_eq "Path traversal (..) rejected" "1" "$rc"

# 7d. Absolute path rejected
validate_paths "/etc/passwd" && rc=0 || rc=1
assert_eq "Absolute path rejected" "1" "$rc"

# 7e. Path with shell metachar rejected
validate_paths 'src/file$(rm).ts' && rc=0 || rc=1
assert_eq "Shell metachar ($) rejected" "1" "$rc"

# 7f. Path with spaces rejected
validate_paths "src/my file.ts" && rc=0 || rc=1
assert_eq "Path with space rejected" "1" "$rc"

# 7g. Path with semicolon rejected
validate_paths "src/file;rm.ts" && rc=0 || rc=1
assert_eq "Path with semicolon rejected" "1" "$rc"

# 7h. Multiple valid paths all accepted
validate_paths "src/a.ts" "src/b.ts" "lib/c.js" && rc=0 || rc=1
assert_eq "Multiple valid paths accepted" "0" "$rc"

# 7i. Multiple paths, one invalid = rejected
validate_paths "src/a.ts" "../evil.ts" "lib/c.js" && rc=0 || rc=1
assert_eq "Multiple paths with one bad = rejected" "1" "$rc"

# 7j. Path with backquote rejected
validate_paths 'src/`rm`.ts' && rc=0 || rc=1
assert_eq "Path with backtick rejected" "1" "$rc"

# 7k. Simple filename accepted
validate_paths "README.md" && rc=0 || rc=1
assert_eq "Simple filename accepted" "0" "$rc"

# 7l. Deep nested path accepted
validate_paths "a/b/c/d/e/f/g.ts" && rc=0 || rc=1
assert_eq "Deep nested path accepted" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 8. _iso_to_epoch
# ═══════════════════════════════════════════════════════════════
printf "\n=== _iso_to_epoch ===\n"

# 8a. Valid ISO timestamp converts
result=$(_iso_to_epoch "2026-01-15T12:30:45Z" 2>/dev/null || echo "FAIL")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$result" =~ ^[0-9]+$ ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Valid ISO timestamp converts to epoch: %s\n" "$result"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: ISO timestamp conversion failed: %s\n" "$result"
fi

# 8b. Timestamp with fractional seconds (JavaScript format)
result=$(_iso_to_epoch "2026-02-22T00:00:00.000Z" 2>/dev/null || echo "FAIL")
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$result" =~ ^[0-9]+$ ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Fractional seconds stripped and converts: %s\n" "$result"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Fractional seconds conversion failed: %s\n" "$result"
fi

# 8c. Invalid format rejected
_iso_to_epoch "not-a-timestamp" 2>/dev/null && rc=0 || rc=1
assert_eq "Invalid timestamp rejected" "1" "$rc"

# 8d. Empty string rejected
_iso_to_epoch "" 2>/dev/null && rc=0 || rc=1
assert_eq "Empty timestamp rejected" "1" "$rc"

# 8e. Injection attempt rejected (SEC-GUARD10)
_iso_to_epoch '2026-01-01T00:00:00Z; rm -rf /' 2>/dev/null && rc=0 || rc=1
assert_eq "Injection in timestamp rejected" "1" "$rc"

# 8f. Missing Z suffix rejected
_iso_to_epoch "2026-01-01T00:00:00" 2>/dev/null && rc=0 || rc=1
assert_eq "Missing Z suffix rejected" "1" "$rc"

# 8g. Extra characters rejected
_iso_to_epoch "2026-01-01T00:00:00Zextra" 2>/dev/null && rc=0 || rc=1
assert_eq "Extra characters after Z rejected" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 9. validate_session_ownership
# ═══════════════════════════════════════════════════════════════
printf "\n=== validate_session_ownership ===\n"

# 9a. Own session (matching config_dir and PID) -> continues
# NOTE: validate_session_ownership compares stored PID against $PPID in the subprocess.
# We create the state file inside the subshell so $PPID matches correctly.
own_state="$TMP_DIR/own-state.md"

result=$(bash -c "
  export CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\"
  export CLAUDE_SESSION_ID=\"$CLAUDE_SESSION_ID\"
  source \"$LIB_DIR/stop-hook-common.sh\"
  # Write state file with THIS subshell's \$PPID
  cat > \"$own_state\" <<EOF2
---
config_dir: \$(cd \"\$CLAUDE_CONFIG_DIR\" && pwd -P)
owner_pid: \$PPID
task_status: active
---
EOF2
  parse_frontmatter \"$own_state\"
  validate_session_ownership \"$own_state\" '' 'skip'
  echo 'CONTINUED'
" 2>/dev/null || true)
assert_contains "Own session ownership continues" "CONTINUED" "$result"

# 9b. Different config_dir -> exits 0 (skip)
diff_cfg_state="$TMP_DIR/diff-cfg.md"
cat > "$diff_cfg_state" <<'DIFFEOF'
---
config_dir: /different/config/path
owner_pid: 12345
task_status: active
---
DIFFEOF

result=$(_capture_sub "
  parse_frontmatter \"$diff_cfg_state\"
  validate_session_ownership \"$diff_cfg_state\" '' 'skip'
  echo 'CONTINUED'
")
assert_not_contains "Different config_dir bails out" "CONTINUED" "$result"

# 9c. Live different PID -> exits 0 (different session)
live_diff_state="$TMP_DIR/live-diff.md"
cat > "$live_diff_state" <<LIVEEOF
---
config_dir: $(cd "$CLAUDE_CONFIG_DIR" && pwd -P)
owner_pid: $$
task_status: active
---
LIVEEOF

result=$(_capture_sub "
  parse_frontmatter \"$live_diff_state\"
  validate_session_ownership \"$live_diff_state\" '' 'skip'
  echo 'CONTINUED'
")
assert_not_contains "Live different PID bails out" "CONTINUED" "$result"

# 9d. Dead PID -> exits 0 (orphan cleanup + skip)
dead_state="$TMP_DIR/dead-state.md"
cat > "$dead_state" <<DEADEOF
---
config_dir: $(cd "$CLAUDE_CONFIG_DIR" && pwd -P)
owner_pid: 99999
task_status: active
---
DEADEOF

result=$(_capture_sub "
  parse_frontmatter \"$dead_state\"
  validate_session_ownership \"$dead_state\" '' 'skip'
  echo 'CONTINUED'
")
assert_not_contains "Dead PID bails out" "CONTINUED" "$result"

# 9e. Dead PID with skip mode removes state file
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$dead_state" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Dead PID state file removed (orphan cleanup)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Dead PID state file still exists\n"
fi

# ═══════════════════════════════════════════════════════════════
# 10. _check_context_at_threshold — context level checking
# ═══════════════════════════════════════════════════════════════
printf "\n=== _check_context_at_threshold ===\n"

# 10a. No bridge file -> returns 1 (fail-open)
_check_context_at_threshold 25 && rc=0 || rc=1
assert_eq "No bridge file: returns 1 (fail-open)" "1" "$rc"

# 10b. Valid bridge file under threshold -> returns 0
session_id_for_bridge="test-ctx-$$"
bridge_file="${TMPDIR:-/tmp}/rune-ctx-${session_id_for_bridge}.json"
# Create bridge file owned by us with fresh timestamp
printf '{"remaining_percentage": 20}' > "$bridge_file"
INPUT="{\"session_id\":\"${session_id_for_bridge}\"}"
_check_context_at_threshold 25 && rc=0 || rc=1
assert_eq "Context 20% <= 25% threshold: returns 0" "0" "$rc"

# 10c. Valid bridge file over threshold -> returns 1
printf '{"remaining_percentage": 80}' > "$bridge_file"
_check_context_at_threshold 25 && rc=0 || rc=1
assert_eq "Context 80% > 25% threshold: returns 1" "1" "$rc"

# 10d. Boundary case: exactly at threshold -> returns 0
printf '{"remaining_percentage": 50}' > "$bridge_file"
_check_context_at_threshold 50 && rc=0 || rc=1
assert_eq "Context 50% == 50% threshold: returns 0" "0" "$rc"

# Clean up bridge file
rm -f "$bridge_file" 2>/dev/null || true

# 10e. Invalid session_id format -> returns 1
INPUT='{"session_id":"invalid session id!!"}'
_check_context_at_threshold 25 && rc=0 || rc=1
assert_eq "Invalid session_id format: returns 1" "1" "$rc"

# 10f. Invalid threshold -> returns 1
INPUT='{"session_id":"valid-id"}'
_check_context_at_threshold "not-a-number" && rc=0 || rc=1
assert_eq "Invalid threshold: returns 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 11. _check_context_critical / _check_context_compact_needed
# ═══════════════════════════════════════════════════════════════
printf "\n=== _check_context_critical / _check_context_compact_needed ===\n"

# 11a. _check_context_critical delegates to threshold 25
# Without a bridge file, returns 1
_check_context_critical && rc=0 || rc=1
assert_eq "context_critical without bridge: returns 1" "1" "$rc"

# 11b. _check_context_compact_needed delegates to threshold 50
_check_context_compact_needed && rc=0 || rc=1
assert_eq "context_compact_needed without bridge: returns 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════
# 12. _read_arc_result_signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== _read_arc_result_signal ===\n"

# Setup CWD
ARC_CWD="$TMP_DIR/arc-project"
mkdir -p "$ARC_CWD/tmp"
CWD="$ARC_CWD"

# 12a. No signal file -> returns 1
_read_arc_result_signal && rc=0 || rc=1
assert_eq "No signal file: returns 1" "1" "$rc"

# 12b. Valid completed signal -> returns 0
jq -n \
  --argjson pid "$PPID" \
  --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{schema_version:1, owner_pid:($pid|tostring), config_dir:$cfg, status:"completed", pr_url:"https://github.com/user/repo/pull/42", arc_id:"arc-123"}' \
  > "$ARC_CWD/tmp/arc-result-current.json"

_read_arc_result_signal && rc=0 || rc=1
assert_eq "Valid completed signal: returns 0" "0" "$rc"
assert_eq "Signal status=completed" "completed" "$ARC_SIGNAL_STATUS"
assert_eq "Signal PR URL" "https://github.com/user/repo/pull/42" "$ARC_SIGNAL_PR_URL"
assert_eq "Signal arc_id" "arc-123" "$ARC_SIGNAL_ARC_ID"

# 12c. Partial status accepted
jq -n \
  --argjson pid "$PPID" \
  --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{schema_version:1, owner_pid:($pid|tostring), config_dir:$cfg, status:"partial", pr_url:"none", arc_id:"arc-456"}' \
  > "$ARC_CWD/tmp/arc-result-current.json"

_read_arc_result_signal && rc=0 || rc=1
assert_eq "Partial status accepted" "0" "$rc"
assert_eq "Signal status=partial" "partial" "$ARC_SIGNAL_STATUS"

# 12d. Invalid status rejected (SEC-005 allowlist)
jq -n \
  --argjson pid "$PPID" \
  --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{schema_version:1, owner_pid:($pid|tostring), config_dir:$cfg, status:"failed", pr_url:"none", arc_id:"arc-789"}' \
  > "$ARC_CWD/tmp/arc-result-current.json"

_read_arc_result_signal && rc=0 || rc=1
assert_eq "Invalid status 'failed' rejected" "1" "$rc"

# 12e. Wrong PID rejected
jq -n \
  --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{schema_version:1, owner_pid:"99999", config_dir:$cfg, status:"completed", pr_url:"none"}' \
  > "$ARC_CWD/tmp/arc-result-current.json"

_read_arc_result_signal && rc=0 || rc=1
assert_eq "Wrong PID rejected" "1" "$rc"

# 12f. Wrong schema_version rejected
jq -n \
  --argjson pid "$PPID" \
  --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{schema_version:2, owner_pid:($pid|tostring), config_dir:$cfg, status:"completed"}' \
  > "$ARC_CWD/tmp/arc-result-current.json"

_read_arc_result_signal && rc=0 || rc=1
assert_eq "Wrong schema_version rejected" "1" "$rc"

# 12g. pr_url "null" normalized to "none"
jq -n \
  --argjson pid "$PPID" \
  --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{schema_version:1, owner_pid:($pid|tostring), config_dir:$cfg, status:"completed", pr_url:"null"}' \
  > "$ARC_CWD/tmp/arc-result-current.json"

_read_arc_result_signal && rc=0 || rc=1
assert_eq "pr_url null->none normalization" "0" "$rc"
assert_eq "pr_url normalized to none" "none" "$ARC_SIGNAL_PR_URL"

# 12h. Symlink signal file rejected
ln -sf "$ARC_CWD/tmp/arc-result-current.json" "$ARC_CWD/tmp/arc-result-symlink.json"
# The function checks for the specific path, so create a symlink AT the expected path
rm -f "$ARC_CWD/tmp/arc-result-current.json"
jq -n '{schema_version:1}' > "$ARC_CWD/tmp/arc-result-real.json"
ln -sf "$ARC_CWD/tmp/arc-result-real.json" "$ARC_CWD/tmp/arc-result-current.json"
_read_arc_result_signal && rc=0 || rc=1
assert_eq "Symlink signal file rejected" "1" "$rc"

# Clean up
rm -rf "$ARC_CWD"

# ═══════════════════════════════════════════════════════════════
# 13. INTEG-016 (SESSION-ID-001): banner-confusion guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== INTEG-016: state session_id vs RUNE_SESSION_ID/hook-input ===\n"

# Source library again in a clean subshell so platform helpers are loaded
INTEG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$INTEG_DIR"' EXIT

# 13a. Match — state session_id == RUNE_SESSION_ID → no INTEG-016 warning
result=$(bash -c '
  set -uo pipefail
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  cat > "'"$INTEG_DIR"'/state-good.md" <<EOF
---
active: true
iteration: 0
max_iterations: 66
checkpoint_path: .rune/arc/arc-12345/checkpoint.json
plan_file: plans/dummy.md
branch: main
arc_flags:
config_dir: '"$CLAUDE_CONFIG_DIR"'
owner_pid: 99999
session_id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
---
EOF
  mkdir -p "'"$INTEG_DIR"'/.rune/arc/arc-12345"
  echo "{\"id\":\"arc-12345\"}" > "'"$INTEG_DIR"'/.rune/arc/arc-12345/checkpoint.json"
  cd "'"$INTEG_DIR"'"
  parse_frontmatter "'"$INTEG_DIR"'/state-good.md"
  RUNE_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
  RUNE_TRACE=1 \
  validate_state_file_integrity "'"$INTEG_DIR"'/state-good.md" "'"$INTEG_DIR"'" 2>&1 | grep "INTEG-016" || echo "no-warn"
' 2>&1)
assert_eq "INTEG-016: matching session_id emits no warning" "no-warn" "$result"

# 13b. Mismatch — state session_id != RUNE_SESSION_ID → INTEG-016 warning
result=$(bash -c '
  set -uo pipefail
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  cat > "'"$INTEG_DIR"'/state-bad.md" <<EOF
---
active: true
iteration: 0
max_iterations: 66
checkpoint_path: .rune/arc/arc-12345/checkpoint.json
plan_file: plans/dummy.md
branch: main
arc_flags:
config_dir: '"$CLAUDE_CONFIG_DIR"'
owner_pid: 99999
session_id: 53edc6ab-c096-44bd-be56-3750a0526911
---
EOF
  cd "'"$INTEG_DIR"'"
  parse_frontmatter "'"$INTEG_DIR"'/state-bad.md"
  RUNE_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
  RUNE_TRACE=1 \
  validate_state_file_integrity "'"$INTEG_DIR"'/state-bad.md" "'"$INTEG_DIR"'" 2>&1
' 2>&1)
assert_contains "INTEG-016: mismatched session_id emits warning" "INTEG-016" "$result"
assert_contains "INTEG-016: warning mentions banner-confusion" "banner-confusion" "$result"

# 13c. Unknown sentinel — state session_id == "unknown" → no INTEG-016 (fresh-write case)
result=$(bash -c '
  set -uo pipefail
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  cat > "'"$INTEG_DIR"'/state-unknown.md" <<EOF
---
active: true
iteration: 0
max_iterations: 66
checkpoint_path: .rune/arc/arc-12345/checkpoint.json
plan_file: plans/dummy.md
branch: main
arc_flags:
config_dir: '"$CLAUDE_CONFIG_DIR"'
owner_pid: 99999
session_id: unknown
---
EOF
  cd "'"$INTEG_DIR"'"
  parse_frontmatter "'"$INTEG_DIR"'/state-unknown.md"
  RUNE_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
  RUNE_TRACE=1 \
  validate_state_file_integrity "'"$INTEG_DIR"'/state-unknown.md" "'"$INTEG_DIR"'" 2>&1 | grep "INTEG-016" || echo "no-warn"
' 2>&1)
assert_eq "INTEG-016: unknown session_id is exempt (claim-on-first-touch path)" "no-warn" "$result"

# ═══════════════════════════════════════════════════════════════
# 14. _arc_write_ownership_rejection_diag — diagnostic file
# ═══════════════════════════════════════════════════════════════
printf "\n=== _arc_write_ownership_rejection_diag ===\n"

DIAG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$INTEG_DIR" "$DIAG_DIR"' EXIT
mkdir -p "$DIAG_DIR/.rune"
touch "$DIAG_DIR/.rune/arc-phase-loop.local.md"

# 14a. Writes diagnostic line on call
bash -c '
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  _arc_write_ownership_rejection_diag "'"$DIAG_DIR"'/.rune/arc-phase-loop.local.md" \
    "session_id_mismatch" "stored=53edc6ab… hook=5fc44a6c… stored_pid=66847"
'
[[ -f "$DIAG_DIR/.rune/arc-ownership-rejection.log" ]]
assert_eq "diag log file created" "0" "$?"

content=$(cat "$DIAG_DIR/.rune/arc-ownership-rejection.log")
assert_contains "diag line includes reason code" "session_id_mismatch" "$content"
assert_contains "diag line includes detail" "stored=53edc6ab" "$content"
assert_contains "diag line includes GUARD identifier" "GUARD 5.7" "$content"

# 14b. Append-only — second call adds a new line
bash -c '
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  _arc_write_ownership_rejection_diag "'"$DIAG_DIR"'/.rune/arc-phase-loop.local.md" \
    "config_dir_mismatch" "stored=/wrong/path"
'
line_count=$(wc -l < "$DIAG_DIR/.rune/arc-ownership-rejection.log" | tr -d ' ')
assert_eq "diag log appends (2 lines after 2 writes)" "2" "$line_count"

# 14c. Control-char sanitization
bash -c '
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  # Embed a literal newline + tab in the detail string (should be stripped)
  _arc_write_ownership_rejection_diag "'"$DIAG_DIR"'/.rune/arc-phase-loop.local.md" \
    "test_sanitize" "$(printf "line1\nline2\there")"
'
# Should still have exactly 3 lines (one new line, no embedded newline leaked through)
line_count=$(wc -l < "$DIAG_DIR/.rune/arc-ownership-rejection.log" | tr -d ' ')
assert_eq "diag log sanitizes control chars (still 3 lines)" "3" "$line_count"

# 14d. Size cap at 16 KB
# Write a large file, then trigger truncation. Use single-command write (no pipeline)
# to avoid SIGPIPE → pipefail killing the test script under `set -euo pipefail`.
head -c 20000 /dev/zero > "$DIAG_DIR/.rune/arc-ownership-rejection.log"
bash -c '
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  _arc_write_ownership_rejection_diag "'"$DIAG_DIR"'/.rune/arc-phase-loop.local.md" \
    "size_test" "post-truncation"
'
final_size=$(wc -c < "$DIAG_DIR/.rune/arc-ownership-rejection.log" | tr -d ' ')
[[ "$final_size" -lt 16384 ]]
assert_eq "diag log truncated when over 16 KB cap" "0" "$?"

# 14e. Non-existent state-file dir — silently no-ops
result=$(bash -c '
  source "'"$LIB_DIR"'/platform.sh"
  source "'"$LIB_DIR"'/stop-hook-common.sh"
  _arc_write_ownership_rejection_diag "/nonexistent/path/state.md" "test" "detail"
  echo "ok"
' 2>&1)
assert_contains "diag log silently no-ops on bad path" "ok" "$result"

# Clean up
rm -rf "$DIAG_DIR" "$INTEG_DIR"

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
