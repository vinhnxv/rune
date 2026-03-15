#!/bin/bash
# scripts/audit-agent-registry.sh
# Validates that lib/known-rune-agents.sh stays in sync with agents/**/*.md
# and specialist-prompts/*.md.
#
# Usage: bash plugins/rune/scripts/audit-agent-registry.sh
# Exit: 0 if in sync, 1 if drift detected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_FILE="${SCRIPT_DIR}/lib/known-rune-agents.sh"

if [[ ! -f "$LIB_FILE" ]]; then
  printf "ERROR: %s not found\n" "$LIB_FILE" >&2
  exit 1
fi

# Extract agent names from the registry (pipe-separated pattern → one per line)
REGISTRY_NAMES=$(grep '^KNOWN_RUNE_AGENTS=' "$LIB_FILE" | sed 's/^KNOWN_RUNE_AGENTS="//' | sed 's/"$//' | tr '|' '\n' | sort)

# Extract agent names from agents/**/*.md (excluding references/)
AGENT_NAMES=$(find "$PLUGIN_DIR/agents" -name '*.md' -not -path '*/references/*' -print0 2>/dev/null \
  | xargs -0 -I{} basename {} .md \
  | sort -u)

# Extract specialist names from specialist-prompts/*.md (multiple possible locations)
SPECIALIST_NAMES=""
for sp_dir in "$PLUGIN_DIR/specialist-prompts" \
              "$PLUGIN_DIR/skills/roundtable-circle/references/specialist-prompts"; do
  if [[ -d "$sp_dir" ]]; then
    sp_found=$(find "$sp_dir" -name '*.md' -not -name 'README*' -print0 2>/dev/null \
      | xargs -0 -I{} basename {} .md)
    if [[ -n "$sp_found" ]]; then
      SPECIALIST_NAMES=$(printf '%s\n%s' "$SPECIALIST_NAMES" "$sp_found")
    fi
  fi
done

# Extract ash-prompt names from roundtable-circle references
ASH_PROMPT_NAMES=""
ASH_DIR="$PLUGIN_DIR/prompts/ash"
if [[ -d "$ASH_DIR" ]]; then
  ASH_PROMPT_NAMES=$(find "$ASH_DIR" -name '*.md' -not -name 'README*' -not -name '*template*' -print0 2>/dev/null \
    | xargs -0 -I{} basename {} .md \
    | sort -u)
fi

# Known dynamically-spawned agents (no .md file — created programmatically)
DYNAMIC_AGENTS="codex-arena-judge
codex-plan-reviewer
codex-researcher
design-inventory-agent
test-runner"

# Combine expected names
EXPECTED_NAMES=$(printf '%s\n%s\n%s\n%s' "$AGENT_NAMES" "$SPECIALIST_NAMES" "$ASH_PROMPT_NAMES" "$DYNAMIC_AGENTS" | grep -v '^$' | sort -u)

# Source the shared lib for is_known_rune_agent() suffix matching
source "$LIB_FILE"

# Compare — agents matched by suffix regex are not considered missing
MISSING_FROM_REGISTRY=""
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if ! echo "$REGISTRY_NAMES" | grep -qxF "$name"; then
    # Not an exact match — check if suffix regex matches
    if ! is_known_rune_agent "$name"; then
      MISSING_FROM_REGISTRY=$(printf '%s\n%s' "$MISSING_FROM_REGISTRY" "$name")
    fi
  fi
done <<< "$EXPECTED_NAMES"
MISSING_FROM_REGISTRY=$(echo "$MISSING_FROM_REGISTRY" | grep -v '^$' | sort -u || true)

EXTRA_IN_REGISTRY=$(comm -13 <(echo "$EXPECTED_NAMES") <(echo "$REGISTRY_NAMES"))

DRIFT=0

if [[ -n "$MISSING_FROM_REGISTRY" ]]; then
  printf "MISSING from registry (agents exist but not in known-rune-agents.sh):\n"
  printf "  %s\n" $MISSING_FROM_REGISTRY
  DRIFT=1
fi

if [[ -n "$EXTRA_IN_REGISTRY" ]]; then
  printf "EXTRA in registry (in known-rune-agents.sh but no agent file):\n"
  printf "  %s\n" $EXTRA_IN_REGISTRY
  DRIFT=1
fi

if [[ "$DRIFT" -eq 0 ]]; then
  REGISTRY_COUNT=$(echo "$REGISTRY_NAMES" | wc -l | tr -d ' ')
  EXPECTED_COUNT=$(echo "$EXPECTED_NAMES" | wc -l | tr -d ' ')
  printf "OK: Registry in sync (%s agents, %s expected)\n" "$REGISTRY_COUNT" "$EXPECTED_COUNT"
fi

exit "$DRIFT"
