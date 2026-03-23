#!/bin/bash
# session-start.sh — Loads using-rune skill content at session start
# Ensures Rune workflow routing is available from the very first message.
# Runs synchronously (async: false) so content is present before user's first prompt.
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

# ── EXIT trap: ensure hookEventName is always emitted (prevents "hook error") ──
_HOOK_JSON_SENT=false
_rune_session_hook_exit() {
  if [[ "$_HOOK_JSON_SENT" != "true" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart"}}\n'
  fi
}
trap '_rune_session_hook_exit' EXIT

# ── Opt-in trace logging ──
_trace() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && echo "[session-start] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${PLUGIN_ROOT}/scripts/lib/rune-state.sh"

# ── Shared venv setup (hash-guarded, lives in CLAUDE_CONFIG_DIR) ──
# shellcheck source=lib/rune-venv.sh
RUNE_REQUIREMENTS="${PLUGIN_ROOT}/scripts/requirements.txt"
if [[ -f "$RUNE_REQUIREMENTS" ]] && command -v python3 &>/dev/null; then
  source "${PLUGIN_ROOT}/scripts/lib/rune-venv.sh" 2>/dev/null || true
  if type rune_resolve_venv &>/dev/null; then
    RUNE_PYTHON=$(rune_resolve_venv "$RUNE_REQUIREMENTS")
    if [[ -x "$RUNE_PYTHON" ]] && "$RUNE_PYTHON" -c "import yaml" 2>/dev/null; then
      _trace "[ensure-venv] OK: venv ready at ${RUNE_PYTHON%/bin/python3}"
    else
      _trace "[ensure-venv] WARN: venv setup incomplete"
    fi
  fi
fi

SKILL_FILE="${PLUGIN_ROOT}/skills/using-rune/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  exit 0
fi

# ── Read hook input for event type + session_id extraction ──
INPUT=$(head -c 1048576 2>/dev/null || true)
EVENT=""
SESSION_ID=""
if command -v jq &>/dev/null; then
  EVENT=$(printf '%s\n' "$INPUT" | jq -r '.event // empty' 2>/dev/null || true)
  SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
fi

# ── Env injection into Bash tool environment ──
# Workaround: $CLAUDE_SESSION_ID and $CLAUDE_PLUGIN_ROOT are NOT available as
# shell env vars in Bash() tool calls. Hooks receive them in stdin JSON or as
# process env, so we bridge them to $CLAUDE_ENV_FILE making them available to
# Bash() calls as $RUNE_SESSION_ID and $RUNE_PLUGIN_ROOT.
# NOTE: Hook scripts (.sh) do NOT source CLAUDE_ENV_FILE — they get these values
# from stdin JSON / BASH_SOURCE instead. This bridge only helps Bash tool context in skills.
# Guard: only write once per session (idempotent on resume/clear/compact).
# SEC: Validate all values before writing to env file (shell injection prevention).
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  # SEC-004: Canonicalize CLAUDE_ENV_FILE and validate it resides under the expected config dir.
  # Prevents path traversal attacks where a malicious CLAUDE_ENV_FILE writes to arbitrary locations.
  _real_env_file="$(cd "$(dirname "$CLAUDE_ENV_FILE")" 2>/dev/null && pwd -P)/$(basename "$CLAUDE_ENV_FILE")" 2>/dev/null || true
  _expected_prefix="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [[ -n "$_real_env_file" ]] && [[ "$_real_env_file" == "$_expected_prefix"/* ]]; then
    # Bridge RUNE_SESSION_ID
    # COMPAT: Bash 3.2 (macOS) does not support {n,m} quantifiers in [[ =~ ]].
    # Use + quantifier and length check instead.
    if [[ -n "$SESSION_ID" ]] && [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ ${#SESSION_ID} -le 128 ]]; then
      if ! grep -q "RUNE_SESSION_ID" "$CLAUDE_ENV_FILE" 2>/dev/null; then
        printf 'export RUNE_SESSION_ID="%s"\n' "$SESSION_ID" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
        _trace "Injected RUNE_SESSION_ID=${SESSION_ID} into CLAUDE_ENV_FILE"
      fi
    else
      _trace "WARN: session_id failed format validation, skipping env injection: '${SESSION_ID:0:32}'"
    fi

    # Bridge RUNE_PLUGIN_ROOT — makes ${RUNE_PLUGIN_ROOT} available in Bash() tool calls.
    # CLAUDE_PLUGIN_ROOT is only available in hook script execution, not in Bash() tool context.
    # SEC: PLUGIN_ROOT is derived from CLAUDE_PLUGIN_ROOT or BASH_SOURCE (line 40), both trusted.
    # Validate: must be an absolute path containing /scripts/ dir, no shell metacharacters.
    # Path varies: /repo/plugins/rune (dev) vs ~/.claude/plugins/cache/.../rune/2.11.0 (installed).
    if [[ -n "$PLUGIN_ROOT" ]] && [[ "$PLUGIN_ROOT" == /* ]] && [[ -d "$PLUGIN_ROOT/scripts" ]] && [[ ! "$PLUGIN_ROOT" =~ [\;\|\&\$\`] ]]; then
      if ! grep -q "RUNE_PLUGIN_ROOT" "$CLAUDE_ENV_FILE" 2>/dev/null; then
        printf 'export RUNE_PLUGIN_ROOT="%s"\n' "$PLUGIN_ROOT" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
        _trace "Injected RUNE_PLUGIN_ROOT=${PLUGIN_ROOT} into CLAUDE_ENV_FILE"
      fi
    else
      _trace "WARN: PLUGIN_ROOT validation failed, skipping env injection: '${PLUGIN_ROOT:0:64}'"
    fi
  else
    _trace "WARN: CLAUDE_ENV_FILE path validation failed, skipping env injection: '${CLAUDE_ENV_FILE}'"
  fi
fi

# Read skill content, strip frontmatter
CONTENT=""
IN_FRONTMATTER=false
PAST_FRONTMATTER=false
while IFS= read -r line; do
  if [ "$PAST_FRONTMATTER" = true ]; then
    CONTENT="${CONTENT}${line}
"
  elif [ "$IN_FRONTMATTER" = true ] && [ "$line" = "---" ]; then
    PAST_FRONTMATTER=true
  elif [ "$IN_FRONTMATTER" = false ] && [ "$line" = "---" ]; then
    IN_FRONTMATTER=true
  fi
done < "$SKILL_FILE"

# ── CWD resolution (runs for ALL events, not just startup) ──
# Must be resolved BEFORE echo injection
CWD=""
if command -v jq &>/dev/null; then
  CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
# SEC-006: Canonicalize CWD before use in path construction
[[ -n "$CWD" ]] && CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD=""

# ── Migrate legacy .claude/ state to .rune/ (one-time, idempotent) ──
if [[ -n "$CWD" ]]; then
  _rune_migrate_legacy "$CWD"
fi

# ── Worktree detection advisory ──
# .git is a FILE (not directory) in both git worktrees and submodules.
# Distinguish by content: worktrees contain "gitdir: .../worktrees/..." path.
_WT_ADVISORY=""
if [[ -n "$CWD" && -f "$CWD/.git" ]]; then
  _git_content=$(head -1 "$CWD/.git" 2>/dev/null)
  if [[ "$_git_content" == "gitdir: "* && "$_git_content" == *"/worktrees/"* ]]; then
    if [[ -f "$CWD/${RUNE_STATE}/talisman.yml" ]] || [[ -f "$CWD/.claude/talisman.yml" ]]; then
      _WT_ADVISORY="\\n[Rune Worktree Mode] Running in git worktree. Config synced from main repo."
    else
      _WT_ADVISORY="\\n[Rune Worktree Mode] WARNING: .rune/talisman.yml missing — using defaults. Run from main repo or add WorktreeCreate hook."
    fi
  fi
fi

# ── Phase 2: Echo summary injection ──
ECHO_SUMMARY=""
inject_echo_summary() {
  [[ -n "$CWD" ]] || return 0

  # Gate: talisman config check (grep-based, no yq dependency)
  local talisman="${CWD}/${RUNE_STATE}/talisman.yml"
  if [[ -f "$talisman" && ! -L "$talisman" ]]; then
    local sess_sum=$(grep -A1 'session_summary:' "$talisman" 2>/dev/null | grep -o 'false' || true)
    [[ "$sess_sum" == "false" ]] && return 0
  fi

  local echo_dir="${CWD}/${RUNE_STATE}/echoes"
  [[ -d "$echo_dir" && ! -L "$echo_dir" ]] || return 0

  local summary=""
  local count=0
  local max_entries=10
  local max_chars=1200
  local total_chars=0

  # Collect entries from all role directories
  # Portable nullglob: shopt -s for bash, restore after loop
  shopt -s nullglob
  for role_dir in "$echo_dir"/*/; do
    [[ -d "$role_dir" ]] || continue
    local mem="${role_dir}MEMORY.md"
    [[ -f "$mem" && ! -L "$mem" ]] || continue

    # Parse entries: match any ### heading, then check layer on next lines
    # Entry format: ### [YYYY-MM-DD] {type}: {description}
    #               - **layer**: etched|inscribed|observations
    # Use glob matching (==), NOT regex (=~) for markdown bold
    # Bash regex treats ** as quantifier; glob treats ** as literal via quoting
    local current_title=""
    while IFS= read -r line; do
      if [[ "$line" == "### "* ]]; then
        current_title="$line"
      elif [[ -n "$current_title" && "$line" == *"**layer**: etched"* ]]; then
        # Etched entry — always include (highest priority)
        summary="${summary}- ${current_title#\#\#\# }\\n"
        total_chars=$((total_chars + ${#current_title}))
        count=$((count + 1))
        current_title=""
      elif [[ -n "$current_title" && "$line" == *"**layer**: inscribed"* ]]; then
        # Inscribed entry — include if under budget
        summary="${summary}- ${current_title#\#\#\# }\\n"
        total_chars=$((total_chars + ${#current_title}))
        count=$((count + 1))
        current_title=""
      elif [[ -n "$current_title" && "$line" == *"**layer**: observations"* ]]; then
        # Observations entry — include promoted/frequently-accessed entries
        summary="${summary}- ${current_title#\#\#\# }\\n"
        total_chars=$((total_chars + ${#current_title}))
        count=$((count + 1))
        current_title=""
      elif [[ "$line" == "### "* || "$line" == "## "* ]]; then
        current_title=""  # Reset on next heading
      fi
      [[ "$count" -ge "$max_entries" || "$total_chars" -ge "$max_chars" ]] && break 2
    done < "$mem"
  done
  shopt -u nullglob

  [[ "$count" -gt 0 ]] && ECHO_SUMMARY="\\n\\n## Echo Learnings (${count} entries)\\n${summary}"
}

# Call within fail-forward context — errors caught by ERR trap
inject_echo_summary 2>/dev/null || true

# JSON-escape the content (jq handles all control chars per RFC 8259)
if command -v jq &>/dev/null; then
  ESCAPED_CONTENT=$(printf '%s' "$CONTENT" | jq -Rs '.' | sed 's/^"//;s/"$//')
else
  # QUAL-006 FIX: Fallback when jq is unavailable. Covers the 6 named JSON
  # control characters (\\, ", \n, \r, \t, \b, \f) plus strips remaining C0
  # control chars (U+0000-U+001F) via tr. This handles 99% of real-world
  # SKILL.md content. Edge case: Unicode escape sequences (\uXXXX) are NOT
  # generated — jq is the preferred path for full RFC 8259 compliance.
  json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # Strip any remaining control chars not covered above (null, BEL, etc.)
    s=$(printf '%s' "$s" | tr -d '\000-\010\016-\037')
    printf '%s' "$s"
  }
  ESCAPED_CONTENT=$(json_escape "$CONTENT")
fi

# ── Build session context prefix (session_id for conversation context) ──
SESSION_CTX=""
if [[ -n "$SESSION_ID" ]]; then
  SESSION_CTX="\\nRUNE_SESSION_ID=${SESSION_ID}"
fi

# Output as hookSpecificOutput with additionalContext
# This injects the skill routing table into Claude's context
# Echo summary appended if available (P2: Session-Start Echo Summary Injection)
# Session ID appended if available (P3: Session ID Bridge Injection)
_HOOK_JSON_SENT=true
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[Rune Plugin Active] ${ESCAPED_CONTENT}${ECHO_SUMMARY}${SESSION_CTX}${_WT_ADVISORY}"}}
EOF

# Statusline configuration diagnostic (startup only, non-blocking)
# CWD already resolved unconditionally above for echo injection
if [[ "$EVENT" == "startup" ]]; then
  # Read context_monitor.enabled from talisman (graceful degradation — no yq required)
  CTX_ENABLED="true"
  if [[ -n "$CWD" ]]; then
    TALISMAN_FILE="${CWD}/${RUNE_STATE}/talisman.yml"
    if [[ -f "$TALISMAN_FILE" && ! -L "$TALISMAN_FILE" ]]; then
      _val=$(grep -A1 'context_monitor:' "$TALISMAN_FILE" 2>/dev/null | grep 'enabled:' | grep -o 'false' || true)
      [[ "$_val" == "false" ]] && CTX_ENABLED="false"
    fi
  fi
  if [[ "${CTX_ENABLED:-true}" != "false" ]]; then
    RECENT_BRIDGE=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "rune-ctx-*.json" -mmin -60 2>/dev/null | head -1)
    if [[ -z "$RECENT_BRIDGE" ]]; then
      _trace "NOTE: No recent bridge file found. Context monitoring requires statusline configuration."
    fi
  fi
fi
