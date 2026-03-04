---
name: design-sync
description: |
  Figma design synchronization workflow. Extracts design specs from Figma URLs,
  creates Visual Spec Maps (VSM), guides implementation workers, and reviews
  fidelity between design and code. 3-phase pipeline: PLAN (extraction) ->
  WORK (implementation) -> REVIEW (fidelity check).

  <example>
  user: "/rune:design-sync https://www.figma.com/design/abc123/MyApp?node-id=1-3"
  assistant: "Initiating design sync — extracting Figma specs and creating VSM..."
  </example>

  <example>
  user: "/rune:design-sync --review-only"
  assistant: "Running design fidelity review against existing VSM..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "<url1> [<url2> ...] [--plan-only] [--resume-work] [--review-only] [--urls <file>]"
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
- Active workflows: !`grep -rl '"active"' tmp/.rune-*-*.json 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:design-sync — Figma Design Synchronization

Extracts design specifications from Figma, creates Visual Spec Maps (VSM), coordinates implementation, and reviews design-to-code fidelity.

**Load skills**: `frontend-design-patterns`, `figma-to-react`, `context-weaving`, `rune-orchestration`, `polling-guard`, `zsh-compat`

## Usage

```
/rune:design-sync <url1>                             # Full pipeline: extract → implement → review
/rune:design-sync <url1> <url2> [<url3>...]          # Multi-URL: process multiple Figma files
/rune:design-sync --urls urls.txt                    # File-based input: one Figma URL per line
/rune:design-sync <figma-url> --plan-only            # Extract VSM only (no implementation)
/rune:design-sync --resume-work                      # Resume from existing VSM
/rune:design-sync --review-only                      # Review fidelity of existing implementation
```

## Prerequisites

1. **Figma MCP server** configured in `.mcp.json` with `FIGMA_TOKEN` environment variable
2. **design_sync.enabled** set to `true` in talisman.yml (default: false)
3. Frontend framework detected in project (React, Vue, Next.js, Vite)

## Pipeline Overview

```
Phase 0: Pre-Flight → Validate URL, check MCP availability, read talisman config
    |
Phase 1: Design Extraction (PLAN) → Fetch Figma data, create VSM files
    |
Phase 1.5: User Confirmation → Show VSM summary, confirm or edit before implementation
    |
Phase 2: Implementation (WORK) → Create components from VSM using swarm workers
    |
Phase 2.5: Design Iteration → Optional screenshot→analyze→fix loop for fidelity
    |
Phase 3: Fidelity Review (REVIEW) → Score implementation against VSM
    |
Phase 4: Cleanup → Shutdown workers, persist echoes, report results
```

## Phase 0: Pre-Flight

```
// Step 0.5: Read talisman config early for URL cap and gate checks
// readTalismanSection: "misc"
config = readTalismanSection("misc")
if NOT config?.design_sync?.enabled:
  AskUserQuestion("Design sync is disabled. Enable it in talisman.yml:\n\ndesign_sync:\n  enabled: true")
  STOP

// Step 1: Parse arguments
FIGMA_URL_PATTERN = /^https?:\/\/[^\s]*figma\.com\/[^\s]+/
flags = parseFlags($ARGUMENTS)  // --plan-only, --resume-work, --review-only, --urls

// Step 1.1: Collect Figma URLs from arguments
// Strategy: filter all positional args that match FIGMA_URL_PATTERN
let figmaUrls = []

if flags.urls:
  // --urls <file>: read one URL per line from file
  const urlsFileContent = Read(flags.urls)
  figmaUrls = urlsFileContent
    .split("\n")
    .map(line => line.trim())
    .filter(line => line.length > 0 && !line.startsWith("#"))
    .filter(url => FIGMA_URL_PATTERN.test(url))
  if figmaUrls.length === 0:
    AskUserQuestion(`No valid Figma URLs found in ${flags.urls}. Each line should be a Figma URL.`)
    STOP
else:
  // Positional args: any argument matching the Figma URL pattern
  figmaUrls = $ARGUMENTS
    .filter(arg => !arg.startsWith("--"))
    .filter(arg => FIGMA_URL_PATTERN.test(arg))

if figmaUrls.length === 0 AND NOT flags.resumeWork AND NOT flags.reviewOnly:
  AskUserQuestion("No Figma URL provided. Usage:\n  /rune:design-sync <figma-url>\n  /rune:design-sync <url1> <url2>\n  /rune:design-sync --urls urls.txt")
  STOP

