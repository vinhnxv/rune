#!/usr/bin/env bash
# lib/rune-state.sh — Rune state directory resolution
# Source this file in all scripts that reference Rune state paths.
#
# IMPORTANT: Set CWD or CLAUDE_PROJECT_DIR before sourcing this file.
# Fallback to $(pwd) is best-effort and may not be the project root in hook contexts.
#
# Provides:
#   RUNE_STATE       — relative path to Rune state dir (default: ".rune")
#   RUNE_STATE_ABS   — absolute path to .rune/ at MAIN REPO root
#   _rune_ensure_dir — creates .rune/ if it doesn't exist
#   _rune_migrate_legacy — one-time migration from .claude/ to .rune/

# Constant — hardcoded, not env-overridable (project-relative, no multi-account concern)
RUNE_STATE=".rune"

# Deprecation timeline: .claude/ fallback paths will be removed in v3.0.0
# All dual-support code sites should reference this constant for grep-ability
RUNE_LEGACY_SUPPORT_UNTIL="3.0.0"

# Resolve absolute path to .rune/ at the MAIN REPO root.
# Priority: CLAUDE_PROJECT_DIR > CWD > pwd
#
# WHY CLAUDE_PROJECT_DIR first:
#   In worktree context, CWD may point to the worktree directory (e.g.,
#   /repo/.worktrees/rune-work-123/), but .rune/ state (echoes, talisman,
#   arc checkpoints) is SHARED and must live at the main repo root.
#   CLAUDE_PROJECT_DIR always points to the original repo per Claude Code #27343.
#
# See lib/worktree-resolve.sh for the dual-directory model:
#   RUNE_PROJECT_DIR    = worktree CWD (local: tmp/, shards)
#   RUNE_MAIN_REPO_ROOT = main repo (shared: .rune/)
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  RUNE_STATE_ABS="${CLAUDE_PROJECT_DIR}/${RUNE_STATE}"
elif [[ -n "${CWD:-}" ]]; then
  RUNE_STATE_ABS="${CWD}/${RUNE_STATE}"
else
  RUNE_STATE_ABS="$(pwd)/${RUNE_STATE}"
fi

# Bootstrap: create .rune/ if it doesn't exist
_rune_ensure_dir() {
  [[ -d "${RUNE_STATE_ABS}" ]] || mkdir -p "${RUNE_STATE_ABS}" 2>/dev/null || {
    echo >&2 "[rune] WARN: cannot create ${RUNE_STATE_ABS}"
    return 1
  }
}

