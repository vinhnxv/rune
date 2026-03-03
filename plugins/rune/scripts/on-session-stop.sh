#!/bin/bash
# scripts/on-session-stop.sh
# STOP-001: Auto-cleans stale Rune workflows on session stop.
#
# When a session ends, this hook automatically cleans up orphaned resources
# instead of blocking the user. Resources cleaned:
#   0. Stale teammate processes (node/claude/claude-*) — SIGTERM then SIGKILL
#   1. Team dirs (rune-*/arc-*) — rm team + task dirs
#   2. State files (.rune-*.json with status "active") — set status to "stopped"
#   3. Arc checkpoints with in_progress phases — set to "cancelled"
#   4. Shutdown signal files (.rune-shutdown-signal-*.json) — rm owned signals
#
# DESIGN PRINCIPLES:
#   1. Fail-open — if anything goes wrong, allow the stop (exit 0)
#   2. Loop prevention — check stop_hook_active field to avoid re-entry
#   3. rune-*/arc-* prefix filter (never touch foreign plugin state)
#   4. Auto-clean, don't block — "janitor on the way out, not security guard"
#   5. Report what was cleaned via additionalContext (informational)
#
# Hook event: Stop
# Timeout: 5s
# Exit 0 with no output: Allow stop (nothing to clean)
# Exit 0 with stdout summary: Report what was cleaned (informational, non-blocking)
#
# QUAL-005: Inline fix markers use format: [AREA]-[NNN] (e.g., SEC-005, BACK-012).
#   These are audit trail comments referencing the finding that motivated the change.

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
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

# ── GUARD 1: jq dependency (fail-open) ──
if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── GUARD 2: Input size cap (SEC-2: 1MB DoS prevention) ──
INPUT=$(head -c 1048576 2>/dev/null || true)

# ── GUARD 3: Loop prevention ──
# If stop_hook_active is true, we already cleaned on a previous pass — allow stop
STOP_HOOK_ACTIVE=$(printf '%s\n' "$INPUT" | jq -r '.stop_hook_active // empty' 2>/dev/null || true)  # Use printf instead of echo for JSON safety (prevents shell interpretation of special chars)
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

# ── GUARD 4: CWD extraction and canonicalization ──
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)  # Use printf instead of echo for JSON safety (prevents shell interpretation of special chars)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then
  exit 0
fi

# ── Session identity for cross-session ownership filtering ──
# Sourced early (before GUARD 5) so all ownership checks use the same RUNE_CURRENT_CFG.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-session-identity.sh
# PAT-007 FIX: Guard source with file existence check
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
else
  # Fallback: inline resolution (matches resolve-session-identity.sh logic)
  RUNE_CURRENT_CFG=$(cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P) || RUNE_CURRENT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  rune_pid_alive() { kill -0 "$1" 2>/dev/null; }
fi

# ── Helper: Extract a YAML frontmatter field value (single-line, simple values only) ──
_get_fm_field() {
  local fm="$1" field="$2"
  # || true: grep returning no match (exit 1) must not trigger ERR trap (set -euo pipefail)
  # Without this, callers outside `if` conditions (lines 94, 105) would exit 0 via ERR trap
  echo "$fm" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | head -1 || true
}

# ── Helper: Check if this session owns a loop state file ──
# Returns 0 (true) if owned, 1 (false) if not. Sets _LOOP_FM for caller to extract extra fields.
_check_loop_ownership() {
  local state_file="$1"
  [[ -f "$state_file" ]] && [[ ! -L "$state_file" ]] || return 1
  _LOOP_FM=$(sed -n '/^---$/,/^---$/p' "$state_file" 2>/dev/null | sed '1d;$d')
  local cfg pid
  cfg=$(_get_fm_field "$_LOOP_FM" "config_dir")
  pid=$(_get_fm_field "$_LOOP_FM" "owner_pid")
  # Check config_dir (uses RUNE_CURRENT_CFG from resolve-session-identity.sh)
  if [[ -n "$cfg" && "$cfg" != "$RUNE_CURRENT_CFG" ]]; then
    return 1
  fi
  # Check PID (EPERM-safe: rune_pid_alive from resolve-session-identity.sh)
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" != "$PPID" ]]; then
    if rune_pid_alive "$pid"; then
      return 1
    fi
  fi
  return 0
}

