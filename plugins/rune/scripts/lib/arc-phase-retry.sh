#!/usr/bin/env bash
# plugins/rune/scripts/lib/arc-phase-retry.sh
#
# Shard 2 — Per-phase retry counter primitive (v2.67.0-rc1).
# Provides _arc_increment_retry + _arc_reset_retry. NO heal actions, NO cascade —
# those land in Shard 3 (v2.67.0 GA).
#
# Plan: plans/2026-04-26-feat-arc-unified-retry-heal-shard-2-plan.md
#
# Acceptance criteria covered:
#   AC-2.2: Strike progression — count++ + retry_strikes[] entry + return 0 (caller re-injects)
#   AC-2.3: Terminal at threshold+1 — return 1 (caller falls through to v2.66.x auto-skip)
#   AC-2.4: _arc_reset_retry clears retry_count, retry_strikes, demotion_revert_count (Shard 1)
#   AC-2.6: Talisman gate — retry_enabled=false → no-op fast path (rollback flag)
#   AC-2.7: Backward compat — jq // default for missing fields
#
# v2.67.0-rc1 fix (concern-context.md P1): The early-return gate reads
# `config.retry_enabled` (new field, mirrors talisman.arc.retry.enabled), NOT
# `config.heal_actions_enabled`. The plan's original code body wired both gates
# to the same field — that defeated the canary kill-switch. retry_enabled is
# distinct from heal_actions_enabled (Shard 3 consumer for the heal action library).
#
# CONSTRAINT C5 (FLAW-008 lesson): Functions ALWAYS return 0 on validation
# failure. Callers can use `if _arc_increment_retry ...; then` without ERR-trap
# landmines under `set -euo pipefail`.
#
# Source guard — idempotent
[[ -n "${_RUNE_ARC_PHASE_RETRY_LOADED:-}" ]] && return 0
_RUNE_ARC_PHASE_RETRY_LOADED=1

