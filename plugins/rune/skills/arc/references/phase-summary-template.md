# Phase Summary Template

Arc phase summaries are written by the orchestrator at the end of each **phase group** to compress completed phase history before entering the next group. This prevents inline phase history from accumulating across 40 phases and exhausting context.

## Phase Groups

| Group | Phases Covered | Written After |
|-------|---------------|---------------|
| `forge` | Phases 1–2.7 (FORGE, PLAN REVIEW, PLAN REFINEMENT, VERIFICATION) | Phase 2.7 completes |
| `verify` | Phases 2.8–4.5 (SEMANTIC VERIFICATION, TASK DECOMPOSITION) | Phase 4.5 completes |
| `work` | Phases 5–5.8 (WORK, GAP ANALYSIS, CODEX GAP ANALYSIS, GAP REMEDIATION, GOLDMASK VERIFICATION) | Phase 5.7 completes |
| `review` | Phases 6–7.5 (CODE REVIEW, GOLDMASK CORRELATION, MEND, VERIFY MEND, convergence cycles) | Phase 7.5 concludes (convergence converged or halted) |
| `ship` | Phases 7.7–9.5 (TEST, TEST COVERAGE CRITIQUE, PRE-SHIP VALIDATION, RELEASE QUALITY CHECK, BOT REVIEW WAIT, PR COMMENT RESOLUTION, SHIP, MERGE) | Phase 9.5 completes (or last executed phase) |

## Summary File Paths

```
tmp/arc/{id}/phase-summary-forge.md
tmp/arc/{id}/phase-summary-verify.md
tmp/arc/{id}/phase-summary-work.md
tmp/arc/{id}/phase-summary-review.md
tmp/arc/{id}/phase-summary-ship.md
```

## Template

```markdown
# Arc Phase Summary: {phase_group_name}

**Plan**: {plan_file_path}
**Arc ID**: {arc_id}
**Phases**: {phase_range}
**Status**: {completed|partial|failed}

## Accomplished
- {bullet points}

## Decisions Made
- {key decisions}

## Artifacts Produced
| Artifact | Path | Status |
|----------|------|--------|
| {name} | {path} | {ok|warning|error} |

## Issues Encountered
- {issues and resolutions}

## Carry-Forward State
- {state for subsequent phases}
```

## Behavioral Contract (C11 — Read-Back Gate)

**CRITICAL**: After writing a phase group summary, the orchestrator MUST treat the summary file as the **sole reference** for that phase group. Inline phase history (verbose phase logs, intermediate checkpoint reads from completed phases) MUST be discarded from working context after the summary is written.

```
MANDATORY after writing each summary:
1. Write phase-summary-{group}.md using the template above
2. Update checkpoint: { phase_summaries: { {group}: "tmp/arc/{id}/phase-summary-{group}.md" } }
3. From this point forward: reference ONLY the summary file for that group
4. Do NOT re-read individual phase artifacts from the completed group
5. If context compaction occurs: read phase_summaries from checkpoint to restore state
```

**Why**: Arc's 40-phase pipeline accumulates significant inline context across phases. Without compression, the orchestrator hits context limits by Phase 7-8. Summaries compress multi-phase history into a fixed-size read (~50 lines per group) while preserving all carry-forward state needed for subsequent phases.

## postPhaseCleanup Considerations

Phase summary files are **persistent artifacts** — do NOT include them in `postPhaseCleanup` filesystem cleanup. They live in `tmp/arc/{id}/` alongside other arc artifacts (enriched-plan.md, tome.md, etc.) and are cleaned only when `rest.md` runs post-arc cleanup for the entire arc session.

The checkpoint field `phase_summaries` tracks which groups have been summarized. On `--resume`, the orchestrator reads `checkpoint.phase_summaries` to determine which groups are already compressed.

## Checkpoint Integration

```javascript
// After writing a phase group summary:
updateCheckpoint({
  phase_summaries: {
    ...checkpoint.phase_summaries,
    [groupName]: `tmp/arc/${id}/phase-summary-${groupName}.md`
  }
})

// On --resume: check which summaries already exist
const summaries = checkpoint.phase_summaries ?? {}
// For each completed group, read summary instead of re-reading phase artifacts
for (const [group, summaryPath] of Object.entries(summaries)) {
  const groupSummary = Read(summaryPath)  // ~50 lines — context-efficient
  // Use groupSummary as context for the resumed phase
}
```
