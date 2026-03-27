#!/bin/bash
# lib/mcp-pkg-manager.sh — Shared MCP package management with version check + staleness cache
#
# Provides: mcp_ensure_package PACKAGE VERSION BINARY
#   1. Fast path: binary exists + version matches + cache fresh → return 0
#   2. Stale/mismatch: auto-update global install → return 0
#   3. No npm: return 1 (caller should fallback to npx)
#
# Cache: ${TMPDIR}/rune-mcp-pkg-${BINARY}.stamp
#   - Stores last-check epoch + installed version
#   - Re-checks every STALENESS_TTL seconds (default: 7 days)
#   - Version mismatch triggers immediate update regardless of TTL

STALENESS_TTL="${MCP_STALENESS_TTL:-604800}"  # 7 days in seconds

# Get installed version of a global npm package
# Usage: _mcp_installed_version PACKAGE
_mcp_installed_version() {
  local pkg="$1"
  npm list -g --depth=0 --json 2>/dev/null | jq -r ".dependencies[\"${pkg}\"].version // empty" 2>/dev/null || true
}

# Check if cache stamp is still fresh
# Usage: _mcp_cache_fresh BINARY
_mcp_cache_fresh() {
  local binary="$1"
  local stamp="${TMPDIR:-/tmp}/rune-mcp-pkg-${binary}.stamp"
  [[ -f "$stamp" && ! -L "$stamp" ]] || return 1
  local last_check installed_ver
  last_check=$(head -1 "$stamp" 2>/dev/null || echo 0)
  [[ "$last_check" =~ ^[0-9]+$ ]] || return 1  # treat non-numeric as stale
  local now
  now=$(date +%s)
  local age=$(( now - last_check ))
  [[ "$age" -lt "$STALENESS_TTL" ]]
}

# Read cached version from stamp
# Usage: _mcp_cached_version BINARY
_mcp_cached_version() {
  local binary="$1"
  local stamp="${TMPDIR:-/tmp}/rune-mcp-pkg-${binary}.stamp"
  [[ -f "$stamp" && ! -L "$stamp" ]] || return 1
  sed -n '2p' "$stamp" 2>/dev/null || true
}

# Write cache stamp
# Usage: _mcp_write_stamp BINARY VERSION
_mcp_write_stamp() {
  local binary="$1" version="$2"
  local stamp="${TMPDIR:-/tmp}/rune-mcp-pkg-${binary}.stamp"
  local tmp_stamp="${stamp}.tmp.$$"
  printf '%s\n%s\n' "$(date +%s)" "$version" > "$tmp_stamp" 2>/dev/null
  mv -f "$tmp_stamp" "$stamp" 2>/dev/null || true
}

# Main entry point
# Usage: mcp_ensure_package PACKAGE VERSION BINARY
# Returns: 0 if binary is ready, 1 if caller should fallback to npx
mcp_ensure_package() {
  local package="$1" version="$2" binary="$3"

  # No binary found at all → need install
  if ! command -v "$binary" >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
      echo "Installing ${package}@${version} globally..." >&2
      npm install -g "${package}@${version}" --silent 2>&1 >&2 || true
      if command -v "$binary" >/dev/null 2>&1; then
        _mcp_write_stamp "$binary" "$version"
        return 0
      fi
    fi
    return 1  # no npm or install failed
  fi

  # Binary exists — check version freshness
  # Fast path: cache is fresh AND version matches → skip npm query
  local cached_ver
  cached_ver=$(_mcp_cached_version "$binary" 2>/dev/null || true)
  if [[ "$cached_ver" == "$version" ]] && _mcp_cache_fresh "$binary" 2>/dev/null; then
    return 0  # cache fresh, version matches pinned version
  fi

  # Cache stale or version unknown — query actual installed version
  if command -v npm >/dev/null 2>&1; then
    local installed_ver
    installed_ver=$(_mcp_installed_version "$package")

    if [[ "$installed_ver" == "$version" ]]; then
      # Correct version, refresh stamp
      _mcp_write_stamp "$binary" "$version"
      return 0
    fi

    # Version mismatch or not found — update
    echo "Updating ${package}: ${installed_ver:-unknown} → ${version}..." >&2
    npm install -g "${package}@${version}" --silent 2>&1 >&2 || true
    _mcp_write_stamp "$binary" "$version"
  fi

  # Binary exists (may be outdated if npm failed), still usable
  return 0
}
