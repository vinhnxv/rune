# Phase 8.5: Pre-Ship Completion Validator — Full Algorithm

Zero-LLM-cost dual-gate completion check before PR creation. Orchestrator-only — no team, no agents.

**Team**: None (orchestrator-only)
**Tools**: Read, Write, Grep
**Timeout**: Max 30_000 ms (30 seconds)

**Inputs**:
- `checkpoint` — arc checkpoint object (phases, convergence, stagnation)
- `planPath` — validated path to plan file (acceptance criteria source)

**Outputs**:
- Return value: `report` object with `{ gates, verdict, diagnostics }`
- Artifact: `tmp/arc/{id}/pre-ship-report.md`

**Preconditions**: Phase 7.7 TEST completed (or skipped). Ship phase not yet started.

**Error handling**: Missing artifacts → WARN (not BLOCK). Validator internal failure → proceed to ship with warning. Non-critical gate failures never halt the pipeline.

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, `warn()`, `log()`, and `Read()`/`Write()` are dispatcher-provided utilities available in the arc orchestrator context.

## Algorithm

```javascript
function preShipValidator(checkpoint, planPath) {
  const report = { gates: [], verdict: "PASS", diagnostics: [] }

  // ════════════════════════════════════════════
  // GATE 1: Artifact Integrity (deterministic)
  // ════════════════════════════════════════════
  //
  // Verifies that critical upstream phase artifacts:
  //   1. Come from completed (not skipped/failed) phases
  //   2. Still exist on disk
  //   3. Have not been tampered with (hash check)
  //
  // CONCERN-2: Hash mismatch → BLOCK (not WARN).
  // A tampered artifact is a security concern — the pre-ship
  // validator has a different threat model than stagnation sentinel.
  // Stagnation is about loop detection; artifact integrity is about
  // trust in the pipeline's prior work.

  const REQUIRED_ARTIFACTS = [
    { phase: "work",        description: "Work summary"     },
    { phase: "code_review", description: "Code review TOME" }
  ]

  for (const req of REQUIRED_ARTIFACTS) {
    const phaseData = checkpoint.phases[req.phase]

    if (!phaseData || phaseData.status === "skipped") {
      report.gates.push({ gate: "artifact", item: req.description, status: "SKIPPED" })
      continue
    }

    if (phaseData.status !== "completed") {
      report.gates.push({
        gate: "artifact",
        item: req.description,
        status: "FAIL",
        reason: `status=${phaseData.status}`
      })
      report.diagnostics.push(`${req.description}: phase not completed (${phaseData.status})`)
      continue
    }

    if (phaseData.artifact) {
      const artifactExists = exists(phaseData.artifact)
      if (!artifactExists) {
        report.gates.push({
          gate: "artifact",
          item: req.description,
          status: "FAIL",
          reason: "artifact file missing"
        })
        report.diagnostics.push(`${req.description}: artifact file not found at ${phaseData.artifact}`)
        continue
      }

      if (phaseData.artifact_hash) {
        const content = Read(phaseData.artifact)
        const currentHash = sha256(content)
        if (currentHash !== phaseData.artifact_hash) {
          // CONCERN-2: BLOCK on hash mismatch — tampered artifact is security concern
          report.gates.push({
            gate: "artifact",
            item: req.description,
            status: "BLOCK",
            reason: "hash mismatch — artifact modified after phase completion (tampered?)"
          })
          report.diagnostics.push(`${req.description}: artifact hash mismatch — possible tampering`)
        } else {
          report.gates.push({ gate: "artifact", item: req.description, status: "PASS" })
        }
      } else {
        // No hash stored — existence check is sufficient
        report.gates.push({ gate: "artifact", item: req.description, status: "PASS" })
      }
    } else {
      // Phase completed but no artifact path stored — treat as PASS
      report.gates.push({ gate: "artifact", item: req.description, status: "PASS" })
    }
  }

  // ════════════════════════════════════════════
  // GATE 2: Quality Signals (heuristic)
  // ════════════════════════════════════════════
  //
  // 2a: Acceptance Criteria completion ratio from plan checkboxes
  // 2b: Test phase exit status
  // 2c: Unresolved P1 findings from last convergence round
  // 2d: Stagnation sentinel warnings (repeating errors + stagnant files)
  //
  // None of these are hard BLOCK conditions — they are WARNs that
  // surface in the PR body as "Pre-Ship Warnings".

  // ── 2a: Acceptance Criteria ──
  try {
    const planContent = Read(planPath)
    const acLines = planContent.match(/^- \[[ x]\] .+$/gm) || []
    const totalAC = acLines.length
    const completedAC = acLines.filter(l => l.startsWith('- [x]')).length
    const acRatio = totalAC > 0 ? completedAC / totalAC : 1.0

    // Thresholds: >=80% = PASS, 50-79% = WARN, <50% = FAIL (non-blocking)
    const acStatus = acRatio >= 0.8 ? "PASS" : acRatio >= 0.5 ? "WARN" : "FAIL"
    report.gates.push({
      gate: "acceptance_criteria",
      status: acStatus,
      detail: `${completedAC}/${totalAC} criteria marked complete (${Math.round(acRatio * 100)}%)`
    })
    if (acRatio < 0.5) {
      report.diagnostics.push(`Acceptance criteria: only ${completedAC}/${totalAC} complete`)
    }
  } catch (e) {
    report.gates.push({ gate: "acceptance_criteria", status: "WARN", reason: "plan file unreadable" })
  }

  // ── 2a.5: Task Completion Gate (v1.169.0 — BLOCKING) ──
  // Reads task completion data from gap_analysis checkpoint.
  // This is a HARD BLOCK — unlike acceptance criteria (advisory), task completion
  // below floor prevents ship. Added after PR #310 shipped with 40% completion.
  const gapPhase = checkpoint.phases?.gap_analysis
  if (gapPhase && gapPhase.task_completion_pct !== undefined) {
    const taskPct = gapPhase.task_completion_pct
    const taskFloor = gapPhase.task_completion_floor ?? 100
    const taskTotal = gapPhase.total_tasks ?? 0
    const taskDone = gapPhase.completed_tasks ?? 0
    const missingTasks = gapPhase.missing_tasks ?? []

    if (taskTotal > 0 && taskPct < taskFloor) {
      report.gates.push({
        gate: "task_completion",
        status: "BLOCK",
        detail: `${taskDone}/${taskTotal} tasks addressed (${taskPct}%) — below floor of ${taskFloor}%`
      })
      report.diagnostics.push(
        `Task completion: ${taskDone}/${taskTotal} (${taskPct}%) — BLOCKS ship (floor: ${taskFloor}%)`,
        ...missingTasks.slice(0, 5).map(t => `  Missing: Task ${t.id} — ${t.title}`)
      )
    } else {
      report.gates.push({
        gate: "task_completion",
        status: "PASS",
        detail: `${taskDone}/${taskTotal} tasks addressed (${taskPct}%)`
      })
    }
  }

  // ── 2b: Test Phase Status ──
  const testPhase = checkpoint.phases?.test
  if (testPhase) {
    if (testPhase.status === "completed") {
      report.gates.push({ gate: "tests", status: "PASS" })
    } else if (testPhase.status === "skipped") {
      report.gates.push({ gate: "tests", status: "WARN", reason: "test phase skipped" })
    } else {
      report.gates.push({ gate: "tests", status: "FAIL", reason: `test phase ${testPhase.status}` })
      report.diagnostics.push(`Tests: phase not completed (${testPhase.status})`)
    }
  }
  // If testPhase is absent entirely: no gate entry (phase not in pipeline variant)

  // ── 2c: Unresolved P1 Findings ──
  // CONCERN-3: Use checkpoint.convergence.history[round] finding counts
  // (per-round TOME files are unavailable — use history array instead)
  const convergence = checkpoint.convergence
  if (convergence?.history?.length > 0) {
    const lastRound = convergence.history[convergence.history.length - 1]
    const p1Remaining = lastRound.p1_remaining ?? 0
    if (p1Remaining > 0) {
      report.gates.push({
        gate: "p1_findings",
        status: "WARN",
        detail: `${p1Remaining} P1 findings unresolved after ${convergence.history.length} mend round(s)`
      })
      report.diagnostics.push(`P1 findings: ${p1Remaining} unresolved`)
    } else {
      report.gates.push({ gate: "p1_findings", status: "PASS", detail: "0 P1 findings" })
    }
  }

  // ── 2d: Stagnation Sentinel Warnings ──
  // Only runs if checkpoint.stagnation exists (stagnation sentinel was active)
  const stagnation = checkpoint.stagnation
  if (stagnation) {
    const repeatingErrors = stagnation.error_patterns?.filter(p => p.occurrences >= 3) || []
    const stagnantFiles  = stagnation.file_velocity?.filter(v => v.velocity === "stagnant") || []

    if (repeatingErrors.length > 0 || stagnantFiles.length > 0) {
      report.gates.push({
        gate: "stagnation",
        status: "WARN",
        detail: `${repeatingErrors.length} repeating error(s), ${stagnantFiles.length} stagnant file(s)`
      })
      report.diagnostics.push(
        `Stagnation sentinel: ${repeatingErrors.length} repeating error(s), ${stagnantFiles.length} stagnant file(s)`
      )
    } else {
      report.gates.push({ gate: "stagnation", status: "PASS" })
    }
  }

  // ════════════════════════════════════════════
  // GATE 3: Discipline Metrics (advisory, v1.171.0+)
  // ════════════════════════════════════════════
  //
  // Computes Spec Compliance Rate (SCR) and proof coverage from evidence
  // artifacts. Advisory for initial rollout — WARN only, never BLOCK.
  // Gated by talisman discipline.enabled (default: true).

  // readTalismanSection: "discipline"
  const disciplineConfig = readTalismanSection("discipline") ?? {}
  if (disciplineConfig.enabled !== false) {
    try {
      // Look for metrics artifact from work phase convergence
      const metricsPath = Glob("tmp/work/*/convergence/metrics.json").sort().pop()
      if (metricsPath) {
        const metrics = JSON.parse(Read(metricsPath))
        const scr = metrics?.metrics?.scr?.value ?? metrics?.SCR ?? null
        const proofCov = metrics?.metrics?.proof_coverage?.value ?? metrics?.proof_coverage ?? null

        if (scr !== null) {
          const scrThreshold = disciplineConfig.scr_threshold ?? 0.95
          const scrStatus = scr >= scrThreshold ? "PASS" : "WARN"
          report.gates.push({
            gate: "discipline_scr",
            status: scrStatus,
            detail: `Spec Compliance Rate: ${Math.round(scr * 100)}% (threshold: ${Math.round(scrThreshold * 100)}%)`
          })
          if (scrStatus === "WARN") {
            report.diagnostics.push(`Discipline SCR: ${Math.round(scr * 100)}% below threshold ${Math.round(scrThreshold * 100)}%`)
          }
        }

        if (proofCov !== null) {
          const covStatus = proofCov >= 0.8 ? "PASS" : "WARN"
          report.gates.push({
            gate: "discipline_proof_coverage",
            status: covStatus,
            detail: `Machine proof coverage: ${Math.round(proofCov * 100)}%`
          })
        }
      }
      // No metrics artifact = discipline work loop didn't run (plan without criteria) → skip gate
    } catch (e) {
      // Metrics parse error → skip discipline gate (non-blocking)
      warn(`Discipline metrics gate: ${e.message}`)
    }
  }

  // ════════════════════════════════════════════
  // GATE 4: Invocability Check (anti-dead-code, v2.9.0)
  // ════════════════════════════════════════════
  //
  // Verifies that commands/features mentioned in acceptance criteria
  // are actually invocable by the user (have routing entries).
  // Severity: WARN (not BLOCK) — will be promoted to BLOCK after validation.

  const planContent = Read(planPath)
  // Match both numbered (1. [ ]) and dash (- [ ]) AC formats
  const acLines = planContent.match(/^(?:\d+\.|-)\s*\[.\]\s*.+$/gm) || []

  const COMMAND_PATTERN = /\/rune:[a-z:-]+(?:\s+[a-z]+)?|`[a-z_-]+\.sh`/gi
  const referencedCommands = []
  for (const ac of acLines) {
    const matches = ac.match(COMMAND_PATTERN) || []
    referencedCommands.push(...matches)
  }

  if (referencedCommands.length > 0) {
    const missingRoutes = []
    for (const cmd of referencedCommands) {
      const cleanCmd = cmd.replace(/^\/rune:/, '').replace(/`/g, '').trim()
      const parts = cleanCmd.split(/\s+/)
      if (parts.length >= 1) {
        const skill = parts[0]
        const subcommand = parts[1] || null
        const skillFiles = Glob(`plugins/rune/skills/${skill}/SKILL.md`)
        if (skillFiles.length === 0) {
          // Skill directory doesn't exist — command is completely unwired
          missingRoutes.push(subcommand ? `${skill} ${subcommand}` : skill)
        } else if (subcommand) {
          const skillContent = Read(skillFiles[0])
          if (!skillContent.includes(subcommand)) {
            missingRoutes.push(`${skill} ${subcommand}`)
          }
        }
      }
    }

    if (missingRoutes.length > 0) {
      report.gates.push({
        gate: "invocability",
        item: "Command routing completeness",
        status: "WARN",
        reason: `${missingRoutes.length} commands from ACs not found in routing: ${missingRoutes.join(', ')}`
      })
      report.diagnostics.push(`DEAD CODE RISK: ${missingRoutes.join(', ')} — mentioned in ACs but not wired`)
    } else {
      report.gates.push({ gate: "invocability", item: "Command routing completeness", status: "PASS" })
    }
  }

  // ════════════════════════════════════════════
  // VERDICT: Aggregate gates
  // ════════════════════════════════════════════
  //
  // BLOCK: Any Gate 1 BLOCK (artifact integrity compromised — hash mismatch)
  //        Any Gate 1 FAIL  (artifact missing or phase not completed)
  // WARN:  Any Gate 2 WARN or FAIL (quality signal degraded — non-blocking)
  // PASS:  All gates PASS or SKIPPED

  const hasBlock = report.gates.some(g => g.status === "BLOCK")
  const hasFail  = report.gates.some(g => g.status === "FAIL" && g.gate === "artifact")
  const hasWarn  = report.gates.some(g => g.status === "WARN" || (g.status === "FAIL" && g.gate !== "artifact"))

  // v1.169.0: task_completion BLOCK now halts the pipeline (not just advisory).
  // This is the second line of defense after gap_analysis STEP D.0.
  report.verdict = hasBlock || hasFail ? "BLOCK" : hasWarn ? "WARN" : "PASS"

  // ════════════════════════════════════════════
  // PROOF MANIFEST GENERATION (Discipline Integration, v1.173.0)
  // ════════════════════════════════════════════
  //
  // Generate a proof manifest summarizing per-criterion status with evidence references.
  // This reuses SCR computation from GATE 3 (discipline metrics) and adds evidence paths.
  // The manifest is persisted at ship/merge (Phase 9/9.5) as a PR comment.
  //
  // Manifest captures:
  // 1. Plan file path and criteria count
  // 2. Per-criterion status (PASS/FAIL/UNTESTED) with evidence file references
  // 3. Spec Compliance Rate (SCR)
  // 4. Failure codes encountered and recovery actions taken
  // 5. Convergence iteration count
  // 6. Timestamp and pipeline run ID
  try {
    const scm = checkpoint.spec_compliance_matrix ?? {}
    const convergence = checkpoint.convergence ?? {}
    // Resolve evidence directory from work phase checkpoint (avoid glob in manifest)
    const workPhase = checkpoint.phases?.work
    const workTimestamp = workPhase?.artifact?.match(/tmp\/arc\/([^/]+)\//)?.[1] || checkpoint.id
    const evidenceDir = `tmp/work/${workTimestamp}/evidence/`

    const manifest = {
      plan_file: checkpoint.plan_file,
      arc_id: checkpoint.id,
      timestamp: new Date().toISOString(),
      criteria_count: scm.total ?? 0,
      scr: scm.scr ?? null,
      convergence_rounds: convergence.round ?? 0,
      per_criterion_status: scm,  // GREEN/YELLOW/RED breakdown
      evidence_directory: evidenceDir,
      verdict: report.verdict
    }
    Write(`tmp/arc/${checkpoint.id}/proof-manifest.json`, JSON.stringify(manifest, null, 2))
    report.proof_manifest_path = `tmp/arc/${checkpoint.id}/proof-manifest.json`
  } catch (e) {
    warn(`Proof manifest generation failed: ${e.message} — non-blocking`)
  }

  // ── Write report ──
  const reportContent = formatPreShipReport(report)
  Write(`tmp/arc/${checkpoint.id}/pre-ship-report.md`, reportContent)

  return report
}

