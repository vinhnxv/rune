#!/bin/bash
set -euo pipefail
umask 077

# ──────────────────────────────────────────────
# arc-batch-preflight.sh — Pre-validate plan files
# Reads plan paths from stdin, validates each, writes validated list to stdout
# ──────────────────────────────────────────────

ERRORS=0
# QUAL-003 FIX: Use temp file + grep for O(N) dedup instead of O(N^2) array scan.
# Maintains Bash 3.x compatibility (no associative arrays needed).
DEDUP_FILE=$(mktemp "${TMPDIR:-/tmp}/arc-batch-dedup-XXXXXX")
trap 'rm -f "$DEDUP_FILE"' EXIT

# Source cross-platform helpers
_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_PREFLIGHT_DIR}/lib/platform.sh"

while IFS= read -r plan || [[ -n "$plan" ]]; do
  [[ -z "$plan" || "$plan" == \#* ]] && continue

  # 1. File exists
  if [[ ! -f "$plan" ]]; then
    echo "ERROR: Plan file not found: $plan" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 2. Not a symlink (arc rejects symlinks)
  if [[ -L "$plan" ]]; then
    echo "ERROR: Symlink rejected: $plan" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 3. Path traversal check
  if [[ "$plan" == *".."* ]]; then
    echo "ERROR: Path traversal rejected: $plan" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 3.5 SEC-001 FIX: Character allowlist — must match stop hook's GUARD 9 allowlist
  # [a-zA-Z0-9._/-] to prevent silent batch abort when stop hook rejects a path
  # that preflight accepted. Previous denylist approach allowed spaces/tildes which
  # the stop hook would reject, causing silent mid-batch failure.
  if [[ "$plan" =~ [^a-zA-Z0-9._/-] ]]; then
    echo "ERROR: Path contains disallowed characters (only alphanumeric, dot, slash, hyphen, underscore allowed): $plan" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 4. Non-empty file check
  if [[ ! -s "$plan" ]]; then
    echo "ERROR: Empty plan file: $plan" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 5. Canonicalize path (cross-platform via lib/platform.sh)
  CANONICAL=$(_resolve_path "$plan")

  # 6. Duplicate check — O(N) via temp file + grep (QUAL-003 FIX)
  DUPLICATE=false
  if grep -qxF "$CANONICAL" "$DEDUP_FILE" 2>/dev/null; then
    echo "WARNING: Duplicate plan skipped: $plan" >&2
    DUPLICATE=true
  fi

  # 7. Shard frontmatter validation (v1.66.0+, lightweight — WARNING only)
  case "$plan" in
    *-shard-[0-9]*-*)
      frontmatter_section=$(head -20 "$plan" 2>/dev/null)
      if ! echo "$frontmatter_section" | grep -q "^shard:"; then
        echo "WARNING: Shard plan missing 'shard:' in frontmatter: $plan" >&2
      fi
      if ! echo "$frontmatter_section" | grep -q "^parent:"; then
        echo "WARNING: Shard plan missing 'parent:' in frontmatter: $plan" >&2
      fi
      ;;
  esac

  if ! $DUPLICATE; then
    printf '%s\n' "$CANONICAL" >> "$DEDUP_FILE"
    echo "$plan"
  fi
done

# ── SHARD GROUP ANALYSIS (v1.66.0+, second pass after main loop) ──
# Uses a temp file to capture shard info for group analysis.
# No associative arrays — uses grep/sort for macOS bash 3.x compatibility.

SHARD_TMPFILE=$(mktemp "${TMPDIR:-/tmp}/shard-check-XXXXXX")
_cleanup_shard() { rm -f "$SHARD_TMPFILE" "$DEDUP_FILE"; }
trap _cleanup_shard EXIT

# Collect shard info: "prefix:num" per validated plan in DEDUP_FILE
while IFS= read -r plan; do
  case "$plan" in
    *-shard-[0-9]*-*)
      # Extract shard number (POSIX-compatible — no BASH_REMATCH)
      shard_num=$(echo "$plan" | sed -n 's/.*-shard-\([0-9]*\)-.*/\1/p')
      feature_prefix="${plan%-shard-*}"
      if [[ -n "$shard_num" ]]; then
        echo "${feature_prefix}:${shard_num}" >> "$SHARD_TMPFILE"
      fi
      ;;
  esac
done < "$DEDUP_FILE"

# Analyze groups (if any shards found)
if [[ -s "$SHARD_TMPFILE" ]]; then
  # Extract unique prefixes
  cut -d: -f1 "$SHARD_TMPFILE" | sort -u | while IFS= read -r prefix; do
    # Get shard numbers for this group (in input order)
    # CDX-006 FIX: Escape regex metacharacters in prefix for literal matching
    escaped_prefix=$(printf '%s' "$prefix" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    nums=$(grep "^${escaped_prefix}:" "$SHARD_TMPFILE" | cut -d: -f2)
    max_num=$(echo "$nums" | sort -n | tail -1)

    # F-005 FIX: Validate max_num is a positive integer; warn on shard-0
    if ! [[ "$max_num" =~ ^[0-9]+$ ]]; then continue; fi
    if [[ "$max_num" -eq 0 ]]; then
      echo "WARNING: Shard group '$(basename "$prefix")' has invalid shard 0 — shard numbers must be >= 1" >&2
      continue
    fi

    # Check for gaps (missing shard numbers)
    i=1
    while [[ "$i" -le "$max_num" ]]; do
      if ! echo "$nums" | grep -qw "$i"; then
        echo "WARNING: Shard group '$(basename "$prefix")' missing shard $i" >&2
      fi
      i=$((i + 1))
    done

    # Check ordering (should be ascending in input order)
    prev_num=0
    for n in $nums; do
      if [[ "$n" -lt "$prev_num" ]]; then
        echo "WARNING: Shard group '$(basename "$prefix")' out of order: shard $n after shard $prev_num" >&2
        break
      fi
      prev_num="$n"
    done
  done
fi

rm -f "$SHARD_TMPFILE"

if [[ $ERRORS -gt 0 ]]; then
  echo "Pre-flight: $ERRORS error(s) found" >&2
  exit 1
fi
