# Phase 5.95: Inspect Fix (Gap Remediation from VERDICT) — Full Algorithm

Reads VERDICT.md from Phase 5.9, extracts FIXABLE findings, and spawns gap-fixer
agents to apply targeted fixes. Each fix gets its own atomic commit.

**Team**: `arc-inspect-fix-{id}` (1+ gap-fixer agents)
**Tools**: Read, Write, Edit, Glob, Grep, Bash, Agent, TeamCreate, TaskCreate, SendMessage
**Duration**: Max 15 minutes

## Entry Guard

```javascript
// Skip if inspect was skipped or produced no verdict
if (checkpoint.phases.inspect.status === 'skipped') {
  updateCheckpoint({ phase: 'inspect_fix', status: 'skipped', phase_sequence: 5.95, team_name: null })
  return
}

// Skip if inspect verdict is READY (no gaps to fix)
if (checkpoint.phases.inspect.verdict === 'READY') {
  updateCheckpoint({ phase: 'inspect_fix', status: 'skipped', phase_sequence: 5.95, team_name: null,
    fixed_count: 0, deferred_count: 0 })
  return
}

// Skip if VERDICT.md is missing
const id = checkpoint.id
let verdictContent
try {
  verdictContent = Read(`tmp/arc/${id}/inspect-verdict.md`)
} catch (e) {
  warn('Phase 5.95: No VERDICT.md found — skipping inspect_fix')
  updateCheckpoint({ phase: 'inspect_fix', status: 'skipped', phase_sequence: 5.95, team_name: null })
  return
}

updateCheckpoint({ phase: 'inspect_fix', status: 'in_progress', phase_sequence: 5.95, team_name: null })
```

## STEP 1: Extract FIXABLE Findings

```javascript
// Parse VERDICT.md for FIXABLE gaps
// Gap categories from verdict-binder: correctness, coverage, test, observability,
// security, operational, performance, maintainability
const gapMarkers = verdictContent.match(/<!-- GAP:[^>]*fixable="true"[^>]*-->/g) || []
const allParsedGaps = gapMarkers.map(marker => {
  const idMatch = marker.match(/id="([^"]+)"/)
  const fileMatch = marker.match(/file="([^"]+)"/)
  const categoryMatch = marker.match(/category="([^"]+)"/)
  const descMatch = marker.match(/desc="([^"]+)"/)
  const classificationMatch = marker.match(/classification="([^"]+)"/)
  return {
    gap_id: idMatch?.[1] ?? 'unknown',
    file: fileMatch?.[1] ?? null,
    category: categoryMatch?.[1] ?? 'unknown',
    description: descMatch?.[1] ?? '',
    classification: classificationMatch?.[1] ?? null,
  }
}).filter(g => g.file)  // Only fixable if we know the target file

// AC-6.1.1: Skip findings classified as false positives or intentional deviations (FRINGE-007)
const FP_CLASSIFICATIONS = [
  'FP_INSPECTOR_ERROR',
  'FP_AMBIGUOUS_AC',
  'DEVIATED_INTENTIONAL',
  'DEVIATED_SUPERSEDED',
  'MISSING_EXCLUDED',
]
const reclassifiedGaps = allParsedGaps.filter(g =>
  g.classification && (
    g.classification.startsWith('FP_') ||
    FP_CLASSIFICATIONS.includes(g.classification)
  )
)
const fixableGaps = allParsedGaps.filter(g =>
  !g.classification || (
    !g.classification.startsWith('FP_') &&
    !FP_CLASSIFICATIONS.includes(g.classification)
  )
)
// AC-6.1.2: Track reclassified count separately from fixed and deferred
const reclassifiedCount = reclassifiedGaps.length

// readTalismanSection: "inspect"
const inspectConfig = readTalismanSection("inspect") ?? {}
const maxFixes = inspectConfig.max_fixes ?? 20

if (fixableGaps.length === 0) {
  // FLAW-005 FIX: Subtract reclassified from deferred (they're not deferred, they're resolved)
  const earlyDeferredCount = Math.max(0, gapMarkers.length - reclassifiedCount)
  warn(`Phase 5.95: No FIXABLE gaps — ${reclassifiedCount} reclassified, ${earlyDeferredCount} deferred`)
  updateCheckpoint({
    phase: 'inspect_fix', status: 'completed', phase_sequence: 5.95, team_name: null,
    artifact: `tmp/arc/${id}/inspect-verdict.md`,
    artifact_hash: sha256(verdictContent),
    fixed_count: 0, deferred_count: earlyDeferredCount, reclassified_count: reclassifiedCount,
  })
  return
}

// Cap fixable gaps
const capsFixable = fixableGaps.slice(0, maxFixes)
const deferredCount = fixableGaps.length - capsFixable.length + (gapMarkers.length - fixableGaps.length - reclassifiedCount)
```

