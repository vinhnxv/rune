#!/usr/bin/env bash
# lib/talisman-shard-path.sh — Resolve talisman shard location (project → system fallback)
#
# Usage: source this, then: SHARD=$(_rune_resolve_talisman_shard "misc")
# Returns: absolute path to shard file, or "" if not found
#
# Priority: project-level (tmp/.talisman-resolved/) → system-level (${CHOME}/.rune/talisman-resolved/)
# Symlink guard: rejects symlinked shard files (defense-in-depth)

# Source guard — prevent double-loading
[[ -n "${_RUNE_SHARD_PATH_LOADED:-}" ]] && return 0
_RUNE_SHARD_PATH_LOADED=1

_rune_resolve_talisman_shard() {
  local shard_name="${1:?Usage: _rune_resolve_talisman_shard <shard_name>}"
  local project_dir="${CLAUDE_PROJECT_DIR:-.}"
  local chome="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

  # SEC-006: Reject path traversal and shell metacharacters in shard_name
  case "$shard_name" in
    *..* | */* | *\\*) echo ""; return 0 ;;
  esac

  # Priority 1: Project-level shards (user has talisman.yml)
  local project_shard="${project_dir}/tmp/.talisman-resolved/${shard_name}.json"
  if [[ -f "$project_shard" && ! -L "$project_shard" ]]; then
    echo "$project_shard"
    return 0
  fi

  # Priority 2: System-level shards (defaults-only cache)
  local system_shard="${chome}/.rune/talisman-resolved/${shard_name}.json"
  if [[ -f "$system_shard" && ! -L "$system_shard" ]]; then
    echo "$system_shard"
    return 0
  fi

  # Not found — caller should use hardcoded defaults
  echo ""
  return 0
}
