#!/bin/bash
# lib/frontmatter-utils.sh — Shared YAML frontmatter extraction utilities
# Source this file — do not execute directly.
#
# Provides _get_fm_field() for extracting single-line values from YAML frontmatter
# in markdown files (--- delimited). Used by detect-workflow-complete.sh and
# on-session-stop.sh for loop file ownership checks.

# Extract a YAML frontmatter field value (single-line, simple values only)
# Usage: value=$(_get_fm_field "$frontmatter_text" "field_name")
# Returns empty string if field not found. Strips surrounding quotes.
# NOTE: Does not handle multi-line values or values with embedded colons.
#       Field names are validated against ^[a-zA-Z0-9_-]+$ (SEC-002).
_get_fm_field() {
  local fm="$1" field="$2"
  # SEC-002: Validate field name to prevent regex injection
  [[ "$field" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  # Extract only frontmatter block (between first two --- lines)
  local fm_block
  fm_block=$(printf '%s\n' "$fm" | sed -n '/^---$/,/^---$/{ /^---$/d; p; }' | head -50)
  # SEC-INFO-001 FIX: When `---` delimiters are absent, return empty instead
  # of falling back to the entire file. The fallback defeated the frontmatter
  # restriction — an attacker with write access to a state file could inject
  # `field: value` outside any frontmatter block (or in a file missing
  # delimiters entirely) and have it honored. Callers MUST treat a missing
  # delimiter pair as "malformed state file" and reject — never lenient-parse.
  [[ -z "$fm_block" ]] && return 0
  printf '%s\n' "$fm_block" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true
}
