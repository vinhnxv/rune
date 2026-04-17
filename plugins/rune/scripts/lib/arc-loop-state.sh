#!/bin/bash
# plugins/rune/scripts/lib/arc-loop-state.sh
#
# Shared library for arc phase-loop state file lifecycle operations.
# Single source of truth for creation, recovery, deletion, and integrity
# logging of `.rune/arc-{phase|batch|hierarchy|issues}-loop.local.md` state
# files (plan AC-5).
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/platform.sh"             # _stat_mtime, _parse_iso_epoch
#   source "${SCRIPT_DIR}/lib/rune-state.sh"           # RUNE_STATE
#   source "${SCRIPT_DIR}/lib/arc-stop-hook-common.sh" # arc_delete_state_file (wrapped by gate)
#   source "${SCRIPT_DIR}/lib/arc-loop-state.sh"       # this file
#
# PUBLIC FUNCTIONS (all honor _rune_fail_forward — never abort caller):
#   arc_state_file_path [kind]                        -> stdout: canonical state file path
#   arc_state_flag_enabled                            -> exit 0 if enabled, 1 otherwise
#   arc_state_integrity_log action cause state_file [extra_json]
#   arc_state_pending_phases checkpoint_path          -> stdout: count | -1 on parse error
#   arc_state_should_delete state_file                -> exit 0 (delete ok) | 1 (defer)
#   arc_state_touch state_file                        -> exit 0
#   arc_state_recover [kind]                          -> exit 0 on recreate | 1 on no-checkpoint
#
# DESIGN NOTES:
#   - Bash 3.2 compatible (no assoc arrays, no `${var,,}`)
#   - Atomic writes via mktemp-in-same-dir + mv -f (XM-1, R17)
#   - jq-based field extraction; returns -1 on parse failure (XM-3)
#   - JSONL log construction via `jq -nc --arg ...` (SEC: CWE-93 newline injection)
#   - Log rotation: pre-append check at 5MB cap, serialized via mkdir lock (XM-4, R22)
#   - Secure perms: umask 077 + chmod 600 on log create
#   - Trust boundary: CLAUDE_CONFIG_DIR via CHOME pattern, never trusted beyond type check
#   - No `sed -i`, no `set -e` beyond caller's, no exit inside functions
#
# See plans/2026-04-17-fix-arc-state-file-reliability-plan.md for AC mapping.

# ─────────────────────────────────────────────────────────────────────────────
# Constants (override-able via environment for testing)
# ─────────────────────────────────────────────────────────────────────────────

: "${RUNE_ARC_INTEG_LOG:=.rune/arc-integrity-log.jsonl}"
: "${RUNE_ARC_INTEG_LOG_MAX_BYTES:=5242880}"  # 5 MB (XM-4)
: "${RUNE_ARC_STATE_TOUCH_THROTTLE_SEC:=60}"
: "${RUNE_ARC_MAX_CREDIBLE_AGE_MIN:=480}"     # XM-5: clock-skew sanity cap
: "${RUNE_ARC_STATE_STALE_MULTIPLIER:=3}"     # deletion threshold multiplier

