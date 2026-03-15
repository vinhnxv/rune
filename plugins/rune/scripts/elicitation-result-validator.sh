#!/usr/bin/env bash
# scripts/elicitation-result-validator.sh
# SEC-ELICIT-001: Validate ElicitationResult user responses for path traversal and injection.
#
# Fired by Claude Code when a user responds to an elicitation prompt from an MCP tool.
# Validates all string fields in the response for dangerous patterns before they are
# passed back to the MCP tool (echo-search or figma-to-react).
#
# SECURITY-class hook — NO _rune_fail_forward ERR trap. Unexpected crashes exit 2
# (fail-closed) to prevent malicious responses from bypassing validation.
# See CLAUDE.md "Hook Crash Classification" for the SECURITY vs OPERATIONAL distinction.
#
# Validation checks:
#   1. Path traversal — reject responses containing ".." sequences
#   2. Command injection — reject responses with shell metacharacters (; && || | ` $( ))
#   3. Null bytes — reject responses containing null (\x00) characters
#
# Exit codes:
#   0 = response is clean — allow (outputs hookSpecificOutput JSON with hookEventName)
#   2 = response blocked — stderr fed to Claude as rejection reason
#
# Matcher: echo-search|figma-to-react
# Event: ElicitationResult
# Timeout: 5s

set -euo pipefail
umask 077

# --- SECURITY: No _rune_fail_forward trap ---
# This is a SECURITY-class hook. Unexpected errors crash → exit 2 (blocking).
# Unlike OPERATIONAL hooks which use _rune_fail_forward to exit 0, SECURITY hooks
# must NOT fail open — an uncaught error could allow a malicious response through.

# ── Guard 1: jq dependency ──
# SECURITY-CRITICAL: failing open would bypass SEC-ELICIT-001 validation.
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found — elicitation-result-validator.sh requires jq. Install jq to enable SEC-ELICIT-001 protection." >&2
  exit 2
fi

# ── Guard 2: Input size cap (SEC-2: 1MB DoS prevention) ──
# Limit stdin to prevent memory exhaustion from oversized payloads.
if command -v timeout &>/dev/null; then
  INPUT=$(timeout 2 head -c 1048576 2>/dev/null || true)
else
  INPUT=$(head -c 1048576 2>/dev/null || true)
fi

if [[ -z "$INPUT" ]]; then
  # No input — nothing to validate, allow
  jq -n '{"hookSpecificOutput": {"hookEventName": "ElicitationResult"}}'
  exit 0
fi

# ── Guard 3: Parse response values from hook input ──
# Extract all string values from the response object for validation.
# ElicitationResult input contains the user's answers as a flat object.
# We collect all values regardless of key names to catch any field injection.
RESPONSE_VALUES=$(printf '%s\n' "$INPUT" | jq -r '
  .response // {} |
  .. |
  if type == "string" then . else empty end
' 2>/dev/null || true)

if [[ -z "$RESPONSE_VALUES" ]]; then
  # No string values to validate — allow
  jq -n '{"hookSpecificOutput": {"hookEventName": "ElicitationResult"}}'
  exit 0
fi

# ── Validation: scan each response value for dangerous patterns ──
# Process values line by line (jq outputs one string per line with -r).
while IFS= read -r value; do
  [[ -z "$value" ]] && continue

  # Check 1: Path traversal — ".." sequences allow escaping expected directories
  if printf '%s' "$value" | grep -qF '..'; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing path traversal sequence ('..'). Value rejected for security. Do not include relative path components in your response." >&2
    exit 2
  fi

  # Check 2: Null bytes — can bypass string length checks and truncate paths
  if printf '%s' "$value" | grep -qP '\x00' 2>/dev/null || \
     printf '%s' "$value" | LC_ALL=C grep -q $'\x00' 2>/dev/null; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing null byte. Value rejected for security." >&2
    exit 2
  fi

  # Check 3: Command injection metacharacters
  # Patterns: semicolon sequences (;), AND (&&), OR (||), pipe (|), backtick (`),
  # command substitution ($(, ${), newline-as-separator injection (\n in string)
  if printf '%s' "$value" | grep -qE '(;|&&|\|\||`|\$\(|\$\{)'; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing shell metacharacter. Value rejected for security. Avoid characters like: ; && || \` \$( \${" >&2
    exit 2
  fi

done <<< "$RESPONSE_VALUES"

# ── All checks passed — allow response ──
# Output hookEventName as required by CLAUDE.md hook JSON output spec.
jq -n '{"hookSpecificOutput": {"hookEventName": "ElicitationResult"}}'
exit 0
