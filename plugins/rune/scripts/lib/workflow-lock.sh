#!/bin/bash
# scripts/lib/workflow-lock.sh
# Advisory workflow lock for cross-command coordination.
# Source this file — do not execute directly.
#
# Exports:
#   rune_acquire_lock(workflow, class)  — Create lock, return 0=acquired, 1=conflict
#   rune_release_lock(workflow)         — Remove lock (ownership-verified)
#   rune_release_all_locks()            — Release ALL locks owned by this PID
#   rune_check_conflicts(class)        — Check for active conflicting workflows, always exit 0
#
# Lock dir: {LOCK_BASE}/{workflow}/
# Metadata: {LOCK_BASE}/{workflow}/meta.json
#
# Uses: resolve-session-identity.sh (RUNE_CURRENT_CFG, rune_pid_alive) — soft dep; config_dir falls back to CLAUDE_CONFIG_DIR/$HOME/.claude
# Requires: jq (fail-open stubs if missing)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../resolve-session-identity.sh"

# SEC-001: Resolve LOCK_BASE to absolute path (anchored to git root or CWD)
_RUNE_LOCK_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_BASE="${_RUNE_LOCK_ROOT}/tmp/.rune-locks"

# SEC-003: jq dependency guard — fail-open stubs if jq missing
# VOID-008: These stubs intentionally disable locking (fail-open per ADR-002).
# rune_check_conflicts returns 0 = "no conflicts" to avoid blocking workflows.
if ! command -v jq &>/dev/null; then
  echo "[rune-lock] WARNING: jq not found — workflow locking disabled (concurrent edits possible)" >&2
  rune_acquire_lock() { return 0; }
  rune_release_lock() { return 0; }
  rune_release_all_locks() { return 0; }
  rune_check_conflicts() { echo "WARNING: jq unavailable — conflict detection disabled" >&2; return 0; }
  return 0 2>/dev/null || exit 0
fi

# SEC-003: LOCK_BASE symlink guard — refuse to operate on symlinked base dir
if [[ -L "$LOCK_BASE" ]]; then
  echo "[rune-lock] ERROR: LOCK_BASE is a symlink — aborting" >&2
  return 1 2>/dev/null || exit 1
fi

# SEC-001: Input validation — workflow name must be safe for filesystem
_rune_validate_workflow_name() {
  local name="$1"
  [[ -n "$name" && "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
}

# SEC-004: Symlink guard — refuse to operate on symlinked paths
_rune_lock_safe() {
  [[ ! -L "$1" ]] || return 1
}

# Helper: write meta.json atomically using jq (SEC-002: safe JSON escaping)
_rune_write_meta() {
  local lock_dir="$1" workflow="$2" class="$3"
  local _cfg="${RUNE_CURRENT_CFG:-$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")}"
  jq -n \
    --arg wf "$workflow" --arg cls "$class" --argjson pid "$PPID" \
    --arg cfg "$_cfg" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "${CLAUDE_SESSION_ID:-unknown}" \
    '{workflow:$wf,class:$cls,pid:$pid,config_dir:$cfg,started:$ts,session_id:$sid}' \
    > "$lock_dir/meta.json.tmp" 2>/dev/null \
    && mv -f "$lock_dir/meta.json.tmp" "$lock_dir/meta.json" 2>/dev/null
}

rune_acquire_lock() {
  local workflow="$1" class="${2:-writer}"
  _rune_validate_workflow_name "$workflow" || return 1
  local lock_dir="${LOCK_BASE}/${workflow}"

  # mkdir is POSIX-atomic — fails if exists
  if mkdir -p "$(dirname "$lock_dir")" 2>/dev/null && mkdir "$lock_dir" 2>/dev/null; then
    _rune_write_meta "$lock_dir" "$workflow" "$class"
    # FLAW-001: Verify meta.json was written; clean up ghost dir on failure
    if [[ ! -f "$lock_dir/meta.json" ]]; then
      rm -rf "$lock_dir" 2>/dev/null; return 1
    fi
    return 0
  fi

  # Lock dir exists — check ownership
  _rune_lock_safe "$lock_dir" || return 1
  if [[ -f "$lock_dir/meta.json" ]]; then
    _rune_lock_safe "$lock_dir/meta.json" || return 1
    local stored_pid stored_cfg
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_cfg=$(jq -r '.config_dir // empty' "$lock_dir/meta.json" 2>/dev/null || true)

    # Different installation → not our concern
    local _current_cfg="${RUNE_CURRENT_CFG:-$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")}"
    [[ -n "$stored_cfg" && "$stored_cfg" != "$_current_cfg" ]] && return 1
    # Same session → re-entrant (e.g., arc delegating to strive)
    [[ -n "$stored_pid" && "$stored_pid" == "$PPID" ]] && return 0

    # PID dead → orphaned lock, reclaim
    if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
      if ! rune_pid_alive "$stored_pid"; then
        rm -rf "$lock_dir" 2>/dev/null
        mkdir "$lock_dir" 2>/dev/null && {
          _rune_write_meta "$lock_dir" "$workflow" "$class"
          [[ -f "$lock_dir/meta.json" ]] && return 0
          rm -rf "$lock_dir" 2>/dev/null; return 1
        }
      fi
    fi
  else
    # Ghost lock dir (no meta.json) — clean up and retry once
    rm -rf "$lock_dir" 2>/dev/null
    mkdir "$lock_dir" 2>/dev/null && {
      _rune_write_meta "$lock_dir" "$workflow" "$class"
      [[ -f "$lock_dir/meta.json" ]] && return 0
      rm -rf "$lock_dir" 2>/dev/null; return 1
    }
  fi

  return 1  # Conflict — another live session holds the lock
}

