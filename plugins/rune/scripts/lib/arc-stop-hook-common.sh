#!/bin/bash
# scripts/lib/arc-stop-hook-common.sh
# ARC-SPECIFIC shared library for arc stop hook loop drivers.
# Extension to stop-hook-common.sh — source AFTER it.
#
# USAGE (recommended order):
#   source "${SCRIPT_DIR}/lib/stop-hook-common.sh"    # parse_input, get_field, etc.
#   source "${SCRIPT_DIR}/lib/arc-stop-hook-common.sh" # arc-specific extensions
#
# NOTE: arc-phase-stop-hook.sh sources in reverse order (arc-stop-hook-common.sh
# first for ERR trap + jq guard, then stop-hook-common.sh later). This works
# because the early functions have no cross-library dependencies.
#
# This library extracts the 9 blocks duplicated across arc-batch, arc-hierarchy,
# arc-issues (outer loops) and arc-phase (inner loop):
#
#   arc_setup_err_trap [verbose]     — _rune_fail_forward + ERR trap definition
#   arc_init_trace_log               — RUNE_TRACE_LOG with TMPDIR validation (SEC-004)
#   arc_guard_jq_required            — exit 0 if jq missing
#   arc_guard_inner_loop_active      — wait for arc-phase-loop lock (outer hooks only)
#   arc_compact_interlude_phase_a    — set compact_pending flag + exit 2
#   arc_compact_interlude_phase_b    — detect + reset compact_pending with F-02 stale recovery
#   arc_get_hook_session_id          — validated session ID from INPUT
#   arc_delete_state_file            — 3-tier deletion guard
#   arc_guard_rapid_iteration        — backoff guard for rapid crash loops
#
# DEPENDENCIES:
#   - stop-hook-common.sh must be sourced first (provides _stat_mtime, _trace-global pattern)
#   - lib/platform.sh must be sourced (provides _stat_mtime, _parse_iso_epoch)
#   - Callers define _trace() before calling functions that use it
#   - _iso_to_epoch() from stop-hook-common.sh used by arc_guard_rapid_iteration
#   - _check_context_critical() from stop-hook-common.sh used by arc_guard_rapid_iteration
#
# Bash 3.2 compatible (macOS): no associative arrays, no ${var,,} lowercase.

# Source rune-state if not already loaded (stop-hook-common.sh may have loaded it)
[[ -n "${RUNE_STATE:-}" ]] || source "$(dirname "${BASH_SOURCE[0]}")/rune-state.sh"

# ─────────────────────────────────────────────────────────────
# Block A: _rune_fail_forward + ERR trap
# ─────────────────────────────────────────────────────────────

