# Phase 5.3: UX VERIFICATION — Arc UX Design Intelligence Integration

Reviews frontend implementation for UX quality: heuristic compliance, user flow completeness, interaction patterns, and cognitive load. Gated by `ux.enabled` in talisman + frontend files detected in diff. **Non-blocking** by default — UX findings never halt the pipeline unless `ux.blocking: true`.

**Team**: `arc-ux-{id}` (up to 4 UX review agents)
**Tools**: Read, Write, Agent, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
**Timeout**: 5 min (PHASE_TIMEOUTS.ux_verification = 300_000)
**Inputs**: id, changed frontend files from diff, talisman `ux:` config
**Outputs**: `tmp/arc/{id}/ux-verification-report.md`, `tmp/arc/{id}/ux-findings.json`
**Error handling**: Non-blocking. Skip if no frontend files. Agent failure → skip with warning.
**Consumers**: Phase 7 MEND (reads UX findings for fix prioritization), Phase 8 TEST (UX-specific test suggestions)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Skip gate — `ux.enabled !== true` in talisman → skip
2. Detect frontend files in diff — skip if no `.tsx`, `.jsx`, `.ts`, `.js`, `.css`, `.scss` files changed
3. Check design_verification phase status — run regardless (UX verification is independent of design sync)

## Algorithm

```javascript
updateCheckpoint({ phase: "ux_verification", status: "in_progress", phase_sequence: 5.3, team_name: null })

// 0. Skip gate — UX verification is DISABLED by default (opt-in via talisman)
// readTalismanSection: "ux"
const uxConfig = readTalismanSection("ux")
const uxEnabled = uxConfig?.enabled === true
if (!uxEnabled) {
  log("UX verification skipped — ux.enabled is false in talisman.")
  updateCheckpoint({ phase: "ux_verification", status: "skipped", skip_reason: "ux_disabled" })
  return
}

// 0.5. Validate Figma URL if present (SEC-001: untrusted user content from plan files)
const figmaUrl = uxConfig?.figma_url ?? null
if (figmaUrl) {
  const FIGMA_URL_PATTERN = /^https:\/\/(www\.)?figma\.com\//
  if (!FIGMA_URL_PATTERN.test(figmaUrl)) {
    warn(`UX verification: invalid Figma URL rejected — must start with https://figma.com/ or https://www.figma.com/`)
    // Continue without Figma reference — do not pass untrusted URL to MCP tools
  }
}

// 1. Detect frontend files in diff
const frontendExts = ['.tsx', '.jsx', '.ts', '.js', '.css', '.scss', '.vue', '.svelte']
const changedFiles = Bash(`git diff --name-only ${defaultBranch}...HEAD`).trim().split('\n').filter(Boolean)
const frontendFiles = changedFiles.filter(f => frontendExts.some(ext => f.endsWith(ext)))

if (frontendFiles.length === 0) {
  log("UX verification skipped — no frontend files in diff.")
  updateCheckpoint({ phase: "ux_verification", status: "skipped", skip_reason: "no_frontend_files" })
  return
}

// 2. Determine agent roster
const agents = [
  { name: "ux-heuristic-1", agent: "ux-heuristic-reviewer", prefix: "UXH" },
  { name: "ux-flow-1", agent: "ux-flow-validator", prefix: "UXF" },
  { name: "ux-interaction-1", agent: "ux-interaction-auditor", prefix: "UXI" },
]

// Cognitive walker is conditional — only when cognitive_walkthrough: true
const cognitiveEnabled = uxConfig?.cognitive_walkthrough === true
if (cognitiveEnabled) {
  agents.push({ name: "ux-cognitive-1", agent: "ux-cognitive-walker", prefix: "UXC" })
}

// MCP-First UX Agent Discovery (v1.171.0+)
// Discover user-defined UX review agents to supplement built-in roster
try {
  const candidates = agent_search({
    query: "UX usability accessibility heuristic interaction review frontend",
    phase: "appraise",
    category: "review",
    limit: 8
  })
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")

  if (candidates?.results?.length > 0) {
    const builtinNames = new Set(["ux-heuristic-reviewer", "ux-flow-validator", "ux-interaction-auditor", "ux-cognitive-walker"])
    let userIdx = 1
    for (const c of candidates.results) {
      if (!builtinNames.has(c.name) && (c.source === "user" || c.source === "project")) {
        const prefix = `UX${String.fromCharCode(65 + agents.length)}`  // UXE, UXF, ...
        agents.push({ name: `ux-user-${userIdx}`, agent: c.name, prefix })
        userIdx++
      }
    }
  }
} catch (e) { /* MCP unavailable — proceed with built-in roster */ }

// 3. Create UX verification team
prePhaseCleanup(checkpoint)
TeamCreate({ team_name: `arc-ux-${id}` })

