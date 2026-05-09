# Post-Arc — Full Algorithm

Post-pipeline lifecycle steps that run after all 26 default phases complete (or after the last non-skipped phase). Covers echo persistence, completion report display, and final zombie teammate sweep.

**Inputs**: completed checkpoint, plan path, echo config, `arcStart` timestamp
**Outputs**: echoes persisted, completion report displayed to user, stale teams cleaned
**Error handling**: Echo persist failure is non-blocking; ARC-9 sweep uses retry with backoff
**Consumers**: SKILL.md (Post-Arc stub)

> **Note**: The Plan Completion Stamp runs BEFORE these steps — see [arc-phase-completion-stamp.md](arc-phase-completion-stamp.md).
> `FORBIDDEN_PHASE_KEYS` is defined inline in SKILL.md and available in the orchestrator's context.

## Update State File with Completion

```javascript
// ── Update State File with Completion ──
const stateFile = ".rune/arc-phase-loop.local.md"
const stateExists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim()
if (stateExists === "yes") {
  const stateContent = Read(stateFile)
  const updatedContent = stateContent
    .replace(/active:\s*true/, 'active: false')
    .replace(/stop_reason:\s*null/, 'stop_reason: "completed"')
  Write(stateFile, updatedContent)
}
```

<!-- Post-Arc Echo Persist + Domain Decision Echo Persist removed in v3.0.0-alpha.3.
     v3.0.0-alpha.1 removed the persistent memory layer (no rune-echoes skill,
     no .rune/echoes/ runtime consumer). The blocks here previously sourced
     `scripts/lib/echo-append.sh` and called `rune_echo_append` — both no-ops
     post-alpha.1. Restore only if the echo runtime is reintroduced. -->
> - Graceful: if no `### Decisions` sections exist → skip, zero side effect

## Completion Report

```
The Tarnished has claimed the Elden Throne.

Plan: {plan_file}
Checkpoint: .rune/arc/{id}/checkpoint.json
Branch: {branch_name}

Phases:
  1.   FORGE:           {status} — enriched-plan.md
  2.   PLAN REVIEW:     {status} — plan-review.md ({verdict})
  2.5  PLAN REFINEMENT: {status} — {concerns_count} concerns extracted
  2.7  VERIFICATION:    {status} — {issues_count} issues
  5.   WORK:            {status} — {tasks_completed}/{tasks_total} tasks
  5.5  GAP ANALYSIS:    {status} — {addressed}/{total} criteria addressed
  5.8  GAP REMEDIATION: {status} — gap-remediation-report.md ({fixed_count} fixed, {deferred_count} deferred)
  6.   CODE REVIEW:     {status} — tome.md ({finding_count} findings)
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
Checkpoint: .rune/arc/{id}/checkpoint.json

Next steps:
1. Review TOME findings: tmp/arc/{id}/tome.md
2. git log --oneline — Review commits
3. {pr_url ? "Review PR: " + pr_url : "Create PR for branch " + branch_name}
4. /rune:rest — Clean up tmp/ artifacts when done
```

### DEFERRED Audit (Anti-Shirking Protocol, v2.9.0)

