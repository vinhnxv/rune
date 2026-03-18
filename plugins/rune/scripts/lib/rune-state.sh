#!/usr/bin/env bash
# lib/rune-state.sh — Rune state directory resolution
# Source this file in all scripts that reference Rune state paths.
#
# Provides:
#   RUNE_STATE       — relative path to Rune state dir (default: ".rune")
#   RUNE_STATE_ABS   — absolute path to .rune/ at MAIN REPO root
#   _rune_ensure_dir — creates .rune/ if it doesn't exist
#   _rune_migrate_legacy — one-time migration from .claude/ to .rune/

# Constant — hardcoded, not env-overridable (project-relative, no multi-account concern)
RUNE_STATE=".rune"

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
  [[ -d "${RUNE_STATE_ABS}" ]] || mkdir -p "${RUNE_STATE_ABS}"
}

# Migration check: move legacy .claude/ state to .rune/ (one-time, idempotent)
# Called by session-start.sh and talisman-resolve.sh
_rune_migrate_legacy() {
  local project_dir="${1:-${CWD:-$(pwd)}}"
  local legacy="${project_dir}/.claude"
  local target="${project_dir}/${RUNE_STATE}"
  local migrated=0

  # Only migrate if target doesn't already have the files
  # Arc checkpoints
  if [[ -d "${legacy}/arc" ]] && [[ ! -d "${target}/arc" ]]; then
    mkdir -p "${target}"
    mv "${legacy}/arc" "${target}/arc" 2>/dev/null && migrated=1
  fi

  # Echoes
  if [[ -d "${legacy}/echoes" ]] && [[ ! -d "${target}/echoes" ]]; then
    mkdir -p "${target}"
    mv "${legacy}/echoes" "${target}/echoes" 2>/dev/null && migrated=1
  fi

  # Talisman
  if [[ -f "${legacy}/talisman.yml" ]] && [[ ! -f "${target}/talisman.yml" ]]; then
    mkdir -p "${target}"
    mv "${legacy}/talisman.yml" "${target}/talisman.yml" 2>/dev/null && migrated=1
  fi

  # Audit state
  if [[ -d "${legacy}/audit-state" ]] && [[ ! -d "${target}/audit-state" ]]; then
    mkdir -p "${target}"
    mv "${legacy}/audit-state" "${target}/audit-state" 2>/dev/null && migrated=1
  fi

  # Worktrees
  if [[ -d "${legacy}/worktrees" ]] && [[ ! -d "${target}/worktrees" ]]; then
    mkdir -p "${target}"
    mv "${legacy}/worktrees" "${target}/worktrees" 2>/dev/null && migrated=1
  fi

  # Agent search index
  for ext in "" "-shm" "-wal"; do
    if [[ -f "${legacy}/.agent-search-index.db${ext}" ]] && [[ ! -f "${target}/.agent-search-index.db${ext}" ]]; then
      mkdir -p "${target}"
      mv "${legacy}/.agent-search-index.db${ext}" "${target}/.agent-search-index.db${ext}" 2>/dev/null && migrated=1
    fi
  done

  # Loop state files (if session crashed and left them behind)
  for loop_file in arc-phase-loop.local.md arc-batch-loop.local.md arc-hierarchy-loop.local.md arc-issues-loop.local.md arc-hierarchy-exec-table.json; do
    if [[ -f "${legacy}/${loop_file}" ]] && [[ ! -f "${target}/${loop_file}" ]]; then
      mkdir -p "${target}"
      mv "${legacy}/${loop_file}" "${target}/${loop_file}" 2>/dev/null && migrated=1
    fi
  done

  if [[ $migrated -eq 1 ]]; then
    echo >&2 "[rune] Migrated legacy state from .claude/ to .rune/"
  fi
}
