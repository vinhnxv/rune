# Agent Registry

**Total: 152 agent definitions** (109 CORE in agents/ + 43 EXTENDED in registry/, 13 shared)

> Agent count verified by `find agents/ registry/ -name "*.md" -type f | wc -l` on 2026-04-10.
> CORE agents (agents/): 17 review + 9 research + 6 work + 16 utility + 31 investigation + 0 testing + 8 qa + 9 meta-qa + 13 shared (incl. README, TEMPLATE) = 109
> EXTENDED agents (registry/): 25 review + 4 work + 6 utility + 2 investigation + 6 testing = 43

> **Stack specialist reviewers** (python-reviewer, typescript-reviewer, rust-reviewer, php-reviewer, axum-reviewer, fastapi-reviewer, django-reviewer, laravel-reviewer, sqlalchemy-reviewer, tdd-compliance-reviewer, ddd-reviewer, di-reviewer) are NOT registered agents. They are prompt templates at `skills/roundtable-circle/references/specialist-prompts/`, loaded on-demand by `buildAshPrompt()` via stack detection.

Shared resources: [Review Checklist](../skills/roundtable-circle/references/agent-patterns/review-checklist.md) (self-review and pre-flight for all review agents)

## Review Agents (`agents/review/`)

| Agent | Expertise |
|-------|-----------|
| ward-sentinel | Security vulnerabilities, OWASP, auth, secrets |
| ember-oracle | Performance bottlenecks, N+1 queries, complexity |
| rune-architect | Architecture compliance, layer boundaries, SOLID |
| simplicity-warden | YAGNI, over-engineering, premature abstraction |
| flaw-hunter | Logic bugs, edge cases, race conditions |
| mimic-detector | DRY violations, code duplication |
| pattern-seer | Cross-cutting consistency: naming, error handling, API design, data modeling, auth, state, logging |
| void-analyzer | Incomplete implementations, TODOs, stubs |
| wraith-finder | Dead code, unwired code, DI wiring gaps, orphaned routes/handlers, AI orphan detection |
| phantom-checker | Dynamic references, reflection analysis |
| phantom-warden | Phantom implementation detection — spec-to-code gaps, doc-vs-implementation drift, unintegrated code, dead specs, missing execution engines, unenforced rules, fallback-as-default (PHNT-) |
| type-warden | Type safety, mypy strict, Python idioms, async correctness |
| trial-oracle | TDD compliance, test quality, coverage gaps, assertions |
| depth-seer | Missing logic, incomplete state machines, complexity hotspots |
| blight-seer | Design anti-patterns, God Service, leaky abstractions, temporal coupling |
| forge-keeper | Data integrity, migration safety, reversibility, lock analysis, transaction boundaries |
| tide-watcher | Async/concurrency patterns, waterfall awaits, unbounded concurrency, cancellation, race conditions |
| reality-arbiter | Production viability truth-telling, deployment gaps, integration honesty |
| assumption-slayer | Premise validation, cargo cult detection, problem-fit analysis |
| entropy-prophet | Long-term consequence analysis, complexity trajectory, lock-in risks |
| naming-intent-analyzer | Naming intent quality, name-behavior mismatch, vague names, boolean inversion, side-effect hiding |
| refactor-guardian | Refactoring completeness, orphaned callers, broken import paths |
| reference-validator | Cross-file reference integrity, config path validation, frontmatter schema |
| doubt-seer | Cross-agent claim verification through adversarial interrogation |
| schema-drift-detector | Schema drift between migrations and ORM/model definitions across 8 frameworks (DRIFT-001 through DRIFT-005) |
| sediment-detector | Feature sediment and dead infrastructure detection for Claude Code plugins — cross-references agents vs spawn sites, talisman config vs consumers, commands vs invokers (SDMT-prefix) |
| agent-parity-reviewer | Agent-native parity — orphan features, context starvation, sandbox isolation (PARITY-001 through PARITY-005) |
| senior-engineer-reviewer | Persona-based senior engineer review — production thinking, temporal reasoning (SENIOR-001 through SENIOR-010) |
| cross-shard-sentinel | Cross-shard consistency analysis — reads only shard summary JSONs, detects import mismatches, auth boundary gaps, naming drift (XSH-001+). Active only when Inscription Sharding is enabled (v1.98.0+) |
| design-implementation-reviewer | Design-to-code fidelity — token compliance, layout matching, responsive coverage, accessibility, variant completeness (FIDE-001 through FIDE-010) |
| ux-heuristic-reviewer | UX heuristic evaluation — Nielsen Norman 10 heuristics at code level, 50+ checklist items (UXH-). Conditional: `ux.enabled` + frontend files |
| ux-flow-validator | User flow completeness — loading states, error boundaries, empty states, confirmation dialogs, undo mechanisms, graceful degradation (UXF-). Conditional: `ux.enabled` + frontend files |
| ux-interaction-auditor | Micro-interaction audit — hover/focus states, keyboard accessibility, touch targets (44px), animation performance, prefers-reduced-motion, scroll behavior (UXI-). Conditional: `ux.enabled` + frontend files |
| ux-cognitive-walker | Cognitive walkthrough — first-time user simulation, discoverability, learnability, error recovery, progressive disclosure (UXC-). Model: opus. Off by default (`cognitive_walkthrough: true` to enable) |
| aesthetic-quality-reviewer | Aesthetic quality beyond pixel fidelity — anti-slop detection, visual coherence, typography, whitespace balance, design personality scoring (0-100). Complements design-implementation-reviewer |
| design-system-compliance-reviewer | Design system convention enforcement — token usage, variant patterns (CVA), import paths, class merge utilities, dark mode. Conditional: frontend stack + design system detected (confidence >= 0.70) |
| flow-integrity-tracer | Field-level data flow verification across UI↔API↔DB layers — field phantoms, persistence gaps, roundtrip asymmetry, display ghosts, schema drift (FLOW-). Conditional: `data_flow.enabled` + 2+ stack layers in diff |

