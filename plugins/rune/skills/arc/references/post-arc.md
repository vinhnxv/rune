# Post-Arc — Full Algorithm

Post-pipeline lifecycle steps that run after all 27 phases complete (or after the last non-skipped phase). Covers scheduled task cleanup, echo persistence, completion report display, and final zombie teammate sweep.

**Inputs**: completed checkpoint, plan path, echo config, `arcStart` timestamp
**Outputs**: scheduled task deleted, echoes persisted, completion report displayed to user, stale teams cleaned
**Error handling**: Echo persist failure is non-blocking; ARC-9 sweep uses retry with backoff
**Consumers**: SKILL.md (Post-Arc stub)

> **Note**: The Plan Completion Stamp runs BEFORE these steps — see [arc-phase-completion-stamp.md](arc-phase-completion-stamp.md).
> `FORBIDDEN_PHASE_KEYS` is defined inline in SKILL.md and available in the orchestrator's context.

## Scheduled Task Cleanup (FIRST — Before All Other Steps)

Delete the monitoring task as the FIRST operation. This must run before echo persist, completion report, or ARC-9 sweep to close the race window where the monitoring task could fire on a completed arc.

```javascript
// ── Delete Monitoring Task (CronDelete) ──
// This MUST be the first operation in post-arc to prevent spurious resumes.
const cronTaskId = checkpoint.cron_task_id
if (cronTaskId && typeof CronDelete !== 'undefined') {
  try {
    // Verify task exists before attempting deletion
    const existingTasks = CronList()
    const taskExists = existingTasks.some(t => t.id === cronTaskId)
    if (taskExists) {
      CronDelete({ task_id: cronTaskId })
      log(`[ARC-SCHEDULER] Deleted monitoring task ${cronTaskId} on completion`)
    } else {
      log(`[ARC-SCHEDULER] Monitoring task ${cronTaskId} already expired or deleted`)
    }
    checkpoint.cron_task_id = null
  } catch (e) {
    warn(`[ARC-SCHEDULER] Failed to delete monitoring task ${cronTaskId}: ${e.message}`)
    // Non-blocking — arc completion proceeds regardless
  }
}

// ── Update State File with Completion ──
// Set stop_reason to prevent monitoring task from resuming
const stateFile = ".claude/arc-phase-loop.local.md"
const stateExists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
if (stateExists === "yes") {
  const stateContent = Read(stateFile)
  const updatedContent = stateContent
    .replace(/active:\s*true/, 'active: false')
    .replace(/stop_reason:\s*null/, 'stop_reason: "completed"')
  Write(stateFile, updatedContent)
}
```

## Post-Arc Echo Persist

After the plan stamp, persist arc quality metrics to echoes for cross-session learning:

```javascript
if (exists(".claude/echoes/")) {
  // CDX-009 FIX: totalDuration is in milliseconds (Date.now() - arcStart), so divide by 60_000 for minutes.
  const totalDuration = Date.now() - arcStart  // milliseconds
  const metrics = {
    plan: checkpoint.plan_file,
    duration_minutes: Math.round(totalDuration / 60_000),
    phases_completed: Object.values(checkpoint.phases).filter(p => p.status === "completed").length,
    tome_findings: { p1: p1Count, p2: p2Count, p3: p3Count },
    convergence_cycles: checkpoint.convergence.history.length,
    mend_fixed: mendFixedCount,
    gap_addressed: addressedCount,
    gap_missing: missingCount,
  }

  appendEchoEntry(".claude/echoes/planner/MEMORY.md", {
    layer: "inscribed",
    source: `rune:arc ${id}`,
    content: `Arc completed: ${metrics.phases_completed}/${PHASE_ORDER.length} phases, ` +
      `${metrics.tome_findings.p1} P1 findings, ` +
      `${metrics.convergence_cycles} mend cycle(s), ` +
      `${metrics.gap_missing} missing criteria. ` +
      `Duration: ${metrics.duration_minutes}min.`
  })
}
```

## Completion Report

