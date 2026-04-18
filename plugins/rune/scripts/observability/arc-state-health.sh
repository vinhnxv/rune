#!/usr/bin/env bash
# plugins/rune/scripts/observability/arc-state-health.sh
#
# 7-day rolling health summary for the arc state file subsystem. Parses
# .rune/arc-integrity-log.jsonl (written by verify-arc-state-integrity.sh,
# arc-loop-state.sh, and related hooks) into a structured JSON report.
#
# USAGE:
#   arc-state-health.sh                       # default JSON summary
#   arc-state-health.sh --canary-gate         # AC-4 evidence gate verdict
#   arc-state-health.sh --log PATH            # override log path (testing)
#   arc-state-health.sh --window-days N       # override rolling window (default 7)
#
# EXIT CODES:
#   0  summary or canary-gate PASS emitted successfully
#   1  canary-gate FAIL
#   2  invalid arg / log parse failure
#
# Closes AC-11 (child-2-operator-ergonomics). Downstream consumer: child-3
# canary flip evaluates --canary-gate verdict for AC-4 evidence criteria.

set -u
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
: "${CWD:=$PWD}"

# Source platform helpers for cross-OS ISO-8601 epoch parsing.
if [ -f "${SCRIPT_DIR}/../lib/platform.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/../lib/platform.sh"
fi

DEFAULT_LOG="${CWD}/.rune/arc-integrity-log.jsonl"
MODE="summary"
LOG_PATH=""
WINDOW_DAYS="7"

# Canary-gate thresholds (AC-4 evidence criteria).
GATE_VERIFIED_MIN=500
GATE_RECOVERY_MIN=10
GATE_RATIO_MIN="1.0"

_usage() {
  cat <<EOF >&2
Usage: arc-state-health.sh [--canary-gate] [--log PATH] [--window-days N]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --canary-gate) MODE="canary-gate"; shift ;;
    --log) LOG_PATH="$2"; shift 2 ;;
    --window-days) WINDOW_DAYS="$2"; shift 2 ;;
    -h|--help) _usage ;;
    *) echo "FATAL: unknown arg: $1" >&2; _usage ;;
  esac
done

case "$WINDOW_DAYS" in
  ''|*[!0-9]*)
    echo "FATAL: --window-days must be a non-negative integer: $WINDOW_DAYS" >&2
    exit 2
    ;;
esac

[ -z "$LOG_PATH" ] && LOG_PATH="$DEFAULT_LOG"

# Safe path check — reject symlinks and traversal.
case "$LOG_PATH" in
  *..*) echo "FATAL: log path contains traversal: $LOG_PATH" >&2; exit 2 ;;
esac
if [ -L "$LOG_PATH" ]; then
  echo "FATAL: log path is a symlink: $LOG_PATH" >&2
  exit 2
fi

# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────
_now_epoch() { date +%s 2>/dev/null; }

# Default-safe epoch parser that falls back to platform.sh when available.
_iso_to_epoch() {
  if command -v _parse_iso_epoch >/dev/null 2>&1; then
    _parse_iso_epoch "$1"
    return
  fi
  # BSD first, GNU fallback
  date -j -f "%Y-%m-%dT%H:%M:%SZ" "${1%%.*}Z" +%s 2>/dev/null \
    || date -d "$1" +%s 2>/dev/null \
    || echo 0
}

# Emit a zero-count JSON payload used when the log is missing or empty.
_emit_zero_summary() {
  cat <<'JSON'
{
  "verified_count": 0,
  "recovered_count": 0,
  "hydrated_count": 0,
  "corrupted_write_count": 0,
  "layer2_mismatch_count": 0,
  "deletion_deferred_vs_spurious_ratio": null,
  "dry_run_ratio": 0,
  "p50_latency_ms": null,
  "p95_latency_ms": null,
  "window_days": WINDOW_SLOT,
  "total_entries": 0,
  "log_path": "LOG_SLOT"
}
JSON
}

_compute_percentile() {
  # $1 file with sorted integer latencies (one per line), $2 percentile (50|95)
  local _file="$1" _pct="$2" _count _idx _val
  _count=$(wc -l < "$_file" 2>/dev/null | tr -d ' ')
  case "$_count" in ''|*[!0-9]*) _count=0 ;; esac
  [ "$_count" = "0" ] && { echo "null"; return; }
  # awk-based index computation (integer ceil). Guards against 0 via case above.
  _idx=$(awk -v c="$_count" -v p="$_pct" 'BEGIN { i=int((c*p/100.0)+0.5); if (i<1) i=1; if (i>c) i=c; print i }')
  _val=$(sed -n "${_idx}p" "$_file" 2>/dev/null)
  case "$_val" in ''|*[!0-9]*) echo "null" ;; *) echo "$_val" ;; esac
}