## Research Agents (`agents/research/`)

| Agent | Purpose |
|-------|---------|
| practice-seeker | External best practices and industry patterns |
| repo-surveyor | Codebase exploration and pattern discovery |
| lore-scholar | Framework documentation and API research |
| git-miner | Git history analysis and code archaeology |
| echo-reader | Reads Rune Echoes to surface relevant past learnings |
| wiring-cartographer | Maps integration points where new code connects to existing system (entry points, layers, registration patterns) |
| activation-pathfinder | Traces activation and migration paths for new features (config, migrations, deployment steps) |

## Work Agents (`agents/work/`)

| Agent | Purpose |
|-------|---------|
| rune-smith | Code implementation (TDD-aware swarm worker) |
| trial-forger | Test generation (swarm worker) |
| design-sync-agent | Figma extraction and VSM creation (design swarm worker) |
| design-iterator | Design fidelity iteration — screenshot→analyze→improve loop (design swarm worker) |
| storybook-reviewer | Storybook component verification (read-only) — screenshot capture, Mode A (Design Fidelity) / Mode B (UI Quality Audit), structured findings for storybook-fixer |
| storybook-fixer | Storybook finding fixer — applies one fix per round (SBK-001), re-verifies via screenshot, three-signal stop convergence detection |

## Utility Agents (`agents/utility/`)

