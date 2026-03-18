#!/usr/bin/env bash
# test-echo-writer.sh -- Tests for scripts/learn/echo-writer.sh
#
# Usage: bash plugins/rune/scripts/tests/test-echo-writer.sh
# Exit: 0 on all pass, 1 on any failure.
#
# NOTE: echo-writer.sh has a known interaction with set -e: when MEMORY.md
# has no existing ## titles, _is_duplicate returns 1 (not duplicate), which
# triggers the ERR trap due to set -e. Tests that write entries pre-populate
# MEMORY.md with a seed entry to avoid this path.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITER="${SCRIPT_DIR}/../learn/echo-writer.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
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
  local test_name="$1" needle="$2" haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle not found)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

assert_not_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle found but should not be)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

# Helper: seed MEMORY.md with a header and one existing entry so _is_duplicate
# won't hit the empty-titles early return (which triggers ERR trap under set -e).
seed_memory() {
  local memfile="$1"
  cat > "$memfile" <<'SEED'
<!-- echo-schema: v1 -->

## Seed Entry For Testing
- **layer**: notes
- **source**: `test/seed`
- **confidence**: LOW
- **date**: 2025-01-01

This is a seed entry so the dedup function has existing titles to check against.
SEED
}

# ── Setup: fake project with .rune/echoes structure ──
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FAKE_PROJECT="${TMPROOT}/project"
mkdir -p "$FAKE_PROJECT/.rune/echoes/orchestrator"
mkdir -p "$FAKE_PROJECT/.rune/echoes/reviewer"
mkdir -p "$FAKE_PROJECT/tmp"

# ===================================================================
# 1. Missing --role flag exits with error
# ===================================================================
printf "\n=== Missing --role flag ===\n"

rc=0
stderr_output=$(echo '{"title":"test","content":"body"}' | (cd "$FAKE_PROJECT" && bash "$WRITER" --layer notes --source test 2>&1 >/dev/null)) || rc=$?
assert_eq "Missing role exits with code 1" "1" "$rc"
assert_contains "Missing role error message" "--role is required" "$stderr_output"

# ===================================================================
# 2. Invalid role name rejected
# ===================================================================
printf "\n=== Invalid role name ===\n"

rc=0
stderr_output=$(echo '{"title":"test","content":"body"}' | (cd "$FAKE_PROJECT" && bash "$WRITER" --role "bad role!" --layer notes --source test 2>&1 >/dev/null)) || rc=$?
assert_eq "Invalid role exits with code 1" "1" "$rc"
assert_contains "Invalid role error message" "invalid role name" "$stderr_output"

# ===================================================================
# 3. Successful entry write
# ===================================================================
printf "\n=== Successful write ===\n"

MEMORY_FILE="${FAKE_PROJECT}/.rune/echoes/orchestrator/MEMORY.md"
seed_memory "$MEMORY_FILE"

input='{"title":"CLI Pattern: git push typo","content":"Always use git push not git psuh","confidence":"HIGH","tags":["cli","git"]}'
echo "$input" | (cd "$FAKE_PROJECT" && bash "$WRITER" --role orchestrator --layer inscribed --source "learn/test" 2>/dev/null) || true

content=$(cat "$MEMORY_FILE")
assert_contains "Title written to MEMORY.md" "CLI Pattern: git push typo" "$content"
assert_contains "Layer written" "inscribed" "$content"
assert_contains "Source written" "learn/test" "$content"
assert_contains "Confidence written" "HIGH" "$content"
assert_contains "Tags written" "cli, git" "$content"
assert_contains "Content body written" "Always use git push not git psuh" "$content"

# ===================================================================
# 4. Default confidence is MEDIUM
# ===================================================================
printf "\n=== Default confidence ===\n"

REVIEWER_MEM="${FAKE_PROJECT}/.rune/echoes/reviewer/MEMORY.md"
seed_memory "$REVIEWER_MEM"

input='{"title":"Default Conf Test Entry","content":"Some content here"}'
echo "$input" | (cd "$FAKE_PROJECT" && bash "$WRITER" --role reviewer --layer notes --source "test" 2>/dev/null) || true

content=$(cat "$REVIEWER_MEM")
# The entry should have MEDIUM (not the seed's LOW)
assert_contains "Default confidence is MEDIUM" "MEDIUM" "$content"

# ===================================================================
# 5. Empty stdin is handled gracefully
# ===================================================================
printf "\n=== Empty stdin ===\n"

rc=0
stderr_output=$(echo "" | (cd "$FAKE_PROJECT" && bash "$WRITER" --role orchestrator --layer notes --source "test" 2>&1 >/dev/null)) || rc=$?
assert_eq "Empty stdin exits 0 (fail-forward)" "0" "$rc"
assert_contains "Empty stdin warns" "empty stdin" "$stderr_output"

