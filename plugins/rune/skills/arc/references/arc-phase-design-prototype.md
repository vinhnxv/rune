# Phase 3.2: DESIGN PROTOTYPE — Arc Prototype Generation

Generates usable React prototype components + Storybook stories from Figma VSM data
and UI builder MCP libraries. Runs AFTER Phase 3 (DESIGN EXTRACTION) and BEFORE Phase 4.5
(TASK DECOMPOSITION). Workers receive prototype paths and use them as implementation starting points.

Gated by `design_sync.enabled` in talisman. **Non-blocking** — design phases never halt the pipeline.

**Team**: `arc-prototype-{id}` (design-sync-agent workers)
**Tools**: Read, Write, Bash, Glob, Grep, Task, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage
**Timeout**: 10 min (PHASE_TIMEOUTS.design_prototype = 600_000)
**Inputs**: id, VSM files from Phase 3 (`tmp/arc/{id}/vsm/`), plan frontmatter (`figma_urls[]`), `arcConfig.design_sync`
**Outputs**: `tmp/arc/{id}/prototypes/` directory with prototype.tsx + stories per component, `tmp/storybook/` bootstrapped
**Error handling**: Non-blocking. Skip if no VSM files from Phase 3. Prototype failures → workers implement without prototypes.
**Consumers**: Phase 5 WORK (workers use prototypes as starting points), Phase 3.3 STORYBOOK VERIFICATION (verifies against prototypes)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Motivation

Phase 3 (DESIGN EXTRACTION) produces VSM files — structured JSON design specs. But workers
still implement from scratch using abstract specs as guidance. This phase bridges the gap:

```
VSM (abstract spec) → figma-to-react (reference JSX) + UI builder (real components) → prototype.tsx
```

Workers then adapt prototypes instead of implementing from zero, reducing design drift by 70-80%.

## Pre-checks

1. Skip gate — `arcConfig.design_sync?.enabled !== true` → skip
2. Verify VSM files exist from Phase 3 — skip if none found
3. Check design_extraction phase completed — skip if "skipped"
4. Check Figma MCP availability — skip with warning if unavailable

## Algorithm