# _arc_increment_retry — per-phase retry tally
# Args:   $1 = phase name, $2 = reason label
# Reads:  CKPT_CONTENT (caller scope — JSON string)
# Writes: CKPT_CONTENT (caller scope — atomically replaced or preserved)
# Returns:
#   0 — caller should re-inject same phase (strike < threshold + 1)
#       OR fast-path (feature disabled, validation failed, jq mutation invalid)
#   1 — terminal: strike == threshold + 1. Caller falls through to existing
#       v2.66.x auto-skip behavior. Shard 3 will replace with _arc_terminal_cascade.
#
# Side effects:
#   - Increments .phases[$phase].retry_count
#   - Mirrors to .phases[$phase].stuck_count for backward compat (AC-2.5)
#   - Appends one strike to .phases[$phase].retry_strikes[]
#   - Emits "retry-strike" breadcrumb if _arc_stop_hook_breadcrumb is defined
#
_arc_increment_retry() {
  local phase="$1" reason="$2"

  # SEC validation — return 0 on bad input (no ERR-trap landmine under set -e)
  [[ "$phase"  =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ "$reason" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ -n "${CKPT_CONTENT:-}" ]] || return 0

  # Talisman gate (AC-2.6, P1 FIX) — read config.retry_enabled (NOT heal_actions_enabled)
  # When user sets `arc.retry.enabled: false` in talisman, the kill-switch fires here.
  local enabled
  enabled=$(printf '%s' "$CKPT_CONTENT" | jq -r '.config.retry_enabled // false' 2>/dev/null || echo "false")
  [[ "$enabled" == "true" ]] || return 0

  # Read threshold from config (talisman-overridable via arc.retry.threshold)
  local threshold
  threshold=$(printf '%s' "$CKPT_CONTENT" | jq -r '.config.retry_threshold // 3' 2>/dev/null || echo "3")
  [[ "$threshold" =~ ^[0-9]+$ ]] && [[ "$threshold" -ge 1 ]] || threshold=3

  # Read current count (jq // default for backward compat — AC-2.7)
  local current
  current=$(printf '%s' "$CKPT_CONTENT" | jq -r --arg p "$phase" '.phases[$p].retry_count // 0' 2>/dev/null || echo "0")
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  local new=$(( current + 1 ))

  # Timestamp (BSD/GNU date both supported)
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Atomic mutation — append strike, bump count, mirror stuck_count
  local _new_ckpt
  _new_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq \
    --arg p "$phase" --arg ts "$now" --arg r "$reason" --argjson n "$new" '
    .phases[$p].retry_count = $n |
    .phases[$p].stuck_count = $n |
    .phases[$p].retry_strikes = ((.phases[$p].retry_strikes // []) + [{
      strike: $n, timestamp: $ts, reason: $r, heal_action: null,
      heal_artifacts_removed: [], heal_team_killed: null
    }])
  ' 2>/dev/null)

  # FIX G validation (v2.66.0) — discard invalid mutation
  if [[ -z "$_new_ckpt" ]] || ! printf '%s' "$_new_ckpt" | jq -e '.' >/dev/null 2>&1; then
    declare -f _trace >/dev/null 2>&1 && _trace "retry: jq mutation invalid — preserving CKPT_CONTENT"
    declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
      _arc_stop_hook_breadcrumb "retry-jq-fail" "$new"
    return 0
  fi
  CKPT_CONTENT="$_new_ckpt"

  # Emit retry-strike breadcrumb
  declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
    _arc_stop_hook_breadcrumb "retry-strike" "$new"

  # ── Shard 3 (AC-3.1, AC-3.2): apply heal action between strike and re-inject ──
  # Heal-2 fires at strike 2 (clean-state), heal-3 fires at strike 3 (rebuild).
  # Heal-1 is no-op (handled implicitly — no case branch needed).
  # Reads arc_id from checkpoint to construct team_name (arc-{phase}-{arc_id}).
  # Heal failures are non-fatal — best-effort cleanup, retry proceeds regardless.
  local arc_id
  arc_id=$(printf '%s' "$CKPT_CONTENT" | jq -r '.id // ""' 2>/dev/null || echo "")
  [[ "$arc_id" =~ ^[a-zA-Z0-9_-]+$ ]] || arc_id=""

  case "$new" in
    2)
      if [[ -n "$arc_id" && -f "${SCRIPT_DIR:-}/lib/arc-phase-heal.sh" ]]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/lib/arc-phase-heal.sh"
        declare -f _arc_heal_clean_state >/dev/null 2>&1 && \
          _arc_heal_clean_state "$phase" "$arc_id" || true

        # Reset started_at + api_error_retries via jq (atomic mutation, FIX G validated)
        local _new_ckpt
        _new_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq --arg p "$phase" --arg ts "$now" '
          .phases[$p].started_at            = $ts |
          .phases[$p].api_error_retries     = 0   |
          .phases[$p].server_error_retries  = 0
        ' 2>/dev/null)
        if [[ -n "$_new_ckpt" ]] && printf '%s' "$_new_ckpt" | jq -e '.' >/dev/null 2>&1; then
          CKPT_CONTENT="$_new_ckpt"
        fi

        # Update last strike record with heal_action and team killed
        _new_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq --arg p "$phase" --arg t "arc-${phase}-${arc_id}" '
          .phases[$p].retry_strikes[-1].heal_action      = "clean-state" |
          .phases[$p].retry_strikes[-1].heal_team_killed = $t
        ' 2>/dev/null)
        if [[ -n "$_new_ckpt" ]] && printf '%s' "$_new_ckpt" | jq -e '.' >/dev/null 2>&1; then
          CKPT_CONTENT="$_new_ckpt"
        fi

        declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
          _arc_stop_hook_breadcrumb "retry-strike-heal" "2"
      fi
      ;;
    3)
      if [[ -n "$arc_id" && -f "${SCRIPT_DIR:-}/lib/arc-phase-heal.sh" ]]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/lib/arc-phase-heal.sh"
        declare -f _arc_heal_rebuild >/dev/null 2>&1 && \
          _arc_heal_rebuild "$phase" "$arc_id" || true

        # Reset compact_pending in state file (atomic sed+mv)
        # STATE_FILE is provided by the calling context (arc-phase-stop-hook.sh)
        if [[ -n "${STATE_FILE:-}" && -f "$STATE_FILE" ]]; then
          local _st_tmp
          _st_tmp=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || _st_tmp=""
          if [[ -n "$_st_tmp" ]]; then
            sed 's/^compact_pending: .*/compact_pending: false/' "$STATE_FILE" > "$_st_tmp" 2>/dev/null \
              && mv -f "$_st_tmp" "$STATE_FILE" 2>/dev/null \
              || rm -f "$_st_tmp" 2>/dev/null || true
          fi
        fi

        # Update last strike record with heal_action
        local _new_ckpt
        _new_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq --arg p "$phase" --arg t "arc-${phase}-${arc_id}" '
          .phases[$p].retry_strikes[-1].heal_action      = "rebuild" |
          .phases[$p].retry_strikes[-1].heal_team_killed = $t
        ' 2>/dev/null)
        if [[ -n "$_new_ckpt" ]] && printf '%s' "$_new_ckpt" | jq -e '.' >/dev/null 2>&1; then
          CKPT_CONTENT="$_new_ckpt"
        fi

        declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
          _arc_stop_hook_breadcrumb "retry-strike-heal" "3"
      fi
      ;;
  esac

  # Terminal signal — strike threshold+1 consumed
  if [[ "$new" -gt "$threshold" ]]; then
    # Mark terminal flag (Shard 3 consumer)
    local _term_ckpt
    _term_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq --arg p "$phase" '.phases[$p].retry_terminal = true' 2>/dev/null)
    if [[ -n "$_term_ckpt" ]] && printf '%s' "$_term_ckpt" | jq -e '.' >/dev/null 2>&1; then
      CKPT_CONTENT="$_term_ckpt"
    fi
    return 1
  fi

  return 0
}

