#!/bin/bash
# detect-stale-lead.sh — Stop hook: wake idle team lead when all teammates completed
# OPERATIONAL hook — fail-forward (ADR-002)
# Fires on every Stop event. Fast-path exit when no active workflows.
#
# Purpose: Detects when all teammates have completed but the team lead is idle.
# Uses 4-method detection cascade:
#   Method A: .all-done sentinel exists in signal dir
#   Method B: Count .done files >= .expected count
#   Method C: All task files in $CHOME/tasks/$TEAM/ have status completed|deleted
#   Method D: Liveness check — no teammate processes + tasks in_progress → CRASHED
#
# Two wake modes:
#   COMPLETE: All tasks done — normal continuation
#   CRASHED:  No processes but tasks in_progress — teammates may have crashed
#
# Hook event: Stop
# Timeout: 10s (filesystem-only operations, no process escalation)
# Position 5 in Stop array: after arc loops, before detect-workflow-complete.sh
#
# STALE-LEAD-001

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077  # PAT-003 FIX

# OPERATIONAL: Capture hook start time for timeout budget tracking
_HOOK_START_EPOCH=$(date +%s)

_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
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

# ── GUARD 0: jq dependency (fail-open) ──
if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── GUARD 1: Read CWD from stdin ──
INPUT=$(head -c 1048576 2>/dev/null || true)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && CWD="${CLAUDE_PROJECT_DIR:-.}"
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD="."
[[ -z "$CWD" || "$CWD" != /* ]] && exit 0

# ── Source shared libraries ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  # shellcheck source=resolve-session-identity.sh
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  RUNE_CURRENT_CFG=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P) || RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  rune_pid_alive() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    local _err
    _err=$(kill -0 "$1" 2>&1) && return 0
    case "$_err" in *ermission*|*[Pp]erm*|*EPERM*) return 0 ;; esac
    return 1
  }
fi

if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  # shellcheck source=lib/platform.sh
  source "${SCRIPT_DIR}/lib/platform.sh"
fi
source "${SCRIPT_DIR}/lib/rune-state.sh"
if [[ -f "${SCRIPT_DIR}/lib/frontmatter-utils.sh" ]]; then
  source "${SCRIPT_DIR}/lib/frontmatter-utils.sh"
else
  _get_fm_field() {
    local fm="$1" field="$2"
    [[ "$field" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    printf '%s\n' "$fm" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true
  }
fi

# Inline _trace (QUAL-007)
RUNE_TRACE_LOG="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
_trace() { [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "$RUNE_TRACE_LOG" ]] && [[ ! -L "${RUNE_TRACE_LOG%/*}" ]] && printf '[%s] detect-stale-lead: %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUNE_TRACE_LOG"; return 0; }

_trace "ENTER detect-stale-lead.sh"

# Initialize variables that may be set conditionally inside loops
_session_id=""

# ── GUARD 2: Fast-path — any state files at all? ──
STATE_FILES=()
while IFS= read -r _sf; do
  [[ -n "$_sf" ]] && STATE_FILES+=("$_sf")
done < <(find "${CWD}/tmp" -maxdepth 1 -name '.rune-*.json' -type f 2>/dev/null || true)

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
  _trace "FAST EXIT: no state files"
  exit 0
fi

# ── GUARD 3: Defer to active arc phase loop ──
# If OUR session's arc loop is active AND status is not completed, arc-phase-stop-hook
# handles wake-up — we should not interfere.
for loop_file in \
  "${CWD}/${RUNE_STATE}/arc-phase-loop.local.md" \
  "${CWD}/${RUNE_STATE}/arc-batch-loop.local.md" \
  "${CWD}/${RUNE_STATE}/arc-hierarchy-loop.local.md" \
  "${CWD}/${RUNE_STATE}/arc-issues-loop.local.md"; do
  if [[ -f "$loop_file" ]] && [[ ! -L "$loop_file" ]]; then
    _loop_fm=$(sed -n '/^---$/,/^---$/p' "$loop_file" 2>/dev/null | sed '1d;$d')
    _loop_cfg=$(printf '%s\n' "$_loop_fm" | grep "^config_dir:" | sed "s/^config_dir:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true)
    _loop_pid=$(printf '%s\n' "$_loop_fm" | grep "^owner_pid:" | sed "s/^owner_pid:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true)
    _loop_status=$(printf '%s\n' "$_loop_fm" | grep "^status:" | sed "s/^status:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true)

    # Skip loop files from different installations
    if [[ -n "$_loop_cfg" && "$_loop_cfg" != "$RUNE_CURRENT_CFG" ]]; then
      continue
    fi
    # FLAW-005 FIX: Use session_id for ownership check (PPID unreliable in hooks)
    _session_id=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""
    _loop_sid=$(_get_fm_field "$_loop_fm" "session_id" 2>/dev/null) || _loop_sid=""
    # Skip loop files from other live sessions (prefer session_id, fall back to PID)
    if [[ -n "$_loop_sid" && -n "$_session_id" && "$_loop_sid" != "$_session_id" ]]; then
      if [[ -n "$_loop_pid" && "$_loop_pid" =~ ^[0-9]+$ ]] && rune_pid_alive "$_loop_pid"; then
        continue
      fi
    elif [[ -n "$_loop_pid" && "$_loop_pid" =~ ^[0-9]+$ && "$_loop_pid" != "$PPID" ]]; then
      if rune_pid_alive "$_loop_pid"; then
        continue
      fi
      # Owner dead → orphaned loop file, don't defer
      continue
    fi

    # OUR loop file — check status field
    # If status is NOT "completed", arc is still active — defer
    if [[ -n "$_loop_status" && "$_loop_status" != "completed" ]]; then
      # Freshness check: also defer if recent (<150 min)
      _loop_mtime=$(_stat_mtime "$loop_file"); _loop_mtime="${_loop_mtime:-}"
      if [[ -n "$_loop_mtime" && "$_loop_mtime" =~ ^[0-9]+$ ]]; then
        _age_min=$(( ($(date +%s) - _loop_mtime) / 60 ))
        [[ $_age_min -lt 0 ]] && _age_min=0
        if [[ $_age_min -lt 150 ]]; then
          _trace "DEFER: active arc loop $(basename "$loop_file") status=${_loop_status} (${_age_min}m old)"
          exit 0
        fi
      else
        # BACK-007 FIX: Use exit 0 (defer entire hook) not continue — matches detect-workflow-complete.sh
        _trace "DEFER: arc loop $(basename "$loop_file") — mtime invalid, deferring hook"
        exit 0
      fi
    fi
    # status == "completed" → arc finished, proceed with stale lead detection
    _trace "ARC loop $(basename "$loop_file") status=completed, proceeding"
  fi
done

# ── Read talisman config for stale_lead_wakeup settings ──
WAKEUP_ENABLED=true
DEBOUNCE_SECONDS=300

TALISMAN_SHARD="${CWD}/tmp/.talisman-resolved/misc.json"
if [[ -f "$TALISMAN_SHARD" && ! -L "$TALISMAN_SHARD" ]]; then
  _tw_enabled=$(jq -r 'if .stale_lead_wakeup.enabled == null then true else .stale_lead_wakeup.enabled end' "$TALISMAN_SHARD" 2>/dev/null || echo "true")
  _tw_debounce=$(jq -r 'if .stale_lead_wakeup.debounce_seconds == null then 300 else .stale_lead_wakeup.debounce_seconds end' "$TALISMAN_SHARD" 2>/dev/null || echo "300")
  [[ "$_tw_enabled" == "false" ]] && WAKEUP_ENABLED=false
  [[ "$_tw_debounce" =~ ^[0-9]+$ ]] && DEBOUNCE_SECONDS="$_tw_debounce"
fi

# Also check teammate_lifecycle section (plan specifies this location)
TALISMAN_SETTINGS_SHARD="${CWD}/tmp/.talisman-resolved/settings.json"
if [[ -f "$TALISMAN_SETTINGS_SHARD" && ! -L "$TALISMAN_SETTINGS_SHARD" ]]; then
  _tl_enabled=$(jq -r '.teammate_lifecycle.stale_lead_wakeup.enabled // empty' "$TALISMAN_SETTINGS_SHARD" 2>/dev/null || true)
  _tl_debounce=$(jq -r '.teammate_lifecycle.stale_lead_wakeup.debounce_seconds // empty' "$TALISMAN_SETTINGS_SHARD" 2>/dev/null || true)
  [[ "$_tl_enabled" == "false" ]] && WAKEUP_ENABLED=false
  [[ "$_tl_debounce" =~ ^[0-9]+$ ]] && DEBOUNCE_SECONDS="$_tl_debounce"
fi

if [[ "$WAKEUP_ENABLED" == "false" ]]; then
  _trace "SKIP: stale_lead_wakeup disabled via talisman"
  exit 0
fi

# SEC-002: Validate and clamp debounce
[[ "$DEBOUNCE_SECONDS" -gt 3600 ]] && DEBOUNCE_SECONDS=300

# ── GUARD 4: Find ALL active teams for this session ──
HOOK_NOW=$(date +%s)

for sf in "${STATE_FILES[@]}"; do
  [[ -f "$sf" ]] || continue
  [[ -L "$sf" ]] && continue  # skip symlinks

  # Timeout budget guard — abort if <2s remaining in 10s budget
  _elapsed=$(( $(date +%s) - _HOOK_START_EPOCH ))
  if [[ $_elapsed -gt 8 ]]; then
    _trace "TIMEOUT GUARD: >${_elapsed}s elapsed, aborting loop"
    break
  fi

  # Skip signal/control files
  case "$(basename "$sf")" in
    .rune-shutdown-signal-*|.rune-force-shutdown-*|.rune-compact-*) continue ;;
  esac

  # Session ownership check
  SF_CFG=$(jq -r '.config_dir // empty' "$sf" 2>/dev/null || true)
  SF_PID=$(jq -r '.owner_pid // empty' "$sf" 2>/dev/null || true)
  SF_STATUS=$(jq -r '.status // empty' "$sf" 2>/dev/null || true)
  SF_TEAM=$(jq -r '.team_name // empty' "$sf" 2>/dev/null || true)
  SF_WORKFLOW=$(jq -r '.workflow_type // empty' "$sf" 2>/dev/null || true)
  SF_OUTPUT=$(jq -r '.output_dir // empty' "$sf" 2>/dev/null || true)

  # Only act on running/monitoring workflows
  case "$SF_STATUS" in
    running|monitoring|active) ;;
    *) continue ;;
  esac

  # Session isolation: config_dir must match
  if [[ -n "$SF_CFG" && "$SF_CFG" != "$RUNE_CURRENT_CFG" ]]; then
    _trace "SKIP $sf: config_dir mismatch"
    continue
  fi

  # Session isolation: prefer session_id, fall back to owner_pid (PPID unreliable in hooks)
  # SEC-004/FLAW-007 FIX: Add session_id-first ownership check, matching detect-workflow-complete.sh pattern
  SF_SID=$(jq -r '.session_id // empty' "$sf" 2>/dev/null || true)
  if [[ -n "$SF_SID" && -n "$_session_id" && "$SF_SID" != "$_session_id" ]]; then
    if [[ -n "$SF_PID" && "$SF_PID" =~ ^[0-9]+$ ]] && rune_pid_alive "$SF_PID"; then
      _trace "SKIP $sf: belongs to live session SID=$SF_SID"
      continue
    fi
    # Owner dead = orphan — let detect-workflow-complete handle it
    _trace "SKIP $sf: orphan (SID=$SF_SID, PID=$SF_PID dead) — defer to detect-workflow-complete"
    continue
  fi
  # RC-3 FIX: Removed PPID-based ownership fallback.
  # Per CLAUDE.md rule 11: $PPID is NOT consistent between hook invocations and skill
  # Bash() calls. The previous fallback wrongly classified the OWNING session's live
  # workflow as "different session" and skipped waking the lead — directly causing
  # phase-stall symptoms on legacy state files (pre-v1.144.16) that lack session_id.
  # Defer no-SID state files to detect-workflow-complete.sh which handles orphans
  # via process-liveness check (which IS reliable, unlike PPID equality).
  if [[ -z "$SF_SID" ]]; then
    _trace "SKIP $sf: no session_id field — defer to detect-workflow-complete (PPID fallback removed, see RC-3)"
    continue
  fi

  # SEC-4: Validate team name
  if [[ -z "$SF_TEAM" || ! "$SF_TEAM" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    _trace "SKIP $sf: invalid team name"
    continue
  fi

  # Verify team directory exists
  if [[ ! -d "${CHOME}/teams/${SF_TEAM}" ]]; then
    _trace "SKIP $sf: team dir does not exist"
    continue
  fi

  _trace "CHECKING team=$SF_TEAM workflow=$SF_WORKFLOW status=$SF_STATUS"

  # ── GUARD 5: Debounce check ──
  SIGNAL_DIR="${CWD}/tmp/.rune-signals/${SF_TEAM}"
  DEBOUNCE_MARKER="${SIGNAL_DIR}/.lead-woken"
  if [[ -f "$DEBOUNCE_MARKER" && ! -L "$DEBOUNCE_MARKER" ]]; then
    # FLAW-002 FIX: Prefer session_id for debounce ownership (PPID unreliable in hooks)
    _marker_sid=$(jq -r '.session_id // empty' "$DEBOUNCE_MARKER" 2>/dev/null || true)
    _marker_pid=$(jq -r '.owner_pid // empty' "$DEBOUNCE_MARKER" 2>/dev/null || true)
    if [[ -n "$_marker_sid" && -n "$_session_id" && "$_marker_sid" == "$_session_id" ]] || \
       [[ -z "$_marker_sid" && "$_marker_pid" == "$PPID" ]]; then
      # Same session — check age
      _marker_mtime=$(_stat_mtime "$DEBOUNCE_MARKER"); _marker_mtime="${_marker_mtime:-0}"
      _marker_age=$(( HOOK_NOW - _marker_mtime ))
      [[ $_marker_age -lt 0 ]] && _marker_age=0
      if [[ $_marker_age -lt $DEBOUNCE_SECONDS ]]; then
        _trace "DEBOUNCE: team=$SF_TEAM already woken ${_marker_age}s ago (threshold=${DEBOUNCE_SECONDS}s)"
        continue
      fi
    fi
    # Different owner_pid or stale marker — ignore and proceed
    _trace "DEBOUNCE: marker exists but owner_pid=$_marker_pid != PPID=$PPID or expired — proceeding"
  fi

  # ── Detection cascade (first match wins) ──
  WAKE_MODE=""
  COMPLETED_COUNT=0
  TOTAL_TASKS=0
  IN_PROGRESS_COUNT=0

  # ── Method A: Check .all-done sentinel ──
  if [[ -f "${SIGNAL_DIR}/.all-done" && ! -L "${SIGNAL_DIR}/.all-done" ]]; then
    _trace "Method A: .all-done sentinel found for team=$SF_TEAM"
    WAKE_MODE="COMPLETE"
    # Extract count from sentinel
    COMPLETED_COUNT=$(jq -r '.total // 0' "${SIGNAL_DIR}/.all-done" 2>/dev/null || echo "0")
    TOTAL_TASKS="$COMPLETED_COUNT"
  fi

  # ── Method B: Count .done files vs .expected ──
  if [[ -z "$WAKE_MODE" && -f "${SIGNAL_DIR}/.expected" && ! -L "${SIGNAL_DIR}/.expected" ]]; then
    _expected=$(head -c 4 "${SIGNAL_DIR}/.expected" 2>/dev/null | tr -d '[:space:]')
    if [[ "$_expected" =~ ^[1-9][0-9]*$ ]]; then
      _done_count=$(find "$SIGNAL_DIR" -maxdepth 1 -type f -name "*.done" -not -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
      _trace "Method B: done=$_done_count expected=$_expected for team=$SF_TEAM"
      if [[ "$_done_count" -ge "$_expected" ]]; then
        WAKE_MODE="COMPLETE"
        COMPLETED_COUNT="$_done_count"
        TOTAL_TASKS="$_expected"
      fi
    fi
  fi

  # ── Method C: Scan task files in $CHOME/tasks/$TEAM/ ──
  if [[ -z "$WAKE_MODE" ]]; then
    TASK_DIR="${CHOME}/tasks/${SF_TEAM}"
    if [[ -d "$TASK_DIR" ]]; then
      _all_done=true
      _found_any=false
      _completed=0
      _total=0
      _in_progress=0
      while IFS= read -r _tf; do
        [[ -f "$_tf" ]] || continue
        [[ -L "$_tf" ]] && continue
        _found_any=true
        _total=$((_total + 1))
        _task_status=$(jq -r '.status // empty' "$_tf" 2>/dev/null || true)
        case "$_task_status" in
          completed|deleted)
            _completed=$((_completed + 1))
            ;;
          in_progress)
            _in_progress=$((_in_progress + 1))
            _all_done=false
            ;;
          *)
            _all_done=false
            ;;
        esac
      done < <(find "$TASK_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null || true)

      _trace "Method C: total=$_total completed=$_completed in_progress=$_in_progress for team=$SF_TEAM"

      if [[ "$_all_done" == "true" && "$_found_any" == "true" ]]; then
        WAKE_MODE="COMPLETE"
        COMPLETED_COUNT="$_completed"
        TOTAL_TASKS="$_total"
      else
        # Store for Method D
        IN_PROGRESS_COUNT="$_in_progress"
        COMPLETED_COUNT="$_completed"
        TOTAL_TASKS="$_total"
      fi
    fi
  fi

  # ── Method D: Liveness check — no processes but tasks in_progress ──
  if [[ -z "$WAKE_MODE" && "$IN_PROGRESS_COUNT" -gt 0 ]]; then
    # CRITICAL: Use owner_pid from state file (NOT $PPID).
    # Hooks have a different $PPID — the hook runner subprocess PID.
    # The stored owner_pid is the Claude Code session PID whose children are the teammates.
    _stored_pid="$SF_PID"
    _teammate_count=0
    if [[ -n "$_stored_pid" && "$_stored_pid" =~ ^[0-9]+$ ]] && command -v pgrep &>/dev/null; then
      while IFS= read -r _child; do
        [[ -z "$_child" || ! "$_child" =~ ^[0-9]+$ ]] && continue
        _child_cmd=$(ps -p "$_child" -o comm= 2>/dev/null || true)
        case "$_child_cmd" in
          node|claude|claude-*) _teammate_count=$((_teammate_count + 1)) ;;
        esac
      done < <(pgrep -P "$_stored_pid" 2>/dev/null || true)
    fi

    _trace "Method D: teammate_processes=$_teammate_count in_progress=$IN_PROGRESS_COUNT for team=$SF_TEAM"

    if [[ "$_teammate_count" -eq 0 ]]; then
      WAKE_MODE="CRASHED"
    fi
  fi

  # ── No detection → continue to next team ──
  if [[ -z "$WAKE_MODE" ]]; then
    _trace "NO WAKE: team=$SF_TEAM — teammates still working"
    continue
  fi

  # ── Pre-wake cleanup ──
  # Clear .readonly-active marker so lead can write files immediately
  if [[ -f "${CWD}/tmp/.readonly-active" ]]; then
    rm -f "${CWD}/tmp/.readonly-active" 2>/dev/null || true
    _trace "PRE-WAKE: cleared .readonly-active"
  fi

  # Write debounce marker (atomic)
  mkdir -p "$SIGNAL_DIR" 2>/dev/null || true
  _marker_tmp=$(mktemp "${DEBOUNCE_MARKER}.XXXXXX" 2>/dev/null) || true
  if [[ -n "$_marker_tmp" ]]; then
    jq -n --arg pid "$PPID" \
      --arg sid "${RUNE_CURRENT_SID:-unknown}" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg mode "$WAKE_MODE" \
      --arg team "$SF_TEAM" \
      '{owner_pid: $pid, session_id: $sid, timestamp: $ts, wake_mode: $mode, team: $team}' \
      > "$_marker_tmp" 2>/dev/null \
      && mv -f "$_marker_tmp" "$DEBOUNCE_MARKER" 2>/dev/null \
      || rm -f "$_marker_tmp" 2>/dev/null
  fi

  # ── WAKE: exit 2 + context-rich stderr ──
  _trace "WAKE: team=$SF_TEAM mode=$WAKE_MODE completed=$COMPLETED_COUNT total=$TOTAL_TASKS"

  if [[ "$WAKE_MODE" == "COMPLETE" ]]; then
    # Build output dir hint
    _output_hint=""
    if [[ -n "$SF_OUTPUT" && "$SF_OUTPUT" != "null" ]]; then
      _output_hint=" Output directory: ${SF_OUTPUT}."
    fi
    _workflow_hint=""
    if [[ -n "$SF_WORKFLOW" && "$SF_WORKFLOW" != "null" ]]; then
      _workflow_hint=" (${SF_WORKFLOW} workflow)"
    fi

    printf 'All %s teammates in team "%s"%s have completed their work.%s\nProcess results and continue the workflow. Check TaskList for completed tasks and collect output from teammates.\n' \
      "$COMPLETED_COUNT" "$SF_TEAM" "$_workflow_hint" "$_output_hint" >&2
    exit 2
  elif [[ "$WAKE_MODE" == "CRASHED" ]]; then
    _output_hint=""
    if [[ -n "$SF_OUTPUT" && "$SF_OUTPUT" != "null" ]]; then
      _output_hint=" Output directory: ${SF_OUTPUT}."
    fi
    _workflow_hint=""
    if [[ -n "$SF_WORKFLOW" && "$SF_WORKFLOW" != "null" ]]; then
      _workflow_hint=" (${SF_WORKFLOW} workflow)"
    fi

    printf 'WARNING: %d task(s) still in_progress but 0 teammate processes found in team "%s"%s. Teammates may have crashed.%s\nProcess any partial results. Check TaskList and decide: retry failed tasks or proceed with available output.\n' \
      "$IN_PROGRESS_COUNT" "$SF_TEAM" "$_workflow_hint" "$_output_hint" >&2
    exit 2
  fi
done

_trace "EXIT detect-stale-lead.sh (no wake needed)"
exit 0
