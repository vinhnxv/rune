#!/usr/bin/env bash
# test-observability-script.sh — exercises arc-state-health.sh summary + canary-gate modes.
#
# Self-contained: builds a synthetic 100-entry integrity log in $TMPDIR and
# verifies JSON shape, counts, and --canary-gate PASS/FAIL verdicts under
# threshold-boundary inputs.
#
# Exit 0 on success, 1 on any failed assertion.

set -u
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
ARC_HEALTH="${SCRIPT_DIR}/../observability/arc-state-health.sh"

_fail() { echo "FAIL: $*" >&2; exit 1; }
_pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/rune-arc-health-test.XXXXXX")
trap 'rm -rf "$SANDBOX" 2>/dev/null' EXIT

_make_log() {
  # $1 dest path, $2 verified count, $3 recovered count, $4 hydrated count,
  # $5 corrupted count, $6 layer2_mismatch count, $7 deletion_deferred count,
  # $8 deletion_spurious count, $9 dry_run frac (0..100)
  #
  # Note: BSD `seq 1 0` prints "1\n0" instead of producing no output. Guard all
  # loops with explicit count checks to keep the synthetic log deterministic.
  local dest="$1" v="$2" r="$3" h="$4" c="$5" l="$6" dd="$7" ds="$8" df="$9"
  local now ts i
  now=$(date +%s)
  : > "$dest"
  # Emit within the last 6 days — all within the 7-day window.
  if [ "$v" -gt 0 ]; then
    for i in $(seq 1 "$v"); do
      ts=$(date -u -r "$((now - i*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - i*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"verified","cause":"idempotent_skip","latency_ms":%d,"dry_run":%s}\n' \
        "$ts" "$((10 + i % 40))" "$([ $((i % 100)) -lt $df ] && echo true || echo false)" >> "$dest"
    done
  fi
  if [ "$r" -gt 0 ]; then
    for i in $(seq 1 "$r"); do
      ts=$(date -u -r "$((now - (v+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - (v+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"recovered_post_checkpoint_write","cause":"hook_recovery","latency_ms":%d,"dry_run":false}\n' \
        "$ts" "$((20 + i))" >> "$dest"
    done
  fi
  if [ "$h" -gt 0 ]; then
    for i in $(seq 1 "$h"); do
      ts=$(date -u -r "$((now - (v+r+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - (v+r+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"hydrated_at_session_start","cause":"session_resume","latency_ms":%d,"dry_run":false}\n' \
        "$ts" "$((15 + i))" >> "$dest"
    done
  fi
  if [ "$c" -gt 0 ]; then
    for i in $(seq 1 "$c"); do
      ts=$(date -u -r "$((now - (v+r+h+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - (v+r+h+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"corrupted_write","cause":"layer2_mismatch","latency_ms":5,"dry_run":false}\n' "$ts" >> "$dest"
    done
  fi
  if [ "$l" -gt 0 ]; then
    for i in $(seq 1 "$l"); do
      ts=$(date -u -r "$((now - (v+r+h+c+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - (v+r+h+c+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"verified","cause":"layer2_mismatch","latency_ms":3,"dry_run":false}\n' "$ts" >> "$dest"
    done
  fi
  if [ "$dd" -gt 0 ]; then
    for i in $(seq 1 "$dd"); do
      ts=$(date -u -r "$((now - (v+r+h+c+l+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - (v+r+h+c+l+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"deletion_deferred","cause":"lock_held","latency_ms":8,"dry_run":false}\n' "$ts" >> "$dest"
    done
  fi
  if [ "$ds" -gt 0 ]; then
    for i in $(seq 1 "$ds"); do
      ts=$(date -u -r "$((now - (v+r+h+c+l+dd+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "@$((now - (v+r+h+c+l+dd+i)*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      printf '{"ts":"%s","action":"deletion_spurious","cause":"false_positive","latency_ms":4,"dry_run":false}\n' "$ts" >> "$dest"
    done
  fi
}

# ──────────────────────────────────────────────
# Case A: missing log → zero-count JSON, exit 0
# ──────────────────────────────────────────────
out=$(bash "$ARC_HEALTH" --log "${SANDBOX}/nonexistent.jsonl" 2>&1)
rc=$?
[ "$rc" = "0" ] || _fail "Case A: expected exit 0 on missing log, got $rc"
echo "$out" | grep -q '"verified_count": 0' || _fail "Case A: expected verified_count=0 in zero summary"
echo "$out" | grep -q '"total_entries": 0' || _fail "Case A: expected total_entries=0"
_pass "Case A: missing log produces zero-count summary"

# ──────────────────────────────────────────────
# Case B: synthetic 100-entry log, summary mode → valid JSON with expected counts
# ──────────────────────────────────────────────
# 80 verified + 8 recovered + 5 hydrated + 0 corrupted + 0 mismatch + 4 deferred + 1 spurious + 2% dry_run = 98 entries
LOG_B="${SANDBOX}/log-b.jsonl"
_make_log "$LOG_B" 80 8 5 0 0 4 1 2
entry_count=$(wc -l < "$LOG_B" | tr -d ' ')
out=$(bash "$ARC_HEALTH" --log "$LOG_B" 2>&1)
rc=$?
[ "$rc" = "0" ] || _fail "Case B: expected exit 0, got $rc. Output: $out"
if command -v jq >/dev/null 2>&1; then
  echo "$out" | jq . >/dev/null 2>&1 || _fail "Case B: summary not valid JSON"
  v=$(echo "$out" | jq -r '.verified_count')
  r=$(echo "$out" | jq -r '.recovered_count')
  h=$(echo "$out" | jq -r '.hydrated_count')
  [ "$v" = "80" ] || _fail "Case B: verified_count=$v expected 80"
  [ "$r" = "8" ] || _fail "Case B: recovered_count=$r expected 8"
  [ "$h" = "5" ] || _fail "Case B: hydrated_count=$h expected 5"
  ratio=$(echo "$out" | jq -r '.deletion_deferred_vs_spurious_ratio')
  case "$ratio" in 4*|4.00) _pass "Case B: ratio ≈ 4.0 as expected ($ratio)" ;; *) _fail "Case B: expected ratio ~4.0, got $ratio" ;; esac
  te=$(echo "$out" | jq -r '.total_entries')
  [ "$te" = "$entry_count" ] || _fail "Case B: total_entries=$te expected $entry_count"
else
  echo "$out" | grep -q '"verified_count": 80' || _fail "Case B (no-jq): missing verified_count=80"
  echo "$out" | grep -q '"recovered_count": 8' || _fail "Case B (no-jq): missing recovered_count=8"
  _pass "Case B: no-jq fallback shape check passed"
fi

# ──────────────────────────────────────────────
# Case C: --canary-gate PASS — all thresholds met, corrupted=0, mismatches=0, ratio > 1.0
# ──────────────────────────────────────────────
LOG_C="${SANDBOX}/log-c.jsonl"
_make_log "$LOG_C" 520 10 5 0 0 6 1 0
out=$(bash "$ARC_HEALTH" --log "$LOG_C" --canary-gate 2>&1)
rc=$?
[ "$rc" = "0" ] || _fail "Case C: expected exit 0 (PASS), got $rc. Output: $out"
echo "$out" | grep -q '"gate_status": "PASS"' || _fail "Case C: expected gate_status=PASS. Got: $out"
_pass "Case C: canary-gate PASS with all thresholds met"

# ──────────────────────────────────────────────
# Case D: --canary-gate FAIL — verified below threshold
# ──────────────────────────────────────────────
LOG_D="${SANDBOX}/log-d.jsonl"
_make_log "$LOG_D" 400 10 5 0 0 6 1 0
out=$(bash "$ARC_HEALTH" --log "$LOG_D" --canary-gate 2>&1)
rc=$?
[ "$rc" = "1" ] || _fail "Case D: expected exit 1 (FAIL), got $rc"
echo "$out" | grep -q '"gate_status": "FAIL"' || _fail "Case D: expected FAIL"
echo "$out" | grep -q "verified_count=400 < 500" || _fail "Case D: expected verified reason"
_pass "Case D: canary-gate FAIL when verified_count below threshold"

# ──────────────────────────────────────────────
# Case E: --canary-gate FAIL — corrupted > 0
# ──────────────────────────────────────────────
LOG_E="${SANDBOX}/log-e.jsonl"
_make_log "$LOG_E" 520 10 5 1 0 6 1 0
out=$(bash "$ARC_HEALTH" --log "$LOG_E" --canary-gate 2>&1)
rc=$?
[ "$rc" = "1" ] || _fail "Case E: expected exit 1 (FAIL), got $rc"
echo "$out" | grep -q "corrupted_write_count=1 > 0" || _fail "Case E: expected corrupted reason"
_pass "Case E: canary-gate FAIL when corrupted_write_count > 0"

# ──────────────────────────────────────────────
# Case F: missing log + --canary-gate → FAIL, exit 1
# ──────────────────────────────────────────────
out=$(bash "$ARC_HEALTH" --log "${SANDBOX}/missing.jsonl" --canary-gate 2>&1)
rc=$?
[ "$rc" = "1" ] || _fail "Case F: expected exit 1 when log missing + canary-gate, got $rc"
echo "$out" | grep -q '"gate_status": "FAIL"' || _fail "Case F: expected FAIL"
_pass "Case F: canary-gate FAIL on missing log"

# ──────────────────────────────────────────────
# Case G: invalid --window-days → exit 2
# ──────────────────────────────────────────────
out=$(bash "$ARC_HEALTH" --log "$LOG_B" --window-days bogus 2>&1) || rc=$?
[ "${rc:-0}" = "2" ] || _fail "Case G: expected exit 2 for invalid window-days, got ${rc:-0}"
_pass "Case G: invalid --window-days exits 2"

echo
echo "ALL TESTS PASSED"
exit 0
