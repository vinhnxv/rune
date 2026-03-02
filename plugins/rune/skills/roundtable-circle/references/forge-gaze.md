# Forge Gaze — Topic-Aware Agent Selection for Plan Enrichment

> Matches plan section topics to specialized agents for plan enrichment (default in `/rune:devise` and `/rune:forge`). Analogous to [Rune Gaze](rune-gaze.md) (file extensions → Ash for reviews). Use `--quick` with `/rune:devise` to skip forge.

## Table of Contents

- [Topic Registry](#topic-registry)
  - [Review Agents (Enrichment Budget)](#review-agents-enrichment-budget)
  - [Research Agents (Research Budget)](#research-agents-research-budget)
  - [Utility Agents (Enrichment Budget)](#utility-agents-enrichment-budget)
- [Matching Algorithm](#matching-algorithm)
  - [Topic Extraction](#topic-extraction)
  - [Scoring](#scoring)
  - [Selection](#selection)
  - [Constants](#constants)
- [Budget Tiers](#budget-tiers)
- [Forge Modes](#forge-modes)
  - [Default](#default-runs-automatically-in-runeplan-and-runeforge)
  - [--exhaustive](#--exhaustive)
- [Custom Forge Agents](#custom-forge-agents)
- [Fallback Behavior](#fallback-behavior)
- [Dry-Run Output](#dry-run-output)
- [References](#references)

## Topic Registry

Each agent declares which plan section topics it can enrich, what subsection it produces, and its perspective focus.

> **Note**: Forge Gaze matches agents **individually** (each agent scores independently against section topics), unlike `/rune:appraise` where agents are grouped into Ash composites.

### Review Agents (Enrichment Budget)

| Agent | Topics | Subsection | Perspective |
|-------|--------|------------|-------------|
| ward-sentinel | security, authentication, authorization, owasp, secrets, input-validation, csrf, xss, injection | Security Considerations | security vulnerabilities and threat modeling |
| ember-oracle | performance, scalability, caching, database, queries, n-plus-one, latency, memory, async | Performance Considerations | performance bottlenecks and optimization opportunities |
| rune-architect | architecture, layers, boundaries, solid, dependencies, services, patterns, design | Architecture Analysis | architectural compliance and structural integrity |
| flaw-hunter | edge-cases, null-handling, race-conditions, concurrency, error-handling, validation, boundaries | Edge Cases & Risk Analysis | logic bugs, race conditions, and edge case coverage |
| pattern-seer | patterns, conventions, naming, consistency, style, standards, api-design, error-handling, data-modeling, auth-patterns, state-management, logging, observability-format | Cross-Cutting Consistency | naming, error handling, API design, data modeling, auth, state, and logging consistency |
| simplicity-warden | complexity, yagni, abstraction, over-engineering, simplicity, minimal | Simplicity Review | unnecessary complexity and YAGNI violations |
| mimic-detector | duplication, dry, reuse, similar, copy-paste, shared | Reuse Opportunities | code duplication and reuse opportunities |
| void-analyzer | completeness, todo, stub, placeholder, partial, implementation, missing | Completeness Gaps | incomplete implementations, stubs, and TODO coverage |
| wraith-finder | dead-code, unused, orphan, deprecated, legacy, cleanup, removal, unwired, di-wiring, router-registration, event-subscription, ai-orphan | Dead Code & Unwired Code Risk | dead code, unwired DI services, orphaned routes/handlers, and AI-generated orphan detection |
| phantom-checker | dynamic, reflection, metaprogramming, string-dispatch, runtime, magic | Dynamic Reference Analysis | dynamic references and runtime resolution concerns |
| type-warden | types, type-safety, mypy, annotations, hints, python, idioms, async, docstrings | Type Safety Analysis | type annotation coverage, language idioms, and async correctness |
| trial-oracle | testing, tdd, coverage, assertions, test-quality, pytest, edge-cases, fixtures | Test Quality Analysis | TDD compliance, test coverage gaps, and assertion quality |
| depth-seer | missing-logic, error-handling, validation, state-machine, complexity, rollback, boundaries | Missing Logic Analysis | incomplete error handling, state machine gaps, and complexity hotspots |
| blight-seer | anti-patterns, god-service, leaky-abstraction, temporal-coupling, observability, consistency-model, failure-modes, primitive-obsession, design-smells | Design Anti-Pattern Analysis | architectural smells, design flaws, and systemic quality degradation |
| forge-keeper | migration, schema, database, transaction, integrity, reversibility, lock, cascade, referential, privacy, pii, audit, backfill | Data Integrity Analysis | migration safety, transaction boundaries, and data integrity verification |
| tide-watcher | async, concurrency, await, waterfall, race-condition, cancellation, semaphore, timer, cleanup, structured-concurrency, promise, goroutine, tokio, asyncio | Async & Concurrency Analysis | async correctness, concurrency patterns, and race condition detection |
| refactor-guardian | refactor, extract, move, rename, split, migration, reorganize, restructure | Refactoring Integrity Analysis | refactoring completeness, orphaned callers, and extraction verification |
| reference-validator | imports, references, paths, config, frontmatter, version, manifest, cross-reference, validation | Reference & Configuration Integrity | import path validation, config-to-source references, frontmatter schema, and version sync |
| reality-arbiter | production, deployment, integration, viability, realistic, monitoring, operational, observability, real-world | Production Viability Analysis | production readiness and integration honesty |
| assumption-slayer | assumptions, premise, justification, rationale, why, problem-fit, cargo-cult, fashion, hype, trend | Assumption Challenge | premise validation and cargo cult detection |
| entropy-prophet | maintenance, long-term, debt, lock-in, vendor, dependency, evolution, future, entropy, cost, burden | Long-term Consequence Analysis | hidden costs, complexity trajectory, and lock-in risks |

### Research Agents (Research Budget)

| Agent | Topics | Subsection | Perspective |
|-------|--------|------------|-------------|
| practice-seeker | best-practices, industry, standards, conventions, recommendations, patterns | Best Practices | external best practices and industry standards |
| lore-scholar | framework, library, api, documentation, version, migration, deprecation | Framework Documentation | framework-specific APIs and version constraints |

### Utility Agents (Enrichment Budget)

| Agent | Topics | Subsection | Perspective |
|-------|--------|------------|-------------|
| flow-seer | user-flow, ux, interaction, workflow, requirements, gaps, completeness | User Flow Analysis | user flow completeness and requirement gaps |
| horizon-sage | strategy, sustainability, long-term, root-cause, future-risk, tech-debt, innovation, resilience, maintainability-trajectory, depth, viability, quick-fix, temporal-horizon | Strategic Depth Analysis | strategic viability, long-term sustainability, and root-cause depth |
| state-weaver | state-machine, phases, transitions, pipeline, workflow, lifecycle, contracts, dataflow, input, output, steps, stages, dead-end, unreachable | State Machine Analysis | plan phase completeness, transition correctness, and I/O contract validation |

### Stack Specialist Agents (Enrichment Budget, v1.86.0+)

> Stack specialist agents participate in Forge Gaze when the project stack is detected. They provide stack-specific enrichment with affinity-boosted scoring. See `skills/stacks/references/detection.md` for detection logic.

| Agent | Topics | Stack Affinities | Subsection | Perspective |
|-------|--------|-----------------|------------|-------------|
| python-reviewer | python, type-hints, async, protocols, dataclass | [python] | Python Patterns | Python-specific type safety, async correctness, and modern idioms |
| fastapi-reviewer | fastapi, pydantic, depends, openapi, idor, api-routes | [fastapi, python] | FastAPI Patterns | FastAPI route design, Pydantic validation, and dependency injection |
| django-reviewer | django, orm, csrf, admin, signals, middleware | [django, python] | Django Patterns | Django ORM optimization, security, and middleware patterns |
| laravel-reviewer | laravel, eloquent, blade, middleware, gates, artisan | [laravel, php] | Laravel Patterns | Laravel Eloquent, Blade security, and authorization patterns |
| sqlalchemy-reviewer | sqlalchemy, orm, session, migration, eager-loading, n-plus-one | [sqlalchemy, python] | SQLAlchemy Patterns | SQLAlchemy session management, N+1 detection, and migration safety |
| tdd-compliance-reviewer | testing, tdd, coverage, test-first, assertion, pytest | [python, typescript, rust, php] | TDD Compliance | Test-first development, coverage thresholds, and assertion quality |
| design-implementation-reviewer | design-system, design-tokens, ui-layout, responsive-design, visual-fidelity, component-variants, figma, accessibility-design, component-states, design-spec | [react, vue, svelte, nextjs, typescript] | Design Implementation | Design fidelity, token usage, responsive compliance, and accessibility |

### Elicitation Methods (Agent Budget — elicitation-sage)

> **Architecture change (v1.31)**: Methods are now executed by a dedicated `elicitation-sage` agent instead of prompt modifiers. The sage is summoned per section where elicitation keywords match. Sage runs in parallel with forge agents.

> **Note**: This topic table is derived from `skills/elicitation/methods.csv`. Re-verify after CSV changes.

**Keyword pre-filter**: Before summoning a sage for a section, check section text (title + first 200 chars) for elicitation keywords: `architecture`, `security`, `risk`, `design`, `trade-off`, `migration`, `performance`, `decision`, `approach`, `comparison`. Sections with zero keyword hits skip sage invocation.

**Per-section fan-out**: MAX 1 sage per section in forge context (focused enrichment). Total cap: `MAX_FORGE_SAGES = 6` across all sections (prevents agent explosion).

**Sage lifecycle**: Each sage reads `skills/elicitation/methods.csv` at runtime, scores methods against section topics, applies the top-scored method, and writes output to `tmp/plans/{timestamp}/forge/{section-slug}-elicitation-{method-name}.md`. Output is merged alongside forge agent enrichments.

| Method | Topics | Output Template | Agent |
|--------|--------|----------------|-------|
| Tree of Thoughts | architecture, design, complex, multiple-approaches, decisions | paths → evaluation → selection | elicitation-sage |
| Architecture Decision Records | architecture, design, trade-offs, decisions, ADR | options → trade-offs → decision → rationale | elicitation-sage |
| Comparative Analysis Matrix | approach, comparison, evaluation, selection, criteria | options → criteria → scores → recommendation | elicitation-sage |
| Pre-mortem Analysis | risk, deployment, migration, breaking-change, failure | failure → causes → prevention | elicitation-sage |
| First Principles Analysis | novel, assumptions, first-principles, fundamentals | assumptions → truths → new approach | elicitation-sage |
| Red Team vs Blue Team | security, auth, injection, api, secrets, vulnerability | defense → attack → hardening | elicitation-sage |
| Debate Club Showdown | approaches, comparison, trade-offs, alternatives | thesis → antithesis → synthesis | elicitation-sage |

**Summoning pattern** (ATE-1 compliant):
```javascript
// Sage is spawned as general-purpose with identity via prompt
Agent({
  team_name: "rune-plan-{timestamp}",
  name: `elicitation-sage-forge-{sectionIndex}`,
  subagent_type: "general-purpose",
  prompt: `You are elicitation-sage — structured reasoning specialist.
    Bootstrap: Read skills/elicitation/SKILL.md and skills/elicitation/methods.csv
    Phase: forge:3 | Section: "{section.title}" | Content: {first 2000 chars}
    Write output to: tmp/plans/{timestamp}/forge/{section.slug}-elicitation-{method}.md`,
  run_in_background: true
})
```

**Disable**: Set `elicitation.enabled: false` in talisman.yml to skip all sage invocations.

Sage output is logged alongside forge agent enrichments in dry-run output (see [Dry-Run Output](#dry-run-output)).

## Matching Algorithm

### Topic Extraction

Extract topics from a plan section's title and content:

```
extract_topics(title, content):
  1. title_words = lowercase(title).split() → filter stopwords
  2. content_signal = first 200 chars of content → extract nouns/adjectives
  3. return unique(title_words + content_signal)
```

Stopwords to filter: `the, a, an, and, or, of, for, in, to, with, is, are, this, that, will, be, on, at, by`

### Scoring

For each plan section, score every agent in the topic registry:

```
score(section, agent, detected_stack=null):
  section_topics = extract_topics(section.title, section.content)

  # Keyword overlap: how many agent topics appear in section topics
  matches = count(topic for topic in agent.topics if topic in section_topics
                  OR any(section_word.startswith(topic) for section_word in section_topics))
  keyword_score = matches / len(agent.topics)

  # Title match bonus: agent's top-3 topics appearing in section title
  title_bonus = 0.3 if any(topic in section.title.lower() for topic in agent.topics[:3]) else 0.0

  # Stack affinity bonus (v1.86.0+): boost agents whose stack_affinities
  # match the detected project stack. Configurable via talisman forge.stack_affinity_bonus.
  stack_bonus = 0.0
  if agent.stack_affinities AND detected_stack:
    stack_affinity_bonus = talisman.forge.stack_affinity_bonus ?? 0.2
    for affinity in agent.stack_affinities:
      if affinity in detected_stack.frameworks \
         OR affinity in detected_stack.libraries \
         OR affinity == detected_stack.primary_language:
        stack_bonus = stack_affinity_bonus
        break

  # Combined score (capped at 1.0)
  return min(keyword_score + title_bonus + stack_bonus, 1.0)
```

### Selection

```
forge_select(plan_sections, topic_registry, mode="default"):
  threshold = THRESHOLD_DEFAULT if mode == "default" else THRESHOLD_EXHAUSTIVE
  max_per_section = MAX_PER_SECTION_DEFAULT if mode == "default" else MAX_PER_SECTION_EXHAUSTIVE
  include_research = (mode == "exhaustive")

  total_agents = 0
  assignments = {}

  for each section in plan_sections:
    candidates = []

    for each agent in topic_registry:
      # Skip research-budget agents in default mode
      if agent.budget == "research" and not include_research:
        continue

      s = score(section, agent)
      if s >= threshold:
        candidates.append((agent, s))

    # Sort by score descending, cap per section
    candidates.sort(by=score, descending)
    selected = candidates[:max_per_section]

    # Enforce total agent cap
    if total_agents + len(selected) > MAX_TOTAL_AGENTS:
      selected = selected[:MAX_TOTAL_AGENTS - total_agents]

    total_agents += len(selected)
    assignments[section] = selected

    if total_agents >= MAX_TOTAL_AGENTS:
      break  # Budget exhausted

  return assignments
```

### Constants

| Constant | Default | Exhaustive | Description |
|----------|---------|------------|-------------|
| `THRESHOLD` | 0.30 | 0.15 | Minimum score to select an agent |
| `MAX_PER_SECTION` | 3 | 5 | Maximum agents per plan section |
| `MAX_TOTAL_AGENTS` | 8 | 12 | Hard cap across all sections |
| `MAX_FORGE_SAGES` | 6 | 6 | Max elicitation sages per forge session (not configurable via talisman) |

These can be overridden via `talisman.yml`:

```yaml
forge:
  threshold: 0.30          # Range: 0.0-1.0
  max_per_section: 3       # Hard upper bound: 5
  max_total_agents: 8      # Hard upper bound: 15
```

**Validation bounds**: `threshold` must be between 0.0 and 1.0. `max_per_section` capped at 5. `max_total_agents` capped at 15. Values exceeding bounds are clamped silently.

## Budget Tiers

| Budget | Agents | Behavior | Token Cost |
|--------|--------|----------|-----------|
| `enrichment` | Review + utility agents | Read plan section, apply expertise, write perspective | ~5k tokens |
| `research` | practice-seeker, lore-scholar | Web search, docs lookup, deeper analysis | ~15k tokens |

- **Default forge**: Only `enrichment` budget agents
- **`--exhaustive`**: Both `enrichment` and `research` budget agents

## Forge Modes

### Default (runs automatically in `/rune:devise` and `/rune:forge`)

```
1. Parse plan into sections (## headings)
2. Run Forge Gaze matching (enrichment agents only)
3. Log selection transparently
4. Summon matched agents per section
5. Each agent writes to: tmp/plans/{timestamp}/forge/{section-slug}-{agent-name}.md
6. Lead merges enrichments into plan document
```

Use `--quick` with `/rune:devise` to skip forge, or `--no-forge` for granular control.

### --exhaustive

Same flow but with:
- Lower threshold (0.15 vs 0.30)
- Higher per-section cap (5 vs 3)
- Higher total cap (12 vs 8)
- Research-budget agents included
- Two-tier aggregation: per-section synthesizer → lead
- Cost warning displayed before summoning

## Custom Forge Agents

Custom Ashes from `talisman.yml` can participate in forge by adding `forge` to their `workflows` list and providing forge-specific config:

```yaml
ashes:
  custom:
    - name: "api-contract-reviewer"
      agent: "api-contract-reviewer"
      source: local
      workflows: [review, audit, forge]   # "forge" enables Forge Gaze matching
      trigger:
        extensions: [".py", ".ts"]        # For review/audit (file-based)
        topics: [api, contract, endpoints, rest, graphql]  # For forge (topic-based)
      forge:
        subsection: "API Contract Analysis"
        perspective: "API design, contract compatibility, and endpoint patterns"
        budget: enrichment
      context_budget: 15
      finding_prefix: "API"
```

### Custom Agent Validation

If `forge` is in `workflows`, these fields are **required**:
- `trigger.topics` — at least 2 topics
- `forge.subsection` — the subsection title this agent produces
- `forge.perspective` — description of the agent's focus area
- `forge.budget` — `enrichment` or `research`

## Fallback Behavior

If no agent scores above the threshold for a section:
- Use an inline generic Task prompt (not a named agent) as fallback — the orchestrator summons a general-purpose agent with a generic "research and enrich this section" prompt
- The generic prompt produces the standard structured subsections

Fallback uses an inline generic prompt — no dedicated `forge-researcher` agent definition.

## Dry-Run Output (Not Yet Implemented)

> **Note**: `--dry-run` is not yet implemented in `/rune:devise`. The format below is the target specification for when it is added. Currently, Forge Gaze logs its selection transparently in the console output during Phase 3.

When `--dry-run` is used, display selection without summoning (forge runs by default; `--quick` skips it):

```
Forge Gaze — Agent Selection
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Plan sections: 6
Agents available: 26 built-in (22 review + 2 research + 2 utility) + custom
Methods available: 7 (via elicitation-sage agent — MAX_FORGE_SAGES = 6 cap, keyword pre-filtered)

Section: "Technical Approach"
  ✓ rune-architect (0.85) — architecture compliance
  ✓ pattern-seer (0.45) — pattern alignment
  ✓ simplicity-warden (0.35) — complexity check

Section: "Security Requirements"
  ✓ ward-sentinel (0.95) — security vulnerabilities
  ✓ flaw-hunter (0.40) — edge cases

Section: "Performance Targets"
  ✓ ember-oracle (0.90) — performance bottlenecks

Section: "API Design"
  ✓ api-contract-reviewer (0.80) — API contracts [custom]
  ✓ pattern-seer (0.35) — pattern alignment

Section: "Overview" — no agent matched (below threshold)
Section: "References" — no agent matched (below threshold)

Total: 8 agent invocations across 4 sections (2 sections skipped)
Estimated tokens: ~40k (enrichment only)
```

## References

- [Rune Gaze](rune-gaze.md) — File extension → Ash matching (analogous system for reviews)
- [Circle Registry](circle-registry.md) — Agent-to-Ash mapping
- [Smart Selection](smart-selection.md) — File assignment and budget enforcement
- [Custom Ash](custom-ashes.md) — Custom agent schema (extended for forge)
