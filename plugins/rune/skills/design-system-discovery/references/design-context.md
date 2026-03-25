# DesignContext — Unified 3-Layer Detection Output

Merges outputs from all 3 detection layers into a single `DesignContext` object consumed by
`design-prototype` Phase 1+ (Extract, Match, Synthesize).

## composeDesignContext(frontendStack, figmaFramework, builderMCP, mode)

**Input**:
- `frontendStack` — output from `discoverFrontendStack()` (Layer 1), always available
- `figmaFramework` — output from `discoverFigmaFramework()` (Layer 2), null in text-only mode
- `builderMCP` — output from `discoverUIBuilder()` (Layer 3), null when no builder found
- `mode` — `"url"` (Figma URL provided) or `"describe"` (text-only, no Figma data)

**Output**: `DesignContext` object (see schema below)

### Algorithm

```
// Pseudocode — NOT implementation code
function composeDesignContext(frontendStack, figmaFramework, builderMCP, mode):

  // --- ARCH-005: Mode guard for text-only (--describe) paths ---
  // In text-only mode, Layer 2 (Figma) is unavailable. Callers MUST NOT call
  // discoverFigmaFramework() — pass figmaFramework = null instead.
  IF mode === "describe":
    figmaFramework = null  // Enforce: no Figma data in text mode

  // --- Build per-layer sections using wrapper keys (PAT-008) ---
  // Each layer's output uses flat fields internally.
  // Wrapper keys (stack, figma, builder) are used ONLY in this merged context.

  context = {
    // Layer 1: Project stack (always present)
    stack: {
      framework: frontendStack.framework,                // "react" | "nextjs" | etc.
      framework_version: frontendStack.framework_version, // integer or null
      build_tool: frontendStack.build_tool,
      css_framework: frontendStack.css_framework,
      css_version: frontendStack.css_version,
      confidence: frontendStack.confidence
    },

    // Layer 2: Figma framework (null in text-only mode)
    figma: null,

    // Layer 3: Builder MCP (null when no builder found)
    builder: null,

    // Synthesis decision (computed below)
    synthesis_strategy: "tailwind",  // default
    rationale: ""
  }

  // --- Populate Layer 2 (if available) ---
  IF figmaFramework is not null:
    context.figma = {
      detected: figmaFramework.framework,    // "untitled_ui" | "shadcn_ui" | etc.
      score: figmaFramework.score,           // 0.0-1.0
      match_summary: summarizeMatches(figmaFramework.matchDetails),
      alternatives: figmaFramework.alternatives
    }

  // --- Populate Layer 3 (if available) ---
  IF builderMCP is not null:
    context.builder = {
      builder_mcp: builderMCP.builder_mcp,
      detected_library: builderMCP.detected_library,
      capabilities: builderMCP.capabilities,
      matches_figma: builderMCP.matches_figma,
      confidence: builderMCP.confidence
    }

  // --- Compute synthesis_strategy ---
  context.synthesis_strategy = decideSynthesisStrategy(context)
  context.rationale = buildRationale(context)

  RETURN context
```

### decideSynthesisStrategy(context)

Determines the code generation approach based on all 3 layers.

```
// Pseudocode — NOT implementation code
function decideSynthesisStrategy(context):
  stack = context.stack
  figma = context.figma
  builder = context.builder

  // --- Non-React frameworks always get tailwind ---
  // Vue, Svelte, Nuxt use template syntax incompatible with React component libraries
  IF stack.framework is not null AND stack.framework NOT IN ["react", "nextjs"]:
    RETURN "tailwind"

  // --- No CSS framework or non-Tailwind CSS (ARCH-003 missing row) ---
  // React + CSS Modules / styled-components → don't generate Tailwind classes
  IF stack.css_framework is not null AND stack.css_framework !== "tailwind":
    RETURN "tailwind"  // Fallback: still generate Tailwind, but flag mismatch in rationale
    // NOTE: In future, a "css-modules" or "css-in-js" strategy could be added

  // --- Figma framework detected with high confidence ---
  IF figma is not null AND figma.score >= 0.40:

    // Library strategy: Figma framework detected + matching builder MCP available
    IF builder is not null AND builder.matches_figma === true:
      RETURN "library"

    // Check if detected framework has a known adapter (ARCH-003 missing row)
    // Only UntitledUI and shadcn have adapters — others fall back
    knownAdapterLibraries = ["untitled_ui", "shadcn_ui"]
    IF figma.detected NOT IN knownAdapterLibraries:
      RETURN "tailwind"  // Detected MUI/Ant/etc. but no adapter → raw Tailwind

    // Hybrid strategy: Figma framework detected but no builder MCP
    IF builder is null OR builder.matches_figma === false:
      RETURN "hybrid"

  // --- Low confidence or no Figma data ---
  // Includes: text-only mode, no Figma match, low score
  IF builder is not null:
    RETURN "tailwind"  // Builder available but no Figma match — offer MCP search

  RETURN "tailwind"  // Default: raw Tailwind CSS
```

