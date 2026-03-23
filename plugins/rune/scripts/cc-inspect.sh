#!/usr/bin/env bash
# cc-inspect.sh — Claude Code runtime environment inspector.
# Comprehensive diagnostic: session identity, env vars, plugin system,
# toolchain versions, Rune runtime state, and platform details.
#
# Usage: bash cc-inspect.sh [--section <name>] [--json]
#   Sections: env, session, system, plugin, runtime, echoes, all (default)

set -euo pipefail

_CC_INSPECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CC_INSPECT_DIR}/lib/rune-state.sh"

# --- Argument parsing ---
SECTION="all"
JSON_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --section) SECTION="${2:-all}"; shift 2 ;;
    --json)    JSON_MODE=true; shift ;;
    *)         shift ;;
  esac
done

CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- Helper: print or skip section ---
should_show() { [[ "$SECTION" == "all" || "$SECTION" == "$1" ]]; }

# --- Helper: safe version check ---
# SEC-001 FIX: Replace eval with bash -c using allowlist validation
ver() {
  if command -v "$1" &>/dev/null; then
    # Allowlist: only permit safe version-check characters (no metacharacters)
    if [[ "$2" =~ ^[a-zA-Z0-9\ _./:=\'\"\|\-]+$ ]]; then
      bash -c "$2" 2>/dev/null || echo "installed (version unknown)"
    else
      echo "installed (version unknown)"
    fi
  else
    echo "NOT INSTALLED"
  fi
}

# ═══════════════════════════════════════════════
#  Header
# ═══════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════"
echo "  Claude Code Runtime Inspector"
echo "═══════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════
#  Section 1: Session Identity
# ═══════════════════════════════════════════════
if should_show "session"; then
  echo "▸ Session Identity"
  echo "─────────────────────────────────────────────────────"
  echo "  CLAUDE_SESSION_ID  : ${CLAUDE_SESSION_ID:-⚠ NOT SET}"
  echo "  RUNE_SESSION_ID    : ${RUNE_SESSION_ID:-⚠ NOT SET}"
  echo "  PPID (CC PID)      : ${PPID:-⚠ NOT SET}"
  echo "  Current PID        : $$"
  echo "  CLAUDE_CONFIG_DIR  : ${CLAUDE_CONFIG_DIR:-⚠ NOT SET (default: ~/.claude)}"
  echo "  Resolved CHOME     : ${CHOME}"
  echo "  CLAUDE_PROJECT_DIR : ${CLAUDE_PROJECT_DIR:-⚠ NOT SET}"
  echo "  Working Directory  : $(pwd)"

  # Session isolation check
  echo ""
  echo "  Session Isolation:"
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    echo "    ✓ CLAUDE_SESSION_ID is set"
  else
    echo "    ⚠ CLAUDE_SESSION_ID missing — session isolation may not work"
  fi
  if [[ -n "${PPID:-}" ]] && kill -0 "$PPID" 2>/dev/null; then
    echo "    ✓ Parent process (PPID=$PPID) is alive"
  else
    echo "    ⚠ Parent process check failed"
  fi
  if [[ -d "$CHOME" ]]; then
    echo "    ✓ Config dir exists: ${CHOME}"
  else
    echo "    ⚠ Config dir does NOT exist: ${CHOME}"
  fi
  echo ""
fi

# ═══════════════════════════════════════════════
#  Section 2: Claude Code Environment Variables
# ═══════════════════════════════════════════════
if should_show "env"; then
  echo "▸ Claude Code Environment Variables"
  echo "─────────────────────────────────────────────────────"

  # Claude Code core vars
  echo "  [Claude Code Core]"
  echo "  CLAUDE_CONFIG_DIR                      : ${CLAUDE_CONFIG_DIR:-⚠ NOT SET}"
  echo "  CLAUDE_SESSION_ID                      : ${CLAUDE_SESSION_ID:-⚠ NOT SET}"
  echo "  CLAUDE_PROJECT_DIR                     : ${CLAUDE_PROJECT_DIR:-⚠ NOT SET}"
  echo "  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS   : ${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-⚠ NOT SET}"
  echo ""

  # Plugin system vars
  echo "  [Plugin System]"
  echo "  CLAUDE_PLUGIN_ROOT                     : ${CLAUDE_PLUGIN_ROOT:-⚠ NOT SET}"
  echo "  CLAUDE_PLUGIN_DATA                     : ${CLAUDE_PLUGIN_DATA:-⚠ NOT SET}"
  echo ""

  # Rune-specific vars
  echo "  [Rune Runtime]"
  echo "  RUNE_SESSION_ID                        : ${RUNE_SESSION_ID:-⚠ NOT SET}"
  echo "  RUNE_TRACE                             : ${RUNE_TRACE:-⚠ NOT SET (default: off)}"
  echo "  RUNE_TRACE_LOG                         : ${RUNE_TRACE_LOG:-⚠ NOT SET}"
  echo "  RUNE_CLEANUP_DRY_RUN                   : ${RUNE_CLEANUP_DRY_RUN:-⚠ NOT SET (default: off)}"
  echo ""

  # Process & system vars
  echo "  [Process & System]"
  echo "  HOME                                   : ${HOME:-⚠ NOT SET}"
  echo "  USER                                   : ${USER:-⚠ NOT SET}"
  echo "  SHELL                                  : ${SHELL:-⚠ NOT SET}"
  echo "  TERM                                   : ${TERM:-⚠ NOT SET}"
  echo "  LANG                                   : ${LANG:-⚠ NOT SET}"
  echo "  LC_ALL                                 : ${LC_ALL:-⚠ NOT SET}"
  echo "  TMPDIR                                 : ${TMPDIR:-⚠ NOT SET (default: /tmp)}"
  echo "  PPID                                   : ${PPID:-⚠ NOT SET}"
  echo "  SHLVL                                  : ${SHLVL:-⚠ NOT SET}"
  echo ""

  # PATH (truncated)
  echo "  [PATH — first 5 entries]"
  echo "${PATH:-}" | tr ':' '\n' | head -5 | while read -r p; do
    echo "    $p"
  done
  path_total=$(echo "${PATH:-}" | tr ':' '\n' | wc -l | tr -d ' ')
  echo "    ... (${path_total} total entries)"
  echo ""

  # Catch-all: any other CLAUDE_* or RUNE_* vars
  echo "  [Other CLAUDE_*/RUNE_* Variables]"
  other_vars=$(env | grep -E '^(CLAUDE_|RUNE_)' | grep -vE '^(CLAUDE_CONFIG_DIR|CLAUDE_SESSION_ID|CLAUDE_PROJECT_DIR|CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS|CLAUDE_PLUGIN_ROOT|CLAUDE_PLUGIN_DATA|RUNE_SESSION_ID|RUNE_TRACE|RUNE_TRACE_LOG|RUNE_CLEANUP_DRY_RUN)=' 2>/dev/null || true)
  if [[ -n "$other_vars" ]]; then
    echo "$other_vars" | while IFS='=' read -r key val; do
      echo "  $key : $val"
    done
  else
    echo "    (none found)"
  fi
  echo ""
fi

# ═══════════════════════════════════════════════
#  Section 3: System & Toolchain
# ═══════════════════════════════════════════════
if should_show "system"; then
  echo "▸ Platform & System"
  echo "─────────────────────────────────────────────────────"
  echo "  OS              : $(uname -s) $(uname -r)"
  echo "  Architecture    : $(uname -m)"
  echo "  Hostname        : $(hostname 2>/dev/null || echo 'unknown')"
  echo "  Uptime          : $(uptime 2>/dev/null | sed 's/^.*up /up /' | sed 's/,.*load.*//' || echo 'unknown')"
  echo ""

  echo "▸ Toolchain Versions"
  echo "─────────────────────────────────────────────────────"
  echo "  bash            : $(ver bash 'bash --version | head -1 | sed "s/.*version //" | sed "s/ .*//"')"
  echo "  zsh             : $(ver zsh  'zsh --version | cut -d" " -f2')"
  echo "  node            : $(ver node 'node --version')"
  echo "  npm             : $(ver npm  'npm --version')"
  echo "  npx             : $(ver npx  'npx --version')"
  echo "  python3         : $(ver python3 'python3 --version 2>&1 | cut -d" " -f2')"
  echo "  pip3            : $(ver pip3 'pip3 --version 2>&1 | cut -d" " -f2')"
  echo "  git             : $(ver git  'git --version | cut -d" " -f3')"
  echo "  gh              : $(ver gh   'gh --version | head -1 | cut -d" " -f3')"
  echo "  jq              : $(ver jq   'jq --version')"
  echo "  yq              : $(ver yq   'yq --version 2>&1 | head -1')"
  echo "  fd              : $(ver fd   'fd --version | cut -d" " -f2')"
  echo "  rg (ripgrep)    : $(ver rg   'rg --version | head -1 | cut -d" " -f2')"
  echo "  fzf             : $(ver fzf  'fzf --version | cut -d" " -f1')"
  echo "  claude          : $(ver claude 'claude --version 2>&1 | head -1')"
  echo "  rtk             : $(ver rtk  'rtk --version 2>&1 | head -1')"
  echo ""

  # macOS-specific: coreutils
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "  [macOS Extras]"
    echo "  gdate           : $(ver gdate 'gdate --version | head -1')"
    echo "  grealpath       : $(ver grealpath 'grealpath --version | head -1')"
    echo "  timeout         : $(ver timeout 'timeout --version 2>&1 | head -1')"
    echo "  Xcode CLT       : $(xcode-select -p 2>/dev/null && echo 'installed' || echo 'NOT INSTALLED')"
    echo ""
  fi
fi

# ═══════════════════════════════════════════════
#  Section 4: Plugin System
# ═══════════════════════════════════════════════
if should_show "plugin"; then
  echo "▸ Plugin System"
  echo "─────────────────────────────────────────────────────"

  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
    echo "  Plugin Root: ${CLAUDE_PLUGIN_ROOT}"
    echo ""

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
  else
    echo "  ⚠ CLAUDE_PLUGIN_ROOT not set or not a directory"
    echo "    (Plugin env vars are only available when loaded by Claude Code)"
  fi
  echo ""

  # Plugin data
  echo "  Plugin Data (CLAUDE_PLUGIN_DATA):"
  if [[ -n "${CLAUDE_PLUGIN_DATA:-}" && -d "${CLAUDE_PLUGIN_DATA}" ]]; then
    echo "    Path: ${CLAUDE_PLUGIN_DATA}"
    file_count=$(find "${CLAUDE_PLUGIN_DATA}" -type f 2>/dev/null | wc -l | tr -d ' ')
    total_size=$(du -sh "${CLAUDE_PLUGIN_DATA}" 2>/dev/null | cut -f1)
    echo "    Files: ${file_count}, Size: ${total_size}"
  elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    echo "    Path: ${CLAUDE_PLUGIN_DATA} (does not exist)"
  else
    echo "    ⚠ Not set"
    # Convention fallback
    rune_data="${CHOME}/plugins/data/rune-rune-marketplace"
    if [[ -d "$rune_data" ]]; then
      echo "    Found conventional path: ${rune_data}"
      file_count=$(find "$rune_data" -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "    Files: ${file_count}"
    fi
  fi
  echo ""

  # Plugin cache
  echo "  Plugin Cache:"
  cache_dir="${CHOME}/plugins/cache"
  if [[ -d "$cache_dir" ]]; then
    echo "    Path: ${cache_dir}"
    for d in "${cache_dir}"/*/; do
      if [[ -d "$d" ]]; then
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        echo "      $(basename "$d")/ — ${size}"
      fi
    done
  else
    echo "    (not found)"
  fi
  echo ""

  # Installed plugins
  echo "  Installed Plugins:"
  plugins_dir="${CHOME}/plugins"
  if [[ -d "$plugins_dir" ]]; then
    while IFS= read -r manifest; do
      [[ -f "$manifest" ]] || continue
      dir_name=$(basename "$(dirname "$manifest")")
      if command -v jq &>/dev/null; then
        name=$(jq -r '.name // "unknown"' "$manifest" 2>/dev/null)
        version=$(jq -r '.version // "?"' "$manifest" 2>/dev/null)
        echo "    ${name} v${version} (${dir_name}/)"
      else
        echo "    ${dir_name}/"
      fi
    done < <(find "${plugins_dir}" -maxdepth 2 -name 'plugin.json' 2>/dev/null)
  fi
  # Also check .claude-plugin dirs
  while IFS= read -r manifest; do
    [[ -f "$manifest" ]] || continue
    dir_name=$(basename "$(dirname "$(dirname "$manifest")")")
    if command -v jq &>/dev/null; then
      name=$(jq -r '.name // "unknown"' "$manifest" 2>/dev/null)
      version=$(jq -r '.version // "?"' "$manifest" 2>/dev/null)
      echo "    ${name} v${version} (${dir_name}/)"
    fi
  done < <(find "${plugins_dir}" -maxdepth 3 -path '*/.claude-plugin/plugin.json' 2>/dev/null)
  echo ""
fi

# ═══════════════════════════════════════════════
#  Section 5: Rune Runtime State
# ═══════════════════════════════════════════════
if should_show "runtime"; then
  echo "▸ Rune Runtime State"
  echo "─────────────────────────────────────────────────────"
  if [[ -d "tmp" ]]; then
    # State files
    state_files=()
    while IFS= read -r f; do state_files+=("$f"); done < <(find tmp -maxdepth 1 -name '.rune-*.json' 2>/dev/null)
    echo "  Active state files : ${#state_files[@]}"
    for sf in "${state_files[@]}"; do
      echo "    $(basename "$sf")"
    done

    # Talisman resolved
    if [[ -d "tmp/.talisman-resolved" ]]; then
      shard_count=$(find tmp/.talisman-resolved -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
      echo "  Talisman shards    : ${shard_count}"
      if [[ -f "tmp/.talisman-resolved/_meta.json" ]] && command -v jq &>/dev/null; then
        merge_status=$(jq -r '.merge_status // "unknown"' tmp/.talisman-resolved/_meta.json 2>/dev/null)
        resolver=$(jq -r '.resolver_status // "unknown"' tmp/.talisman-resolved/_meta.json 2>/dev/null)
        echo "  Talisman merge     : ${merge_status} (resolver: ${resolver})"
      fi
    fi

    # Signals
    if [[ -d "tmp/.rune-signals" ]]; then
      signal_count=$(find tmp/.rune-signals -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "  Signal files       : ${signal_count}"
      if [[ "$signal_count" -gt 0 && "$signal_count" -le 20 ]]; then
        find tmp/.rune-signals -type f 2>/dev/null | while read -r sf; do
          echo "    $(basename "$sf")"
        done
      elif [[ "$signal_count" -gt 20 ]]; then
        # Show team dirs only when there are many signals
        echo "    (showing team directories only)"
        find tmp/.rune-signals -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r sd; do
          team_signals=$(find "$sd" -type f 2>/dev/null | wc -l | tr -d ' ')
          echo "    $(basename "$sd")/ — ${team_signals} signals"
        done
      fi
    fi

    # Arc checkpoint
    if [[ -d "${RUNE_STATE}/arc" ]]; then
      checkpoint_count=$(find "${RUNE_STATE}/arc" -name 'checkpoint.json' 2>/dev/null | wc -l | tr -d ' ')
      echo "  Arc checkpoints    : ${checkpoint_count}"
    fi

    # Total tmp size
    tmp_size=$(du -sh tmp 2>/dev/null | cut -f1)
    echo "  Total tmp/ size    : ${tmp_size}"
  else
    echo "  (tmp/ not found)"
  fi
  echo ""

  # Active teams
  echo "  Active Teams:"
  teams_dir="${CHOME}/teams"
  if [[ -d "$teams_dir" ]]; then
    team_count=0
    for td in "${teams_dir}"/*/; do
      if [[ -d "$td" ]]; then
        team_name=$(basename "$td")
        echo "    ${team_name}"
        team_count=$((team_count + 1))
      fi
    done
    if [[ "$team_count" -eq 0 ]]; then
      echo "    (none)"
    fi
  else
    echo "    (teams dir not found)"
  fi
  echo ""

  # Talisman config
  echo "  Talisman Config:"
  if [[ -f "${RUNE_STATE}/talisman.yml" ]]; then
    size=$(du -h "${RUNE_STATE}/talisman.yml" 2>/dev/null | cut -f1)
    echo "    Project: ${RUNE_STATE}/talisman.yml (${size})"
  else
    echo "    Project: (not found)"
  fi
  if [[ -f "${CHOME}/talisman.yml" ]]; then
    size=$(du -h "${CHOME}/talisman.yml" 2>/dev/null | cut -f1)
    echo "    Global : ${CHOME}/talisman.yml (${size})"
  else
    echo "    Global : (not found)"
  fi
  echo ""
fi

# ═══════════════════════════════════════════════
#  Section 6: Echoes (Persistent Memory)
# ═══════════════════════════════════════════════
if should_show "echoes"; then
  echo "▸ Rune Echoes (${RUNE_STATE}/echoes/)"
  echo "─────────────────────────────────────────────────────"
  if [[ -d "${RUNE_STATE}/echoes" ]]; then
    total_entries=0
    for role_dir in "${RUNE_STATE}/echoes"/*/; do
      if [[ -d "$role_dir" ]]; then
        role=$(basename "$role_dir")
        if [[ -f "${role_dir}MEMORY.md" ]]; then
          entry_count=$(grep -c '^## ' "${role_dir}MEMORY.md" 2>/dev/null || echo "0")
          size=$(du -h "${role_dir}MEMORY.md" 2>/dev/null | cut -f1)
          echo "    ${role}: ${entry_count} entries (${size})"
          total_entries=$((total_entries + entry_count))
        else
          echo "    ${role}: (no MEMORY.md)"
        fi
      fi
    done
    echo "  Total entries: ${total_entries}"

    # Global echoes
    if [[ -d "${CHOME}/echoes" ]]; then
      global_entries=0
      for role_dir in "${CHOME}/echoes"/*/; do
        if [[ -d "$role_dir" ]]; then
          if [[ -f "${role_dir}MEMORY.md" ]]; then
            count=$(grep -c '^## ' "${role_dir}MEMORY.md" 2>/dev/null || echo "0")
            global_entries=$((global_entries + count))
          fi
        fi
      done
      echo "  Global echoes: ${global_entries} entries"
    fi
  else
    echo "  (not found)"
  fi
  echo ""
fi

# ═══════════════════════════════════════════════
#  Footer
# ═══════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════"
echo "  Inspection complete — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"
