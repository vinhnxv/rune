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
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below

# RUIN-003 FIX: Capture hook start time for adaptive timeout budget tracking
_HOOK_START_EPOCH=$(date +%s)

_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    # SEC-004 FIX: Use per-session mktemp trace log to avoid predictable path symlink attacks
    local _ffl="${RUNE_TRACE_LOG:-}"
    if [[ -n "$_ffl" && ! -L "$_ffl" && ! -L "${_ffl%/*}" ]]; then
      printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
        "$(date +%H:%M:%S 2>/dev/null || true)" \
        "${BASH_SOURCE[0]##*/}" \
        "${BASH_LINENO[0]:-?}" \
        >> "$_ffl" 2>/dev/null
    fi
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ── GUARD 0: Auto-cleanup toggle (MCP-PROTECT-003) ──
# Auto-cleanup is ENABLED by default. Uses positive teammate PID whitelist (MCP-PROTECT-003).
# Set RUNE_DISABLE_AUTO_CLEANUP=1 to disable, or talisman process_management.auto_cleanup: false.
if [[ "${RUNE_DISABLE_AUTO_CLEANUP:-0}" == "1" ]]; then
  exit 0
fi

# ── GUARD 0.5: jq dependency (fail-open) ──
if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── GUARD 0.6: Talisman auto_cleanup config (AC-5) ──
if [[ -z "${RUNE_DISABLE_AUTO_CLEANUP:-}" ]]; then
  _talisman_shard="${CLAUDE_PROJECT_DIR:-.}/tmp/.talisman-resolved/misc.json"
  if [[ -f "$_talisman_shard" && ! -L "$_talisman_shard" ]]; then
    _auto_cleanup=$(jq -r '.process_management.auto_cleanup // empty' "$_talisman_shard" 2>/dev/null || true)
    if [[ "$_auto_cleanup" == "false" ]]; then
      exit 0
    fi
  fi
fi

