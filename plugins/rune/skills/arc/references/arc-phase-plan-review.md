# Phase 2: PLAN REVIEW — Full Algorithm

Three to six parallel reviewers evaluate the enriched plan. Any BLOCK verdict halts the pipeline.

**Team**: `arc-plan-review-{id}`
**Tools (read-only)**: Read, Glob, Grep, Write (own output file only)
**Timeout**: 15 min (PHASE_TIMEOUTS.plan_review = 900_000 — inner 10m + 5m setup)
**Inputs**: id (string, validated at arc init), enriched plan path (`tmp/arc/{id}/enriched-plan.md`)
**Outputs**: `tmp/arc/{id}/plan-review.md`
**Error handling**: BLOCK verdict halts pipeline. User fixes plan, then `/rune:arc --resume`.
**Consumers**: SKILL.md (Phase 2 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## ATE-1 Compliance

This phase creates a team and spawns agents. It MUST follow the Agent Teams pattern:

```
1. TeamCreate({ team_name: "arc-plan-review-{id}" })     ← CREATE TEAM FIRST
2. TaskCreate({ subject: ..., description: ... })          ← CREATE TASKS
3. Agent({ team_name: "arc-plan-review-{id}", name: "...", ← SPAWN WITH team_name
     subagent_type: "general-purpose",                      ← ALWAYS general-purpose
     prompt: "...", ... })                                   ← IDENTITY VIA PROMPT
4. Monitor → Shutdown → TeamDelete with fallback           ← CLEANUP
```

**NEVER** use bare `Agent()` calls or named `subagent_type` values in this phase.

## Reviewer Roster

| Reviewer | Agent | Condition | Focus |
|----------|-------|-----------|-------|
| scroll-reviewer | `agents/utility/scroll-reviewer.md` | Always | Document quality |
| decree-arbiter | `agents/utility/decree-arbiter.md` | Always | Technical soundness |
| knowledge-keeper | `agents/utility/knowledge-keeper.md` | Always | Documentation coverage |
| veil-piercer-plan | `agents/utility/veil-piercer-plan.md` | Always | Plan truth-telling (reality vs fiction) |
| horizon-sage | `agents/utility/horizon-sage.md` | `talisman.horizon.enabled !== false` | Strategic depth assessment |
| evidence-verifier | `agents/utility/evidence-verifier.md` | `talisman.evidence.enabled !== false` | Evidence-based plan grounding |
| codex-plan-reviewer | CLI-backed (codex exec) | Codex detected + `codex.workflows` includes `"arc"` | Cross-model plan verification |

## Algorithm

```javascript
updateCheckpoint({ phase: "plan_review", status: "in_progress", phase_sequence: 2, team_name: `arc-plan-review-${id}` })

// Pre-create guard (see team-sdk/references/engines.md)
// QUAL-13 FIX: Full regex validation per team-sdk/references/engines.md (defense-in-depth)
if (!/^arc-[a-zA-Z0-9_-]+$/.test(id)) throw new Error('Invalid arc id')
// SEC-3 FIX: Redundant path traversal check — defense-in-depth (matches arc-phase-forge.md pattern)
if (id.includes('..')) throw new Error('Path traversal detected in arc id')
// NOTE: prePhaseCleanup(checkpoint) runs BEFORE this phase (added in v1.28.1),
// clearing SDK leadership state + prior phase team dirs. This inline guard is
// defense-in-depth for the specific team being created (stale same-name team).
// postPhaseCleanup(checkpoint, "plan_review") runs AFTER checkpoint update (v1.68.0).
// teamTransition — inlined 5-step protocol (see team-sdk/references/engines.md)
// STEP 1: Validate — done above at lines 37-39 (defense-in-depth, upstream validated at arc init)
// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
let teamDeleteSucceeded = false
const RETRY_DELAYS = [0, 3000, 8000]
for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
  if (attempt > 0) {
    warn(`arc-plan-review: TeamDelete attempt ${attempt + 1} failed, retrying in ${RETRY_DELAYS[attempt]/1000}s...`)
    Bash(`sleep ${RETRY_DELAYS[attempt] / 1000}`)
  }
  try {
    TeamDelete()
    teamDeleteSucceeded = true
    break
  } catch (e) {
    if (attempt === RETRY_DELAYS.length - 1) {
      warn(`arc-plan-review: TeamDelete failed after ${RETRY_DELAYS.length} attempts. Using filesystem fallback.`)
    }
  }
}
// STEP 3: Filesystem fallback (only when STEP 2 failed — avoids blast radius on happy path)
// CDX-003 FIX: Gate behind !teamDeleteSucceeded to prevent cross-workflow scan from
// wiping concurrent workflows when TeamDelete already succeeded cleanly.
if (!teamDeleteSucceeded) {
  // SEC-003: id validated at lines 37-39 — contains only [a-zA-Z0-9_-]
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-plan-review-${id}/" "$CHOME/tasks/arc-plan-review-${id}/" 2>/dev/null`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && find "$CHOME/teams/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) -exec rm -rf {} + && find "$CHOME/tasks/" -maxdepth 1 -type d \( -name "rune-*" -o -name "arc-*" \) -exec rm -rf {} + 2>/dev/null`)
  try { TeamDelete() } catch (e2) { /* proceed to TeamCreate */ }
}
// STEP 4: TeamCreate with "Already leading" catch-and-recover
try {
  TeamCreate({ team_name: `arc-plan-review-${id}` })
} catch (createError) {
  if (/already leading/i.test(createError.message)) {
    warn(`arc-plan-review: "Already leading" detected — clearing stale leadership and retrying...`)
    try { TeamDelete() } catch (_) {}
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-plan-review-${id}/" "$CHOME/tasks/arc-plan-review-${id}/" 2>/dev/null`)
    try {
      TeamCreate({ team_name: `arc-plan-review-${id}` })
    } catch (finalError) {
      throw new Error(`teamTransition failed: unable to create team after exhausting all cleanup strategies. Run /rune:rest --heal to manually clean up, then retry. (${finalError.message})`)
    }
  } else { throw createError }
}
// STEP 5: Post-create verification
// TOME-3 FIX: Use Bash test -f + CHOME for consistency with command files
Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -f "$CHOME/teams/arc-plan-review-${id}/config.json" || echo "WARN: config.json not found after TeamCreate"`)

// Delegation checklist: see arc-delegation-checklist.md (Phase 2)
const reviewers = [
  { name: "scroll-reviewer", agent: "agents/utility/scroll-reviewer.md", focus: "Document quality" },
  { name: "decree-arbiter", agent: "agents/utility/decree-arbiter.md", focus: "Technical soundness" },
  { name: "knowledge-keeper", agent: "agents/utility/knowledge-keeper.md", focus: "Documentation coverage" },
  { name: "veil-piercer-plan", agent: "agents/utility/veil-piercer-plan.md", focus: "Plan truth-telling (reality vs fiction)" }
]

// readTalismanSection: "gates"
const gates = readTalismanSection("gates")

// Horizon Sage — strategic depth assessment (v1.47.0+)
// Skipped if talisman horizon.enabled === false
const horizonEnabled = gates?.horizon?.enabled !== false
if (horizonEnabled) {
  const planFrontmatter = extractYamlFrontmatter(Read(`tmp/arc/${id}/enriched-plan.md`))
  const VALID_INTENTS = ["long-term", "quick-win", "auto"]
  const intentDefault = gates?.horizon?.intent_default ?? "long-term"
  const strategicIntent = VALID_INTENTS.includes(planFrontmatter?.strategic_intent)
    ? planFrontmatter.strategic_intent : intentDefault
  reviewers.push({
    name: "horizon-sage",
    agent: "agents/utility/horizon-sage.md",
    focus: `Strategic depth assessment (intent: ${strategicIntent})`
  })
}

// Evidence Verifier — evidence-based plan validation (v1.113.0)
// Skipped if talisman evidence.enabled === false
const evidenceEnabled = gates?.evidence?.enabled !== false
if (evidenceEnabled) {
  const evidenceExternalSearch = gates?.evidence?.external_search === true
  reviewers.push({
    name: "evidence-verifier",
    agent: "agents/utility/evidence-verifier.md",
    focus: `Evidence-based plan grounding (external_search: ${evidenceExternalSearch})`
  })
}

// State Weaver — plan state machine validation (v1.127.0)
// Skipped if talisman state_weaver.enabled === false
const stateWeaverEnabled = gates?.state_weaver?.enabled !== false
if (stateWeaverEnabled) {
  reviewers.push({
    name: "state-weaver",
    agent: "agents/utility/state-weaver.md",
    focus: "Plan state machine validation (phases, transitions, I/O contracts)"
  })
}

// Codex Plan Reviewer (optional 6th reviewer — see arc-delegation-checklist.md Phase 2)
// Detection: canonical codex-detection.md algorithm (9 steps, NOT inline simplified check)
// Arc-mode adaptation: if .codexignore is missing, skip Codex silently (no AskUserQuestion)
// — AskUserQuestion would block the automated arc pipeline indefinitely.
const codexDetected = detectCodexOracle()  // per roundtable-circle/references/codex-detection.md
if (codexDetected && talisman?.codex?.workflows?.includes("arc")) {
  reviewers.push({
    name: "codex-plan-reviewer",
    agent: null,  // CLI-backed reviewer — uses codex exec directly, no agent file
    focus: "Cross-model plan verification (Codex Oracle)"
  })
}

for (const reviewer of reviewers) {
  // Evidence-verifier gets augmented prompt with ANCHOR/RE-ANCHOR and config
  let reviewerPrompt = `Review plan for: ${reviewer.focus}
      Plan: tmp/arc/${id}/enriched-plan.md
      Output: tmp/arc/${id}/reviews/${reviewer.name}-verdict.md
      Include structured verdict marker: <!-- VERDICT:${reviewer.name}:{PASS|CONCERN|BLOCK} -->`
  if (reviewer.name === "state-weaver") {
    const swConfig = gates?.state_weaver ?? {}
    reviewerPrompt = `<!-- ANCHOR: You are state-weaver. Your ONLY role is plan state machine validation. -->
      Review plan for: ${reviewer.focus}
      Plan: tmp/arc/${id}/enriched-plan.md
      Output: tmp/arc/${id}/reviews/${reviewer.name}-verdict.md
      Trigger gate: >= 5 phase indicators required for full analysis
      I/O calibration: Plans with implicit artifact flow may trigger false positives for STSM-003/004/005
      Include structured verdict marker: <!-- VERDICT:${reviewer.name}:{PASS|CONCERN|BLOCK} -->
      <!-- RE-ANCHOR: Extract phases, build transition graph, validate completeness (10 checks), verify I/O contracts. Dead-end states and loops-without-exit are P1. -->`
  }
  if (reviewer.name === "evidence-verifier") {
    const evConfig = gates?.evidence ?? {}
    reviewerPrompt = `<!-- ANCHOR: You are evidence-verifier. Your ONLY role is grounding verification. -->
      Review plan for: ${reviewer.focus}
      Plan: tmp/arc/${id}/enriched-plan.md
      Output: tmp/arc/${id}/reviews/${reviewer.name}-verdict.md
      Evidence config: block_threshold=${evConfig.block_threshold ?? 0.4}, concern_threshold=${evConfig.concern_threshold ?? 0.6}
      External search: ${evConfig.external_search === true ? "ALLOWED (WebSearch/WebFetch permitted)" : "DISABLED (codebase + documentation only)"}
      Evidence types (strength order): CODEBASE > DOCUMENTATION > EXTERNAL > OBSERVED > NOVEL
      Include structured verdict marker: <!-- VERDICT:${reviewer.name}:{PASS|CONCERN|BLOCK} -->
      <!-- RE-ANCHOR: Evaluate grounding score. Below ${evConfig.block_threshold ?? 0.4} → BLOCK, below ${evConfig.concern_threshold ?? 0.6} → CONCERN, otherwise PASS. -->`
  }
  Agent({
    team_name: `arc-plan-review-${id}`, name: reviewer.name,
    subagent_type: "general-purpose",
    prompt: reviewerPrompt,
    run_in_background: true
  })
}

// Monitor with timeout — see roundtable-circle/references/monitor-utility.md
// ANTI-PATTERN — NEVER DO: Bash("sleep N && echo poll check") — skips TaskList entirely.
// CORRECT: Call TaskList on every poll cycle. See monitor-utility.md and polling-guard skill.
const result = waitForCompletion(`arc-plan-review-${id}`, reviewers.length, {
  timeoutMs: PHASE_TIMEOUTS.plan_review, staleWarnMs: STALE_THRESHOLD,
  pollIntervalMs: 30_000, label: "Arc: Plan Review"
})

// Match completed tasks to reviewers by task subject (more reliable than owner name matching)
result.completed.forEach(t => {
  const r = reviewers.find(r => t.subject.includes(r.name) || t.owner === r.name)
  if (r) r.completed = true
})

if (result.timedOut) {
  warn("Phase 2 (PLAN REVIEW) timed out.")
  for (const reviewer of reviewers) {
    if (!reviewer.completed) {
      const outputPath = `tmp/arc/${id}/reviews/${reviewer.name}-verdict.md`
      if (exists(outputPath)) {
        // CDX-3 FIX: Verify file has a VERDICT marker before treating as complete
        const partialOutput = Read(outputPath)
        if (/<!-- VERDICT:/.test(partialOutput)) {
          reviewer.verdict = parseVerdict(reviewer.name, partialOutput)
        } else {
          warn(`${reviewer.name} output file exists but lacks VERDICT marker — treating as incomplete`)
          reviewer.verdict = "CONCERN"
        }
      } else {
        // QUAL-14 FIX: Write synthetic verdict so Phase 2.5 can read it from disk
        reviewer.verdict = "CONCERN"
        Write(outputPath, `# ${reviewer.name} — Timed Out\n\nReviewer did not complete within timeout.\n\n<!-- VERDICT:${reviewer.name}:CONCERN -->`)
      }
    }
  }
}

