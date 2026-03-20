# Discipline Work Loop — 8-Phase Convergence Cycle

The Discipline Work Loop replaces strive's linear task execution with an 8-phase convergence cycle. Each phase builds on the previous, ensuring that every plan criterion is addressed, verified, and evidenced before completion.

**Activation gate**: Plan has YAML acceptance criteria (`AC-*` blocks in code fences). Plans without criteria degrade to the existing strive linear execution (backward compatibility).

**File structure**:
```
tmp/work/{timestamp}/
├── tasks/                    # Task definition files (Phase 1 output)
│   ├── task-1.md
│   └── task-2.md
├── task-review/              # Cross-reference results (Phase 1.5 output)
│   ├── task-1-review.md
│   └── coverage-matrix.md
├── evidence/                 # Worker-collected proof artifacts (Phase 3 output)
│   ├── task-1/
│   │   ├── pattern-match-001.json
│   │   └── summary.json
│   └── task-2/
├── work-review/              # Per-task completion assessments (Phase 4.5 output)
│   ├── task-1-review.md
│   └── completion-matrix.md
├── convergence/              # Per-iteration state + metrics (Phase 5 output)
│   ├── iteration-1.json
│   ├── iteration-2.json
│   └── metrics.json
└── drift-signals/            # Plan-reality mismatch signals (Phase 3 worker output)
```

---

## Phase 1: Decompose

Generate one task file per plan task section. Each task file contains the full acceptance criteria from the plan, file targets, and context needed for the worker.

**Input**: Enriched plan file
**Output**: `tmp/work/{timestamp}/tasks/task-{id}.md` (one per task)

See [task-file-format.md](task-file-format.md) for the canonical task file schema.

**Key rules**:
- Every plan acceptance criterion MUST appear in exactly one task file
- Task files include the plan section text verbatim (no paraphrasing)
- File targets extracted from plan (backtick-wrapped paths, `Files:` annotations)

### Criteria Classification (F16 Guard)

During decomposition, each acceptance criterion is classified into one of three scopes.
This prevents cross-cutting criteria from being silently dropped (F16 CROSS_CUTTING_ORPHAN).

| Scope | Definition | Assignment | Verification |
|-------|-----------|------------|-------------|
| **TASK-SCOPED** | Can be verified within a single task's file targets | Assigned to one worker's task file | Worker collects evidence; Phase 4.5 verifies |
| **CROSS-CUTTING** | Spans multiple tasks or files (e.g., "all endpoints return consistent error format") | NOT assigned to individual workers | Verified holistically at Phase 4.5 by orchestrator |
| **SYSTEM-LEVEL** | Cannot be verified from code alone (e.g., "handles 1000 concurrent users") | NOT assigned to individual workers | Verified at Phase 6 (Quality Gates) or escalated to human |

**Classification heuristic** (applied during Phase 1 decomposition):

```javascript
function classifyCriterion(criterion, taskFileMap) {
  const text = criterion.text.toLowerCase()

  // SYSTEM-LEVEL: performance, scalability, deployment requirements
  const systemKeywords = ['concurrent', 'latency', 'throughput', 'deploy', 'production',
    'load test', 'scale', 'uptime', 'availability', 'monitoring dashboard']
  if (systemKeywords.some(k => text.includes(k))) return 'SYSTEM_LEVEL'

  // CROSS-CUTTING: criteria that reference "all", "every", "consistent", or multiple files
  const crossCuttingKeywords = ['all endpoints', 'every file', 'consistent', 'across all',
    'uniform', 'standardized', 'each module', 'all services', 'every route']
  if (crossCuttingKeywords.some(k => text.includes(k))) return 'CROSS_CUTTING'

  // CROSS-CUTTING: criteria whose file targets span 2+ tasks
  if (criterion.files && criterion.files.length > 0) {
    const owningTasks = new Set()
    for (const file of criterion.files) {
      for (const [taskId, taskFiles] of Object.entries(taskFileMap)) {
        if (taskFiles.includes(file)) owningTasks.add(taskId)
      }
    }
    if (owningTasks.size > 1) return 'CROSS_CUTTING'
  }

  return 'TASK_SCOPED'
}
```

