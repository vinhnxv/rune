#!/bin/bash
# scripts/lib/team-shutdown.sh
# Centralized team shutdown fallback logic for Rune cleanup.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/team-shutdown.sh"
#   rune_team_shutdown_fallback "team-name" "$PPID" "arc" "smith-1,smith-2"
#
# DESIGN:
#   - Covers Steps 5-6 ONLY (filesystem cleanup + process kill + diagnostic)
#   - Session isolation: refuses to act if owner_pid belongs to another live session
#   - Uses _rune_kill_tree from process-tree.sh for MCP-safe process termination
#   - Bash 3.2 compatible (no associative arrays, no ${var,,})
#
# RETURNS:
#   0 = clean (no fallback needed or completed successfully)
#   1 = fallback exercised (cleanup was performed)
#   2 = invalid input or session isolation block
#
# SOURCING GUARD: Safe to source multiple times (idempotent).

[[ -n "${_RUNE_TEAM_SHUTDOWN_LOADED:-}" ]] && return 0
_RUNE_TEAM_SHUTDOWN_LOADED=1

# Source dependencies
_RUNE_TS_DIR="${BASH_SOURCE[0]%/*}"

# Source process-tree.sh (which sources platform.sh transitively)
if [[ -z "${_RUNE_PROCESS_TREE_LOADED:-}" ]]; then
  # shellcheck source=process-tree.sh
  source "${_RUNE_TS_DIR}/process-tree.sh"
fi

