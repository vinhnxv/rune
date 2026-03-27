#!/bin/bash
# scripts/enforce-gh-account.sh
# PreToolUse:Bash hook — ensures the correct GitHub account is active
# before any `gh` CLI command that requires repo access.
#
# HOOK: PreToolUse (matcher: "Bash")
# CATEGORY: OPERATIONAL (fail-forward)
# TIMEOUT: 5s
#
# TRIGGER: Bash commands containing `gh pr`, `gh issue`, `gh api repos/`,
#          `gh repo`, `git push`, or `gh auth switch`.
#          Fast-path exit (<1ms) for non-gh commands.
#
# BEHAVIOR:
#   - Detects gh commands that require repo access
#   - Sources gh-account-resolver.sh to ensure correct account
#   - On success: allows command (exit 0, no output)
#   - On failure: injects advisory context (exit 0 with additionalContext)
#   - Never blocks (OPERATIONAL — fail-forward)
#
# SECURITY:
#   - GH_PROMPT_DISABLED=1 on all gh commands (SEC-DECREE-003)
#   - No command modification (read-only advisory)

set -euo pipefail
umask 077  # WARD-004 FIX: Match all other enforcement scripts

# Fail-forward ERR trap (OPERATIONAL category)
_rune_fail_forward() {
  local script_name="${BASH_SOURCE[0]##*/}"
  local line="${BASH_LINENO[0]}"
  echo "WARN: ${script_name}:${line} — fail-forward ERR trap, allowing operation" >&2
  if [[ "${RUNE_TRACE:-0}" == "1" ]]; then
    [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace.log}" ]] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WARN ${script_name}:${line} ERR-trap" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace.log}"
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Read hook input from stdin
input=$(head -c 1048576 2>/dev/null || true)

# Guard: jq dependency (fail-open without jq)
command -v jq >/dev/null 2>&1 || exit 0

# Fast-path: extract command from hook input (support both snake_case and camelCase)
command_str=$(printf '%s\n' "$input" | jq -r '(.tool_input.command // .toolInput.command) // empty' 2>/dev/null) || exit 0
[[ -z "$command_str" ]] && exit 0

# Fast-path: skip if command doesn't involve gh or git push
# This grep runs in <1ms for non-matching commands
if ! echo "$command_str" | grep -qE '(^|\s|;|&&|\|\|)(gh\s+(pr|issue|api|repo)|git\s+push)'; then
  exit 0
fi

# Skip gh auth commands themselves (avoid infinite loop)
if echo "$command_str" | grep -qE '(^|\s)gh\s+auth\s+(login|switch|status|setup-git)'; then
  exit 0
fi

# Debounce: only resolve once per session (write marker on success)
DEBOUNCE_MARKER="${TMPDIR:-/tmp}/rune-gh-account-resolved-${CLAUDE_SESSION_ID:-${PPID:-unknown}}"
if [[ -f "$DEBOUNCE_MARKER" ]]; then
  # Already resolved this session — check if marker is fresh (< 30 min)
  local_now=$(date +%s 2>/dev/null || echo "0")
  marker_time=$(cat "$DEBOUNCE_MARKER" 2>/dev/null || echo "0")
  if [[ "$local_now" -gt 0 ]] && [[ "$marker_time" -gt 0 ]]; then
    age=$(( local_now - marker_time ))
    if [[ "$age" -lt 1800 ]]; then
      exit 0  # Fresh marker — skip resolution
    fi
  fi
fi

# Resolve correct account
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/lib/gh-account-resolver.sh"

if [[ ! -f "$RESOLVER" ]]; then
  exit 0  # Resolver not available — allow command
fi

export GH_PROMPT_DISABLED=1
# shellcheck source=lib/gh-account-resolver.sh
source "$RESOLVER"

# Capture resolver output
resolve_output=$(rune_gh_ensure_correct_account 2>&1) || {
  # Account resolution failed — inject advisory (don't block)
  jq -n --arg ctx "GH-ACCOUNT-001: GitHub account resolution failed for this repository. The active gh account may not have access. Error: $resolve_output. Consider running 'gh auth login' with the correct account." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
  exit 0
}

# Resolution succeeded — write debounce marker
# WARD-003 FIX: Reject symlink before writing to prevent symlink TOCTOU
[[ -L "$DEBOUNCE_MARKER" ]] && rm -f "$DEBOUNCE_MARKER" 2>/dev/null
date +%s > "$DEBOUNCE_MARKER" 2>/dev/null || true

# If account was switched, inject context so Claude knows
if echo "$resolve_output" | grep -q "Switched to account"; then
  switched_account=$(echo "$resolve_output" | grep "Switched to account" | sed "s/.*Switched to account '\\([^']*\\)'.*/\\1/")
  jq -n --arg ctx "GH-ACCOUNT-001: Automatically switched GitHub account to '$switched_account' for this repository. Previous account did not have access." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
fi

exit 0
