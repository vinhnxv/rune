#!/usr/bin/env bash
# scripts/design-proofs/verify-story-coverage.sh
# Design proof: story_exists — checks Storybook story files exist for components and variants.
#
# Input (JSON via $1): {"criterion_id":"DES-001","target":"src/components/Button","variants":["primary","secondary"]}
# Output (JSON to stdout): {"criterion_id":"...","result":"PASS|FAIL","evidence":"...","timestamp":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Parse input ---
INPUT="${1:?Usage: verify-story-coverage.sh <json-input>}"
CRITERION_ID="$(printf '%s' "$INPUT" | jq -r '.criterion_id // "unknown"')"
TARGET="$(printf '%s' "$INPUT" | jq -r '.target // ""')"
VARIANTS_JSON="$(printf '%s' "$INPUT" | jq -r '.variants // "[]"')"
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

# --- Find story file ---
STORY_FILE=""
# Search for story files matching component name
COMPONENT_NAME="$(basename "$TARGET")"
while IFS= read -r -d '' sf; do
  STORY_FILE="$sf"
  break
done < <(find "$(dirname "$TARGET")" -maxdepth 2 -type f \( -name "${COMPONENT_NAME}.stories.tsx" -o -name "${COMPONENT_NAME}.stories.jsx" -o -name "${COMPONENT_NAME}.stories.ts" -o -name "${COMPONENT_NAME}.stories.js" \) -print0 2>/dev/null)

if [[ -z "$STORY_FILE" ]]; then
  emit_result "FAIL" "No story file found for component: $COMPONENT_NAME (searched $(dirname "$TARGET"))" "F3"
  exit 0
fi

# --- Check variant exports ---
MISSING_VARIANTS=()
FOUND_VARIANTS=()
while IFS= read -r variant; do
  [[ -z "$variant" ]] && continue
  # Case-insensitive search for exported variant (export const Primary, export const Disabled, etc.)
  if grep -qiE "export\s+(const|function)\s+${variant}" "$STORY_FILE" 2>/dev/null; then
    FOUND_VARIANTS+=("$variant")
  else
    MISSING_VARIANTS+=("$variant")
  fi
done < <(printf '%s' "$VARIANTS_JSON" | jq -r '.[]' 2>/dev/null || true)

# --- Emit result ---
TOTAL_VARIANTS=$((${#FOUND_VARIANTS[@]} + ${#MISSING_VARIANTS[@]}))
if [[ ${#MISSING_VARIANTS[@]} -eq 0 ]]; then
  emit_result "PASS" "Story file exists ($STORY_FILE) with all $TOTAL_VARIANTS variant(s) exported"
else
  MISSING_LIST="$(printf '%s, ' "${MISSING_VARIANTS[@]}")"
  emit_result "FAIL" "Story file $STORY_FILE missing variant exports: ${MISSING_LIST%, } (found ${#FOUND_VARIANTS[@]}/$TOTAL_VARIANTS)" "F3"
fi
