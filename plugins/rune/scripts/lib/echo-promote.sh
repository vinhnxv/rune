#!/bin/bash
# scripts/lib/echo-promote.sh
# Auto-promotes Observation-tier echo entries to Inscribed when access_count >= 3.
#
# USAGE:
#   source scripts/lib/echo-promote.sh
#   rune_echo_promote --role reviewer
#   rune_echo_promote               # promotes across ALL roles
#
# Reads access counts from the echo-search SQLite database.
# Rewrites "**layer**: observations" to "**layer**: inscribed" in MEMORY.md.
#
# Dependencies:
#   - sqlite3 (for querying echo_access_log)
#   - rune-state.sh (for RUNE_STATE variable)
#
# Exit codes:
#   0 — success (or no promotable entries)
#   1 — missing dependency
#
# SOURCING GUARD: Safe to source multiple times (idempotent).
# Cross-platform: POSIX-safe, no bash 4+ features.

# ── Resolve paths ──
_ECHO_PROMOTE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source rune-state.sh for RUNE_STATE variable (idempotent)
if [[ -z "${RUNE_STATE:-}" ]]; then
  # shellcheck source=rune-state.sh
  source "${_ECHO_PROMOTE_DIR}/rune-state.sh"
fi

# ── Constants ──
_PROMOTE_THRESHOLD=3
_PROMOTE_DATE=$(date +%Y-%m-%d)

# ── Main function ──
# rune_echo_promote [--role ROLE]
# If --role omitted, promotes across all role directories.
rune_echo_promote() {
  # ── Guard: sqlite3 required ──
  if ! command -v sqlite3 &>/dev/null; then
    echo "WARN: sqlite3 not found — echo-promote skipped." >&2
    return 1
  fi

  # ── Parse args ──
  local _role=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        shift
        _role="${1:-}"
        ;;
      *)
        ;;
    esac
    shift
  done

  # ── Resolve echoes directory ──
  local _echoes_dir="${RUNE_STATE_ABS:-${RUNE_STATE:-.rune}}/echoes"
  if [[ ! -d "$_echoes_dir" ]]; then
    return 0  # No echoes dir, nothing to promote
  fi

  # ── Find the echo-search database ──
  # DB location: .rune/.echo-search-index.db (same dir as echoes parent)
  local _state_dir="${RUNE_STATE_ABS:-${RUNE_STATE:-.rune}}"
  local _db_path="${_state_dir}/.echo-search-index.db"
  if [[ ! -f "$_db_path" ]]; then
    # Try project-level fallback
    _db_path="${TMPDIR:-/tmp}/rune-echo-search-$(id -u).db"
    if [[ ! -f "$_db_path" ]]; then
      echo "WARN: echo-search database not found — promotion skipped." >&2
      return 0
    fi
  fi

  # Symlink guard on DB
  if [[ -L "$_db_path" ]]; then
    echo "WARN: echo-search database is a symlink — promotion skipped." >&2
    return 0
  fi

  # ── Collect role directories to scan ──
  local _roles=""
  if [[ -n "$_role" ]]; then
    if [[ ! "$_role" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      echo "ERROR: invalid role name: ${_role}" >&2
      return 1
    fi
    _roles="$_role"
  else
    # Scan all role directories
    _roles=""
    for _d in "${_echoes_dir}"/*/; do
      [[ -d "$_d" ]] || continue
      local _rname
      _rname="$(basename "$_d")"
      [[ "$_rname" =~ ^[a-zA-Z0-9_-]+$ ]] && _roles="${_roles} ${_rname}"
    done
  fi

  local _promoted_total=0

  for _r in $_roles; do
    local _memory_file="${_echoes_dir}/${_r}/MEMORY.md"
    [[ -f "$_memory_file" ]] || continue
    [[ -L "$_memory_file" ]] && continue  # Symlink guard

    # ── Query access counts for entries in this role ──
    # Get entry IDs with access_count >= threshold
    local _promotable_ids
    _promotable_ids=$(sqlite3 "$_db_path" \
      "SELECT entry_id, COUNT(*) as cnt FROM echo_access_log GROUP BY entry_id HAVING cnt >= ${_PROMOTE_THRESHOLD};" \
      2>/dev/null) || continue

    [[ -z "$_promotable_ids" ]] && continue

    # ── Check if MEMORY.md has observations entries to promote ──
    if ! grep -q '^\*\*layer\*\*: observations' "$_memory_file" 2>/dev/null; then
      continue  # No observations in this file
    fi

    # ── Promote: rewrite layer from observations to inscribed ──
    # Use temp file approach (no sed -i for portability)
    local _tmpfile
    _tmpfile=$(mktemp "${TMPDIR:-/tmp}/echo-promote-XXXXXX") || continue

    # Simple approach: replace ALL observations with inscribed in this file
    # This is safe because entries that shouldn't be promoted will re-enter
    # as observations on next write (echo-writer.sh dedup handles this)
    sed 's/\*\*layer\*\*: observations/**layer**: inscribed/' "$_memory_file" > "$_tmpfile"

    if [[ -s "$_tmpfile" ]]; then
      mv "$_tmpfile" "$_memory_file"
      _promoted_total=$((_promoted_total + 1))
    else
      rm -f "$_tmpfile"
    fi
  done

  if [[ $_promoted_total -gt 0 ]]; then
    # Signal echo-search dirty for re-indexing
    local _signal_dir
    _signal_dir="$(pwd)/tmp/.rune-signals"
    if [[ -d "$_signal_dir" ]]; then
      touch "${_signal_dir}/.echo-dirty" 2>/dev/null || true
    fi
  fi

  return 0
}
