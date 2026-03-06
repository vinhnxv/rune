# discoverUIBuilder(sessionCacheDir, repoRoot)

**Input**: `sessionCacheDir` — caller-provided session-scoped temp directory (same as passed to `discoverDesignSystem`); `repoRoot` — repository root path
**Output**: `builder-profile.yaml` (written to `{sessionCacheDir}/`), builder config object returned to caller or null

Discovers which UI builder MCP is available for the detected design system.
Called after `discoverDesignSystem()` during devise Phase 0.5 and strive Phase 1.5.

## Algorithm

**Return type**: `{ name: string, library: string, capabilities: object, conventions: string|null }` on success, or `null` when no builder is found.

**Tiebreaker**: When two skills at the same priority step match the same library, the skill with the alphabetically first name (directory basename) wins. This ensures deterministic selection when multiple builder skills are installed.

**Priority cascade summary**:

| Step | Source | Confidence | Notes |
|------|--------|-----------|-------|
| 1 | Session cache | — | Short-circuit if already run this session |
| 2 | Talisman `integrations.mcp_tools[*].skill_binding` | 0.95 | Explicit binding wins |
| 3 | Project skill frontmatter (`.claude/skills/*/SKILL.md`) | 0.90 | Project overrides plugin |
| 4 | Plugin skill frontmatter (`plugins/*/skills/*/SKILL.md`) | 0.90 | Plugin fallback |
| 5 | Known MCP registry + heuristic (`.mcp.json`) | 0.50 | Last resort |

## Pre-flight (Session-Level Cache)

```
// A-2: Session-level caching — once written, short-circuit
IF {sessionCacheDir}/builder-profile.yaml EXISTS:
  RETURN cached builder profile  // Re-use within same session
```

## 5-Step Detection Algorithm

Detection proceeds in priority order. First match wins and short-circuits remaining steps.

```
// Step 1: Read design-system-profile.yaml to get detected library
profile = Read({sessionCacheDir}/design-system-profile.yaml)
IF profile does not exist OR profile.library is null:
  RETURN null  // discoverDesignSystem() must run first

detectedLibrary = profile.library  // e.g., "untitled_ui", "shadcn_ui"

// Step 2 (confidence: 0.95) — Explicit talisman binding
// Check talisman.yml → integrations.mcp_tools for skill_binding
talisman = readTalismanSection("misc")
FOR each ns IN talisman.integrations.mcp_tools:
  binding = talisman.integrations.mcp_tools[ns].skill_binding
  IF binding is not null:
    skillPath = resolveSkillPath(binding)  // plugin or project skill
    protocol = parseBuilderFrontmatter(skillPath)
    IF protocol AND protocol.library === detectedLibrary:
      RETURN buildBuilderProfile(binding, ns, protocol, "talisman", 0.95)

// Step 3 (confidence: 0.90) — Project skill with builder-protocol frontmatter
// Priority: project > plugin skills
// Tiebreaker: sort by skill name alphabetically, pick first match
FOR each skillDir IN Glob(".claude/skills/*/SKILL.md") SORTED by basename ASC:
  protocol = parseBuilderFrontmatter(skillDir)
  IF protocol AND protocol.library === detectedLibrary:
    RETURN buildBuilderProfile(skillDir, protocol.mcp_server, protocol, "skill_frontmatter", 0.90)

// Step 4 (confidence: 0.90) — Plugin skill with builder-protocol frontmatter
// Tiebreaker: sort by skill name alphabetically, pick first match
FOR each skillDir IN Glob("plugins/*/skills/*/SKILL.md") SORTED by basename ASC:
  protocol = parseBuilderFrontmatter(skillDir)
  IF protocol AND protocol.library === detectedLibrary:
    RETURN buildBuilderProfile(skillDir, protocol.mcp_server, protocol, "skill_frontmatter", 0.90)

// Step 5 (confidence: 0.50) — MCP server heuristic detection
// Only if ≥2 of 4 capability patterns match (S-3)
mcpConfig = Read(".mcp.json")
IF mcpConfig EXISTS:
  result = checkKnownMCPRegistry(mcpConfig, detectedLibrary)
  IF result:
    RETURN buildBuilderProfile(null, result.server_name, result.capabilities, "mcp_heuristic", 0.50)
  heuristic = detectHeuristicBuilder(mcpConfig, detectedLibrary)
  IF heuristic:
    RETURN buildBuilderProfile(null, heuristic.server_name, heuristic.capabilities, "mcp_heuristic", 0.50)

RETURN null  // No builder found — pipeline proceeds unchanged
```

