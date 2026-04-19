#!/bin/bash
# scripts/validate-shutdown-pattern.sh
# SHUTDOWN-DRIFT: Verifies canonical consumers of the MANDATORY 5-component
# Agent Team cleanup pattern — dynamic discovery (C1), force-reply (C2),
# adaptive grace (C3), retry-with-backoff (C4), filesystem fallback (C5).
# Previously only checked C5 sourcing (TEAM-001 audit 20260419-150325); now
# flags partial coverage across all five components.
#
# Detection strategy:
#   1. Fast-path: exit 0 if jq missing
#   2. Fast-path: exit 0 if FILE_PATH doesn't match one of the 3 canonical consumers
#   3. Slow path: read the file content and grep for each component signature
#   4. Advisory (additionalContext) enumerating missing components — does NOT block writes
#
# Classification: OPERATIONAL (fail-forward)
# Exit 0 always — this hook is advisory-only, never denies writes.
#
# Canonical consumers (files that MUST source lib/team-shutdown.sh):
#   - plugins/rune/skills/team-sdk/references/engines.md
#   - plugins/rune/skills/roundtable-circle/references/orchestration-phases.md
#   - plugins/rune/skills/mend/references/phase-7-cleanup.md

set -euo pipefail
umask 077
trap 'exit 0' ERR

# Bypass: allow disabling for testing/development
if [[ "${_RUNE_DISABLE_SHUTDOWN_PATTERN_CHECK:-}" == "1" ]]; then
  exit 0
fi

# Pre-flight: jq is required for JSON parsing (fail-open if missing)
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Read stdin (PreToolUse hook input) — 1MB cap (SEC-2)
INPUT=$(head -c 1048576 2>/dev/null || true)

# Extract file_path from tool_input
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

# SEC-002 FIX (review c1a9714-018c647e): reject path-traversal in FILE_PATH
# before it reaches the `cat "$FILE_PATH"` on the Edit branch. A crafted
# tool_input.file_path like "../../etc/passwd" would otherwise disclose
# arbitrary file contents into the advisory injected back into Claude's
# context. This is advisory-only anyway (exit 0 on any reject).
case "$FILE_PATH" in
  *..*) exit 0 ;;
esac

# Extract CWD for relative path resolution
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$CWD" ]] && exit 0

