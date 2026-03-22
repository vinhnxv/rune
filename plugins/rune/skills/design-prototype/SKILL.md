---
name: design-prototype
description: |
  Generate prototype React components + Storybook stories from Figma URLs.
  6-phase pipeline: figma_to_react → UntitledUI matching → prototype synthesis → verify → storybook integration → present.
  Input: Figma URL(s). Output: prototypes auto-copied to Storybook with full-screen preview opened in browser.
  Generates both individual components AND a full-page composition for complete screen preview.
  Use when you want to preview design implementation before coding.
  Trigger keywords: prototype, figma prototype, storybook from figma, design preview,
  generate components from figma, preview design.

  <example>
  user: "/rune:design-prototype https://www.figma.com/design/abc123/MyApp?node-id=1-3"
  assistant: "Generating prototypes from Figma design..."
  </example>

  <example>
  user: "/rune:design-prototype --describe 'login form with email and social login'"
  assistant: "Generating prototype from description..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "<figma-url> [--components N] [--no-storybook] [--describe 'text'] [--no-team]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Agent
  - TaskCreate
  - TaskUpdate
  - TaskGet
  - TaskList
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
---

**Runtime context** (preprocessor snapshot):
- Active workflows: !`find tmp -maxdepth 1 -name '.rune-*-*.json' -exec grep -l '"running"' {} + 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:design-prototype — Figma-to-Storybook Prototype Generator

Standalone prototype generator: extracts Figma designs, matches against UI library components, and synthesizes prototype React components with Storybook stories.

**Load skills**: `frontend-design-patterns`, `figma-to-react`, `design-system-discovery`, `storybook`, `context-weaving`, `rune-orchestration`, `team-sdk`, `polling-guard`, `zsh-compat`

## Usage

```
/rune:design-prototype <figma-url>                          # Full pipeline from Figma URL
/rune:design-prototype <url1> <url2>                        # Multiple Figma URLs
/rune:design-prototype --describe "login form with social"  # Text-only mode (library search)
/rune:design-prototype <url> --no-storybook                 # Skip Storybook story generation
/rune:design-prototype <url> --components 5                 # Limit to top N components
/rune:design-prototype <url> --no-team                      # Force single-agent mode
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--components N` | `5` | Max components to extract from Figma |
| `--no-storybook` | `false` | Skip Storybook story generation |
| `--describe 'text'` | — | Text-only mode: skip Figma extraction, search library by description |
| `--no-team` | `false` | Force single-agent mode (no Agent Team even for >= 3 components) |

## Prerequisites

1. **design_sync.enabled** set to `true` in talisman.yml (shared gate with design-sync)
2. **Figma MCP server** configured in `.mcp.json` (for URL mode)
3. Frontend framework detected in project (React, Vue, Next.js, Vite)

## Pipeline Overview

```
Phase 0: Validate Input + 3-Layer Detection
    → Parse ARGUMENTS, detect Figma URL vs text description
    → Check design_sync.enabled gate
    → Phase 0a (parallel): L1 discoverFrontendStack() + L3 discoverUIBuilder()
    → Phase 0b (sequential, URL mode): L2 discoverFigmaFramework()
    → Compose DesignContext → Write design-context.yaml
    → Create output directory
    |
Phase 1: Extract (URL mode only)
    → figma_list_components per URL
    → figma_to_react per component (capped by --components)
    → Save tokens-snapshot.json + extraction reports
    |
Phase 2: Match (conditional — requires UI builder MCP)
    → Search builder library for each extracted/described component
    → Circuit breaker: 3 consecutive failures → skip remaining
    → Write match-report.json with scores + confidence
    |
Phase 3: Synthesize
    → Combine figma-ref + library-match into prototype.tsx
    → Generate Storybook stories (unless --no-storybook)
    → Write per-component output to design-references/
    |
Phase 3.5: UX Flow Mapping (conditional — >= 2 components)
    → Analyze inter-component relationships
    → Generate flow-map.md with navigation + data flow
    |
Phase 4: Verify (conditional — >= 1 prototype generated)
    → Structural self-review of generated prototypes
    → Check import consistency, prop types, story coverage
    |