// Cap at talisman max (default 10)
const maxFigmaUrls = config?.design_sync?.max_figma_urls ?? 10
if figmaUrls.length > maxFigmaUrls:
  warn(`${figmaUrls.length} URLs provided — capping at ${maxFigmaUrls}`)
  figmaUrls = figmaUrls.slice(0, maxFigmaUrls)

// Primary URL for single-URL consumers (backward compat) and MCP probing
const figmaUrl = figmaUrls[0] ?? null

// Step 2: Validate all Figma URLs
FIGMA_URL_STRICT_PATTERN = /^https:\/\/www\.figma\.com\/(design|file)\/[A-Za-z0-9]+/
const invalidUrls = figmaUrls.filter(u => !FIGMA_URL_STRICT_PATTERN.test(u))
```

### Figma URL Validation Constants

Two URL patterns are used depending on context:

- **`FIGMA_URL_STRICT`**: `/^https:\/\/(?:www\.)?figma\.com\/(?:design|file)\/[a-zA-Z0-9]+/`
  - HTTPS only (no HTTP)
  - Restricts path to `design` or `file` types
  - Use for **all MCP tool invocations** (`figma_fetch_design`, `figma_inspect_node`, `figma_list_components`, `figma_to_react`)
  - Rejects HTTP, invalid path types, and malformed file keys before making API calls

- **`FIGMA_URL_LENIENT`**: `/^https?:\/\/[^\s]*figma\.com\/[^\s]+/`
  - Accepts HTTP or HTTPS
  - Permissive path matching — accepts any non-whitespace path
  - Use for **user input parsing** (filtering positional arguments, reading URLs from `--urls` file)
  - Accepts the broadest set of recognizable Figma URLs before strict validation

**When each applies**:
- Step 1 (collect URLs from arguments): use `FIGMA_URL_LENIENT` — cast wide net for URL collection
- Step 2 (validate before MCP probing): use `FIGMA_URL_STRICT` — reject invalid URLs early, before API calls
- MCP tool calls: always validate with `FIGMA_URL_STRICT` first; never pass unvalidated URLs to MCP tools

```
// [pseudocode continues]
if invalidUrls.length > 0:
  AskUserQuestion(`Invalid Figma URL format for: ${invalidUrls.join(", ")}\nPlease provide valid Figma URLs (https://www.figma.com/design/...).`)
  STOP

// Parse primary URL into components for reuse by Step 3.5 and Phase 1
parsedUrl = parseFigmaUrl(figmaUrl)
// parsedUrl = { fileKey: "abc123", nodeId: "1-3" | null, type: "design"|"file" }
// See references/figma-url-parser.md for full parser logic

// Step 3.5: MCP Provider Detection
// Read talisman override — auto|rune|official|desktop (default: "auto")
```

### MCP Provider Fallback Strategy

MCP provider availability handling differs between design-sync and arc orchestration:

| Context | Behavior when no MCP provider detected | Rationale |
|---------|----------------------------------------|-----------|
| **design-sync standalone** (this skill) | `AskUserQuestion(...)` + `STOP` — **mandatory, fail with user error** | Interactive skill: user is present and can act on setup instructions immediately |
| **arc-phase-design-extraction** (arc Phase 6) | Log warning + `continue` — **skippable, non-blocking** | Orchestration: arc must not block an entire pipeline run due to optional Figma integration |

**Rule**: design-sync is interactive (user-facing) — MCP is required and the user must be told how to fix it. Arc orchestration is non-blocking — Figma extraction is best-effort and arc continues without it.

When adding new callers of the MCP detection block, classify them explicitly:
- User-facing workflow: REQUIRED — treat missing MCP as fatal
- Orchestration/automation: SKIPPABLE — log warning and continue

```
// [pseudocode continues]
figmaProviderOverride = config?.design_sync?.figma_provider ?? "auto"
mcpProvider = null  // "rune" | "official" | "desktop" | null

if figmaProviderOverride === "rune" OR figmaProviderOverride === "auto":
  // Probe Rune MCP — use figma_fetch_design(depth=1) as cheap availability check
  try:
    figma_fetch_design(url=figmaUrl, depth=1)
    mcpProvider = "rune"
  catch:
    // Rune MCP not available — fall through to next provider

