# Registry-Aware Implementation — Decision Flow and shadcn Registry Protocol

Before implementing any component from a Figma design, check whether it already exists in the project's component registry or an external registry. This avoids duplicate implementations and leverages tested, maintained components.

## Decision Hierarchy

**REUSE > INSTALL > EXTEND > CREATE** — always prefer higher-priority decisions.

| Priority | Decision | Meaning |
|----------|----------|---------|
| 1 | **REUSE** | Import an existing project component as-is |
| 2 | **INSTALL** | Install from an external registry (e.g., `npx shadcn add`) |
| 3 | **EXTEND** | Add a variant or wrapper to an existing component |
| 4 | **CREATE** | Build from scratch, optionally using a primitive base |

## Decision Flow

```
Figma component "{ComponentName}" detected
  |
  +-- CHECK 1: Project component registry (component-registry.json)
  |     |
  |     +-- Found: matching name + matching variants --> REUSE (import existing)
  |     +-- Found: matching name, missing variant   --> EXTEND (add variant)
  |     +-- Not found                               --> CHECK 2
  |
  +-- CHECK 2: External registry (shadcn only -- machine-consumable JSON API)
  |     |
  |     +-- shadcn project detected?
  |     |     +-- YES: fetch registry JSON for component
  |     |     |     +-- Component exists --> INSTALL (npx shadcn add {name})
  |     |     |     +-- Not in registry  --> CHECK 3
  |     |     +-- NO: skip to CHECK 3
  |
  +-- CHECK 3: Base primitive exists?
  |     |
  |     +-- Radix has matching primitive   --> CREATE with Radix base
  |     +-- React Aria has matching        --> CREATE with React Aria Components base
  |     +-- No primitive available         --> CREATE from scratch
  |
  +-- DECISION: highest-priority match wins (REUSE > INSTALL > EXTEND > CREATE)
```

## CHECK 1: Project Component Registry

The project's `component-registry.json` is the first lookup target. This file is generated during the design extraction phase (see [component-registry-spec.md](component-registry-spec.md)).

**Lookup algorithm:**

```
function checkProjectRegistry(componentName, requiredVariants):
  registry = readFile("component-registry.json")
  if registry is null:
    return { decision: null }  // No registry -- skip to CHECK 2

  // Exact name match
  match = registry.components.find(c => c.name === componentName)
  if match is null:
    // Fuzzy match: normalize casing and common prefixes
    normalized = componentName.toLowerCase().replace(/^(ui-|base-)/, "")
    match = registry.components.find(c =>
      c.name.toLowerCase().replace(/^(ui-|base-)/, "") === normalized
    )

  if match is null:
    return { decision: null }

  // Check variant coverage
  existingVariants = match.variants ?? []
  missingVariants = requiredVariants.filter(v => !existingVariants.includes(v))

  if missingVariants.length === 0:
    return { decision: "REUSE", path: match.path, component: match.name }
  else:
    return { decision: "EXTEND", path: match.path, component: match.name, missingVariants }
```

**Output format:**

```json
{
  "check": 1,
  "source": "project-registry",
  "decision": "REUSE",
  "component": "Button",
  "path": "src/components/ui/button.tsx",
  "confidence": "high",
  "reason": "Existing component matches all required variants (primary, secondary, ghost)"
}
```

## CHECK 2: External Registry (shadcn)

Only runs when CHECK 1 returns no match AND the project uses shadcn (detected via `design-system-profile.yaml` or `components.json`).

### shadcn Registry Protocol

shadcn provides a machine-consumable JSON registry at `https://ui.shadcn.com/r/`. This enables automated component discovery without scraping documentation.

**Registry URL pattern:**

```
https://ui.shadcn.com/r/styles/{style}/{component-name}.json
```

Where `{style}` is typically `new-york-v4` (default for shadcn v2+). The style is read from the project's `components.json` if present.

**Fetch with timeout and graceful degradation:**

```
function checkShadcnRegistry(componentName, style):
  // CRITICAL: Network call -- use 5s timeout + try/catch degrade
  // Per architect: agent loops must not hang on network failures
  url = "https://ui.shadcn.com/r/styles/{style}/{componentName}.json"

  try:
    response = fetchWithTimeout(url, { timeout: 5000 })
    if response.status === 404:
      return { decision: null, reason: "Component not in shadcn registry" }
    registryData = response.json()
  catch (error):
    // Network timeout or failure -- degrade gracefully
    // Log warning but do NOT block the implementation pipeline
    warn("shadcn registry check failed: {error.message}. Falling back to CHECK 3.")
    return { decision: null, reason: "Registry unavailable", degraded: true }

  // Verify dependencies
  deps = registryData.registryDependencies ?? []
  installedComponents = readProjectInstalledComponents()
  missingDeps = deps.filter(d => !installedComponents.includes(d))

  return {
    decision: "INSTALL",
    command: "npx shadcn add {componentName}",
    registryDependencies: deps,
    missingDependencies: missingDeps,
    installSequence: missingDeps.length > 0
      ? missingDeps.map(d => "npx shadcn add {d}").concat(["npx shadcn add {componentName}"])
      : ["npx shadcn add {componentName}"]
  }
```

**Registry JSON response structure** (shadcn v2):

```json
{
  "name": "button",
  "type": "registry:ui",
  "registryDependencies": ["badge"],
  "dependencies": ["@radix-ui/react-slot"],
  "files": [
    {
      "path": "ui/button.tsx",
      "content": "...",
      "type": "registry:ui"
    }
  ],
  "tailwind": {
    "config": {}
  },
  "cssVars": {}
}
```

