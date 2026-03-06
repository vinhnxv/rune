# UI/UX Planning Protocol

Structured protocol for frontend planning during Phase 0 of `/rune:devise`. Activated when the feature involves UI components, design systems, or Figma assets. Runs automatically when `design_sync_candidate = true` or when the feature description contains design-related keywords.

The protocol runs in 8 steps (0-7). Step 0 routes to greenfield/brownfield UX methodology when `ux.enabled` is true in talisman (opt-in, backward compatible). Steps 1-2 are automatic (no user interaction). Steps 3-7 are semi-automatic or guided. Each step feeds its output into the plan synthesis (Phase 2) and the strive worker context (Phase 4).

## Step 0: UX Process Selection (automatic)

When `ux.enabled === true` in talisman, determine the UX methodology before running Steps 1-7. Routes to greenfield or brownfield UX process based on project context. This step is additive — it enriches the existing protocol without replacing it.

```javascript
// readTalismanSection: "ux"
const uxConfig = readTalismanSection("ux")
const uxEnabled = uxConfig?.enabled === true

if (uxEnabled) {
  // Detect project context for UX methodology routing
  const hasComponents = Glob("src/components/**/*.{tsx,jsx}").length > 0
    || Glob("components/**/*.{tsx,jsx}").length > 0
  const hasExistingUI = hasComponents || Glob("app/**/*.{tsx,jsx}").length > 10

  const uxProcess = hasExistingUI ? "brownfield" : "greenfield"

  // Load UX process reference
  // Greenfield: new project — focus on information architecture, user research, wireframes
  // Brownfield: existing codebase — focus on heuristic audit, pattern consistency, incremental improvement
  const uxProcessRef = uxProcess === "greenfield"
    ? Read("skills/ux-design-process/references/greenfield-process.md")
    : Read("skills/ux-design-process/references/brownfield-process.md")

  brainstormContext.ux_process = {
    type: uxProcess,
    enabled: true,
    cognitive_walkthrough: uxConfig.cognitive_walkthrough === true,
    blocking: uxConfig.blocking === true,
    reference_loaded: uxProcessRef !== null,
  }

  // Load heuristic checklist for both processes
  const heuristicChecklist = Read("skills/ux-design-process/references/heuristic-checklist.md")
  brainstormContext.ux_heuristics_loaded = heuristicChecklist !== null
} else {
  brainstormContext.ux_process = { type: null, enabled: false }
}
```

**Output**: `brainstormContext.ux_process` — gates UX-specific enrichment in Steps 3-7. When `ux.enabled` is false, Steps 1-7 run unchanged (backward compatible).

## Step 1: Design System Audit (automatic)

Discover the project's design system before any component decisions are made.

