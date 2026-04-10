# Phase 3: DESIGN EXTRACTION — Arc Design Sync Integration

Extracts Figma design specifications and creates Visual Spec Maps (VSM) for the arc pipeline.
Gated by `design_sync.enabled` in talisman. **Non-blocking** — design phases never halt the pipeline.

Supports single-URL (fast path, existing behavior preserved) and multi-URL extraction
with parallel teammates, Design Analyst classification, and user confirmation for ambiguous
frame relationships.

**Team**: `arc-design-{id}` (design-sync-agent workers + design-analyst)
**Tools**: Read, Write, Bash, Agent, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
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
  updateCheckpoint({ phase: "design_extraction", status: "skipped", skip_reason: "design_sync_disabled" })
  return
}

// === STEP 1: Read Figma URLs ===
// readFigmaUrls() supports both figma_urls[] array and deprecated figma_url scalar
const planContent = Read(checkpoint.plan_file)
let figmaUrls = readFigmaUrls(planContent)

// === FALLBACK: Scan plan body if frontmatter empty ===
if (figmaUrls.length === 0) {
  // Fallback: extract Figma URLs from plan body text (e.g., from arc-issues generated plans)
  // Only scan AFTER the YAML frontmatter delimiter (second ---)
  const bodyStart = planContent.indexOf('---', planContent.indexOf('---') + 3)
  const planBody = bodyStart >= 0 ? planContent.substring(bodyStart + 3) : ''

  const FIGMA_URL_BODY_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
  const FIGMA_DOMAIN_BODY_PATTERN = /^https:\/\/(www\.)?figma\.com\/(design|file)\/[A-Za-z0-9]+/
  const bodyUrls = (planBody.match(FIGMA_URL_BODY_PATTERN) || [])
    .map(url => url.replace(/[\r\n)>\]]/g, ''))  // Strip trailing markdown chars
    .filter(url => FIGMA_DOMAIN_BODY_PATTERN.test(url))
    .slice(0, 10)

  if (bodyUrls.length > 0) {
    log(`Design extraction: Recovered ${bodyUrls.length} Figma URL(s) from plan body (fallback scan).`)
    figmaUrls = bodyUrls
  }
}

if (figmaUrls.length === 0) {
  log("Design extraction skipped — no figma_url(s) found in plan frontmatter or body.")
  updateCheckpoint({ phase: "design_extraction", status: "skipped", skip_reason: "no_figma_urls" })
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
  updateCheckpoint({ phase: "design_extraction", status: "skipped", skip_reason: "invalid_figma_urls" })
  return
}

// Pre-discovery dedup: remove duplicate URLs (same full URL string)
const dedupedUrls = [...new Set(validUrls)]
const urlCount = dedupedUrls.length

// === STEP 2.5: Load UI builder companion skill if detected ===
// Reads ui_builder from plan frontmatter (written by devise Phase 0.5 or arc-issues Task 6)
const uiBuilderMatch = planContent.match(/ui_builder:\s*\n\s+builder_mcp:\s*"([^"]+)"/)
const companionSkillMatch = planContent.match(/companion_skill:\s*"([^"]+)"/)
let extractionWorkerContext = ''

if (uiBuilderMatch) {
  const builderMcp = uiBuilderMatch[1]
  const companionSkill = companionSkillMatch?.[1]
  log(`Design extraction: UI builder detected — ${builderMcp}`)

  if (companionSkill) {
    loadedSkills.push(companionSkill)
    log(`Design extraction: Loaded companion skill '${companionSkill}' for ${builderMcp}`)
  }

  // Inject builder context into extraction worker prompts
  extractionWorkerContext += `\n\nUI Builder available: ${builderMcp}. Use its search_components() tool to find matching library components for extracted Figma designs. Prefer library matches over raw figma_to_react output.\n`
}

// === STEP 3: Check Figma MCP Availability (Composition Model) ===
// Probe ALL providers independently — use each for its strengths
const providers = { framelink: false, rune: false }
try { get_figma_data({ fileKey: parseFigmaUrl(dedupedUrls[0]).fileKey, depth: 1 }); providers.framelink = true } catch (e) { /* Framelink unavailable */ }
try { figma_list_components({ url: dedupedUrls[0] }); providers.rune = true } catch (e) { /* Rune unavailable */ }

