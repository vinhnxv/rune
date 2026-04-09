#!/usr/bin/env bash
# diagnose-session-identity.sh — Diagnostic tool for session identity system
#
# Usage: bash plugins/rune/scripts/diagnose-session-identity.sh
#
# Prints all 3 identity layers and their values, checks for format mismatches,
# lists active state files with ownership fields, and reports cache status.
# AC-7: Observability for session identity system.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf "\n=== Rune Session Identity Diagnostics ===\n\n"

# ── Layer 1: Config Dir ──
printf "LAYER 1: Config Dir\n"
_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_real_cfg=$(cd "$_cfg" 2>/dev/null && pwd -P || echo "$_cfg")
printf "  CLAUDE_CONFIG_DIR: %s\n" "${CLAUDE_CONFIG_DIR:-<unset, using default>}"
printf "  Resolved path:    %s\n" "$_real_cfg"
printf "  Exists:           %s\n" "$([ -d "$_real_cfg" ] && echo 'yes' || echo 'NO')"

# ── Layer 2: Session ID ──
printf "\nLAYER 2: Session ID\n"
printf "  CLAUDE_SESSION_ID: %s\n" "${CLAUDE_SESSION_ID:-<unset>}"
printf "  RUNE_SESSION_ID:   %s\n" "${RUNE_SESSION_ID:-<unset>}"

# Source resolver to get RUNE_CURRENT_SID
source "${SCRIPT_DIR}/resolve-session-identity.sh" 2>/dev/null || true
printf "  RUNE_CURRENT_SID:  %s\n" "${RUNE_CURRENT_SID:-<empty>}"

# Check format consistency
if [[ -n "${CLAUDE_SESSION_ID:-}" && -n "${RUNE_SESSION_ID:-}" ]]; then
  if [[ "$CLAUDE_SESSION_ID" == "$RUNE_SESSION_ID" ]]; then
    printf "  Format match:      YES (CLAUDE_SESSION_ID == RUNE_SESSION_ID)\n"
  else
    printf "  Format match:      MISMATCH!\n"
    printf "    CLAUDE_SESSION_ID: %s\n" "$CLAUDE_SESSION_ID"
    printf "    RUNE_SESSION_ID:   %s\n" "$RUNE_SESSION_ID"
  fi
fi

# ── Layer 3: Owner PID ──
printf "\nLAYER 3: Owner PID\n"
printf "  \$PPID:             %s\n" "${PPID:-<unset>}"
printf "  \$\$:               %s\n" "$$"
if [[ -n "${PPID:-}" ]]; then
  if rune_pid_alive "$PPID" 2>/dev/null; then
    printf "  PPID alive:        yes\n"
  else
    printf "  PPID alive:        NO (process may have exited)\n"
  fi
fi

# ── Cache Status ──
printf "\nCACHE STATUS\n"
_cache="${TMPDIR:-/tmp}/rune-identity-${PPID}"
if [[ -f "$_cache" && ! -L "$_cache" ]]; then
  printf "  Cache file:        %s\n" "$_cache"
  source "${SCRIPT_DIR}/lib/platform.sh" 2>/dev/null || true
  if declare -f _stat_mtime &>/dev/null; then
    _mtime=$(_stat_mtime "$_cache")
    _now=$(date +%s 2>/dev/null || echo "0")
    if [[ -n "$_mtime" && "$_mtime" =~ ^[0-9]+$ && "$_now" =~ ^[0-9]+$ ]]; then
      _age=$(( _now - _mtime ))
      printf "  Cache age:         %ds\n" "$_age"
      if [[ $_age -gt 3600 ]]; then
        printf "  TTL status:        EXPIRED (>1 hour)\n"
      else
        printf "  TTL status:        valid (%ds remaining)\n" "$(( 3600 - _age ))"
      fi
    fi
  fi
  printf "  Cache contents:\n"
  while IFS= read -r line; do
    printf "    %s\n" "$line"
  done < "$_cache"