# ── arc_setup_err_trap([verbose]) ──
# Define _rune_fail_forward (OPERATIONAL: fail-forward) and install ERR trap.
#
# Args:
#   $1 = "verbose" (optional) — use the phase-style verbose ERR trap that always
#        writes to trace log AND emits stderr. Omit for the standard brief trap.
#
# CRITICAL: This function defines _rune_fail_forward at TOP-LEVEL scope, then
# immediately calls `trap '_rune_fail_forward' ERR`. Both must happen at script
# top-level before any other code, not inside subshells or nested functions.
# Callers should invoke arc_setup_err_trap as the FIRST statement after shebang.
#
# Verbose mode (arc-phase): always logs crash location (BASH_LINENO + cmd) to
#   trace log + emits to stderr. Used by the inner phase loop where silent failures
#   are especially dangerous (arc stops with no user-visible reason).
# Standard mode (batch/issues/hierarchy): logs rc + line to stderr, conditionally
#   appends to trace log when RUNE_TRACE=1.
arc_setup_err_trap() {
  local _mode="${1:-standard}"

  if [[ "$_mode" == "verbose" ]]; then
    # Verbose (arc-phase) variant — DIAGNOSTIC: always logs, always emits stderr.
    # BUG FIX (v1.144.12): Previously bare `trap 'exit 0' ERR` silently swallowed
    # all errors. Now logs crash location to enable debugging.
    _rune_fail_forward() {
      local _err_line="${BASH_LINENO[0]:-?}"
      local _err_cmd="${BASH_COMMAND:-unknown}"
      local _crash_script="${BASH_SOURCE[1]##*/}"  # [1] = caller, [0] = this function
      local _crash_msg="ERR trap — fail-forward at ${_crash_script}:${_err_line} (cmd=${_err_cmd})"
      local _ffl="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u 2>/dev/null || echo 0)-${PPID}.log}"
      if [[ -n "$_ffl" && ! -L "$_ffl" && ! -L "${_ffl%/*}" ]]; then
        printf '[%s] arc-phase-stop: %s\n' \
          "$(date +%H:%M:%S 2>/dev/null || true)" \
          "$_crash_msg" \
          >> "$_ffl" 2>/dev/null
      fi
      # Write crash diagnostic to a signal file for observability (AC-5)
      # Signal file enables crash recovery (Task 3.3) and session-team-hygiene.sh reporting
      # RUIN-001 FIX: Symlink guard on WRITE path (matches READ-side guard at arc-phase-stop-hook.sh:52)
      local _crash_signal="${TMPDIR:-/tmp}/rune-stop-hook-crash-${PPID}.txt"
      if [[ ! -L "$_crash_signal" ]]; then
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" "$_crash_msg" \
          >> "$_crash_signal" 2>/dev/null || true
      fi
      printf 'arc-phase-stop: %s — fail-forward, allowing stop\n' \
        "$_crash_msg" >&2 2>/dev/null || true
      exit 0
    }
  else
    # Standard variant — used by arc-batch, arc-issues, arc-hierarchy.
    # Emits brief message to stderr; writes to trace log only when RUNE_TRACE=1.
    _rune_fail_forward() {
      local rc=$?
      printf '[rune:%s] ERR trap fired (rc=%d, line=%s) — failing forward\n' \
        "${BASH_SOURCE[0]##*/}" "$rc" "${BASH_LINENO[0]:-?}" >&2
      [[ "${RUNE_TRACE:-}" == "1" ]] && [[ -n "${RUNE_TRACE_LOG:-}" ]] && [[ ! -L "${RUNE_TRACE_LOG}" ]] && \
        printf '[%s] arc-stop: ERR rc=%d line=%s\n' "$(date +%H:%M:%S)" "$rc" "${BASH_LINENO[0]:-?}" \
          >> "$RUNE_TRACE_LOG" 2>/dev/null
      exit 0
    }
  fi

  trap '_rune_fail_forward' ERR
}

# ─────────────────────────────────────────────────────────────
# Block B: RUNE_TRACE_LOG initialization
# ─────────────────────────────────────────────────────────────

