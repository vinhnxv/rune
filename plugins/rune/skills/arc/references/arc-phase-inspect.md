# Phase 5.9: Inspect (Plan-vs-Implementation Audit + Fix + Convergence) — Full Algorithm

<!--
v3.0.0-alpha.7 (Day 6) absorption notes — gap_analysis family merge

The verification phase group (gap_analysis + gap_analysis_qa + gap_remediation) was
collapsed into this single inspect phase. PHASE_ORDER 19 → 16. The 5 locked decisions
that drove this absorption (recorded here so future readers see what was decided and why):

  1. Verdict file canonical name → `VERDICT.md` (at `tmp/arc/{id}/inspect/VERDICT.md`).
     The 4-Inspector verdict is a strict superset of the retired 2-Inspector
     gap-analysis-verdict.md; one canonical name eliminates dual-consumer code paths.

  2. Inspector pool → 4 Ashes (grace-warden, ruin-prophet, sight-oracle, vigil-keeper)
     plus 1 verdict-binder. The 2-Inspector gap-analysis pass retires entirely. Token
     cost rises ~6-10K per arc gap-detection cycle; brainstorm Devil's Advocate
     analysis identified CLAUDE.md as the dominant token cost, not per-arc inspectors.

  3. gap_analysis_qa checklist → dropped (Q3). The 13 GAP-STEP-XX items in
     qa-manifests/gap-analysis.yaml and arc-phase-qa-gate.md are retired. Day 7's
     parametric qa-verifier (brainstorm cut-list line 139) will replace the bar.
     CHANGELOG documents the temporary quality-bar lowering.

  4. Team prefix reconciliation:
     - RETIRED: `arc-inspect-{id}` (gap_analysis STEP B), `arc-gap-fix-{id}` (gap_remediation)
     - KEPT: `arc-inspect-full-{id}` (4-Inspector audit), `arc-inspect-fix-{id}` (gap-fixer dispatch)
     - `arc-gap-fix-` stays in ARC_TEAM_PREFIXES for one alpha (Q4) as cleanup-only
       insurance against orphan teams during the alpha-to-alpha transition.

  5. artifact-extract mode → `inspect` (replaces `gap-analysis` mode in scripts/artifact-extract.sh).
     Output path: tmp/arc/{id}/inspect-digest.json. v3-defaults.md keys renamed
     immediately: arc.gap_analysis.* → arc.inspect.* (no dual-naming alpha — keys are
     baked, no user-facing config benefit to deprecation cycle).

