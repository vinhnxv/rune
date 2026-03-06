# Phase 6.5: GOLDMASK CORRELATION — Full Algorithm

Synthesize investigation findings into correlation report. Cross-references TOME review findings with Goldmask predictions.

**Team**: None — orchestrator-only (deterministic correlation, no agents)
**Tools**: Read, Write, Glob, Grep
**Timeout**: 1 min (PHASE_TIMEOUTS.goldmask_correlation = 60_000)
**Inputs**: id, `tmp/arc/{id}/goldmask-findings.json` (from Phase 5.7), `tmp/arc/{id}/tome.md` (from Phase 6)
**Outputs**: `tmp/arc/{id}/goldmask-correlation.md`
**Error handling**: Non-blocking. Missing prerequisites → status "skipped". Parse failure → status "skipped".
**Consumers**: SKILL.md (Phase 6.5 stub), Phase 7 MEND (priority ordering + human review flags)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Design Note: Orchestrator-Only

Phase 6.5 does NOT need `prePhaseCleanup()` — it spawns no team and delegates nothing. The orchestrator reads two files, performs deterministic correlation, and writes the output. This matches the verify-mend.md pattern (also orchestrator-only).

## Algorithm

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0: PRE-FLIGHT GUARDS
// ═══════════════════════════════════════════════════════

if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Phase 6.5: unsafe id value: "${id}"`)

// Skip if Phase 5.7 was skipped (no goldmask data to correlate)
if (checkpoint.phases.goldmask_verification?.status !== 'completed') {
  warn(`Phase 6.5: skipped — Phase 5.7 (Goldmask Verification) was ${checkpoint.phases.goldmask_verification?.status ?? 'missing'}`)
  updateCheckpoint({
    phase: "goldmask_correlation", status: "skipped",
    phase_sequence: 6.5
  })
  return
}

// Skip if no TOME was produced in Phase 6
// QUAL-101 FIX: Use round-aware TOME path for convergence cycles
const round = checkpoint.convergence?.round ?? 0
const tomePath = round > 0
  ? `tmp/arc/${id}/tome-round-${round}.md`
  : `tmp/arc/${id}/tome.md`

if (!exists(tomePath)) {
  warn(`Phase 6.5: skipped — no TOME found at ${tomePath}`)
  updateCheckpoint({
    phase: "goldmask_correlation", status: "skipped",
    phase_sequence: 6.5
  })
  return
}

const findingsPath = `tmp/arc/${id}/goldmask-findings.json`
if (!exists(findingsPath)) {
  warn(`Phase 6.5: skipped — no goldmask-findings.json found`)
  updateCheckpoint({
    phase: "goldmask_correlation", status: "skipped",
    phase_sequence: 6.5
  })
  return
}

updateCheckpoint({
  phase: "goldmask_correlation", status: "in_progress",
  phase_sequence: 6.5
})

// ═══════════════════════════════════════════════════════
// STEP 1: PARSE INPUTS
// ═══════════════════════════════════════════════════════

let goldmaskFindings = null
try {
  goldmaskFindings = JSON.parse(Read(findingsPath))
} catch (e) {
  warn(`Phase 6.5: Failed to parse goldmask-findings.json — ${e.message ?? 'unknown'}`)
  updateCheckpoint({
    phase: "goldmask_correlation", status: "skipped",
    phase_sequence: 6.5
  })
  return
}

const tome = Read(tomePath)

// Inline parseTOMEFindings: extract findings from TOME markdown
// Uses TOME_FINDING_REGEX — the canonical regex for extracting [PREFIX-NNN] finding IDs
// and associated file paths from TOME markdown. Pattern matches lines like:
//   [SEC-001] Found vulnerability in `src/auth.ts`
//   [QUAL-003] Missing validation in "api/handler.js"
const TOME_FINDING_REGEX = /\[([A-Z]+-\d+)\].*?[`"]([a-zA-Z0-9._\/-]+\.[a-zA-Z0-9]+)[`"]/g
const tomeFindings = []
let match
while ((match = TOME_FINDING_REGEX.exec(tome)) !== null) {
  tomeFindings.push({
    id: match[1],
    file: match[2],
    line: 0  // TOME findings don't always include line numbers
  })
}

