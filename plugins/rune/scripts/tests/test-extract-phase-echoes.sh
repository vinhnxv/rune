#!/usr/bin/env bash
# test-extract-phase-echoes.sh — Tests for _extract_phase_echoes() in arc-phase-stop-hook.sh
#
# This function is critical: it filters meta-QA echo entries for injection into
# arc phase prompts. Bugs here either bloat prompts or miss relevant warnings.
#
# Usage: bash plugins/rune/scripts/tests/test-extract-phase-echoes.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/arc-phase-stop-hook.sh"

# ── Temp workspace ──
TMPWORK=$(mktemp -d "${TMPDIR:-/tmp}/test-phase-echoes-XXXXXX")
trap 'rm -rf "$TMPWORK"' EXIT

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$expected" = "$actual" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s\n" "$test_name"
    printf "    expected: %q\n" "$expected"
    printf "    actual:   %q\n" "$actual"
  fi
}

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle not found)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %.200s...\n" "$haystack"
  fi
}

assert_not_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle should NOT be present)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
  fi
}


# ── Extract _extract_phase_echoes from the hook script ──
# We extract the function definition (lines between _extract_phase_echoes() { and the closing })
# using sed, then source it.
_FUNC_FILE="$TMPWORK/func.sh"
sed -n '/^_extract_phase_echoes()/,/^}/p' "$HOOK_SCRIPT" > "$_FUNC_FILE"
if [[ ! -s "$_FUNC_FILE" ]]; then
  echo "FATAL: Could not extract _extract_phase_echoes from $HOOK_SCRIPT"
  exit 1
fi
source "$_FUNC_FILE"

# ═══════════════════════════════════════════════
# TEST FIXTURES
# ═══════════════════════════════════════════════

# Fixture 1: Standard MEMORY.md with mixed entries
cat > "$TMPWORK/memory-standard.md" << 'EOF'
# Meta-QA Echoes

### [SA-RC-001] Code review consistently misses null safety

- **layer**: inscribed
- **phase_tags**: code_review, mend
- **recurrence**: 4/5 runs
- **pattern**: Reviewers flag style but miss null deref in error paths

**Recommendation**: Add null-safety check to ward-sentinel prompt.

### [SA-WF-002] Work phase workers skip evidence collection

- **layer**: etched
- **phase_tags**: work, strive
- **recurrence**: 3/5 runs
- **pattern**: Workers complete tasks but omit evidence section

**Recommendation**: Strengthen discipline proof enforcement.

### [SA-AGT-003] Forge enrichment is too shallow

- **layer**: observations
- **phase_tags**: forge, work
- **recurrence**: 2/5 runs
- **pattern**: Forge agents produce generic enrichment

### [SA-HK-004] Hook timeout too aggressive

- **layer**: traced
- **phase_tags**: work, code_review
- **recurrence**: 1/5 runs
- **pattern**: 5s timeout insufficient for large diffs
EOF

# Fixture 2: Many entries (tests max_entries cap)
cat > "$TMPWORK/memory-many.md" << 'EOF'
### [SA-001] Finding A
- **layer**: inscribed
- **phase_tags**: work

### [SA-002] Finding B
- **layer**: etched
- **phase_tags**: work

### [SA-003] Finding C
- **layer**: inscribed
- **phase_tags**: work

### [SA-004] Finding D
- **layer**: inscribed
- **phase_tags**: work

### [SA-005] Finding E
- **layer**: etched
- **phase_tags**: work
EOF

# Fixture 3: Word boundary testing
cat > "$TMPWORK/memory-boundary.md" << 'EOF'
### [SA-WB-001] Network timeout issue
- **layer**: inscribed
- **phase_tags**: network, infrastructure

### [SA-WB-002] Actual work phase issue
- **layer**: inscribed
- **phase_tags**: work, strive
EOF

# Fixture 4: Empty file
cat > "$TMPWORK/memory-empty.md" << 'EOF'
# Meta-QA Echoes
EOF

# ═══════════════════════════════════════════════
# TEST CASES
# ═══════════════════════════════════════════════

echo ""
echo "=== Test: Phase tag matching ==="

result=$(_extract_phase_echoes "$TMPWORK/memory-standard.md" "code_review")
assert_contains "matches code_review tagged entry" "SA-RC-001" "$result"
assert_not_contains "does not match work-only entry" "SA-WF-002" "$result"

result=$(_extract_phase_echoes "$TMPWORK/memory-standard.md" "work")
assert_contains "matches work tagged entry" "SA-WF-002" "$result"
assert_not_contains "does not match code_review-only entry" "SA-RC-001" "$result"

echo ""
echo "=== Test: Layer exclusion ==="

result=$(_extract_phase_echoes "$TMPWORK/memory-standard.md" "work")
assert_contains "includes etched entry" "SA-WF-002" "$result"
assert_not_contains "excludes observations layer" "SA-AGT-003" "$result"
assert_not_contains "excludes traced layer" "SA-HK-004" "$result"

echo ""
echo "=== Test: Max entries cap (3) ==="

result=$(_extract_phase_echoes "$TMPWORK/memory-many.md" "work")
# Count how many ### entries are in the output
entry_count=$(printf '%s\n' "$result" | grep -c '^### ' || true)
assert_eq "max 3 entries returned" "3" "$entry_count"

echo ""
echo "=== Test: Word boundary matching ==="

result=$(_extract_phase_echoes "$TMPWORK/memory-boundary.md" "work")
assert_contains "matches 'work' phase tag" "SA-WB-002" "$result"
assert_not_contains "does not match 'network' when searching 'work'" "SA-WB-001" "$result"

echo ""
echo "=== Test: Empty/no matches ==="

result=$(_extract_phase_echoes "$TMPWORK/memory-empty.md" "work")
assert_eq "empty file returns empty" "" "$result"

result=$(_extract_phase_echoes "$TMPWORK/memory-standard.md" "nonexistent_phase")
assert_eq "no matching phase returns empty" "" "$result"

echo ""
echo "=== Test: Last entry flush ==="
# The last entry in a file must also be flushed (edge case)
cat > "$TMPWORK/memory-last.md" << 'EOF'
### [SA-LAST-001] Only entry
- **layer**: inscribed
- **phase_tags**: merge
EOF
result=$(_extract_phase_echoes "$TMPWORK/memory-last.md" "merge")
assert_contains "last entry is flushed" "SA-LAST-001" "$result"

echo ""
echo "=== Test: Layer exclusion overrides phase match ==="
# An entry tagged for the right phase but at observations layer should be excluded
cat > "$TMPWORK/memory-layer-priority.md" << 'EOF'
### [SA-LP-001] Observation with matching phase
- **layer**: observations
- **phase_tags**: work
- **pattern**: This should be excluded despite matching phase
EOF
result=$(_extract_phase_echoes "$TMPWORK/memory-layer-priority.md" "work")
assert_eq "observations layer excluded despite phase match" "" "$result"

# ═══════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════

echo ""
echo "════════════════════════════════"
printf "Results: %d/%d passed" "$PASS_COUNT" "$TOTAL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf " (%d FAILED)" "$FAIL_COUNT"
fi
echo ""
echo "════════════════════════════════"

[[ "$FAIL_COUNT" -eq 0 ]]
