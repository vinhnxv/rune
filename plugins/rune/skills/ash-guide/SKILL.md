---
name: ash-guide
description: |
  Use when summoning Rune agents, when encountering "agent not found" errors, when
  selecting which review agents to use, or when checking agent capabilities and tools.
  Quick reference for all 109 agents across 6 categories (66 core + 43 extended in
  review, research, work, utility, investigation, testing). Keywords: agent list, Ash, subagent type, agent not found.

  <example>
  Context: User wants to know which agents are available
  user: "What review agents does Rune have?"
  assistant: "Loading ash-guide for the agent reference table"
  </example>
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
---

# Ash Guide

Quick reference for all Rune plugin agents, their roles, and invocation patterns.

## Invocation Models

### Direct Invocation (standalone tasks, custom workflows)

All Rune agents are plugin agents. Invoke with the `rune:` namespace prefix:

```
Agent rune:review:ward-sentinel("Review these files for security")
Agent rune:review:ember-oracle("Check performance bottlenecks")
Agent rune:utility:runebinder("Aggregate review findings")
```

**Common mistake:** Using agent name without namespace prefix.

```
# WRONG - agent not found
Agent ward-sentinel(...)

# CORRECT - full namespace
Agent rune:review:ward-sentinel(...)
```

### Composite Ash Invocation (review/audit workflows)

The `/rune:appraise` and `/rune:audit` commands use `general-purpose` subagents with composite
Ash prompt templates from [agents/](../../agents/). Each Ash embeds
multiple agent perspectives into a single teammate. This is intentional — composite Ashes
don't map 1:1 to individual agent files.

```
Agent({ subagent_type: "general-purpose", team_name: teamName, name: "ash-name", prompt: /* from ../../agents/{category}/{role}.md */ })
```

The agent file `allowed-tools` are not enforced at runtime for composite Ashes.
Tool restriction is enforced via prompt instructions (defense-in-depth).

> **Note:** Agents listed below with `rune:review:*`, `rune:testing:*`, or `rune:utility:*` types may live in `registry/` rather than `agents/`. Registry agents cannot be spawned directly via `Agent({ subagent_type: "rune:review:blight-seer" })` — the plugin-namespaced type won't resolve. Instead, use `subagent_type: "general-purpose"` and inject the agent body via the `agent_detail(name)` MCP call or `Read("registry/{category}/{name}.md")`. Agents in `agents/` (e.g., `ward-sentinel`, `ember-oracle`, `flaw-hunter`) ARE directly spawnable via their listed type names.

## Review Agents

35 specialized reviewers that form Ash teams:

| Agent | Role | Perspective |
|-------|------|-------------|
| `rune:review:ward-sentinel` | Security review | Vulnerabilities, auth, injection, OWASP, prompt injection |
| `rune:review:ember-oracle` | Performance review | Bottlenecks, N+1 queries, async patterns, memory |
| `rune:review:rune-architect` | Architecture review | Layer violations, DDD, dependency direction |
| `rune:review:simplicity-warden` | Simplicity review | YAGNI, over-engineering, premature abstraction |
| `rune:review:flaw-hunter` | Logic review | Edge cases, race conditions, null handling, off-by-one |
| `rune:review:mimic-detector` | Duplication review | DRY violations, copy-paste code, similar patterns |
| `rune:review:pattern-seer` | Pattern review | Naming consistency, convention adherence |
| `rune:review:void-analyzer` | Completeness review | Missing error handling, incomplete implementations |
| `rune:review:wraith-finder` | Dead code & unwired code review | Unused functions, DI wiring gaps, orphaned routes/handlers, AI orphan detection |
| `rune:review:phantom-checker` | Dynamic reference check | Reflection, string-based imports, meta-programming |
| `rune:review:type-warden` | Type safety review | Type hints, mypy strict, Python idioms, async correctness |
| `rune:review:trial-oracle` | TDD compliance review | Test-first order, coverage gaps, assertion quality |
| `rune:review:depth-seer` | Missing logic review | Error handling gaps, state machines, complexity hotspots |
| `rune:review:blight-seer` | Design anti-pattern review | God Service, leaky abstractions, temporal coupling, observability |
| `rune:review:forge-keeper` | Data integrity review | Migration safety, reversibility, lock analysis, transaction boundaries, PII |
| `rune:review:tide-watcher` | Async/concurrency review | Waterfall awaits, unbounded concurrency, cancellation, race conditions |
| `rune:review:refactor-guardian` | Refactoring completeness review | Orphaned callers, incomplete extractions, missing dependency moves, stale test refs |
| `rune:review:reference-validator` | Reference integrity review | Import paths, config-to-source refs, frontmatter schema, version sync |
| `rune:review:reality-arbiter` | Production viability truth-telling | Integration honesty, production readiness, data reality, error path honesty |
| `rune:review:assumption-slayer` | Premise validation truth-telling | Problem-solution fit, cargo cult detection, complexity justification |
| `rune:review:entropy-prophet` | Long-term consequence truth-telling | Complexity compounding, dependency trajectory, lock-in, maintenance burden |
| `rune:review:design-system-compliance-reviewer` | Design system compliance review | Token usage, variant patterns, import paths, class merge utilities, dark mode implementation |
| `rune:review:ux-heuristic-reviewer` | UX heuristic evaluation | Nielsen Norman 10 heuristics at code level, 50+ checklist items (UXH-). Conditional: `ux.enabled` + frontend files |
| `rune:review:ux-flow-validator` | User flow completeness | Loading states, error boundaries, empty states, confirmation dialogs, undo, graceful degradation (UXF-). Conditional: `ux.enabled` + frontend files |
| `rune:review:ux-interaction-auditor` | Micro-interaction audit | Hover/focus states, keyboard accessibility, touch targets (44px), animation, prefers-reduced-motion (UXI-). Conditional: `ux.enabled` + frontend files |
| `rune:review:ux-cognitive-walker` | Cognitive walkthrough | First-time user simulation, discoverability, learnability, error recovery, progressive disclosure (UXC-). Conditional: `ux.enabled` + `cognitive_walkthrough: true` |