# rune_team_shutdown_fallback <team_name> <owner_pid> <workflow_label> [fallback_members] [grace_seconds]
#
# Parameters:
#   team_name        — Team name (required, [a-zA-Z0-9_-]+)
#   owner_pid        — PID of the owning Claude Code session (required, digits)
#   workflow_label   — Label for diagnostics (required, defaults to "unknown" if empty)
#   fallback_members — Comma-separated list of member names (optional, for diagnostics)
#   grace_seconds    — SIGTERM→SIGKILL grace period (optional, default 5, clamped to [0,20]).
#                      RUIN-002 FIX: Callers with a tight hook budget (e.g.,
#                      detect-workflow-complete.sh computing _budget_remaining) should pass
#                      a budget-aware value. Omitting preserves legacy 5s behavior.
#
# Environment:
#   _RUNE_DISABLE_SHUTDOWN_FALLBACK=1  — Skip all cleanup (for testing)
#   CLAUDE_CONFIG_DIR                  — Custom config dir (default: $HOME/.claude)
#   RUNE_TRACE=1                       — Enable trace logging
rune_team_shutdown_fallback() {
  local team_name="${1:-}"
  local owner_pid="${2:-}"
  local workflow_label="${3:-unknown}"
  local fallback_members="${4:-}"
  local grace_seconds="${5:-5}"

  # Clamp grace_seconds to [0,20].
  # BACK-005 (v2.63.0): accept signed ints so callers passing `-1` (over-budget
  # shorthand) or a computed negative remainder get clamped to 0 rather than
  # silently reverting to the 5s default. Decimal inputs (e.g. `2.5`) are not
  # supported — we keep integer-only semantics but trace the coercion so
  # callers can adjust.
  local _gs_original="$grace_seconds"
  if [[ "$grace_seconds" =~ ^-?[0-9]+$ ]]; then
    if (( grace_seconds < 0 )); then
      grace_seconds=0
    elif (( grace_seconds > 20 )); then
      grace_seconds=20
    fi
    if [[ "$_gs_original" != "$grace_seconds" ]]; then
      [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] grace_seconds clamped %s → %s\n' "$_gs_original" "$grace_seconds" >&2
    fi
  else
    grace_seconds=5
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] grace_seconds invalid (%s) — using default 5\n' "$_gs_original" >&2
  fi

  # ── Respect disable flag ──
  if [[ "${_RUNE_DISABLE_SHUTDOWN_FALLBACK:-}" == "1" ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] Disabled via _RUNE_DISABLE_SHUTDOWN_FALLBACK\n' >&2
    return 0
  fi

  # ── Validate team_name ──
  if [[ -z "$team_name" ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] ERROR: empty team_name\n' >&2
    return 2
  fi
  if [[ ! "$team_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] ERROR: invalid team_name: %s\n' "$team_name" >&2
    return 2
  fi

  # ── Validate owner_pid ──
  if [[ -z "$owner_pid" ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] ERROR: empty owner_pid\n' >&2
    return 2
  fi
  if [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] ERROR: non-numeric owner_pid: %s\n' "$owner_pid" >&2
    return 2
  fi

  # ── Default workflow_label ──
  if [[ -z "$workflow_label" ]]; then
    workflow_label="unknown"
  fi

  # ── Session isolation check ──
  # If owner_pid is alive AND not our parent, refuse to act
  if kill -0 "$owner_pid" 2>/dev/null; then
    if [[ "$owner_pid" != "$PPID" ]]; then
      [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] BLOCKED: owner_pid %s is alive but != PPID %s\n' "$owner_pid" "$PPID" >&2
      return 2
    fi
  fi

  local CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local killed=0
  local fallback_exercised=false

  # ── Step 5a: Process kill via _rune_kill_tree ──
  if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] Step 5a: killing tree for pid=%s team=%s\n' "$owner_pid" "$team_name" >&2
    killed=$(_rune_kill_tree "$owner_pid" "2stage" "$grace_seconds" "teammates" "$team_name")
    [[ "$killed" =~ ^[0-9]+$ ]] || killed=0
    if [[ "$killed" -gt 0 ]]; then
      fallback_exercised=true
    fi
  fi

  # ── Step 5b: Filesystem cleanup ──
  local team_dir="${CHOME}/teams/${team_name}"
  local task_dir="${CHOME}/tasks/${team_name}"

  if [[ -d "$team_dir" || -d "$task_dir" ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] Step 5b: removing %s and %s\n' "$team_dir" "$task_dir" >&2
    rm -rf "$team_dir" "$task_dir" 2>/dev/null || true
    fallback_exercised=true
  fi

  # ── Step 6: Diagnostic JSON ──
  local diag_file="${TMPDIR:-/tmp}/rune-cleanup-diagnostic-${team_name}.json"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

  # Build diagnostic JSON without jq (Bash 3.2 compatible)
  # SEC-001: Sanitize string fields to prevent JSON injection
  local _safe_label _safe_members
  _safe_label=$(printf '%s' "$workflow_label" | tr -cd 'a-zA-Z0-9_. -')
  _safe_members=$(printf '%s' "$fallback_members" | tr -cd 'a-zA-Z0-9_., -')
  local diag_json
  diag_json=$(printf '{
  "team_name": "%s",
  "owner_pid": "%s",
  "workflow_label": "%s",
  "fallback_members": "%s",
  "processes_killed": %s,
  "fallback_exercised": %s,
  "timestamp": "%s",
  "ppid": "%s"
}' \
    "$team_name" \
    "$owner_pid" \
    "$_safe_label" \
    "$_safe_members" \
    "$killed" \
    "$fallback_exercised" \
    "$timestamp" \
    "$PPID")

  # Atomic write via tmp+mv
  # SEC-005 (v2.63.0): mktemp must succeed — when it fails we SKIP the
  # diagnostic write entirely rather than falling back to the predictable
  # `${TMPDIR}/rune-diag-$$` name. The prior fallback + symlink guard closed
  # the actual content-redirection attack but left a narrow TOCTOU window
  # (attacker pre-creates symlink → our `-L` check runs → attacker swaps
  # symlink for a regular file → mv overwrites attacker-chosen path). Failing
  # closed removes that window entirely; diagnostics are best-effort anyway
  # and the team-shutdown return code already reflects fallback_exercised.
  #
  # RUIN-003 FIX (retained): even on the mktemp happy path we still reject
  # symlink targets in case the temp dir itself is compromised (e.g., TOCTOU
  # via a shared TMPDIR on a multi-user host).
  local diag_tmp
  diag_tmp=$(mktemp "${TMPDIR:-/tmp}/rune-diag-XXXXXX" 2>/dev/null)
  if [[ -z "$diag_tmp" ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] mktemp failed — skipping diagnostic write (fail-closed)\n' >&2
    if [[ "$fallback_exercised" == "true" ]]; then
      return 1
    fi
    return 0
  fi
  if [[ -L "$diag_tmp" ]]; then
    [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] diag_tmp is a symlink — aborting diagnostic write: %s\n' "$diag_tmp" >&2
    rm -f -- "$diag_tmp" 2>/dev/null
    if [[ "$fallback_exercised" == "true" ]]; then
      return 1
    fi
    return 0
  fi
  printf '%s\n' "$diag_json" > "$diag_tmp" 2>/dev/null
  mv "$diag_tmp" "$diag_file" 2>/dev/null || true

  [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[team-shutdown] Diagnostic written to %s\n' "$diag_file" >&2

  # ── Return code ──
  if [[ "$fallback_exercised" == "true" ]]; then
    return 1
  fi
  return 0
}