**Cross-cutting criteria handling**:
- Written to `tmp/work/{timestamp}/cross-cutting-criteria.json` during Phase 1
- Verified at Phase 4.5 by the orchestrator (not individual workers)
- Appear in the completion matrix with `worker: "orchestrator"` instead of a specific worker name
- If any cross-cutting criterion is FAIL at Phase 5, it generates a gap task assigned to all relevant workers' file scope

---

## Pre-Delegation Coverage Matrix (AC-12, AC-13)

Before spawning any workers, the Tarnished MUST verify that the generated task files cover 100% of the plan's acceptance criteria. This runs immediately after Phase 1 task file creation, before Phase 2 worker spawning.

### Coverage Matrix — Pre-Delegation Check (AC-12)

```javascript
// Run AFTER Phase 1 task file creation, BEFORE Phase 2 worker spawning
function buildCoverageMatrix(timestamp, planPath, extractedTasks, taskCriteriaMap) {
  // Extract all AC IDs from the plan's YAML frontmatter
  const planACs = extractAcceptanceCriteria(planPath)  // Returns [{id, text}]

  // Collect all AC IDs mapped to any task file
  const taskACIds = new Set(
    extractedTasks.flatMap(t => (taskCriteriaMap[t.id] || []).map(c => c.id))
  )

  const coverageMatrix = {
    mapped: [],      // AC in plan AND covered by at least one task
    unmapped: [],    // AC in plan but NOT in any task — DELEGATION ERROR
    fabricated: [],  // AC in tasks but NOT in plan — HALLUCINATION
  }

  for (const ac of planACs) {
    if (taskACIds.has(ac.id)) {
      coverageMatrix.mapped.push(ac.id)
    } else {
      coverageMatrix.unmapped.push(ac.id)
    }
  }

  for (const taskAcId of taskACIds) {
    if (!planACs.some(ac => ac.id === taskAcId)) {
      coverageMatrix.fabricated.push(taskAcId)
    }
  }

  // Write coverage matrix for traceability
  Write(`tmp/work/${timestamp}/coverage-matrix.json`, JSON.stringify({
    plan: planPath,
    total_plan_acs: planACs.length,
    mapped: coverageMatrix.mapped,
    unmapped: coverageMatrix.unmapped,
    fabricated: coverageMatrix.fabricated,
    coverage_pct: planACs.length > 0
      ? ((coverageMatrix.mapped.length / planACs.length) * 100).toFixed(1)
      : 100,
    timestamp: new Date().toISOString(),
  }, null, 2))

  // Report unmapped ACs — these represent delegation gaps
  if (coverageMatrix.unmapped.length > 0) {
    warn(`COVERAGE GAP: ${coverageMatrix.unmapped.length} plan ACs have no task file:`)
    for (const id of coverageMatrix.unmapped) {
      warn(`  - ${id}: not covered by any task file`)
    }
    // Create gap tasks to cover unmapped ACs
    for (const unmappedId of coverageMatrix.unmapped) {
      const planAC = planACs.find(ac => ac.id === unmappedId)
      const gapTaskContent = buildGapTaskFileContent(unmappedId, planAC?.text ?? "")
      Write(`tmp/work/${timestamp}/tasks/task-gap-${unmappedId}.md`, gapTaskContent)
    }
    log(`Created ${coverageMatrix.unmapped.length} gap tasks for unmapped ACs`)
  }

  if (coverageMatrix.fabricated.length > 0) {
    warn(`HALLUCINATION: ${coverageMatrix.fabricated.length} task ACs not in plan: ${coverageMatrix.fabricated.join(", ")}`)
  }

  return coverageMatrix
}
```

**Unmapped ACs = DELEGATION ERROR**: Do NOT spawn workers with unmapped criteria. Create gap tasks first.

**Fabricated ACs = HALLUCINATION**: Task files reference criteria that don't exist in the plan. Remove these or align with plan text.