| Agent | Purpose |
|-------|---------|
| runebinder | Aggregates Ash findings into TOME.md |
| decree-arbiter | Technical soundness review for plans (9-dimension evaluation) |
| truthseer-validator | Audit coverage validation (Roundtable Phase 5.5) |
| flow-seer | Spec flow analysis and gap detection |
| scroll-reviewer | Document quality review |
| mend-fixer | Parallel code fixer for /rune:mend findings (restricted tools) |
| gap-fixer | Gap remediation fixer for Phase 5.8 — dedicated agent definition in `agents/work/gap-fixer.md` |
| knowledge-keeper | Documentation coverage reviewer for plans |
| elicitation-sage | Structured reasoning using curated methods (summoned per eligible section, max 6 per forge session) |
| veil-piercer-plan | Plan truth-telling (6-dimension analysis, PASS/CONCERN/BLOCK verdicts) |
| horizon-sage | Strategic depth assessment — Temporal Horizon, Root Cause Depth, Innovation Quotient, Stability, Maintainability |
| deployment-verifier | Deployment artifact generation — Go/No-Go checklists, SQL verification, rollback plans, monitoring (DEPLOY-) |
| research-verifier | Validates external research outputs for relevance, accuracy, freshness, cross-validation, and security before plan synthesis (/rune:devise Phase 1C.5) |
| todo-verifier | TODO staleness classification — VALID/FALSE_POSITIVE verdicts with Hypothesis Protocol. Used by /rune:resolve-todos Phase 3 |
| state-weaver | Plan state machine validation — extracts phases, builds transition graphs, validates completeness (10 STSM checks), verifies I/O contracts, generates mermaid diagrams |
| design-analyst | Figma frame relationship classifier — 5-signal weighted composite (name 0.35, component set 0.25, structure 0.20, dimension 0.10, shared instances 0.10), single-linkage clustering. Used by arc Phase 3 (Design Extraction) |
| evidence-verifier | Evidence-based plan claim validation — systematic per-claim verification against codebase/docs/external sources with grounding scores. Used by /rune:devise |
| ux-pattern-analyzer | Codebase UX maturity assessment — inventories loading, error handling, form validation, navigation, empty state, confirmation/undo, and feedback patterns. 4-level maturity scale. Used by devise Phase 0.3 |
| tome-digest | TOME finding extraction — counts P1/P2/P3 severity, extracts recurring prefixes, top findings. Shell-based extraction via artifact-extract.sh (zero LLM tokens). Used by arc Phase 7 (Mend) |
| codex-phase-handler | Delegated Codex phase execution — runs Codex CLI commands as a teammate to keep Tarnished context clean |

## Investigation Agents (`agents/investigation/`)

### Goldmask Agents (Impact Layer + Wisdom Layer + Lore Layer)

Used by `/rune:goldmask`, `/rune:arc` Phase 5.7, and `/rune:devise` predictive mode:

| Agent | Layer | Purpose |
|-------|-------|---------|
| data-layer-tracer | Impact | Impact tracing across data models, schemas, migrations, and storage layers |
| api-contract-tracer | Impact | Impact tracing across API endpoints, contracts, request/response schemas |
| business-logic-tracer | Impact | Impact tracing across business rules, domain logic, and workflow orchestration |
| event-message-tracer | Impact | Impact tracing across event buses, message queues, pub/sub, and async pipelines |
| config-dependency-tracer | Impact | Impact tracing across configuration, environment variables, feature flags, and deployment settings |
| wisdom-sage | Wisdom | Git archaeology — commit intent classification, caution scoring via git blame analysis |
| lore-analyst | Lore | Quantitative git history analysis — churn metrics, co-change clustering, ownership concentration. Used in: goldmask, appraise, audit, devise, forge (Phase 1.5), inspect (Phase 1.3) |
| goldmask-coordinator | Synthesis | Three-layer synthesis — merges Impact + Wisdom + Lore findings into unified GOLDMASK.md report |

### Inspector Agents (Plan-vs-Implementation)

Used by `/rune:inspect` and `/rune:arc` Phase 5.5:

| Agent | Purpose |
|-------|---------|
| grace-warden | Correctness & completeness inspector — plan requirement traceability and implementation status |
| ruin-prophet | Failure modes, security posture, and operational readiness inspector |
| sight-oracle | Design alignment, coupling analysis, and performance profiling inspector |
| vigil-keeper | Test coverage, observability, maintainability, and documentation inspector |
| decree-auditor | Business logic decrees — domain rules, state machine gaps, validation inconsistencies, invariant violations |
| fringe-watcher | Edge cases — missing boundary checks, unhandled null/empty inputs, race conditions, overflow risks |
| rot-seeker | Tech debt rot — TODOs, deprecated patterns, complexity hotspots, unmaintained code, dependency debt |
| strand-tracer | Integration strands — unconnected modules, broken imports, unused exports, dead routes, unwired DI |
| truth-seeker | Correctness truth — logic vs requirements, behavior validation, test quality, state machine correctness |
| ruin-watcher | Failure modes — network failures, crash recovery, circuit breakers, timeout chains, resource lifecycle |
| breach-hunter | Security breaches — threat modeling, auth boundary gaps, data exposure vectors, CVE patterns, input sanitization |
| order-auditor | Design order — responsibility separation, dependency direction, coupling metrics, abstraction fitness, layer boundaries |
| ember-seer | Performance embers — resource lifecycle degradation, memory patterns, pool management, async correctness, algorithmic complexity |
| signal-watcher | Signal propagation — logging adequacy, metrics coverage, distributed tracing, error classification, incident reproducibility |
| decay-tracer | Progressive decay — naming quality erosion, comment staleness, complexity creep, convention drift, tech debt trajectories |

### Debugging Agents

Used by `/rune:debug` skill:

| Agent | Purpose |
|-------|---------|
| hypothesis-investigator | ACH-based hypothesis investigation — structured Analysis of Competing Hypotheses with 4 evidence tiers (DIRECT/CORRELATIONAL/TESTIMONIAL/ABSENCE) and consistency matrix scoring |

## Testing Agents (`registry/testing/` — all EXTENDED)

| Agent | Purpose |
|-------|---------|
| unit-test-runner | Diff-scoped unit test execution — pytest, jest, vitest (model: sonnet) |
| integration-test-runner | Integration test execution with service dependency management (model: sonnet) |
| e2e-browser-tester | E2E browser testing via agent-browser with file-to-route mapping (model: sonnet) |
| extended-test-runner | Extended-tier test execution with checkpoint/resume protocol — heartbeat liveness, budget enforcement, atomic checkpoint writes for crash recovery (model: sonnet) |
| contract-validator | API contract validation — OpenAPI/JSON Schema compliance, hook output formats, request/response consistency (model: sonnet) |
| test-failure-analyst | Read-only failure analysis — root cause classification and fix suggestions (maxTurns: 15) |

## QA Verifier Agents (`agents/qa/`)

| Agent | Purpose |
|-------|---------|
| phase-qa-verifier | Independent arc phase completion artifact verification — PASS/FAIL verdict |
| code-review-qa-verifier | Code review phase TOME existence, finding structure, Ash prefix validity |
| forge-qa-verifier | Forge phase enriched plan existence, enrichment depth/quality |
| gap-analysis-qa-verifier | Gap analysis compliance matrix, per-criterion status, code evidence |
| mend-qa-verifier | Mend phase resolution report, per-finding status, commit SHA references |
| test-qa-verifier | Test phase test report, SEAL markers, strategy ordering, tier coverage |
| work-qa-verifier | Work phase delegation manifests, task files, worker reports, evidence quality |

## Meta-QA Agents (`agents/meta-qa/`)

| Agent | Purpose |
|-------|---------|
| effectiveness-analyzer | Per-agent finding accuracy, false-positive rates, unique contribution |
| hallucination-detector | Phantom claims, inflated scores, evidence fabrication detection |
| rule-consistency-auditor | CLAUDE.md vs skill instruction contradictions, stale references |
| convergence-analyzer | Review-mend convergence efficiency, retry patterns, stagnation |
| workflow-auditor | Workflow definition validation, phase ordering, handoff contracts |
| hook-integrity-auditor | hooks.json vs script existence, executability, timeout validation |
| prompt-linter | Agent definition consistency, frontmatter completeness, tool permissions |
| improvement-advisor | Concrete fix proposals for Etched-tier meta-QA findings |