```javascript
// DEFERRED Audit — classify each deferred item for the completion report
if (exists(`tmp/arc/${id}/gap-remediation-report.md`)) {
  const gapReport = Read(`tmp/arc/${id}/gap-remediation-report.md`)
  // Match both ## and ### heading levels (gap-remediation.md uses ## Deferred Findings)
  const deferredSection = gapReport.match(/#{2,3} Deferred[\s\S]*?(?=#{2,3} |$)/)?.[0] || ''
  const deferredItems = (deferredSection.match(/^- \[ \] .+$/gm) || [])

  if (deferredItems.length > 0) {
    function classifyDeferred(desc) {
      if (/routing|wiring|wire|register|hook|entry.?point|SKILL\.md|hooks\.json|dispatcher|command.?table/i.test(desc)) return 'SHIRKING'
      if (/AC|acceptance.*criter/i.test(desc)) return 'SHIRKING'
      if (/too.*large|needs.*plan|separate.*scope|dedicated.*plan/i.test(desc)) return 'LEGITIMATE'
      return 'REVIEW_NEEDED'
    }

    completionReport += `\n## Deferred Items Audit\n\n`
    completionReport += `| Item | Classification | Reason |\n`
    completionReport += `|------|----------------|--------|\n`
    for (const item of deferredItems) {
      const classification = classifyDeferred(item)
      completionReport += `| ${item.slice(6)} | ${classification} | Auto-classified |\n`
    }
    const shirkingCount = deferredItems.filter(d => classifyDeferred(d) === 'SHIRKING').length
    if (shirkingCount > 0) {
      completionReport += `\n**WARNING**: ${shirkingCount} deferred item(s) classified as SHIRKING.\n`
    }
  }
}
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
      const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
      const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
      for (const m of members) {
        if (m.name) allMembers.push({ name: m.name, teamName })
      }
    } catch (e) {
      // Team config unreadable — dir may already be gone. That's fine.
    }
  }

  // ── Step 1.5: Kill orphaned bare agents (ATE-1 exemptions) ──
  // Bare agents (lore-analyst, research agents) spawned with run_in_background: true
  // have no team_name, so they're invisible to team-based cleanup (Steps 2-5).
  // Process-level kill is the only mechanism. Runs UNCONDITIONALLY — not gated
  // behind TeamDelete failure. Safe: kills only child claude/node processes.
  const arcOwnerPid = Bash(`echo $PPID`).trim()
  if (arcOwnerPid && /^\d+$/.test(arcOwnerPid)) {
    // MCP-PROTECT-003: Canonical _rune_kill_tree applies full MCP/LSP/connector classification.
    // Empty team_name → "teammates" filter falls back to claude+MCP-skip filter (correct for
    // bare agents that have no team registration).
    Bash(`source "${RUNE_PLUGIN_ROOT}/scripts/lib/process-tree.sh" && _rune_kill_tree "${arcOwnerPid}" "term" "0" "teammates" ""`)
  }

  // ── Step 2: Send ALL shutdown_requests at once (no sleep between) ──
  for (const member of allMembers) {
    SendMessage({ type: "shutdown_request", recipient: member.name, content: "Arc pipeline complete — final sweep" })
  }

  // ── Step 3: ONE single grace period (20s max) ──
  if (allMembers.length > 0) {
    Bash(`sleep 20`, { run_in_background: true })
  }

  // ── Step 4: TeamDelete — retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s) ──
  let sweepCleared = false
  const SWEEP_CLEANUP_DELAYS = [0, 3000, 6000, 10000]
  for (let attempt = 0; attempt < SWEEP_CLEANUP_DELAYS.length; attempt++) {
    if (attempt > 0) Bash(`sleep ${SWEEP_CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
    try { TeamDelete(); sweepCleared = true; break } catch (e) {
      if (attempt === SWEEP_CLEANUP_DELAYS.length - 1) warn(`ARC-9: TeamDelete failed after ${SWEEP_CLEANUP_DELAYS.length} attempts`)
    }
  }

  // ── Step 5: Filesystem fallback — only if TeamDelete never succeeded (QUAL-012) ──
  if (!sweepCleared) {
    // Process-level kill — terminate lingering teammates before filesystem cleanup.
    // MCP-PROTECT-003: Canonical _rune_kill_tree with empty team_name falls back to
    // claude+MCP-skip filter (correct here since multiple teams are being swept).
    Bash(`source "${RUNE_PLUGIN_ROOT}/scripts/lib/process-tree.sh" && _rune_kill_tree "$PPID" "2stage" "5" "teammates" ""`)
    // Filesystem cleanup for all checkpoint-recorded teams
    if (allTeamNames.length > 0) {
      const rmCommands = allTeamNames.map(tn =>
        `rm -rf "$CHOME/teams/${tn}/" "$CHOME/tasks/${tn}/" 2>/dev/null`
      ).join('; ')
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && ${rmCommands}`)
    }
    try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
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