if mcpProvider === null AND (figmaProviderOverride === "official" OR figmaProviderOverride === "auto"):
  // Probe Official Figma MCP
  try:
    mcp__claude_ai_Figma__get_metadata(fileKey=parsedUrl.fileKey)
    mcpProvider = "official"
  catch:
    // Official MCP not available — fall through

if mcpProvider === null AND figmaProviderOverride === "desktop":
  // Probe Desktop MCP bridge directly
  try:
    mcp__figma_desktop__get_selection()
    mcpProvider = "desktop"
  catch:
    // Desktop bridge not available

if mcpProvider === null:
  // No provider detected — show setup options
  AskUserQuestion(
    "No Figma MCP provider detected. Choose a setup option:\n\n" +
    "1. **Rune MCP** (recommended): Add to .mcp.json — see scripts/figma-to-react/start.sh\n" +
    "2. **Official Figma MCP**: Add FIGMA_TOKEN to .mcp.json official server config\n" +
    "3. **Desktop MCP**: Open Figma Desktop → Enable Dev Mode (Shift+D) → enable MCP bridge\n\n" +
    "After setup, set `design_sync.figma_provider` in talisman.yml to skip auto-detection."
  )
  STOP

// Store mcp_provider in state file (written at Step 7)
stateExtras = { mcp_provider: mcpProvider, parsed_url: parsedUrl }

// Step 4: (removed — MCP availability now checked in Step 3.5)
figmaMcpAvailable = mcpProvider !== null

// Step 5: Check agent-browser availability (for Phase 2.5)
agentBrowserAvailable = checkAgentBrowser()  // non-blocking, used later

// Step 6: Session isolation
CHOME = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
timestamp = Bash("date +%Y%m%d-%H%M%S").stdout.trim()
workDir = "tmp/design-sync/{timestamp}"
Bash("mkdir -p {workDir}/vsm {workDir}/components {workDir}/reviews {workDir}/iterations")

// Step 7: Write state file with session isolation
stateFile = "tmp/.rune-design-sync-{timestamp}.json"
Write(stateFile, JSON.stringify({
  status: "active",
  phase: "pre-flight",
  figma_url: figmaUrl,           // primary URL (backward compat)
  figma_urls: figmaUrls,         // full URL array
  url_statuses: figmaUrls.map(url => ({ url, status: "pending", vsm_count: 0 })),
  parsed_url: stateExtras.parsed_url,
  mcp_provider: stateExtras.mcp_provider,
  work_dir: workDir,
  config_dir: CHOME,
  owner_pid: "$PPID",
  session_id: "$CLAUDE_SESSION_ID",
  started_at: timestamp,
  flags: flags
}))

// Step 8: Handle flags
if flags.resumeWork:
  // Find most recent VSM directory
  // Resume from Phase 2
if flags.reviewOnly:
  // Skip to Phase 3
```

See [figma-url-parser.md](references/figma-url-parser.md) for URL format details.

## Phase 1: Design Extraction

Extract Figma design data and create Visual Spec Maps (VSM).

```
// Step 1: Create extraction team
TeamCreate("rune-design-sync-{timestamp}")

// Step 2: Create extraction tasks for all Figma URLs
// For each URL, fetch components and create one task per top-level component/frame
let urlIndex = 0
for each url in figmaUrls:
  urlIndex++
  // Use a subdirectory per URL to prevent VSM filename collisions across files
  const urlWorkDir = figmaUrls.length > 1 ? `${workDir}/url-${urlIndex}` : workDir
  if figmaUrls.length > 1: Bash(`mkdir -p ${urlWorkDir}/vsm`)

  figmaData = figma_fetch_design(url=url)
  components = figma_list_components(url=url)

  // Step 3: Create one task per top-level component/frame
  for each component in components:
    TaskCreate({
      subject: "Extract VSM for {component.name}",
      description: "Fetch Figma node {component.id}, extract tokens, build region tree, map variants. Output: {urlWorkDir}/vsm/{component.name}.md. Source URL: {url}",
      metadata: { phase: "extraction", node_id: component.id, source_url: url, url_index: urlIndex }
    })

  // Update url_statuses in state file
  updateUrlStatus(url, "extracting")

// Step 4: Summon design-sync-agent workers
maxWorkers = config?.design_sync?.max_extraction_workers ?? 2
for i in range(maxWorkers):
  Agent(team_name="rune-design-sync-{timestamp}", name="design-syncer-{i+1}", ...)
    // Spawn design-sync-agent with extraction context