The three LOAD-BEARING semantics preserved across the absorption (audit these on every
future edit to this file):

  - STEP D.0 Task Completion Gate (PR #310 fix, 2026-03-16): hardcoded 100% floor,
    non-bypassable in non-headless mode. The `error()` call after needsRemediation
    evaluation is the gate mechanism — preserve verbatim.
  - STEP D.7 Plan writeback: appends "Implementation Status" section + DEFERRED tasks
    back to checkpoint.plan_file. Enforces "no silent deferrals" invariant.
  - SEC-GAP-001: validate-gap-fixer-paths.sh PreToolUse hook matches on agent name
    "gap-fixer" verbatim. Path restrictions (.claude/, .github/, .env, node_modules/,
    CI YAML) lapse silently if the agent name changes.
-->

Spawns 4 Inspector Ashes to evaluate plan-vs-implementation alignment, then spawns gap-fixers for FIXABLE findings (absorbed `inspect_fix` in v3.0.0-alpha.6 Day 5 C4c; absorbed `gap_remediation` in v3.0.0-alpha.7 Day 6), then evaluates convergence and either retries or halts (absorbed `verify_inspect`). Also runs deterministic pre-team checks (absorbed STEP A from `gap_analysis`) and a halt-decision gate with Task Completion Gate (absorbed STEP D from `gap_analysis`). Output is aggregated by verdict-binder into a unified VERDICT.md.

**Teams**: `arc-inspect-full-{id}` (4 Inspector Ashes + 1 verdict-binder), then `arc-inspect-fix-{id}` (gap-fixer agents, conditional on verdict != READY)
**Tools**: Read, Glob, Grep, Write, Edit, Bash (git diff), Agent, TeamCreate, TaskCreate, SendMessage
**Duration**: Max 34 minutes per convergence round (15m audit + 15m fix + 4m convergence eval)
**Convergence**: Up to `inspect_convergence.max_rounds` (default 2) cycles. On retry, the phase resets itself to `pending` so the dispatcher loops back.

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
// Set initial substate: entering deterministic STEP A (pre-team)
updateCheckpoint({ phase: 'inspect', substate: 'deterministic' })

// v3.0.0-alpha.7 (Day 6) FIX (CORR-003): declare `id` and `defaultBranch` BEFORE STEP A
// is invoked — STEP A's sub-reference reads both. Previously declared in STEP 1 below;
// the Day 6 split into a pre-team sub-step required pulling them earlier.
const id = checkpoint.id
const defaultBranch = Bash("git rev-parse --abbrev-ref HEAD@{upstream} 2>/dev/null || echo main").trim().split('/').pop()
// CORR-005 FIX: Ensure inspect/ subdirectory exists before any STEP A / STEP D writes.
Bash(`mkdir -p "tmp/arc/${id}/inspect"`)
```

## STEP A: Deterministic Pre-Team Checks (absorbed gap_analysis STEP A)

<!-- v3.0.0-alpha.7 (Day 6): Absorbed from the retired gap_analysis phase. -->
<!-- Orchestrator-only pre-team sub-step. Zero LLM cost. Produces -->
<!-- tmp/arc/{id}/inspect/deterministic.md which STEP D halt-gate reads. -->
<!-- Full algorithm in inspect-step-a-deterministic.md (sub-reference). -->

Read and follow [inspect-step-a-deterministic.md](inspect-step-a-deterministic.md). It runs deterministic checks (acceptance criteria coverage, doc consistency, plan-section coverage, evaluator quality, semantic claims, stale references, scope creep, spec compliance matrix) and writes `tmp/arc/{id}/inspect/deterministic.md`. On completion, it sets `checkpoint.phases.inspect.substate = 'deterministic_done'` and writes `checkpoint.phases.inspect.deterministic_gaps` for STEP D consumption.

After STEP A returns, advance substate before STEP 1 spawns the inspector team:

```javascript
updateCheckpoint({ phase: 'inspect', substate: 'audit' })  // entering STEP 1-4
```

## STEP 1: Prepare Inspect Context

```javascript
// v3.0.0-alpha.7 (Day 6): `id` and `defaultBranch` are declared in the Entry Guard above
// (CORR-003 fix) — STEP A's sub-reference uses both. Do NOT re-declare them here.
const planContent = Read(checkpoint.plan_file)
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

// STEP 1.5: Extract wiring map requirements for inspector context (v2.2.0+)
// When the plan contains `## Integration & Wiring Map`, parse the tables and inject
// into inspectorContext so grace-warden (in inspect mode) can verify wiring completeness.
let wiringRequirements = null
const wiringMatch = planContent.match(/## Integration & Wiring Map([\s\S]*?)(?=\n## [^#]|\n---|\Z)/)
if (wiringMatch) {
  // parseMarkdownTable: regex-based table parser — extracts rows as objects from named subsection
  // parseRegistrationList: extracts bullet points matching `- **text**: description`
  wiringRequirements = {
    entry_points: parseMarkdownTable(wiringMatch[1], 'Entry Points'),
    existing_modifications: parseMarkdownTable(wiringMatch[1], 'Existing File Modifications'),
    layer_traversal: parseMarkdownTable(wiringMatch[1], 'Layer Traversal'),
    registration: parseRegistrationList(wiringMatch[1]),
  }
  // Inject into inspector context so grace-warden can verify
  inspectorContext.wiring_requirements = wiringRequirements
  log(`Wiring map detected: ${wiringRequirements.entry_points.length} entry points, ` +
    `${wiringRequirements.existing_modifications.length} file modifications, ` +
    `${wiringRequirements.layer_traversal.length} layer traversals`)
}
// Gap categories: correctness, coverage, test, observability,
//                 security, operational, performance, maintainability,
//                 wiring  // NEW (v2.2.0) — from grace-warden WIRE- findings

Bash(`mkdir -p "tmp/arc/${id}"`)
Write(`tmp/arc/${id}/inspect-context.json`, JSON.stringify(inspectorContext))
```

## STEP 2: Spawn Inspector Team

> **CLEAN-001 FIX**: STEPs 2–3 are conceptually wrapped in `try { ... } finally { ... }`.
> If the phase crashes between `TeamCreate` and `waitForCompletion`, the `finally` block
> (STEP 5 below) shuts down inspectors and deletes the team. `postPhaseCleanup` also runs
> on normal completion, but an inline finally is required because `postPhaseCleanup` is
> skipped on mid-phase crashes — see `arc-phase-cleanup.md:14`.

```javascript
const teamName = `arc-inspect-full-${id}`
TeamCreate({ team_name: teamName })
updateCheckpoint({ phase: 'inspect', team_name: teamName })

// 4 Inspector Ashes — each evaluates different dimensions
// Inspectors are single base agents with mode dispatch; spawn-prompt prepends `MODE: inspect\n\n`
// to route the base agent to its `## Mode: inspect` section.
const inspectors = [
  { name: 'grace-warden', desc: 'Correctness and completeness inspector — COMPLETE/PARTIAL/MISSING/DEVIATED status per requirement' },
  { name: 'ruin-prophet', desc: 'Failure modes and security inspector — error handling, security posture, operational readiness' },
  { name: 'sight-oracle', desc: 'Design and architecture inspector — architectural alignment, coupling analysis, performance profile' },
  { name: 'vigil-keeper', desc: 'Observability and testing inspector — test coverage gaps, logging/metrics, code quality, documentation' },
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
    prompt: `MODE: inspect\n\nYou are ${inspector.name} in arc inspect phase. Read tmp/arc/${id}/inspect-context.json for the enriched plan and implementation diff. Evaluate plan-vs-implementation alignment from your dimension. Write structured findings to tmp/arc/${id}/${inspector.name}-findings.md. Claim your task via TaskList + TaskUpdate (status: completed) when done.`,
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
  description: `Read all inspector findings from tmp/arc/${id}/*-findings.md. Merge into tmp/arc/${id}/inspect/VERDICT.md using verdict-binder protocol. Include completion percentage, dimension scores, and gap classification.`,
})
Agent({
  team_name: teamName,
  name: 'verdict-binder',
  subagent_type: 'rune:utility:verdict-binder',
  prompt: `You are verdict-binder. Aggregate all inspector findings from tmp/arc/${id}/*-findings.md into a unified VERDICT.md at tmp/arc/${id}/inspect/VERDICT.md. Compute overall completion percentage, merge dimension scores, deduplicate findings, classify gaps, and determine final verdict (READY/GAPS_FOUND/INCOMPLETE/CRITICAL_ISSUES). Claim your task via TaskList + TaskUpdate (status: completed) when done.`,
})

waitForCompletion(teamName, 1, { timeoutMs: 180_000, pollIntervalMs: 15_000 })
```

## STEP 3.5: Cleanup (CLEAN-001 FIX)

Runs in the `finally` branch of the try/finally wrapping STEPs 2–3. Shuts down inspectors and deletes the team. Required because `postPhaseCleanup` is skipped when a phase crashes mid-execution — without this block, the 5 Inspector Ashes would persist as orphans in the current session.

```javascript
// Standard 5-component cleanup (CLAUDE.md canonical pattern)
// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // Fallback: hardcoded list of every inspector + verdict-binder
  // Inspectors use base agent names — mode is dispatched via the spawn-prompt MODE: prefix.
  allMembers = [
    "grace-warden", "ruin-prophet",
    "sight-oracle", "vigil-keeper",
    "verdict-binder",
  ]
}

