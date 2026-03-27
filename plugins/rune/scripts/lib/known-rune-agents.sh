#!/bin/bash
# scripts/lib/known-rune-agents.sh
# Shared registry of known Rune agent names (grep pattern + helper function).
#
# SOURCE OF TRUTH: plugins/rune/agents/**/*.md (core, all *.md excluding references/)
#                  + plugins/rune/registry/**/*.md (extended+niche agents)
#                  + specialist-prompts/*.md (stack-specific reviewers)
# SOURCED BY: enforce-teams.sh, guard-context-critical.sh
# UPDATE: When adding a new agent to agents/ or registry/, also add it here.
#         Run scripts/audit-agent-registry.sh to verify sync.

# Read-only reference (grep pattern for O(1) agent name matching)
# Includes agents from agents/*.md + specialist-prompts + codex/arena agents
# Last synced: 2026-03-28 — 143 agents (92 from agents/registry + 12 specialist-prompts + 39 dynamic/spawned)
# To re-sync, run: bash scripts/audit-agent-registry.sh
KNOWN_RUNE_AGENTS="activation-pathfinder|aesthetic-quality-reviewer|agent-parity-reviewer|api-contract-tracer|assumption-slayer|axum-reviewer|blight-seer|breach-hunter|business-logic-tracer|code-review-qa-verifier|codex-arena-judge|codex-oracle|codex-phase-handler|codex-plan-reviewer|codex-researcher|config-dependency-tracer|context-builder|contract-validator|convergence-analyzer|cross-shard-sentinel|data-layer-tracer|ddd-reviewer|decay-tracer|decree-arbiter|decree-auditor|deployment-verifier|depth-seer|design-analyst|design-implementation-reviewer|design-inventory-agent|design-iterator|design-qa-verifier|design-sync-agent|design-system-compliance-reviewer|di-reviewer|django-reviewer|doubt-seer|e2e-browser-tester|echo-reader|effectiveness-analyzer|elicitation-sage|ember-oracle|ember-seer|entropy-prophet|event-message-tracer|evidence-verifier|extended-test-runner|fastapi-reviewer|flaw-hunter|flow-seer|forge-keeper|forge-qa-verifier|forge-warden|fringe-watcher|gap-analysis-qa-verifier|gap-fixer|git-miner|glyph-scribe|goldmask-coordinator|grace-warden|grace-warden-inspect|grace-warden-plan-review|hallucination-detector|hook-integrity-auditor|horizon-sage|hypothesis-investigator|improvement-advisor|integration-test-runner|knowledge-keeper|laravel-reviewer|lore-analyst|lore-scholar|mend-fixer|mend-qa-verifier|micro-evaluator|mimic-detector|naming-intent-analyzer|necessity-analyzer|order-auditor|pattern-seer|pattern-weaver|phantom-checker|phantom-warden|phase-qa-verifier|php-reviewer|practice-seeker|prompt-linter|proto-worker|python-reviewer|reality-arbiter|refactor-guardian|reference-validator|repo-surveyor|research-verifier|rot-seeker|ruin-prophet|ruin-prophet-inspect|ruin-prophet-plan-review|ruin-watcher|rule-consistency-auditor|rune-architect|rune-smith|runebinder|rust-reviewer|schema-drift-detector|scroll-reviewer|sediment-detector|senior-engineer-reviewer|shard-reviewer|sight-oracle|sight-oracle-inspect|sight-oracle-plan-review|signal-watcher|simplicity-warden|sqlalchemy-reviewer|state-weaver|storybook-fixer|storybook-reviewer|strand-tracer|tdd-compliance-reviewer|test-failure-analyst|test-qa-verifier|test-runner|tide-watcher|todo-verifier|tome-digest|trial-forger|trial-oracle|truth-seeker|truthseer-validator|type-warden|typescript-reviewer|unit-test-runner|ux-cognitive-walker|ux-flow-validator|ux-heuristic-reviewer|ux-interaction-auditor|ux-pattern-analyzer|veil-piercer|veil-piercer-plan|verdict-binder|vigil-keeper|vigil-keeper-inspect|vigil-keeper-plan-review|void-analyzer|ward-sentinel|wiring-cartographer|wisdom-sage|work-qa-verifier|workflow-auditor|wraith-finder"

# Helper function: Test if agent name is in the registry.
# Handles numbered suffixes (-1, -2), named suffixes (-deep, -exhaustive),
# and explicit named suffixes (-deep, -exhaustive, -plan, -inspect, -wN) via suffix allowlist.
# Args: $1 = agent name (may include suffix)
# Returns: 0 if known Rune agent, 1 if unknown or empty
is_known_rune_agent() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" == *$'\n'* ]] && return 1
  printf '%s\n' "$name" | grep -qE "^(${KNOWN_RUNE_AGENTS})(-[0-9]+|-deep|-exhaustive|-plan|-inspect|-review|-verifier|-auditor|-analyzer|-detector|-pathfinder|-cartographer|-w[0-9]+)*$"
}
