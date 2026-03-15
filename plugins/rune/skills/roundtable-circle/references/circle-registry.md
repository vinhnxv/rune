# Circle Registry — Agent-to-Ash Mapping

> Maps review agent perspectives to Ash roles, with scope assignments and wave scheduling for the Parameterized Roundtable Circle.

## Agent Registry

Each review agent is embedded as a "perspective" inside an Ash. This registry defines which perspectives belong to which Ash, what file scopes they target, and which wave they execute in.

> **Architecture note:** Forge Warden, Ward Sentinel, Pattern Weaver, and Veil Piercer embed dedicated review agent files from `agents/review/` (21 agents across 4 Ashes). Glyph Scribe, Knowledge Keeper, and Codex Oracle use **inline perspective definitions** in their Ash prompts rather than dedicated agent files.

### Wave & Depth Fields

Each Ash entry carries two scheduling fields used by [wave-scheduling.md](wave-scheduling.md):

| Field | Type | Description |
|-------|------|-------------|
| `wave` | number (1-3) | Execution wave. Wave 1 runs first, Wave 2 after Wave 1 completes, etc. |
| `deepOnly` | boolean | If `true`, this Ash only runs in `depth=deep` mode. Standard depth skips it. |

### Forge Warden (Backend)

**Wave:** 1 | **Deep only:** false

| Agent | Perspective | Scope Priority |
|-------|-------------|---------------|
| rune-architect | Architecture compliance | Entry points > services > core modules |
| ember-oracle | Performance bottlenecks | Database queries > API handlers > utils |
| flaw-hunter | Logic bugs, edge cases | Business logic > data transformations |
| mimic-detector | Code duplication | Largest files first (highest risk) |
| type-warden | Type safety, language idioms | All backend source files |
| depth-seer | Missing logic, complexity | Services > handlers > core modules |
| blight-seer | Design anti-patterns, architectural smells | Entry points > services > core modules |
| forge-keeper | Data integrity, migration safety, lock analysis | Migration files > model files > transaction code |

**Audit file priority:** entry points > core modules > services > utils > tests
**Context budget:** max 30 files

### Ward Sentinel (Security)

**Wave:** 1 | **Deep only:** false

| Agent | Perspective | Scope Priority |
|-------|-------------|---------------|
| ward-sentinel | Vulnerabilities, OWASP | Auth files > API routes > infrastructure |

**Audit file priority:** auth/security > API routes > configuration > infrastructure > other
**Context budget:** max 20 files (all file types)

### Pattern Weaver (Quality)

**Wave:** 1 | **Deep only:** false

| Agent | Perspective | Scope Priority |
|-------|-------------|---------------|
| simplicity-warden | YAGNI, over-engineering | Largest/most complex files first |
| pattern-seer | Naming, conventions | All files by size descending |
| wraith-finder | Dead code, unwired code, DI wiring, orphaned routes/handlers | All files by size descending |
| phantom-checker | Dynamic references | Entry points > configuration |
| void-analyzer | Incomplete implementations | All files (look for TODOs, stubs) |
| trial-oracle | TDD compliance, test quality | Test files > source files |
| tide-watcher | Async/concurrency patterns, race conditions | Async code > event handlers > frontend |
| refactor-guardian | Refactoring completeness, orphaned callers, extraction verification | Changed files with R/D/A git status |
| reference-validator | Import paths, config refs, frontmatter, version sync | All changed files + config files |

**Audit file priority:** largest files first (highest complexity risk)
**Context budget:** max 30 files (all file types)

### Glyph Scribe (Frontend)

**Wave:** 1 | **Deep only:** false

> **Inline perspectives** — Glyph Scribe does not use dedicated agent files. Its perspectives are defined inline within the Ash prompt.

| Perspective (inline) | Focus | Scope Priority |
|----------------------|-------|---------------|
| TypeScript safety | Type guards, generics | Pages/routes > components |
| React performance | Re-renders, bundle size | Pages/routes > components > hooks |
| Accessibility | ARIA, keyboard navigation | Components > pages |

