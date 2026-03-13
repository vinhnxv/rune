#!/usr/bin/env bash
# scripts/verify-agent-deliverables.sh — SubagentStop hook
# DELIV-001: Advisory deliverable existence check on agent stop
# Classification: OPERATIONAL (fail-forward)
# Timeout: 5s
#
# NOTE: SubagentStop hooks CANNOT block — this is advisory only.
# Returns additionalContext warnings when expected output is missing.
# Exit code: 0 always (advisory hook, never blocks)

set -euo pipefail

# --- Fail-forward (OPERATIONAL hook) ---
_fail_forward() { exit 0; }
trap '_fail_forward' ERR

# --- Guard: jq dependency ---
command -v jq >/dev/null 2>&1 || exit 0

# --- Talisman gate ---
TALISMAN_SHARD="${CLAUDE_PROJECT_DIR:-.}/tmp/.talisman-resolved/misc.json"
MIN_SIZE=200
if [[ -f "$TALISMAN_SHARD" && ! -L "$TALISMAN_SHARD" ]]; then
  ENABLED=$(jq -r '.deliverable_verification.enabled // true' "$TALISMAN_SHARD" 2>/dev/null || echo "true")
  [[ "$ENABLED" == "false" ]] && exit 0
  MIN_SIZE=$(jq -r '.deliverable_verification.min_file_size // 200' "$TALISMAN_SHARD" 2>/dev/null || echo "200")
fi

# --- Read stdin (SEC-2: 1MB cap) ---
INPUT=$(head -c 1048576 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# --- Extract agent info from SubagentStop input ---
AGENT_NAME=$(printf '%s\n' "$INPUT" | jq -r '.agent_name // .subagent_type // empty' 2>/dev/null || true)
CWD=$(printf '%s\n' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

[[ -z "$AGENT_NAME" || -z "$CWD" ]] && exit 0

# --- SEC-4: Validate AGENT_NAME character set before use ---
if [[ ! "$AGENT_NAME" =~ ^[a-zA-Z0-9_:-]+$ ]]; then
  exit 0
fi

# --- Canonicalize CWD (path traversal prevention) ---
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
[[ -z "$CWD" || "$CWD" != /* ]] && exit 0

# --- Guard: Only check Rune agents (rune-* prefix or known Rune agent patterns) ---
# Source known agents list if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KNOWN_AGENTS_FILE="${SCRIPT_DIR}/lib/known-rune-agents.sh"
if [[ -f "$KNOWN_AGENTS_FILE" ]]; then
  # shellcheck source=lib/known-rune-agents.sh
  source "$KNOWN_AGENTS_FILE"
  # is_known_rune_agent() or _is_known_rune_agent() depending on version
  if type -t is_known_rune_agent &>/dev/null; then
    if ! is_known_rune_agent "$AGENT_NAME" 2>/dev/null; then
      exit 0  # Not a Rune agent — skip
    fi
  elif type -t _is_known_rune_agent &>/dev/null; then
    if ! _is_known_rune_agent "$AGENT_NAME" 2>/dev/null; then
      exit 0
    fi
  fi
  # If neither function exists, fall through (registry may use different interface)
fi

# --- Deliverable check by agent role pattern ---
WARNINGS=""

case "$AGENT_NAME" in
  # Review agents: should produce findings in tmp/reviews/ or tmp/audit/
  *-reviewer|*-seer|*-hunter|*-oracle|*-watcher|*-sentinel|*-prophet|*-tracer)
    FOUND=0
    # Use find instead of glob to avoid zsh NOMATCH and bash glob expansion issues
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      # Min size check
      FILE_SIZE=$(wc -c < "$f" 2>/dev/null | tr -dc '0-9' || echo "0")
      [[ -z "$FILE_SIZE" ]] && FILE_SIZE=0
      if (( FILE_SIZE >= MIN_SIZE )); then
        FOUND=1
        break
      fi
    done < <(find "$CWD/tmp/reviews" "$CWD/tmp/audit" -maxdepth 2 -name "*${AGENT_NAME}*" -type f 2>/dev/null || true)
    if (( FOUND == 0 )); then
      WARNINGS="Review agent '${AGENT_NAME}' completed without producing a findings file (>=${MIN_SIZE} bytes) in tmp/reviews/ or tmp/audit/."
    fi
    ;;

  # Research agents: should produce output in tmp/plans/*/research/
  repo-surveyor|echo-reader|git-miner|practice-seeker|lore-scholar)
    FOUND=0
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      FILE_SIZE=$(wc -c < "$f" 2>/dev/null | tr -dc '0-9' || echo "0")
      [[ -z "$FILE_SIZE" ]] && FILE_SIZE=0
      if (( FILE_SIZE >= 100 )); then
        FOUND=1
        break
      fi
    done < <(find "$CWD/tmp/plans" -maxdepth 3 -path "*/research/*${AGENT_NAME}*" -type f 2>/dev/null || true)
    if (( FOUND == 0 )); then
      WARNINGS="Research agent '${AGENT_NAME}' completed without producing output (>=100 bytes) in tmp/plans/*/research/."
    fi
    ;;

  # Elicitation agents: should produce output in tmp/
  *-sage)
    FOUND=0
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      FILE_SIZE=$(wc -c < "$f" 2>/dev/null | tr -dc '0-9' || echo "0")
      [[ -z "$FILE_SIZE" ]] && FILE_SIZE=0
      if (( FILE_SIZE >= 100 )); then
        FOUND=1
        break
      fi
    done < <(find "$CWD/tmp" "$CWD/tmp/plans" -maxdepth 3 -name "*${AGENT_NAME}*" -type f 2>/dev/null || true)
    if (( FOUND == 0 )); then
      WARNINGS="Elicitation agent '${AGENT_NAME}' completed without producing output (>=100 bytes)."
    fi
    ;;

  # Work agents: should have modified files (git diff non-empty)
  rune-smith|trial-forger|mend-fixer|gap-fixer)
    if command -v git >/dev/null 2>&1; then
      DIFF_LINES=$(cd "$CWD" && git diff --stat 2>/dev/null | wc -l | tr -dc '0-9' || echo "0")
      [[ -z "$DIFF_LINES" ]] && DIFF_LINES=0
      if (( DIFF_LINES == 0 )); then
        # Also check staged changes
        STAGED_LINES=$(cd "$CWD" && git diff --cached --stat 2>/dev/null | wc -l | tr -dc '0-9' || echo "0")
        [[ -z "$STAGED_LINES" ]] && STAGED_LINES=0
        if (( STAGED_LINES == 0 )); then
          WARNINGS="Work agent '${AGENT_NAME}' completed without modifying any files (git diff empty)."
        fi
      fi
    fi
    ;;
esac

# --- Output advisory ---
if [[ -n "$WARNINGS" ]]; then
  jq -n --arg ctx "[DELIV-001] $WARNINGS This may indicate the agent completed prematurely. Check agent output and task completion signals." '{
    hookSpecificOutput: { hookEventName: "SubagentStop", additionalContext: $ctx },
    continue: true
  }' 2>/dev/null || true
else
  printf '{"continue":true,"suppressOutput":true}\n'
fi

exit 0
