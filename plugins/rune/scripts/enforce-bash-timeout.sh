#!/bin/bash
# scripts/enforce-bash-timeout.sh
# BASH-TIMEOUT-001: Wrap long-running Bash commands with timeout during active Rune workflows.
#
# Detection strategy:
#   1. Fast-path: skip if no active Rune workflow
#   2. Fast-path: skip if command already has timeout/gtimeout prefix
#   3. Fast-path: skip if tool_input.timeout is set (Claude already set a timeout)
#   4. Fast-path: skip if command is a codex exec invocation
#   5. Match command against TIMEOUT_PATTERNS (npm test, pytest, cargo test, etc.)
#   6. Resolve timeout value from talisman process_management.bash_timeout (default 300s)
#   7. Detect timeout binary: gtimeout (macOS coreutils) → timeout (Linux)
#   8. Inject timeout wrapper via updatedInput.command
#
# Handles `setopt nullglob;` prefix from enforce-zsh-compat.sh (ZSH-001E).
# Handles piped/chained commands by wrapping in `bash -c`.
#
# Exit 0 with hookSpecificOutput.permissionDecision="allow" + updatedInput = auto-wrap.
# Exit 0 without JSON = tool call allowed as-is.
#
# OPERATIONAL hook — fail-forward on crash (see ADR-002).

set -euo pipefail
trap 'exit 0' ERR  # immediate fail-forward guard — upgraded below
umask 077

# --- Fail-forward guard (OPERATIONAL hook — see ADR-002) ---
_rune_fail_forward() {
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

# Pre-flight: jq required
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(head -c 1048576 2>/dev/null || true)  # SEC-2: 1MB cap

TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Fast-path: skip if tool_input.timeout is already set (Claude chose a custom timeout)
TOOL_TIMEOUT=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.timeout // empty' 2>/dev/null || true)
if [[ -n "$TOOL_TIMEOUT" ]]; then
  exit 0
fi

# Strip `setopt nullglob;` prefix injected by enforce-zsh-compat.sh for pattern matching.
# We preserve the prefix in the final wrapped command.
NULLGLOB_PREFIX=""
MATCH_CMD="$COMMAND"
case "$COMMAND" in
  "setopt nullglob;"*)
    NULLGLOB_PREFIX="setopt nullglob; "
    MATCH_CMD="${COMMAND#setopt nullglob;}"
    MATCH_CMD="${MATCH_CMD# }"  # trim leading space
    ;;
esac

# Fast-path: skip if command already has timeout/gtimeout prefix
case "$MATCH_CMD" in
  timeout\ *|gtimeout\ *) exit 0 ;;
esac

# Fast-path: skip codex exec commands
case "$MATCH_CMD" in
  *codex\ exec*|*"codex exec"*) exit 0 ;;
esac

# ── Resolve CWD and check for active Rune workflow ──
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || { exit 0; }
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNE_STATE="${RUNE_STATE:-.rune}"

if [[ -f "${SCRIPT_DIR}/lib/rune-state.sh" ]]; then
  # shellcheck source=lib/rune-state.sh
  source "${SCRIPT_DIR}/lib/rune-state.sh"
fi

# Check for active Rune workflow (arc checkpoint OR state files)
active_workflow=""

# Arc checkpoint detection
if [[ -d "${CWD}/${RUNE_STATE}/arc" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # Consolidated jq: extract status + ownership fields in one call
    # Uses Unit Separator (\u001f) to avoid delimiter collisions with JSON values
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
    # Consolidated jq: extract status + ownership fields in one call
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
      active_workflow="state"
      break
      ;; esac
  done
  shopt -u nullglob
fi

# No active workflow → skip (don't wrap commands outside Rune pipelines)
if [[ -z "$active_workflow" ]]; then
  exit 0
fi

# ── Pattern matching: only wrap commands that match TIMEOUT_PATTERNS ──
# These are commands known to potentially hang or run very long.
NORMALIZED=$(printf '%s\n' "$MATCH_CMD" | tr '\n' ' ')

match_found=""
case "$NORMALIZED" in
  # Test runners
  *"npm test"*|*"npm run test"*|*"npx jest"*|*"npx vitest"*|*"npx mocha"*) match_found="test" ;;
  *pytest*|*"python -m pytest"*|*"python -m unittest"*) match_found="test" ;;
  *"cargo test"*|*"cargo nextest"*) match_found="test" ;;
  *"go test"*) match_found="test" ;;
  # Build tools
  *"make test"*|*"make build"*|*"make check"*|*"make all"*) match_found="build" ;;
  *"npm run build"*|*"npm run dev"*|*"npx tsc"*) match_found="build" ;;
  *"cargo build"*|*"cargo clippy"*|*"cargo check"*) match_found="build" ;;
  *"go build"*|*"go vet"*) match_found="build" ;;
  # Package managers
  *"npm install"*|*"npm ci"*|*"yarn install"*|*"pnpm install"*) match_found="install" ;;
  *"pip install"*|*"pip3 install"*) match_found="install" ;;
  # Container/infra
  *"docker compose"*|*"docker-compose"*|*"docker build"*) match_found="container" ;;
  # JVM build tools
  *mvn\ *|*"./mvnw"*|*gradle\ *|*"./gradlew"*) match_found="jvm" ;;