# Normalize to relative path
REL_PATH="$FILE_PATH"
if [[ "$FILE_PATH" == /* ]]; then
  REL_PATH="${FILE_PATH#"${CWD}/"}"
fi
REL_PATH="${REL_PATH#./}"

# Fast-path: Only check the 3 canonical consumer files
case "$REL_PATH" in
  plugins/rune/skills/team-sdk/references/engines.md|\
  plugins/rune/skills/roundtable-circle/references/orchestration-phases.md|\
  plugins/rune/skills/mend/references/phase-7-cleanup.md)
    # This is a canonical consumer — proceed to content check
    ;;
  *)
    # Not a canonical consumer — no check needed
    exit 0
    ;;
esac

# Slow path: Extract the new content being written
# For Write tool: content field. For Edit tool: new_string field.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

NEW_CONTENT=""
case "$TOOL_NAME" in
  Write)
    NEW_CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
    ;;
  Edit)
    # For Edit, we check the existing file + new_string — but the simplest
    # approach is to check the existing file on disk (the edit hasn't happened yet)
    # If the file already has the source pattern, allow. If it's being edited
    # to remove it, we'd need to check the result — but that's complex.
    # Pragmatic: check the file on disk. If it has the pattern, allow.
    # The advisory fires if the file currently lacks the pattern.
    if [[ -f "$FILE_PATH" ]]; then
      NEW_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || true)
    fi
    ;;
  *)
    exit 0
    ;;
esac

[[ -z "$NEW_CONTENT" ]] && exit 0

# Check all 5 components of the MANDATORY Agent Team cleanup pattern
# (see plugins/rune/CLAUDE.md § "Agent Team Cleanup (MANDATORY)").
# Each component has a distinct grep signature. Absence of any indicates
# drift risk — the advisory enumerates missing components explicitly.
#
# Component 1: Dynamic member discovery from teams/{teamName}/config.json
#   Signature: reads config.json under teams/${teamName}/
# Component 2: Step 2a force-reply (plain "message" before shutdown_request)
#   Signature: SendMessage with type "message" (distinct from shutdown_request)
# Component 3: Adaptive grace period formula min(20, max(5, alive * 5))
#   Signature: max(5,...*5) OR min(20,...) arithmetic
# Component 4: TeamDelete retry-with-backoff + success sentinel
#   Signature: cleanupTeamDeleteSucceeded flag (gates Component 5)
# Component 5: Filesystem fallback via lib/team-shutdown.sh + rune_team_shutdown_fallback
#   Signature: source line + function call (legacy checks — retained)

HAS_C1=0; HAS_C2=0; HAS_C3=0; HAS_C4=0; HAS_C5_SOURCE=0; HAS_C5_FN=0

# Component 1: teams/{teamName}/config.json pattern
if printf '%s' "$NEW_CONTENT" | grep -Eq 'teams/\$\{?teamName\}?/config\.json' 2>/dev/null; then
  HAS_C1=1
fi

# Component 2: force-reply plain message (distinct from shutdown_request)
# Match: type: "message" or type:"message" within a SendMessage context
if printf '%s' "$NEW_CONTENT" | grep -Eq 'type:[[:space:]]*"message"' 2>/dev/null; then
  HAS_C2=1
fi

# Component 3: adaptive grace formula — max(5, ... * 5) is the canonical shape
if printf '%s' "$NEW_CONTENT" | grep -Eq 'max\(5,[^)]*\*[[:space:]]*5' 2>/dev/null; then
  HAS_C3=1
fi

# Component 4: TeamDelete retry success sentinel
if printf '%s' "$NEW_CONTENT" | grep -q 'cleanupTeamDeleteSucceeded' 2>/dev/null; then
  HAS_C4=1
fi

# Component 5: source + delegate
if printf '%s' "$NEW_CONTENT" | grep -q 'lib/team-shutdown\.sh' 2>/dev/null; then
  HAS_C5_SOURCE=1
fi
if printf '%s' "$NEW_CONTENT" | grep -q 'rune_team_shutdown_fallback' 2>/dev/null; then
  HAS_C5_FN=1
fi
HAS_C5=0
[[ "$HAS_C5_SOURCE" -eq 1 && "$HAS_C5_FN" -eq 1 ]] && HAS_C5=1

# Fully compliant → exit silently
if [[ "$HAS_C1" -eq 1 && "$HAS_C2" -eq 1 && "$HAS_C3" -eq 1 && "$HAS_C4" -eq 1 && "$HAS_C5" -eq 1 ]]; then
  exit 0
fi

# Build a per-component missing list so the advisory names the gaps
MISSING=""
[[ "$HAS_C1" -eq 0 ]] && MISSING="${MISSING}  - C1 (dynamic discovery from teams/\${teamName}/config.json)\n"
[[ "$HAS_C2" -eq 0 ]] && MISSING="${MISSING}  - C2 (Step 2a force-reply — SendMessage type \"message\" before shutdown_request, per GitHub #31389)\n"
[[ "$HAS_C3" -eq 0 ]] && MISSING="${MISSING}  - C3 (adaptive grace period — max(5, alive*5))\n"
[[ "$HAS_C4" -eq 0 ]] && MISSING="${MISSING}  - C4 (TeamDelete retry-with-backoff — cleanupTeamDeleteSucceeded sentinel)\n"
[[ "$HAS_C5" -eq 0 ]] && MISSING="${MISSING}  - C5 (filesystem fallback — source lib/team-shutdown.sh + rune_team_shutdown_fallback)\n"

# Advisory: additionalContext only — never blocks writes
ADVISORY_MSG=$(printf 'SHUTDOWN-DRIFT: %s is a canonical consumer of the Agent Team cleanup pattern but appears to be missing the following component(s):\n%bSee plugins/rune/CLAUDE.md § "Agent Team Cleanup (MANDATORY)" and plugins/rune/skills/team-sdk/references/engines.md (shutdown()) for the canonical 5-component pattern. Each component is independently load-bearing: C1 prevents orphans when config reads fail, C2 prevents GitHub #31389 deliveries being dropped, C3 scales grace period with live members, C4 survives TeamDelete timing races, C5 cleans up filesystem state when SDK state is stuck.' "$REL_PATH" "$MISSING")

printf '%s\n' "$(jq -n \
  --arg ctx "$ADVISORY_MSG" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }')"

exit 0