# ── GUARD 5d: Defer to arc-phase stop hook (with ownership check) ──
# v1.110.0: Phase loop is the innermost loop — defer here BEFORE batch/hierarchy/issues.
# If loop file is active but older than the staleness threshold, the loop hook likely crashed.
# Force cleanup instead of deferring indefinitely, which would leave the session unable to stop.
# v1.125.1 FIX: Increased threshold from 10 min to 90 min. Arc phases can legitimately
# take up to 50 min (test with E2E) and the state file mtime is only updated between
# phases (by arc-phase-stop-hook.sh iteration increment). The 10-min threshold caused
# premature deletion of active state files, breaking the phase loop.
# GUARD 5d: 90 min = ~26 phases × ~3.5 min per phase (full arc single-run)
_PHASE_STALE_MIN=90
[[ -z "${NOW:-}" ]] && NOW=$(date +%s)
if _check_loop_ownership "${CWD}/.claude/arc-phase-loop.local.md"; then
  _phase_active=$(_get_fm_field "$_LOOP_FM" "active")
  if [[ "$_phase_active" == "true" ]]; then
    _phase_mtime=$(stat -f %m "${CWD}/.claude/arc-phase-loop.local.md" 2>/dev/null || stat -c %Y "${CWD}/.claude/arc-phase-loop.local.md" 2>/dev/null || echo 0)
    _phase_age_min=$(( (NOW - _phase_mtime) / 60 ))
    if [[ $_phase_age_min -gt $_PHASE_STALE_MIN ]]; then
      rm -f "${CWD}/.claude/arc-phase-loop.local.md" 2>/dev/null
    else
      exit 0
    fi
  else
    rm -f "${CWD}/.claude/arc-phase-loop.local.md" 2>/dev/null
  fi
fi

# ── GUARD 5: Defer to arc-batch stop hook (with ownership check) ──
# v1.101.1 FIX (Finding #5): Add staleness check. If loop file is active but older
# than the threshold, the loop hook likely crashed. Force cleanup instead of deferring
# indefinitely, which would leave the session unable to stop.
# v1.125.1 FIX: Increased threshold from 10 min to 150 min. A single arc run can
# take 30-90 minutes (all 26 phases), and the batch loop file mtime is only updated
# between arc runs (not between phases). The 10-min threshold caused premature deletion
# of active state files during the first arc's execution.
# GUARD 5: 150 min = arc runtime (30-90 min) × up to 2 arcs in flight
_BATCH_STALE_MIN=150
[[ -z "${NOW:-}" ]] && NOW=$(date +%s)
if _check_loop_ownership "${CWD}/.claude/arc-batch-loop.local.md"; then
  _batch_active=$(_get_fm_field "$_LOOP_FM" "active")
  if [[ "$_batch_active" == "true" ]]; then
    # Check staleness — if file is older than threshold, loop hook likely crashed
    _batch_mtime=$(stat -f %m "${CWD}/.claude/arc-batch-loop.local.md" 2>/dev/null || stat -c %Y "${CWD}/.claude/arc-batch-loop.local.md" 2>/dev/null || echo 0)
    _batch_age_min=$(( (NOW - _batch_mtime) / 60 ))
    if [[ $_batch_age_min -gt $_BATCH_STALE_MIN ]]; then
      # Stale loop file — force cleanup instead of deferring
      rm -f "${CWD}/.claude/arc-batch-loop.local.md" 2>/dev/null
    else
      # Fresh active batch — defer to arc-batch-stop-hook.sh
      exit 0
    fi
  else
    # Not active (completed/cancelled) — clean up orphaned file
    rm -f "${CWD}/.claude/arc-batch-loop.local.md" 2>/dev/null
  fi
fi