## Conflict Resolution Rules

When layers produce contradictory signals, these rules determine the outcome:

| Conflict | Resolution | Rationale |
|----------|------------|-----------|
| Vue project + shadcn Figma | `tailwind` | shadcn is React-only; can't use its components in Vue |
| React + CSS Modules + UntitledUI Figma | `tailwind` (flagged) | CSS Modules project shouldn't get Tailwind classes |
| React + Tailwind + MUI Figma (high) + No MCP | `tailwind` | MUI detected but no adapter available |
| React + Tailwind + UntitledUI Figma (high) + shadcn MCP | `hybrid` | MCP doesn't match Figma framework |
| No framework + UntitledUI Figma (high) + UntitledUI MCP | `library` | MCP + Figma aligned; assume React |
| Text-only mode (any stack) | L1 + L3 only | No Figma data available; figma: null |

## Complete Decision Matrix

| Layer 1 (Stack) | Layer 2 (Figma) | Layer 3 (MCP) | Strategy | Notes |
|-----------------|-----------------|---------------|----------|-------|
| React + Tailwind | UntitledUI (>=0.40) | UntitledUI MCP | `library` | Full library components |
| React + Tailwind | shadcn (>=0.40) | shadcn MCP | `library` | Full library components |
| React + Tailwind | UntitledUI (>=0.40) | No MCP | `hybrid` | Tailwind + naming conventions |
| React + Tailwind | UntitledUI (>=0.40) | shadcn MCP | `hybrid` | MCP doesn't match Figma |
| React + Tailwind | MUI/Ant (>=0.40) | Any | `tailwind` | No adapter for MUI/Ant yet |
| React + Tailwind | Low (<0.40) | Any MCP | `tailwind` | Low confidence → default |
| React + Tailwind | No match | No MCP | `tailwind` | Default fallback |
| React + CSS Modules | Any | Any | `tailwind` | CSS Modules project (flagged) |
| React + styled-comp | Any | Any | `tailwind` | CSS-in-JS project (flagged) |
| Next.js + Tailwind | Same as React rows | Same | Same | Next.js treated as React |
| Vue / Nuxt | Any | Any | `tailwind` | Non-React framework |
| Svelte | Any | Any | `tailwind` | Non-React framework |
| None detected | Any | Any | `tailwind` | Default React + Tailwind v4 |
| Any (text-only) | null (skipped) | Any | `tailwind` | L2 unavailable |

## Detection Timeout Budget (ARCH-004)

All 3 layers combined must complete within `detection_timeout_ms` (default: 5000ms).
If the timeout is exceeded, the pipeline falls back to `{ synthesis_strategy: "tailwind" }`.

```
// Pseudocode — NOT implementation code
DETECTION_TIMEOUT_MS = talisman?.design_prototype?.detection_timeout_ms ?? 5000

startTime = now()

// ARCH-001: L1 + L3 can run in parallel (both read local files only)
// L2 requires Figma API response which is fetched separately
[frontendStack, builderMCP] = parallel(
  discoverFrontendStack(repoRoot),
  discoverUIBuilder(sessionCacheDir, repoRoot, null, null)  // Initial: no library yet
)

// Check timeout before L2
IF (now() - startTime) >= DETECTION_TIMEOUT_MS:
  RETURN { synthesis_strategy: "tailwind", rationale: "Detection timeout exceeded" }

// L2 runs sequentially (needs Figma API data)
IF mode === "url" AND figmaApiResponse is not null:
  figmaFramework = discoverFigmaFramework(figmaApiResponse, nodeId)

  // Re-run L3 with Figma framework for better matching
  IF figmaFramework.score >= 0.40:
    builderMCP = discoverUIBuilder(sessionCacheDir, repoRoot,
                                    frontendStack.detectedLibrary, figmaFramework)
ELSE:
  figmaFramework = null  // ARCH-005: text-only mode

// Final timeout check
IF (now() - startTime) >= DETECTION_TIMEOUT_MS:
  RETURN { synthesis_strategy: "tailwind", rationale: "Detection timeout exceeded" }

RETURN composeDesignContext(frontendStack, figmaFramework, builderMCP, mode)
```

### Parallelization Note (ARCH-001)

