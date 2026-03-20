# Arc Phase QA Gate — Independent Phase Verification Protocol

<!-- FILE OWNERSHIP: Shard 1 defines checklists. Shard 2 extends with orchestration. -->

Each significant arc phase, after completion, passes through an independent QA gate before the
stop hook advances to the next phase. QA agents are completely separate from the Tarnished —
they read artifacts only, cannot modify code, and their verdict cannot be overridden
programmatically. This eliminates the conflict-of-interest of the Tarnished evaluating its own work.

**Scope**: All 6 gated phases — work, forge, code_review, mend, test, gap_analysis.

**Reference**: Plan AC-15, AC-16, AC-17.

> **GUARD 9 CONSTRAINT (load-bearing)**:
> `MAX_QA_RETRIES` MUST be `< MAX_PHASE_DISPATCHES - 1` (currently: max 2 retries, MAX_PHASE_DISPATCHES=4).
> With max 2 retries, the parent phase dispatches 3 times — within safe bounds.
> Increasing MAX_QA_RETRIES to 3 would cause GUARD 9 to destroy the state file and halt the pipeline.
> Do NOT increase this limit without first raising MAX_PHASE_DISPATCHES in arc-phase-stop-hook.sh.

---

## QA Gate Architecture

```
Phase N (e.g., work):
  Tarnished executes phase
  ↓
  QA GATE (work_qa sub-phase):
    Spawn 1-3 QA agents (independent context — no shared state with Tarnished)
    Each QA agent:
      1. Read phase-specific checklist from this file
      2. Verify artifacts exist on disk (Glob + Read)
      3. Verify content is substantive (not empty/generic)
      4. Check for missing steps or plan mismatches
      5. Score each check item (0-100) and write verdict JSON
    ↓
    Aggregate verdicts → overall_score (0-100)
    overall_score >= 70 → PASS → advance to Phase N+1
    overall_score < 50  → FAIL → loop back (revert Phase N to "pending")
    MAX RETRIES (2) exceeded → escalate to human via AskUserQuestion
  ↓
Phase N+1 (only reached after PASS)
```

---

## Scoring System

Every QA gate produces a **numerical score** (0-100) across 3 dimensions. The overall score
is a weighted average based on phase type.

### Score Thresholds

| Score Range | Verdict | Action |
|-------------|---------|--------|
| 90–100 | EXCELLENT | Advance — phase executed perfectly |
| 70–89 | PASS | Advance — acceptable quality, warnings logged |
| 50–69 | MARGINAL | **Retry once** — specific issues need fixing |
| 0–49 | FAIL | **Retry required** — major issues (max 2 retries then escalate) |

### Per-Check Item Scoring (0-100)

- **100**: Fully satisfied with strong evidence
- **75**: Satisfied but evidence could be stronger
- **50**: Partially satisfied — issues found but not critical
- **25**: Mostly unsatisfied — significant gaps
- **0**: Completely missing or wrong

Dimension score = average of all check items in that dimension.

### Dimension Weights per Phase

| Phase | Artifact Weight | Quality Weight | Completeness Weight | Rationale |
|-------|----------------|----------------|---------------------|-----------|
| work | 30% | 40% | 30% | Quality highest — worker reports must be substantive, not generic |
| forge | 20% | 50% | 30% | Quality dominant — enrichment depth matters more than file existence |
| code_review | 30% | 30% | 40% | Completeness highest — all changed files must be reviewed |
| mend | 30% | 30% | 40% | Completeness highest — all findings must be addressed |
| test | 40% | 30% | 30% | Artifacts highest — test report + SEAL marker existence is critical |
| gap_analysis | 30% | 30% | 40% | Completeness highest — all acceptance criteria must appear in matrix |

`overall_score = (artifact_score × W_art) + (quality_score × W_qual) + (completeness_score × W_cmp)`

Where `W_art`, `W_qual`, `W_cmp` are looked up from the table above per phase.

---

## Phase: work — QA Checklist

The work phase QA gate verifies that strive file-based delegation ran correctly and workers
produced substantive, evidence-backed reports.

### Artifact Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-ART-01 | `tmp/work/{ts}/delegation-manifest.json` exists AND is valid JSON AND `workers` array is not empty | `Glob` + `JSON.parse` |
| WRK-ART-02 | `tmp/work/{ts}/tasks/task-*.md` count matches plan task count | `Glob` count vs `total_tasks` in manifest |
| WRK-ART-03 | `tmp/work/{ts}/scopes/*.md` count matches worker count from manifest | `Glob` count vs `workers.length` in manifest |
| WRK-ART-04 | `tmp/work/{ts}/prompts/*.md` count matches worker count from manifest | `Glob` count vs `workers.length` in manifest |
| WRK-ART-05 | `tmp/arc/{id}/work-summary.md` exists and has >10 lines | `Read` + line count |

### Quality Checks (weight: 40%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-QUA-01 | Each task file has `## Worker Report` section that is NOT empty | `Read` + `includes('## Worker Report')` |
| WRK-QUA-02 | Each task file has `### Evidence` with file:line references (e.g., `src/foo.ts:45`) | `Read` + regex `/\w+\.\w+:\d+/` |
| WRK-QUA-03 | Each task file has `### Self-Review Checklist` with at least one `[x]` item | `Read` + regex `/- \[x\]/i` |
| WRK-QUA-04 | No task file has generic evidence like "implemented as planned" or "it works" | `Read` + anti-pattern check |
| WRK-QUA-05 | No task file has `status: STUCK` without resolution note | YAML frontmatter parse |

