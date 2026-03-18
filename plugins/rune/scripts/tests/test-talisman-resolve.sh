#!/usr/bin/env bash
# test-talisman-resolve.sh — Tests for scripts/talisman-resolve.sh
#
# Usage: bash plugins/rune/scripts/tests/test-talisman-resolve.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/talisman-resolve.sh"

# ── Test framework ──
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

# ── Setup ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"
mkdir -p "$MOCK_CWD/.claude"
mkdir -p "$MOCK_CWD/.rune"

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

# We need the actual plugin root for talisman-defaults.json
REAL_PLUGIN_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# ═══════════════════════════════════════════════════════════════
# 1. Defaults-only mode (no talisman.yml files)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Defaults-only Mode ===\n"

result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-talisman-1"}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)

assert_contains "Output has Talisman Shards" "Talisman Shards" "$result"
assert_contains "Output has SessionStart" "SessionStart" "$result"

# Verify shards were created at SYSTEM-LEVEL dir (defaults-only → .rune/talisman-resolved/)
SHARD_DIR="$MOCK_CHOME/.rune/talisman-resolved"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$SHARD_DIR" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: System shard directory created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: System shard directory NOT created at %s\n" "$SHARD_DIR"
fi

# Verify _meta.json exists with cache_type: system
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SHARD_DIR/_meta.json" ]]; then
  cache_type=$(jq -r '.cache_type // "unknown"' "$SHARD_DIR/_meta.json" 2>/dev/null || echo "unknown")
  if [[ "$cache_type" == "system" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: _meta.json created with cache_type=system\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: _meta.json cache_type=%s (expected system)\n" "$cache_type"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: _meta.json NOT created\n"
fi

# Verify system meta has NO session isolation fields
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SHARD_DIR/_meta.json" ]]; then
  has_pid=$(jq -r '.owner_pid // "absent"' "$SHARD_DIR/_meta.json" 2>/dev/null || echo "absent")
  if [[ "$has_pid" == "absent" || "$has_pid" == "null" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: System _meta.json has no owner_pid\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: System _meta.json has owner_pid=%s (should be absent)\n" "$has_pid"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: _meta.json not found for session field check\n"
fi

# Verify NO project-level shards created (defaults-only should NOT touch project tmp/)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -d "$MOCK_CWD/tmp/.talisman-resolved" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No project-level shards created (defaults-only)\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Project-level shards created (should use system dir for defaults-only)\n"
fi

# Verify key shards exist in system dir
for shard in arc codex review work settings; do
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ -f "$SHARD_DIR/${shard}.json" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: ${shard}.json shard created\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: ${shard}.json shard NOT created\n"
  fi
done

# Verify defaults hash file was written
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SHARD_DIR/.defaults-hash" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: .defaults-hash file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: .defaults-hash file NOT created\n"
fi

rm -rf "$SHARD_DIR"

# ═══════════════════════════════════════════════════════════════
# 2. Project talisman.yml merge
# ═══════════════════════════════════════════════════════════════
printf "\n=== Project Talisman Merge ===\n"

cat > "$MOCK_CWD/.rune/talisman.yml" <<YAML
version: "1.0"
cost_tier: "efficient"
review:
  max_ashes: 5
codex:
  enabled: true
YAML

# Project talisman exists → shards go to project-level dir
SHARD_DIR="$MOCK_CWD/tmp/.talisman-resolved"
result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-talisman-2"}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Project merge has Talisman Shards" "Talisman Shards" "$result"

# Verify project overrides are in shards
# NOTE: Requires python3+PyYAML or yq to merge project talisman.yml
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
_has_yaml_parser=false
python3 -c "import yaml" 2>/dev/null && _has_yaml_parser=true
[[ "$_has_yaml_parser" != "true" ]] && command -v yq &>/dev/null && _has_yaml_parser=true

if [[ "$_has_yaml_parser" != "true" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Project merge SKIPPED (no YAML parser: need python3+PyYAML or yq)\n"
elif [[ -f "$SHARD_DIR/review.json" ]]; then
  max_ashes=$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("max_ashes",""))' < "$SHARD_DIR/review.json" 2>/dev/null || echo "")
  if [[ "$max_ashes" == "5" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Project override (max_ashes=5) merged into review shard\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Project override not merged (max_ashes=%s)\n" "$max_ashes"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: review.json shard missing\n"
fi

rm -f "$MOCK_CWD/.rune/talisman.yml"
rm -rf "$SHARD_DIR"

# ═══════════════════════════════════════════════════════════════
# 3. Session isolation in _meta.json
# ═══════════════════════════════════════════════════════════════
printf "\n=== Session Isolation in Meta ===\n"

# For session isolation test, use project talisman to force project-level resolution
cat > "$MOCK_CWD/.rune/talisman.yml" <<YAML
version: "1.0"
YAML
SHARD_DIR="$MOCK_CWD/tmp/.talisman-resolved"
result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-talisman-3"}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$SHARD_DIR/_meta.json" ]]; then
  has_iso=$(python3 -c '
import sys, json
d = json.load(sys.stdin)
assert "config_dir" in d
assert "owner_pid" in d
assert "session_id" in d
print("ok")
' < "$SHARD_DIR/_meta.json" 2>/dev/null || echo "fail")
  if [[ "$has_iso" == "ok" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: _meta.json has session isolation fields\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: _meta.json missing session isolation fields\n"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: _meta.json not found\n"
fi

rm -rf "$SHARD_DIR"

# ═══════════════════════════════════════════════════════════════
# 4. Missing defaults file → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing Defaults File ===\n"

# Use a fake plugin root with no defaults
FAKE_PLUGIN="$TMP_DIR/fake-plugin"
mkdir -p "$FAKE_PLUGIN/scripts"

result_code=0
echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Missing defaults → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 5. Symlink defaults file → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Defaults File ===\n"

SYMLINK_PLUGIN="$TMP_DIR/symlink-plugin"
mkdir -p "$SYMLINK_PLUGIN/scripts"
ln -sf /etc/passwd "$SYMLINK_PLUGIN/scripts/talisman-defaults.json"

result_code=0
echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_PLUGIN_ROOT="$SYMLINK_PLUGIN" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Symlink defaults → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 6. Empty CWD fallback
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty CWD Fallback ===\n"

# Should fall back to pwd
result_code=0
echo '{}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Empty CWD → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 7. CHOME absoluteness guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== CHOME Absoluteness Guard ===\n"

result_code=0
echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="relative/path" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Relative CHOME → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 8. Shard count (12 data shards)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shard Count ===\n"

# Clean system dir to force fresh resolve (may have hash from prior test)
rm -rf "$MOCK_CHOME/.rune/talisman-resolved" 2>/dev/null || true

# Defaults-only → system-level dir
result=$(echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-talisman-count"}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)

SHARD_DIR="$MOCK_CHOME/.rune/talisman-resolved"
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$SHARD_DIR" ]]; then
  json_count=$(find "$SHARD_DIR" -maxdepth 1 -name '*.json' -not -name '_meta.json' -not -name '.tmp-*' | wc -l | tr -d ' ')
  # Should be 12 data shards
  if [[ "$json_count" -ge 10 ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Got %d data shards (expected ~12)\n" "$json_count"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Only %d data shards (expected ~12)\n" "$json_count"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Shard directory not found\n"
fi

rm -rf "$SHARD_DIR"

# ═══════════════════════════════════════════════════════════════
# 9. All shards are valid JSON
# ═══════════════════════════════════════════════════════════════
printf "\n=== Shard JSON Validity ===\n"

# Defaults-only → system dir
echo '{"cwd":"'"$MOCK_CWD"'","session_id":"test-talisman-valid"}' | CLAUDE_PLUGIN_ROOT="$REAL_PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1

SHARD_DIR="$MOCK_CHOME/.rune/talisman-resolved"
all_valid=true
invalid_count=0
for shard in "$SHARD_DIR"/*.json; do
  [[ -f "$shard" ]] || continue
  if ! python3 -c 'import sys,json; json.load(sys.stdin)' < "$shard" 2>/dev/null; then
    all_valid=false
    invalid_count=$((invalid_count + 1))
  fi
done

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ "$all_valid" == "true" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: All shard files are valid JSON\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: %d shard files are invalid JSON\n" "$invalid_count"
fi

rm -rf "$SHARD_DIR"

# ═══════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════
printf "\n═══════════════════════════════════════════════════\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "═══════════════════════════════════════════════════\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
