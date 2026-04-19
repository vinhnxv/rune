#!/bin/bash
# scripts/lib/stop-failure-common.sh
# Shared error classification for StopFailure hook handlers.
# Source AFTER stop-hook-common.sh (depends on INPUT, CWD, _rune_detect_rate_limit).
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/stop-hook-common.sh"
#   source "${SCRIPT_DIR}/lib/stop-failure-common.sh"
#   classify_stop_failure
#   # Now use: ERROR_TYPE, WAIT_SECONDS, ERROR_ACTION
#
# EXPORTED GLOBALS (set by classify_stop_failure):
#   ERROR_TYPE    — one of: RATE_LIMIT, AUTH, SERVER, UNKNOWN
#   WAIT_SECONDS  — recommended wait before retry (integer seconds, capped)
#   ERROR_ACTION  — human-readable action: "wait", "halt", "backoff", "proceed"
#
# Bash 3.2 compatible (macOS): no associative arrays, no ${var,,} lowercase.

# Source guard — prevent double-loading
[[ -n "${_RUNE_STOP_FAILURE_COMMON_LOADED:-}" ]] && return 0
_RUNE_STOP_FAILURE_COMMON_LOADED=1

# Source talisman shard resolver if not already loaded
# STOP-003 FIX (audit 20260419-150325): renamed `local_dir` to `_lib_dir` —
# prior name visually collided with the bash `local` keyword, which made the
# code harder to skim even though `local` is only valid inside functions.
if ! type _rune_resolve_talisman_shard &>/dev/null; then
  _lib_dir="$(dirname "${BASH_SOURCE[0]}")"
  if [[ -f "${_lib_dir}/talisman-shard-path.sh" ]]; then
    source "${_lib_dir}/talisman-shard-path.sh"
  fi
  unset _lib_dir
fi

