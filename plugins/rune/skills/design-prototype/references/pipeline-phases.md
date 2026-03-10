# Design Prototype Pipeline — Phase Reference

## Phase 1: Extract (Figma Inventory + Reference Generation)

```javascript
// Phase 1: Extract visual intent from Figma
const inventory = figma_list_components(url)
const components = inventory.slice(0, maxComponents)  // talisman cap

for (const comp of components) {
  try {
    const ref = figma_to_react(url + '?node-id=' + comp.nodeId, comp.name)
    Write(`${outputDir}/${comp.name}/figma-reference.tsx`, ref.code)
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
// Gate: builder MCP available (UntitledUI or similar)
if (!builderMCP) { skip("No builder MCP available") }

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
// Gate: React stack detected AND at least 1 library match
for (const comp of componentsWithBothRefs) {
  const figmaRef = Read(`${comp}/figma-reference.tsx`)
  const libraryMatch = Read(`${comp}/library-match.tsx`)

  // Extract LAYOUT INTENT from figma-ref (flex, grid, hierarchy)
  // Extract REAL API from library-match (imports, props, variants)
  // Synthesize: library component API + Figma layout intent

  const prototype = synthesize(figmaRef, libraryMatch)
  Write(`${comp}/prototype.tsx`, `// PROTOTYPE — adapt before production use\n${prototype}`)

  // CSF3 Storybook story
  const story = generateCSF3Story(comp.name, prototype)
  Write(`${comp}/prototype.stories.tsx`, story)
}
Write(`${outputDir}/reports/04-prototype-synthesis.md`, synthReport)
Write(`${outputDir}/prototypes-manifest.json`, prototypeMetadata)
```

**Inputs**: Phase 1 `figma-reference.tsx` + Phase 2 `library-match.tsx`
**Outputs**: `prototype.tsx` + `prototype.stories.tsx` per component, report 04, `prototypes-manifest.json`
**Gate**: React stack detected AND >= 1 library match from Phase 2
**Conditional**: Skipped when Phase 2 produces no matches (falls back to figma-ref only report)

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
    Write(`${outputDir}/_pages/${page.name}.tsx`, composePage(page))
  }
}

Write(`${outputDir}/reports/03b-ux-flow-mapping.md`, flowReport)
```

**Inputs**: Phase 3 prototypes, Figma inventory
**Outputs**: `flow-map.md`, enhanced stories (data states + interactions), `ux-patterns.md`, optional `_pages/`, report 03b
**Gate**: >= 2 prototype components
**Conditional**: Page composition requires >= 3 related components

## Phase 4: Verify (Self-Review + Visual Verification)

```javascript
// Step 4.0: Structural self-review
const completeness = checkCompleteness(inventory, prototypes)     // inventory vs prototypes
const elementCoverage = checkElements(figmaRefs, prototypes)      // element-level diff
const stateCoverage = checkStates(figmaRefs, stories)             // variants vs stories
const apiCoverage = checkAPIs(libraryMatches, prototypes)         // library props vs usage

Write(`${outputDir}/reports/04b-self-review.md`, selfReviewReport)

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
**Outputs**: Reports 04b (self-review) + 05 (verification summary)
**Steps**: 4.0 always runs; 4.1 conditional on Storybook MCP; 4.2 conditional on agent-browser; 4.3 merges all
**Dimensions**: Completeness, Element Coverage, State Coverage, API Coverage

## Phase 5: Present (Summary + User Interaction)

```javascript
// Aggregate all reports
const reports = Glob(`${outputDir}/reports/*.md`)
const summary = aggregateReports(reports)
Write(`${outputDir}/PIPELINE-SUMMARY.md`, summary)

// Per-component status
const componentStatus = prototypeComponents.map(comp => ({
  name: comp.name,
  phases: { extracted: true, matched: !!comp.libraryMatch, synthesized: !!comp.prototype },
  confidence: comp.overallConfidence,
  issues: comp.openIssues
}))
Write(`${outputDir}/SUMMARY.md`, renderStatusTable(componentStatus))

// User interaction
AskUserQuestion({
  question: "Pipeline complete. What would you like to do?",
  options: [
    "Open Storybook to preview prototypes",
    "Show detailed report",
    "Auto-fix verification issues",
    "Done — I'll take it from here"
  ]
})
```

**Inputs**: All reports from Phases 1-4
**Outputs**: `PIPELINE-SUMMARY.md`, `SUMMARY.md`, user prompt
**Always runs**: This phase has no gates
