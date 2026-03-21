# Phase 5.8: GAP REMEDIATION — Full Algorithm

New phase between Codex Gap Analysis (5.6) and Goldmask Verification (5.7). Automatically fixes FIXABLE findings from the Phase 5.5 Inspector Ashes VERDICT before handing off to code review, reducing P2/P3 noise and improving the signal-to-noise ratio in the TOME.

**Team**: `arc-gap-fix-{id}` — follows ATE-1 pattern
**Timeout**: 900_000ms (15 min: inner 10m + 5m setup)
**Inputs**: `tmp/arc/{id}/gap-analysis-verdict.md` (from Phase 5.5 STEP B), `tmp/arc/{id}/codex-gap-analysis.md` (from Phase 5.6), checkpoint `needs_remediation` + `codex_needs_remediation` flags
**Outputs**: `tmp/arc/{id}/gap-remediation-report.md`, committed code fixes
**Talisman key**: `arc.gap_analysis.remediation`

---

## STEP 1: Gate Check

```javascript
// Gate A (deterministic): needs_remediation from Phase 5.5 STEP D
const deterministicNeedsRemediation = checkpoint.phases?.gap_analysis?.needs_remediation === true

// Gate B (Codex): codex_needs_remediation from Phase 5.6
const codexNeedsRemediation = checkpoint.phases?.codex_gap_analysis?.codex_needs_remediation === true
const codexFindingCount = checkpoint.phases?.codex_gap_analysis?.codex_finding_count ?? 0
const codexThreshold = checkpoint.phases?.codex_gap_analysis?.codex_threshold ?? 5

// Gate C: remediation enabled in talisman
const remediationEnabled = talisman?.arc?.gap_analysis?.remediation?.enabled !== false  // Default: true

// Decision: either signal triggers remediation (if enabled)
const shouldRemediate = remediationEnabled && (deterministicNeedsRemediation || codexNeedsRemediation)

if (!shouldRemediate) {
  const reason = !remediationEnabled
    ? "arc.gap_analysis.remediation.enabled: false in talisman"
    : `Neither Phase 5.5 nor Phase 5.6 flagged needs_remediation (deterministicNeedsRemediation=${deterministicNeedsRemediation}, codexNeedsRemediation=${codexNeedsRemediation}, codexFindingCount=${codexFindingCount}, codexThreshold=${codexThreshold})`

  Write(`tmp/arc/${id}/gap-remediation-report.md`,
    `# Gap Remediation — Skipped\n\n**Reason**: ${reason}\n**Date**: ${new Date().toISOString()}\n`)

  updateCheckpoint({
    phase: "gap_remediation",
    status: "skipped",
    artifact: `tmp/arc/${id}/gap-remediation-report.md`,
    artifact_hash: sha256(Read(`tmp/arc/${id}/gap-remediation-report.md`)),
    phase_sequence: 5.8,
    team_name: null
  })
  return  // Skip to next phase
}

// Gate decision logging (AC 4.10)
log(`Phase 5.8: Gate triggered by: deterministic=${deterministicNeedsRemediation}, codex=${codexNeedsRemediation} (${codexFindingCount} findings >= threshold ${codexThreshold})`)

// Determine fixer inputs based on which gate triggered
const fixerInputs = []
if (deterministicNeedsRemediation) {
  fixerInputs.push(`tmp/arc/${id}/gap-analysis-verdict.md`)
}
if (codexNeedsRemediation) {
  fixerInputs.push(`tmp/arc/${id}/codex-gap-analysis.md`)
}

// ── Task Remediation (v1.169.0) ──
// When needs_task_remediation is true, gap-remediation also implements
// missing plan tasks — not just FIXABLE findings from inspector verdicts.
const needsTaskRemediation = checkpoint.phases?.gap_analysis?.needs_task_remediation === true
const missingPlanTasks = checkpoint.phases?.gap_analysis?.missing_tasks ?? []
const taskCompletionPct = checkpoint.phases?.gap_analysis?.task_completion_pct ?? 100
const taskCompletionFloor = checkpoint.phases?.gap_analysis?.task_completion_floor ?? 100