// 2a. Force-reply — put all teammates in message-processing state (GitHub #31389)
let confirmedAlive = 0
let confirmedDead = 0
const aliveMembers = []
for (const member of allMembers) {
  try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { confirmedDead++ }
}

// 2b. Single shared pause
if (aliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }

// 2c. Send shutdown_request to alive members
for (const member of aliveMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Inspect complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
}

// 3. Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`, { run_in_background: true })
} else {
  Bash("sleep 2", { run_in_background: true })
}

// 4. TeamDelete with retry-with-backoff
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`inspect cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  // 5a. Process-level kill — READ-FIRST, KILL-SECOND (MCP-PROTECT-003)
  // Canonical _rune_kill_tree applies full MCP/LSP/connector classification (40+ MCP binaries,
  // --stdio/--lsp/--sse transport markers, connector patterns). Single call performs
  // SIGTERM → 5s grace → SIGKILL on teammate survivors only.
  Bash(`source "${RUNE_PLUGIN_ROOT}/scripts/lib/process-tree.sh" && _rune_kill_tree "$PPID" "2stage" "5" "teammates" "${teamName}"`)
  // 5b. Filesystem cleanup
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}
```

## STEP 4: Parse VERDICT and Update Checkpoint

```javascript
// VERDICT.md missing guard
let verdictContent
try {
  verdictContent = Read(`tmp/arc/${id}/inspect/VERDICT.md`)
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

// P1 Fixability Assessment: classify P1 findings before passing to inspect_fix
// Design/architecture findings are downgraded to P2 since gap-fixer cannot
// meaningfully resolve them without full business context.
let adjustedP1Count = p1Markers
if (p1Markers > 0) {
  // Parse P1 findings from VERDICT.md
  const p1Regex = /- \[ \] \*\*\[(\w+-\d+)\] (.+?)\*\*.+?\n\s+- \*\*Category:\*\* (\w+)/g
  let match
  const downgrades = []
  while ((match = p1Regex.exec(verdictContent)) !== null) {
    const [, findingId, title, category] = match
    // Design and architectural findings are not auto-fixable
    if (['architectural', 'design', 'maintainability', 'documentation', 'observability'].includes(category)) {
      downgrades.push({ id: findingId, title, category, reason: 'design decision — not auto-fixable' })
    }
  }
  if (downgrades.length > 0) {
    adjustedP1Count = Math.max(0, p1Markers - downgrades.length)
    for (const d of downgrades) {
      warn(`Inspect: Downgraded ${d.id} from P1 to P2 (${d.reason})`)
    }
    log(`Inspect P1 fixability: ${p1Markers} raw → ${adjustedP1Count} fixable (${downgrades.length} downgraded)`)
  }
}

// v3.0.0-alpha.6: do NOT mark inspect as 'completed' here yet — STEP 5 (Fix)
// and STEP 6 (Convergence) still run in this same phase invocation. Record
// the intermediate verdict so subsequent steps can read it; status stays
// 'in_progress' until STEP 6 finalizes (converge/halt) or resets to 'pending'
// (retry).
updateCheckpoint({
  phase: 'inspect', status: 'in_progress', phase_sequence: 5.9,
  artifact: `tmp/arc/${id}/inspect/VERDICT.md`,
  artifact_hash: sha256(verdictContent),
  completion_pct: completionPct,
  p1_count: adjustedP1Count,
  p1_raw_count: p1Markers,
  verdict: inspectVerdict,
})
```

