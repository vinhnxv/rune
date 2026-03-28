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

# zsh-compat: BASH_SOURCE is empty in zsh; fall back to $0 for sourced scripts
if [[ -n "${BASH_VERSION:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Soft dep: resolve-session-identity.sh provides RUNE_CURRENT_CFG + rune_pid_alive
if [[ -f "${SCRIPT_DIR}/../resolve-session-identity.sh" ]]; then
  source "${SCRIPT_DIR}/../resolve-session-identity.sh"
fi
# Fallback stub if rune_pid_alive was not loaded
if ! type rune_pid_alive &>/dev/null; then
  rune_pid_alive() {
    local err rc=0
    # CDX-BUG-002 FIX: Use `|| rc=$?` to prevent set -e from aborting before rc is captured.
    # Original `err=$(kill -0 ...); rc=$?` fails under set -e because the failed command
    # substitution exits nonzero, triggering shell abort before rc=$? executes.
    err=$(kill -0 "$1" 2>&1) || rc=$?
    [[ $rc -eq 0 ]] && return 0
    # EPERM means process exists but we lack permission — treat as alive
    # Single-call pattern avoids TOCTOU (matches resolve-session-identity.sh)
    # FLAW-006: Multi-pattern rationale — *ermission* covers English "Permission denied"/"Operation not permitted",
    # *[Pp]erm* covers locale-abbreviated variants, *EPERM* covers raw errno string. Overlap is intentional for robustness.
    case "$err" in *ermission*|*[Pp]erm*|*EPERM*) return 0 ;; esac
    return 1
  }
fi

# SEC-001: Resolve LOCK_BASE to absolute path (anchored to MAIN repo root, not worktree)
# SEC-006: git may be absent or output may contain unexpected whitespace — validate output
# WORKTREE-FIX: $SCRIPT_DIR is the plugin's scripts/lib/ dir (in plugin cache),
# NOT inside the project repo. So `git -C "$SCRIPT_DIR"` always FAILS for both
# --show-toplevel and --git-common-dir. The existing code falls back to $(pwd).
# In a worktree, $(pwd) = worktree root → locks are isolated (broken).
# Fix: After $(pwd) fallback, check for .rune-worktree-source marker to resolve
# the main repo root for shared lock visibility.
if ! command -v git &>/dev/null; then
  echo "[rune-lock] ERROR: git not found — workflow locking requires git" >&2
  return 1 2>/dev/null || exit 1
fi
_RUNE_LOCK_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\n' || true)"
# SEC-006: Reject output if empty or contains path traversal / unsafe characters
# Note: regex stored in variable to avoid bash/zsh parse errors with character classes
_RUNE_LOCK_PATTERN='^/[a-zA-Z0-9_./ -]+$'
if [[ -z "$_RUNE_LOCK_ROOT" ]] || [[ ! "$_RUNE_LOCK_ROOT" =~ $_RUNE_LOCK_PATTERN ]]; then
  _RUNE_LOCK_ROOT="$(pwd)"
fi

# WORKTREE-FIX: Only redirect when _RUNE_LOCK_ROOT is actually a worktree
# (.git is a file, not a directory, in git worktrees). This structural check
# prevents accidental redirect if a .rune-worktree-source marker exists in
# a non-worktree repo (e.g., surviving a deleted worktree).
if [[ -f "$_RUNE_LOCK_ROOT/.git" ]]; then
  _RUNE_WT_MARKER="${_RUNE_LOCK_ROOT}/.rune/.rune-worktree-source"
  # Fallback to legacy marker location (pre-migration worktrees)
  if [[ ! -f "$_RUNE_WT_MARKER" || -L "$_RUNE_WT_MARKER" ]]; then
    _legacy="${_RUNE_LOCK_ROOT}/.claude/.rune-worktree-source"
    [[ -f "$_legacy" && ! -L "$_legacy" ]] && _RUNE_WT_MARKER="$_legacy"
  fi
  if [[ -f "$_RUNE_WT_MARKER" && ! -L "$_RUNE_WT_MARKER" ]]; then
    _RUNE_MAIN_ROOT=$(head -1 "$_RUNE_WT_MARKER" 2>/dev/null | tr -d '\n')
    # SEC: Character-set validation (absolute path, safe chars) + explicit traversal guard.
    # NOTE: the regex alone does NOT block ".." — the "! *".."*" glob check is load-bearing.
    if [[ -n "$_RUNE_MAIN_ROOT" && "$_RUNE_MAIN_ROOT" =~ $_RUNE_LOCK_PATTERN && ! "$_RUNE_MAIN_ROOT" == *".."* && -d "$_RUNE_MAIN_ROOT" ]]; then
      _RUNE_LOCK_ROOT="$_RUNE_MAIN_ROOT"
    fi
  fi
fi

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

# Helper: build meta.json content to stdout (SEC-002: safe JSON escaping)
_rune_build_meta() {
  local workflow="$1" class="$2"
  local _cfg="${RUNE_CURRENT_CFG:-$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")}"
  jq -n \
    --arg wf "$workflow" --arg cls "$class" --argjson pid "$PPID" \
    --arg cfg "$_cfg" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-unknown}}" \
    '{workflow:$wf,class:$cls,pid:$pid,config_dir:$cfg,started:$ts,session_id:$sid}'
}