## builder-protocol Frontmatter Fields

The `builder-protocol` YAML block in a skill's frontmatter uses the following fields:

| Field | Required | Description |
|-------|----------|-------------|
| `library` | Yes | Design library this builder targets (e.g., `untitled_ui`, `shadcn_ui`) |
| `mcp_server` | Yes | MCP server name as it appears in `.mcp.json` |
| `capabilities` | No | Map of capability names to MCP tool names |
| `conventions` | No | Relative path to conventions doc (no `..`, `/`, or `~`) |
| `min_version` | No | Minimum required semver for the MCP server (e.g., `"1.2.0"`). Version mismatch emits a warning but does NOT block detection. Omit to skip version checks. |

## parseBuilderFrontmatter(skillPath)

Reads the first 50 lines of a SKILL.md file and extracts the `builder-protocol` YAML block.

```
// Read first 50 lines only (frontmatter scanning — avoids loading full skill content)
lines = Read(skillPath, limit=50)
IF lines does not start with "---":
  RETURN null

// Extract YAML between the two --- delimiters
frontmatterLines = lines between first "---" and second "---"
parsedYaml = parseYAML(frontmatterLines)

IF parsedYaml["builder-protocol"] does not exist:
  RETURN null

protocol = parsedYaml["builder-protocol"]

// Validate required fields
IF protocol.library is null OR protocol.mcp_server is null:
  RETURN null

// SEC-UI-BUILDER-005: Optional version pinning — warn on mismatch, do NOT block
// min_version field: semver string e.g. "1.2.0" (optional; omit to skip version check)
IF protocol.min_version is not null:
  detectedVersion = resolveInstalledVersion(protocol.mcp_server)  // null if unknown
  IF detectedVersion is not null AND semverLessThan(detectedVersion, protocol.min_version):
    WARN "Builder version mismatch: detected " + detectedVersion +
         " < required " + protocol.min_version + " for " + protocol.mcp_server +
         ". Detection proceeds — capabilities may differ."
    // Do NOT return null — version mismatch is advisory only, not a hard block

// S-2: Validate conventions path — reject traversal and absolute paths
IF protocol.conventions is not null:
  IF protocol.conventions contains ".." OR
     protocol.conventions starts with "/" OR
     protocol.conventions starts with "~":
    WARN "Invalid conventions path rejected: " + protocol.conventions
    protocol.conventions = null

RETURN protocol
```

## Known MCP Server Registry

Maps well-known MCP server names to their builder capabilities and library associations.
Used in Step 5 of the detection algorithm.