if (tomeFindings.length === 0) {
  log(`Phase 6.5: No parseable findings in TOME — writing empty correlation`)
  Write(`tmp/arc/${id}/goldmask-correlation.md`,
    `# Goldmask Correlation Report\n\nNo TOME findings to correlate.\n`)
  updateCheckpoint({
    phase: "goldmask_correlation", status: "completed",
    artifact: `tmp/arc/${id}/goldmask-correlation.md`,
    artifact_hash: sha256(Read(`tmp/arc/${id}/goldmask-correlation.md`)),
    phase_sequence: 6.5,
    correlation_count: 0,
    human_review_count: 0
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 2: CORRELATE FINDINGS
// ═══════════════════════════════════════════════════════

// For each TOME finding, check if Goldmask predicted risk for the same file
const correlations = []
for (const tf of tomeFindings) {
  const gmMatch = (goldmaskFindings.findings ?? []).find(gf =>
    gf.file === tf.file
  )
  if (gmMatch) {
    correlations.push({
      tome_id: tf.id,
      goldmask_id: gmMatch.id ?? 'N/A',
      file: tf.file,
      blast_radius: gmMatch.blast_radius ?? 'UNKNOWN',
      caution_score: gmMatch.caution ?? 0,
      wisdom_intent: gmMatch.wisdom?.intent ?? 'UNKNOWN',
      risk_priority: gmMatch.priority ?? 0
    })
  }
}

// ═══════════════════════════════════════════════════════
// STEP 3: IDENTIFY HUMAN REVIEW CANDIDATES
// ═══════════════════════════════════════════════════════

// HIGH caution + WIDE blast-radius → flag for human review in mend
const humanReviewFindings = correlations
  .filter(c => c.caution_score >= 0.75 || c.blast_radius === 'WIDE')
  .map(c => c.tome_id)

// ═══════════════════════════════════════════════════════
// STEP 4: WRITE CORRELATION REPORT
// ═══════════════════════════════════════════════════════

let report = `# Goldmask Correlation Report\n\n`
report += `**TOME findings**: ${tomeFindings.length}\n`
report += `**Goldmask findings**: ${(goldmaskFindings.findings ?? []).length}\n`
report += `**Correlated**: ${correlations.length}\n`
report += `**Flagged for human review**: ${humanReviewFindings.length}\n\n`

if (correlations.length > 0) {
  report += `## Correlated Findings\n\n`
  report += `| TOME ID | File | Blast Radius | Caution | Intent | Goldmask ID |\n`
  report += `|---------|------|-------------|---------|--------|-------------|\n`
  for (const c of correlations) {
    const flag = humanReviewFindings.includes(c.tome_id) ? ' **[HUMAN REVIEW]**' : ''
    report += `| ${c.tome_id}${flag} | ${c.file} | ${c.blast_radius} | ${(c.caution_score).toFixed(2)} | ${c.wisdom_intent} | ${c.goldmask_id} |\n`
  }
}

if (humanReviewFindings.length > 0) {
  report += `\n## Human Review Required\n\n`
  report += `> These findings have high caution scores (>=0.75) or WIDE blast radius.\n`
  report += `> Mend should NOT auto-fix these — flag for human review instead.\n\n`
  for (const findingId of humanReviewFindings) {
    const c = correlations.find(x => x.tome_id === findingId)
    report += `- **${findingId}** in \`${c.file}\` — caution: ${c.caution_score.toFixed(2)}, blast: ${c.blast_radius}, intent: ${c.wisdom_intent}\n`
  }
}

// Uncorrelated TOME findings (no Goldmask prediction)
const uncorrelated = tomeFindings.filter(tf =>
  !correlations.some(c => c.tome_id === tf.id)
)
if (uncorrelated.length > 0) {
  report += `\n## Uncorrelated TOME Findings\n\n`
  report += `These findings had no corresponding Goldmask prediction (novel issues):\n\n`
  for (const tf of uncorrelated.slice(0, 20)) {
    report += `- ${tf.id} in \`${tf.file}\`\n`
  }
  if (uncorrelated.length > 20) {
    report += `- ... and ${uncorrelated.length - 20} more\n`
  }
}

Write(`tmp/arc/${id}/goldmask-correlation.md`, report)

if (humanReviewFindings.length > 0) {
  log(`Goldmask Correlation: ${humanReviewFindings.length} findings flagged for human review`)
  log(`  (Caution >= 0.75 or WIDE blast radius)`)
}

// ═══════════════════════════════════════════════════════
// STEP 5: UPDATE CHECKPOINT
// ═══════════════════════════════════════════════════════

updateCheckpoint({
  phase: "goldmask_correlation", status: "completed",
  artifact: `tmp/arc/${id}/goldmask-correlation.md`,
  artifact_hash: sha256(report),
  phase_sequence: 6.5,
  correlation_count: correlations.length,
  human_review_count: humanReviewFindings.length
})
```

## Convergence Cycle Reset

When verify-mend triggers a convergence loop-back (Phase 7.5), goldmask_correlation is reset to `pending` so it re-correlates with the new TOME from the next review cycle. See [verify-mend.md](verify-mend.md) lines 198-203.

## Crash Recovery

Phase 6.5 is orchestrator-only with no team — crash recovery is straightforward:

| Resource | Location |
|----------|----------|
| Correlation report | `tmp/arc/{id}/goldmask-correlation.md` |

Recovery: Re-run Phase 6.5 from checkpoint. No team cleanup needed.
