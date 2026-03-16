# Forge Gaze — Topic-Aware Agent Selection for Plan Enrichment

> Matches plan section topics to specialized agents for plan enrichment (default in `/rune:devise` and `/rune:forge`). Analogous to [Rune Gaze](rune-gaze.md) (file extensions → Ash for reviews). Use `--quick` with `/rune:devise` to skip forge.

## Table of Contents

- [Topic Registry](#topic-registry)
  - [Review Agents (Enrichment Budget)](#review-agents-enrichment-budget)
  - [Research Agents (Research Budget)](#research-agents-research-budget)
  - [Utility Agents (Enrichment Budget)](#utility-agents-enrichment-budget)
  - [Weight Overrides](#weight-overrides)
- [Matching Algorithm](#matching-algorithm)
  - [Topic Extraction](#topic-extraction)
  - [Scoring](#scoring)
  - [Exclusion Penalty](#exclusion-penalty)
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

> **DOC-002: Excludes column** — The `Excludes` column lists topics that, when present in a section, trigger a score penalty via `exclusion_penalty()` (see [Exclusion Penalty](#exclusion-penalty)). Agents with `—` in this column have no exclusions and are never penalized. The penalty scales with the fraction of excluded topics found in the section, up to `EXCLUSION_PENALTY_WEIGHT` (default 0.5). This prevents, e.g., ward-sentinel from being selected for a pure CSS styling section even if "security" is mentioned in passing.

### Review Agents (Enrichment Budget)

| Agent | Topics | Excludes | Subsection | Perspective |
|-------|--------|----------|------------|-------------|
| ward-sentinel | security, authentication, authorization, owasp, secrets, input-validation, csrf, xss, injection | ui-styling, css-layout, animation | Security Considerations | security vulnerabilities and threat modeling |
| ember-oracle | performance, scalability, caching, database, queries, n-plus-one, latency, memory, async | documentation, naming, conventions | Performance Considerations | performance bottlenecks and optimization opportunities |
| rune-architect | architecture, layers, boundaries, solid, dependencies, services, patterns, design | testing, migration, security | Architecture Analysis | architectural compliance and structural integrity | <!-- VEIL-010: rune-architect participates in forge topic scoring like any other agent. However, in `/rune:appraise --deep` and `/rune:arc` Phase 4, rune-architect is ALSO summoned separately as a dedicated architecture reviewer (see circle-registry.md). This dual presence is intentional: forge enrichment is additive (plan-time), while review is evaluative (post-implementation). Excluding rune-architect from forge would leave architectural concerns unaddressed during planning. -->
| flaw-hunter | edge-cases, null-handling, race-conditions, concurrency, error-handling, validation, boundaries | documentation, naming, simplicity | Edge Cases & Risk Analysis | logic bugs, race conditions, and edge case coverage |
| pattern-seer | patterns, conventions, naming, consistency, style, standards, api-design, error-handling, data-modeling, auth-patterns, state-management, logging, observability-format | — | Cross-Cutting Consistency | naming, error handling, API design, data modeling, auth, state, and logging consistency |
| simplicity-warden | complexity, yagni, abstraction, over-engineering, simplicity, minimal | — | Simplicity Review | unnecessary complexity and YAGNI violations |
| mimic-detector | duplication, dry, reuse, similar, copy-paste, shared | — | Reuse Opportunities | code duplication and reuse opportunities |
| void-analyzer | completeness, todo, stub, placeholder, partial, implementation, missing | — | Completeness Gaps | incomplete implementations, stubs, and TODO coverage |
| wraith-finder | dead-code, unused, orphan, deprecated, legacy, cleanup, removal, unwired, di-wiring, router-registration, event-subscription, ai-orphan | — | Dead Code & Unwired Code Risk | dead code, unwired DI services, orphaned routes/handlers, and AI-generated orphan detection |
| phantom-checker | dynamic, reflection, metaprogramming, string-dispatch, runtime, magic | — | Dynamic Reference Analysis | dynamic references and runtime resolution concerns |
| type-warden | types, type-safety, mypy, annotations, hints, python, idioms, async, docstrings | — | Type Safety Analysis | type annotation coverage, language idioms, and async correctness |
| trial-oracle | testing, tdd, coverage, assertions, test-quality, pytest, edge-cases, fixtures | — | Test Quality Analysis | TDD compliance, test coverage gaps, and assertion quality |
| depth-seer | missing-logic, error-handling, validation, state-machine, complexity, rollback, boundaries | — | Missing Logic Analysis | incomplete error handling, state machine gaps, and complexity hotspots |
| blight-seer | anti-patterns, god-service, leaky-abstraction, temporal-coupling, observability, consistency-model, failure-modes, primitive-obsession, design-smells | — | Design Anti-Pattern Analysis | architectural smells, design flaws, and systemic quality degradation |
| forge-keeper | migration, schema, database, transaction, integrity, reversibility, lock, cascade, referential, privacy, pii, audit, backfill | testing, naming, patterns | Data Integrity Analysis | migration safety, transaction boundaries, and data integrity verification |
| tide-watcher | async, concurrency, await, waterfall, race-condition, cancellation, semaphore, timer, cleanup, structured-concurrency, promise, goroutine, tokio, asyncio | — | Async & Concurrency Analysis | async correctness, concurrency patterns, and race condition detection |
| refactor-guardian | refactor, extract, move, rename, split, migration, reorganize, restructure | — | Refactoring Integrity Analysis | refactoring completeness, orphaned callers, and extraction verification |
| reference-validator | imports, references, paths, config, frontmatter, version, manifest, cross-reference, validation | — | Reference & Configuration Integrity | import path validation, config-to-source references, frontmatter schema, and version sync |
| reality-arbiter | production, deployment, integration, viability, realistic, monitoring, operational, observability, real-world | — | Production Viability Analysis | production readiness and integration honesty |
| assumption-slayer | assumptions, premise, justification, rationale, why, problem-fit, cargo-cult, fashion, hype, trend | — | Assumption Challenge | premise validation and cargo cult detection |
| entropy-prophet | maintenance, long-term, debt, lock-in, vendor, dependency, evolution, future, entropy, cost, burden | — | Long-term Consequence Analysis | hidden costs, complexity trajectory, and lock-in risks |

### Research Agents (Research Budget)

| Agent | Topics | Excludes | Subsection | Perspective |
|-------|--------|----------|------------|-------------|
| practice-seeker | best-practices, industry, standards, conventions, recommendations, patterns | — | Best Practices | external best practices and industry standards |
| lore-scholar | framework, library, api, documentation, version, migration, deprecation | — | Framework Documentation | framework-specific APIs and version constraints |

### Utility Agents (Enrichment Budget)

| Agent | Topics | Excludes | Subsection | Perspective |
|-------|--------|----------|------------|-------------|
| flow-seer | user-flow, ux, interaction, workflow, requirements, gaps, completeness | — | User Flow Analysis | user flow completeness and requirement gaps |
| horizon-sage | strategy, sustainability, long-term, root-cause, future-risk, tech-debt, innovation, resilience, maintainability-trajectory, depth, viability, quick-fix, temporal-horizon | — | Strategic Depth Analysis | strategic viability, long-term sustainability, and root-cause depth |
| state-weaver | state-machine, phases, transitions, pipeline, workflow, lifecycle, contracts, dataflow, input, output, steps, stages, dead-end, unreachable | — | State Machine Analysis | plan phase completeness, transition correctness, and I/O contract validation |

### Stack Specialist Prompts (Enrichment Budget, v1.86.0+)

> Stack specialist prompts participate in Forge Gaze when the project stack is detected. They provide stack-specific enrichment with affinity-boosted scoring. See `skills/stacks/references/detection.md` for detection logic.
>
> These are prompt templates at `specialist-prompts/` (not registered agents). `buildAshPrompt()` loads them via filesystem-derived dispatch when the specialist name is detected in `specialist-prompts/`.

| Agent | Topics | Excludes | Stack Affinities | Subsection | Perspective |
|-------|--------|----------|-----------------|------------|-------------|
| python-reviewer | python, type-hints, async, protocols, dataclass | — | [python] | Python Patterns | Python-specific type safety, async correctness, and modern idioms |
| fastapi-reviewer | fastapi, pydantic, depends, openapi, idor, api-routes | — | [fastapi, python] | FastAPI Patterns | FastAPI route design, Pydantic validation, and dependency injection |
| django-reviewer | django, orm, csrf, admin, signals, middleware | — | [django, python] | Django Patterns | Django ORM optimization, security, and middleware patterns |
| laravel-reviewer | laravel, eloquent, blade, middleware, gates, artisan | — | [laravel, php] | Laravel Patterns | Laravel Eloquent, Blade security, and authorization patterns |
| sqlalchemy-reviewer | sqlalchemy, orm, session, migration, eager-loading, n-plus-one | — | [sqlalchemy, python] | SQLAlchemy Patterns | SQLAlchemy session management, N+1 detection, and migration safety |
| tdd-compliance-reviewer | testing, tdd, coverage, test-first, assertion, pytest | — | [python, typescript, rust, php] | TDD Compliance | Test-first development, coverage thresholds, and assertion quality |
| design-implementation-reviewer | design-system, design-tokens, ui-layout, responsive-design, visual-fidelity, component-variants, figma, accessibility-design, component-states, design-spec | — | [react, vue, svelte, nextjs, typescript] | Design Implementation | Design fidelity, token usage, responsive compliance, and accessibility |

### Weight Overrides

Agents with uniform topic weights (all topics equally important) need no entry here — the scoring algorithm treats list-format topics as weight 1.0 each. Only agents with graduated expertise declare weight overrides using dict format. Topics MUST be listed in descending weight order (highest first) since the top-3 by weight drive the `title_bonus` calculation.

**ward-sentinel** (security specialist):
```yaml
topics:
  injection: 1.0
  owasp: 0.95
  authentication: 0.9
  authorization: 0.9
  xss: 0.85
  csrf: 0.85
  input-validation: 0.8
  secrets: 0.7
  security: 0.6
```

**ember-oracle** (performance specialist):
```yaml
topics:
  n-plus-one: 1.0
  latency: 0.95
  performance: 0.9
  scalability: 0.85
  caching: 0.8
  memory: 0.75
  database: 0.7
  async: 0.6
  queries: 0.5
```

**rune-architect** (architecture specialist):
```yaml
topics:
  architecture: 1.0
  layers: 0.95
  boundaries: 0.9
  solid: 0.85
  dependencies: 0.8
  services: 0.7
  patterns: 0.6
  design: 0.5
```

**flaw-hunter** (edge case specialist):
```yaml
topics:
  race-conditions: 1.0
  edge-cases: 0.95
  null-handling: 0.9
  concurrency: 0.85
  error-handling: 0.8
  validation: 0.7
  boundaries: 0.6
```

**forge-keeper** (data integrity specialist):
```yaml
topics:
  migration: 1.0
  schema: 0.95
  transaction: 0.9
  integrity: 0.85
  reversibility: 0.8
  lock: 0.75
  cascade: 0.7
  referential: 0.65
  privacy: 0.6
  pii: 0.55
  audit: 0.5
  backfill: 0.45
```

Agents without weight overrides continue to use the flat list format in the topic registry tables above. The scoring algorithm auto-detects the format at runtime.

> **VEIL-004: Format detection edge cases** — The `isinstance(agent.topics, dict)` check covers the two canonical formats (list and dict). Edge cases to be aware of: (1) an empty dict `{}` is treated as dict format but scores 0.0 due to the `len(agent.topics) == 0` guard; (2) an empty list `[]` is treated as list format and also scores 0.0; (3) a `None`/missing value should be caught before reaching the scoring function (custom agent validation requires `trigger.topics` with at least 2 entries). If a non-standard type (e.g., tuple, string) reaches `score()`, it falls through to the `else` branch and is treated as a list, which is safe but may produce unexpected matches — custom agent validation should prevent this at load time.

> **DOC-004**: Weighted proficiency (dict format) was introduced in v1.80.0. The CHANGELOG entry should reference this file and the scoring algorithm changes. List format remains supported indefinitely — no deprecation planned.

#### Weighting Guidelines

Use this scale when assigning topic weights. Weight values must be floats in [0.0, 1.0].

| Weight Range | Meaning | Example |
|-------------|---------|---------|
| 1.0 | Core expertise — the agent's primary focus | injection for ward-sentinel |
| 0.8-0.9 | Strong proficiency — high confidence area | authorization for ward-sentinel |
| 0.5-0.7 | Moderate proficiency — competent but not primary | security (generic) for ward-sentinel |
| 0.3-0.4 | Peripheral — agent shouldn't be primary reviewer for this | logging for ward-sentinel |
| < 0.3 | Weak — omit entirely rather than including at low weight | — |

Topics below 0.3 should be omitted from the dict entirely. Including many low-weight topics dilutes `total_weight` and reduces the keyword_score ratio for genuinely strong matches.

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

> **SEC-004: Topic string safety** — Section titles and content are user-controlled input (from plan documents). The `extract_topics` function operates purely on string splitting and set membership — no eval, no regex compilation from user input, no shell interpolation. Topic strings from the agent registry are trusted (defined in this file or in validated talisman.yml custom agents). The `in` operator and `startswith` comparisons are safe against injection. However, custom agent topic strings from `talisman.yml` should be validated at load time to contain only lowercase alphanumeric characters and hyphens (enforced by custom agent validation).

### Scoring

> **VEIL-001: Why weighted scoring** — A binary match/no-match approach (agent selected if ANY topic overlaps) was considered but rejected because it produces too many false positives: agents with broad topic lists (e.g., pattern-seer with 13 topics) would match nearly every section, diluting enrichment quality. Weighted scoring with a threshold gate ensures agents are only selected when they have meaningful expertise overlap with the section's content, not just incidental keyword presence. The graduated weight system (0.3-1.0) further differentiates core expertise from peripheral competence.

For each plan section, score every agent in the topic registry:

```
score(section, agent, detected_stack=null):
  section_topics = extract_topics(section.title, section.content)

  # Division-by-zero guard: agents with no topics score 0.0
  if len(agent.topics) == 0:
    return 0.0

  # Keyword overlap — supports both list (legacy) and dict (weighted) formats.
  # Dict format: { "topic": weight, ... } where weight is 0.0-1.0
  # List format: ["topic", ...] treated as uniform weight 1.0
  if isinstance(agent.topics, dict):
    # BACK-004: Validate weights are numeric; default non-numeric to 1.0 with warning.
    # BACK-005: Clamp weights to minimum 0.01 to prevent division-by-zero or negative scores.
    validated_topics = {}
    for topic, weight in agent.topics.items():
      if not isinstance(weight, (int, float)):
        warn(f"Agent {agent.name}: topic '{topic}' has non-numeric weight '{weight}', defaulting to 1.0")
        weight = 1.0
      validated_topics[topic] = max(0.01, float(weight))

    matched_weight = sum(
      validated_topics[topic]
      for topic in validated_topics
      if topic in section_topics
         OR any(section_word.startswith(topic) for section_word in section_topics)
    )
    total_weight = sum(validated_topics.values())
    if total_weight == 0:
      return 0.0
    keyword_score = matched_weight / total_weight
  else:
    matches = count(topic for topic in agent.topics if topic in section_topics
                    OR any(section_word.startswith(topic) for section_word in section_topics))
    keyword_score = matches / len(agent.topics)

  # Title match bonus: top-3 topics by weight appearing in section title.
  # Sort by weight descending (dict) or use first 3 (list) to ensure
  # the most important topics drive the bonus — not declaration order.
  if isinstance(agent.topics, dict):
    top3 = [t for t, _ in sorted(agent.topics.items(), key=lambda x: x[1], reverse=True)[:3]]
  else:
    top3 = agent.topics[:3]
  title_bonus = 0.3 if any(topic in section.title.lower() for topic in top3) else 0.0

  # Exclusion penalty: demote agents when section contains topics the agent
  # explicitly should NOT handle. See exclusion_penalty() below.
  # BACK-007: Pass cached section_topics to avoid redundant extract_topics() call.
  excl_penalty = exclusion_penalty(section, agent, section_topics)

  # Stack affinity bonus (v1.86.0+): boost agents whose stack_affinities
  # match the detected project stack. Configurable via talisman forge.stack_affinity_bonus.
  # VEIL-005: Rationale — stack specialists (e.g., fastapi-reviewer) have narrow topic lists
  # that may score below threshold even when the project uses their stack. The affinity bonus
  # compensates for this by giving a small, fixed boost (default 0.05-0.2) that helps stack-
  # relevant agents cross the threshold without dominating topic-matched generalists.
  stack_bonus = 0.0
  if agent.stack_affinities AND detected_stack:
    stack_affinity_bonus = talisman.forge.stack_affinity_bonus ?? 0.2
    for affinity in agent.stack_affinities:
      if affinity in detected_stack.frameworks \
         OR affinity in detected_stack.libraries \
         OR affinity == detected_stack.primary_language:
        stack_bonus = stack_affinity_bonus
        break

  # DOC-003: Combined score formula breakdown:
  #   keyword_score  — [0.0, 1.0] ratio of matched topic weights to total weights
  #   title_bonus    — 0.0 or 0.3, awarded if top-3 topics appear in section title
  #   stack_bonus    — 0.0 or STACK_AFFINITY_BONUS, for stack-matching agents
  #   excl_penalty   — [-EXCLUSION_PENALTY_WEIGHT, 0.0], penalty for excluded topic hits
  # Result capped at 1.0 (title+stack can't inflate beyond max), floored at 0.0.
  return max(0.0, min(keyword_score + title_bonus + stack_bonus + excl_penalty, 1.0))
```

### Exclusion Penalty

Agents may declare an `excludes` list of topics they should NOT be matched against. When a section contains excluded topics, the agent's score is penalized:

```
exclusion_penalty(section, agent, section_topics=null):
  if not agent.excludes:
    return 0.0
  # BACK-007: Use cached section_topics when provided to avoid redundant extraction.
  if section_topics is null:
    section_topics = extract_topics(section.title, section.content)
  exclusion_hits = count(topic for topic in agent.excludes if topic in section_topics)
  if exclusion_hits > 0:
    # BACK-002: When EXCLUSION_PENALTY_WEIGHT is 0, the penalty formula yields 0.0,
    # meaning excluded agents are NOT penalized at all. To preserve exclusion semantics
    # even when penalty weight is zeroed out, return -Infinity (effectively removing
    # the agent from candidacy) when exclusion_hits > 0 AND EXCLUSION_PENALTY_WEIGHT == 0.
    if EXCLUSION_PENALTY_WEIGHT == 0:
      return -float('inf')  # Agent is hard-excluded (score floors at 0.0 in caller)
    return -EXCLUSION_PENALTY_WEIGHT * (exclusion_hits / len(agent.excludes))
  return 0.0
```

The penalty scales linearly with the fraction of excluded topics found, up to `EXCLUSION_PENALTY_WEIGHT` (default 0.5). Combined with the floor at 0.0 in `score()`, an agent can never receive a negative score.

> **VEIL-002: EXCLUSION_PENALTY_WEIGHT rationale** — The default 0.5 was chosen as a midpoint that demotes but does not eliminate agents with partial exclusion matches. At 0.5, an agent matching 100% of its excluded topics loses 0.5 from its score (typically enough to drop below the 0.30 threshold), while matching only 1 of 3 excluded topics loses ~0.17 (allowing the agent to remain if its keyword score is strong). This balances false negatives (agent excluded despite genuine expertise) against false positives (agent selected for an irrelevant section). The value is configurable via `talisman.forge.exclusion_penalty_weight` for projects that need stricter or more lenient exclusion behavior.

### MCP-First Topic Discovery (v1.170.0+)

When agent-search MCP is available, Forge Gaze can discover topic-specialized agents
beyond the hardcoded mapping:

```pseudocode
# After hardcoded topic→agent matching:
if mcp_available:
  for section in plan_sections:
    topic_candidates = agent_search({
      query: section.topic + " " + section.keywords,
      phase: "forge",
      limit: 3
    })
    for candidate in topic_candidates:
      if candidate.name not in forge_selections:
        forge_selections.add(candidate.name)

  # Write signal
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")
```

This enriches the existing static mapping with registry/user agents that specialize in
the plan's specific topics (e.g., a user-defined "django-forge-advisor" for Django plans).
Fallback: if MCP unavailable, the existing hardcoded mapping works unchanged.

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
      # BACK-009: Float precision — scores are computed as ratios of floats, which may
      # produce values like 0.29999... instead of 0.30. The >= comparison is intentional:
      # agents at exactly the threshold are included. For practical purposes, IEEE 754
      # double precision provides sufficient accuracy for this use case (weights are
      # specified to at most 2 decimal places). No epsilon comparison is needed.
      if s >= threshold:
        candidates.append((agent, s))

    # Sort by score descending, apply alphabetical tiebreaker for determinism
    candidates.sort(by=(score DESC, agent.name ASC))
    selected = candidates[:max_per_section]

    # BACK-001: Empty selection guard — if no agent passed the threshold,
    # fall back to the top-2 agents by score (regardless of threshold).
    # This prevents sections from receiving zero enrichment.
    if len(selected) == 0:
      all_agents_scored = [(agent, score(section, agent)) for agent in topic_registry
                           if not (agent.budget == "research" and not include_research)]
      all_agents_scored.sort(by=(score DESC, agent.name ASC))
      selected = all_agents_scored[:min(2, max_per_section)]

    # BACK-008: Enforce total agent cap — applies to both threshold-passing candidates
    # and BACK-001 fallback selections, ensuring MAX_TOTAL_AGENTS is never exceeded.
    if total_agents + len(selected) > MAX_TOTAL_AGENTS:
      selected = selected[:MAX_TOTAL_AGENTS - total_agents]

    total_agents += len(selected)
    assignments[section] = selected

    if total_agents >= MAX_TOTAL_AGENTS:
      break  # Budget exhausted

  # VEIL-007: Selection transparency — the orchestrator logs each agent's score,
  # whether it passed threshold, and why it was selected/excluded (threshold miss,
  # exclusion penalty, budget cap). This logging happens at the call site (Phase 3
  # of devise/forge), not inside forge_select itself. See Dry-Run Output for the
  # target format. Current implementation logs to console output transparently.
  return assignments
```

### Constants

| Constant | Default | Exhaustive | Description |
|----------|---------|------------|-------------|
| `THRESHOLD` | 0.30 | 0.15 | Minimum score to select an agent. Default 0.30 chosen to require at least ~30% topic overlap (e.g., 2 of 7 topics matching at weight 1.0). Exhaustive 0.15 lowers the bar to include peripheral matches. Both values are configurable via talisman |
| `MAX_PER_SECTION` | 3 | 5 | Maximum agents per plan section (see rationale below) |
| `MAX_TOTAL_AGENTS` | 8 | 12 | Hard cap across all sections |
| `MAX_FORGE_SAGES` | 6 | 6 | Max elicitation sages per forge session (not configurable via talisman) |
| `EXCLUSION_PENALTY_WEIGHT` | 0.5 | 0.5 | Maximum exclusion penalty applied when agent.excludes topics match section |
| `STACK_AFFINITY_BONUS` | 0.05 | 0.05 | Score bonus for agents whose stack affinities match the detected project stack. Overridable via `talisman.forge.stack_affinity_bonus` (default 0.2 in talisman, 0.05 built-in fallback) |

These can be overridden via `talisman.yml`:

```yaml
forge:
  threshold: 0.30                 # Range: 0.0-1.0
  max_per_section: 3              # Hard upper bound: 5
  max_total_agents: 8             # Hard upper bound: 15
  exclusion_penalty_weight: 0.5   # Range: 0.0-1.0
  stack_affinity_bonus: 0.05      # Range: 0.0-0.5 (default 0.05; scoring code uses 0.2 if talisman overrides)
```

**Validation bounds**: `threshold` must be between 0.0 and 1.0. `max_per_section` capped at 5. `max_total_agents` capped at 15. `exclusion_penalty_weight` must be between 0.0 and 1.0. Values exceeding bounds are clamped silently.

**DOC-005: Configuration examples**:
```yaml
# Minimal — accept defaults (recommended for most projects)
forge: {}

# Strict — fewer agents, higher quality bar
forge:
  threshold: 0.45
  max_per_section: 2
  max_total_agents: 6

# Broad — more agents, lower bar (useful for unfamiliar codebases)
forge:
  threshold: 0.20
  max_per_section: 4
  max_total_agents: 10
  stack_affinity_bonus: 0.15
```

> **VEIL-003: MAX_PER_SECTION rationale** — Default 3 / Exhaustive 5 were chosen based on context cost tradeoffs. Each forge agent consumes ~5k tokens (enrichment budget). At 3 agents/section with ~6 sections, the default ceiling is ~90k tokens — roughly 30% of a 300k context window, leaving room for the plan itself, elicitation sages, and lead coordination. Exhaustive mode's 5 agents/section (capped at 12 total) pushes to ~60k tokens for agent output alone, which is acceptable only when explicitly opted-in. Values of 2 or fewer risk missing cross-cutting concerns (e.g., security + performance overlap); values above 5 produce diminishing returns with significant context pressure, and agent perspectives begin to overlap.

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

> **QUAL-002**: Both modes intentionally share the same `forge_select` algorithm — they differ only in parameterization (threshold, caps, research inclusion). This is by design: a single code path reduces divergence risk and ensures that scoring semantics are identical regardless of mode. The mode parameter acts as a configuration selector, not a branch into different logic.

Same flow but with:
- Lower threshold (0.15 vs 0.30)
- Higher per-section cap (5 vs 3)
- Higher total cap (12 vs 8)
- Research-budget agents included
- Two-tier aggregation: per-section synthesizer → lead
- Cost warning displayed before summoning

## Custom Forge Agents

Custom Ashes from `talisman.yml` can participate in forge by adding `forge` to their `workflows` list and providing forge-specific config.

`trigger.topics` supports both **list format** (legacy, all weights 1.0) and **dict format** (weighted). The scoring algorithm auto-detects the format.

**List format** (legacy — uniform weights):
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

**Dict format** (weighted — graduated expertise):
```yaml
ashes:
  custom:
    - name: "api-contract-reviewer"
      agent: "api-contract-reviewer"
      source: local
      workflows: [review, audit, forge]
      trigger:
        extensions: [".py", ".ts"]
        topics:                            # Weighted dict format
          api: 1.0
          contract: 0.9
          endpoints: 0.8
          rest: 0.7
          graphql: 0.6
      forge:
        subsection: "API Contract Analysis"
        perspective: "API design, contract compatibility, and endpoint patterns"
        budget: enrichment
      context_budget: 15
      finding_prefix: "API"
```

When using dict format, weights must be floats in [0.0, 1.0]. Topics should be listed in descending weight order (highest first) to ensure correct `title_bonus` derivation.

> **Migration note**: Existing custom Ashes using list format (`topics: [api, contract, ...]`) continue to work unchanged. To adopt weighted scoring, replace the list with a dict (`topics: {api: 1.0, contract: 0.9, ...}`). No migration step is required -- both formats are valid indefinitely.

### Custom Agent Validation

If `forge` is in `workflows`, these fields are **required**:
- `trigger.topics` — at least 2 topics (list or dict format)
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
Agents available: 33 built-in (21 review + 2 research + 3 utility + 7 stack specialist) + custom
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

## Acceptance Criteria Generation

When a plan section lacks explicit acceptance criteria, forge agents MUST generate them as part of enrichment output. This ensures every enriched section has testable, verifiable conditions before implementation begins.

### Detection

A plan section is considered **criteria-absent** if it contains none of the following markers:
- `acceptance criteria` or `acceptance_criteria` (case-insensitive)
- `✓`, `- [ ]`, or `## Acceptance` heading
- A `**Done when**`, `**Definition of Done**`, or `**Verified by**` block

### Generation Instruction

When a forge agent's enrichment output targets a criteria-absent section, it MUST append an `## Acceptance Criteria` subsection following its perspective-specific analysis:

```markdown
## Acceptance Criteria

<!-- Generated by forge: {agent-name} — section lacked explicit criteria -->
- [ ] {criterion 1 — specific, measurable, tied to a plan requirement}
- [ ] {criterion 2 — …}
- [ ] {criterion N — …}
```

Criteria must be:
- **Specific** — tied to an explicit requirement or behavior in the section
- **Verifiable** — expressible as a pass/fail test or observable outcome
- **Scoped** — no broader than the section's stated purpose
- **Non-redundant** — do not repeat criteria already present in the plan

The forge agent generating criteria should use its perspective to inform criterion design:
- `ward-sentinel` → criteria focus on security invariants (e.g., "All inputs validated before processing")
- `ember-oracle` → criteria focus on performance thresholds (e.g., "p99 latency < 200ms under target load")
- `trial-oracle` → criteria focus on test coverage (e.g., "≥80% line coverage for new code paths")
- `flaw-hunter` → criteria focus on edge case handling (e.g., "Empty input returns empty collection, not null")

### Proof Type Mapping

Each generated criterion should reference an appropriate proof type from the proof schema. Proof types determine how the criterion can be verified during gap analysis and pre-ship validation.

See [proof-schema.md](../../discipline/references/proof-schema.md) for the full list of available proof types: `file_exists`, `pattern_matches`, `no_pattern_exists`, `test_passes`, `builds_clean`, `git_diff_contains`, `line_count_delta`, `semantic_match`.

Annotate each criterion with its proof type in a comment when the type is non-obvious:

```markdown
- [ ] All SQL queries use parameterized statements <!-- proof: pattern_matches -->
- [ ] Endpoint returns 429 after 100 req/min per IP <!-- proof: test_passes -->
```

### Budget Note

Criteria generation is additive — it does NOT replace the forge agent's primary enrichment output (the perspective-specific subsection). It runs as a second pass within the same agent turn, only when the section is criteria-absent. Agents operating under a strict context budget (e.g., `context_budget: 10`) should generate a minimum of 2 criteria rather than omitting the section entirely.

## References

- [Rune Gaze](rune-gaze.md) — File extension → Ash matching (analogous system for reviews)
- [Circle Registry](circle-registry.md) — Agent-to-Ash mapping
- [Smart Selection](smart-selection.md) — File assignment and budget enforcement
- [Custom Ash](custom-ashes.md) — Custom agent schema (extended for forge)
- [Proof Schema](../../discipline/references/proof-schema.md) — Available proof types for criterion verification