if (needsTaskRemediation && missingPlanTasks.length > 0) {
  log(`Phase 5.8: Task remediation triggered — ${missingPlanTasks.length} missing tasks ` +
      `(${taskCompletionPct}% < floor ${taskCompletionFloor}%)`)
  // Missing tasks will be handled in STEP 3.5 (below) alongside FIXABLE findings
}
```

---

## STEP 1.5: DEFERRED Classification (Anti-Shirking Protocol, v2.9.0)

```javascript
// DEFERRED Classification Rules (Anti-Shirking Protocol)
// A finding can only be DEFERRED if it passes ALL checks.
// Called before any DEFERRED classification in STEP 10/11.
function canDefer(finding, allFindings) {
  // RULE 1: Wiring/routing tasks (<50 LOC estimated) are NEVER deferrable
  // Heuristic: check description + file path for wiring keywords
  const isWiringTask = /routing|wiring|wire|register|hook|entry.?point|SKILL\.md|hooks\.json|dispatcher|command.?table/i
    .test(finding.description + ' ' + (finding.file || ''))
  // Heuristic: estimate LOC from file reference (files <200 lines = small task)
  const isSmallTask = true  // Default conservative — treat unknown sizes as small
  if (isWiringTask && isSmallTask) {
    return { canDefer: false, reason: "WIRING_REQUIRED: routing/wiring task" }
  }

  // RULE 2: If deferring creates dead code (other findings depend on this one)
  const dependents = allFindings.filter(f =>
    (f.depends_on?.includes(finding.id)) ||
    (f.file === finding.file && f.id !== finding.id)
  )
  const wouldCreateDeadCode = dependents.some(d => d.status === 'FIXED')
  if (wouldCreateDeadCode) {
    return { canDefer: false, reason: "DEAD_CODE: deferring would make fixed code unreachable" }
  }

  // RULE 3: If plan acceptance criteria reference this finding's file
  const planContent = Read(checkpoint.plan_file)
  const acLines = (planContent.match(/^\d+\.\s*\[.\]\s*.+$/gm) || [])
  const acMentionsFile = acLines.some(ac =>
    finding.file && ac.toLowerCase().includes(finding.file.split('/').pop().toLowerCase())
  )
  if (acMentionsFile) {
    return { canDefer: false, reason: "AC_REQUIRED: acceptance criterion references this file" }
  }

  // RULE 4: Genuinely large features can be deferred
  return { canDefer: true, reason: "LEGITIMATE: large feature, needs dedicated plan" }
}
```

---

## STEP 2: Pre-Fix SHA Capture

```javascript
// Capture current HEAD SHA before any fixes are applied
// Used in post-fix verification to isolate remediation commits
const preSha = Bash("git rev-parse HEAD 2>/dev/null").trim()
if (!/^[0-9a-f]{40}$/.test(preSha)) {
  warn("Phase 5.8: Could not capture pre-fix SHA — verification may be imprecise")
}
```

---

## STEP 3: Parse FIXABLE Findings

```javascript
// Read the VERDICT from Phase 5.5 STEP B
const verdictContent = Read(`tmp/arc/${id}/gap-analysis-verdict.md`)

