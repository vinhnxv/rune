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
# Requires: python3 (on failure: sanitize functions return empty string with exit 1)
# Compatible: macOS bash 3.2+ / Linux bash 4.0+
#
# NOTE: Do NOT set `set -euo pipefail` here — caller's responsibility.
#
# VEIL-002 (RESOLVED): This library is sourced by advise-mcp-untrusted.sh for
# suspicious pattern detection in MCP output (PostToolUse advisory enhancement).
# To integrate in other scripts: `source "${SCRIPT_DIR}/lib/sanitize-text.sh"`
# and pipe stdin through sanitize_untrusted_text or sanitize_plan_content.
#
# QUAL-003: sanitize_untrusted_text and sanitize_plan_content share ~90% of the
# same Python inline code in their sanitize_pass() helpers.  The duplication is
# intentional for now (both functions are shell-embedded Python strings, so
# extracting a shared .py helper would require a separate file dependency).
# ── SYNC NOTE ── Any change to the sanitize_pass() body in one function MUST
# be mirrored in the other.  The only intentional difference is the YAML
# frontmatter strip line present only in sanitize_plan_content.

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

  # P1-FE-002: Read from stdin (SEC-2: 1MB cap to prevent memory exhaustion)
  local input
  input=$(head -c 1048576)

  # P1-FE-005: stderr suppression on python3, P1-FE-006: passthrough on failure
  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, re, html

def sanitize_pass(text):
    # SEC-001: html.unescape FIRST so all regex patterns operate on decoded text.
    # Double-encoded payloads (e.g. &lt;!-- decoding to <!--) are neutralised here
    # before any stripping pass, preventing bypass via entity encoding.
    text = html.unescape(text)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"\x60\x60\x60[^\x60]*\x60\x60\x60", "", text, flags=re.DOTALL)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[\u200b-\u200f\ufeff\u00ad\ufe00-\ufe0f]", "", text)
    text = re.sub(r"[\u202a-\u202e\u2066-\u2069]", "", text)
    text = re.sub(r"[\U000e0000-\U000e007f]", "", text)
    # BACK-002: Strip mathematical alphanumeric symbols (U+1D400-U+1D7FF).
    # These visually resemble Latin letters/digits (e.g. 𝐀 ≈ A) and can
    # smuggle homoglyph payloads past Latin-only script detection.
    text = re.sub(r"[\U0001D400-\U0001D7FF]", "", text)
    return text

text = sys.stdin.read()
max_chars = int(sys.argv[1])
if len(text) > max_chars:
    text = text[:max_chars]
text = sanitize_pass(text)
text = sanitize_pass(text)
sys.stdout.write(text)
' "$max_chars" 2>/dev/null) || {
    # VEIL-001: On python3 failure, fail closed — return empty string rather than
    # passing through raw content.  A [UNSANITIZED] prefix gave callers false
    # confidence while still exposing unsanitised input to downstream consumers.
    printf ''
    return 1
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

  # P1-FE-002: Read from stdin (SEC-2: 1MB cap to prevent memory exhaustion)
  local input
  input=$(head -c 1048576)

  # P1-FE-005: stderr suppression on python3, P1-FE-006: passthrough on failure
  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, re, html, unicodedata

def sanitize_pass(text):
    # SEC-001: html.unescape FIRST so all regex patterns operate on decoded text.
    # Double-encoded payloads (e.g. &lt;!-- decoding to <!--) are neutralised here
    # before any stripping pass, preventing bypass via entity encoding.
    text = html.unescape(text)
    text = re.sub(r"^---\n.*?\n---\n?", "", text, count=1, flags=re.DOTALL)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"\x60\x60\x60[^\x60]*\x60\x60\x60", "", text, flags=re.DOTALL)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[\u200b-\u200f\ufeff\u00ad\ufe00-\ufe0f]", "", text)
    text = re.sub(r"[\u202a-\u202e\u2066-\u2069]", "", text)
    text = re.sub(r"[\U000e0000-\U000e007f]", "", text)
    # BACK-002: Strip mathematical alphanumeric symbols (U+1D400-U+1D7FF).
    # These visually resemble Latin letters/digits (e.g. 𝐀 ≈ A) and can
    # smuggle homoglyph payloads past Latin-only script detection.
    text = re.sub(r"[\U0001D400-\U0001D7FF]", "", text)
    return text

text = sys.stdin.read()
max_chars = int(sys.argv[1])
if len(text) > max_chars:
    text = text[:max_chars]
text = sanitize_pass(text)
text = sanitize_pass(text)
text = unicodedata.normalize("NFC", text)
sys.stdout.write(text)
' "$max_chars" 2>/dev/null) || {
    # VEIL-001: On python3 failure, fail closed — return empty string rather than
    # passing through raw content.  A [UNSANITIZED] prefix gave callers false
    # confidence while still exposing unsanitised input to downstream consumers.
    printf ''
    return 1
  }

  printf '%s' "$result"
}

# ── normalize_unicode_nfc ──
# NFC-normalize text via python3 unicodedata.normalize.
#
# Input: stdin (P1-FE-002)
# Output: stdout (NFC-normalized text)
normalize_unicode_nfc() {
  # P1-FE-002: Read from stdin (SEC-2: 1MB cap to prevent memory exhaustion)
  local input
  input=$(head -c 1048576)

  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, unicodedata
text = sys.stdin.read()
sys.stdout.write(unicodedata.normalize("NFC", text))
' 2>/dev/null) || {
    # SEC-002 FIX: Fail-closed to match VEIL-001 mandate (consistent with sanitize_untrusted_text)
    printf ''
    return 1
  }

  printf '%s' "$result"
}

# ── detect_homoglyphs_tier_ab ──
# Mixed-script detection: flags text containing both Latin AND Cyrillic or Greek characters.
# Returns JSON: {"detected": true/false, "details": [...]}
#
# SEC-002 TIER LIMITATION: This function is Tier A/B only.
#   Covered scripts : Latin (baseline), Cyrillic, Greek
#   NOT covered     : Arabic, Armenian, Georgian, Hebrew, Devanagari, CJK, and all
#                     other scripts that contain visually similar characters to Latin.
# Callers requiring broader coverage must implement Tier C+ detection separately.
#
# Input: stdin
# Output: stdout (JSON)
detect_homoglyphs_tier_ab() {
  # P1-FE-002: Read from stdin (SEC-2: 1MB cap to prevent memory exhaustion)
  local input
  input=$(head -c 1048576)

  local result
  result=$(printf '%s' "$input" | python3 -c '
import sys, unicodedata, json

text = sys.stdin.read()

# BACK-006: Strip variation selectors (U+FE00-U+FE0F) before analysis.
# These invisible codepoints can be used to cloak homoglyphs from detection.
import re
text = re.sub(r"[\uFE00-\uFE0F]", "", text)

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
    # P1-FE-006: On python3 failure, fail closed — assume homoglyphs present
    printf '{"detected":true,"details":[],"error":"python3_unavailable"}'
    return 0
  }

  # SEC-008: Validate that $result is a non-empty, valid-looking JSON object
  # before printing.  An empty result (e.g. python3 crash without exit code)
  # would silently emit nothing, causing callers to see a false negative.
  if [[ -z "$result" ]]; then
    printf '{"detected":false,"details":[],"error":"empty_result"}'
    return 0
  fi

  printf '%s' "$result"
}
