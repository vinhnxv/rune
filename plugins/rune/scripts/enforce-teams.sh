#!/bin/bash
# scripts/enforce-teams.sh
# ATE-1: Enforce Agent Teams usage during active Rune multi-agent workflows.
# Blocks bare Agent/Task calls (without team_name) when an arc/review/audit/work
# workflow is active. Prevents context explosion from subagent output flowing
# into the orchestrator's context window.
#
# NOTE: Claude Code 2.1.63 renamed the "Task" tool to "Agent". This script
# handles both names for backward compatibility.
#
# Detection strategy:
#   1. Check if tool_name is "Task" or "Agent" (only tools this hook targets)
#   2. Check for active Rune workflow via state files:
#      - ${RUNE_STATE}/arc/*/checkpoint.json with "in_progress" phase
#      - tmp/.rune-{review,audit,work,inspect,mend,plan,forge,goldmask,
#        brainstorm,debug,design-sync}-*.json with "active" status
#   3. If active workflow found, verify Task input includes team_name
#   4. Block if team_name missing — output deny JSON
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON (or with permissionDecision="allow") = tool call allowed.
# Exit 2 = hook error, stderr fed to Claude (not used by this script).

set -euo pipefail
umask 077

# --- Fail-closed guard (SECURITY-ADJACENT hook) ---
# SEC-001 FIX: ATE-1 enforcement is security-adjacent — crash mid-validation
# MUST block the operation (exit 2), not silently allow it (exit 0).
# A fail-open crash here allows bare Agent/Task calls → context explosion.
_rune_fail_closed() {
  printf 'ERROR: %s: ERR trap — fail-closed activated (line %s). ATE-1 blocking operation.\n' \
    "${BASH_SOURCE[0]##*/}" \
    "${BASH_LINENO[0]:-?}" \
    >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-${UID:-$(id -u)}.log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-closed activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 2
}
trap '_rune_fail_closed' ERR

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read

# VEIL-002 FIX: grep-based fast-path BEFORE jq availability check.
# If the input contains a non-empty "team_name", the Agent/Task call already has what we need — allow it.
# FLAW-017 FIX: Previous pattern `grep -q '"team_name"'` matched empty values ("team_name": ""),
# allowing bare Agent calls to bypass enforcement. Now requires at least one non-quote char.
if printf '%s' "$INPUT" | grep -qE '"team_name"[[:space:]]*:[[:space:]]*"[^"]+"'; then
  exit 0
fi

# Pre-flight: jq is required for JSON parsing.
# If missing, exit 2 (fail-closed) — consistent with _rune_fail_closed ERR trap.
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found — enforce-teams.sh requires jq (fail-closed)" >&2
  exit 2
fi

# Fast path: if caller is team-lead (not subagent), check for team_name in input.
# Team leads MUST also use team_name — this is the whole point of ATE-1.
# Note: Claude Code 2.1.63 renamed Task → Agent. Both are checked below.

# BACK-003 FIX: Use printf instead of echo to avoid flag interpretation if $INPUT starts with '-'
# Claude Code 2.1.63+ renamed "Task" → "Agent". Match both for backward compat.
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Task" && "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

# QUAL-5: Canonicalize CWD to resolve symlinks (matches on-task-completed.sh pattern)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# ── Early AGENT_NAME extraction (before workflow detection) ──
# Extract agent name once — reused by non-Rune exemption and Signal 4.
AGENT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || true)

# ── Source shared agent registry ──
SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "${SCRIPT_DIR_LIB}/lib/known-rune-agents.sh" ]]; then
  # shellcheck source=lib/known-rune-agents.sh
  source "${SCRIPT_DIR_LIB}/lib/known-rune-agents.sh"
fi