# ── GUARD 1: Read CWD from stdin (consistent with other Stop hooks) ──
# Stop hooks receive JSON input with .cwd field (same as PreToolUse/PostToolUse).
# Fallback to CLAUDE_PROJECT_DIR for backwards compatibility.
INPUT=$(head -c 1048576 2>/dev/null || true)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-.}"
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD="."
# XVER-002: Absolute-path guard (consistent with on-session-stop.sh and session-team-hygiene.sh)
[[ -z "$CWD" || "$CWD" != /* ]] && exit 0

# ── Source shared libraries ──
# REC-6 FIX: resolve-session-identity.sh lives at scripts/, NOT scripts/lib/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  # shellcheck source=resolve-session-identity.sh
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  # Fallback: inline resolution
  RUNE_CURRENT_CFG=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P) || RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  rune_pid_alive() {
    # BUG FIX: Single kill -0 call captures both exit code and stderr.
    # Previous version called kill -0 twice (TOCTOU: process could die between calls).
    # Matches on-session-stop.sh single-call pattern.
    local _err _rc
    _err=$(kill -0 "$1" 2>&1); _rc=$?
    [[ $_rc -eq 0 ]] && return 0
    # EPERM means process exists but we lack permission — treat as alive
    # TOME-019 FIX: Use case pattern instead of grep -qi "perm" for locale safety
    case "$_err" in *ermission*|*[Pp]erm*|*EPERM*) return 0 ;; esac
    return 1
  }
fi

# Source platform helpers for cross-platform stat
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh
  source "${SCRIPT_DIR}/lib/platform.sh"
fi
source "${SCRIPT_DIR}/lib/rune-state.sh"

# Source process tree kill library for 2-stage SIGTERM→SIGKILL escalation
if [[ -f "${SCRIPT_DIR}/lib/process-tree.sh" ]]; then
  # shellcheck source=lib/process-tree.sh
  source "${SCRIPT_DIR}/lib/process-tree.sh"
fi

# Source frontmatter utils for loop file ownership checks
if [[ -f "${SCRIPT_DIR}/lib/frontmatter-utils.sh" ]]; then
  # shellcheck source=lib/frontmatter-utils.sh
  source "${SCRIPT_DIR}/lib/frontmatter-utils.sh"
else
  # Fallback: inline _get_fm_field
  _get_fm_field() {
    local fm="$1" field="$2"
    # XSEC-002 FIX: Sync with canonical lib/frontmatter-utils.sh regex (SEC-002)
    [[ "$field" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    printf '%s\n' "$fm" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true
  }
fi

# Inline _trace (QUAL-007: each hook defines its own — no shared trace-logger.sh exists)
# SEC-004 FIX: Use O_NOFOLLOW-equivalent guard — reject symlinked log paths
# SEC-003 NOTE: RUNE_TRACE=1 logs team names, file paths, and state file contents.
# Trace logs go to $RUNE_TRACE_LOG (default /tmp/, mode 600 via umask 077).
# Do NOT enable RUNE_TRACE in shared environments without reviewing log contents.
# SEC-005 FIX: Include session PID in trace log path to avoid predictable path
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
# T7 / SEC-001+SEC-009 FIX: TMPDIR allowlist — reject attacker-supplied trace paths
# outside TMPDIR or /tmp. Without this, RUNE_TRACE_LOG=/var/spool/cron/crontabs/user
# combined with RUNE_TRACE=1 would write hook trace content to arbitrary paths.
# Pattern matches the canonical mitigation in session-team-hygiene.sh:71-74.
case "$RUNE_TRACE_LOG" in
  "${TMPDIR:-/tmp}/"*|/tmp/*) ;;
  *) RUNE_TRACE_LOG="${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log" ;;
esac
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && [[ ! -L "${RUNE_TRACE_LOG%/*}" ]] && printf '[%s] detect-workflow-complete: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

HOOK_START_TIME=$(date +%s)
_trace "ENTER detect-workflow-complete.sh"

# Extract session_id from hook input ONCE — used by GUARD 2 and GUARD 2.5 session_id checks.
# CLAUDE.md rule #11: $PPID is unreliable in hooks (hook runner subprocess differs from skill PPID).
# Prefer session_id for ownership decisions when available.
_hook_sid=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

# ── GUARD 1: Fast-path — any state files at all? ──
# Bash 3.2 compatible (no readarray): collect state files via loop
STATE_FILES=()
_saved_nullglob=$(shopt -p nullglob 2>/dev/null || true)
shopt -s nullglob 2>/dev/null || true
for _sf in "${CWD}/tmp"/.rune-*.json; do
  STATE_FILES+=("$_sf")
done
# CLD-SEC-001: Restore nullglob without eval (safe pattern, avoids eval precedent)
if [[ "$_saved_nullglob" == *"-s nullglob"* ]]; then
  shopt -s nullglob 2>/dev/null || true
else
  shopt -u nullglob 2>/dev/null || true
fi

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
  _trace "FAST EXIT: no state files"
  exit 0
fi

# ── GUARD 2: Defer to arc loop hooks — NOW session-scoped ──
# REC-1 FIX: Loop files live at ${CWD}/${RUNE_STATE}/ (.rune/), NOT ${CHOME}/
# If OUR session's arc loop is active, this hook must NOT interfere — the loop hooks handle transitions.
# Other sessions' loop files are skipped so their cleanup hooks can run independently.
for loop_file in \
  "${CWD}/${RUNE_STATE}/arc-phase-loop.local.md" \
  "${CWD}/${RUNE_STATE}/arc-batch-loop.local.md" \
  "${CWD}/${RUNE_STATE}/arc-hierarchy-loop.local.md" \
  "${CWD}/${RUNE_STATE}/arc-issues-loop.local.md"; do
  if [[ -f "$loop_file" ]] && [[ ! -L "$loop_file" ]]; then
    # Session ownership check: only defer for OUR loop files
    _loop_fm=$(sed -n '/^---$/,/^---$/p' "$loop_file" 2>/dev/null | sed '1d;$d')
    _loop_cfg=$(_get_fm_field "$_loop_fm" "config_dir")
    _loop_pid=$(_get_fm_field "$_loop_fm" "owner_pid")
    _loop_sid=$(_get_fm_field "$_loop_fm" "session_id")
    # Prefer session_id for ownership (PPID unreliable in hooks per CLAUDE.md rule #11)
    if [[ -n "$_loop_sid" && -n "$_hook_sid" && "$_loop_sid" == "$_hook_sid" ]]; then
      # Same session — defer to arc loop hooks
      _loop_mtime=$(_stat_mtime "$loop_file"); _loop_mtime="${_loop_mtime:-0}"
      if [[ -n "$_loop_mtime" && "$_loop_mtime" =~ ^[0-9]+$ ]]; then
        age_min=$(( (HOOK_START_TIME - _loop_mtime) / 60 ))
        [[ $age_min -lt 0 ]] && age_min=0
        if [[ $age_min -lt 150 ]]; then
          _trace "DEFER: OUR active loop file $(basename "$loop_file") via session_id match (${age_min}m old)"
          exit 0
        fi
      else
        _trace "DEFER: loop file $(basename "$loop_file") — mtime invalid, deferring conservatively"
        exit 0
      fi
    fi

    # Skip loop files from different installations
    if [[ -n "$_loop_cfg" && "$_loop_cfg" != "$RUNE_CURRENT_CFG" ]]; then
      _trace "SKIP loop file $(basename "$loop_file"): config_dir mismatch"
      continue
    fi
    # Fallback: PPID-based ownership check for loop files without session_id
    if [[ -n "$_loop_pid" && "$_loop_pid" =~ ^[0-9]+$ && "$_loop_pid" != "$PPID" ]]; then
      if rune_pid_alive "$_loop_pid"; then
        _trace "SKIP loop file $(basename "$loop_file"): belongs to live session PID=$_loop_pid"
        continue
      fi
      # Owner dead → orphaned loop file, don't defer — let cleanup proceed
      _trace "ORPHAN loop file $(basename "$loop_file"): owner PID=$_loop_pid dead"
      continue
    fi

    # No ownership fields → legacy loop file — fall through to freshness check (backward compat)
    # OUR loop file — check freshness and defer
    # v1.125.1 FIX: Increased from 30 min to 150 min. Phase loop files stay
    # untouched during long phases (work=35m, test+E2E=50m). Batch/hierarchy/issues
    # loop files stay untouched for entire arc runs (30-90m). Must match
    # on-session-stop.sh thresholds to avoid premature cleanup.
    _loop_mtime=$(_stat_mtime "$loop_file"); _loop_mtime="${_loop_mtime:-}"
    # BACK-002: validate mtime; if invalid, defer conservatively to avoid false cleanup.
    # DEEP-103: Conservative DEFER is intentional — if _stat_mtime fails consistently
    # (e.g., macOS stat variant issue via lib/platform.sh), we prefer deferring all loop
    # files over risking premature cleanup of an active arc. Trace logging below captures
    # the raw return value to aid platform debugging (RUNE_TRACE=1).
    # M-10 FIX: Use exit 0 (not continue) for legacy loop files — conservatively defer
    # the entire hook rather than just skipping the one file. A legacy loop file with
    # unreadable mtime could be an active arc from an older Rune version.
    if [[ -z "$_loop_mtime" || ! "$_loop_mtime" =~ ^[0-9]+$ ]]; then
      _trace "DEFER: $(basename "$loop_file") — mtime invalid (raw='${_loop_mtime:-<empty>}'), deferring hook. If recurring, check _stat_mtime platform compat in lib/platform.sh"
      exit 0
    fi
    age_min=$(( ($HOOK_START_TIME - _loop_mtime) / 60 ))
    # EDGE-002 FIX: Guard against clock skew producing negative age
    [[ $age_min -lt 0 ]] && age_min=0
    if [[ $age_min -lt 150 ]]; then
      _trace "DEFER: OUR active loop file $(basename "$loop_file") (${age_min}m old)"
      exit 0
    fi
  fi
done

# ── GUARD 2.5: Active arc checkpoint freshness check (AC-6) ──
# If any arc checkpoint was written in the last 60 seconds, defer cleanup —
# a phase transition is likely in progress. This covers the gap between
# phase completion and next phase re-injection by arc-phase-stop-hook.sh.
if [[ -d "${CWD}/${RUNE_STATE}/arc" ]]; then
  for _ckpt_dir in "${CWD}/${RUNE_STATE}/arc"/*/; do
    [[ -d "$_ckpt_dir" ]] || continue
    _ckpt_file="${_ckpt_dir}checkpoint.json"
    [[ -f "$_ckpt_file" && ! -L "$_ckpt_file" ]] || continue
    # RUIN-003 FIX: Session-scope checkpoint freshness check — only defer for OUR checkpoints
    _ckpt_cfg=$(jq -r '.config_dir // empty' "$_ckpt_file" 2>/dev/null || true)
    if [[ -n "$_ckpt_cfg" && "$_ckpt_cfg" != "$RUNE_CURRENT_CFG" ]]; then
      continue  # Different installation — not our checkpoint
    fi
    _ckpt_pid=$(jq -r '.owner_pid // empty' "$_ckpt_file" 2>/dev/null || true)
    _ckpt_sid=$(jq -r '.session_id // empty' "$_ckpt_file" 2>/dev/null || true)
    # Prefer session_id for ownership (PPID unreliable in hooks per CLAUDE.md rule #11)
    if [[ -n "$_ckpt_sid" && -n "$_hook_sid" && "$_ckpt_sid" == "$_hook_sid" ]]; then
      # Our checkpoint — check freshness
      _ckpt_mtime=$(_stat_mtime "$_ckpt_file"); _ckpt_mtime="${_ckpt_mtime:-0}"
      if [[ "$_ckpt_mtime" =~ ^[0-9]+$ ]]; then
        _ckpt_age=$(( HOOK_START_TIME - _ckpt_mtime ))
        if [[ "$_ckpt_age" -ge 0 && "$_ckpt_age" -lt 60 ]]; then
          _trace "GUARD 2.5: DEFER — fresh checkpoint via session_id match (${_ckpt_age}s)"
          exit 0
        fi
      fi
    fi
    # Fallback: PPID-based ownership check for checkpoints without session_id
    if [[ -n "$_ckpt_pid" && "$_ckpt_pid" =~ ^[0-9]+$ && "$_ckpt_pid" != "$PPID" ]]; then
      if rune_pid_alive "$_ckpt_pid"; then
        continue  # Belongs to another live session
      fi
    fi
    _ckpt_mtime=$(_stat_mtime "$_ckpt_file")
    if [[ -n "$_ckpt_mtime" && "$_ckpt_mtime" =~ ^[0-9]+$ ]]; then
      _ckpt_age=$(( HOOK_START_TIME - _ckpt_mtime ))
      [[ $_ckpt_age -lt 0 ]] && _ckpt_age=0  # clock skew guard
      if [[ $_ckpt_age -lt 60 ]]; then
        _trace "DEFER: arc checkpoint fresh (${_ckpt_age}s) — phase transition likely"
        exit 0
      fi
    fi
  done
fi

# ── GUARD 3: Read talisman cleanup config ──
# REC-4 FIX: Use grep/awk instead of python3+PyYAML (simple scalar extraction)
CLEANUP_ENABLED=true
ESCALATION_TIMEOUT=5

TALISMAN="${CWD}/${RUNE_STATE}/talisman.yml"
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
  # H-7 FIX: Use _HOOK_START_EPOCH (captured before guards) not HOOK_START_TIME (same value here
  # but _HOOK_START_EPOCH is the canonical "true start" variable; keeps usage consistent)
  elapsed_total=$(( $(date +%s) - _HOOK_START_EPOCH ))
  if [[ $elapsed_total -gt 25 ]]; then
    _trace "TIMEOUT GUARD: >${elapsed_total}s elapsed, aborting loop"
    break
  fi

  # Skip signal/control files — only process workflow state files
  case "$(basename "$sf")" in
    .rune-shutdown-signal-*|.rune-force-shutdown-*|.rune-compact-*) continue ;;
  esac

  # OBSV-003 FIX: Validate JSON before field extraction — warn on corruption instead of silent skip
  if ! jq empty "$sf" 2>/dev/null; then
    echo "WARN: Corrupted state file (invalid JSON): $sf — skipping" >&2
    _trace "CORRUPT state file: $sf"
    continue
  fi

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
  # BACK-2 FIX: Use ORPHAN flag from first check (lines 211-222) instead of re-calling rune_pid_alive.
  # Re-checking PID liveness creates a TOCTOU window: if PID is recycled between checks,
  # first check sets ORPHAN=true but second check sees the recycled PID as alive and skips cleanup.
  if [[ "$SF_STATUS" =~ ^(completed|failed|cancelled)$ ]]; then
    # TOME-024 FIX: Pre-isolation state files (no owner_pid) with terminal status
    # are safe to clean — they can never be claimed by any session.
    if [[ -z "$SF_PID" ]]; then
      _trace "TRACE $sf: completed state has no owner_pid attribute — treating as safe to clean (pre-isolation)"
      # Fall through to cleanup decision below
    elif [[ "$SF_PID" =~ ^[0-9]+$ && "$SF_PID" != "$PPID" && "$ORPHAN" != "true" ]]; then
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
        # CDX-007 FIX: Use mktemp for unique temp file to avoid concurrent hook race
        _sf_tmp=$(mktemp "${sf}.XXXXXX" 2>/dev/null) || continue
        jq --arg by "CLEANUP-HOOK-VERIFIED" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '. + {stopped_by: $by, stopped_at: $ts}' "$sf" > "$_sf_tmp" 2>/dev/null \
          && mv "$_sf_tmp" "$sf" 2>/dev/null || rm -f "$_sf_tmp" 2>/dev/null
      fi
      continue
    fi
  fi

  # Case 2: Orphan (PID dead, status not terminal)
  # BACK-6 FIX: Match any non-terminal status, not just "active". Non-standard status
  # values (e.g., custom states) would otherwise create permanent orphans.
  if [[ "$ORPHAN" == "true" && ! "$SF_STATUS" =~ ^(completed|failed|cancelled|stopped)$ ]]; then
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

  # Process escalation: 2-stage SIGTERM→SIGKILL via centralized process-tree.sh
  # SEC-003: PID recycling guarded by lstart comparison (XVER-001)
  # VEIL-004: Single-pass escalation within 30s timeout budget
  # MCP-PROTECT-003: "teammates" filter uses positive PID whitelist when available
  _RUNE_PT_CWD="${CWD:-$PWD}"

  # RUIN-003 FIX: Adaptive timeout — skip or reduce grace when hook budget is nearly exhausted.
  _elapsed_s=$(( $(date +%s) - ${_HOOK_START_EPOCH:-$(date +%s)} ))
  _budget_remaining=$(( 30 - _elapsed_s - 2 ))  # 2s safety margin for cleanup
  if [[ "$_budget_remaining" -gt 0 ]]; then
    _esc_grace=$(( ESCALATION_TIMEOUT < _budget_remaining ? ESCALATION_TIMEOUT : _budget_remaining ))
  else
    _esc_grace=0
    _trace "SKIP escalation: budget exhausted (elapsed=${_elapsed_s}s)"
  fi

  if [[ "$_esc_grace" -gt 0 && -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]]; then
    _trace "Process escalation: team=$SF_TEAM pid=$SF_PID grace=${_esc_grace}s"
    if declare -f _rune_kill_tree &>/dev/null; then
      _rune_kill_tree "$SF_PID" "2stage" "$_esc_grace" "teammates" "$SF_TEAM" >/dev/null
    else
      _trace "WARN: process-tree.sh not loaded — skipping process escalation"
    fi
  fi

  # Filesystem cleanup
  _trace "Filesystem cleanup for team=$SF_TEAM"
  if [[ -n "$SF_TEAM" && "$SF_TEAM" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    # SEC-002: Atomic symlink-safe delete (eliminates TOCTOU window)
    find "${CHOME}/teams/${SF_TEAM}" -maxdepth 0 -not -type l -exec rm -rf {} + 2>/dev/null
    find "${CHOME}/tasks/${SF_TEAM}" -maxdepth 0 -not -type l -exec rm -rf {} + 2>/dev/null
    find "${CWD}/tmp/.rune-signals/${SF_TEAM}" -maxdepth 0 -not -type l -exec rm -rf {} + 2>/dev/null
  fi

  # Update state file — SEC-004: use mktemp to avoid predictable temp file path
  # TOME-008 FIX: Remove predictable fallback — skip state update on mktemp failure
  _sf_tmp=$(mktemp "${sf}.XXXXXX" 2>/dev/null) || { _trace "mktemp failed for $sf"; continue; }
  jq --arg by "CLEANUP-HOOK" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {status: "stopped", stopped_by: $by, stopped_at: $ts}' "$sf" > "$_sf_tmp" 2>/dev/null \
    && mv "$_sf_tmp" "$sf" 2>/dev/null || { rm -f "$_sf_tmp" 2>/dev/null; true; }

  _trace "DONE escalation for team=$SF_TEAM"
done

# ── Stale artifact crash detection (non-blocking, advisory) ──
# Scan runs/ directories for artifacts stuck in "running" status with stale timestamps.
# Updates their meta.json to "crashed" so /rune:runs can report them accurately.
# QUAL-009 FIX: Named constant with cross-reference to loop stale threshold (150min on line 99)
# These thresholds serve different purposes: artifact staleness (30min running with no update)
# vs loop file staleness (150min to accommodate long arc phases). Keep independent but documented.
STALE_ARTIFACT_THRESHOLD_SECS=1800  # 30 minutes — max expected single-agent run duration

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

    # Parse started_at timestamp (cross-platform via lib/platform.sh)
    _art_start_epoch=$(_parse_iso_epoch "$_art_started")
    if [[ ! "$_art_start_epoch" =~ ^[0-9]+$ || "$_art_start_epoch" -eq 0 ]]; then
      continue
    fi

    _art_age=$(( _artifact_now - _art_start_epoch ))
    # EDGE-001 FIX: Guard against clock skew producing negative age
    [[ $_art_age -lt 0 ]] && _art_age=0
    if [[ $_art_age -lt $STALE_ARTIFACT_THRESHOLD_SECS ]]; then
      continue
    fi

    # Stale artifact detected — update status to "crashed"
    _art_agent=$(jq -r '.agent_name // "unknown"' "$meta_file" 2>/dev/null || echo "unknown")
    _trace "STALE ARTIFACT: ${_art_agent} (age=${_art_age}s) — marking as crashed: $meta_file"

    if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" != "1" ]]; then
      _art_tmp=$(mktemp "${meta_file}.XXXXXX" 2>/dev/null) || continue
      jq --arg tstat "crashed" --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson dur "$_art_age" \
        '.status = $tstat | .completed_at = $completed | .duration_seconds = $dur' \
        "$meta_file" > "$_art_tmp" 2>/dev/null \
        && mv -f "$_art_tmp" "$meta_file" 2>/dev/null || { rm -f "$_art_tmp" 2>/dev/null; true; }
    fi
  # BACK-004 FIX: Bound find depth to prevent latency on large trees
  # Pattern: tmp/{workflow}/{timestamp}/runs/{agent}/meta.json = 5 levels deep
  # EDGE-020 NOTE: maxdepth 6 is intentional — matches the exact nesting depth of the
  # runs/*/meta.json pattern (tmp/workflow/timestamp/runs/agent/meta.json). Deeper nesting
  # would indicate a non-standard layout and should not be auto-discovered here.
  done < <(find "${CWD}/tmp" -maxdepth 6 -path '*/runs/*/meta.json' -type f 2>/dev/null || true)
fi

_trace "EXIT detect-workflow-complete.sh"
exit 0