# Helper: write meta.json atomically from pre-written temp file
# CDXS-003 FIX: Uses mktemp for unpredictable temp file names (prevents symlink pre-placement)
# XVER-001 FIX: Expects meta content already written to temp file before lock acquisition
_rune_finalize_meta() {
  local tmp_file="$1" lock_dir="$2"
  # Atomic move from temp to final location
  mv -f "$tmp_file" "$lock_dir/meta.json" 2>/dev/null
}

# Helper: Atomic lock reclaim — stash existing lock, mkdir new, finalize meta, cleanup stash
# Eliminates TOCTOU window by using rename-based stash instead of rm+mkdir
# XQAL-002 FIX: Extracted from 3 duplicate reclaim paths (orphan, dead, ghost)
# Returns 0 on success (lock reclaimed), 1 on failure (contention loss or error)
_rune_atomic_reclaim() {
  local lock_dir="$1" workflow="$2" class="$3" label="${4:-reclaim}"
  local _reclaim_tmp _reclaim_stash

  # Step 1: Write metadata to temp file BEFORE lock manipulation
  # FLAW-003 FIX: Fallback to TMPDIR if LOCK_BASE mktemp fails (e.g., missing dir or no write perms)
  _reclaim_tmp="$(mktemp "${LOCK_BASE}/.meta.XXXXXX" 2>/dev/null)" || \
    _reclaim_tmp="$(mktemp "${TMPDIR:-/tmp}/.rune-meta.XXXXXX" 2>/dev/null)" || return 1
  if ! _rune_build_meta "$workflow" "$class" > "$_reclaim_tmp" 2>/dev/null; then
    rm -f "$_reclaim_tmp" 2>/dev/null; return 1
  fi

  # Step 2: Create unpredictable stash directory (kept as container — NOT removed)
  # CLD-BUG-001 FIX: Eliminated TOCTOU race by removing the rmdir step entirely.
  # Old pattern: mktemp -d → rmdir (free name) → mv lock to freed name
  #   Race window: between rmdir and mv, another process could mkdir at the freed path,
  #   causing mv to move lock_dir INSIDE the new directory instead of renaming it.
  # New pattern: mktemp -d (keep it) → mv lock INSIDE stash dir → stash name is never freed.
  _reclaim_stash="$(mktemp -d "${lock_dir}.${label}.XXXXXX" 2>/dev/null)" || \
    _reclaim_stash="$(mktemp -d "${TMPDIR:-/tmp}/rune-${label}.XXXXXX" 2>/dev/null)" || \
    { [[ "${RUNE_TRACE:-0}" == "1" ]] && echo "[rune-lock] TRACE: mktemp -d failed for both ${lock_dir}.${label}.XXXXXX and \${TMPDIR}/rune-${label}.XXXXXX" >&2; \
      rm -f "$_reclaim_tmp" 2>/dev/null; return 1; }

  # Step 3: Atomic rename of existing lock INTO the stash (no rmdir = no TOCTOU window)
  mv "$lock_dir" "$_reclaim_stash/stale" 2>/dev/null || { rm -rf "$_reclaim_stash" 2>/dev/null; rm -f "$_reclaim_tmp" 2>/dev/null; return 1; }

  # Step 4: Atomic mkdir for new lock
  if mkdir "$lock_dir" 2>/dev/null; then
    _rune_finalize_meta "$_reclaim_tmp" "$lock_dir"
    rm -rf "$_reclaim_stash" 2>/dev/null
    if [[ -f "$lock_dir/meta.json" ]]; then
      return 0
    fi
    # DEEP-104 FIX: Finalize failed — restore stashed lock to preserve old metadata
    mv "$_reclaim_stash/stale" "$lock_dir" 2>/dev/null || true
    rm -rf "$_reclaim_stash" 2>/dev/null
    rm -f "$_reclaim_tmp" 2>/dev/null
    return 1
  fi

  # Step 5: mkdir failed (contention loss) — restore stashed lock
  mv "$_reclaim_stash/stale" "$lock_dir" 2>/dev/null || true
  rm -rf "$_reclaim_stash" 2>/dev/null
  rm -f "$_reclaim_tmp" 2>/dev/null
  return 1
}

