# Phase 2: Forge Gaze Selection

Applies the Forge Gaze topic-matching algorithm to select enrichment agents per section, with force-include from Phase 1.7 and risk-weighted scoring from Goldmask Lore Layer.

**Inputs**: `sections` (parsed plan sections), `forceIncludeList` (from Phase 1.7), `riskMap` (from Phase 1.5), `flags` (--exhaustive), `topic_registry`
**Outputs**: `assignments` map (section -> [agent, score] pairs), risk-boosted sections flagged
**Preconditions**: Phase 1.7 (Codex Section Validation) complete

```javascript
const mode = flags.exhaustive ? "exhaustive" : "default"
const assignments = forge_select(sections, topic_registry, mode)

// Apply Phase 1.7 force-include list (Codex Section Validation)
if (forceIncludeList.length > 0) {
  for (const sectionTitle of forceIncludeList) {
    const section = sections.find(s => s.title === sectionTitle)
    if (section && !assignments.has(section)) {
      // Force-include with default enrichment agent (must match forge-gaze [agent_object, score] shape)
      const defaultAgent = topic_registry.find(a => a.name === "rune-architect") || { name: "rune-architect", perspective: "Architectural compliance and design pattern review" }
      assignments.set(section, [[defaultAgent, 0.50]])
      log(`  Force-include: "${sectionTitle}" — added by Codex Section Validation`)
    }
  }
}

// ── Risk-Boosted Scoring (Goldmask Lore Layer) ──
// When risk-map data is available from Phase 1.5, boost Forge Gaze scores
// for sections that reference CRITICAL or HIGH risk files.
if (riskMap) {
  const TIER_ORDER: Record<string, number> = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3, STALE: 4, UNKNOWN: 5 }

  // getMaxRiskTier: returns the highest risk tier among the given files.
  // NOTE: forge signature differs from inspect — second param is the full parsed risk-map object
  // ({ files: RiskEntry[] }), not a flat RiskEntry[] array as in inspect/SKILL.md:335.
  function getMaxRiskTier(files: string[], parsedRiskMap: { files: Array<{ path: string, tier: string }> }): string {
    let maxTier: string = "UNKNOWN"
    for (const filePath of files) {
      const entry = parsedRiskMap.files?.find((f: { path: string }) => f.path === filePath)
      if (entry && (TIER_ORDER[entry.tier] ?? 5) < (TIER_ORDER[maxTier] ?? 5)) {
        maxTier = entry.tier
      }
    }
    return maxTier
  }

  try {
    const parsedRiskMap = JSON.parse(riskMap)
    for (const [section, agents] of assignments) {
      // Extract file refs from this specific section
      const sectionFiles: string[] = []
      for (const match of (section.content || '').matchAll(fileRefPattern)) {
        const fp: string = match[1] || match[2]
        if (fp && !fp.includes('..')) sectionFiles.push(fp)
      }
      const maxRiskTier: string = getMaxRiskTier(sectionFiles, parsedRiskMap)

      if (maxRiskTier === 'CRITICAL') {
        // Boost all agent scores for this section by 0.15 (heuristic threshold — not empirically
        // calibrated; subject to tuning via future talisman.yml forge.risk_boost_critical config)
        for (const agentEntry of agents) {
          agentEntry[1] = Math.min(agentEntry[1] + 0.15, 1.0)
        }
        section.riskBoost = 0.15
        section.autoIncludeResearchBudget = true  // Include research-budget agents even in default mode
        log(`  Risk boost: "${section.title}" — CRITICAL files, +0.15 boost`)
      } else if (maxRiskTier === 'HIGH') {
        // Boost by 0.08 (heuristic threshold — not empirically calibrated; subject to tuning)
        for (const agentEntry of agents) {
          agentEntry[1] = Math.min(agentEntry[1] + 0.08, 1.0)
        }
        section.riskBoost = 0.08
        log(`  Risk boost: "${section.title}" — HIGH files, +0.08 boost`)
      }
      // MEDIUM/LOW/STALE/UNKNOWN: no boost
    }
  } catch (parseError) {
    warn("Phase 2: risk-map.json parse error — proceeding without risk boost")
  }
}

// Log selection transparently (after risk boost applied)
for (const [section, agents] of assignments) {
  log(`Section: "${section.title}"${section.riskBoost ? ` [risk-boosted +${section.riskBoost}]` : ''}`)
  for (const [agent, score] of agents) {
    log(`  + ${agent.name} (${score.toFixed(2)}) — ${agent.perspective}`)
  }
}
```

## Selection Constants

| Constant | Default | Exhaustive |
|----------|---------|------------|
| Threshold | 0.30 | 0.15 |
| Max per section | 3 | 5 |
| Max concurrent | 5 | 5 |
| Max total agents | 8 | 12 |

These can be overridden via `talisman.yml` `forge:` section.

## Codex Oracle Forge Agent (conditional)

When `codex` CLI is available and `codex.workflows` includes `"forge"`, Codex Oracle participates in Forge Gaze topic matching. It provides cross-model enrichment.

See [forge-enrichment-protocol.md](forge-enrichment-protocol.md) for the full Codex Oracle activation logic, prompt templates, and agent lifecycle.
