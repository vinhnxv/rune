# Design Prototype Pipeline — Phase Reference

## Phase 0: Validate Input + 3-Layer Detection

Runs the 3-layer detection pipeline to build a `DesignContext` that drives code generation
in Phases 2-3. Combined timeout: `detection_timeout_ms` (default: 5000ms).

```javascript
// Phase 0: 3-Layer Detection Pipeline
// ARCH-001: L1 + L3 run in parallel (local file reads, ~2-3 tool calls)
// ARCH-004: Combined timeout budget for all 3 layers
// ARCH-005: Text mode (--describe) skips Layer 2 entirely

const mode = flags.describe ? "describe" : "url"
const detectionTimeout = talisman?.design_prototype?.detection_timeout_ms ?? 5000
const startTime = Date.now()

// Phase 0a: Parallel local detection
const [frontendStack, initialBuilder] = await Promise.all([
  discoverFrontendStack(repoRoot),                          // L1: ~2 tool calls
  discoverUIBuilder(sessionCacheDir, repoRoot, null, null)  // L3: ~1 tool call
])

// Phase 0b: Figma framework detection (URL mode only)
let figmaFramework = null
let figmaApiResponse = null
let builderMCP = initialBuilder

if (mode === "url") {
  // Fetch Figma API data
  figmaApiResponse = figma_list_components(figmaUrls[0])
  const nodeId = extractNodeId(figmaUrls[0])

  // L2: Detect framework from Figma metadata (0 extra tool calls)
  if ((Date.now() - startTime) < detectionTimeout) {
    figmaFramework = discoverFigmaFramework(figmaApiResponse, nodeId)

    // Re-run L3 with Figma framework for better builder matching
    if (figmaFramework?.score >= 0.40) {
      builderMCP = discoverUIBuilder(
        sessionCacheDir, repoRoot,
        frontendStack.detectedLibrary ?? null,
        figmaFramework
      )
    }
  }
}
// ARCH-005: In text mode, figmaFramework stays null — L2 never runs

// Compose unified context
let designContext
if ((Date.now() - startTime) >= detectionTimeout) {
  designContext = { synthesis_strategy: "tailwind", rationale: "Detection timeout exceeded" }
} else {
  designContext = composeDesignContext(frontendStack, figmaFramework, builderMCP, mode)
}

// BACK-008: Cache key includes figma_node_id for per-URL caching
// Prevents stale cache when analyzing multiple Figma URLs in same session
const cacheKey = mode === "url"
  ? `${sessionId}:${extractNodeId(figmaUrls[0])}`
  : sessionId

// Persist context for Phases 2-3
Write(`${outputDir}/design-context.yaml`, designContext)
```

**Inputs**: `$ARGUMENTS`, `talisman.yml`, `package.json`, `.mcp.json`, Figma URL(s)
**Outputs**: `design-context.yaml`, `designContext` object in memory
**Tool calls**: ~4-6 total (L1: 1-2, L2: 0, L3: 1-2, Figma fetch: 1, context write: 1)
**Timeout**: `detection_timeout_ms` (default: 5000ms) — falls back to `{ strategy: "tailwind" }`
**Mode guard**: `--describe` skips Layer 2 (no Figma API response in text mode)

## Phase 1: Extract (Figma Inventory + Reference Generation)

```javascript
// Phase 1: Extract visual intent from Figma
const inventory = figma_list_components(url)
const components = inventory.slice(0, maxComponents)  // talisman cap

for (const comp of components) {
  try {
    // Sanitize external API names before use in paths (SEC-003: path traversal prevention)
    const safeName = comp.name.replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 64)
    const ref = figma_to_react(url + '?node-id=' + comp.nodeId, safeName)
    Write(`${outputDir}/${safeName}/figma-reference.tsx`, ref.code)
    // Extract tokens from ref code
    tokens.push(...extractTokens(ref))
  } catch (e) {
    // Per-component timeout (15s), skip on failure
    warn(`Skipping ${comp.name}: ${e.message}`)
    continue
  }
}
Write(`${outputDir}/tokens-snapshot.json`, tokens)
Write(`${outputDir}/reports/01-figma-inventory.md`, inventoryReport)
Write(`${outputDir}/reports/02-reference-extraction.md`, extractionReport)
```