```
KNOWN_MCP_REGISTRY = {
  "untitledui": {
    library: "untitled_ui",
    capabilities: {
      search: "search_components",
      list: "list_components",
      details: "get_component",
      bundle: "get_component_bundle",
      templates: "get_page_templates",
      template_files: "get_page_template_files"
    },
    built_in_skill: "untitledui-mcp"
  },
  "shadcn": {
    library: "shadcn_ui",
    capabilities: { search: "search", details: "get", bundle: "add" }
  },
  "21st-dev": {
    library: "shadcn_ui",
    capabilities: { search: "search", details: "get" }
  },
  "magic-mcp": {
    library: "shadcn_ui",
    capabilities: { search: "search", details: "get" }
  },
  "chakra": {
    library: "chakra_ui",
    capabilities: { search: "search_components", details: "get_component" }
  },
  "radix": {
    library: "custom_design_system",
    capabilities: { search: "search", details: "get" }
  },
  "mui": {
    library: "material_ui",
    capabilities: { search: "search_components", details: "get_component" }
  },
  "material-ui": {
    library: "material_ui",
    capabilities: { search: "search_components", details: "get_component" }
  }
}

function checkKnownMCPRegistry(mcpConfig, detectedLibrary):
  FOR each serverName IN mcpConfig.mcpServers:
    entry = KNOWN_MCP_REGISTRY[serverName]
    IF entry AND entry.library === detectedLibrary:
      RETURN { server_name: serverName, capabilities: entry.capabilities, built_in_skill: entry.built_in_skill }
  RETURN null
```

## Heuristic Builder Detection

Used for unknown MCP servers not in the registry (Step 5 fallback).
**S-3**: Confidence threshold — requires ≥2 of 4 heuristic patterns to match.

```
// Heuristic tool name patterns (4 patterns)
HEURISTIC_PATTERNS = [
  // Pattern 1 — Search capability: tools for finding/browsing components
  { pattern: /search|find|browse|list/, capability: "search" },
  // Pattern 2 — Details capability: tools for fetching component source
  { pattern: /get_component|install|add/, capability: "details" },
  // Pattern 3 — Bundle capability: tools for multi-component operations
  { pattern: /bundle|batch|multi/, capability: "bundle" },
  // Pattern 4 — Templates capability: tools for page-level scaffolding
  { pattern: /template|page|layout|scaffold/, capability: "templates" }
]

function detectHeuristicBuilder(mcpConfig, detectedLibrary):
  FOR each serverName IN mcpConfig.mcpServers:
    IF serverName IN KNOWN_MCP_REGISTRY:
      CONTINUE  // Already handled by checkKnownMCPRegistry

    serverTools = mcpConfig.mcpServers[serverName].tools OR []
    matchedCapabilities = {}
    matchCount = 0

    FOR each tool IN serverTools:
      FOR each heuristic IN HEURISTIC_PATTERNS:
        IF heuristic.pattern matches tool.name AND
           heuristic.capability not in matchedCapabilities:
          matchedCapabilities[heuristic.capability] = tool.name
          matchCount++

    // S-3: Require ≥2 of 4 patterns matched before accepting as a builder
    IF matchCount >= 2:
      RETURN {
        server_name: serverName,
        capabilities: matchedCapabilities
      }

  RETURN null
```

## Output Schema: builder-profile.yaml

```yaml
# Written to: tmp/plans/{timestamp}/builder-profile.yaml
# Generated by: discoverUIBuilder() — do not edit manually

builder_skill: untitledui-mcp         # Resolved skill name (null if none)
builder_mcp: untitledui               # MCP server name in .mcp.json
capabilities:
  search: search_components           # Tool name for searching components
  list: list_components               # Tool name for browsing by category
  details: get_component              # Tool name for fetching component source
  bundle: get_component_bundle        # Tool name for batch install
  templates: get_page_templates       # Tool name for page templates (optional)
  template_files: get_page_template_files  # Tool name for template install (optional)
conventions: references/agent-conventions.md  # Relative to skill dir (validated: no .., no /, no ~)
detection_source: skill_frontmatter   # talisman | skill_frontmatter | mcp_heuristic
confidence: 0.95                      # 0.95 (talisman) | 0.90 (frontmatter) | 0.50 (heuristic)
detected_library: untitled_ui         # Echo of design-system-profile.yaml library field
```

**Null return** (no builder found):
```yaml
# builder-profile.yaml is NOT written when no builder is detected
# discoverUIBuilder() returns null — pipeline proceeds unchanged
```
