#!/usr/bin/env bash
# scripts/design-proofs/verify-accessibility.sh
# Design proof: axe_passes — runs axe-core accessibility scan on rendered component.
# Gracefully degrades to INCONCLUSIVE (F4) when axe-core or Storybook unavailable.
#
# Input (JSON via $1): {"criterion_id":"DES-001","target":"src/components/Button","rules":"wcag2aa"}
# Output (JSON to stdout): {"criterion_id":"...","result":"PASS|FAIL|INCONCLUSIVE","evidence":"...","timestamp":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Parse input ---
INPUT="${1:?Usage: verify-accessibility.sh <json-input>}"
CRITERION_ID="$(printf '%s' "$INPUT" | jq -r '.criterion_id // "unknown"')"
TARGET="$(printf '%s' "$INPUT" | jq -r '.target // ""')"
RULES="$(printf '%s' "$INPUT" | jq -r '.rules // "wcag2aa"')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# --- Output helper ---
# QUAL-304: Include dimension field per design-proof-types.md schema
emit_result() {
  local result="$1" evidence="$2" fc="${3:-}" dimension="${4:-accessibility}"
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

# --- Check tool availability ---
# axe-core requires npx and either @axe-core/cli or storybook with addon-a11y
if ! command -v npx &>/dev/null; then
  emit_result "INCONCLUSIVE" "tool not available: npx (required for axe-core)" "F4"
  exit 0
fi

# Check if storybook is installed (needed to render component for scanning)
HAS_STORYBOOK=false
if [[ -f "package.json" ]]; then
  if jq -e '.dependencies["@storybook/react"] // .devDependencies["@storybook/react"] // .dependencies["storybook"] // .devDependencies["storybook"]' package.json >/dev/null 2>&1; then
    HAS_STORYBOOK=true
  fi
fi

if [[ "$HAS_STORYBOOK" == "false" ]]; then
  emit_result "INCONCLUSIVE" "tool not available: storybook (required to render component for axe-core scan)" "F4"
  exit 0
fi

# Check for axe-core CLI or addon
HAS_AXE=false
if jq -e '.dependencies["@axe-core/cli"] // .devDependencies["@axe-core/cli"] // .dependencies["axe-core"] // .devDependencies["axe-core"]' package.json >/dev/null 2>&1; then
  HAS_AXE=true
fi

if [[ "$HAS_AXE" == "false" ]]; then
  emit_result "INCONCLUSIVE" "tool not available: axe-core (not found in package.json dependencies)" "F4"
  exit 0
fi

# --- Run axe-core scan ---
# Use @axe-core/cli if available, targeting the component's storybook URL
COMPONENT_NAME="$(basename "$TARGET")"
AXE_OUTPUT=""
AXE_EXIT=0

# Try running axe via npx with timeout
# QUAL-302/SEC-002: Use tr for lowercase (Bash 3.2 compatible, replaces ${var,,})
COMPONENT_NAME_LOWER="$(printf '%s' "$COMPONENT_NAME" | tr '[:upper:]' '[:lower:]')"
# Guard: timeout may not be available on macOS without coreutils
if command -v timeout &>/dev/null; then
  AXE_OUTPUT="$(timeout 60 npx @axe-core/cli --tags "$RULES" --exit "http://localhost:6006/iframe.html?id=${COMPONENT_NAME_LOWER}--default" 2>&1)" || AXE_EXIT=$?
else
  AXE_OUTPUT="$(npx @axe-core/cli --tags "$RULES" --exit "http://localhost:6006/iframe.html?id=${COMPONENT_NAME_LOWER}--default" 2>&1)" || AXE_EXIT=$?
fi

if [[ $AXE_EXIT -eq 124 ]]; then
  emit_result "INCONCLUSIVE" "axe-core scan timed out (60s)" "F4"
  exit 0
fi

# Parse axe output for violations
if [[ $AXE_EXIT -eq 0 ]]; then
  emit_result "PASS" "axe-core scan passed ($RULES rules) for $COMPONENT_NAME: 0 violations"
else
  # Count violations from output
  VIOLATION_COUNT="$(printf '%s' "$AXE_OUTPUT" | grep -c 'Violation' 2>/dev/null || echo "unknown")"
  emit_result "FAIL" "axe-core scan failed ($RULES rules) for $COMPONENT_NAME: $VIOLATION_COUNT violation(s). ${AXE_OUTPUT:0:500}" "F3"
fi