**Inputs**: Figma URL, `max_reference_components` (talisman), `reference_timeout_ms` (talisman)
**Outputs**: `figma-reference.tsx` per component, `tokens-snapshot.json`, reports 01 + 02
**Gate**: Figma MCP must be available (figma_list_components tool)
**Error handling**: Per-component try/catch with timeout — failures logged, pipeline continues

## Phase 2: Match (Library Component Matching)

```javascript
// Gate: builder MCP available AND strategy requires matching
if (!designContext.builder || designContext.synthesis_strategy === "tailwind") {
  skip("No builder MCP or tailwind-only strategy")
}

// Page Template Pre-Step (v2.12.0)
// Gate: builder has templates capability AND access tier is PRO
let templateMode = false
let baseCode = null
if (builderProfile.capabilities.templates && !flags.skipTemplates && builderProfile.accessTier === "pro") {
  try {
    const templates = get_page_templates()
    const bestTemplate = matchPageTemplate(templates, extractedRegions)
    if (bestTemplate.score >= 0.80) {
      log("Page template match: " + bestTemplate.name + " (score: " + bestTemplate.score + ")")
      // Use template as starting skeleton — fill regions from component matches
      baseCode = get_page_template_files(bestTemplate.slug)
      templateMode = true
    }
    // If score < 0.80, templateMode stays false — proceed with per-component matching
  } catch (e) {
    // Template fetch failed — not fatal, proceed with per-component matching
    warn("Page template check failed: " + e.message)
  }
}

let consecutiveFailures = 0
for (const comp of successfulExtractions) {
  if (consecutiveFailures >= 3) { warn("Circuit breaker: 3 consecutive failures"); break }

  const keywords = analyzeReference(comp.figmaRef)  // Extract component type + layout
  const matches = search_components(keywords)

  if (matches[0]?.confidence >= libraryMatchThreshold) {
    const detail = get_component(matches[0].slug)
    Write(`${outputDir}/${comp.name}/library-match.tsx`, detail.code)
    Write(`${outputDir}/${comp.name}/mapping.json`, {
      intent: keywords,
      slug: matches[0].slug,
      confidence: matches[0].confidence
    })
    consecutiveFailures = 0
  } else {
    consecutiveFailures++
  }
}
Write(`${outputDir}/reports/03-library-matching.md`, matchReport)
Write(`${outputDir}/library-manifest.json`, usedPackages)
```

**Inputs**: Phase 1 `figma-reference.tsx` files, `library_match_threshold` (talisman), `library_timeout_ms` (talisman)
**Outputs**: `library-match.tsx` + `mapping.json` per matched component, report 03, `library-manifest.json`
**Gate**: Builder MCP available (detected via `discoverUIBuilder()`)
**Circuit breaker**: 3 consecutive failures → stop matching (prevents API waste)
**Conditional**: Entire phase skipped if no builder MCP

## Phase 3: Synthesize (Prototype Generation)

