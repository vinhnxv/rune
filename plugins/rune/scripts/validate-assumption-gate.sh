#!/bin/bash
# scripts/validate-assumption-gate.sh
# INNER-FLAME-0: Pre-execution assumption gate for strive workers.
# Gates the first Write/Edit/NotebookEdit per task on assumption declaration.
#
# Checks that the worker's task file contains at least min_assumptions declared
# [ASSUMPTION-N] entries before allowing the first write to the codebase.
# On pass, writes a signal marker so subsequent writes are not re-checked.
#
# Exit 0          = allow (pass marker present, sufficient assumptions, or fail-forward)
# Exit 2 + stderr = DENY (insufficient assumptions AND block_on_missing=true)
#
# Fail-open design: On any parsing/validation error, allow the operation.
# False negatives (allowing writes without assumptions) are preferable to false
# positives (blocking legitimate workers who set talisman assumption_gate wrong).
#
# CRITICAL (CONCERN-1): On the DENY path, DO NOT write the pass marker.
# The pass marker is ONLY written on the ALLOW path (sufficient assumptions found).

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
    # SEC-007: reject symlink to prevent log redirection attacks
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# Pre-flight: jq required for JSON parsing (fail-open if missing)
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — validate-assumption-gate.sh is inactive (fail-forward)" >&2
  exit 0
fi

# Source shared PreToolUse Write guard library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pretooluse-write-guard.sh
source "${SCRIPT_DIR}/lib/pretooluse-write-guard.sh"
source "${SCRIPT_DIR}/lib/rune-state.sh"

# Common fast-path gates (sets INPUT, TOOL_NAME, FILE_PATH, TRANSCRIPT_PATH, CWD, CHOME)
rune_write_guard_preflight "validate-assumption-gate.sh"

# --- State file discovery: rune-work-* | arc-work-* teams only ---
# Cannot use rune_find_active_state() twice (it exits 0 on no-match).
# Inline search across both patterns in one pass.
STATE_FILE=""
TEAM_PREFIX=""
IDENTIFIER=""

_ag_nullglob_was_set=0
if shopt -q nullglob 2>/dev/null; then
  _ag_nullglob_was_set=1
fi
shopt -s nullglob

for _ag_f in "${CWD}"/tmp/.rune-work-*.json "${CWD}"/tmp/.rune-arc-work-*.json; do
  if [[ -f "$_ag_f" ]] && jq -e '.status == "active"' "$_ag_f" >/dev/null 2>&1; then
    STATE_FILE="$_ag_f"
    _ag_base=$(basename "$_ag_f" .json)
    if [[ "$_ag_base" == .rune-arc-work-* ]]; then
      TEAM_PREFIX="arc-work"
      IDENTIFIER="${_ag_base#.rune-arc-work-}"
    else
      TEAM_PREFIX="rune-work"
      IDENTIFIER="${_ag_base#.rune-work-}"
    fi
    break
  fi
done

[[ "$_ag_nullglob_was_set" -eq 0 ]] && shopt -u nullglob

# No active work workflow — allow (hook only applies during work phases)
if [[ -z "$STATE_FILE" || -z "$IDENTIFIER" ]]; then
  exit 0
fi

