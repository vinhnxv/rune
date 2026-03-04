# Phase 3: DESIGN EXTRACTION — Arc Design Sync Integration

Extracts Figma design specifications and creates Visual Spec Maps (VSM) for the arc pipeline.
Gated by `design_sync.enabled` in talisman. **Non-blocking** — design phases never halt the pipeline.

Supports single-URL (fast path, existing behavior preserved) and multi-URL extraction
with parallel teammates, Design Analyst classification, and user confirmation for ambiguous
frame relationships.

**Team**: `arc-design-{id}` (design-sync-agent workers + design-analyst)
**Tools**: Read, Write, Bash, Task, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
**Timeout**: Dynamic — `60_000 + (url_count * 120_000)` ms (PHASE_TIMEOUTS.design_extraction)
**Inputs**: id, plan frontmatter (`figma_urls[]` or `figma_url`), `arcConfig.design_sync` (resolved via `resolveArcConfig()`)
**Outputs**: `tmp/arc/{id}/vsm/` directory with VSM files per component
**Error handling**: Non-blocking. All design phases are skippable — failures set status "skipped" with reason.
**Consumers**: Phase 5.2 DESIGN VERIFICATION (reads VSM files), WORK phase workers (consult VSM for implementation)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Skip gate — `arcConfig.design_sync?.enabled !== true` → skip
2. Read Figma URLs from plan frontmatter (see Step 1) — skip if empty
3. Check Figma MCP tools available — skip with warning if unavailable
4. Validate all Figma URL formats: `/^https:\/\/www\.figma\.com\/(design|file)\/[A-Za-z0-9]+/`

## Algorithm

