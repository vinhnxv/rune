#!/usr/bin/env bash
# scripts/validate-agent-shared-refs.sh
# Validates shared agent reference file integrity and usage.
# 7 checks: Bootstrap paths, inline duplication, size cap, interpolation,
# git tracking, injection patterns, shared file non-empty.
#
# Usage: bash plugins/rune/scripts/validate-agent-shared-refs.sh
# Exit: 0 if clean, 1 if violations found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$PLUGIN_DIR/agents/shared"

VIOLATIONS=0
CHECKED=0

# --- Helpers ---

violation() {
  local code="$1"
  shift
  printf "  [%s] %s\n" "$code" "$*"
  VIOLATIONS=$((VIOLATIONS + 1))
}

section() {
  printf "\n=== Check %s: %s ===\n" "$1" "$2"
}

# --- Check 1: SHARED-001 — Read() paths in Bootstrap Context resolve to existing files ---
section "1" "SHARED-001 — Bootstrap Read() paths resolve"

check1_total=0
check1_pass=0

while IFS= read -r agent_file; do
  [ -z "$agent_file" ] && continue
  # Only check agents that have Bootstrap Context
  if grep -q '## Bootstrap Context' "$agent_file" 2>/dev/null; then
    # Extract Read() paths from Bootstrap Context section
    # Match lines like: 1. Read `plugins/rune/agents/shared/...`
    # or: 1. Read plugins/rune/agents/shared/...
    while IFS= read -r read_path; do
      [ -z "$read_path" ] && continue
      check1_total=$((check1_total + 1))
      # SHARED-008: Reject path traversal sequences (SEC-001)
      if printf '%s' "$read_path" | grep -qE '\.\.'; then
        violation "SHARED-008" "Path traversal in Read() path in $(basename "$agent_file"): $read_path"
        continue
      fi
      # Resolve path relative to project root (3 levels up from agents/)
      project_root="$(cd "$PLUGIN_DIR/../.." && pwd)"
      full_path="$project_root/$read_path"
      if [ -f "$full_path" ]; then
        check1_pass=$((check1_pass + 1))
      else
        violation "SHARED-001" "Broken Read() path in $(basename "$agent_file"): $read_path"
      fi
    done < <(sed -n '/## Bootstrap Context/,/^## [^B]/p' "$agent_file" \
      | grep -oE 'plugins/rune/agents/shared/[^`'"'"'[:space:]]+' \
      2>/dev/null || true)
  fi
done < <(find "$PLUGIN_DIR/agents" -name '*.md' \
  -not -path '*/shared/*' \
  2>/dev/null | sort)

CHECKED=$((CHECKED + check1_total))
printf "  Checked %d Read() paths, %d valid, %d broken\n" "$check1_total" "$check1_pass" "$((check1_total - check1_pass))"

# --- Check 2: SHARED-002 — No variable interpolation in Bootstrap Read() paths ---
section "2" "SHARED-002 — No variable interpolation in Read() paths"

check2_total=0
check2_violations=0

while IFS= read -r agent_file; do
  [ -z "$agent_file" ] && continue
  if grep -q '## Bootstrap Context' "$agent_file" 2>/dev/null; then
    check2_total=$((check2_total + 1))
    # Check for ${...} or $VAR patterns in Bootstrap Context Read() lines
    if sed -n '/## Bootstrap Context/,/^## [^B]/p' "$agent_file" \
      | grep -E 'Read.*\$\{|Read.*\$[A-Z]' 2>/dev/null | grep -qv '^--$'; then
      violation "SHARED-002" "Variable interpolation in Bootstrap Read() paths: $(basename "$agent_file")"
      check2_violations=$((check2_violations + 1))
    fi
  fi
done < <(find "$PLUGIN_DIR/agents" -name '*.md' \
  -not -path '*/shared/*' \
  2>/dev/null | sort)

CHECKED=$((CHECKED + check2_total))
printf "  Checked %d agents, %d clean, %d with interpolation\n" "$check2_total" "$((check2_total - check2_violations))" "$check2_violations"

# --- Check 3: SHARED-003 — Shared files are not empty and within size cap ---
section "3" "SHARED-003 — Shared file size validation"

SIZE_CAP=150
check3_total=0
check3_pass=0

while IFS= read -r shared_file; do
  [ -z "$shared_file" ] && continue
  fname="$(basename "$shared_file")"
  # Skip README.md and TEMPLATE.md — they are documentation, not protocol refs
  case "$fname" in
    README.md|TEMPLATE.md) continue ;;
  esac
  check3_total=$((check3_total + 1))
  line_count=$(wc -l < "$shared_file" | tr -d ' ')
  if [ "$line_count" -eq 0 ]; then
    violation "SHARED-003" "Empty shared file: $fname"
  elif [ "$line_count" -gt "$SIZE_CAP" ]; then
    violation "SHARED-003" "Shared file exceeds ${SIZE_CAP}-line cap: $fname ($line_count lines)"
  else
    check3_pass=$((check3_pass + 1))
  fi
done < <(find "$SHARED_DIR" -name '*.md' 2>/dev/null | sort)

CHECKED=$((CHECKED + check3_total))
printf "  Checked %d shared files, %d within cap, %d violations\n" "$check3_total" "$check3_pass" "$((check3_total - check3_pass))"