rune_acquire_lock() {
  local workflow="$1" class="${2:-writer}"
  _rune_validate_workflow_name "$workflow" || return 1
  local lock_dir="${LOCK_BASE}/${workflow}"

  # mkdir is POSIX-atomic — fails if exists
  # BACK-005: Re-check for symlinks on parent dir after mkdir -p (symlink may have been created between checks)
  if mkdir -p "$(dirname "$lock_dir")" 2>/dev/null; then
    [[ -L "$(dirname "$lock_dir")" ]] && return 1
  else
    return 1
  fi
  # XVER-001 FIX: Write metadata to temp file BEFORE mkdir to eliminate TOCTOU window
  # CDXS-003 FIX: Use mktemp for unpredictable temp file name (prevents symlink pre-placement)
  local _meta_tmp
  _meta_tmp="$(mktemp "${LOCK_BASE}/.meta.XXXXXX" 2>/dev/null)" || return 1
  if ! _rune_build_meta "$workflow" "$class" > "$_meta_tmp" 2>/dev/null; then
    rm -f "$_meta_tmp" 2>/dev/null; return 1
  fi

  if mkdir "$lock_dir" 2>/dev/null; then
    # Atomic move of pre-written metadata into the lock directory
    _rune_finalize_meta "$_meta_tmp" "$lock_dir"
    if [[ ! -f "$lock_dir/meta.json" ]]; then
      rm -rf "$lock_dir" "$_meta_tmp" 2>/dev/null; return 1
    fi
    return 0
  fi
  # mkdir failed (lock exists) — clean up temp file
  rm -f "$_meta_tmp" 2>/dev/null

  # Lock dir exists — check ownership
  _rune_lock_safe "$lock_dir" || return 1
  if [[ -f "$lock_dir/meta.json" ]]; then
    _rune_lock_safe "$lock_dir/meta.json" || return 1
    local stored_pid stored_cfg stored_sid
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_cfg=$(jq -r '.config_dir // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_sid=$(jq -r '.session_id // empty' "$lock_dir/meta.json" 2>/dev/null || true)

    # BACK-003: Different installation → not our concern, fall through (do not block)
    local _current_cfg="${RUNE_CURRENT_CFG:-$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P || echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")}"
    [[ -n "$stored_cfg" && "$stored_cfg" != "$_current_cfg" ]] && return 0
    # BIZL-004: Same session → re-entrant (e.g., arc delegating to strive)
    # Validate both PID and session_id when available for stronger session identity
    local _current_sid="${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-unknown}}"
    if [[ -n "$stored_pid" && "$stored_pid" == "$PPID" ]]; then
      # PID matches — also verify session_id if both sides have one
      if [[ "$stored_sid" != "unknown" && "$_current_sid" != "unknown" && "$stored_sid" != "$_current_sid" ]]; then
        # Same PID but different session_id → PID was recycled, treat as stale
        :
      else
        return 0
      fi
    fi

    # BIZL-010: Null pid guard — empty stored_pid means corrupt meta.json, treat as orphan
    # XQAL-002 FIX: Uses shared _rune_atomic_reclaim helper (extracted from 3 duplicate paths)
    if [[ -z "$stored_pid" ]]; then
      _rune_atomic_reclaim "$lock_dir" "$workflow" "$class" "orphan" && return 0
      return 1
    fi

    # PID dead → orphaned lock, reclaim
    # SEC-007: TOCTOU fix — atomic stash-and-reclaim; contention loss = return 1.
    if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
      if ! rune_pid_alive "$stored_pid"; then
        _rune_atomic_reclaim "$lock_dir" "$workflow" "$class" "dead" && return 0
        return 1
      fi
    fi
  else
    # Ghost lock dir (no meta.json) — clean up and retry with jitter
    # EDGE-007: Add retry with random jitter to reduce concurrent write race window
    # XQAL-002 FIX: Uses shared _rune_atomic_reclaim helper
    local _ghost_attempt
    for _ghost_attempt in 1 2; do
      # Jitter: sleep 0-50ms on retry to desynchronize concurrent acquirers
      if [[ "$_ghost_attempt" -gt 1 ]]; then
        # RUIN-002 FIX: Multi-tier jitter fallback — perl (sub-ms) → bash $RANDOM (0-49ms via sleep) → no-op
      perl -e 'select(undef,undef,undef,rand(0.05))' 2>/dev/null || \
        sleep "0.0$((RANDOM % 50))" 2>/dev/null || \
        true
      fi
      _rune_atomic_reclaim "$lock_dir" "$workflow" "$class" "ghost" && return 0
    done
  fi

  return 1  # Conflict — another live session holds the lock
}

