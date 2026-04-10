#!/bin/bash
# scripts/arc-issues-preflight.sh
# Pre-flight validation for /rune:arc-issues.
#
# Validates:
#   1. gh CLI is installed (>= 2.4.0)
#   2. gh authentication is valid (non-expired token)
#   3. Each issue number is valid (numeric, 1-7 digits)
#   4. Each issue exists and is open (via gh issue view)
#   5. Issues without duplicate entries (dedup)
#
# OUTPUT (JSON to stdout):
#   {
#     "valid": [42, 55],
#     "skipped": [78],          // already has a Rune status label
#     "invalid": [0, 99999999], // bad format or not found
#     "errors": ["..."],        // fatal errors (gh not installed, auth failed)
#     "ok": true/false          // false if fatal errors or no valid issues
#   }
#
# Usage: echo '42 55 78' | arc-issues-preflight.sh
#   Or:  arc-issues-preflight.sh 42 55 78
#
# Exit codes:
#   0 — validation complete (check .ok field for fatal errors)
#   1 — unexpected script error (non-JSON output, use fail-open)
#
# Timeout per gh call: 5s (prevents hang on slow GitHub API)

set -euo pipefail
trap 'exit 1' ERR
umask 077

# ── Timeout helper: uses `timeout` if available, falls back to plain call ──
_gh_timeout() {
  if command -v timeout &>/dev/null; then
    timeout 5 "$@"
  else
    "$@"
  fi
}

