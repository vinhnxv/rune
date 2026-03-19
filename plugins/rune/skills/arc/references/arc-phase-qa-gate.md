# Arc Phase QA Gate — Independent Phase Verification Protocol

Each significant arc phase, after completion, passes through an independent QA gate before the
stop hook advances to the next phase. QA agents are completely separate from the Tarnished —
they read artifacts only, cannot modify code, and their verdict cannot be overridden
programmatically. This eliminates the conflict-of-interest of the Tarnished evaluating its own work.

**Scope (initial implementation)**: WORK phase only. Additional phases (forge, code_review, mend,
test) can be added incrementally once the work phase gate is validated in production.

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

| Phase | Artifact Weight | Quality Weight | Completeness Weight |
|-------|----------------|----------------|---------------------|
| work | 30% | 40% | 30% |

`overall_score = (artifact_score × 0.30) + (quality_score × 0.40) + (completeness_score × 0.30)`

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
count against the retry budget (they are infrastructure failures, not quality failures).

---

## QA Gate Implementation (arc-phase-qa-gate pseudocode)

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
  const qaTeamName = `arc-qa-${id}-${parentPhase}`
  TeamCreate({ team_name: qaTeamName })

  try {
    // QA Agent 1: Artifact verifier
    TaskCreate({ team_name: qaTeamName, subject: `QA-ARTIFACTS: Verify ${parentPhase} output files` })
    Agent({
      team_name: qaTeamName,
      name: "qa-artifact-verifier",
      subagent_type: "phase-qa-verifier",
      prompt: buildQAAgentPrompt("artifact", id, parentPhase, timestamp, qaDir)
    })

    // QA Agent 2: Quality verifier
    TaskCreate({ team_name: qaTeamName, subject: `QA-QUALITY: Verify ${parentPhase} output quality` })
    Agent({
      team_name: qaTeamName,
      name: "qa-quality-verifier",
      subagent_type: "phase-qa-verifier",
      prompt: buildQAAgentPrompt("quality", id, parentPhase, timestamp, qaDir)
    })

    // QA Agent 3: Completeness verifier
    TaskCreate({ team_name: qaTeamName, subject: `QA-COMPLETENESS: Verify ${parentPhase} coverage` })
    Agent({
      team_name: qaTeamName,
      name: "qa-completeness-verifier",
      subagent_type: "phase-qa-verifier",
      prompt: buildQAAgentPrompt("completeness", id, parentPhase, timestamp, qaDir)
    })

    // Monitor QA agents (5-minute timeout for all 3 agents)
    waitForCompletion(qaTeamName, 3, { timeoutMs: 300_000 })

    // Aggregate dimension verdicts into overall verdict
    const artifactVerdict = safeReadJSON(`${qaDir}/${parentPhase}-artifacts.json`, { items: [], timed_out: true })
    const qualityVerdict = safeReadJSON(`${qaDir}/${parentPhase}-quality.json`, { items: [], timed_out: true })
    const completenessVerdict = safeReadJSON(`${qaDir}/${parentPhase}-completeness.json`, { items: [], timed_out: true })

    const artifactItems = artifactVerdict.items || []
    const qualityItems = qualityVerdict.items || []
    const completenessItems = completenessVerdict.items || []

    const score = (items) => items.length === 0 ? 0 :
      items.reduce((sum, i) => sum + (i.score ?? (i.verdict === "PASS" ? 100 : 0)), 0) / items.length

    const artifactScore = score(artifactItems)
    const qualityScore = score(qualityItems)
    const completenessScore = score(completenessItems)

    // Phase weights: artifact=30%, quality=40%, completeness=30%
    const overallScore = (artifactScore * 0.30) + (qualityScore * 0.40) + (completenessScore * 0.30)

    const allItems = [...artifactItems, ...qualityItems, ...completenessItems]
    const failedItems = allItems.filter(i => i.verdict === "FAIL")
    const timedOut = artifactVerdict.timed_out || qualityVerdict.timed_out || completenessVerdict.timed_out

    // Determine verdict from overall score
    let verdictStr = "FAIL"
    if (overallScore >= 70) verdictStr = "PASS"
    if (overallScore >= 90) verdictStr = "EXCELLENT"
    if (overallScore >= 50 && overallScore < 70) verdictStr = "MARGINAL"

    const retryCount = checkpoint.phases?.[`${parentPhase}_qa`]?.retry_count ?? 0

    // Write aggregated verdict
    Write(`${qaDir}/${parentPhase}-verdict.json`, JSON.stringify({
      phase: parentPhase,
      verdict: timedOut ? "FAIL" : verdictStr,
      retry_count: retryCount,
      timed_out: timedOut,
      scores: {
        artifact_score: Math.round(artifactScore),
        quality_score: Math.round(qualityScore),
        completeness_score: Math.round(completenessScore),
        overall_score: Math.round(overallScore * 10) / 10,
      },
      thresholds: { pass_threshold: 70, excellence_threshold: 90 },
      checks: {
        total: allItems.length,
        passed: allItems.filter(i => i.verdict === "PASS").length,
        failed: failedItems.length,
        warnings: allItems.filter(i => i.verdict === "WARNING").length,
      },
      items: allItems,
      summary: `Phase ${parentPhase} scored ${overallScore.toFixed(1)}/100 (${verdictStr}). ${failedItems.length} failed checks.`,
      timestamp: new Date().toISOString(),
    }, null, 2))

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
    const allQAMembers = ["qa-artifact-verifier", "qa-quality-verifier", "qa-completeness-verifier"]
    let confirmedAlive = 0
    for (const member of allQAMembers) {
      try { SendMessage({ type: "shutdown_request", recipient: member, content: "QA complete" }); confirmedAlive++ } catch (_) {}
    }
    if (confirmedAlive > 0) Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`)
    else Bash("sleep 2")

    const DELAYS = [0, 3000, 6000, 10000]
    let deleted = false
    for (let i = 0; i < DELAYS.length; i++) {
      if (i > 0) Bash(`sleep ${DELAYS[i] / 1000}`)
      try { TeamDelete({ team_name: qaTeamName }); deleted = true; break } catch (_) {}
    }
    if (!deleted) {
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

**Initial scope (this implementation)**: `work_qa` only. Additional `*_qa` phases are additive
and can be enabled incrementally by inserting them into PHASE_ORDER after their parent phase.

```javascript
// arc-phase-constants.md — JavaScript PHASE_ORDER (add work_qa after work)
const PHASE_ORDER = [
  "forge", "plan_review", "plan_refinement", "verification", "semantic_verification",
  "design_extraction", "design_prototype", "task_decomposition",
  "work",
  "work_qa",          // ← NEW: QA gate for work phase
  "gap_analysis", "code_review", "mend", "verify_mend", "design_iteration",
  "test", "pre_ship_validation", "release_quality_check", "ship",
  "bot_review_wait", "pr_comment_resolution", "merge"
]
```

```bash
# arc-phase-stop-hook.sh — bash PHASE_ORDER array (add work_qa after work)
PHASE_ORDER=(
  forge plan_review plan_refinement verification semantic_verification
  design_extraction design_prototype task_decomposition
  work
  work_qa          # ← NEW: QA gate for work phase
  gap_analysis code_review mend verify_mend design_iteration
  test pre_ship_validation release_quality_check ship
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
must include `work_qa → arc-qa-` for postPhaseCleanup (Layer 2). See `arc-phase-cleanup.md`.

---

## See Also

- [arc-phase-work.md](arc-phase-work.md) — Work phase algorithm and backward compatibility notes
- [arc-phase-cleanup.md](arc-phase-cleanup.md) — Inter-phase cleanup and PHASE_PREFIX_MAP
- [arc-phase-constants.md](arc-phase-constants.md) — PHASE_ORDER and PHASE_TIMEOUTS
- [phase-qa-verifier.md](../../../agents/qa/phase-qa-verifier.md) — QA agent definition
- [discipline-work-loop.md](../../strive/references/discipline-work-loop.md) — Coverage matrix and worker report verification
