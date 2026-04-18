#!/usr/bin/env bash
# test-doctor-subcommand.sh — exercises rune-arc-init-state.sh doctor across all 4 loop kinds.
#
# Self-contained: builds an isolated sandbox under $TMPDIR, constructs a fake
# .rune/arc/{id}/checkpoint.json, and optionally a .rune/arc-phase-loop.local.md
# to cover HEALTHY, MISSING, ORPHAN, and FOREIGN ownership cases.
#
# Exit 0 on success, 1 on any failed assertion.

set -u
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
RUNE_ARC_INIT="${SCRIPT_DIR}/../rune-arc-init-state.sh"

_fail() {
  echo "FAIL: $*" >&2
  exit 1
}

_pass() {
  echo "PASS: $*"
}

# ──────────────────────────────────────────────
# Sandbox setup
# ──────────────────────────────────────────────
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/rune-doctor-test.XXXXXX")
trap 'rm -rf "$SANDBOX" 2>/dev/null' EXIT

export CWD="$SANDBOX"
export CLAUDE_CONFIG_DIR="${SANDBOX}/claude-config"
export RUNE_SESSION_ID="test-session-abc123"
mkdir -p "$CLAUDE_CONFIG_DIR"

# ──────────────────────────────────────────────
# Case A: clean slate — no checkpoint, no state file → exit 0
# ──────────────────────────────────────────────
out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor 2>&1)
rc=$?
[ "$rc" = "0" ] || _fail "Case A: expected exit 0 on clean slate, got $rc. Output: $out"
echo "$out" | grep -q "Overall: 0 issues" || _fail "Case A: expected 0 issues summary"
echo "$out" | grep -q "Loop kind: phase" || _fail "Case A: expected phase section"
echo "$out" | grep -q "Loop kind: batch" || _fail "Case A: expected batch section"
echo "$out" | grep -q "Loop kind: hierarchy" || _fail "Case A: expected hierarchy section"
echo "$out" | grep -q "Loop kind: issues" || _fail "Case A: expected issues section"
_pass "Case A: clean slate exits 0 with all 4 kinds reported"

# ──────────────────────────────────────────────
# Case B: checkpoint present, state file MISSING → exit 1, recommended fix
# ──────────────────────────────────────────────
ARC_ID="arc-1700000000000"
mkdir -p "${SANDBOX}/.rune/arc/${ARC_ID}"
cat > "${SANDBOX}/.rune/arc/${ARC_ID}/checkpoint.json" <<JSON
{
  "id": "${ARC_ID}",
  "session_id": "${RUNE_SESSION_ID}",
  "owner_pid": "$$",
  "plan_file": "plans/test.md",
  "phases": {
    "forge":   { "status": "completed" },
    "plan_review": { "status": "pending" },
    "work":    { "status": "pending" }
  }
}
JSON

out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor 2>&1)
rc=$?
[ "$rc" = "1" ] || _fail "Case B: expected exit 1 when state file missing, got $rc. Output: $out"
echo "$out" | grep -q "MISSING" || _fail "Case B: expected MISSING marker in output"
echo "$out" | grep -q "Recommended fix:" || _fail "Case B: expected 'Recommended fix:' line"
echo "$out" | grep -q "2 pending phases" || _fail "Case B: expected pending phase count"
_pass "Case B: checkpoint+missing-state-file exits 1 with fix hint"

# ──────────────────────────────────────────────
# Case C: both present, session_id matches → exit 0 OWNED
# ──────────────────────────────────────────────
cat > "${SANDBOX}/.rune/arc-phase-loop.local.md" <<EOF
---
active: true
iteration: 0
max_iterations: 66
checkpoint_path: .rune/arc/${ARC_ID}/checkpoint.json
plan_file: "plans/test.md"
branch: "main"
arc_flags: ""
config_dir: ${CLAUDE_CONFIG_DIR}
owner_pid: $$
session_id: ${RUNE_SESSION_ID}
compact_pending: false
user_cancelled: false
cancel_reason: null
cancelled_at: null
stop_reason: null
group_mode: null
group_paused: null
---
EOF

