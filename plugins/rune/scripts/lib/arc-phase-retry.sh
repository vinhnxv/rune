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

  # Emit breadcrumb (Shard 3 will add retry-heal/retry-terminal/retry-cascade-skip namespace)
  declare -f _arc_stop_hook_breadcrumb >/dev/null 2>&1 && \
    _arc_stop_hook_breadcrumb "retry-strike" "$new"

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
