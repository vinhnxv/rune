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

  # Build pattern list for python3 inline.
  # Use positional list (_SPAT_LIST) for bash 3 compatibility.
  # SEC-001 FIX: Pass patterns via stdin as NUL-delimited label\x01regex pairs
  # instead of hand-rolling JSON in shell. Python parses raw bytes — no shell
  # escaping needed, so special regex chars (backslash, brackets, quotes, etc.)
  # are transmitted safely.
  local patterns_stdin=""
  for _spat_entry in "${_SPAT_LIST[@]}"; do
    local _label="${_spat_entry%%:*}"
    local _regex="${_spat_entry#*:}"
    # Validate label is safe (alphanumeric + underscore only) — BACK-005
    if [[ ! "$_label" =~ ^[A-Za-z0-9_]+$ ]]; then
      continue
    fi
    patterns_stdin+="${_label}"$'\x01'"${_regex}"$'\x00'
  done

  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, re, os

max_chars = int(sys.argv[1])

# Read NUL-delimited "label\x01regex" pairs from fd 3
raw = os.read(3, 1 << 20)
patterns = []
for entry in raw.split(b"\x00"):
    if not entry:
        continue
    sep = entry.find(b"\x01")
    if sep < 0:
        continue
    label = entry[:sep].decode("utf-8", errors="replace")
    regex = entry[sep+1:].decode("utf-8", errors="replace")
    patterns.append((label, regex))

text = sys.stdin.read()
if len(text) > max_chars:
    text = text[:max_chars]

for label, regex in patterns:
    if not regex:
        continue
    try:
        compiled = re.compile(regex, re.IGNORECASE)
        text = compiled.sub(f"[REDACTED:{label.upper()}]", text)
    except re.error:
        continue

sys.stdout.write(text)
' "$max_chars" 3< <(printf '%s' "$patterns_stdin") 2>/dev/null) || {
    # Fail closed — return empty string on python3 failure
    printf ''
    return 1
  }

  printf '%s' "$result"
}