# Check for active Rune workflows
# TOCTOU MITIGATION (XVER-001 FIX): Use directory-based mutex for atomic state detection.
# mkdir is atomic on POSIX systems — if another workflow starts during this check,
# the mutex acquisition will fail and we'll see the new state file.
#
# STALENESS GUARD (v1.61.0): Skip files older than STALE_THRESHOLD_MIN (mtime-based).
# Stale checkpoints from crashed/interrupted sessions should not block new work.
# STALE THRESHOLD CROSS-REFERENCE:
#   TLC-001 enforce-team-lifecycle.sh: 30 min (team DIRS, PreToolUse:TeamCreate)
#   TLC-003 session-team-hygiene.sh:   30 min (team DIRS, SessionStart)
#   ATE-1  enforce-teams.sh:          120 min (STATE FILES, PreToolUse:Agent — this file)
#   CDX-7  detect-workflow-complete.sh: 150 min (LOOP FILES, Stop hook)
# 120 min here — longer than TLC-001 (30 min) to support long-running arc phases.
# These operate on different file types so direct conflict is minimal.
STALE_THRESHOLD_MIN=120
# Signal 2 inscription staleness: tighter than Signal 1's 120 min.
# Inscriptions are per-phase — they age out quickly. 30 min handles the 30-120 min
# window where Signal 1's threshold misses stale inscriptions from crashed sessions.
INSCR_STALE_MIN=30
active_workflow=""
detected_team_name=""   # team name inferred from non-state-file signals
detected_source=""      # which signal triggered detection (state-file|inscription|signal-dir|agent-name)

# XVER-001 FIX: Acquire mutex for atomic workflow detection
# This prevents race condition where workflow starts between check and Agent execution
# Only use mutex when tmp/ directory exists (otherwise no workflow can be active)
MUTEX_DIR="${CWD}/tmp/.rune-ate1-mutex"
MUTEX_HELD=false
_rune_release_ate1_mutex() {
  if [[ "$MUTEX_HELD" == "true" ]]; then
    rmdir "$MUTEX_DIR" 2>/dev/null || true
    MUTEX_HELD=false
  fi
}

# Only acquire mutex if tmp/ exists (no tmp = no possible workflow)
if [[ -d "${CWD}/tmp" ]]; then
  trap '_rune_release_ate1_mutex' EXIT
  # Try to acquire mutex (mkdir is atomic)
  if mkdir "$MUTEX_DIR" 2>/dev/null; then
    MUTEX_HELD=true
  else
    # Mutex held by another process — check if stale (SIGKILL crash recovery)
    # A hook should never take >60s; stale mutex = crashed process left it behind
    # XBUG-002 FIX: Use atomic mv to claim stale mutex, eliminating TOCTOU race.
    # Race window was: find → rmdir → mkdir (another process could claim between)
    # Now: mv atomically transfers ownership, then we clean up the renamed dir.
    if find "$MUTEX_DIR" -maxdepth 0 -mmin +1 -print -quit 2>/dev/null | grep -q .; then
      _stale_mutex="${MUTEX_DIR}.stale.$$"
      if mv "$MUTEX_DIR" "$_stale_mutex" 2>/dev/null; then
        # We now own the stale mutex (renamed). Clean it up and create fresh.
        rm -rf "$_stale_mutex" 2>/dev/null || true
        if mkdir "$MUTEX_DIR" 2>/dev/null; then
          MUTEX_HELD=true
        fi
      fi
    fi
    # If still not acquired, brief wait and retry once
    if [[ "$MUTEX_HELD" != "true" ]]; then
      sleep 0.1 2>/dev/null || true
      if mkdir "$MUTEX_DIR" 2>/dev/null; then
        MUTEX_HELD=true
      else
        # Another workflow is actively transitioning — treat as active workflow detected
        # This is the safe (fail-closed) behavior
        active_workflow=1
        detected_source="mutex-contention"
      fi
    fi
  fi
fi

# ── Session identity for cross-session ownership filtering ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=resolve-session-identity.sh
# SEC-001/VEIL-005 FIX: Guard against missing resolve-session-identity.sh.
# Without this guard, a missing file triggers the ERR trap which exits 0,
# leaving RUNE_CURRENT_CFG unset and silently allowing bare Agent/Task calls.
if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
  source "${SCRIPT_DIR}/lib/rune-state.sh"
