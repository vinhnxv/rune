#!/bin/bash
# scripts/talisman-invalidate.sh
# PostToolUse hook: Regenerates talisman shards when talisman.yml is edited.
#
# Fast-path exit (<5ms) for non-talisman writes using grep (not jq).
# Only talisman.yml writes trigger the full resolver (~0.6s).
#
# Hook events: PostToolUse:Write|Edit
# Timeout: 5s
# Non-blocking: exits 0 on all failures

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
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

# ── Fast-path: read stdin and check for talisman.yml via grep ──
# Using grep instead of jq for file_path extraction (~0.3ms vs ~5-8ms).
# This hook fires on EVERY Write/Edit, so cumulative overhead matters.
INPUT=$(head -c 1048576 2>/dev/null || true)

# Quick grep — exit immediately if not talisman
# Matches file_path or filePath containing "talisman.yml"
if ! echo "$INPUT" | grep -q 'talisman\.yml' 2>/dev/null; then
  exit 0
fi

# ── Slower path: confirm via jq for precision ──
if command -v jq &>/dev/null; then
  FILE_PATH=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // ""' 2>/dev/null || true)
else
  # No jq — trust the grep match
  FILE_PATH="talisman.yml"
fi

# Confirm it actually ends with talisman.yml
if [[ "$FILE_PATH" != *talisman.yml ]]; then
  exit 0
fi

# ── Trace logging ──
if [[ "${RUNE_TRACE:-}" == "1" ]]; then
  _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
  [[ ! -L "$_log" ]] && echo "[talisman-invalidate] Detected talisman.yml write: $FILE_PATH — regenerating shards" >> "$_log" 2>/dev/null
fi

# ── Re-run resolver ──
# Pass through the original input so the resolver can extract CWD and session_id
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RESOLVER="${PLUGIN_ROOT}/scripts/talisman-resolve.sh"

if [[ -x "$RESOLVER" ]] && [[ ! -L "$RESOLVER" ]]; then
  echo "$INPUT" | "$RESOLVER" || {
    if [[ "${RUNE_TRACE:-}" == "1" ]]; then
      _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
      [[ ! -L "$_log" ]] && echo "[talisman-invalidate] WARN: resolver failed with exit code $?" >> "$_log" 2>/dev/null
    fi
    exit 0  # Non-blocking per design
  }
else
  exit 0
fi