// Step 5: Monitor until extraction complete
// Use TaskList polling (see polling-guard)
```

See [phase1-design-extraction.md](references/phase1-design-extraction.md) for the full extraction algorithm.

### VSM Output Format

See [vsm-spec.md](references/vsm-spec.md) for the complete Visual Spec Map schema.

## Phase 1.5: User Confirmation

```
if NOT flags.planOnly:
  // Show VSM summary to user
  vsmFiles = Glob("tmp/design-sync/{timestamp}/vsm/*.md")
  summary = generateVsmSummary(vsmFiles)
  AskUserQuestion("VSM extraction complete:\n\n{summary}\n\nProceed to implementation? [yes/edit/stop]")

if flags.planOnly:
  // Write completion report, cleanup team, STOP
  updateState({ status: "completed", phase: "plan-only" })
  STOP
```

## Phase 2: Implementation

Create components from VSM using swarm workers.

```
// Step 1: Detect framework and resolve codegen profile
// Read design-system-profile.yaml (generated by discoverDesignSystem() in Phase 0 or earlier arc phases)
profilePath = ".claude/design-system-profile.yaml"
codegenProfile = "generic"  // default fallback
try:
  dsProfile = Read(profilePath)
  framework = dsProfile.framework  // "shadcn" | "untitled-ui" | "generic" | "unknown"

  // Check for talisman override
  overrideProfile = config?.design_sync?.codegen_profile ?? null
  if overrideProfile:
    codegenProfile = overrideProfile
  else if framework === "shadcn":
    codegenProfile = "shadcn"
  else if framework === "untitled-ui":
    codegenProfile = "untitled-ui"
  else:
    codegenProfile = "generic"
catch:
  // No profile found — use generic (Tailwind palette, clsx, no framework assumptions)
  codegenProfile = "generic"

// Step 1.5: Load codegen profile reference for worker injection
// See framework-codegen-profiles.md for the full transformation rules per profile
codegenProfileRef = "plugins/rune/skills/frontend-design-patterns/references/framework-codegen-profiles.md"
tokenMapRef = null
if codegenProfile === "shadcn":
  tokenMapRef = "plugins/rune/skills/frontend-design-patterns/references/profiles/shadcn-token-map.yaml"
else if codegenProfile === "untitled-ui":
  tokenMapRef = "plugins/rune/skills/frontend-design-patterns/references/profiles/untitled-ui-token-map.yaml"

codegenContext = "Codegen profile: {codegenProfile}. " +
  "Follow transformation rules in {codegenProfileRef} for the '{codegenProfile}' profile. " +
  (tokenMapRef ? "Use semantic tokens from {tokenMapRef}. " : "") +
  "Do NOT mix framework patterns (e.g., no cva() in UntitledUI, no CSS Modules in shadcn)."

// Step 2: Parse VSM files into implementation tasks
vsmFiles = Glob("{workDir}/vsm/*.md")
for each vsm in vsmFiles:
  TaskCreate({
    subject: "Implement {component_name} from VSM",
    description: "Read VSM at {vsm.path}. Create component following design tokens, layout, variants, and a11y requirements. " + codegenContext,
    metadata: { phase: "implementation", vsm_path: vsm.path, codegen_profile: codegenProfile }
  })

// Step 3: Summon rune-smith workers
maxWorkers = config?.design_sync?.max_implementation_workers ?? 3
for i in range(maxWorkers):
  Agent(team_name="rune-design-sync-{timestamp}", name="rune-smith-{i+1}", ...)
    // Spawn rune-smith with VSM context + frontend-design-patterns skill
    // Worker prompt includes: codegenContext for framework-native code generation

// Step 4: Monitor until implementation complete
```

See [phase2-design-implementation.md](references/phase2-design-implementation.md) for implementation guidance.
See [framework-codegen-profiles.md](../frontend-design-patterns/references/framework-codegen-profiles.md) for codegen transformation rules per framework.

## Phase 2.5: Design Iteration (Optional)

If agent-browser is available and design_sync.iterate_enabled is true:

```
if agentBrowserAvailable AND config?.design_sync?.iterate_enabled:
  // Create iteration tasks for each implemented component
  for each component in implementedComponents:
    TaskCreate({
      subject: "Iterate on {component_name} design fidelity",
      description: "Run screenshot→analyze→improve loop. Max {config.design_sync.max_iterations ?? 5} iterations.",
      metadata: { phase: "iteration", vsm_path: component.vsm_path }
    })

  // Summon design-iterator workers
  maxIterators = config?.design_sync?.max_iteration_workers ?? 2
  for i in range(maxIterators):
    Agent(team_name="rune-design-sync-{timestamp}", name="design-iter-{i+1}", ...)
      // Spawn design-iterator with VSM + screenshot context