### Completeness Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-CMP-01 | All plan ACs appear in at least one task file | `coverage-matrix.json` `.unmapped` is empty |
| WRK-CMP-02 | All task files have `status: DONE` (not `PENDING`, `IN_PROGRESS`, or `STUCK`) | YAML frontmatter parse per file |
| WRK-CMP-03 | `git diff HEAD~N..HEAD` shows actual code changes (not empty commit) | `Bash("git diff --stat HEAD~1 HEAD")` |
| WRK-CMP-04 | Task completion ratio ≥ 50% (checkpoint guard condition) | `completed_tasks / total_tasks >= 0.5` from work-summary.md |

### Additional Work Checks (Shard 1 extension)

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-ART-06 | `coverage-matrix.json` exists in work directory AND has valid JSON with `mapped` and `unmapped` arrays | `Glob` + `JSON.parse` |
| WRK-QUA-06 | Phase log contains `task_files_created` event with non-zero file counts (observability) | `Read` execution log + search for `task_files_created` |

### Composite "Going Through the Motions" Detection (AC-11)

Aggregates weak signals from individual checks to detect perfunctory task completion that
passes each individual check at minimum threshold but collectively indicates hollow work.

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-MOT-01 | Composite motions score: count borderline signals across QUA and CMP checks for each task file. Signals: (a) Worker Report < 10 lines, (b) Evidence section has < 2 file:line refs, (c) Self-Review has exactly 1 `[x]` item, (d) Echo-Back is < 30% different from original AC text, (e) Critical Review section is absent or < 3 lines. Task with ≥ 3 signals = FAIL ("going through the motions detected"). | `Read` each task file, count signal matches per file. Report per-file signal count and which signals triggered. |

**Scoring**: WRK-MOT-01 contributes to the **Quality dimension**. Weight: equivalent to one WRK-QUA check.
A single task triggering WRK-MOT-01 caps the Quality dimension score at 60 (MARGINAL).
Multiple tasks triggering WRK-MOT-01 caps Quality at 40 (FAIL).

### Process Compliance Checks (AC-15)

Cross-references process manifests against execution logs and filesystem artifacts to detect
procedural drift — steps that were required but not executed, or executed out of order.

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-PRC-01 | Process manifest `qa-manifests/{phase}.yaml` exists for this phase | `Glob("qa-manifests/{phase}.yaml")` — missing manifest = skip compliance checks (INFO) |
| WRK-PRC-02 | Every `required: true` step in manifest has a matching entry in execution log (`tmp/arc/{id}/execution-log.jsonl`) | Parse manifest steps → cross-reference execution log entries by `step_id`. Missing = FAIL with evidence. |
| WRK-PRC-03 | Step execution order matches manifest sequence (no out-of-order steps) | Compare execution log timestamps against manifest step ordering. Out-of-order = WARN (not FAIL — some parallelization is expected). |
| WRK-PRC-04 | Every `artifact` listed in manifest has a corresponding file on disk | Extract `artifact` paths from manifest → `test -f` each. Missing artifact = FAIL with specific path. |
| WRK-PRC-05 | Completion percentage = (executed required steps / total required steps) × 100 | Count `required: true` steps with execution log entries vs total. Report as percentage. |

**Scoring**: Process compliance checks contribute to the **Quality dimension** (not a separate dimension).
When no process manifest exists for a phase, all PRC checks score 100 (no requirements = fully compliant).

### Step Order Compliance (AC-21)

| ID | Check | Evidence Required |
|----|-------|------------------|
| WRK-ORD-01 | Execution log entries are in chronological order | Parse `timestamp` field from each JSONL entry, verify monotonically increasing |
| WRK-ORD-02 | No skipped required steps between first and last executed step | Detect gaps in manifest step sequence from execution log — required steps with `executed: false` between two `executed: true` steps |
| WRK-ORD-03 | Completion percentage includes step-level granularity | Report per-step status: EXECUTED / SKIPPED / NOT_REACHED in QA verdict `items[]` |

---

## Phase: forge — QA Checklist

The forge phase QA gate verifies that plan enrichment produced a deeper, more detailed plan
without destroying the original structure.

<!-- Weight rationale: Quality at 50% because enrichment DEPTH is the primary value —
     a forge that produces superficial additions is worse than no forge at all. -->

### Artifact Checks (weight: 20%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| FRG-ART-01 | `tmp/arc/{id}/enriched-plan.md` exists AND has >100 lines | `Glob` + `Read` line count |
| FRG-ART-02 | Checkpoint has `phase=forge`, `status=completed`, and valid `artifact_hash` | `Read` checkpoint JSON + field validation |

### Quality Checks (weight: 50%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| FRG-QUA-01 | Enriched plan contains Forge Gaze enrichment sections (not just a copy of original) | `Read` + search for `Forge Enrichment` or `forge_gaze` markers |
| FRG-QUA-02 | Enriched sections include code samples, technical detail, or specific file references | `Read` + regex for backtick code blocks or `file:line` patterns |
| FRG-QUA-03 | Original plan structure preserved — all H2 headings from original appear in enriched version | Compare H2 headings between original and enriched plan |

### Completeness Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| FRG-CMP-01 | All sections from original plan appear in enriched plan (no dropped content) | `Grep` for each original H2 heading in enriched plan |

---

## Phase: code_review — QA Checklist

The code review QA gate verifies that the TOME was produced with structured findings and
relocated to the arc artifacts directory.

<!-- Weight rationale: Completeness at 40% because an incomplete review (missed files)
     is more dangerous than a slightly lower-quality review of all files. -->

### Artifact Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| REV-ART-01 | `tmp/arc/{id}/tome.md` (or `tome-round-{N}.md` for convergence retries) exists | `Glob("tmp/arc/{id}/tome*.md")` |
| REV-ART-02 | Checkpoint has `phase=code_review`, `status=completed`, and valid `artifact_hash` | `Read` checkpoint JSON + field validation |
| REV-ART-03 | TOME relocated from review output dir (`tmp/reviews/*/TOME.md`) to arc artifacts dir | `Glob` confirms file in `tmp/arc/{id}/` not just `tmp/reviews/` |

