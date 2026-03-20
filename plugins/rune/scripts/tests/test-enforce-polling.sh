#!/usr/bin/env bash
# test-enforce-polling.sh — Tests for scripts/enforce-polling.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-polling.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-polling.sh"

# ── Temp workspace ──
TMPWORK=$(mktemp -d)
trap 'rm -rf "$TMPWORK"' EXIT

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

# Helper: run the script with given JSON on stdin, capture stdout and exit code
run_hook() {
  local json="$1"
  local output
  local rc=0
  output=$(printf '%s' "$json" | bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
  printf '%s\n%d' "$output" "$rc"
}

get_output() {
  local result="$1"
  # Everything except the last line (which is the exit code)
  printf '%s' "$result" | sed '$d'
}

get_exit_code() {
  local result="$1"
  printf '%s' "$result" | tail -1
}

# ═══════════════════════════════════════════════════════════════
# 1. Non-matching tool names (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-matching Tool Names ===\n"

# 1a. Non-Bash tool should pass through
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "tool_input": {"command": "sleep 30 && echo done"}}')
assert_eq "Non-Bash tool exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Non-Bash tool produces no output" "" "$(get_output "$result")"

# 1b. Empty tool name
result=$(run_hook '{"tool_name": "", "cwd": "/tmp", "tool_input": {"command": "sleep 30 && echo done"}}')
assert_eq "Empty tool_name exits 0" "0" "$(get_exit_code "$result")"

# 1c. Missing tool_name field
result=$(run_hook '{"cwd": "/tmp", "tool_input": {"command": "sleep 30 && echo done"}}')
assert_eq "Missing tool_name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 2. Commands without sleep (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Sleep in Command ===\n"

# 2a. Normal command with no sleep
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "echo hello world"}}')
assert_eq "No-sleep command exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No-sleep command no output" "" "$(get_output "$result")"

# 2b. Command with ls
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "ls -la"}}')
assert_eq "ls command exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Small sleep values (below threshold) — with active workflow
# ═══════════════════════════════════════════════════════════════
printf "\n=== Small Sleep Values (Below Threshold) ===\n"

# Create a fake CWD with active review for threshold tests
THRESHCWD="$TMPWORK/thresh-project"
mkdir -p "$THRESHCWD/tmp"
cat > "$THRESHCWD/tmp/.rune-review-thresh.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF

# 3a. sleep 5 && echo (below 10s threshold) — should pass even with workflow
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$THRESHCWD\", \"tool_input\": {\"command\": \"sleep 5 && echo poll\"}}")
assert_eq "sleep 5+echo exits 0 (below threshold)" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "sleep 5+echo not blocked" "POLL-001" "$output"

# 3b. sleep 1 && echo (startup probe)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$THRESHCWD\", \"tool_input\": {\"command\": \"sleep 1 && echo check\"}}")
assert_eq "sleep 1+echo exits 0 (startup probe)" "0" "$(get_exit_code "$result")"

# 3c. sleep 9 && echo (just below threshold)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$THRESHCWD\", \"tool_input\": {\"command\": \"sleep 9 && echo check\"}}")
assert_eq "sleep 9+echo exits 0 (just below threshold)" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 4. Sleep+echo pattern WITHOUT active workflow
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep+Echo Without Active Workflow ===\n"

# 4a. sleep 30 && echo with no workflow state files
EMPTYCWD="$TMPWORK/empty-project"
mkdir -p "$EMPTYCWD"
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$EMPTYCWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll check\"}}")
assert_eq "sleep 30+echo without workflow exits 0" "0" "$(get_exit_code "$result")"
assert_eq "sleep 30+echo without workflow no deny" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 5. Sleep+echo pattern WITH active workflow (BLOCK expected)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep+Echo With Active Workflow (Arc) ===\n"

# Create a fake CWD with active arc checkpoint
# Use a dead PID (99999999) so ownership filter treats it as "our" orphaned state
# Omit config_dir so the config_dir filter is skipped (both empty = no mismatch)
ARCCWD="$TMPWORK/arc-project"
mkdir -p "$ARCCWD/.rune/arc/test-phase"
cat > "$ARCCWD/.rune/arc/test-phase/checkpoint.json" <<EOF
{"phase_status": "in_progress", "owner_pid": "99999999"}
EOF

# 5a. sleep 30 && echo with active arc workflow (owner_pid is dead PID = owned by us)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$ARCCWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll check\"}}")
assert_eq "sleep+echo with arc exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_contains "sleep+echo with arc produces deny JSON" "POLL-001" "$output"
assert_contains "deny JSON has permissionDecision deny" '"permissionDecision": "deny"' "$output"
assert_contains "deny JSON has hookEventName" '"hookEventName": "PreToolUse"' "$output"