elif [[ -L "$_cache" ]]; then
  printf "  Cache file:        SYMLINK (rejected for security)\n"
else
  printf "  Cache file:        not found (will be created on next resolution)\n"
fi

# ── Active State Files ──
printf "\nACTIVE STATE FILES\n"
_state_count=0
for _pattern in "tmp/.rune-arc-phase-*.json" "tmp/.rune-strive-*.json" "tmp/.rune-appraise-*.json" "tmp/.rune-audit-*.json"; do
  for _sf in ${_pattern}; do
    [[ -f "$_sf" ]] || continue
    _state_count=$(( _state_count + 1 ))
    _sf_sid=$(grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sf" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)"/\1/' || echo "<missing>")
    _sf_pid=$(grep -o '"owner_pid"[[:space:]]*:[[:space:]]*[0-9]*' "$_sf" 2>/dev/null | head -1 | sed 's/.*: *//' || echo "<missing>")
    _sf_cfg=$(grep -o '"config_dir"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sf" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)"/\1/' || echo "<missing>")
    printf "  %s\n" "$_sf"
    printf "    session_id: %s\n" "$_sf_sid"
    printf "    owner_pid:  %s\n" "$_sf_pid"
    printf "    config_dir: %s\n" "$_sf_cfg"
    # Check ownership
    if [[ "$_sf_cfg" != "$_real_cfg" ]]; then
      printf "    ownership:  DIFFERENT CONFIG DIR\n"
    elif [[ "$_sf_sid" == "${RUNE_CURRENT_SID:-}" && -n "$_sf_sid" ]]; then
      printf "    ownership:  THIS SESSION\n"
    elif [[ -n "$_sf_pid" && "$_sf_pid" =~ ^[0-9]+$ ]]; then
      if rune_pid_alive "$_sf_pid" 2>/dev/null; then
        printf "    ownership:  OTHER SESSION (pid %s alive)\n" "$_sf_pid"
      else
        printf "    ownership:  ORPHANED (pid %s dead)\n" "$_sf_pid"
      fi
    else
      printf "    ownership:  UNKNOWN\n"
    fi
  done
done

# Also check YAML frontmatter state files (.md)
for _sf in .rune/arc-phase-loop.local.md .rune/arc-batch-loop.local.md .rune/arc-hierarchy-loop.local.md .rune/arc-issues-loop.local.md; do
  [[ -f "$_sf" ]] || continue
  _state_count=$(( _state_count + 1 ))
  _sf_sid=$(grep "^session_id:" "$_sf" 2>/dev/null | head -1 | sed 's/session_id: *//' || echo "<missing>")
  _sf_pid=$(grep "^owner_pid:" "$_sf" 2>/dev/null | head -1 | sed 's/owner_pid: *//' || echo "<missing>")
  _sf_cfg=$(grep "^config_dir:" "$_sf" 2>/dev/null | head -1 | sed 's/config_dir: *//' || echo "<missing>")
  printf "  %s\n" "$_sf"
  printf "    session_id: %s\n" "$_sf_sid"
  printf "    owner_pid:  %s\n" "$_sf_pid"
  printf "    config_dir: %s\n" "$_sf_cfg"
done

if [[ $_state_count -eq 0 ]]; then
  printf "  (none found)\n"
fi

# ── Trace Log ──
printf "\nTRACE LOG\n"
_trace_log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
if [[ -f "$_trace_log" ]]; then
  printf "  Trace log: %s\n" "$_trace_log"
  _session_lines=$(grep -c "session" "$_trace_log" 2>/dev/null || echo "0")
  printf "  Session-related entries: %s\n" "$_session_lines"
  # Show last 5 session-related lines
  grep "session\|SESSION\|OWNERSHIP\|claim" "$_trace_log" 2>/dev/null | tail -5 | while IFS= read -r line; do
    printf "    %s\n" "$line"
  done
else
  printf "  Trace log: not found (set RUNE_TRACE=1 to enable)\n"
fi

printf "\n=== Diagnostics Complete ===\n"
