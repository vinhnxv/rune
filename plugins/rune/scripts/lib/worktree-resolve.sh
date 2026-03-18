#!/bin/bash
# lib/worktree-resolve.sh — Resolve project directory with worktree awareness
# Source this file. Provides: rune_resolve_project_dir(), rune_ensure_project_dir(),
#                             rune_resolve_claude_resource()
#
# DUAL-DIRECTORY MODEL:
#   RUNE_PROJECT_DIR    = worktree CWD (local state, shards, tmp/)
#   RUNE_MAIN_REPO_ROOT = original repo root (shared indexes, fallback .claude/)
#   RUNE_IN_WORKTREE    = 0 or 1
#
# In non-worktree sessions, all three resolve to the same directory.
#
# Usage (hook scripts with .cwd):
#   source "${SCRIPT_DIR}/lib/worktree-resolve.sh"
#   CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
#   rune_resolve_project_dir "$CWD" >/dev/null
#   TALISMAN_SHARD="${RUNE_PROJECT_DIR}/tmp/.talisman-resolved/shard.json"
#
# Usage (MCP startup scripts):
#   source "$(dirname "$0")/../lib/worktree-resolve.sh"
#   rune_resolve_project_dir "" >/dev/null
#   ECHO_DIR="${RUNE_PROJECT_DIR}/.rune/echoes"
#   DB_PATH="${RUNE_MAIN_REPO_ROOT}/.rune/.agent-search-index.db"

# Source guard — safe to source multiple times
[[ -n "${__RUNE_LIB_WORKTREE_RESOLVE_LOADED:-}" ]] && return 0
__RUNE_LIB_WORKTREE_RESOLVE_LOADED=1

# Global variables (set by rune_resolve_project_dir)
RUNE_PROJECT_DIR=""
RUNE_MAIN_REPO_ROOT=""
RUNE_IN_WORKTREE=0

# rune_resolve_project_dir [cwd_from_hook]
#
# Resolution priority for RUNE_PROJECT_DIR:
#   1. $1 (CWD from hook .cwd field) — most reliable in hooks
#   2. $(pwd -P) — shell CWD (correct in worktree hooks)
#   3. $CLAUDE_PROJECT_DIR — Claude Code's project root (may be wrong in worktree per #27343)
#
# Resolution for RUNE_MAIN_REPO_ROOT:
#   1. .rune-worktree-source marker (written by setup-worktree.sh)
#   2. $CLAUDE_PROJECT_DIR (always points to original repo per #27343)
#   3. Same as RUNE_PROJECT_DIR (non-worktree case)
#
# Returns: RUNE_PROJECT_DIR on stdout. Sets RUNE_PROJECT_DIR, RUNE_MAIN_REPO_ROOT,
#          RUNE_IN_WORKTREE as global variables.
rune_resolve_project_dir() {
  local hook_cwd="${1:-}"
  local resolved=""

  # Priority chain: hook CWD > pwd > CLAUDE_PROJECT_DIR
  if [[ -n "$hook_cwd" ]]; then
    resolved="$hook_cwd"
  else
    resolved="$(pwd -P 2>/dev/null || true)"
  fi
  if [[ -z "$resolved" && -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    resolved="$CLAUDE_PROJECT_DIR"
  fi

  # Canonicalize — resolve symlinks, verify absolute path
  resolved=$(cd "$resolved" 2>/dev/null && pwd -P) || resolved=""
  if [[ -z "$resolved" || "$resolved" != /* ]]; then
    echo ""
    return 1
  fi

  RUNE_PROJECT_DIR="$resolved"
  RUNE_MAIN_REPO_ROOT="$resolved"
  RUNE_IN_WORKTREE=0

  # Worktree detection: .git is a FILE (not directory) in git worktrees.
  # A regular repo has .git/ as a directory; worktrees have .git as a file
  # containing "gitdir: /path/to/main/.git/worktrees/<name>".
  if [[ -f "$resolved/.git" ]]; then
    RUNE_IN_WORKTREE=1

    # Primary: read marker for main repo root (written by setup-worktree.sh)
    local marker="$resolved/.claude/.rune-worktree-source"
    if [[ -f "$marker" && ! -L "$marker" ]]; then
      local main_root
      main_root=$(head -1 "$marker" 2>/dev/null | tr -d '\n')
      # SEC-005: Character-set validation (absolute path, safe chars) + explicit traversal guard.
      # NOTE: the regex alone does NOT block ".." — the "! *".."*" glob check is load-bearing.
      local _pattern='^/[a-zA-Z0-9_./ -]+$'
      if [[ -n "$main_root" && "$main_root" =~ $_pattern && ! "$main_root" == *".."* && -d "$main_root" ]]; then
        RUNE_MAIN_REPO_ROOT="$main_root"
      fi
    fi

    # Fallback: CLAUDE_PROJECT_DIR always points to original repo per #27343
    if [[ "$RUNE_MAIN_REPO_ROOT" == "$resolved" && -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
      local cpd
      cpd=$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P) || cpd=""
      if [[ -n "$cpd" && "$cpd" != "$resolved" && -d "$cpd/.claude" ]]; then
        RUNE_MAIN_REPO_ROOT="$cpd"
      fi
    fi
  fi

  echo "$RUNE_PROJECT_DIR"
}

# rune_ensure_project_dir
#
# Convenience: resolve for hooks that already parsed .cwd into $CWD.
# Only resolves if not already set (idempotent).
rune_ensure_project_dir() {
  if [[ -z "${RUNE_PROJECT_DIR:-}" ]]; then
    rune_resolve_project_dir "${CWD:-}" >/dev/null
  fi
}

# rune_resolve_claude_resource <relative-path>
#
# Resolve a .claude/ resource with worktree→main fallback.
# Returns absolute path to the file on stdout, empty string on failure.
# SEC-005: Rejects path traversal (.. or absolute paths in resource name).
rune_resolve_claude_resource() {
  local resource="${1:?Usage: rune_resolve_claude_resource <relative-path>}"
  rune_ensure_project_dir

  # BACK-001: Guard against empty RUNE_PROJECT_DIR (all resolution paths failed).
  # Without this, paths resolve to "/.claude/<resource>" (filesystem root).
  [[ -z "${RUNE_PROJECT_DIR:-}" ]] && { echo ""; return 1; }

  # SEC-005: Reject path traversal and absolute paths
  case "$resource" in *..* | /*) echo ""; return 1 ;; esac

  # Priority 1: worktree-local
  local local_path="${RUNE_PROJECT_DIR}/.claude/${resource}"
  if [[ -f "$local_path" && ! -L "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi

  # Priority 2: main repo (via marker or CLAUDE_PROJECT_DIR)
  if [[ "$RUNE_MAIN_REPO_ROOT" != "$RUNE_PROJECT_DIR" ]]; then
    local main_path="${RUNE_MAIN_REPO_ROOT}/.claude/${resource}"
    if [[ -f "$main_path" && ! -L "$main_path" ]]; then
      echo "$main_path"
      return 0
    fi
  fi

  echo ""
  return 1
}
