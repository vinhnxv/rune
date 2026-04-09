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
  _cache_mtime_raw=$(stat -c '%Y' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || stat -f '%m' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || echo "")
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
    _cache_uid=$(stat -c '%u' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || stat -f '%u' "$_RUNE_IDENTITY_CACHE" 2>/dev/null || echo "")
    if [[ -n "$_cache_uid" && "$_cache_uid" == "$(id -u)" ]]; then
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

# ── Write cache atomically (if not already cached) ──
if [[ -n "${RUNE_CURRENT_CFG:-}" && ! -f "$_RUNE_IDENTITY_CACHE" ]]; then
  _tmp_cache="${_RUNE_IDENTITY_CACHE}.$$"
  (umask 077 && printf 'RUNE_CURRENT_CFG=%q\nRUNE_CURRENT_SID=%q\n' \
    "$RUNE_CURRENT_CFG" "$RUNE_CURRENT_SID" > "$_tmp_cache") 2>/dev/null
  mv "$_tmp_cache" "$_RUNE_IDENTITY_CACHE" 2>/dev/null || rm -f "$_tmp_cache" 2>/dev/null
fi

# ── PID liveness check (EPERM-safe) ──
# kill -0 returns non-zero for BOTH "no such process" (ESRCH) AND "permission denied" (EPERM).
# EPERM means the process IS alive but owned by another user — treat as alive to avoid
# cross-session contamination in restricted/multi-user runtimes.
#
# Usage: rune_pid_alive "$pid" && continue  # alive = skip
# Returns: 0 if alive (or EPERM), 1 if dead
rune_pid_alive() {
  local pid="$1"
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