```javascript
// Run discoverDesignSystem() — see skills/design-system-discovery/SKILL.md
const designSystem = discoverDesignSystem()
// Returns: { library, confidence, tokens, variants, components, accessibility, ... }
// library: "shadcn_ui" | "untitled_ui" | "custom_design_system" | "unknown"

// Map library identifier to profile key
// discoverDesignSystem() returns snake_case IDs (e.g., "shadcn_ui", "untitled_ui").
// These are mapped to profile key names below — mixed formats (kebab, bare-word, generic) are intentional:
// snake_case input → kebab/bare-word output reflects each design system's conventional naming.
const LIBRARY_TO_PROFILE_KEY = {
  shadcn_ui:            "shadcn",
  untitled_ui:          "untitled-ui",
  custom_design_system: "generic",
  unknown:              "unknown",
}

// Load the matching profile
// NOTE: Profile files below are scaffolded for future implementation.
// shadcn-profile.md, untitled-ui-profile.md, and generic-profile.md do not yet exist on disk.
// The null fallback in the catch block is intentional: profile loading is best-effort.
// When profiles are absent, downstream logic proceeds without them (fail-open design).
let systemProfile = null
const PROFILE_MAP = {
  shadcn:      "skills/frontend-design-patterns/references/profiles/shadcn-profile.md",
  "untitled-ui": "skills/frontend-design-patterns/references/profiles/untitled-ui-profile.md",
  generic:     "skills/frontend-design-patterns/references/profiles/generic-profile.md",
  unknown:     "skills/frontend-design-patterns/references/profiles/generic-profile.md",
}
// custom_design_system (weight 0.6 in discoverDesignSystem) falls back to the generic profile.
// Only shadcn/ui and untitled-ui have distinct profiles (confidence weight >= 0.85).
// All other libraries (custom_design_system, unknown) map to generic.

const profileKey = LIBRARY_TO_PROFILE_KEY[designSystem?.library ?? "unknown"] ?? "unknown"
const profilePath = PROFILE_MAP[profileKey]
try {
  systemProfile = Read(profilePath)
} catch (e) {
  systemProfile = null  // Fail-open: proceed without profile (profile files are not yet implemented)
}

// Record audit result in brainstorm context
brainstormContext.design_system = {
  type: profileKey,
  name: designSystem?.library ?? null,
  profile_loaded: systemProfile !== null,
  component_paths: designSystem?.components?.existing ?? [],
}

// Discover UI builder MCP — zero-cost when absent
// See skills/design-system-discovery/SKILL.md → discoverUIBuilder()
const uiBuilder = discoverUIBuilder(sessionCacheDir, repoRoot)
// Returns: { builder_skill, builder_mcp, capabilities, conventions, detection_source, confidence }
// OR null when no builder is detected (pipeline proceeds unchanged)

if (uiBuilder !== null) {
  // Record builder in brainstorm context for downstream phases
  brainstormContext.ui_builder = {
    builder_skill: uiBuilder.builder_skill,    // e.g., "untitledui-mcp"
    builder_mcp: uiBuilder.builder_mcp,        // e.g., "untitledui"
    capabilities: uiBuilder.capabilities,       // { search, list, details, bundle, templates }
    conventions: uiBuilder.conventions,         // Relative path or null
    detection_source: uiBuilder.detection_source,
    confidence: uiBuilder.confidence,
  }
}
// When uiBuilder is null, brainstormContext.ui_builder is not set — no injection, no overhead
```

**Output**: `brainstormContext.design_system` — used in Steps 2–7 and injected into strive worker prompts.
`brainstormContext.ui_builder` — set when a UI builder MCP is detected; used in Phase 2 synthesis and strive worker injection.

## Step 2: Component Inventory (automatic)

Scan existing components and classify them by atomic design tier before making any new component decisions.

```javascript
const componentPaths = designSystem?.componentPaths ?? []

// Discover all existing component files
const discoveredComponents = []
const searchPaths = [
  "src/components/ui/",
  "src/components/base/",
  "src/design-system/components/",
  "src/components/",
  "components/",
]

for (const basePath of searchPaths) {
  const files = Glob(`${basePath}**/*.tsx`) || Glob(`${basePath}**/*.jsx`) || []
  discoveredComponents.push(...files)
}

// Classify each component by atomic design tier
// Classification heuristic: based on file path, name, and line count
const inventory = {
  atoms: [],      // Button, Input, Badge, Icon, Avatar — pure primitives
  molecules: [],  // SearchBar, FormField, CardHeader — simple compositions
  organisms: [],  // NavigationBar, DataTable, UserProfile — complex UI
  pages: [],      // DashboardPage, SettingsPage — full page compositions
  unknown: [],    // Unclassified
}

for (const filePath of discoveredComponents) {
  const name = filePath.split("/").pop()?.replace(/\.(tsx|jsx)$/, "") ?? ""
  const tier = classifyComponentTier(name, filePath)
  inventory[tier].push({ name, path: filePath })
}

// classifyComponentTier heuristic:
// - "atoms" if: name matches [Button,Input,Badge,Avatar,Icon,Spinner,Checkbox,Radio,Label,Tooltip]
//   OR file is in ui/ or base/ and < 80 lines
// - "pages" if: name ends in "Page" or "Layout", OR file is in pages/ or app/ directory
// - "organisms" if: name contains [Nav,Sidebar,Header,Footer,Table,Form,Dashboard,Profile,Card]
//   AND > 150 lines
// - "molecules" if: name is a recognizable composition (2+ nouns, or ends in Bar/Field/Panel/Row)
// - "unknown" default for components that don't match any of the above heuristics

brainstormContext.component_inventory = inventory
```