### Post-Completion Worker Report Verification (AC-13)

After all workers complete (Phase 4 monitoring ends), the Tarnished reads every task file and verifies report quality. Generic or empty reports are INSUFFICIENT — send workers back for revision.

```javascript
// Run AFTER Phase 4 monitoring completes, BEFORE Phase 4.5 completion matrix
function verifyWorkerReports(timestamp) {
  const taskFiles = Glob(`tmp/work/${timestamp}/tasks/task-*.md`)
  const reportIssues = []

  for (const taskFile of taskFiles) {
    const content = Read(taskFile)
    const frontmatter = parseYAMLFrontmatter(content)
    const taskId = String(frontmatter.task_id ?? taskFile.match(/task-([^/]+)\.md/)?.[1] ?? "unknown")

    // Check 1: Worker Report section must exist
    if (!content.includes('## Worker Report')) {
      reportIssues.push({ taskId, issue: 'MISSING_REPORT', severity: 'CRITICAL' })
      continue
    }

    // Check 2: Echo-Back must be substantive (not empty or placeholder)
    const echoBackMatch = content.match(/### Echo-Back\n([\s\S]*?)(?=\n###|\n##|$)/)
    const echoBack = echoBackMatch?.[1]?.trim() ?? ""
    if (echoBack.length < 50 || echoBack.includes('_To be filled')) {
      reportIssues.push({ taskId, issue: 'EMPTY_ECHO_BACK', severity: 'HIGH',
        detail: 'Echo-Back must paraphrase each AC in own words (>50 chars)' })
    }

    // Check 3: Evidence must have file:line references (not generic claims)
    const evidenceMatch = content.match(/### Evidence\n([\s\S]*?)(?=\n###|\n##|$)/)
    const evidence = evidenceMatch?.[1]?.trim() ?? ""
    if (!evidence.match(/\w+\.\w+:\d+/) && evidence.length > 0) {
      reportIssues.push({ taskId, issue: 'GENERIC_EVIDENCE', severity: 'HIGH',
        detail: 'Evidence must include file:line references, not just "implemented correctly"' })
    }
    if (evidence.length === 0) {
      reportIssues.push({ taskId, issue: 'MISSING_EVIDENCE', severity: 'CRITICAL' })
    }

    // Check 3b (R3 FIX): Reject known filler phrases in Evidence section
    const fillerPatterns = [
      /implemented as planned/i,
      /it works/i,
      /works correctly/i,
      /implemented correctly/i,
      /changes applied/i,
      /done as requested/i,
    ]
    if (evidence.length > 0 && !evidence.match(/\w+\.\w+:\d+/)) {
      const hasFillerOnly = fillerPatterns.some(p => p.test(evidence))
      if (hasFillerOnly) {
        reportIssues.push({ taskId, issue: 'FILLER_EVIDENCE', severity: 'HIGH',
          detail: 'Evidence contains only generic filler phrases without file:line references' })
      }
    }

    // Check 3c (R3 FIX): Implementation Notes must have minimum substance
    const implNotesMatch = content.match(/### Implementation Notes\n([\s\S]*?)(?=\n###|\n##|$)/)
    const implNotes = implNotesMatch?.[1]?.trim() ?? ""
    if (implNotes.length > 0 && implNotes.length < 30) {
      reportIssues.push({ taskId, issue: 'THIN_IMPL_NOTES', severity: 'MEDIUM',
        detail: `Implementation Notes too brief (${implNotes.length} chars, min 30)` })
    }

    // Check 4: Self-Review Checklist must have checked items
    if (!content.includes('### Self-Review Checklist') || !content.match(/- \[x\]/i)) {
      reportIssues.push({ taskId, issue: 'INCOMPLETE_SELF_REVIEW', severity: 'HIGH',
        detail: 'Self-Review Checklist must have at least one checked [x] item' })
    }

    // Check 5: Status must be DONE (not stuck or in-progress)
    if (frontmatter.status === 'STUCK') {
      reportIssues.push({ taskId, issue: 'STUCK_UNRESOLVED', severity: 'CRITICAL',
        detail: `Worker reported STUCK: ${frontmatter.stuck_reason ?? 'no reason given'}` })
    }
  }

  if (reportIssues.length > 0) {
    Write(`tmp/work/${timestamp}/report-verification.json`, JSON.stringify({
      issues: reportIssues,
      critical: reportIssues.filter(i => i.severity === 'CRITICAL').length,
      high: reportIssues.filter(i => i.severity === 'HIGH').length,
      timestamp: new Date().toISOString(),
    }, null, 2))

    for (const issue of reportIssues.filter(i => i.severity === 'CRITICAL')) {
      warn(`REPORT VERIFICATION FAILED: task ${issue.taskId} — ${issue.issue}: ${issue.detail ?? ''}`)
    }
  } else {
    Write(`tmp/work/${timestamp}/report-verification.json`, JSON.stringify({
      issues: [], critical: 0, high: 0, verdict: 'PASS',
      timestamp: new Date().toISOString(),
    }, null, 2))
  }

  return reportIssues
}
```