# ── Validate issue number format (numeric only, 1-7 digits) ──
_is_valid_issue_num() {
  local num="$1"
  # NOTE: {1,7} quantifier not supported in Bash 3.2 (macOS) — use + and length check
  [[ ${#num} -le 7 ]] && [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -gt 0 ]]
}

# ── Collect issue numbers from args or stdin ──
ISSUE_NUMS=()

if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    # Strip leading # if present (e.g. #42 → 42)
    arg="${arg#\#}"
    ISSUE_NUMS+=("$arg")
  done
else
  # Read from stdin (space or newline separated)
  while IFS= read -r line; do
    for token in $line; do
      token="${token#\#}"
      ISSUE_NUMS+=("$token")
    done
  done
fi

# ── Output builder ──
# Array type contract:
#   valid[]   — numbers (issue IDs that passed validation)
#   skipped[] — numbers (issue IDs with existing Rune status labels)
#   invalid[] — strings (issue number + implicit reason: bad format, not found, or closed)
#   errors[]  — strings (fatal error messages: gh missing, auth failed, etc.)
ERRORS_JSON="[]"
VALID_JSON="[]"
SKIPPED_JSON="[]"
INVALID_JSON="[]"
OVERALL_OK="true"

_add_error() {
  ERRORS_JSON=$(echo "$ERRORS_JSON" | jq --arg e "$1" '. += [$e]' 2>/dev/null || echo '[]')
  OVERALL_OK="false"
}

_add_valid() {
  VALID_JSON=$(echo "$VALID_JSON" | jq --argjson n "$1" '. += [$n]' 2>/dev/null || echo '[]')
}

_add_skipped() {
  SKIPPED_JSON=$(echo "$SKIPPED_JSON" | jq --argjson n "$1" '. += [$n]' 2>/dev/null || echo '[]')
}

# NOTE: invalid[] uses strings (via --argjson with quoted value) while valid[]/skipped[]
# use numbers. This is intentional — invalid entries carry the raw input which may not be
# numeric (e.g. "abc", "99999999"), so string type preserves the original value for diagnostics.
_add_invalid() {
  INVALID_JSON=$(printf '%s\n' "$INVALID_JSON" | jq --arg n "$1" '. += [$n]' 2>/dev/null || echo '[]')
}

# ── Output JSON and exit ──
# Output contract: JSON object (NOT array) to stdout.
# Schema: { valid: number[], skipped: number[], invalid: string[], errors: string[], ok: boolean }
# Consumers (e.g. arc-issues-algorithm.md) parse this as an object and access fields by name.
# The .ok field is false when: fatal errors occurred OR no valid issues remain.
_output_and_exit() {
  # If no valid issues and no errors, set ok=false
  local valid_count
  valid_count=$(echo "$VALID_JSON" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$valid_count" -eq 0 ]] && [[ "$OVERALL_OK" == "true" ]]; then
    OVERALL_OK="false"
  fi
  jq -n \
    --argjson valid "$VALID_JSON" \
    --argjson skipped "$SKIPPED_JSON" \
    --argjson invalid "$INVALID_JSON" \
    --argjson errors "$ERRORS_JSON" \
    --argjson ok "$OVERALL_OK" \
    '{valid: $valid, skipped: $skipped, invalid: $invalid, errors: $errors, ok: $ok}'
  exit 0
}

# ── GUARD 1: jq dependency ──
if ! command -v jq &>/dev/null; then
  _add_error "jq not found — arc-issues-preflight requires jq for JSON parsing"
  _output_and_exit
fi

# ── GUARD 2: gh CLI installed ──
if ! command -v gh &>/dev/null; then
  _add_error "gh CLI not found — install GitHub CLI (https://cli.github.com) to use /rune:arc-issues"
  _output_and_exit
fi

# ── GUARD 3: gh CLI version >= 2.4.0 ──
GH_VERSION=$(gh --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
GH_MAJOR=$(echo "$GH_VERSION" | cut -d. -f1)
GH_MINOR=$(echo "$GH_VERSION" | cut -d. -f2)
if [[ ! "$GH_MAJOR" =~ ^[0-9]+$ ]] || [[ ! "$GH_MINOR" =~ ^[0-9]+$ ]]; then
  _add_error "Could not determine gh CLI version (got: ${GH_VERSION}) — upgrade to >= 2.4.0"
  _output_and_exit
fi
if [[ "$GH_MAJOR" -lt 2 ]] || { [[ "$GH_MAJOR" -eq 2 ]] && [[ "$GH_MINOR" -lt 4 ]]; }; then
  _add_error "gh CLI version ${GH_VERSION} is too old — upgrade to >= 2.4.0 (current: ${GH_VERSION})"
  _output_and_exit
fi

# ── GUARD 4: gh authentication ──
# Detect expired/invalid token. GH_PROMPT_DISABLED prevents interactive prompts.
GH_AUTH_STATUS=$(GH_PROMPT_DISABLED=1 _gh_timeout gh auth status 2>&1 || true)
if echo "$GH_AUTH_STATUS" | grep -qiE 'not logged|token.*expired|authentication.*failed|no.*auth|unauthenticated'; then
  _add_error "gh CLI is not authenticated or token has expired. Run: gh auth login"
  _output_and_exit
fi
# Additional check: if we get no output at all, auth may have failed silently
if [[ -z "$GH_AUTH_STATUS" ]]; then
  _add_error "gh auth status returned empty output — check gh CLI configuration"
  _output_and_exit
fi

# ── GUARD 5: No issue numbers provided ──
if [[ ${#ISSUE_NUMS[@]} -eq 0 ]]; then
  _add_error "No issue numbers provided to preflight"
  _output_and_exit
fi

# ── RUNE STATUS LABELS (issues with these labels are already processed) ──
RUNE_STATUS_LABELS=("rune:in-progress" "rune:done" "rune:failed" "rune:needs-review")

# ── Process each issue number ──
# Dedup: track seen numbers (string-based for Bash 3.2 compat — no declare -A)
SEEN_NUMS=" "
for raw_num in "${ISSUE_NUMS[@]}"; do
  # Validate format
  if ! _is_valid_issue_num "$raw_num"; then
    _add_invalid "$raw_num"
    continue
  fi

  # Dedup check (word-boundary match in space-delimited string)
  case "$SEEN_NUMS" in
    *" ${raw_num} "*) continue ;;  # Duplicate — skip silently
  esac
  SEEN_NUMS="${SEEN_NUMS}${raw_num} "

  # Validate issue exists and is open via gh issue view
  ISSUE_JSON=$(GH_PROMPT_DISABLED=1 _gh_timeout gh issue view "$raw_num" --json number,state,labels 2>/dev/null || echo "")

  if [[ -z "$ISSUE_JSON" ]]; then
    _add_invalid "$raw_num"
    continue
  fi

  # Check issue state is open
  ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null || echo "")
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    _add_invalid "$raw_num"
    continue
  fi

  # Check for Rune status labels (already processed)
  ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '(.labels // [])[] | .name' 2>/dev/null || echo "")
  is_rune_processed="false"
  for label in "${RUNE_STATUS_LABELS[@]}"; do
    if echo "$ISSUE_LABELS" | grep -qF "$label" 2>/dev/null; then
      is_rune_processed="true"
      break
    fi
  done

  if [[ "$is_rune_processed" == "true" ]]; then
    _add_skipped "$raw_num"
  else
    _add_valid "$raw_num"
  fi
done

# ── Output final results ──
_output_and_exit