if (!providers.framelink && !providers.rune) {
  warn("Design extraction: No Figma MCP providers available. Skipping design extraction. Check .mcp.json configuration.")
  updateCheckpoint({ phase: "design_extraction", status: "skipped", skip_reason: "figma_mcp_unavailable" })
  return
}
const figmaMcpAvailable = true

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

  // Composition: prefer Framelink for data (compressed), Rune as fallback
  const parsedUrl = parseFigmaUrl(figmaUrl)
  const figmaData = providers.framelink
    ? get_figma_data({ fileKey: parsedUrl.fileKey, nodeId: parsedUrl.nodeId })
    : figma_fetch_design({ url: figmaUrl })
  const components = providers.framelink
    ? parseComponentsFromData(get_figma_data({ fileKey: parsedUrl.fileKey, depth: 1 }))
    : figma_list_components({ url: figmaUrl })
  const maxWorkers = designSyncConfig.max_extraction_workers ?? 2

  for (const component of components.slice(0, 20)) {
    TaskCreate({
      subject: `Extract VSM for ${component.name}`,
      description: `Fetch Figma node ${component.id} from ${figmaUrl}. Extract design tokens, region tree, variant map. Output to: tmp/arc/${id}/vsm/${component.name}.json`,
      metadata: { phase: "extraction", node_id: component.id, figma_url: figmaUrl }
    })
  }

  // MCP-First Design Agent Discovery (v1.171.0+)
  let designAgentType = "design-sync-agent"
  try {
    const candidates = agent_search({
      query: "figma design extraction VSM visual spec map component",
      phase: "arc",
      category: "work",
      limit: 5
    })
    Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")
    const userAgent = candidates?.results?.find(c => c.source === "user" || c.source === "project")
    if (userAgent) designAgentType = userAgent.name
  } catch (e) { /* MCP unavailable — use default */ }

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

  waitForCompletion(`arc-design-${id}`, maxWorkers, {
    timeoutMs: 480_000, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Extraction (sync)"
  })

  // --- Standard 5-component cleanup (CLAUDE.md compliance) ---
  // 1. Dynamic member discovery
  let allMembers = []
  try {
    const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
    const teamConfig = JSON.parse(Read(`${CHOME}/teams/arc-design-${id}/config.json`))
    const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
    allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
  } catch (e) {
    allMembers = Array.from({ length: maxWorkers }, (_, i) => `design-syncer-${i + 1}`)
  }

  // 2a. Force-reply — put all teammates in message-processing state
  let confirmedAlive = 0
  let confirmedDead = 0
  const aliveMembers = []
  for (const member of allMembers) {
    try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { confirmedDead++ }
  }

  // 2b. Single shared pause
  if (aliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }

  // 2c. Send shutdown_request to alive members
  for (const member of aliveMembers) {
    try { SendMessage({ type: "shutdown_request", recipient: member, content: "Design extraction complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
  }

  // 3. Adaptive grace period
  if (confirmedAlive > 0) {
    Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`, { run_in_background: true })
  } else {
    Bash("sleep 2", { run_in_background: true })
  }

  // 4. TeamDelete with retry-with-backoff
  let cleanupTeamDeleteSucceeded = false
  const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
  for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
    if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
    try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
      if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-extraction cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
    }
  }

  // 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
  if (!cleanupTeamDeleteSucceeded) {
    // 5a. Process-level kill
    Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash(`sleep 5`, { run_in_background: true })
    Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
    // 5b. Filesystem cleanup
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-${id}/" "$CHOME/tasks/arc-design-${id}/" 2>/dev/null`)
    try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
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
waitForCompletion(`arc-design-${id}`, spawnedWorkers.length, { timeoutMs: innerTimeoutMs, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Extraction (workers)" })

// Shutdown extraction workers
for (const workerName of spawnedWorkers) {
  SendMessage({ type: "shutdown_request", recipient: workerName })
}
sleep(20_000)

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

  waitForCompletion(`arc-design-${id}`, 1, { timeoutMs: 120_000, pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Extraction (analyst)" })
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
    updateCheckpoint({ phase: "design_extraction", status: "skipped", skip_reason: "user_aborted_partial_failure", failed_urls: failedUrls })
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

waitForCompletion(`arc-design-${id}`, vsmWorkers.length, { timeoutMs: Math.max(300_000, vsmTaskIds.length * 60_000), pollIntervalMs: 30_000, staleWarnMs: 300_000, label: "Arc: Design Extraction (VSM)" })

// === STEP 13: Component Cap Enforcement ===
// Global cap: trim VSM files to max_total_components
// Cache file list — reused in Step 15 to avoid redundant filesystem scan
let cachedVsmFiles = Bash(`find "tmp/arc/${id}/vsm" -name "*.json" 2>/dev/null`)
  .trim().split('\n').filter(Boolean)

if (cachedVsmFiles.length > maxTotalComponents) {
  warn(`Component cap enforced: ${cachedVsmFiles.length} VSMs trimmed to ${maxTotalComponents}.`)
  // Keep first maxTotalComponents files (sorted by filename for determinism)
  const sorted = cachedVsmFiles.sort()
  const excess = sorted.slice(maxTotalComponents)
  for (const f of excess) {
    Bash(`rm -f "${f}"`)
  }
  cachedVsmFiles = sorted.slice(0, maxTotalComponents)  // update cache to reflect trim
}

// === STEP 13.5: Verification Gate ===
// Run cross-verification gate on collected VSM files
// See design-sync/references/verification-gate.md for full algorithm
const checkpointErrors = []  // Declared before gate — gate pushes verdict here
const gateConfig = designSyncConfig.verification_gate ?? {}

// SEC-04: Type-check enabled flag
if (gateConfig.enabled !== undefined && typeof gateConfig.enabled !== 'boolean') {
  warn(`verification_gate.enabled must be a boolean, got: ${typeof gateConfig.enabled}. Treating as enabled.`)
}
const gateEnabled = gateConfig.enabled === false ? false : true

if (gateEnabled && cachedVsmFiles.length > 0) {
  const vsmRegionCount = countVsmRegions(cachedVsmFiles)

  // Zero-region guard: flag as needs_attention if extraction produced no regions
  if (vsmRegionCount === 0) {
    warn("Zero VSM regions found — extraction produced no usable data.")
    checkpointErrors.push({
      type: 'verification_gate',
      verdict: 'ABORT',
      reason: 'zero-regions',
      mismatch_pct: 0,
      matched: 0,
      total: 0,
      timestamp: new Date().toISOString()
    })
  } else {
    const extractionCoverage = countCoveredRegions(cachedVsmFiles)
    const rawMismatchPct = ((vsmRegionCount - extractionCoverage) / vsmRegionCount) * 100
    const mismatchPct = Math.max(0, rawMismatchPct)  // Clamp negative (over-coverage)

    if (rawMismatchPct < 0) {
      warn(`countCoveredRegions (${extractionCoverage}) exceeds vsmRegionCount (${vsmRegionCount}) — possible VSM parsing inconsistency`)
    }

    // Threshold validation: clamp to 0-100, detect inverted thresholds
    let warnThreshold = Math.max(0, Math.min(100, gateConfig.warn_threshold ?? 20))
    let blockThreshold = Math.max(0, Math.min(100, gateConfig.block_threshold ?? 40))
    if (warnThreshold >= blockThreshold) {
      warn(`Inverted thresholds: warn_threshold (${warnThreshold}) >= block_threshold (${blockThreshold}). Reverting to defaults (20/40).`)
      warnThreshold = 20
      blockThreshold = 40
    }

    const verdict = mismatchPct > blockThreshold ? 'BLOCK'
      : mismatchPct > warnThreshold ? 'WARN' : 'PASS'

    checkpointErrors.push({
      type: 'verification_gate',
      verdict,
      mismatch_pct: mismatchPct,
      matched: extractionCoverage,
      total: vsmRegionCount,
      timestamp: new Date().toISOString()
    })

    // Store gate result in checkpoint for downstream Phase 5 (WORK) worker injection
    checkpoint.vsm_quality = verdict === 'BLOCK' ? 'blocked' : verdict === 'WARN' ? 'degraded' : 'good'
    checkpoint.gate_verdict = { verdict, mismatchPct, matched: extractionCoverage, total: vsmRegionCount }

    if (verdict === 'BLOCK') {
      // In arc context: non-blocking — log warning, continue pipeline
      // Workers will receive vsm_quality: "blocked" flag
      warn(`Design extraction verification gate: BLOCK (${mismatchPct.toFixed(0)}% unmatched). Implementation quality may be reduced.`)
    } else if (verdict === 'WARN') {
      warn(`Design extraction verification gate: WARN (${mismatchPct.toFixed(0)}% unmatched). ${vsmRegionCount - extractionCoverage} regions may need manual attention.`)
    }
  }
}

// === STEP 13.7: VSM Quality Scoring ===
// Per-VSM quality checks to prevent low-quality VSMs from propagating to downstream phases.
// See design-convergence.md for how quality tiers affect downstream consumers.
const qualityReport = { vsms: [], summary: {} }

for (const vsmPath of cachedVsmFiles) {
  try {
    const vsm = JSON.parse(Read(vsmPath))
    const componentName = vsmPath.split('/').pop().replace('.json', '')

    // 6-dimension quality check
    const checks = {
      has_tokens: Boolean(vsm.tokens && Object.keys(vsm.tokens).length > 0),
      has_variants: Boolean(vsm.variants && vsm.variants.length > 0),
      has_a11y: Boolean(vsm.accessibility),
      has_breakpoints: Boolean(vsm.breakpoints && vsm.breakpoints.length > 0),
      has_states: Boolean(vsm.states && vsm.states.length > 0),
      has_layout: Boolean(vsm.layout)
    }

    // Handle empty VSMs (valid JSON but no data) — score 0
    const isEmptyVsm = Object.keys(vsm).length === 0
    const passed = isEmptyVsm ? 0 : Object.values(checks).filter(Boolean).length
    const total = Object.keys(checks).length
    const score = Math.round((passed / total) * 100)

    // Quality tier: >= 80 HIGH, >= 50 MEDIUM, < 50 LOW
    const tier = score >= 80 ? "HIGH" : score >= 50 ? "MEDIUM" : "LOW"

    qualityReport.vsms.push({
      file: vsmPath,
      component: componentName,
      score,
      tier,
      checks,
      empty: isEmptyVsm
    })
  } catch (e) {
    // Per-VSM try/catch: one malformed VSM does not block the entire report
    qualityReport.vsms.push({
      file: vsmPath,
      component: vsmPath.split('/').pop().replace('.json', ''),
      score: 0,
      tier: "LOW",
      checks: { has_tokens: false, has_variants: false, has_a11y: false, has_breakpoints: false, has_states: false, has_layout: false },
      empty: false,
      error: e.message ?? "Parse error"
    })
  }
}

// Aggregate summary
const highCount = qualityReport.vsms.filter(v => v.tier === "HIGH").length
const medCount = qualityReport.vsms.filter(v => v.tier === "MEDIUM").length
const lowCount = qualityReport.vsms.filter(v => v.tier === "LOW").length
const avgScore = qualityReport.vsms.length > 0
  ? Math.round(qualityReport.vsms.reduce((sum, v) => sum + v.score, 0) / qualityReport.vsms.length)
  : 0

qualityReport.summary = {
  total: qualityReport.vsms.length,
  high: highCount,
  medium: medCount,
  low: lowCount,
  average_score: avgScore,
  timestamp: new Date().toISOString()
}

// LOW quality advisory for downstream phases
if (lowCount > 0) {
  const lowComponents = qualityReport.vsms.filter(v => v.tier === "LOW").map(v => v.component)
  warn(`VSM Quality: ${lowCount} LOW-quality VSM(s) detected: ${lowComponents.join(', ')}. ` +
    `Downstream consumers should handle missing dimensions gracefully.`)
}

Write(`tmp/arc/${id}/vsm/quality-report.json`, JSON.stringify(qualityReport, null, 2))

// Store quality summary in checkpoint for downstream phase injection
checkpoint.vsm_quality_summary = qualityReport.summary
checkpoint.vsm_low_quality_components = qualityReport.vsms
  .filter(v => v.tier === "LOW")
  .map(v => v.component)

// === STEP 14: Shutdown + Cleanup (standard 5-component pattern) ===
// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/arc-design-${id}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  allMembers = [...spawnedWorkers, ...vsmWorkers, "design-analyst-1"]
}

// 2a. Force-reply
let confirmedAlive = 0
let confirmedDead = 0
const aliveMembers = []
for (const member of allMembers) {
  try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { confirmedDead++ }
}

// 2b. Single shared pause
if (aliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }

// 2c. Send shutdown_request to alive members
for (const member of aliveMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Design extraction complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
}

// 3. Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`, { run_in_background: true })
} else {
  Bash("sleep 2", { run_in_background: true })
}

// 4. TeamDelete with retry-with-backoff
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-extraction cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  Bash(`sleep 5`, { run_in_background: true })
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) ps -p "$pid" -o args= 2>/dev/null | grep -q -- --stdio && continue; kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-design-${id}/" "$CHOME/tasks/arc-design-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// === STEP 15: Collect Results ===
// Reuse cached file list from Step 13 (avoids redundant filesystem scan)
const finalVsmFiles = cachedVsmFiles

// Build structured error log for checkpoint — errors are always recorded even on "completed" status
// Note: checkpointErrors[] declared at STEP 13.5 (before verification gate)
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
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "design_extraction") |

Recovery: On `--resume`, if design_extraction is `in_progress`, clean up stale team and re-run from the beginning. Extraction is idempotent — IR tree and VSM files are overwritten cleanly.

Per-URL checkpoint: each `{url-hash}/ir-tree.json` serves as an atomic checkpoint for that URL's extraction. If resume detects all IR trees exist, the extraction phase is skipped and VSM generation proceeds directly from cached IR data.

## VSM Quality Scoring

Per-component quality scoring applied after VSM extraction (Step 13.7) to gate downstream
phase behavior. Prevents low-quality VSMs from causing cascading INCONCLUSIVE results.

### Quality Dimensions (6 checks)

| Dimension | Check | What it validates |
|---|---|---|
| `has_tokens` | `vsm.tokens && Object.keys(vsm.tokens).length > 0` | Design tokens extracted (colors, spacing, typography) |
| `has_variants` | `vsm.variants && vsm.variants.length > 0` | Component variants identified (hover, disabled, sizes) |
| `has_a11y` | `vsm.accessibility` truthy | Accessibility metadata present (ARIA, contrast, focus) |
| `has_breakpoints` | `vsm.breakpoints && vsm.breakpoints.length > 0` | Responsive breakpoints detected |
| `has_states` | `vsm.states && vsm.states.length > 0` | Interactive states mapped (loading, error, empty) |
| `has_layout` | `vsm.layout` truthy | Layout structure extracted (flex, grid, positioning) |

### Score Calculation

```
score = (checks_passed / total_checks) * 100
```

### Quality Tiers

| Tier | Score Range | Meaning |
|---|---|---|
| `HIGH` | >= 80 | Rich VSM — all major dimensions present |
| `MEDIUM` | >= 50, < 80 | Partial VSM — some dimensions missing |
| `LOW` | < 50 | Sparse VSM — most dimensions missing |

### Edge Cases

- **Empty VSM** (valid JSON, no keys): score 0, tier LOW
- **Malformed VSM** (parse error): per-VSM try/catch catches error, score 0, tier LOW with `error` field
- **One malformed VSM does NOT block** the quality report for other VSMs

### Output

Written to `tmp/arc/{id}/vsm/quality-report.json`:

```json
{
  "vsms": [
    {
      "file": "tmp/arc/{id}/vsm/Button.json",
      "component": "Button",
      "score": 83,
      "tier": "HIGH",
      "checks": {
        "has_tokens": true,
        "has_variants": true,
        "has_a11y": true,
        "has_breakpoints": false,
        "has_states": true,
        "has_layout": true
      },
      "empty": false
    }
  ],
  "summary": {
    "total": 5,
    "high": 3,
    "medium": 1,
    "low": 1,
    "average_score": 70,
    "timestamp": "2026-03-24T12:00:00Z"
  }
}
```

### Downstream Consumers

| Phase | Behavior with LOW-quality VSMs |
|---|---|
| **Phase 3.2 (Design Prototypes)** | Skip LOW-quality components — insufficient data for prototype generation |
| **Phase 5 (Work)** | Workers receive `vsm_quality_summary` in checkpoint — quality advisory for implementation decisions |
| **Phase 5.2 (Design Verification)** | Mark dimensions with missing VSM data as `INCONCLUSIVE` instead of `FAIL` — absence of VSM data ≠ implementation failure |