// ════════════════════════════════════════════
// REPORT FORMATTER
// ════════════════════════════════════════════

function formatPreShipReport(report) {
  const gateTable = [
    `| Gate | Item | Status | Detail |`,
    `|------|------|--------|--------|`,
    ...report.gates.map(g =>
      `| ${g.gate} | ${g.item ?? '—'} | ${g.status} | ${g.reason ?? g.detail ?? '—'} |`
    )
  ].join('\n')

  const diagSection = report.diagnostics.length > 0
    ? `\n## Diagnostics\n\n` + report.diagnostics.map(d => `- ${d}`).join('\n')
    : '\n## Diagnostics\n\nNone.'

  return `# Pre-Ship Validation Report

**Verdict**: ${report.verdict}
**Checked at**: ${new Date().toISOString()}

## Gate Results

${gateTable}
${diagSection}
`
}
```

## Verdict Decision Matrix

| Condition | Verdict | Action in Ship Phase |
|-----------|---------|----------------------|
| Any Gate 1 BLOCK (hash mismatch) | BLOCK | Append diagnostics to PR body as "Known Issues" |
| Any Gate 1 FAIL (artifact missing/phase failed) | BLOCK | Append diagnostics to PR body as "Known Issues" |
| Any Gate 2 WARN or non-artifact FAIL | WARN | Append diagnostics to PR body as "Pre-Ship Warnings" |
| All gates PASS or SKIPPED | PASS | No extra PR body content |

**Halting contract** (v1.169.0 — changed from non-halting):
- **BLOCK from `task_completion` gate**: HALTS the pipeline. Task completion below floor is a hard stop — ship phase will NOT proceed. This prevents shipping fundamentally incomplete implementations (PR #310 incident).
- **BLOCK from `artifact` gate**: HALTS the pipeline. Artifact integrity (hash mismatch) is a security stop.
- **WARN/FAIL from other gates**: Non-halting. Quality signals are injected into PR body for visibility.
- Previously (pre-v1.169.0), the validator never halted. This was changed after PR #310 shipped with 40% plan completion because no gate in the pipeline could block ship.

## Ship Phase Integration

The integration point in arc SKILL.md:

```javascript
// Phase 8.5: Pre-Ship Completion Validator
// Runs between Phase 7.7 (TEST) and Phase 9 (SHIP)
const preShipResult = preShipValidator(checkpoint, checkpoint.plan_file)