# _arc_terminal_cascade — terminal-skip phase + cascade-skip dependents (AC-3.3)
# Args:    $1 = phase name
# Reads:   CKPT_CONTENT (must contain .config.skip_map_dependents.{phase} array)
# Writes:  CKPT_CONTENT (atomically replaced with terminal+cascade markings)
# Returns: 0 always (best-effort — jq failure preserves CKPT_CONTENT unchanged)
#
# Side effects:
#   - .phases[$phase] gets status="skipped", retry_terminal=true, force_advanced=true,
#     skip_reason="retry_exhausted_after_heal", completed_at=now
#   - For each dependent in .config.skip_map_dependents[$phase] with status=="pending":
#     - dependent.status = "skipped"
#     - dependent.skip_reason = "upstream_terminal_skip_<phase>"
#     - dependent.completed_at = now
#   - .phase_skip_log gets one terminal_auto_skip event + one cascade_skip event per dependent
#   - Dependents already complete/skipped/in_progress are NOT modified (safe to re-run)
#   - Emits "retry-terminal-cascade" breadcrumb with cascade-skipped dependent count
#
# Invariants:
#   - jq mutation is atomic (single jq invocation; if it fails, CKPT_CONTENT is preserved)
#   - Skip event log is append-only (never truncates existing entries)
#   - Dependent loop only modifies pending phases (won't override active in_progress work)
_arc_terminal_cascade() {
  local phase="$1"

  # SEC validation — silent no-op on bad input
  [[ "$phase" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ -n "${CKPT_CONTENT:-}" ]] || return 0

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Atomic mutation: terminal-skip phase + cascade-skip eligible dependents + log events
  local _new_ckpt
  _new_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq --arg p "$phase" --arg ts "$now" '
    (.config.skip_map_dependents[$p] // []) as $deps |
    .phases[$p].status         = "skipped"                       |
    .phases[$p].skip_reason    = "retry_exhausted_after_heal"    |
    .phases[$p].retry_terminal = true                            |
    .phases[$p].force_advanced = true                            |
    .phases[$p].completed_at   = $ts                             |
    .phase_skip_log = (.phase_skip_log // []) + [{
      phase: $p,
      event: "terminal_auto_skip",
      reason: "retry_exhausted_after_heal",
      timestamp: $ts
    }] |
    reduce $deps[] as $d (.;
      if .phases[$d] != null and .phases[$d].status == "pending" then
        .phases[$d].status       = "skipped"                                |
        .phases[$d].skip_reason  = ("upstream_terminal_skip_" + $p)         |
        .phases[$d].completed_at = $ts                                      |
        .phase_skip_log = (.phase_skip_log // []) + [{
          phase: $d,
          event: "cascade_skip",
          reason: ("upstream_terminal_skip_" + $p),
          timestamp: $ts
        }]
      else . end
    )
  ' 2>/dev/null)

  # FIX G validation — discard invalid mutation, preserve original CKPT_CONTENT
  if [[ -n "$_new_ckpt" ]] && printf '%s' "$_new_ckpt" | jq -e '.' >/dev/null 2>&1; then
    CKPT_CONTENT="$_new_ckpt"

    # Compute dependent skip count for breadcrumb (informational)
    local _dep_count
    _dep_count=$(printf '%s' "$CKPT_CONTENT" | jq -r --arg p "$phase" '
      [.phase_skip_log[] | select(.event == "cascade_skip" and .reason == ("upstream_terminal_skip_" + $p))] | length
    ' 2>/dev/null || echo "0")

    declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
      _arc_stop_hook_breadcrumb "retry-terminal-cascade" "$_dep_count"
  else
    # jq mutation failed — emit failure breadcrumb but don't touch CKPT_CONTENT
    declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
      _arc_stop_hook_breadcrumb "retry-jq-fail" "cascade"
  fi

  return 0
}

# _arc_reset_retry — reset per-phase retry state on successful completion (AC-2.4)
# Args:   $1 = phase name
# Reads:  CKPT_CONTENT
# Writes: CKPT_CONTENT (atomically replaced or preserved on jq error)
# Returns: 0 always (caller doesn't branch on this)
#
# Resets:
#   - retry_count → 0
#   - retry_strikes → []
#   - retry_terminal → false (so post-recovery phase can retry again if stuck)
#   - demotion_revert_count → 0 (Shard 1 cross-shard invariant: ALL retry-family
#     counters reset together on success)
#   - stuck_count → 0 (mirror for backward compat — AC-2.5)
#
_arc_reset_retry() {
  local phase="$1"
  [[ "$phase" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ -n "${CKPT_CONTENT:-}" ]] || return 0

  local _new_ckpt
  _new_ckpt=$(printf '%s' "$CKPT_CONTENT" | jq --arg p "$phase" '
    .phases[$p].retry_count            = 0 |
    .phases[$p].stuck_count            = 0 |
    .phases[$p].retry_strikes          = [] |
    .phases[$p].retry_terminal         = false |
    .phases[$p].demotion_revert_count  = 0
  ' 2>/dev/null)

  if [[ -n "$_new_ckpt" ]] && printf '%s' "$_new_ckpt" | jq -e '.' >/dev/null 2>&1; then
    CKPT_CONTENT="$_new_ckpt"
  fi
  return 0
}
