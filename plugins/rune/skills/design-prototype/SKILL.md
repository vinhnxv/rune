---
name: design-prototype
description: |
  Generate prototype React components + Storybook stories from Figma URLs.
  5-phase pipeline: figma_to_react → UntitledUI matching → prototype synthesis → verify → present.
  Input: Figma URL(s). Output: design-references/ directory with prototypes + stories.
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
- Active workflows: !`grep -rl '"active"' tmp/.rune-*-*.json 2>/dev/null || true | wc -l | tr -d ' '`
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
Phase 0: Validate Input + Mode Selection
    → Parse ARGUMENTS, detect Figma URL vs text description
    → Check design_sync.enabled gate
    → Run discoverUIBuilder(), detect React stack
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
Phase 5: Present
    → Aggregate reports into summary
    → AskUserQuestion with next-step options
```

## Phase 0: Validate Input + Mode Selection

Parse `$ARGUMENTS` to determine input mode:
- **URL mode**: One or more Figma URLs detected → full pipeline (Phases 1-5)
- **Text mode**: `--describe` flag present → skip Phase 1, use description for library search (Phases 2-5)
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

builderProfile = discoverUIBuilder()  // from design-system-discovery
stackInfo = detectReactStack()        // package.json scan

timestamp = formatTimestamp()
outputDir = "design-references/{timestamp}"
Bash("mkdir -p {outputDir}")

maxComponents = flags.components ?? talisman?.design_sync?.max_reference_components ?? 5
```

See [pipeline-phases.md](references/pipeline-phases.md) for detailed input parsing logic.

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

Conditional on `builderProfile !== null` (a UI builder MCP is available). Searches the builder library for real component matches.

```
if builderProfile === null:
  // No builder — skip matching, Phase 3 uses raw figma-to-react output
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

For each component:
1. If library match exists → merge reference structure with real library component API
2. If no match → use Figma reference code with Tailwind styling as-is
3. Generate `prototype.tsx` with proper imports and prop types
4. If `--no-storybook` is NOT set → generate `prototype.stories.tsx` (CSF3 format)

```
for component in components:
  match = matchResults.find(m => m.component === component.name)
  prototypeCode = synthesizePrototype(component, match, stackInfo)
  Write("{outputDir}/prototypes/{component.name}/prototype.tsx", prototypeCode)

  if NOT flags.noStorybook:
    storyCode = generateStory(component, prototypeCode, stackInfo)
    Write("{outputDir}/prototypes/{component.name}/prototype.stories.tsx", storyCode)
```

See [prototype-conventions.md](references/prototype-conventions.md) for synthesis rules and story format.

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

## Phase 5: Present

Aggregate all reports and present to user with actionable next steps.

```
summary = {
  components_extracted: components.length,
  library_matches: matchResults.filter(m => m.match).length,
  prototypes_generated: Glob("{outputDir}/prototypes/*/prototype.tsx").length,
  stories_generated: Glob("{outputDir}/prototypes/*/*.stories.tsx").length,
  issues_found: issues.length,
  output_dir: outputDir
}

Write("{outputDir}/summary.json", summary)

AskUserQuestion(formatSummary(summary) + "\n\nNext steps:\n" +
  "1. Copy prototypes to your component directory\n" +
  "2. Run /rune:design-sync <url> for full implementation pipeline\n" +
  "3. Run Storybook to preview stories: npx storybook dev\n" +
  "4. Regenerate with different options\n\n" +
  "Choose an option or provide feedback:")
```

See [report-format.md](references/report-format.md) for summary formatting.

## Output Directory Structure

```
tmp/design-prototype/{timestamp}/{component-name}/
├── extraction.tsx                  # Raw figma-to-react output
├── prototype.tsx                   # Synthesized React component
├── prototype.stories.tsx           # Storybook CSF3 story
└── match.json                      # Library match result for this component

tmp/design-prototype/{timestamp}/
├── tokens-snapshot.json            # Extracted design tokens
├── match-report.json               # Library match results (all components)
├── flow-map.md                     # UX flow mapping (>= 2 components)
├── verify-report.md                # Verification results
└── summary.json                    # Aggregate summary
```

## Agent Team Architecture

When >= 3 components AND `--no-team` is NOT set, the pipeline uses Agent Teams for parallel extraction and synthesis.

```
if components.length >= 3 AND NOT flags.noTeam:
  teamName = "rune-prototype-{timestamp}"
  TeamCreate({ name: teamName })

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
```

### Team Cleanup

Standard 5-component pattern:

```
// 1. Dynamic member discovery
CHOME = Bash('echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"')
teamConfig = Read("{CHOME}/teams/{teamName}/config.json")
allMembers = teamConfig.members.map(m => m.name).filter(n => /^[a-zA-Z0-9_-]+$/.test(n))

// 2. Shutdown request to all members
for member in allMembers:
  SendMessage({ type: "shutdown_request", recipient: member, content: "Prototype pipeline complete" })

// 3. Grace period
if allMembers.length > 0: Bash("sleep 20")

// 4. TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
for attempt in [0, 5, 10, 15]:
  if attempt > 0: Bash("sleep {attempt}")
  try: TeamDelete(); break
  catch: if last attempt: warn("TeamDelete failed after 4 attempts")

// 5. Filesystem fallback (only if TeamDelete never succeeded)
if NOT teamDeleteSucceeded:
  Bash('for pid in $(pgrep -P $PPID 2>/dev/null); do ... kill -TERM/-KILL ... done')
  Bash('CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/{teamName}/" "$CHOME/tasks/{teamName}/" 2>/dev/null')
```

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
```

## References

- [pipeline-phases.md](references/pipeline-phases.md) — Detailed phase pseudocode and error handling
- [prototype-conventions.md](references/prototype-conventions.md) — Synthesis rules, naming, story format
- [report-format.md](references/report-format.md) — Summary and report templates
- Cross-references: [design-sync](../design-sync/SKILL.md), [figma-to-react](../figma-to-react/SKILL.md), [storybook](../storybook/SKILL.md), [design-system-discovery](../design-system-discovery/SKILL.md)