# ── arc_init_trace_log ──
# Initialize RUNE_TRACE_LOG with TMPDIR validation.
# SEC-004: Restricts trace log to expected TMPDIR location to prevent
# env-var redirect attacks. Resets to safe default if outside TMPDIR.
# TOME-011: Add -${PPID} suffix to prevent concurrent session log interleaving.
#
# Sets: RUNE_TRACE_LOG (global)
arc_init_trace_log() {
  # SEC-004: Validate TMPDIR — must be absolute, must not contain '..'
  local _safe_tmpdir="${TMPDIR:-/tmp}"
  if [[ "$_safe_tmpdir" == *".."* ]] || [[ "$_safe_tmpdir" != /* ]]; then
    _safe_tmpdir="/tmp"
  fi

  RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${_safe_tmpdir}/rune-hook-trace-$(id -u)-${PPID}.log}"

  # If already set, still validate it stays within TMPDIR
  case "$RUNE_TRACE_LOG" in
    "${_safe_tmpdir}/"*) ;;  # allowed
    *) RUNE_TRACE_LOG="${_safe_tmpdir}/rune-hook-trace-$(id -u)-${PPID}.log" ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Block C: jq guard
# ─────────────────────────────────────────────────────────────

# ── arc_guard_jq_required ──
# Exit 0 (fail-open) if jq is not available.
# Call AFTER sourcing arc-stop-hook-common.sh but BEFORE sourcing stop-hook-common.sh.
# stop-hook-common.sh uses jq, so this guard must precede it.
# This function exists to provide a named entry point; callers may also inline
# the check before sourcing (which is what the hooks currently do for the
# pre-source case). After sourcing, this function can guard subsequent jq use.
arc_guard_jq_required() {
  if ! command -v jq &>/dev/null; then
    exit 0
  fi
}

# ─────────────────────────────────────────────────────────────
# Block D: Inner loop active guard (outer hooks only)
# ─────────────────────────────────────────────────────────────

# ── arc_guard_inner_loop_active STATE_FILE GUARD_LABEL ──
# Wait up to 2s for arc-phase-loop.local.md to disappear before deciding
# whether the inner phase loop is still active. If active after retries, exit 0.
#
# RACE FIX (v1.116.0): Claude Code fires Stop hooks in parallel. The phase hook
# may be removing its state file while the outer hook checks it. A brief wait
# allows the phase hook to complete its removal before the outer hook skips.
#
# Args:
#   $1 = CWD          — project root (absolute path)
#   $2 = GUARD_LABEL  — label for trace output (e.g., "GUARD 6.5" or "GUARD 7.5")
#
# Exits 0 (silently) if inner phase loop is active after retries.
# Returns (does not exit) if inner loop is done.
arc_guard_inner_loop_active() {
  local cwd="$1"
  local guard_label="${2:-GUARD 6.5}"
  local _phase_state="${cwd}/${RUNE_STATE}/arc-phase-loop.local.md"

  if [[ -f "$_phase_state" && ! -L "$_phase_state" ]]; then
    local _phase_retries=0
    while [[ $_phase_retries -lt 4 ]]; do
      sleep 0.5
      if [[ ! -f "$_phase_state" ]] || [[ -L "$_phase_state" ]]; then
        if declare -f _trace &>/dev/null; then
          _trace "${guard_label}: Phase state file removed during retry ${_phase_retries} — proceeding (parallel hook race fix)"
        fi
        break
      fi
      _phase_retries=$((_phase_retries + 1))
    done
    # After retries, if file still exists, the phase loop is genuinely active
    if [[ -f "$_phase_state" && ! -L "$_phase_state" ]]; then
      if declare -f _trace &>/dev/null; then
        _trace "${guard_label}: Phase loop active — skipping outer hook"
      fi
      exit 0
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# Blocks E/F: Compact interlude Phase A and Phase B
# ─────────────────────────────────────────────────────────────

# ── arc_compact_interlude_phase_a STATE_FILE COMPACT_PROMPT_TEXT ──
# Phase A of the compact interlude state machine:
#   1. Guard: state file must be non-empty (BUG-3 protection)
#   2. Write compact_pending=true atomically (insert if missing, update if present)
#   3. Verify write succeeded (F-05 protection)
#   4. Print COMPACT_PROMPT_TEXT to stderr and exit 2 (continue conversation)
#
# Sets:  COMPACT_PENDING=true on successful write (in-memory update)
# Exits: 0 on any failure (fail-open), 2 on success (re-inject prompt)
#
# Args:
#   $1 = STATE_FILE          — absolute path to YAML state file
#   $2 = COMPACT_PROMPT_TEXT — text to emit to stderr for the checkpoint turn
arc_compact_interlude_phase_a() {
  local state_file="$1"
  local compact_prompt="$2"

  # BUG-3 FIX: Pre-read guard — empty/deleted state file → sed writes 0 bytes
  if [[ ! -s "$state_file" ]]; then
    if declare -f _trace &>/dev/null; then
      _trace "BUG-3: State file empty/missing before compact Phase A — aborting"
    fi
    exit 0
  fi

  local _state_tmp
  _state_tmp=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || { echo "WARN: mktemp failed for state file update" >&2; exit 0; }

  if grep -q '^compact_pending:' "$state_file" 2>/dev/null; then
    sed 's/^compact_pending: .*$/compact_pending: true/' "$state_file" > "$_state_tmp" 2>/dev/null
  else
    # Insert compact_pending field before closing --- of YAML frontmatter
    awk 'NR>1 && /^---$/ && !done { print "compact_pending: true"; done=1 } { print }' \
      "$state_file" > "$_state_tmp" 2>/dev/null
  fi

  if ! mv -f "$_state_tmp" "$state_file" 2>/dev/null; then
    # Preserve state file on transient mv failure — deleting it would permanently
    # terminate the batch/hierarchy/issues loop (v1.179.0 fix, BACK-004)
    rm -f "$_state_tmp" 2>/dev/null
    exit 0
  fi

  # F-05 FIX: Verify compact_pending was actually written
  if ! grep -q '^compact_pending: true' "$state_file" 2>/dev/null; then
    if declare -f _trace &>/dev/null; then
      _trace "F-05: compact_pending write verification failed — preserving state file, exiting"
    fi
    # FIX: Don't delete state file on transient sed/write failure — preserve for retry
    exit 0
  fi

  COMPACT_PENDING="true"

  # Stop hook: exit 2 = show stderr to model and continue conversation
  printf '%s\n' "$compact_prompt" >&2
  exit 2
}

# ── arc_compact_interlude_phase_b STATE_FILE ──
# Phase B entry gate of the compact interlude state machine:
#   1. F-02: Detect and reset stale compact_pending (mtime > 300s → reset to false)
#   2. Guard: state file must be non-empty (BUG-3 protection)
#   3. Reset compact_pending=false atomically
#
# After this function returns (does not exit), callers proceed to inject the
# actual arc/child/iteration prompt.
#
# Sets: COMPACT_PENDING in-memory (either "false" after F-02 stale reset, or
#       kept "true" before the Phase B sed reset which this function does).
# Exits: 0 on any failure (fail-open).
# Returns: 0 on success (caller continues with arc prompt injection).
#
# Args:
#   $1 = STATE_FILE — absolute path to YAML state file
arc_compact_interlude_phase_b() {
  local state_file="$1"

  # F-02 FIX: Stale compact_pending recovery.
  # If Phase A set compact_pending=true but Phase B never fired (e.g., crash from
  # context exhaustion before Claude responded to the lightweight prompt), the flag
  # stays "true" indefinitely. Detect via state file mtime > 5 minutes.
  # Reset flag so Phase A can re-attempt compaction on the next cycle.
  if [[ "${COMPACT_PENDING:-}" == "true" ]]; then
    local _sf_mtime
    _sf_mtime=$(_stat_mtime "$state_file"); _sf_mtime="${_sf_mtime:-0}"
    if [[ "$_sf_mtime" -le 0 ]]; then
      if declare -f _trace &>/dev/null; then
        _trace "WARN: _stat_mtime returned 0 — skipping stale check"
      fi
    else
      local _sf_now _sf_age
      _sf_now=$(date +%s)
      _sf_age=$(( _sf_now - _sf_mtime ))
      if [[ "$_sf_age" -gt 300 ]]; then
        if declare -f _trace &>/dev/null; then
          _trace "F-02: Stale compact_pending (${_sf_age}s > 300s) — resetting to false"
        fi
        local _state_tmp
        _state_tmp=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || { exit 0; }
        sed 's/^compact_pending: true$/compact_pending: false/' "$state_file" > "$_state_tmp" 2>/dev/null \
          && mv -f "$_state_tmp" "$state_file" 2>/dev/null \
          || { rm -f "$_state_tmp" 2>/dev/null; exit 0; }
        COMPACT_PENDING="false"
        # After resetting stale flag, return so Phase A can be entered on this cycle
        return 0
      fi
    fi
  fi

  # Only execute Phase B reset if compact_pending is still "true" (not just stale-reset)
  if [[ "${COMPACT_PENDING:-}" != "true" ]]; then
    return 0
  fi

  # BUG-3 FIX: Pre-read guard — empty/deleted state file → sed writes 0 bytes
  if [[ ! -s "$state_file" ]]; then
    if declare -f _trace &>/dev/null; then
      _trace "BUG-3: State file empty/missing before compact Phase B — aborting"
    fi
    exit 0
  fi

  local _state_tmp
  _state_tmp=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || { echo "WARN: mktemp failed for state file update" >&2; exit 0; }
  sed 's/^compact_pending: true$/compact_pending: false/' "$state_file" > "$_state_tmp" 2>/dev/null \
    && mv -f "$_state_tmp" "$state_file" 2>/dev/null \
    || { rm -f "$_state_tmp" 2>/dev/null; exit 0; }

  if declare -f _trace &>/dev/null; then
    _trace "Compact interlude Phase B: context checkpointed, proceeding to arc prompt"
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────
# Block G: Session ID extraction
# ─────────────────────────────────────────────────────────────

# ── arc_get_hook_session_id ──
# Extract and validate session_id from hook input JSON (INPUT variable).
# SEC-004: Validates against UUID/alphanumeric pattern, sanitizes to empty on failure.
#
# Requires: INPUT variable to be set (by parse_input() from stop-hook-common.sh).
# Sets:     HOOK_SESSION_ID (global)
arc_get_hook_session_id() {
  HOOK_SESSION_ID=$(printf '%s\n' "${INPUT:-}" | jq -r '.session_id // empty' 2>/dev/null || true)
  # NOTE: {1,128} quantifier not supported in Bash 3.2 (macOS) — use + and length check
  if [[ -n "$HOOK_SESSION_ID" ]] && { [[ ${#HOOK_SESSION_ID} -gt 128 ]] || [[ ! "$HOOK_SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; }; then
    if declare -f _trace &>/dev/null; then
      _trace "Invalid session_id format — sanitizing to empty"
    fi
    HOOK_SESSION_ID=""
  fi
}

# ─────────────────────────────────────────────────────────────
# Block H: 3-tier state file deletion
# ─────────────────────────────────────────────────────────────

# ── arc_delete_state_file STATE_FILE ──
# 3-tier persistence guard for state file removal.
# CRITICAL: If rm -f fails (immutable flag, permissions), state file persists
# and the hook re-enters its "done" block on next Stop event — causing an
# infinite summary loop (Finding #1, v1.101.1).
#
# Tier 1: rm -f
# Tier 2: chmod 644 + rm -f (immutable-flag recovery)
# Tier 3: truncate to empty (last resort — makes frontmatter unparseable so
#         existing guards catch it on the next Stop event)
#
# Args:
#   $1 = STATE_FILE — absolute path to state file to delete
arc_delete_state_file() {
  local state_file="$1"

  # ── TRIPWIRE PATCH (Option A, user-requested 2026-04-18) ──
  # Verify ownership BEFORE delete. Log every attempt with caller stack.
  # Refuse delete if checkpoint is owned by a live session matching hook input.
  # Caller should treat return 1 as "delete refused — leave state file alone".
  local _tw_caller_script="${BASH_SOURCE[1]##*/}"
  local _tw_caller_line="${BASH_LINENO[0]:-?}"
  local _tw_caller_func="${FUNCNAME[1]:-MAIN}"
  local _tw_log="${TMPDIR:-/tmp}/rune-state-delete-tripwire.log"
  local _tw_verdict="ALLOWED"
  local _tw_reason=""

  {
    printf '[%s] DELETE_ATTEMPT: %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$state_file"
    printf '  caller: %s:%s (%s)\n' "$_tw_caller_script" "$_tw_caller_line" "$_tw_caller_func"
    printf '  PPID=%s hook_sid=%s\n' "${PPID:-?}" "$(printf '%s\n' "${INPUT:-}" | jq -r '.session_id // empty' 2>/dev/null || echo '-')"
  } >> "$_tw_log" 2>/dev/null

  if [[ -f "$state_file" ]]; then
    local _tw_owner_pid _tw_session_id _tw_active _tw_hook_sid
    _tw_owner_pid=$(sed -n 's/^owner_pid: //p' "$state_file" 2>/dev/null | head -1)
    _tw_session_id=$(sed -n 's/^session_id: //p' "$state_file" 2>/dev/null | head -1)
    _tw_active=$(sed -n 's/^active: //p' "$state_file" 2>/dev/null | head -1)
    _tw_hook_sid=$(printf '%s\n' "${INPUT:-}" | jq -r '.session_id // empty' 2>/dev/null || echo "")

    {
      printf '  state: owner_pid=%s session_id=%s active=%s\n' \
        "$_tw_owner_pid" "$_tw_session_id" "$_tw_active"
    } >> "$_tw_log" 2>/dev/null

    # Refuse delete when: active=true AND owner PID alive AND session_id matches hook
    if [[ "$_tw_active" == "true" ]] && [[ "$_tw_owner_pid" =~ ^[0-9]+$ ]] \
         && kill -0 "$_tw_owner_pid" 2>/dev/null; then
      if [[ -z "$_tw_hook_sid" ]] || [[ "$_tw_session_id" == "$_tw_hook_sid" ]]; then
        _tw_verdict="REFUSED"
        _tw_reason="owner PID $_tw_owner_pid alive AND session match (sid=$_tw_session_id)"
      fi
    fi

    {
      printf '  VERDICT: %s%s\n' "$_tw_verdict" "${_tw_reason:+ — $_tw_reason}"
      printf '  ---\n'
    } >> "$_tw_log" 2>/dev/null

    if [[ "$_tw_verdict" == "REFUSED" ]]; then
      if declare -f _trace &>/dev/null; then
        _trace "TRIPWIRE REFUSED delete — ${_tw_reason} — caller=${_tw_caller_script}:${_tw_caller_line}"
      fi
      return 1
    fi
  else
    {
      printf '  state: FILE_NOT_FOUND (nothing to delete)\n'
      printf '  VERDICT: %s\n' "$_tw_verdict"
      printf '  ---\n'
    } >> "$_tw_log" 2>/dev/null
  fi
  # ── END TRIPWIRE PATCH ──

  rm -f "$state_file" 2>/dev/null
  if [[ -f "$state_file" ]]; then
    if declare -f _trace &>/dev/null; then
      _trace "WARN: rm -f failed for state file, trying chmod+rm"
    fi
    chmod 644 "$state_file" 2>/dev/null
    rm -f "$state_file" 2>/dev/null
    if [[ -f "$state_file" ]]; then
      # Last resort: truncate to make it unparseable so guards catch it next time
      : > "$state_file" 2>/dev/null
      if declare -f _trace &>/dev/null; then
        _trace "WARN: state file could not be removed, truncated instead"
      fi
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# Block I: Rapid iteration guard
# ─────────────────────────────────────────────────────────────

# ── arc_guard_rapid_iteration STATE_FILE STARTED_AT MIN_SECS ABORT_CALLBACK GRACEFUL_CALLBACK LABEL ──
# Guard against rapid crash loops (context exhaustion or phantom arcs).
#
# If the iteration/child completed in < MIN_SECS seconds:
#   → call ABORT_CALLBACK "reason" (hard abort — marks all pending as failed)
# If elapsed >= MIN_SECS but no arc output AND context is critical:
#   → call ABORT_CALLBACK "reason" (GUARD 10b — phantom arc with inflated elapsed time)
# If no started_at available AND context is critical:
#   → call GRACEFUL_CALLBACK "reason" (compact interlude edge case — preserves pending)
#
# Both ABORT_CALLBACK and GRACEFUL_CALLBACK are shell functions defined by the caller.
# They are expected to emit to stderr and call `exit 2`.
#
# Args:
#   $1 = STARTED_AT        — ISO-8601 timestamp from progress/table, or empty
#   $2 = MIN_SECS          — minimum elapsed seconds (rapid iteration threshold)
#   $3 = ARC_STATUS        — arc completion status (e.g., "failed", "completed")
#   $4 = ABORT_CALLBACK    — function name to call on rapid/phantom iteration
#   $5 = GRACEFUL_CALLBACK — function name to call on context-critical with no started_at
#   $6 = LABEL             — label for trace/abort message (e.g., "iteration 2/5")
arc_guard_rapid_iteration() {
  local _started_at="$1"
  local _min_secs="$2"
  local _arc_status="$3"
  local _abort_cb="$4"
  local _graceful_cb="$5"
  local _label="$6"

  if [[ -n "$_started_at" ]] && [[ "$_started_at" != "null" ]]; then
    local _now_epoch
    _now_epoch=$(date +%s 2>/dev/null || echo "0")
    # FIX-004: Use if-context to isolate _iso_to_epoch from set -e.
    # In bash/zsh, commands inside `if` conditions are exempt from set -e.
    local _started_epoch=""
    local _started_epoch_val
    if _started_epoch_val=$(_iso_to_epoch "$_started_at" 2>/dev/null); then
      _started_epoch="$_started_epoch_val"
    fi

    if [[ -n "$_started_epoch" ]] && [[ "$_now_epoch" -gt 0 ]]; then
      local _elapsed
      _elapsed=$(( _now_epoch - _started_epoch ))
      if [[ "$_elapsed" -ge 0 ]] && [[ "$_elapsed" -lt "$_min_secs" ]]; then
        "$_abort_cb" "GUARD 10: Rapid iteration (${_elapsed}s < ${_min_secs}s) at ${_label}"
        return 0
      fi
      # GUARD 10b: Arc completed above MIN_RAPID_SECS but produced no checkpoint.
      # Catches phantom arcs where skill loading (~90-120s) inflates elapsed time
      # past MIN_RAPID_SECS but no real work happened.
      if [[ "$_elapsed" -ge "$_min_secs" ]] && [[ "$_elapsed" -lt 300 ]] && [[ "$_arc_status" == "failed" ]]; then
        if _check_context_critical 2>/dev/null; then
          "$_abort_cb" "GUARD 10b: Short iteration (${_elapsed}s) with no arc output + context critical at ${_label}"
          return 0
        fi
      fi
    fi
  else
    # F-07/F-13 FIX: No in_progress plan/child found (compact interlude turn or edge case).
    # GUARD 10's elapsed-time check cannot fire without started_at. Fall back to
    # context-level check via statusline bridge file. If context is critical (<= 25%
    # remaining), use graceful stop (preserves pending) instead of hard abort.
    if _check_context_critical 2>/dev/null; then
      "$_graceful_cb" "GUARD 10: Context critical with no active ${_label}"
      return 0
    fi
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────
# Block J: Context-critical check with stale bridge detection
# ─────────────────────────────────────────────────────────────

# ── arc_guard_context_critical_with_stale_bridge ──
# GUARD 11 wrapper: checks if the bridge file is stale (written before compact
# interlude Phase A) and skips the context-critical check if so. Without this,
# post-compaction turns see pre-compaction context levels and falsely abort.
#
# BUG FIX (v1.165.0): Extracted from arc-batch and arc-hierarchy stop hooks
# into shared library (v1.179.0) after arc-issues was found missing this guard.
#
# Arguments:
#   $1 — STATE_FILE path (for mtime comparison)
#   $2 — graceful stop callback function name
#   $3 — label for trace/log messages
#
# Returns: 0 always (graceful stop callback handles abort via exit 2)
arc_guard_context_critical_with_stale_bridge() {
  local state_file="$1"
  local _graceful_cb="$2"
  local _label="${3:-GUARD 11}"

  local _skip_context_check="false"
  if [[ -n "${HOOK_SESSION_ID:-}" ]]; then
    local _bridge_file="${TMPDIR:-/tmp}/rune-ctx-${HOOK_SESSION_ID}.json"
    if [[ -f "$_bridge_file" && ! -L "$_bridge_file" ]]; then
      local _bridge_mtime
      _bridge_mtime=$(_stat_mtime "$_bridge_file" 2>/dev/null || echo "0"); _bridge_mtime="${_bridge_mtime:-0}"
      local _state_mtime
      _state_mtime=$(_stat_mtime "$state_file" 2>/dev/null || echo "0"); _state_mtime="${_state_mtime:-0}"
      # Bridge file older than state file → stale (written before compact interlude)
      if [[ "$_bridge_mtime" -le "$_state_mtime" ]]; then
        _skip_context_check="true"
        if declare -f _trace &>/dev/null; then
          _trace "${_label}: Skipping context check — bridge file stale (bridge=${_bridge_mtime} <= state=${_state_mtime})"
        fi
      fi
    fi
  fi
  if [[ "$_skip_context_check" == "false" ]] && _check_context_critical 2>/dev/null; then
    "$_graceful_cb" "${_label}: Context critical at Phase B of compact interlude"
  fi
  return 0
}