# ──────────────────────────────────────────────────────────────────────────
# Missing log handling — emit zero-count summary
# ──────────────────────────────────────────────────────────────────────────
if [ ! -f "$LOG_PATH" ]; then
  if [ "$MODE" = "canary-gate" ]; then
    cat <<JSON
{
  "gate_status": "FAIL",
  "recommendation": "No integrity log at $LOG_PATH — cannot evaluate canary criteria. Run arcs to accumulate samples.",
  "window_days": $WINDOW_DAYS
}
JSON
    exit 1
  fi
  _emit_zero_summary \
    | sed "s|WINDOW_SLOT|$WINDOW_DAYS|" \
    | sed "s|LOG_SLOT|$LOG_PATH|"
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────────
# Aggregation (jq preferred, awk fallback)
# ──────────────────────────────────────────────────────────────────────────
NOW=$(_now_epoch)
CUTOFF=$(( NOW - WINDOW_DAYS * 86400 ))

_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/rune-arc-health.XXXXXX") || {
  echo "FATAL: mktemp -d failed" >&2
  exit 2
}
trap 'rm -rf "$_tmp_dir" 2>/dev/null' EXIT

filtered_log="${_tmp_dir}/filtered.jsonl"
: > "$filtered_log"

if command -v jq >/dev/null 2>&1; then
  # jq extracts `{ts, action, cause, latency_ms, dry_run}` objects that are valid
  # JSON. Malformed lines are skipped silently (fail-forward).
  jq -c 'select(type == "object") | {
    ts: (.ts // .timestamp // ""),
    action: (.action // ""),
    cause: (.cause // ""),
    latency_ms: (.latency_ms // null),
    dry_run: (.dry_run // false)
  }' "$LOG_PATH" 2>/dev/null > "${_tmp_dir}/parsed.jsonl" || true

  while IFS= read -r _line; do
    _ts=$(printf '%s' "$_line" | jq -r '.ts // empty' 2>/dev/null)
    [ -z "$_ts" ] && continue
    _epoch=$(_iso_to_epoch "$_ts")
    case "$_epoch" in ''|*[!0-9]*) continue ;; esac
    [ "$_epoch" -ge "$CUTOFF" ] 2>/dev/null || continue
    printf '%s\n' "$_line" >> "$filtered_log"
  done < "${_tmp_dir}/parsed.jsonl"
else
  # Fallback: naive line parse. Captures `"ts":"..."` or `"timestamp":"..."`.
  while IFS= read -r _line; do
    case "$_line" in
      *'"ts":"'* ) _ts=$(printf '%s' "$_line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p') ;;
      *'"timestamp":"'* ) _ts=$(printf '%s' "$_line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p') ;;
      *) continue ;;
    esac
    [ -z "$_ts" ] && continue
    _epoch=$(_iso_to_epoch "$_ts")
    case "$_epoch" in ''|*[!0-9]*) continue ;; esac
    [ "$_epoch" -ge "$CUTOFF" ] 2>/dev/null || continue
    printf '%s\n' "$_line" >> "$filtered_log"
  done < "$LOG_PATH"
fi

total_entries=$(wc -l < "$filtered_log" 2>/dev/null | tr -d ' ')
case "$total_entries" in ''|*[!0-9]*) total_entries=0 ;; esac

# Counters
verified=0
recovered=0
hydrated=0
corrupted=0
layer2_mismatch=0
deletion_deferred=0
deletion_spurious=0
dry_run=0
: > "${_tmp_dir}/latencies.txt"

if [ "$total_entries" -gt 0 ]; then
  while IFS= read -r _line; do
    _action=""
    _cause=""
    _latency=""
    _dry=""
    if command -v jq >/dev/null 2>&1; then
      _action=$(printf '%s' "$_line" | jq -r '.action // ""' 2>/dev/null)
      _cause=$(printf '%s' "$_line" | jq -r '.cause // ""' 2>/dev/null)
      _latency=$(printf '%s' "$_line" | jq -r '.latency_ms // empty' 2>/dev/null)
      _dry=$(printf '%s' "$_line" | jq -r '.dry_run // false' 2>/dev/null)
    else
      _action=$(printf '%s' "$_line" | sed -n 's/.*"action":"\([^"]*\)".*/\1/p')
      _cause=$(printf '%s' "$_line" | sed -n 's/.*"cause":"\([^"]*\)".*/\1/p')
      _latency=$(printf '%s' "$_line" | sed -n 's/.*"latency_ms":\([0-9]*\).*/\1/p')
      case "$_line" in *'"dry_run":true'*) _dry="true" ;; *) _dry="false" ;; esac
    fi

    case "$_action" in
      verified) verified=$((verified + 1)) ;;
      recovered*|recovery_ok) recovered=$((recovered + 1)) ;;
      hydrated*) hydrated=$((hydrated + 1)) ;;
      corrupted_write) corrupted=$((corrupted + 1)) ;;
      deletion_deferred) deletion_deferred=$((deletion_deferred + 1)) ;;
      deletion_spurious) deletion_spurious=$((deletion_spurious + 1)) ;;
    esac
    case "$_cause" in
      layer2_mismatch) layer2_mismatch=$((layer2_mismatch + 1)) ;;
    esac
    [ "$_dry" = "true" ] && dry_run=$((dry_run + 1))
    case "$_latency" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$_latency" >> "${_tmp_dir}/latencies.txt" ;;
    esac
  done < "$filtered_log"