```javascript
// Always runs when React stack detected
// Uses designContext.synthesis_strategy to select code generation approach:
//   "library"  → use library adapter for correct props/imports/icons (see library-adapters.md)
//   "hybrid"   → Tailwind CSS with library naming conventions
//   "tailwind" → raw figma-ref output (no library translation)

// Step 3.1: Select adapter based on DesignContext (see library-adapters.md §selectAdapter)
const adapter = selectAdapter(designContext)
// adapter is one of: UNTITLEDUI_ADAPTER, SHADCN_ADAPTER, TAILWIND_ADAPTER
// If strategy="library" but no adapter exists → logs warning, falls back to TAILWIND_ADAPTER (DEPTH-003)

for (const comp of componentsWithBothRefs) {
  const figmaRef = Read(`${comp}/figma-reference.tsx`)
  const libraryMatch = comp.hasLibraryMatch ? Read(`${comp}/library-match.tsx`) : null

  // Step 3.2: Extract Semantic IR from figma-ref (see semantic-ir.md §extractSemanticIR)
  const irComponents = extractSemanticIR(figmaRef)
  // Returns SemanticComponent[] — each with type, intent, size, state, icons, children

  // Step 3.3: Generate code using adapter dispatch table (DEPTH-001)
  // Adapter handles all 23 ComponentTypes from the IR:
  //   button, input, select, badge, card, breadcrumb, pagination, avatar-group,
  //   dialog, tabs, tooltip, toggle, alert, table, dropdown-menu,
  //   toast, checkbox, radio, textarea, slider, progress, sidebar, file-upload
  // Unhandled types fall through to Tailwind with warning comment
  const codeFragments = irComponents.map(irComp => {
    const typeMapping = adapter.types[irComp.type]

    if (!typeMapping) {
      // IR type not in adapter — emit raw Tailwind fallback with TODO comment
      return generateTailwindFallback(irComp, figmaRef)
    }

    return generateComponentCode(irComp, typeMapping, adapter, {
      // Import resolution: adapter.importStyle determines path format
      //   "relative" (UntitledUI): import { Button } from '@untitledui/button'
      //   "barrel"   (shadcn):     import { Button } from '@/components/ui/button'
      importStyle: adapter.importStyle,

      // Icon resolution: resolveIconName() fallback chain (semantic-ir.md §resolveIconName)
      //   iconMap lookup → Figma name sanitize → generic fallback
      iconPackage: adapter.iconPackage,

      // Variant mapping: irComp.intent → typeMapping.variants[intent]
      //   e.g., intent="destructive" → variant="error" (UntitledUI) or "destructive" (shadcn)
      // Size mapping: irComp.size → typeMapping.sizes[size]
      //   e.g., size="md" → size="md" (UntitledUI) or "default" (shadcn)
      // State mapping: irComp.state → typeMapping.stateProps[state]
      //   e.g., state="disabled" → disabled={true}
    })
  })

  // Step 3.4: Compose prototype from fragments + Figma layout intent
  const layoutIntent = extractLayoutIntent(figmaRef)  // flex direction, gaps, padding from Figma
  const imports = deduplicateImports(codeFragments)    // Merge all import statements
  const prototype = composePrototype(imports, codeFragments, layoutIntent)

  Write(`${comp}/prototype.tsx`, `// PROTOTYPE — adapt before production use\n${prototype}`)

  // Step 3.5: CSF3 Storybook story
  const story = generateCSF3Story(comp.name, prototype)
  Write(`${comp}/prototype.stories.tsx`, story)
}

Write(`${outputDir}/reports/04-prototype-synthesis.md`, synthReport)
Write(`${outputDir}/prototypes-manifest.json`, prototypeMetadata)
```

**Inputs**: Phase 1 `figma-reference.tsx` + Phase 2 `library-match.tsx` + `design-context.yaml`
**Outputs**: `prototype.tsx` + `prototype.stories.tsx` per component, report 04, `prototypes-manifest.json`
**Gate**: React stack detected
**Adapter selection**: `selectAdapter(designContext)` → dispatches to library-specific adapter (see [library-adapters.md](../../design-system-discovery/references/library-adapters.md))
**IR extraction**: `extractSemanticIR(figmaRef)` → produces `SemanticComponent[]` (see [semantic-ir.md](../../design-system-discovery/references/semantic-ir.md))
**Fallback**: When Phase 2 produces no library matches OR adapter type mapping is missing, falls through to Tailwind with warning comment

## Phase 3.5: UX Flow Mapping (Conditional)

```javascript
// Gate: >= 2 components with prototypes
if (prototypeComponents.length < 2) { skip("Need >= 2 components for flow mapping") }