// Parse FIXABLE gaps from gap-analysis-verdict.md (arc context — distinct from standalone VERDICT.md)
// FIXABLE = findings tagged with "FIXABLE" label or P2/P3 findings without "architecture" or "design" category
// Format expected from Inspector Ashes:
//   - [ ] **[GRACE-001] {Title}** in `{file}:{line}`
//     - **Fixable**: yes
//   OR tag lines containing: <!-- FIXABLE -->
const fixablePattern = /^- \[ \].*?\[([A-Z]+-\d+)\].*?`([^`]+)`/gm
const FIXABLE_TAG = /\*\*Fixable\*\*:\s*yes|<!--\s*FIXABLE\s*-->/i

const allFindings = []
let fMatch
const verdictLines = verdictContent.split('\n')
for (let i = 0; i < verdictLines.length; i++) {
  const line = verdictLines[i]
  const findingMatch = line.match(/^- \[ \].*?\[([A-Z]+-\d+)\](.*)/)
  if (!findingMatch) continue

  const findingId = findingMatch[1]
  const findingText = findingMatch[2].trim()

  // Look ahead up to 6 lines for fixable tag, file ref, and description
  // BACK-005: Stop lookahead at next finding boundary to avoid crossing into adjacent findings
  let lookaheadEnd = Math.min(i + 8, verdictLines.length)
  for (let j = i + 1; j < lookaheadEnd; j++) {
    if (/^- \[ \]|^- \[x\]/.test(verdictLines[j])) { lookaheadEnd = j; break }
  }
  const context = verdictLines.slice(i + 1, lookaheadEnd).join('\n')
  const isFixable = FIXABLE_TAG.test(line) || FIXABLE_TAG.test(context)
  const fileMatch = (line + '\n' + context).match(/`([a-zA-Z0-9._\-\/]+):(\d+)`/)

  if (isFixable && fileMatch) {
    const filePath = fileMatch[1]
    const lineNum = parseInt(fileMatch[2])
    // SEC-003: Validate file path before any filesystem use
    if (/^[a-zA-Z0-9._\-\/]+$/.test(filePath) && !filePath.includes('..') && !filePath.startsWith('/')) {
      allFindings.push({
        id: findingId,
        description: findingText.replace(/\*\*\[.*?\]\*\*/g, '').replace(/`.*?`/g, '').trim(),
        file: filePath,
        line: lineNum,
        context: context.slice(0, 300)
      })
    }
  }
}

// Cap at max_fixes from talisman
const maxFixes = talisman?.arc?.gap_analysis?.remediation?.max_fixes ?? 20
const cappedFindings = allFindings.slice(0, maxFixes)

log(`Phase 5.8: ${allFindings.length} FIXABLE findings, capping at ${cappedFindings.length}`)

// ── STEP 3.5: Merge Task Remediation Items (v1.169.0) ──
// When missing plan tasks exist, convert them to remediation work items
// alongside FIXABLE findings. Task items get higher priority.
const taskRemediationItems = []
if (needsTaskRemediation && missingPlanTasks.length > 0) {
  // Read the enriched plan for task context
  const enrichedPlan = (() => {
    try { return Read(`tmp/arc/${id}/enriched-plan.md`) } catch { return "" }
  })()

  for (const task of missingPlanTasks) {
    // Extract the task section from the plan for context
    const taskSectionPattern = new RegExp(
      `### Task ${task.id.replace(/\./g, '\\.')}[:\\s].*?(?=### (?:Task \\d|[A-Za-z])|##[^#]|$)`, 's'
    )
    const sectionMatch = enrichedPlan.match(taskSectionPattern)
    const TASK_DESC_LIMIT = 4000
    const taskContext = sectionMatch
      ? (sectionMatch[0].length > TASK_DESC_LIMIT
          ? sectionMatch[0].slice(0, TASK_DESC_LIMIT) + '\n\n<!-- TRUNCATED: Full task in plan file -->'
          : sectionMatch[0])
      : task.title

    taskRemediationItems.push({
      id: `TASK-${task.id}`,
      description: `Implement plan task ${task.id}: ${task.title}`,
      type: "task",
      context: taskContext
    })
  }
  log(`Phase 5.8: ${taskRemediationItems.length} missing plan tasks added to remediation queue`)
}

// Combined gate: FIXABLE findings + missing tasks
const hasWork = cappedFindings.length > 0 || taskRemediationItems.length > 0