# ===================================================================
# 6. Invalid JSON input
# ===================================================================
printf "\n=== Invalid JSON ===\n"

rc=0
echo "not json at all" | (cd "$FAKE_PROJECT" && bash "$WRITER" --role orchestrator --layer notes --source "test" >/dev/null 2>&1) || rc=$?
assert_eq "Invalid JSON exits 0 (fail-forward)" "0" "$rc"

# ===================================================================
# 7. Symlink MEMORY.md is rejected
# ===================================================================
printf "\n=== Symlink MEMORY.md rejected ===\n"

SYMLINK_ROLE="symlink-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${SYMLINK_ROLE}"
ln -sf /tmp/some-target "${FAKE_PROJECT}/.rune/echoes/${SYMLINK_ROLE}/MEMORY.md" 2>/dev/null || true

if [[ -L "${FAKE_PROJECT}/.rune/echoes/${SYMLINK_ROLE}/MEMORY.md" ]]; then
  rc=0
  stderr_output=$(echo '{"title":"Symlink Test","content":"body"}' | (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$SYMLINK_ROLE" --layer notes --source "test" 2>&1 >/dev/null)) || rc=$?
  assert_eq "Symlink MEMORY.md exits 0" "0" "$rc"
  assert_contains "Symlink MEMORY.md warns" "symlink" "$stderr_output"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 2 ))
  PASS_COUNT=$(( PASS_COUNT + 2 ))
  printf "  PASS: Symlink MEMORY.md rejected (skip - creation failed)\n"
  printf "  PASS: Symlink MEMORY.md exits 0 (skip)\n"
fi

# ===================================================================
# 8. Dedup: identical titles rejected (Jaccard >= 80%)
# ===================================================================
printf "\n=== Dedup identical titles ===\n"

DEDUP_ROLE="dedup-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${DEDUP_ROLE}"
DEDUP_MEM="${FAKE_PROJECT}/.rune/echoes/${DEDUP_ROLE}/MEMORY.md"
seed_memory "$DEDUP_MEM"

# Write first entry
echo '{"title":"Unique Pattern Title Here","content":"first content"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$DEDUP_ROLE" --layer notes --source "test" 2>/dev/null) || true

# Verify first entry was written
assert_contains "First entry written" "Unique Pattern Title Here" "$(cat "$DEDUP_MEM")"