esac

# Check talisman bash_timeout_patterns for additional user-defined patterns
if [[ -z "$match_found" ]]; then
  TALISMAN_SETTINGS="${CWD}/tmp/.talisman-resolved/settings.json"
  if [[ -f "$TALISMAN_SETTINGS" ]]; then
    EXTRA_PATTERNS=$(jq -r '.process_management.bash_timeout_patterns // [] | .[]' "$TALISMAN_SETTINGS" 2>/dev/null || true)
    if [[ -n "$EXTRA_PATTERNS" ]]; then
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # SEC-001 FIX: Validate user-supplied regex pattern (max 100 chars, no backreferences)
        # WARD-001 FIX: Also reject nested quantifiers that cause ReDoS
        if [[ ${#pat} -gt 100 ]] || [[ "$pat" =~ \\[0-9] ]] || [[ "$pat" =~ \(\.\*\)\+ ]] || [[ "$pat" =~ \(.+\)\+ ]] || [[ "$pat" =~ \(.+\)\* ]]; then
          continue  # Skip potentially dangerous patterns
        fi
        # WARD-001 FIX: Wrap in timeout to prevent ReDoS stalling the hook
        if timeout 1 grep -qE "$pat" <<< "$NORMALIZED" 2>/dev/null; then
          match_found="custom"
          break
        fi
      done <<< "$EXTRA_PATTERNS"
    fi
  fi
  # Also check misc.json shard (process_management may be here)
  if [[ -z "$match_found" ]]; then
    TALISMAN_MISC="${CWD}/tmp/.talisman-resolved/misc.json"
    if [[ -f "$TALISMAN_MISC" ]]; then
      EXTRA_PATTERNS=$(jq -r '.process_management.bash_timeout_patterns // [] | .[]' "$TALISMAN_MISC" 2>/dev/null || true)
      if [[ -n "$EXTRA_PATTERNS" ]]; then
        while IFS= read -r pat; do
          [[ -z "$pat" ]] && continue
          # SEC-001 FIX: Validate user-supplied regex pattern (max 100 chars, no backreferences, no nested quantifiers)
          if [[ ${#pat} -gt 100 ]] || [[ "$pat" =~ \\[0-9] ]] || [[ "$pat" =~ \(\.\*\)\+ ]] || [[ "$pat" =~ \(.+\)\+ ]] || [[ "$pat" =~ \(.+\)\* ]]; then
            continue
          fi
          if timeout 1 grep -qE "$pat" <<< "$NORMALIZED" 2>/dev/null; then
            match_found="custom"
            break
          fi
        done <<< "$EXTRA_PATTERNS"
      fi
    fi
  fi
fi

# No pattern match → allow as-is
if [[ -z "$match_found" ]]; then
  exit 0
fi

# ── Resolve timeout value ──
TIMEOUT_SECS=""
# Check talisman resolved shards for bash_timeout
for shard in "${CWD}/tmp/.talisman-resolved/settings.json" "${CWD}/tmp/.talisman-resolved/misc.json"; do
  if [[ -f "$shard" ]]; then
    _val=$(jq -r '.process_management.bash_timeout // empty' "$shard" 2>/dev/null || true)
    if [[ -n "$_val" && "$_val" =~ ^[0-9]+$ ]]; then
      TIMEOUT_SECS="$_val"
      break
    fi
  fi
done
# Check if bash_timeout_enabled is explicitly false
for shard in "${CWD}/tmp/.talisman-resolved/settings.json" "${CWD}/tmp/.talisman-resolved/misc.json"; do
  if [[ -f "$shard" ]]; then
    _enabled=$(jq -r '.process_management.bash_timeout_enabled // empty' "$shard" 2>/dev/null || true)
    if [[ "$_enabled" == "false" ]]; then
      exit 0  # User explicitly disabled bash timeout
    fi
  fi
done
# Fallback to default
if [[ -z "$TIMEOUT_SECS" ]]; then
  TIMEOUT_SECS=300
fi

# ── Detect timeout binary ──
TIMEOUT_BIN=""
KILL_AFTER_SUPPORTED=""
if command -v gtimeout &>/dev/null; then
  TIMEOUT_BIN="gtimeout"
  # GNU coreutils gtimeout always supports --kill-after
  KILL_AFTER_SUPPORTED="1"
elif command -v timeout &>/dev/null; then
  TIMEOUT_BIN="timeout"
  # Probe --kill-after support (GNU extension, not on all platforms)
  if timeout --kill-after=1 0.1 true 2>/dev/null; then
    KILL_AFTER_SUPPORTED="1"
  fi
fi

# No timeout binary available → advisory only (AC-3: graceful degradation)
if [[ -z "$TIMEOUT_BIN" ]]; then
  cat <<'ENDJSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"WARN: No timeout binary available (timeout/gtimeout not found). Long-running commands will not be time-bounded. Consider installing coreutils (macOS: brew install coreutils)."}}
ENDJSON
  exit 0
fi

# ── Build wrapped command ──
# Kill-after grace: 10% of timeout, minimum 5 seconds
KILL_AFTER=$(( TIMEOUT_SECS / 10 ))
if [[ "$KILL_AFTER" -lt 5 ]]; then
  KILL_AFTER=5
fi

# Determine if the command needs bash -c wrapping (pipes, chains, redirects, env assignments)
# CDX-BUG-002 FIX: Also wrap commands starting with VAR=value (env-prefixed) —
# without bash -c, `gtimeout ... CI=1 npm test` treats CI=1 as argv0.
NEEDS_BASH_C=""
case "$MATCH_CMD" in
  *\|*|*\&\&*|*\|\|*|*\;*|*\>*|*\<*) NEEDS_BASH_C="1" ;;
esac
# Detect env-prefixed commands: one or more VAR=value before the actual command
if [[ -z "$NEEDS_BASH_C" && "$MATCH_CMD" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
  NEEDS_BASH_C="1"
fi

TIMEOUT_PREFIX="$TIMEOUT_BIN"
if [[ -n "$KILL_AFTER_SUPPORTED" ]]; then
  TIMEOUT_PREFIX="${TIMEOUT_BIN} --kill-after=${KILL_AFTER} ${TIMEOUT_SECS}"
else
  TIMEOUT_PREFIX="${TIMEOUT_BIN} ${TIMEOUT_SECS}"
fi

if [[ -n "$NEEDS_BASH_C" ]]; then
  # Escape single quotes in command for bash -c wrapping
  ESCAPED_CMD=$(printf '%s' "$MATCH_CMD" | sed "s/'/'\\\\''/g")
  WRAPPED="${TIMEOUT_PREFIX} bash -c '${ESCAPED_CMD}'"
else
  WRAPPED="${TIMEOUT_PREFIX} ${MATCH_CMD}"
fi

# Re-apply nullglob prefix if it was stripped
if [[ -n "$NULLGLOB_PREFIX" ]]; then
  WRAPPED="${NULLGLOB_PREFIX}${WRAPPED}"
fi

# ── Emit PreToolUse JSON with updatedInput ──
# Use jq to properly escape the wrapped command for JSON
WRAPPED_JSON=$(printf '%s\n' "$WRAPPED" | jq -Rs '.')

cat <<ENDJSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"BASH-TIMEOUT-001: wrapped with ${TIMEOUT_BIN} ${TIMEOUT_SECS}s (pattern: ${match_found})","updatedInput":{"command":${WRAPPED_JSON}},"additionalContext":"Command wrapped with ${TIMEOUT_BIN} ${TIMEOUT_SECS}s timeout (kill-after ${KILL_AFTER}s). Pattern: ${match_found}."}}
ENDJSON
