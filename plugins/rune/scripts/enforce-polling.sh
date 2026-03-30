#!/bin/bash
# scripts/enforce-polling.sh
# POLL-001: Enforce monitoring loop fidelity during active Rune workflows.
# Uses an ALLOWLIST approach: during active workflows, only bare "sleep N"
# commands are permitted. Any sleep combined with other commands (echo, printf,
# pipes, chains) is blocked — preventing polling anti-patterns that skip TaskList.
#
# Detection strategy:
#   1. Fast-path: skip if command doesn't contain "sleep"
#   2. Check for active Rune workflow via state files (skip early if none)
#   3. Allowlist: bare "sleep N" is OK, sleep+anything is blocked
#   4. Threshold: only block sleep >= 10s (tiny sleeps are startup probes)
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON = tool call allowed.

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
# NOTE: ERR trap does NOT fire on `set -u` unbound variable errors in Bash 3.2-5.x.
# All variables used after this point must be explicitly defaulted to avoid silent bypass.
_rune_fail_forward() {
  # SEC-002 FIX: Always emit stderr warning for enforcement hooks.
  # Silent fail-forward in a security-adjacent hook masks mid-validation crashes.
  printf 'WARNING: %s: ERR trap — fail-forward activated (line %s). sleep+echo check skipped.\n' \
    "${BASH_SOURCE[0]##*/}" \
    "${BASH_LINENO[0]:-?}" \
    >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u)-${PPID}.log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

# ── ENV TOGGLE: Allow disabling POLL-001 entirely ──
# POLL-001 is DISABLED by default. Set RUNE_DISABLE_POLL_GUARD=0 to enable.
# Also configurable via talisman.yml: process_management.poll_guard_enabled: false
if [[ "${RUNE_DISABLE_POLL_GUARD:-1}" == "1" ]]; then
  exit 0
fi

# Pre-flight: jq is required for JSON parsing.
# If missing, exit 0 (non-blocking) — allow rather than crash.
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — enforce-polling.sh hook is inactive" >&2
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap to prevent unbounded stdin read

TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

# ── Talisman config toggle: process_management.poll_guard_enabled ──
# Resolved talisman shards take priority over env var.
_talisman_shard="${CWD}/tmp/.talisman-resolved/settings.json"
if [[ -f "$_talisman_shard" && ! -L "$_talisman_shard" ]]; then
  _poll_enabled=$(jq -r '.process_management.poll_guard_enabled // true' "$_talisman_shard" 2>/dev/null || echo "true")
  if [[ "$_poll_enabled" == "false" ]]; then
    exit 0
  fi
fi

COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Fast-path: skip if no sleep in command
case "$COMMAND" in *sleep*) ;; *) exit 0 ;; esac

# ── Session identity + state directory (unconditional) ──
# BUGFIX: Previously, RUNE_STATE and session identity were only loaded inside the
# old denylist regex branch. When resolve-session-identity.sh was missing,
# RUNE_STATE remained unbound → set -u crash → ERR trap doesn't fire on unbound
# vars in Bash 3.2-5.x → enforcement silently disabled. Now loaded unconditionally.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Always set RUNE_STATE default BEFORE sourcing rune-state.sh (defense against source failure)
RUNE_STATE="${RUNE_STATE:-.rune}"

if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
  # EDGE-001 FIX: Initialize with safe default before sourcing — if resolve-session-identity.sh
  # fails to set RUNE_CURRENT_CFG (e.g., partial source failure), the variable remains
  # defined (empty) instead of unbound, preventing set -u crashes in Bash 3.2-5.x.
  RUNE_CURRENT_CFG="${RUNE_CURRENT_CFG:-}"
  # shellcheck source=resolve-session-identity.sh
  source "${SCRIPT_DIR}/resolve-session-identity.sh"
  # shellcheck source=lib/rune-state.sh
  if [[ -f "${SCRIPT_DIR}/lib/rune-state.sh" ]]; then
    source "${SCRIPT_DIR}/lib/rune-state.sh"
  fi
else
  # VEIL-001 FIX: PID-based fallback instead of disabling ownership entirely.
  printf 'WARNING: %s: resolve-session-identity.sh not found — using PID-based ownership fallback\n' \
    "${BASH_SOURCE[0]##*/}" >&2 2>/dev/null || true
  RUNE_CURRENT_CFG=""
  rune_pid_alive() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    local _err
    _err=$(kill -0 "$1" 2>&1) && return 0
    case "$_err" in *ermission*|*[Pp]erm*|*EPERM*) return 0 ;; esac
    return 1
  }
fi

# ── Check for active Rune workflow FIRST (skip expensive analysis if none) ──
# This is checked before pattern analysis so we exit early when no workflow is active.
# Uses consolidated single-jq-call per file for performance (was 3 calls per file).
active_workflow=""

