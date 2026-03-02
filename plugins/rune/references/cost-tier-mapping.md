# Cost Tier Agent Model Mapping

Centralized reference for the `cost_tier` system that controls which Claude model each agent category uses when spawned. One switch, four profiles — from maximum quality to maximum savings.

## Tier Definitions

| Tier | Philosophy | Est. Cost vs All-Opus |
|------|-----------|----------------------|
| **`opus`** | Maximum quality — all agents on strongest model | 100% |
| **`balanced`** | Strategic mix — truth-tellers on Opus, others on Sonnet/Haiku (default) | ~35-40% |
| **`efficient`** | Save money — Sonnet primary, Haiku for mechanical tasks | ~20-25% |
| **`minimal`** | Maximum savings — Haiku for most, Sonnet for reasoning-heavy | ~15-20% |

## 8 Agent Categories

| # | Category | Description | Rationale |
|---|----------|-------------|-----------|
| 1 | **Truth-tellers** | Senior judgment, arbitration, adversarial challenge | Need strongest reasoning for high-stakes decisions |
| 2 | **Deep analysis** | Investigation, root cause, cross-cutting reasoning | Complex multi-file analysis benefits from stronger models |
| 3 | **Standard review** | Single-dimension review, pattern matching | Well-scoped tasks that Sonnet handles well |
| 4 | **Code workers** | Implementation, test generation, finding fixes | Code generation needs good reasoning but not maximal |
| 5 | **Research** | Grep/read/search/extract operations | Read-only operations, Haiku sufficient for efficient tier |
| 6 | **Tracers** | Follow references, extract structured data | Mechanical traversal, Haiku sufficient |
| 7 | **Utility** | Aggregation, validation, orchestration helpers | Format-focused, Haiku sufficient for efficient tier |
| 8 | **Testing** | Test execution and failure analysis | Execution needs reliability |

## Category-to-Tier Model Map

| Category | opus | balanced | efficient | minimal |
|----------|------|----------|-----------|---------|
| Truth-tellers | opus | opus | sonnet | sonnet |
| Deep analysis | opus | sonnet | sonnet | sonnet |
| Standard review | opus | sonnet | sonnet | haiku |
| Code workers¹ | opus | sonnet | sonnet | sonnet |
| Research | sonnet | sonnet | haiku | haiku |
| Tracers | sonnet | haiku | haiku | haiku |
| Utility | sonnet | sonnet | haiku | haiku |
| Testing | sonnet | sonnet | sonnet | haiku |

**Exception:** `test-failure-analyst` uses opus/opus/sonnet/sonnet (needs deep reasoning for failure root cause analysis). This exception is handled inline in `resolveModelForAgent()` before the category lookup — it is NOT reflected in `CATEGORY_TIER_MAP`.

¹ Code workers and deep-analysis currently map to identical tiers. They are separated as distinct categories for future tier differentiation (e.g., giving code workers haiku on minimal tier while keeping deep-analysis on sonnet).

## Agent-to-Category Assignment

### Truth-tellers (10)

`senior-engineer-reviewer`, `assumption-slayer`, `reality-arbiter`, `entropy-prophet`, `decree-arbiter`, `horizon-sage`, `veil-piercer-plan`, `goldmask-coordinator`, `wisdom-sage`, `doubt-seer`

### Deep analysis (19)

`breach-hunter`, `truth-seeker`, `fringe-watcher`, `ruin-watcher`, `ruin-prophet`, `grace-warden`, `sight-oracle`, `vigil-keeper`, `ember-seer`, `decay-tracer`, `rot-seeker`, `signal-watcher`, `order-auditor`, `decree-auditor`, `strand-tracer`, `depth-seer`, `blight-seer`, `rune-architect`, `hypothesis-investigator`

### Standard review (32)

`flaw-hunter`, `void-analyzer`, `wraith-finder`, `mimic-detector`, `pattern-seer`, `tide-watcher`, `trial-oracle`, `type-warden`, `forge-keeper`, `ember-oracle`, `schema-drift-detector`, `phantom-checker`, `refactor-guardian`, `reference-validator`, `naming-intent-analyzer`, `simplicity-warden`, `agent-parity-reviewer`, `tdd-compliance-reviewer`, `ward-sentinel`, `python-reviewer`, `typescript-reviewer`, `rust-reviewer`, `php-reviewer`, `fastapi-reviewer`, `django-reviewer`, `laravel-reviewer`, `sqlalchemy-reviewer`, `ddd-reviewer`, `di-reviewer`, `cross-shard-sentinel`, `design-implementation-reviewer`, `axum-reviewer`

