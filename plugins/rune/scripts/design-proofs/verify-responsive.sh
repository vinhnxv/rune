#!/usr/bin/env bash
# scripts/design-proofs/verify-responsive.sh
# Design proof: responsive_check — DOM inspection at defined viewport breakpoints.
# Gracefully degrades to INCONCLUSIVE (F4) when agent-browser is not available.
#
# Input (JSON via $1): {"criterion_id":"DES-001","target":"src/components/Button","breakpoints":"375,768,1024,1440","checks":"no_overflow,no_truncation,layout_adapts"}
# Output (JSON to stdout): {"criterion_id":"...","result":"PASS|FAIL|INCONCLUSIVE","evidence":"...","timestamp":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Parse input ---
INPUT="${1:?Usage: verify-responsive.sh <json-input>}"
CRITERION_ID="$(printf '%s' "$INPUT" | jq -r '.criterion_id // "unknown"')"
TARGET="$(printf '%s' "$INPUT" | jq -r '.target // ""')"
BREAKPOINTS_CSV="$(printf '%s' "$INPUT" | jq -r '.breakpoints // "375,768,1024,1440"')"
CHECKS_CSV="$(printf '%s' "$INPUT" | jq -r '.checks // "no_overflow,no_truncation,layout_adapts"')"
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
  emit_result "FAIL" "Path traversal blocked" "F8"
  exit 0
fi

# --- Check agent-browser availability ---
# responsive_check requires browser automation for DOM inspection at breakpoints
BROWSER_AVAILABLE=false

if command -v agent-browser &>/dev/null; then
  BROWSER_AVAILABLE=true
fi

# Fallback: check for playwright/puppeteer which can do viewport manipulation
if [[ "$BROWSER_AVAILABLE" == "false" ]] && command -v npx &>/dev/null; then
  if [[ -f "package.json" ]]; then
    if jq -e '.dependencies["@playwright/test"] // .devDependencies["@playwright/test"] // .dependencies["playwright"] // .devDependencies["playwright"] // .dependencies["puppeteer"] // .devDependencies["puppeteer"]' package.json >/dev/null 2>&1; then
      BROWSER_AVAILABLE=true
    fi
  fi
fi

if [[ "$BROWSER_AVAILABLE" == "false" ]]; then
  emit_result "INCONCLUSIVE" "agent-browser not available: neither agent-browser CLI nor playwright/puppeteer found" "F4"
  exit 0
fi

# --- Check Storybook server ---
sb_port="${STORYBOOK_PORT:-6006}"
if ! curl -sf "http://localhost:${sb_port}" > /dev/null 2>&1; then
  emit_result "INCONCLUSIVE" "Storybook server not running on port ${sb_port} (required for responsive viewport inspection)" "F4"
  exit 0
fi

# --- Parse breakpoints and checks ---
IFS=',' read -ra breakpoints <<< "$BREAKPOINTS_CSV"
IFS=',' read -ra checks <<< "$CHECKS_CSV"

COMPONENT_NAME="$(basename "$TARGET" | sed 's/\.[^.]*$//')"
story_url="http://localhost:${sb_port}/iframe.html?id=${COMPONENT_NAME}--default"

# --- Run responsive checks at each breakpoint ---
failures=()
passed_count=0
total_checks=0

for bp in "${breakpoints[@]}"; do
  bp="$(echo "$bp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$bp" ]] && continue

  for check in "${checks[@]}"; do
    check="$(echo "$check" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$check" ]] && continue
    total_checks=$((total_checks + 1))

    # Run agent-browser DOM inspection at this breakpoint
    if timeout 30 agent-browser inspect \
      --url "$story_url" \
      --viewport-width "$bp" \
      --check "$check" >/dev/null 2>&1; then
      passed_count=$((passed_count + 1))
    else
      failures+=("${check}@${bp}px")
    fi
  done
done

# --- Emit result ---
failure_count=${#failures[@]}

if [[ $failure_count -eq 0 ]]; then
  emit_result "PASS" "Responsive checks passed for ${TARGET} (${passed_count}/${total_checks} checks across ${#breakpoints[@]} breakpoints)"
else
  failure_detail=""
  shown=0
  for f in "${failures[@]}"; do
    if [[ $shown -ge 5 ]]; then
      failure_detail="${failure_detail}, +$((failure_count - 5)) more"
      break
    fi
    if [[ -n "$failure_detail" ]]; then
      failure_detail="${failure_detail}, $f"
    else
      failure_detail="$f"
    fi
    shown=$((shown + 1))
  done
  emit_result "FAIL" "Responsive check failures for ${TARGET}: ${failure_detail} (${passed_count}/${total_checks} passed)" "F3"
fi

exit 0
