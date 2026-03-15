#!/bin/bash
# scripts/post-compact-verify.sh
# Validates the compact checkpoint written by pre-compact-checkpoint.sh
# after context compaction completes. Writes a failure signal when the
# checkpoint is missing, corrupt, or incomplete; injects compact_summary
# into valid checkpoints for downstream recovery context.
#
# DESIGN PRINCIPLES:
#   1. Non-blocking — always exit 0 (PostCompact must never be prevented)
#   2. Fail-forward — ERR trap exits cleanly on unexpected failures
#   3. 3-tier validation: missing → corrupt JSON → incomplete fields
#   4. Atomic writes — temp+mv pattern prevents partial file writes
#   5. Compact summary injection — capped 2000 chars for context efficiency
#
# Hook events: PostCompact
# Matcher: manual|auto
# Timeout: 5s
# Exit 0: Always (non-blocking)

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  # VEIL-003/BACK-005: Always emit stderr warning so crash-through-compaction is observable
  printf 'WARN: post-compact-verify.sh: ERR trap — fail-forward activated (line %s)\n' \
    "${BASH_LINENO[0]:-?}" >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Opt-in trace logging (consistent with other Rune hook scripts)
_trace() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && echo "[post-compact-verify] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

# --- GUARD 1: jq dependency ---
if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — post-compact verification skipped" >&2
  exit 0
fi

# --- GUARD 2: Input size cap (SEC-2: 1MB DoS prevention) ---
# timeout guard prevents blocking on disconnected stdin (macOS may lack timeout)
if command -v timeout &>/dev/null; then
  INPUT=$(timeout 2 head -c 1048576 || true)
else
  INPUT=$(head -c 1048576 2>/dev/null || true)
fi

# --- GUARD 3: CWD extraction and canonicalization ---
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then exit 0; fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# --- GUARD 4: tmp/ directory must exist ---
if [[ ! -d "${CWD}/tmp" ]]; then exit 0; fi

# --- CHOME resolution ---
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0
fi

CHECKPOINT_FILE="${CWD}/tmp/.rune-compact-checkpoint.json"
SIGNAL_FILE="${CWD}/tmp/.compact-checkpoint-failed"

# Cleanup temp file on exit
CHECKPOINT_TMP=""
SIGNAL_TMP=""
cleanup() {
  [[ -n "$CHECKPOINT_TMP" ]] && rm -f "$CHECKPOINT_TMP" 2>/dev/null
  [[ -n "$SIGNAL_TMP" ]] && rm -f "$SIGNAL_TMP" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Helper: write failure signal atomically
_write_signal() {
  local _reason="$1"
  SIGNAL_TMP=$(mktemp "${SIGNAL_FILE}.XXXXXX" 2>/dev/null) || return 0
  [[ -L "$SIGNAL_TMP" ]] && { rm -f "$SIGNAL_TMP" 2>/dev/null; SIGNAL_TMP=""; return 0; }
  jq -n \
    --arg reason "$_reason" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
    '{ reason: $reason, timestamp: $ts }' > "$SIGNAL_TMP" 2>/dev/null || {
      rm -f "$SIGNAL_TMP" 2>/dev/null; SIGNAL_TMP=""; return 0
    }
  mv -f "$SIGNAL_TMP" "$SIGNAL_FILE" 2>/dev/null || rm -f "$SIGNAL_TMP" 2>/dev/null
  SIGNAL_TMP=""
}

# ── TIER 1: Checkpoint file must exist ──
if [[ ! -f "$CHECKPOINT_FILE" ]] || [[ -L "$CHECKPOINT_FILE" ]]; then
  _trace "No compact checkpoint found — verification skipped"
  exit 0
fi

# ── TIER 2: Corrupt JSON check ──
CHECKPOINT_DATA=$(jq -c '.' "$CHECKPOINT_FILE" 2>/dev/null) || {
  echo "WARN: post-compact-verify.sh: checkpoint is not valid JSON — writing failure signal" >&2
  _trace "Checkpoint corrupt JSON: ${CHECKPOINT_FILE}"
  _write_signal "corrupt_json"
  exit 0
}

# ── TIER 3: Incomplete fields check ──
# Required keys: saved_at, config_dir, owner_pid
_missing_key=""
for _key in saved_at config_dir owner_pid; do
  _val=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r ".${_key} // empty" 2>/dev/null || true)
  if [[ -z "$_val" ]]; then
    _missing_key="$_key"
    break
  fi