# 5b. sleep 60 && echo with active arc workflow
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$ARCCWD\", \"tool_input\": {\"command\": \"sleep 60 && echo checking status\"}}")
output=$(get_output "$result")
assert_contains "sleep 60+echo blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 6. Sleep+echo with state file workflows
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep+Echo With State File Workflows ===\n"

# Create CWD with active review state file (dead PID, no config_dir = owned by us)
REVIEWCWD="$TMPWORK/review-project"
mkdir -p "$REVIEWCWD/tmp"
cat > "$REVIEWCWD/tmp/.rune-review-abc123.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF

# 6a. sleep 30 && echo with active review
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "sleep+echo with review blocked" "POLL-001" "$output"

# 6b. Also test with semicolon separator: sleep 30 ; echo
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 ; echo poll\"}}")
output=$(get_output "$result")
assert_contains "sleep+echo with semicolon blocked" "POLL-001" "$output"

# 6c. sleep 30 && printf variant
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 && printf poll\"}}")
output=$(get_output "$result")
assert_contains "sleep+printf blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 7. Commands that mention sleep but are not the anti-pattern
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Anti-Pattern Sleep Commands ===\n"

# 7a. Simple sleep without echo (ALLOWLISTED — bare sleep is fine)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30\"}}")
assert_eq "Bare sleep exits 0 (allowlisted)" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Bare sleep not blocked" "POLL-001" "$output"

# 7b. echo command that mentions sleep in string (no chain operator)
# With allowlist: "echo sleep is important" doesn't start with bare sleep, but does
# contain "sleep" → enters workflow check. No active workflow if we test without one.
# Test with active workflow — echo doesn't start with "sleep" so it's not bare sleep,
# BUT it does contain "sleep" in the string. The allowlist won't match it.
# However, the sleep number extraction won't find a sleep+number pattern either.
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"echo sleep is important\"}}")
assert_eq "echo mentioning sleep exits 0" "0" "$(get_exit_code "$result")"

# 7c. sleep with decimal value (bare, should be allowed)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30.5\"}}")
assert_eq "Bare sleep with decimal exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Bare sleep decimal not blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 8. Empty/missing command field
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty/Missing Command ===\n"

# 8a. Empty command
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": ""}}')
assert_eq "Empty command exits 0" "0" "$(get_exit_code "$result")"

# 8b. Missing command field
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {}}')
assert_eq "Missing command exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 9. Empty/missing CWD
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty/Missing CWD ===\n"

# 9a. Empty cwd
result=$(run_hook '{"tool_name": "Bash", "cwd": "", "tool_input": {"command": "sleep 30 && echo poll"}}')
assert_eq "Empty cwd exits 0" "0" "$(get_exit_code "$result")"

# 9b. Missing cwd
result=$(run_hook '{"tool_name": "Bash", "tool_input": {"command": "sleep 30 && echo poll"}}')
assert_eq "Missing cwd exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 10. Max sleep extraction (VEIL-009 preserved)
# ═══════════════════════════════════════════════════════════════
printf "\n=== VEIL-009: Max Sleep Extraction ===\n"

# 10a. Bypass attempt: small sleep first, big sleep second
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 1 && echo setup; sleep 60 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "Max sleep extracted — blocks on sleep 60" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 11. Multiline commands (newline = separator in bash)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multiline Commands ===\n"

