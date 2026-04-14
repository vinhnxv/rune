#!/usr/bin/env bats
# plugins/rune/scripts/tests/validate-assumption-gate.bats
# Bats tests for validate-assumption-gate.sh — Inner Flame Layer 0 assumption gate.
#
# Usage: bats plugins/rune/scripts/tests/validate-assumption-gate.bats
# Exit:  0 on all pass, non-zero on any failure.
# Covers: AC-5, AC-6, AC-7, AC-8, AC-9, AC-16

HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../validate-assumption-gate.sh"

has_jq() { command -v jq &>/dev/null; }
has_yq() { command -v yq &>/dev/null; }

# ── setup: create mock directories and fixture files ──
setup() {
  # Canonicalize temp dir to handle macOS /var -> /private/var symlink.
  # The hook script uses pwd -P when resolving CWD, so all paths in the
  # JSON input and fixtures must use the resolved form.
  TEST_DIR=$(mktemp -d)
  TEST_DIR=$(cd "$TEST_DIR" && pwd -P)

  # Mock project structure
  mkdir -p "$TEST_DIR/tmp/.rune-signals/rune-work-testteam"
  mkdir -p "$TEST_DIR/tmp/work/testteam/tasks"
  mkdir -p "$TEST_DIR/.rune"

  # Active rune-work state file.
  # owner_pid=$$ so the session ownership check passes: the hook's $PPID
  # matches the bats runner's $$ (both point to the same parent process).
  cat > "$TEST_DIR/tmp/.rune-work-testteam.json" <<EOF
{
  "status": "active",
  "owner_pid": "$$",
  "team_name": "rune-work-testteam"
}
EOF

  # inscription.json maps agent "rune-smith-1" → task "task-test".
  # The hook reads this to resolve which task the calling agent owns.
  cat > "$TEST_DIR/tmp/.rune-signals/rune-work-testteam/inscription.json" <<EOF
{
  "task_ownership": {
    "task-test": {
      "owner": "rune-smith-1",
      "files": ["some/file.sh"]
    }
  }
}
EOF

  # Talisman config: enable assumption gate with min 3 + block on missing.
  cat > "$TEST_DIR/.rune/talisman.yml" <<'EOF'
inner_flame:
  assumption_gate:
    enabled: true
    min_assumptions: 3
    block_on_missing: true
EOF
}

# ── teardown: clean up temp directory ──
teardown() {
  [[ -d "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# ── _hook_json: build standard PreToolUse Write hook input ──
# Simulates a Write call from subagent rune-smith-1 with the test CWD.
# The transcript_path must contain "/subagents/" so the hook identifies
# the caller as a subagent (team-lead is exempt from the gate).
_hook_json() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"some/file.sh"},"transcript_path":"/tmp/subagents/rune-smith-1/t.jsonl","cwd":"%s"}' \
    "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# AC-5: denies when assumptions missing
# ─────────────────────────────────────────────────────────────────────────────
@test "denies when assumptions missing" {
  has_jq || skip "jq not installed"
  has_yq || skip "yq not installed"

  # Task file with NO [ASSUMPTION- entries — gate should deny first write
  cat > "$TEST_DIR/tmp/work/testteam/tasks/task-test.md" <<'EOF'
## Task
Implement the feature. No assumptions declared here.

## Notes
Some implementation notes with no assumption entries.
EOF

  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 2 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# AC-6: allows when assumptions present (>= min_assumptions)
# ─────────────────────────────────────────────────────────────────────────────
@test "allows when assumptions present" {
  has_jq || skip "jq not installed"
  has_yq || skip "yq not installed"

  # Task file with exactly 3 [ASSUMPTION- entries (meets min_assumptions=3)
  cat > "$TEST_DIR/tmp/work/testteam/tasks/task-test.md" <<'EOF'
## Assumptions
- [ASSUMPTION-1]: The existing code follows single-responsibility principle
- [ASSUMPTION-2]: The interface contract is stable and will not change
- [ASSUMPTION-3]: The test environment matches the production environment

## Task
Implement the feature with documented assumptions.
EOF

  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# AC-7: fails forward on error — malformed input exits 0
# ─────────────────────────────────────────────────────────────────────────────
@test "fails forward on error" {
  has_jq || skip "jq not installed"

  # Malformed non-JSON input: jq parse fails → TOOL_NAME="" → fast-path exit 0.
  # The hook must never exit 2 on unexpected input (fail-open design).
  run bash "$HOOK_SCRIPT" <<< "this-is-not-valid-json{{{malformed"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# AC-8: fast-path exits for non-worker team
# ─────────────────────────────────────────────────────────────────────────────
@test "fast-path exits for non-worker" {
  has_jq || skip "jq not installed"

  # Remove work state file to simulate a non-worker context (e.g., rune-review-*).
  # With no .rune-work-*.json active, the hook exits 0 before reaching any check.
  rm -f "$TEST_DIR/tmp/.rune-work-testteam.json"

  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# AC-9: gates first write only — second call with marker exits 0
# ─────────────────────────────────────────────────────────────────────────────
@test "gates first write only" {
  has_jq || skip "jq not installed"
  has_yq || skip "yq not installed"

  # Task file WITHOUT assumptions (would normally be denied on first write)
  cat > "$TEST_DIR/tmp/work/testteam/tasks/task-test.md" <<'EOF'
## Task
No assumptions declared — would fail without the pass marker.
EOF

  # Pre-create the pass marker to simulate a prior successful gate pass
  touch "$TEST_DIR/tmp/.rune-signals/rune-work-testteam/.assumption-gate-passed-task-test"

  # Second+ write with marker present → exit 0 without re-checking assumptions
  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# AC-16: integration — declare-write-complete-persist cycle
# ─────────────────────────────────────────────────────────────────────────────
@test "integration: declare-write-complete-persist cycle" {
  has_jq || skip "jq not installed"
  has_yq || skip "yq not installed"

  local marker="$TEST_DIR/tmp/.rune-signals/rune-work-testteam/.assumption-gate-passed-task-test"

  # ── Phase 1: No assumptions → DENY (exit 2) ──
  cat > "$TEST_DIR/tmp/work/testteam/tasks/task-test.md" <<'EOF'
## Task
Implement the feature without any assumptions declared.
EOF

  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 2 ]

  # CONCERN-1: pass marker must NOT be written on the DENY path
  [ ! -f "$marker" ]

  # ── Phase 2: Declare assumptions → ALLOW (exit 0) ──
  cat > "$TEST_DIR/tmp/work/testteam/tasks/task-test.md" <<'EOF'
## Assumptions
- [ASSUMPTION-1]: The existing code follows single-responsibility principle
- [ASSUMPTION-2]: The interface contract is stable and will not change
- [ASSUMPTION-3]: The test environment matches the production environment

## Task
Implement the feature with documented assumptions.
EOF

  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 0 ]

  # Pass marker was written on the ALLOW path
  [ -f "$marker" ]

  # ── Phase 3: Remove assumptions — marker persists, subsequent writes pass ──
  cat > "$TEST_DIR/tmp/work/testteam/tasks/task-test.md" <<'EOF'
## Task
Assumptions removed — but pass marker persists from Phase 2.
EOF

  # Subsequent write: marker is present → exit 0 without re-checking
  run bash "$HOOK_SCRIPT" <<< "$(_hook_json)"
  [ "$status" -eq 0 ]
}