**Output**: Component inventory table injected into plan. Used by Step 3 to determine REUSE/EXTEND/CREATE strategies.

## Step 3: Component Decomposition (semi-automatic)

6-step algorithm to decompose the feature into concrete component requirements and assign a strategy to each.

### The 6-Step Algorithm

**EXTRACT → CLASSIFY → DETERMINE → BUILD → GENERATE → IDENTIFY**

```javascript
// EXTRACT: Parse UI nouns from the feature description and Figma frames (if available)
// UI nouns are visual entities: Button, Modal, Card, Table, Form, Input, Dropdown, etc.
const UI_NOUN_PATTERN = /\b(button|modal|dialog|card|table|list|form|input|field|dropdown|menu|nav|sidebar|header|footer|badge|chip|tag|avatar|icon|tooltip|toast|banner|alert|panel|section|grid|layout|page|screen|view|tab|accordion|drawer|sheet|popover|checkbox|radio|select|date.?picker|calendar|chart|graph|progress|spinner|skeleton|empty.?state|error.?state|loading.?state)\b/gi

const featureText = featureDescription + " " + (brainstormContext.design_assets ?? "")
const rawNouns = [...new Set([...featureText.matchAll(UI_NOUN_PATTERN)].map(m => m[0].toLowerCase()))]

// CLASSIFY: Assign each UI noun to an atomic design tier
// Using the same heuristic as Step 2 classifyComponentTier()
const classifiedComponents = rawNouns.map(noun => ({
  name: noun,
  tier: classifyComponentTier(noun, "")
}))

// DETERMINE: Assign a strategy to each component
// Strategy options: REUSE | EXTEND | CREATE | COMPOSE
// Evaluation order matters — check REUSE before CREATE
const componentPlans = []
for (const { name, tier } of classifiedComponents) {
  const strategy = determineStrategy(name, tier, inventory, systemProfile)
  componentPlans.push({ name, tier, strategy, details: null })
}

// COMPOSE: A 4th strategy alongside REUSE/EXTEND/CREATE
// COMPOSE = wrapping existing primitives in a new container without modifying source
// Example: <SearchBar> = COMPOSE(<Input> + <Button> + <Dropdown>)
// Use COMPOSE when: 2+ existing atoms/molecules combine into a new molecule/organism
// that doesn't exist yet — but each primitive is already available as-is.
//
// Strategy selection rules:
// REUSE:   Component exists in inventory with matching visual/behavior output
// EXTEND:  Component exists but needs a new variant, slot, or wrapper
// COMPOSE: 2+ existing components can be assembled into the new component
// CREATE:  No existing component covers the need (last resort)
```

### Strategy Determination (determineStrategy)

```javascript
function determineStrategy(name, tier, inventory, systemProfile) {
  // 1. REUSE: exact match in inventory
  const exactMatch = inventory[tier]?.find(c =>
    c.name.toLowerCase() === name.toLowerCase() ||
    c.name.toLowerCase().includes(name.toLowerCase())
  )
  if (exactMatch) return { strategy: "REUSE", source: exactMatch.path }

  // 2. REUSE via design system profile: component exists in the system library
  if (systemProfile && systemProfile.includes(name)) {
    return { strategy: "REUSE", source: "design-system-library" }
  }

  // 3. COMPOSE: 2+ atoms/molecules in inventory can assemble this
  const composePrimitives = findComposePrimitives(name, inventory)
  if (composePrimitives.length >= 2) {
    return { strategy: "COMPOSE", primitives: composePrimitives }
  }

  // 4. EXTEND: partial match — 70%+ overlap component exists
  const partialMatch = findPartialMatch(name, inventory)
  if (partialMatch) return { strategy: "EXTEND", source: partialMatch.path }

  // 5. CREATE: no suitable existing component
  return { strategy: "CREATE", tier }
}
```