### Quality Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| REV-QUA-01 | TOME has structured findings (not empty or placeholder content) | `Read` + line count > 20 AND contains `## Findings` or finding prefix markers |
| REV-QUA-02 | Findings have valid Ash prefixes (SEC-, BACK-, QUAL-, FRONT-, DOC-, PERF-, etc.) | `Read` + regex for `^(SEC\|BACK\|QUAL\|FRONT\|DOC\|PERF\|CDX)-\d+` |
| REV-QUA-03 | No duplicate finding IDs in TOME | `Read` + extract all finding IDs + check uniqueness |

### Completeness Checks (weight: 40%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| REV-CMP-01 | Review covered all changed files (diff files vs files mentioned in TOME) | `git diff --name-only` cross-referenced with TOME file mentions |
| REV-CMP-02 | Gap analysis context propagated to reviewers (if gap analysis phase ran) | `Read` TOME header or review context for MISSING/PARTIAL counts |

---

## Phase: mend — QA Checklist

The mend phase QA gate verifies that findings were resolved with evidence and the resolution
report tracks outcomes per finding.

<!-- Weight rationale: Completeness at 40% because unaddressed P1 findings represent
     security/correctness risks that must not slip through. -->

### Artifact Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| MND-ART-01 | Resolution report exists at round-aware path: `tmp/arc/{id}/resolution-report.md` (round 0) or `tmp/arc/{id}/resolution-report-round-{N}.md` (retry) | `Glob("tmp/arc/{id}/resolution-report*.md")` |

### Quality Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| MND-QUA-01 | Resolution report has per-finding status (FIXED, WONTFIX, FALSE_POSITIVE, or FAILED) | `Read` + regex for status keywords per finding |
| MND-QUA-02 | Each FIXED finding references a commit SHA or specific code change | `Read` + regex for git SHA pattern `/[0-9a-f]{7,40}/` near FIXED entries |
| MND-QUA-03 | Halt condition enforced: checkpoint status is `failed` when >3 findings remain FAILED | `Read` checkpoint + count FAILED in resolution report |

### Completeness Checks (weight: 40%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| MND-CMP-01 | All P1 findings from TOME addressed (not left as FAILED without justification) | Cross-reference TOME P1 findings with resolution report statuses |
| MND-CMP-02 | Resolution report covers all TOME findings (every finding ID from TOME appears) | Extract finding IDs from both files + set difference |

---

## Phase: test — QA Checklist

The test phase QA gate verifies that test execution produced valid reports with proper
completion markers and that strategy preceded execution.

<!-- Weight rationale: Artifacts at 40% because test output is non-blocking — the pipeline
     continues regardless of pass/fail, so EXISTENCE of reports is the primary gate.
     Without reports, downstream phases (audit, ship) have no test evidence. -->

### Artifact Checks (weight: 40%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| TST-ART-01 | `tmp/arc/{id}/test-report.md` exists AND has >10 lines | `Glob` + `Read` line count |
| TST-ART-02 | Test report contains SEAL marker `<!-- SEAL: test-report-complete -->` | `Read` + `includes('<!-- SEAL: test-report-complete -->')` |
| TST-ART-03 | `tmp/arc/{id}/test-strategy.md` exists (strategy generated before execution) | `Glob("tmp/arc/{id}/test-strategy.md")` |

### Quality Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| TST-QUA-01 | Test report has pass/fail counts per tier (unit, integration, e2e) | `Read` + search for tier result tables or summary counts |
| TST-QUA-02 | Test results are non-blocking (checkpoint status is `completed` regardless of pass/fail) | `Read` checkpoint — status should never be `failed` for test phase |
| TST-QUA-03 | Test strategy was generated BEFORE test execution (strategy timestamp < first batch timestamp) | Compare `test-strategy.md` mtime vs first `test-results-*` mtime |

### Completeness Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| TST-CMP-01 | All active tiers ran (at minimum unit tier for any code change) | Checkpoint `tiers_run` array is non-empty |
| TST-CMP-02 | Checkpoint has `tiers_run`, `pass_rate`, and `coverage_pct` metrics | `Read` checkpoint JSON + field existence validation |

---

## Phase: gap_analysis — QA Checklist

The gap analysis QA gate verifies that deterministic checks produced a compliance matrix
mapping every acceptance criterion to its implementation status.

<!-- Weight rationale: Completeness at 40% because the PRIMARY purpose of gap analysis
     is ensuring ALL acceptance criteria are accounted for — missing criteria in the
     matrix means the pipeline lost track of requirements. -->

### Artifact Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| GAP-ART-01 | `tmp/arc/{id}/gap-analysis.md` exists with summary counts for ADDRESSED, PARTIAL, and MISSING | `Glob` + `Read` + search for count summary table |
| GAP-ART-02 | Spec compliance matrix section exists with per-criterion status entries | `Read` + search for `## Spec Compliance Matrix` or `## Compliance Matrix` |

### Quality Checks (weight: 30%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| GAP-QUA-01 | Each acceptance criterion has explicit status: ADDRESSED, PARTIAL, or MISSING | `Read` + regex for status keywords per criterion row |
| GAP-QUA-02 | Evidence includes file:line references or code snippets (not just assertions) | `Read` + regex `/\w+\.\w+:\d+/` or backtick code blocks near evidence |
| GAP-QUA-03 | Deterministic checks (STEP A) ran before LLM inspectors (STEP B) — ordering preserved | `Read` gap-analysis.md structure: deterministic sections appear before inspector sections |

### Completeness Checks (weight: 40%)