# Arc checkpoint detection
if [[ -d "${CWD}/${RUNE_STATE}/arc" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # Consolidated jq: extract status + ownership fields in one call (was 3 separate calls)
    # Uses ASCII Unit Separator (\u001f) as delimiter — NOT tab.
    # Bash `read` collapses consecutive whitespace delimiters (tab, space, newline),
    # which silently corrupts parsing when config_dir is empty ("yes\t\t99999999"
    # becomes "yes" + "99999999" instead of "yes" + "" + "99999999").
    # Unit Separator is non-whitespace, so empty fields are preserved.
    _arc_info=$(jq -r '
      (if (.phase_status // .status // "none") == "in_progress" then "yes"
       elif ([.phases[]?.status] | any(. == "in_progress")) then "yes"
       else "no" end) + "\u001f" +
      (.config_dir // "") + "\u001f" +
      (.owner_pid // "" | tostring)
    ' "$f" 2>/dev/null) || continue
    IFS=$'\x1f' read -r has_active stored_cfg stored_pid <<< "$_arc_info"
    if [[ "$has_active" == "yes" ]]; then
      # Ownership filter: skip checkpoints from other sessions
      if [[ -n "$stored_cfg" && -n "${RUNE_CURRENT_CFG:-}" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        rune_pid_alive "$stored_pid" && continue
      fi
      active_workflow="arc"
      break
    fi
  done < <(find "${CWD}/${RUNE_STATE}/arc" -maxdepth 2 -name checkpoint.json -type f 2>/dev/null)
fi

# State file detection — all workflow types
if [[ -z "$active_workflow" ]]; then
  shopt -s nullglob
  for f in "${CWD}"/tmp/.rune-review-*.json "${CWD}"/tmp/.rune-audit-*.json \
           "${CWD}"/tmp/.rune-work-*.json "${CWD}"/tmp/.rune-mend-*.json \
           "${CWD}"/tmp/.rune-plan-*.json "${CWD}"/tmp/.rune-forge-*.json \
           "${CWD}"/tmp/.rune-inspect-*.json "${CWD}"/tmp/.rune-goldmask-*.json \
           "${CWD}"/tmp/.rune-brainstorm-*.json "${CWD}"/tmp/.rune-debug-*.json \
           "${CWD}"/tmp/.rune-design-sync-*.json; do
    [[ -f "$f" ]] || continue
    # Consolidated jq: extract status + ownership fields in one call (was 3 separate calls)
    # Uses Unit Separator (\u001f) — see arc checkpoint comment for rationale.
    _state_info=$(jq -r '
      (.status // "") + "\u001f" +
      (.config_dir // "") + "\u001f" +
      (.owner_pid // "" | tostring)
    ' "$f" 2>/dev/null) || continue
    IFS=$'\x1f' read -r file_status stored_cfg stored_pid <<< "$_state_info"
    case "$file_status" in active|in_progress|running)
      # Ownership filter: skip state files from other sessions
      if [[ -n "$stored_cfg" && -n "${RUNE_CURRENT_CFG:-}" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
        rune_pid_alive "$stored_pid" && continue
      fi
      active_workflow=1
      break
      ;; esac
  done
  shopt -u nullglob
fi

# No active workflow → allow everything (sleep commands are fine outside workflows)
if [[ -z "$active_workflow" ]]; then
  exit 0
fi

# ── ALLOWLIST detection (replaces old denylist regex) ──
# During active workflows, only bare "sleep N" is permitted.
# Any sleep combined with other commands is blocked.
# This catches ALL bypass variants: variable expansion, command substitution,
# full path (/bin/sleep), env prefix, newline-separated chains, etc.

# Normalize: collapse newlines to semicolons (newline IS a command separator in bash),
# strip comments, collapse whitespace, strip trailing semicolons
# (printf '%s\n' adds trailing newline → tr converts to ';' → must strip it)
NORMALIZED=$(printf '%s\n' "$COMMAND" | tr '\n' ';' | sed 's/#[^"'"'"']*$//' | sed 's/[[:space:]]\{1,\}/ /g' | sed 's/^[[:space:];]*//;s/[[:space:];]*$//')

# Allowlist: bare sleep command (with optional decimal, e.g., "sleep 30" or "sleep 30.5")
# Matches: "sleep N", "sleep N.N" — nothing else
if [[ "$NORMALIZED" =~ ^[[:space:]]*sleep[[:space:]]+[0-9]+\.?[0-9]*[[:space:]]*$ ]]; then
  exit 0
fi

# If we reach here: sleep is combined with something else during an active workflow.
# Extract the maximum sleep value from the command for threshold check.
# Matches both literal numbers and covers the common LLM patterns.
# Uses -E extended regex: finds all "sleep <number>" occurrences, takes the max.
SLEEP_NUM=$(printf '%s\n' "$NORMALIZED" | grep -oE '(^|[[:space:];|&(/])sleep[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | sort -rn | head -1)

# Threshold: only block sleep >= 10s (tiny sleeps are startup probes or retry backoff)
if [[ "${SLEEP_NUM:-0}" -lt 10 ]]; then
  exit 0
fi

# ── Block: sleep+something during active workflow ──
cat <<'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "POLL-001: Blocked sleep combined with other commands during active Rune workflow. During monitoring, sleep must be called alone — not chained with echo, printf, or any other command.",
    "additionalContext": "CORRECT monitoring loop: (1) Call TaskList tool, (2) Count completed tasks, (3) Log progress, (4) Check if all done, (5) Check stale tasks, (6) Bash('sleep ${pollIntervalMs/1000}'). Derive sleep interval from per-command pollIntervalMs config — see monitor-utility.md configuration table for exact values. NEVER chain sleep with echo/printf — it bypasses the monitoring contract."
  }
}
DENY_JSON
exit 0