Phase 4.5: Storybook Integration (auto-copy + launch)
    → Copy prototypes to storybook/src/prototypes/
    → Install deps, launch Storybook dev server
    → Detect full-page composition, open in browser
    |
Phase 5: Present
    → Aggregate reports into summary
    → AskUserQuestion with next-step options
```

## Phase 0: Validate Input + 3-Layer Detection

Parse `$ARGUMENTS` to determine input mode, then run the 3-layer detection pipeline to
build a `DesignContext` that drives Phases 2-3. Detection has a combined timeout budget
of `detection_timeout_ms` (default: 5000ms) — see ARCH-004.

**Input modes**:
- **URL mode**: One or more Figma URLs detected → all 3 layers → full pipeline (Phases 1-5)
- **Text mode**: `--describe` flag present → Layer 1 + Layer 3 only (ARCH-005) → Phases 2-5
- **No input**: → `AskUserQuestion("Provide a Figma URL or use --describe 'text'")`

```
// Guard empty --describe (BACK-005) + harden input (SEC-005)
if flags.describe !== undefined:
  if (!flags.describe || flags.describe.trim().length === 0):
    AskUserQuestion("--describe requires a non-empty description. Example: --describe 'login form with email and social login'")
    STOP
  flags.describe = flags.describe.replace(/<[^>]*>/g, '').slice(0, 500)  // strip HTML, cap at 500 chars

talisman = readTalismanSection("settings")
if NOT talisman?.design_sync?.enabled:
  AskUserQuestion("design_sync.enabled is false. Enable it in talisman.yml to use this skill.")
  STOP

mode = flags.describe ? "describe" : "url"

// --- 3-Layer Detection Pipeline ---
// ARCH-001: L1 + L3 run in parallel (local file reads only, ~2-3 tool calls)
// ARCH-004: Combined timeout budget for all 3 layers
detection_timeout_ms = talisman?.design_prototype?.detection_timeout_ms ?? 5000
startTime = now()

// Phase 0a: Parallel — L1 (frontend stack) + L3 (builder MCP) + Figma fetch
[frontendStack, builderMCP] = parallel(
  discoverFrontendStack(repoRoot),                              // Layer 1: ~2 tool calls
  discoverUIBuilder(sessionCacheDir, repoRoot, null, null)      // Layer 3: ~1 tool call
)

// Phase 0b: Sequential — L2 (Figma framework, URL mode only)
figmaFramework = null
if mode === "url":
  // Fetch Figma API data (can overlap with L1+L3 in parallel)
  figmaApiResponse = figma_list_components(figmaUrls[0])
  nodeId = extractNodeId(figmaUrls[0])

  if (now() - startTime) < detection_timeout_ms:
    figmaFramework = discoverFigmaFramework(figmaApiResponse, nodeId)  // Layer 2: 0 tool calls

    // Re-run L3 with Figma framework for better builder matching
    if figmaFramework is not null AND figmaFramework.score >= 0.40:
      builderMCP = discoverUIBuilder(sessionCacheDir, repoRoot,
                                      frontendStack.detectedLibrary, figmaFramework)
// ARCH-005: Text mode skips Layer 2 entirely — figmaFramework stays null

// Compose unified context (see design-context.md)
if (now() - startTime) >= detection_timeout_ms:
  designContext = { synthesis_strategy: "tailwind", rationale: "Detection timeout exceeded" }
else:
  designContext = composeDesignContext(frontendStack, figmaFramework, builderMCP, mode)

// BACK-008: Cache key includes figma_node_id for per-URL caching
cacheKey = mode === "url" ? (sessionId + ":" + nodeId) : sessionId

timestamp = formatTimestamp()
outputDir = "design-references/{timestamp}"
Bash("mkdir -p {outputDir}")
Write("{outputDir}/design-context.yaml", designContext)  // Persist for Phase 2/3

