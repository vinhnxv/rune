#!/bin/bash
# scripts/enforce-polling.sh
# POLL-001: Enforce monitoring loop fidelity during active Rune workflows.
# Blocks sleep+echo anti-pattern (sleep N && echo ...) that skips TaskList
# and provides zero visibility into task progress.
#
# Detection strategy:
#   1. Fast-path: skip if command doesn't contain "sleep"
#   2. Normalize multiline commands (newline -> space)
#   3. Pattern match: sleep N <chain-op> echo/printf
#      Catches: && and ; separators + echo and printf variants
#   4. Threshold: only block sleep >= 10s (tiny sleeps are startup probes)
#   5. Check for active Rune workflow via state files
#   6. Block if anti-pattern detected during active workflow
#
# Exit 0 with hookSpecificOutput.permissionDecision="deny" JSON = tool call blocked.
# Exit 0 without JSON = tool call allowed.

set -euo pipefail
umask 077

# --- Fail-forward guard (OPERATIONAL hook) ---
# Crash before validation → allow operation (don't stall workflows).
_rune_fail_forward() {
  # SEC-002 FIX: Always emit stderr warning for enforcement hooks.
  # Silent fail-forward in a security-adjacent hook masks mid-validation crashes.
  printf 'WARNING: %s: ERR trap — fail-forward activated (line %s). sleep+echo check skipped.\n' \
    "${BASH_SOURCE[0]##*/}" \
    "${BASH_LINENO[0]:-?}" \
    >&2 2>/dev/null || true
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && printf '[%s] %s: ERR trap — fail-forward activated (line %s)\n' \
      "$(date +%H:%M:%S 2>/dev/null || true)" \
      "${BASH_SOURCE[0]##*/}" \
      "${BASH_LINENO[0]:-?}" \
      >> "$_log" 2>/dev/null
  fi
  exit 0
}
trap '_rune_fail_forward' ERR

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

COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Fast-path: skip if no sleep in command
case "$COMMAND" in *sleep*) ;; *) exit 0 ;; esac

# Normalize multiline commands (catches newline-separated sleep/echo)
NORMALIZED=$(printf '%s\n' "$COMMAND" | tr '\n' ' ')

# Pre-filter: skip if command is a simple echo/printf/cat/grep WITHOUT chain operators.
# Known limitation: regex cannot distinguish shell quoting context. Commands that *mention*
# the anti-pattern in string literals (e.g., echo "sleep 30 && echo poll") would false-positive.
# This pre-filter catches the most common case, but ONLY when no chain operator is present —
# a chained command like "echo setup && sleep 30 && echo poll" must still be checked.
case "$NORMALIZED" in
  echo\ *|printf\ *|cat\ *|grep\ *)
    # Only skip if no chain operator that could hide a sleep+echo anti-pattern
    case "$NORMALIZED" in
      *"&&"*|*";"*) ;; # Contains chain operator — fall through to regex check
      *) exit 0 ;;     # Simple command — safe to skip
    esac
    ;;
esac

