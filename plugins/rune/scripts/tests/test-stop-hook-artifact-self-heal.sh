#!/usr/bin/env bash
# test-stop-hook-artifact-self-heal.sh (plan AC-4 evidence)
#
# SCOPE: Artifact-mtime self-heal — the v2.59.0 feature that closes the
# QA-notification race. Complements test-stop-hook-self-heal.sh which covers
# the separate v2.54.0 state-file self-heal path.
#
# Scenario (from plan AC-4 test spec):
#   1. Checkpoint has phases.work_qa.status = "in_progress", started_at set.
#   2. tmp/arc/{id}/qa/work-verdict.json is placed with mtime > started_at.
#   3. Fire _arc_phase_self_heal directly (unit test mode — bypasses full
#      stop hook to avoid Claude-Code harness dependency).
#   4. Expected: returned checkpoint JSON has phases.work_qa.status = "completed"
#      and phases.work_qa.self_healed = true.
#
# Additionally validates:
#   - Stale artifact (mtime <= started_at) is NOT healed (ARC-QA-001 discipline).
#   - Invalid JSON verdict is NOT healed (Risk #1 mitigation).
#   - Non-QA in_progress phase is NOT healed in v1 (scope guard).
#   - fail-forward: missing jq or bad arc_id returns original content unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR=$(mktemp -d "$TEST_HOME/rune-ac4-XXXXXX")
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

ARC_ID="arc-9988776655"
ARC_DIR="${TEST_DIR}/tmp/arc/${ARC_ID}"
CKPT_PATH="${TEST_DIR}/.rune/arc/${ARC_ID}/checkpoint.json"
mkdir -p "${ARC_DIR}/qa" "${ARC_DIR}/.done" "$(dirname "$CKPT_PATH")"

# Source the helper under test
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/scripts/lib/platform.sh"
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/scripts/lib/arc-phase-self-heal.sh"

_pass=0
_fail=0
_check() {
  local _name="$1" _got="$2" _want="$3"
  if [[ "$_got" == "$_want" ]]; then
    printf 'PASS: %s\n' "$_name"
    _pass=$((_pass + 1))
  else
    printf 'FAIL: %s — got=%q want=%q\n' "$_name" "$_got" "$_want" >&2
    _fail=$((_fail + 1))
  fi
}