Layer 1 (`discoverFrontendStack`) and Layer 3 (`discoverUIBuilder`) both read local files
only (`package.json`, `.mcp.json`, skill frontmatter). They can run in parallel as Phase 0a.

Layer 2 (`discoverFigmaFramework`) requires the Figma API response, which is fetched via
`figma_list_components` MCP tool. This fetch can also run in parallel with L1+L3.

After all 3 complete, `composeDesignContext()` merges results sequentially (Phase 0b).

Optionally, L3 can be re-run after L2 completes to benefit from `figmaFramework` matching.

## Output Schema

```yaml
# DesignContext — merged output from all 3 detection layers
# Generated by: composeDesignContext() — do not edit manually
# Wrapper keys (stack, figma, builder) are used ONLY here, not in per-layer files (PAT-008)

design_context:
  # Layer 1: Project stack
  stack:
    framework: "react"              # react | nextjs | vuejs | nuxt | svelte | null
    framework_version: 18           # Major version (integer) or null
    build_tool: "vite"              # vite | next | webpack | null
    css_framework: "tailwind"       # tailwind | styled-components | emotion | null
    css_version: 4                  # Major version (integer) or null
    confidence: 0.95                # 0.0-1.0

  # Layer 2: Figma framework (null in text-only mode or when no Figma data)
  figma:
    detected: "untitled_ui"         # untitled_ui | shadcn_ui | material_ui | ant_design | null
    score: 0.82                     # 0.0-1.0 weighted match score
    match_summary: "15/18 components match UntitledUI patterns"
    alternatives:
      - framework: "shadcn_ui"
        score: 0.12

  # Layer 3: Builder MCP (null when no builder detected)
  builder:
    builder_mcp: "untitledui"       # MCP server name from .mcp.json
    detected_library: "untitled_ui" # Library matched
    capabilities:
      search: "search_components"
      list: "list_components"
      details: "get_component"
    matches_figma: true             # Does builder match Figma-detected framework?
    confidence: 0.90                # 0.50-0.95

  # Brand overrides (optional — from talisman brand section)
  brand:
    enabled: false                  # Whether brand config is populated
    colors:                         # Highest-priority token overrides
      primary: "#7F56D9"            # Overrides project_tokens in Layer 2
      secondary: "#6941C6"
    typography:                     # Brand typography for prototype generation
      heading_font: "Inter"
      body_font: "Inter"
      base_size: 16
      scale_ratio: 1.25

  # Synthesis decision
  synthesis_strategy: "library"     # "library" | "tailwind" | "hybrid"
  rationale: "UntitledUI detected in Figma (0.82), UntitledUI MCP available, React+Tailwind v4 project"
```

### Strategy Descriptions

| Strategy | When | Code Generation Approach |
|----------|------|--------------------------|
| `library` | All 3 layers aligned (framework + Figma + MCP) | Use library adapter to generate React components with correct props, imports, and icons |
| `hybrid` | Figma detected a framework but no matching MCP | Use Tailwind CSS but apply library naming conventions for component structure |
| `tailwind` | Default / no framework / non-React / low confidence | Raw Tailwind CSS from `figma-to-react` output (no library translation) |

## Detection Result Caching (BACK-008)

Caching avoids redundant API calls and file scans when analyzing multiple Figma URLs
in the same session. Each layer has different cache granularity.

### Cache Directory Structure

```
{sessionCacheDir}/
├── design-system-profile.yaml          # Layer 1: per-session (project-scoped)
├── builder-profile.yaml                # Layer 3: per-session (project-scoped)
├── figma-cache/                        # Layer 2: per-node (Figma-scoped)
│   ├── {nodeId-1}.yaml                 # Cached discoverFigmaFramework result
│   ├── {nodeId-2}.yaml                 # Cached discoverFigmaFramework result
│   └── ...
└── design-context-cache/               # Merged DesignContext: per-node
    ├── {nodeId-1}.yaml                 # Cached composeDesignContext result
    ├── {nodeId-2}.yaml                 # Cached composeDesignContext result
    └── ...
```

`sessionCacheDir` is the caller-provided session-scoped directory (e.g., `tmp/plans/{timestamp}`
or `tmp/arc/arc-{timestamp}`). All cache files are ephemeral — cleaned up when the session
directory is removed (by `/rune:rest` or session end).

### Cache Key Strategy

