#!/bin/bash
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
trap 'exit 2' ERR  # XVER-SEC-002 FIX: fail-closed from start for SECURITY hook
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

  # Check 2: Null bytes — ACCEPTED RISK (SEC-004)
  # Bash strips null bytes from variables at read time (NUL terminates C strings).
  # By the time $value is stored, null bytes are already removed. This check can
  # never match. jq itself handles null bytes safely during JSON parsing upstream.
  # Keeping the check as defense-in-depth for non-bash execution contexts.
  if printf '%s' "$value" | LC_ALL=C grep -q $'\x00' 2>/dev/null; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing null byte. Value rejected for security." >&2
    exit 2
  fi

  # Check 3: Command injection metacharacters
  # Patterns: semicolon sequences (;), AND (&&), OR (||), pipe (|), backtick (`),
  # command substitution ($(, ${), process substitution (<(, >()), brace expansion ({..})
  # WARD-009 FIX: Remove single pipe (|) — too aggressive for natural language input
  # DSEC-001 FIX: Added process substitution (<(, >() and literal newline detection
  if printf '%s' "$value" | grep -qE '(;|&&|\|\||`|\$\(|\$\{|<\(|>\()'; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing shell metacharacter. Value rejected for security. Avoid characters like: ; && || \` \$( \${ <( >(" >&2
    exit 2
  fi

  # DSEC-001 FIX: Detect literal newline/carriage return injection (can terminate commands in shell context)
  # Uses printf %b to interpret escape sequences, then checks if value contains them
  if [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing newline injection." >&2
    exit 2
  fi

  # SEC-005 FIX (audit 20260414-194615): Block Unicode direction overrides (U+202A-202E, U+2066-2069).
  # These render text differently than it appears in source, enabling spoofed file paths and
  # homoglyph attacks in elicitation responses that flow into MCP tool calls.
  # Byte sequences: U+202A-202E = 0xE2 0x80 0xAA-AE; U+2066-2069 = 0xE2 0x81 0xA6-A9.
  if printf '%s' "$value" | LC_ALL=C grep -qE $'\xe2\x80[\xaa-\xae]|\xe2\x81[\xa6-\xa9]'; then
    echo "SEC-ELICIT-001: Blocked elicitation response containing Unicode direction override. Value rejected for security." >&2
    exit 2
  fi

done <<< "$RESPONSE_VALUES"

# ── All checks passed — allow response ──
# Output hookEventName as required by CLAUDE.md hook JSON output spec.
jq -n '{"hookSpecificOutput": {"hookEventName": "ElicitationResult"}}'
exit 0