// Collect verdicts, merge → tmp/arc/{id}/plan-review.md
```

### parseVerdict()

Parse structured verdict markers using anchored regex. Defaults to CONCERN if marker is missing or malformed.

```javascript
// Also duplicated in arc-phase-plan-refine.md for self-containment — keep in sync.
const parseVerdict = (reviewer, output) => {
  const pattern = /^<!-- VERDICT:([a-zA-Z_-]+):(PASS|CONCERN|BLOCK) -->$/m
  const match = output.match(pattern)
  if (!match) { warn(`Reviewer ${reviewer} output lacks verdict marker — defaulting to CONCERN.`); return "CONCERN" }
  if (match[1] !== reviewer) warn(`Verdict marker reviewer mismatch: expected ${reviewer}, found ${match[1]}.`)
  return match[2]
}
```

### Verdict Definitions

| Verdict | Meaning |
|---------|---------|
| **PASS** | Plan is sound and ready for implementation |
| **CONCERN** | Issues worth noting but not blocking — workers should address these during implementation |
| **BLOCK** | Critical flaw that must be fixed before implementation can proceed |

### Circuit Breaker

| Condition | Action |
|-----------|--------|
| Any reviewer returns BLOCK | HALT pipeline, report blocking reviewer + reason |
| No BLOCK verdicts (mix of PASS/CONCERN) | Proceed to Phase 2.5 |

```javascript
updateCheckpoint({
  phase: "plan_review", status: blocked ? "failed" : "completed",
  artifact: `tmp/arc/${id}/plan-review.md`, artifact_hash: sha256(planReview), phase_sequence: 2
})
```

**Output**: `tmp/arc/{id}/plan-review.md`

If blocked: user fixes plan, then `/rune:arc --resume`.

## Layer 2: Implementation Correctness (inspect agents)

Conditional: only when the enriched plan contains fenced code blocks. Runs in PARALLEL with Layer 1 utility reviewers, sharing the same outer Phase 2 timeout.

**Team**: `arc-plan-inspect-{id}`
**Inspectors**: grace-warden, ruin-prophet, sight-oracle, vigil-keeper (plan-review mode templates)
**Inputs**: enriched plan path (`tmp/arc/{id}/enriched-plan.md`), requirements, identifiers, scope files
**Outputs**: `tmp/arc/{id}/plan-inspect-{inspector}.md` per inspector, `tmp/arc/{id}/plan-inspect-verdict.md` (merged)
**Trigger**: `hasCodeBlocks` regex matches fenced code blocks in the enriched plan

```javascript
// ═════════════════════════════════════════════════════════
// LAYER 2: Implementation Correctness (inspect agents)
// Conditional: only when plan contains code blocks
// Runs in PARALLEL with Layer 1 reviewers
// ═════════════════════════════════════════════════════════