// DEEP-003 FIX: Convert task remediation items into the same format as FIXABLE findings
// so they are visible to STEP 6 (grouping) and STEP 7 (fixer prompt injection).
// Task items use a synthetic file path based on their first **Files**: reference.
for (const taskItem of taskRemediationItems) {
  // Extract first file reference from task context for grouping
  const fileMatch = taskItem.context.match(/`([a-zA-Z0-9._\-\/]+\.\w+)`/)
  const taskFile = fileMatch ? fileMatch[1] : `plan-task-${taskItem.id}`

  cappedFindings.push({
    id: taskItem.id,
    description: taskItem.description,
    file: taskFile,
    line: 0,
    context: taskItem.context.slice(0, 500),
    isTaskRemediation: true  // Flag for fixer prompt to handle differently
  })
}

if (!hasWork) {
  Write(`tmp/arc/${id}/gap-remediation-report.md`,
    `# Gap Remediation — No Fixable Gaps\n\n` +
    `**Date**: ${new Date().toISOString()}\n` +
    `**VERDICT**: ${verdictContent.slice(0, 200)}\n\n` +
    `No FIXABLE findings or missing tasks found. ` +
    `Manual review may be required for flagged gaps.\n`)

  updateCheckpoint({
    phase: "gap_remediation",
    status: "completed",
    artifact: `tmp/arc/${id}/gap-remediation-report.md`,
    artifact_hash: sha256(Read(`tmp/arc/${id}/gap-remediation-report.md`)),
    phase_sequence: 5.8,
    team_name: null,
    fixed_count: 0,
    deferred_count: allFindings.length
  })
  return
}
```

---

## STEP 4: Write State File

```javascript
// State file for crash recovery + /rune:rest cleanup detection
const stateFile = `tmp/.rune-gap-fix-${id}.json`
Write(stateFile, JSON.stringify({
  status: "active",
  phase: "gap_remediation",
  id,
  started: new Date().toISOString(),
  pre_sha: preSha,
  finding_count: cappedFindings.length,
  verdict_path: `tmp/arc/${id}/gap-analysis-verdict.md`
}))
```

---

## STEP 5: Pre-Create Guard (team-sdk/references/engines.md 3-step protocol)

```javascript
const fixTeamName = `arc-gap-fix-${id}`

// SEC-003: Validate team name before any filesystem operations
if (!/^[a-zA-Z0-9_-]+$/.test(fixTeamName)) {
  warn("Phase 5.8: Invalid gap-fix team name — skipping remediation")
  Write(`tmp/arc/${id}/gap-remediation-report.md`,
    `# Gap Remediation — Skipped\n\n**Reason**: Invalid team name generated.\n`)
  // BACK-006: Clean up state file on early exit (written in STEP 4)
  const earlyStateData = JSON.parse(Read(stateFile))
  earlyStateData.status = "skipped"
  earlyStateData.completed = new Date().toISOString()
  Write(stateFile, JSON.stringify(earlyStateData))
  updateCheckpoint({ phase: "gap_remediation", status: "skipped", phase_sequence: 5.8, team_name: null })
  return
}

// Step A: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
const FIX_RETRY_DELAYS = [0, 3000, 8000]
let fixDeleteSucceeded = false
for (let attempt = 0; attempt < FIX_RETRY_DELAYS.length; attempt++) {
  if (attempt > 0) {
    warn(`Phase 5.8: TeamDelete attempt ${attempt + 1} failed, retrying in ${FIX_RETRY_DELAYS[attempt] / 1000}s...`)
    Bash(`sleep ${FIX_RETRY_DELAYS[attempt] / 1000}`)
  }
  try { TeamDelete(); fixDeleteSucceeded = true; break } catch (e) { /* retry */ }
}