# 11a. Multiline sleep+echo (newline between) — NOW BLOCKED by allowlist
# In bash, newline is a command separator. "sleep 30\necho poll" = "sleep 30; echo poll".
# The old regex missed this. The new allowlist catches it (sleep is not bare).
MULTI_CMD=$(printf 'sleep 30\necho poll check')
JSON=$(jq -n --arg cmd "$MULTI_CMD" --arg cwd "$REVIEWCWD" \
  '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "Multiline sleep+echo NOW blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 12. v4 nested checkpoint schema
# ═══════════════════════════════════════════════════════════════
printf "\n=== V4 Nested Checkpoint Schema ===\n"

# Create CWD with v4 nested schema
V4CWD="$TMPWORK/v4-project"
mkdir -p "$V4CWD/.rune/arc/test-v4"
cat > "$V4CWD/.rune/arc/test-v4/checkpoint.json" <<EOF
{"phases": {"forge": {"status": "in_progress"}}, "owner_pid": "99999999"}
EOF

result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$V4CWD\", \"tool_input\": {\"command\": \"sleep 30 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "v4 nested schema detected" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 13. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 13a. Completely empty stdin
result=$(printf '' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 13b. Invalid JSON
result=$(printf 'not json at all' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

# ═══════════════════════════════════════════════════════════════
# 14. ALLOWLIST bypass regression tests (previously undetected)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Allowlist Bypass Regression Tests ===\n"

# 14a. Variable expansion: N=30; sleep $N && echo poll
# Static analysis limitation: $N has no literal digits, so threshold extraction
# fails (SLEEP_NUM=0 < 10 → allowed). This is acceptable for the threat model —
# LLMs generate literal numbers, not variable expansions.
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"N=30; sleep \\\$N && echo poll\"}}")
assert_eq "Variable expansion: allowed (static analysis limitation)" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Variable expansion: no deny" "POLL-001" "$output"

# 14b. Command substitution: sleep $(echo 30) && echo poll
# Same static analysis limitation as 14a — no literal digits after sleep.
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep \\\$(echo 30) && echo poll\"}}")
assert_eq "Command substitution: allowed (static analysis limitation)" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Command substitution: no deny" "POLL-001" "$output"

# 14c. Full path bypass: /bin/sleep 30 && echo poll
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"/bin/sleep 30 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "Full path bypass NOW blocked" "POLL-001" "$output"

# 14d. env prefix bypass: env sleep 30 && echo poll
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"env sleep 30 && echo poll\"}}")
output=$(get_output "$result")
assert_contains "env prefix bypass NOW blocked" "POLL-001" "$output"

# 14e. Pipe chain: sleep 30 | tee log && echo poll
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 | tee /dev/null && echo poll\"}}")
output=$(get_output "$result")
assert_contains "Pipe chain bypass NOW blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 15. Allowlist: legitimate bare sleep patterns
# ═══════════════════════════════════════════════════════════════
printf "\n=== Allowlist: Legitimate Bare Sleep ===\n"

# 15a. Bare "sleep 30" (the correct monitoring pattern)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30\"}}")
assert_eq "Bare sleep 30 allowed" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Bare sleep 30 not blocked" "POLL-001" "$output"

# 15b. Bare "sleep 5" (below threshold, also bare — double-allowed)
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 5\"}}")
assert_eq "Bare sleep 5 allowed" "0" "$(get_exit_code "$result")"

# 15c. Bare sleep with leading/trailing whitespace
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"  sleep 30  \"}}")
assert_eq "Bare sleep with whitespace allowed" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_not_contains "Bare sleep whitespace not blocked" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 16. sleep || echo — error fallback, NOT anti-pattern
# ═══════════════════════════════════════════════════════════════
printf "\n=== Sleep || Echo (Error Fallback) ===\n"

# With allowlist approach: "sleep 30 || echo failed" is NOT bare sleep,
# so it would be blocked. But "||" is a legitimate error fallback, not anti-pattern.
# The threshold check looks for "sleep N" in the command — finds sleep 30 >= 10.
# This IS a behavior change from the old regex (which excluded ||).
# We accept this: during active workflows, prefer bare sleep. If you need error
# handling, do it at the tool-call level, not with shell || chains.
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$REVIEWCWD\", \"tool_input\": {\"command\": \"sleep 30 || echo failed\"}}")
output=$(get_output "$result")
assert_contains "sleep||echo blocked (not bare sleep)" "POLL-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 17. RUNE_STATE fallback (regression for the unbound variable bug)
# ═══════════════════════════════════════════════════════════════
printf "\n=== RUNE_STATE Fallback ===\n"

# 17a. Script should work even when resolve-session-identity.sh is missing
# (Previously caused unbound variable crash → silent enforcement bypass)
ISOLCWD="$TMPWORK/isolated-project"
mkdir -p "$ISOLCWD/.rune/arc/test"
cat > "$ISOLCWD/.rune/arc/test/checkpoint.json" <<EOF
{"phase_status": "in_progress", "owner_pid": "99999999"}
EOF
# Copy only enforce-polling.sh (no resolve-session-identity.sh, no lib/)
ISOLSCRIPT="$TMPWORK/isolated-enforce-polling.sh"
cp "$ENFORCE_SCRIPT" "$ISOLSCRIPT"
result_rc=0
result_out=$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"sleep 30 && echo poll"}}' "$ISOLCWD" \
  | bash "$ISOLSCRIPT" 2>/dev/null) || result_rc=$?
assert_eq "Missing deps: exits 0 (not crash)" "0" "$result_rc"
assert_contains "Missing deps: still enforces POLL-001" "POLL-001" "$result_out"

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