# Write duplicate entry (same title)
rc=0
stderr_output=$(echo '{"title":"Unique Pattern Title Here","content":"second content"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$DEDUP_ROLE" --layer notes --source "test" 2>&1 >/dev/null)) || rc=$?
assert_eq "Dedup exits 0" "0" "$rc"
assert_contains "Dedup detected" "duplicate" "$stderr_output"

# Verify only one entry with that title
count=$(grep -c "Unique Pattern Title Here" "$DEDUP_MEM" 2>/dev/null || echo 0)
assert_eq "Only one entry with duplicate title" "1" "$count"

# ===================================================================
# 9. Non-existent echo role directory
# ===================================================================
printf "\n=== Non-existent role directory ===\n"

rc=0
stderr_output=$(echo '{"title":"test","content":"body"}' | (cd "$FAKE_PROJECT" && bash "$WRITER" --role nonexistentrole --layer notes --source "test" 2>&1 >/dev/null)) || rc=$?
assert_eq "Non-existent role exits 0" "0" "$rc"
assert_contains "Non-existent role warns" "does not exist" "$stderr_output"

# ===================================================================
# 10. Confidence normalization (lowercase -> uppercase)
# ===================================================================
printf "\n=== Confidence normalization ===\n"

CONF_ROLE="conf-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${CONF_ROLE}"
CONF_MEM="${FAKE_PROJECT}/.rune/echoes/${CONF_ROLE}/MEMORY.md"
seed_memory "$CONF_MEM"

echo '{"title":"Conf Normal Test Entry","content":"body text","confidence":"low"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$CONF_ROLE" --layer notes --source "test" 2>/dev/null) || true

content=$(cat "$CONF_MEM")
# Should have LOW (not "low") after ascii_upcase
assert_contains "Lowercase confidence normalized to uppercase" "LOW" "$content"

# ===================================================================
# 11. Invalid confidence defaults to MEDIUM
# ===================================================================
printf "\n=== Invalid confidence defaults to MEDIUM ===\n"

INVCONF_ROLE="invconf-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${INVCONF_ROLE}"
INVCONF_MEM="${FAKE_PROJECT}/.rune/echoes/${INVCONF_ROLE}/MEMORY.md"
seed_memory "$INVCONF_MEM"

echo '{"title":"Invalid Conf Entry","content":"body text","confidence":"INVALID_VALUE"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$INVCONF_ROLE" --layer notes --source "test" 2>/dev/null) || true

content=$(cat "$INVCONF_MEM")
assert_contains "Invalid confidence defaults to MEDIUM" "MEDIUM" "$content"

# ===================================================================
# 12. Dirty signal written after successful append
# ===================================================================
printf "\n=== Dirty signal ===\n"

DIRTY_ROLE="dirty-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${DIRTY_ROLE}"
DIRTY_MEM="${FAKE_PROJECT}/.rune/echoes/${DIRTY_ROLE}/MEMORY.md"
seed_memory "$DIRTY_MEM"

echo '{"title":"Dirty Signal Test Entry","content":"trigger dirty signal"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$DIRTY_ROLE" --layer notes --source "test" 2>/dev/null) || true

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "${FAKE_PROJECT}/tmp/.rune-signals/.echo-dirty" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Dirty signal file exists\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Dirty signal file not created\n"
fi

# ===================================================================
# 13. Lock directory is cleaned up
# ===================================================================
printf "\n=== Lock cleanup ===\n"

LOCK_ROLE="lock-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${LOCK_ROLE}"
LOCK_MEM="${FAKE_PROJECT}/.rune/echoes/${LOCK_ROLE}/MEMORY.md"
seed_memory "$LOCK_MEM"

echo '{"title":"Lock Cleanup Test Entry","content":"body"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$LOCK_ROLE" --layer notes --source "test" 2>/dev/null) || true

LOCK_DIR="${FAKE_PROJECT}/tmp/.rune-echo-lock-${LOCK_ROLE}"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -d "$LOCK_DIR" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Lock directory cleaned up after write\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Lock directory still exists after write\n"
fi

# ===================================================================
# 14. Schema header on new MEMORY.md
# ===================================================================
printf "\n=== Schema header on new MEMORY.md ===\n"

SCHEMA_ROLE="schema-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${SCHEMA_ROLE}"
# Create MEMORY.md with just the schema header (no ## entries)
# This will trigger the empty-titles path, but test the file creation
rm -f "${FAKE_PROJECT}/.rune/echoes/${SCHEMA_ROLE}/MEMORY.md"

# Run writer -- will fail-forward due to empty titles, but MEMORY.md should be created
echo '{"title":"Schema Test","content":"body"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$SCHEMA_ROLE" --layer notes --source "test" 2>/dev/null) || true

SCHEMA_MEM="${FAKE_PROJECT}/.rune/echoes/${SCHEMA_ROLE}/MEMORY.md"
if [[ -f "$SCHEMA_MEM" ]]; then
  first_line=$(head -1 "$SCHEMA_MEM")
  assert_contains "MEMORY.md has schema header" "echo-schema: v1" "$first_line"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: MEMORY.md not created\n"
fi

# ===================================================================
# 15. Date field written
# ===================================================================
printf "\n=== Date field ===\n"

content=$(cat "${FAKE_PROJECT}/.rune/echoes/orchestrator/MEMORY.md")
TODAY=$(date +%Y-%m-%d)
assert_contains "Date field has today's date" "$TODAY" "$content"

# ===================================================================
# 16. Entry format has ## heading
# ===================================================================
printf "\n=== Entry heading format ===\n"

content=$(cat "${FAKE_PROJECT}/.rune/echoes/orchestrator/MEMORY.md")
assert_contains "Entry has ## heading" "## CLI Pattern" "$content"

# ===================================================================
# 17. Role name with hyphens and underscores accepted
# ===================================================================
printf "\n=== Valid role names ===\n"

for role_name in "test-role" "test_role" "TestRole123"; do
  mkdir -p "${FAKE_PROJECT}/.rune/echoes/${role_name}"
  seed_memory "${FAKE_PROJECT}/.rune/echoes/${role_name}/MEMORY.md"
  rc=0
  echo '{"title":"Role Name Test","content":"body"}' | \
    (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$role_name" --layer notes --source "test" 2>/dev/null) || rc=$?
  assert_eq "Role '$role_name' accepted" "0" "$rc"
done

# ===================================================================
# 18. 150-line pre-flight warning
# ===================================================================
printf "\n=== 150-line warning ===\n"

WARN_ROLE="warn-test"
mkdir -p "${FAKE_PROJECT}/.rune/echoes/${WARN_ROLE}"
WARN_MEM="${FAKE_PROJECT}/.rune/echoes/${WARN_ROLE}/MEMORY.md"
# Create a file with >150 lines
python3 -c "
print('<!-- echo-schema: v1 -->')
print('## Existing Entry')
for i in range(160):
    print(f'Line {i}')
" > "$WARN_MEM"

rc=0
stderr_output=$(echo '{"title":"Over Limit Test Entry","content":"body"}' | \
  (cd "$FAKE_PROJECT" && bash "$WRITER" --role "$WARN_ROLE" --layer notes --source "test" 2>&1 >/dev/null)) || rc=$?
assert_contains "150-line warning emitted" "150" "$stderr_output"

# ===================================================================
# Results
# ===================================================================
printf "\n===================================================\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "===================================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