out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor 2>&1)
rc=$?
[ "$rc" = "0" ] || _fail "Case C: expected exit 0 when both present and owned, got $rc. Output: $out"
echo "$out" | grep -q "OWNED (session_id match)" || _fail "Case C: expected OWNED ownership"
echo "$out" | grep -q "Overall: 0 issues" || _fail "Case C: expected 0 issues"
_pass "Case C: OWNED state file exits 0"

# ──────────────────────────────────────────────
# Case D: state file with DEAD owner_pid → ORPHAN, exit 1
# ──────────────────────────────────────────────
# Pick an unlikely-to-be-alive PID (max + 1)
DEAD_PID=999999
sed "s/^owner_pid: .*/owner_pid: ${DEAD_PID}/" "${SANDBOX}/.rune/arc-phase-loop.local.md" \
  > "${SANDBOX}/.rune/arc-phase-loop.local.md.tmp"
mv "${SANDBOX}/.rune/arc-phase-loop.local.md.tmp" "${SANDBOX}/.rune/arc-phase-loop.local.md"
# Also alter session_id so the primary match doesn't short-circuit ownership resolution
sed "s/^session_id: .*/session_id: foreign-session/" "${SANDBOX}/.rune/arc-phase-loop.local.md" \
  > "${SANDBOX}/.rune/arc-phase-loop.local.md.tmp"
mv "${SANDBOX}/.rune/arc-phase-loop.local.md.tmp" "${SANDBOX}/.rune/arc-phase-loop.local.md"

out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor 2>&1)
rc=$?
[ "$rc" = "1" ] || _fail "Case D: expected exit 1 with orphan state file, got $rc. Output: $out"
echo "$out" | grep -q "ORPHAN" || _fail "Case D: expected ORPHAN ownership"
_pass "Case D: ORPHAN state file exits 1"

# ──────────────────────────────────────────────
# Case E: --kind phase restricts output to one kind
# ──────────────────────────────────────────────
out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor --kind phase 2>&1)
echo "$out" | grep -q "Loop kind: phase" || _fail "Case E: expected phase section"
if echo "$out" | grep -q "Loop kind: batch"; then
  _fail "Case E: expected --kind phase to SKIP batch section"
fi
_pass "Case E: --kind phase restricts to single kind"

# ──────────────────────────────────────────────
# Case F: --json produces parseable JSON
# ──────────────────────────────────────────────
out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor --json 2>&1)
if command -v jq >/dev/null 2>&1; then
  echo "$out" | jq . >/dev/null 2>&1 || _fail "Case F: --json output failed jq parse. Output: $out"
  kinds_count=$(echo "$out" | jq -r '.kinds | keys | length' 2>/dev/null)
  [ "$kinds_count" = "4" ] || _fail "Case F: expected 4 kinds in JSON, got $kinds_count"
  _pass "Case F: --json produces valid 4-kind JSON structure"
else
  # Degraded: no jq → at least verify presence of key structural markers
  echo "$out" | grep -q '"kinds"' || _fail "Case F (no-jq): missing kinds key"
  echo "$out" | grep -q '"total_issues"' || _fail "Case F (no-jq): missing total_issues"
  _pass "Case F: --json emits expected structural markers (jq unavailable)"
fi

# ──────────────────────────────────────────────
# Case G: invalid --kind → exit 2 with FATAL
# ──────────────────────────────────────────────
out=$(cd "$SANDBOX" && bash "$RUNE_ARC_INIT" doctor --kind bogus 2>&1) || rc=$?
[ "${rc:-0}" = "2" ] || _fail "Case G: expected exit 2 for invalid --kind, got ${rc:-0}"
echo "$out" | grep -q "FATAL: invalid kind" || _fail "Case G: expected FATAL invalid kind message"
_pass "Case G: invalid --kind exits 2 with FATAL"

echo
echo "ALL TESTS PASSED"
exit 0