# Valid loop kinds (prevents prototype pollution and arbitrary filename injection)
_ARC_LOOP_KINDS="phase batch hierarchy issues"

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_file_path [kind] → stdout: canonical state file path
# ─────────────────────────────────────────────────────────────────────────────
# Default kind=phase. Reject unknown kinds via allowlist.
arc_state_file_path() {
  local _kind="${1:-phase}"
  case " $_ARC_LOOP_KINDS " in
    *" $_kind "*) ;;
    *) return 1 ;;  # invalid kind
  esac
  # RUNE_STATE is set by lib/rune-state.sh; default to .rune if unset
  local _base="${RUNE_STATE:-.rune}"
  printf '%s/arc-%s-loop.local.md' "${CWD:-$PWD}/${_base}" "$_kind" \
    | sed 's|//|/|g'
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_flag_enabled → exit 0 if enabled, 1 otherwise
# ─────────────────────────────────────────────────────────────────────────────
# Reads arc.state_file.code_enforced_writes from talisman. Prefers resolved
# shard (tmp/.talisman-resolved/arc.json); falls back to literal false.
# Issue 8: flag is OPERATIONAL, not security — never gate security checks on it.
arc_state_flag_enabled() {
  local _shard="${CWD:-$PWD}/tmp/.talisman-resolved/arc.json"
  if [ -f "$_shard" ] && command -v jq >/dev/null 2>&1; then
    local _val
    _val=$(jq -r '.state_file.code_enforced_writes // false' "$_shard" 2>/dev/null)
    [ "$_val" = "true" ] && return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_pending_phases checkpoint_path → stdout: count | -1 on error
# ─────────────────────────────────────────────────────────────────────────────
# XM-3: return -1 (NOT 0) on jq parse failure so callers can treat as defer.
# Counts both "pending" AND "in_progress" — the current phase is in_progress
# (API fitness delta: plan §6.6 corrected this from the original draft).
arc_state_pending_phases() {
  local _cp="$1"
  if [ -z "$_cp" ] || [ ! -f "$_cp" ]; then
    echo "-1"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "-1"
    return 0
  fi
  local _count
  _count=$(jq -r '
    if (.phases // null) == null then -1
    else [ .phases | to_entries[]
           | select(.value.status == "pending" or .value.status == "in_progress") ]
         | length
    end
  ' "$_cp" 2>/dev/null)
  case "$_count" in
    ''|*[!0-9-]*) echo "-1" ;;
    *) echo "$_count" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_integrity_log action cause state_file [extra_json]
# ─────────────────────────────────────────────────────────────────────────────
# Secure JSONL via jq -nc --arg (CWE-93 immune). Pre-append rotation at cap.
# All string fields enum-validated where the plan specifies (§16).
arc_state_integrity_log() {
  local _action="$1" _cause="$2" _state_file="$3" _extra="${4:-{}}"
  [ -z "$_action" ] && return 0  # silent no-op if misused
  command -v jq >/dev/null 2>&1 || return 0

  local _log_path="${CWD:-$PWD}/${RUNE_ARC_INTEG_LOG}"
  local _log_dir; _log_dir=$(dirname "$_log_path")
  mkdir -p "$_log_dir" 2>/dev/null || return 0

  # Rotation under mkdir lock (XM-4)
  local _lock="${_log_path%.jsonl}-rotate-lock.d"
  if [ -f "$_log_path" ]; then
    local _sz
    _sz=$(wc -c < "$_log_path" 2>/dev/null | tr -d ' ')
    _sz="${_sz:-0}"
    if [ "$_sz" -ge "$RUNE_ARC_INTEG_LOG_MAX_BYTES" ] 2>/dev/null; then
      if mkdir "$_lock" 2>/dev/null; then
        mv -f "$_log_path" "${_log_path%.jsonl}-$(date +%Y%m%d-%H%M%S).jsonl" 2>/dev/null || true
        rmdir "$_lock" 2>/dev/null || true
      fi
    fi
  fi

  # Identity fields
  local _sid="${RUNE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
  case "$_sid" in *[!a-zA-Z0-9_-]*|'') _sid="unknown" ;; esac
  local _pid="$PPID"
  case "$_pid" in ''|*[!0-9]*) _pid="0" ;; esac
  local _cdir; _cdir=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "")
  local _ts; _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local _src="${BASH_SOURCE[1]##*/}"
  _src="${_src:-unknown}"

  # Severity + event_class lookup
  local _sev="info" _class="lifecycle"
  case "$_action" in
    recovered_mid_arc|recovered_post_checkpoint_write) _sev="warn"; _class="recovery" ;;
    deletion_deferred_pending_phases|deletion_deferred_jq_unavailable|deletion_deferred_ambiguous)
      _sev="warn"; _class="deletion" ;;
    legitimate_stale_delete|legitimate_completion_delete) _sev="info"; _class="deletion" ;;
    recovery_failed_no_checkpoint|corrupted_write|failed_write|failed_verify)
      _sev="error"; _class="failure" ;;
  esac

  # Flag state (dry_run=true when flag=false but hook fired anyway)
  local _flag_enabled="false" _dry_run="true"
  if arc_state_flag_enabled; then _flag_enabled="true"; _dry_run="false"; fi

  # Construct the entry atomically via jq --arg (newline-safe)
  # Write append-only via >> (atomic for <PIPE_BUF=4096 bytes on POSIX)
  {
    umask 077
    jq -nc \
      --arg ts "$_ts" \
      --arg session_id "$_sid" \
      --arg owner_pid "$_pid" \
      --arg config_dir "$_cdir" \
      --arg action "$_action" \
      --arg cause "${_cause:-}" \
      --arg source_script "$_src" \
      --arg state_file_path "${_state_file:-}" \
      --arg severity "$_sev" \
      --arg event_class "$_class" \
      --arg flag_enabled "$_flag_enabled" \
      --arg dry_run "$_dry_run" \
      '{ts:$ts, session_id:$session_id, owner_pid:$owner_pid, config_dir:$config_dir,
        action:$action, cause:$cause, source_script:$source_script,
        state_file_path:$state_file_path, severity:$severity, event_class:$event_class,
        flag_enabled:($flag_enabled=="true"), dry_run:($dry_run=="true")}' 2>/dev/null >> "$_log_path"
  } || true

  # Ensure file mode 600 (umask may already cover; chmod for inherited files)
  [ -f "$_log_path" ] && chmod 600 "$_log_path" 2>/dev/null || true

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_touch state_file → exit 0
# ─────────────────────────────────────────────────────────────────────────────
# Refreshes mtime only (NEVER content rewrite — R27 invariant).
# Throttled to once per RUNE_ARC_STATE_TOUCH_THROTTLE_SEC.
arc_state_touch() {
  local _sf="$1"
  [ -z "$_sf" ] || [ ! -f "$_sf" ] && return 0
  # Symlink guard (SEC — CWE-61, shallow but matches existing convention)
  [ -L "$_sf" ] && return 0

  local _now _mtime _age
  _now=$(date +%s)
  _mtime=$(_stat_mtime "$_sf" 2>/dev/null || echo 0)
  _mtime="${_mtime:-0}"
  _age=$((_now - _mtime))
  if [ "$_age" -ge "$RUNE_ARC_STATE_TOUCH_THROTTLE_SEC" ] 2>/dev/null; then
    touch "$_sf" 2>/dev/null || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_should_delete state_file → exit 0 (delete ok) | 1 (defer)
# ─────────────────────────────────────────────────────────────────────────────
# 3-criterion rubric (plan §4.3):
#   1. pending_phases > 0 OR jq unavailable (-1) → DEFER (AC-4, AC-14)
#   2. stop_reason ∈ {completed, cancelled, context_limit} → OK to delete
#   3. active=true AND mtime > PHASE_TIMEOUT[current] * multiplier → OK (stale)
#   else → DEFER (safe default)
arc_state_should_delete() {
  local _sf="$1"
  [ -z "$_sf" ] || [ ! -f "$_sf" ] && return 0  # no file → nothing to defer
  [ -L "$_sf" ] && return 1  # symlink → defer (SEC)

  # Extract checkpoint_path from state file frontmatter
  local _cp_rel _cp_abs
  _cp_rel=$(sed -n 's/^checkpoint_path:[[:space:]]*\(.*\)$/\1/p' "$_sf" 2>/dev/null | head -1 | tr -d '\r')
  if [ -z "$_cp_rel" ]; then
    # No checkpoint pointer — ambiguous, defer (XM-3 safe default)
    arc_state_integrity_log "deletion_deferred_ambiguous" "no_checkpoint_pointer" "$_sf"
    return 1
  fi
  # Path validation: no .., absolute path disallowed
  case "$_cp_rel" in
    *..*|/*) arc_state_integrity_log "deletion_deferred_ambiguous" "invalid_checkpoint_path" "$_sf"; return 1 ;;
  esac
  _cp_abs="${CWD:-$PWD}/$_cp_rel"

  # Criterion 1: pending phases count (XM-3 honors -1)
  local _pending
  _pending=$(arc_state_pending_phases "$_cp_abs")
  if [ "$_pending" = "-1" ]; then
    arc_state_integrity_log "deletion_deferred_jq_unavailable" "jq_or_parse_error" "$_sf"
    return 1
  fi
  if [ "$_pending" -gt 0 ] 2>/dev/null; then
    arc_state_integrity_log "deletion_deferred_pending_phases" "pending=$_pending" "$_sf"
    return 1
  fi

  # Criterion 2: stop_reason set → legitimate completion delete
  if command -v jq >/dev/null 2>&1; then
    local _stop_reason
    _stop_reason=$(jq -r '.stop_reason // .user_cancelled // ""' "$_cp_abs" 2>/dev/null)
    case "$_stop_reason" in
      completed|cancelled|context_limit|true)
        arc_state_integrity_log "legitimate_completion_delete" "stop_reason=$_stop_reason" "$_sf"
        return 0
        ;;
    esac
  fi

  # Criterion 3: no pending phases, no stop_reason — unusual but not stale
  # Defer as safe default (AC-4)
  arc_state_integrity_log "deletion_deferred_ambiguous" "no_pending_no_stop_reason" "$_sf"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# arc_state_recover [kind] → exit 0 on recreate | 1 on no-checkpoint
# ─────────────────────────────────────────────────────────────────────────────
# Invokes rune-arc-init-state.sh create in recovery mode. Library itself
# does NOT do atomic write — that logic lives in the init script to avoid
# duplication (AC-5).
arc_state_recover() {
  local _kind="${1:-phase}"
  case " $_ARC_LOOP_KINDS " in
    *" $_kind "*) ;;
    *) return 1 ;;
  esac

  # Locate init script relative to this lib file
  local _lib_dir; _lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
  local _init="${_lib_dir}/../rune-arc-init-state.sh"
  if [ ! -x "$_init" ]; then
    arc_state_integrity_log "recovery_failed_no_checkpoint" "init_script_missing" ""
    return 1
  fi

  # Delegate to init script in recovery mode (--source=hook signals PPID is hook runner, not session)
  if "$_init" create --kind "$_kind" --source hook >/dev/null 2>&1; then
    arc_state_integrity_log "recovered_mid_arc" "stop_hook_watchdog" "$(arc_state_file_path "$_kind")"
    return 0
  fi
  arc_state_integrity_log "recovery_failed_no_checkpoint" "init_script_exit_nonzero" ""
  return 1
}

# Sentinel — indicates the library was successfully sourced
_RUNE_ARC_LOOP_STATE_LOADED=1
