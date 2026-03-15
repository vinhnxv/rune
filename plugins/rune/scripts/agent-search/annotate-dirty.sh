#!/bin/bash
# PostToolUse hook: detects writes to agent definition files and writes dirty signal
# Triggers on writes to agents/*.md, registry/*.md, .claude/agents/*.md
# Signal-file pattern for debounced reindex.
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

# SEC-006: Cap stdin to 64KB (only need file_path, not full content)
TOOL_INPUT=$(head -c 65536 2>/dev/null || true)

FILE_PATH=$(printf '%s' "$TOOL_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

# Match agent definition paths: agents/*.md, registry/*.md, .claude/agents/*.md
if [[ "$FILE_PATH" == */agents/*.md ]] || [[ "$FILE_PATH" == */registry/*.md ]]; then
  # Write dirty signal for next agent-search invocation to pick up
  HOOK_CWD=$(printf '%s' "$TOOL_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  # SEC-005: Canonicalize CWD before use in file paths
  [[ -n "$HOOK_CWD" ]] && HOOK_CWD=$(cd "$HOOK_CWD" 2>/dev/null && pwd -P) || HOOK_CWD=""
  SIGNAL_DIR="${HOOK_CWD:-${CLAUDE_PROJECT_DIR:-$(pwd)}}/tmp/.rune-signals"
  mkdir -p "$SIGNAL_DIR" 2>/dev/null
  printf '1' > "$SIGNAL_DIR/.agent-search-dirty" 2>/dev/null
fi

exit 0