# ── Scenario 1: happy path heal ────────────────────────────────────────────
# work_qa in_progress, verdict JSON placed AFTER started_at → heal
STARTED=$(date -u -r $(($(date +%s) - 120)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
cat > "$CKPT_PATH" <<EOF
{
  "id": "${ARC_ID}",
  "phases": {
    "work": {"status": "completed", "completed_at": "${STARTED}"},
    "work_qa": {"status": "in_progress", "started_at": "${STARTED}"}
  }
}
EOF
cat > "${ARC_DIR}/qa/work-verdict.json" <<'EOF'
{"phase":"work","verdict":"FAIL","scores":{"overall_score":0}}
EOF
# Force mtime to "now" (later than started_at two minutes ago)
touch "${ARC_DIR}/qa/work-verdict.json"

CKPT_JSON=$(cat "$CKPT_PATH")
OUT=$(_arc_phase_self_heal "$CKPT_JSON" "$ARC_DIR" "$ARC_ID" "$CKPT_PATH")

_got_status=$(printf '%s' "$OUT" | jq -r '.phases.work_qa.status')
_got_healed=$(printf '%s' "$OUT" | jq -r '.phases.work_qa.self_healed')
_got_artifact=$(printf '%s' "$OUT" | jq -r '.phases.work_qa.artifact')
_got_log_len=$(printf '%s' "$OUT" | jq -r '.self_heal_log | length')
_check "S1 status flipped to completed" "$_got_status" "completed"
_check "S1 self_healed marker set" "$_got_healed" "true"
_check "S1 artifact path recorded" "$_got_artifact" "${ARC_DIR}/qa/work-verdict.json"
_check "S1 self_heal_log appended" "$_got_log_len" "1"

# Disk was also rewritten atomically
_disk_status=$(jq -r '.phases.work_qa.status' "$CKPT_PATH")
_check "S1 disk checkpoint updated" "$_disk_status" "completed"

# ── Scenario 2: stale artifact (mtime <= started_at) → NOT healed ──────────
rm -f "${ARC_DIR}/qa/work-verdict.json"
# Create verdict THEN update started_at to "now" so verdict mtime is in past
cat > "${ARC_DIR}/qa/work-verdict.json" <<'EOF'
{"phase":"work","verdict":"FAIL"}
EOF
# VEIL-008 FIX (review c1a9714-018c647e): sleep 2 (not 1) to tolerate scheduler
# jitter on loaded CI. stat() resolution is 1 second — with sleep 1, a jittery
# scheduler could land verdict write and started_at stamp in the same second,
# making the _artifact_mtime == _started_epoch case. After VEIL-003 fix changed
# `<=` to `<`, that equality would INCORRECTLY heal instead of refusing stale.
# sleep 2 guarantees >=1 full second of mtime separation.
sleep 2
STARTED_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$CKPT_PATH" <<EOF
{
  "id": "${ARC_ID}",
  "phases": {
    "work_qa": {"status": "in_progress", "started_at": "${STARTED_NOW}"}
  }
}
EOF

CKPT_JSON=$(cat "$CKPT_PATH")
OUT=$(_arc_phase_self_heal "$CKPT_JSON" "$ARC_DIR" "$ARC_ID" "$CKPT_PATH")
_got_status=$(printf '%s' "$OUT" | jq -r '.phases.work_qa.status')
_check "S2 stale artifact NOT healed" "$_got_status" "in_progress"

# ── Scenario 3: invalid JSON verdict → NOT healed ──────────────────────────
STARTED=$(date -u -r $(($(date +%s) - 120)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
cat > "$CKPT_PATH" <<EOF
{
  "id": "${ARC_ID}",
  "phases": {
    "work_qa": {"status": "in_progress", "started_at": "${STARTED}"}
  }
}
EOF
# Write malformed JSON (truncated mid-write simulation)
printf '{"phase":"work","verdict":"FA' > "${ARC_DIR}/qa/work-verdict.json"
touch "${ARC_DIR}/qa/work-verdict.json"

CKPT_JSON=$(cat "$CKPT_PATH")
OUT=$(_arc_phase_self_heal "$CKPT_JSON" "$ARC_DIR" "$ARC_ID" "$CKPT_PATH")
_got_status=$(printf '%s' "$OUT" | jq -r '.phases.work_qa.status')
_check "S3 invalid JSON NOT healed" "$_got_status" "in_progress"

# ── Scenario 4: non-QA in_progress phase → NOT healed (scope guard) ────────
rm -f "${ARC_DIR}/qa/work-verdict.json"
cat > "$CKPT_PATH" <<EOF
{
  "id": "${ARC_ID}",
  "phases": {
    "work": {"status": "in_progress", "started_at": "${STARTED}"}
  }
}
EOF

CKPT_JSON=$(cat "$CKPT_PATH")
OUT=$(_arc_phase_self_heal "$CKPT_JSON" "$ARC_DIR" "$ARC_ID" "$CKPT_PATH")
_got_status=$(printf '%s' "$OUT" | jq -r '.phases.work.status')
_check "S4 non-QA phase NOT healed in v1" "$_got_status" "in_progress"

# ── Scenario 5: bad arc_id → original returned unchanged (SEC fail-forward) ─
CKPT_JSON='{"phases":{"work_qa":{"status":"in_progress"}}}'
OUT=$(_arc_phase_self_heal "$CKPT_JSON" "$ARC_DIR" "bad;rm -rf /" "$CKPT_PATH")
_check "S5 bad arc_id returns unchanged" "$OUT" "$CKPT_JSON"

# ── Summary ────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$_pass" "$_fail"
[[ "$_fail" -eq 0 ]]
