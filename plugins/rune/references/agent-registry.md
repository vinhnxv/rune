# Agent Registry

**Total: 91 agents** (40 review + 5 research + 4 work + 14 utility* + 24 investigation + 4 testing)

\* 14 utility agents; gap-fixer is additionally prompt-template-based (no dedicated .md file) and not counted in the total.

Shared resources: [Review Checklist](../agents/review/references/review-checklist.md) (self-review and pre-flight for all review agents)

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
| python-reviewer | Python type safety, async correctness, modern idioms (PY-001 through PY-010) |
| typescript-reviewer | TypeScript type system, strict mode, generics patterns (TSR-001 through TSR-010) |
| rust-reviewer | Rust ownership, lifetimes, unsafe blocks, async safety (RST-001 through RST-016) |
| axum-reviewer | Axum/SQLx web service patterns: N+1 queries, extractor ordering, IDOR, Tower middleware (AXUM-001 through AXUM-010) |
| php-reviewer | PHP type system, namespacing, security patterns (PHP-001 through PHP-010) |
| fastapi-reviewer | FastAPI route design, Pydantic validation, dependency injection (FAPI-001 through FAPI-010) |
| django-reviewer | Django ORM, security, middleware patterns (DJG-001 through DJG-010) |
| laravel-reviewer | Eloquent, Blade security, authorization (LARV-001 through LARV-010) |
| sqlalchemy-reviewer | Session management, N+1 detection, migration safety (SQLA-001 through SQLA-010) |
| tdd-compliance-reviewer | Test-first development, coverage, assertion quality (TDD-001 through TDD-010) |
| ddd-reviewer | Domain-Driven Design patterns and bounded contexts (DDD-001 through DDD-010) |
| di-reviewer | Dependency injection patterns and wiring validation (DI-001 through DI-010) |
| schema-drift-detector | Schema drift between migrations and ORM/model definitions across 8 frameworks (DRIFT-001 through DRIFT-005) |
| agent-parity-reviewer | Agent-native parity — orphan features, context starvation, sandbox isolation (PARITY-001 through PARITY-005) |
| senior-engineer-reviewer | Persona-based senior engineer review — production thinking, temporal reasoning (SENIOR-001 through SENIOR-010) |
| cross-shard-sentinel | Cross-shard consistency analysis — reads only shard summary JSONs, detects import mismatches, auth boundary gaps, naming drift (XSH-001+). Active only when Inscription Sharding is enabled (v1.98.0+) |
| design-implementation-reviewer | Design-to-code fidelity — token compliance, layout matching, responsive coverage, accessibility, variant completeness (FIDE-001 through FIDE-010) |

## Research Agents (`agents/research/`)

| Agent | Purpose |
|-------|---------|
| practice-seeker | External best practices and industry patterns |
| repo-surveyor | Codebase exploration and pattern discovery |
| lore-scholar | Framework documentation and API research |
| git-miner | Git history analysis and code archaeology |
| echo-reader | Reads Rune Echoes to surface relevant past learnings |

## Work Agents (`agents/work/`)

| Agent | Purpose |
|-------|---------|
| rune-smith | Code implementation (TDD-aware swarm worker) |
| trial-forger | Test generation (swarm worker) |
| design-sync-agent | Figma extraction and VSM creation (design swarm worker) |
| design-iterator | Design fidelity iteration — screenshot→analyze→improve loop (design swarm worker) |

## Utility Agents (`agents/utility/`)

| Agent | Purpose |
|-------|---------|
| runebinder | Aggregates Ash findings into TOME.md |
| decree-arbiter | Technical soundness review for plans (9-dimension evaluation) |
| truthseer-validator | Audit coverage validation (Roundtable Phase 5.5) |
| flow-seer | Spec flow analysis and gap detection |
| scroll-reviewer | Document quality review |
| mend-fixer | Parallel code fixer for /rune:mend findings (restricted tools) |
| gap-fixer | Gap remediation fixer for Phase 5.8 — prompt-template-based (no dedicated .md file, uses `skills/roundtable-circle/references/ash-prompts/gap-fixer.md`) |
| knowledge-keeper | Documentation coverage reviewer for plans |
| elicitation-sage | Structured reasoning using curated methods (summoned per eligible section, max 6 per forge session) |
| veil-piercer-plan | Plan truth-telling (6-dimension analysis, PASS/CONCERN/BLOCK verdicts) |
| horizon-sage | Strategic depth assessment — Temporal Horizon, Root Cause Depth, Innovation Quotient, Stability, Maintainability |
| deployment-verifier | Deployment artifact generation — Go/No-Go checklists, SQL verification, rollback plans, monitoring (DEPLOY-) |
| research-verifier | Validates external research outputs for relevance, accuracy, freshness, cross-validation, and security before plan synthesis (/rune:devise Phase 1C.5) |
| state-weaver | Plan state machine validation — extracts phases, builds transition graphs, validates completeness (10 STSM checks), verifies I/O contracts, generates mermaid diagrams |

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

## Testing Agents (`agents/testing/`)

| Agent | Purpose |
|-------|---------|
| unit-test-runner | Diff-scoped unit test execution — pytest, jest, vitest (model: sonnet) |
| integration-test-runner | Integration test execution with service dependency management (model: sonnet) |
| e2e-browser-tester | E2E browser testing via agent-browser with file-to-route mapping (model: sonnet) |
| test-failure-analyst | Read-only failure analysis — root cause classification and fix suggestions (maxTurns: 15) |
