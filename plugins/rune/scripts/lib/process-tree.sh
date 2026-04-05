#!/bin/bash
# scripts/lib/process-tree.sh
# Centralized process tree kill logic for Rune cleanup.
#
# USAGE:
#   source "${SCRIPT_DIR}/lib/process-tree.sh"
#   _rune_collect_descendants "$PPID"   # populates _RUNE_DESC_PIDS array
#   _rune_kill_tree "$PPID" "2stage" "5" "claude"
#
# DESIGN:
#   - Recursive pgrep -P walk with max depth 8
#   - 2-stage SIGTERM→SIGKILL with PID recycling guard (lstart comparison)
#   - Filter mode: "all" (default) or "claude" (node|claude|claude-* only)
#   - MCP/LSP server protection: broad mcp-*/mcp_*/--stdio/--lsp pattern (MCP-PROTECT-001)
#   - Uses parallel indexed arrays (Bash 3.2 compatible — no declare -A)
#   - Sources lib/platform.sh for _RUNE_PLATFORM and _proc_name if not defined
#
# SOURCING GUARD: Safe to source multiple times (idempotent).

[[ -n "${_RUNE_PROCESS_TREE_LOADED:-}" ]] && return 0
_RUNE_PROCESS_TREE_LOADED=1

# Source platform.sh for _RUNE_PLATFORM if not already loaded
_RUNE_PT_DIR="${BASH_SOURCE[0]%/*}"
if [[ -z "${_RUNE_PLATFORM:-}" ]]; then
  # shellcheck source=platform.sh
  source "${_RUNE_PT_DIR}/platform.sh"
fi

# Cross-platform process name retrieval (CLD-003 pattern from on-session-stop.sh)
# Only define if not already defined by the sourcing script.
if ! declare -f _proc_name &>/dev/null; then
  _proc_name() {
    local pid="$1"
    if [[ -r "/proc/$pid/comm" ]]; then
      cat "/proc/$pid/comm" 2>/dev/null
    else
      ps -p "$pid" -o comm= 2>/dev/null
    fi
  }
fi

