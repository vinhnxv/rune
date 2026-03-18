#!/usr/bin/env bash
# plugin-env-inspect.sh — Diagnostic script to inspect plugin environment variables
# and cached/data directories at runtime.
#
# Usage: Called from within plugin context (skill, hook, or agent)
# where CLAUDE_PLUGIN_ROOT and CLAUDE_PLUGIN_DATA are injected by Claude Code.

set -euo pipefail

CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

echo "═══════════════════════════════════════════════"
echo "  Rune Plugin Environment Inspector"
echo "═══════════════════════════════════════════════"
echo ""

# --- Section 1: Environment Variables ---
echo "▸ Plugin Environment Variables"
echo "───────────────────────────────────────────────"
echo "  CLAUDE_PLUGIN_ROOT : ${CLAUDE_PLUGIN_ROOT:-⚠ NOT SET}"
echo "  CLAUDE_PLUGIN_DATA : ${CLAUDE_PLUGIN_DATA:-⚠ NOT SET}"
echo "  CLAUDE_CONFIG_DIR  : ${CLAUDE_CONFIG_DIR:-⚠ NOT SET (default: ~/.claude)}"
echo "  CLAUDE_SESSION_ID  : ${CLAUDE_SESSION_ID:-⚠ NOT SET}"
echo "  CLAUDE_PROJECT_DIR : ${CLAUDE_PROJECT_DIR:-⚠ NOT SET}"
echo "  Resolved CHOME     : ${CHOME}"
echo ""

# --- Section 2: Plugin Root Contents ---
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
  echo "▸ Plugin Root (CLAUDE_PLUGIN_ROOT)"
  echo "───────────────────────────────────────────────"
  echo "  Path: ${CLAUDE_PLUGIN_ROOT}"

  # Top-level dirs
  echo "  Directories:"
  for d in "${CLAUDE_PLUGIN_ROOT}"/*/; do
    [[ -d "$d" ]] && echo "    $(basename "$d")/"
  done

  # Count key components
  agent_count=$(find "${CLAUDE_PLUGIN_ROOT}/agents" -name '*.md' -not -path '*/references/*' 2>/dev/null | wc -l | tr -d ' ')
  skill_count=$(find "${CLAUDE_PLUGIN_ROOT}/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
  command_count=$(find "${CLAUDE_PLUGIN_ROOT}/commands" -name '*.md' -not -path '*/references/*' 2>/dev/null | wc -l | tr -d ' ')
  script_count=$(find "${CLAUDE_PLUGIN_ROOT}/scripts" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
  hook_count=0
  if [[ -f "${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json" ]]; then
    hook_count=$(grep -c '"command"' "${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json" 2>/dev/null || echo "0")
  fi

  echo ""
  echo "  Components:"
  echo "    Agents  : ${agent_count}"
  echo "    Skills  : ${skill_count}"
  echo "    Commands: ${command_count}"
  echo "    Scripts : ${script_count}"
  echo "    Hooks   : ${hook_count}"

  # Plugin manifest
  if [[ -f "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]]; then
    echo ""
    echo "  Manifest (plugin.json):"
    if command -v jq &>/dev/null; then
      jq -r '  "    Name    : \(.name)\n    Version : \(.version)\n    License : \(.license // "N/A")"' \
        "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null || echo "    (jq parse error)"
    else
      grep -E '"(name|version)"' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" | sed 's/^/    /'
    fi
  fi

  # MCP servers
  if [[ -f "${CLAUDE_PLUGIN_ROOT}/.mcp.json" ]]; then
    echo ""
    echo "  MCP Servers (.mcp.json):"
    if command -v jq &>/dev/null; then
      jq -r '.mcpServers // {} | keys[] | "    - \(.)"' "${CLAUDE_PLUGIN_ROOT}/.mcp.json" 2>/dev/null || echo "    (parse error)"
    else
      grep -oE '"[^"]+"\s*:' "${CLAUDE_PLUGIN_ROOT}/.mcp.json" | head -10 | sed 's/^/    /'
    fi
  fi
  echo ""
else
  echo "▸ Plugin Root: ⚠ NOT AVAILABLE (CLAUDE_PLUGIN_ROOT not set or not a directory)"
  echo ""
fi

# --- Section 3: Plugin Data Directory ---
echo "▸ Plugin Data (CLAUDE_PLUGIN_DATA)"
echo "───────────────────────────────────────────────"
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" && -d "${CLAUDE_PLUGIN_DATA}" ]]; then
  echo "  Path: ${CLAUDE_PLUGIN_DATA}"
  file_count=$(find "${CLAUDE_PLUGIN_DATA}" -type f 2>/dev/null | wc -l | tr -d ' ')
  dir_count=$(find "${CLAUDE_PLUGIN_DATA}" -type d -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  total_size=$(du -sh "${CLAUDE_PLUGIN_DATA}" 2>/dev/null | cut -f1)
  echo "  Files       : ${file_count}"
  echo "  Directories : ${dir_count}"
  echo "  Total Size  : ${total_size}"

  if [[ "$file_count" -gt 0 ]]; then
    echo ""
    echo "  Contents (up to 20):"
    find "${CLAUDE_PLUGIN_DATA}" -type f -maxdepth 3 2>/dev/null | head -20 | while read -r f; do
      size=$(du -h "$f" 2>/dev/null | cut -f1)
      echo "    ${f#"${CLAUDE_PLUGIN_DATA}/"} (${size})"
    done
  else
    echo "  (empty — no files stored)"
  fi
elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  echo "  Path: ${CLAUDE_PLUGIN_DATA} (does not exist)"
else
  echo "  ⚠ CLAUDE_PLUGIN_DATA not set"
  # Try to find it via convention
  rune_data="${CHOME}/plugins/data/rune-rune-marketplace"
  if [[ -d "$rune_data" ]]; then
    echo "  Found conventional path: ${rune_data}"
    file_count=$(find "$rune_data" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "  Files: ${file_count}"
  fi
fi
echo ""

# --- Section 4: Plugin Cache ---
echo "▸ Plugin Cache"
echo "───────────────────────────────────────────────"
cache_dir="${CHOME}/plugins/cache"
if [[ -d "$cache_dir" ]]; then
  echo "  Path: ${cache_dir}"
  for d in "${cache_dir}"/*/; do
    if [[ -d "$d" ]]; then
      size=$(du -sh "$d" 2>/dev/null | cut -f1)
      echo "    $(basename "$d")/ — ${size}"
    fi
  done