maxComponents = flags.components ?? talisman?.design_sync?.max_reference_components ?? 5
```

**Tool call budget (BACK-009)**: Phase 0 costs ~4-6 tool calls total:
- L1: 1-2 (Read package.json + Glob configs)
- L2: 0 (uses already-fetched Figma API data)
- L3: 1-2 (Read .mcp.json + Glob skill frontmatter)
- Figma fetch: 1 (figma_list_components)
- Context write: 1 (Write design-context.yaml)

See [pipeline-phases.md](references/pipeline-phases.md) for detailed Phase 0 pseudocode and detection orchestration.
See [design-context.md](../design-system-discovery/references/design-context.md) for the `composeDesignContext()` algorithm and decision matrix.

## Phase 1: Extract

Runs only in URL mode. For each Figma URL:

1. Call `figma_list_components(url)` to discover top-level frames/components
2. Cap to `maxComponents` (sorted by visual hierarchy)
3. Call `figma_to_react(nodeId)` per component → reference JSX + Tailwind
4. Save raw extraction to `{outputDir}/extractions/{component-name}.tsx`
5. Write `{outputDir}/tokens-snapshot.json` with design token summary

**Token budget**: Each `figma_to_react` call costs ~2-5k tokens. Cap prevents runaway costs.

```
components = []
for url in figmaUrls:
  listing = figma_list_components(url)
  nodes = listing.components.slice(0, maxComponents)
  for node in nodes:
    result = figma_to_react(node.id)
    safeName = node.name.replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 64)  // SEC-002: path sanitization
    Write("{outputDir}/extractions/{safeName}.tsx", result.code)
    components.push({ name: node.name, safeName, code: result.code, nodeId: node.id, url })

Write("{outputDir}/tokens-snapshot.json", extractDesignTokens(components))
```

See [pipeline-phases.md](references/pipeline-phases.md) for extraction error handling.

## Phase 2: Match

Conditional on `designContext.builder !== null` (a UI builder MCP is available) AND
`designContext.synthesis_strategy !== "tailwind"` (detection found a matchable framework).

```
if designContext.builder === null OR designContext.synthesis_strategy === "tailwind":
  // No builder or pure tailwind strategy — skip matching, Phase 3 uses raw output
  SKIP to Phase 3

matchResults = []
consecutiveFailures = 0
timeout = talisman?.design_sync?.reference_timeout_ms ?? 15000
threshold = talisman?.design_sync?.library_match_threshold ?? 0.5

for component in components:
  if consecutiveFailures >= 3:
    BREAK  // Circuit breaker

  try:
    matches = builderProfile.search(component.name, { timeout })
    bestMatch = matches.filter(m => m.score >= threshold)[0]
    if bestMatch:
      matchResults.push({ component: component.name, match: bestMatch })
      consecutiveFailures = 0
    else:
      matchResults.push({ component: component.name, match: null })
  catch:
    consecutiveFailures++

Write("{outputDir}/match-report.json", matchResults)
```

See [pipeline-phases.md](references/pipeline-phases.md) for circuit breaker details and text-mode matching.

## Phase 3: Synthesize

Combines Figma reference code with library matches to produce prototype components.
Uses `designContext.synthesis_strategy` to determine code generation approach:
- `"library"` → use library adapter for correct props, imports, icons via Semantic IR
- `"hybrid"` → Tailwind CSS with library naming conventions
- `"tailwind"` → raw Tailwind CSS from figma-to-react output

**Adapter-based code generation pipeline** (DEPTH-001):

1. **Select adapter**: `selectAdapter(designContext)` → returns `UNTITLEDUI_ADAPTER`, `SHADCN_ADAPTER`, or `TAILWIND_ADAPTER` based on `synthesis_strategy` and detected library. Falls back to Tailwind if no adapter matches (DEPTH-003).
2. **Extract Semantic IR**: `extractSemanticIR(figmaRef)` → produces `SemanticComponent[]` with type, intent, size, state, icons. Covers all 15 component types.
3. **Dispatch per IR type**: `generateComponentCode(irComp, adapter)` → maps each `SemanticComponent` through the adapter's type mapping table for correct props, variants, sizes, icons, and state props.
4. **Compose prototype**: Merge code fragments with Figma layout intent (flex, grid, spacing) into a single `prototype.tsx`.
5. **Generate story**: CSF3 Storybook story with baseline variants (Default, Loading, Error, Empty, Disabled).

```
adapter = selectAdapter(designContext)

