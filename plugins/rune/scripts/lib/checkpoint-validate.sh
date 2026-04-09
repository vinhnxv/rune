#!/usr/bin/env bash
# checkpoint-validate.sh — Checkpoint JSON validation with duplicate key detection
#
# Validates a checkpoint.json file for:
#   CKPT-VAL-001: Valid JSON syntax
#   CKPT-VAL-002: No duplicate top-level keys
#   CKPT-VAL-003: Required fields present (id, plan_file, schema_version, phases)
#   CKPT-VAL-004: phase_sequence is a single value (not duplicated)
#   CKPT-VAL-005: All phase statuses are valid
#   CKPT-VAL-006: No orphaned top-level fields (warns on unknown keys)
#   CKPT-VAL-007: schema_version is numeric and within range
#
# Usage:
#   checkpoint-validate.sh <checkpoint-path> [--fix]
#
# Options:
#   --fix    Auto-fix duplicate keys by re-serializing through jq
#            (jq merge deduplicates, keeping last value — same as most parsers)
#
# Exit codes:
#   0 = valid (or fixed with --fix)
#   1 = invalid (errors found)
#   2 = file not found or not readable
#   3 = jq not available
#
# Output: JSON report to stdout with findings array
#
# Dependencies: jq (required), python3 (optional, for duplicate key detection)
# Platform: macOS + Linux

set -euo pipefail

CHECKPOINT_PATH="${1:-}"
FIX_MODE=false
if [[ "${2:-}" == "--fix" ]]; then
  FIX_MODE=true
fi

if [[ -z "$CHECKPOINT_PATH" ]]; then
  echo "Usage: checkpoint-validate.sh <checkpoint-path> [--fix]" >&2
  exit 2
fi

if [[ ! -f "$CHECKPOINT_PATH" ]]; then
  echo "ERROR: file not found: $CHECKPOINT_PATH" >&2
  exit 2
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq required" >&2
  exit 3
fi

# ── Findings accumulator ──
ERRORS=0
WARNINGS=0
FINDINGS=""

_add_finding() {
  local severity="$1" code="$2" msg="$3"
  if [[ -n "$FINDINGS" ]]; then
    FINDINGS="${FINDINGS},"
  fi
  FINDINGS="${FINDINGS}{\"severity\":\"${severity}\",\"code\":\"${code}\",\"message\":$(echo "$msg" | jq -Rs '.')}"
  if [[ "$severity" == "error" ]]; then
    ERRORS=$((ERRORS + 1))
  else
    WARNINGS=$((WARNINGS + 1))
  fi
}

# ── CKPT-VAL-001: Valid JSON ──
if ! jq empty "$CHECKPOINT_PATH" 2>/dev/null; then
  _add_finding "error" "CKPT-VAL-001" "File is not valid JSON"
  # Output report and exit early — can't check further
  echo "{\"valid\":false,\"errors\":1,\"warnings\":0,\"findings\":[${FINDINGS}]}"
  exit 1
fi

# ── CKPT-VAL-002: Duplicate key detection ──
# jq silently deduplicates, so we need raw text analysis or python
_check_duplicate_keys() {
  local file="$1"

  # Strategy 1: Python (most reliable)
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys

class DupKeyDetector:
    def __init__(self):
        self.duplicates = []

    def check(self, pairs):
        keys = {}
        for key, value in pairs:
            if key in keys:
                self.duplicates.append(key)
            keys[key] = value
        return keys

detector = DupKeyDetector()
with open(sys.argv[1], 'r') as f:
    json.loads(f.read(), object_pairs_hook=detector.check)

if detector.duplicates:
    # Deduplicate the list of duplicate keys
    seen = set()
    unique_dups = []
    for k in detector.duplicates:
        if k not in seen:
            seen.add(k)
            unique_dups.append(k)
    print(','.join(unique_dups))
else:
    print('')
" "$file" 2>/dev/null
    return
  fi

  # Strategy 2: grep-based heuristic (top-level keys only)
  # Count occurrences of each top-level key pattern "  "key":
  # This catches the most common case (top-level duplicates) but misses nested ones
  local raw_keys
  raw_keys=$(grep -E '^\s+"[^"]+"\s*:' "$file" 2>/dev/null | sed -E 's/^\s*"([^"]+)".*/\1/' | sort | uniq -d)
  echo "$raw_keys" | tr '\n' ',' | sed 's/,$//'
}

