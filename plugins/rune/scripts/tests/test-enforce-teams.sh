#!/usr/bin/env bash
# test-enforce-teams.sh — Tests for scripts/enforce-teams.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-teams.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-teams.sh"

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
  local output
  local rc=0
  output=$(printf '%s' "$json" | bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
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

# ═══════════════════════════════════════════════════════════════
# 1. Non-matching tool names (fast path)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-matching Tool Names ===\n"

# 1a. Bash tool should pass through
result=$(run_hook '{"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "echo hi"}}')
assert_eq "Bash tool exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Bash tool no output" "" "$(get_output "$result")"

# 1b. Write tool should pass through
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "tool_input": {}}')
assert_eq "Write tool exits 0" "0" "$(get_exit_code "$result")"

# 1c. TeamCreate tool should pass through
result=$(run_hook '{"tool_name": "TeamCreate", "cwd": "/tmp", "tool_input": {}}')
assert_eq "TeamCreate tool exits 0" "0" "$(get_exit_code "$result")"

# 1d. Empty tool name
result=$(run_hook '{"tool_name": "", "cwd": "/tmp", "tool_input": {}}')
assert_eq "Empty tool_name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 2. Agent/Task WITHOUT active workflow (ALLOW)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Agent/Task Without Active Workflow ===\n"

NOCWD="$TMPWORK/no-workflow"
mkdir -p "$NOCWD"

# 2a. Agent tool without active workflow
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$NOCWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
assert_eq "Agent without workflow exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Agent without workflow no output" "" "$(get_output "$result")"