done

if [[ -n "$_missing_key" ]]; then
  echo "WARN: post-compact-verify.sh: checkpoint missing required field '${_missing_key}' — writing failure signal" >&2
  _trace "Checkpoint incomplete: missing ${_missing_key}"
  _write_signal "incomplete_fields"
  exit 0
fi

# ── Checkpoint is valid — remove any stale failure signal ──
rm -f "$SIGNAL_FILE" 2>/dev/null

# ── Build compact_summary (capped 2000 chars) ──
TEAM_NAME=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.team_name // empty' 2>/dev/null || true)
SAVED_AT=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.saved_at // "unknown"' 2>/dev/null || echo "unknown")
TASK_COUNT=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.tasks // [] | length' 2>/dev/null || echo "0")

if [[ -n "$TEAM_NAME" ]]; then
  COMPACT_SUMMARY="Team '${TEAM_NAME}' state checkpointed at ${SAVED_AT}. Tasks: ${TASK_COUNT}."
else
  COMPACT_SUMMARY="No active team at compaction. Checkpoint saved at ${SAVED_AT}."
fi

# Append arc-batch context if present
BATCH_ITER=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.arc_batch_state.iteration // empty' 2>/dev/null || true)
if [[ -n "$BATCH_ITER" ]] && [[ "$BATCH_ITER" =~ ^[0-9]+$ ]]; then
  BATCH_TOTAL=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.arc_batch_state.total_plans // empty' 2>/dev/null || true)
  if [[ ! "$BATCH_TOTAL" =~ ^[0-9]+$ ]]; then BATCH_TOTAL="?"; fi
  COMPACT_SUMMARY="${COMPACT_SUMMARY} Arc-batch: ${BATCH_ITER}/${BATCH_TOTAL}."
fi

# Append arc-issues context if present
ISSUES_ITER=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.arc_issues_state.iteration // empty' 2>/dev/null || true)
if [[ -n "$ISSUES_ITER" ]] && [[ "$ISSUES_ITER" =~ ^[0-9]+$ ]]; then
  ISSUES_TOTAL=$(printf '%s\n' "$CHECKPOINT_DATA" | jq -r '.arc_issues_state.total_plans // empty' 2>/dev/null || true)
  if [[ ! "$ISSUES_TOTAL" =~ ^[0-9]+$ ]]; then ISSUES_TOTAL="?"; fi
  COMPACT_SUMMARY="${COMPACT_SUMMARY} Arc-issues: ${ISSUES_ITER}/${ISSUES_TOTAL}."
fi

# Cap at 2000 chars
COMPACT_SUMMARY="${COMPACT_SUMMARY:0:2000}"
_trace "compact_summary: ${COMPACT_SUMMARY}"

# ── Inject compact_summary into checkpoint (atomic update) ──
CHECKPOINT_TMP=$(mktemp "${CHECKPOINT_FILE}.XXXXXX" 2>/dev/null) || { exit 0; }
[[ -L "$CHECKPOINT_TMP" ]] && { rm -f "$CHECKPOINT_TMP" 2>/dev/null; CHECKPOINT_TMP=""; exit 0; }

if jq --arg summary "$COMPACT_SUMMARY" '. + {compact_summary: $summary}' \
    "$CHECKPOINT_FILE" > "$CHECKPOINT_TMP" 2>/dev/null; then
  mv -f "$CHECKPOINT_TMP" "$CHECKPOINT_FILE" 2>/dev/null || {
    rm -f "$CHECKPOINT_TMP" 2>/dev/null
    CHECKPOINT_TMP=""
    exit 0
  }
  CHECKPOINT_TMP=""  # Moved successfully — do not delete in cleanup
  _trace "compact_summary injected into checkpoint"
else
  # jq update failed — checkpoint still valid, just no summary
  rm -f "$CHECKPOINT_TMP" 2>/dev/null
  CHECKPOINT_TMP=""
fi

# ── Output hookSpecificOutput for PostCompact ──
jq -n \
  --arg summary "$COMPACT_SUMMARY" \
  '{
    hookSpecificOutput: {
      hookEventName: "PostCompact",
      additionalContext: $summary
    }
  }'

exit 0