// Analyze Figma inventory + prototypes for navigation flow
const flowMap = analyzeNavigationFlow(inventory, prototypes)
Write(`${outputDir}/flow-map.md`, renderMermaidFlowDiagram(flowMap))

// Generate data state stories
for (const comp of prototypeComponents) {
  const stateStories = generateDataStateStories(comp)
  // WithData, EmptyState, LoadingState, ErrorState
  Write(`${comp}/prototype.stories.tsx`, mergeStories(existing, stateStories))
}

// Generate interaction stories
for (const comp of interactiveComponents) {
  const interactionStories = generateInteractionStories(comp)
  // SubmitLoading, ValidationErrors, ModalOpen
  Write(`${comp}/prototype.stories.tsx`, mergeStories(existing, interactionStories))
}

// UX patterns analysis
Write(`${outputDir}/ux-patterns.md`, analyzeUXPatterns(prototypes))
// notification types, navigation transitions, loading strategies

// Optional: page-level composition (>= 3 related components)
if (relatedComponents.length >= 3) {
  for (const page of detectPages(relatedComponents)) {
    const safePageName = page.name.replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 64)
    Write(`${outputDir}/_pages/${safePageName}.tsx`, composePage(page))
  }
}

Write(`${outputDir}/reports/03.5-ux-flow-mapping.md`, flowReport)
```

**Inputs**: Phase 3 prototypes, Figma inventory
**Outputs**: `flow-map.md`, enhanced stories (data states + interactions), `ux-patterns.md`, optional `_pages/`, report 03.5
**Gate**: >= 2 prototype components
**Conditional**: Page composition requires >= 3 related components

## Phase 4: Verify (Self-Review + Visual Verification)

```javascript
// Step 4.0: Structural self-review
const completeness = checkCompleteness(inventory, prototypes)     // inventory vs prototypes
const elementCoverage = checkElements(figmaRefs, prototypes)      // element-level diff
const stateCoverage = checkStates(figmaRefs, stories)             // variants vs stories
const apiCoverage = checkAPIs(libraryMatches, prototypes)         // library props vs usage

Write(`${outputDir}/reports/04.5-self-review.md`, selfReviewReport)

// Step 4.1: Storybook MCP validation (conditional)
if (storybookMCP) {
  for (const comp of prototypeComponents) {
    const validation = storybook_validate(comp.storyPath)
    findings.push(...validation.issues)
  }
}

// Step 4.2: Visual verification via agent-browser + storybook-reviewer (conditional)
if (agentBrowser && storybookRunning) {
  for (const comp of prototypeComponents) {
    const visual = visualVerify(comp.storyUrl, comp.figmaRef)
    findings.push(...visual.issues)
  }
}

