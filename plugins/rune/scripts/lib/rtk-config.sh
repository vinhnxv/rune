#!/bin/bash
# scripts/lib/rtk-config.sh
# RTK config reading library — reads pre-cached misc.json shard.
#
# USAGE: Source this file after set -euo pipefail and fail-forward trap.
#   source "${SCRIPT_DIR}/lib/rtk-config.sh"
#   rtk_load_config "$CWD"
#
# Provides:
#   rtk_load_config(cwd) — load RTK config from tmp/.talisman-resolved/misc.json
#   RTK_ENABLED          — "true" | "false" (string)
#   RTK_AUTO_DETECT      — "true" | "false" (string)
#   RTK_TEE_MODE         — "always" | "failures" | "never"
#   RTK_EXEMPT_WORKFLOWS — newline-separated workflow names
#   RTK_EXEMPT_COMMANDS  — newline-separated shell patterns
#
# Does NOT read talisman.yml at runtime. Relies on talisman-resolve.sh having
# pre-cached the misc shard at session start.

# ── rtk_load_config: load RTK config from pre-cached misc shard ──
# Sets: RTK_ENABLED, RTK_AUTO_DETECT, RTK_TEE_MODE,
#       RTK_EXEMPT_WORKFLOWS, RTK_EXEMPT_COMMANDS
# Returns: 0 on success, 1 if shard missing/unreadable (caller should exit 0)
rtk_load_config() {
  local cwd="$1"
  local misc_shard="${cwd}/tmp/.talisman-resolved/misc.json"

  RTK_ENABLED="false"
  RTK_AUTO_DETECT="true"
  RTK_TEE_MODE="always"
  RTK_EXEMPT_WORKFLOWS=""
  RTK_EXEMPT_COMMANDS=""

  # Shard must exist and not be a symlink
  if [[ ! -f "$misc_shard" ]] || [[ -L "$misc_shard" ]]; then
    return 1
  fi

  local rtk_json
  rtk_json=$(jq -r '.rtk // {}' "$misc_shard" 2>/dev/null) || return 1
  if [[ -z "$rtk_json" || "$rtk_json" == "null" ]]; then
    return 1
  fi

  RTK_ENABLED=$(printf '%s\n' "$rtk_json" | jq -r '.enabled // false' 2>/dev/null || echo "false")
  RTK_AUTO_DETECT=$(printf '%s\n' "$rtk_json" | jq -r '.auto_detect // true' 2>/dev/null || echo "true")
  RTK_TEE_MODE=$(printf '%s\n' "$rtk_json" | jq -r '.tee_mode // "always"' 2>/dev/null || echo "always")

  # Validate tee_mode against allowlist
  case "$RTK_TEE_MODE" in
    always|failures|never) ;;
    *) RTK_TEE_MODE="always" ;;
  esac

  RTK_EXEMPT_WORKFLOWS=$(printf '%s\n' "$rtk_json" | jq -r '(.exempt_workflows // []) | .[]' 2>/dev/null || true)
  RTK_EXEMPT_COMMANDS=$(printf '%s\n' "$rtk_json" | jq -r '(.exempt_commands // []) | .[]' 2>/dev/null || true)

  return 0
}
