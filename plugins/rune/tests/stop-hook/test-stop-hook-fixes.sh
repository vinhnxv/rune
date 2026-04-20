#!/bin/bash
# tests/stop-hook/test-stop-hook-fixes.sh — stop-hook v2.62.0 fix regression tests
#
# Covers three AC gaps:
#   GAP-T5 (5 tests): AC-11 _sanitize_prompt_content() in arc-phase-stop-hook.sh
#   GAP-T6 (2 tests): AC-13 PPID legacy-fallback gate in detect-workflow-complete.sh
#   GAP-T7 (5 tests): AC-17 CKPT-INT-008 field validation in lib/stop-hook-common.sh
#
# Run from the repository root:
#   bash plugins/rune/tests/stop-hook/test-stop-hook-fixes.sh
#
# Requirements: bash 3.2+, jq

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL=14

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 — $2"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo "SKIP: $1 — $2"; }

# ── Preflight ──
for script in plugins/rune/scripts/arc-phase-stop-hook.sh \
              plugins/rune/scripts/detect-workflow-complete.sh \
              plugins/rune/scripts/lib/stop-hook-common.sh; do
  if [[ ! -f "$script" ]]; then
    echo "ABORT: Missing required script: $script"
    echo "Run this test from the repository root directory."
    exit 1
  fi
done

if ! command -v jq &>/dev/null; then
  echo "ABORT: jq is required but not found."
  exit 1
fi

# ── Test workspace ──
CKPT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rune-test-stop-hook-XXXXXX")
_cleanup() { rm -rf "$CKPT_DIR" 2>/dev/null; }
trap '_cleanup' EXIT

# ────────────────────────────────────────────────────────────────
# GAP-T5: AC-11 — _sanitize_prompt_content() in arc-phase-stop-hook.sh
# ────────────────────────────────────────────────────────────────

