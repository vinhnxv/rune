#!/usr/bin/env bash
# scripts/design-proofs/verify-design-tokens.sh
# Design proof: token_scan — scans component files for hardcoded visual values.
# Verifies implementation uses design tokens instead of raw hex colors, px values, etc.
#
# Input (JSON via $1): {"criterion_id":"DES-001","target":"src/Button.tsx","token_source":"vsm/Button.json"}
# Output (JSON to stdout): {"criterion_id":"...","result":"PASS|FAIL","evidence":"...","timestamp":"...","failure_code":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Parse input ---
INPUT="${1:?Usage: verify-design-tokens.sh <json-input>}"
CRITERION_ID="$(printf '%s' "$INPUT" | jq -r '.criterion_id // "unknown"')"
TARGET="$(printf '%s' "$INPUT" | jq -r '.target // ""')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# --- Output helper ---
# QUAL-304: Include dimension field per design-proof-types.md schema
emit_result() {
  local result="$1" evidence="$2" fc="${3:-}" dimension="${4:-color}"
  if [[ -n "$fc" ]]; then
    jq -n --arg cid "$CRITERION_ID" --arg r "$result" --arg e "$evidence" \
      --arg fc "$fc" --arg ts "$TIMESTAMP" --arg dim "$dimension" \
      '{criterion_id:$cid,result:$r,evidence:$e,failure_code:$fc,dimension:$dim,timestamp:$ts}'
  else
    jq -n --arg cid "$CRITERION_ID" --arg r "$result" --arg e "$evidence" \
      --arg ts "$TIMESTAMP" --arg dim "$dimension" \
      '{criterion_id:$cid,result:$r,evidence:$e,dimension:$dim,timestamp:$ts}'
  fi
}

# --- SEC: Path traversal guard ---
if [[ "$TARGET" == *".."* ]]; then
  emit_result "FAIL" "Path traversal blocked: $TARGET" "F8"
  exit 0
fi

# --- Validate target exists ---
if [[ -z "$TARGET" || ! -f "$TARGET" ]]; then
  emit_result "FAIL" "Target file not found: $TARGET" "F3"
  exit 0
fi

# --- Scan for hardcoded visual values ---
VIOLATIONS=()
LINE_COUNT=0

while IFS= read -r _line; do
  LINE_COUNT=$((LINE_COUNT + 1))
done < "$TARGET"

# Scan for hex colors outside of token references
HEX_VIOLATIONS=()
while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  # Exclude lines with var(--, theme(, tokens., CSS custom property declarations
  if printf '%s' "$match" | grep -qE 'var\(--|theme\(|tokens\.|--[a-zA-Z]' 2>/dev/null; then
    continue
  fi
  # Exclude SVG path data and viewBox
  if printf '%s' "$match" | grep -qE 'viewBox|d="M|stroke-width' 2>/dev/null; then
    continue
  fi
  # Exclude comments
  if printf '%s' "$match" | grep -qE '^\s*(//|/\*|\*|#)' 2>/dev/null; then
    continue
  fi
  # Exclude import/require paths
  if printf '%s' "$match" | grep -qE "import |require\(" 2>/dev/null; then
    continue
  fi
  HEX_VIOLATIONS+=("$match")
done < <(grep -nE '#[0-9a-fA-F]{3,8}\b' "$TARGET" 2>/dev/null || true)

if [[ ${#HEX_VIOLATIONS[@]} -gt 0 ]]; then
  VIOLATIONS+=("Hardcoded hex colors: ${#HEX_VIOLATIONS[@]} violation(s)")
  for v in "${HEX_VIOLATIONS[@]:0:3}"; do
    VIOLATIONS+=("  $v")
  done
fi

# --- Emit result ---
if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  emit_result "PASS" "No hardcoded hex colors found in $TARGET (scanned $LINE_COUNT lines, 0 violations)"
else
  VIOLATION_TEXT="$(printf '%s; ' "${VIOLATIONS[@]}")"
  emit_result "FAIL" "Hardcoded values detected in $TARGET: $VIOLATION_TEXT" "F3"
fi