rune_release_lock() {
  local workflow="$1"
  _rune_validate_workflow_name "$workflow" || return 0
  local lock_dir="${LOCK_BASE}/${workflow}"

  [[ -d "$lock_dir" ]] || return 0
  _rune_lock_safe "$lock_dir" || return 0

  # Ownership check — only release our own locks
  if [[ -f "$lock_dir/meta.json" ]]; then
    local stored_pid
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    [[ "$stored_pid" == "$PPID" ]] && rm -rf "$lock_dir" 2>/dev/null
  fi
  return 0
}

# Release ALL locks owned by this PID (for arc final cleanup)
rune_release_all_locks() {
  [[ -d "$LOCK_BASE" ]] || return 0
  shopt -s nullglob 2>/dev/null || true
  for lock_dir in "$LOCK_BASE"/*/; do
    [[ -d "$lock_dir" ]] || continue
    _rune_lock_safe "$lock_dir" || continue
    [[ -f "$lock_dir/meta.json" ]] || { rm -rf "$lock_dir" 2>/dev/null; continue; }
    local stored_pid
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    [[ "$stored_pid" == "$PPID" ]] && rm -rf "$lock_dir" 2>/dev/null
  done
  return 0
}

rune_check_conflicts() {
  local my_class="${1:-writer}"
  local conflicts=""

  [[ -d "$LOCK_BASE" ]] || return 0

  # FLAW-003: zsh-compat — protect glob from NOMATCH error
  shopt -s nullglob 2>/dev/null || true
  for lock_dir in "$LOCK_BASE"/*/; do
    [[ -d "$lock_dir" ]] || continue
    _rune_lock_safe "$lock_dir" || continue

    # FLAW-001/SEC-005: Lock dir without meta.json = in-progress acquisition
    if [[ ! -f "$lock_dir/meta.json" ]]; then
      conflicts="${conflicts}ADVISORY: unknown workflow (lock acquiring, no metadata yet)\n"
      continue
    fi

    local stored_pid stored_cfg stored_workflow stored_class
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_cfg=$(jq -r '.config_dir // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_workflow=$(jq -r '.workflow // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_class=$(jq -r '.class // "writer"' "$lock_dir/meta.json" 2>/dev/null || true)

    # Skip different installations
    local _current_cfg="${RUNE_CURRENT_CFG:-$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")}"
    [[ -n "$stored_cfg" && "$stored_cfg" != "$_current_cfg" ]] && continue
    # Skip same session (re-entrant)
    [[ -n "$stored_pid" && "$stored_pid" == "$PPID" ]] && continue
    # Skip dead PIDs (cleanup)
    if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
      if ! rune_pid_alive "$stored_pid"; then
        rm -rf "$lock_dir" 2>/dev/null
        continue
      fi
    fi

    # Conflict rules:
    #   writer vs writer → CONFLICT
    #   writer vs reader/planner → ADVISORY
    #   reader vs reader → OK
    if [[ "$my_class" == "writer" && "$stored_class" == "writer" ]]; then
      conflicts="${conflicts}CONFLICT: /rune:${stored_workflow} (writer, PID ${stored_pid})\n"
    elif [[ "$my_class" == "writer" || "$stored_class" == "writer" ]]; then
      conflicts="${conflicts}ADVISORY: /rune:${stored_workflow} (${stored_class}, PID ${stored_pid})\n"
    fi
  done

  # Always exit 0 — encode conflict in stdout for reliable Bash() capture
  # FLAW-002 FIX: Use %b to expand \n sequences in conflict report
  [[ -n "$conflicts" ]] && printf '%b' "$conflicts"
  return 0
}
