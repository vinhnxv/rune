#!/bin/bash
# scripts/session-team-hygiene.sh
# TLC-003: Session startup orphan detection hook.
# Runs once at session start. Scans for orphaned rune-*/arc-* team dirs
# and stale state files. Reports findings to user.
#
# SessionStart hooks CANNOT block the session.
# Output on stdout is shown to Claude as context.
#
# Hook events: SessionStart
# Matcher: startup|resume (fires on fresh start and post-crash resume — primary orphan scenarios)
# Timeout: 5s

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

# Guard: jq dependency
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(head -c 1048576)

# Extract CWD for state file scan
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then exit 0; fi
# SEC-005: Path traversal guard — reject CWD containing ".." before cd
if [[ "$CWD" == *".."* ]]; then exit 0; fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# FIX-1: CHOME absoluteness guard
if [[ -z "$CHOME" ]] || [[ "$CHOME" != /* ]]; then
  exit 0
fi

# ── Session identity for cross-session ownership filtering ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# QUAL-010: Guard against missing helper before sourcing
if [[ ! -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then exit 0; fi
# shellcheck source=resolve-session-identity.sh
source "${SCRIPT_DIR}/resolve-session-identity.sh"

# Extract session_id from hook input JSON (same pattern as enforce-team-lifecycle.sh)
HOOK_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

# Count orphaned team dirs (older than 30 min)
orphan_count=0
orphan_names=()
if [[ -d "$CHOME/teams/" ]]; then
  while IFS= read -r dir; do
    # SEC-006: Reject symlinks before any processing (defense-in-depth: find -type d filters
    # most symlinks, but -follow or race conditions could slip one through)
    [[ -L "$dir" ]] && continue
    dirname=$(basename "$dir")
    if [[ "$dirname" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      # Session ownership filter: skip teams owned by other live sessions
      if [[ -f "$dir/.session" ]] && [[ ! -L "$dir/.session" ]]; then
        marker_session=$(head -c 256 "$dir/.session" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -n "$marker_session" ]] && [[ -n "$HOOK_SESSION_ID" ]] && [[ "$marker_session" != "$HOOK_SESSION_ID" ]]; then
          continue  # Different session owns this team — not an orphan for us
        fi
      fi
      orphan_names+=("$dirname")
      # BACK-012 FIX: ((0++)) returns exit code 1 under set -e, killing the script
      orphan_count=$((orphan_count + 1))
    fi
  done < <(find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" -o -name "goldmask-*" \) -mmin +30 2>/dev/null)
fi

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphan team dirs found: ${orphan_count}" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"

# ── Auto-clean PID-dead orphans (REC-9) ──
# After detection, actually remove team dirs whose owner PID is provably dead.
# Cleans teams where PID is verifiably dead via:
#   (a) .session file (primary), OR
#   (b) corresponding state file in CWD/tmp/ (BACK-007: fallback for teams without .session)
# Also requires: config_dir matches and PID is dead.
# Handles both JSON and plain string .session files (horizon-sage finding).
orphans_cleaned=0
if [[ $orphan_count -gt 0 ]] && [[ -d "$CHOME/teams/" ]]; then
  for oname in "${orphan_names[@]}"; do
    odir="$CHOME/teams/${oname}"
    [[ -d "$odir" ]] || continue
    [[ -L "$odir" ]] && continue
    session_file="$odir/.session"

    owner_pid=""
    owner_cfg=""

    if [[ -f "$session_file" ]] && [[ ! -L "$session_file" ]]; then
      # Primary path: read PID from .session file
      # Read .session content (max 4KB safety cap)
      session_content=$(head -c 4096 "$session_file" 2>/dev/null || true)
      [[ -z "$session_content" ]] && continue

      # Extract owner_pid — handle both JSON and plain string formats
      if echo "$session_content" | jq -e '.' >/dev/null 2>&1; then
        # JSON format: {"session_id":"...","config_dir":"...","owner_pid":"..."}
        owner_pid=$(echo "$session_content" | jq -r '.owner_pid // empty' 2>/dev/null || true)
        owner_cfg=$(echo "$session_content" | jq -r '.config_dir // empty' 2>/dev/null || true)
      fi
      # Plain string format has no PID info — skip (can't verify PID is dead)
      [[ -n "$owner_pid" && "$owner_pid" =~ ^[0-9]+$ ]] || continue
    else
      # BACK-007: Fallback — no .session file. Scan CWD/tmp/ state files for a matching team name.
      # Look for a state file whose team_name (or inferred from filename) matches oname and has a dead PID.
      if [[ -d "${CWD}/tmp/" ]]; then
        # NOTE: Do NOT use `local` here — this is main script body, not a function.
        _saved_nullglob=$(shopt -p nullglob 2>/dev/null || true)
        shopt -s nullglob 2>/dev/null || true
        for sf in "${CWD}/tmp/"/.rune-*.json; do
          [[ -f "$sf" ]] && [[ ! -L "$sf" ]] || continue
          sf_pid=$(jq -r '.owner_pid // empty' "$sf" 2>/dev/null || true)
          sf_cfg=$(jq -r '.config_dir // empty' "$sf" 2>/dev/null || true)
          sf_team=$(jq -r '.team_name // empty' "$sf" 2>/dev/null || true)
          sf_status=$(jq -r '.status // empty' "$sf" 2>/dev/null || true)
          [[ "$sf_status" == "active" ]] || continue
          [[ "$sf_team" == "$oname" ]] || continue
          [[ -n "$sf_pid" && "$sf_pid" =~ ^[0-9]+$ ]] || continue
          owner_pid="$sf_pid"
          owner_cfg="$sf_cfg"
          break
        done
        [[ -n "$_saved_nullglob" ]] && eval "$_saved_nullglob" 2>/dev/null || true
      fi
      # If no matching state file found, cannot verify PID — skip
      [[ -n "$owner_pid" ]] || continue
    fi

    # SEC-008: Exclude sentinel PIDs 0 (kernel) and 1 (init/launchd) — never valid owners
    if [[ "$owner_pid" == "0" || "$owner_pid" == "1" ]]; then continue; fi

    # Layer 1: config_dir mismatch → different installation, skip
    if [[ -n "$owner_cfg" && "$owner_cfg" != "$RUNE_CURRENT_CFG" ]]; then
      continue
    fi

    # Layer 2: PID alive → different active session, skip
    if rune_pid_alive "$owner_pid"; then
      continue
    fi

    # PID is provably dead → safe to auto-clean
    if [[ ! -L "$CHOME/teams/${oname}" ]]; then
      if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
        orphans_cleaned=$((orphans_cleaned + 1))
        [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: DRY RUN: would auto-clean orphan: ${oname} (dead PID ${owner_pid})" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
        continue
      fi
      rm -rf "$CHOME/teams/${oname}/" "$CHOME/tasks/${oname}/" 2>/dev/null
      orphans_cleaned=$((orphans_cleaned + 1))
      [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: auto-cleaned orphan: ${oname} (dead PID ${owner_pid})" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    fi
  done
fi

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphans auto-cleaned: ${orphans_cleaned}" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"

# ── Kill orphan teammate processes on resume ──
# Same pattern as on-session-stop.sh Phase 0 (_kill_stale_teammates), but scoped to
# dead owner PIDs found in state files. On crash-resume, teammate processes from the
# prior session may still be running as children of the now-dead Claude Code process.
orphan_procs_killed=0
if [[ -d "${CWD}/tmp/" ]]; then
  # Collect dead owner PIDs from active state files
  dead_pids=()
  shopt -s nullglob 2>/dev/null
  for sf in "${CWD}/tmp/"/.rune-*.json; do
    [[ -f "$sf" ]] && [[ ! -L "$sf" ]] || continue
    sf_status=$(jq -r '.status // empty' "$sf" 2>/dev/null || true)
    [[ "$sf_status" == "active" ]] || continue
    sf_cfg=$(jq -r '.config_dir // empty' "$sf" 2>/dev/null || true)
    sf_pid=$(jq -r '.owner_pid // empty' "$sf" 2>/dev/null || true)
    [[ -n "$sf_pid" && "$sf_pid" =~ ^[0-9]+$ ]] || continue
    # Skip if different config_dir
    if [[ -n "$sf_cfg" && "$sf_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
    # Skip if PID is alive (active session — not orphaned)
    if rune_pid_alive "$sf_pid"; then continue; fi
    # Dead PID — collect for child process kill
    dead_pids+=("$sf_pid")
  done
  shopt -u nullglob 2>/dev/null

  # Kill child processes of dead owner PIDs
  for dpid in "${dead_pids[@]+"${dead_pids[@]}"}"; do
    child_pids=$(pgrep -P "$dpid" 2>/dev/null || true)
    [[ -z "$child_pids" ]] && continue
    while IFS= read -r cpid; do
      [[ -z "$cpid" ]] && continue
      [[ "$cpid" =~ ^[0-9]+$ ]] || continue
      child_comm=$(ps -p "$cpid" -o comm= 2>/dev/null || true)
      case "$child_comm" in
        node|claude|claude-*) ;;
        *) continue ;;
      esac
      if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
        orphan_procs_killed=$((orphan_procs_killed + 1))
        [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: DRY RUN: would kill orphan PID=$cpid (comm=$child_comm)" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
        continue
      fi
      # BACK-008: Intentional SIGTERM-only design. We do NOT escalate to SIGKILL here because:
      # (1) This SessionStart hook has a strict 5s timeout budget — SIGKILL escalation with
      #     a wait loop would risk exceeding the budget and crashing the hook.
      # (2) SessionStart is informational; hard kills belong in on-session-stop.sh Phase 0
      #     where SIGTERM+5s+SIGKILL escalation is explicitly budgeted.
      # (3) Graceful SIGTERM gives node/claude processes time to flush state — safer than SIGKILL.
      kill -TERM "$cpid" 2>/dev/null || true
      orphan_procs_killed=$((orphan_procs_killed + 1))
    done <<< "$child_pids"
  done
fi

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphan processes killed: ${orphan_procs_killed}" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"

# Count stale state files
stale_state_count=0

# QUAL-005 FIX: Run glob loop in subshell to scope nullglob (prevents leak on early exit)
# BACK-001 FIX: Simplified — script uses #!/bin/bash, so ZSH_VERSION is never set.
# Using subshell instead of setopt/unsetopt pair eliminates scope leak entirely.
# QUAL-002 NOTE: Uses stat for file age (not find -mmin) because we need BOTH age AND
# content check (status == "active"). find alone can't check JSON content.
stale_state_count=$(
  shopt -s nullglob 2>/dev/null
  count=0
  # BACK-015 FIX: Capture epoch once before loop (consistency + efficiency)
  NOW=$(date +%s)
  for f in "${CWD}"/tmp/.rune-review-*.json "${CWD}"/tmp/.rune-audit-*.json "${CWD}"/tmp/.rune-work-*.json "${CWD}"/tmp/.rune-mend-*.json "${CWD}"/tmp/.rune-inspect-*.json "${CWD}"/tmp/.rune-forge-*.json "${CWD}"/tmp/.rune-goldmask-*.json "${CWD}"/tmp/.rune-brainstorm-*.json "${CWD}"/tmp/.rune-resolve-todos-*.json; do
    if [[ -f "$f" ]]; then
      # Check if status is "active" and file is older than 30 min
      # FIX-2: Fallback to epoch 0 (Jan 1 1970) if stat fails. Math: (NOW - 0) / 60 = ~29M minutes
      # = always triggers stale (>30 min). Forge suggested 999999999 but that's wrong: (NOW - 999999999)
      # could be small for timestamps near 2001. Epoch 0 is the safe default.
      # BACK-002 NOTE: macOS stat -f first, then Linux stat -c, then epoch-0 (assume stale)
      file_mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
      file_age_min=$(( (NOW - file_mtime) / 60 ))
      if [[ $file_age_min -gt 30 ]]; then
        # SEC-4 FIX: Use jq for precise status extraction instead of grep string match
        file_status=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
        if [[ "$file_status" == "active" ]]; then
          # ── Ownership filter: only count THIS session's stale state files ──
          sf_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
          sf_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
          if [[ -n "$sf_cfg" && "$sf_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
          if [[ -n "$sf_pid" && "$sf_pid" =~ ^[0-9]+$ && "$sf_pid" != "$PPID" ]]; then
            rune_pid_alive "$sf_pid" && continue  # alive = different session
          fi
          count=$((count + 1))
        fi
      fi
    fi
  done
  echo "$count"
)

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: stale state files found: ${stale_state_count}" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"

# Count orphaned arc checkpoints (v1.110.0: Bug 2 fix)
# Scan .claude/arc/ and tmp/arc/ for checkpoints with dead owner_pid
orphan_checkpoint_count=0
orphan_checkpoint_count=$(
  count=0
  for ckpt_dir in "${CWD}/.claude/arc" "${CWD}/tmp/arc"; do
    [[ -d "$ckpt_dir" ]] || continue
    shopt -s nullglob 2>/dev/null || true
    for f in "$ckpt_dir"/*/checkpoint.json; do
      [[ -f "$f" ]] && [[ ! -L "$f" ]] || continue
      # Extract ownership fields
      ckpt_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      ckpt_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # Skip if no owner_pid (backward compat with pre-session-isolation checkpoints)
      [[ -n "$ckpt_pid" && "$ckpt_pid" =~ ^[0-9]+$ ]] || continue
      # Skip if different config_dir (different installation)
      if [[ -n "$ckpt_cfg" && -n "$RUNE_CURRENT_CFG" && "$ckpt_cfg" != "$RUNE_CURRENT_CFG" ]]; then
        continue
      fi
      # Skip if same session (ours — not orphaned)
      [[ "$ckpt_pid" == "$PPID" ]] && continue
      # Skip if owner is alive (another live session)
      if rune_pid_alive "$ckpt_pid"; then
        continue
      fi
      # Dead owner — orphaned checkpoint
      count=$((count + 1))
    done
  done
  echo "$count"
)

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphaned checkpoints found: ${orphan_checkpoint_count}" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"

# ── Orphaned worktree detection ──
# WORKTREE-GC: Remove when SDK provides native worktree lifecycle management
# Detect rune-work-* worktrees left by crashed sessions (informational only — no auto-cleanup at startup)
orphaned_wt_count=0
if [[ -f "${SCRIPT_DIR}/lib/worktree-gc.sh" ]]; then
  # shellcheck source=lib/worktree-gc.sh
  source "${SCRIPT_DIR}/lib/worktree-gc.sh"
  if rune_has_worktree_support "$CWD"; then
    while IFS= read -r wt_path; do
      [[ -z "$wt_path" ]] && continue
      wt_timestamp=$(rune_extract_wt_timestamp "$wt_path")
      if rune_wt_is_orphaned "$CWD" "$wt_timestamp"; then
        orphaned_wt_count=$((orphaned_wt_count + 1))
      fi
    done < <(rune_list_work_worktrees "$CWD")
  fi
fi

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphaned worktrees found: ${orphaned_wt_count}" >> "${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"

# Report if anything found
# BACK-007 FIX: Conditionally append orphan list to avoid trailing "Orphans: " with no names
remaining_orphans=$((orphan_count - orphans_cleaned))
if [[ $remaining_orphans -gt 0 ]] || [[ $stale_state_count -gt 0 ]] || [[ $orphan_checkpoint_count -gt 0 ]] || [[ $orphaned_wt_count -gt 0 ]] || [[ $orphans_cleaned -gt 0 ]] || [[ $orphan_procs_killed -gt 0 ]]; then
  msg="TLC-003 SESSION HYGIENE:"
  if [[ $orphans_cleaned -gt 0 ]]; then
    msg+=" Auto-cleaned ${orphans_cleaned} PID-dead orphan(s)."
  fi
  if [[ $orphan_procs_killed -gt 0 ]]; then
    msg+=" Killed ${orphan_procs_killed} orphan teammate process(es)."
  fi
  if [[ $remaining_orphans -gt 0 ]] || [[ $stale_state_count -gt 0 ]] || [[ $orphan_checkpoint_count -gt 0 ]] || [[ $orphaned_wt_count -gt 0 ]]; then
    msg+=" Found ${remaining_orphans} orphaned team dir(s), ${stale_state_count} stale state file(s), ${orphan_checkpoint_count} orphaned checkpoint(s), and ${orphaned_wt_count} orphaned worktree(s) from prior sessions. Run /rune:rest --heal to clean up."
  fi
  if [[ ${#orphan_names[@]} -gt 0 ]] && [[ $remaining_orphans -gt 0 ]]; then
    msg+=" Orphans: ${orphan_names[*]:0:5}"
  fi
  jq -n --arg ctx "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0
