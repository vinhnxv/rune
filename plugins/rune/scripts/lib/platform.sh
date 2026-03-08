#!/bin/bash
# scripts/lib/platform.sh
# Cross-platform stat helpers. Detects OS ONCE at source time.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/platform.sh"
#   mtime=$(_stat_mtime "$file")     # returns mtime or empty string
#   uid=$(_stat_uid "$file")         # returns uid or empty string
#
# DESIGN:
#   - OS detected once via uname (cached in _RUNE_PLATFORM)
#   - Each function calls the correct stat variant directly — no fallback chain
#   - Returns empty string on failure (caller decides default)
#   - Safe under set -euo pipefail (|| true on stat, explicit return 0)
#
# SOURCING GUARD: Safe to source multiple times (idempotent).

if [[ -z "${_RUNE_PLATFORM:-}" ]]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin) _RUNE_PLATFORM=darwin ;;
    *)      _RUNE_PLATFORM=linux ;;
  esac
  readonly _RUNE_PLATFORM
fi

# _stat_mtime <path>
# Prints modification time as Unix epoch. Empty string on failure.
_stat_mtime() {
  local _path="$1"
  if [[ "$_RUNE_PLATFORM" == "darwin" ]]; then
    stat -f '%m' "$_path" 2>/dev/null || true
  else
    stat -c '%Y' "$_path" 2>/dev/null || true
  fi
}

# _stat_uid <path>
# Prints owner UID. Empty string on failure.
_stat_uid() {
  local _path="$1"
  if [[ "$_RUNE_PLATFORM" == "darwin" ]]; then
    stat -f '%u' "$_path" 2>/dev/null || true
  else
    stat -c '%u' "$_path" 2>/dev/null || true
  fi
}
