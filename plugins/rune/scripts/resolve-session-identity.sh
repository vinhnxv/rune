#!/bin/bash
# scripts/resolve-session-identity.sh
# Resolve current session identity for cross-session ownership checks.
# Source this file — do not execute directly.
#
# Exports: RUNE_CURRENT_CFG (resolved config dir path)
#          RUNE_CURRENT_SID (resolved session ID — primary identifier)
#          rune_pid_alive()  (EPERM-safe PID liveness check function)
# Uses: $PPID (Claude Code process PID — fallback identifier)
#       CLAUDE_SESSION_ID / RUNE_SESSION_ID (primary session identifier)
#
# Cache: PID-scoped tmpfile at ${TMPDIR:-/tmp}/rune-identity-${PPID}
#   Format: Two shell assignments (RUNE_CURRENT_CFG=... RUNE_CURRENT_SID=...)
#           Values are printf-%q escaped for safe sourcing.
#   Lifecycle: Created on first resolution per session. Keyed by PPID, so
#              stale files from dead sessions are never read (different PPID).
#              No explicit cleanup needed — OS tmpdir rotation handles eviction.
#   Security: Symlink guard (! -L) before source; umask 077 on creation;
#             atomic write (tmp+mv) prevents partial reads.
#
# Pattern: Three-layer session identity (XVER-004 FIX)
#   Layer 1: config_dir (CLAUDE_CONFIG_DIR) — installation/account isolation
#   Layer 2: session_id (CLAUDE_SESSION_ID) — primary session identifier
#   Layer 3: owner_pid ($PPID) — fallback for liveness checks
#
# Ownership check pattern (for callers):
#   stored_cfg=$(jq -r '.config_dir // empty' "$f")
#   stored_sid=$(jq -r '.session_id // empty' "$f")
#   stored_pid=$(jq -r '.owner_pid // empty' "$f")
#   # Layer 1: config dir mismatch → different installation
#   if [[ -n "$stored_cfg" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
#   # Layer 2: session_id match → same session (definitive)
#   if [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" && "$stored_sid" == "$RUNE_CURRENT_SID" ]]; then
#     : # same session, proceed
#   elif [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" && "$stored_sid" != "$RUNE_CURRENT_SID" ]]; then
#     continue  # different session, skip
#   else
#     # Layer 3: PID mismatch + alive → different session (fallback)
#     #          PID mismatch + dead → orphaned state (proceed with cleanup)
#     if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
#       rune_pid_alive "$stored_pid" && continue  # alive = different session
#     fi
#   fi

# ── Source platform.sh for _stat_mtime / _stat_uid ──
# BACK-004 FIX: Source platform.sh here (same pattern as lib/find-teammate-session.sh)
# so macOS users don't pay 2 wasted stat forks per hook cold-start before the inline
# `stat -c` fallback fails. Fail-soft (|| true) because this file is sourced — we must
# not hijack caller's error handling.
if [[ -z "${_RUNE_PLATFORM_SOURCED:-}" ]]; then
  _RSID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null)" || _RSID_DIR=""
  if [[ -n "$_RSID_DIR" && -f "${_RSID_DIR}/lib/platform.sh" ]]; then
    # shellcheck source=lib/platform.sh
    source "${_RSID_DIR}/lib/platform.sh" 2>/dev/null || true
  fi
  unset _RSID_DIR
fi

# ── Cache file path (PID-scoped) ──
_RUNE_IDENTITY_CACHE="${TMPDIR:-/tmp}/rune-identity-${PPID}"

