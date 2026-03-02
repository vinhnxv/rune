#!/bin/bash
# scripts/lib/rtk-exempt.sh
# RTK exemption logic — both exemption layers.
#
# USAGE: Source this file after rtk-config.sh is loaded.
#   source "${SCRIPT_DIR}/lib/rtk-exempt.sh"
#
# Provides:
#   rtk_is_command_exempt(command, exempt_commands) — Layer 2: command-level exemption
#   rtk_is_workflow_exempt(cwd, exempt_workflows)   — Layer 1: workflow-level exemption
#
# Layer 2 is checked BEFORE Layer 1 (cheaper — no filesystem reads).

# ── rtk_is_command_exempt: Layer 2 — command-level exemption ──
# Returns: 0 if exempt (skip RTK), 1 if not exempt (proceed)
# Args:
#   $1 — COMMAND (raw command string)
#   $2 — RTK_EXEMPT_COMMANDS (newline-separated shell patterns)
rtk_is_command_exempt() {
  local command="$1"
  local exempt_patterns="$2"

  if [[ -z "$exempt_patterns" ]]; then
    return 1
  fi

  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    # Use grep -E for regex pattern matching against the command
    if printf '%s\n' "$command" | grep -qE "$pattern" 2>/dev/null; then
      return 0
    fi
  done <<< "$exempt_patterns"

  return 1
}

# ── rtk_is_workflow_exempt: Layer 1 — active workflow exemption ──
# Checks tmp/.rune-*.json state files for active exempt workflows.
# Returns: 0 if exempt (skip RTK), 1 if not exempt (proceed)
# Args:
#   $1 — CWD (canonicalized working directory)
#   $2 — RTK_EXEMPT_WORKFLOWS (newline-separated workflow names)
rtk_is_workflow_exempt() {
  local cwd="$1"
  local exempt_workflows="$2"

  if [[ -z "$exempt_workflows" ]]; then
    return 1
  fi

  # Check each active state file
  local prev_nullglob
  prev_nullglob=$(shopt -p nullglob)
  shopt -s nullglob
  local f workflow_type file_status
  for f in "${cwd}"/tmp/.rune-review-*.json \
            "${cwd}"/tmp/.rune-audit-*.json \
            "${cwd}"/tmp/.rune-work-*.json \
            "${cwd}"/tmp/.rune-mend-*.json \
            "${cwd}"/tmp/.rune-plan-*.json \
            "${cwd}"/tmp/.rune-forge-*.json \
            "${cwd}"/tmp/.rune-inspect-*.json \
            "${cwd}"/tmp/.rune-goldmask-*.json \
            "${cwd}"/tmp/.rune-debug-*.json; do
    [[ ! -f "$f" ]] && continue
    file_status=$(jq -r '.status // empty' "$f" 2>/dev/null || true)
    [[ "$file_status" != "active" ]] && continue

    # Extract workflow name from filename: .rune-{workflow}-{id}.json
    local basename="${f##*/}"          # .rune-mend-12345.json
    local stripped="${basename#.rune-}" # mend-12345.json
    workflow_type="${stripped%%-*}"     # mend

    while IFS= read -r exempt; do
      [[ -z "$exempt" ]] && continue
      if [[ "$workflow_type" == "$exempt" ]]; then
        eval "$prev_nullglob"
        return 0
      fi
    done <<< "$exempt_workflows"
  done

  eval "$prev_nullglob"
  return 1
}