**Audit file priority:** pages/routes > components > hooks > utils
**Context budget:** max 25 files

### Knowledge Keeper (Documentation)

**Wave:** 1 | **Deep only:** false

> **Inline perspectives** — Knowledge Keeper does not use dedicated agent files. Its perspectives are defined inline within the Ash prompt.

| Perspective (inline) | Focus | Scope Priority |
|----------------------|-------|---------------|
| Accuracy | Technical correctness | README > CLAUDE.md > API docs |
| Completeness | Coverage, missing sections | docs/ > root .md files |
| Consistency | Cross-reference accuracy | All docs cross-checked |
| Readability | Clear, scannable documentation | All .md files |
| Security | Prompt injection in docs | .claude/**/*.md > other docs |

**Audit file priority:** README > CLAUDE.md > docs/ > other .md files
**Context budget:** max 25 files

### Codex Oracle (Cross-Model)

**Wave:** 1 | **Deep only:** false

> **External CLI** — Codex Oracle invokes `codex exec` via Bash, unlike other Ashes which use Claude Code tools directly. Auto-detected, conditionally summoned. Uses **inline perspective definitions** (like Glyph Scribe and Knowledge Keeper).

| Perspective (inline) | Focus | Scope Priority |
|----------------------|-------|---------------|
| Cross-model security | Issues that Claude Ashes might miss | Auth files > API routes > infrastructure |
| Cross-model logic | Edge cases, concurrency, error handling | Business logic > data transformations |
| Cross-model quality | Duplication, API design, validation gaps | All file types |

**Activation:** `command -v codex` returns 0 AND `talisman.codex.disabled` is not true
**Audit file priority:** new files > modified files > high-risk files > other
**Context budget:** max 20 files (configurable via talisman)
**Finding prefix:** `CDX`

### Veil Piercer (Truth-Telling)

**Wave:** 1 | **Deep only:** false

| Agent | Perspective | Scope Priority |
|-------|-------------|---------------|
| reality-arbiter | Production viability, integration honesty | Entry points > services > new files |
| assumption-slayer | Premise validation, cargo cult detection | Architecture files > config > domain logic |
| entropy-prophet | Long-term consequences, hidden costs | Dependencies > abstractions > infrastructure |

**Audit file priority:** entry points > new files > services > abstractions > infrastructure
**Context budget:** max 30 files (all file types)

### Stack Specialist Ashes (v1.86.0+)

> Stack specialist Ashes are conditionally summoned based on detected project stack. They run alongside Wave 1 Ashes when their activation condition is met. See `skills/stacks/references/detection.md` for detection logic.
>
> **Prompt templates**: Stack specialist reviewer prompts are stored in `specialist-prompts/` (not registered as Claude Code agents). They are loaded on-demand by `buildAshPrompt()` via filesystem-derived dispatch — no hardcoded list to maintain.

| Ash | Prompt Template | Activation Condition | Prefix | Context Budget |
|-----|----------------|---------------------|--------|---------------|
| python-reviewer | `specialist-prompts/python-reviewer.md` | `detected_stack.primary_language == 'python'` | PY | 25 files |
| fastapi-reviewer | `specialist-prompts/fastapi-reviewer.md` | `detected_stack.frameworks.includes('fastapi')` | FAPI | 20 files |
| django-reviewer | `specialist-prompts/django-reviewer.md` | `detected_stack.frameworks.includes('django')` | DJG | 20 files |
| laravel-reviewer | `specialist-prompts/laravel-reviewer.md` | `detected_stack.frameworks.includes('laravel')` | LARV | 20 files |
| sqlalchemy-reviewer | `specialist-prompts/sqlalchemy-reviewer.md` | `detected_stack.frameworks.includes('sqlalchemy')` | SQLA | 20 files |
| tdd-compliance-reviewer | `specialist-prompts/tdd-compliance-reviewer.md` | Test files in diff | TDD | 25 files |

**Cap**: `max_stack_ashes` (default: 3) from `talisman.stack_awareness.max_stack_ashes`.