## STEP 2: Group by File and Spawn Fixers

```javascript
// Group gaps by file for efficient fixing
const gapsByFile = {}
for (const gap of capsFixable) {
  if (!gapsByFile[gap.file]) gapsByFile[gap.file] = []
  gapsByFile[gap.file].push(gap)
}

const teamName = `arc-inspect-fix-${id}`
TeamCreate({ team_name: teamName })
updateCheckpoint({ phase: 'inspect_fix', team_name: teamName })

const fixerNames = []
let fixerIdx = 0
for (const [file, gaps] of Object.entries(gapsByFile)) {
  const fixerName = `gap-fixer-${fixerIdx++}`
  fixerNames.push(fixerName)

  TaskCreate({
    subject: `${fixerName}: fix ${gaps.length} gaps in ${file}`,
    description: `Fix FIXABLE gaps in ${file}. Gap IDs: ${gaps.map(g => g.gap_id).join(', ')}. Each fix gets its own atomic commit with format: fix({context}): [{GAP-ID}]. Read tmp/arc/${id}/inspect-verdict.md for full gap context.`,
  })
  Agent({
    team_name: teamName,
    name: fixerName,
    subagent_type: 'rune:work:gap-fixer',
    prompt: `You are gap-fixer for inspect remediation. Fix these FIXABLE gaps in ${file}:\n${gaps.map(g => `- [${g.gap_id}] (${g.category}): ${g.description}`).join('\n')}\n\nRead tmp/arc/${id}/inspect-verdict.md for full context. Apply minimal, targeted fixes. Each fix gets its own atomic commit: fix(inspect): [${gaps[0].gap_id}]. Claim your task via TaskList + TaskUpdate (status: completed) when done.`,
  })
}

waitForCompletion(teamName, fixerNames.length, { timeoutMs: 600_000, pollIntervalMs: 30_000 })
```

## STEP 3: Count Results and Update Checkpoint

```javascript
// Count commits made by fixers
const fixCommits = Bash(`git log --oneline --since="30 minutes ago" --grep="fix(inspect):" | wc -l`).trim()
const fixedCount = parseInt(fixCommits, 10) || 0

// AC-6.1.3: Write remediation report with reclassified section
const reportContent = [
  `# Inspect Fix Report — Round ${checkpoint.inspect_convergence?.round ?? 0}`,
  '',
  `**Total FIXABLE gaps**: ${capsFixable.length}`,
  `**Fixed**: ${fixedCount}`,
  `**Deferred**: ${deferredCount}`,
  `**Reclassified (False Positive)**: ${reclassifiedCount}`,
  '',
  '## Gaps Addressed',
  ...capsFixable.map(g => `- [${g.gap_id}] ${g.category}: ${g.description} → ${g.file}`),
  '',
  // AC-6.1.3: False Positive section in resolution report
  ...(reclassifiedCount > 0 ? [
    '## Reclassified (False Positive)',
    '',
    'The following findings were skipped — classified as false positives or intentional deviations:',
    '',
    ...reclassifiedGaps.map(g => `- [${g.gap_id}] ${g.category}: ${g.description} → \`${g.classification}\``),
  ] : []),
].join('\n')

const reportPath = `tmp/arc/${id}/inspect-fix-report.md`
Write(reportPath, reportContent)

updateCheckpoint({
  phase: 'inspect_fix', status: 'completed', phase_sequence: 5.95,
  artifact: reportPath,
  artifact_hash: sha256(reportContent),
  fixed_count: fixedCount,
  deferred_count: deferredCount,
  reclassified_count: reclassifiedCount,
})
```

**Output**: `tmp/arc/{id}/inspect-fix-report.md` — remediation report with fix counts.

**Failure policy**: Non-blocking. If no fixable gaps exist, phase completes with zero counts. Individual fixer failures are counted as deferred gaps. The convergence controller (verify_inspect) evaluates overall progress.
