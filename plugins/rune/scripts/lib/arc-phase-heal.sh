#!/usr/bin/env bash
# plugins/rune/scripts/lib/arc-phase-heal.sh
#
# Shard 3 — Heal action library (v2.67.0 GA).
# Provides progressive heal actions invoked between retry strikes:
#   - _arc_heal_strike_1: no-op (placeholder for symmetry)
#   - _arc_heal_clean_state: strike-2 heal (kill teammates + remove .partial files)
#   - _arc_heal_rebuild: strike-3 heal (clean-state + filesystem TeamDelete + remove all phase artifacts)
#
# Plan: plans/2026-04-26-feat-arc-unified-retry-heal-shard-3-plan.md
#
# Acceptance criteria covered:
#   AC-3.1: Heal-2 (clean-state) executes between strike 2 and re-inject
#   AC-3.2: Heal-3 (rebuild) executes between strike 3 and re-inject
#
# Constraints:
#   C1: MCP-PROTECT-003 process kill via _rune_kill_tree "teammates" filter
#   C2: STOP-001 CHOME canonicalization
#   C3: Atomic mktemp+mv (caller responsibility for state file mutations)
#   C5: bash 3.2 compat
#   C7: No `set -e` + ERR-trap landmines — all functions return 0 always
#
# Invariants:
#   - All functions ALWAYS return 0 (best-effort heal — failures don't abort retry)
#   - Validation failure → silent no-op (FLAW-008 lesson)
#   - Symlinked CHOME team dirs are NEVER removed (defense-in-depth)
#
# Source guard — idempotent
[[ -n "${_RUNE_ARC_PHASE_HEAL_LOADED:-}" ]] && return 0
_RUNE_ARC_PHASE_HEAL_LOADED=1

# _arc_heal_strike_1 — no-op heal placeholder
# Args: $1 = phase (unused), $2 = arc_id (unused)
# Returns: 0 always
# Purpose: API symmetry — caller can invoke heal at all 3 strikes uniformly
_arc_heal_strike_1() { :; }