**Key fields:**

| Field | Purpose |
|-------|---------|
| `registryDependencies` | Other shadcn components this one depends on |
| `dependencies` | npm packages required |
| `files` | Generated file paths and content |
| `tailwind.config` | Tailwind config extensions needed |
| `cssVars` | CSS variables to add to globals.css |

### shadcn MCP Search Integration

When the project has shadcn MCP tools available, prefer the MCP search over direct HTTP:

```
function checkShadcnViaMcp(componentName):
  // Use MCP search tool for fuzzy matching
  results = mcp_shadcn_search(query: componentName)
  if results.length === 0:
    return { decision: null }

  bestMatch = results[0]
  if nameSimilarity(bestMatch.name, componentName) < 0.8:
    return { decision: null, reason: "No close match (best: {bestMatch.name})" }

  // Fetch full registry data for the match
  return checkShadcnRegistry(bestMatch.name, style)
```

### Dependency Resolution

When a shadcn component has `registryDependencies`, install them in dependency order:

```
Example: "accordion" depends on "collapsible"

Install sequence:
  1. npx shadcn add collapsible   (dependency first)
  2. npx shadcn add accordion     (target component)

If "collapsible" is already installed:
  1. npx shadcn add accordion     (skip installed deps)
```

**Output format:**

```json
{
  "check": 2,
  "source": "shadcn-registry",
  "decision": "INSTALL",
  "component": "button",
  "command": "npx shadcn add button",
  "registryDependencies": [],
  "missingDependencies": [],
  "installSequence": ["npx shadcn add button"],
  "confidence": "high"
}
```

## CHECK 3: Base Primitive Lookup

When no existing or installable component matches, check if a headless primitive exists to build on.

**Primitive library priority** (based on detected design system):

| Design System | Primary Primitive | Fallback |
|---------------|-------------------|----------|
| shadcn | Radix UI | React Aria |
| UntitledUI | React Aria Components | Radix UI |
| Generic | Radix UI | React Aria |

**Common primitive mappings:**

| Component | Radix Primitive | React Aria Primitive |
|-----------|----------------|---------------------|
| Button | N/A (use native) | `Button` |
| Dialog | `Dialog` | `Modal`, `Dialog` |
| Dropdown | `DropdownMenu` | `Menu` |
| Select | `Select` | `Select` |
| Tabs | `Tabs` | `Tabs` |
| Tooltip | `Tooltip` | `Tooltip` |
| Popover | `Popover` | `Popover` |
| Checkbox | `Checkbox` | `Checkbox` |
| Switch | `Switch` | `Switch` |
| Slider | `Slider` | `Slider` |
| Accordion | `Accordion` | `Disclosure` |

**Output format:**

```json
{
  "check": 3,
  "source": "primitive-lookup",
  "decision": "CREATE",
  "base": "radix",
  "primitive": "Dialog",
  "package": "@radix-ui/react-dialog",
  "confidence": "medium",
  "reason": "No existing component or registry match. Radix Dialog provides accessible foundation."
}
```

## Decision Summary Format

After all checks complete, emit a decision summary:

```json
{
  "component": "AlertDialog",
  "figmaNodeId": "1234:5678",
  "checks": [
    { "check": 1, "source": "project-registry", "result": "no-match" },
    { "check": 2, "source": "shadcn-registry", "result": "found", "command": "npx shadcn add alert-dialog" },
    { "check": 3, "source": "primitive-lookup", "result": "skipped" }
  ],
  "decision": "INSTALL",
  "action": "npx shadcn add alert-dialog",
  "confidence": "high"
}
```

**Rules:**
- Stop at the first successful decision (highest priority wins)
- CHECK 3 is skipped if CHECK 2 succeeds
- If all checks fail, decision is `CREATE` from scratch (no base)
- Network failures in CHECK 2 degrade to CHECK 3 (never block the pipeline)

## Error Handling and Timeouts

| Operation | Timeout | On Failure |
|-----------|---------|------------|
| Read `component-registry.json` | N/A (local file) | Skip to CHECK 2 |
| Fetch shadcn registry JSON | 5 seconds | Log warning, skip to CHECK 3 |
| shadcn MCP search | 5 seconds | Fall back to HTTP fetch |
| Read `components.json` (shadcn config) | N/A (local file) | Assume default style |

**Graceful degradation principle**: Network-dependent checks must NEVER block the implementation pipeline. A 5-second timeout ensures the agent loop remains responsive. On timeout, log a warning and fall through to the next check.

## Integration Points

This decision flow integrates into the design-sync pipeline at Step 3 (Implementation):

```
Phase 2: Implementation
  Step 1: Read VSM (visual-spec-manifest.json)
  Step 2: Load codegen profile (framework-codegen-profiles.md)
  Step 3: For each component in VSM:
    --> Run registry decision flow (this document)
    --> Based on decision:
        REUSE:   Import existing, apply design tokens only
        INSTALL: Run install command, then customize
        EXTEND:  Modify existing component, add variant
        CREATE:  Generate from codegen profile template
  Step 4: Apply semantic tokens from token resolver
```

## Cross-References

- [component-reuse-strategy.md](component-reuse-strategy.md) — General REUSE > EXTEND > CREATE philosophy
- [component-registry-spec.md](component-registry-spec.md) — JSON schema for `component-registry.json`
- [design-system-rules.md](design-system-rules.md) — Design system constraints
- [variant-mapping.md](variant-mapping.md) — Figma variant to code prop mapping