**Critical findings block completion**: Workers with CRITICAL report issues (missing report, missing evidence, STUCK) must be sent back for revision via SendMessage before Phase 4.5 runs.

---

## Phase 1.5: Review Tasks (Cross-Reference Protocol) — IMPLEMENTED

5-step cross-reference between plan criteria and task file criteria:

1. **Extract plan AC**: Parse all `AC-*` entries from the original plan
2. **Extract task AC**: Parse all `AC-*` entries from generated task files
3. **Cross-reference**: Compare plan AC ↔ task AC, classify each as:
   - **MAPPED**: Criterion exists in both plan and task file ✓
   - **MISSING**: Criterion in plan but not in any task file ✗
   - **DRIFTED**: Criterion text differs between plan and task file ⚠
   - **FABRICATED**: Criterion in task file but not in plan ✗
4. **Remediate**: For MISSING → add to appropriate task. For FABRICATED → remove from task. For DRIFTED → align with plan text.
5. **Verify**: Re-run cross-reference to confirm 100% MAPPED after remediation.

**Output**: `tmp/work/{timestamp}/task-review/coverage-matrix.md` and `tmp/work/{timestamp}/cross-reference.md`

**Gate**: MISSING count must be 0 after remediation. FABRICATED count must be 0.

### Executable pseudocode