# ── GUARD 5b: Defer to arc-hierarchy stop hook (with ownership check) ──
# v1.125.1 FIX: Increased threshold from 10 min to 150 min (same as batch — hierarchy
# runs multiple child arcs sequentially, each taking 30-90 min).
_HIERARCHY_STALE_MIN=150
if _check_loop_ownership "${CWD}/.claude/arc-hierarchy-loop.local.md"; then
  _hier_status=$(_get_fm_field "$_LOOP_FM" "status")
  if [[ "$_hier_status" == "active" ]]; then
    _hier_mtime=$(stat -f %m "${CWD}/.claude/arc-hierarchy-loop.local.md" 2>/dev/null || stat -c %Y "${CWD}/.claude/arc-hierarchy-loop.local.md" 2>/dev/null || echo 0)
    _hier_age_min=$(( (NOW - _hier_mtime) / 60 ))
    if [[ $_hier_age_min -gt $_HIERARCHY_STALE_MIN ]]; then
      rm -f "${CWD}/.claude/arc-hierarchy-loop.local.md" 2>/dev/null
    else
      exit 0
    fi
  else
    # Not active (completed/cancelled) — clean up orphaned file
    rm -f "${CWD}/.claude/arc-hierarchy-loop.local.md" 2>/dev/null
  fi
fi

# ── GUARD 5c: Defer to arc-issues stop hook (with ownership check) ──
# v1.125.1 FIX: Increased threshold from 10 min to 150 min (same as batch — issues
# runs multiple arcs sequentially, each taking 30-90 min).
_ISSUES_STALE_MIN=150
if _check_loop_ownership "${CWD}/.claude/arc-issues-loop.local.md"; then
  _issues_active=$(_get_fm_field "$_LOOP_FM" "active")
  if [[ "$_issues_active" == "true" ]]; then
    _issues_mtime=$(stat -f %m "${CWD}/.claude/arc-issues-loop.local.md" 2>/dev/null || stat -c %Y "${CWD}/.claude/arc-issues-loop.local.md" 2>/dev/null || echo 0)
    _issues_age_min=$(( (NOW - _issues_mtime) / 60 ))
    if [[ $_issues_age_min -gt $_ISSUES_STALE_MIN ]]; then
      rm -f "${CWD}/.claude/arc-issues-loop.local.md" 2>/dev/null
    else
      exit 0
    fi
  else
    # Not active (completed/cancelled) — clean up orphaned file
    rm -f "${CWD}/.claude/arc-issues-loop.local.md" 2>/dev/null
  fi
fi

# ── Helper: Kill stale teammate processes ──
# Terminates child processes of this Claude Code session (node/claude/claude-*).
# SIGTERM first (graceful), then SIGKILL survivors after 2s.
# Only kills OUR session's children — PPID match guarantees this.
# SEC-002: PPID scoping limits blast radius to children of this Claude Code process.
# Command name filter (node|claude|claude-*) further narrows targets to teammate processes.
# Intentional trade-off: command name could theoretically match non-teammate child processes,
# but PPID + command name together keep false-positive risk acceptably low.
_kill_stale_teammates() {
  local child_pids child_pid child_comm killed=0

  # BACK-008: Validate that PPID is actually a Claude Code process before targeting its children.
  # Hook execution model may vary — $PPID is the hook runner, which should be node or claude.
  # NOTE: This check is best-effort only. $PPID is captured at script start; by the time
  # this function runs (after sleep 1 in Phase 2), the process table may have changed.
  # The primary safety net against PID recycling is the child re-verification at Phase 2
  # (lines below, after sleep 1): each survivor PID is re-checked by command name before SIGKILL.
  local ppid_cmd
  ppid_cmd=$(ps -p "$PPID" -o comm= 2>/dev/null || true)
  if [[ ! "$ppid_cmd" =~ ^(node|claude)$ ]]; then
    # Not a Claude Code process — skip kill to avoid collateral damage
    echo "0"
    return 0
  fi

  child_pids=$(pgrep -P "$PPID" 2>/dev/null || true)
  [[ -z "$child_pids" ]] && { echo "$killed"; return 0; }

  # Phase 1: SIGTERM eligible children
  local sigterm_pids=()
  while IFS= read -r child_pid; do
    [[ -z "$child_pid" ]] && continue
    [[ ! "$child_pid" =~ ^[0-9]+$ ]] && continue
    child_comm=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
    case "$child_comm" in
      node|claude|claude-*) ;;
      *) continue ;;
    esac
    kill -TERM "$child_pid" 2>/dev/null || true
    sigterm_pids+=("$child_pid")
  done <<< "$child_pids"

  [[ ${#sigterm_pids[@]} -eq 0 ]] && { echo "0"; return 0; }

  # Phase 2: Wait 1s, then SIGKILL survivors
  # SEC-005: Reduced from 2s to 1s (40% → 20% of 5s hook timeout budget).
  # SEC-P1-001 FIX: Re-verify process identity before SIGKILL to prevent
  # killing unrelated processes due to PID recycling.
  sleep 1
  for child_pid in "${sigterm_pids[@]}"; do
    if kill -0 "$child_pid" 2>/dev/null; then
      # Re-check command name — PID could have been recycled during sleep
      local survivor_comm
      survivor_comm=$(ps -p "$child_pid" -o comm= 2>/dev/null || true)
      case "$survivor_comm" in
        node|claude|claude-*)
          if kill -KILL "$child_pid" 2>/dev/null; then
            killed=$((killed + 1))
          fi
          ;;
        *)
          # PID recycled to a non-Claude process — do NOT kill
          ;;
      esac
    fi
  done

  echo "$killed"
  return 0
}

