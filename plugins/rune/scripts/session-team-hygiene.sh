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
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "${_RUNE_TRACE_PATH:-${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}}" 2>/dev/null
  fi
  # BACK-002: Unconditional stderr warning for ERR trap visibility in production
  printf 'WARN: session-team-hygiene.sh ERR trap at line %s — fail-forward activated\n' "${BASH_LINENO[0]:-?}" >&2
  exit 0
}
trap '_rune_fail_forward' ERR

# ── EXIT trap: ensure hookEventName is always emitted (prevents "hook error") ──
_HOOK_JSON_SENT=false
_rune_session_hook_exit() {
  if [[ "$_HOOK_JSON_SENT" != "true" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart"}}\n'
  fi
}
trap '_rune_session_hook_exit' EXIT

# Guard: Auto-cleanup toggle (MCP-PROTECT-003)
# Auto-cleanup is ENABLED by default. Uses positive teammate PID whitelist (MCP-PROTECT-003).
# Set RUNE_DISABLE_AUTO_CLEANUP=1 to disable, or talisman process_management.auto_cleanup: false.
if [[ "${RUNE_DISABLE_AUTO_CLEANUP:-0}" == "1" ]]; then
  exit 0
fi

# Guard: jq dependency
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Guard: Talisman auto_cleanup config (AC-5)
if [[ -z "${RUNE_DISABLE_AUTO_CLEANUP:-}" ]]; then
  _talisman_shard="${CLAUDE_PROJECT_DIR:-.}/tmp/.talisman-resolved/misc.json"
  if [[ -f "$_talisman_shard" && ! -L "$_talisman_shard" ]]; then
    _auto_cleanup=$(jq -r '.process_management.auto_cleanup // empty' "$_talisman_shard" 2>/dev/null || true)
    if [[ "$_auto_cleanup" == "false" ]]; then
      exit 0
    fi
  fi
fi

# DSEC-005 FIX: Cache trace log path once to prevent TOCTOU write-to-symlink races.
# Each inline expansion of ${RUNE_TRACE_LOG:-...} re-evaluates and re-checks -L separately,
# creating a window where the path could be replaced with a symlink between check and write.
_RUNE_TRACE_PATH="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
# TMPDIR restriction: reject trace paths outside TMPDIR or /tmp (prevent write to arbitrary locations)
case "$_RUNE_TRACE_PATH" in
  "${TMPDIR:-/tmp}/"*|/tmp/*) ;;  # Allowed prefixes
  *) _RUNE_TRACE_PATH="${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log" ;;
esac

INPUT=$(head -c 1048576 2>/dev/null || true)

# Extract CWD for state file scan
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
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

# XVER-001: Canonicalize CHOME to prevent symlink traversal
CHOME_CANON=$(cd "$CHOME" 2>/dev/null && pwd -P) || exit 0
TEAMS_CANON="$CHOME_CANON/teams"
TASKS_CANON="$CHOME_CANON/tasks"

# XVER-001: Reject symlinked intermediate roots
[[ -L "$TEAMS_CANON" ]] && exit 0
[[ -L "$TASKS_CANON" ]] && exit 0

# ── Session identity for cross-session ownership filtering ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# QUAL-010: Guard against missing helper before sourcing
if [[ ! -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then exit 0; fi
# shellcheck source=resolve-session-identity.sh
source "${SCRIPT_DIR}/resolve-session-identity.sh"

# shellcheck source=lib/platform.sh
if [[ -f "${SCRIPT_DIR}/lib/platform.sh" ]]; then
  source "${SCRIPT_DIR}/lib/platform.sh"
fi
source "${SCRIPT_DIR}/lib/rune-state.sh"

# Extract session_id from hook input JSON (same pattern as enforce-team-lifecycle.sh)
HOOK_SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
# SEC-004: Validate session ID format — reject malformed values (path traversal, injection)
# NOTE: {1,128} quantifier not supported in Bash 3.2 (macOS) — use + and length check
if [[ -n "$HOOK_SESSION_ID" ]] && { [[ ${#HOOK_SESSION_ID} -gt 128 ]] || [[ ! "$HOOK_SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; }; then
  HOOK_SESSION_ID=""
fi

# Count orphaned team dirs (older than 30 min)
# STALE THRESHOLD CROSS-REFERENCE:
#   TLC-001 enforce-team-lifecycle.sh: 30 min (team DIRS, PreToolUse:TeamCreate)
#   TLC-003 session-team-hygiene.sh:   30 min (team DIRS, SessionStart — this file)
#   ATE-1  enforce-teams.sh:          120 min (STATE FILES, PreToolUse:Agent)
#   CDX-7  detect-workflow-complete.sh: 150 min (LOOP FILES, Stop hook)
# Thresholds differ intentionally — they check different file types at different lifecycle points.
# NOTE: The 30-min age is INFORMATIONAL ONLY for different-session teams. It controls what gets
# COUNTED and REPORTED, not what gets CLEANED. Auto-cleanup is restricted to own-session teams.
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
        marker_session=$(jq -r '.session_id // empty' "$dir/.session" 2>/dev/null || true)
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

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphan team dirs found: ${orphan_count}" >> "${_RUNE_TRACE_PATH}"

# ── Auto-clean OWN-SESSION PID-dead orphans (REC-9, hardened v1.157.0) ──
# STRICT CROSS-SESSION SAFETY RULES:
#   (a) .session file MUST exist — teams without .session are NEVER auto-cleaned
#       (may be in race window between TeamCreate and stamp-team-session.sh)
#   (b) session_id MUST match current session — NEVER touch other sessions' teams,
#       even if their owner PID is dead (user may want to inspect/manually recover)
#   (c) owner_pid MUST be dead (kill -0 check)
#   (d) config_dir must match (installation isolation)
# BACK-007 fallback (state file scan for teams without .session) REMOVED in v1.157.0 —
# positive session ownership proof is now required before any destructive action.
orphans_cleaned=0
if [[ $orphan_count -gt 0 ]] && [[ -d "$CHOME/teams/" ]] && [[ -n "$HOOK_SESSION_ID" ]]; then
  for oname in "${orphan_names[@]}"; do
    odir="$CHOME/teams/${oname}"
    [[ -d "$odir" ]] || continue
    [[ -L "$odir" ]] && continue
    session_file="$odir/.session"

    # Rule (a): .session file MUST exist — no .session means skip normal cleanup.
    # The team may be in the race window between TeamCreate and stamp-team-session.sh.
    # VEIL-006 FIX: Teams without .session that are older than 24 hours are safe to clean —
    # the TeamCreate→stamp race window is seconds, not hours. Without this threshold,
    # unstamped teams accumulate indefinitely as orphans.
    if [[ ! -f "$session_file" ]] || [[ -L "$session_file" ]]; then
      # Check if team dir is older than 24 hours (1440 minutes) — safe to assume not in race window
      odir_mtime=$(_stat_mtime "$odir"); odir_mtime="${odir_mtime:-0}"
      odir_age_min=$(( ($(date +%s) - odir_mtime) / 60 ))
      [[ "$odir_age_min" -lt 0 ]] && odir_age_min=0
      if [[ $odir_age_min -gt 1440 ]]; then
        # XVER-001: Verify resolved paths before cleanup
        team_target="$CHOME/teams/${oname}"
        task_target="$CHOME/tasks/${oname}"
        [[ -L "$team_target" ]] && continue
        if [[ -d "$team_target" ]]; then
          team_resolved=$(cd "$team_target" 2>/dev/null && pwd -P) || continue
          [[ "$team_resolved" == "$TEAMS_CANON/"* ]] || continue
        fi
        if [[ -d "$task_target" ]]; then
          task_resolved=$(cd "$task_target" 2>/dev/null && pwd -P) || continue
          [[ "$task_resolved" == "$TASKS_CANON/"* ]] || continue
        fi
        if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
          orphans_cleaned=$((orphans_cleaned + 1))
          [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: DRY RUN: would auto-clean 24h+ unstamped orphan: ${oname}" >> "${_RUNE_TRACE_PATH}"
        else
          rm -rf "$team_target/" "$task_target/" 2>/dev/null
          orphans_cleaned=$((orphans_cleaned + 1))
          [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: auto-cleaned 24h+ unstamped orphan: ${oname}" >> "${_RUNE_TRACE_PATH}"
        fi
      fi
      continue
    fi

    # Read .session content (max 4KB safety cap)
    session_content=$(head -c 4096 "$session_file" 2>/dev/null || true)
    [[ -z "$session_content" ]] && continue

    owner_pid=""
    owner_cfg=""
    marker_session=""

    # Extract fields — handle both JSON and plain string formats
    if echo "$session_content" | jq -e '.' >/dev/null 2>&1; then
      # JSON format: {"session_id":"...","config_dir":"...","owner_pid":"..."}
      owner_pid=$(echo "$session_content" | jq -r '.owner_pid // empty' 2>/dev/null || true)
      owner_cfg=$(echo "$session_content" | jq -r '.config_dir // empty' 2>/dev/null || true)
      marker_session=$(echo "$session_content" | jq -r '.session_id // empty' 2>/dev/null || true)
    fi
    # Plain string format has no structured data — skip (can't verify ownership)
    [[ -n "$owner_pid" && "$owner_pid" =~ ^[0-9]+$ ]] || continue

    # Rule (b): session_id MUST match current session — NEVER touch other sessions' teams.
    # Even if their PID is dead, the user may want to inspect or manually recover.
    if [[ -z "$marker_session" ]] || [[ "$marker_session" != "$HOOK_SESSION_ID" ]]; then
      continue
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
    # XVER-001: Verify delete targets resolve under canonical CHOME before rm -rf
    team_target="$CHOME/teams/${oname}"
    task_target="$CHOME/tasks/${oname}"

    # Skip if target is a symlink (defense-in-depth)
    [[ -L "$team_target" ]] && continue

    # Verify resolved paths are under canonical roots
    if [[ -d "$team_target" ]]; then
      team_resolved=$(cd "$team_target" 2>/dev/null && pwd -P) || continue
      [[ "$team_resolved" == "$TEAMS_CANON/"* ]] || continue
    fi
    if [[ -d "$task_target" ]]; then
      task_resolved=$(cd "$task_target" 2>/dev/null && pwd -P) || continue
      [[ "$task_resolved" == "$TASKS_CANON/"* ]] || continue
    fi

    if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
      orphans_cleaned=$((orphans_cleaned + 1))
      [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: DRY RUN: would auto-clean orphan: ${oname} (dead PID ${owner_pid})" >> "${_RUNE_TRACE_PATH}"
      continue
    fi
    rm -rf "$team_target/" "$task_target/" 2>/dev/null
    orphans_cleaned=$((orphans_cleaned + 1))
    [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: auto-cleaned orphan: ${oname} (dead PID ${owner_pid})" >> "${_RUNE_TRACE_PATH}"
  done
fi

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphans auto-cleaned: ${orphans_cleaned}" >> "${_RUNE_TRACE_PATH}"

# ── Stale heartbeat detection (advisory only) ──
# Scans tmp/arc/*/heartbeat.json for heartbeats whose owner_pid is dead,
# indicating a crashed arc session. Reports to stderr — does NOT auto-cleanup.
_scan_stale_heartbeats() {
  local cwd="$1"
  local hb_dir="${cwd}/tmp/arc"
  [[ -d "$hb_dir" ]] || return 0

  # Read stale threshold from talisman arc shard (default: 15 minutes)
  local stale_threshold_min=15
  local talisman_shard="${cwd}/tmp/.talisman-resolved/arc.json"
  if [[ -f "$talisman_shard" ]] && [[ ! -L "$talisman_shard" ]]; then
    local talisman_val
    talisman_val=$(jq -r '.heartbeat.stale_threshold_minutes // 15' "$talisman_shard" 2>/dev/null || echo "15")
    if [[ "$talisman_val" =~ ^[0-9]+$ ]]; then
      stale_threshold_min="$talisman_val"
      # Clamp to [5, 120]
      [[ "$stale_threshold_min" -lt 5 ]] && stale_threshold_min=5
      [[ "$stale_threshold_min" -gt 120 ]] && stale_threshold_min=120
    fi
  fi

  local stale_threshold_sec=$(( stale_threshold_min * 60 ))
  local now_epoch
  now_epoch=$(date +%s)
  local stale_hb_count=0

  shopt -s nullglob 2>/dev/null || true
  for hb_file in "$hb_dir"/*/heartbeat.json; do
    [[ -f "$hb_file" ]] || continue
    [[ -L "$hb_file" ]] && continue

    # Extract fields from heartbeat JSON
    local hb_arc_id hb_last_activity hb_owner_pid hb_nonce hb_config_dir hb_session_id
    hb_arc_id=$(jq -r '.arc_id // empty' "$hb_file" 2>/dev/null || true)
    hb_last_activity=$(jq -r '.last_activity // empty' "$hb_file" 2>/dev/null || true)
    hb_owner_pid=$(jq -r '.owner_pid // empty' "$hb_file" 2>/dev/null || true)
    hb_nonce=$(jq -r '.nonce // empty' "$hb_file" 2>/dev/null || true)
    hb_config_dir=$(jq -r '.config_dir // empty' "$hb_file" 2>/dev/null || true)
    hb_session_id=$(jq -r '.session_id // empty' "$hb_file" 2>/dev/null || true)

    # Skip if missing critical fields
    [[ -n "$hb_arc_id" && "$hb_arc_id" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
    [[ -n "$hb_last_activity" ]] || continue

    # AC-3.4: Session isolation — skip heartbeats from different config_dir (installation isolation)
    if [[ -n "$hb_config_dir" && "$hb_config_dir" != "$CHOME" ]]; then
      continue
    fi

    # Parse last_activity timestamp to epoch
    local hb_epoch
    hb_epoch=$(_parse_iso_epoch "$hb_last_activity" 2>/dev/null || echo "0")
    [[ "$hb_epoch" =~ ^[0-9]+$ ]] || hb_epoch=0

    # Calculate elapsed time
    local elapsed=$(( now_epoch - hb_epoch ))
    [[ "$elapsed" -lt 0 ]] && elapsed=0

    # Check staleness: elapsed > threshold AND owner_pid is dead
    if [[ "$elapsed" -gt "$stale_threshold_sec" ]]; then
      # If owner_pid is present and valid, check liveness
      if [[ -n "$hb_owner_pid" && "$hb_owner_pid" =~ ^[0-9]+$ ]]; then
        # SEC-008: Skip sentinel PIDs
        [[ "$hb_owner_pid" == "0" || "$hb_owner_pid" == "1" ]] && continue
        # Owner alive → not stale (active session, just slow)
        if rune_pid_alive "$hb_owner_pid"; then
          continue
        fi
      fi

      # Advisory: emit warning to stderr
      local elapsed_min=$(( elapsed / 60 ))
      printf 'WARN: TLC-003: stale heartbeat detected — arc_id=%s, last_activity=%s (%d min ago), owner_pid=%s (dead), nonce=%s\n' \
        "$hb_arc_id" "$hb_last_activity" "$elapsed_min" "${hb_owner_pid:-unknown}" "${hb_nonce:-unknown}" >&2
      stale_hb_count=$((stale_hb_count + 1))
    fi
  done
  shopt -u nullglob 2>/dev/null || true

  [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && \
    echo "[$(date '+%H:%M:%S')] TLC-003: stale heartbeats found: ${stale_hb_count} (threshold: ${stale_threshold_min}m)" >> "${_RUNE_TRACE_PATH}"
}

_scan_stale_heartbeats "$CWD"

# ── Kill orphan teammate processes on resume ──
# Same pattern as on-session-stop.sh Phase 0 (_kill_stale_teammates), but scoped to
# dead owner PIDs found in state files. On crash-resume, teammate processes from the
# prior session may still be running as children of the now-dead Claude Code process.
orphan_procs_killed=0
if [[ -d "${CWD}/tmp" ]]; then
  # Collect dead owner PIDs from active state files
  dead_pids=()
  shopt -s nullglob 2>/dev/null
  for sf in "${CWD}/tmp"/.rune-*.json; do
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
      # MCP-PROTECT-001: Skip MCP/LSP servers (broad pattern — --stdio, --lsp, mcp-*, mcp_*)
      child_args=$(ps -p "$cpid" -o args= 2>/dev/null || true)
      case "$child_args" in *--stdio*|*--lsp*|*mcp-*|*mcp_*|*python*mcp*|*@anthropic*connector*) continue ;; esac
      if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
        orphan_procs_killed=$((orphan_procs_killed + 1))
        [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: DRY RUN: would kill orphan PID=$cpid (comm=$child_comm)" >> "${_RUNE_TRACE_PATH}"
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

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphan processes killed: ${orphan_procs_killed}" >> "${_RUNE_TRACE_PATH}"

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
  for f in "${CWD}"/tmp/.rune-review-*.json "${CWD}"/tmp/.rune-audit-*.json "${CWD}"/tmp/.rune-work-*.json "${CWD}"/tmp/.rune-mend-*.json "${CWD}"/tmp/.rune-inspect-*.json "${CWD}"/tmp/.rune-plan-*.json "${CWD}"/tmp/.rune-forge-*.json "${CWD}"/tmp/.rune-goldmask-*.json "${CWD}"/tmp/.rune-brainstorm-*.json "${CWD}"/tmp/.rune-debug-*.json "${CWD}"/tmp/.rune-design-sync-*.json "${CWD}"/tmp/.rune-codex-review-*.json "${CWD}"/tmp/.rune-resolve-todos-*.json "${CWD}"/tmp/.rune-self-audit-*.json; do
    if [[ -f "$f" ]]; then
      # Check if status is "active" and file is older than 30 min
      # FIX-2: Fallback to epoch 0 (Jan 1 1970) if stat fails. Math: (NOW - 0) / 60 = ~29M minutes
      # = always triggers stale (>30 min). Forge suggested 999999999 but that's wrong: (NOW - 999999999)
      # could be small for timestamps near 2001. Epoch 0 is the safe default.
      # BACK-002 NOTE: macOS stat -f first, then Linux stat -c, then epoch-0 (assume stale)
      file_mtime=$(_stat_mtime "$f"); file_mtime="${file_mtime:-0}"
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

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: stale state files found: ${stale_state_count}" >> "${_RUNE_TRACE_PATH}"

# Count orphaned arc checkpoints (v1.110.0: Bug 2 fix)
# Scan ${RUNE_STATE}/arc/ and tmp/arc/ for checkpoints with dead owner_pid
# v1.174.0: Also scan worktree checkpoint directories (.claude/worktrees/*/.rune/arc/)
# so orphaned worktree arc checkpoints are visible from the main repo session.
# NOTE: Claude Code SDK creates worktrees at .claude/worktrees/ (not .rune/worktrees/).
orphan_checkpoint_count=0
orphan_checkpoint_count=$(
  count=0
  # Build scan dirs: project root + any worktree ${RUNE_STATE}/arc/ directories
  scan_dirs=("${CWD}/${RUNE_STATE}/arc" "${CWD}/.claude/arc" "${CWD}/tmp/arc")
  # Add worktree checkpoint dirs (worktrees are at .claude/worktrees/*/)
  # SEC-S8-002 FIX: Reject symlinks on worktree dirs (parity with team dir scanning at line 108)
  shopt -s nullglob 2>/dev/null || true
  for wt_dir in "${CWD}/.claude/worktrees"/*/${RUNE_STATE}/arc; do
    [[ -d "$wt_dir" ]] || continue
    [[ -L "$wt_dir" ]] && continue  # symlink rejection
    # SEC-S8-001: path traversal guard on worktree dir name
    [[ "$wt_dir" == *".."* ]] && continue
    wt_base="${wt_dir%/${RUNE_STATE}/arc}"  # no `local` — we're in a subshell, not a function
    [[ -L "$wt_base" ]] && continue  # reject symlinked worktree root
    scan_dirs+=("$wt_dir")
  done
  for ckpt_dir in "${scan_dirs[@]}"; do
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

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphaned checkpoints found: ${orphan_checkpoint_count}" >> "${_RUNE_TRACE_PATH}"

# ── Stale checkpoint archival (48h TTL for incomplete arcs) ──
# Moves checkpoints with no completed_at that are older than 48h to archived/
# Non-destructive — archived checkpoints can be manually restored (AC-3)
stale_archived_count=0
STALE_THRESHOLD=$((48 * 3600))  # 48 hours in seconds
NOW_ARCHIVE=$(date +%s)
for ckpt_dir in "${CWD}/${RUNE_STATE}/arc" "${CWD}/.claude/arc"; do
  [[ -d "$ckpt_dir" ]] || continue
  ARCHIVE_DIR="${ckpt_dir}/archived"
  shopt -s nullglob 2>/dev/null || true
  for ckpt in "$ckpt_dir"/*/checkpoint.json; do
    [[ -f "$ckpt" ]] && [[ ! -L "$ckpt" ]] || continue
    # Skip if already in archived/
    [[ "$ckpt" == */archived/* ]] && continue
    # Skip if completed
    completed=$(jq -r '.completed_at // empty' "$ckpt" 2>/dev/null || true)
    [[ -n "$completed" ]] && continue
    # Check age
    ckpt_mtime=$(_stat_mtime "$ckpt"); ckpt_mtime="${ckpt_mtime:-0}"
    age=$(( NOW_ARCHIVE - ckpt_mtime ))
    if [[ "$age" -gt "$STALE_THRESHOLD" ]]; then
      arc_dir=$(dirname "$ckpt")
      # XVER-001: Reject symlinked arc directories before mv
      [[ -L "$arc_dir" ]] && continue
      arc_id=$(basename "$arc_dir")
      # SEC-006: Validate arc_id before use in paths
      [[ "$arc_id" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
      [[ "$arc_id" == *".."* ]] && continue
      if [[ "${RUNE_CLEANUP_DRY_RUN:-0}" == "1" ]]; then
        stale_archived_count=$((stale_archived_count + 1))
        [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: DRY RUN: would archive stale checkpoint: $arc_id (age: $((age/3600))h)" >> "${_RUNE_TRACE_PATH}"
      else
        mkdir -p "$ARCHIVE_DIR"
        mv "$arc_dir" "$ARCHIVE_DIR/$arc_id" 2>/dev/null && stale_archived_count=$((stale_archived_count + 1))
        [[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: archived stale checkpoint: $arc_id (age: $((age/3600))h)" >> "${_RUNE_TRACE_PATH}"
      fi
    fi
  done
done

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: stale checkpoints archived: ${stale_archived_count}" >> "${_RUNE_TRACE_PATH}"

# ── Layer 2: Resumable arc detection — REMOVED (v1.156.0) ──
# Previously detected interrupted arcs and injected an advisory message into
# additionalContext ("ARC CRASH RECOVERY: ... Resume: /rune:arc --resume").
# BUG: The advisory was interpreted by Claude as a directive, causing automatic
# arc resume without user consent. The advisory also did not update owner_pid
# or session_id in the state file, leading to stale ownership data.
# Fix: Removed entirely. Users must explicitly run /rune:arc --resume to resume
# interrupted arcs. Orphaned arc state files are still cleaned up by the Stop
# hook's validate_session_ownership() orphan handler.
# Replacement: SKILL.md pre-flight conflict detection (Decision Matrix 1, F4)

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

[[ "${RUNE_TRACE:-}" == "1" ]] && [[ ! -L "${_RUNE_TRACE_PATH}" ]] && echo "[$(date '+%H:%M:%S')] TLC-003: orphaned worktrees found: ${orphaned_wt_count}" >> "${_RUNE_TRACE_PATH}"

# Report if anything found
# BACK-007 FIX: Conditionally append orphan list to avoid trailing "Orphans: " with no names
remaining_orphans=$((orphan_count - orphans_cleaned))
if [[ $remaining_orphans -gt 0 ]] || [[ $stale_state_count -gt 0 ]] || [[ $orphan_checkpoint_count -gt 0 ]] || [[ $orphaned_wt_count -gt 0 ]] || [[ $orphans_cleaned -gt 0 ]] || [[ $orphan_procs_killed -gt 0 ]] || [[ $stale_archived_count -gt 0 ]]; then
  msg="TLC-003 SESSION HYGIENE:"
  if [[ $orphans_cleaned -gt 0 ]]; then
    msg+=" Auto-cleaned ${orphans_cleaned} PID-dead orphan(s)."
  fi
  if [[ $orphan_procs_killed -gt 0 ]]; then
    msg+=" Killed ${orphan_procs_killed} orphan teammate process(es)."
  fi
  if [[ $stale_archived_count -gt 0 ]]; then
    msg+=" Archived ${stale_archived_count} stale checkpoint(s) (>48h incomplete)."
  fi
  if [[ $remaining_orphans -gt 0 ]] || [[ $stale_state_count -gt 0 ]] || [[ $orphan_checkpoint_count -gt 0 ]] || [[ $orphaned_wt_count -gt 0 ]]; then
    msg+=" Found ${remaining_orphans} orphaned team dir(s), ${stale_state_count} stale state file(s), ${orphan_checkpoint_count} orphaned checkpoint(s), and ${orphaned_wt_count} orphaned worktree(s) from prior sessions. Run /rune:rest --heal to clean up."
  fi
  if [[ ${#orphan_names[@]} -gt 0 ]] && [[ $remaining_orphans -gt 0 ]]; then
    msg+=" Orphans: ${orphan_names[*]:0:5}"
  fi
  _HOOK_JSON_SENT=true
  jq -n --arg ctx "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0