**Intermediate output**: `tmp/arc/{id}/inspect/VERDICT.md` — unified VERDICT.md with completion %, dimension scores, gap classification. STEP 5 (Fix) reads this; STEP 6 (Convergence) evaluates it.

**Failure policy (audit half)**: Non-blocking. Missing VERDICT skips STEP 5 fix and treats convergence as "halt" with null metrics. Individual inspector timeouts produce partial findings — verdict-binder aggregates whatever is available.

## STEP 4.5: Halt Decision Gate (absorbed gap_analysis STEP D)

<!-- v3.0.0-alpha.7 (Day 6): Absorbed from the retired gap_analysis phase's STEP D. -->
<!-- HIGHEST semantic risk in this phase — STEP D.0 Task Completion Gate (PR #310 fix) -->
<!-- and STEP D.7 plan writeback are both load-bearing. Full algorithm in -->
<!-- inspect-step-d-halt-gate.md (sub-reference). DO NOT INLINE the error() call -->
<!-- in a try/catch — it is the non-bypassable mechanism that prevents the -->
<!-- "40% shipped" bug class. -->

Read and follow [inspect-step-d-halt-gate.md](inspect-step-d-halt-gate.md). It runs:

- STEP C aggregate (merges `tmp/arc/{id}/inspect/deterministic.md` from STEP A with
  the verdict from STEP 4 into `tmp/arc/{id}/inspect/UNIFIED.md`)
- STEP D-DISCIPLINE Spec Compliance Matrix (when plan has YAML `AC-*` blocks)
- STEP D.0 Task Completion Gate — non-bypassable 100% floor (PR #310 fix)
- STEP D.1-D.2 Quality Score Gate — halt_threshold=70
- STEP D.5 Halt — raises `error()` in non-headless mode when needsRemediation
- STEP D.6 Plan Drift Reassessment Gate — 40% MISSING triggers warning
- STEP D.7 Plan writeback — appends "Implementation Status" + DEFERRED tasks back to plan

On PASS, sets `checkpoint.phases.inspect.substate = 'halt_gate_done'` and the existing
STEP 5 below reads `checkpoint.phases.inspect.needs_remediation` to gate gap-fixer
dispatch. On halt in non-headless mode, the `error()` throws and terminates this run;
the user resumes via `/rune:arc --resume` after manual fixes.

```javascript
// Advance substate to "halt_gate" before invoking STEP D
updateCheckpoint({ phase: 'inspect', substate: 'halt_gate' })
// ... follow inspect-step-d-halt-gate.md ...
// On return: checkpoint.phases.inspect.needs_remediation is set,
//            checkpoint.phases.inspect.substate === 'halt_gate_done',
//            UNIFIED.md exists, plan file has Implementation Status appendix.
```

## STEP 5: Inspect Fix (absorbed inspect_fix)

<!-- v3.0.0-alpha.6: absorbed from the deleted arc-phase-inspect-fix.md (Day 5 C4c). -->
<!-- Conditional sub-step: reads the VERDICT.md just written, extracts FIXABLE -->
<!-- findings, spawns a separate gap-fixer team to apply targeted fixes. -->

```javascript
// Advance substate to "fix" — entering STEP 5 gap-fixer execution
updateCheckpoint({ phase: 'inspect', substate: 'fix' })

// Entry guard — skip if no verdict, verdict is READY, or VERDICT.md missing.
// v3.0.0-alpha.7 (Day 6) CORR-004 FIX: also consider Task Completion Gate signals
// from STEP 4.5 (inspect-step-d-halt-gate.md). When the 4-Inspector pass votes READY
// (high quality) but the absorbed STEP D detected missing plan tasks
// (needs_task_remediation: true), STEP 5 must still spawn gap-fixers to close the
// gap — otherwise the "no silent deferrals" invariant breaks in headless/CI mode
// (where the error() halt is suppressed but the deferred-tasks plan writeback already happened).
const needsRemediation = checkpoint.phases?.inspect?.needs_remediation === true
const needsTaskRemediation = checkpoint.phases?.inspect?.needs_task_remediation === true
const fixSkipReason = (
  !verdictContent                                          ? 'no_verdict' :
  (inspectVerdict === 'READY' && !needsRemediation && !needsTaskRemediation) ? 'verdict_ready_no_remediation_needed' :
  null
)

if (fixSkipReason) {
  log(`Phase 5.9 STEP 5 (inspect_fix): skipping — ${fixSkipReason}`)
} else {
  // ── STEP 5.1: Extract FIXABLE Findings ──
  // Parse VERDICT.md for FIXABLE gaps. Gap categories: correctness, coverage,
  // test, observability, security, operational, performance, maintainability,
  // wiring (WIRE- prefix; NOT auto-fixable — excluded by fixable="true" filter).
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
  }).filter(g => g.file)

  // AC-6.1.1: Skip findings classified as false positives or intentional deviations
  const FP_CLASSIFICATIONS = [
    'FP_INSPECTOR_ERROR', 'FP_AMBIGUOUS_AC',
    'DEVIATED_INTENTIONAL', 'DEVIATED_SUPERSEDED', 'MISSING_EXCLUDED',
  ]
  const reclassifiedGaps = allParsedGaps.filter(g =>
    g.classification && (g.classification.startsWith('FP_') || FP_CLASSIFICATIONS.includes(g.classification)))
  const fixableGaps = allParsedGaps.filter(g =>
    !g.classification || (!g.classification.startsWith('FP_') && !FP_CLASSIFICATIONS.includes(g.classification)))
  const reclassifiedCount = reclassifiedGaps.length
  const maxFixes = 20  // v3.x: inspect.max_fixes baked from former talisman.inspect

  let fixedCount = 0
  let deferredCount = 0

  if (fixableGaps.length === 0) {
    const earlyDeferredCount = Math.max(0, gapMarkers.length - reclassifiedCount)
    warn(`Phase 5.9 STEP 5: No FIXABLE gaps — ${reclassifiedCount} reclassified, ${earlyDeferredCount} deferred`)
    deferredCount = earlyDeferredCount
  } else {
    // ── STEP 5.2: Group by File and Spawn Fixers ──
    const capsFixable = fixableGaps.slice(0, maxFixes)
    deferredCount = fixableGaps.length - capsFixable.length + (gapMarkers.length - fixableGaps.length - reclassifiedCount)

    const gapsByFile = {}
    for (const gap of capsFixable) {
      if (!gapsByFile[gap.file]) gapsByFile[gap.file] = []
      gapsByFile[gap.file].push(gap)
    }

    const fixTeamName = `arc-inspect-fix-${id}`

    // v3.0.0-alpha.7 (Day 6) CORR-009 FIX: Write SEC-GAP-001 state file BEFORE TeamCreate.
    // The validate-gap-fixer-paths.sh PreToolUse hook detects active gap-fix workflows by
    // globbing tmp/.rune-gap-fix-*.json with status="active". Without this file, the hook
    // fails open and gap-fixer agents spawned by arc bypass the .claude/, .env, .github/,
    // node_modules/, CI YAML path restrictions. The standalone /rune:inspect skill writes
    // this file already; previously the arc path silently skipped it.
    // Includes Rune Session Isolation Rule fields (config_dir + owner_pid + session_id).
    const _chome = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
    const _ppid = Bash("echo $PPID").trim()
    Write(`tmp/.rune-gap-fix-${id}.json`, JSON.stringify({
      status: "active",
      arc_id: id,
      team_name: fixTeamName,
      config_dir: _chome,
      owner_pid: parseInt(_ppid, 10),
      session_id: process?.env?.CLAUDE_SESSION_ID ?? null,
      started_at: new Date().toISOString(),
    }, null, 2))

    TeamCreate({ team_name: fixTeamName })

    try {
    const fixerNames = []
    let fixerIdx = 0
    for (const [file, gaps] of Object.entries(gapsByFile)) {
      const fixerName = `gap-fixer-${fixerIdx++}`
      fixerNames.push(fixerName)
      TaskCreate({
        subject: `${fixerName}: fix ${gaps.length} gaps in ${file}`,
        description: `Fix FIXABLE gaps in ${file}. Gap IDs: ${gaps.map(g => g.gap_id).join(', ')}. Each fix gets its own atomic commit: fix(inspect): [{GAP-ID}]. Read tmp/arc/${id}/inspect/VERDICT.md for full gap context.`,
      })
      Agent({
        team_name: fixTeamName,
        name: fixerName,
        subagent_type: 'rune:work:gap-fixer',
        prompt: `You are gap-fixer for inspect remediation. Fix these FIXABLE gaps in ${file}:\n${gaps.map(g => `- [${g.gap_id}] (${g.category}): ${g.description}`).join('\n')}\n\nRead tmp/arc/${id}/inspect/VERDICT.md for full context. Apply minimal, targeted fixes. Each fix gets its own atomic commit: fix(inspect): [${gaps[0].gap_id}]. Claim your task via TaskList + TaskUpdate (status: completed) when done.`,
      })
    }

    waitForCompletion(fixTeamName, fixerNames.length, { timeoutMs: 600_000, pollIntervalMs: 30_000 })

    } catch (e) {
      warn(`inspect-fix team timed out / failed: ${e.message}`)
      throw e
    } finally {
    // ── STEP 5.3: Cleanup fix team (CLEAN-002 finally block) ──
    // Always runs — even on timeout/exception. Same 5-component standard cleanup
    // pattern as STEP 3.5 above. Dynamic member discovery with fallback to spawned
    // fixer names. Force-reply + adaptive grace + TeamDelete retry-with-backoff +
    // filesystem fallback.
    let fixAllMembers = []
    try {
      const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
      const fixTeamConfig = JSON.parse(Read(`${CHOME}/teams/${fixTeamName}/config.json`))
      const fixMembers = Array.isArray(fixTeamConfig.members) ? fixTeamConfig.members : []
      fixAllMembers = fixMembers.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
    } catch (e) {
      fixAllMembers = (fixerNames.length > 0)
        ? fixerNames
        : Array.from({ length: Math.max(1, maxFixes) }, (_, i) => `gap-fixer-${i}`)
    }
    const fixAliveMembers = []
    for (const member of fixAllMembers) {
      try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); fixAliveMembers.push(member) } catch (e) {}
    }
    if (fixAliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }
    let fixConfirmedAlive = 0
    for (const member of fixAliveMembers) {
      try { SendMessage({ type: "shutdown_request", recipient: member, content: "Inspect-fix complete" }); fixConfirmedAlive++ } catch (e) {}
    }
    if (fixConfirmedAlive > 0) {
      Bash(`sleep ${Math.min(20, Math.max(5, fixConfirmedAlive * 5))}`, { run_in_background: true })
    } else {
      Bash("sleep 2", { run_in_background: true })
    }
    let fixCleanupTeamDeleteSucceeded = false
    const FIX_CLEANUP_DELAYS = [0, 3000, 6000, 10000]
    for (let attempt = 0; attempt < FIX_CLEANUP_DELAYS.length; attempt++) {
      if (attempt > 0) Bash(`sleep ${FIX_CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
      try { TeamDelete(); fixCleanupTeamDeleteSucceeded = true; break } catch (e) {
        if (attempt === FIX_CLEANUP_DELAYS.length - 1) warn(`inspect-fix cleanup: TeamDelete failed after ${FIX_CLEANUP_DELAYS.length} attempts`)
      }
    }
    if (!fixCleanupTeamDeleteSucceeded) {
      Bash(`source "${RUNE_PLUGIN_ROOT}/scripts/lib/process-tree.sh" && _rune_kill_tree "$PPID" "2stage" "5" "teammates" "${fixTeamName}"`)
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${fixTeamName}/" "$CHOME/tasks/${fixTeamName}/" 2>/dev/null`)
      try { TeamDelete() } catch (e) { /* best effort */ }
    }

    // v3.0.0-alpha.7 (Day 6) CORR-009 FIX: Remove SEC-GAP-001 state file in the
    // finally block — must run on success AND on cleanup-after-failure paths so the
    // PreToolUse hook stops gating writes after the fix team has dispersed.
    Bash(`rm -f "tmp/.rune-gap-fix-${id}.json" 2>/dev/null`)
    } // end finally

    // ── STEP 5.4: Count fix results ──
    const fixCommits = Bash(`git log --oneline --since="30 minutes ago" --grep="fix(inspect):" | wc -l`).trim()
    fixedCount = parseInt(fixCommits, 10) || 0

    // Write inspect-fix-report.md (consumer: humans + post-arc review)
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
      ...(reclassifiedCount > 0 ? [
        '## Reclassified (False Positive)',
        '',
        'The following findings were skipped — classified as false positives or intentional deviations:',
        '',
        ...reclassifiedGaps.map(g => `- [${g.gap_id}] ${g.category}: ${g.description} → \`${g.classification}\``),
      ] : []),
    ].join('\n')
    Write(`tmp/arc/${id}/inspect-fix-report.md`, reportContent)
  }

  // Stash fix counts in checkpoint for STEP 6 convergence evaluator
  updateCheckpoint({
    phase: 'inspect', status: 'in_progress', phase_sequence: 5.9,
    inspect_fixed_count: fixedCount,
    inspect_deferred_count: deferredCount,
    inspect_reclassified_count: reclassifiedCount,
  })
}