```javascript
updateCheckpoint({ phase: "design_prototype", status: "in_progress", phase_sequence: 3.2, team_name: null })

// 0. Skip gate — design sync is DISABLED by default (opt-in via talisman)
const designSyncConfig = arcConfig.design_sync ?? {}
const designSyncEnabled = designSyncConfig.enabled === true
if (!designSyncEnabled) {
  log("Design prototype skipped — design_sync.enabled is false in talisman.")
  updateCheckpoint({ phase: "design_prototype", status: "skipped", skip_reason: "design_sync_disabled" })
  return
}

// 1. Check upstream Phase 3 ran
const extractionPhase = checkpoint.phases?.design_extraction
if (!extractionPhase || extractionPhase.status === "skipped") {
  log("Design prototype skipped — Phase 3 (DESIGN EXTRACTION) was skipped.")
  updateCheckpoint({ phase: "design_prototype", status: "skipped", skip_reason: "design_extraction_skipped" })
  return
}

// 2. Verify VSM files exist
const vsmFiles = Glob("tmp/arc/{id}/vsm/*.json")
if (vsmFiles.length === 0) {
  warn("Design prototype: No VSM files found from Phase 3. Skipping.")
  updateCheckpoint({ phase: "design_prototype", status: "skipped", skip_reason: "no_vsm_files" })
  return
}

// 3. Read Figma URLs from plan frontmatter (for figma-to-react calls)
const planContent = Read(checkpoint.plan_file)
const figmaUrls = readFigmaUrls(planContent)
if (figmaUrls.length === 0) {
  warn("Design prototype: No Figma URLs — cannot call figma_to_react. Skipping.")
  updateCheckpoint({ phase: "design_prototype", status: "skipped", skip_reason: "no_figma_urls" })
  return
}

// 4. Check Figma MCP availability
let figmaMcpAvailable = false
try {
  figma_list_components({ url: figmaUrls[0] })
  figmaMcpAvailable = true
} catch (e) {
  warn("Design prototype: Figma MCP tools unavailable. Skipping.")
  updateCheckpoint({ phase: "design_prototype", status: "skipped", skip_reason: "figma_mcp_unavailable" })
  return
}

// 5. Discover UI builder MCP (UntitledUI, shadcn, etc.)
// Uses discoverUIBuilder() from design-system-discovery skill
const builderProfile = discoverUIBuilder()
// builderProfile may be null — prototype generation still works (raw figma-ref only)

// 6. Configuration
const maxComponents = designSyncConfig.max_reference_components ?? 10
const maxWorkers = designSyncConfig.max_extraction_workers ?? 2
const referenceTimeoutMs = designSyncConfig.reference_timeout_ms ?? 15000
const libraryMatchThreshold = designSyncConfig.library_match_threshold ?? 0.5

// 7. Create output directory
Bash(`mkdir -p "tmp/arc/${id}/prototypes"`)

// 8. Create team
prePhaseCleanup(checkpoint)
TeamCreate({ team_name: `arc-prototype-${id}` })

updateCheckpoint({
  phase: "design_prototype", status: "in_progress", phase_sequence: 3.2,
  team_name: `arc-prototype-${id}`
})

// === STEP A: Extract reference JSX via figma_to_react ===
// For each VSM component, call figma_to_react to get reference React + Tailwind code
const components = []
for (const vsmPath of vsmFiles.slice(0, maxComponents)) {
  const vsm = JSON.parse(Read(vsmPath))
  const componentName = vsm.name || vsmPath.replace(/.*\//, '').replace('.json', '')
  // SEC-003: Sanitize component name for safe path usage
  const safeName = componentName.replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 64)

  // Find matching Figma node ID from VSM or plan
  const nodeId = vsm.figma_node_id || vsm.node_id || null
  const figmaUrl = vsm.figma_url || figmaUrls[0]

  try {
    const refResult = figma_to_react({
      url: nodeId ? `${figmaUrl}?node-id=${nodeId}` : figmaUrl,
      component_name: safeName
    })

    Bash(`mkdir -p "tmp/arc/${id}/prototypes/${safeName}"`)
    Write(`tmp/arc/${id}/prototypes/${safeName}/figma-reference.tsx`, refResult.code)

    components.push({
      name: componentName,
      safeName,
      vsmPath,
      figmaRefPath: `tmp/arc/${id}/prototypes/${safeName}/figma-reference.tsx`,
      figmaUrl,
      nodeId
    })
  } catch (e) {
    warn(`Design prototype: figma_to_react failed for ${componentName}: ${e.message}. Skipping component.`)
    continue
  }
}

if (components.length === 0) {
  warn("Design prototype: All figma_to_react calls failed. Skipping.")
  // Cleanup team before early return
  // No workers spawned at this point — go straight to TeamDelete
  try { TeamDelete() } catch (e) { /* best effort */ }
  updateCheckpoint({ phase: "design_prototype", status: "skipped", skip_reason: "all_extractions_failed" })
  return
}

// === STEP B: Match against UI builder library (conditional) ===
const matchResults = []
if (builderProfile !== null) {
  let consecutiveFailures = 0

  for (const comp of components) {
    if (consecutiveFailures >= 3) {
      warn("Design prototype: Circuit breaker — 3 consecutive builder failures. Skipping remaining matches.")
      break
    }

    try {
      const matches = builderProfile.search(comp.name, { timeout: referenceTimeoutMs })
      const bestMatch = matches.filter(m => m.score >= libraryMatchThreshold)[0]
      if (bestMatch) {
        const detail = builderProfile.getComponent(bestMatch.slug)
        Write(`tmp/arc/${id}/prototypes/${comp.safeName}/library-match.tsx`, detail.code)
        Write(`tmp/arc/${id}/prototypes/${comp.safeName}/mapping.json`, JSON.stringify({
          intent: comp.name,
          slug: bestMatch.slug,
          confidence: bestMatch.confidence || bestMatch.score,
          library: builderProfile.name
        }, null, 2))
        matchResults.push({ component: comp.safeName, match: bestMatch, library: builderProfile.name })
        consecutiveFailures = 0
      } else {
        matchResults.push({ component: comp.safeName, match: null })
      }
    } catch (e) {
      consecutiveFailures++
      matchResults.push({ component: comp.safeName, match: null, error: e.message })
    }
  }

  Write(`tmp/arc/${id}/prototypes/match-report.json`, JSON.stringify(matchResults, null, 2))
}

// === STEP C: Synthesize prototypes ===
// Create tasks for prototype synthesis — each component gets a task
for (const comp of components) {
  const hasLibraryMatch = exists(`tmp/arc/${id}/prototypes/${comp.safeName}/library-match.tsx`)
  TaskCreate({
    subject: `Synthesize prototype for ${comp.name}`,
    description: `Combine figma-reference + ${hasLibraryMatch ? 'library-match' : 'raw figma-ref'} into prototype.tsx.
      Figma reference: ${comp.figmaRefPath}
      ${hasLibraryMatch ? `Library match: tmp/arc/${id}/prototypes/${comp.safeName}/library-match.tsx` : 'No library match — use Figma reference with Tailwind styling'}
      VSM: ${comp.vsmPath}
      Output: tmp/arc/${id}/prototypes/${comp.safeName}/prototype.tsx
      Story: tmp/arc/${id}/prototypes/${comp.safeName}/prototype.stories.tsx (CSF3 format)

      Trust hierarchy (highest → lowest):
      1. Figma design (figma-reference.tsx) — visual structure, layout, spacing
      2. Design tokens (VSM) — colors, typography, spacing values
      3. UI library match (library-match.tsx) — real component API, props, variants
      4. Stack conventions — import paths, naming, file structure

      When library match exists: merge reference structure with real library component API.
      When no match: use Figma reference code with Tailwind styling as-is.

      Generate CSF3 Storybook story with: Default, Loading, Error, Empty, Disabled states.`,
    metadata: {
      phase: "synthesis",
      component: comp.safeName,
      has_library_match: hasLibraryMatch
    }
  })
}

// Spawn synthesis workers
const workerCount = Math.min(maxWorkers, components.length)
const spawnedWorkers = []
for (let i = 0; i < workerCount; i++) {
  const workerName = `proto-synth-${i + 1}`
  spawnedWorkers.push(workerName)
  Agent({
    subagent_type: "general-purpose", model: "sonnet",
    name: workerName, team_name: `arc-prototype-${id}`,
    prompt: `You are ${workerName}. Synthesize React prototype components from Figma references and library matches.