const planContent = Read(enrichedPlanPath)
const hasCodeBlocks = /```(bash|javascript|python|ruby|typescript|sh|go|rust|yaml|json|toml)\b/m.test(planContent)

let layer2Active = false
let layer2TeamName = null

if (hasCodeBlocks) {
  layer2Active = true
  layer2TeamName = `arc-plan-inspect-${id}`

  // Pre-create guard for Layer 2 team
  // teamName validated: arc-plan-inspect-{id} where id is validated at arc init
  // Pre-create guard with "Already leading" recovery (matching Layer 1 pattern)
  try { TeamDelete() } catch (e) { /* may not exist */ }
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${layer2TeamName}/" "$CHOME/tasks/${layer2TeamName}/" 2>/dev/null`)

  try {
    TeamCreate({ team_name: layer2TeamName, description: `Plan inspect: code sample review for arc ${id}` })
  } catch (e) {
    if (e.message && e.message.includes("Already leading")) {
      // SDK still thinks we're leading another team — clear and retry
      try { TeamDelete() } catch (e2) { /* ignore */ }
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${layer2TeamName}/" "$CHOME/tasks/${layer2TeamName}/" 2>/dev/null`)
      Bash(`sleep 5`)
      TeamCreate({ team_name: layer2TeamName, description: `Plan inspect: code sample review for arc ${id}` })
    } else {
      throw e  // Unknown error — propagate
    }
  }

  // Create inspect tasks (4 inspectors)
  const inspectors = ["grace-warden", "ruin-prophet", "sight-oracle", "vigil-keeper"]
  for (const inspector of inspectors) {
    TaskCreate({
      subject: `${inspector}: Plan code sample review`,
      description: `Review code blocks in enriched plan for correctness and pattern compliance`,
      activeForm: `${inspector} reviewing plan code`
    })
  }

  // Extract code blocks for template variable
  const codeBlockRegex = /```(bash|javascript|python|ruby|typescript|sh|go|rust|yaml|json|toml)\b\n([\s\S]*?)```/gm
  const codeBlocks = []
  let match
  let blockIndex = 0
  while ((match = codeBlockRegex.exec(planContent)) !== null && blockIndex < 20) {
    const lang = match[1]
    const code = match[2].trim()
    if (code.length > 0) {
      codeBlocks.push({ index: blockIndex, language: lang, code: code.slice(0, 1500), lineStart: planContent.slice(0, match.index).split('\n').length })
      blockIndex++
    }
  }

  const codeBlocksText = codeBlocks.map(b =>
    `### Block ${b.index} (${b.language}, line ${b.lineStart})\n\`\`\`${b.language}\n${b.code}\n\`\`\``
  ).join("\n\n")

  // Spawn 4 inspect agents (plan-review mode templates)
  for (const inspector of inspectors) {
    const templatePath = `skills/roundtable-circle/references/ash-prompts/${inspector}-plan-review.md`
    // CONCERN 3: fileExists guard
    if (!exists(templatePath)) {
      warn(`Plan-review template missing for ${inspector}: ${templatePath} — skipping`)
      continue
    }

    Agent({
      team_name: layer2TeamName,
      name: inspector,
      subagent_type: "general-purpose",
      model: resolveModelForAgent(inspector, talisman),  // Cost tier mapping (references/cost-tier-mapping.md)
      prompt: loadTemplate(templatePath, {
        plan_path: enrichedPlanPath,
        output_path: `tmp/arc/${id}/plan-inspect-${inspector}.md`,
        task_id: "auto",
        requirements: requirements.map(r => `- ${r.id}: ${r.text}`).join("\n"),
        identifiers: identifiers.map(i => `${i.type}: ${i.value}`).join("\n"),
        scope_files: scopeFiles.join("\n"),
        code_blocks: codeBlocksText,
        timestamp: new Date().toISOString()
      }),
      run_in_background: true
    })
  }
}
```

### Layer 2 Monitoring

Layer 2 runs in parallel with Layer 1 — both share the Phase 2 outer timeout.

```javascript
// Monitor both Layer 1 and Layer 2 in parallel
// Layer 1: existing monitoring logic (already there)
// Layer 2: additional polling for inspect team
if (layer2Active) {
  // Wait for Layer 2 completion (shares the same outer timeout)
  const layer2PollInterval = 30_000  // 30 seconds
  const layer2Timeout = Math.max(60_000, PHASE_TIMEOUTS.plan_review - (Date.now() - phaseStartMs))
  const layer2MaxIterations = Math.ceil(layer2Timeout / layer2PollInterval)
  let layer2PrevCompleted = 0
  let layer2StaleCount = 0

  for (let i = 0; i < layer2MaxIterations; i++) {
    const tasks = TaskList()
    const completed = tasks.filter(t => t.status === "completed").length
    const total = tasks.length

    if (completed >= total) {
      log(`Layer 2: All ${total} inspector tasks completed.`)
      break
    }

    if (i > 0 && completed === layer2PrevCompleted) {
      layer2StaleCount++
      if (layer2StaleCount >= 6) {
        warn("Layer 2: Inspection stalled after 3 minutes — proceeding with available results.")
        break
      }
    } else {
      layer2StaleCount = 0
      layer2PrevCompleted = completed
    }

    log(`Layer 2: [${i+1}/${layer2MaxIterations}] ${completed}/${total} tasks completed`)
    Bash(`sleep ${layer2PollInterval / 1000}`)
  }
}
```

### Layer 2 Circuit Breaker Integration

After Layer 1 verdicts are collected, merge Layer 2 findings into the circuit breaker decision.

```javascript
// Circuit breaker: merge Layer 2 verdict with Layer 1
if (layer2Active) {
  // Read Layer 2 inspector outputs
  const inspectorOutputs = inspectors
    .map(i => `tmp/arc/${id}/plan-inspect-${i}.md`)
    .filter(f => exists(f))

  // Aggregate Layer 2 findings
  let layer2P1Count = 0
  for (const f of inspectorOutputs) {
    const content = Read(f)
    const p1Match = content.match(/P1:\s*(\d+)/)
    if (p1Match) layer2P1Count += parseInt(p1Match[1])
  }

  // Map Layer 2 → Layer 1 verdicts
  if (layer2P1Count > 0) {
    // NOT READY with P1 → BLOCK
    verdicts.push({ reviewer: "inspect-layer-2", verdict: "BLOCK", details: `${layer2P1Count} P1 findings in plan code samples` })
  } else if (inspectorOutputs.length > 0) {
    verdicts.push({ reviewer: "inspect-layer-2", verdict: "PASS", details: "Plan code samples pass inspection" })
  }

  // Construct verdict content from aggregated inspector findings
  const verdictContent = `# Plan Inspect Verdict\n\nLayer 2 P1 findings: ${layer2P1Count}\nInspector outputs: ${inspectorOutputs.length}/${inspectors.length}\n\n` +
    inspectorOutputs.map(f => {
      const name = f.split('/').pop().replace('.md', '')
      return `## ${name}\n\n${Read(f)}`
    }).join("\n\n")

  // Write Layer 2 verdict to dedicated file
  Write(`tmp/arc/${id}/plan-inspect-verdict.md`, verdictContent)

  // Cleanup Layer 2 team
  for (const inspector of inspectors) {
    try { SendMessage({ type: "shutdown_request", recipient: inspector, content: "Plan review complete" }) } catch(e) {}
  }
  Bash("sleep 20")  // Grace period — let teammates deregister
  // Layer 2 cleanup: always use filesystem fallback
  // (SDK tracks Layer 1 as "current team" — TeamDelete() would delete Layer 1, not Layer 2)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${layer2TeamName}/" "$CHOME/tasks/${layer2TeamName}/" 2>/dev/null`)
}
```

## Cleanup

Dynamic member discovery reads the team config to find ALL teammates (catches teammates summoned in any phase, not just the initial batch):

```javascript
// Dynamic member discovery — reads team config to find ALL teammates
// This catches teammates summoned in any phase, not just the initial batch
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/arc-plan-review-${id}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  // SEC-4 FIX: Validate member names against safe pattern before use in SendMessage
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: Phase 2 plan review — core reviewers summoned in this phase (horizon-sage, evidence-verifier, codex-plan-reviewer are conditional)
  allMembers = ["scroll-reviewer", "decree-arbiter", "knowledge-keeper", "veil-piercer-plan",
    "horizon-sage", "evidence-verifier", "state-weaver", "codex-plan-reviewer"]
}