# 2b. Task tool without active workflow (legacy name)
result=$(run_hook "{\"tool_name\": \"Task\", \"cwd\": \"$NOCWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
assert_eq "Task without workflow exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Task without workflow no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Agent WITH team_name during active workflow (ALLOW)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Agent With team_name During Active Workflow ===\n"

# Create a CWD with active review workflow (dead PID, no config_dir)
ACTIVECWD="$TMPWORK/active-project"
mkdir -p "$ACTIVECWD/tmp"
cat > "$ACTIVECWD/tmp/.rune-review-abc123.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF

# 3a. Agent with team_name should be allowed
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"team_name\": \"rune-review-abc123\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
assert_eq "Agent with team_name exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Agent with team_name no deny" "" "$(get_output "$result")"

# 3b. Task with team_name should be allowed
result=$(run_hook "{\"tool_name\": \"Task\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"team_name\": \"rune-review-abc123\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
assert_eq "Task with team_name exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 4. Agent WITHOUT team_name during active workflow (DENY)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Agent Without team_name During Active Workflow (DENY) ===\n"

# 4a. Agent without team_name — should be denied
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
assert_eq "Bare Agent exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_contains "Bare Agent denied" '"permissionDecision": "deny"' "$output"
assert_contains "Bare Agent has ATE-1" "ATE-1" "$output"
assert_contains "Bare Agent has hookEventName" '"hookEventName": "PreToolUse"' "$output"

# 4b. Task without team_name — should be denied
result=$(run_hook "{\"tool_name\": \"Task\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Bare Task denied" '"permissionDecision": "deny"' "$output"
assert_contains "Bare Task has ATE-1" "ATE-1" "$output"

# 4c. Agent with empty team_name — should be denied
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"team_name\": \"\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Empty team_name denied" '"permissionDecision": "deny"' "$output"

# ═══════════════════════════════════════════════════════════════
# 5. Explore/Plan exemption
# ═══════════════════════════════════════════════════════════════
printf "\n=== Explore/Plan Exemption ===\n"

# 5a. Explore subagent without team_name — exempted
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"subagent_type\": \"Explore\", \"prompt\": \"Search codebase\"}}")
assert_eq "Explore exempted exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Explore exempted no output" "" "$(get_output "$result")"

# 5b. Plan subagent without team_name — exempted
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"subagent_type\": \"Plan\", \"prompt\": \"Research\"}}")
assert_eq "Plan exempted exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Plan exempted no output" "" "$(get_output "$result")"

# 5c. general-purpose without team_name — NOT exempted
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "general-purpose not exempted" "ATE-1" "$output"

# ═══════════════════════════════════════════════════════════════
# 6. Arc checkpoint detection
# ═══════════════════════════════════════════════════════════════
printf "\n=== Arc Checkpoint Detection ===\n"

# Create CWD with active arc checkpoint
ARCCWD="$TMPWORK/arc-project"
mkdir -p "$ARCCWD/.rune/arc/test-phase"
cat > "$ARCCWD/.rune/arc/test-phase/checkpoint.json" <<EOF
{"phase_status": "in_progress", "owner_pid": "99999999"}
EOF

# 6a. Bare Agent during arc workflow
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ARCCWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Arc checkpoint triggers deny" "ATE-1" "$output"

# 6b. V4 nested schema (phases.*.status)
V4CWD="$TMPWORK/v4-project"
mkdir -p "$V4CWD/.rune/arc/test-v4"
cat > "$V4CWD/.rune/arc/test-v4/checkpoint.json" <<EOF
{"phases": {"forge": {"status": "in_progress"}}, "owner_pid": "99999999"}
EOF
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$V4CWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "V4 schema triggers deny" "ATE-1" "$output"

# ═══════════════════════════════════════════════════════════════
# 7. Multiple state file types
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multiple State File Types ===\n"

# 7a. Audit state file
AUDITCWD="$TMPWORK/audit-project"
mkdir -p "$AUDITCWD/tmp"
cat > "$AUDITCWD/tmp/.rune-audit-xyz789.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$AUDITCWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Audit state triggers deny" "ATE-1" "$output"

# 7b. Work state file
WORKCWD="$TMPWORK/work-project"
mkdir -p "$WORKCWD/tmp"
cat > "$WORKCWD/tmp/.rune-work-def456.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$WORKCWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Work state triggers deny" "ATE-1" "$output"

# 7c. Forge state file
FORGECWD="$TMPWORK/forge-project"
mkdir -p "$FORGECWD/tmp"
cat > "$FORGECWD/tmp/.rune-forge-ghi012.json" <<EOF
{"status": "active", "owner_pid": "99999999"}
EOF
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$FORGECWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Forge state triggers deny" "ATE-1" "$output"

# 7d. Completed state file should NOT trigger deny
DONECWD="$TMPWORK/done-project"
mkdir -p "$DONECWD/tmp"
cat > "$DONECWD/tmp/.rune-review-done.json" <<EOF
{"status": "completed", "owner_pid": "99999999"}
EOF
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$DONECWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
assert_eq "Completed state exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Completed state no deny" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 8. CWD handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 8a. Empty CWD
result=$(run_hook '{"tool_name": "Agent", "cwd": "", "tool_input": {"subagent_type": "general-purpose"}}')
assert_eq "Empty CWD exits 0" "0" "$(get_exit_code "$result")"

# 8b. Missing CWD
result=$(run_hook '{"tool_name": "Agent", "tool_input": {"subagent_type": "general-purpose"}}')
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code "$result")"

# 8c. Invalid CWD
result=$(run_hook '{"tool_name": "Agent", "cwd": "/nonexistent/does/not/exist", "tool_input": {"subagent_type": "general-purpose"}}')
assert_eq "Invalid CWD exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 8b. Signal 4 — Known agent name matching (last resort detection)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Signal 4: Known Agent Name Matching ===\n"

# Create a CWD with NO state files, NO inscription, NO signal dirs
# Signal 4 should still detect known Rune agents by name alone
SIGNAL4_CWD=$(mktemp -d)

# 8b-1. Audit Ash: rot-seeker (previously missing from KNOWN_RUNE_AGENTS)
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"rot-seeker\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: rot-seeker detected" "ATE-1" "$output"

# 8b-2. Audit Ash: strand-tracer
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"strand-tracer\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: strand-tracer detected" "ATE-1" "$output"