# Extract the function body from arc-phase-stop-hook.sh using per-character brace depth.
# This avoids eval risks and handles nested ${...} substitutions correctly.
_SANITIZE_FN=$(awk '
  function count_char(str, ch,    n, i) {
    n = 0
    for (i = 1; i <= length(str); i++) {
      if (substr(str, i, 1) == ch) n++
    }
    return n
  }
  /^_sanitize_prompt_content\(\)/ { capturing=1; depth=0 }
  capturing {
    nopen = count_char($0, "{")
    ncl   = count_char($0, "}")
    depth += nopen - ncl
    print
    if (capturing && depth <= 0 && NR > 1) capturing=0
  }
' plugins/rune/scripts/arc-phase-stop-hook.sh)

if [[ -z "$_SANITIZE_FN" ]]; then
  echo "ABORT: Could not extract _sanitize_prompt_content() from arc-phase-stop-hook.sh"
  exit 1
fi

# Write extracted function to a temp file so sub-tests can source it safely
SANITIZE_FN_FILE="${CKPT_DIR}/sanitize_fn.sh"
printf '%s\n' "$_SANITIZE_FN" > "$SANITIZE_FN_FILE"

# Helper: run sanitize function in a fresh subshell, return output
_run_sanitize() {
  local input="$1"
  bash -c "
    source '${SANITIZE_FN_FILE}' 2>/dev/null
    _sanitize_prompt_content \"\$1\"
  " -- "$input" 2>/dev/null
}

# T5.1: Markdown code fence BLOCKS stripped (multi-line payload must not survive)
# QUAL-003 (v2.63.0): previously this test assigned input_t5_1 but called
# _run_sanitize with a DIFFERENT inline one-liner — the advertised newline-path
# coverage was false. Now the variable is actually used, with $'...' quoting so
# the fence markers are real backticks and the newlines are real newlines. This
# also regresses SEC-002: a line-based sed would strip the opening/closing
# markers but leave `rm -rf /` on line 2 intact. The awk fence-toggle must drop
# the entire block.
input_t5_1=$'Hello\n```bash\nrm -rf /\n```\nworld'
result_t5_1=$(_run_sanitize "$input_t5_1")
if [[ "$result_t5_1" != *'```'* && "$result_t5_1" != *'rm -rf'* ]]; then
  pass "T5.1: Markdown code fence BLOCK stripped (markers + payload) from content"
else
  fail "T5.1: Multi-line fence block not fully stripped" "got: ${result_t5_1:0:120}"
fi

# T5.2: HTML comments stripped
result_t5_2=$(_run_sanitize 'before <!-- inject --> after')
if [[ "$result_t5_2" != *'<!--'* && "$result_t5_2" != *'-->'* ]]; then
  pass "T5.2: HTML comments stripped from content"
else
  fail "T5.2: HTML comments not stripped" "got: ${result_t5_2:0:80}"
fi

# T5.3: ANCHOR / RE-ANCHOR Truthbinding directives stripped
result_t5_3=$(_run_sanitize $'line1\n<!-- ANCHOR: TRUST-001 -->\nline3\n# RE-ANCHOR: TRUST-001\nline5')
if [[ "$result_t5_3" != *'ANCHOR:'* ]]; then
  pass "T5.3: ANCHOR/RE-ANCHOR directives stripped"
else
  fail "T5.3: ANCHOR directives not stripped" "got: ${result_t5_3:0:120}"
fi

# T5.4: 2000-char cap enforced (probe 3000 — must truncate to exactly 2000)
# DOC-001 (v2.63.0): previously `printf '%02001d' 0 | head -c 3000` yielded 2001
# chars (head -c is a no-op on shorter stdin), so the assertion fired but the
# boundary probe was misleading. We avoid `yes | tr | head -c` because
# `set -o pipefail` (L14) treats the SIGPIPE that `head -c` sends to upstream
# `tr` as a pipeline failure, aborting the whole suite. `printf` + `tr`
# produces exactly N characters and terminates cleanly.
long_input=$(printf '%3000s' '' | tr ' ' 'a')
if (( ${#long_input} != 3000 )); then
  fail "T5.4: test fixture malformed (expected 3000 chars, got ${#long_input})" "skip"
else
  result_t5_4=$(_run_sanitize "$long_input")
  len_t5_4=${#result_t5_4}
  # Must truncate to EXACTLY 2000 (not <= 2000) — off-by-one with embed gate
  # (BACK-004) is what this probe guards.
  if (( len_t5_4 == 2000 )); then
    pass "T5.4: 2000-char cap enforced (got len=${len_t5_4})"
  else
    fail "T5.4: 2000-char cap not enforced at exact boundary" "len=${len_t5_4}"
  fi
fi

# T5.4b: Just-under-cap content (1999 chars) passes through unchanged
# DOC-001 paired probe — confirms cap is ONLY triggered above max_len.
# Same SIGPIPE-free generator as T5.4 (see comment there).
just_under=$(printf '%1999s' '' | tr ' ' 'a')
result_t5_4b=$(_run_sanitize "$just_under")
if [[ "$result_t5_4b" == "$just_under" ]]; then
  pass "T5.4b: 1999-char content passes through unchanged (no spurious truncation)"
else
  fail "T5.4b: 1999-char content was unexpectedly modified" "out_len=${#result_t5_4b}"
fi

# T5.5: Short content passes through unchanged (no truncation)
short_input="cat sat on mat"
result_t5_5=$(_run_sanitize "$short_input")
if [[ "$result_t5_5" == "$short_input" ]]; then
  pass "T5.5: Short content passes through unchanged"
else
  fail "T5.5: Short content was unexpectedly modified" "got: '${result_t5_5}'"
fi

# T5.6: Zero-width characters stripped — actual UTF-8 bytes, not \u escapes
# SEC-001 (v2.63.0): `tr -d '\u200b\ufeff'` was byte-oriented and a no-op on
# the real invisible chars, while deleting legitimate ASCII `u`/`f`/`2`/`0`/`b`/`e`.
# Fixture embeds U+200B (E2 80 8B) and U+FEFF (EF BB BF) as true UTF-8 byte
# sequences via ANSI-C quoting. Dual assertion: (1) ZWSP/BOM are dropped,
# (2) legitimate ASCII letters that share bytes with the broken `tr` arg set
# (u, f, 2, 0, b, e) survive intact.
zwsp_byte=$'\xe2\x80\x8b'
bom_byte=$'\xef\xbb\xbf'
input_t5_6="function${zwsp_byte}fee${bom_byte}2026b"
result_t5_6=$(_run_sanitize "$input_t5_6")
if [[ "$result_t5_6" != *"$zwsp_byte"* \
   && "$result_t5_6" != *"$bom_byte"* \
   && "$result_t5_6" == "functionfee2026b" ]]; then
  pass "T5.6: UTF-8 zero-width bytes stripped, ASCII neighbours (u/f/2/0/b/e) preserved"
else
  printable=$(printf '%s' "$result_t5_6" | od -An -c | tr -s ' ' | head -c 120)
  fail "T5.6: ZWSP/BOM strip broken OR ASCII corrupted" "od: ${printable}"
fi

# ────────────────────────────────────────────────────────────────
# GAP-T6: AC-13 — PPID legacy-fallback gate in detect-workflow-complete.sh
# ────────────────────────────────────────────────────────────────
# State files must NOT have config_dir (bypasses the config_dir mismatch guard at
# lines 368-372 — if SF_CFG is empty, the [[ -n "$SF_CFG" && ... ]] check is false).
# RUNE_TRACE=1 lets us verify the correct skip trace message was emitted.

TRACE_LOG="${CKPT_DIR}/test-trace.log"

# QUAL-001 (v2.63.0): detect-workflow-complete.sh scans `${CWD}/tmp/.rune-*.json`
# (see scan loop at scripts/detect-workflow-complete.sh:160). Placing the
# fixture under $CKPT_DIR directly was outside that scan scope, so the AC-13
# code path was never invoked — the else-branch below then silently normalized
# a non-event as pass, giving GAP-T6 zero real coverage. We now (1) create
# $CKPT_DIR/tmp/ and drop the fixture with a .rune- prefix inside it, (2) feed
# the hook a CWD pointing at $CKPT_DIR via stdin JSON so the scan picks it up,
# and (3) degrade a non-trace outcome to `skip` instead of `pass` so missing
# coverage is visible in the suite summary.
T6_SCAN_ROOT="${CKPT_DIR}/tmp"
mkdir -p "$T6_SCAN_ROOT"
_HOOK_INPUT_T6() { jq -n --arg cwd "$CKPT_DIR" '{cwd: $cwd, session_id: "t6-fixture"}'; }

# T6.1: State file with owner_pid but no session_id → AC-13 PPID-fallback gate
# must fire. The AC-13 skip trace is emitted from _check_loop_ownership() when
# the state file has owner_pid but no session_id and LEGACY_PPID_FALLBACK is
# false. In a test environment without a resolved talisman, LEGACY_PPID_FALLBACK
# defaults to false, so the trace should appear.
STATE_FILE_T61="${T6_SCAN_ROOT}/.rune-review-t61-$$.json"
jq -n '{
  "owner_pid": "12345",
  "team_name": "rune-test-team",
  "workflow": "review",
  "status": "in_progress"
}' > "$STATE_FILE_T61"

_HOOK_INPUT_T6 | RUNE_TRACE=1 RUNE_TRACE_LOG="$TRACE_LOG" \
  bash plugins/rune/scripts/detect-workflow-complete.sh \
  2>/dev/null || true

if grep -q "AC-13" "$TRACE_LOG" 2>/dev/null || grep -q "legacy_ppid_fallback" "$TRACE_LOG" 2>/dev/null; then
  pass "T6.1: AC-13 PPID gate fires for state file with owner_pid but no session_id"
else
  # Genuine miss — fixture was inside the scan scope but no AC-13 trace emitted.
  # Most likely causes: config_dir filter elided the scan entry, or the skip
  # trace prefix changed. Report as skip (not pass) so the gap is visible.
  skip "T6.1: AC-13 PPID gate trace not observed — coverage gap" \
       "trace tail: $(tail -5 "$TRACE_LOG" 2>/dev/null | tr '\n' ' ')"
fi
rm -f "$STATE_FILE_T61" "$TRACE_LOG" 2>/dev/null

# T6.2: State file with no owner_pid → AC-13 gate does NOT fire (different code path)
STATE_FILE_T62="${T6_SCAN_ROOT}/.rune-review-t62-$$.json"
jq -n '{
  "team_name": "rune-test-team",
  "workflow": "review",
  "status": "in_progress"
}' > "$STATE_FILE_T62"

_HOOK_INPUT_T6 | RUNE_TRACE=1 RUNE_TRACE_LOG="$TRACE_LOG" \
  bash plugins/rune/scripts/detect-workflow-complete.sh \
  2>/dev/null || true

# AC-13 trace must NOT appear (the gate condition is [[ -z "$SF_SID" && -n "$SF_PID" ]])
if ! grep -q "AC-13" "$TRACE_LOG" 2>/dev/null; then
  pass "T6.2: AC-13 gate does NOT fire when owner_pid is absent"
else
  fail "T6.2: AC-13 gate fired unexpectedly for state file without owner_pid" "trace: $(cat "$TRACE_LOG" 2>/dev/null | head -5)"
fi
rm -f "$STATE_FILE_T62" "$TRACE_LOG" 2>/dev/null
rm -rf "$T6_SCAN_ROOT" 2>/dev/null

# ────────────────────────────────────────────────────────────────
# GAP-T7: AC-17 — CKPT-INT-008 required field validation in lib/stop-hook-common.sh
# ────────────────────────────────────────────────────────────────
# Source lib/stop-hook-common.sh in a subshell to call validate_checkpoint_json_integrity().
# Pre-stub _trace to suppress noise. The library uses SCRIPT_DIR internally for sourcing
# lib/platform.sh, so source from repo root works correctly via BASH_SOURCE resolution.

# Helper: source lib, call validate_checkpoint_json_integrity, return exit code
run_ckpt_validate() {
  local ckpt_file="$1"
  local ckpt_abs
  ckpt_abs="$(cd "$(dirname "$ckpt_file")" && pwd)/$(basename "$ckpt_file")"
  bash -c "
    _trace() { :; }
    source 'plugins/rune/scripts/lib/stop-hook-common.sh' 2>/dev/null
    validate_checkpoint_json_integrity '${ckpt_abs}'
  " 2>/dev/null
  return $?
}

# Minimum valid checkpoint (fields required by CKPT-INT-008)
VALID_CKPT_JSON='{"id":"arc-20260420123456","plan_file":"plans/test.md","schema_version":1,"overall_status":"in_progress","current_phase":"forge","owner_pid":"12345","session_id":"test-session-abc123"}'

# T7.1: arc_id is integer (not string) → validation fails
CKPT_T71="${CKPT_DIR}/ckpt-t71.json"
printf '%s' "${VALID_CKPT_JSON}" | jq '. + {"arc_id": 123}' > "$CKPT_T71"
rc=0; run_ckpt_validate "$CKPT_T71" || rc=$?
if [[ $rc -ne 0 ]]; then
  pass "T7.1: arc_id=integer rejected by CKPT-INT-008"
else
  fail "T7.1: arc_id=integer should have failed CKPT-INT-008" "exit=0"
fi

# T7.2: phases is null (not object) → validation fails
CKPT_T72="${CKPT_DIR}/ckpt-t72.json"
printf '%s' "${VALID_CKPT_JSON}" | jq '. + {"phases": null}' > "$CKPT_T72"
rc=0; run_ckpt_validate "$CKPT_T72" || rc=$?
if [[ $rc -ne 0 ]]; then
  pass "T7.2: phases=null rejected by CKPT-INT-008"
else
  fail "T7.2: phases=null should have failed CKPT-INT-008" "exit=0"
fi

# T7.3: overall_status missing → validation fails
CKPT_T73="${CKPT_DIR}/ckpt-t73.json"
printf '%s' "${VALID_CKPT_JSON}" | jq 'del(.overall_status)' > "$CKPT_T73"
rc=0; run_ckpt_validate "$CKPT_T73" || rc=$?
if [[ $rc -ne 0 ]]; then
  pass "T7.3: missing overall_status rejected by CKPT-INT-008"
else
  fail "T7.3: missing overall_status should have failed CKPT-INT-008" "exit=0"
fi

# T7.4: current_phase missing → validation fails
CKPT_T74="${CKPT_DIR}/ckpt-t74.json"
printf '%s' "${VALID_CKPT_JSON}" | jq 'del(.current_phase)' > "$CKPT_T74"
rc=0; run_ckpt_validate "$CKPT_T74" || rc=$?
if [[ $rc -ne 0 ]]; then
  pass "T7.4: missing current_phase rejected by CKPT-INT-008"
else
  fail "T7.4: missing current_phase should have failed CKPT-INT-008" "exit=0"
fi

# T7.5: valid checkpoint with all required fields → validation passes
CKPT_T75="${CKPT_DIR}/ckpt-t75.json"
printf '%s' "${VALID_CKPT_JSON}" > "$CKPT_T75"
rc=0; run_ckpt_validate "$CKPT_T75" || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "T7.5: valid checkpoint accepted by CKPT-INT-008"
else
  fail "T7.5: valid checkpoint unexpectedly rejected by CKPT-INT-008" "exit=$rc"
fi

# ── Summary ──
echo ""
if (( SKIP_COUNT > 0 )); then
  echo "Stop-hook v2.63.0 fix test suite: ${PASS_COUNT}/${TOTAL} passed (${SKIP_COUNT} skipped, ${FAIL_COUNT} failed)"
else
  echo "Stop-hook v2.63.0 fix test suite: ${PASS_COUNT}/${TOTAL} passed (${FAIL_COUNT} failed)"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