| ID | Check | Evidence Required |
|----|-------|------------------|
| GAP-CMP-01 | All acceptance criteria from the plan appear in the compliance matrix | Cross-reference plan AC list with matrix entries + check for gaps |
| GAP-CMP-02 | Plan section coverage computed — all H2 headings have ADDRESSED or MISSING status | `Read` + search for plan section coverage table |

---

## Edge Case Handling

QA gates must handle non-standard phase outcomes gracefully:

### Skipped Phases

When a phase has `status: "skipped"` in the checkpoint (e.g., test phase skipped via `--no-test`),
the QA gate MUST return PASS with a skip reason — never FAIL a phase that was intentionally skipped.

```json
{
  "phase": "test",
  "verdict": "PASS",
  "skip_reason": "Phase skipped via --no-test flag",
  "scores": { "artifact_score": 100, "quality_score": 100, "completeness_score": 100, "overall_score": 100 }
}
```

### Round-Aware Artifact Paths

Mend and code review phases support convergence rounds. QA checks must accept EITHER:
- Round 0: `resolution-report.md`, `tome.md`
- Round N: `resolution-report-round-{N}.md`, `tome-round-{N}.md`

Use glob patterns (e.g., `Glob("tmp/arc/{id}/resolution-report*.md")`) to discover the correct file.

### Empty vs Missing vs Skipped Artifacts

| State | Detection | QA Result |
|-------|-----------|-----------|
| **Missing** | File does not exist | FAIL (score: 0) |
| **Empty** | File exists but 0 bytes or <3 lines | FAIL (score: 25) |
| **Skip-content** | File exists with explicit skip marker (`<!-- SKIPPED: reason -->`) | PASS (score: 75) |
| **Valid** | File exists with substantive content | PASS (score: 75-100 based on depth) |

---

## Verdict File Format

QA agents write their verdict to `tmp/arc/{id}/qa/{phase}-verdict.json` before marking their
task complete. The stop hook reads this file to decide whether to advance.

```json
{
  "phase": "work",
  "verdict": "PASS",
  "retry_count": 0,
  "timed_out": false,
  "scores": {
    "artifact_score": 95,
    "quality_score": 82,
    "completeness_score": 90,
    "overall_score": 88.6
  },
  "thresholds": {
    "pass_threshold": 70,
    "excellence_threshold": 90
  },
  "checks": {
    "total": 13,
    "passed": 12,
    "failed": 1,
    "warnings": 2
  },
  "items": [
    {
      "id": "WRK-ART-01",
      "dimension": "artifact",
      "check": "delegation-manifest.json exists and valid",
      "verdict": "PASS",
      "score": 100,
      "evidence": "File exists at tmp/work/20260319/delegation-manifest.json, 3 workers"
    },
    {
      "id": "WRK-QUA-03",
      "dimension": "quality",
      "check": "Self-Review Checklist with [x] items",
      "verdict": "FAIL",
      "score": 40,
      "evidence": "task-2.1.md has Self-Review section but all items are [ ] (unchecked)",
      "remediation": "Worker must check items after completing each review step"
    }
  ],
  "summary": "Phase work scored 88.6/100 (PASS). 1 quality issue: task-2.1 self-review unchecked.",
  "timestamp": "2026-03-19T15:30:00Z"
}
```

**Missing verdict file rule**: If the QA agent times out or crashes without writing verdict JSON,
the stop hook MUST treat the absent file as FAIL with `timed_out: true`. Timed-out FAILs do NOT
count against the quality retry budget (they are infrastructure failures, not quality failures).
Infrastructure retries are tracked separately via `infra_retry_count` (max 2) and only consume
the `global_retry_count` as a safety cap. This prevents QA agent crashes from exhausting the
quality retry budget that should be reserved for genuine quality failures.

---

## QA Gate Implementation (arc-phase-qa-gate pseudocode)

### `buildQAAgentPrompt()` — Content Injection (AC-24)

