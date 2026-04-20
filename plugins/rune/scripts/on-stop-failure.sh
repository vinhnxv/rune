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
# P3-006 FIX: Scope trace log per-UID + PID, aligning with pre-compact-checkpoint.sh
# (avoids cross-user trace content leakage on shared/multi-user systems).
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"

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

# P2-001 FIX: Source platform.sh for cross-platform _stat_mtime helper (CLAUDE.md §Cross-Platform).
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh
  source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true
fi

# P2-006 FIX: Source stop-hook-common.sh to inherit the 1 MB stdin cap + shared
# field accessors. `classify_stop_failure` (below) also expects CWD/INPUT to be
# set by the common loader via its source chain.
if [[ -f "${SCRIPT_DIR}/lib/stop-hook-common.sh" ]]; then
  # shellcheck source=lib/stop-hook-common.sh
  source "${SCRIPT_DIR}/lib/stop-hook-common.sh" 2>/dev/null || true
fi

# Source error classifier (optional — fail-forward if missing)
if [[ -f "${SCRIPT_DIR}/lib/stop-failure-common.sh" ]]; then
  # shellcheck source=lib/stop-failure-common.sh
  source "${SCRIPT_DIR}/lib/stop-failure-common.sh" 2>/dev/null || true
fi

# jq is required for JSON log entry construction
command -v jq >/dev/null 2>&1 || { _trace "SKIP: jq unavailable"; exit 0; }

# ── Parse hook input ──
# P2-006 FIX: Use shared parse_input() from stop-hook-common.sh when available
# (1 MB DoS cap). Falls back to inline head -c on older setups.
if declare -F parse_input >/dev/null 2>&1; then
  parse_input 2>/dev/null || true
else
  INPUT="$(head -c 1048576 2>/dev/null || true)"
fi
[[ -z "${INPUT:-}" ]] && { _trace "SKIP: empty stdin"; exit 0; }

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
ERROR_TYPE=$(printf '%s' "$INPUT" | jq -r '.error_type // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

# SEC: validate fields
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || SESSION_ID=""
[[ "$ERROR_TYPE" =~ ^[a-zA-Z0-9_]+$ ]] || ERROR_TYPE="unknown"
# P3-005 FIX: ERROR_TYPE is used as a filename suffix below — cap length to avoid
# ENAMETOOLONG (POSIX 255-byte limit) even when the regex passes.
(( ${#ERROR_TYPE} > 32 )) && ERROR_TYPE="unknown"

# P1-003 FIX: CWD feeds mkdir/cp below. Reject relative paths and traversal
# sequences, then canonicalize via `cd && pwd -P` (matches stop-hook-common.sh
# resolve_cwd() pattern). On any failure, blank CWD so the snapshot block
# short-circuits — we never write to an attacker-influenced path.
if [[ -z "$CWD" || "$CWD" != /* || "$CWD" == *".."* ]]; then
  CWD=""
fi
if [[ -n "$CWD" ]]; then
  CWD="$(cd "$CWD" 2>/dev/null && pwd -P)" || CWD=""
fi

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

# Optional error classification from lib/stop-failure-common.sh.
#
# P1-002 FIX: The function is `classify_stop_failure` (not `stop_failure_classify`)
# and it takes NO args — it reads global $INPUT and SETS globals ERROR_TYPE,
# WAIT_SECONDS, ERROR_ACTION. The previous code had three bugs:
#   1. Wrong function name (silent no-op).
#   2. Used command-substitution to capture stdout, but classifier writes no stdout.
#   3. Passed an arg the classifier doesn't accept.
#
# We preserve the raw hook-input error_type for the JSONL entry (call it
# RAW_ERROR_TYPE), run the classifier, then derive severity from the classified
# ERROR_TYPE (RATE_LIMIT / AUTH / SERVER / UNKNOWN). Finally we restore
# ERROR_TYPE to the raw hook value so the log entry keeps its original shape.
RAW_ERROR_TYPE="$ERROR_TYPE"
CLASSIFIED_SEVERITY="info"
CLASSIFIED_CATEGORY="UNKNOWN"
CLASSIFIED_ACTION="proceed"
if declare -F classify_stop_failure >/dev/null 2>&1; then
  # classify_stop_failure writes globals; preserve our local ERROR_TYPE.
  classify_stop_failure 2>/dev/null || true
  CLASSIFIED_CATEGORY="${ERROR_TYPE:-UNKNOWN}"
  CLASSIFIED_ACTION="${ERROR_ACTION:-proceed}"
  case "$CLASSIFIED_CATEGORY" in
    AUTH)       CLASSIFIED_SEVERITY="critical" ;;  # credential compromise risk
    SERVER)     CLASSIFIED_SEVERITY="warning"  ;;  # API outage
    RATE_LIMIT) CLASSIFIED_SEVERITY="notice"   ;;  # expected, retryable
    *)          CLASSIFIED_SEVERITY="info"     ;;
  esac
  ERROR_TYPE="$RAW_ERROR_TYPE"
fi

# Append JSONL entry (atomic — jq outputs one line)
if [[ ! -L "$LOG_FILE" ]]; then
  jq -cn \
    --arg ts "$TIMESTAMP" \
    --arg sid "$SESSION_ID" \
    --arg err "$ERROR_TYPE" \
    --arg cat "$CLASSIFIED_CATEGORY" \
    --arg sev "$CLASSIFIED_SEVERITY" \
    --arg act "$CLASSIFIED_ACTION" \
    --arg cwd "$CWD" \
    '{timestamp: $ts, session_id: $sid, error_type: $err, category: $cat, severity: $sev, action: $act, cwd: $cwd, schema_version: 2}' \
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
  # P2-001 FIX: use _stat_mtime() from lib/platform.sh (cross-platform) instead
  # of inlining the BSD/GNU fallback chain.
  # Shebang is bash — `[[ -f ... ]] || continue` already handles the no-match
  # case when bash returns the literal pattern. No nullglob needed.
  for _ckpt in "$CWD"/.rune/arc/*/checkpoint.json; do
    [[ -f "$_ckpt" && ! -L "$_ckpt" ]] || continue
    if declare -F _stat_mtime >/dev/null 2>&1; then
      _m=$(_stat_mtime "$_ckpt" 2>/dev/null || echo "0")
    else
      _m=$(stat -f '%m' "$_ckpt" 2>/dev/null || stat -c '%Y' "$_ckpt" 2>/dev/null || echo "0")
    fi
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