// ── STEP 6: Convergence Evaluation (absorbed verify_inspect) ──
// Advance substate to "convergence" — entering STEP 6 convergence eval
updateCheckpoint({ phase: 'inspect', substate: 'convergence' })
// Decides whether to converge (move on to code_review), retry (loop back),
// or halt (give up gracefully).

const inspectRoundForEval = checkpoint.inspect_convergence?.round ?? 0
const maxRounds = checkpoint.inspect_convergence?.max_rounds ?? 2
const threshold = checkpoint.inspect_convergence?.threshold ?? 95
const evalFixedCount = checkpoint.phases.inspect?.inspect_fixed_count ?? 0
const evalDeferredCount = checkpoint.phases.inspect?.inspect_deferred_count ?? 0

function evaluateInspectConvergence(completionPct, p1Count, fixedCount, inspectRound, maxRounds, threshold) {
  // Gate 1: Completion threshold met AND no P1 findings → converge
  if (completionPct >= threshold && p1Count === 0) return 'converge'
  // Gate 2: Max rounds exceeded → halt
  if (inspectRound + 1 >= maxRounds) return 'halt'
  // Gate 3: No progress in this round (0 fixes after the first round) → halt
  if (fixedCount === 0 && inspectRound > 0) return 'halt'
  // Default: retry
  return 'retry'
}