```javascript
// Builds the prompt for a dedicated per-phase QA agent.
// KEY: Injects FULL CONTENT of manifest and execution log — not just file paths.
// This ensures the QA agent has complete source of truth without needing to discover files.
function buildQAAgentPrompt(id, parentPhase, timestamp, qaDir) {
  let prompt = ""

  // 1. Inject arc ID and phase context
  prompt += `## QA Gate Context\n\n`
  prompt += `- Arc ID: ${id}\n`
  prompt += `- Parent Phase: ${parentPhase}\n`
  prompt += `- Timestamp: ${timestamp}\n`
  prompt += `- Output directory: ${qaDir}\n\n`

  // 2. Inject FULL manifest content (AC-24)
  const manifestPath = `tmp/arc/${id}/qa-manifests/${parentPhase}.yaml`
  try {
    const manifestContent = Read(manifestPath)
    prompt += `## Process Manifest (full content)\n\n\`\`\`yaml\n${manifestContent}\n\`\`\`\n\n`
  } catch (_) {
    prompt += `## Process Manifest\n\nNo manifest found at ${manifestPath} — skip process compliance checks.\n\n`
  }

  // 3. Inject FULL execution log content (AC-24)
  const logPath = `tmp/arc/${id}/execution-log.jsonl`
  try {
    const logContent = Read(logPath)
    // Cap at 500 lines to avoid context overflow
    const logLines = logContent.split('\n')
    const cappedLog = logLines.length > 500
      ? logLines.slice(-500).join('\n') + `\n\n(Truncated — showing last 500 of ${logLines.length} lines)`
      : logContent
    prompt += `## Execution Log (full content)\n\n\`\`\`jsonl\n${cappedLog}\n\`\`\`\n\n`
  } catch (_) {
    prompt += `## Execution Log\n\nNo execution log found at ${logPath}.\n\n`
  }

  // 4. Inject phase-specific artifact paths for the agent to verify
  const PHASE_ARTIFACTS = {
    work: [`tmp/work/${timestamp}/delegation-manifest.json`, `tmp/arc/${id}/work-summary.md`],
    forge: [`tmp/arc/${id}/enriched-plan.md`],
    code_review: [`tmp/arc/${id}/tome.md`],
    mend: [`tmp/arc/${id}/resolution-report.md`],
    test: [`tmp/arc/${id}/test-report.md`, `tmp/arc/${id}/test-strategy.md`],
    gap_analysis: [`tmp/arc/${id}/gap-analysis.md`],
  }
  const artifacts = PHASE_ARTIFACTS[parentPhase] ?? []
  prompt += `## Expected Artifacts\n\n${artifacts.map(a => `- \`${a}\``).join('\n')}\n\n`

  // 5. Instruct the agent to cover ALL 3 dimensions and write unified verdict
  prompt += `## Instructions\n\n`
  prompt += `Verify ALL 3 dimensions (artifact, quality, completeness) for the **${parentPhase}** phase.\n`
  prompt += `Use the phase-specific checklist from your agent definition.\n`
  prompt += `Write your unified verdict JSON to: \`${qaDir}/${parentPhase}-verdict.json\`\n`
  prompt += `Write a human-readable report to: \`${qaDir}/${parentPhase}-report.md\`\n`
  prompt += `Then mark your task as completed via TaskUpdate.\n`

  return prompt
}
```

### `runQAGate()` — Main Orchestration

```javascript
// Called by arc orchestrator when phase === "work_qa"
// parentPhase = "work" (stripped "_qa" suffix)
async function runQAGate(id, parentPhase, checkpoint) {
  const qaDir = `tmp/arc/${id}/qa`
  Bash(`mkdir -p "${qaDir}"`)

  // Discover strive run timestamp from work-summary or state file
  const workStateFiles = Glob("tmp/.rune-work-*.json")
  const timestamp = workStateFiles.length > 0
    ? JSON.parse(Read(workStateFiles[0])).timestamp
    : null

  // Spawn QA team (independent from main arc team)
  // NOTE: Uses teamTransition protocol — TeamDelete retry before TeamCreate
  // to handle stale teams from crashed prior runs (AC-17 edge case 6e).
  const qaTeamName = `arc-qa-${id}-${parentPhase}`
  TeamCreate({ team_name: qaTeamName })

  try {
    // Design decision: 1 DEDICATED agent per gate, not 3 generic agents.
    // Each gated phase spawns exactly 1 dedicated QA agent (e.g., work-qa-verifier
    // for work phase). This agent covers all 3 dimensions (artifact, quality,
    // completeness) because it has phase-specific domain knowledge — it knows what
    // "quality" means for work output vs test output.
    // 3 generic agents would be shallower (no domain expertise) and 3× more expensive.

    // Map parentPhase to dedicated agent subagent_type
    const QA_AGENT_MAP = {
      forge:        "rune:qa:forge-qa-verifier",
      work:         "rune:qa:work-qa-verifier",
      code_review:  "rune:qa:code-review-qa-verifier",
      mend:         "rune:qa:mend-qa-verifier",
      test:         "rune:qa:test-qa-verifier",
      gap_analysis: "rune:qa:gap-analysis-qa-verifier",
    }
    const agentType = QA_AGENT_MAP[parentPhase] ?? "rune:qa:phase-qa-verifier"
    const agentName = `qa-${parentPhase}-verifier`

    TaskCreate({ team_name: qaTeamName, subject: `QA: Verify ${parentPhase} phase (all dimensions)` })
    Agent({
      team_name: qaTeamName,
      name: agentName,
      subagent_type: agentType,
      prompt: buildQAAgentPrompt(id, parentPhase, timestamp, qaDir)
    })

    // Monitor QA agent (5-minute timeout for 1 agent)
    waitForCompletion(qaTeamName, 1, { timeoutMs: 300_000 })

    // Read unified verdict from dedicated agent
    const verdict = safeReadJSON(`${qaDir}/${parentPhase}-verdict.json`, { items: [], timed_out: true })

    // The dedicated agent writes the verdict directly — it computes scores internally
    // using its phase-specific weights (defined in the agent's own prompt).
    // We read the pre-computed result rather than re-aggregating from 3 dimension files.
    const allItems = verdict.items || []
    const failedItems = allItems.filter(i => i.verdict === "FAIL")
    const timedOut = verdict.timed_out || false
    const overallScore = verdict.scores?.overall_score ?? 0

    // Determine verdict string from score (agent writes this too, but we re-derive
    // as a safety check in case the agent's verdict string is malformed)
    let verdictStr = "FAIL"
    if (overallScore >= 70) verdictStr = "PASS"
    if (overallScore >= 90) verdictStr = "EXCELLENT"
    if (overallScore >= 50 && overallScore < 70) verdictStr = "MARGINAL"

    const retryCount = checkpoint.phases?.[`${parentPhase}_qa`]?.retry_count ?? 0

    // If agent didn't write verdict (timed out), write a FAIL verdict for the stop hook
    if (timedOut || allItems.length === 0) {
      Write(`${qaDir}/${parentPhase}-verdict.json`, JSON.stringify({
        phase: parentPhase,
        verdict: "FAIL",
        retry_count: retryCount,
        timed_out: true,
        scores: { artifact_score: 0, quality_score: 0, completeness_score: 0, overall_score: 0 },
        thresholds: { pass_threshold: 70, excellence_threshold: 90 },
        checks: { total: 0, passed: 0, failed: 0, warnings: 0 },
        items: [],
        summary: `Phase ${parentPhase} QA agent timed out or produced no items.`,
        timestamp: new Date().toISOString(),
      }, null, 2))
    }

    // Handle QA result — GUARD 9 constraint: MAX_QA_RETRIES < MAX_PHASE_DISPATCHES - 1 = 3
    const MAX_QA_RETRIES = 2  // DO NOT increase without raising MAX_PHASE_DISPATCHES in stop hook

    if ((verdictStr === "FAIL" || verdictStr === "MARGINAL") && !timedOut) {
      if (retryCount >= MAX_QA_RETRIES) {
        // Max retries reached — escalate to human
        warn(`QA FAILED for ${parentPhase} after ${retryCount} retries. Escalating to human.`)
        AskUserQuestion(
          `Phase "${parentPhase}" failed QA ${retryCount} time(s):\n\n` +
          failedItems.map(f => `- [${f.id}] ${f.check}: ${f.evidence}`).join('\n') +
          `\n\nOptions:\n1. Retry the phase\n2. Skip QA and continue\n3. Abort the arc`
        )
      } else {
        // Revert parent phase to "pending" — stop hook will re-execute it
        updateCheckpoint({
          [`phases.${parentPhase}.status`]: "pending",
          [`phases.${parentPhase}_qa.status`]: "pending",
          [`phases.${parentPhase}_qa.retry_count`]: retryCount + 1,
          [`phases.${parentPhase}_qa.last_failure`]: failedItems.map(f => f.id).join(", "),
        })
        log(`QA ${verdictStr} for ${parentPhase} (score=${overallScore.toFixed(1)}) — reverting to pending (attempt ${retryCount + 1}/${MAX_QA_RETRIES})`)
      }
    } else {
      log(`QA ${verdictStr} for ${parentPhase} (score=${overallScore.toFixed(1)}) — advancing to next phase`)
    }

  } finally {
    // Always clean up QA team (standard 5-component pattern from CLAUDE.md)
    const allQAMembers = [agentName]  // Single dedicated agent per gate
    let confirmedAlive = 0
    for (const member of allQAMembers) {
      try { SendMessage({ type: "shutdown_request", recipient: member, content: "QA complete" }); confirmedAlive++ } catch (_) {}
    }
    if (confirmedAlive > 0) Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`)
    else Bash("sleep 2")

    const DELAYS = [0, 3000, 6000, 10000]
    let cleanupTeamDeleteSucceeded = false
    for (let i = 0; i < DELAYS.length; i++) {
      if (i > 0) Bash(`sleep ${DELAYS[i] / 1000}`)
      try { TeamDelete({ team_name: qaTeamName }); cleanupTeamDeleteSucceeded = true; break } catch (_) {}
    }
    if (!cleanupTeamDeleteSucceeded) {
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${qaTeamName}/" "$CHOME/tasks/${qaTeamName}/" 2>/dev/null`)
    }
  }
}
```

---

## Stop Hook Integration — QA-Gated Phase Advance

The critical integration point is `arc-phase-stop-hook.sh`. When the just-completed phase is a
`_qa` sub-phase, the stop hook reads the verdict before advancing.

```bash
# In arc-phase-stop-hook.sh, after finding NEXT_PHASE and before writing updated checkpoint:

# ── QA Gate Check ──
# If the JUST-COMPLETED phase was a _qa phase, check verdict before advancing.
if [[ "$_IMMEDIATE_PREV" == *_qa ]]; then
  _parent_phase="${_IMMEDIATE_PREV%_qa}"
  _qa_verdict_file="${_ARC_DIR}/qa/${_parent_phase}-verdict.json"

  if [[ -f "$_qa_verdict_file" ]]; then
    _qa_verdict=$(jq -r '.verdict // "UNKNOWN"' "$_qa_verdict_file" 2>/dev/null)
    _qa_score=$(jq -r '.scores.overall_score // 0' "$_qa_verdict_file" 2>/dev/null)
    _qa_timed_out=$(jq -r '.timed_out // false' "$_qa_verdict_file" 2>/dev/null)
    _qa_retries=$(jq -r '.retry_count // 0' "$_qa_verdict_file" 2>/dev/null)

    if [[ "$_qa_verdict" == "FAIL" || "$_qa_verdict" == "MARGINAL" ]]; then
      if [[ "$_qa_timed_out" == "true" ]]; then
        # Timeout failures don't count against retry budget — log but advance
        _trace "QA timeout for ${_parent_phase} — treating as PASS (infrastructure failure)"
      elif [[ "$_qa_retries" -lt 2 ]]; then
        # GUARD 9 constraint documented: 2 < MAX_PHASE_DISPATCHES - 1 = 3 (safe)
        _trace "QA ${_qa_verdict} for ${_parent_phase} (score=${_qa_score}, retry=${_qa_retries}) — reverting"

        # Revert parent phase AND QA phase to pending
        CKPT_CONTENT=$(echo "$CKPT_CONTENT" | jq \
          --arg pp "$_parent_phase" \
          --arg qa "$_IMMEDIATE_PREV" \
          '.phases[$pp].status = "pending" | .phases[$qa].status = "pending"')

        echo "$CKPT_CONTENT" > "$CKPT_PATH"
        NEXT_PHASE="$_parent_phase"
        _trace "QA loop-back: next phase is ${NEXT_PHASE}"
      else
        _trace "QA FAIL for ${_parent_phase} after max retries — human escalation expected"
        # AskUserQuestion is triggered by the QA phase prompt, not here
      fi
    fi
  else
    # Missing verdict file — default to FAIL (safe default, per plan concern E8)
    _trace "QA verdict file missing for ${_parent_phase} — treating as FAIL (timed_out=true)"
    # Revert if retries remain, otherwise let human escalation handle it
    if [[ "${_qa_retries:-0}" -lt 2 ]]; then
      CKPT_CONTENT=$(echo "$CKPT_CONTENT" | jq \
        --arg pp "$_parent_phase" \
        --arg qa "$_IMMEDIATE_PREV" \
        '.phases[$pp].status = "pending" | .phases[$qa].status = "pending"')
      echo "$CKPT_CONTENT" > "$CKPT_PATH"
      NEXT_PHASE="$_parent_phase"
    fi
  fi
