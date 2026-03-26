# Phase 0: Pre-Flight

Detailed pre-flight steps for `/rune:design-sync`. Validates config, parses URLs, detects MCP provider, sets up session state.

## Step 0.5: Read Talisman Config

```
config = readTalismanSection("misc")
if NOT config?.design_sync?.enabled:
  AskUserQuestion("Design sync is disabled. Enable it in talisman.yml:\n\ndesign_sync:\n  enabled: true")
  STOP
```

## Step 1: Parse Arguments & Collect Figma URLs

```
FIGMA_URL_PATTERN = /^https?:\/\/[^\s]*figma\.com\/[^\s]+/
flags = parseFlags($ARGUMENTS)  // --plan-only, --resume-work, --review-only, --urls

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
```

## Step 2: Validate All Figma URLs

```
FIGMA_URL_STRICT_PATTERN = /^https:\/\/www\.figma\.com\/(design|file)\/[A-Za-z0-9]{22,26}/
const invalidUrls = figmaUrls.filter(u => !FIGMA_URL_STRICT_PATTERN.test(u))

if invalidUrls.length > 0:
  AskUserQuestion(`Invalid Figma URL format for: ${invalidUrls.join(", ")}\nPlease provide valid Figma URLs (https://www.figma.com/design/...).`)
  STOP

// Parse primary URL into components for reuse by Step 3.5 and Phase 1
parsedUrl = parseFigmaUrl(figmaUrl)
// parsedUrl = { fileKey: "abc123", nodeId: "1-3" | null, type: "design"|"file" }
// See references/figma-url-parser.md for full parser logic
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

## Step 3.5: MCP Provider Detection (Composition Model)

Probes ALL available providers independently — not an exclusive cascade.
Each provider contributes its unique capabilities. See capability routing in Phase 1.

```
figmaProviderOverride = config?.design_sync?.figma_provider ?? "auto"

// --- Probe each provider independently ---
providers = { framelink: false, rune: false, desktop: false }

if figmaProviderOverride === "auto" OR figmaProviderOverride === "framelink":
  // Probe Framelink — preferred for data extraction (AI-optimized, ~90% compression)
  try:
    get_figma_data(fileKey=parsedUrl.fileKey, depth=1)
    providers.framelink = true
  catch:
    // figma-context-mcp not available

if figmaProviderOverride === "auto" OR figmaProviderOverride === "rune":
  // Probe Rune MCP — unique capabilities: figma_inspect_node, figma_to_react
  try:
    figma_fetch_design(url=figmaUrl, depth=1)
    providers.rune = true
  catch:
    // Rune MCP not available

if figmaProviderOverride === "official":
  // Soft-deprecation: "official" is no longer a valid provider
  warn('figma_provider: "official" is deprecated in Rune v2.19.0. Use "framelink" or "auto" instead.')
  try:
    get_figma_data(fileKey=parsedUrl.fileKey, depth=1)
    providers.framelink = true
  catch:
    // figma-context-mcp not available

if figmaProviderOverride === "desktop":
  try:
    mcp__figma_desktop__get_selection()
    providers.desktop = true
  catch:
    // Desktop bridge not available

// --- Determine primary provider (for backward-compat state field) ---
// Priority: framelink (best data quality) > rune (most tools) > desktop (local)
const mcpProvider = providers.framelink ? "framelink"
                  : providers.rune ? "rune"
                  : providers.desktop ? "desktop"
                  : null

if mcpProvider === null:
  AskUserQuestion(
    "No Figma MCP provider detected. Choose a setup option:\n\n" +
    "1. **figma-context-mcp** (Framelink, recommended): Set FIGMA_TOKEN env var — already configured in .mcp.json as 'figma-context'. AI-optimized data, ~90% compression.\n" +
    "2. **Rune MCP**: Add to .mcp.json — see scripts/figma-to-react/start.sh. Unique: deep inspection + code generation.\n" +
    "3. **Desktop MCP**: Open Figma Desktop → Enable Dev Mode (Shift+D) → enable MCP bridge\n\n" +
    "**Best setup**: Both Framelink + Rune MCP for optimal results (compressed data + deep inspection + code gen).\n" +
    "After setup, set `design_sync.figma_provider` in talisman.yml to skip auto-detection."
  )
  STOP

stateExtras = { mcp_provider: mcpProvider, providers: providers, parsed_url: parsedUrl }
figmaMcpAvailable = true
```

### Provider Composition: Capability Routing

When multiple providers are available, each is used for its strengths:

| Capability | Best Provider | Fallback | Graceful Skip? |
|------------|--------------|----------|----------------|
| Data extraction (structure, tokens) | figma-context-mcp (Framelink) `get_figma_data` | Rune `figma_fetch_design` | No — at least one required |
| Component listing | figma-context-mcp (Framelink) `get_figma_data(depth=1)` | Rune `figma_list_components` | No — at least one required |
| Deep node inspection | Rune `figma_inspect_node` | _(none)_ | Yes — VSM still usable without deep inspection |
| Reference code generation | Rune `figma_to_react` | _(none)_ | Yes — VSM-only path works |
| Image download | figma-context-mcp (Framelink) `download_figma_images` | _(none)_ | Yes — optional enrichment |

**When only Rune available**: works exactly as before (backward compatible).
**When only Framelink available**: data extraction + images, no deep inspect or code gen (graceful degradation).
**When both available**: best of both worlds — compressed data + deep inspection + code gen + images.

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

## Steps 5–8: Session Setup

```
// Step 5: Check agent-browser availability (for Phase 2.5)
agentBrowserAvailable = checkAgentBrowser()  // non-blocking, used later

// Step 6: Session isolation
CHOME = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
timestamp = Bash("date +%Y%m%d-%H%M%S").trim()
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
  mcp_provider: stateExtras.mcp_provider,      // backward compat: primary provider name
  providers: stateExtras.providers,              // composition: { framelink, rune, desktop } booleans
  work_dir: workDir,
  config_dir: CHOME,
  owner_pid: "$PPID",
  session_id: "$CLAUDE_SESSION_ID" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
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
