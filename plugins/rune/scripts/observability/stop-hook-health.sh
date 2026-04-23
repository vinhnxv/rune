#!/usr/bin/env bash
# plugins/rune/scripts/observability/stop-hook-health.sh
#
# Rolling health summary for the arc Stop hook emission subsystem.
# Parses ${TMPDIR}/rune-stop-hook-events-${UID}.jsonl (written by
# arc_stop_continue / arc_stop_halt in lib/arc-stop-hook-common.sh Block K)
# into a structured JSON report.
#
# PURPOSE (VEIL-004 runtime canary):
#   Verifies the {decision:"block", reason} re-injection contract is firing
#   on the running Claude Code version. If `emission_count` is 0 or lags
#   the actual arc phase count, it indicates either a stale binary or a
#   contract regression in the host Claude Code.
#
# USAGE:
#   stop-hook-health.sh                    # rolling summary (default 60 min window)
#   stop-hook-health.sh --window-mins N    # override window (default 60)
#   stop-hook-health.sh --log PATH         # override log path (testing)
#   stop-hook-health.sh --contract-check   # verify contract live: exit 1 if
#                                          # no emissions in the last N mins
#                                          # while arc checkpoint is active
#
# EXIT CODES:
#   0  summary emitted successfully (or contract-check PASS)
#   1  contract-check FAIL (no emissions during active arc)
#   2  invalid arg / log parse failure
#
# DEPENDS: jq (for JSON formatting).

set -u
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
: "${CWD:=$PWD}"

_TMPDIR="${TMPDIR:-/tmp}"
_UID="${UID:-$(id -u 2>/dev/null || echo 0)}"
DEFAULT_LOG="${_TMPDIR}/rune-stop-hook-events-${_UID}.jsonl"

MODE="summary"
LOG_PATH=""
WINDOW_MINS="60"

_usage() {
  cat <<EOF >&2
Usage: stop-hook-health.sh [--contract-check] [--log PATH] [--window-mins N]

Reports Stop hook emission telemetry from arc_stop_continue / arc_stop_halt.

  --contract-check  Verify re-injection contract is live. Exits 1 if no
                    emissions in the last --window-mins while an arc
                    checkpoint shows in_progress phases — signals a
                    possible Claude Code regression.
  --log PATH        Override breadcrumb log path (default: ${DEFAULT_LOG}).
  --window-mins N   Rolling window for summary (default: 60).
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --contract-check) MODE="contract-check"; shift ;;
    --log) LOG_PATH="$2"; shift 2 ;;
    --window-mins) WINDOW_MINS="$2"; shift 2 ;;
    -h|--help) _usage ;;
    *) echo "FATAL: unknown arg: $1" >&2; _usage ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq required","mode":"'"$MODE"'"}'
  exit 2
fi

# Integer validation on --window-mins.
if ! [[ "$WINDOW_MINS" =~ ^[0-9]+$ ]] || [ "$WINDOW_MINS" -lt 1 ]; then
  echo "FATAL: --window-mins must be a positive integer (got: $WINDOW_MINS)" >&2
  exit 2
fi

LOG_PATH="${LOG_PATH:-$DEFAULT_LOG}"

# Symlink guard (defense-in-depth — the writer also rejects symlinks).
if [ -L "$LOG_PATH" ]; then
  echo '{"error":"log path is a symlink (rejected)","path":"'"$LOG_PATH"'"}'
  exit 2
fi