# --- Check 4: SHARED-004 — No inline duplication of shared content ---
section "4" "SHARED-004 — No inline duplication of shared content"

check4_total=0
check4_violations=0

# Extract unique non-comment, non-empty lines from shared protocol files as fingerprints
# Use 3+ significant lines as duplication markers
DUPLICATION_MARKERS=(
  "PROVEN.*Read.*traced.*confirmed"
  "LIKELY.*Read.*pattern.*known issue"
  "UNCERTAIN.*naming.*structure.*partial"
  "## Shutdown Protocol"
  "## Adaptive Reset Depth"
  "## Context Rot Detection"
)

while IFS= read -r agent_file; do
  [ -z "$agent_file" ] && continue
  check4_total=$((check4_total + 1))
  for marker in "${DUPLICATION_MARKERS[@]}"; do
    if grep -qE "$marker" "$agent_file" 2>/dev/null; then
      # Check if agent also has Bootstrap Context (meaning it should use shared refs)
      if grep -q '## Bootstrap Context' "$agent_file" 2>/dev/null; then
        violation "SHARED-004" "Inline duplication detected in $(basename "$agent_file"): matches '$marker'"
        check4_violations=$((check4_violations + 1))
        break
      fi
    fi
  done
done < <(find "$PLUGIN_DIR/agents" -name '*.md' \
  -not -path '*/shared/*' \
  2>/dev/null | sort)

CHECKED=$((CHECKED + check4_total))
printf "  Checked %d agents, %d clean, %d with inline duplication\n" "$check4_total" "$((check4_total - check4_violations))" "$check4_violations"

# --- Check 5: SHARED-005 — All shared files are git-tracked ---
section "5" "SHARED-005 — Shared files git-tracked"

check5_total=0
check5_pass=0

while IFS= read -r shared_file; do
  [ -z "$shared_file" ] && continue
  check5_total=$((check5_total + 1))
  if git ls-files --error-unmatch "$shared_file" >/dev/null 2>&1; then
    check5_pass=$((check5_pass + 1))
  else
    violation "SHARED-005" "Shared file not git-tracked: $(basename "$shared_file")"
  fi
done < <(find "$SHARED_DIR" -name '*.md' 2>/dev/null | sort)

CHECKED=$((CHECKED + check5_total))
printf "  Checked %d shared files, %d tracked, %d untracked\n" "$check5_total" "$check5_pass" "$((check5_total - check5_pass))"

# --- Check 6: SHARED-006 — No instruction-injection patterns in shared files ---
section "6" "SHARED-006 — No injection patterns in shared files"

check6_total=0
check6_pass=0

# IMPORTANT: This denylist is a BEST-EFFORT heuristic, NOT a security boundary.
# It catches naive injection attempts but is trivially bypassable via synonym
# substitution, encoding tricks, non-English text, or multi-line splitting.
# The primary security control is human PR review of shared file changes.
INJECTION_PATTERNS=(
  "ignore.*previous.*instructions"
  "ignore.*above.*instructions"
  "disregard.*instructions"
  "forget.*instructions"
  "new.*instructions.*follow"
  "system.*prompt.*override"
  "you.*are.*now"
  "act.*as.*if"
)

while IFS= read -r shared_file; do
  [ -z "$shared_file" ] && continue
  check6_total=$((check6_total + 1))
  found_injection=false
  for pattern in "${INJECTION_PATTERNS[@]}"; do
    if grep -qiE "$pattern" "$shared_file" 2>/dev/null; then
      violation "SHARED-006" "Potential injection pattern in $(basename "$shared_file"): matches '$pattern'"
      found_injection=true
      break
    fi
  done
  if [ "$found_injection" = false ]; then
    check6_pass=$((check6_pass + 1))
  fi
done < <(find "$SHARED_DIR" -name '*.md' 2>/dev/null | sort)

CHECKED=$((CHECKED + check6_total))
printf "  Checked %d shared files, %d clean, %d suspicious\n" "$check6_total" "$check6_pass" "$((check6_total - check6_pass))"

# --- Check 7: SHARED-007 — Shared dir has extraction headers ---
section "7" "SHARED-007 — Extraction source headers present"

check7_total=0
check7_pass=0

while IFS= read -r shared_file; do
  [ -z "$shared_file" ] && continue
  fname="$(basename "$shared_file")"
  case "$fname" in
    README.md|TEMPLATE.md) continue ;;
  esac
  check7_total=$((check7_total + 1))
  if head -3 "$shared_file" | grep -q '<!-- Source: extracted from' 2>/dev/null; then
    check7_pass=$((check7_pass + 1))
  else
    violation "SHARED-007" "Missing extraction header in: $fname"
  fi
done < <(find "$SHARED_DIR" -name '*.md' 2>/dev/null | sort)

CHECKED=$((CHECKED + check7_total))
printf "  Checked %d protocol files, %d with headers, %d missing\n" "$check7_total" "$check7_pass" "$((check7_total - check7_pass))"

# --- Summary ---

printf "\n─────────────────────────────────────\n"
printf "Total checks: %d | Violations: %d\n" "$CHECKED" "$VIOLATIONS"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf "FAIL: %d shared reference violations found\n" "$VIOLATIONS"
  exit 1
else
  printf "PASS: All shared reference checks passed\n"
  exit 0
fi