```

See [screenshot-comparison.md](references/screenshot-comparison.md) for browser integration.

## Phase 3: Fidelity Review

Score implementation against design specifications.

```
// Step 1: Create fidelity review tasks
for each component in implementedComponents:
  TaskCreate({
    subject: "Review fidelity of {component_name}",
    description: "Score implementation against VSM. 6 dimensions: tokens, layout, responsive, a11y, variants, states.",
    metadata: { phase: "review", vsm_path: component.vsm_path }
  })

// Step 2: Summon design-implementation-reviewer
Agent(team_name="rune-design-sync-{timestamp}", name="design-reviewer-1", ...)
  // Spawn design-implementation-reviewer with VSM + component paths

// Step 3: Aggregate fidelity scores
// Read reviewer output, compute overall fidelity score
```

See [phase3-fidelity-review.md](references/phase3-fidelity-review.md) for the review protocol.
See [fidelity-scoring.md](references/fidelity-scoring.md) for the scoring algorithm.

## Phase 4: Cleanup

```javascript
// Step 1: Generate completion report
Write("{workDir}/report.md", completionReport)

// Step 2: Persist echoes
// Write design patterns learned to .claude/echoes/

// Step 3: Shutdown workers — dynamic member discovery with fallback
const teamName = `rune-design-sync-${timestamp}`
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // Fallback: known workers across all design-sync phases (max counts from talisman defaults)
  // Phase 1 (extraction): design-syncer-1, design-syncer-2
  // Phase 2 (implementation): rune-smith-1, rune-smith-2, rune-smith-3
  // Phase 3 (iteration): design-iter-1, design-iter-2, design-reviewer-1
  allMembers = ["design-syncer-1", "design-syncer-2",
    "rune-smith-1", "rune-smith-2", "rune-smith-3",
    "design-iter-1", "design-iter-2", "design-reviewer-1"]
}

for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Design sync complete" })
}

// Grace period for shutdown acknowledgment
if (allMembers.length > 0) { Bash("sleep 15") }

// Step 4: Cleanup team — TeamDelete with retry-with-backoff (3 attempts: 0s, 5s, 10s)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 5000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn(`design-sync cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}
// Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// Step 5: Update state
updateState({ status: "completed", phase: "cleanup", fidelity_score: overallScore })

// Step 6: Report to user
"Design sync complete. Fidelity: {score}/100. Report: {workDir}/report.md"
```

## Configuration

```yaml
# talisman.yml
design_sync:
  enabled: false                         # Master toggle (default: false)
  figma_provider: auto                   # MCP provider: auto|rune|official|desktop (default: auto)
                                         #   auto     — probe Rune first, then Official, then fail
                                         #   rune     — Rune figma-to-react MCP only (no FIGMA_TOKEN needed)
                                         #   official — Official Figma MCP only (requires FIGMA_TOKEN)
                                         #   desktop  — Figma Desktop bridge (requires Dev Mode Shift+D)
  max_extraction_workers: 2              # Extraction phase workers
  max_implementation_workers: 3          # Implementation phase workers
  max_iteration_workers: 2              # Iteration phase workers
  max_iterations: 5                      # Max design iterations per component
  iterate_enabled: false                 # Enable screenshot→fix loop (requires agent-browser)
  fidelity_threshold: 80                 # Min fidelity score to pass review
  codegen_profile: null                  # Force codegen profile: null (auto-detect) | shadcn | untitled-ui | generic
  token_snap_distance: 20               # Max RGB distance for color snapping
  figma_cache_ttl: 1800                  # Figma API cache TTL (seconds)
