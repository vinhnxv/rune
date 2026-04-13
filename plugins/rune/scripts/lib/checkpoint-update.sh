#!/usr/bin/env bash
# checkpoint-update.sh — Deterministic checkpoint JSON merge utility
#
# Replaces the implicit `updateCheckpoint()` pseudocode pattern with a
# real jq-based read → merge → validate → atomic write pipeline.
#
# Usage (from LLM pseudocode):
#   Bash("${RUNE_PLUGIN_ROOT}/scripts/lib/checkpoint-update.sh" \
#     "$checkpointPath" \
#     '{"phase":"forge","status":"completed","phase_sequence":1}')
#
# Usage (phase update with nested path):
#   Bash("${RUNE_PLUGIN_ROOT}/scripts/lib/checkpoint-update.sh" \
#     "$checkpointPath" \
#     '{"phase":"forge","status":"completed"}' \
#     --phase-update)
#
# Modes:
#   (default)       Top-level merge: update * into checkpoint root
#   --phase-update  Phase-aware merge: extracts "phase" key, updates
#                   checkpoint.phases[phase].{status,artifact,...} AND
#                   top-level fields (phase_sequence, current_phase, etc.)
#
# Safety:
#   - Atomic write via tmp + mv (no partial writes)
#   - Duplicate key prevention (jq merge produces clean JSON)
#   - Post-write validation (re-reads and checks required fields)
#   - Backup before write (.bak file)
#
# Exit codes:
#   0 = success
#   1 = usage error / missing args
#   2 = jq not available
#   3 = checkpoint file not found
#   4 = invalid update JSON
#   5 = merge failed
#   6 = post-write validation failed
#
# Dependencies: jq (required), mktemp
# Platform: macOS + Linux (POSIX-compatible)

set -euo pipefail

# ── Args ──
CHECKPOINT_PATH="${1:-}"
UPDATE_JSON="${2:-}"
MODE="top-level"
if [[ "${3:-}" == "--phase-update" ]]; then
  MODE="phase-update"
fi

if [[ -z "$CHECKPOINT_PATH" ]] || [[ -z "$UPDATE_JSON" ]]; then
  echo "Usage: checkpoint-update.sh <checkpoint-path> '<json-update>' [--phase-update]" >&2
  exit 1
fi

# ── jq check ──
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required for checkpoint-update.sh" >&2
  exit 2
fi

# ── File check ──
if [[ ! -f "$CHECKPOINT_PATH" ]]; then
  echo "ERROR: checkpoint not found: $CHECKPOINT_PATH" >&2
  exit 3
fi

# ── Validate update JSON ──
if ! echo "$UPDATE_JSON" | jq empty 2>/dev/null; then
  echo "ERROR: invalid update JSON: $UPDATE_JSON" >&2
  exit 4
fi

# ── Backup before write ──
cp -f "$CHECKPOINT_PATH" "${CHECKPOINT_PATH}.bak.$(date +%s)" 2>/dev/null || true

# BUG-004 FIX: Prune old backups (keep 3 most recent)
# FLAW-002/QUAL-003 FIX: Use ls -t (mtime sort) instead of fragile dot-count sort key.
# Epoch-suffixed filenames sort identically by name and by mtime.
_bak_dir="$(dirname "$CHECKPOINT_PATH")"
_bak_base="$(basename "$CHECKPOINT_PATH")"
find "$_bak_dir" -name "${_bak_base}.bak.*" -type f 2>/dev/null | while IFS= read -r _f; do
  _suffix="${_f##*.}"
  printf '%s %s\n' "$_suffix" "$_f"
done | sort -rn | tail -n +4 | while read -r _ _f; do rm -f "$_f" 2>/dev/null; done

# ── Read current checkpoint ──
CURRENT=$(cat "$CHECKPOINT_PATH" 2>/dev/null)
if [[ -z "$CURRENT" ]] || ! echo "$CURRENT" | jq empty 2>/dev/null; then
  echo "ERROR: checkpoint file is not valid JSON" >&2
  exit 5
fi

