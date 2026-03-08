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

# ── Opt-in trace logging ──
_trace() {
  if [[ "${RUNE_TRACE:-}" == "1" ]]; then
    local _log="${RUNE_TRACE_LOG:-${TMPDIR:-/tmp}/rune-hook-trace-$(id -u).log}"
    [[ ! -L "$_log" ]] && echo "[session-start] $*" >> "$_log" 2>/dev/null
  fi
  return 0
}

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILL_FILE="${PLUGIN_ROOT}/skills/using-rune/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  exit 0
fi

# ── Read hook input for event type extraction ──
INPUT=$(head -c 1048576 2>/dev/null || true)
EVENT=""
if command -v jq &>/dev/null; then
  EVENT=$(printf '%s\n' "$INPUT" | jq -r '.event // empty' 2>/dev/null || true)
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

# ── Phase 2: Echo summary injection ──
ECHO_SUMMARY=""
inject_echo_summary() {
  [[ -n "$CWD" ]] || return 0

  # Gate: talisman config check (grep-based, no yq dependency)
  local talisman="${CWD}/.claude/talisman.yml"
  if [[ -f "$talisman" && ! -L "$talisman" ]]; then
    local sess_sum=$(grep -A1 'session_summary:' "$talisman" 2>/dev/null | grep -o 'false' || true)
    [[ "$sess_sum" == "false" ]] && return 0
  fi

  local echo_dir="${CWD}/.claude/echoes"
  [[ -d "$echo_dir" && ! -L "$echo_dir" ]] || return 0

  local summary=""
  local count=0
  local max_entries=5
  local max_chars=500
  local total_chars=0

  # Collect entries from all role directories
  # zsh glob compat: *(N)/ provides nullglob behavior
  for role_dir in "$echo_dir"/*(N)/; do
    [[ -d "$role_dir" ]] || continue
    local mem="${role_dir}MEMORY.md"
    [[ -f "$mem" && ! -L "$mem" ]] || continue

    # Parse entries: match title heading, then check layer on next lines
    # Entry format: ### [YYYY-MM-DD] Pattern: {description}
    #               - **layer**: etched|inscribed
    # Use glob matching (==), NOT regex (=~) for markdown bold
    # Bash regex treats ** as quantifier; glob treats ** as literal via quoting
    local current_title=""
    while IFS= read -r line; do
      if [[ "$line" == "### "* && "$line" == *"Pattern:"* ]]; then
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
      elif [[ "$line" == "### "* || "$line" == "## "* ]]; then
        current_title=""  # Reset on next heading
      fi
      [[ "$count" -ge "$max_entries" || "$total_chars" -ge "$max_chars" ]] && break 2
    done < "$mem"
  done

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

# Output as hookSpecificOutput with additionalContext
# This injects the skill routing table into Claude's context
# Echo summary appended if available (P2: Session-Start Echo Summary Injection)
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[Rune Plugin Active] ${ESCAPED_CONTENT}${ECHO_SUMMARY}"}}
EOF

# Statusline configuration diagnostic (startup only, non-blocking)
# CWD already resolved unconditionally above for echo injection
if [[ "$EVENT" == "startup" ]]; then
  # Read context_monitor.enabled from talisman (graceful degradation — no yq required)
  CTX_ENABLED="true"
  if [[ -n "$CWD" ]]; then
    TALISMAN_FILE="${CWD}/.claude/talisman.yml"
    if [[ -f "$TALISMAN_FILE" && ! -L "$TALISMAN_FILE" ]]; then
      _val=$(grep -A1 'context_monitor:' "$TALISMAN_FILE" 2>/dev/null | grep 'enabled:' | grep -o 'false' || true)
      [[ "$_val" == "false" ]] && CTX_ENABLED="false"
    fi
  fi
  if [[ "${CTX_ENABLED:-true}" != "false" ]]; then
    RECENT_BRIDGE=$(find /tmp -maxdepth 1 -name "rune-ctx-*.json" -mmin -60 2>/dev/null | head -1)
    if [[ -z "$RECENT_BRIDGE" ]]; then
      _trace "NOTE: No recent bridge file found. Context monitoring requires statusline configuration."
    fi
  fi
fi