Output directory: tmp/arc/${id}/prototypes/
Each component gets: prototype.tsx + prototype.stories.tsx (CSF3 format)

Trust hierarchy:
1. Figma design → layout, spacing, visual hierarchy
2. VSM tokens → exact color/typography/spacing values
3. Library match → real component API (imports, props, variants)
4. Tailwind CSS v4 → styling approach

For CSF3 stories, use this pattern:
- Default export = component meta (title, component, args)
- Named exports = individual stories (Default, Loading, Error, Empty, Disabled)
- Use layout: "fullscreen" for page-level compositions

Claim tasks from the pool. Mark each completed when prototype.tsx is written.`
  })
}

waitForCompletion(spawnedWorkers, { timeoutMs: 480_000 })

// === STEP D: Bootstrap Storybook with prototypes ===
const prototypeFiles = Glob(`tmp/arc/${id}/prototypes/*/prototype.tsx`)
if (prototypeFiles.length > 0) {
  const bootstrapScript = `${CLAUDE_PLUGIN_ROOT}/scripts/storybook/bootstrap.sh`
  try {
    const bootstrapResult = JSON.parse(
      Bash(`cd "${CWD}" && bash "${bootstrapScript}" --src-dir "tmp/arc/${id}/prototypes"`)
    )
    updateCheckpoint({
      storybook_dir: bootstrapResult.storybook_dir,
      storybook_ready: bootstrapResult.ready,
      full_page_component: bootstrapResult.full_page_component
    })
  } catch (e) {
    warn(`Design prototype: Storybook bootstrap failed: ${e.message}. Prototypes still available for workers.`)
  }
}

// === STEP E: Write manifest ===
const manifest = {
  arc_id: id,
  generated_at: new Date().toISOString(),
  components: components.map(c => ({
    name: c.name,
    safe_name: c.safeName,
    prototype_path: `prototypes/${c.safeName}/prototype.tsx`,
    story_path: `prototypes/${c.safeName}/prototype.stories.tsx`,
    vsm_path: c.vsmPath,
    has_library_match: exists(`tmp/arc/${id}/prototypes/${c.safeName}/library-match.tsx`),
    library: matchResults.find(m => m.component === c.safeName)?.library || null
  })),
  library_matches: matchResults.filter(m => m.match).length,
  total_components: components.length,
  builder_profile: builderProfile?.name || null
}
Write(`tmp/arc/${id}/prototypes/manifest.json`, JSON.stringify(manifest, null, 2))

// === STEP F: Shutdown + Cleanup ===
for (const workerName of spawnedWorkers) {
  SendMessage({ type: "shutdown_request", recipient: workerName })
}
sleep(20_000)

let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000, 15000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-prototype cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
if (!cleanupTeamDeleteSucceeded) {
  // 5a. Process-level kill — terminate lingering teammates before filesystem cleanup
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  Bash(`sleep 5`)
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  // 5b. Filesystem cleanup
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/arc-prototype-${id}/" "$CHOME/tasks/arc-prototype-${id}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// === STEP G: Collect Results ===
const finalPrototypes = Glob(`tmp/arc/${id}/prototypes/*/prototype.tsx`)
const finalStories = Glob(`tmp/arc/${id}/prototypes/*/prototype.stories.tsx`)

updateCheckpoint({
  phase: "design_prototype", status: "completed",
  phase_sequence: 3.2, team_name: null,
  prototype_count: finalPrototypes.length,
  story_count: finalStories.length,
  library_matches: matchResults.filter(m => m.match).length,
  builder_profile: builderProfile?.name || null,
  manifest_path: `tmp/arc/${id}/prototypes/manifest.json`
})
```

## Worker Integration (Phase 5 WORK)

Workers receive prototype context in their task descriptions when prototypes are available:

```javascript
// In arc-phase-work.md task creation
const prototypeManifest = exists(`tmp/arc/${id}/prototypes/manifest.json`)
  ? JSON.parse(Read(`tmp/arc/${id}/prototypes/manifest.json`))
  : null

// Per-task: inject prototype path if component matches
for (const task of planTasks) {
  let protoContext = ""
  if (prototypeManifest) {
    const matchingProto = prototypeManifest.components.find(c =>
      task.description.toLowerCase().includes(c.name.toLowerCase()) ||
      task.files?.some(f => f.toLowerCase().includes(c.safe_name.toLowerCase()))
    )
    if (matchingProto) {
      protoContext = `
PROTOTYPE AVAILABLE — Use as starting point:
  - Prototype: tmp/arc/${id}/${matchingProto.prototype_path}
  - Story: tmp/arc/${id}/${matchingProto.story_path}
  - VSM: ${matchingProto.vsm_path}
  ${matchingProto.has_library_match ? `- Library: ${matchingProto.library} (HIGH trust ~85-95%)` : '- No library match — prototype uses Tailwind CSS directly'}

  INSTRUCTIONS:
  1. Read the prototype FIRST — it captures 70-80% of the design intent
  2. Adapt to project conventions (imports, state management, routing)
  3. Integrate with actual API endpoints and data models
  4. Preserve design tokens and layout structure from prototype
  5. Add production concerns: error handling, loading states, accessibility`
    }
  }

  TaskCreate({
    subject: task.subject,
    description: `${task.description}\n${protoContext}`,
    // ...
  })
}
```

## Storybook Integration

This phase bootstraps `tmp/storybook/` via `bootstrap.sh --src-dir`. The same Storybook
instance is reused by:
- **Phase 3.3 STORYBOOK VERIFICATION**: Adds implemented component stories via `--story-files`
- **User preview**: Can open `http://localhost:6006` to preview prototypes before work begins

## Error Handling

| Error | Recovery |
|-------|----------|
| `design_sync.enabled` is false | Skip phase — status "skipped" |
| No VSM files from Phase 3 | Skip phase — nothing to prototype |
| Figma MCP unavailable | Skip phase — cannot call figma_to_react |
| figma_to_react fails for component | Skip that component, continue with others |
| UI builder MCP unavailable | Proceed without library matching — raw figma-ref prototypes |
| Circuit breaker (3 builder failures) | Stop matching, use existing matches + raw figma-ref for rest |
| All figma_to_react calls fail | Skip phase — workers implement without prototypes |
| Storybook bootstrap fails | Non-blocking — prototypes still available as files |
| Agent timeout (>8 min) | Proceed with completed prototypes |

## Crash Recovery

| Resource | Location |
|----------|----------|
| Figma references | `tmp/arc/{id}/prototypes/{name}/figma-reference.tsx` |
| Library matches | `tmp/arc/{id}/prototypes/{name}/library-match.tsx` |
| Prototypes | `tmp/arc/{id}/prototypes/{name}/prototype.tsx` |
| Stories | `tmp/arc/{id}/prototypes/{name}/prototype.stories.tsx` |
| Match report | `tmp/arc/{id}/prototypes/match-report.json` |
| Manifest | `tmp/arc/{id}/prototypes/manifest.json` |
| Team config | `$CHOME/teams/arc-prototype-{id}/` |
| Checkpoint state | `.claude/arc/{id}/checkpoint.json` (phase: "design_prototype") |

Recovery: On `--resume`, if design_prototype is `in_progress`, clean up stale team and re-run
from the beginning. Prototype generation is idempotent — files are overwritten cleanly.

## Output Directory Structure

```
tmp/arc/{id}/prototypes/
├── manifest.json                      # Component inventory + metadata
├── match-report.json                  # Library match results (all components)
├── {ComponentName}/
│   ├── figma-reference.tsx            # Raw figma-to-react output
│   ├── library-match.tsx              # UI builder match (if found)
│   ├── mapping.json                   # Match metadata (confidence, library)
│   ├── prototype.tsx                  # Synthesized React component
│   └── prototype.stories.tsx          # CSF3 Storybook story
└── ...
```
