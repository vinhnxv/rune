#!/bin/bash
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

# FLAW-008 FIX: Canonicalize CWD to avoid relative path issues
CWD="${CLAUDE_PROJECT_DIR:-.}"
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD="."
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
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && [[ ! -L "${RUNE_TRACE_LOG%/*}" ]] && printf '[%s] detect-workflow-complete: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

HOOK_START_TIME=$(date +%s)
_trace "ENTER detect-workflow-complete.sh"

# ── GUARD 1: Fast-path — any state files at all? ──
readarray -t STATE_FILES < <(shopt -s nullglob || true; printf '%s\n' "${CWD}/tmp/"/.rune-*.json)
[[ ${#STATE_FILES[@]} -eq 1 && -z "${STATE_FILES[0]}" ]] && STATE_FILES=()

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
    # Check staleness — only defer if loop file is fresh enough.
    # v1.125.1 FIX: Increased from 30 min to 150 min. Phase loop files stay
    # untouched during long phases (work=35m, test+E2E=50m). Batch/hierarchy/issues
    # loop files stay untouched for entire arc runs (30-90m). Must match
    # on-session-stop.sh thresholds to avoid premature cleanup.
    if [[ "$(uname)" == "Darwin" ]]; then
      _loop_mtime=$(stat -f %m "$loop_file" 2>/dev/null || true)
    else
      _loop_mtime=$(stat -c %Y "$loop_file" 2>/dev/null || true)
    fi
    # BACK-002: validate mtime; if invalid, defer conservatively to avoid false cleanup
    if [[ -z "$_loop_mtime" || ! "$_loop_mtime" =~ ^[0-9]+$ ]]; then
      _trace "DEFER: $(basename "$loop_file") — mtime invalid, deferring conservatively"
      exit 0
    fi
    age_min=$(( ($HOOK_START_TIME - _loop_mtime) / 60 ))
    if [[ $age_min -lt 150 ]]; then
      _trace "DEFER: active loop file $(basename "$loop_file") (${age_min}m old)"
      exit 0
    fi
  fi
done

# ── GUARD 3: Read talisman cleanup config ──
# REC-4 FIX: Use grep/awk instead of python3+PyYAML (simple scalar extraction)
CLEANUP_ENABLED=true
ESCALATION_TIMEOUT=5

TALISMAN="${CWD}/talisman.yml"
if [[ -f "$TALISMAN" ]]; then
  CLEANUP_ENABLED=$(grep -A5 'cleanup:' "$TALISMAN" 2>/dev/null | grep 'enabled:' | awk '{print $2}' | head -1 || echo "true")
  # NOTE: escalation_timeout_seconds must stay < 23s to fit within 30s hook timeout budget (GAP-DOC-4)
  # BACK-005: grace_period_seconds removed — not used in hook context (SDK-based grace period unavailable)
  ESCALATION_TIMEOUT=$(grep -A5 'cleanup:' "$TALISMAN" 2>/dev/null | grep 'escalation_timeout_seconds:' | awk '{print $2}' | head -1 || echo "5")
fi

# SEC-002: Validate and clamp talisman-sourced numeric values
[[ "$ESCALATION_TIMEOUT" =~ ^[0-9]+$ ]] || ESCALATION_TIMEOUT=5
[[ "$ESCALATION_TIMEOUT" -gt 23 ]] && ESCALATION_TIMEOUT=5

if [[ "$CLEANUP_ENABLED" == "false" ]]; then
  _trace "SKIP: cleanup disabled via talisman"
  exit 0
fi

# ── Scan state files for completed-but-uncleaned workflows ──
for sf in "${STATE_FILES[@]}"; do
  [[ -f "$sf" ]] || continue
  [[ -L "$sf" ]] && continue  # skip symlinks

  # VEIL-005: Per-iteration timeout budget guard — abort if <5s remaining in 30s budget
  elapsed_total=$(( $(date +%s) - HOOK_START_TIME ))
  if [[ $elapsed_total -gt 25 ]]; then
    _trace "TIMEOUT GUARD: >${elapsed_total}s elapsed, aborting loop"
    break
  fi

  # Skip signal/control files — only process workflow state files
  case "$(basename "$sf")" in
    .rune-shutdown-signal-*|.rune-force-shutdown-*|.rune-compact-*) continue ;;
  esac

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
  if [[ "$SF_STATUS" =~ ^(completed|failed|cancelled)$ ]]; then
    if [[ -z "$SF_PID" ]]; then
      _trace "TRACE $sf: completed state has no owner_pid attribute, skipping cleanup for unattributable state"
      continue
    fi
    if [[ "$SF_PID" =~ ^[0-9]+$ ]]; then
      if [[ "$SF_PID" != "$PPID" ]] && rune_pid_alive "$SF_PID"; then
        _trace "SKIP $sf: completed state belongs to live session PID=$SF_PID"
        continue
      fi
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

  # BACK-004: Clear SF_PID for orphans — signal escalation is ineffective (dead PID has no
  # live children via pgrep -P). For orphans, filesystem cleanup is the only reclamation
  # mechanism on macOS (re-parented processes owned by launchd). Skip signal stages.
  if [[ "$ORPHAN" == "true" ]]; then
    SF_PID=""
  fi

  # REC-2 FIX: Validate SF_PID is a Claude Code process before sending signals
  if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    sf_pid_cmd=$(ps -p "$SF_PID" -o comm= 2>/dev/null || true)
    if [[ ! "$sf_pid_cmd" =~ ^(node|claude)$ ]]; then
      _trace "SKIP signal escalation: SF_PID=$SF_PID is not a Claude process (cmd=$sf_pid_cmd)"
      # Still do filesystem cleanup below
      SF_PID=""
    fi
  fi

  # VEIL-008: Signal escalation (SIGTERM/SIGKILL via pgrep -P) is effective ONLY for Case 1
  # (completed workflow with alive owner PID). For Case 2 (orphan, dead owner PID), the owner
  # process has already exited; its children are re-parented to launchd (PID 1) on macOS.
  # pgrep -P <dead_pid> returns nothing — signals are a no-op for orphans.
  # Filesystem cleanup (rm -rf teams/ tasks/) is the sole reclamation mechanism for orphans.

  # REC-3: On macOS, orphaned child processes are re-parented to launchd (PID 1).
  # pgrep -P $dead_pid returns nothing for re-parented children.
  # Filesystem cleanup (rm -rf) is the primary reclamation mechanism for orphans.

  # Stage 1: SIGTERM to all child processes of this session
  # SEC-003: Collect PIDs into array for reuse in Stage 2 — avoids re-querying pgrep
  # (PID recycling window between Stage 1 and Stage 2 is already guarded by comm= re-verify)
  # VEIL-004: Single-pass SIGTERM→SIGKILL escalation within 30s timeout budget

  _trace "Stage 1: SIGTERM for team=$SF_TEAM"
  sigterm_pids=()
  if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    # Find teammate processes that are children of the owner PID
    while IFS= read -r child_pid; do
      [[ -z "$child_pid" ]] && continue
      [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
      # Verify this is a Claude/node process (not MCP/LSP server)
      child_cmd=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
      case "$child_cmd" in
        node|claude|claude-*)
          kill -TERM "$child_pid" 2>/dev/null || true
          sigterm_pids+=("$child_pid")
          _trace "SIGTERM sent to PID=$child_pid (cmd=$child_cmd)"
          ;;
      esac
    done < <(pgrep -P "$SF_PID" 2>/dev/null || true)
  fi

  # Wait for SIGTERM to take effect
  sleep "$ESCALATION_TIMEOUT" 2>/dev/null || sleep 5

  # Stage 2: SIGKILL survivors — reuse Stage 1 PID list (SEC-003)
  _trace "Stage 2: SIGKILL survivors for team=$SF_TEAM"
  for child_pid in "${sigterm_pids[@]}"; do
    [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
    # Re-verify before SIGKILL (PID recycling guard — SEC-P1-001)
    child_cmd=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
    case "$child_cmd" in
      node|claude|claude-*)
        kill -KILL "$child_pid" 2>/dev/null || true
        _trace "SIGKILL sent to PID=$child_pid"
        ;;
    esac
  done

  # Filesystem cleanup
  _trace "Filesystem cleanup for team=$SF_TEAM"
  if [[ -n "$SF_TEAM" && "$SF_TEAM" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    rm -rf "${CHOME}/teams/${SF_TEAM}/" "${CHOME}/tasks/${SF_TEAM}/" 2>/dev/null || true
    rm -rf "${CWD}/tmp/.rune-signals/${SF_TEAM}/" 2>/dev/null || true
  fi

  # Update state file — SEC-004: use mktemp to avoid predictable temp file path
  _sf_tmp=$(mktemp "${sf}.XXXXXX" 2>/dev/null) || _sf_tmp="${sf}.tmp"
  jq --arg by "CLEANUP-HOOK" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {status: "stopped", stopped_by: $by, stopped_at: $ts}' "$sf" > "$_sf_tmp" 2>/dev/null \
    && mv "$_sf_tmp" "$sf" 2>/dev/null || { rm -f "$_sf_tmp" 2>/dev/null; true; }

  _trace "DONE escalation for team=$SF_TEAM"
done

# ── Stale artifact crash detection (non-blocking, advisory) ──
# Scan runs/ directories for artifacts stuck in "running" status with stale timestamps.
# Updates their meta.json to "crashed" so /rune:runs can report them accurately.
STALE_ARTIFACT_THRESHOLD=1800  # 30 minutes

_artifact_now=$(date -u +%s 2>/dev/null || echo 0)
if [[ "$_artifact_now" =~ ^[0-9]+$ && "$_artifact_now" -gt 0 ]]; then
  # Use find to locate all meta.json files in runs/ subdirectories
  # Pattern: tmp/{workflow}/{timestamp}/runs/{agent}/meta.json
  while IFS= read -r meta_file; do
    [[ -f "$meta_file" ]] || continue
    [[ -L "$meta_file" ]] && continue  # skip symlinks

    # Per-iteration timeout guard
    _art_elapsed=$(( $(date +%s) - HOOK_START_TIME ))
    if [[ $_art_elapsed -gt 28 ]]; then
      _trace "ARTIFACT SCAN TIMEOUT: >${_art_elapsed}s elapsed, aborting"
      break
    fi

    _art_status=$(jq -r '.status // empty' "$meta_file" 2>/dev/null || true)
    [[ "$_art_status" == "running" ]] || continue

    # Session isolation: config_dir must match
    _art_cfg=$(jq -r '.config_dir // empty' "$meta_file" 2>/dev/null || true)
    if [[ -n "$_art_cfg" && "$_art_cfg" != "$RUNE_CURRENT_CFG" ]]; then
      continue
    fi

    # Check staleness: started_at > threshold ago
    _art_started=$(jq -r '.started_at // empty' "$meta_file" 2>/dev/null || true)
    if [[ -z "$_art_started" ]]; then
      continue
    fi

    # Parse started_at timestamp (macOS + GNU date compat)
    _art_start_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%SZ" "$_art_started" +%s 2>/dev/null || \
                       date -d "$_art_started" +%s 2>/dev/null || echo "0")
    if [[ ! "$_art_start_epoch" =~ ^[0-9]+$ || "$_art_start_epoch" -eq 0 ]]; then
      continue
    fi

    _art_age=$(( _artifact_now - _art_start_epoch ))
    if [[ $_art_age -lt $STALE_ARTIFACT_THRESHOLD ]]; then
      continue
    fi

    # Stale artifact detected — update status to "crashed"
    _art_agent=$(jq -r '.agent_name // "unknown"' "$meta_file" 2>/dev/null || echo "unknown")
    _trace "STALE ARTIFACT: ${_art_agent} (age=${_art_age}s) — marking as crashed: $meta_file"

    if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" != "1" ]]; then
      _art_tmp=$(mktemp "${meta_file}.XXXXXX" 2>/dev/null) || _art_tmp="${meta_file}.tmp"
      jq --arg tstat "crashed" --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson dur "$_art_age" \
        '.status = $tstat | .completed_at = $completed | .duration_seconds = $dur' \
        "$meta_file" > "$_art_tmp" 2>/dev/null \
        && mv -f "$_art_tmp" "$meta_file" 2>/dev/null || { rm -f "$_art_tmp" 2>/dev/null; true; }
    fi
  done < <(find "${CWD}/tmp" -path '*/runs/*/meta.json' -type f 2>/dev/null || true)
fi

_trace "EXIT detect-workflow-complete.sh"
exit 0