// Step 4.3: Gap synthesis — merge structural + visual findings
const gaps = synthesizeGaps(selfReview, storybookFindings, visualFindings)
Write(`${outputDir}/reports/05-verification-summary.md`, verificationReport)
```

**Inputs**: All Phase 1-3 outputs
**Outputs**: Reports 04.5 (self-review) + 05 (verification summary)
**Steps**: 4.0 always runs; 4.1 conditional on Storybook MCP; 4.2 conditional on agent-browser; 4.3 merges all
**Dimensions**: Completeness, Element Coverage, State Coverage, API Coverage

## Phase 4.5: Storybook Integration (Bootstrap + Launch)

Bootstraps an ephemeral Storybook at `tmp/storybook/` via the shared bootstrap script,
copies prototypes, launches the dev server, and opens the full-page composition.

```javascript
if (!flags.noStorybook && Glob(`${outputDir}/prototypes/*/prototype.tsx`).length > 0) {
  // 1. Bootstrap: scaffold + install deps + copy prototypes
  const bootstrapScript = `${RUNE_PLUGIN_ROOT}/scripts/storybook/bootstrap.sh`
  const result = Bash(`cd "${CWD}" && bash "${bootstrapScript}" --src-dir "${outputDir}/prototypes"`)
  const bootstrapResult = JSON.parse(result)

  // 2. Kill stale Storybook, launch fresh
  Bash(`lsof -ti:6006 | xargs kill -9 2>/dev/null || true`)
  Bash(`cd "${bootstrapResult.storybook_dir}" && npm run storybook &`)
  Bash(`sleep 10`)

  // 3. Open full-page composition in browser
  const fullPage = bootstrapResult.full_page_component
  const storyId = fullPage
    ? `prototypes-${fullPage.toLowerCase()}--primary`
    : `prototypes-${components[0].safeName.toLowerCase()}--primary`
  Bash(`open "http://localhost:6006/?path=/story/${storyId}"`)

  summary.storybook_dir = bootstrapResult.storybook_dir
  summary.storybook_launched = true
  summary.storybook_url = `http://localhost:6006/?path=/story/${storyId}`
  summary.full_page_component = fullPage
}
```

**Inputs**: Phase 3 prototypes
**Outputs**: `tmp/storybook/` bootstrapped, Storybook launched, browser opened
**Gate**: `--no-storybook` NOT set AND prototypes generated
**Shared with**: Arc Phase 3.3 (Storybook Verification) uses same `tmp/storybook/` via `bootstrap.sh --story-files`

## Phase 5: Present (Summary + User Interaction)

```javascript
// Aggregate all reports
const reports = Glob(`${outputDir}/reports/*.md`)
const pipelineSummary = aggregateReports(reports)
Write(`${outputDir}/PIPELINE-SUMMARY.md`, pipelineSummary)

// Per-component status — full-page component listed FIRST
const fullPage = findFullPageComponent(prototypeComponents)
const sortedComponents = fullPage
  ? [fullPage, ...prototypeComponents.filter(c => c.name !== fullPage.name)]
  : prototypeComponents

const componentStatus = sortedComponents.map(comp => ({
  name: comp.name,
  isFullPage: comp.name === fullPage?.name,
  phases: { extracted: true, matched: !!comp.libraryMatch, synthesized: !!comp.prototype },
  confidence: comp.overallConfidence,
  issues: comp.openIssues
}))
Write(`${outputDir}/SUMMARY.md`, renderStatusTable(componentStatus))

// User interaction — Storybook status reflected in options
AskUserQuestion({
  question: summary.storybook_launched
    ? `Pipeline complete. Full screen preview opened: ${summary.full_page_component || "Primary"}`
    : "Pipeline complete. What would you like to do?",
  options: summary.storybook_launched
    ? [
        "Show detailed report",
        "Auto-fix verification issues",
        "Regenerate with different options",
        "Done — I'll take it from here"
      ]
    : [
        "Open Storybook to preview prototypes",
        "Show detailed report",
        "Auto-fix verification issues",
        "Done — I'll take it from here"
      ]
})
```

**Inputs**: All reports from Phases 1-4.5
**Outputs**: `PIPELINE-SUMMARY.md`, `SUMMARY.md`, user prompt
**Always runs**: This phase has no gates

## Crash Recovery

If the design-prototype pipeline crashes mid-run, orphaned teams with prefix `rune-prototype-` may remain. On session resume:

| Prefix | Recovery | Notes |
|--------|----------|-------|
| `rune-prototype-` | `prePhaseCleanup()` preflight scan (ARC_TEAM_PREFIXES) + `postPhaseCleanup()` (PHASE_PREFIX_MAP: `design_prototype`) | Conditional on design_sync.enabled. Filesystem fallback: `rm -rf "$CHOME/teams/rune-prototype-*/"` |

Manual cleanup:
```bash
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
find "$CHOME/teams/" -maxdepth 1 -type d -name "rune-prototype-*" -exec rm -rf {} +
find "$CHOME/tasks/" -maxdepth 1 -type d -name "rune-prototype-*" -exec rm -rf {} +
```