else
  # FLAW-007 FIX: Fail-closed when identity script is missing.
  # Previous behavior: rune_pid_alive() { return 1; } treated ALL PIDs as dead,
  # causing ALL state files to be processed regardless of ownership — cross-session interference.
  # Now: deny the tool call so the user sees a clear error instead of silent mis-ownership.
  printf '[%s] enforce-teams.sh: CRITICAL — resolve-session-identity.sh not found at %s\n' \
    "$(date +%H:%M:%S 2>/dev/null || true)" "${SCRIPT_DIR}" >&2
  printf 'Session ownership filtering unavailable — blocking to prevent cross-session interference.\n' >&2
  exit 2
fi

# Check arc checkpoints (skip stale files older than STALE_THRESHOLD_MIN)
if [[ -d "${CWD}/${RUNE_STATE}/arc" ]]; then
  while IFS= read -r f; do
    if jq -e '(.phase_status // .phase // .status // "none" | . == "in_progress") or ([.phases[]?.status] | any(. == "in_progress"))' "$f" &>/dev/null; then
      # ── Ownership filter: skip checkpoints from other sessions (XVER-004 FIX: 3-layer) ──
      stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      stored_sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # Layer 1: config dir mismatch → different installation
      if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      # Layer 2: session_id primary — definitive match/mismatch
      if [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" ]]; then
        [[ "$stored_sid" == "$RUNE_CURRENT_SID" ]] || continue  # different session
      else
        # Layer 3: PID fallback when session_id unavailable
        if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
          rune_pid_alive "$stored_pid" && continue  # alive = different session
        fi
      fi
      active_workflow=1
      detected_source="state-file"
      # CDX-GAP-002 FIX: Extract team_name from arc checkpoint for recovery context
      local_team_name=$(jq -r '.phases.work.team_name // empty' "$f" 2>/dev/null || true)
      if [[ -n "$local_team_name" ]]; then
        detected_team_name="$local_team_name"
      fi
      break
    fi
  done < <(find "${CWD}/${RUNE_STATE}/arc" -name checkpoint.json -maxdepth 2 -type f -mmin -${STALE_THRESHOLD_MIN} 2>/dev/null)
fi

# Check review/audit/work state files (skip stale files)
# SEC-1 FIX: Use nullglob + flattened loop to prevent word splitting on paths with spaces
if [[ -z "$active_workflow" ]]; then
  shopt -s nullglob
  for f in "${CWD}"/tmp/.rune-review-*.json "${CWD}"/tmp/.rune-audit-*.json \
           "${CWD}"/tmp/.rune-work-*.json "${CWD}"/tmp/.rune-inspect-*.json \
           "${CWD}"/tmp/.rune-mend-*.json "${CWD}"/tmp/.rune-plan-*.json \
           "${CWD}"/tmp/.rune-forge-*.json "${CWD}"/tmp/.rune-goldmask-*.json \
           "${CWD}"/tmp/.rune-brainstorm-*.json "${CWD}"/tmp/.rune-debug-*.json \
           "${CWD}"/tmp/.rune-design-sync-*.json "${CWD}"/tmp/.rune-codex-review-*.json \
           "${CWD}"/tmp/.rune-resolve-todos-*.json "${CWD}"/tmp/.rune-self-audit-*.json; do
    # Skip files older than STALE_THRESHOLD_MIN minutes
    # PERF: per-file `find -maxdepth 0 -mmin` is O(n) but safe; batch find risks glob/ownership edge cases
    if [[ -f "$f" ]] && find "$f" -maxdepth 0 -mmin -${STALE_THRESHOLD_MIN} -print -quit 2>/dev/null | grep -q . && jq -e '.status == "active"' "$f" &>/dev/null; then
      # ── Ownership filter: skip state files from other sessions (XVER-004 FIX: 3-layer) ──
      stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      stored_sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # Layer 1: config dir mismatch → different installation
      if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      # Layer 2: session_id primary — definitive match/mismatch
      if [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" ]]; then
        [[ "$stored_sid" == "$RUNE_CURRENT_SID" ]] || continue  # different session
      else
        # Layer 3: PID fallback when session_id unavailable
        if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
          rune_pid_alive "$stored_pid" && continue  # alive = different session
        fi
      fi
      active_workflow=1
      detected_source="state-file"
      # CDX-GAP-002 FIX: Extract team_name from state file for recovery context
      local_team_name=$(jq -r '.team_name // empty' "$f" 2>/dev/null || true)
      if [[ -n "$local_team_name" ]]; then
        detected_team_name="$local_team_name"
      fi
      break
    fi
  done
  shopt -u nullglob
fi

# ── Signal 2: Recent output directories with inscription.json ──
# 3-layer check: (1) direct ownership from inscription fields, (2) age-based staleness,
# (3) team .session fallback for legacy inscriptions without ownership fields.
# Catches workflows where model created output dir but skipped state file.
# INSCR_STALE_MIN (defined at file-level constants): see cross-reference at STALE_THRESHOLD_MIN.
if [[ -z "$active_workflow" ]]; then
  shopt -s nullglob
  for inscr in "${CWD}"/tmp/reviews/*/inscription.json \
               "${CWD}"/tmp/audit/*/inscription.json \
               "${CWD}"/tmp/forge/*/inscription.json \
               "${CWD}"/tmp/work/*/inscription.json \
               "${CWD}"/tmp/mend/*/inscription.json; do
    # Recency guard: skip files older than INSCR_STALE_MIN (tighter than Signal 1)
    if [[ -f "$inscr" ]] && find "$inscr" -maxdepth 0 -mmin -${INSCR_STALE_MIN} -print -quit 2>/dev/null | grep -q .; then

      # ── Layer 1: Direct ownership check from inscription.json fields (v1.167.0+) ──
      # New inscriptions include config_dir/owner_pid/session_id. Direct check avoids
      # team dir indirection that fails after TeamDelete cleans up .session files.
      inscr_cfg=$(jq -r '.config_dir // empty' "$inscr" 2>/dev/null || true)
      inscr_sid=$(jq -r '.session_id // empty' "$inscr" 2>/dev/null || true)
      inscr_pid=$(jq -r '.owner_pid // empty' "$inscr" 2>/dev/null || true)

      # Layer 1a: config dir mismatch → different installation → skip
      if [[ -n "$inscr_cfg" && -n "$RUNE_CURRENT_CFG" && "$inscr_cfg" != "$RUNE_CURRENT_CFG" ]]; then
        continue
      fi

      # Layer 1b: session_id available in both → definitive match/mismatch
      if [[ -n "$inscr_sid" && -n "$RUNE_CURRENT_SID" ]]; then
        [[ "$inscr_sid" == "$RUNE_CURRENT_SID" ]] || continue  # different session → skip
        # Same session — fall through to active_workflow=1
      elif [[ -n "$inscr_pid" && "$inscr_pid" =~ ^[0-9]+$ ]]; then
        # Layer 1c: PID fallback when session_id unavailable
        if [[ "$inscr_pid" != "$PPID" ]]; then
          if rune_pid_alive "$inscr_pid"; then
            continue  # different live session → skip
          else
            # PID dead → stale inscription from crashed session → skip
            [[ -n "${RUNE_TRACE:-}" ]] && printf '[enforce-teams] Skipping dead-PID inscription: %s (pid=%s)\n' "$inscr" "$inscr_pid" >> "${RUNE_TRACE_LOG:-/dev/null}" 2>/dev/null
            continue
          fi
        fi
        # Same PID — fall through to active_workflow=1
      fi
      # If we reach here with ownership fields set, it's our session → proceed to detect

      # ── Layer 2: Legacy fallback — team .session indirection (pre-v1.167.0 inscriptions) ──
      # Only reached when inscription lacks ownership fields (inscr_sid and inscr_pid both empty)
      if [[ -z "$inscr_sid" && -z "$inscr_pid" ]]; then
        local_team=$(jq -r '.team_name // empty' "$inscr" 2>/dev/null || true)
        if [[ -n "$local_team" ]]; then
          CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
          session_file="${CHOME}/teams/${local_team}/.session"
          if [[ -f "$session_file" ]]; then
            stored_sid=$(jq -r '.session_id // empty' "$session_file" 2>/dev/null || true)
            if [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" ]]; then
              [[ "$stored_sid" == "$RUNE_CURRENT_SID" ]] || continue  # different session
            else
              local_team_cfg="${CHOME}/teams/${local_team}/config.json"
              if [[ -f "$local_team_cfg" ]]; then
                team_owner_pid=$(jq -r '.members[0].pid // empty' "$local_team_cfg" 2>/dev/null || true)
                if [[ -n "$team_owner_pid" && "$team_owner_pid" =~ ^[0-9]+$ && "$team_owner_pid" != "$PPID" ]]; then
                  rune_pid_alive "$team_owner_pid" && continue
                fi
              fi
            fi
          else
            # No .session file AND no ownership fields → stale inscription (team already cleaned up)
            [[ -n "${RUNE_TRACE:-}" ]] && printf '[enforce-teams] Skipping orphan inscription (no .session, no ownership): %s\n' "$inscr" >> "${RUNE_TRACE_LOG:-/dev/null}" 2>/dev/null
            continue
          fi
        else
          # No team_name AND no ownership → cannot determine ownership → skip (fail-open for Signal 2)
          continue
        fi
      fi

      # Passed all ownership checks — this inscription belongs to our active session
      local_team=$(jq -r '.team_name // empty' "$inscr" 2>/dev/null || true)
      if [[ -n "$local_team" ]]; then
        active_workflow=1
        detected_team_name="$local_team"
        detected_source="inscription"
        break
      fi
    fi
  done
  shopt -u nullglob
fi

# ── Signal 3: Active signal directories ──
# Signal dirs are created by Phase 2 (Forge Team) and contain .expected count files.
# Their presence indicates an active orchestration even without state files.
if [[ -z "$active_workflow" ]]; then
  shopt -s nullglob
  for sigdir in "${CWD}"/tmp/.rune-signals/rune-*/; do
    if [[ -d "$sigdir" ]] && find "$sigdir" -maxdepth 0 -mmin -${STALE_THRESHOLD_MIN} -print -quit 2>/dev/null | grep -q .; then
      # Extract team name from directory name (tmp/.rune-signals/rune-review-abc123/ -> rune-review-abc123)
      local_team=$(basename "$sigdir")
      if [[ "$local_team" =~ ^rune-[a-zA-Z]+-[a-zA-Z0-9_-]+$ ]]; then
        # CDX-GAP-004 FIX: Session ownership check for signal directories
        CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        sig_session_file="${CHOME}/teams/${local_team}/.session"
        if [[ -f "$sig_session_file" ]]; then
          sig_stored_sid=$(jq -r '.session_id // empty' "$sig_session_file" 2>/dev/null || true)
          # XVER-004 FIX: Use pre-resolved RUNE_CURRENT_SID (consistent with Signal 1 3-layer pattern)
          # Layer 2: session_id primary — definitive match/mismatch
          if [[ -n "$sig_stored_sid" && -n "$RUNE_CURRENT_SID" ]]; then
            [[ "$sig_stored_sid" == "$RUNE_CURRENT_SID" ]] || continue  # different session
          else
            # Layer 3: PID fallback when session_id unavailable on either side
            sig_team_cfg="${CHOME}/teams/${local_team}/config.json"
            if [[ -f "$sig_team_cfg" ]]; then
              sig_team_owner_pid=$(jq -r '.members[0].pid // empty' "$sig_team_cfg" 2>/dev/null || true)
              if [[ -n "$sig_team_owner_pid" && "$sig_team_owner_pid" =~ ^[0-9]+$ && "$sig_team_owner_pid" != "$PPID" ]]; then
                rune_pid_alive "$sig_team_owner_pid" && continue  # alive = different session
              fi
            fi
          fi
        fi
        active_workflow=1
        detected_team_name="$local_team"
        detected_source="signal-dir"
        break
      fi
    fi
  done
  shopt -u nullglob
fi

# Signal 4: Agent name matching (defense-in-depth fallback).
# YAGNI-001 NOTE: This signal fires only when Signals 1-3 all miss AND the agent
# name matches the registry. Narrow scenario but provides a safety net for workflows
# that start without creating state files. Kept intentionally for defense-in-depth.
# ── Signal 4: Known Rune agent name matching ──
# If the Agent() call uses a name matching a known Rune Ash, this is a Rune workflow
# even if no state file, inscription, or signal dir exists.
# IMPORTANT: This signal does NOT set detected_team_name (we don't know which team).
# It only activates the ATE-1 block so the deny message can guide team creation.
# Uses AGENT_NAME extracted early (before workflow detection) and shared registry
# from lib/known-rune-agents.sh. Supports numbered (-1, -2) and named (-deep,
# -exhaustive) suffixes via is_known_rune_agent().
if [[ -z "$active_workflow" ]]; then
  if [[ -n "$AGENT_NAME" ]] && type -t is_known_rune_agent &>/dev/null; then
    if is_known_rune_agent "$AGENT_NAME"; then
      active_workflow=1
      detected_team_name=""
      detected_source="agent-name"
    fi
  fi
fi

# No active workflow — allow all Agent/Task calls
if [[ -z "$active_workflow" ]]; then
  exit 0
fi

# YAGNI-002 NOTE: Registry-based exemption is intentional over team_name prefix matching.
# The registry provides precise agent identification (name-level, not team-level).
# Prefix matching would miss agents spawned without a rune- prefixed team name.
# ── Non-Rune agent exemption ──
# If the Agent call uses a name that is NOT a known Rune agent, allow it through.
# This enables other plugins (and user-defined agents) to coexist with Rune
# workflows without being blocked by ATE-1 enforcement.
# Named agents only — unnamed bare Agent calls are still blocked (could be Rune).
if [[ -n "$AGENT_NAME" ]]; then
  if type -t is_known_rune_agent &>/dev/null; then
    if ! is_known_rune_agent "$AGENT_NAME"; then
      exit 0
    fi
  fi
fi

# Active workflow detected — verify Agent/Task input includes team_name
# BACK-2 FIX: Single-pass jq extraction (avoids fragile double-parse of tool_input)
HAS_TEAM_NAME=$(printf '%s\n' "$INPUT" | jq -r 'if .tool_input.team_name and (.tool_input.team_name | length > 0) then "yes" else "no" end' 2>/dev/null || echo "no")

if [[ "$HAS_TEAM_NAME" == "yes" ]]; then
  exit 0
fi

# ATE-1 EXEMPTION: Read-only built-in subagent types are safe without team_name.
# Explore (Haiku, read-only) and Plan (read-only) agents produce bounded output
# and cannot modify files — no risk of context explosion. The orchestrator needs
# these for quick codebase queries during workflow phases.
SUBAGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
if [[ "$SUBAGENT_TYPE" == "Explore" || "$SUBAGENT_TYPE" == "Plan" ]]; then
  exit 0
fi

# ── ATE-1 VIOLATION: Build intelligent recovery message ──

# Infer workflow type from detected_team_name or agent name
WORKFLOW_TYPE=""
SUGGESTED_TEAM=""

# SEC-004: Validate detected_team_name before use in recovery message
# SEC-007 FIX: Moved validation BEFORE SUGGESTED_TEAM assignment to prevent
# shell-special chars from being interpolated into RECOVERY_STEPS unvalidated.
[[ -z "$detected_team_name" || "$detected_team_name" =~ ^[a-zA-Z0-9_-]+$ ]] || detected_team_name=""

if [[ -n "$detected_team_name" ]]; then
  SUGGESTED_TEAM="$detected_team_name"
  # Extract workflow from team prefix: rune-review-xxx -> review, rune-audit-xxx -> audit
  WORKFLOW_TYPE=$(printf '%s\n' "$detected_team_name" | sed -n 's/^rune-\([a-z]*\)-.*/\1/p')
elif [[ -n "${AGENT_NAME:-}" ]]; then
  # Infer workflow from agent name -> category mapping
  # Strip numbered/named suffixes for matching: ward-sentinel-1 -> ward-sentinel
  _match_name=$(printf '%s\n' "$AGENT_NAME" | sed -E 's/(-[0-9]+|-deep|-exhaustive|-plan|-inspect|-review|-w[0-9]+)*$//')
  case "$_match_name" in
    # Review/Audit Ashes (built-in + specialist + UX + design)
    ward-sentinel|forge-warden|pattern-weaver|pattern-seer|veil-piercer|glyph-scribe|\
    knowledge-keeper|wraith-finder|void-analyzer|flaw-hunter|blight-seer|\
    simplicity-warden|runebinder|doubt-seer|ember-oracle|rune-architect|forge-keeper|\
    design-implementation-reviewer|design-system-compliance-reviewer|\
    ux-heuristic-reviewer|ux-interaction-auditor|ux-cognitive-walker|ux-flow-validator|\
    aesthetic-quality-reviewer|shard-reviewer|senior-engineer-reviewer|\
    naming-intent-analyzer|phantom-checker|phantom-warden|mimic-detector|\
    type-warden|refactor-guardian|cross-shard-sentinel|\
    agent-parity-reviewer|reference-validator|truthseer-validator|\
    python-reviewer|typescript-reviewer|rust-reviewer|php-reviewer|\
    axum-reviewer|fastapi-reviewer|django-reviewer|laravel-reviewer|\
    sqlalchemy-reviewer|ddd-reviewer|di-reviewer|tdd-compliance-reviewer)
      WORKFLOW_TYPE="review-or-audit" ;;
    # Investigation Ashes (deep review/audit + goldmask tracers)
    breach-hunter|fringe-watcher|rot-seeker|strand-tracer|decree-auditor|\
    order-auditor|truth-seeker|ember-seer|ruin-watcher|signal-watcher|\
    api-contract-tracer|business-logic-tracer|config-dependency-tracer|\
    data-layer-tracer|event-message-tracer|schema-drift-detector|\
    sediment-detector|decay-tracer|tide-watcher|\
    reality-arbiter|assumption-slayer|entropy-prophet|depth-seer)
      WORKFLOW_TYPE="review-or-audit" ;;
    # Work Ashes
    rune-smith|gap-fixer|design-sync-agent|design-iterator|storybook-fixer|\
    storybook-reviewer|deployment-verifier|todo-verifier)
      WORKFLOW_TYPE="work" ;;
    # Mend Ashes
    mend-fixer)
      WORKFLOW_TYPE="mend" ;;
    # Plan/Devise Ashes
    repo-surveyor|echo-reader|git-miner|practice-seeker|lore-scholar|\
    flow-seer|scroll-reviewer|decree-arbiter|research-verifier|\
    evidence-verifier|veil-piercer-plan|horizon-sage|elicitation-sage|\
    ux-pattern-analyzer|state-weaver|codex-researcher|codex-plan-reviewer|\
    design-analyst|design-inventory-agent)
      WORKFLOW_TYPE="plan" ;;
    # Inspect Ashes
    grace-warden|sight-oracle|ruin-prophet|vigil-keeper|verdict-binder)
      WORKFLOW_TYPE="inspect" ;;
    # Goldmask Ashes
    goldmask-coordinator|lore-analyst|wisdom-sage)
      WORKFLOW_TYPE="goldmask" ;;
    # Test Ashes
    test-runner|unit-test-runner|integration-test-runner|extended-test-runner|\
    e2e-browser-tester|trial-forger|trial-oracle|test-failure-analyst|\
    contract-validator)
      WORKFLOW_TYPE="test" ;;
    # Codex Ashes
    codex-oracle|codex-phase-handler|codex-arena-judge)
      WORKFLOW_TYPE="codex" ;;
    # Debug Ashes
    hypothesis-investigator)
      WORKFLOW_TYPE="debug" ;;
    # Aggregation
    tome-digest)
      WORKFLOW_TYPE="utility" ;;
    *)
      WORKFLOW_TYPE="unknown" ;;
  esac