# 8b-3. Audit Ash: decree-auditor
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"decree-auditor\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: decree-auditor detected" "ATE-1" "$output"

# 8b-4. Audit Ash: fringe-watcher
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"fringe-watcher\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: fringe-watcher detected" "ATE-1" "$output"

# 8b-5. Specialist: python-reviewer (from specialist-prompts/)
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"python-reviewer\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: python-reviewer detected" "ATE-1" "$output"

# 8b-6. Specialist: typescript-reviewer
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"typescript-reviewer\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: typescript-reviewer detected" "ATE-1" "$output"

# 8b-7. Previously-present agent: ward-sentinel (sanity check)
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"ward-sentinel\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: ward-sentinel detected" "ATE-1" "$output"

# 8b-8. Numbered suffix: rot-seeker-2 (Agent Teams appends instance numbers)
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"rot-seeker-2\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: rot-seeker-2 (numbered) detected" "ATE-1" "$output"

# 8b-9. Unknown agent name should NOT be detected by Signal 4
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"random-unknown-agent\"}}")
exit_code=$(get_exit_code "$result")
output=$(get_output "$result")
assert_eq "Signal 4: unknown agent passes through" "0" "$exit_code"
assert_not_contains "Signal 4: unknown agent not blocked" "ATE-1" "$output"

# 8b-10. New agents: breach-hunter, goldmask-coordinator
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"breach-hunter\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: breach-hunter detected" "ATE-1" "$output"

result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$SIGNAL4_CWD\", \"tool_input\": {\"name\": \"goldmask-coordinator\"}}")
output=$(get_output "$result")
assert_contains "Signal 4: goldmask-coordinator detected" "ATE-1" "$output"

rm -rf "$SIGNAL4_CWD"

# ═══════════════════════════════════════════════════════════════
# 9. Non-Rune agent exemption (hook scope isolation)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Rune Agent Exemption ===\n"

# 9a. Non-Rune named agent allowed during active Rune workflow
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"name\": \"my-custom-plugin-agent\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
exit_code=$(get_exit_code "$result")
output=$(get_output "$result")
assert_eq "Non-Rune agent exits 0" "0" "$exit_code"
assert_not_contains "Non-Rune agent not blocked" "ATE-1" "$output"

# 9b. Known Rune agent still blocked during active Rune workflow
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"name\": \"ward-sentinel\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Review code\"}}")
output=$(get_output "$result")
assert_contains "Rune agent still blocked" "ATE-1" "$output"

# 9c. Unnamed bare Agent call still blocked (could be Rune)
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"subagent_type\": \"general-purpose\", \"prompt\": \"Do work\"}}")
output=$(get_output "$result")
assert_contains "Unnamed agent still blocked" "ATE-1" "$output"

# 9d. Non-Rune agent with numbered suffix also allowed
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"name\": \"external-code-checker-2\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Check code\"}}")
exit_code=$(get_exit_code "$result")
output=$(get_output "$result")
assert_eq "Non-Rune numbered agent exits 0" "0" "$exit_code"
assert_not_contains "Non-Rune numbered agent not blocked" "ATE-1" "$output"

# 9e. Rune agent with named suffix still blocked (e.g., rot-seeker-deep)
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\", \"tool_input\": {\"name\": \"rot-seeker-deep\", \"subagent_type\": \"general-purpose\", \"prompt\": \"Deep review\"}}")
output=$(get_output "$result")
assert_contains "Rune agent with named suffix still blocked" "ATE-1" "$output"

# ═══════════════════════════════════════════════════════════════
# 10. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 10a. Empty stdin
result=$(printf '' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 10b. Invalid JSON
result=$(printf 'garbage' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

# 10c. Missing tool_input
result=$(run_hook "{\"tool_name\": \"Agent\", \"cwd\": \"$ACTIVECWD\"}")
output=$(get_output "$result")
# Missing tool_input means HAS_TEAM_NAME will be "no" → deny
assert_contains "Missing tool_input denied" "ATE-1" "$output"

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
