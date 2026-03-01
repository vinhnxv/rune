#!/usr/bin/env bash
# detect-workflow-complete.sh — Stop hook: deterministic post-workflow teammate cleanup
# OPERATIONAL hook — fail-forward (ADR-002)
# Fires on every Stop event. Fast-path exit when no active workflows.
#
# Layer 5 defense: Hook-driven workflow boundary cleanup.
# Detects workflows that completed but whose teams weren't cleaned up by
# the prompt-driven path. Executes 2-stage process-level escalation (SIGTERM -> SIGKILL).
#
# Two trigger cases:
#   Case 1: Status transitioned to completed/failed/cancelled but team dir still exists
#           (prompt-driven cleanup failed — orchestrator context exhausted)
#   Case 2: Orphan — owner PID dead, status still active
#
# NOTE: Stop hooks cannot call SDK tools (SendMessage, TeamDelete, TaskUpdate).
# The hook uses direct process signals (SIGTERM/SIGKILL) and filesystem cleanup (rm -rf).
# This is the same pattern used by on-session-stop.sh Phase 0.
#
# Hook event: Stop
# Timeout: 30s (accounts for grace period + escalation + filesystem cleanup)

set -euo pipefail

_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

CWD="${CLAUDE_PROJECT_DIR:-.}"
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ── GUARD 0: jq dependency (fail-open) ──
if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── Source shared libraries ──
# REC-6 FIX: resolve-session-identity.sh lives at scripts/, NOT scripts/lib/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  # shellcheck source=resolve-session-identity.sh
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  # Fallback: inline resolution
  RUNE_CURRENT_CFG=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P) || RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  rune_pid_alive() { kill -0 "$1" 2>/dev/null; }
fi

# Inline _trace (QUAL-007: each hook defines its own — no shared trace-logger.sh exists)
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && printf '[%s] detect-workflow-complete: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

_trace "ENTER detect-workflow-complete.sh"

# ── GUARD 1: Fast-path — any state files at all? ──
shopt -s nullglob
STATE_FILES=("${CWD}/tmp/"/.rune-*.json)
shopt -u nullglob

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
  _trace "FAST EXIT: no state files"
  exit 0
fi

# ── GUARD 2: Defer to arc loop hooks ──
# REC-1 FIX: Loop files live at ${CWD}/.claude/, NOT ${CHOME}/
# If any arc loop is active, this hook must NOT interfere — the loop hooks handle transitions.
for loop_file in \
  "${CWD}/.claude/arc-phase-loop.local.md" \
  "${CWD}/.claude/arc-batch-loop.local.md" \
  "${CWD}/.claude/arc-hierarchy-loop.local.md" \
  "${CWD}/.claude/arc-issues-loop.local.md"; do
  if [[ -f "$loop_file" ]]; then
    # Check staleness — only defer if loop file is <10 min old
    if [[ "$(uname)" == "Darwin" ]]; then
      age_min=$(( ($(date +%s) - $(stat -f %m "$loop_file" 2>/dev/null || echo 0)) / 60 ))
    else
      age_min=$(( ($(date +%s) - $(stat -c %Y "$loop_file" 2>/dev/null || echo 0)) / 60 ))
    fi
    if [[ $age_min -lt 10 ]]; then
      _trace "DEFER: active loop file $(basename "$loop_file") (${age_min}m old)"
      exit 0
    fi
  fi
done

# ── GUARD 3: Read talisman cleanup config ──
# REC-4 FIX: Use grep/awk instead of python3+PyYAML (simple scalar extraction)
CLEANUP_ENABLED=true
GRACE_PERIOD=10
ESCALATION_TIMEOUT=5