rune_release_lock() {
  local workflow="$1"
  _rune_validate_workflow_name "$workflow" || return 0
  local lock_dir="${LOCK_BASE}/${workflow}"

  [[ -d "$lock_dir" ]] || return 0
  _rune_lock_safe "$lock_dir" || return 0

  # Ownership check — only release our own locks (PID + session_id)
  if [[ -f "$lock_dir/meta.json" ]]; then
    local stored_pid stored_sid
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    stored_sid=$(jq -r '.session_id // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    local _current_sid="${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-unknown}}"
    # BIZL-004: Require both PID and session_id match for release (when available)
    if [[ "$stored_pid" == "$PPID" ]]; then
      if [[ "$stored_sid" == "unknown" || "$_current_sid" == "unknown" || "$stored_sid" == "$_current_sid" ]]; then
        rm -rf "$lock_dir" 2>/dev/null
      fi
    fi
  fi
  return 0
}

# Release ALL locks owned by this PID (for arc final cleanup)
rune_release_all_locks() {
  [[ -d "$LOCK_BASE" ]] || return 0
  local stored_pid
  # zsh-compat: shopt is bash-only; use setopt localoptions for zsh
  # BACK-011: Save and restore nullglob state to avoid leaking into caller
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt localoptions nullglob 2>/dev/null
  else
    local _nullglob_was_set=0
    shopt -q nullglob 2>/dev/null && _nullglob_was_set=1
    shopt -s nullglob 2>/dev/null || true
  fi
  for lock_dir in "$LOCK_BASE"/*/; do
    [[ -d "$lock_dir" ]] || continue
    _rune_lock_safe "$lock_dir" || continue
    [[ -f "$lock_dir/meta.json" ]] || { rm -rf "$lock_dir" 2>/dev/null; continue; }
    stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
    [[ "$stored_pid" == "$PPID" ]] && rm -rf "$lock_dir" 2>/dev/null
  done
  # BACK-011: Restore nullglob state to avoid leaking into caller (bash only)
  if [[ -z "${ZSH_VERSION:-}" && "${_nullglob_was_set:-0}" == "0" ]]; then
    shopt -u nullglob 2>/dev/null || true
  fi
  return 0
}

rune_check_conflicts() {
  local my_class="${1:-writer}"
  local conflicts=""

  [[ -d "$LOCK_BASE" ]] || return 0

  # FLAW-003: zsh-compat — protect glob from NOMATCH error
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt localoptions nullglob 2>/dev/null
  else
    # FLAW-005 FIX: Save nullglob state to restore after loop
    # BACK-003 FIX: Standardized to match rune_release_all_locks pattern (0=not set, 1=was set)
    local _ng_was_set=0
    shopt -q nullglob 2>/dev/null && _ng_was_set=1
    shopt -s nullglob 2>/dev/null || true
  fi
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
    #
    # DECREE-004: ADVISORY allows reader+writer simultaneous execution.
    # Race condition behavior: A code review (reader) running simultaneously
    # with strive (writer) may see inconsistent file states if files are
    # modified during the read. This is accepted for parallel workflow
    # efficiency. Users seeking atomic consistency should run workflows
    # sequentially or use git commits as synchronization points.
    if [[ "$my_class" == "writer" && "$stored_class" == "writer" ]]; then
      conflicts="${conflicts}CONFLICT: /rune:${stored_workflow} (writer, PID ${stored_pid})\n"
    elif [[ "$my_class" == "writer" || "$stored_class" == "writer" ]]; then
      conflicts="${conflicts}ADVISORY: /rune:${stored_workflow} (${stored_class}, PID ${stored_pid})\n"
    fi
  done

  # FLAW-005 FIX: Restore nullglob state (bash only — zsh uses localoptions)
  # BACK-003 FIX: Standardized — unset only when nullglob was NOT already set (0 = not set)
  if [[ -z "${ZSH_VERSION:-}" && "${_ng_was_set:-0}" == "0" ]]; then
    shopt -u nullglob 2>/dev/null || true
  fi

  # Always exit 0 — encode conflict in stdout for reliable Bash() capture
  # FLAW-002 FIX: Use %b to expand \n sequences in conflict report
  [[ -n "$conflicts" ]] && printf '%b' "$conflicts"
  return 0
}