# Migration check: move legacy .claude/ state to .rune/ (one-time, idempotent)
# Called by session-start.sh and talisman-resolve.sh
#
# Design: per-resource idempotent. Interruption leaves a partially-migrated state
# that self-heals on next session start (each item checks independently).
#
# Security: rejects symlinks on both source and target to prevent symlink attacks
# (consistent with symlink checks in stop-hook-common.sh, talisman-resolve.sh)
#
# Concurrency: uses mkdir-based POSIX-atomic lock to prevent race conditions
# when two sessions start simultaneously on the same project.
_rune_migrate_legacy() {
  local project_dir="${1:-${CWD:-$(pwd)}}"
  local legacy="${project_dir}/.claude"
  local target="${project_dir}/${RUNE_STATE}"
  local migrated=0
  local _warn_count=0

  # SEC-002: reject if legacy or target dir is a symlink
  [[ -L "${legacy}" ]] && return 0
  [[ -L "${target}" ]] && return 0

  # Atomic lock: prevent concurrent migration from parallel sessions
  # mkdir is atomic on all POSIX filesystems — only one process succeeds
  local _lockdir="${target}/.migration-lock"
  mkdir -p "${target}" 2>/dev/null || {
    echo >&2 "[rune] WARN: cannot create ${target} — migration skipped"
    return 0
  }
  if ! mkdir "${_lockdir}" 2>/dev/null; then
    # Lock held — check if stale (>5 min old = likely from crashed prior session).
    # T1 fix: stale-check + force-remove + retry recovers from the scenario where a
    # previous migration died before cleanup (trap-less by design for sourced files).
    if [[ -n "$(find "${_lockdir}" -maxdepth 0 -mmin +5 2>/dev/null)" ]]; then
      rm -rf "${_lockdir}" 2>/dev/null
      if ! mkdir "${_lockdir}" 2>/dev/null; then
        return 0
      fi
    else
      # Active lock from another session — skip (it will complete the migration)
      return 0
    fi
  fi
  # Ensure lock is released on function exit (normal or error)
  # FLAW-001 fix: Explicit cleanup at each exit point instead of trap.
  # trap ... RETURN leaks to callers on bash 4.0+; trap ... EXIT overwrites
  # the caller's EXIT trap when this file is sourced. Both are unsafe.
  # T1 fix: stale-check above is the compensating mechanism for mid-function crashes.

  # Helper: migrate a single item with error logging
  _migrate_item() {
    local src="$1" dst="$2" label="$3"
    if ! mv "${src}" "${dst}" 2>/dev/null; then
      echo >&2 "[rune] WARN: failed to migrate ${label} — manual move may be needed"
      _warn_count=$((_warn_count + 1))
      return 1
    fi
    migrated=1
    return 0
  }

  # BUG-001 FIX: Track critical migration failures. If arc/echoes/talisman fail,
  # skip remaining items to prevent partial state corruption.
  local _critical_failed=0

  # Arc checkpoints (CRITICAL)
  if [[ -d "${legacy}/arc" ]] && [[ ! -L "${legacy}/arc" ]] && [[ ! -d "${target}/arc" ]]; then
    _migrate_item "${legacy}/arc" "${target}/arc" ".claude/arc" || _critical_failed=1
  fi

  # Echoes (CRITICAL)
  if [[ $_critical_failed -eq 0 ]] && [[ -d "${legacy}/echoes" ]] && [[ ! -L "${legacy}/echoes" ]] && [[ ! -d "${target}/echoes" ]]; then
    _migrate_item "${legacy}/echoes" "${target}/echoes" ".claude/echoes" || _critical_failed=1
  fi

  # Talisman (CRITICAL)
  if [[ $_critical_failed -eq 0 ]] && [[ -f "${legacy}/talisman.yml" ]] && [[ ! -L "${legacy}/talisman.yml" ]] && [[ ! -f "${target}/talisman.yml" ]]; then
    _migrate_item "${legacy}/talisman.yml" "${target}/talisman.yml" ".claude/talisman.yml" || _critical_failed=1
  fi

  # If critical items failed, skip remaining non-critical items to avoid partial state
  if [[ $_critical_failed -eq 1 ]]; then
    echo >&2 "[rune] CRITICAL: Migration of core state items failed — skipping remaining items."
    echo >&2 "[rune] CRITICAL: Manual migration may be needed: check both .claude/ and .rune/"
    # T1 fix: rm -rf (not rmdir) so any residue inside the lockdir is also removed.
    rm -rf "${_lockdir}" 2>/dev/null || true
    return 0
  fi

  # Audit state
  if [[ -d "${legacy}/audit-state" ]] && [[ ! -L "${legacy}/audit-state" ]] && [[ ! -d "${target}/audit-state" ]]; then
    _migrate_item "${legacy}/audit-state" "${target}/audit-state" ".claude/audit-state"
  fi

  # Worktrees — DO NOT migrate. Claude Code SDK creates worktrees at .claude/worktrees/
  # (not .rune/worktrees/). Moving them would break git worktree references.
  # The .rune/worktrees/ directory (if it exists from older Rune versions) is unused.

  # Agent search index — migrate .db + .db-shm + .db-wal as a group for SQLite integrity
  # FLAW-004: Individual migration can corrupt the DB if interrupted between .db and -wal moves
  # SEC-006: Check symlinks on ALL companion files, not just the main .db
  if [[ -f "${legacy}/.agent-search-index.db" ]] && [[ ! -L "${legacy}/.agent-search-index.db" ]] && [[ ! -f "${target}/.agent-search-index.db" ]]; then
    local _db_ok=1
    for ext in "" "-shm" "-wal"; do
      if [[ -f "${legacy}/.agent-search-index.db${ext}" ]]; then
        # SEC-006: reject symlinks on companion files too
        if [[ -L "${legacy}/.agent-search-index.db${ext}" ]]; then
          echo >&2 "[rune] WARN: .agent-search-index.db${ext} is a symlink — skipping SQLite migration"
          _db_ok=0
          break
        fi
        mv "${legacy}/.agent-search-index.db${ext}" "${target}/.agent-search-index.db${ext}" 2>/dev/null || _db_ok=0
      fi
    done
    if [[ $_db_ok -eq 1 ]]; then
      migrated=1
    else
      # Rollback: move back any files that were successfully moved
      for ext in "" "-shm" "-wal"; do
        if [[ -f "${target}/.agent-search-index.db${ext}" ]] && [[ ! -f "${legacy}/.agent-search-index.db${ext}" ]]; then
          if ! mv "${target}/.agent-search-index.db${ext}" "${legacy}/.agent-search-index.db${ext}" 2>/dev/null; then
            echo >&2 "[rune] CRITICAL: rollback of .agent-search-index.db${ext} failed — check both .claude/ and .rune/"
          fi
        fi
      done
    fi
  fi

  # Test history
  if [[ -d "${legacy}/test-history" ]] && [[ ! -L "${legacy}/test-history" ]] && [[ ! -d "${target}/test-history" ]]; then
    _migrate_item "${legacy}/test-history" "${target}/test-history" ".claude/test-history"
  fi

  # Test scenarios
  if [[ -d "${legacy}/test-scenarios" ]] && [[ ! -L "${legacy}/test-scenarios" ]] && [[ ! -d "${target}/test-scenarios" ]]; then
    _migrate_item "${legacy}/test-scenarios" "${target}/test-scenarios" ".claude/test-scenarios"
  fi

  # Visual baselines
  if [[ -d "${legacy}/visual-baselines" ]] && [[ ! -L "${legacy}/visual-baselines" ]] && [[ ! -d "${target}/visual-baselines" ]]; then
    _migrate_item "${legacy}/visual-baselines" "${target}/visual-baselines" ".claude/visual-baselines"
  fi

  # Design sync state
  if [[ -d "${legacy}/design-sync" ]] && [[ ! -L "${legacy}/design-sync" ]] && [[ ! -d "${target}/design-sync" ]]; then
    _migrate_item "${legacy}/design-sync" "${target}/design-sync" ".claude/design-sync"
  fi

  # Design system profile
  if [[ -f "${legacy}/design-system-profile.yaml" ]] && [[ ! -L "${legacy}/design-system-profile.yaml" ]] && [[ ! -f "${target}/design-system-profile.yaml" ]]; then
    _migrate_item "${legacy}/design-system-profile.yaml" "${target}/design-system-profile.yaml" ".claude/design-system-profile.yaml"
  fi

  # Loop state files (if session crashed and left them behind)
  for loop_file in arc-phase-loop.local.md arc-batch-loop.local.md arc-hierarchy-loop.local.md arc-issues-loop.local.md arc-hierarchy-exec-table.json; do
    if [[ -f "${legacy}/${loop_file}" ]] && [[ ! -L "${legacy}/${loop_file}" ]] && [[ ! -f "${target}/${loop_file}" ]]; then
      _migrate_item "${legacy}/${loop_file}" "${target}/${loop_file}" ".claude/${loop_file}"
    fi
  done

  if [[ $migrated -eq 1 ]]; then
    echo >&2 "[rune] Migrated legacy state from .claude/ to .rune/"
  fi
  if [[ $_warn_count -gt 0 ]]; then
    echo >&2 "[rune] Migration completed with ${_warn_count} warning(s) — some items may need manual migration"
  fi

  # FLAW-001: Explicit lock release (no trap — see comment at lock acquisition)
  # T1 fix: force-remove with rm -rf. Prior `rmdir` failed silently on non-empty
  # lockdirs (e.g., after a crashed subprocess left residue), blocking all future
  # migrations. Stale-lock detection at acquisition handles mid-function crashes.
  rm -rf "${_lockdir}" 2>/dev/null || true
}