const convergenceVerdict = evaluateInspectConvergence(
  completionPct ?? 0, adjustedP1Count, evalFixedCount, inspectRoundForEval, maxRounds, threshold
)

checkpoint.inspect_convergence = checkpoint.inspect_convergence ?? { round: 0, history: [], max_rounds: maxRounds, threshold }
checkpoint.inspect_convergence.history.push({
  round: inspectRoundForEval,
  completion_pct: completionPct,
  p1_count: adjustedP1Count,
  fixed_count: evalFixedCount,
  deferred_count: evalDeferredCount,
  verdict: convergenceVerdict,
  timestamp: new Date().toISOString(),
})

if (convergenceVerdict === 'retry') {
  // ── STEP 6.1: Build progressive focus scope for next round ──
  const remainingGaps = verdictContent.match(/<!-- GAP:[^>]*-->/g) || []
  const focusResult = {
    round: inspectRoundForEval + 1,
    remaining_gap_count: remainingGaps.length,
    focused_diff: Bash(`git diff ${defaultBranch}...HEAD`),
  }
  const nextRound = inspectRoundForEval + 1
  Write(`tmp/arc/${id}/inspect-focus-round-${nextRound}.json`, JSON.stringify(focusResult))
  checkpoint.inspect_convergence.round = nextRound

  // Budget exhaustion guard — convergence rounds * per-round timeout.
  // PHASE_TIMEOUTS.inspect already covers audit + fix + eval (15+15+4 = 34 min).
  const cycleBudget = PHASE_TIMEOUTS.inspect
  const elapsedBudget = checkpoint.inspect_convergence.history.length * cycleBudget
  if (elapsedBudget > cycleBudget * maxRounds) {
    warn(`Inspect convergence budget exhausted after ${inspectRoundForEval + 1} rounds — halting`)
    checkpoint.inspect_convergence.history[checkpoint.inspect_convergence.history.length - 1].verdict = 'halt'
    checkpoint.inspect_convergence.history[checkpoint.inspect_convergence.history.length - 1].reason = 'budget_exhausted'
    updateCheckpoint({ phase: 'inspect', status: 'completed', phase_sequence: 5.9 })
    return
  }

  // ── STEP 6.2: Reset inspect to 'pending' so the dispatcher loops back ──
  // With inspect_fix and verify_inspect absorbed in v3.0.0-alpha.6, we only
  // reset the single 'inspect' phase. The dispatcher's "first pending in
  // PHASE_ORDER" scan re-enters this file from STEP 1 with a higher round.
  checkpoint.phases.inspect.status = 'pending'
  checkpoint.phases.inspect.artifact = null
  checkpoint.phases.inspect.artifact_hash = null
  checkpoint.phases.inspect.team_name = null
  checkpoint.phases.inspect.completion_pct = null
  checkpoint.phases.inspect.p1_count = null
  checkpoint.phases.inspect.verdict = null
  checkpoint.phases.inspect.inspect_fixed_count = null
  checkpoint.phases.inspect.inspect_deferred_count = null
  checkpoint.phases.inspect.inspect_reclassified_count = null

  updateCheckpoint(checkpoint)
  return  // Dispatcher will re-enter the inspect phase next turn.
} else if (convergenceVerdict === 'halt') {
  warn(`Inspect convergence halted after ${inspectRoundForEval + 1} cycle(s): ${completionPct}% complete, ${adjustedP1Count} P1 findings remain. Proceeding to code_review.`)
  updateCheckpoint({
    phase: 'inspect', status: 'completed', phase_sequence: 5.9,
    artifact: `tmp/arc/${id}/inspect/VERDICT.md`,
    artifact_hash: sha256(verdictContent),
    substate: null,  // clear substate on completion
  })
} else {
  // 'converge'
  updateCheckpoint({
    phase: 'inspect', status: 'completed', phase_sequence: 5.9,
    artifact: `tmp/arc/${id}/inspect/VERDICT.md`,
    artifact_hash: sha256(verdictContent),
    substate: null,  // clear substate on completion
  })
}
```

**Final output**: `tmp/arc/{id}/inspect/VERDICT.md` (always present once STEP 4 succeeds); `tmp/arc/{id}/inspect-fix-report.md` (when STEP 5 ran with fixable gaps); per-round focus JSONs `tmp/arc/{id}/inspect-focus-round-N.json` (on retry).

**Failure policy (whole phase)**: Non-blocking. Halting after the convergence-budget guard or max-rounds gate proceeds to code_review with a warning. The convergence gate never blocks the pipeline permanently; it either retries or gives up gracefully.

---

## Agent Completion Contract (v2.58.0+, ARC-QA-001/002)

Agents spawned by this phase MUST follow the durable-first completion contract. Inject into every agent spawn prompt:

```
COMPLETION CONTRACT (mandatory — ARC-QA-001):
When your task is complete, you MUST do ALL THREE:
1. Write your artifact to its canonical path (e.g., tmp/arc/{id}/{agent}-findings.md)
2. Write a sentinel to tmp/arc/{id}/.done/{your-agent-name}.done with a one-line JSON payload:
   {"agent":"{your-name}","status":"completed","verdict_path":"<artifact-path>","timestamp":"<ISO8601 UTC>"}
3. Call TaskUpdate(status:"completed") AND SendMessage to team-lead

The sentinel (step 2) is the primary completion signal — survives TeamDelete. Steps 1 and 3
are required for downstream consumers but the leader polls step 2 (ARC-QA-001 Sentinel check).

Do NOT skip step 2 even if you completed steps 1 and 3.
```

See `roundtable-circle/references/monitor-utility.md` `countCompletedAgents()` for the leader-side fusion protocol.