for component in components:
  figmaRef = Read("{outputDir}/prototypes/{component.name}/figma-reference.tsx")
  irComponents = extractSemanticIR(figmaRef)
  codeFragments = irComponents.map(ir => generateComponentCode(ir, adapter))
  prototype = composePrototype(codeFragments, extractLayoutIntent(figmaRef))
  Write("{outputDir}/prototypes/{component.name}/prototype.tsx", prototype)

  if NOT flags.noStorybook:
    storyCode = generateStory(component, prototype, stackInfo)
    Write("{outputDir}/prototypes/{component.name}/prototype.stories.tsx", storyCode)
```

See [prototype-conventions.md](references/prototype-conventions.md) for synthesis rules, library-specific import patterns, and adapter-aware conventions.
See [library-adapters.md](../design-system-discovery/references/library-adapters.md) for adapter registry and `selectAdapter()`.
See [semantic-ir.md](../design-system-discovery/references/semantic-ir.md) for `SemanticComponent` interface and `extractSemanticIR()`.

## Phase 3.5: UX Flow Mapping

Conditional: only runs when >= 2 components were extracted. Analyzes relationships between components to produce a navigation and data flow map.

```
if components.length >= 2:
  flowMap = analyzeComponentRelationships(components, matchResults)
  Write("{outputDir}/flow-map.md", flowMap)
```

## Phase 4: Verify

Conditional: runs when >= 1 prototype was generated. Performs structural self-review:

- Import consistency (no missing/unused imports)
- Prop type completeness
- Story coverage (each variant has a story)
- Tailwind class validity
- Accessibility basics (alt text, aria labels, semantic HTML)
- (4.1-4.2) Visual verification substeps: conditional screenshot comparison via agent-browser when `storybook.enabled` and Storybook is running. See [pipeline-phases.md](references/pipeline-phases.md) for details.

```
prototypes = Glob("{outputDir}/prototypes/*/prototype.tsx")
if prototypes.length === 0:
  SKIP to Phase 5

issues = []
for proto in prototypes:
  content = Read(proto)
  issues.push(...verifyPrototype(content))

Write("{outputDir}/verify-report.md", formatVerifyReport(issues))
```

## Phase 4.5: Storybook Integration (Bootstrap + Launch)

Bootstraps an ephemeral Storybook environment at `tmp/storybook/`, copies prototypes into it, and launches the dev server. The `tmp/storybook/` directory is session-scoped — cleaned by `/rune:rest`.

**Gate**: `--no-storybook` is NOT set AND prototypes were generated.

Uses `scripts/storybook/bootstrap.sh` which handles: scaffold (once) → install deps (once) → copy prototypes → detect full-page composition → return JSON `{ storybook_dir, full_page_component, ready }`. After bootstrap, kills existing Storybook on port 6006, launches fresh, and opens the full-page composition (or first component) in browser.

See [pipeline-phases.md](references/pipeline-phases.md) for the full Phase 4.5 implementation code and bootstrap script details.

## Phase 5: Present

Aggregate all reports and present to user with actionable next steps.

```
summary = {
  components_extracted: components.length,
  library_matches: matchResults.filter(m => m.match).length,
  prototypes_generated: Glob("{outputDir}/prototypes/*/prototype.tsx").length,
  stories_generated: Glob("{outputDir}/prototypes/*/*.stories.tsx").length,
  issues_found: issues.length,
  output_dir: outputDir,
  storybook_launched: summary.storybook_launched || false,
  storybook_url: summary.storybook_url || null,
  full_page_component: findFullPageComponent(prototypeFiles) || null
}

Write("{outputDir}/summary.json", summary)

// Present full-page component prominently
if (summary.full_page_component) {
  present(`Full screen preview: ${summary.full_page_component}`)
  present(`Open: ${summary.storybook_url}`)
}

AskUserQuestion(formatSummary(summary) + "\n\nNext steps:\n" +
  (summary.storybook_launched
    ? "1. ✅ Storybook running — full screen preview opened in browser\n"
    : "1. Run Storybook to preview: cd tmp/storybook && npx storybook dev\n") +
  "2. Run /rune:design-sync <url> for full implementation pipeline\n" +
  "3. Regenerate with different options\n\n" +
  "Choose an option or provide feedback:")
