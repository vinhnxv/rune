#!/bin/bash
# scripts/lib/platform.sh
# Cross-platform helpers. Detects OS ONCE at source time.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/platform.sh"
#   mtime=$(_stat_mtime "$file")               # returns mtime or empty string
#   uid=$(_stat_uid "$file")                   # returns uid or empty string
#   epoch=$(_parse_iso_epoch "$iso_timestamp")  # returns epoch seconds or "0"
#   epoch_ms=$(_now_epoch_ms)                   # returns current epoch in milliseconds
#
# DESIGN:
#   - OS detected once via uname (cached in _RUNE_PLATFORM)
#   - Each function calls the correct variant directly per platform
#   - Returns empty string or "0" on failure (caller decides default)
#   - Safe under set -euo pipefail (|| true on commands, explicit return 0)
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

# _parse_iso_epoch <iso-timestamp>
# Parses ISO-8601 timestamp (e.g. "2026-03-08T12:00:00.000Z") to Unix epoch seconds.
# Strips fractional seconds before parsing. Returns "0" on failure.
# Fallback chain: gdate (GNU on macOS) → date -d (GNU on Linux) → date -j (BSD on macOS)
_parse_iso_epoch() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && echo "0" && return 0
  # Strip optional fractional seconds (.NNN) before terminal Z
  if [[ "$ts" =~ \.[0-9]+Z$ ]]; then
    ts="${ts%%.*}Z"
  fi
  # Strip timezone offset suffix (+00:00) if present, replace with Z
  ts="${ts%+*}"
  ts="${ts%Z}Z"
  # Try gdate (GNU coreutils on macOS) first
  gdate -d "$ts" +%s 2>/dev/null && return 0
  # Try GNU date (Linux)
  date -d "$ts" +%s 2>/dev/null && return 0
  # Try BSD date (macOS native)
  date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null && return 0
  echo "0"
}

# _parse_iso_epoch_ms <iso-timestamp>
# Like _parse_iso_epoch but returns milliseconds. "0" on failure.
_parse_iso_epoch_ms() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && echo "0" && return 0
  # Strip fractional seconds (capture for ms if available, but not worth the complexity)
  if [[ "$ts" =~ \.[0-9]+Z$ ]]; then
    ts="${ts%%.*}Z"
  fi
  ts="${ts%+*}"
  ts="${ts%Z}Z"
  # gdate supports %s%3N (milliseconds)
  gdate -d "$ts" +%s%3N 2>/dev/null && return 0
  # GNU date on Linux supports %s%3N
  if date --version &>/dev/null 2>&1; then
    date -d "$ts" +%s%3N 2>/dev/null && return 0
  fi
  # BSD fallback: seconds * 1000 (loses sub-second precision)
  local ep
  ep=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo "0")
  echo $(( ep * 1000 ))
}

# _now_epoch_ms
# Returns current epoch in milliseconds. Cross-platform.
_now_epoch_ms() {
  gdate +%s%3N 2>/dev/null && return 0
  if date --version &>/dev/null 2>&1; then
    date +%s%3N 2>/dev/null && return 0
  fi
  echo $(( $(date +%s) * 1000 ))
}

# _resolve_path <path>
# Resolves to canonical absolute path. Cross-platform.
# Fallback chain: grealpath → realpath → readlink -f → literal path
_resolve_path() {
  local _p="$1"
  grealpath -m "$_p" 2>/dev/null ||
  realpath -m "$_p" 2>/dev/null ||
  readlink -f "$_p" 2>/dev/null ||
  echo "$_p"
}