// Step B: Filesystem fallback (only when Step A failed)
if (!fixDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${fixTeamName}/" "$CHOME/tasks/${fixTeamName}/" 2>/dev/null`)
  // Step C: Cross-workflow scan — stale arc-gap-fix teams only
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && find "$CHOME/teams/" -maxdepth 1 -type d -name "arc-gap-fix-*" -mmin +30 -exec rm -rf {} + 2>/dev/null`)
  try { TeamDelete() } catch (e2) { /* proceed to TeamCreate */ }
}
```

---

## STEP 6: TeamCreate + Group Gaps by File + Create Tasks

```javascript
TeamCreate({ team_name: fixTeamName })

// Group findings by target file for batched fixing
const gapsByFile = cappedFindings.reduce((acc, gap) => {
  if (!acc[gap.file]) acc[gap.file] = []
  acc[gap.file].push(gap)
  return acc
}, {})

// Signal directory for lifecycle tracking
const signalDir = `tmp/.rune-signals/${fixTeamName}`
Bash(`mkdir -p "${signalDir}"`)
Write(`${signalDir}/.expected`, String(Object.keys(gapsByFile).length))

const fixerTasks = []
for (const [file, gaps] of Object.entries(gapsByFile)) {
  const taskId = TaskCreate({
    subject: `gap-fixer: fix ${gaps.length} gap(s) in ${file}`,
    description: `Fix FIXABLE gaps in ${file}: ${gaps.map(g => g.id).join(", ")}. ` +
      `Read the file, apply targeted fixes for each gap, write the corrected code.`,
    activeForm: `Fixing gaps in ${file}`
  })
  fixerTasks.push({ file, gaps, taskId })
}
```

---

## STEP 7: Spawn Gap-Fixer Agent

Spawns one `gap-fixer` agent per file group (or a single agent that handles all files if the total is small). Uses the shared gap-fixer prompt template created in Task 2.

```javascript
// Load gap-fixer prompt template
// Template reference: agents/work/gap-fixer.md
// (Created by Worker 1 in Tasks 1-2 of this plan)
const gapList = cappedFindings.map(g =>
  `- [ ] **[${g.id}]** ${g.description} — \`${g.file}:${g.line}\``
).join("\n")

const fixerPrompt = loadTemplate("gap-fixer.md", {
  verdict_path: `tmp/arc/${id}/gap-analysis-verdict.md`,
  output_dir: `tmp/arc/${id}`,
  identifier: id,
  gaps: gapList,
  fixer_inputs: fixerInputs,
  context: "arc-gap-remediation",
  timestamp: new Date().toISOString()
})

// ATE-1: general-purpose subagent with identity via prompt
Agent({
  prompt: fixerPrompt,
  subagent_type: "general-purpose",
  team_name: fixTeamName,
  name: "gap-fixer",
  model: resolveModelForAgent("gap-fixer", talisman),  // Cost tier mapping
  run_in_background: true
})
```

---

## STEP 8: Monitor + Post-Fix Verification

```javascript
// Monitor gap-fixer (polling-guard.md compliant)
const fixPollIntervalMs = 30_000  // 30s
const fixMaxIterations = Math.ceil(600_000 / fixPollIntervalMs)  // 20 iterations for 10 min
let fixPreviousCompleted = 0
let fixStaleCount = 0

for (let i = 0; i < fixMaxIterations; i++) {
  const taskListResult = TaskList()
  const fixCompleted = taskListResult.filter(t => t.status === "completed").length
  const fixTotal = taskListResult.length

  if (fixCompleted >= fixTotal) {
    log(`Phase 5.8: gap-fixer completed all ${fixTotal} tasks.`)
    break
  }

  if (i > 0 && fixCompleted === fixPreviousCompleted) {
    fixStaleCount++
    if (fixStaleCount >= 6) {  // 3 min of no progress
      warn("Phase 5.8: gap-fixer stalled — proceeding with partial fixes.")
      break
    }
  } else {
    fixStaleCount = 0
    fixPreviousCompleted = fixCompleted
  }

  Bash(`sleep ${fixPollIntervalMs / 1000}`)
}

