#!/bin/bash
# scripts/enforce-rtk.sh
# RTK-001: Optional PreToolUse hook — rewrites Bash commands with `rtk` prefix
# for token compression when the RTK (Rust Token Killer) integration is enabled.
#
# Pipeline (14 steps):
#   1. Fail-forward guard (OPERATIONAL hook)
#   2. Fast-path: exit if tool is not Bash
#   3. jq dependency check
#   4. Read JSON input (1MB cap)
#   5. Extract CWD and COMMAND
#   6. Load RTK config from cached misc shard
#   7. Check rtk.enabled — exit if false
#   8. Detect rtk binary (SESSION_ID-scoped cache)
#   9. Skip if command already prefixed with "rtk"
#  10. Skip if command contains heredoc (<<) — NOT herestrings (<<<)
#  11. Skip compound commands (&&, ||, ;, | outside quotes at top level)
#  12. Layer 2: check exempt_commands patterns (cheaper — no filesystem reads)
#  13. Layer 1: check active workflow state files for exempt workflows
#  14. Rewrite and emit updatedInput JSON
#
# Output format: hookSpecificOutput with updatedInput (no permissionDecision).
# Follows enforce-zsh-compat.sh pattern. Never uses permissionDecision: "allow".
#
# Hook event: PreToolUse (Bash)
# Timeout: 5s
# Fail mode: OPERATIONAL (fail-forward on crash)

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Step 1: Fail-forward guard (OPERATIONAL hook) ──────────────────────────────
_rune_fail_forward() {
  printf 'WARNING: %s: ERR trap — fail-forward activated (line %s). RTK rewrite skipped.\n' \
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

# ── Step 2: Fast-path — skip if not a Bash tool call ─────────────────────────
# Read a tiny slice first to check tool_name before loading the full payload.
INPUT_PEEK=$(head -c 256 2>/dev/null || true)
case "$INPUT_PEEK" in *'"Bash"'*) ;; *) exit 0 ;; esac

# ── Step 3: jq dependency check ───────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not found — enforce-rtk.sh hook is inactive" >&2
  exit 0
fi

# ── Step 4: Read full JSON input (1MB cap) ────────────────────────────────────
# IMPORTANT: We already read 256 bytes above. Re-read from scratch is not
# possible on stdin — use the peeked data plus remaining stdin.
INPUT="${INPUT_PEEK}$(head -c $((1048576 - ${#INPUT_PEEK})) 2>/dev/null || true)"

# BACK-004: Validate JSON is parseable before extracting fields
if ! printf '%s\n' "$INPUT" | jq empty 2>/dev/null; then
  exit 0  # Malformed JSON — skip silently
fi

TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# ── Step 5: Extract CWD and COMMAND ──────────────────────────────────────────
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
if [[ -z "$CWD" ]]; then
  exit 0
