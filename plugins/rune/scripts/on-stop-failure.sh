#!/bin/bash
# scripts/on-stop-failure.sh
# STOP-FAIL-001 (v2.62.0): Log API errors and snapshot arc checkpoint.
#
# StopFailure fires when a Claude Code turn ends due to an API error (rate_limit,
# server_error, max_output_tokens, authentication_failed, etc). Per the official
# hook docs (code.claude.com/docs/en/hooks):
#
#   > StopFailure — When the turn ends due to an API error.
#   > Output and exit code are IGNORED — used for side effects like logging
#   > or cleanup only.
#
# So this script is pure side-effect:
#   1. Parse hook input JSON (session_id, error_type, transcript_path)
#   2. Classify error via lib/stop-failure-common.sh
#   3. Append JSONL entry to ${TMPDIR}/rune-stop-failure-$(id -u).jsonl
#      (5MB size cap, rotation by truncation)
#   4. Best-effort copy of current arc checkpoint to
#      .rune/arc-checkpoint-snapshots/checkpoint-{timestamp}.json
#
# What this script does NOT do (because output is ignored):
#   - Construct backoff / retry prompts (would be discarded)
#   - Kill teammate processes (Stop hook handles next session)
#   - TeamDelete / filesystem cleanup (Stop hook handles next session)
#
# OPERATIONAL: fail-forward (exit 0 on any error — exit code ignored anyway).

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-/tmp/rune-hook-trace.log}"

# Fail-forward ERR trap (exit code is ignored per spec, but consistent with
# other OPERATIONAL hooks for auditing).
_rune_fail_forward() {
  [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] \
    && printf '[%s] on-stop-failure: ERR at line %s\n' "$(date +%H:%M:%S)" "${BASH_LINENO[0]:-?}" >> "$RUNE_TRACE_LOG"
  exit 0
}
trap '_rune_fail_forward' ERR

_trace() {
  [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] \
    && printf '[%s] on-stop-failure: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"
  return 0
}

# Source error classifier (optional — fail-forward if missing)
if [[ -f "${SCRIPT_DIR}/lib/stop-failure-common.sh" ]]; then
  # shellcheck source=lib/stop-failure-common.sh
  source "${SCRIPT_DIR}/lib/stop-failure-common.sh" 2>/dev/null || true
fi

# jq is required for JSON log entry construction
command -v jq >/dev/null 2>&1 || { _trace "SKIP: jq unavailable"; exit 0; }

# ── Parse hook input ──
INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && { _trace "SKIP: empty stdin"; exit 0; }

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
ERROR_TYPE=$(printf '%s' "$INPUT" | jq -r '.error_type // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

# SEC: validate fields
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || SESSION_ID=""
[[ "$ERROR_TYPE" =~ ^[a-zA-Z0-9_]+$ ]] || ERROR_TYPE="unknown"

_trace "ENTER session=${SESSION_ID:-?} error=${ERROR_TYPE}"

# ── Log entry ──
LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="${LOG_DIR}/rune-stop-failure-$(id -u).jsonl"
LOG_MAX_BYTES=$((5 * 1024 * 1024))  # 5 MB cap

# Rotation: if file exceeds cap, truncate (best-effort, fail-forward)
if [[ -f "$LOG_FILE" && ! -L "$LOG_FILE" ]]; then
  _log_size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ "$_log_size" =~ ^[0-9]+$ ]] && (( _log_size > LOG_MAX_BYTES )); then
    : > "$LOG_FILE" 2>/dev/null || true
    _trace "log rotated: size ${_log_size} exceeded ${LOG_MAX_BYTES}"
  fi
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

# Optional error classification from lib
CLASSIFIED_SEVERITY="info"
if declare -F stop_failure_classify >/dev/null 2>&1; then
  CLASSIFIED_SEVERITY=$(stop_failure_classify "$ERROR_TYPE" 2>/dev/null || echo "info")
fi

# Append JSONL entry (atomic — jq outputs one line)
if [[ ! -L "$LOG_FILE" ]]; then
  jq -cn \
    --arg ts "$TIMESTAMP" \
    --arg sid "$SESSION_ID" \
    --arg err "$ERROR_TYPE" \
    --arg sev "$CLASSIFIED_SEVERITY" \
    --arg cwd "$CWD" \
    '{timestamp: $ts, session_id: $sid, error_type: $err, severity: $sev, cwd: $cwd, schema_version: 1}' \
    >> "$LOG_FILE" 2>/dev/null || _trace "log append failed"
fi

# ── Best-effort checkpoint snapshot ──
# Find the most-recently-modified arc checkpoint in CWD and copy it to
# .rune/arc-checkpoint-snapshots/ with a timestamp suffix. Non-fatal.
if [[ -n "$CWD" && -d "$CWD/.rune/arc" ]]; then
  SNAP_DIR="$CWD/.rune/arc-checkpoint-snapshots"
  mkdir -p "$SNAP_DIR" 2>/dev/null || true

  # Find newest checkpoint.json under .rune/arc/*/checkpoint.json
  LATEST_CHECKPOINT=""
  LATEST_MTIME=0
  for _ckpt in "$CWD"/.rune/arc/*/checkpoint.json; do
    [[ -f "$_ckpt" && ! -L "$_ckpt" ]] || continue
    _m=$(stat -f '%m' "$_ckpt" 2>/dev/null || stat -c '%Y' "$_ckpt" 2>/dev/null || echo "0")
    [[ "$_m" =~ ^[0-9]+$ ]] || continue
    if (( _m > LATEST_MTIME )); then
      LATEST_MTIME=$_m
      LATEST_CHECKPOINT="$_ckpt"
    fi
  done

  if [[ -n "$LATEST_CHECKPOINT" ]]; then
    SNAP_NAME="checkpoint-${TIMESTAMP//:/-}-${ERROR_TYPE}.json"
    cp -p "$LATEST_CHECKPOINT" "$SNAP_DIR/$SNAP_NAME" 2>/dev/null \
      && _trace "checkpoint snapshot: $SNAP_NAME" \
      || _trace "checkpoint snapshot failed"
  fi
fi

_trace "EXIT ok"
exit 0