if [ ! -f "$LOG_PATH" ]; then
  # Empty state is valid — no arc has run yet, or the breadcrumb log was
  # rotated/cleared. Emit a zero-count summary and exit 0 for summary mode.
  if [ "$MODE" = "contract-check" ]; then
    # Contract-check fails only if an arc is actively running without
    # emissions. If no log exists AND no arc is active, that's fine.
    if [ -d "${CWD}/.rune/arc" ] && compgen -G "${CWD}/.rune/arc/*/checkpoint.json" >/dev/null 2>&1; then
      echo '{"verdict":"FAIL","reason":"arc checkpoint present but no breadcrumb log — Stop hook may not be firing","log":"'"$LOG_PATH"'"}'
      exit 1
    fi
    echo '{"verdict":"PASS","reason":"no arc active, no emissions expected","log":"'"$LOG_PATH"'"}'
    exit 0
  fi
  echo '{"mode":"summary","window_mins":'"$WINDOW_MINS"',"emission_count":0,"log_exists":false,"log":"'"$LOG_PATH"'"}'
  exit 0
fi

# Compute cutoff epoch = now - window_mins*60.
NOW_EPOCH=$(date +%s)
WINDOW_SECS=$((WINDOW_MINS * 60))
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_SECS))

# Source platform helpers for cross-OS ISO-8601 parsing.
if [ -f "${SCRIPT_DIR}/../lib/platform.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/../lib/platform.sh"
fi

# Filter breadcrumbs by timestamp window using jq + platform helper.
# Skip malformed lines silently (log rotation / concurrent writes can
# truncate a partial line).
_filter_recent() {
  while IFS= read -r _line; do
    # Skip blank or invalid JSON.
    [ -z "$_line" ] && continue
    echo "$_line" | jq -e . >/dev/null 2>&1 || continue
    _ts=$(echo "$_line" | jq -r '.ts // empty')
    [ -z "$_ts" ] && continue
    _epoch=$(_parse_iso_epoch "$_ts" 2>/dev/null || echo 0)
    [ "${_epoch:-0}" -ge "$CUTOFF_EPOCH" ] && echo "$_line"
  done < "$LOG_PATH"
}

_RECENT=$(_filter_recent)
_COUNT=$(printf '%s\n' "$_RECENT" | grep -c . 2>/dev/null || echo 0)

if [ "$MODE" = "contract-check" ]; then
  # Pass if we've seen any recent emissions, OR if no arc is active.
  _arc_active="false"
  if [ -d "${CWD}/.rune/arc" ] && compgen -G "${CWD}/.rune/arc/*/checkpoint.json" >/dev/null 2>&1; then
    _arc_active="true"
  fi

  if [ "$_COUNT" -gt 0 ]; then
    printf '{"verdict":"PASS","emission_count":%s,"window_mins":%s,"arc_active":%s}\n' \
      "$_COUNT" "$WINDOW_MINS" "$_arc_active"
    exit 0
  fi

  if [ "$_arc_active" = "true" ]; then
    printf '{"verdict":"FAIL","reason":"arc active but no Stop hook emissions in last %s mins","emission_count":0,"window_mins":%s}\n' \
      "$WINDOW_MINS" "$WINDOW_MINS"
    exit 1
  fi

  printf '{"verdict":"PASS","reason":"no arc active, no emissions expected","emission_count":0,"window_mins":%s}\n' \
    "$WINDOW_MINS"
  exit 0
fi

# Default mode: summary. Aggregate by source + kind.
_SUMMARY=$(printf '%s\n' "$_RECENT" | jq -s '
  {
    mode: "summary",
    window_mins: ('"$WINDOW_MINS"' | tonumber),
    emission_count: length,
    by_source: (group_by(.source) | map({key: (.[0].source // "unknown"), value: length}) | from_entries),
    by_kind: (group_by(.kind) | map({key: (.[0].kind // "unknown"), value: length}) | from_entries),
    first_ts: (if length > 0 then (min_by(.ts) | .ts) else null end),
    last_ts: (if length > 0 then (max_by(.ts) | .ts) else null end),
    log_size_bytes: '"$(wc -c <"$LOG_PATH" 2>/dev/null | tr -d ' ')"'
  }
' 2>/dev/null)

if [ -z "$_SUMMARY" ]; then
  echo '{"error":"jq aggregation failed","log":"'"$LOG_PATH"'","recent_count":'"$_COUNT"'}'
  exit 2
fi

echo "$_SUMMARY"
exit 0