else
  echo "  (not found)"
fi
echo ""

# --- Section 5: Rune Runtime State ---
echo "▸ Rune Runtime State (tmp/)"
echo "───────────────────────────────────────────────"
if [[ -d "tmp" ]]; then
  # State files
  state_files=$(find tmp -maxdepth 1 -name '.rune-*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "  Active state files : ${state_files}"

  # Talisman resolved
  if [[ -d "tmp/.talisman-resolved" ]]; then
    shard_count=$(find tmp/.talisman-resolved -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    echo "  Talisman shards    : ${shard_count}"
  fi

  # Signals
  if [[ -d "tmp/.rune-signals" ]]; then
    signal_count=$(find tmp/.rune-signals -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "  Signal files       : ${signal_count}"
  fi

  # Total tmp size
  tmp_size=$(du -sh tmp 2>/dev/null | cut -f1)
  echo "  Total tmp/ size    : ${tmp_size}"
else
  echo "  (tmp/ not found)"
fi
echo ""

# --- Section 6: Echoes (Persistent Memory) ---
echo "▸ Rune Echoes (.claude/echoes/)"
echo "───────────────────────────────────────────────"
if [[ -d ".claude/echoes" ]]; then
  for role_dir in .claude/echoes/*/; do
    if [[ -d "$role_dir" ]]; then
      role=$(basename "$role_dir")
      if [[ -f "${role_dir}MEMORY.md" ]]; then
        entry_count=$(grep -c '^## ' "${role_dir}MEMORY.md" 2>/dev/null || echo "0")
        size=$(du -h "${role_dir}MEMORY.md" 2>/dev/null | cut -f1)
        echo "    ${role}: ${entry_count} entries (${size})"
      else
        echo "    ${role}: (no MEMORY.md)"
      fi
    fi
  done
else
  echo "  (not found)"
fi
echo ""

echo "═══════════════════════════════════════════════"
echo "  Inspection complete"
echo "═══════════════════════════════════════════════"