```javascript
updateCheckpoint({ phase: "design_extraction", status: "in_progress", phase_sequence: 5.1, team_name: null })

// 0. Skip gate — design sync is DISABLED by default (opt-in via talisman)
const designSyncConfig = arcConfig.design_sync ?? {}
const designSyncEnabled = designSyncConfig.enabled === true
if (!designSyncEnabled) {
  log("Design extraction skipped — design_sync.enabled is false in talisman.")
  updateCheckpoint({ phase: "design_extraction", status: "skipped" })
  return
}

// === STEP 1: Read Figma URLs ===
// readFigmaUrls() supports both figma_urls[] array and deprecated figma_url scalar
const planContent = Read(checkpoint.plan_file)
const figmaUrls = readFigmaUrls(planContent)

if (figmaUrls.length === 0) {
  log("Design extraction skipped — no figma_url(s) found in plan frontmatter.")
  updateCheckpoint({ phase: "design_extraction", status: "skipped" })
  return
}

// readFigmaUrls() implementation:
// function readFigmaUrls(planContent):
//   // Try array format first (new)
//   const arrayMatch = planContent.match(/figma_urls:\s*\n((?:\s+-\s+https:\/\/[^\n]+\n?)+)/)
//   if (arrayMatch):
//     return arrayMatch[1].match(/https:\/\/[^\s]+/g) ?? []
//   // Fall back to scalar (deprecated — single URL)
//   const scalarMatch = planContent.match(/figma_url:\s*(https:\/\/www\.figma\.com\/[^\s]+)/)
//   return scalarMatch ? [scalarMatch[1]] : []

// === STEP 2: Validate and Dedup URLs ===
const FIGMA_URL_PATTERN = /^https:\/\/www\.figma\.com\/(design|file)\/[A-Za-z0-9]+/
const validUrls = []
for (const url of figmaUrls) {
  if (!FIGMA_URL_PATTERN.test(url)) {
    warn(`Design extraction: invalid Figma URL format skipped: ${url}`)
    continue
  }
  validUrls.push(url)
}

if (validUrls.length === 0) {
  warn("Design extraction: all figma_urls failed format validation.")
  updateCheckpoint({ phase: "design_extraction", status: "skipped" })
  return
}

// Pre-discovery dedup: remove duplicate URLs (same full URL string)
const dedupedUrls = [...new Set(validUrls)]
const urlCount = dedupedUrls.length

// === STEP 3: Check Figma MCP Availability ===
let figmaMcpAvailable = false
try {
  figma_list_components({ url: dedupedUrls[0] })
  figmaMcpAvailable = true
} catch (e) {
  warn("Design extraction: Figma MCP tools unavailable. Skipping design extraction. Check .mcp.json configuration.")
  updateCheckpoint({ phase: "design_extraction", status: "skipped" })
  return
}

// === FAST PATH: Single-URL (preserves existing behavior exactly) ===
if (urlCount === 1) {
  const figmaUrl = dedupedUrls[0]
  Bash(`mkdir -p "tmp/arc/${id}/vsm"`)
  prePhaseCleanup(checkpoint)
  TeamCreate({ team_name: `arc-design-${id}` })

  updateCheckpoint({
    phase: "design_extraction", status: "in_progress", phase_sequence: 5.1,
    team_name: `arc-design-${id}`,
    figma_url: figmaUrl,
    figma_urls: [figmaUrl]
  })

  const figmaData = figma_fetch_design({ url: figmaUrl })
  const components = figma_list_components({ url: figmaUrl })
  const maxWorkers = designSyncConfig.max_extraction_workers ?? 2

  for (const component of components.slice(0, 20)) {
    TaskCreate({
      subject: `Extract VSM for ${component.name}`,
      description: `Fetch Figma node ${component.id} from ${figmaUrl}. Extract design tokens, region tree, variant map. Output to: tmp/arc/${id}/vsm/${component.name}.json`,
      metadata: { phase: "extraction", node_id: component.id, figma_url: figmaUrl }
    })
  }

  for (let i = 0; i < Math.min(maxWorkers, components.length); i++) {
    Agent({
      subagent_type: "general-purpose", model: "sonnet",
      name: `design-syncer-${i + 1}`, team_name: `arc-design-${id}`,
      prompt: `You are design-syncer-${i + 1}. Extract Figma design specs and create VSM files.
        Figma URL: ${figmaUrl}
        Output directory: tmp/arc/${id}/vsm/
        [inject agent design-sync-agent.md content]`
    })
  }

  waitForCompletion([...Array(maxWorkers).keys()].map(i => `design-syncer-${i + 1}`), {
    timeoutMs: 480_000
  })

  for (let i = 0; i < maxWorkers; i++) {
    SendMessage({ type: "shutdown_request", recipient: `design-syncer-${i + 1}` })
  }
  sleep(15_000)

  let cleanupTeamDeleteSucceeded = false
  const CLEANUP_DELAYS = [0, 5000, 10000]
  for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
    if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
    try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
      if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-extraction cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
    }
  }
  if (!cleanupTeamDeleteSucceeded) {
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-${id}/" "$CHOME/tasks/arc-design-${id}/" 2>/dev/null`)
    try { TeamDelete() } catch (e) { /* best effort */ }
  }

  const vsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`).trim().split('\n').filter(Boolean)
  updateCheckpoint({
    phase: "design_extraction", status: "completed",
    phase_sequence: 5.1, team_name: null,
    vsm_files: vsmFiles,
    vsm_count: vsmFiles.length,
    figma_url: figmaUrl,
    figma_urls: [figmaUrl]
  })
  return
}

// === MULTI-URL PATH (urlCount >= 2) ===

// === STEP 4: Pre-Group by file_key ===
// Cheap string extraction — group URLs that share a Figma file_key
// Same file_key = frames from the same Figma file (likely variants/breakpoints)
const fileKeyGroups = {}  // fileKey → [url, ...]
for (const url of dedupedUrls) {
  const fileKeyMatch = url.match(/figma\.com\/(?:design|file)\/([A-Za-z0-9]+)/)
  const fileKey = fileKeyMatch ? fileKeyMatch[1] : url
  if (!fileKeyGroups[fileKey]) fileKeyGroups[fileKey] = []
  fileKeyGroups[fileKey].push(url)
}
const fileKeyList = Object.keys(fileKeyGroups)
const distinctFileKeys = fileKeyList.length

// === STEP 5: Prepare Output Directories ===
Bash(`mkdir -p "tmp/arc/${id}/vsm" "tmp/arc/${id}/extraction"`)
for (let i = 0; i < urlCount; i++) {
  const urlHash = sha256(dedupedUrls[i]).slice(0, 8)
  Bash(`mkdir -p "tmp/arc/${id}/extraction/${urlHash}"`)
}

// === STEP 6: Create Extraction Team ===
prePhaseCleanup(checkpoint)
TeamCreate({ team_name: `arc-design-${id}` })

updateCheckpoint({
  phase: "design_extraction", status: "in_progress", phase_sequence: 5.1,
  team_name: `arc-design-${id}`,
  figma_urls: dedupedUrls,
  url_count: urlCount,
  distinct_file_keys: distinctFileKeys
})

// === STEP 7: Compute Component Cap Per URL ===
const maxTotalComponents = designSyncConfig.max_total_components ?? 40
const perUrlCap = Math.min(20, Math.floor(maxTotalComponents / urlCount))
const maxWorkers = Math.min(urlCount, designSyncConfig.max_extraction_workers ?? 4)

// === STEP 8: Create Extraction Tasks (URL-Affinity Assignment) ===
// One task per URL — workers claim by URL index to ensure URL-affinity
const extractionTaskIds = []
for (let i = 0; i < urlCount; i++) {
  const url = dedupedUrls[i]
  const urlHash = sha256(url).slice(0, 8)
  const fileKey = url.match(/figma\.com\/(?:design|file)\/([A-Za-z0-9]+)/)?.[1] ?? "unknown"
  const taskId = TaskCreate({
    subject: `Extract IR tree for URL ${i + 1}/${urlCount}`,
    description: `Figma URL: ${url}
      URL index: ${i}
      File key: ${fileKey}
      URL hash: ${urlHash}
      Component cap: ${perUrlCap}
      Output: tmp/arc/${id}/extraction/${urlHash}/ir-tree.json
      Also write: tmp/arc/${id}/extraction/${urlHash}/components.json
      Use design-sync-agent extraction pipeline (Phases 1-4 only, skip VSM output for now).`,
    metadata: {
      phase: "extraction",
      url_index: i,
      url_hash: urlHash,
      figma_url: url,
      file_key: fileKey,
      component_cap: perUrlCap
    }
  })
  extractionTaskIds.push(taskId)
}

// === STEP 9: Spawn Extraction Workers ===
// Workers are URL-affinity assigned: worker-1 handles URLs 0,maxWorkers, 2*maxWorkers...
// This prevents workers from competing for the same URL's Figma API quota
const spawnedWorkers = []
for (let i = 0; i < maxWorkers; i++) {
  const workerName = `design-syncer-${i + 1}`
  spawnedWorkers.push(workerName)
  Agent({
    subagent_type: "general-purpose", model: "sonnet",
    name: workerName, team_name: `arc-design-${id}`,
    prompt: `You are ${workerName}. Extract Figma design specs and write IR tree JSON files.
      URL queue: ${JSON.stringify(dedupedUrls)}
      URL-affinity: claim tasks where (url_index % ${maxWorkers}) == ${i}
      Output base: tmp/arc/${id}/extraction/
      Component cap per URL: ${perUrlCap}
      Write each result atomically: tmp/arc/${id}/extraction/{url_hash}/ir-tree.json
      [inject agent design-sync-agent.md content — Phases 1-4 only]`
  })
}

// Dynamic timeout: 2 min per URL, minimum 8 min inner budget
const innerTimeoutMs = Math.max(480_000, urlCount * 120_000)
waitForCompletion(spawnedWorkers, { timeoutMs: innerTimeoutMs })

// Shutdown extraction workers
for (const workerName of spawnedWorkers) {
  SendMessage({ type: "shutdown_request", recipient: workerName })
}
sleep(15_000)

// === STEP 10: Design Analyst Classification ===
// Spawn design-analyst to classify relationships between extracted frames
const irFiles = []
for (let i = 0; i < urlCount; i++) {
  const urlHash = sha256(dedupedUrls[i]).slice(0, 8)
  const irPath = `tmp/arc/${id}/extraction/${urlHash}/ir-tree.json`
  if (exists(irPath)) irFiles.push(irPath)
}

let relationshipGraph = null
let analystRan = false

if (irFiles.length >= 2) {
  // Rename existing extraction workers and spawn analyst
  TaskCreate({
    subject: "Classify frame relationships",
    description: `Run 5-signal composite on extracted IR trees.
      IR files: ${JSON.stringify(irFiles)}
      Output: tmp/arc/${id}/extraction/relationship-graph.json
      [inject agent design-analyst.md content]`,
    metadata: { phase: "classification" }
  })

  Agent({
    subagent_type: "general-purpose", model: "sonnet",
    name: "design-analyst-1", team_name: `arc-design-${id}`,
    prompt: `You are design-analyst-1. Classify relationships between Figma frames.
      IR files: ${JSON.stringify(irFiles)}
      Output: tmp/arc/${id}/extraction/relationship-graph.json
      [inject agent design-analyst.md content]`
  })

  waitForCompletion(["design-analyst-1"], { timeoutMs: 120_000 })
  SendMessage({ type: "shutdown_request", recipient: "design-analyst-1" })
  sleep(5_000)

  if (exists(`tmp/arc/${id}/extraction/relationship-graph.json`)) {
    relationshipGraph = JSON.parse(Read(`tmp/arc/${id}/extraction/relationship-graph.json`))
    analystRan = true
  }
} else if (irFiles.length === 1 && distinctFileKeys > 1) {
  // Some URLs failed to extract IR — treat remaining as distinct screens
  warn("Design analyst skipped — fewer than 2 IR trees available.")
}

// Track failed URL extractions
const failedUrls = []
for (let i = 0; i < urlCount; i++) {
  const urlHash = sha256(dedupedUrls[i]).slice(0, 8)
  const irPath = `tmp/arc/${id}/extraction/${urlHash}/ir-tree.json`
  if (!exists(irPath)) {
    failedUrls.push({ url: dedupedUrls[i], url_index: i, reason: "IR tree not found after extraction" })
  }
}

// If some URLs failed but others succeeded, confirm with user before proceeding
if (failedUrls.length > 0 && irFiles.length > 0) {
  const failureList = failedUrls
    .map(f => `  - URL ${f.url_index + 1}: ${f.url}`)
    .join('\n')
  const userChoice = AskUserQuestion(
    `Design extraction: ${failedUrls.length} of ${urlCount} URL(s) failed IR extraction:\n\n${failureList}\n\n` +
    `${irFiles.length} URL(s) succeeded. Proceed with partial data (partial VSM coverage)?` +
    ` Reply "yes" to continue, "no" to abort design extraction.`
  )
  if (userChoice?.trim().toLowerCase().startsWith('n')) {
    warn("Design extraction aborted by user after partial URL failure.")
    updateCheckpoint({ phase: "design_extraction", status: "skipped", failed_urls: failedUrls })
    return
  }
}

// === STEP 11: User Confirmation for RELATED Pairs ===
// Skip if all groups resolved (no RELATED pairs) or all frames had user screen: labels
let confirmedGroups = relationshipGraph?.groups ?? null

if (analystRan && relationshipGraph?.user_confirmation_required?.length > 0) {
  const confirmationList = relationshipGraph.user_confirmation_required
    .map(item => `  - ${item.frame_a} ↔ ${item.frame_b}: ${item.reason}`)
    .join('\n')

  const userChoice = AskUserQuestion(
    `Design Analyst found ${confirmationList.length} frame pair(s) in the RELATED band (score 0.50–0.75). ` +
    `Please confirm their classification:\n\n${confirmationList}\n\n` +
    `Reply with "same" to merge each pair into one group, "different" to keep them separate, ` +
    `or "same:1,2 different:3" for per-pair overrides.`
  )

  // Parse user overrides and apply to groups
  confirmedGroups = applyUserConfirmation(relationshipGraph.groups, confirmationList, userChoice)
}

// If analyst did not run (single distinct file_key or < 2 IR files), create trivial groups
if (!confirmedGroups) {
  confirmedGroups = dedupedUrls.map((url, i) => ({
    group_id: `grp-${String(i + 1).padStart(3, '0')}`,
    classification: "DIFFERENT-SCREEN",
    confidence: 1.0,
    frames: [{ url_index: i, frame_id: null, frame_name: null }],
    representative_frame: { url_index: i }
  }))
}

// === STEP 12: VSM Generation ===
// Spawn fresh workers for VSM generation — use confirmed groups to determine merge vs independent
const vsmTaskIds = []

for (const group of confirmedGroups) {
  if (group.classification === "SAME-SCREEN" || group.classification === "VARIANT") {
    // Merged VSM: all frames in group become variant_sources[]
    const groupUrls = group.frames.map(f => dedupedUrls[f.url_index])
    const primaryUrl = groupUrls[group.frames.findIndex(f =>
      f.url_index === group.representative_frame.url_index
    )]
    const taskId = TaskCreate({
      subject: `Generate merged VSM for group ${group.group_id}`,
      description: `Create a merged VSM for ${group.frames.length} related frames.
        Primary URL: ${primaryUrl}
        Variant sources: ${JSON.stringify(groupUrls)}
        Group classification: ${group.classification}
        IR trees: ${group.frames.map(f => `tmp/arc/${id}/extraction/${sha256(dedupedUrls[f.url_index]).slice(0, 8)}/ir-tree.json`).join(', ')}
        Output: tmp/arc/${id}/vsm/{component-name}.json
        VSM schema v1.1: include variant_sources[], relationship_group, relationship_confidence fields.`,
      metadata: { phase: "vsm_generation", group_id: group.group_id, merged: true }
    })
    vsmTaskIds.push(taskId)
  } else {
    // Independent VSM per frame (DIFFERENT-SCREEN)
    for (const frame of group.frames) {
      const url = dedupedUrls[frame.url_index]
      const taskId = TaskCreate({
        subject: `Generate VSM for URL ${frame.url_index + 1} (${group.classification})`,
        description: `Create an independent VSM for URL index ${frame.url_index}.
          Figma URL: ${url}
          IR tree: tmp/arc/${id}/extraction/${sha256(url).slice(0, 8)}/ir-tree.json
          Output: tmp/arc/${id}/vsm/{component-name}.json
          Component cap: ${perUrlCap}`,
        metadata: { phase: "vsm_generation", group_id: group.group_id, merged: false, url_index: frame.url_index }
      })
      vsmTaskIds.push(taskId)
    }
  }
}

// Spawn VSM generation workers (reuse maxWorkers budget)
const vsmWorkers = []
for (let i = 0; i < Math.min(maxWorkers, vsmTaskIds.length); i++) {
  const workerName = `design-vsm-${i + 1}`
  vsmWorkers.push(workerName)
  Agent({
    subagent_type: "general-purpose", model: "sonnet",
    name: workerName, team_name: `arc-design-${id}`,
    prompt: `You are ${workerName}. Generate VSM files from IR trees according to assigned tasks.
      Output directory: tmp/arc/${id}/vsm/
      [inject agent design-sync-agent.md content — Phase 6 VSM Output only]`
  })
}

waitForCompletion(vsmWorkers, { timeoutMs: Math.max(300_000, vsmTaskIds.length * 60_000) })

// === STEP 13: Component Cap Enforcement ===
// Global cap: trim VSM files to max_total_components
const allVsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`)
  .trim().split('\n').filter(Boolean)