updateCheckpoint({
  phase: "pre_ship_validation",
  status: preShipResult.verdict === "BLOCK" ? "failed" : "completed",
  artifact: `tmp/arc/${checkpoint.id}/pre-ship-report.md`
})

// BLOCK verdict: HALT the pipeline (v1.169.0 — previously "proceed with warning")
// DEEP-001 FIX: BLOCK must actually prevent ship, not just warn.
// This was the exact bug that shipped PR #310 at 40% completion.
if (preShipResult.verdict === "BLOCK") {
  const blockGates = preShipResult.gates.filter(g => g.status === "BLOCK")
  const blockReasons = blockGates.map(g => `${g.gate}: ${g.detail || g.reason}`).join("; ")

  error(
    `Pre-Ship Validator: BLOCK — pipeline halted.\n` +
    `Blocked by: ${blockReasons}\n` +
    `Report: tmp/arc/${checkpoint.id}/pre-ship-report.md\n\n` +
    preShipResult.diagnostics.map(d => `  - ${d}`).join('\n') + '\n\n' +
    `Fix the blocking issues and run /rune:arc --resume to continue.`
  )
  // error() halts execution — ship phase does NOT proceed
}

// Gate 2 WARN: Append diagnostics to PR body as "Pre-Ship Warnings" section
if (preShipResult.verdict === "WARN") {
  warn("Pre-Ship Validator: WARN — quality signals degraded")
  // Ship phase reads checkpoint.phases.pre_ship_validation and appends
  // preShipResult.diagnostics as "Pre-Ship Warnings" in PR body
}

