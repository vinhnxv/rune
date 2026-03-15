#!/bin/bash
# PreToolUse hook: checks dirty signal before agent_search and auto-reindexes
# Only fires on agent-search MCP tool calls. Fast-path exit for clean index.
set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
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

# QUAL-002: jq guard
if ! command -v jq &>/dev/null; then
  exit 0
fi

# SEC-006: Cap stdin to 64KB
TOOL_INPUT=$(head -c 65536 2>/dev/null || true)

# Fast-path: only process agent-search MCP tool calls
TOOL_NAME=$(printf '%s' "$TOOL_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL_NAME" in
  mcp__plugin_rune_agent-search__agent_search) ;;
  *) exit 0 ;;
esac

# Check for dirty signal
HOOK_CWD=$(printf '%s' "$TOOL_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -n "$HOOK_CWD" ]] && HOOK_CWD=$(cd "$HOOK_CWD" 2>/dev/null && pwd -P) || HOOK_CWD=""
PROJECT_DIR="${HOOK_CWD:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
SIGNAL_FILE="${PROJECT_DIR}/tmp/.rune-signals/.agent-search-dirty"

if [[ ! -f "$SIGNAL_FILE" ]]; then
  # Clean index — allow tool call to proceed without reindex
  exit 0
fi

# Dirty signal found — inject advisory context to trigger server-side reindex
# The server.py _check_and_clear_dirty() will handle the actual reindex
# We just provide context that the index may be stale
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"Agent index dirty signal detected — server will auto-reindex before returning results."}}\n'
exit 0