> **design-implementation-reviewer** is NOT a stack-specialist Ash. It is activated via the **Phase 1.6 Design Fidelity gate** in `appraise/references/phase-1-rune-gaze.md`, gated by `talisman.design_review.enabled`. It uses finding prefix `DES`. This placement avoids duplicate activation that would otherwise occur if it were listed as both a stack-specialist and a Phase 1.6 reviewer.

### Shard Reviewers (Inscription Sharding, v1.98.0+)

**Wave:** N/A — parallel, no wave scheduling | **Deep only:** false (exclusive to standard depth)

> Active only when `inscription.sharding.enabled === true`.
> Shard Reviewers replace standard specialist Ash selection for `scope=diff` + large diffs.
> They are NOT used in `scope=full` audit or `depth=deep` mode.

| Agent | Prefix | Scope |
|-------|--------|-------|
| Shard Reviewer A | `SHA-` | Files in shard A (domain-affinity group) |
| Shard Reviewer B | `SHB-` | Files in shard B |
| Shard Reviewer C | `SHC-` | Files in shard C |
| Shard Reviewer D | `SHD-` | Files in shard D |
| Shard Reviewer E | `SHE-` | Files in shard E (MAX_SHARDS = 5) |
| Cross-Shard Sentinel | `XSH-` | Reads only shard summary JSONs (no source files) |

**Model policy:** `auto` = sonnet for security/code shards, haiku for docs-only shards.
**Context budget:** SHARD_SIZE files per reviewer (default 12, configurable via talisman).
**Finding format:** Uses standard RUNE:FINDING markers with `shard="{shard_id}"` attribute.
**Prompt template:** [shard-reviewer.md](../../../prompts/ash/shard-reviewer.md)
**Allocator:** [shard-allocator.md](shard-allocator.md)

> **SHA- prefix note:** `SHA-001` finding IDs will not collide with `SHA-256` algorithm
> references in code comments — RUNE:FINDING HTML markers are the structural dedup anchor,
> not the prefix string alone. Plain-text `SHA-256` references in code have no markers.

## Audit Scope Assignment

During `/rune:audit`, each Ash receives a file list capped by its context budget. Files are assigned using the priority order above.

```
for each selected Ash:
  1. Collect all files matching its extension group (from Rune Gaze)
  2. Sort by scope priority (defined above)
  3. Cap at context budget
  4. Files beyond budget are listed in TOME.md "Coverage Gaps" section
```

### Cross-Ash File Sharing

Some files may be reviewed by multiple Ash:

| File Type | Reviewed By |
|-----------|------------|
| `.claude/**/*.md` | Ward Sentinel + Knowledge Keeper |
| `Dockerfile` | Ward Sentinel + Forge Warden |
| CI/CD configs | Ward Sentinel + Pattern Weaver |
| Test files | Pattern Weaver + Forge Warden |
| ALL files (when codex available) | Codex Oracle (cross-model perspective) |
| ALL files | Veil Piercer (truth-telling perspective) |

This is intentional — different perspectives catch different issues.

## Focus Mode (`--focus`)

When `/rune:audit --focus <area>` is used, only summon the relevant Ash(s):

| Focus Area | Ash Summoned |
|-----------|-------------------|
| `security` | Ward Sentinel only |
| `performance` | Forge Warden only |
| `quality` | Pattern Weaver only |
| `frontend` | Glyph Scribe only |
| `docs` | Knowledge Keeper only |
| `backend` | Forge Warden + Ward Sentinel |
| `cross-model` | Codex Oracle only |
| `truth` | Veil Piercer only |
| `full` | All (default) |

Focus mode increases context budget per Ash since fewer are competing for resources.

### CLI-Backed Ashes (External Model, v1.57.0+)

> **External CLI** — CLI-backed Ashes invoke external model CLIs (e.g., `gemini`, `llama`) via Bash,
> similar to Codex Oracle. Defined in `ashes.custom[]` with `cli:` field. Auto-detected via
> `detectExternalModel()`, conditionally summoned. Uses the parameterized
> [external-model-template.md](../../../prompts/ash/external-model-template.md) prompt.