| Layer | Cache Key | Granularity | Rationale |
|-------|-----------|-------------|-----------|
| Layer 1 (Frontend Stack) | `{sessionCacheDir}/design-system-profile.yaml` | Per-session | Project files don't change within a session |
| Layer 2 (Figma Framework) | `{sessionCacheDir}/figma-cache/{nodeId}.yaml` | Per-node | Different Figma URLs have different components |
| Layer 3 (Builder MCP) | `{sessionCacheDir}/builder-profile.yaml` | Per-session | `.mcp.json` doesn't change within a session |
| Merged DesignContext | `{sessionCacheDir}/design-context-cache/{nodeId}.yaml` | Per-node | Includes Layer 2 per-node result |

**Why per-node, not per-URL**: A Figma URL resolves to a specific `nodeId`. Two different
URLs pointing to the same node should hit the same cache. The `nodeId` is the stable
identifier extracted from the URL by `parseUrl()`.

### Cache Algorithm

```
// Pseudocode — NOT implementation code
function getOrComputeDesignContext(sessionCacheDir, repoRoot, figmaApiResponse, nodeId, mode):

  // --- Check merged cache first ---
  cacheKey = nodeId ?? "text-only"
  contextCachePath = "{sessionCacheDir}/design-context-cache/{cacheKey}.yaml"
  IF file_exists(contextCachePath):
    cached = Read(contextCachePath)
    RETURN cached  // Full cache hit — zero tool calls

  // --- Layer 1: Per-session cache ---
  // discoverFrontendStack and discoverDesignSystem already cache via
  // {sessionCacheDir}/design-system-profile.yaml (see SKILL.md Phase 0)
  frontendStack = discoverFrontendStack(repoRoot, sessionCacheDir)  // Reads cache internally

  // --- Layer 2: Per-node cache (BACK-008) ---
  figmaFramework = null
  IF mode === "url" AND figmaApiResponse is not null AND nodeId is not null:
    figmaCachePath = "{sessionCacheDir}/figma-cache/{nodeId}.yaml"
    IF file_exists(figmaCachePath):
      figmaFramework = Read(figmaCachePath)  // Per-node cache hit
    ELSE:
      figmaFramework = discoverFigmaFramework(figmaApiResponse, nodeId)
      // Write per-node cache
      mkdir_p("{sessionCacheDir}/figma-cache/")
      Write(figmaCachePath, figmaFramework)

  // --- Layer 3: Per-session cache ---
  // discoverUIBuilder already caches via {sessionCacheDir}/builder-profile.yaml
  builderMCP = discoverUIBuilder(sessionCacheDir, repoRoot,
                                  frontendStack.detectedLibrary, figmaFramework)

  // --- Compose and cache merged result ---
  context = composeDesignContext(frontendStack, figmaFramework, builderMCP, mode)
  mkdir_p("{sessionCacheDir}/design-context-cache/")
  Write(contextCachePath, context)

  RETURN context
```

### Cache Invalidation

Detection caches are **never explicitly invalidated** within a session. Instead:

1. **Session-scoped cleanup**: The entire `{sessionCacheDir}` is deleted when the session ends
   (via `/rune:rest` or workflow completion). No dangling cache files.
2. **No cross-session persistence**: Cache lives in `tmp/` which is ephemeral. Each new session
   starts with a fresh cache directory.
3. **No file-watch invalidation**: `package.json` and `.mcp.json` changes during a session
   are not automatically detected. If a user modifies project deps mid-session, they must
   re-run the detection pipeline (or start a new session).

### Cache Performance Impact

| Scenario | Without Cache | With Cache |
|----------|---------------|------------|
| Single Figma URL | 4-6 tool calls | 4-6 tool calls (first run) |
| Same URL, second analysis | 4-6 tool calls | 0 tool calls (full cache hit) |
| Different URL, same session | 4-6 tool calls | 1-2 tool calls (L1+L3 cached, L2 new) |
| 5 Figma URLs, same session | 20-30 tool calls | 8-14 tool calls (~50% savings) |

### Configuration

```yaml
# talisman.yml
design_prototype:
  detection_timeout_ms: 5000         # Max time for all 3 layers (default: 5000)
  cache_enabled: true                # Enable detection caching (default: true)
```

When `cache_enabled: false`, all cache reads are skipped but cache writes still occur
(warm the cache for potential re-enable within the session).

## Cross-References

- [tiered-scanning.md](tiered-scanning.md) — `discoverFrontendStack()` algorithm (Layer 1)
- [figma-framework-detection.md](figma-framework-detection.md) — `discoverFigmaFramework()` algorithm (Layer 2)
- [ui-builder-discovery.md](ui-builder-discovery.md) — `discoverUIBuilder()` algorithm (Layer 3)
- [library-adapters.md](library-adapters.md) — Adapter definitions consumed by `library` strategy
- [semantic-ir.md](semantic-ir.md) — Intermediate representation between Figma output and adapters