## Ash Roles (Consolidated Teammates)

In `/rune:appraise`, agents are grouped into 7 built-in Ashes (extensible via talisman.yml):

| Ash | Agents Embedded | Scope |
|-----------|-----------------|-------|
| **Forge Warden** | rune-architect, ember-oracle, flaw-hunter, mimic-detector, type-warden, depth-seer, blight-seer, forge-keeper | Backend code (`.py`, `.go`, `.rs`, `.rb`, `.java`) |
| **Ward Sentinel** | ward-sentinel | ALL files (security always) |
| **Veil Piercer** | reality-arbiter, assumption-slayer, entropy-prophet | ALL files (truth-telling always) |
| **Pattern Weaver** | simplicity-warden, pattern-seer, wraith-finder, phantom-checker, void-analyzer, trial-oracle, tide-watcher, refactor-guardian, reference-validator | ALL files (quality patterns) |
| **Glyph Scribe** | Inline perspectives (TypeScript safety, React performance, accessibility) | Frontend code (`.ts`, `.tsx`, `.js`, `.jsx`) |
| **Knowledge Keeper** | Inline perspectives (accuracy, completeness, consistency) | Docs (`.md` files, conditional) |
| **Codex Oracle** | Inline perspectives (cross-model security, logic, quality via `codex exec`) | ALL files (when `codex` CLI available) |

**Note:** Forge Warden, Ward Sentinel, Veil Piercer, and Pattern Weaver embed dedicated review agent files. Glyph Scribe, Knowledge Keeper, and Codex Oracle use inline perspective definitions in their Ash prompts (no dedicated agent files). Codex Oracle is CLI-gated and wraps the external `codex exec` command.

## Utility Agents

| Agent | Role |
|-------|------|
| `rune:utility:runebinder` | Aggregates review/audit outputs → writes TOME.md |
| `rune:utility:truthseer-validator` | Audit coverage validation (Phase 5.5) |
| `rune:utility:flow-seer` | Spec flow analysis |
| `rune:utility:scroll-reviewer` | Document quality review |
| `rune:utility:decree-arbiter` | Technical soundness review for plans |
| `rune:utility:mend-fixer` | Parallel code fixer for /rune:mend findings |
| `rune:utility:knowledge-keeper` | Documentation coverage reviewer for plans |
| `rune:utility:veil-piercer-plan` | Plan-level truth-teller (Phase 4C plan review) |
| `rune:utility:ux-pattern-analyzer` | Codebase UX maturity assessment — inventories loading, error, form, navigation, empty state, confirmation/undo patterns (devise Phase 0.3) |

## Research Agents

| Agent | Role |
|-------|------|
| `rune:research:practice-seeker` | External best practices research |
| `rune:research:repo-surveyor` | Codebase/repo exploration |
| `rune:research:lore-scholar` | Framework documentation research |
| `rune:research:echo-reader` | Reads Rune Echoes (past learnings) |
| `rune:research:git-miner` | Git history archaeology |

## Work Agents

| Agent | Role |
|-------|------|
| `rune:work:rune-smith` | Code implementation (TDD-aware) |
| `rune:work:trial-forger` | Test generation |

## Testing Agents (Registry — Not Directly Spawnable)

> These agents live in `registry/testing/` and are spawned indirectly by the `/rune:testing` skill during arc Phase 7.7. They cannot be passed to the `Agent()` tool's `subagent_type` parameter directly.

| Agent | Role |
|-------|------|
| `registry:testing:unit-test-runner` | Diff-scoped unit test execution (Sonnet) |
| `registry:testing:integration-test-runner` | Integration test execution with service management (Sonnet) |
| `registry:testing:e2e-browser-tester` | E2E browser testing via agent-browser (Sonnet) |
| `registry:testing:test-failure-analyst` | Read-only failure analysis and fix suggestions (Opus inherit) |

## Ash Selection Logic

The `/rune:appraise` command selects Ash based on file extensions (Rune Gaze):

| File Pattern | Ash Selected |
|-------------|---------------------|
| `**/*.py` | Forge Warden + Ward Sentinel + Pattern Weaver + Veil Piercer |
| `**/*.{ts,tsx,js,jsx}` | Glyph Scribe + Ward Sentinel + Pattern Weaver + Veil Piercer |
| `**/*.md` (>= 10 lines changed) | Knowledge Keeper (conditional) |
| Mixed code + docs | All applicable Ash |

Ward Sentinel, Pattern Weaver, and Veil Piercer are selected for every review regardless of file types.

See `roundtable-circle` skill for full Ash architecture and prompts.