fi
```

---

## QA Phases in PHASE_ORDER

Adding QA sub-phases requires updating TWO synchronized copies of PHASE_ORDER.

> **DECREE-003 — Dual PHASE_ORDER Sync (load-bearing constraint)**:
> PHASE_ORDER exists in two files that MUST stay in sync:
> 1. `arc-phase-stop-hook.sh` (bash array, line ~235) — authoritative for execution
> 2. `arc-phase-constants.md` (JavaScript array, line ~12) — authoritative for budget/timeout
>
> Adding `work_qa` requires updating BOTH files plus: `_phase_ref()`, `PHASE_TIMEOUTS`,
> `PHASE_PREFIX_MAP`, and `ARC_TEAM_PREFIXES` (6 locations total).
> Adding DECREE-003 validation to arc preflight will detect drift automatically.

**Gated phases**: `forge_qa`, `work_qa`, `gap_analysis_qa`, `code_review_qa`, `mend_qa`, `test_qa`.
Each `*_qa` phase is inserted into PHASE_ORDER immediately after its parent phase.

```javascript
// arc-phase-constants.md — JavaScript PHASE_ORDER (QA gates after each parent phase)
const PHASE_ORDER = [
  "forge",
  "forge_qa",              // ← QA gate for forge phase
  "plan_review", "plan_refinement", "verification", "semantic_verification",
  "design_extraction", "design_prototype", "task_decomposition",
  "work",
  "work_qa",               // ← QA gate for work phase
  "gap_analysis",
  "gap_analysis_qa",       // ← QA gate for gap analysis phase
  "code_review",
  "code_review_qa",        // ← QA gate for code review phase
  "mend",
  "mend_qa",               // ← QA gate for mend phase
  "verify_mend", "design_iteration",
  "test",
  "test_qa",               // ← QA gate for test phase
  "pre_ship_validation", "release_quality_check", "ship",
  "bot_review_wait", "pr_comment_resolution", "merge"
]
```

```bash
# arc-phase-stop-hook.sh — bash PHASE_ORDER array (QA gates after each parent phase)
PHASE_ORDER=(
  forge
  forge_qa               # QA gate for forge phase
  plan_review plan_refinement verification semantic_verification
  design_extraction design_prototype task_decomposition
  work
  work_qa                # QA gate for work phase
  gap_analysis
  gap_analysis_qa        # QA gate for gap analysis phase
  code_review
  code_review_qa         # QA gate for code review phase
  mend
  mend_qa                # QA gate for mend phase
  verify_mend design_iteration
  test
  test_qa                # QA gate for test phase
  pre_ship_validation release_quality_check ship
  bot_review_wait pr_comment_resolution merge
)
```

---

## QA Crash Recovery

If the QA phase crashes before writing a verdict, the 3-layer defense applies:

| Resource | Location | Recovery |
|----------|----------|----------|
| QA team config | `$CHOME/teams/arc-qa-{id}-{phase}/` | Arc cleanup (`arc-phase-cleanup.md`) |
| QA task list | `$CHOME/tasks/arc-qa-{id}-{phase}/` | Arc cleanup |
| Verdict file | `tmp/arc/{id}/qa/{phase}-verdict.json` | Missing → default FAIL (stop hook) |

ARC_TEAM_PREFIXES must include `arc-qa-` for pre-flight stale scan (Layer 1) and PHASE_PREFIX_MAP
must include all QA phases for postPhaseCleanup (Layer 2):

```javascript
// PHASE_PREFIX_MAP entries for all QA phases
"forge_qa":        "arc-qa-",
"work_qa":         "arc-qa-",
"gap_analysis_qa": "arc-qa-",
"code_review_qa":  "arc-qa-",
"mend_qa":         "arc-qa-",
"test_qa":         "arc-qa-",
```

See `arc-phase-cleanup.md`.

---

## QA Dashboard Generation

After all QA gates have run, the orchestrator generates a consolidated dashboard summarizing
quality across the entire arc pipeline. This dashboard is used in the PR body (Phase 9: ship)
and persisted as a JSON artifact for programmatic consumption.

### Dashboard Algorithm

```javascript
// Called after the last QA-gated phase completes (typically test_qa)
// Reads all verdict files and produces a unified quality dashboard.
function generateQADashboard(arcId) {
  const qaDir = `tmp/arc/${arcId}/qa`
  const GATED_PHASES = ["forge", "work", "gap_analysis", "code_review", "mend", "test"]

  // Collect verdict data from all gated phases
  const phaseResults = []
  for (const phase of GATED_PHASES) {
    const verdictPath = `${qaDir}/${phase}-verdict.json`
    try {
      const verdict = JSON.parse(Read(verdictPath))
      phaseResults.push({
        phase,
        verdict: verdict.verdict ?? "UNKNOWN",
        overall_score: verdict.scores?.overall_score ?? 0,
        artifact_score: verdict.scores?.artifact_score ?? 0,
        quality_score: verdict.scores?.quality_score ?? 0,
        completeness_score: verdict.scores?.completeness_score ?? 0,
        checks_passed: verdict.checks?.passed ?? 0,
        checks_total: verdict.checks?.total ?? 0,
        retry_count: verdict.retry_count ?? 0,
        timed_out: verdict.timed_out ?? false,
      })
    } catch (e) {
      // Phase was skipped or verdict file missing — record as skipped
      phaseResults.push({
        phase,
        verdict: "SKIPPED",
        overall_score: null,
        artifact_score: null,
        quality_score: null,
        completeness_score: null,
        checks_passed: 0,
        checks_total: 0,
        retry_count: 0,
        timed_out: false,
      })
    }
  }

  // Compute weighted average across all phases that ran (exclude SKIPPED)
  const scoredPhases = phaseResults.filter(r => r.verdict !== "SKIPPED" && r.overall_score !== null)

  // Inline utility — weighted average with custom weight function
  function weightedAverage(items, weightFn) {
    if (items.length === 0) return 0
    let totalWeight = 0
    let weightedSum = 0
    for (const item of items) {
      const w = weightFn(item)
      weightedSum += item.overall_score * w
      totalWeight += w
    }
    return totalWeight > 0 ? Math.round((weightedSum / totalWeight) * 10) / 10 : 0
  }

  // Weight phases by check count (more checks = more influence on overall score)
  const pipelineScore = weightedAverage(scoredPhases, (r) => Math.max(r.checks_total, 1))

  // Determine pipeline integrity verdict
  let pipelineIntegrity = "UNKNOWN"
  const failedPhases = scoredPhases.filter(r => r.verdict === "FAIL")
  const marginalPhases = scoredPhases.filter(r => r.verdict === "MARGINAL")
  if (failedPhases.length > 0) {
    pipelineIntegrity = "DEGRADED"
  } else if (marginalPhases.length > 0) {
    pipelineIntegrity = "ACCEPTABLE"
  } else if (scoredPhases.length > 0) {
    pipelineIntegrity = pipelineScore >= 90 ? "EXCELLENT" : "HEALTHY"
  }

  const totalRetries = phaseResults.reduce((sum, r) => sum + r.retry_count, 0)
  const totalChecks = phaseResults.reduce((sum, r) => sum + r.checks_total, 0)
  const totalPassed = phaseResults.reduce((sum, r) => sum + r.checks_passed, 0)

  const summary = {
    arc_id: arcId,
    pipeline_score: pipelineScore,
    pipeline_integrity: pipelineIntegrity,
    phases_scored: scoredPhases.length,
    phases_skipped: phaseResults.filter(r => r.verdict === "SKIPPED").length,
    total_checks: totalChecks,
    total_passed: totalPassed,
    total_retries: totalRetries,
    phase_results: phaseResults,
    generated_at: new Date().toISOString(),
  }

  // Write JSON artifact
  Write(`${qaDir}/dashboard.json`, JSON.stringify(summary, null, 2))

  // Generate markdown table for PR body injection
  const markdown = generateDashboardMarkdown(summary)
  Write(`${qaDir}/dashboard.md`, markdown)

  return summary
}