fi

# SEC-003 FIX: Build recovery steps without bash interpolation of SUGGESTED_TEAM.
# The team name is passed via jq --arg below for safe escaping.
#
# ATE-1-RECOVERY FIX: Three-tier recovery messages:
#   (A) SUGGESTED_TEAM known → manual team steps with specific team name
#   (B) Signal 4 (agent-name, no active workflow) → suggest the correct /rune:* skill
#   (C) Fallback → generic manual team steps
if [[ -n "$SUGGESTED_TEAM" ]]; then
  # (A) Active workflow with known team name — guide manual team creation
  RECOVERY_STEPS="STOP. Do NOT write a state file — that does not create a team. Do NOT retry Agent() immediately. Follow these steps EXACTLY: Step 1: Read the phase reference file from the checkpoint to find the correct algorithm. Step 2: Call TeamCreate({ team_name: '${SUGGESTED_TEAM}' }) — this is the SDK call that registers the team. Step 3: Call TaskCreate() for each agent you plan to spawn. Step 4: THEN retry Agent() calls with team_name: '${SUGGESTED_TEAM}' on each call."
elif [[ "$detected_source" == "agent-name" ]]; then
  # (B) Signal 4: No active workflow, just a bare Agent() with a Rune agent name.
  # The LLM is trying to manually orchestrate instead of using the proper skill.
  # Map WORKFLOW_TYPE to the correct /rune:* skill suggestion.
  _suggested_skill=""
  case "$WORKFLOW_TYPE" in
    review-or-audit) _suggested_skill="/rune:appraise (for code review) or /rune:audit (for full codebase audit)" ;;
    work)            _suggested_skill="/rune:strive <plan-file>" ;;
    mend)            _suggested_skill="/rune:mend <TOME-file>" ;;
    plan)            _suggested_skill="/rune:devise" ;;
    inspect)         _suggested_skill="/rune:inspect <plan-file>" ;;
    goldmask)        _suggested_skill="/rune:goldmask" ;;
    debug)           _suggested_skill="/rune:debug" ;;
    test)            _suggested_skill="/rune:arc (test phase runs within arc pipeline)" ;;
    codex)           _suggested_skill="/rune:codex-review" ;;
    *)               _suggested_skill="/rune:appraise, /rune:audit, or the appropriate /rune:* workflow skill" ;;
  esac
  RECOVERY_STEPS="STOP. Do NOT spawn Rune agents directly with bare Agent() calls. You MUST use the proper Rune workflow skill instead: ${_suggested_skill}. The skill handles TeamCreate, TaskCreate, and Agent orchestration automatically. Do NOT attempt to create teams manually — invoke the Skill() tool with the correct /rune:* command."