fi

# Sort latencies ascending for percentile math.
sort -n "${_tmp_dir}/latencies.txt" -o "${_tmp_dir}/latencies.sorted.txt" 2>/dev/null || true
p50=$(_compute_percentile "${_tmp_dir}/latencies.sorted.txt" 50)
p95=$(_compute_percentile "${_tmp_dir}/latencies.sorted.txt" 95)

# Ratio and dry-run fraction
if [ "$deletion_spurious" = "0" ]; then
  if [ "$deletion_deferred" = "0" ]; then
    ratio="null"
  else
    ratio="Infinity"
  fi
else
  # 2-decimal float via awk (portable). Clamp to 2dp.
  ratio=$(awk -v d="$deletion_deferred" -v s="$deletion_spurious" 'BEGIN { if (s==0) print "null"; else printf "%.2f", d/s }')
fi

if [ "$total_entries" = "0" ]; then
  dry_run_ratio="0"
else
  dry_run_ratio=$(awk -v n="$dry_run" -v t="$total_entries" 'BEGIN { if (t==0) print 0; else printf "%.4f", n/t }')
fi

# ──────────────────────────────────────────────────────────────────────────
# Emit
# ──────────────────────────────────────────────────────────────────────────
if [ "$MODE" = "summary" ]; then
  cat <<JSON
{
  "verified_count": $verified,
  "recovered_count": $recovered,
  "hydrated_count": $hydrated,
  "corrupted_write_count": $corrupted,
  "layer2_mismatch_count": $layer2_mismatch,
  "deletion_deferred_vs_spurious_ratio": $ratio,
  "dry_run_ratio": $dry_run_ratio,
  "p50_latency_ms": $p50,
  "p95_latency_ms": $p95,
  "window_days": $WINDOW_DAYS,
  "total_entries": $total_entries,
  "log_path": "$LOG_PATH"
}
JSON
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────────
# --canary-gate: AC-4 evidence criteria
# ──────────────────────────────────────────────────────────────────────────
status="PASS"
reasons=""
recovery_count=$((recovered + hydrated))

if [ "$verified" -lt "$GATE_VERIFIED_MIN" ]; then
  status="FAIL"
  reasons="${reasons}verified_count=$verified < $GATE_VERIFIED_MIN; "
fi
if [ "$recovery_count" -lt "$GATE_RECOVERY_MIN" ]; then
  status="FAIL"
  reasons="${reasons}recovered+hydrated=$recovery_count < $GATE_RECOVERY_MIN; "
fi
if [ "$corrupted" -gt 0 ]; then
  status="FAIL"
  reasons="${reasons}corrupted_write_count=$corrupted > 0; "
fi
if [ "$layer2_mismatch" -gt 0 ]; then
  status="FAIL"
  reasons="${reasons}layer2_mismatch_count=$layer2_mismatch > 0; "
fi
# Ratio check: numeric compare only when ratio is a real number.
case "$ratio" in
  null|Infinity)
    # Infinity = spurious is 0, which is a PASS signal for this criterion.
    # null = no deletions at all; can't evaluate the ratio criterion — treat
    # as FAIL per strict evidence gate (sample-size insufficiency).
    if [ "$ratio" = "null" ]; then
      status="FAIL"
      reasons="${reasons}no deletion samples to evaluate ratio; "
    fi
    ;;
  *)
    # awk comparison — portable and honors decimals.
    _below=$(awk -v r="$ratio" -v m="$GATE_RATIO_MIN" 'BEGIN { print (r <= m) ? "1" : "0" }')
    if [ "$_below" = "1" ]; then
      status="FAIL"
      reasons="${reasons}deletion_deferred/spurious=$ratio <= $GATE_RATIO_MIN; "
    fi
    ;;
esac

reasons="${reasons%; }"

if [ "$status" = "PASS" ]; then
  recommendation="All AC-4 canary thresholds met ($verified verified, $recovery_count recovered/hydrated, 0 corrupted, 0 layer2 mismatches, ratio=$ratio)."
else
  recommendation="Canary gate FAIL — $reasons. Continue canary period; do not flip default yet."
fi

# JSON encode recommendation safely.
if command -v jq >/dev/null 2>&1; then
  rec_json=$(printf '%s' "$recommendation" | jq -R .)
else
  # Basic escape: drop quotes/backslashes.
  rec_json="\"$(printf '%s' "$recommendation" | tr -d '"\\')\""
fi

cat <<JSON
{
  "gate_status": "$status",
  "recommendation": $rec_json,
  "window_days": $WINDOW_DAYS,
  "evidence": {
    "verified_count": $verified,
    "recovered_count": $recovered,
    "hydrated_count": $hydrated,
    "corrupted_write_count": $corrupted,
    "layer2_mismatch_count": $layer2_mismatch,
    "deletion_deferred_vs_spurious_ratio": $ratio,
    "total_entries": $total_entries
  }
}
JSON

[ "$status" = "PASS" ] && exit 0
exit 1