```
The Tarnished has claimed the Elden Throne.

Plan: {plan_file}
Checkpoint: .claude/arc/{id}/checkpoint.json
Branch: {branch_name}

Phases:
  1.   FORGE:           {status} — enriched-plan.md
  2.   PLAN REVIEW:     {status} — plan-review.md ({verdict})
  2.5  PLAN REFINEMENT: {status} — {concerns_count} concerns extracted
  2.7  VERIFICATION:    {status} — {issues_count} issues
  2.8  SEMANTIC VERIFY: {status} — codex-semantic-verification.md
  5.   WORK:            {status} — {tasks_completed}/{tasks_total} tasks
  5.5  GAP ANALYSIS:    {status} — {addressed}/{total} criteria addressed
  5.6  CODEX GAP:       {status} — codex-gap-analysis.md
  5.8  GAP REMEDIATION: {status} — gap-remediation-report.md ({fixed_count} fixed, {deferred_count} deferred)
  5.7  GOLDMASK VERIFY: {status} — goldmask-verification.md ({finding_count} findings, {critical_count} critical)
  6.   CODE REVIEW:     {status} — tome.md ({finding_count} findings)
  6.5  GOLDMASK CORR:   {status} — goldmask-correlation.md ({correlation_count} correlations, {human_review_count} human review)
  7.   MEND:            {status} — {fixed}/{total} findings resolved
  7.5  VERIFY MEND:     {status} — {convergence_verdict} (cycle {convergence.round + 1}/{convergence.tier.maxCycles})
  7.7  TEST:            {status} — test-report.md ({pass_rate}% pass rate, tiers: {tiers_run})
  8.5  PRE-SHIP:        {status} — pre-ship-report.md ({verdict})
  9.   SHIP:            {status} — PR: {pr_url || "skipped"}
  9.5  MERGE:           {status} — {merge_strategy} {wait_ci ? "(auto-merge pending)" : "(merged)"}

PR: {pr_url || "N/A — create manually with `gh pr create`"}

Review-Mend Convergence:
  Tier: {convergence.tier.name} ({convergence.tier.maxCycles} max cycles)
  Reason: {convergence.tier.reason}
  Cycles completed: {convergence.round + 1}/{convergence.tier.maxCycles}

  {for each entry in convergence.history:}
  Cycle {N}: {findings_before} → {findings_after} findings ({verdict})

Commits: {commit_count} on branch {branch_name}
Files changed: {file_count}
Time: {total_duration}

Artifacts: tmp/arc/{id}/
Checkpoint: .claude/arc/{id}/checkpoint.json

Next steps:
1. Review TOME findings: tmp/arc/{id}/tome.md
2. git log --oneline — Review commits
3. {pr_url ? "Review PR: " + pr_url : "Create PR for branch " + branch_name}
4. /rune:rest — Clean up tmp/ artifacts when done
```

## Post-Arc Final Sweep (ARC-9)

> **IMPORTANT — Execution order**: This step runs AFTER the completion report. It catches zombie
> teammates left alive by incomplete phase cleanup. Without this sweep, the lead session spins
> on idle notifications ("Twisting...") because the SDK still holds leadership state from
> the last phase's team. This is the safety net — `prePhaseCleanup` handles inter-phase cleanup,
> but there is no subsequent phase to trigger cleanup after Phase 9.5 (the last phase).
> Phases 9 and 9.5 are orchestrator-only so their cleanup is a no-op, but Phase 7 (MEND)
> and Phase 6 (CODE REVIEW) summon teams that need cleanup.
>
> **TIME BUDGET: 30 seconds max.** ARC-9 must NOT become the bottleneck that prevents session
> termination. Send all shutdown_requests at once, wait ONCE, then attempt TeamDelete.
> If cleanup is incomplete, the `on-session-stop.sh` Stop hook handles remaining cleanup
> automatically via filesystem fallback.
>
> **CRITICAL — Idle notification trap**: After ARC-9, do NOT process any `TeammateIdle`
> notifications. Responding to zombie teammate idle messages creates an infinite loop that
> prevents the session from ending. IGNORE all teammate messages after this point.

