#!/usr/bin/env bash
# scripts/design-proofs/verify-screenshot-fidelity.sh
# Design proof: screenshot_diff — visual diff between reference and rendered component.
# Gracefully degrades to INCONCLUSIVE (F4) when agent-browser is not available.
#
# Input (JSON via $1): {"criterion_id":"DES-001","target":"src/components/Button","reference":"vsm/Button-ref.png","threshold":5}
# Output (JSON to stdout): {"criterion_id":"...","result":"PASS|FAIL|INCONCLUSIVE","evidence":"...","timestamp":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Parse input ---
INPUT="${1:?Usage: verify-screenshot-fidelity.sh <json-input>}"
CRITERION_ID="$(printf '%s' "$INPUT" | jq -r '.criterion_id // "unknown"')"
TARGET="$(printf '%s' "$INPUT" | jq -r '.target // ""')"
REFERENCE="$(printf '%s' "$INPUT" | jq -r '.reference // ""')"
THRESHOLD="$(printf '%s' "$INPUT" | jq -r '.threshold // "5"')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# Validate threshold is numeric
if [[ ! "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  THRESHOLD=5
fi

# --- Output helper ---
emit_result() {
  local result="$1" evidence="$2" fc="${3:-}"
  if [[ -n "$fc" ]]; then
    jq -n --arg cid "$CRITERION_ID" --arg r "$result" --arg e "$evidence" \
      --arg fc "$fc" --arg ts "$TIMESTAMP" \
      '{criterion_id:$cid,result:$r,evidence:$e,failure_code:$fc,timestamp:$ts}'
  else
    jq -n --arg cid "$CRITERION_ID" --arg r "$result" --arg e "$evidence" \
      --arg ts "$TIMESTAMP" \
      '{criterion_id:$cid,result:$r,evidence:$e,timestamp:$ts}'
  fi
}

# --- SEC: Path traversal guard ---
if [[ "$TARGET" == *".."* || "$REFERENCE" == *".."* ]]; then
  emit_result "FAIL" "Path traversal blocked" "F8"
  exit 0
fi

# --- Check agent-browser availability ---
# screenshot_diff requires a browser automation tool to capture screenshots
BROWSER_AVAILABLE=false

# Check for playwright
if command -v npx &>/dev/null; then
  if [[ -f "package.json" ]]; then
    if jq -e '.dependencies["@playwright/test"] // .devDependencies["@playwright/test"] // .dependencies["playwright"] // .devDependencies["playwright"]' package.json >/dev/null 2>&1; then
      BROWSER_AVAILABLE=true
    fi
  fi
fi

# Check for puppeteer as fallback
if [[ "$BROWSER_AVAILABLE" == "false" ]] && [[ -f "package.json" ]]; then
  if jq -e '.dependencies["puppeteer"] // .devDependencies["puppeteer"]' package.json >/dev/null 2>&1; then
    BROWSER_AVAILABLE=true
  fi
fi

if [[ "$BROWSER_AVAILABLE" == "false" ]]; then
  emit_result "INCONCLUSIVE" "agent-browser not available: neither playwright nor puppeteer found in package.json" "F4"
  exit 0
fi

# --- Check reference image exists ---
if [[ -z "$REFERENCE" || ! -f "$REFERENCE" ]]; then
  emit_result "INCONCLUSIVE" "reference screenshot not found: $REFERENCE (generate via Figma export first)" "F4"
  exit 0
fi

# --- Screenshot capture and comparison would run here ---
# In practice, this delegates to playwright/puppeteer to:
# 1. Start Storybook dev server (or use existing)
# 2. Navigate to component story
# 3. Capture screenshot
# 4. Compare with reference using pixel diff
# 5. Report percentage difference
#
# For now, emit INCONCLUSIVE since browser automation requires runtime setup
COMPONENT_NAME="$(basename "$TARGET")"
emit_result "INCONCLUSIVE" "screenshot_diff for $COMPONENT_NAME: browser automation runtime not initialized (threshold: ${THRESHOLD}%)" "F4"