// Post-fix verification: get fresh diff to see what was actually changed
const postSha = Bash("git rev-parse HEAD 2>/dev/null").trim()
// SEC-007: Validate postSha before shell interpolation
if (!/^[0-9a-f]{40}$/.test(postSha)) {
  warn("Phase 5.8: Invalid postSha — skipping commit log")
}
// SEC-005 FIX: Validate preSha with same hex regex as postSha (defense-in-depth)
const validShas = /^[0-9a-f]{40}$/.test(preSha) && /^[0-9a-f]{40}$/.test(postSha) && preSha !== postSha
const fixCommits = validShas
  ? Bash(`git log --oneline "${preSha}..${postSha}" 2>/dev/null`).trim()
  : ""
const fixedFiles = validShas
  ? Bash(`git diff --name-only "${preSha}..${postSha}" 2>/dev/null`).trim().split('\n').filter(Boolean)
  : []

log(`Phase 5.8: ${fixedFiles.length} files modified by gap-fixer. Commits:\n${fixCommits || "(none)"}`)
```

---

## STEP 9: Cleanup

```javascript
// Shutdown gap-fixer
try { SendMessage({ type: "shutdown_request", recipient: "gap-fixer" }) } catch (e) { /* already exited */ }
Bash("sleep 20")  // Grace period — let teammate deregister

// TeamDelete with retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`gap-remediation cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${fixTeamName}/" "$CHOME/tasks/${fixTeamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}
```

---

## STEP 10: Write DEFERRED Findings to Echoes

```javascript
// Findings not fixed (manual-review required) are surfaced as inscribed echoes
// so future arc sessions benefit from the gap pattern awareness
// BACK-007: Include both overflow findings (beyond max_fixes cap) AND unfixed-within-cap findings
// Anti-Shirking: Force non-deferrable overflow findings into the fix queue
// BACK-001 FIX: Save original cap length before push to avoid read-after-write hazard
const originalCapLength = cappedFindings.length
const nonDeferrableOverflow = allFindings.slice(originalCapLength)
  .filter(f => !canDefer(f, allFindings).canDefer)
if (nonDeferrableOverflow.length > 0) {
  cappedFindings.push(...nonDeferrableOverflow)
  log(`Anti-Shirking: ${nonDeferrableOverflow.length} overflow findings forced into fix queue (non-deferrable)`)
}
const overflowFindings = allFindings.slice(originalCapLength)
  .filter(f => !nonDeferrableOverflow.includes(f))
const overflowIds = overflowFindings.map(f => f.id)
// VK-002 FIX: Persist BOTH overflow IDs (beyond max_fixes cap) AND within-cap deferred
// findings (attempted but unfixable by the agent). Within-cap deferred are identified
// in STEP 11 via fixedFiles comparison — we defer the echo write until after STEP 11.
// See echo write block below (after STEP 11) for the combined persistence.
const allDeferredIds = overflowIds  // Will be extended with within-cap deferred after STEP 11

// PW-006 FIX: Removed STEP 10 partial echo write — the combined write in STEP 11
// includes both overflow IDs and within-cap deferred IDs, making this write redundant.
// See STEP 11 below for the unified echo persistence.
```

---

## STEP 11: Update Checkpoint

```javascript
// Calculate how many gaps were addressed based on fixed files
const fixedFindingIds = cappedFindings
  .filter(f => fixedFiles.includes(f.file))
  .map(f => f.id)
// Anti-Shirking: Only defer findings that pass canDefer() check
const deferredFindingIds = cappedFindings
  .filter(f => !fixedFiles.includes(f.file) && canDefer(f, allFindings).canDefer)
  .map(f => f.id)
const forcedFixIds = cappedFindings
  .filter(f => !fixedFiles.includes(f.file) && !canDefer(f, allFindings).canDefer)
  .map(f => f.id)