```

## State Persistence

All state files follow session isolation rules:

```json
{
  "status": "active",
  "phase": "extraction",
  "config_dir": "/Users/user/.claude",
  "owner_pid": "12345",
  "session_id": "abc-123",
  "started_at": "20260225-120000",
  "figma_url": "https://www.figma.com/design/...",
  "figma_urls": [
    "https://www.figma.com/design/abc123/MyApp?node-id=1-3",
    "https://www.figma.com/design/xyz789/Components"
  ],
  "url_statuses": [
    { "url": "https://www.figma.com/design/abc123/MyApp?node-id=1-3", "status": "completed", "vsm_count": 3 },
    { "url": "https://www.figma.com/design/xyz789/Components", "status": "pending", "vsm_count": 0 }
  ],
  "parsed_url": { "fileKey": "abc123", "nodeId": "1-3", "type": "design" },
  "mcp_provider": "rune",
  "work_dir": "tmp/design-sync/20260225-120000",
  "components": [],
  "fidelity_scores": {}
}
```

## Error Handling

### MCP Provider Errors

| Error | Rune MCP | Official MCP | Desktop MCP |
|-------|----------|--------------|-------------|
| Provider not detected | `figma_fetch_design` probe failed — check `.mcp.json` for Rune server entry | `mcp__claude_ai_Figma__get_metadata` probe failed — check `FIGMA_TOKEN` env var | `mcp__figma_desktop__get_selection` probe failed — Open Figma Desktop → Enable Dev Mode (Shift+D) |
| Auth failure | Rune MCP uses bundled token — check `scripts/figma-to-react/start.sh` config | `FIGMA_TOKEN` invalid or expired — regenerate at figma.com/settings | Desktop bridge requires active Figma Desktop session |
| File not found | File key invalid or not accessible to configured account | Same | Same — file must be open in Desktop |
| Rate limit | Rune MCP handles internally | Figma REST API rate-limited (429) — retry after delay | N/A (local IPC) |
| Node not found | `node-id` in URL does not exist — use `figma_list_components` to discover valid IDs | Same | Selection-based — ensure node is selected in Figma |

### Setup Options (when no provider detected)

1. **Rune MCP** (recommended, no personal token needed): Add to `.mcp.json`:
   ```json
   { "mcpServers": { "figma-to-react": { "command": "bash", "args": ["scripts/figma-to-react/start.sh"] } } }
   ```
2. **Official Figma MCP** (requires personal token): Set `FIGMA_TOKEN=figd_...` in env, configure official MCP server
3. **Desktop MCP**: Open Figma Desktop → Dev Mode (`Shift+D`) → enable MCP bridge in settings

### Error Response Convention

Error response type depends on execution context:

| Context | Error Response Type | Mechanism | Examples |
|---------|--------------------|-----------|----|
| **design-sync** (this skill, interactive) | INTERACTIVE | `AskUserQuestion(...)` + `STOP` | No Figma URL provided; design_sync not enabled; no MCP provider; invalid URL format |
| **arc orchestration** (e.g., arc-phase-design-extraction) | NON-BLOCKING | `warn(...)` + `continue` | MCP unavailable during arc Phase 6; URL parse failure on one of many URLs |

**Guidelines**:
- design-sync is user-facing: always surface errors interactively so the user can take immediate corrective action
- Arc orchestration is automated: log warnings and skip non-critical failures to avoid blocking an entire pipeline run
- `AskUserQuestion` is reserved for design-sync standalone contexts — never use it in arc subphases
- For arc contexts where a fatal condition is reached (e.g., zero valid URLs after filtering), log the error and set the phase result to `skipped` rather than `failed`

**Decision rule**: If a human is waiting for a response → INTERACTIVE. If running as part of automated orchestration → NON-BLOCKING.

## References

- [phase1-design-extraction.md](references/phase1-design-extraction.md) — Figma parsing and VSM creation
- [phase2-design-implementation.md](references/phase2-design-implementation.md) — VSM-guided implementation
- [phase3-fidelity-review.md](references/phase3-fidelity-review.md) — Fidelity review protocol
- [vsm-spec.md](references/vsm-spec.md) — Visual Spec Map schema
- [design-token-mapping.md](references/design-token-mapping.md) — Color snapping and token mapping
- [figma-url-parser.md](references/figma-url-parser.md) — URL format and file key extraction
- [figma-url-reader.md](references/figma-url-reader.md) — Dual-format frontmatter reader (figma_url scalar + figma_urls array)
- [fidelity-scoring.md](references/fidelity-scoring.md) — Scoring algorithm
- [screenshot-comparison.md](references/screenshot-comparison.md) — Agent-browser integration
- [framework-codegen-profiles.md](../frontend-design-patterns/references/framework-codegen-profiles.md) — Framework-specific codegen transformation rules