```

See [report-format.md](references/report-format.md) for summary formatting.

## Output Directory Structure

Per-component: `tmp/design-prototype/{timestamp}/{component-name}/` with `extraction.tsx`, `prototype.tsx`, `prototype.stories.tsx`, `match.json`. Per-run: `tokens-snapshot.json`, `match-report.json`, `flow-map.md`, `verify-report.md`, `summary.json`. Storybook runtime at `tmp/storybook/` (session-scoped, cleaned by `/rune:rest`).

See [report-format.md](references/report-format.md) § Output Directory Structure for the full tree.

## Agent Team Architecture

When >= 3 components AND `--no-team` is NOT set, the pipeline uses Agent Teams for parallel extraction and synthesis.

```
if components.length >= 3 AND NOT flags.noTeam:
  teamName = "rune-prototype-{timestamp}"
  try:
    TeamCreate({ team_name: teamName })

  // Create extraction tasks
  for component in components:
    TaskCreate({
      subject: "Extract + synthesize {component.name}",
      description: "Run figma_to_react, match against builder, synthesize prototype + story",
      metadata: { phase: "extract-synthesize", component: component.name }
    })

  // Spawn workers (max 5)
  workerCount = min(components.length, 5)
  for i in range(workerCount):
    Agent(team_name=teamName, name="proto-worker-{i+1}", ...)
  finally:

### Team Cleanup

## Teammate Fallback Array

```javascript
allMembers = ["proto-worker-1", "proto-worker-2", "proto-worker-3", "proto-worker-4", "proto-worker-5"]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

No skill-specific post-cleanup steps.

## Worker Trust Hierarchy

| Source | Priority | Usage |
|--------|----------|-------|
| Figma design (via figma_to_react) | 1 (highest) | Visual structure, layout, spacing |
| Design tokens (tokens-snapshot) | 2 | Colors, typography, spacing values |
| UI library match (builder search) | 3 | Real component API, props, variants |
| Stack conventions (detected) | 4 | Import paths, naming, file structure |
| Storybook patterns (project) | 5 | Story format, decorator usage |
| Generic defaults | 6 (lowest) | Fallback when no other source available |

## Error Handling

| Error | Response | Recovery |
|-------|----------|----------|
| `design_sync.enabled` is false | INTERACTIVE: AskUserQuestion with setup instructions | Enable in talisman.yml |
| No Figma URL and no `--describe` | INTERACTIVE: AskUserQuestion requesting input | Provide URL or description |
| Figma MCP not available | INTERACTIVE: AskUserQuestion with MCP setup options | Configure MCP in .mcp.json |
| figma_to_react fails for a component | WARN: skip component, continue pipeline | Retry with different node-id |
| Builder search timeout | Circuit breaker after 3 failures, skip remaining | Prototypes use raw Figma output |
| All extractions fail | INTERACTIVE: AskUserQuestion reporting failure | Check Figma URL validity |
| Storybook generation fails | WARN: write prototype without story | Manual story creation |

## Configuration

```yaml
# talisman.yml — under design_sync section
design_sync:
  enabled: false                         # Master toggle (shared with design-sync)
  prototype_generation: true             # Enable prototype output (default: true)
  storybook_preview: true                # Generate Storybook stories (default: true)
  max_reference_components: 5            # Max components to extract per URL
  reference_timeout_ms: 15000            # Per-component figma_to_react timeout in ms (Phase 1 extraction)
  library_timeout_ms: 10000             # Per-component UntitledUI search timeout in ms
  library_match_threshold: 0.5          # Min score to accept a library match

# talisman.yml — under design_prototype section (Phase 0 detection)
design_prototype:
  detection_timeout_ms: 5000             # Max time for 3-layer detection pipeline (ARCH-004)
  cache_enabled: true                    # Enable detection result caching (BACK-008)
```

## References

- [pipeline-phases.md](references/pipeline-phases.md) — Detailed phase pseudocode and error handling
- [prototype-conventions.md](references/prototype-conventions.md) — Synthesis rules, naming, story format
- [report-format.md](references/report-format.md) — Summary and report templates
- Cross-references: [design-sync](../design-sync/SKILL.md), [figma-to-react](../figma-to-react/SKILL.md), [storybook](../storybook/SKILL.md), [design-system-discovery](../design-system-discovery/SKILL.md)