# ── Try reading from cache before expensive resolution ──
# SEC: Never source cache files from shared /tmp — parse key=value safely instead.
# XVER-SEC-001 FIX: Replaced `source` with read-based parsing + UID ownership check.
if [[ -z "${RUNE_CURRENT_CFG:-}" && -f "$_RUNE_IDENTITY_CACHE" && ! -L "$_RUNE_IDENTITY_CACHE" ]]; then
  # TTL GUARD (v2.39.1): Evict stale cache to prevent PID reuse reading wrong values.
  # Cache is PID-scoped, but on long-running machines PIDs can wrap around. 1-hour TTL
  # ensures stale cache files from dead sessions with recycled PIDs are discarded.
  _RUNE_CACHE_TTL=3600  # 1 hour
  _cache_mtime_raw=""
  # Cross-platform stat: macOS uses -f, Linux uses -c (platform.sh may not be available here)
  # PAT-001 FIX: Prefer platform.sh helpers when available; fall back to inline stat
  if type _stat_mtime &>/dev/null; then
    _cache_mtime_raw=$(_stat_mtime "$_RUNE_IDENTITY_CACHE" 2>/dev/null || echo "")
  else
    _cache_mtime_raw=$(stat -c '%Y' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || stat -f '%m' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || echo "")
  fi
  _cache_now=$(date +%s 2>/dev/null || echo "0")
  if [[ -n "$_cache_mtime_raw" && "$_cache_mtime_raw" =~ ^[0-9]+$ && "$_cache_now" =~ ^[0-9]+$ && "$_cache_now" != "0" ]]; then
    if [[ $(( _cache_now - _cache_mtime_raw )) -gt $_RUNE_CACHE_TTL ]]; then
      rm -f "$_RUNE_IDENTITY_CACHE" 2>/dev/null
      # Fall through to fresh resolution below
    fi
  fi

  # Verify file is owned by current user (prevents attacker-planted files)
  # Re-check -f after potential TTL eviction
  if [[ -f "$_RUNE_IDENTITY_CACHE" && ! -L "$_RUNE_IDENTITY_CACHE" ]]; then
    # PAT-001 FIX: Prefer platform.sh _stat_uid when available
    if type _stat_uid &>/dev/null; then
      _cache_uid=$(_stat_uid "$_RUNE_IDENTITY_CACHE" 2>/dev/null || echo "")
    else
      _cache_uid=$(stat -c '%u' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || stat -f '%u' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || echo "")
    fi
    # PAT-007 FIX: Use bash built-in $UID (zero forks) instead of $(id -u)
    if [[ -n "$_cache_uid" && "$_cache_uid" == "${UID:-$(id -u)}" ]]; then
      # Parse key=value lines safely — only accept expected variable names
      while IFS='=' read -r _key _val; do
        _key="${_key## }"  # trim leading space
        _val="${_val## }"  # trim leading space
        # Remove printf %q quoting (leading/trailing $'...' or '...')
        _val="${_val#\$\'}" ; _val="${_val%\'}"
        _val="${_val#\'}"   ; _val="${_val%\'}"
        case "$_key" in
          RUNE_CURRENT_CFG) RUNE_CURRENT_CFG="$_val" ;;
          RUNE_CURRENT_SID) RUNE_CURRENT_SID="$_val" ;;
          *) ;; # ignore unexpected keys
        esac
      done < "$_RUNE_IDENTITY_CACHE"
    fi
  fi  # end TTL re-check guard
fi

if [[ -z "${RUNE_CURRENT_CFG:-}" ]]; then
  RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  RUNE_CURRENT_CFG=$(cd "$RUNE_CURRENT_CFG" 2>/dev/null && pwd -P || echo "$RUNE_CURRENT_CFG")
  export RUNE_CURRENT_CFG
fi