```javascript
// POST-ARC FINAL SWEEP (ARC-9)
// TIME BUDGET: 30 seconds max. Do NOT exceed this.
// Catches zombie teammates from the last delegated phases.
// If incomplete, on-session-stop.sh handles remaining cleanup.

// Resolve config directory once (CLAUDE_CONFIG_DIR aware)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

try {
  // ── Step 1: Collect ALL team members from ALL phases at once ──
  // Do NOT sleep per-phase — collect all members first, then one single sleep.
  const allMembers = []  // { name, teamName }
  const allTeamNames = []

  for (const [phaseName, phaseInfo] of Object.entries(checkpoint.phases)) {
    if (FORBIDDEN_PHASE_KEYS.has(phaseName)) continue
    if (!phaseInfo?.team_name || typeof phaseInfo.team_name !== 'string') continue
    if (!/^[a-zA-Z0-9_-]+$/.test(phaseInfo.team_name)) continue

    const teamName = phaseInfo.team_name
    allTeamNames.push(teamName)

    try {
      const teamConfig = Read(`${CHOME}/teams/${teamName}/config.json`)
      const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
      for (const m of members) {
        if (m.name) allMembers.push({ name: m.name, teamName })
      }
    } catch (e) {
      // Team config unreadable — dir may already be gone. That's fine.
    }
  }

  // ── Step 2: Send ALL shutdown_requests at once (no sleep between) ──
  for (const member of allMembers) {
    SendMessage({ type: "shutdown_request", recipient: member.name, content: "Arc pipeline complete — final sweep" })
  }

  // ── Step 3: ONE single grace period (20s max) ──
  if (allMembers.length > 0) {
    Bash(`sleep 20`)
  }

  // ── Step 4: TeamDelete — single attempt ──
  // If this fails, filesystem fallback handles it. No retry loop.
  let sweepCleared = false
  try { TeamDelete(); sweepCleared = true } catch (e) { /* expected if no active team */ }

  // ── Step 5: Filesystem fallback — rm -rf all checkpoint-recorded teams ──
  // Runs regardless of TeamDelete result to ensure dirs are cleaned.
  // on-session-stop.sh also does this, but doing it here is faster.
  if (allTeamNames.length > 0) {
    const rmCommands = allTeamNames.map(tn =>
      `rm -rf "$CHOME/teams/${tn}/" "$CHOME/tasks/${tn}/" 2>/dev/null`
    ).join('; ')
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && ${rmCommands}`)
  }

  // ── Step 6: Final TeamDelete after filesystem cleanup ──
  if (!sweepCleared) {
    try { TeamDelete() } catch (e) { /* done */ }
  }

  // NOTE: Strategy D (prefix-based sweep) is deliberately REMOVED from ARC-9.
  // The on-session-stop.sh Stop hook handles prefix-based orphan cleanup
  // automatically when the session ends. Keeping it here added 10-30s of
  // find + cat + rm per prefix, which caused the session to hang.

} catch (e) {
  // Defensive — final sweep must NEVER halt the pipeline or prevent response completion.
  warn(`ARC-9: Final sweep failed (${e.message}) — on-session-stop.sh will handle cleanup`)
}

// ══════════════════════════════════════════════════════════════════════
// RESPONSE COMPLETE — FINISH YOUR TURN NOW
// ══════════════════════════════════════════════════════════════════════
// After this point, do NOT:
//   - Process any TeammateIdle notifications (creates infinite loop)
//   - Respond to any teammate messages
//   - Use any tools
//   - Attempt additional cleanup
//
// The on-session-stop.sh Stop hook automatically handles:
//   - Remaining team dirs (prefix-based scan + rm-rf)
//   - State files (active → stopped)
//   - Arc checkpoints (in_progress → cancelled)
//
// Your turn ENDS HERE. Return control to the user.
// The session stays open for further prompts.
// ══════════════════════════════════════════════════════════════════════
```