# ── AUTO-CLEAN PHASE 0: Terminate stale teammate processes ──
if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
  cleaned_processes=0
else
  cleaned_processes=$(_kill_stale_teammates)
fi

# ── CHOME resolution ──
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0
fi

# ── BUILD STATE FILE TEAM SET ──
# Collect team names referenced by state files in THIS project's tmp/.
# This scopes cleanup to teams owned by workflows in the current CWD,
# preventing cross-session interference when multiple sessions run concurrently.
state_team_names=()
if [[ -d "${CWD}/tmp/" ]]; then
  shopt -s nullglob
  for sf in "${CWD}/tmp/"/.rune-*.json; do
    [[ ! -f "$sf" ]] && continue
    [[ -L "$sf" ]] && continue
    # Extract team_name ONLY from active state files (skip completed/stopped/failed)
    # This prevents matching old state files from previous workflows
    # BACK-011: select(.team_name != null) guards against null team_name passing the // empty filter
    tname=$(jq -r 'select(.status == "active") | select(.team_name != null) | .team_name // empty' "$sf" 2>/dev/null || true)
    if [[ -n "$tname" ]] && [[ "$tname" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      # ── Ownership filter: only collect teams from THIS session ──
      sf_cfg=$(jq -r '.config_dir // empty' "$sf" 2>/dev/null || true)
      sf_pid=$(jq -r '.owner_pid // empty' "$sf" 2>/dev/null || true)
      if [[ -n "$sf_cfg" && "$sf_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$sf_pid" && "$sf_pid" =~ ^[0-9]+$ && "$sf_pid" != "$PPID" ]]; then
        rune_pid_alive "$sf_pid" && continue  # alive = different session
      fi
      state_team_names+=("$tname")
    fi
  done
  shopt -u nullglob
fi

# ── AUTO-CLEAN PHASE 1: Team dirs (rune-*/arc-*) ──
# Strategy:
#   - Teams WITH a matching state file in CWD → always clean (belongs to this project)
#   - Teams WITHOUT a state file → only clean if older than 30 min (orphan fallback)
# This protects active teams from other sessions while still catching true orphans.
cleaned_teams=()
if [[ -d "$CHOME/teams/" ]]; then
  NOW=$(date +%s)
  shopt -s nullglob
  for dir in "$CHOME/teams/"*/; do
    [[ ! -d "$dir" ]] && continue
    [[ -L "$dir" ]] && continue
    dirname="${dir%/}"
    dirname="${dirname##*/}"
    if [[ "$dirname" == rune-* || "$dirname" == arc-* || "$dirname" == goldmask-* ]]; then
      [[ "$dirname" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

      # Check if this team has a corresponding state file in CWD
      has_state_file=false
      for stn in "${state_team_names[@]+"${state_team_names[@]}"}"; do
        if [[ "$stn" == "$dirname" ]]; then
          has_state_file=true
          break
        fi
      done

      should_clean=false
      if [[ "$has_state_file" == "true" ]]; then
        # State file in CWD → belongs to this project's workflow → safe to clean
        should_clean=true
      else
        # No state file → only clean if older than 30 min (true orphan)
        dir_mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
        dir_age_min=$(( (NOW - dir_mtime) / 60 ))
        if [[ $dir_age_min -gt 30 ]]; then
          should_clean=true
        fi
      fi

      if [[ "$should_clean" == "true" ]]; then
        if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
          cleaned_teams+=("$dirname")
          continue
        fi
        # SEC-1: Re-check symlink immediately before rm-rf (TOCTOU mitigation)
        if [[ ! -L "$CHOME/teams/${dirname}" ]]; then
          rm -rf "$CHOME/teams/${dirname}/" "$CHOME/tasks/${dirname}/" 2>/dev/null
          cleaned_teams+=("$dirname")
        fi
      fi
    fi
  done
  shopt -u nullglob
fi

# ── AUTO-CLEAN PHASE 2: State files (set active → stopped) ──
cleaned_states=()
if [[ -d "${CWD}/tmp/" ]]; then
  shopt -s nullglob
  for f in "${CWD}/tmp/"/.rune-*.json; do
    [[ ! -f "$f" ]] && continue
    [[ -L "$f" ]] && continue
    # Skip signal files handled by dedicated cleanup blocks above
    case "$(basename "$f")" in
      .rune-shutdown-signal-*|.rune-force-shutdown-*|.rune-compact-*) continue ;;
    esac
    # BACK-012: Schema validation — skip files that don't have a non-empty .team_name field
    jq -e '.team_name | select(length > 0)' "$f" >/dev/null 2>&1 || continue
    if jq -e '.status == "active"' "$f" >/dev/null 2>&1; then
      # ── Ownership filter: only mark THIS session's state files as stopped ──
      f_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      f_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      if [[ -n "$f_cfg" && "$f_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$f_pid" && "$f_pid" =~ ^[0-9]+$ && "$f_pid" != "$PPID" ]]; then
        rune_pid_alive "$f_pid" && continue  # alive = different session
      fi
      # Update status to "stopped" (not "completed" — distinguishes clean exit from crash)
      fname="${f##*/}"
      if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
        cleaned_states+=("$fname")
        continue
      fi
      jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "stopped" | .stopped_by = "STOP-001" | .stopped_at = $ts' "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null
      cleaned_states+=("$fname")
    fi
  done
  shopt -u nullglob
fi

# ── AUTO-CLEAN PHASE 3: Arc checkpoints (in_progress → cancelled) ──
# Only cancel checkpoints older than 5 min to avoid hitting active arc in another session.
# 5 min is shorter than the 30 min team threshold because arc checkpoints are CWD-scoped
# (less cross-session risk) and in_progress phases from crashed sessions should be cancelled quickly.
cleaned_arcs=()
if [[ -d "${CWD}/.claude/arc/" ]]; then
  [[ -z "${NOW:-}" ]] && NOW=$(date +%s)
  shopt -s nullglob
  for f in "${CWD}/.claude/arc/"*/checkpoint.json; do
    [[ ! -f "$f" ]] && continue
    [[ -L "$f" ]] && continue
    # Age guard: skip checkpoints modified within the last 5 minutes
    f_mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    f_age_min=$(( (NOW - f_mtime) / 60 ))
    if [[ $f_age_min -le 5 ]]; then
      continue
    fi
    if jq -e '.phases | to_entries | map(.value.status) | any(. == "in_progress")' "$f" >/dev/null 2>&1; then
      # ── Ownership filter: only cancel THIS session's arc checkpoints ──
      f_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      f_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      if [[ -n "$f_cfg" && "$f_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$f_pid" && "$f_pid" =~ ^[0-9]+$ && "$f_pid" != "$PPID" ]]; then
        rune_pid_alive "$f_pid" && continue  # alive = different session
      fi
      # Cancel all in_progress phases
      jq '.phases |= with_entries(if .value.status == "in_progress" then .value.status = "cancelled" else . end)' "$f" > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null
      arc_id="${f%/*}"
      arc_id="${arc_id##*/}"
      cleaned_arcs+=("$arc_id")
    fi
  done
  shopt -u nullglob
fi

# ── F-19 FIX: Advise-post-completion flag file cleanup ──
# These flag files are created by advise-post-completion.sh to debounce warnings
# (one per session). They are never cleaned up, leading to /tmp accumulation.
# Pattern: ${TMPDIR}/rune-postcomp-$(id -u)-${SESSION_ID}.json
# We clean all owned flag files (matching UID) since the session is ending.
shopt -s nullglob
for f in "${TMPDIR:-/tmp}"/rune-postcomp-"$(id -u)"-*.json; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && { rm -f "$f" 2>/dev/null; continue; }
  # Ownership check via file content (config_dir + owner_pid)
  F19_CFG=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
  F19_PID=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
  [[ -n "$F19_CFG" && "$F19_CFG" != "$RUNE_CURRENT_CFG" ]] && continue
  if [[ -n "$F19_PID" && "$F19_PID" =~ ^[0-9]+$ && "$F19_PID" != "$PPID" ]]; then
    rune_pid_alive "$F19_PID" && continue
  fi
  rm -f "$f" 2>/dev/null
done
shopt -u nullglob

# ── Bridge file cleanup (context monitor) ──
# Ownership-scan pattern — session_id not available in Stop hook
# NOTE: $RUNE_CURRENT_CFG is already available (sourced at top of script)
shopt -s nullglob
for f in /tmp/rune-ctx-*-warned.json /tmp/rune-ctx-*.json; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && { rm -f "$f" 2>/dev/null; continue; }  # symlink guard
  B_CFG=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
  B_PID=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
  # Only clean if: our config_dir AND (our PID or dead PID)
  [[ -n "$B_CFG" && "$B_CFG" != "$RUNE_CURRENT_CFG" ]] && continue
  if [[ -n "$B_PID" && "$B_PID" =~ ^[0-9]+$ && "$B_PID" != "${PPID:-0}" ]]; then
    rune_pid_alive "$B_PID" && continue
  fi
  rm -f "$f" 2>/dev/null
  # NOTE: _trace may not be defined in on-session-stop.sh — use inline trace
  [[ "${RUNE_TRACE:-}" == "1" ]] && printf '[%s] on-session-stop: CLEANUP: removed bridge file %s\n' "$(date +%H:%M:%S)" "$f" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" 2>/dev/null || true
done
shopt -u nullglob

# ── Shutdown signal file cleanup ──
# Clean up .rune-shutdown-signal-*.json files created by guard-context-critical.sh (Layer 1)
shopt -s nullglob
for f in "${CWD}/tmp/"/.rune-shutdown-signal-*.json; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && continue
  # Session ownership check
  SS_CFG=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
  SS_PID=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
  [[ -n "$SS_CFG" && "$SS_CFG" != "$RUNE_CURRENT_CFG" ]] && continue
  if [[ -n "$SS_PID" && "$SS_PID" =~ ^[0-9]+$ && "$SS_PID" != "$PPID" ]]; then
    rune_pid_alive "$SS_PID" && continue
  fi
  rm -f "$f" 2>/dev/null
done
shopt -u nullglob

# ── Force shutdown signal file cleanup ──
# Clean up .rune-force-shutdown-*.json files created by guard-context-critical.sh (Tier 3)
shopt -s nullglob
for f in "${CWD}/tmp/"/.rune-force-shutdown-*.json; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && continue
  # Session ownership check
  FS_CFG=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
  FS_PID=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
  [[ -n "$FS_CFG" && "$FS_CFG" != "$RUNE_CURRENT_CFG" ]] && continue
  if [[ -n "$FS_PID" && "$FS_PID" =~ ^[0-9]+$ && "$FS_PID" != "$PPID" ]]; then
    rune_pid_alive "$FS_PID" && continue
  fi
  rm -f "$f" 2>/dev/null
done
shopt -u nullglob

# ── Signal directory cleanup (F10) ──
# Clean up tmp/.rune-signals/rune-work-*/ directories where the associated
# state file has a dead owner_pid. Only clean dirs belonging to dead sessions.
cleaned_signal_dirs=0
if [[ -d "${CWD}/tmp/.rune-signals/" ]]; then
  shopt -s nullglob
  for sdir in "${CWD}/tmp/.rune-signals/"rune-work-*/; do
    [[ ! -d "$sdir" ]] && continue
    [[ -L "$sdir" ]] && continue
    sdirname="${sdir%/}"
    sdirname="${sdirname##*/}"
    [[ "$sdirname" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
    # Check if there's a matching state file with ownership info
    state_found=false
    for sf in "${CWD}/tmp/"/.rune-*.json; do
      [[ ! -f "$sf" ]] && continue
      [[ -L "$sf" ]] && continue
      sf_team=$(jq -r '.team_name // empty' "$sf" 2>/dev/null || true)
      [[ "$sf_team" != "$sdirname" ]] && continue
      state_found=true
      # Ownership filter: check config_dir and owner_pid
      sf_cfg=$(jq -r '.config_dir // empty' "$sf" 2>/dev/null || true)
      sf_pid=$(jq -r '.owner_pid // empty' "$sf" 2>/dev/null || true)
      [[ -n "$sf_cfg" && "$sf_cfg" != "$RUNE_CURRENT_CFG" ]] && continue 2
      if [[ -n "$sf_pid" && "$sf_pid" =~ ^[0-9]+$ && "$sf_pid" != "$PPID" ]]; then
        rune_pid_alive "$sf_pid" && continue 2  # alive = different session
      fi
      break
    done
    # Clean if: state file found with dead/matching owner, or no state file (true orphan)
    if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" != "1" ]]; then
      rm -rf "$sdir" 2>/dev/null
    fi
    cleaned_signal_dirs=$((cleaned_signal_dirs + 1))
  done
  shopt -u nullglob
fi

# ── AUTO-CLEAN PHASE 4: Orphaned git worktrees (rune-work-*) ──
# WORKTREE-GC: Remove when SDK provides native worktree lifecycle management
# Catches worktrees left behind when strive Phase 6 was never reached.
# Uses shared GC library for session-safe cleanup.
cleaned_worktrees=""
if [[ -f "${SCRIPT_DIR}/lib/worktree-gc.sh" ]]; then
  # shellcheck source=lib/worktree-gc.sh
  source "${SCRIPT_DIR}/lib/worktree-gc.sh"
  cleaned_worktrees=$(rune_worktree_gc "$CWD" "session-stop")
  # session-stop mode caps at 3 worktrees to stay within 5s timeout budget
fi

# ── REPORT ──
wt_count=0
if [[ -n "$cleaned_worktrees" ]]; then
  wt_count=$(echo "$cleaned_worktrees" | grep -c . 2>/dev/null || echo 1)
fi
total=$((${#cleaned_teams[@]} + ${#cleaned_states[@]} + ${#cleaned_arcs[@]} + cleaned_processes + wt_count + cleaned_signal_dirs))

if [[ $total -eq 0 ]]; then
  # Nothing to clean — allow stop silently
  exit 0
fi

# Build summary of what was cleaned
summary="STOP-001 AUTO-CLEANUP: Cleaned ${total} stale resource(s) on session exit."

if [[ ${#cleaned_teams[@]} -gt 0 ]]; then
  team_list="${cleaned_teams[*]:0:5}"
  summary="${summary} Teams: [${team_list}]."
  if [[ ${#cleaned_teams[@]} -gt 5 ]]; then
    summary="${summary} (+$((${#cleaned_teams[@]} - 5)) more)"
  fi
fi

if [[ ${#cleaned_states[@]} -gt 0 ]]; then
  state_list="${cleaned_states[*]:0:3}"
  summary="${summary} States: [${state_list}]."
fi

if [[ ${#cleaned_arcs[@]} -gt 0 ]]; then
  arc_list="${cleaned_arcs[*]:0:3}"
  summary="${summary} Arcs: [${arc_list}]."
fi

if [[ "$cleaned_processes" -gt 0 ]]; then
  summary="${summary} Processes: ${cleaned_processes} terminated."
fi

if [[ -n "$cleaned_worktrees" ]]; then
  summary="${summary} ${cleaned_worktrees}"
fi

if [[ "$cleaned_signal_dirs" -gt 0 ]]; then
  summary="${summary} Signal dirs: ${cleaned_signal_dirs} removed."
fi

# Log to trace file for debugging (always, not just RUNE_TRACE)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $summary" >> "${CWD}/tmp/.rune-stop-cleanup.log" 2>/dev/null

# Silent cleanup — allow stop immediately, no block
# NOTE: Stop hooks do NOT support hookSpecificOutput (unlike PreToolUse/SessionStart).
# The "Stop hook error:" UI label is a known Claude Code UX issue (#12667), not fixable from hook side.
echo "$summary"
exit 0
