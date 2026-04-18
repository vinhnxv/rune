#!/usr/bin/env bash
# probe-monitor-availability.sh — SessionStart host capability probe.
#
# Detects whether the Claude Code `Monitor` tool is likely available on this
# host by checking env vars that disable telemetry / non-essential traffic
# or that route Claude through Bedrock/Vertex (where Monitor may not propagate).
# Writes a sentinel file under `${CLAUDE_PROJECT_DIR:-$(pwd)}/tmp/` for
# downstream consumers to gate Monitor-dependent behavior.
#
# Covers plan AC-5 — monitor tool integration, host capability probe.
# Fail-open: never blocks session start. Idempotent: safe to re-run.

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null || true
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# --- EXIT trap: always emit a valid SessionStart envelope ---
_HOOK_JSON_SENT=false
_rune_session_hook_exit() {
  if [[ "$_HOOK_JSON_SENT" != "true" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart"}}\n'
  fi
}
trap '_rune_session_hook_exit' EXIT

# --- Source platform helpers (optional) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh disable=SC1091
  source "${SCRIPT_DIR}/lib/platform.sh"
fi

# --- Detect unavailability triggers ---
# NOTE: CLAUDE_CODE_ENTRYPOINT is explicitly excluded (RISK-E: unverified).
reasons=""
_add_reason() {
  if [[ -z "$reasons" ]]; then
    reasons="$1"
  else
    reasons="${reasons},$1"
  fi
}

if [[ -n "${DISABLE_TELEMETRY:-}" ]]; then
  _add_reason "DISABLE_TELEMETRY"
fi
if [[ -n "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]]; then
  _add_reason "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
fi
if [[ -n "${ANTHROPIC_BEDROCK_BASE_URL:-}" ]]; then
  _add_reason "ANTHROPIC_BEDROCK_BASE_URL"
fi
if [[ -n "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]]; then
  _add_reason "ANTHROPIC_VERTEX_PROJECT_ID"
fi

# --- Resolve target sentinel dir ---
TARGET_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/tmp"
mkdir -p "$TARGET_DIR"

avail_file="${TARGET_DIR}/.rune-monitor-available"
unavail_file="${TARGET_DIR}/.rune-monitor-unavailable"
probed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Write sentinel (atomic tmp+mv) ---
if [[ -z "$reasons" ]]; then
  available="true"
  reason_out="none"
  tmp_file="${avail_file}.tmp.$$"
  printf 'available=1\nprobed_at=%s\n' "$probed_at" > "$tmp_file"
  mv -f "$tmp_file" "$avail_file"
  rm -f "$unavail_file" 2>/dev/null || true
else
  available="false"
  reason_out="$reasons"
  tmp_file="${unavail_file}.tmp.$$"
  printf 'available=0\nreason=%s\nprobed_at=%s\n' "$reasons" "$probed_at" > "$tmp_file"
  mv -f "$tmp_file" "$unavail_file"
  rm -f "$avail_file" 2>/dev/null || true
fi

# --- Emit JSON (mark sent so EXIT trap does not re-emit) ---
_HOOK_JSON_SENT=true
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[monitor-probe] available=%s reason=%s"}}\n' \
  "$available" "$reason_out"

exit 0
