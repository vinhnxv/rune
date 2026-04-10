#!/bin/bash
# scripts/lib/worktree-gc.sh
# WORKTREE-GC: Remove when SDK provides native worktree lifecycle management
#
# Shared worktree garbage collection library.
# Reusable across Stop hook, SessionStart hook, and /rune:rest command.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/worktree-gc.sh"
#   result=$(rune_worktree_gc "$CWD" "$mode")
#   # mode: "session-stop" | "session-start" | "rest"
#   # result: human-readable summary of what was cleaned

# ── Resolve own directory and source dependencies ──
_WORKTREE_GC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../resolve-session-identity.sh
source "${_WORKTREE_GC_DIR}/../resolve-session-identity.sh"

# ── Check if git repo and worktree support available ──
rune_has_worktree_support() {
  local cwd="$1"
  git -C "$cwd" rev-parse --git-dir &>/dev/null || return 1
  git -C "$cwd" worktree list &>/dev/null 2>&1 || return 1
  return 0
}

# ── Find rune-work-* worktrees via git worktree list --porcelain ──
# Output: one line per worktree path (only rune-work-* entries)
rune_list_work_worktrees() {
  local cwd="$1"
  git -C "$cwd" worktree list --porcelain 2>/dev/null \
    | grep '^worktree ' \
    | sed 's/^worktree //' \
    | grep 'rune-work-' || true
}

# ── Find rune-work-* branches ──
# Output: one branch name per line (trimmed, no * prefix)
rune_list_work_branches() {
  local cwd="$1"
  git -C "$cwd" branch --list 'rune-work-*' 2>/dev/null \
    | sed 's/^[* ]*//' \
    | grep -v '^$' || true
}

# ── Extract timestamp from rune-work-{timestamp} pattern ──
rune_extract_wt_timestamp() {
  local name="$1"
  echo "$name" | grep -oE 'rune-work-[a-zA-Z0-9_-]+' | sed 's/rune-work-//' | head -1
}

# ── Check if a worktree/branch belongs to a live session ──
# Returns 0 if safe to remove (orphaned/dead), 1 if owned by live session (skip)
rune_wt_is_orphaned() {
  local cwd="$1" timestamp="$2"
  [[ -z "$timestamp" ]] && return 0  # no timestamp = unknown = treat as orphan

  local state_file="${cwd}/tmp/.rune-work-${timestamp}.json"
  [[ ! -f "$state_file" ]] && return 0  # no state file = orphan

  # Read ownership from state file
  local sf_cfg sf_pid
  sf_cfg=$(jq -r '.config_dir // empty' "$state_file" 2>/dev/null || true)
  sf_pid=$(jq -r '.owner_pid // empty' "$state_file" 2>/dev/null || true)

  # Different config_dir = different installation = not our problem
  if [[ -n "$sf_cfg" && "$sf_cfg" != "$RUNE_CURRENT_CFG" ]]; then
    return 1  # skip — belongs to different installation
  fi

  # Same PID as us = our session = we're cleaning our own
  if [[ -n "$sf_pid" && "$sf_pid" =~ ^[0-9]+$ ]]; then
    if [[ "$sf_pid" == "$PPID" ]]; then
      return 0  # our own session — safe to clean
    fi
    # Different PID — check if alive
    if rune_pid_alive "$sf_pid"; then
      return 1  # alive = different live session — skip
    fi
  fi

  return 0  # dead PID or no PID = orphan = safe to clean
}

# ── Clean a single worktree (with uncommitted change handling) ──
# Args: $1=worktree path, $2=CWD (main repo), $3=mode
# Returns: 0 on success, 1 on failure
rune_clean_worktree() {
  local wt_path="$1" cwd="$2" mode="${3:-session-stop}"
  [[ -z "$wt_path" ]] && return 0
  [[ ! -d "$wt_path" ]] && return 0

  # SEC: path traversal + symlink guards
  [[ "$wt_path" == *".."* ]] && return 0
  [[ -L "$wt_path" ]] && return 0

  # Check for uncommitted changes (crash mid-commit)
  local wt_status
  wt_status=$(git -C "$wt_path" status --porcelain 2>/dev/null || true)
  if [[ -n "$wt_status" ]]; then
    # Salvage uncommitted work as patch (skip in session-stop for timeout)
    local _salvage_ok=false
    if [[ "$mode" != "session-stop" && -n "$cwd" ]]; then
      local salvage_dir="${cwd}/tmp"
      # SEC-005: Symlink guard - prevent writing to attacker-controlled paths
      if [[ -d "$salvage_dir" && ! -L "$salvage_dir" ]]; then
        # ERR-013 FIX: Track salvage success before allowing reset --hard
        if git -C "$wt_path" diff HEAD > "${salvage_dir}/.rune-salvage-$(basename "$wt_path").patch" 2>/dev/null; then
          _salvage_ok=true
        else
          echo "WARN: salvage failed for $wt_path — skipping reset --hard to preserve changes" >&2
        fi
      fi
    else
      # session-stop mode: skip salvage, allow reset (timeout budget)
      _salvage_ok=true
    fi
    # ERR-013 FIX: Only reset if salvage succeeded or was intentionally skipped
    if [[ "$_salvage_ok" == "true" ]]; then
      git -C "$wt_path" reset --hard HEAD 2>/dev/null || true
    fi
  fi

  # Remove worktree (retry with --force on failure)
  # Use git -C "$cwd" for proper repository context
  if ! git -C "$cwd" worktree remove "$wt_path" 2>/dev/null; then
    if ! git -C "$cwd" worktree remove --force "$wt_path" 2>/dev/null; then
      return 1  # Failure: worktree could not be removed
    fi
  fi
  return 0  # Success
}

