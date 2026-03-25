#!/bin/bash
# scripts/lib/process-tree.sh
# Centralized process tree kill logic for Rune cleanup.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/process-tree.sh"
#   _rune_collect_descendants "$PPID"   # populates _RUNE_DESC_PIDS array
#   _rune_kill_tree "$PPID" "2stage" "5" "claude"
#
# DESIGN:
#   - Recursive pgrep -P walk with max depth 8
#   - 2-stage SIGTERM→SIGKILL with PID recycling guard (lstart comparison)
#   - Filter mode: "all" (default) or "claude" (node|claude|claude-* only)
#   - Uses parallel indexed arrays (Bash 3.2 compatible — no declare -A)
#   - Sources lib/platform.sh for _RUNE_PLATFORM and _proc_name if not defined
#
# SOURCING GUARD: Safe to source multiple times (idempotent).

[[ -n "${_RUNE_PROCESS_TREE_LOADED:-}" ]] && return 0
_RUNE_PROCESS_TREE_LOADED=1

# Source platform.sh for _RUNE_PLATFORM if not already loaded
_RUNE_PT_DIR="${BASH_SOURCE[0]%/*}"
if [[ -z "${_RUNE_PLATFORM:-}" ]]; then
  # shellcheck source=platform.sh
  source "${_RUNE_PT_DIR}/platform.sh"
fi

# Cross-platform process name retrieval (CLD-003 pattern from on-session-stop.sh)
# Only define if not already defined by the sourcing script.
if ! declare -f _proc_name &>/dev/null; then
  _proc_name() {
    local pid="$1"
    if [[ -r "/proc/$pid/comm" ]]; then
      cat "/proc/$pid/comm" 2>/dev/null
    else
      ps -p "$pid" -o comm= 2>/dev/null
    fi
  }
fi

# _RUNE_DESC_PIDS — populated by _rune_collect_descendants
_RUNE_DESC_PIDS=()

# _rune_collect_descendants <parent_pid> [depth]
# Recursive pgrep -P walk. Populates _RUNE_DESC_PIDS with all descendant PIDs.
# Max depth 8 to prevent runaway recursion.
_rune_collect_descendants() {
  local parent_pid="$1"
  local depth="${2:-0}"
  local max_depth=8

  [[ -z "$parent_pid" || ! "$parent_pid" =~ ^[0-9]+$ ]] && return 0
  [[ "$depth" -ge "$max_depth" ]] && return 0

  local children
  children=$(pgrep -P "$parent_pid" 2>/dev/null || true)
  [[ -z "$children" ]] && return 0

  local child_pid
  while IFS= read -r child_pid; do
    [[ -z "$child_pid" ]] && continue
    [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
    _RUNE_DESC_PIDS+=("$child_pid")
    _rune_collect_descendants "$child_pid" "$((depth + 1))"
  done <<< "$children"
}

# _rune_kill_tree <root_pid> <mode> [grace_seconds] [filter]
#
# Kills process tree rooted at root_pid.
#
# Parameters:
#   root_pid       — PID whose children to kill (the root itself is NOT killed)
#   mode           — "2stage" (SIGTERM then SIGKILL) or "term" (SIGTERM only)
#   grace_seconds  — seconds between SIGTERM and SIGKILL (default: 5)
#   filter         — "all" (default, kill all descendants) or "claude" (only node|claude|claude-*)
#
# Returns: number of processes killed (echoed to stdout)
#
# Uses parallel indexed arrays for Bash 3.2 compatibility (no declare -A).
# XVER-001: lstart-based PID recycling detection between SIGTERM and SIGKILL.
_rune_kill_tree() {
  local root_pid="$1"
  local mode="${2:-2stage}"
  local grace="${3:-5}"
  local filter="${4:-all}"
  local killed=0

  [[ -z "$root_pid" || ! "$root_pid" =~ ^[0-9]+$ ]] && echo "0" && return 0

  # Validate root_pid is alive.
  # When root is dead, its children are re-parented to PID 1 (init/launchd).
  # pgrep -P on a dead PID returns nothing — orphaned grandchildren are not
  # targetable via this tree walk. This is by design: re-parented processes
  # belong to the OS, not to our session.
  if ! kill -0 "$root_pid" 2>/dev/null; then
    echo "0"
    return 0
  fi

  # Collect all descendants
  _RUNE_DESC_PIDS=()
  _rune_collect_descendants "$root_pid"
  [[ ${#_RUNE_DESC_PIDS[@]} -eq 0 ]] && echo "0" && return 0

  # Phase 1: SIGTERM eligible descendants
  # Parallel arrays for PID recycling guard (Bash 3.2 — no associative arrays)
  local _kill_pids=()
  local _kill_lstarts=()

  local pid child_comm child_lstart
  for pid in "${_RUNE_DESC_PIDS[@]}"; do
    [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue

    # Apply filter
    if [[ "$filter" == "claude" ]]; then
      child_comm=$(_proc_name "$pid")
      case "$child_comm" in
        node|claude|claude-*) ;;
        *) continue ;;
      esac
    fi

    # XVER-001: Record lstart before SIGTERM for recycling detection
    child_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ' || echo "")
    kill -TERM "$pid" 2>/dev/null || true
    _kill_pids+=("$pid")
    _kill_lstarts+=("${child_lstart:-unknown}")
  done

  [[ ${#_kill_pids[@]} -eq 0 ]] && echo "0" && return 0

  # Count SIGTERM'd processes (FLAW-008 fix: track all terminated, not just SIGKILL'd)
  killed=${#_kill_pids[@]}

  # If term-only mode, we're done
  if [[ "$mode" == "term" ]]; then
    echo "$killed"
    return 0
  fi

  # Phase 2: Wait grace period, then SIGKILL survivors
  sleep "$grace" 2>/dev/null || sleep 1

  local idx=0
  for pid in "${_kill_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      # Re-verify process identity (PID recycling guard — CLD-003)
      if [[ "$filter" == "claude" ]]; then
        child_comm=$(_proc_name "$pid")
        case "$child_comm" in
          node|claude|claude-*) ;;
          *)
            idx=$((idx + 1))
            continue
            ;;
        esac
      fi

      # XVER-001: Verify lstart hasn't changed (PID recycling detection)
      local orig_lstart="${_kill_lstarts[$idx]}"
      local cur_lstart
      cur_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ' || echo "")
      if [[ "$orig_lstart" != "unknown" && -n "$cur_lstart" && "$orig_lstart" != "$cur_lstart" ]]; then
        # PID was recycled — different process start time, skip
        idx=$((idx + 1))
        continue
      fi

      if kill -KILL "$pid" 2>/dev/null; then
        killed=$((killed + 1))
      fi
    fi
    idx=$((idx + 1))
  done

  echo "$killed"
  return 0
}