if (allVsmFiles.length > maxTotalComponents) {
  warn(`Component cap enforced: ${allVsmFiles.length} VSMs trimmed to ${maxTotalComponents}.`)
  // Keep first maxTotalComponents files (sorted by filename for determinism)
  const excess = allVsmFiles.sort().slice(maxTotalComponents)
  for (const f of excess) {
    Bash(`rm -f "${f}"`)
  }
}

// === STEP 14: Shutdown + Cleanup ===
for (const workerName of vsmWorkers) {
  SendMessage({ type: "shutdown_request", recipient: workerName })
}
sleep(15_000)

let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-extraction cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-${id}/" "$CHOME/tasks/arc-design-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// === STEP 15: Collect Results ===
const finalVsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`)
  .trim().split('\n').filter(Boolean)

// Build structured error log for checkpoint — errors are always recorded even on "completed" status
const checkpointErrors = []
for (const f of failedUrls) {
  checkpointErrors.push({
    type: "url_extraction_failure",
    url_or_component: f.url,
    recovery_strategy: "skipped_url_continued_with_partial_data",
    timestamp: new Date().toISOString()
  })
}
if (!analystRan && irFiles.length >= 2) {
  checkpointErrors.push({
    type: "analyst_failure",
    url_or_component: `tmp/arc/${id}/extraction/relationship-graph.json`,
    recovery_strategy: "treat_all_urls_as_different_screen",
    timestamp: new Date().toISOString()
  })
}

updateCheckpoint({
  phase: "design_extraction", status: "completed",
  phase_sequence: 5.1, team_name: null,
  vsm_files: finalVsmFiles,
  vsm_count: finalVsmFiles.length,
  figma_urls: dedupedUrls,
  figma_url: dedupedUrls[0],  // backward-compat scalar (first URL)
  url_count: urlCount,
  relationship_graph: analystRan ? `tmp/arc/${id}/extraction/relationship-graph.json` : null,
  errors: checkpointErrors.length > 0 ? checkpointErrors : undefined
})
```

