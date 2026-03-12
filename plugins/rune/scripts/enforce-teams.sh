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
#      - .claude/arc/*/checkpoint.json with "in_progress" phase
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

# Claude Code 2.1.69+: agent_type/agent_id identify the calling agent (diagnostic/trace).
# Not used for control flow — team_name prefix matching remains the primary mechanism.
AGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)
AGENT_ID=$(printf '%s\n' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)

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
    if find "$MUTEX_DIR" -maxdepth 0 -mmin +1 -print -quit 2>/dev/null | grep -q .; then
      rmdir "$MUTEX_DIR" 2>/dev/null || rm -rf "$MUTEX_DIR" 2>/dev/null
      if mkdir "$MUTEX_DIR" 2>/dev/null; then
        MUTEX_HELD=true
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
if [[ -d "${CWD}/.claude/arc" ]]; then
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
  done < <(find "${CWD}/.claude/arc" -name checkpoint.json -maxdepth 2 -type f -mmin -${STALE_THRESHOLD_MIN} 2>/dev/null)
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
           "${CWD}"/tmp/.rune-design-sync-*.json; do
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
# Catches workflows where model created output dir but skipped state file.
# Performance: find -maxdepth 3 with -mmin -30 is bounded and fast (~3ms).
if [[ -z "$active_workflow" ]]; then
  shopt -s nullglob
  for inscr in "${CWD}"/tmp/reviews/*/inscription.json \
               "${CWD}"/tmp/audit/*/inscription.json \
               "${CWD}"/tmp/forge/*/inscription.json \
               "${CWD}"/tmp/work/*/inscription.json \
               "${CWD}"/tmp/mend/*/inscription.json; do
    # Recency guard: skip files older than 30 min
    if [[ -f "$inscr" ]] && find "$inscr" -maxdepth 0 -mmin -${STALE_THRESHOLD_MIN} -print -quit 2>/dev/null | grep -q .; then
      # Ownership filter: read team_name from inscription, check if team config has session marker
      local_team=$(jq -r '.team_name // empty' "$inscr" 2>/dev/null || true)
      if [[ -n "$local_team" ]]; then
        CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        session_file="${CHOME}/teams/${local_team}/.session"
        if [[ -f "$session_file" ]]; then
          stored_sid=$(jq -r '.session_id // empty' "$session_file" 2>/dev/null || true)
          # XVER-004 FIX: Use pre-resolved RUNE_CURRENT_SID (consistent with Signal 1 3-layer pattern)
          # Layer 2: session_id primary — definitive match/mismatch
          if [[ -n "$stored_sid" && -n "$RUNE_CURRENT_SID" ]]; then
            [[ "$stored_sid" == "$RUNE_CURRENT_SID" ]] || continue  # different session
          else
            # Layer 3: PID fallback when session_id unavailable on either side
            local_team_cfg="${CHOME}/teams/${local_team}/config.json"
            if [[ -f "$local_team_cfg" ]]; then
              team_owner_pid=$(jq -r '.members[0].pid // empty' "$local_team_cfg" 2>/dev/null || true)
              if [[ -n "$team_owner_pid" && "$team_owner_pid" =~ ^[0-9]+$ && "$team_owner_pid" != "$PPID" ]]; then
                rune_pid_alive "$team_owner_pid" && continue  # alive = different session
              fi
            fi
          fi
        fi
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
  case "$AGENT_NAME" in
    ward-sentinel|forge-warden|pattern-weaver|veil-piercer|glyph-scribe|knowledge-keeper|wraith-finder|void-analyzer|flaw-hunter|blight-seer|simplicity-warden|runebinder)
      WORKFLOW_TYPE="review-or-audit" ;;
    rune-smith*|gap-fixer*|design-sync-agent|design-iterator|storybook-*)
      WORKFLOW_TYPE="work" ;;
    mend-fixer*)
      WORKFLOW_TYPE="mend" ;;
    repo-surveyor|echo-reader|git-miner|practice-seeker|lore-scholar|flow-seer|scroll-reviewer|decree-arbiter|research-verifier)
      WORKFLOW_TYPE="plan" ;;
    tome-digest|condenser-gap|condenser-plan|condenser-verdict|condenser-work)
      WORKFLOW_TYPE="utility" ;;
    *)
      WORKFLOW_TYPE="unknown" ;;
  esac
fi

# SEC-003 FIX: Build recovery steps without bash interpolation of SUGGESTED_TEAM.
# The team name is passed via jq --arg below (line ~384) for safe escaping.
if [[ -n "$SUGGESTED_TEAM" ]]; then
  RECOVERY_STEPS="Step 1: TeamCreate with the suggested team name. Step 2: Write state file with status:'active', config_dir, owner_pid, session_id. Step 3: Retry this Agent() call with the team_name parameter."
else
  RECOVERY_STEPS="Step 1: TeamCreate({ team_name: 'rune-WORKFLOW-TIMESTAMP' }). Step 2: Write state file: Write('tmp/.rune-WORKFLOW-ID.json', { team_name: '...', status: 'active', config_dir: configDir, owner_pid: ownerPid, session_id: sessionId }). Step 3: Retry Agent() with team_name parameter."
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
      additionalContext: ("BLOCKED by enforce-teams.sh (ATE-1). Detection source: " + $src + ". Workflow type: " + $wf + ". Agent name: " + $agent_name + ". RECOVERY: " + $recovery + " Use TeamEngine.createTeam() from team-sdk skill, or manually call TeamCreate + Write state file. See team-sdk/references/engines.md for the full createTeam() protocol.")
    }
  }' 2>/dev/null && exit 0

# Fallback: static deny (jq failed)
cat << 'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "ATE-1: Bare Agent call blocked during active Rune workflow. Call TeamCreate first, then add team_name to Agent call.",
    "additionalContext": "BLOCKED by enforce-teams.sh. RECOVERY: 1) TeamCreate({ team_name: 'rune-WORKFLOW-TIMESTAMP' }), 2) Write state file with status:active + session isolation fields, 3) Retry Agent() with team_name. See team-sdk/references/engines.md."
  }
}
DENY_JSON
exit 0