# SEC-001: Validate IDENTIFIER (safe chars + length cap)
if [[ ! "$IDENTIFIER" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ${#IDENTIFIER} -gt 64 ]]; then
  exit 0
fi

# Verify session ownership (config_dir + owner_pid isolation)
rune_verify_session_ownership "$STATE_FILE"

TEAM_NAME="${TEAM_PREFIX}-${IDENTIFIER}"

# SEC-001: Validate TEAM_NAME
if [[ ! "$TEAM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ${#TEAM_NAME} -gt 128 ]]; then
  exit 0
fi

# --- Talisman config: inner_flame.assumption_gate ---
ASSUMPTION_GATE_ENABLED="false"
MIN_ASSUMPTIONS=3
BLOCK_ON_MISSING="true"

for TALISMAN_PATH in "${CWD}/${RUNE_STATE}/talisman.yml" "${CHOME}/talisman.yml"; do
  if [[ -f "$TALISMAN_PATH" ]]; then
    if command -v yq &>/dev/null; then
      _ag_enabled=$(yq -r 'if .inner_flame.assumption_gate.enabled == true then "true" else "false" end' \
        "$TALISMAN_PATH" 2>/dev/null) || _ag_enabled="false"
      [[ -z "$_ag_enabled" ]] && _ag_enabled="false"
      ASSUMPTION_GATE_ENABLED="$_ag_enabled"

      _ag_min=$(yq -r '.inner_flame.assumption_gate.min_assumptions // 3' \
        "$TALISMAN_PATH" 2>/dev/null) || _ag_min=3
      [[ "$_ag_min" =~ ^[0-9]+$ ]] && MIN_ASSUMPTIONS="$_ag_min"

      _ag_block=$(yq -r 'if .inner_flame.assumption_gate.block_on_missing == false then "false" else "true" end' \
        "$TALISMAN_PATH" 2>/dev/null) || _ag_block="true"
      [[ -z "$_ag_block" ]] && _ag_block="true"
      BLOCK_ON_MISSING="$_ag_block"
    else
      echo "validate-assumption-gate.sh: yq not found — cannot read talisman config (fail-forward)" >&2
    fi
    break
  fi
done

# Exit if assumption gate disabled (or yq unavailable — default false for safety)
if [[ "$ASSUMPTION_GATE_ENABLED" != "true" ]]; then
  exit 0
fi

# --- Extract caller agent name from TRANSCRIPT_PATH ---
CALLER_AGENT=""
if [[ -n "${TRANSCRIPT_PATH:-}" ]]; then
  CALLER_AGENT=$(printf '%s' "$TRANSCRIPT_PATH" | sed -n 's|.*/subagents/\([^/]*\)/.*|\1|p')
fi

# Fail-forward if caller agent cannot be determined
if [[ -z "$CALLER_AGENT" ]]; then
  exit 0
fi

# SEC-001/SEC-4: Validate caller agent name (safe chars only)
if [[ ! "$CALLER_AGENT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  exit 0
fi

# --- Find task assignment for this worker ---
INSCRIPTION_PATH="${CWD}/tmp/.rune-signals/${TEAM_NAME}/inscription.json"

# Path containment check (SEC-003): verify INSCRIPTION_PATH is under CWD/tmp/
REAL_INSCRIPTION_DIR=$(cd "$(dirname "$INSCRIPTION_PATH")" 2>/dev/null && pwd -P) || exit 0
case "$REAL_INSCRIPTION_DIR" in
  "${CWD}/tmp/"*) ;; # OK — within project tmp/
  *) exit 0 ;;
esac

TASK_ID=""
if [[ -f "$INSCRIPTION_PATH" ]]; then
  # Look for task_id where owner matches this agent's name
  TASK_ID=$(jq -r --arg name "$CALLER_AGENT" \
    '.task_ownership | to_entries[] | select(.value.owner == $name) | .key' \
    "$INSCRIPTION_PATH" 2>/dev/null | head -1 || true)
fi

# Fail-forward: no task assignment found (early phase, or inscription not yet written)
if [[ -z "$TASK_ID" ]]; then
  exit 0
fi

# SEC-001: Validate TASK_ID (safe chars + length cap)
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ${#TASK_ID} -gt 64 ]]; then
  exit 0
fi

# --- Check pass marker (first-write-only gate) ---
SIGNAL_DIR="${CWD}/tmp/.rune-signals/${TEAM_NAME}"
PASS_MARKER="${SIGNAL_DIR}/.assumption-gate-passed-${TASK_ID}"

if [[ -f "$PASS_MARKER" ]]; then
  # Already cleared this gate for this task — allow without re-checking
  exit 0
fi

# --- Find and read the worker's task file ---
TASK_FILE="${CWD}/tmp/work/${IDENTIFIER}/tasks/${TASK_ID}.md"

if [[ ! -f "$TASK_FILE" ]]; then
  # Task file not yet created — fail-forward (allow)
  exit 0
fi

# Path containment check (SEC-003): verify TASK_FILE is under CWD/tmp/
REAL_TASK_DIR=$(cd "$(dirname "$TASK_FILE")" 2>/dev/null && pwd -P) || exit 0
case "$REAL_TASK_DIR" in
  "${CWD}/tmp/"*) ;; # OK — within project tmp/
  *) exit 0 ;;
esac

# --- Count [ASSUMPTION- entries in Assumptions section ---
ASSUMPTION_COUNT=0
ASSUMPTION_COUNT=$(grep -c '\[ASSUMPTION-' "$TASK_FILE" 2>/dev/null || echo 0)

# Guard: ensure valid integer
[[ "$ASSUMPTION_COUNT" =~ ^[0-9]+$ ]] || ASSUMPTION_COUNT=0

# --- Gate decision ---
if [[ "$ASSUMPTION_COUNT" -ge "$MIN_ASSUMPTIONS" ]]; then
  # ALLOW: Sufficient assumptions declared — write pass marker and permit the write
  # CONCERN-1: marker is ONLY written here (ALLOW path), never on DENY path
  mkdir -p "$SIGNAL_DIR" 2>/dev/null || true
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) team=${TEAM_NAME} task=${TASK_ID} count=${ASSUMPTION_COUNT}" \
    > "$PASS_MARKER" 2>/dev/null || true
  exit 0
fi

# Insufficient assumptions — enforce based on block_on_missing config
if [[ "$BLOCK_ON_MISSING" == "true" ]]; then
  # DENY: emit Claude Code 2.1.63 permissionDecision JSON on stdout + exit 0
  # (CONCERN-1: NO marker written on deny path)
  # Routes the reason into Claude's context rather than the hook-error stderr channel.
  DENY_MSG=$(cat <<DENYEOF
INNER-FLAME-0: Assumption gate blocked.
Task ${TASK_ID} has ${ASSUMPTION_COUNT}/${MIN_ASSUMPTIONS} required [ASSUMPTION-N] declarations.

Before writing code, declare your assumptions in the task file:
  ${TASK_FILE}

Add an Assumptions section:
  ## Assumptions
  - [ASSUMPTION-1]: What you assume about the existing code structure
  - [ASSUMPTION-2]: What you assume about the interface or contract
  - [ASSUMPTION-3]: What you assume about the runtime environment

This gate ensures work decisions are explicit and reviewable.
To disable: set inner_flame.assumption_gate.block_on_missing: false in .rune/talisman.yml
DENYEOF
)
  DENY_JSON=$(jq -n --arg reason "$DENY_MSG" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }')
  printf '%s\n' "$DENY_JSON"
  exit 0
fi

# Soft enforcement — warn only, do not block
echo "INNER-FLAME-0: Task ${TASK_ID} has ${ASSUMPTION_COUNT}/${MIN_ASSUMPTIONS} [ASSUMPTION-N] declarations (soft enforcement — not blocking)." >&2
exit 0