// PASS: No extra PR body content — proceed silently
```

### PR Body Injection (in arc-phase-ship.md)

After building the base PR body, ship phase checks pre-ship validation results:

```javascript
// Read pre-ship validation result from checkpoint
const preShipPhase = checkpoint.phases?.pre_ship_validation
const preShipReportPath = `tmp/arc/${id}/pre-ship-report.md`

if (preShipPhase?.status === "failed" && exists(preShipReportPath)) {
  // BLOCK verdict: append as "Known Issues"
  const preShipReport = Read(preShipReportPath)
  prBody += `\n\n## Known Issues (Pre-Ship Validator)\n\n${preShipReport}`
} else if (preShipPhase?.status === "completed" && exists(preShipReportPath)) {
  // Read verdict from report to distinguish WARN from PASS
  const preShipReport = Read(preShipReportPath)
  if (preShipReport.includes('**Verdict**: WARN')) {
    prBody += `\n\n## Pre-Ship Warnings\n\n${preShipReport}`
  }
  // PASS: no injection
}
```

## Crash Recovery

Orchestrator-only phase with no team — minimal crash surface.

| Resource | Location |
|----------|----------|
| Pre-ship report | `tmp/arc/{id}/pre-ship-report.md` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "pre_ship_validation") |

Recovery: On `--resume`, if pre_ship_validation is `in_progress`, re-run from the beginning. The validator is idempotent — re-running overwrites the report file cleanly.

## Checkpoint Update

```javascript
updateCheckpoint({
  phase: "pre_ship_validation",
  status: "in_progress",
  phase_sequence: 8.5,
  team_name: null
})

// ... run gates ...

updateCheckpoint({
  phase: "pre_ship_validation",
  status: preShipResult.verdict === "BLOCK" ? "failed" : "completed",
  artifact: `tmp/arc/${checkpoint.id}/pre-ship-report.md`,
  artifact_hash: sha256(Read(`tmp/arc/${checkpoint.id}/pre-ship-report.md`)),
  phase_sequence: 8.5,
  team_name: null
})
```