else
  # (C) Fallback: active workflow detected but no team name known
  RECOVERY_STEPS="STOP. Do NOT write a state file — that does not create a team. Do NOT retry Agent() immediately. Follow these steps EXACTLY: Step 1: Read the phase reference file from the checkpoint to find the correct team name and algorithm. Step 2: Call TeamCreate({ team_name: 'the-team-name-from-reference' }) — this is the SDK call that registers the team. Step 3: Call TaskCreate() for each agent you plan to spawn. Step 4: THEN retry Agent() calls with the team_name parameter on each call."
fi

# Output deny with recovery instructions
jq -n \
  --arg src "${detected_source:-unknown}" \
  --arg team "${SUGGESTED_TEAM:-}" \
  --arg wf "${WORKFLOW_TYPE:-unknown}" \
  --arg recovery "$RECOVERY_STEPS" \
  --arg agent_name "${AGENT_NAME:-}" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("ATE-1: Bare Agent call blocked. Detected active Rune workflow via " + $src + ". You MUST use Agent Teams."),
      additionalContext: ("BLOCKED by enforce-teams.sh (ATE-1). Detection source: " + $src + ". Workflow type: " + $wf + ". Agent name: " + $agent_name + ". RECOVERY: " + $recovery + " CRITICAL: Writing a JSON state file is NOT the same as calling TeamCreate. You must call the TeamCreate tool first. A state file alone will not unblock Agent calls.")
    }
  }' 2>/dev/null && exit 0

# Fallback: static deny (jq failed)
cat << 'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "ATE-1: Bare Agent call blocked during active Rune workflow. Call TeamCreate first, then add team_name to Agent call.",
    "additionalContext": "BLOCKED by enforce-teams.sh. RECOVERY: STOP — do NOT write a state file (it does NOT create a team). 1) Read the phase reference file for the correct algorithm, 2) Call TeamCreate({ team_name: 'rune-WORKFLOW-TIMESTAMP' }), 3) Call TaskCreate() for each agent, 4) Retry Agent() with team_name parameter."
  }
}
DENY_JSON
exit 0