### Code workers (5)

`rune-smith`, `trial-forger`, `mend-fixer`, `design-sync-agent`, `design-iterator`

### Research (5)

`repo-surveyor`, `lore-scholar`, `practice-seeker`, `echo-reader`, `git-miner`

### Tracers (6)

`api-contract-tracer`, `business-logic-tracer`, `config-dependency-tracer`, `data-layer-tracer`, `event-message-tracer`, `lore-analyst`

### Utility (10)

`runebinder`, `scroll-reviewer`, `knowledge-keeper`, `flow-seer`, `elicitation-sage`, `deployment-verifier`, `truthseer-validator`, `evidence-verifier`, `research-verifier`, `state-weaver`

### Testing (4)

`unit-test-runner`, `integration-test-runner`, `e2e-browser-tester`, `test-failure-analyst` (exception: see above)

## resolveModelForAgent()

**Inputs**: `agentName` (string — agent name from Agent call), `talisman` (object — parsed talisman.yml)
**Outputs**: `model` (string — "opus" | "sonnet" | "haiku")
**Preconditions**: `talisman` loaded via `readTalisman()`, `COST_TIER_TABLE` populated from this file
**Error handling**: Unknown agent → return tier default. Invalid tier value → fallback to "balanced".

```javascript
function resolveModelForAgent(agentName, talisman) {
  const tier = talisman?.cost_tier ?? "balanced"
  const validTiers = ["opus", "balanced", "efficient", "minimal"]
  const effectiveTier = validTiers.includes(tier) ? tier : "balanced"

  // Exception: test-failure-analyst always gets elevated model
  if (agentName === "test-failure-analyst") {
    return { opus: "opus", balanced: "opus", efficient: "sonnet", minimal: "sonnet" }[effectiveTier]
  }

  // Lookup from COST_TIER_TABLE (keyed by agent name → category)
  const category = AGENT_CATEGORY_MAP[agentName]
  if (!category) return TIER_DEFAULTS[effectiveTier]
  const model = CATEGORY_TIER_MAP[category][effectiveTier]
  // Output validation: guard against data corruption in CATEGORY_TIER_MAP
  const VALID_MODELS = new Set(["opus", "sonnet", "haiku"])
  return VALID_MODELS.has(model) ? model : TIER_DEFAULTS[effectiveTier]
}

const TIER_DEFAULTS = {
  opus: "opus",
  balanced: "sonnet",
  efficient: "sonnet",
  minimal: "sonnet"
}

const CATEGORY_TIER_MAP = {
  "truth-tellers":   { opus: "opus",   balanced: "opus",   efficient: "sonnet", minimal: "sonnet" },
  "deep-analysis":   { opus: "opus",   balanced: "sonnet", efficient: "sonnet", minimal: "sonnet" },
  "standard-review": { opus: "opus",   balanced: "sonnet", efficient: "sonnet", minimal: "haiku"  },
  "code-workers":    { opus: "opus",   balanced: "sonnet", efficient: "sonnet", minimal: "sonnet" },
  "research":        { opus: "sonnet", balanced: "sonnet", efficient: "haiku",  minimal: "haiku"  },
  "tracers":         { opus: "sonnet", balanced: "haiku",  efficient: "haiku",  minimal: "haiku"  },
  "utility":         { opus: "sonnet", balanced: "sonnet", efficient: "haiku",  minimal: "haiku"  },
  "testing":         { opus: "sonnet", balanced: "sonnet", efficient: "sonnet", minimal: "haiku"  }
}
```

## Notes

- **Custom Ashes** defined by users are NOT affected by `cost_tier` — they may use non-Claude models
- **Codex Oracle** has its own `codex.model` config path — NOT affected
- **Main session model** is controlled by Claude Code settings — NOT affected
- **Agent frontmatter `model:`** becomes the fallback when `cost_tier` is not set in talisman
- Unknown agents (e.g., future agents not yet categorized) fall back to `TIER_DEFAULTS`
- **Tracers vs Research asymmetry**: Tracers get haiku on `balanced` tier while research gets sonnet — tracers perform mechanical reference traversal (follow imports, extract structured data) while research agents need reasoning to interpret search results and synthesize findings
- **Pseudocode nature**: `resolveModelForAgent()` above is reference pseudocode — actual callers pass the resolved model string as the `model:` parameter in their Task spawn call. See individual skill SKILL.md files for call sites