# _arc_heal_clean_state — strike-2 heal: clean stale state without destroying artifacts
# When:    Invoked by _arc_increment_retry (arc-phase-retry.sh strike==2 case branch)
#          AFTER strike persistence + retry-strike breadcrumb emission, BEFORE the next
#          Stop hook re-inject. Heal failures are non-fatal — retry proceeds regardless.
# Args:    $1 = phase name, $2 = arc id
# Reads:   ${SCRIPT_DIR}/lib/process-tree.sh (optional — loaded if present)
#          ${CWD}/tmp/arc/{arc_id}/ (filesystem)
# Writes:  Removes ${CWD}/tmp/arc/{arc_id}/{phase}-*.partial files
#          Sends SIGTERM/SIGKILL to teammate PIDs of arc-{phase}-{arc_id} (PROC-001 compliant)
# Returns: 0 always (best-effort — failures don't abort retry)
#
# Side effects:
#   - Kills teammates in team arc-{phase}-{arc_id} via _rune_kill_tree "teammates" filter
#   - Removes .partial artifacts (preserves completed artifacts)
#   - Does NOT touch checkpoint or state file (caller's responsibility)
_arc_heal_clean_state() {
  local phase="$1" arc_id="$2"

  # SEC validation — silent no-op on bad input (no ERR-trap landmine under set -e)
  [[ "$phase"  =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ "$arc_id" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0

  local team_name="arc-${phase}-${arc_id}"

  # MCP-PROTECT-003 compliant teammate kill — only fires if process-tree.sh available.
  # _rune_kill_tree "teammates" filter applies the 3-check verification automatically
  # via _collect_teammate_pids() — protects MCP servers, connectors, non-teammate processes.
  if [[ -f "${SCRIPT_DIR:-}/lib/process-tree.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/process-tree.sh"
    # _rune_kill_tree(parent_pid, mode, grace_secs, filter, team_name)
    declare -f _rune_kill_tree >/dev/null 2>&1 && \
      _rune_kill_tree "$PPID" "2stage" "5" "teammates" "${team_name}" >/dev/null 2>&1 || true
  fi

  # Remove partial artifacts (keep completed artifacts intact for audit trail)
  # Use ${CWD:-$PWD} fallback for callers that don't export CWD
  local arc_dir="${CWD:-$PWD}/tmp/arc/${arc_id}"
  if [[ -d "$arc_dir" ]]; then
    find "$arc_dir" -maxdepth 2 -type f -name "${phase}-*.partial" -delete 2>/dev/null || true
  fi

  return 0
}

# _arc_heal_rebuild — strike-3 heal: rebuild from clean slate
# When:    Invoked by _arc_increment_retry (arc-phase-retry.sh strike==3 case branch)
#          AFTER strike persistence + retry-strike breadcrumb emission, BEFORE the next
#          Stop hook re-inject. Last heal before terminal_cascade fires at threshold+1.
#          Heal failures are non-fatal — retry proceeds regardless.
# Args:    $1 = phase name, $2 = arc id
# Reads:   ${SCRIPT_DIR}/lib/process-tree.sh (via _arc_heal_clean_state)
#          ${CHOME}/teams/{team_name}/ (filesystem)
#          ${CWD}/tmp/arc/{arc_id}/ (filesystem)
# Writes:  Same as clean-state PLUS:
#          - rm -rf $CHOME_CANON/teams/{team_name}/ and $CHOME_CANON/tasks/{team_name}/
#          - rm ALL ${CWD}/tmp/arc/{arc_id}/{phase}-* artifacts (not just .partial)
#          - rm ${CWD}/tmp/arc/{arc_id}/qa/{phase}-* artifacts
# Returns: 0 always
#
# Side effects:
#   - Reuses _arc_heal_clean_state for strike-2 actions (kill + .partial cleanup)
#   - Filesystem TeamDelete fallback (CHOME canonicalization per STOP-001)
#   - Removes ALL phase artifacts (caller should write minimal recovery state if needed)
#   - Symlinked team dirs are SKIPPED (defense against symlink redirection attack)
_arc_heal_rebuild() {
  local phase="$1" arc_id="$2"

  # SEC validation — silent no-op on bad input
  [[ "$phase"  =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ "$arc_id" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0

  local team_name="arc-${phase}-${arc_id}"

  # Step 1: clean-state heal first (kill teammates + remove .partial)
  _arc_heal_clean_state "$phase" "$arc_id" || true

  # Step 2: filesystem TeamDelete fallback (canonicalized CHOME — STOP-001 pattern)
  # CHOME_CANON resolves symlinks to absolute path; rm only fires when:
  #   - CHOME_CANON is non-empty (canonicalization succeeded)
  #   - Team dir exists at canonical path
  #   - Team dir is NOT itself a symlink (defense against symlink redirection)
  local CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local CHOME_CANON
  CHOME_CANON=$(cd "$CHOME" 2>/dev/null && pwd -P) || CHOME_CANON=""
  if [[ -n "$CHOME_CANON" && -d "$CHOME_CANON/teams/${team_name}" && ! -L "$CHOME_CANON/teams/${team_name}" ]]; then
    rm -rf "$CHOME_CANON/teams/${team_name}/" "$CHOME_CANON/tasks/${team_name}/" 2>/dev/null || true
  fi

  # Step 3: remove ALL phase artifacts (not just .partial)
  # Includes both top-level phase artifacts and qa/ subdirectory verdicts
  local arc_dir="${CWD:-$PWD}/tmp/arc/${arc_id}"
  if [[ -d "$arc_dir" ]]; then
    find "$arc_dir"     -maxdepth 2 -type f -name "${phase}-*" -delete 2>/dev/null || true
    [[ -d "$arc_dir/qa" ]] && \
      find "$arc_dir/qa" -maxdepth 1 -type f -name "${phase}-*" -delete 2>/dev/null || true
  fi

  return 0
}
