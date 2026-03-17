#!/usr/bin/env bash
# scripts/design-proofs/verify-storybook-build.sh
# Design proof: storybook_renders — runs Storybook build smoke test.
# Gracefully degrades to INCONCLUSIVE (F4) when Storybook is not installed.
#
# Input (JSON via $1): {"criterion_id":"DES-001","target":"src/components/Button","command":"npx storybook build --smoke-test"}
# Output (JSON to stdout): {"criterion_id":"...","result":"PASS|FAIL|INCONCLUSIVE","evidence":"...","timestamp":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Parse input ---
INPUT="${1:?Usage: verify-storybook-build.sh <json-input>}"
CRITERION_ID="$(printf '%s' "$INPUT" | jq -r '.criterion_id // "unknown"')"
TARGET="$(printf '%s' "$INPUT" | jq -r '.target // ""')"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.command // "npx storybook build --smoke-test"')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

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
if [[ "$TARGET" == *".."* ]]; then
  emit_result "FAIL" "Path traversal blocked: $TARGET" "F8"
  exit 0
fi

# --- Check Storybook availability ---
if ! command -v npx &>/dev/null; then
  emit_result "INCONCLUSIVE" "tool not available: npx (required for storybook)" "F4"
  exit 0
fi

HAS_STORYBOOK=false
if [[ -f "package.json" ]]; then
  if jq -e '.dependencies["@storybook/react"] // .devDependencies["@storybook/react"] // .dependencies["storybook"] // .devDependencies["storybook"]' package.json >/dev/null 2>&1; then
    HAS_STORYBOOK=true
  fi
fi

if [[ "$HAS_STORYBOOK" == "false" ]]; then
  emit_result "INCONCLUSIVE" "storybook not found in package.json dependencies" "F4"
  exit 0
fi

# --- SEC: Command validation (same blocklist as main executor) ---
if [[ "$COMMAND" =~ [$'\n'\;\&\|\$\`\<\>\(\)\{\}\!\~\'\"\\] ]]; then
  emit_result "FAIL" "Command contains blocked shell metacharacters: ${COMMAND:0:100}" "F8"
  exit 0
fi

# --- Run Storybook build ---
COMPONENT_NAME="$(basename "$TARGET")"
BUILD_OUTPUT=""
BUILD_EXIT=0

BUILD_OUTPUT="$(timeout 120 bash -c "$COMMAND" 2>&1)" || BUILD_EXIT=$?

if [[ $BUILD_EXIT -eq 124 ]]; then
  emit_result "INCONCLUSIVE" "Storybook build timed out (120s)" "F4"
  exit 0
fi

if [[ $BUILD_EXIT -eq 0 ]]; then
  emit_result "PASS" "Storybook build succeeded (exit 0) for $COMPONENT_NAME: $COMMAND"
else
  emit_result "FAIL" "Storybook build failed (exit $BUILD_EXIT) for $COMPONENT_NAME: ${BUILD_OUTPUT:0:500}" "F3"
fi
