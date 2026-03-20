#!/usr/bin/env bash
# scripts/lib/find-teammate-session.sh
# Locates the most recent JSONL session file for a teammate process.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/find-teammate-session.sh"
#   session_file=$(_find_teammate_session "rune-smith-1" "rune-work-1742556000")
#
# Output:
#   Prints the path to the most recent JSONL session file on stdout,
#   or empty string if not found. Caller decides default behavior.
#
# Discovery heuristic:
#   1. Resolve session_dir from CLAUDE_CONFIG_DIR + project CWD encoding
#   2. Find .jsonl files modified within last 30 minutes
#   3. Sort by mtime descending, return newest
#
# Security:
#   - SEC-4: teammate_name validated against /^[a-zA-Z0-9_-]+$/
#   - DA-004: No symlink following (find -P, reject symlinked dirs)
#
# Requirements: bash 3.2+
# Compatible: macOS + Linux

# ── Fail-forward trap (OPERATIONAL library — ADR-002) ──
_rune_fail_forward() {
  local _crash_line="${BASH_LINENO[0]:-unknown}"
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "$_crash_line" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}" 2>/dev/null
  fi
  # Library function — return empty string instead of exit
  return 0
}
trap '_rune_fail_forward' ERR

# ── Source cross-platform stat helpers ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${_RUNE_PLATFORM:-}" ]]; then
  source "${SCRIPT_DIR}/platform.sh"
fi

# _find_teammate_session <teammate_name> <team_name>
# Returns: path to most recent JSONL file (stdout), or empty string
_find_teammate_session() {
  local teammate_name="${1:-}"
  local team_name="${2:-}"

  # ── Validate inputs ──
  if [[ -z "$teammate_name" || -z "$team_name" ]]; then
    return 0
  fi

  # SEC-4: Validate teammate_name (prevent path traversal)
  if [[ ! "$teammate_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    return 0
  fi

  # SEC-4: Validate team_name too
  if [[ ! "$team_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    return 0
  fi

  # ── Resolve session directory ──
  local CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local project_dir
  project_dir=$(pwd -P 2>/dev/null) || return 0

  # Encode project path: replace / with -, strip leading -
  local encoded="${project_dir//\//-}"
  encoded="${encoded#-}"

  # SEC-004: reject encoded paths with traversal
  [[ "$encoded" == *".."* ]] && return 0

  local session_dir="${CHOME}/projects/${encoded}"

  # ── Validate session directory ──
  if [[ ! -d "$session_dir" ]]; then
    return 0
  fi

  # DA-004: No symlink following
  if [[ -L "$session_dir" ]]; then
    return 0
  fi

  # ── Find JSONL files modified within last 30 minutes ──
  local now_epoch
  now_epoch=$(date +%s)
  local cutoff_epoch=$(( now_epoch - 1800 ))  # 30 minutes

  local best_file=""
  local best_mtime=0

  # DA-004: find -P (no symlink follow), -maxdepth 1
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue

    # DA-004: Skip symlinks
    [[ -L "$candidate" ]] && continue

    # Skip unreadable files
    [[ -r "$candidate" ]] || continue

    # Get mtime via platform.sh helper
    local fmtime
    fmtime=$(_stat_mtime "$candidate" 2>/dev/null) || continue
    fmtime="${fmtime:-0}"
    [[ "$fmtime" =~ ^[0-9]+$ ]] || continue

    # Skip files older than 30 minutes
    [[ "$fmtime" -lt "$cutoff_epoch" ]] && continue

    # Track newest file
    if [[ "$fmtime" -gt "$best_mtime" ]]; then
      best_mtime="$fmtime"
      best_file="$candidate"
    fi
  done < <(find -P "$session_dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null || true)

  # Output result (empty string if not found)
  if [[ -n "$best_file" ]]; then
    printf '%s\n' "$best_file"
  fi

  return 0
}