# XVER-004 FIX: Resolve session ID as PRIMARY identifier
# Priority: CLAUDE_SESSION_ID > RUNE_SESSION_ID > empty (fallback to PPID)
if [[ -z "${RUNE_CURRENT_SID:-}" ]]; then
  RUNE_CURRENT_SID="${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-}}"
  # Validate format: alphanumeric + hyphens/underscores only, max 64 chars
  if [[ -n "$RUNE_CURRENT_SID" && "$RUNE_CURRENT_SID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    RUNE_CURRENT_SID="${RUNE_CURRENT_SID:0:64}"
  else
    RUNE_CURRENT_SID=""  # Invalid or missing — fall back to PPID-based checks
  fi
  export RUNE_CURRENT_SID

  # FORMAT CONSISTENCY ASSERTION (v2.39.1, AC-4): When native CLAUDE_SESSION_ID
  # ships, it might differ from the hook-bridged RUNE_SESSION_ID. Log diagnostic
  # when both sources are available and diverge — prefer CLAUDE_SESSION_ID (authoritative).
  if [[ -n "${CLAUDE_SESSION_ID:-}" && -n "${RUNE_SESSION_ID:-}" ]]; then
    if [[ "$CLAUDE_SESSION_ID" != "$RUNE_SESSION_ID" ]]; then
      # Diagnostic trace — not an error, just a mismatch to investigate during migration
      if [[ "${RUNE_TRACE:-}" == "1" ]]; then
        _rune_trace_log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
        [[ ! -L "$_rune_trace_log" ]] && \
          echo "[resolve-session-identity] WARN: session_id source mismatch — CLAUDE_SESSION_ID='${CLAUDE_SESSION_ID:0:16}...' vs RUNE_SESSION_ID='${RUNE_SESSION_ID:0:16}...'" \
          >> "$_rune_trace_log" 2>/dev/null
      fi
    fi
  fi
fi

# OBSERVABILITY (v2.39.1, AC-7): Log session identity resolution result
if [[ "${RUNE_TRACE:-}" == "1" ]]; then
  _rune_sid_source="unknown"
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then _rune_sid_source="CLAUDE_SESSION_ID"
  elif [[ -n "${RUNE_SESSION_ID:-}" ]]; then _rune_sid_source="RUNE_SESSION_ID"
  elif [[ -n "${RUNE_CURRENT_SID:-}" ]]; then _rune_sid_source="cache"
  fi
  _rune_trace_log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
  [[ ! -L "$_rune_trace_log" ]] && \
    echo "[resolve-session-identity] SESSION-ID: source=${_rune_sid_source} value=${RUNE_CURRENT_SID:0:16}... cache=${_RUNE_IDENTITY_CACHE}" \
    >> "$_rune_trace_log" 2>/dev/null
fi

# ── Write cache atomically (create OR refresh) ──
# BACK-IDN-001 FIX (v2.53.2): Refresh cache when env now has a SID but cache had empty.
# Previously: cache was written once and never updated. If the FIRST hook to source
# this file ran before RUNE_SESSION_ID was bridged (early PreToolUse before SessionStart
# finishes), the cache pinned RUNE_CURRENT_SID='' for the session lifetime. Downstream
# ownership checks (rune-arc-init-state.sh skill mode) then mis-judged same-session
# checkpoints as "foreign PID", refusing state-file recovery.
#
# Fix: write cache if missing OR if cached SID is empty/stale while env has a fresh one.
_RUNE_CACHE_NEEDS_WRITE=0
if [[ -n "${RUNE_CURRENT_CFG:-}" ]]; then
  if [[ ! -f "$_RUNE_IDENTITY_CACHE" ]]; then
    _RUNE_CACHE_NEEDS_WRITE=1
  elif [[ -n "${RUNE_CURRENT_SID:-}" ]]; then
    # Re-parse cached SID to compare (cheap — single read of the small cache file)
    _cached_sid_line=$(grep '^RUNE_CURRENT_SID=' "$_RUNE_IDENTITY_CACHE" 2>/dev/null | head -1)
    _cached_sid="${_cached_sid_line#RUNE_CURRENT_SID=}"
    # Strip printf %q quoting
    _cached_sid="${_cached_sid#\$\'}" ; _cached_sid="${_cached_sid%\'}"
    _cached_sid="${_cached_sid#\'}"   ; _cached_sid="${_cached_sid%\'}"
    if [[ -z "$_cached_sid" || "$_cached_sid" != "$RUNE_CURRENT_SID" ]]; then
      _RUNE_CACHE_NEEDS_WRITE=1
    fi
  fi
fi
if [[ "$_RUNE_CACHE_NEEDS_WRITE" == "1" ]]; then
  _tmp_cache="${_RUNE_IDENTITY_CACHE}.$$"
  (umask 077 && printf 'RUNE_CURRENT_CFG=%q\nRUNE_CURRENT_SID=%q\n' \
    "$RUNE_CURRENT_CFG" "$RUNE_CURRENT_SID" > "$_tmp_cache") 2>/dev/null
  mv "$_tmp_cache" "$_RUNE_IDENTITY_CACHE" 2>/dev/null || rm -f "$_tmp_cache" 2>/dev/null
fi
unset _RUNE_CACHE_NEEDS_WRITE _cached_sid_line _cached_sid

# ── PID liveness check (EPERM-safe) ──
# kill -0 returns non-zero for BOTH "no such process" (ESRCH) AND "permission denied" (EPERM).
# EPERM means the process IS alive but owned by another user — treat as alive to avoid
# cross-session contamination in restricted/multi-user runtimes.
#
# Usage: rune_pid_alive "$pid" && continue  # alive = skip
# Returns: 0 if alive (or EPERM), 1 if dead
rune_pid_alive() {
  local pid="$1"
  # MON-005 FIX (audit 20260419-150325): numeric bounds (1..4194304) before
  # kill -0. Linux's kernel.pid_max default is 2^22; 4194304 is a generous
  # ceiling that rejects clearly-forged values like 999999999999 without
  # requiring a runtime pid_max probe.
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && "$pid" -lt 4194304 ]] || return 1
  # Single kill -0 call — captures both exit code and stderr in one shot.
  # Fixes BACK-P2-001: eliminates TOCTOU window from double kill -0 calls.
  local err rc
  err=$(kill -0 "$pid" 2>&1) && rc=0 || rc=$?
  [[ $rc -eq 0 ]] && return 0  # definitely alive
  # kill -0 failed — distinguish ESRCH (dead) from EPERM (alive, different user)
  case "$err" in
    *"Operation not permitted"*|*"EPERM"*|*"permission"*)
      return 0  # alive but owned by another user
      ;;
    *)
      return 1  # dead (ESRCH or other error)
      ;;
  esac
}
