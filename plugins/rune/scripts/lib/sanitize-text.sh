#!/bin/bash
# scripts/lib/sanitize-text.sh
# Sanitization library for untrusted text input (prompt injection defense).
#
# USAGE: Source this file from caller scripts.
#   source "${SCRIPT_DIR}/lib/sanitize-text.sh"
#
# Exports:
#   sanitize_untrusted_text [max_chars]  — Strip dangerous patterns from stdin
#   sanitize_plan_content [max_chars]    — Superset: also strips YAML frontmatter + NFC normalize
#   normalize_unicode_nfc                — NFC-normalize stdin via python3
#   detect_homoglyphs_tier_ab            — Mixed-script detection (Latin+Cyrillic/Greek) from stdin
#
# All functions read from stdin, write to stdout.
# Requires: python3 (fallback: passthrough with [UNSANITIZED] prefix)
# Compatible: macOS bash 3.2+ / Linux bash 4.0+
#
# NOTE: Do NOT set `set -euo pipefail` here — caller's responsibility.

# ── sanitize_untrusted_text ──
# Strip HTML comments, code fences, image syntax, headings, zero-width chars,
# Unicode directional overrides, and HTML entities from stdin.
# Two-pass sanitization for nested/encoded patterns.
#
# Args: $1 = max_chars (default 2000)
# Input: stdin
# Output: stdout (sanitized text)
sanitize_untrusted_text() {
  local max_chars="${1:-2000}"
  # P1-FE-001: Quote max_chars in arithmetic to prevent injection
  max_chars=$(( "${max_chars}" + 0 )) 2>/dev/null || max_chars=2000

  # P1-FE-002: Read from stdin
  local input
  input=$(cat)

  # P1-FE-005: stderr suppression on python3, P1-FE-006: passthrough on failure
  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, re, html

def sanitize_pass(text):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"\x60\x60\x60[^\x60]*\x60\x60\x60", "", text, flags=re.DOTALL)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[\u200b\u200c\u200d\ufeff\u00ad]", "", text)
    text = re.sub(r"[\u202a-\u202e\u2066-\u2069]", "", text)
    text = html.unescape(text)
    return text

text = sys.stdin.read()
text = sanitize_pass(text)
text = sanitize_pass(text)
max_chars = int(sys.argv[1])
if len(text) > max_chars:
    text = text[:max_chars]
sys.stdout.write(text)
' "$max_chars" 2>/dev/null) || {
    # P1-FE-006: On python3 failure, passthrough with [UNSANITIZED] prefix
    local truncated
    truncated=$(printf '%s' "$input" | head -c "$(( "${max_chars}" + 0 ))" 2>/dev/null || printf '%s' "$input")
    printf '[UNSANITIZED] %s' "$truncated"
    return 0
  }

  printf '%s' "$result"
}

# ── sanitize_plan_content ──
# Superset of sanitize_untrusted_text — also strips YAML frontmatter markers
# and applies NFC normalization (P1-FE-003).
#
# Args: $1 = max_chars (default 4000)
# Input: stdin
# Output: stdout (sanitized + NFC-normalized text)
sanitize_plan_content() {
  local max_chars="${1:-4000}"
  # P1-FE-001: Quote max_chars in arithmetic to prevent injection
  max_chars=$(( "${max_chars}" + 0 )) 2>/dev/null || max_chars=4000

  # P1-FE-002: Read from stdin
  local input
  input=$(cat)

  # P1-FE-005: stderr suppression on python3, P1-FE-006: passthrough on failure
  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, re, html, unicodedata

def sanitize_pass(text):
    text = re.sub(r"^---\n.*?\n---\n?", "", text, count=1, flags=re.DOTALL)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"\x60\x60\x60[^\x60]*\x60\x60\x60", "", text, flags=re.DOTALL)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[\u200b\u200c\u200d\ufeff\u00ad]", "", text)
    text = re.sub(r"[\u202a-\u202e\u2066-\u2069]", "", text)
    text = html.unescape(text)
    return text

text = sys.stdin.read()
text = sanitize_pass(text)
text = sanitize_pass(text)
text = unicodedata.normalize("NFC", text)
max_chars = int(sys.argv[1])
if len(text) > max_chars:
    text = text[:max_chars]
sys.stdout.write(text)
' "$max_chars" 2>/dev/null) || {
    # P1-FE-006: On python3 failure, passthrough with [UNSANITIZED] prefix
    local truncated
    truncated=$(printf '%s' "$input" | head -c "$(( "${max_chars}" + 0 ))" 2>/dev/null || printf '%s' "$input")
    printf '[UNSANITIZED] %s' "$truncated"
    return 0
  }

  printf '%s' "$result"
}

# ── normalize_unicode_nfc ──
# NFC-normalize text via python3 unicodedata.normalize.
#
# Input: stdin (P1-FE-002)
# Output: stdout (NFC-normalized text)
normalize_unicode_nfc() {
  # P1-FE-002: Read from stdin
  local input
  input=$(cat)

  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, unicodedata
text = sys.stdin.read()
sys.stdout.write(unicodedata.normalize("NFC", text))
' 2>/dev/null) || {
    # P1-FE-006: On python3 failure, passthrough with [UNSANITIZED] prefix
    printf '[UNSANITIZED] %s' "$input"
    return 0
  }

  printf '%s' "$result"
}

# ── detect_homoglyphs_tier_ab ──
# Mixed-script detection: flags text containing both Latin AND Cyrillic or Greek characters.
# Returns JSON: {"detected": true/false, "details": [...]}
#
# Input: stdin
# Output: stdout (JSON)
detect_homoglyphs_tier_ab() {
  # P1-FE-002: Read from stdin
  local input
  input=$(cat)

  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, unicodedata, json

text = sys.stdin.read()

scripts_found = set()
details = []

for ch in text:
    if not ch.isalpha():
        continue
    try:
        name = unicodedata.name(ch, "")
    except ValueError:
        continue
    name_upper = name.upper()
    if "LATIN" in name_upper:
        scripts_found.add("Latin")
    elif "CYRILLIC" in name_upper:
        scripts_found.add("Cyrillic")
        details.append({"char": ch, "codepoint": "U+{:04X}".format(ord(ch)), "script": "Cyrillic", "name": name})
    elif "GREEK" in name_upper:
        scripts_found.add("Greek")
        details.append({"char": ch, "codepoint": "U+{:04X}".format(ord(ch)), "script": "Greek", "name": name})

detected = "Latin" in scripts_found and bool(scripts_found & {"Cyrillic", "Greek"})

result = {"detected": detected, "details": details}
json.dump(result, sys.stdout)
' 2>/dev/null) || {
    # P1-FE-006: On python3 failure, return safe default
    printf '{"detected":false,"details":[],"error":"python3_unavailable"}'
    return 0
  }

  printf '%s' "$result"
}
