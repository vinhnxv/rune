# Phase 5.9: Inspect (Plan-vs-Implementation Audit) — Full Algorithm

Spawns 4 Inspector Ashes to evaluate plan-vs-implementation alignment. Each inspector
receives the enriched plan + committed files diff and produces dimension-specific findings.
Output is aggregated by verdict-binder into a unified VERDICT.md.

**Team**: `arc-inspect-full-{id}` (4 Inspector Ashes + 1 verdict-binder)
**Tools**: Read, Glob, Grep, Write, Bash (git diff), Agent, TeamCreate, TaskCreate, SendMessage
**Duration**: Max 15 minutes (inner 10m inspect + 5m setup/aggregation)

## Entry Guard

```javascript
// Skip if inspect is disabled via skip_map
if (checkpoint.skip_map?.inspect) {
  updateCheckpoint({ phase: 'inspect', status: 'skipped', phase_sequence: 5.9, team_name: null })
  return
}

// Skip if no plan file is available
if (!checkpoint.plan_file || !Read(checkpoint.plan_file)) {
  warn('Phase 5.9: No plan file available — skipping inspect')
  updateCheckpoint({ phase: 'inspect', status: 'skipped', phase_sequence: 5.9, team_name: null })
  return
}

updateCheckpoint({ phase: 'inspect', status: 'in_progress', phase_sequence: 5.9, team_name: null })
```

## STEP 1: Prepare Inspect Context

```javascript
const id = checkpoint.id
const planContent = Read(checkpoint.plan_file)
const defaultBranch = Bash("git rev-parse --abbrev-ref HEAD@{upstream} 2>/dev/null || echo main").trim().split('/').pop()
const diffOutput = Bash(`git diff ${defaultBranch}...HEAD --stat`)
const detailedDiff = Bash(`git diff ${defaultBranch}...HEAD`)

// Progressive focus on retry rounds — narrow scope to unresolved gaps
const inspectRound = checkpoint.inspect_convergence?.round ?? 0
let focusScope = null
if (inspectRound > 0) {
  try {
    focusScope = JSON.parse(Read(`tmp/arc/${id}/inspect-focus-round-${inspectRound}.json`))
  } catch (e) {
    warn(`Inspect round ${inspectRound}: no focus scope found — running full inspection`)
  }
}

// Build inspector context block
const inspectorContext = {
  plan: planContent,
  diff_stats: diffOutput,
  detailed_diff: focusScope ? focusScope.focused_diff : detailedDiff,
  round: inspectRound,
  focus: focusScope,
}

Bash(`mkdir -p "tmp/arc/${id}"`)
Write(`tmp/arc/${id}/inspect-context.json`, JSON.stringify(inspectorContext))
```

## STEP 2: Spawn Inspector Team

```javascript
const teamName = `arc-inspect-full-${id}`
TeamCreate({ team_name: teamName })
updateCheckpoint({ phase: 'inspect', team_name: teamName })

// 4 Inspector Ashes — each evaluates different dimensions
const inspectors = [
  { name: 'grace-warden-inspect', desc: 'Correctness and completeness inspector — COMPLETE/PARTIAL/MISSING/DEVIATED status per requirement' },
  { name: 'ruin-prophet-inspect', desc: 'Failure modes and security inspector — error handling, security posture, operational readiness' },
  { name: 'sight-oracle-inspect', desc: 'Design and architecture inspector — architectural alignment, coupling analysis, performance profile' },
  { name: 'vigil-keeper-inspect', desc: 'Observability and testing inspector — test coverage gaps, logging/metrics, code quality, documentation' },
]

// Create tasks + spawn agents
for (const inspector of inspectors) {
  TaskCreate({
    subject: `${inspector.name}: inspect plan-vs-implementation`,
    description: `Read tmp/arc/${id}/inspect-context.json for plan and diff context. Write findings to tmp/arc/${id}/${inspector.name}-findings.md. Include VERDICT markers for aggregation.${focusScope ? ' FOCUS: Only evaluate gaps from prior round — see context.focus for narrowed scope.' : ''}`,
  })
  Agent({
    team_name: teamName,
    name: inspector.name,
    subagent_type: `rune:investigation:${inspector.name}`,
    prompt: `You are ${inspector.name} in arc inspect phase. Read tmp/arc/${id}/inspect-context.json for the enriched plan and implementation diff. Evaluate plan-vs-implementation alignment from your dimension. Write structured findings to tmp/arc/${id}/${inspector.name}-findings.md. Claim your task via TaskList + TaskUpdate (status: completed) when done.`,
  })
}

// Wait for all inspectors
waitForCompletion(teamName, inspectors.length, { timeoutMs: 600_000, pollIntervalMs: 30_000 })
```

## STEP 3: Aggregate via Verdict-Binder