fi
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
if [[ -z "$CWD" || "$CWD" != /* ]]; then exit 0; fi

SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
# SEC-RTK-002: Sanitize SESSION_ID before use in path construction
if [[ -n "$SESSION_ID" ]] && ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  SESSION_ID=""
fi

COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# ── Step 6: Load RTK config from cached misc shard ───────────────────────────
# shellcheck source=lib/rtk-config.sh
source "${SCRIPT_DIR}/lib/rtk-config.sh"
if ! rtk_load_config "$CWD"; then
  exit 0  # No shard available — skip (talisman not resolved yet or no config)
fi

# ── Step 7: Check rtk.enabled ────────────────────────────────────────────────
if [[ "$RTK_ENABLED" != "true" ]]; then
  exit 0
fi

# SEC-RTK-001: Re-validate RTK_TEE_MODE after config load (defense-in-depth)
case "${RTK_TEE_MODE:-}" in
  always|failures|never) ;;
  *) RTK_TEE_MODE="always" ;;
esac

# ── Helper: portable symlink resolution (Linux + macOS) ──────────────────────
# Resolves symlinks to the final real binary path.
# Chain: readlink -f (GNU/Linux, macOS 13+) → realpath → manual loop (BSD)
_resolve_binary() {
  local path="$1" resolved
  # 1. GNU readlink -f (Linux, macOS with coreutils or macOS 13+)
  if resolved=$(readlink -f "$path" 2>/dev/null) && [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"; return 0
  fi
  # 2. realpath (macOS 12.3+, most Linux distros)
  if resolved=$(realpath "$path" 2>/dev/null) && [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"; return 0
  fi
  # 3. Manual symlink loop (stock BSD macOS fallback, max 10 hops)
  local _i=0
  while [[ -L "$path" ]] && (( _i++ < 10 )); do
    local _target
    _target=$(readlink "$path" 2>/dev/null) || break
    # Handle relative symlinks
    [[ "$_target" != /* ]] && _target="$(dirname "$path")/$_target"
    path="$_target"
  done
  # Canonicalize the final directory component
  resolved=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path") 2>/dev/null || return 1
  printf '%s' "$resolved"
}

# ── Step 8: Detect rtk binary (SESSION_ID-scoped cache) ──────────────────────
RTK_CACHE_DIR="${CWD}/tmp/.rune-rtk-cache"
RTK_CACHE_FILE="${RTK_CACHE_DIR}/rtk-binary-${SESSION_ID:-default}.json"
RTK_BIN=""

# BACK-002: TTL cleanup — purge stale cache files older than 24h (once per run, best-effort)
if [[ -d "$RTK_CACHE_DIR" ]]; then
  find "$RTK_CACHE_DIR" -name 'rtk-binary-*.json' -type f -mmin +1440 -delete 2>/dev/null || true
fi

if [[ -f "$RTK_CACHE_FILE" && ! -L "$RTK_CACHE_FILE" ]]; then
  RTK_BIN=$(jq -r '.rtk_bin // empty' "$RTK_CACHE_FILE" 2>/dev/null || true)
fi

if [[ -z "$RTK_BIN" ]]; then
  RTK_BIN=$(command -v rtk 2>/dev/null || true)
  if [[ -n "$RTK_BIN" ]]; then
    # Resolve symlinks portably (Homebrew/nix/apt use file-level symlinks)
    RTK_BIN=$(_resolve_binary "$RTK_BIN") || RTK_BIN=""
  fi

  if [[ -z "$RTK_BIN" ]]; then
    # rtk not found
    if [[ "$RTK_AUTO_DETECT" == "true" ]]; then
      exit 0  # auto_detect: true → silently skip when binary absent
    fi
    # auto_detect: false → warn and skip
    echo "WARNING: enforce-rtk.sh: rtk binary not found and auto_detect=false" >&2
    exit 0
  fi

  # Cache the resolved binary path
  mkdir -p "$RTK_CACHE_DIR" 2>/dev/null || true
  local_cache_tmp=$(mktemp "${RTK_CACHE_DIR}/.rtk-cache.XXXXXX" 2>/dev/null) || true
  if [[ -n "$local_cache_tmp" ]]; then
    jq -n --arg bin "$RTK_BIN" '{"rtk_bin": $bin}' > "$local_cache_tmp" 2>/dev/null \
      && mv -f "$local_cache_tmp" "$RTK_CACHE_FILE" 2>/dev/null \
      || rm -f "$local_cache_tmp" 2>/dev/null
  fi
fi

# Validate cached binary still exists and is executable (resolve symlinks if cached path is stale)
if [[ -L "$RTK_BIN" ]]; then
  RTK_BIN=$(_resolve_binary "$RTK_BIN") || { exit 0; }
fi
if [[ ! -x "$RTK_BIN" ]]; then
  exit 0
fi

# ── Step 9: Skip if already prefixed with rtk ────────────────────────────────
NORMALIZED=$(printf '%s\n' "$COMMAND" | tr '\n' ' ')
case "$NORMALIZED" in
  rtk\ *|*\ rtk\ --\ *) exit 0 ;;
esac

# ── Step 10: Skip if command contains heredoc (but NOT herestrings <<<) ──────
# Heredoc (<<) would be broken by rtk prefix; herestrings (<<<) are safe.
HEREDOC_CHECK=$(printf '%s\n' "$COMMAND" | sed 's/<<<//g')
case "$HEREDOC_CHECK" in *'<<'*) exit 0 ;; esac

# ── Step 11: Skip compound commands ──────────────────────────────────────────
# Commands joined by &&, ||, ;, or | at the top level cannot be safely prefixed.
# Simple heuristic: strip quoted strings then check for operators.
STRIPPED=$(printf '%s\n' "$NORMALIZED" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
case "$STRIPPED" in *'&&'*|*'||'*|*';'*|*'|'*) exit 0 ;; esac

# ── Step 12: Layer 2 — command-level exemption (checked first, cheaper) ──────
# shellcheck source=lib/rtk-exempt.sh
source "${SCRIPT_DIR}/lib/rtk-exempt.sh"
if rtk_is_command_exempt "$COMMAND" "$RTK_EXEMPT_COMMANDS"; then
  exit 0
fi

# ── Step 13: Layer 1 — workflow-level exemption ───────────────────────────────
if rtk_is_workflow_exempt "$CWD" "$RTK_EXEMPT_WORKFLOWS"; then
  exit 0
fi

# ── Step 14: Rewrite command with rtk prefix ─────────────────────────────────
# Extract leading VAR=VALUE env-prefix assignments (e.g., RUNE_TRACE=1 cmd)
ENV_PREFIX=""
REST_COMMAND="$COMMAND"
while true; do
  case "$REST_COMMAND" in
    *=*)
      first_word="${REST_COMMAND%% *}"
      # VAR=VALUE pattern: identifier=anything at start, no shell metacharacters in VAR
      if printf '%s\n' "$first_word" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
        # If first_word == REST_COMMAND there was no space — single token, stop
        if [[ "$first_word" == "$REST_COMMAND" ]]; then
          break
        fi
        ENV_PREFIX="${ENV_PREFIX}${first_word} "
        REST_COMMAND="${REST_COMMAND#"$first_word" }"
      else
        break
      fi
      ;;
    *) break ;;
  esac
done

# Build rewritten command:
#   <env-prefixes> RTK_TEE=1 RTK_TEE_MODE=<mode> rtk -- <command>
REWRITTEN="${ENV_PREFIX}RTK_TEE=1 RTK_TEE_MODE=${RTK_TEE_MODE} ${RTK_BIN} -- ${REST_COMMAND}"

jq -n \
  --arg cmd "$REWRITTEN" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "updatedInput": { "command": $cmd },
      "additionalContext": "RTK-001: Command rewritten with rtk prefix for token compression."
    }
  }' || exit 0

exit 0