**BUILD**: Construct the component hierarchy from the classified + stratified list.

```
// Example output for "User Dashboard" feature:
// REUSE:   Button (src/components/ui/button.tsx)
// REUSE:   Input (src/components/ui/input.tsx)
// COMPOSE: SearchBar = Input + Button + Dropdown
// EXTEND:  Card (add "stats" variant to src/components/ui/card.tsx)
// CREATE:  MetricWidget (new atom — no existing match)
// COMPOSE: DashboardHeader = Avatar + Text + Button (existing primitives)
```

**GENERATE**: For each CREATE component, generate a minimal spec:

```javascript
// Only generate specs for CREATE strategy components
const createComponents = componentPlans.filter(c => c.strategy.strategy === "CREATE")
for (const component of createComponents) {
  component.details = {
    name: toPascalCase(component.name),
    tier: component.tier,
    props: inferMinimalProps(component.name),  // heuristic from name + feature context
    tokens: ["use design system tokens — no arbitrary values"],
    accessibility: inferA11yRequirements(component.name),
    location: inferFilePath(component.name, component.tier, designSystem),
  }
}
```

**IDENTIFY**: For each EXTEND component, identify the exact customization needed:

```javascript
const extendComponents = componentPlans.filter(c => c.strategy.strategy === "EXTEND")
for (const component of extendComponents) {
  component.details = {
    source: component.strategy.source,
    customization: inferExtensionType(component.name),
    // Extension types: "new-variant" | "new-slot" | "wrapper" | "css-override"
  }
}
```

**Output**: `brainstormContext.component_decomposition` — injected into plan Technical Approach and strive worker prompts.

## Step 4: User Flow Mapping (guided)

Map the user journey through the feature to identify all pages, routes, and state transitions.

```javascript
AskUserQuestion({
  questions: [{
    question: "What are the main user flows in this feature?",
    header: "User Flows",
    options: [
      { label: "Single-page (no navigation)", description: "All interactions on one route" },
      { label: "Multi-page flow", description: "User navigates across multiple routes" },
      { label: "Modal/overlay flow", description: "Primary route + modal overlays" },
      { label: "Wizard/stepper flow", description: "Sequential steps in a guided process" }
    ],
    multiSelect: false
  }]
})
```

Document the flow for each key path:

```
// Flow mapping format
userFlows = [
  {
    name: "{flow name}",
    trigger: "{entry point — link, button, URL}",
    steps: [
      { step: 1, route: "/path", component: "{PageComponent}", action: "{user action}" },
      { step: 2, route: "/path/next", component: "{NextComponent}", action: "{user action}" },
    ],
    loading_state: "{how loading appears during async}",
    error_state: "{error boundary or inline error}",
    empty_state: "{empty list / no data placeholder}",
    success_state: "{confirmation or redirect after completion}",
  }
]
```

**Loading/error/empty states**: For every async data-dependent view, define all three states explicitly. Empty state is the most commonly forgotten — include it.

## Step 5: Responsive Strategy (guided)

Define the responsive behavior for each component. Capture per-component breakpoint strategy, not just global layout rules.

```javascript
AskUserQuestion({
  questions: [{
    question: "What responsive breakpoints does this feature need?",
    header: "Responsive Strategy",
    options: [
      { label: "Mobile-first standard (sm/md/lg/xl)", description: "Tailwind default breakpoints — 640/768/1024/1280px" },
      { label: "Custom breakpoints", description: "Project-specific breakpoints from design system" },
      { label: "Desktop-only", description: "No mobile requirement — internal tool or admin interface" },
      { label: "Mobile-only", description: "PWA or mobile-first app with no desktop layout" }
    ],
    multiSelect: false
  }]
})
```

Per-component responsive spec format:

```
// Example responsive strategy table (include in plan Technical Approach)
| Component | Mobile (<640px) | Tablet (640–1024px) | Desktop (>1024px) |
|-----------|----------------|---------------------|-------------------|
| NavigationBar | Hamburger menu + drawer | Tab bar | Full horizontal nav |
| DataTable | Horizontal scroll + column hide | 5 columns visible | All columns + sort |
| DashboardGrid | Single column stack | 2-column grid | 3-column grid |
| MetricWidget | Full width | Half width | Fixed 280px |
```

**Rules**:
- Define mobile layout first — it constrains all other decisions
- Never hide core functionality on mobile (only secondary actions)
- Touch targets: minimum 44×44px on mobile

## Step 6: State Management Strategy (guided)

Define data flow, mutations, and cache strategy before implementation begins.

```javascript
AskUserQuestion({
  questions: [{
    question: "Where does the data for this feature come from?",
    header: "State Management",
    options: [
      { label: "Server state only (React Query/SWR)", description: "Fetch from API, cache on client" },
      { label: "Local UI state + server data", description: "Form state + API data + React Query" },
      { label: "Global client state (Redux/Zustand)", description: "Shared state across distant components" },
      { label: "URL state (query params)", description: "Filter/pagination state in URL for shareability" },
      { label: "Mixed strategy", description: "Combination of the above" }
    ],
    multiSelect: false
  }]
})
```

State management spec format:

```
// State strategy (capture in plan Technical Approach)
stateStrategy = {
  data_sources: [
    { name: "{resource}", type: "server", fetcher: "{API endpoint}" },
    { name: "{resource}", type: "local", scope: "component | page | global" },
  ],
  mutations: [
    {
      action: "{what the user does}",
      endpoint: "{API endpoint}",
      optimistic_update: true | false,
      cache_invalidation: "{which cache keys to invalidate}",
      rollback: "{how to undo on failure}",
    }
  ],
  persistence: "none | localStorage | sessionStorage | URL params",
}
```

**Optimistic updates**: Only use when the mutation is highly likely to succeed (>95%). Always implement rollback.

## Step 7: Accessibility Requirements (automatic + guided)

Derive baseline WCAG 2.1 AA requirements automatically from the component list, then confirm with the user.

### Automatic Baseline

```javascript
// Auto-derive from componentPlans (Step 3 output)
const a11yRequirements = []

for (const component of componentPlans) {
  const requirements = deriveA11yRequirements(component.name, component.tier)
  a11yRequirements.push({ component: component.name, requirements })
}

// deriveA11yRequirements heuristic:
// Modal/Dialog → role="dialog", aria-modal="true", focus trap, Escape to close
// Button → type="button", keyboard-activatable (Space/Enter)
// Form/Input → associated <label>, aria-describedby for error messages
// Table → <caption> or aria-label, <th scope="col|row">
// Nav → <nav> landmark, aria-label for multiple navs
// Tab panel → role="tablist", role="tab", aria-selected, Arrow key navigation
// Tooltip → role="tooltip", aria-describedby on trigger
// Image → alt text (descriptive) or alt="" (decorative) + aria-hidden="true"
// Link → meaningful text (no "click here"), aria-label when needed
// Loading → aria-busy="true", aria-live="polite" for status announcements
// Error state → role="alert" or aria-live="assertive" for error messages
```

### User Guidance (for non-automatic requirements)

```javascript
// Ask about specific requirements not derivable from component names
AskUserQuestion({
  questions: [{
    question: "Are there accessibility requirements beyond WCAG 2.1 AA baseline?",
    header: "Accessibility",
    options: [
      { label: "WCAG 2.1 AA only (standard)", description: "Baseline — covers most legal requirements" },
      { label: "WCAG 2.1 AAA", description: "Enhanced requirements — higher contrast, no timing" },
      { label: "Section 508 / ARIA APG patterns", description: "Government/enterprise — strict ARIA widget patterns" },
      { label: "Screen reader testing required", description: "VoiceOver + NVDA manual verification before ship" }
    ],
    multiSelect: true
  }]
})
```

### Accessibility Output Format