# ── Merge ──
if [[ "$MODE" == "phase-update" ]]; then
  # Phase-aware merge:
  # 1. Extract "phase" name from update
  # 2. Separate phase-level fields from top-level fields
  # 3. Merge phase fields into .phases[phaseName]
  # 4. Merge top-level fields into root
  MERGED=$(echo "$CURRENT" | jq --argjson update "$UPDATE_JSON" '
    # Extract phase name
    ($update.phase // null) as $phaseName |

    # Phase-level fields (go into .phases[phaseName])
    ["status", "artifact", "artifact_hash", "team_name",
     "started_at", "completed_at", "skip_reason", "retry_count",
     "score", "verdicts", "refinements", "fixed_count",
     "deferred_count", "reclassified_count", "prototype_count",
     "story_count", "library_matches"] as $phaseFields |

    # Split update into phase-level and top-level
    ($update | to_entries | map(select(.key as $k | $phaseFields | index($k))) | from_entries) as $phaseUpdate |
    ($update | to_entries | map(select(.key as $k | ($phaseFields | index($k) | not) and $k != "phase")) | from_entries) as $topUpdate |

    # Apply phase update
    (if $phaseName != null and (.phases[$phaseName] // null) != null then
      .phases[$phaseName] *= $phaseUpdate
    else . end) |

    # Apply top-level update (this REPLACES existing keys, preventing duplicates)
    . * $topUpdate
  ' 2>/dev/null)
else
  # Simple top-level merge — jq * operator replaces existing keys
  MERGED=$(echo "$CURRENT" | jq --argjson update "$UPDATE_JSON" '. * $update' 2>/dev/null)
fi

if [[ -z "$MERGED" ]] || ! echo "$MERGED" | jq empty 2>/dev/null; then
  echo "ERROR: merge produced invalid JSON" >&2
  exit 5
fi

# ── Atomic write ──
TMP_FILE=$(mktemp "${CHECKPOINT_PATH}.XXXXXX" 2>/dev/null) || {
  echo "ERROR: failed to create temp file (disk full? permission?) at $(dirname "$CHECKPOINT_PATH")" >&2
  exit 5
}
# Pretty-print for readability + debugging
echo "$MERGED" | jq '.' > "$TMP_FILE" 2>/dev/null || {
  rm -f "$TMP_FILE" 2>/dev/null
  echo "ERROR: failed to write merged JSON to $TMP_FILE (likely disk full / ENOSPC / permission)" >&2
  exit 5
}

# T9 / RUIN-004 FIX: explicit post-write verification. Previously the script
# trusted pipefail + stderr redirection to surface ENOSPC, but a truncated
# write could still land a short/empty temp file and then mv over the real
# checkpoint, silently reverting a "completed" phase on next read. Now we
# check (a) non-empty, (b) valid JSON before promoting the temp file.
if [[ ! -s "$TMP_FILE" ]]; then
  rm -f "$TMP_FILE" 2>/dev/null
  echo "ERROR: checkpoint temp file is empty after write — aborting to preserve existing checkpoint ($CHECKPOINT_PATH). Likely disk full." >&2
  exit 5
fi
if ! jq empty "$TMP_FILE" 2>/dev/null; then
  rm -f "$TMP_FILE" 2>/dev/null
  echo "ERROR: checkpoint temp file is not valid JSON after write — aborting to preserve existing checkpoint ($CHECKPOINT_PATH)." >&2
  exit 5
fi

mv -f "$TMP_FILE" "$CHECKPOINT_PATH" || {
  rm -f "$TMP_FILE" 2>/dev/null
  echo "ERROR: atomic mv failed for $CHECKPOINT_PATH (disk full? cross-filesystem?)" >&2
  exit 5
}

# T9 / RUIN-004 FIX: best-effort flush to disk so a post-mv crash does not lose
# the committed checkpoint. sync() is fast and per-filesystem on macOS/Linux.
sync 2>/dev/null || true

# ── Post-write validation ──
# Quick sanity check: required fields still present
_post_id=$(jq -r '.id // empty' "$CHECKPOINT_PATH" 2>/dev/null || true)
_post_plan=$(jq -r '.plan_file // empty' "$CHECKPOINT_PATH" 2>/dev/null || true)
_post_schema=$(jq -r '.schema_version // empty' "$CHECKPOINT_PATH" 2>/dev/null || true)

if [[ -z "$_post_id" ]] || [[ -z "$_post_plan" ]] || [[ -z "$_post_schema" ]]; then
  echo "ERROR: post-write validation failed — required fields missing after merge" >&2
  # Restore from backup
  # BACK-001 FIX: Use _local_bak (prefixed) to avoid global variable leakage.
  # Cannot use 'local' here — this is script-level, not inside a function.
  _local_bak=$(find "$(dirname "$CHECKPOINT_PATH")" -maxdepth 1 -name "$(basename "$CHECKPOINT_PATH").bak.*" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
  if [[ -n "$_local_bak" ]]; then
    cp -f "$_local_bak" "$CHECKPOINT_PATH" 2>/dev/null || true
    echo "RESTORED from backup: $_local_bak" >&2
  fi
  exit 6
fi

# ── Success — output path for caller ──
echo "$CHECKPOINT_PATH"
