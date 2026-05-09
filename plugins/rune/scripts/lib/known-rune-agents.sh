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
# Includes agents from agents/*.md + registry/*.md + specialist-prompts (stack reviewers).
# Last synced: 2026-05-09 (self-audit run 1778280306) — 116 actual agent files
# (74 in agents/, 42 in registry/) + stack specialist prompt templates matched
# here defensively but living as prompts under
# skills/roundtable-circle/references/specialist-prompts/. The 4 dynamic
# agent names without on-disk .md files (design-inventory-agent, glyph-scribe,
# pattern-weaver, test-runner) are still spawned programmatically by tests and
# ash-prompt templates and remain in the allowlist intentionally — see
# audit-agent-registry.sh DYNAMIC_AGENTS.
# To re-sync, run: bash scripts/audit-agent-registry.sh
KNOWN_RUNE_AGENTS="activation-pathfinder|aesthetic-quality-reviewer|agent-parity-reviewer|api-contract-tracer|assumption-slayer|axum-reviewer|blight-seer|blind-verifier|breach-hunter|business-logic-tracer|config-dependency-tracer|context-builder|contract-validator|convergence-analyzer|cross-shard-sentinel|data-layer-tracer|ddd-reviewer|decay-tracer|decree-arbiter|decree-auditor|deployment-verifier|depth-seer|design-analyst|design-inventory-agent|design-iterator|design-sync-agent|di-reviewer|django-reviewer|doubt-seer|e2e-browser-tester|effectiveness-analyzer|elicitation-sage|ember-oracle|ember-seer|entropy-prophet|event-message-tracer|evidence-verifier|extended-test-runner|fastapi-reviewer|finding-verifier|flaw-hunter|flow-seer|forge-keeper|forge-warden|flow-integrity-tracer|fringe-watcher|gap-fixer|git-miner|glyph-scribe|goldmask-coordinator|grace-warden|hallucination-detector|hook-integrity-auditor|horizon-sage|hypothesis-investigator|improvement-advisor|integration-test-runner|knowledge-keeper|laravel-reviewer|lore-analyst|lore-scholar|mend-fixer|micro-evaluator|mimic-detector|naming-intent-analyzer|necessity-analyzer|order-auditor|pattern-seer|pattern-weaver|phantom-checker|phantom-warden|phase-qa-verifier|php-reviewer|practice-seeker|prompt-linter|python-reviewer|react-performance|reality-arbiter|refactor-guardian|refactor-guardian-extended|reference-validator|repo-surveyor|research-verifier|rot-seeker|ruin-prophet|ruin-watcher|rule-consistency-auditor|rune-architect|rune-smith|runebinder|rust-reviewer|schema-drift-detector|scroll-reviewer|sediment-detector|senior-engineer-reviewer|shard-reviewer|sight-oracle|signal-watcher|simplicity-warden|sqlalchemy-reviewer|state-weaver|storybook-fixer|storybook-reviewer|strand-tracer|supply-chain-sentinel|tdd-compliance-reviewer|test-failure-analyst|test-runner|tide-watcher|todo-verifier|tome-digest|trial-forger|trial-oracle|truth-seeker|truthseer-validator|type-warden|type-warden-extended|typescript-reviewer|unit-test-runner|ux-cognitive-walker|ux-flow-validator|veil-piercer|veil-piercer-plan|variant-hunter|verdict-binder|vigil-keeper|void-analyzer|ward-sentinel|web-interface|wiring-cartographer|wisdom-sage|workflow-auditor|wraith-finder|wraith-finder-extended"

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
