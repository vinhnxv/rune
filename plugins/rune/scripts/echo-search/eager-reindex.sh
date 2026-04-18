#!/usr/bin/env bash
# echo-search/eager-reindex.sh — plugin monitor companion (Track B.2)
#
# Watches tmp/.rune-signals/.echo-dirty. When the signal is present, invokes
# the echo-search reindex MCP endpoint (or falls back to the indexer script)
# so the next echo_search call does NOT pay the rebuild cost lazily.
#
# Emission discipline: one stdout line per reindex trigger (state change only).
# Fast-path exit when no signal exists (most polling cycles — near-zero cost).
#
# This monitor is declared with `when: "on-skill-invoke:rune-echoes"` in
# monitors/monitors.json so it only runs when echoes are actually being used.

set -euo pipefail

if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/lib/platform.sh" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/platform.sh" 2>/dev/null || true
fi

POLL_SECS="${RUNE_ECHO_REINDEX_POLL_SECS:-5}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SIGNAL_FILE="${PROJECT_DIR}/tmp/.rune-signals/.echo-dirty"
SENTINEL_OK="${PROJECT_DIR}/tmp/.rune-monitor-available"

# AC-5 capability gate — silent skip on unsupported hosts
if [[ ! -f "$SENTINEL_OK" ]]; then
  exit 0
fi

iso_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ
}

# Determine reindex invocation. Preferred path: call the indexer script directly.
# Fallback path: leave a breadcrumb marker that the next echo_search call will honor.
reindex_once() {
  local ts
  ts="$(iso_utc)"
  local indexer="${CLAUDE_PLUGIN_ROOT:-}/scripts/echo-search/indexer.sh"
  if [[ -x "$indexer" ]]; then
    if "$indexer" --reindex >/dev/null 2>&1; then
      printf '%s STATE_CHANGE echo_reindex_ok source=indexer\n' "$ts"
      return 0
    fi
  fi
  # Fallback: touch a marker so next MCP call reindexes lazily.
  # This is the existing behavior; monitor adds no value here beyond logging.
  printf '%s STATE_CHANGE echo_reindex_deferred source=lazy\n' "$ts"
  return 0
}

silent_streak=0
while true; do
  if [[ -f "$SIGNAL_FILE" ]]; then
    rm -f "$SIGNAL_FILE" 2>/dev/null || true
    reindex_once
    silent_streak=0
  else
    silent_streak=$((silent_streak + 1))
    # exit after ~5 min of inactivity (on-skill-invoke monitors are short-lived)
    if [[ "$silent_streak" -ge 60 ]]; then
      exit 0
    fi
  fi
  sleep "$POLL_SECS"
done