# Detection: sleep + echo/printf pattern
# Catches && and ; separators + echo and printf variants
# NOTE: || excluded — "sleep N || echo" is error fallback, not polling anti-pattern
# SEC-002 FIX: Word boundary — (^|[[:space:];|&(]) anchors "sleep" to prevent
# matching substrings like "nosleep" in variable/function names.
if printf '%s\n' "$NORMALIZED" | grep -qE '(^|[[:space:];|&(])sleep[[:space:]]+[0-9]+[[:space:]]*(&&|;)[[:space:]]*(echo|printf)'; then
  # Threshold: only block sleep >= 10s (startup probes use sleep 1-5)
  # Extract the sleep value specifically from the anti-pattern match (sleep N && echo / sleep N ; echo)
  # not just the first sleep token in the command — avoids bypass via "sleep 1 && setup; sleep 60 && echo poll"
  # VEIL-009 FIX: Use sort -rn to extract the MAXIMUM sleep value from all anti-pattern matches,
  # not just the first — prevents bypass via "sleep 1 && echo setup; sleep 60 && echo poll"
  SLEEP_NUM=$(printf '%s\n' "$NORMALIZED" | grep -oE 'sleep[[:space:]]+[0-9]+[[:space:]]*(&&|;)[[:space:]]*(echo|printf)' | grep -oE 'sleep[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | sort -rn | head -1)
  [[ "${SLEEP_NUM:-0}" -lt 10 ]] && exit 0

  # Check for active Rune workflow (THIS session only)
  active_workflow=""

  # ── Session identity for cross-session ownership filtering ──
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # VEIL-005 FIX: Guard against missing resolve-session-identity.sh.
  # Without this, a missing file triggers ERR trap → fail-forward → anti-pattern allowed.
  if [[ -f "${SCRIPT_DIR}/resolve-session-identity.sh" ]]; then
    # shellcheck source=resolve-session-identity.sh
    source "${SCRIPT_DIR}/resolve-session-identity.sh"
    source "${SCRIPT_DIR}/lib/rune-state.sh"
  else
    # VEIL-001 FIX: PID-based fallback instead of disabling ownership entirely.
    # Without this, _rune_skip_ownership=1 treated ALL active workflows as "ours",
    # causing cross-session interference (session A blocks session B's polling).
    printf 'WARNING: %s: resolve-session-identity.sh not found — using PID-based ownership fallback\n' \
      "${BASH_SOURCE[0]##*/}" >&2 2>/dev/null || true
    RUNE_CURRENT_CFG=""
    rune_pid_alive() {
      kill -0 "$1" 2>/dev/null && return 0
      # EPERM means process exists but we lack permission — treat as alive
      # This prevents false "dead" detection for cross-user PIDs
      kill -0 "$1" 2>&1 | grep -qi "perm" && return 0
      return 1
    }
  fi

  # Arc checkpoint detection
  if [[ -d "${CWD}/${RUNE_STATE}/arc" ]]; then
    while IFS= read -r f; do
      # Race condition guard: file may be deleted between find and jq
      [[ -f "$f" ]] || continue
      # Validate JSON before parsing — skip corrupted/truncated files
      jq -e . "$f" >/dev/null 2>&1 || continue
      # SEC-4 FIX: Use jq for precise field extraction instead of grep substring match
      # FIX: Check both legacy flat schema (.phase_status/.status) AND v4 nested schema (phases.*.status)
      has_active=$(jq -r 'if (.phase_status // .status // "none") == "in_progress" then "yes" elif ([.phases[]?.status] | any(. == "in_progress")) then "yes" else "no" end' "$f" 2>/dev/null || echo "no")
      if [[ "$has_active" == "yes" ]]; then
        # ── Ownership filter: skip checkpoints from other sessions ──
        stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
        stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
        if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
        if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
          rune_pid_alive "$stored_pid" && continue  # alive = different session
        fi
        active_workflow="arc"
        break
      fi
    done < <(find "${CWD}/${RUNE_STATE}/arc" -name checkpoint.json -maxdepth 2 -type f 2>/dev/null)
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
      if [[ ! -f "$f" ]]; then continue; fi
      # SEC-4 FIX: Use jq for precise status extraction instead of grep substring match
      file_status=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
      if [[ "$file_status" == "active" ]]; then
        # ── Ownership filter: skip state files from other sessions ──
        stored_cfg=$(jq -r '.config_dir // empty' "$f" 2>/dev/null || true)
        stored_pid=$(jq -r '.owner_pid // empty' "$f" 2>/dev/null || true)
        if [[ -n "$stored_cfg" && -n "$RUNE_CURRENT_CFG" && "$stored_cfg" != "$RUNE_CURRENT_CFG" ]]; then continue; fi
        if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ && "$stored_pid" != "$PPID" ]]; then
          rune_pid_alive "$stored_pid" && continue  # alive = different session
        fi
        active_workflow=1
        break
      fi
    done
    shopt -u nullglob
  fi

  if [[ -n "$active_workflow" ]]; then
    cat <<'DENY_JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "POLL-001: Blocked sleep+echo monitoring anti-pattern during active Rune workflow. This pattern skips TaskList and provides zero progress visibility.",
    "additionalContext": "CORRECT monitoring loop: (1) Call TaskList tool, (2) Count completed tasks, (3) Log progress, (4) Check if all done, (5) Check stale tasks, (6) Bash('sleep ${pollIntervalMs/1000}'). Derive sleep interval from per-command pollIntervalMs config — see monitor-utility.md configuration table for exact values. NEVER use 'sleep N && echo poll check' — it bypasses the entire monitoring contract."
  }
}
DENY_JSON
    exit 0
  fi
fi

exit 0
