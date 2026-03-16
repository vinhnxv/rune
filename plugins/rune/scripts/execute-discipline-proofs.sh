#!/usr/bin/env bash
# scripts/execute-discipline-proofs.sh
# Executes machine proofs against discipline engineering acceptance criteria.
# Each criterion is evaluated by proof type and results are output as JSON.
#
# Usage: execute-discipline-proofs.sh <criteria.json> [cwd]
#
# criteria.json format:
#   [{"criterion_id":"C-001","type":"file_exists","target":"path/to/file"}, ...]
#
# Proof types:
#   file_exists        — test -f <target>
#   pattern_matches    — grep -qE <pattern> <target>
#   no_pattern_exists  — inverse grep -qE (fails if pattern found)
#   test_passes        — execute command, check exit code
#   builds_clean       — execute build command, check exit code

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL — see ADR-002) ---
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true

# --- Arguments ---
CRITERIA_FILE="${1:?Usage: execute-discipline-proofs.sh <criteria.json> [cwd]}"
CWD="${2:-.}"

# Validate criteria file exists
if [[ ! -f "$CRITERIA_FILE" ]]; then
  printf '{"error":"criteria file not found: %s"}\n' "$CRITERIA_FILE" >&2
  exit 1
fi

# Change to working directory
cd "$CWD" || { printf '{"error":"cannot cd to: %s"}\n' "$CWD" >&2; exit 1; }

# SEC-004: Containment check — verify .claude/ exists in CWD
if [[ ! -d ".claude" ]]; then
  printf '{"error":"containment check failed: .claude/ not found in CWD"}\n' >&2
  exit 1
fi

# Pre-flight: jq required
if ! command -v jq &>/dev/null; then
  printf '{"error":"jq is required but not found"}\n' >&2
  exit 1
fi

# Validate JSON
if ! jq empty "$CRITERIA_FILE" 2>/dev/null; then
  printf '{"error":"invalid JSON in criteria file"}\n' >&2
  exit 1
fi

# --- Proof type implementations ---

# file_exists: test -f <target>
proof_file_exists() {
  local target="$1"
  if test -f "$target"; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# pattern_matches: grep -qE <pattern> <file>
proof_pattern_matches() {
  local pattern="$1"
  local file="$2"
  if [[ ${#pattern} -gt 200 ]]; then
    echo "FAIL"
    return
  fi
  if [[ -z "$file" ]]; then
    echo "FAIL"
    return
  fi
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# no_pattern_exists: inverse grep — PASS if pattern NOT found
proof_no_pattern_exists() {
  local pattern="$1"
  local file="$2"
  if [[ ${#pattern} -gt 200 ]]; then
    echo "FAIL"
    return
  fi
  if [[ -z "$file" ]]; then
    # No file specified — search CWD recursively
    if grep -rqE "$pattern" . 2>/dev/null; then
      echo "FAIL"
    else
      echo "PASS"
    fi
    return
  fi
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "FAIL"
  else
    echo "PASS"
  fi
}

# test_passes: execute command, check exit code
# SEC-001 FIX: Replace eval with allowlisted command execution to prevent injection
proof_test_passes() {
  local cmd="$1"
  # Validate command against allowlist (no shell metacharacters)
  if [[ "$cmd" =~ [$'\n'\;\&\|\$\`\<\>\(\)\{\}\!\~] ]]; then
    echo "FAIL"  # Reject commands with shell metacharacters
    return
  fi
  # Execute via bash -c with timeout (no eval)
  if timeout 60 bash -c "$cmd" >/dev/null 2>&1; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# builds_clean: execute build command, check exit code
# SEC-001 FIX: Same allowlist pattern as test_passes
proof_builds_clean() {
  local cmd="$1"
  if [[ "$cmd" =~ [$'\n'\;\&\|\$\`\<\>\(\)\{\}\!\~] ]]; then
    echo "FAIL"
    return
  fi
  if timeout 120 bash -c "$cmd" >/dev/null 2>&1; then
    echo "PASS"
  else
    echo "FAIL"
  fi
}

# --- Execute proofs ---
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
COUNT="$(jq 'length' "$CRITERIA_FILE")"

echo "["
i=0
while IFS= read -r criterion; do
  criterion_id="$(echo "$criterion" | jq -r '.criterion_id // "unknown"')"
  proof_type="$(echo "$criterion"  | jq -r '.type // "unknown"')"
  target="$(echo "$criterion"      | jq -r '.target // ""')"
  pattern="$(echo "$criterion"     | jq -r '.pattern // ""')"
  command_="$(echo "$criterion"    | jq -r '.command // ""')"
  file="$(echo "$criterion"        | jq -r '.file // ""')"

  result="FAIL"
  evidence=""

  case "$proof_type" in
    file_exists)
      result="$(proof_file_exists "$target")"
      if [[ "$result" == "PASS" ]]; then
        evidence="File exists: $target"
      else
        evidence="File not found: $target"
      fi
      ;;

    pattern_matches)
      result="$(proof_pattern_matches "$pattern" "$file")"
      if [[ "$result" == "PASS" ]]; then
        evidence="Pattern '$pattern' found in: ${file:-<stream>}"
      else
        evidence="Pattern '$pattern' not found in: ${file:-<stream>}"
      fi
      ;;

    no_pattern_exists)
      result="$(proof_no_pattern_exists "$pattern" "$file")"
      if [[ "$result" == "PASS" ]]; then
        evidence="Pattern '$pattern' correctly absent from: ${file:-CWD}"
      else
        evidence="Pattern '$pattern' unexpectedly found in: ${file:-CWD}"
      fi
      ;;

    test_passes)
      result="$(proof_test_passes "$command_")"
      if [[ "$result" == "PASS" ]]; then
        evidence="Command exited 0: $command_"
      else
        evidence="Command exited non-zero: $command_"
      fi
      ;;

    builds_clean)
      result="$(proof_builds_clean "$command_")"
      if [[ "$result" == "PASS" ]]; then
        evidence="Build succeeded: $command_"
      else
        evidence="Build failed: $command_"
      fi
      ;;

    *)
      result="FAIL"
      evidence="Unknown proof type: $proof_type"
      ;;
  esac

  # Separator
  if [[ $i -gt 0 ]]; then
    echo ","
  fi

  # Output JSON per criterion
  jq -n \
    --arg criterion_id "$criterion_id" \
    --arg result "$result" \
    --arg evidence "$evidence" \
    --arg timestamp "$TIMESTAMP" \
    '{criterion_id: $criterion_id, result: $result, evidence: $evidence, timestamp: $timestamp}'

  i=$((i + 1))
done < <(jq -c '.[]' "$CRITERIA_FILE")

echo "]"