| Aspect | Description |
|--------|-------------|
| **Activation** | `detectExternalModel()` succeeds AND workflow matches config |
| **Sub-cap** | `max_cli_ashes` (default: 2) — separate from Codex Oracle gate |
| **Context budget** | From `ashes.custom[].context_budget` (configurable per entry) |
| **Finding prefix** | From `ashes.custom[].finding_prefix` (2-5 uppercase chars) |
| **Dedup position** | Below CDX in default hierarchy; built-in prefixes always precede |
| **Prompt template** | `prompts/ash/external-model-template.md` (parameterized) |

**Example entry (from talisman.yml):**
```yaml
- name: "gemini-oracle"
  cli: "gemini"
  model: "gemini-2.5-pro"
  output_format: "json"
  finding_prefix: "GEM"
  timeout: 300
  workflows: [review, audit]
  trigger: { always: true }
  context_budget: 20
```

**Registry pattern:** Each CLI-backed Ash appears in the Circle as a named Ash with its own finding prefix, prompt wrapper, and Seal. It participates in standard dedup, TOME aggregation, and Truthsight verification — identical lifecycle to agent-backed custom Ashes.

### Deep Investigation Ashes (Wave 2, deepOnly)

**Wave:** 2 | **Deep only:** true

> Deep investigation Ashes run in Wave 2 of `depth=deep` reviews/audits. They receive Wave 1 findings as additional context and focus on specialized investigation areas. In standard depth, these Ashes are skipped entirely.

| Ash | Agent | Prefix | Focus | Context Budget |
|-----|-------|--------|-------|---------------|
| rot-seeker | rot-seeker | DEBT | Tech debt, complexity, deprecated patterns | 30 files |
| strand-tracer | strand-tracer | INTG | Integration gaps, dead routes, unwired DI | 30 files |
| decree-auditor | decree-auditor | BIZL | Business rules, state machines, validation | 25 files |
| fringe-watcher | fringe-watcher | EDGE | Boundary checks, null handling, race conditions | 25 files |

**Audit file priority:** Investigation-specific (see Deep Gaze section)
**Activation:** `depth=deep` (via `--deep` flag or `audit.always_deep: true` in talisman.yml)

### Deep Dimension Ashes (Wave 3, deepOnly)

**Wave:** 3 | **Deep only:** true

> Deep dimension Ashes run in Wave 3 of `depth=deep` reviews/audits. They analyze code through specialized dimension lenses, receiving findings from both Wave 1 and Wave 2 as context.
>
> **Merge rule:** If fewer than 3 dimension agents are selected, Wave 3 merges into Wave 2 (see [wave-scheduling.md](wave-scheduling.md) `mergeSmallWaves`).

| Ash | Agent | Prefix | Focus | Context Budget |
|-----|-------|--------|-------|---------------|
| truth-seeker | truth-seeker | CORR | Correctness: logic vs requirements, behavior validation, test quality | 30 files |
| ruin-watcher | ruin-watcher | FAIL | Failure modes: resilience, retry, crash recovery, circuit breakers | 30 files |
| breach-hunter | breach-hunter | DSEC | Security-deep: threat modeling, auth boundaries, data exposure | 25 files |
| order-auditor | order-auditor | DSGN | Design: responsibility separation, dependency direction, coupling | 30 files |
| ember-seer | ember-seer | RSRC | Performance-deep: resource lifecycle, memory, blocking, pool management | 25 files |
| signal-watcher | signal-watcher | OBSV | Observability: logging context, metrics, traces, error classification | 25 files |
| decay-tracer | decay-tracer | MTNB | Maintainability: naming intent, complexity hotspots, convention drift | 25 files |

## Wave Summary

Quick reference for wave assignments across all Ashes. See [wave-scheduling.md](wave-scheduling.md) for the scheduling algorithm.

