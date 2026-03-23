# Phase 2.3.5: Research Conflict Tiebreaker (Codex)

**CONDITIONAL** — only runs when research agents produce conflicting recommendations. Most runs skip (~80% skip rate).

After Phase 2.3 Goldmask injection and before Phase 2.5 Shatter Assessment, detect conflicting recommendations from research agent outputs and invoke Codex for a tiebreaker verdict.

**Inputs**: `talisman` (config object), `timestamp` (validated identifier), `planPath` (string)
**Outputs**: Tiebreaker verdict annotated inline in plan with `[CDX-TIEBREAKER]` tag
**Preconditions**: Phase 1 research completed, research outputs in `tmp/plans/{timestamp}/research/`

**Team**: None (inline codex exec within existing plan team — no new team)
**Failure**: Non-blocking — conflicting recommendations preserved without tiebreaker annotation.

## Protocol

```javascript
// Phase 2.3.5: RESEARCH CONFLICT TIEBREAKER
// 4-condition detection gate (canonical pattern)
const codexAvailable = detectCodex()
const codexDisabled = talisman?.codex?.disabled === true
const tiebreakerEnabled = talisman?.codex?.research_tiebreaker?.enabled !== false  // Default ON
const workflowIncluded = (talisman?.codex?.workflows ?? []).includes("plan")

if (codexAvailable && !codexDisabled && tiebreakerEnabled && workflowIncluded) {
  // Step 1: Detect conflicts in research outputs
  // Read research agent outputs from Phase 1 (stored in plan team output directory)
  const researchOutputDir = `tmp/plans/${timestamp}/research/`
  const researchFiles = Glob(`${researchOutputDir}*.md`)

  // Conflict detection: look for contradictory recommendations
  // Parse each research output for recommendation sections and compare
  const recommendations = []
  for (const f of researchFiles) {
    try {
      const content = Read(f)
      // Extract recommendations from ## Recommendations or ## Approach sections
      const recMatch = content.match(/##\s*(?:Recommendations?|Approach|Conclusion|Verdict)\s*\n([\s\S]*?)(?=\n##|\n---|\Z)/i)
      if (recMatch) {
        recommendations.push({
          source: f.split('/').pop().replace('.md', ''),
          content: recMatch[1].trim().substring(0, 2000)
        })
      }
    } catch (e) { continue }
  }

  // Conflict detection gate: need at least 2 recommendations to compare
  if (recommendations.length < 2) {
    warn("Phase 2.3.5: Fewer than 2 research recommendations — skipping tiebreaker")
    // No output needed — tiebreaker is conditional
  } else {
    // Simple heuristic: check if recommendations mention different approaches
    // Look for contradictory signals (e.g., "REST" vs "GraphQL", "monolith" vs "microservices")
    const allText = recommendations.map(r => r.content).join("\n")
    const contradictionPairs = [
      [/\bREST\b/i, /\bGraphQL\b/i],
      [/\bmonolith/i, /\bmicroservice/i],
      [/\bSQL\b/i, /\bNoSQL\b/i],
      [/\bsynchronous\b/i, /\basynchronous\b/i],
      [/\bnot recommend/i, /\brecommend(?!.*not)\b/i]
    ]
    const hasConflict = contradictionPairs.some(([a, b]) => a.test(allText) && b.test(allText))

    if (!hasConflict) {
      warn("Phase 2.3.5: No conflicting recommendations detected — skipping tiebreaker")
    } else {
      // Conflict detected — invoke Codex for tiebreaker
      const { timeout, reasoning, model: codexModel } = resolveCodexConfig(talisman, "research_tiebreaker", {
        timeout: 300, reasoning: "high"
      })

      const promptTmpFile = `tmp/plans/${timestamp}/.codex-prompt-tiebreaker.tmp`
      try {
        const recSummary = recommendations.map(r =>
          `=== ${r.source} ===\n${sanitizePlanContent(r.content)}\n=== END ${r.source} ===`
        ).join("\n\n")

        const nonce = Bash(`openssl rand -hex 16`).trim()
        const promptContent = `SYSTEM: You are a cross-model research conflict resolver.

Research agents produced conflicting recommendations. Analyze each position and provide a tiebreaker verdict.

<<<NONCE_${nonce}>>>
${recSummary}
<<<END_NONCE_${nonce}>>>

Provide:
1. Summary of each position (1-2 sentences)
2. Key trade-offs between positions
3. Tiebreaker verdict: which approach to use and why
4. Confidence level (HIGH/MEDIUM/LOW)

Tag your verdict with [CDX-TIEBREAKER] for transparency.
Base analysis on technical merits, not assumptions.`

        Write(promptTmpFile, promptContent)
        const result = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g "${promptTmpFile}"`)
        const classified = classifyCodexError(result)

        if (classified === "SUCCESS" && result.stdout) {
          // Inject tiebreaker verdict into the plan document
          const verdict = result.stdout.substring(0, 3000)
          const planContent = Read(planPath)
          const tiebreakerSection = `\n\n### Research Conflict Resolution [CDX-TIEBREAKER]\n\n${verdict}\n`

          // Find the first ## heading after research section and inject before it
          // Or append after the last research-related section
          const injectionPoint = planContent.indexOf("## Implementation") !== -1
            ? planContent.indexOf("## Implementation")
            : planContent.indexOf("## Constraints") !== -1
              ? planContent.indexOf("## Constraints")
              : planContent.length
          Edit(planPath, {
            old_string: planContent.substring(injectionPoint, injectionPoint + 50),
            new_string: tiebreakerSection + planContent.substring(injectionPoint, injectionPoint + 50)
          })
          warn("Phase 2.3.5: Tiebreaker verdict injected into plan with [CDX-TIEBREAKER] tag")
        }
      } finally {
        Bash(`rm -f "${promptTmpFile}"`)  // Guaranteed cleanup
      }
    }
  }
} else {
  // Codex not available — skip silently (conditional phase, no output required)
  if (codexAvailable && !codexDisabled && tiebreakerEnabled) {
    warn("Phase 2.3.5: Skipped — plan not in codex.workflows")
  }
}
```

## Conflict Detection Heuristic

The heuristic uses simple keyword pair matching. It intentionally favors false positives (triggering tiebreaker when no real conflict exists) over false negatives (missing a real conflict). A false positive costs one Codex call (~$0.30); a false negative leaves conflicting advice unresolved.

## Error Handling — Phase 2.3.5

| Phase | Error | Recovery | Severity |
|-------|-------|----------|----------|
| 2.3.5 | No research outputs found | Skip silently | INFO |
| 2.3.5 | Fewer than 2 recommendations | Skip silently | INFO |
| 2.3.5 | No conflicts detected | Skip silently (expected ~80% of runs) | INFO |
| 2.3.5 | Codex timeout/error | Skip tiebreaker, proceed with conflicting recs | WARN |
| 2.3.5 | Plan injection fails | Log warning, proceed without annotation | WARN |