```markdown
## Accessibility Requirements (WCAG 2.1 AA)

| Component | Requirement | Test Method |
|-----------|-------------|-------------|
| {Component} | {ARIA role/attribute required} | {Automated / Manual} |
| Button | type="button", Space/Enter activation | Automated (axe-core) |
| Modal | role="dialog", aria-modal, focus trap, Escape | Manual (keyboard nav) |
| DataTable | <th scope="col">, aria-sort on sortable columns | Automated + Manual |
| Form fields | <label> association, aria-describedby for errors | Automated (axe-core) |
```

---

## Figma-to-Code Mapping Algorithm (Phase 6A)

When a Figma URL is present in the brainstorm context (`brainstormContext.figma_url`), use this algorithm to map Figma component names to existing codebase components.

**Purpose**: Before generating new components from Figma, exhaust all possibilities of mapping to existing code — reducing duplication and ensuring design system consistency.

### The Mapping Algorithm

```javascript
// For each Figma component node (from figma_list_components tool):
function mapFigmaComponentToCode(figmaNodeName, componentInventory) {
  const name = figmaNodeName

  // Step 1: NORMALIZE — strip Figma naming conventions
  // Remove: variant suffixes (Type=Primary/Size=Large/State=Default), frame wrappers,
  // underscores, slashes, and common Figma prefixes
  const normalized = name
    .replace(/[A-Z][a-z]+=[A-Z][a-z]+(?:,\s*)?/g, "")  // Remove "Key=Value" pairs
    .replace(/^\//g, "")          // Remove leading slash
    .replace(/\//g, " ")          // Replace path separators with spaces
    .replace(/[_-]+/g, " ")       // Replace underscores/hyphens with spaces
    .trim()
    .toLowerCase()

  // Step 2: SEARCH exact — look for exact name match in component inventory
  const allComponents = [
    ...componentInventory.atoms,
    ...componentInventory.molecules,
    ...componentInventory.organisms,
    ...componentInventory.pages,
  ]

  const exactMatch = allComponents.find(c =>
    c.name.toLowerCase() === normalized ||
    c.name.toLowerCase() === toPascalCase(normalized).toLowerCase()
  )
  if (exactMatch) return { match: "exact", component: exactMatch, action: "REUSE" }

  // Step 3: SEARCH fuzzy — edit distance <= 2 (Levenshtein)
  const fuzzyMatch = allComponents.find(c =>
    levenshteinDistance(c.name.toLowerCase(), normalized) <= 2
  )
  if (fuzzyMatch) return { match: "fuzzy", component: fuzzyMatch, action: "REUSE", confidence: "high" }

  // Step 4: SEARCH semantic — token overlap (shared meaningful words)
  // Split both names into tokens, count overlap (ignore stop words)
  const STOP_WORDS = new Set(["the", "a", "an", "and", "or", "for", "of", "with", "in", "on"])
  const figmaTokens = new Set(
    normalized.split(/\s+/).filter(t => t.length > 2 && !STOP_WORDS.has(t))
  )
  const semanticMatch = allComponents.find(c => {
    const codeTokens = c.name.toLowerCase().split(/(?=[A-Z])|\s+|-/)
      .filter(t => t.length > 2 && !STOP_WORDS.has(t))
    const overlap = codeTokens.filter(t => figmaTokens.has(t)).length
    return overlap >= Math.min(2, figmaTokens.size)
  })
  if (semanticMatch) return { match: "semantic", component: semanticMatch, action: "REUSE", confidence: "medium" }

  // Step 5: CREATE — no match found, component needs to be built
  return {
    match: "none",
    action: "CREATE",
    suggestedName: toPascalCase(normalized),
    tier: inferTierFromFigmaName(name),
  }
}
```

### Mapping Result Table