# MCP/LSP server process detection (MCP-PROTECT-001, enhanced MCP-PROTECT-003, MCP-PROTECT-004)
# Returns 0 if the process is an MCP/LSP server, 1 otherwise.
#
# 3-layer detection strategy:
#   Layer 1 — Known binary whitelist (highest confidence, from .mcp.json + common servers)
#   Layer 2 — Transport/protocol markers (--stdio, --lsp, --sse, --transport)
#   Layer 3 — Generic MCP/LSP pattern matching (broad catch-all)
#
# Checks are ordered from most-specific to least-specific for fast early exit.
_is_mcp_server() {
  local pid="$1"
  [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && return 1
  local cmdline
  # Cross-platform: /proc on Linux, ps on macOS
  if [[ -r "/proc/$pid/cmdline" ]]; then
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  else
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
  fi
  [[ -z "$cmdline" ]] && return 1

  # ── Layer 1: Known binary whitelist (MCP-PROTECT-004) ──
  # Comprehensive whitelist of known MCP/LSP server binaries and paths.
  # Organized by: Rune → Anthropic official → npm scoped → third-party → LSP.
  # When adding new entries, place them in the correct category.
  case "$cmdline" in
    # ─ Rune plugin MCP servers (plugins/rune/.mcp.json) ─
    *echo-search/server.py*) return 0 ;;
    *agent-search/server.py*) return 0 ;;
    *figma-to-react/server.py*) return 0 ;;
    *pace_mcp_server*) return 0 ;;
    *context7-mcp*|*context7*) return 0 ;;
    *figma-developer-mcp*|*figma-context*) return 0 ;;

    # ─ Anthropic official MCP servers ─
    *sequential-thinking*) return 0 ;;
    *@anthropic-ai/*) return 0 ;;

    # ─ npm scoped MCP packages (official registries) ─
    *@modelcontextprotocol/*) return 0 ;;   # server-filesystem, server-git, server-memory, server-fetch, server-time, server-everything
    *@upstash/*) return 0 ;;               # context7-mcp, ratelimit-mcp
    *@playwright/*) return 0 ;;            # playwright MCP
    *@cloudflare/*) return 0 ;;            # cloudflare workers MCP
    *@stripe/*) return 0 ;;               # stripe MCP

    # ─ Figma ecosystem ─
    *figma-developer*|*figma_*) return 0 ;;

    # ─ Database & data MCP servers ─
    *postgres-mcp*|*mcp-server-postgres*) return 0 ;;
    *supabase-mcp*|*supabase*server*) return 0 ;;
    *sqlite-mcp*|*mcp-server-sqlite*) return 0 ;;
    *mysql-mcp*|*mcp-server-mysql*) return 0 ;;
    *redis-mcp*|*mcp-server-redis*) return 0 ;;
    *neo4j-mcp*|*qdrant-mcp*|*meilisearch-mcp*) return 0 ;;
    *chroma-mcp*|*claude-mem*) return 0 ;;

    # ─ Cloud & infrastructure MCP servers ─
    *stripe-mcp*|*stripe*server*) return 0 ;;
    *aws-mcp*|*vercel-mcp*|*cloudflare-mcp*) return 0 ;;
    *github-mcp*|*notion-mcp*|*linear-mcp*|*slack-mcp*) return 0 ;;
    *jira-mcp*|*asana-mcp*|*salesforce-mcp*) return 0 ;;

    # ─ Browser automation MCP servers ─
    *puppeteer-mcp*|*playwright-mcp*|*browserbase-mcp*) return 0 ;;

    # ─ Search & web MCP servers ─
    *tavily-mcp*|*exa-mcp*|*firecrawl-mcp*) return 0 ;;
    *e2b-mcp*) return 0 ;;

    # ─ UI component library MCP servers ─
    *untitledui*) return 0 ;;

    # ─ Common LSP servers ─
    *typescript-language-server*|*tsserver*) return 0 ;;
    *pyright*|*pylsp*|*python-lsp*|*jedi-language*) return 0 ;;
    *rust-analyzer*) return 0 ;;
    *gopls*) return 0 ;;
    *vscode-*-language*|*vscode-langservers*) return 0 ;;
    *lua-language-server*) return 0 ;;
    *eslint*language*|*tailwindcss*language*|*cssmodules*language*) return 0 ;;
    *clangd*|*ccls*) return 0 ;;
    *solargraph*|*ruby-lsp*) return 0 ;;
    *intelephense*|*phpactor*) return 0 ;;
    *yaml-language*|*json-language*|*html-language*) return 0 ;;
  esac

  # ── Layer 2: Transport/protocol markers (most reliable generic detection) ──
  # MCP stdio transport — the dominant transport mode for local MCP servers
  case "$cmdline" in *--stdio*) return 0 ;; esac
  # LSP flag
  case "$cmdline" in *--lsp*) return 0 ;; esac
  # SSE transport and explicit transport flag (MCP over HTTP)
  case "$cmdline" in *--sse*|*--transport*stdio*|*--transport*sse*) return 0 ;; esac

  # ── Layer 3: Generic MCP/LSP pattern matching (broad catch-all) ──
  # Covers any process with "mcp" as a hyphenated/underscored component in its path/args.
  # Both directions: "mcp-foo" (prefix, e.g. mcp-remote) and "foo-mcp" (suffix, e.g. context7-mcp).
  # Safe: teammate processes (node claude-code args) never have "mcp" in their cmdline.
  case "$cmdline" in
    *mcp-*|*mcp_*|*-mcp|*-mcp\ *|*_mcp|*_mcp\ *) return 0 ;;
  esac

  # Python processes running MCP servers (uvicorn, python -m mcp, FastMCP)
  case "$cmdline" in
    *python*mcp*) return 0 ;;
    *uvicorn*) return 0 ;;
    *fastmcp*) return 0 ;;
  esac

  # Claude Code's own connector processes (not teammates)
  case "$cmdline" in
    *@anthropic*connector*|*claude-connector*) return 0 ;;
  esac

  return 1
}

# _describe_process <pid>
# Returns a human-readable description of a process: "PID comm args_prefix"
# Used for trace logging before any kill decision. Read-first, kill-second.
_describe_process() {
  local pid="$1"
  [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && return 0
  local comm args
  comm=$(_proc_name "$pid" 2>/dev/null || echo "?")
  if [[ -r "/proc/$pid/cmdline" ]]; then
    args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 200 || true)
  else
    args=$(ps -p "$pid" -o args= 2>/dev/null | head -c 200 || true)
  fi
  printf 'pid=%s comm=%s args="%s"' "$pid" "$comm" "${args:-?}"
}

# _collect_teammate_pids <team_name>
# Returns confirmed Rune teammate PIDs from two sources:
#   (1) SDK team config.json members[].pid
#   (2) Rune activity signal files (written by track-teammate-activity.sh)
# Returns empty if no teammate PIDs can be identified (caller falls back to negative filter).
#
# MCP-PROTECT-003: Positive identification — only PIDs from these sources are kill targets.
# Each candidate PID is VERIFIED before being returned:
#   - Must be alive (kill -0)
#   - Must look like a Claude Code process (node|claude|claude-*)
#   - Must NOT be an MCP/LSP server
# This ensures the caller receives a pre-validated list — no blind kills.
_collect_teammate_pids() {
  local team_name="$1"
  [[ -z "$team_name" || ! "$team_name" =~ ^[a-zA-Z0-9_-]+$ ]] && return 0
  local chome="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local pids_raw=""

  # Source 1: SDK team config
  local cfg="${chome}/teams/${team_name}/config.json"
  if [[ -f "$cfg" && ! -L "$cfg" ]]; then
    local member_pids
    member_pids=$(jq -r '.members[]?.pid // empty' "$cfg" 2>/dev/null || true)
    if [[ -n "$member_pids" ]]; then
      pids_raw="${pids_raw}${member_pids}"$'\n'
    fi
  fi

  # Source 2: Rune activity signal files (written by track-teammate-activity.sh)
  local sig_dir="${_RUNE_PT_CWD:-$PWD}/tmp/.rune-signals/${team_name}"
  if [[ -d "$sig_dir" && ! -L "$sig_dir" ]]; then
    local pf sp
    # ZSH-001: Protect glob from NOMATCH fatal error
    local _orig_ng=""
    if shopt -q nullglob 2>/dev/null; then _orig_ng="on"; else shopt -s nullglob 2>/dev/null || true; fi
    for pf in "${sig_dir}"/*.pid; do
      [[ -f "$pf" && ! -L "$pf" ]] || continue
      sp=$(cat "$pf" 2>/dev/null || true)
      [[ "$sp" =~ ^[0-9]+$ ]] && pids_raw="${pids_raw}${sp}"$'\n'
    done
    [[ "$_orig_ng" != "on" ]] && shopt -u nullglob 2>/dev/null || true
  fi

  # Deduplicate candidate PIDs
  local candidates
  candidates=$(printf '%s\n' "$pids_raw" | grep -E '^[0-9]+$' | sort -u 2>/dev/null || true)
  [[ -z "$candidates" ]] && return 0

  # VERIFY each candidate before returning — read-first, kill-second discipline
  local candidate_pid candidate_comm
  while IFS= read -r candidate_pid; do
    [[ -z "$candidate_pid" ]] && continue

    # 1. Must be alive
    kill -0 "$candidate_pid" 2>/dev/null || continue

    # 2. Must look like a Claude Code teammate process
    candidate_comm=$(_proc_name "$candidate_pid" 2>/dev/null || true)
    case "$candidate_comm" in
      node|claude|claude-*) ;;
      *)
        # Trace: candidate PID is not a Claude process — skip
        if [[ "${RUNE_TRACE:-}" == "1" ]]; then
          printf '[process-tree] SKIP candidate %s — not a Claude process (comm=%s)\n' \
            "$candidate_pid" "$candidate_comm" >&2
        fi
        continue
        ;;
    esac

    # 3. Must NOT be an MCP/LSP server (double safety net)
    if _is_mcp_server "$candidate_pid"; then
      if [[ "${RUNE_TRACE:-}" == "1" ]]; then
        printf '[process-tree] SKIP candidate %s — MCP/LSP server detected\n' "$candidate_pid" >&2
      fi
      continue
    fi

    # All checks passed — this is a verified teammate PID
    if [[ "${RUNE_TRACE:-}" == "1" ]]; then
      printf '[process-tree] VERIFIED teammate: %s\n' "$(_describe_process "$candidate_pid")" >&2
    fi
    printf '%s\n' "$candidate_pid"
  done <<< "$candidates"
}

# _RUNE_DESC_PIDS — populated by _rune_collect_descendants
_RUNE_DESC_PIDS=()

# _rune_collect_descendants <parent_pid> [depth]
# Recursive pgrep -P walk. Populates _RUNE_DESC_PIDS with all descendant PIDs.
# Max depth 8 to prevent runaway recursion.
_rune_collect_descendants() {
  local parent_pid="$1"
  local depth="${2:-0}"
  local max_depth=8

  [[ -z "$parent_pid" || ! "$parent_pid" =~ ^[0-9]+$ ]] && return 0
  [[ "$depth" -ge "$max_depth" ]] && return 0

  local children
  children=$(pgrep -P "$parent_pid" 2>/dev/null || true)
  [[ -z "$children" ]] && return 0

  local child_pid
  while IFS= read -r child_pid; do
    [[ -z "$child_pid" ]] && continue
    [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
    _RUNE_DESC_PIDS+=("$child_pid")
    _rune_collect_descendants "$child_pid" "$((depth + 1))"
  done <<< "$children"
}

# _rune_kill_tree <root_pid> <mode> [grace_seconds] [filter] [team_name]
#
# Kills process tree rooted at root_pid.
#
# Parameters:
#   root_pid       — PID whose children to kill (the root itself is NOT killed)
#   mode           — "2stage" (SIGTERM then SIGKILL) or "term" (SIGTERM only)
#   grace_seconds  — seconds between SIGTERM and SIGKILL (default: 5)
#   filter         — "all" (kill all descendants), "claude" (only node|claude|claude-*),
#                    or "teammates" (MCP-PROTECT-003: positive PID whitelist from team config)
#   team_name      — required when filter="teammates"; the team name to look up PIDs for
#
# Returns: number of processes killed (echoed to stdout)
#
# Uses parallel indexed arrays for Bash 3.2 compatibility (no declare -A).
# XVER-001: lstart-based PID recycling detection between SIGTERM and SIGKILL.
_rune_kill_tree() {
  local root_pid="$1"
  local mode="${2:-2stage}"
  local grace="${3:-5}"
  local filter="${4:-all}"
  local team_name="${5:-}"
  local killed=0

  [[ -z "$root_pid" || ! "$root_pid" =~ ^[0-9]+$ ]] && echo "0" && return 0

  # Validate root_pid is alive.
  # When root is dead, its children are re-parented to PID 1 (init/launchd).
  # pgrep -P on a dead PID returns nothing — orphaned grandchildren are not
  # targetable via this tree walk. This is by design: re-parented processes
  # belong to the OS, not to our session.
  if ! kill -0 "$root_pid" 2>/dev/null; then
    echo "0"
    return 0
  fi

  # Collect all descendants
  _RUNE_DESC_PIDS=()
  _rune_collect_descendants "$root_pid"
  [[ ${#_RUNE_DESC_PIDS[@]} -eq 0 ]] && echo "0" && return 0

  # Phase 1: SIGTERM eligible descendants
  # Parallel arrays for PID recycling guard (Bash 3.2 — no associative arrays)
  local _kill_pids=()
  local _kill_lstarts=()

  # MCP-PROTECT-003: Build teammate PID whitelist for "teammates" filter
  local _whitelist_pids=""
  local _whitelist_available=false
  if [[ "$filter" == "teammates" && -n "$team_name" ]]; then
    _whitelist_pids=$(_collect_teammate_pids "$team_name")
    if [[ -n "$_whitelist_pids" ]]; then
      _whitelist_available=true
      if [[ "${RUNE_TRACE:-}" == "1" ]]; then
        local _wl_count
        _wl_count=$(printf '%s\n' "$_whitelist_pids" | wc -l | tr -d ' ')
        printf '[process-tree] Teammate whitelist for team=%s: %s verified PID(s)\n' \
          "$team_name" "$_wl_count" >&2
      fi
    else
      if [[ "${RUNE_TRACE:-}" == "1" ]]; then
        printf '[process-tree] No teammate whitelist for team=%s — falling back to claude filter\n' \
          "$team_name" >&2
      fi
    fi
    # If no whitelist available, fall back to "claude" filter behavior
  fi

  local pid child_comm child_lstart
  for pid in "${_RUNE_DESC_PIDS[@]}"; do
    [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue

    # Apply filter
    if [[ "$filter" == "teammates" ]]; then
      if [[ "$_whitelist_available" == "true" ]]; then
        # Positive filter: only kill PIDs in the whitelist
        if ! printf '%s\n' "$_whitelist_pids" | grep -qx "$pid"; then
          continue
        fi
      else
        # Fallback: no whitelist available — use "claude" filter with enhanced MCP detection
        child_comm=$(_proc_name "$pid")
        case "$child_comm" in
          node|claude|claude-*) ;;
          *) continue ;;
        esac
        if _is_mcp_server "$pid"; then
          continue
        fi
      fi
    elif [[ "$filter" == "claude" ]]; then
      child_comm=$(_proc_name "$pid")
      case "$child_comm" in
        node|claude|claude-*) ;;
        *) continue ;;
      esac
      # MCP-PROTECT-001: Skip MCP/LSP server processes.
      # MCP servers are node processes with --stdio flag — they must survive
      # teammate cleanup. Without this guard, cleanup hooks kill all node
      # children of Claude Code, disconnecting MCP servers mid-session.
      if _is_mcp_server "$pid"; then
        continue
      fi
    fi

    # MCP-PROTECT-003: Log process identity before any kill (read-first, kill-second)
    if [[ "${RUNE_TRACE:-}" == "1" ]]; then
      printf '[process-tree] SIGTERM target: %s (filter=%s)\n' \
        "$(_describe_process "$pid")" "$filter" >&2
    fi

    # XVER-001: Record lstart before SIGTERM for recycling detection
    child_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ' || echo "")
    kill -TERM "$pid" 2>/dev/null || true
    _kill_pids+=("$pid")
    _kill_lstarts+=("${child_lstart:-unknown}")
  done

  [[ ${#_kill_pids[@]} -eq 0 ]] && echo "0" && return 0

  # Count SIGTERM'd processes (FLAW-008 fix: track all terminated, not just SIGKILL'd)
  killed=${#_kill_pids[@]}

  # If term-only mode, we're done
  if [[ "$mode" == "term" ]]; then
    echo "$killed"
    return 0
  fi

  # Phase 2: Wait grace period, then SIGKILL survivors
  # EDGE-003 FIX: Use validated grace value in fallback instead of hardcoded 1.
  # $grace is already validated as numeric by the caller or defaults to 5.
  # Fallback chain: try grace → try safe minimum (2s) → guaranteed minimum.
  sleep "$grace" 2>/dev/null || sleep "${grace:-2}" 2>/dev/null || sleep 2

  local idx=0
  for pid in "${_kill_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      # Re-verify process identity (PID recycling guard — CLD-003)
      if [[ "$filter" == "teammates" ]]; then
        if [[ "$_whitelist_available" == "true" ]]; then
          # Re-verify PID is still in whitelist (shouldn't change, but defensive)
          if ! printf '%s\n' "$_whitelist_pids" | grep -qx "$pid"; then
            idx=$((idx + 1))
            continue
          fi
        else
          # Fallback: re-verify with claude filter
          child_comm=$(_proc_name "$pid")
          case "$child_comm" in
            node|claude|claude-*) ;;
            *) idx=$((idx + 1)); continue ;;
          esac
          if _is_mcp_server "$pid"; then
            idx=$((idx + 1))
            continue
          fi
        fi
      elif [[ "$filter" == "claude" ]]; then
        child_comm=$(_proc_name "$pid")
        case "$child_comm" in
          node|claude|claude-*) ;;
          *)
            idx=$((idx + 1))
            continue
            ;;
        esac
        # MCP-PROTECT-001: Re-check MCP server status before SIGKILL
        if _is_mcp_server "$pid"; then
          idx=$((idx + 1))
          continue
        fi
      fi

      # XVER-001: Verify lstart hasn't changed (PID recycling detection)
      local orig_lstart="${_kill_lstarts[$idx]}"
      local cur_lstart
      cur_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ' || echo "")
      if [[ "$orig_lstart" != "unknown" && -n "$cur_lstart" && "$orig_lstart" != "$cur_lstart" ]]; then
        # PID was recycled — different process start time, skip
        idx=$((idx + 1))
        continue
      fi

      # FLAW-001 FIX: Don't double-count — process was already counted in SIGTERM phase
      kill -KILL "$pid" 2>/dev/null || true
    fi
    idx=$((idx + 1))
  done

  echo "$killed"
  return 0
}