```javascript
// Spawn verdict-binder to merge all inspector findings into VERDICT.md
TaskCreate({
  subject: 'verdict-binder: aggregate inspector findings into VERDICT.md',
  description: `Read all inspector findings from tmp/arc/${id}/*-findings.md. Merge into tmp/arc/${id}/inspect-verdict.md using verdict-binder protocol. Include completion percentage, dimension scores, and gap classification.`,
})
Agent({
  team_name: teamName,
  name: 'verdict-binder',
  subagent_type: 'rune:utility:verdict-binder',
  prompt: `You are verdict-binder. Aggregate all inspector findings from tmp/arc/${id}/*-findings.md into a unified VERDICT.md at tmp/arc/${id}/inspect-verdict.md. Compute overall completion percentage, merge dimension scores, deduplicate findings, classify gaps, and determine final verdict (READY/GAPS_FOUND/INCOMPLETE/CRITICAL_ISSUES). Claim your task via TaskList + TaskUpdate (status: completed) when done.`,
})

waitForCompletion(teamName, 1, { timeoutMs: 180_000, pollIntervalMs: 15_000 })
```

## STEP 4: Parse VERDICT and Update Checkpoint

```javascript
// VERDICT.md missing guard
let verdictContent
try {
  verdictContent = Read(`tmp/arc/${id}/inspect-verdict.md`)
} catch (e) {
  warn('Phase 5.9: VERDICT.md not produced — inspectors may have timed out')
  updateCheckpoint({
    phase: 'inspect', status: 'completed', phase_sequence: 5.9,
    artifact: null, artifact_hash: null,
    completion_pct: null, p1_count: null, verdict: 'missing',
  })
  return
}

// Extract metrics from VERDICT.md — dual scoring (adjusted preferred, raw fallback, legacy compat)
const adjustedMatch = verdictContent.match(/Overall Completion \(Adjusted\)\s*\|\s*(\d+(?:\.\d+)?)%/)
const rawMatch = verdictContent.match(/Overall Completion \(Raw\)\s*\|\s*(\d+(?:\.\d+)?)%/)
const legacyMatch = verdictContent.match(/Overall Completion:\s*(\d+(?:\.\d+)?)%/)
  ?? verdictContent.match(/Overall Completion\s*\|\s*(\d+(?:\.\d+)?)%/)
// NaN guard (RUIN-002): parseFloat may return NaN on malformed VERDICT
const rawPct = adjustedMatch ? parseFloat(adjustedMatch[1])
  : rawMatch ? parseFloat(rawMatch[1])
  : legacyMatch ? parseFloat(legacyMatch[1]) : null
const completionPct = Number.isFinite(rawPct) ? rawPct : null

// P1 count — adjusted preferred (excludes INTENTIONAL/EXCLUDED/FP), legacy fallback
const adjP1Match = verdictContent.match(/P1 Findings \(Adjusted\)\s*\|\s*(\d+)/)
const rawP1Match = verdictContent.match(/P1 Findings \(Raw\)\s*\|\s*(\d+)/)
// NaN guard (RUIN-003): parseInt may return NaN on non-numeric capture
const rawP1 = adjP1Match ? parseInt(adjP1Match[1], 10)
  : rawP1Match ? parseInt(rawP1Match[1], 10)
  : (verdictContent.match(/severity="P1"/gi) || []).length
const p1Markers = Number.isFinite(rawP1) ? rawP1 : 0
const verdictMatch = verdictContent.match(/Final Verdict:\s*(READY|GAPS_FOUND|INCOMPLETE|CRITICAL_ISSUES)/)
const inspectVerdict = verdictMatch ? verdictMatch[1] : 'GAPS_FOUND'

updateCheckpoint({
  phase: 'inspect', status: 'completed', phase_sequence: 5.9,
  artifact: `tmp/arc/${id}/inspect-verdict.md`,
  artifact_hash: sha256(verdictContent),
  completion_pct: completionPct,
  p1_count: p1Markers,
  verdict: inspectVerdict,
})

// Phase ordering assertion: inspect must precede inspect_fix in PHASE_ORDER
const inspIdx = PHASE_ORDER.indexOf('inspect')
const fixIdx = PHASE_ORDER.indexOf('inspect_fix')
if (inspIdx < 0 || fixIdx < 0 || inspIdx >= fixIdx) {
  throw new Error(`PHASE_ORDER invariant violated: inspect (${inspIdx}) must precede inspect_fix (${fixIdx})`)
}
```

**Output**: `tmp/arc/{id}/inspect-verdict.md` — unified VERDICT.md with completion %, dimension scores, gap classification.

**Failure policy**: Non-blocking. Missing VERDICT proceeds to inspect_fix with null metrics. Individual inspector timeouts produce partial findings — verdict-binder aggregates whatever is available.