if (forcedFixIds.length > 0) {
  log(`Anti-Shirking: ${forcedFixIds.length} within-cap findings forced to non-deferred: ${forcedFixIds.join(', ')}`)
}

// VK-002 FIX: Extend allDeferredIds with within-cap deferred findings (now known)
// and persist combined set to echoes. Covers both overflow (cap-exceeded) and
// within-cap (attempted but unfixable) deferred findings.
allDeferredIds.push(...deferredFindingIds)
if (allDeferredIds.length > 0 && exists(".rune/echoes/workers/")) {
  const combinedEcho = `## Arc Gap Remediation — All Deferred Findings (${new Date().toISOString()})\n\n` +
    `Plan: ${checkpoint.plan_file}\n` +
    `Overflow deferred (cap-exceeded): ${overflowIds.join(", ") || "none"}\n` +
    `Within-cap deferred (unfixable): ${deferredFindingIds.join(", ") || "none"}\n`
  const existingWorkerEchoes = exists(".rune/echoes/workers/MEMORY.md")
    ? Read(".rune/echoes/workers/MEMORY.md") : ""
  Write(".rune/echoes/workers/MEMORY.md", existingWorkerEchoes + "\n" + combinedEcho)
}

// Write remediation report
const remediationReport = `# Gap Remediation Report\n\n` +
  `**Phase**: 5.8\n` +
  `**Date**: ${new Date().toISOString()}\n` +
  `**Plan**: ${checkpoint.plan_file}\n\n` +
  `## Summary\n\n` +
  `| Metric | Value |\n|--------|-------|\n` +
  `| FIXABLE findings parsed | ${allFindings.length} |\n` +
  `| Capped at max_fixes | ${cappedFindings.length} |\n` +
  `| Fixed (file modified) | ${fixedFindingIds.length} |\n` +
  `| Deferred (not fixed) | ${deferredFindingIds.length + (allFindings.length - cappedFindings.length)} |\n` +
  `| Files modified | ${fixedFiles.length} |\n\n` +
  `## Fixed Findings\n\n` +
  (fixedFindingIds.length > 0
    ? fixedFindingIds.map(id => `- [x] ${id}`).join('\n') + '\n'
    : '_None_\n') + '\n' +
  `## Deferred Findings\n\n` +
  (deferredFindingIds.length > 0
    ? deferredFindingIds.map(id => `- [ ] ${id} — NOT fixed (requires manual review)`).join('\n') + '\n'
    : '_None_\n') + '\n' +
  `## Commits\n\n` +
  (fixCommits ? '```\n' + fixCommits + '\n```\n' : '_No commits made_\n')

Write(`tmp/arc/${id}/gap-remediation-report.md`, remediationReport)

// Update state file
const stateData = JSON.parse(Read(stateFile))
stateData.status = "completed"
stateData.completed = new Date().toISOString()
stateData.fixed_count = fixedFindingIds.length
stateData.deferred_count = deferredFindingIds.length
Write(stateFile, JSON.stringify(stateData))

updateCheckpoint({
  phase: "gap_remediation",
  status: "completed",
  artifact: `tmp/arc/${id}/gap-remediation-report.md`,
  artifact_hash: sha256(remediationReport),
  phase_sequence: 5.8,
  team_name: fixTeamName,
  fixed_count: fixedFindingIds.length,
  deferred_count: deferredFindingIds.length + (allFindings.length - cappedFindings.length)
})

log(`Phase 5.8 complete: ${fixedFindingIds.length} gaps fixed, ${deferredFindingIds.length} deferred.`)
```

---

**Output**: `tmp/arc/{id}/gap-remediation-report.md`

**Failure policy**: Non-blocking (WARN). Gate failure (needs_remediation=false AND codex_needs_remediation=false, or talisman disabled) skips cleanly. If gap-fixer times out or produces no commits, the report records zero fixes and the pipeline continues. The deferred findings are persisted to echoes for future awareness. Does not halt pipeline.
