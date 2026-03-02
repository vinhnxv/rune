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

  # BACK-005: Single jq call extracts all 5 fields at once (was 6 subprocess forks).
  # Uses RS (0x1e) as section delimiter — safe since values are config strings.
  local rtk_parsed
  rtk_parsed=$(jq -rj '
    (.rtk // {}) as $r |
    ($r.enabled // false | tostring),
    "\u001e",
    ($r.auto_detect // true | tostring),
    "\u001e",
    ($r.tee_mode // "always"),
    "\u001e",
    (($r.exempt_workflows // []) | join("\n")),
    "\u001e",
    (($r.exempt_commands // []) | join("\n"))
  ' "$misc_shard" 2>/dev/null) || return 1
  if [[ -z "$rtk_parsed" ]]; then
    return 1
  fi

  # Split on RS delimiter (0x1e) into positional fields
  local IFS=$'\x1e'
  # shellcheck disable=SC2162
  read -d '' -r RTK_ENABLED RTK_AUTO_DETECT RTK_TEE_MODE RTK_EXEMPT_WORKFLOWS RTK_EXEMPT_COMMANDS <<< "$rtk_parsed" || true

  # Validate tee_mode against allowlist
  case "$RTK_TEE_MODE" in
    always|failures|never) ;;
    *) RTK_TEE_MODE="always" ;;
  esac

  return 0
}