## Helper: readFigmaUrls()

```javascript
function readFigmaUrls(planContent):
  // Try figma_urls array format (new)
  const arrayMatch = planContent.match(/figma_urls:\s*\n((?:\s+-\s+https:\/\/[^\n]+\n?)+)/)
  if (arrayMatch) {
    return arrayMatch[1].match(/https:\/\/[^\s]+/g) ?? []
  }
  // Fall back to figma_url scalar (deprecated, single URL)
  const scalarMatch = planContent.match(/figma_url:\s*(https:\/\/www\.figma\.com\/[^\s]+)/)
  return scalarMatch ? [scalarMatch[1]] : []
```

## Error Handling

| Error | Recovery |
|-------|----------|
| `design_sync.enabled` is false | Skip phase — status "skipped" |
| No Figma URL(s) in plan frontmatter | Skip phase — status "skipped" |
| All URLs fail format validation | Skip phase — status "skipped", warn user |
| Figma MCP tools unavailable | Skip phase — status "skipped", warn user |
| Figma API timeout (>60s) on URL N | Skip that URL's tasks, continue with others |
| Some URLs fail IR extraction (partial) | Track in `failedUrls[]`; ask user via `AskUserQuestion` to confirm proceeding with partial data. If user declines, status "skipped". If user confirms, continue with available IR files. |
| Design analyst fails or times out | Skip classification, treat all URLs as DIFFERENT-SCREEN. Recorded in checkpoint `errors[]` with recovery_strategy "treat_all_urls_as_different_screen". |
| User confirmation skipped (timeout) | Default: treat RELATED pairs as DIFFERENT-SCREEN |
| Agent failure on VSM generation | Skip phase — design phases are non-blocking |

