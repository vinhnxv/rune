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
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077  # WARD-004 FIX: Match all other enforcement scripts

# Fail-forward ERR trap (OPERATIONAL category)
_rune_fail_forward() {
  local script_name="${BASH_SOURCE[0]##*/}"
  local line="${BASH_LINENO[0]}"
  echo "WARN: ${script_name}:${line} — fail-forward ERR trap, allowing operation" >&2
  if [[ "${RUNE_TRACE:-0}" == "1" ]]; then
    # COMPAT-002 FIX: Add PID scope to trace log path (prevents write race on Linux /tmp)
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
    [[ ! -L "$_log" ]] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WARN ${script_name}:${line} ERR-trap" >> "$_log"
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
# SEC-002 FIX: Use printf instead of echo to avoid backslash expansion
# ENF-001 FIX (audit 20260419-150325): BSD grep with -E does not support `\s`
# (GNU ERE extension). On stock macOS (no coreutils) the `\s` atom silently
# failed to match whitespace, so the fast-path regex never matched any command
# and gh account resolution never fired. Use POSIX `[[:space:]]` which works
# on both BSD and GNU grep — aligns with the rest of the enforcer set.
# (VEIL-009 comment refinement from review c1a9714-018c647e.)
if ! printf '%s\n' "$command_str" | grep -qE '(^|[[:space:]]|;|&&|\|\|)(gh[[:space:]]+(pr|issue|api|repo)|git[[:space:]]+push)'; then
  exit 0
fi

# Skip gh auth commands themselves (avoid infinite loop)
if printf '%s\n' "$command_str" | grep -qE '(^|[[:space:]])gh[[:space:]]+auth[[:space:]]+(login|switch|status|setup-git)'; then
  exit 0
fi

# SEC-003 FIX (review c1a9714-018c647e): sanitize the session-id component of
# the debounce marker path. Mirror the validator in resolve-session-identity.sh:125-129
# (charset [a-zA-Z0-9_-], max 64 chars). On validation failure, fall back to PPID.
_safe_sid="${CLAUDE_SESSION_ID:-${PPID:-unknown}}"
if [[ -n "$_safe_sid" && "$_safe_sid" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  _safe_sid="${_safe_sid:0:64}"
else
  _safe_sid="${PPID:-unknown}"
fi
# Debounce: only resolve once per session (write marker on success)
DEBOUNCE_MARKER="${TMPDIR:-/tmp}/rune-gh-account-resolved-${_safe_sid}"
# SEC-004 FIX: Reject symlink before reading debounce marker (TOCTOU mitigation)
if [[ -f "$DEBOUNCE_MARKER" && ! -L "$DEBOUNCE_MARKER" ]]; then
  # Already resolved this session — check if marker is fresh (< 30 min)
  local_now=$(date +%s 2>/dev/null || echo "0")
  marker_time=$(cat "$DEBOUNCE_MARKER" 2>/dev/null || echo "0")
  # SEC-001 FIX: Explicit integer validation — attacker with $TMPDIR write access could
  # populate the marker with non-numeric garbage. Arithmetic coercion to 0 is defensive
  # by accident; enforce explicitly so future refactors can't remove the implicit sanitize.
  [[ "$marker_time" =~ ^[0-9]+$ ]] || marker_time=0
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
# SEC-002/SEC-003 FIX: Use printf instead of echo; validate switched_account format
if printf '%s\n' "$resolve_output" | grep -q "Switched to account"; then
  switched_account=$(printf '%s\n' "$resolve_output" | grep "Switched to account" | sed "s/.*Switched to account '\\([^']*\\)'.*/\\1/")
  # SEC-003 FIX: Validate account name format before embedding in message
  if [[ ! "$switched_account" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    switched_account="(unknown)"
  fi
  jq -n --arg ctx "GH-ACCOUNT-001: Automatically switched GitHub account to '$switched_account' for this repository. Previous account did not have access." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
fi

exit 0
