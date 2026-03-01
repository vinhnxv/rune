#!/bin/bash
# scripts/lib/sensitive-patterns.sh
# Reusable sensitive data filter library — 16 regex patterns for API keys,
# passwords, tokens, connection strings, SSH keys.
#
# USAGE: Source this file from caller scripts.
#   source "${SCRIPT_DIR}/lib/sensitive-patterns.sh"
#
# Exports:
#   SENSITIVE_PATTERNS  — associative array of label → regex
#   rune_strip_sensitive [max_chars]  — Filter stdin, write clean text to stdout
#
# All functions read from stdin, write to stdout.
# Compatible: macOS bash 3.2+ / Linux bash 4.0+
#
# NOTE: Do NOT set `set -euo pipefail` here — caller's responsibility.

# ── SENSITIVE_PATTERNS ──
# 16 regex patterns for common sensitive data.
# Order: most specific first (API keys with clear prefix, then generic tokens).
# SEC-PAT-001: Patterns are designed for grep -E / sed -E compatibility.
#
# Escape note: These are POSIX ERE patterns for use with `grep -E` or `sed -E`.
declare -A SENSITIVE_PATTERNS 2>/dev/null || true

# Only populate if array declaration succeeded (bash 4+)
# For bash 3 (macOS default), we use positional logic in rune_strip_sensitive
_SPAT_LIST=(
  # 1. OpenAI API keys: sk-[A-Za-z0-9]{20,}
  "openai_key:sk-[A-Za-z0-9_-]{20,}"
  # 2. Anthropic API keys: sk-ant-[A-Za-z0-9]{20,}
  "anthropic_key:sk-ant-[A-Za-z0-9_-]{20,}"
  # 3. AWS access key IDs: AKIA[A-Z0-9]{16}
  "aws_access_key:AKIA[A-Z0-9]{16}"
  # 4. AWS secret access keys: 40 base64 chars following known assignment patterns
  "aws_secret:aws[_-]secret[_-]?(access)?[_-]?key[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9/+=]{40}['\"]?"
  # 5. Generic Bearer tokens (Authorization: Bearer header)
  "bearer_token:Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}"
  # 6. GitHub personal access tokens: ghp_ or github_pat_
  "github_pat:(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}"
  # 7. Private key PEM headers
  "pem_key:-----BEGIN[[:space:]]+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"
  # 8. SSH private key markers
  "ssh_key:-----BEGIN[[:space:]]+OPENSSH PRIVATE KEY-----"
  # 9. Password assignments (common patterns)
  "password_assign:(password|passwd|pwd|secret)[[:space:]]*[=:][[:space:]]*['\"]?[^[:space:]'\"]{8,}"
  # 10. Connection strings with credentials (postgres://, mysql://, mongodb://)
  "db_url:(postgres|mysql|mongodb|redis|amqp)(ql)?://[^:@]+:[^@]+@[a-zA-Z0-9._-]+"
  # 11. Generic API key assignments
  "api_key_assign:(api[_-]?key|apikey|api[_-]?token)[[:space:]]*[=:][[:space:]]*['\"]?[A-Za-z0-9._~+/=-]{20,}"
  # 12. JWT tokens (three base64url segments separated by dots)
  "jwt:eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"
  # 13. Slack tokens: xox[bpas]-
  "slack_token:xox[bpas]-[A-Za-z0-9-]{20,}"
  # 14. Stripe API keys: sk_live_ or sk_test_
  "stripe_key:sk_(live|test)_[A-Za-z0-9]{20,}"
  # 15. Google API keys: AIza[A-Za-z0-9_-]{35}
  "google_api:AIza[A-Za-z0-9_-]{35}"
  # 16. Generic high-entropy tokens (40+ hex chars following = or :)
  "hex_token:[=:][[:space:]]*['\"]?[0-9a-fA-F]{40,}['\"]?"
)

# Populate associative array if supported (bash 4+)
if declare -A _SPAT_TEST 2>/dev/null; then
  for _spat_entry in "${_SPAT_LIST[@]}"; do
    _spat_label="${_spat_entry%%:*}"
    _spat_regex="${_spat_entry#*:}"
    SENSITIVE_PATTERNS["$_spat_label"]="$_spat_regex"
  done
  unset _SPAT_TEST _spat_entry _spat_label _spat_regex
fi

# ── rune_strip_sensitive ──
# Filter sensitive data patterns from stdin using python3.
# Two-pass approach: strip known patterns, then truncate.
#
# Args: $1 = max_chars (default 2000)
# Input: stdin
# Output: stdout (filtered text, with [REDACTED] placeholders)
rune_strip_sensitive() {
  local max_chars="${1:-2000}"
  max_chars=$(( "${max_chars}" + 0 )) 2>/dev/null || max_chars=2000

  local input
  input=$(cat)

  # Build pattern list for python3 inline
  # Use positional list (_SPAT_LIST) for bash 3 compatibility
  local patterns_json="["
  local first=1
  for _spat_entry in "${_SPAT_LIST[@]}"; do
    local _label="${_spat_entry%%:*}"
    local _regex="${_spat_entry#*:}"
    if [[ $first -eq 1 ]]; then
      first=0
    else
      patterns_json+=","
    fi
    # JSON-encode label and regex (escape backslashes and quotes)
    local _jlabel _jregex
    _jlabel=$(printf '%s' "$_label" | sed 's/\\/\\\\/g; s/"/\\"/g')
    _jregex=$(printf '%s' "$_regex" | sed 's/\\/\\\\/g; s/"/\\"/g')
    patterns_json+="{\"label\":\"${_jlabel}\",\"regex\":\"${_jregex}\"}"
  done
  patterns_json+="]"

  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, re, json

max_chars = int(sys.argv[1])
patterns_json = sys.argv[2]
patterns = json.loads(patterns_json)

text = sys.stdin.read()
if len(text) > max_chars:
    text = text[:max_chars]

for pat in patterns:
    label = pat.get("label", "sensitive")
    regex = pat.get("regex", "")
    if not regex:
        continue
    try:
        compiled = re.compile(regex, re.IGNORECASE)
        text = compiled.sub(f"[REDACTED:{label.upper()}]", text)
    except re.error:
        continue

sys.stdout.write(text)
' "$max_chars" "$patterns_json" 2>/dev/null) || {
    # Fail closed — return empty string on python3 failure
    printf ''
    return 1
  }

  printf '%s' "$result"
}