DUP_KEYS=$(_check_duplicate_keys "$CHECKPOINT_PATH")
if [[ -n "$DUP_KEYS" ]]; then
  _add_finding "error" "CKPT-VAL-002" "Duplicate top-level keys found: ${DUP_KEYS}"

  if [[ "$FIX_MODE" == true ]]; then
    # Fix by re-serializing through jq (deduplicates, keeping last value)
    TMP_FIX=$(mktemp "${CHECKPOINT_PATH}.fix-XXXXXX" 2>/dev/null)
    if jq '.' "$CHECKPOINT_PATH" > "$TMP_FIX" 2>/dev/null; then
      mv -f "$TMP_FIX" "$CHECKPOINT_PATH"
      _add_finding "info" "CKPT-VAL-002-FIX" "Auto-fixed: re-serialized through jq to remove duplicate keys"
    else
      rm -f "$TMP_FIX" 2>/dev/null
      _add_finding "error" "CKPT-VAL-002-FIX" "Auto-fix failed: jq re-serialization error"
    fi
  fi
fi

# ── CKPT-VAL-003: Required fields ──
for field in id plan_file schema_version phases config_dir session_id; do
  val=$(jq -r ".${field} // empty" "$CHECKPOINT_PATH" 2>/dev/null || true)
  if [[ -z "$val" ]]; then
    _add_finding "error" "CKPT-VAL-003" "Missing required field: ${field}"
  fi
done

# ── CKPT-VAL-004: phase_sequence single value ──
# After jq dedup, check the value is reasonable
PS_VAL=$(jq -r '.phase_sequence // empty' "$CHECKPOINT_PATH" 2>/dev/null || true)
if [[ -n "$PS_VAL" ]]; then
  # If we found duplicates above and phase_sequence was one of them, flag it
  if echo "$DUP_KEYS" | grep -q "phase_sequence" 2>/dev/null; then
    _add_finding "warning" "CKPT-VAL-004" "phase_sequence was duplicated (jq resolved to: ${PS_VAL})"
  fi
fi

# ── CKPT-VAL-005: Phase statuses ──
VALID_STATUSES="pending in_progress completed failed skipped timeout cancelled"
PHASE_STATUSES=$(jq -r '.phases | to_entries[] | "\(.key)=\(.value.status // "MISSING")"' "$CHECKPOINT_PATH" 2>/dev/null || true)
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  phase_name="${entry%%=*}"
  phase_status="${entry#*=}"
  if ! echo "$VALID_STATUSES" | grep -qw "$phase_status" 2>/dev/null; then
    _add_finding "error" "CKPT-VAL-005" "Phase '${phase_name}' has invalid status: '${phase_status}'"
  fi
done <<< "$PHASE_STATUSES"

# ── CKPT-VAL-006: Unknown top-level keys ──
KNOWN_KEYS="id schema_version plan_file config_dir owner_pid session_id flags arc_config pr_url freshness session_nonce phase_sequence parent_plan stagnation skip_map phase_skip_log started_at completed_at totals phases current_phase convergence reaction_state codex_cascade commits phase_summaries"
TOP_KEYS=$(jq -r 'keys[]' "$CHECKPOINT_PATH" 2>/dev/null || true)
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  if ! echo "$KNOWN_KEYS" | grep -qw "$key" 2>/dev/null; then
    _add_finding "warning" "CKPT-VAL-006" "Unknown top-level key: '${key}'"
  fi
done <<< "$TOP_KEYS"

# ── CKPT-VAL-007: schema_version range ──
SV=$(jq -r '.schema_version // empty' "$CHECKPOINT_PATH" 2>/dev/null || true)
if [[ -n "$SV" ]]; then
  if ! [[ "$SV" =~ ^[0-9]+$ ]]; then
    _add_finding "error" "CKPT-VAL-007" "schema_version '${SV}' is not numeric"
  elif [[ "$SV" -lt 1 ]]; then
    _add_finding "error" "CKPT-VAL-007" "schema_version must be >= 1"
  fi
fi

# ── Output report ──
VALID="true"
if [[ $ERRORS -gt 0 ]]; then
  VALID="false"
fi

echo "{\"valid\":${VALID},\"errors\":${ERRORS},\"warnings\":${WARNINGS},\"findings\":[${FINDINGS}]}"

if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi
exit 0