| Ash | Wave | Deep Only | Prefix | Conditional |
|-----|------|-----------|--------|-------------|
| Forge Warden | 1 | false | BACK | Yes (backend files) |
| Ward Sentinel | 1 | false | SEC | No (always) |
| Pattern Weaver | 1 | false | QUAL | No (always) |
| Veil Piercer | 1 | false | VEIL | No (always) |
| Glyph Scribe | 1 | false | FRONT | Yes (frontend files) |
| Knowledge Keeper | 1 | false | DOC | Yes (docs >= 10 lines) |
| Codex Oracle | 1 | false | CDX | Yes (codex CLI available) |
| design-implementation-reviewer | 1 | false | DES | Yes (design_review.enabled + design_sync.enabled + frontend files) |
| rot-seeker | 2 | true | DEBT | No (all deep) |
| strand-tracer | 2 | true | INTG | No (all deep) |
| decree-auditor | 2 | true | BIZL | No (all deep) |
| fringe-watcher | 2 | true | EDGE | No (all deep) |
| truth-seeker | 3 | true | CORR | No (all deep) |
| ruin-watcher | 3 | true | FAIL | No (all deep) |
| breach-hunter | 3 | true | DSEC | No (all deep) |
| order-auditor | 3 | true | DSGN | No (all deep) |
| ember-seer | 3 | true | RSRC | No (all deep) |
| signal-watcher | 3 | true | OBSV | No (all deep) |
| decay-tracer | 3 | true | MTNB | No (all deep) |

## Weighted Topic Propagation

When an agent's forge topics use weighted format (dict with float values), the weights propagate to Forge Gaze scoring. The scoring algorithm auto-detects whether `agent.topics` is a list (legacy, uniform weight 1.0) or dict (graduated weights) at runtime — see [forge-gaze.md](forge-gaze.md#scoring) for the full algorithm.

### Data Flow: Circle Registry to Forge Gaze Scoring

The weighted topic proficiency data flows through a three-stage pipeline:

1. **Circle Registry defines agent topic weights** — Each agent in this registry declares its topics as either a flat list (uniform weight 1.0) or a dict with float weights in [0.0, 1.0]. Weight overrides are declared in [forge-gaze.md Weight Overrides](forge-gaze.md#weight-overrides), using a graduated scale from 1.0 (core expertise) down to 0.3 (peripheral). Topics below 0.3 are omitted entirely.

2. **Forge Gaze reads these weights at scoring time** — During plan enrichment (`/rune:devise`, `/rune:forge`), the [Forge Gaze scoring algorithm](forge-gaze.md#scoring) iterates over each plan section and scores every registered agent. For dict-format topics, it computes `matched_weight / total_weight` (weighted keyword overlap). For list-format topics, it computes `matches / len(topics)` (uniform overlap). The format is auto-detected at runtime — no migration is required.

3. **Weights influence agent selection, not review orchestration** — The `keyword_score` feeds into the final score alongside `title_bonus` (top-3 topics by weight appearing in the section title), `exclusion_penalty`, and `stack_affinity_bonus`. Agents exceeding the selection threshold are assigned to enrich that plan section. Wave scheduling, context budgets, and Ash-level orchestration are unaffected — weights only influence the Forge Gaze selection step.

Composite Ashes (which embed multiple review agent perspectives) inherit the topic format of their constituent agents. Each agent within a composite is scored independently against plan sections. The Ash-level context budget and wave scheduling are unaffected by topic weighting — weights only influence the Forge Gaze selection step.

Custom Ashes defined in `talisman.yml` follow the same rules: `trigger.topics` accepts both list and dict format. See [forge-gaze.md](forge-gaze.md#custom-forge-agents) for examples of both formats.

## References

- [Wave Scheduling](wave-scheduling.md) — Wave selection, merge logic, timeout distribution
- [Smart Selection](smart-selection.md) — File-to-Ash assignment, context budgets
- [Rune Gaze](rune-gaze.md) — Extension classification rules
- [Forge Gaze](forge-gaze.md) — Topic-aware agent selection for plan enrichment