TALISMAN="${CWD}/talisman.yml"
if [[ -f "$TALISMAN" ]]; then
  CLEANUP_ENABLED=$(grep -A5 'cleanup:' "$TALISMAN" 2>/dev/null | grep 'enabled:' | awk '{print $2}' | head -1 || echo "true")
  GRACE_PERIOD=$(grep -A5 'cleanup:' "$TALISMAN" 2>/dev/null | grep 'grace_period_seconds:' | awk '{print $2}' | head -1 || echo "10")
  # NOTE: escalation_timeout_seconds must stay < 23s to fit within 30s hook timeout budget (GAP-DOC-4)
  ESCALATION_TIMEOUT=$(grep -A5 'cleanup:' "$TALISMAN" 2>/dev/null | grep 'escalation_timeout_seconds:' | awk '{print $2}' | head -1 || echo "5")
fi

if [[ "$CLEANUP_ENABLED" == "false" ]]; then
  _trace "SKIP: cleanup disabled via talisman"
  exit 0
fi

# ── Scan state files for completed-but-uncleaned workflows ──
for sf in "${STATE_FILES[@]}"; do
  [[ -f "$sf" ]] || continue
  [[ -L "$sf" ]] && continue  # skip symlinks

  # Session ownership check
  SF_CFG=$(jq -r '.config_dir // empty' "$sf" 2>/dev/null || true)
  SF_PID=$(jq -r '.owner_pid // empty' "$sf" 2>/dev/null || true)
  SF_STATUS=$(jq -r '.status // empty' "$sf" 2>/dev/null || true)
  SF_TEAM=$(jq -r '.team_name // empty' "$sf" 2>/dev/null || true)
  SF_STOPPED_BY=$(jq -r '.stopped_by // empty' "$sf" 2>/dev/null || true)

  # Skip if already cleaned
  [[ "$SF_STATUS" == "stopped" ]] && continue
  [[ -n "$SF_STOPPED_BY" ]] && continue

  # Session isolation: config_dir must match
  if [[ -n "$SF_CFG" && "$SF_CFG" != "$RUNE_CURRENT_CFG" ]]; then
    _trace "SKIP $sf: config_dir mismatch"
    continue
  fi

  # Session isolation: owner_pid must match OR be dead
  ORPHAN=false
  if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    if [[ "$SF_PID" != "$PPID" ]]; then
      if rune_pid_alive "$SF_PID"; then
        _trace "SKIP $sf: belongs to live session PID=$SF_PID"
        continue
      else
        ORPHAN=true
        _trace "ORPHAN detected: $sf (PID=$SF_PID dead)"
      fi
    fi
  fi

  # ── Decision: Should we clean? ──
  SHOULD_CLEAN=false

  # REC-5 FIX: Session filter for completed-status path — don't clean another live session's state
  if [[ "$SF_STATUS" =~ ^(completed|failed|cancelled)$ && -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    if [[ "$SF_PID" != "$PPID" ]] && rune_pid_alive "$SF_PID"; then
      _trace "SKIP $sf: completed state belongs to live session PID=$SF_PID"
      continue
    fi
  fi

  # Case 1: Status is completed/failed/cancelled but team dir still exists
  if [[ "$SF_STATUS" =~ ^(completed|failed|cancelled)$ ]]; then
    if [[ -n "$SF_TEAM" && -d "${CHOME}/teams/${SF_TEAM}" ]]; then
      _trace "CLEANUP NEEDED: $SF_TEAM status=$SF_STATUS but team dir exists"
      SHOULD_CLEAN=true
    else
      # Team dir already gone — prompt-driven cleanup worked. Just mark state file.
      if [[ "$SF_STATUS" != "stopped" ]]; then
        jq --arg by "CLEANUP-HOOK-VERIFIED" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '. + {stopped_by: $by, stopped_at: $ts}' "$sf" > "${sf}.tmp" 2>/dev/null \
          && mv "${sf}.tmp" "$sf" 2>/dev/null || true
      fi
      continue
    fi
  fi

  # Case 2: Orphan (PID dead, status still active)
  if [[ "$ORPHAN" == "true" && "$SF_STATUS" == "active" ]]; then
    if [[ -n "$SF_TEAM" && -d "${CHOME}/teams/${SF_TEAM}" ]]; then
      _trace "ORPHAN CLEANUP: $SF_TEAM (dead PID=$SF_PID)"
      SHOULD_CLEAN=true
    fi
  fi

  [[ "$SHOULD_CLEAN" == "true" ]] || continue

  # ── Dry-run mode (RUNE_CLEANUP_DRY_RUN=1) ──
  if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
    _trace "DRY RUN: would clean team=$SF_TEAM (status=$SF_STATUS, orphan=$ORPHAN)"
    continue
  fi

  # ── 2-Stage Escalation (hook context — no SDK access) ──
  _trace "BEGIN escalation for team=$SF_TEAM"

  # NOTE: We cannot call Claude Code SDK from a hook script. We use process signals.
  # The shutdown_request is only possible from the orchestrator context.
  # In hook context, we skip directly to process-level cleanup.

  # REC-2 FIX: Validate SF_PID is a Claude Code process before sending signals
  if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    sf_pid_cmd=$(ps -p "$SF_PID" -o comm= 2>/dev/null || true)
    if [[ ! "$sf_pid_cmd" =~ ^(node|claude)$ ]] && [[ "$ORPHAN" != "true" ]]; then
      _trace "SKIP signal escalation: SF_PID=$SF_PID is not a Claude process (cmd=$sf_pid_cmd)"
      # Still do filesystem cleanup below
      SF_PID=""
    fi
  fi

  # REC-3: On macOS, orphaned child processes are re-parented to launchd (PID 1).
  # pgrep -P $dead_pid returns nothing for re-parented children.
  # Filesystem cleanup (rm -rf) is the primary reclamation mechanism for orphans.

  # Stage 1: SIGTERM to all child processes of this session
  _trace "Stage 1: SIGTERM for team=$SF_TEAM"
  if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    # Find teammate processes that are children of the owner PID
    while IFS= read -r child_pid; do
      [[ -z "$child_pid" ]] && continue
      [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
      # Verify this is a Claude/node process (not MCP/LSP server)
      child_cmd=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
      if [[ "$child_cmd" =~ ^(node|claude) ]]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        _trace "SIGTERM sent to PID=$child_pid (cmd=$child_cmd)"
      fi
    done < <(pgrep -P "$SF_PID" 2>/dev/null || true)
  fi

  # Wait for SIGTERM to take effect
  sleep "$ESCALATION_TIMEOUT" 2>/dev/null || sleep 5

  # Stage 2: SIGKILL survivors
  _trace "Stage 2: SIGKILL survivors for team=$SF_TEAM"
  if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    while IFS= read -r child_pid; do
      [[ -z "$child_pid" ]] && continue
      [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
      # Re-verify before SIGKILL (PID recycling guard — SEC-P1-001)
      child_cmd=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
      if [[ "$child_cmd" =~ ^(node|claude) ]]; then
        kill -KILL "$child_pid" 2>/dev/null || true
        _trace "SIGKILL sent to PID=$child_pid"
      fi
    done < <(pgrep -P "$SF_PID" 2>/dev/null || true)
  fi

  # Filesystem cleanup
  _trace "Filesystem cleanup for team=$SF_TEAM"
  if [[ -n "$SF_TEAM" && "$SF_TEAM" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    rm -rf "${CHOME}/teams/${SF_TEAM}/" "${CHOME}/tasks/${SF_TEAM}/" 2>/dev/null || true
    rm -rf "${CWD}/tmp/.rune-signals/${SF_TEAM}/" 2>/dev/null || true
  fi

  # Update state file
  jq --arg by "CLEANUP-HOOK" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {status: "stopped", stopped_by: $by, stopped_at: $ts}' "$sf" > "${sf}.tmp" 2>/dev/null \
    && mv "${sf}.tmp" "$sf" 2>/dev/null || true

  _trace "DONE escalation for team=$SF_TEAM"
done

_trace "EXIT detect-workflow-complete.sh"
exit 0
