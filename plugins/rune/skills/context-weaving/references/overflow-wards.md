# Overflow Wards

> Detailed pre-summon protocol and Glyph Budget enforcement for multi-agent workflows.

## Glyph Budget Injection Text

**Copy-paste this into EVERY agent prompt** when summoning in a multi-agent workflow:

```
GLYPH BUDGET PROTOCOL:
- Write ALL detailed findings to: {output-directory}/{agent-name}.md
- Return to caller ONLY: the output file path + 1-sentence summary (max 50 words)
- DO NOT include full analysis, code examples, or detailed recommendations in return message

Example return:
"Findings written to {output-directory}/{agent-name}.md. Found 2 P1 issues (SQL injection in queries, missing auth check) and 4 P2 issues across 3 files."
```

## How to Inject

When calling the Agent tool, append the protocol to the prompt:

```
Agent({
  name: "ward-sentinel-1",
  team_name: teamName,
  subagent_type: "rune:review:ward-sentinel",
  prompt: `[Your actual review/analysis prompt here]

GLYPH BUDGET PROTOCOL:
- Write ALL detailed findings to: tmp/reviews/142/ward-sentinel.md
- Return to caller ONLY: the output file path + 1-sentence summary (max 50 words)
- DO NOT include full analysis in return message`
})
```

This works for ALL agent types because it's part of the prompt, not the agent definition.

## Token Impact

| Scenario | Tokens per agent return | 10 agents total |
|----------|------------------------|-----------------|
| Without Glyph Budget | 3,000-5,000 | 30,000-50,000 |
| With Glyph Budget | 100-200 | 1,000-2,000 |
| **Savings** | **2,800-4,800** | **28,000-48,000** |

With a finite context window and ~30k base context, Glyph Budget is the difference between fitting 10 agents comfortably and overflowing at 7.

## Runebinder Invocation

After all agents complete, use the Runebinder to process raw files:

### When to Aggregate

| Raw files | Action |
|-----------|--------|
| 1-3 files | Read directly (aggregator adds overhead) |
| 4+ files | Summon Runebinder agent |
| 10+ files | MUST summon Runebinder (never read all directly) |

### How to Invoke

```
Agent({
  name: "runebinder",
  team_name: teamName,
  subagent_type: "rune:utility:runebinder",
  prompt: `Read all findings from {output-directory}/
Write TOME.md with deduplicated, prioritized findings.
Skip non-findings files: TOME.md, truthsight-report.md`
})
```

### After Aggregation

Read ONLY the TOME.md file. Do NOT also read raw files (that defeats the purpose).

**Runebinder Input Management:**
1. Phase 5.0 pre-aggregation (automatic when combined size > threshold)
2. Condensed files reduce input by 40-60%
3. Fallback: If Runebinder still fails, read raw files ONE AT A TIME

## MCP Schema Cost Per Teammate

Every MCP server connected to a teammate injects its tool schemas into that teammate's context window at spawn time. This cost is **per teammate** — 5 teammates with Playwright connected = 5x the schema overhead.

### Estimated Schema Costs

| MCP Server | Approx. Tokens | Notes |
|------------|---------------|-------|
| Context7 | ~500 | 2 tools, lightweight schemas |
| Playwright | ~3,000 | 20+ tools, complex parameter schemas |
| Memory | ~1,500 | CRUD operations with metadata |
| Slack | ~2,000 | Message, channel, user operations |
| Custom (typical) | ~500-2,000 | Varies by tool count |

### Multiplication Effect

```
Base teammate context cost:  ~30,000 tokens (system prompt + instructions)
+ 1 MCP server (Context7):  +500 tokens  → 30,500 total
+ 3 MCP servers:            +5,000 tokens → 35,000 total
× 5 teammates:              = 175,000 tokens (just overhead, before any work)
```

With a finite context window, heavy MCP usage can consume 85%+ of available context before agents start working.

### Mitigation Guidelines

1. **Disconnect unused MCP servers** before spawning teams — each costs tokens on every teammate
2. **Prefer CLI over MCP** where equivalent: `gh` CLI for GitHub vs GitHub MCP server
3. **Exception: Context7** — always keep connected. Its 500-token cost is negligible vs the documentation value it provides
4. **Future**: `mcp.teammate_servers` talisman key (roadmap) will allow per-workflow MCP selection

## Decision Tree Summary

```
About to summon agents?
├── Rune command (any agent count)
│   └── Agent Teams + Glyph Budget + inscription.json REQUIRED.
└── Custom workflow (3+ agents)
    └── Agent Teams + Glyph Budget + inscription.json REQUIRED.
        (Custom workflows with 1-2 agents may skip inscription but SHOULD still inject the Truthbinding Protocol when reviewing untrusted content.)
```
