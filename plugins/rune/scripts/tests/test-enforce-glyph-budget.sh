#!/usr/bin/env bash
# test-enforce-glyph-budget.sh — Tests for scripts/enforce-glyph-budget.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-glyph-budget.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-glyph-budget.sh"

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

# Helper: run the script with given JSON on stdin
run_hook() {
  local json="$1"
  local budget="${2:-}"
  local output
  local rc=0
  if [[ -n "$budget" ]]; then
    output=$(printf '%s' "$json" | RUNE_GLYPH_BUDGET="$budget" bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
  else
    output=$(printf '%s' "$json" | bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
  fi
  printf '%s\n%d' "$output" "$rc"
}

get_output() {
  local result="$1"
  printf '%s' "$result" | sed '$d'
}

get_exit_code() {
  local result="$1"
  printf '%s' "$result" | tail -1
}

# Generate a string with N words
generate_words() {
  local count="$1"
  local words=""
  for (( i=0; i<count; i++ )); do
    words="${words}word "
  done
  printf '%s' "$words"
}

# Create a project with an active rune workflow
# PATT-001: Include full session-isolation triple (config_dir, owner_pid, session_id)
# to match Rune Session Isolation Rule schema.
ACTIVECWD="$TMPWORK/active-project"
mkdir -p "$ACTIVECWD/tmp"
cat > "$ACTIVECWD/tmp/.rune-review-abc123.json" <<EOF
{"status":"active","config_dir":"${CLAUDE_CONFIG_DIR:-$HOME/.claude}","owner_pid":"$PPID","session_id":"${CLAUDE_SESSION_ID:-test-session}"}
EOF

# Create a project WITHOUT an active rune workflow
NOCWD="$TMPWORK/no-workflow"
mkdir -p "$NOCWD/tmp"

# ═══════════════════════════════════════════════════════════════
# 1. No active workflow — skip
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Active Workflow ===\n"

# 1a. Long message without active workflow — should pass silently
BIG_CONTENT=$(generate_words 500)
JSON=$(jq -n --arg cwd "$NOCWD" --arg content "$BIG_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
assert_eq "No workflow exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No workflow no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 2. Under budget — no advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Under Budget ===\n"

# 2a. 100 words (under default 300)
SMALL_CONTENT=$(generate_words 100)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$SMALL_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
assert_eq "Under budget exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Under budget no output" "" "$(get_output "$result")"

# 2b. Exactly 300 words (at budget, not over)
EXACT_CONTENT=$(generate_words 300)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$EXACT_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
assert_eq "At budget exits 0" "0" "$(get_exit_code "$result")"
assert_eq "At budget no advisory" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Over budget — advisory emitted
# ═══════════════════════════════════════════════════════════════
printf "\n=== Over Budget ===\n"

# 3a. 400 words (over default 300)
OVER_CONTENT=$(generate_words 400)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$OVER_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
assert_eq "Over budget exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_contains "Over budget has violation" "GLYPH-BUDGET-VIOLATION" "$output"
assert_contains "Over budget has hookEventName" '"hookEventName": "PostToolUse"' "$output"
assert_contains "Over budget mentions word count" "400 words" "$output"
assert_contains "Over budget mentions budget" "budget: 300" "$output"

# 3b. 301 words (just over)
BARELY_OVER=$(generate_words 301)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$BARELY_OVER" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "301 words triggers advisory" "GLYPH-BUDGET-VIOLATION" "$output"

# ═══════════════════════════════════════════════════════════════
# 4. Custom budget via RUNE_GLYPH_BUDGET
# ═══════════════════════════════════════════════════════════════
printf "\n=== Custom Budget ===\n"

# 4a. Custom budget of 50 — 100 words should trigger
CONTENT_100=$(generate_words 100)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$CONTENT_100" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON" "50")
output=$(get_output "$result")
assert_contains "Custom budget 50 triggers at 100 words" "GLYPH-BUDGET-VIOLATION" "$output"
assert_contains "Custom budget shows budget: 50" "budget: 50" "$output"

# 4b. Custom budget of 500 — 400 words should not trigger
CONTENT_400=$(generate_words 400)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$CONTENT_400" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON" "500")
assert_eq "Custom budget 500 no trigger at 400" "0" "$(get_exit_code "$result")"
assert_eq "Custom budget 500 no output" "" "$(get_output "$result")"

# 4c. Invalid budget falls back to 300
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$OVER_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON" "not-a-number")
output=$(get_output "$result")
assert_contains "Invalid budget falls back to 300" "budget: 300" "$output"

# ═══════════════════════════════════════════════════════════════
# 5. Empty/missing content
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty/Missing Content ===\n"

# 5a. Empty content
JSON=$(jq -n --arg cwd "$ACTIVECWD" '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: ""}}')
result=$(run_hook "$JSON")
assert_eq "Empty content exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Empty content no output" "" "$(get_output "$result")"

# 5b. Missing content field
JSON=$(jq -n --arg cwd "$ACTIVECWD" '{tool_name: "SendMessage", cwd: $cwd, tool_input: {}}')
result=$(run_hook "$JSON")
assert_eq "Missing content exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Missing content no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 6. CWD handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 6a. Empty CWD
result=$(run_hook '{"tool_name": "SendMessage", "cwd": "", "tool_input": {"content": "hello"}}')
assert_eq "Empty CWD exits 0" "0" "$(get_exit_code "$result")"

# 6b. Missing CWD
result=$(run_hook '{"tool_name": "SendMessage", "tool_input": {"content": "hello"}}')
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code "$result")"

# 6c. Invalid CWD
result=$(run_hook '{"tool_name": "SendMessage", "cwd": "/nonexistent/path", "tool_input": {"content": "hello"}}')
assert_eq "Invalid CWD exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 7. Multiple workflow types
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multiple Workflow Types ===\n"

# 7a. Work workflow
WORKCWD="$TMPWORK/work-project"
mkdir -p "$WORKCWD/tmp"
cat > "$WORKCWD/tmp/.rune-work-xyz.json" <<'EOF'
{"status": "active"}
EOF
JSON=$(jq -n --arg cwd "$WORKCWD" --arg content "$OVER_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "Work workflow triggers advisory" "GLYPH-BUDGET-VIOLATION" "$output"

# 7b. Forge workflow
FORGECWD="$TMPWORK/forge-project"
mkdir -p "$FORGECWD/tmp"
cat > "$FORGECWD/tmp/.rune-forge-abc.json" <<'EOF'
{"status": "active"}
EOF
JSON=$(jq -n --arg cwd "$FORGECWD" --arg content "$OVER_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
output=$(get_output "$result")
assert_contains "Forge workflow triggers advisory" "GLYPH-BUDGET-VIOLATION" "$output"

# ═══════════════════════════════════════════════════════════════
# 8. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 8a. Empty stdin
result=$(printf '' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 8b. Invalid JSON
result=$(printf 'not json' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

# 8c. Non-blocking: PostToolUse hook always exits 0
# Even when over budget, exit code should be 0 (advisory only)
JSON=$(jq -n --arg cwd "$ACTIVECWD" --arg content "$OVER_CONTENT" \
  '{tool_name: "SendMessage", cwd: $cwd, tool_input: {content: $content}}')
result=$(run_hook "$JSON")
assert_eq "Always exits 0 (advisory)" "0" "$(get_exit_code "$result")"

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
