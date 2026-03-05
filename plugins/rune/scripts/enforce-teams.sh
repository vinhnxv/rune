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
#      - tmp/.rune-review-*.json with "active" status
#      - tmp/.rune-audit-*.json with "active" status
#      - tmp/.rune-work-*.json with "active" status
#      - tmp/.rune-inspect-*.json with "active" status
#      - tmp/.rune-mend-*.json with "active" status
#      - tmp/.rune-plan-*.json with "active" status
#      - tmp/.rune-forge-*.json with "active" status
#      - tmp/.rune-brainstorm-*.json with "active" status
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

# Pre-flight: jq is required for JSON parsing.
# If missing, exit 2 (fail-closed) — consistent with _rune_fail_closed ERR trap.
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found — enforce-teams.sh requires jq (fail-closed)" >&2
  exit 2
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read

# Fast path: if caller is team-lead (not subagent), check for team_name in input.
# Team leads MUST also use team_name — this is the whole point of ATE-1.
# Note: Claude Code 2.1.63 renamed Task → Agent. Both are checked below.

# BACK-003 FIX: Use printf instead of echo to avoid flag interpretation if $INPUT starts with '-'
# Claude Code 2.1.63+ renamed "Task" → "Agent". Match both for backward compat.
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Task" && "$TOOL_NAME" != "Agent" ]]; then
  exit 0
fi

# Claude Code 2.1.69+: agent_type identifies the calling agent (diagnostic/trace).
# Not used for control flow — team_name prefix matching remains the primary mechanism.
AGENT_TYPE=$(printf '%s\n' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)

# QUAL-5: Canonicalize CWD to resolve symlinks (matches on-task-completed.sh pattern)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# Check for active Rune workflows
# NOTE: File-based state detection has inherent TOCTOU window (SEC-3). A workflow
# could start between this check and the Task executing. Claude Code processes tool
# calls sequentially within a session, making the race window effectively zero.
#
# STALENESS GUARD (v1.61.0): Skip files older than 30 minutes (mtime-based).
# Stale checkpoints from crashed/interrupted sessions should not block new work.
# Mirrors the 30-min threshold from enforce-team-lifecycle.sh (TLC-001).
STALE_THRESHOLD_MIN=30
active_workflow=""
detected_team_name=""   # team name inferred from non-state-file signals
detected_source=""      # which signal triggered detection (state-file|inscription|signal-dir|agent-name)

# ── Session identity for cross-session ownership filtering ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
      # ── Ownership filter: skip checkpoints from other sessions ──
      stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # VEIL-007 FIX: Guard against empty RUNE_CURRENT_CFG — when identity script is missing,
      # "$stored_cfg" != "" is always true for any non-empty stored_cfg → skip ALL files.
      if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        rune_pid_alive "$stored_pid" && continue  # alive = different session
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
           "${CWD}"/tmp/.rune-brainstorm-*.json; do
    # Skip files older than STALE_THRESHOLD_MIN minutes
    if [[ -f "$f" ]] && find "$f" -maxdepth 0 -mmin -${STALE_THRESHOLD_MIN} -print -quit 2>/dev/null | grep -q . && jq -e '.status == "active"' "$f" &>/dev/null; then
      # ── Ownership filter: skip state files from other sessions ──
      stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
      stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
      # VEIL-007 FIX: Guard against empty RUNE_CURRENT_CFG (see arc checkpoint block above)
      if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        rune_pid_alive "$stored_pid" && continue  # alive = different session
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
          stored_sid=$(cat "$session_file" 2>/dev/null || true)
          # CDX-GAP-001 FIX: Compare session marker to current session
          # Skip if session marker exists but belongs to different session
          # (stamp-team-session.sh writes this via PostToolUse:TeamCreate)
          current_sid=$(echo "${CLAUDE_SESSION_ID:-}" | head -c 64)
          if [[ -n "$stored_sid" && -n "$current_sid" && "$stored_sid" != "$current_sid" ]]; then
            continue  # Different session — skip this inscription
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
          sig_stored_sid=$(cat "$sig_session_file" 2>/dev/null || true)
          sig_current_sid=$(echo "${CLAUDE_SESSION_ID:-}" | head -c 64)
          if [[ -n "$sig_stored_sid" && -n "$sig_current_sid" && "$sig_stored_sid" != "$sig_current_sid" ]]; then
            continue  # Different session — skip this signal dir
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

# ── Signal 4: Known Rune agent name matching ──
# If the Agent() call uses a name matching a known Rune Ash, this is a Rune workflow
# even if no state file, inscription, or signal dir exists.
# IMPORTANT: This signal does NOT set detected_team_name (we don't know which team).
# It only activates the ATE-1 block so the deny message can guide team creation.
if [[ -z "$active_workflow" ]]; then
  AGENT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || true)
  if [[ -n "$AGENT_NAME" ]]; then
    # Known Rune agent names — review, work, research, utility categories
    # Maintained as a simple grep pattern for O(1) matching (~0.5ms)
    # Source of truth: references/agent-registry.md
    KNOWN_RUNE_AGENTS="ward-sentinel|forge-warden|pattern-weaver|veil-piercer|glyph-scribe|knowledge-keeper|wraith-finder|void-analyzer|flaw-hunter|blight-seer|simplicity-warden|ember-oracle|type-warden|mimic-detector|trial-oracle|tide-watcher|doubt-seer|rune-architect|forge-keeper|phantom-checker|cross-shard-sentinel|entropy-prophet|reality-arbiter|runebinder|mend-fixer|scroll-reviewer|decree-arbiter|elicitation-sage|flow-seer|evidence-verifier|state-weaver|truthseer-validator|todo-verifier|veil-piercer-plan|horizon-sage|rune-smith|design-sync-agent|design-iterator|trial-forger|storybook-fixer|storybook-reviewer|repo-surveyor|echo-reader|git-miner|practice-seeker|lore-scholar|research-verifier|design-inventory-agent|codex-researcher|codex-plan-reviewer|codex-arena-judge|gap-fixer|test-runner|test-failure-analyst"
    if printf '%s\n' "$AGENT_NAME" | grep -qE "^(${KNOWN_RUNE_AGENTS})(-[0-9]+)?$"; then
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
    *)
      WORKFLOW_TYPE="unknown" ;;
  esac
fi

# Build recovery JSON with exact commands
RECOVERY_STEPS="Step 1: TeamCreate({ team_name: '${SUGGESTED_TEAM:-rune-WORKFLOW-TIMESTAMP}' }). Step 2: Write state file: Write('tmp/.rune-WORKFLOW-ID.json', { team_name: '...', status: 'active', config_dir: configDir, owner_pid: ownerPid, session_id: sessionId }). Step 3: Retry Agent() with team_name parameter."

if [[ -n "$SUGGESTED_TEAM" ]]; then
  RECOVERY_STEPS="Step 1: TeamCreate({ team_name: '${SUGGESTED_TEAM}' }). Step 2: Write state file with status:'active', config_dir, owner_pid, session_id. Step 3: Retry this Agent() call with team_name: '${SUGGESTED_TEAM}'."
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