```javascript
// Phase 1.5: Cross-Reference Verification
// Run AFTER task file creation (Phase 1), BEFORE worker spawning (Phase 2)

function crossReferenceVerification(timestamp, planPath, taskCriteriaMap) {
  const taskFiles = Glob(`tmp/work/${timestamp}/tasks/task-*.md`)
  const results = { mapped: 0, missing: 0, drifted: 0, fabricated: 0, details: [] }

  // Collect all criterion IDs from plan for fabrication detection
  const allPlanCriterionIds = new Set()
  for (const [taskId, criteria] of Object.entries(taskCriteriaMap)) {
    for (const c of criteria) allPlanCriterionIds.add(c.id)
  }

  // For each plan criterion, check if it exists in a task file
  for (const [taskId, criteria] of Object.entries(taskCriteriaMap)) {
    const normalizedId = String(taskId)  // FLAW-008: normalize to String
    const taskFilePath = `tmp/work/${timestamp}/tasks/task-${normalizedId}.md`
    let taskContent
    try { taskContent = Read(taskFilePath) } catch {
      results.missing += criteria.length
      criteria.forEach(c => results.details.push({ id: c.id, status: 'MISSING', reason: 'Task file not found' }))
      continue
    }

    for (const criterion of criteria) {
      // SIGHT-003 FIX: Use AC identifier (AC-NNN) as primary match key.
      // Fall back to normalized text comparison only when no explicit ID is present.
      const hasExplicitId = /^AC-[\d.]+$/.test(criterion.id)

      if (hasExplicitId && taskContent.includes(criterion.id)) {
        // Primary: AC-NNN identifier found in task file — check text drift
        // Use normalized comparison (lowercase, trimmed) instead of fragile 60-char prefix
        const planTextNorm = criterion.text.trim().toLowerCase().slice(0, 120)
        const taskTextNorm = taskContent.toLowerCase()
        if (taskTextNorm.includes(planTextNorm.slice(0, 40))) {
          results.mapped++
          results.details.push({ id: criterion.id, status: 'MAPPED' })
        } else {
          results.drifted++
          results.details.push({ id: criterion.id, status: 'DRIFTED', reason: 'AC ID present but text diverged' })
        }
      } else if (!hasExplicitId && taskContent.includes(criterion.text.slice(0, 60))) {
        // Fallback for criteria without AC-NNN IDs: use text prefix match (legacy behavior)
        results.mapped++
        results.details.push({ id: criterion.id, status: 'MAPPED' })
      } else {
        results.missing++
        results.details.push({ id: criterion.id, status: 'MISSING', reason: 'Criterion ID not in task file' })
      }
    }
  }

  // Check for fabricated criteria (in task files but NOT in plan)
  const acPattern = /AC-[\d.]+/g
  for (const taskFile of taskFiles) {
    const content = Read(taskFile)
    const matches = content.match(acPattern) || []
    for (const acId of matches) {
      if (!allPlanCriterionIds.has(acId)) {
        results.fabricated++
        results.details.push({ id: acId, status: 'FABRICATED', reason: `Found in ${taskFile} but not in plan` })
      }
    }
  }

  // Write cross-reference report
  Bash(`mkdir -p "tmp/work/${timestamp}/task-review"`)
  const report = [
    '# Cross-Reference Verification Report',
    '',
    `Plan: ${planPath}`,
    `Timestamp: ${new Date().toISOString()}`,
    '',
    `## Summary`,
    '',
    `| Status | Count |`,
    `|--------|-------|`,
    `| MAPPED | ${results.mapped} |`,
    `| MISSING | ${results.missing} |`,
    `| DRIFTED | ${results.drifted} |`,
    `| FABRICATED | ${results.fabricated} |`,
    '',
    `## Details`,
    '',
    `| Criterion | Status | Reason |`,
    `|-----------|--------|--------|`,
    ...results.details.map(d => `| ${d.id} | ${d.status} | ${d.reason || '—'} |`),
  ].join('\n')

  Write(`tmp/work/${timestamp}/cross-reference.md`, report)
  Write(`tmp/work/${timestamp}/task-review/coverage-matrix.md`, report)

  // BLOCK if any MISSING criteria (when discipline enabled)
  // readTalismanSection: "discipline"
  const disciplineConfig = readTalismanSection("discipline")
  if (disciplineConfig?.enabled !== false && results.missing > 0) {
    error(`CROSS-REFERENCE BLOCK: ${results.missing} plan criteria missing from task files`)
  }

  return results
}
```

---

## Phase 2: Assign

Distribute task files to workers. Each worker receives ONLY their assigned task files (context isolation — prevents cross-contamination).

**SOW (Scope of Work) Contract** per worker:
```
## Your Scope of Work
RESPONSIBLE FOR: [list of task IDs and their criteria]
NOT RESPONSIBLE FOR: [everything else — do not modify files outside your scope]
```

**SOW coverage check**: After assignment, verify that the union of all worker SOWs covers every plan criterion. Any uncovered criterion → assign to an existing worker or create a new task.

---

## Phase 3: Execute

Workers implement their assigned tasks, collecting evidence as they go. Each worker:

1. Reads the task file (their only source of truth)
2. Implements the required changes
3. Collects evidence per acceptance criterion (see evidence-convention.md)
4. Writes a Worker Report section in the task file
5. Produces a patch for the commit broker

**Context isolation**: Each teammate receives only assigned task files — not the full plan, not other workers' tasks. This prevents cross-contamination and ensures each worker operates from a bounded, verified specification.

---

## Phase 4: Monitor

Standard strive Phase 3 monitoring with discipline extensions:
- Track per-criterion evidence collection (not just task completion)
- Detect stuck workers via silence timeout (configurable, default 5 min)
- Escalation chain: retry → decompose → reassign → human (max 4 attempts per criterion)
- Wall-clock budget: convergence loop exits with F15 if `max_convergence_wall_clock_min` exceeded (default: 60 min)

See [work-loop-convergence.md](work-loop-convergence.md) "Assignment Strategy — 4-Attempt Escalation Chain" for the full escalation protocol with auto-decompose (Attempt 2) and auto-reassign (Attempt 3).

---

## Phase 4.5: Review Work (Completion Matrix) — IMPLEMENTED

Build a completion matrix per task after workers finish. Reads task files to detect worker crashes (IN_PROGRESS with no evidence) and evidence summaries to classify each criterion.

| Task | Criterion | Status | Evidence | Worker |
|------|-----------|--------|----------|--------|
| T1 | AC-1.1 | PASS | pattern-match-001.json | rune-smith-1 |
| T1 | AC-1.2 | FAIL | Missing evidence | rune-smith-1 |
| T2 | AC-2.1 | PASS | file-exists-001.json | rune-smith-2 |
| T2 | AC-2.2 | INCONCLUSIVE | Partial match | rune-smith-2 |
| T2 | AC-2.3 | MISSING | worker_crash | rune-smith-2 |

**Status values**:
- **PASS**: Criterion verified with machine-readable evidence
- **FAIL**: Evidence collected but verification failed
- **INCONCLUSIVE**: Evidence collected but result ambiguous (FLAW-014)
- **MISSING**: No evidence collected (silent skip or worker crash)

**Output**: `tmp/work/{timestamp}/work-review/completion-matrix.md`

### Utility: parseYAMLFrontmatter

Inline regex parser for task file YAML frontmatter. No external YAML dependency.

```javascript
// Parse YAML frontmatter from task file content (inline regex — no YAML lib needed)
function parseYAMLFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---/)
  if (!match) return {}
  const frontmatter = {}
  for (const line of match[1].split('\n')) {
    const kv = line.match(/^(\w[\w_]*)\s*:\s*(.*)$/)
    if (kv) {
      let val = kv[2].trim()
      // Strip surrounding quotes
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1)
      }
      // Coerce known types
      if (val === 'null') val = null
      else if (val === 'true') val = true
      else if (val === 'false') val = false
      else if (/^\d+$/.test(val)) val = parseInt(val, 10)
      frontmatter[kv[1]] = val
    }
  }
  return frontmatter
}
```

### Executable pseudocode

```javascript
// Phase 4.5: Completion Matrix Generation
// Run AFTER all workers complete (Phase 4 monitoring ends), BEFORE convergence decision
function generateCompletionMatrix(timestamp, planCriteriaMap) {
  const taskFiles = Glob(`tmp/work/${timestamp}/tasks/task-*.md`)
  const matrix = []

  for (const taskFile of taskFiles) {
    const content = Read(taskFile)
    const frontmatter = parseYAMLFrontmatter(content)
    const taskId = String(frontmatter.task_id)  // FLAW-008: normalize to String

    // FLAW-005 FIX: Worker crash detection — IN_PROGRESS with no evidence = MISSING
    if (frontmatter.status === 'IN_PROGRESS') {
      const evidenceExists = Glob(`tmp/work/${timestamp}/evidence/${taskId}/summary.json`).length > 0
      if (!evidenceExists) {
        // Worker crashed — map ALL criteria to MISSING with reason
        const criteria = planCriteriaMap[taskId] || planCriteriaMap[parseInt(taskId)] || []
        for (const criterion of criteria) {
          matrix.push({
            task_id: taskId, criterion_id: criterion.id, text: criterion.text,
            task_status: 'IN_PROGRESS',
            proof_result: 'MISSING', reason: 'worker_crash',
            has_worker_report: false, evidence_path: null, worker: frontmatter.assigned_to,
          })
        }
        continue  // Skip to next task file
      }
    }

    // Read evidence if available
    let evidence = null
    try {
      evidence = JSON.parse(Read(`tmp/work/${timestamp}/evidence/${taskId}/summary.json`))
    } catch { /* no evidence collected */ }

    // Read task file Worker Report for additional signals
    const hasWorkerReport = content.includes('### Echo-Back') &&
                            !content.includes('_To be filled by assigned worker._')

    const criteria = planCriteriaMap[taskId] || planCriteriaMap[parseInt(taskId)] || []
    for (const criterion of criteria) {
      const evidenceResult = evidence?.criteria_results?.find(r => r.id === criterion.id)
      matrix.push({
        task_id: taskId,
        criterion_id: criterion.id,
        text: criterion.text,
        task_status: frontmatter.status,            // PENDING/IN_PROGRESS/COMPLETED/VERIFIED/FAILED
        proof_result: evidenceResult?.result ?? 'MISSING',  // PASS/FAIL/INCONCLUSIVE/MISSING
        has_worker_report: hasWorkerReport,
        evidence_path: evidenceResult?.evidence_path ?? null,
        worker: frontmatter.assigned_to,
      })
    }
  }

  // Compute Spec Compliance Rate (SCR)
  const passCount = matrix.filter(m => m.proof_result === 'PASS').length
  const totalCount = matrix.length
  const scr = totalCount > 0 ? (passCount / totalCount * 100) : 0

  // Compute per-status breakdown (FLAW-014: include INCONCLUSIVE)
  const breakdown = {
    PASS: matrix.filter(m => m.proof_result === 'PASS').length,
    FAIL: matrix.filter(m => m.proof_result === 'FAIL').length,
    INCONCLUSIVE: matrix.filter(m => m.proof_result === 'INCONCLUSIVE').length,
    MISSING: matrix.filter(m => m.proof_result === 'MISSING').length,
  }

  // Write completion matrix
  Bash(`mkdir -p "tmp/work/${timestamp}/work-review"`)
  Bash(`mkdir -p "tmp/work/${timestamp}/convergence"`)
  const header = [
    '# Completion Matrix',
    '',
    `**SCR**: ${scr.toFixed(1)}% (${passCount}/${totalCount} criteria PASS)`,
    '',
    `| Status | Count |`,
    `|--------|-------|`,
    ...Object.entries(breakdown).map(([k, v]) => `| ${k} | ${v} |`),
    '',
    '## Per-Criterion Results',
    '',
    '| Task | Criterion | Status | Worker Report | Evidence | Worker |',
    '|------|-----------|--------|---------------|----------|--------|',
  ].join('\n')
  const rows = matrix.map(m =>
    `| ${m.task_id} | ${m.criterion_id} | ${m.proof_result}${m.reason ? ` (${m.reason})` : ''} | ${m.has_worker_report ? 'Yes' : 'No'} | ${m.evidence_path ? 'Yes' : 'No'} | ${m.worker ?? '—'} |`
  ).join('\n')
  Write(`tmp/work/${timestamp}/work-review/completion-matrix.md`, header + '\n' + rows)

  // Write metrics JSON for Phase 5 consumption
  Write(`tmp/work/${timestamp}/convergence/metrics.json`, JSON.stringify({
    metrics: {
      scr: { value: scr },
      first_pass_rate: { value: scr },
    },
    breakdown, matrix, passCount, totalCount,
    timestamp: new Date().toISOString(),
  }, null, 2))

  return { matrix, scr, breakdown, passCount, totalCount }
}
```

---

## Phase 5: Convergence — IMPLEMENTED

Iterative re-work loop for non-PASS criteria. Each iteration:

1. Read completion matrix from Phase 4.5
2. Identify non-PASS criteria (FAIL, INCOMPLETE, MISSING)
3. Generate correction tasks for non-PASS criteria
4. Re-assign to workers (same or different)
5. Re-execute (Phase 3) and re-review (Phase 4.5)
6. Check convergence: all criteria PASS → exit loop

**Convergence limits**:
- `max_convergence_iterations`: Default 3 (talisman configurable via `discipline.max_convergence_iterations`)
- **Stagnation detection**: If same criteria fail across 2+ iterations → escalate to human
- **Exit conditions**: All PASS, max iterations reached, or human intervention

**Detailed convergence protocol**: See [work-loop-convergence.md](work-loop-convergence.md) for the full protocol — entry conditions, iteration logic, exit conditions (success + 3 failure modes), gap task creation, and convergence report format.

**Output**: `tmp/work/{timestamp}/convergence/iteration-{N}.json` per iteration + final `metrics.json`

### Executable pseudocode

```javascript
// Phase 5: Convergence Loop
function convergenceLoop(timestamp, matrixResult, tasks, planCriteria, maxIterations) {
  // readTalismanSection: "discipline"
  const scrThreshold = readTalismanSection("discipline")?.scr_threshold ?? 100
  let iteration = 0
  let prevFailingIds = new Set()

  while (matrixResult.scr < scrThreshold && iteration < maxIterations) {
    const gapCriteria = matrixResult.matrix.filter(m =>
      m.status === 'FAIL' || m.status === 'MISSING' || m.status === 'INCOMPLETE'
    )
    if (gapCriteria.length === 0) break

    // Stagnation detection
    const setsEqual = (a, b) => a.size === b.size && [...a].every(x => b.has(x))
    const currentFailingIds = new Set(gapCriteria.map(g => g.criterion_id))
    if (iteration >= 1 && setsEqual(currentFailingIds, prevFailingIds)) {
      warn(`Convergence stagnated at iteration ${iteration + 1} — same criteria failing`)
      break
    }
    prevFailingIds = currentFailingIds

    // Create gap tasks
    for (const gap of gapCriteria) {
      TaskCreate({
        subject: `[GAP] Fix ${gap.criterion_id}: ${gap.text}`,
        description: `Criterion ${gap.criterion_id} has status ${gap.status}. Fix the implementation to satisfy: ${gap.text}`
      })
    }

    // Re-execute workers, monitor, collect evidence (reuse wave execution)
    // ... (Phase 3 monitoring reused)

    // Re-generate completion matrix
    matrixResult = generateCompletionMatrix(timestamp, tasks, planCriteria)
    iteration++

    Write(`tmp/work/${timestamp}/convergence/iteration-${iteration}.json`, JSON.stringify({
      iteration, scr: matrixResult.scr, gapCount: gapCriteria.length,
      timestamp: new Date().toISOString()
    }))
  }

  return { finalScr: matrixResult.scr, iterations: iteration, converged: matrixResult.scr >= scrThreshold }
}
```

---

## Phase 6: Quality Gates

Standard strive Phase 4 quality gates + discipline-specific checks:
- Ward check (existing)
- Discipline metrics computation (see metrics-schema.md)
- Final SCR calculation
- Metrics artifact write to `convergence/metrics.json`

---

## Backward Compatibility

Plans **without** YAML acceptance criteria (no `AC-*` blocks) degrade gracefully:

| Feature | With Criteria | Without Criteria |
|---------|--------------|-----------------|
| Task decomposition | From AC blocks | From `### Task` headings (existing) |
| Cross-reference (Phase 1.5) | Full 5-step protocol | Skipped |
| Evidence collection | Machine-verifiable | Best-effort |
| Convergence loop | Enabled | Disabled (single pass) |
| SOW contracts | Bounded by criteria | Bounded by files |
| Completion matrix | Per-criterion | Per-task |
| Metrics | Full schema | Partial (no SCR) |

The discipline work loop is an **overlay** — it enhances the existing strive execution without replacing it. The activation gate (`hasCriteria`) determines which path runs.

---

## See Also

- [task-file-format.md](task-file-format.md) — Task file YAML schema and body sections
- [metrics-schema.md](../../discipline/references/metrics-schema.md) — Discipline metrics JSON schema
- [evidence-convention.md](../../discipline/references/evidence-convention.md) — Evidence directory layout
- [proof-schema.md](../../discipline/references/proof-schema.md) — Proof types and execution
- [spec-continuity.md](../../discipline/references/spec-continuity.md) — Spec propagation across phases