```markdown
## Figma-to-Code Mapping

| Figma Component | Normalized Name | Match Type | Code Component | Action |
|----------------|-----------------|-----------|----------------|--------|
| Button/Type=Primary | button | exact | src/components/ui/button.tsx | REUSE |
| Card/Elevated | card elevated | fuzzy | src/components/ui/card.tsx | EXTEND (add "elevated" variant) |
| MetricWidget | metric widget | none | — | CREATE (src/components/base/MetricWidget/) |
| SearchBar | search bar | semantic | src/components/SearchField.tsx | REUSE (rename prop if needed) |
```

### Confidence Thresholds

| Match Type | Confidence | Action |
|------------|-----------|--------|
| exact | 100% | Auto-REUSE, no confirmation needed |
| fuzzy (distance <= 1) | High (90%+) | Auto-REUSE with note in plan |
| fuzzy (distance == 2) | Medium (70%) | Present to user for confirmation |
| semantic (2+ token overlap) | Medium (60%) | Present to user for confirmation |
| none | — | CREATE (apply pre-creation checklist) |

When confidence is medium, present mapping to user for confirmation before including in the component plan.

---

## Protocol Output

All 7 steps produce structured output written to `brainstormContext` and included in the plan frontmatter and Technical Approach sections:

```javascript
// Summary written to brainstorm-decisions.md after protocol completes
const uiUxProtocolOutput = {
  design_system: brainstormContext.design_system,
  component_inventory: {
    atoms: inventory.atoms.length,
    molecules: inventory.molecules.length,
    organisms: inventory.organisms.length,
    pages: inventory.pages.length,
  },
  component_decomposition: componentPlans.map(c => ({
    name: c.name,
    tier: c.tier,
    strategy: c.strategy.strategy,  // REUSE | EXTEND | CREATE | COMPOSE
    source: c.strategy.source ?? null,
  })),
  user_flows: userFlows,
  responsive_strategy: responsiveStrategy,
  state_strategy: stateStrategy,
  a11y_requirements: a11yRequirements,
  figma_mapping: figmaMapping ?? null,
}

// Append to brainstorm-decisions.md
Write(`tmp/plans/${timestamp}/brainstorm-decisions.md`,
  existingContent +
  "\n\n## UI/UX Planning Protocol\n\n" +
  JSON.stringify(uiUxProtocolOutput, null, 2)
)
```

This output is consumed by:
- **Phase 2 (Synthesize)**: Populates Technical Approach and Frontend Architecture sections
- **Phase 4 (Strive workers)**: Injects component constraints into worker prompts
- **Phase 5A (Compliance reviewer)**: Provides design system profile for compliance checks
- **Phase 6A (Design sync)**: Seeds the Figma-to-Code mapping table

## Cross-References

- [ux-design-process SKILL.md](../../ux-design-process/SKILL.md) — UX design intelligence skill (Step 0 routing)
- [greenfield-process.md](../../ux-design-process/references/greenfield-process.md) — Greenfield UX methodology
- [brownfield-process.md](../../ux-design-process/references/brownfield-process.md) — Brownfield UX methodology
- [heuristic-checklist.md](../../ux-design-process/references/heuristic-checklist.md) — Nielsen+Baymard heuristic checklist
- [brainstorm-phase.md](brainstorm-phase.md) — Phase 0 where UI/UX protocol is triggered
- [synthesize.md](synthesize.md) — Phase 2 that consumes protocol output
- [design-system-rules.md](../../frontend-design-patterns/references/design-system-rules.md) — Token constraints enforced during decomposition
- [component-reuse-strategy.md](../../frontend-design-patterns/references/component-reuse-strategy.md) — REUSE > EXTEND > CREATE > COMPOSE decision tree
- [accessibility-patterns.md](../../frontend-design-patterns/references/accessibility-patterns.md) — WCAG 2.1 AA requirements (Step 7 source)
- [profiles/shadcn-profile.md](../../frontend-design-patterns/references/profiles/shadcn-profile.md) — shadcn/ui component creation patterns
- [profiles/untitled-ui-profile.md](../../frontend-design-patterns/references/profiles/untitled-ui-profile.md) — Untitled UI component patterns
- [profiles/generic-profile.md](../../frontend-design-patterns/references/profiles/generic-profile.md) — Generic design system patterns