// Shutdown all discovered members
for (const member of allMembers) { SendMessage({ type: "shutdown_request", recipient: member, content: "Plan review complete" }) }

// Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 20`)
}

// SEC-003: id validated at arc init (/^arc-[a-zA-Z0-9_-]+$/) — see Initialize Checkpoint section
// TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`arc-plan-review cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
// QUAL-012 FIX: Gate filesystem fallback behind !cleanupTeamDeleteSucceeded (CDX-003 pattern).
// When TeamDelete succeeds cleanly, rm-rf is unnecessary and adds blast radius risk.
if (!cleanupTeamDeleteSucceeded) {
  // 5a. Process-level kill — terminate lingering teammates before filesystem cleanup
  const ownerPid = Bash(`echo $PPID`).trim()
  if (ownerPid && /^\d+$/.test(ownerPid)) {
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash(`sleep 5`)
    Bash(`for pid in $(pgrep -P ${ownerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  }
  // 5b. Filesystem fallback with CHOME
  // SEC-005: id validated at line 37 — contains only [a-zA-Z0-9_-]
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-plan-review-${id}/" "$CHOME/tasks/arc-plan-review-${id}/" 2>/dev/null`)
  // Step C: Post-rm-rf TeamDelete to clear SDK leadership state.
  // BUG FIX: If TeamDelete failed above (e.g., "Cannot cleanup team with N active members"),
  // rm-rf removed the dirs that were blocking TeamDelete. Try once more — TeamDelete may
  // now succeed because the "active members" dirs are gone. Without this, SDK leadership
  // state leaks to Phase 6+ causing "Already leading team" errors on next TeamCreate.
  try { TeamDelete() } catch (e) { /* SDK state will be handled by prePhaseCleanup Strategy 4 */ }
}
```