# ── Clean a single branch ──
# Args: $1=CWD (main repo), $2=branch name
# Returns: 0 on success, 1 on failure (including current branch)
rune_clean_branch() {
  local cwd="$1" branch="$2"
  [[ -z "$branch" ]] && return 0
  # SEC-007: Path traversal guard - block ".." in branch names
  [[ "$branch" == *".."* ]] && return 0
  # SEC: prevent injection — validate branch name
  [[ "$branch" =~ ^[a-zA-Z0-9._/-]+$ ]] || return 0
  # Never delete current branch
  local current
  current=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
  [[ "$branch" == "$current" ]] && return 1

  # Try safe delete first, force only on failure
  if ! git -C "$cwd" branch -d "$branch" 2>/dev/null; then
    if ! git -C "$cwd" branch -D "$branch" 2>/dev/null; then
      return 1  # Failure: branch could not be deleted
    fi
  fi
  return 0  # Success
}

# ── Main GC function ──
# Args: $1=CWD, $2=mode (session-stop|session-start|rest)
# Output: summary string on stdout
# Returns: always 0 (count communicated via stdout)
rune_worktree_gc() {
  local cwd="$1" mode="${2:-session-stop}"
  local cleaned_wt=0 cleaned_br=0 skipped=0

  # Fail-open: cannot verify ownership without jq (matches on-session-stop.sh:43 pattern)
  if ! command -v jq &>/dev/null; then
    echo ""
    return 0
  fi

  # Guard: git + worktree support
  if ! rune_has_worktree_support "$cwd"; then
    echo ""
    return 0
  fi

  # Mode-dependent cap to stay within timeout budgets
  local max_items=999
  if [[ "$mode" == "session-stop" ]]; then
    max_items=3  # ~1.5s budget within 5s Stop hook
  fi

  # Pass 1: Prune stale worktree entries (metadata only)
  git -C "$cwd" worktree prune 2>/dev/null || true

  # Pass 2: Remove orphaned worktrees
  local wt_path wt_timestamp
  while IFS= read -r wt_path; do
    [[ -z "$wt_path" ]] && continue
    # Check cap
    if [[ $((cleaned_wt + cleaned_br)) -ge $max_items ]]; then
      echo "GC: limit reached ($max_items), remaining deferred to /rune:rest"
      break
    fi
    wt_timestamp=$(rune_extract_wt_timestamp "$wt_path")
    if rune_wt_is_orphaned "$cwd" "$wt_timestamp"; then
      if rune_clean_worktree "$wt_path" "$cwd" "$mode"; then
        cleaned_wt=$((cleaned_wt + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done < <(rune_list_work_worktrees "$cwd")

  # Pass 3: Remove orphaned branches (may exist without worktree)
  local branch br_timestamp
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    # Check cap
    if [[ $((cleaned_wt + cleaned_br)) -ge $max_items ]]; then
      echo "GC: limit reached ($max_items), remaining deferred to /rune:rest"
      break
    fi
    br_timestamp=$(rune_extract_wt_timestamp "$branch")
    if rune_wt_is_orphaned "$cwd" "$br_timestamp"; then
      if rune_clean_branch "$cwd" "$branch"; then
        cleaned_br=$((cleaned_br + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done < <(rune_list_work_branches "$cwd")

  # Pass 4: Final prune
  git -C "$cwd" worktree prune 2>/dev/null || true

  # Build summary
  local total=$((cleaned_wt + cleaned_br))
  if [[ $total -gt 0 ]]; then
    echo "Worktrees: ${cleaned_wt} removed, branches: ${cleaned_br} removed, skipped: ${skipped} (live sessions)"
  else
    echo ""
  fi
  return 0  # Always succeed; count communicated via stdout
}