# ── classify_stop_failure() ──
# Classifies the stop failure error from hook input JSON and/or transcript tail.
# Sets globals: ERROR_TYPE, WAIT_SECONDS, ERROR_ACTION
#
# Input sources (tried in order):
#   1. Hook input JSON fields: .error, .error_message, .stop_reason (from $INPUT)
#   2. Transcript tail via _rune_detect_rate_limit() (if available)
#   3. Default: UNKNOWN
#
# Error classification (case-insensitive):
#   RATE_LIMIT — 429, rate limit, too many requests, overloaded_error, retry-after
#   AUTH       — 401, 403, auth fail, token expired, permission denied
#   SERVER     — 500, 502, 503, 504, internal error, service unavailable
#   UNKNOWN    — anything else
classify_stop_failure() {
  # Initialize globals
  ERROR_TYPE="UNKNOWN"
  WAIT_SECONDS=0
  ERROR_ACTION="proceed"

  # ── Step 1: Read talisman config for wait defaults ──
  local default_wait=60
  local max_wait=300

  local talisman_shard=""
  if type _rune_resolve_talisman_shard &>/dev/null; then
    talisman_shard=$(_rune_resolve_talisman_shard "arc" "${CWD:-}" 2>/dev/null || true)
  fi
  [[ -z "$talisman_shard" ]] && talisman_shard="${CWD:-}/tmp/.talisman-resolved/arc.json"

  if [[ -f "$talisman_shard" && ! -L "$talisman_shard" ]] && command -v jq &>/dev/null; then
    local _dw _mw
    _dw=$(jq -r '.rate_limit.default_wait_seconds // 60' "$talisman_shard" 2>/dev/null || echo "60")
    _mw=$(jq -r '.rate_limit.max_wait_seconds // 300' "$talisman_shard" 2>/dev/null || echo "300")
    # Validate numeric before use
    [[ "$_dw" =~ ^[0-9]+$ ]] && default_wait="$_dw"
    [[ "$_mw" =~ ^[0-9]+$ ]] && max_wait="$_mw"
  fi

  # ── Step 2: Extract error text from hook input JSON ──
  local error_text=""

  if [[ -n "${INPUT:-}" ]] && command -v jq &>/dev/null; then
    local _err _err_msg _stop_reason
    _err=$(printf '%s\n' "$INPUT" | jq -r '.error // empty' 2>/dev/null || true)
    _err_msg=$(printf '%s\n' "$INPUT" | jq -r '.error_message // empty' 2>/dev/null || true)
    _stop_reason=$(printf '%s\n' "$INPUT" | jq -r '.stop_reason // empty' 2>/dev/null || true)
    error_text="${_err} ${_err_msg} ${_stop_reason}"
  fi

  # ── Step 3: Classify based on error text (case-insensitive) ──
  # Convert to lowercase for pattern matching (Bash 3.2 compatible)
  local error_lower
  error_lower=$(printf '%s' "$error_text" | tr '[:upper:]' '[:lower:]')

  if _match_rate_limit "$error_lower"; then
    ERROR_TYPE="RATE_LIMIT"
    WAIT_SECONDS="$default_wait"
    ERROR_ACTION="wait"

    # Try to extract retry-after value from error text
    local retry_after
    retry_after=$(printf '%s' "$error_text" | grep -oiE 'retry.?after[":= ]+([0-9]+)' | grep -oE '[0-9]+' | tail -1 2>/dev/null || true)
    if [[ -n "$retry_after" ]] && [[ "$retry_after" =~ ^[0-9]+$ ]]; then
      WAIT_SECONDS="$retry_after"
    fi

  elif _match_auth "$error_lower"; then
    ERROR_TYPE="AUTH"
    WAIT_SECONDS=0
    ERROR_ACTION="halt"

  elif _match_server "$error_lower"; then
    ERROR_TYPE="SERVER"
    WAIT_SECONDS=30
    ERROR_ACTION="backoff"

  else
    # ── Step 4: Fallback — check transcript tail via _rune_detect_rate_limit ──
    # This catches rate limits visible in the transcript but not in structured error fields
    if type _rune_detect_rate_limit &>/dev/null; then
      local _session_id=""
      if [[ -n "${INPUT:-}" ]] && command -v jq &>/dev/null; then
        _session_id=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
        # SEC-004: Validate session_id format
        # NOTE: {1,128} quantifier not supported in Bash 3.2 (macOS) — use + and length check
        if [[ -n "$_session_id" ]] && { [[ ${#_session_id} -gt 128 ]] || [[ ! "$_session_id" =~ ^[a-zA-Z0-9_-]+$ ]]; }; then
          _session_id=""
        fi
      fi

      if [[ -n "$_session_id" ]] && [[ -n "${CWD:-}" ]]; then
        local _rl_wait
        if _rl_wait=$(_rune_detect_rate_limit "$_session_id" "$CWD" 2>/dev/null); then
          if [[ -n "$_rl_wait" ]] && [[ "$_rl_wait" =~ ^[0-9]+$ ]]; then
            ERROR_TYPE="RATE_LIMIT"
            WAIT_SECONDS="$_rl_wait"
            ERROR_ACTION="wait"
          fi
        fi
      fi
    fi
  fi

  # ── Step 5: Cap WAIT_SECONDS at max_wait ──
  if [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] && [[ "$max_wait" =~ ^[0-9]+$ ]]; then
    if [[ "$WAIT_SECONDS" -gt "$max_wait" ]]; then
      WAIT_SECONDS="$max_wait"
    fi
  fi

  return 0
}

# ── Pattern matchers (internal helpers) ──
# Each returns 0 if pattern matched, 1 otherwise.
# Input: already-lowercased error text string.

# RATE_LIMIT: 429, rate limit, too many requests, overloaded, retry-after
# Uses word-boundary matching (\b) for HTTP codes to avoid false positives
# (e.g., port 4290 should not match 429).
_match_rate_limit() {
  local text="$1"
  case "$text" in
    *overloaded_error*) return 0 ;;
  esac
  # Word-boundary matching for HTTP code 429 and text patterns
  if printf '%s' "$text" | grep -qE '(\b429\b|rate.?limit|too many requests|retry.?after)' 2>/dev/null; then
    return 0
  fi
  return 1
}

# AUTH: 401, 403, auth fail, token expired, permission denied
# Uses word-boundary matching (\b) for HTTP codes to avoid false positives
# (e.g., "503" should not substring-match "403", port 4013 should not match 401).
_match_auth() {
  local text="$1"
  # Word-boundary matching for HTTP codes 401/403 and text patterns
  if printf '%s' "$text" | grep -qE '(\b401\b|\b403\b|auth.*fail|token.*expired|permission.*denied)' 2>/dev/null; then
    return 0
  fi
  return 1
}

# SERVER: 500, 502, 503, 504, internal error, service unavailable
# Uses word-boundary matching (\b) for HTTP codes to avoid false positives
# (e.g., "5000" port should not match 500, "5032" should not match 503).
_match_server() {
  local text="$1"
  # Word-boundary matching for HTTP codes 500/502/503/504 and text patterns
  if printf '%s' "$text" | grep -qE '(\b500\b|\b502\b|\b503\b|\b504\b|internal.*error|service.*unavailable)' 2>/dev/null; then
    return 0
  fi
  return 1
}