### Checkpoint Error Logging

Errors are always written to the `errors[]` field of the checkpoint update, even when phase status is "completed". This enables recovery strategies and diagnostics to identify partial failures. Each entry:

```json
{
  "type": "url_extraction_failure | analyst_failure",
  "url_or_component": "<url or file path>",
  "recovery_strategy": "<description of how the failure was handled>",
  "timestamp": "<ISO 8601 timestamp>"
}
```

## Crash Recovery

| Resource | Location |
|----------|----------|
| IR trees | `tmp/arc/{id}/extraction/{url-hash}/ir-tree.json` |
| Relationship graph | `tmp/arc/{id}/extraction/relationship-graph.json` |
| VSM files | `tmp/arc/{id}/vsm/*.json` |
| Team config | `$CHOME/teams/arc-design-{id}/` |
| Task list | `$CHOME/tasks/arc-design-{id}/` |
| Checkpoint state | `.claude/arc/{id}/checkpoint.json` (phase: "design_extraction") |

Recovery: On `--resume`, if design_extraction is `in_progress`, clean up stale team and re-run from the beginning. Extraction is idempotent — IR tree and VSM files are overwritten cleanly.

Per-URL checkpoint: each `{url-hash}/ir-tree.json` serves as an atomic checkpoint for that URL's extraction. If resume detects all IR trees exist, the extraction phase is skipped and VSM generation proceeds directly from cached IR data.