// Generates a markdown table summarizing QA dashboard data.
function generateDashboardMarkdown(summary) {
  let md = `### QA Dashboard\n\n`
  md += `**Pipeline Score**: ${summary.pipeline_score}/100 | `
  md += `**Integrity**: ${summary.pipeline_integrity} | `
  md += `**Checks**: ${summary.total_passed}/${summary.total_checks} passed`
  if (summary.total_retries > 0) {
    md += ` | **Retries**: ${summary.total_retries}`
  }
  md += `\n\n`

  md += `| Phase | Verdict | Score | Artifact | Quality | Completeness | Checks |\n`
  md += `|-------|---------|-------|----------|---------|--------------|--------|\n`

  for (const r of summary.phase_results) {
    if (r.verdict === "SKIPPED") {
      md += `| ${r.phase} | SKIPPED | — | — | — | — | — |\n`
    } else {
      const checkStr = `${r.checks_passed}/${r.checks_total}`
      const retryStr = r.retry_count > 0 ? ` (${r.retry_count} retry)` : ""
      md += `| ${r.phase} | ${r.verdict}${retryStr} | ${r.overall_score} | ${r.artifact_score} | ${r.quality_score} | ${r.completeness_score} | ${checkStr} |\n`
    }
  }

  return md
}
```

### Dashboard Output Paths

| Artifact | Path | Format |
|----------|------|--------|
| Dashboard JSON | `tmp/arc/{id}/qa/dashboard.json` | Machine-readable summary |
| Dashboard Markdown | `tmp/arc/{id}/qa/dashboard.md` | Human-readable table for PR body |

### Integration Points

- **Phase 9 (ship)**: Reads `dashboard.md` and injects into PR body between Arc Pipeline Results and Review Summary
- **Post-arc completion report**: Reads `dashboard.json` for pipeline quality metrics
- **Checkpoint**: `pipeline_score` and `pipeline_integrity` can be stored in checkpoint totals

---

## See Also

- [arc-phase-work.md](arc-phase-work.md) — Work phase algorithm and backward compatibility notes
- [arc-phase-cleanup.md](arc-phase-cleanup.md) — Inter-phase cleanup and PHASE_PREFIX_MAP
- [arc-phase-constants.md](arc-phase-constants.md) — PHASE_ORDER and PHASE_TIMEOUTS
- [phase-qa-verifier.md](../../../agents/qa/phase-qa-verifier.md) — Generic QA agent (fallback)
- Dedicated QA agents: [forge-qa-verifier](../../../agents/qa/forge-qa-verifier.md), [work-qa-verifier](../../../agents/qa/work-qa-verifier.md), [code-review-qa-verifier](../../../agents/qa/code-review-qa-verifier.md), [mend-qa-verifier](../../../agents/qa/mend-qa-verifier.md), [test-qa-verifier](../../../agents/qa/test-qa-verifier.md), [gap-analysis-qa-verifier](../../../agents/qa/gap-analysis-qa-verifier.md)
- [discipline-work-loop.md](../../strive/references/discipline-work-loop.md) — Coverage matrix and worker report verification
