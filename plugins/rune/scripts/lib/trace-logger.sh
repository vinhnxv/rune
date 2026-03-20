#!/bin/bash
# Shared trace logging for Rune hook scripts
# Source this file to get _trace() — caller name is auto-detected via BASH_SOURCE[1]
#
# Usage:
#   source "${SCRIPT_DIR}/lib/trace-logger.sh"
#   _trace "message here"
#
# Requires RUNE_TRACE_LOG to be set before sourcing, or falls back to default.
# Set RUNE_TRACE=1 to enable output. Zero overhead when disabled.

RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"

_trace() {
  [[ "${RUNE_TRACE:-}" == "1" ]] || return 0
  [[ ! -L "$RUNE_TRACE_LOG" ]] || return 0
  local _caller="${BASH_SOURCE[1]##*/}"
  _caller="${_caller%.sh}"
  printf '[%s] %s: %s\n' "$(date +%H:%M:%S)" "$_caller" "$*" >> "$RUNE_TRACE_LOG" 2>/dev/null
  return 0
}