updateCheckpoint({
  phase: "ux_verification", status: "in_progress", phase_sequence: 5.3,
  team_name: `arc-ux-${id}`
})

// 4. Create review tasks (one per agent)
for (const { name, agent, prefix } of agents) {
  TaskCreate({
    subject: `UX review: ${agent} (${prefix}-)`,
    description: `Review frontend files for UX quality. Scope: ${frontendFiles.join(', ')}. Output findings with ${prefix}-NNN prefixes to tmp/arc/${id}/ux-${name}.md`,
    metadata: { phase: "ux_verification", agent, prefix }
  })
}

// 5. Spawn UX review agents
for (const { name, agent } of agents) {
  Agent({
    subagent_type: "general-purpose", model: resolveModelForAgent(agent, talisman),
    name, team_name: `arc-ux-${id}`,
    prompt: `You are ${name}, a UX review specialist.
      Review the following frontend files for UX quality:
      ${frontendFiles.map(f => `- ${f}`).join('\n')}
      Output findings to: tmp/arc/${id}/ux-${name}.md
      Follow the review checklist and output format from your agent definition.`
  })
}

// 6. Monitor — waitForCompletion with 5-min timeout
waitForCompletion(`arc-ux-${id}`, agents.length, { timeoutMs: 240_000, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: UX Verification" })

// 7. Cleanup — standard 5-component pattern
for (const { name } of agents) {
  try { SendMessage({ type: "shutdown_request", recipient: name, content: `UX verification complete` }) } catch (e) { /* agent may be done */ }
}
Bash("sleep 20")  // Grace period

// TeamDelete with retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`ux-verification cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-ux-${id}/" "$CHOME/tasks/arc-ux-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// 8. Aggregate findings
const allFindings = []
for (const { name, prefix } of agents) {
  const outputPath = `tmp/arc/${id}/ux-${name}.md`
  if (exists(outputPath)) {
    const content = Read(outputPath)
    // Parse findings from output (RUNE:FINDING markers)
    const findings = parseFindingsFromOutput(content, prefix)
    allFindings.push(...findings)
  }
}

// 9. Write aggregated report (SEC-002: nonce-bounded markers for structured findings)
const nonce = crypto.randomUUID()
const report = generateUXReport(allFindings, agents, frontendFiles, {
  findingWrapper: (finding) =>
    `<!-- RUNE:UX_FINDING nonce=${nonce} -->\n${finding}\n<!-- /RUNE:UX_FINDING nonce=${nonce} -->`
})
Write(`tmp/arc/${id}/ux-verification-report.md`, report)
Write(`tmp/arc/${id}/ux-findings.json`, JSON.stringify(allFindings, null, 2))

// 10. Check blocking condition (BACK-003: fallback defaults for talisman keys)
const blocking = uxConfig?.blocking ?? false
const p1Count = allFindings.filter(f => f.severity === "P1").length
const threshold = uxConfig?.thresholds ?? {}
const maxP1 = threshold.max_p1_findings ?? 0

if (blocking && p1Count > maxP1) {
  warn(`UX verification: ${p1Count} P1 findings exceed threshold (${maxP1}). Blocking pipeline.`)
  // Blocking mode: halt pipeline (rare — most projects use non-blocking UX findings)
}

updateCheckpoint({
  phase: "ux_verification", status: "completed",
  artifact: `tmp/arc/${id}/ux-verification-report.md`,
  artifact_hash: exists(`tmp/arc/${id}/ux-verification-report.md`)
    ? sha256(Read(`tmp/arc/${id}/ux-verification-report.md`)) : null,
  phase_sequence: 5.3, team_name: null,
  findings_count: allFindings.length,
  p1_count: p1Count,
  agents_completed: agents.length,
  cognitive_enabled: cognitiveEnabled
})
```

## Error Handling

| Error | Recovery |
|-------|----------|
| `ux.enabled` is false | Skip phase — status "skipped" |
| No frontend files in diff | Skip phase — nothing to verify |
| Agent failure | Skip agent — partial results from remaining agents |
| All agents fail | Skip phase — UX verification is non-blocking |
| Blocking mode + P1 findings | Halt pipeline (only when `ux.blocking: true`) |

## Crash Recovery

| Resource | Location |
|----------|----------|
| UX verification report | `tmp/arc/{id}/ux-verification-report.md` |
| UX findings JSON | `tmp/arc/{id}/ux-findings.json` |
| Per-agent outputs | `tmp/arc/{id}/ux-{agent-name}.md` |
| Team config | `$CHOME/teams/arc-ux-{id}/` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "ux_verification") |

Recovery: On `--resume`, if ux_verification is `in_progress`, clean up stale team and re-run from the beginning. Verification is idempotent — report and findings files are overwritten cleanly.
