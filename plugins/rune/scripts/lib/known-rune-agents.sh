#!/bin/bash
# scripts/lib/known-rune-agents.sh
# Shared registry of known Rune agent names (grep pattern + helper function).
#
# SOURCE OF TRUTH: plugins/rune/agents/**/*.md (all *.md excluding references/)
#                  + specialist-prompts/*.md (stack-specific reviewers)
# SOURCED BY: enforce-teams.sh, guard-context-critical.sh
# UPDATE: When adding a new agent to agents/, also add it here.
#         Run scripts/audit-agent-registry.sh to verify sync.

# Read-only reference (grep pattern for O(1) agent name matching)
# Includes agents from agents/*.md + specialist-prompts + codex/arena agents
KNOWN_RUNE_AGENTS="aesthetic-quality-reviewer|agent-parity-reviewer|api-contract-tracer|assumption-slayer|axum-reviewer|blight-seer|breach-hunter|business-logic-tracer|codex-arena-judge|codex-oracle|codex-phase-handler|codex-plan-reviewer|codex-researcher|condenser-gap|condenser-plan|condenser-verdict|condenser-work|config-dependency-tracer|context-scribe|cross-shard-sentinel|data-layer-tracer|ddd-reviewer|decay-tracer|decree-arbiter|decree-auditor|deployment-verifier|depth-seer|design-analyst|design-implementation-reviewer|design-inventory-agent|design-iterator|design-sync-agent|design-system-compliance-reviewer|di-reviewer|dispatch-herald|django-reviewer|doubt-seer|e2e-browser-tester|echo-reader|elicitation-sage|ember-oracle|ember-seer|entropy-prophet|event-message-tracer|evidence-verifier|extended-test-runner|fastapi-reviewer|flaw-hunter|flow-seer|forge-keeper|forge-warden|fringe-watcher|gap-fixer|git-miner|glyph-scribe|goldmask-coordinator|grace-warden|horizon-sage|hypothesis-investigator|integration-test-runner|knowledge-keeper|laravel-reviewer|lore-analyst|lore-scholar|mend-fixer|mimic-detector|naming-intent-analyzer|order-auditor|pattern-seer|pattern-weaver|phantom-checker|php-reviewer|practice-seeker|prompt-warden|python-reviewer|reality-arbiter|refactor-guardian|reference-validator|repo-surveyor|research-verifier|rot-seeker|ruin-prophet|ruin-watcher|rune-architect|rune-smith|runebinder|rust-reviewer|schema-drift-detector|scroll-reviewer|senior-engineer-reviewer|shard-reviewer|sight-oracle|signal-watcher|simplicity-warden|sqlalchemy-reviewer|state-weaver|storybook-fixer|storybook-reviewer|strand-tracer|tdd-compliance-reviewer|test-failure-analyst|test-runner|tide-watcher|todo-verifier|tome-digest|trial-forger|trial-oracle|truth-seeker|truthseer-validator|type-warden|typescript-reviewer|unit-test-runner|ux-cognitive-walker|ux-flow-validator|ux-heuristic-reviewer|ux-interaction-auditor|ux-pattern-analyzer|veil-piercer|veil-piercer-plan|verdict-binder|vigil-keeper|void-analyzer|ward-sentinel|wisdom-sage|wraith-finder"

# Helper function: Test if agent name is in the registry.
# Handles numbered suffixes (-1, -2), named suffixes (-deep, -exhaustive),
# and explicit named suffixes (-deep, -exhaustive, -plan, -inspect, -wN) via suffix allowlist.
# Args: $1 = agent name (may include suffix)
# Returns: 0 if known Rune agent, 1 if unknown or empty
is_known_rune_agent() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" == *$'\n'* ]] && return 1
  printf '%s\n' "$name" | grep -qE "^(${KNOWN_RUNE_AGENTS})(-[0-9]+|-deep|-exhaustive|-plan|-inspect|-w[0-9]+)*$"
}
