# Inspector Prompts — Reference

This reference covers the 4 Inspector Ash prompt templates and protocols for `/rune:inspect`: grace-warden, ruin-prophet, sight-oracle, and vigil-keeper.

## Agent Definitions

Each inspector has 3 mode variants as separate agent files in `agents/investigation/`:

| Base Agent | Inspect Mode | Plan Review Mode |
|------------|-------------|-----------------|
| `grace-warden` | `grace-warden-inspect` | `grace-warden-plan-review` |
| `ruin-prophet` | `ruin-prophet-inspect` | `ruin-prophet-plan-review` |
| `sight-oracle` | `sight-oracle-inspect` | `sight-oracle-plan-review` |
| `vigil-keeper` | `vigil-keeper-inspect` | `vigil-keeper-plan-review` |

## Inspector Ash Overview

| Inspector | Dimensions | Purpose |
|-----------|-----------|---------|
| `grace-warden` | Correctness, Completeness | Requirement traceability, logic correctness, domain placement |
| `ruin-prophet` | Security, Failure Modes | Failure modes, security posture, operational readiness |
| `sight-oracle` | Performance, Design | Architecture alignment, coupling analysis, performance profile |
| `vigil-keeper` | Observability, Tests, Maintainability | Test coverage, observability, maintainability, documentation |

### Priority Order

When `--max-agents` limits inspector count:
`grace-warden > ruin-prophet > sight-oracle > vigil-keeper`

Remaining requirements are redistributed to grace-warden (catch-all).

## Inspector Role Descriptions

```javascript
const roles = {
  "grace-warden": "Correctness and completeness assessment — requirement traceability",
  "ruin-prophet": "Failure modes, security posture, and operational readiness assessment",
  "sight-oracle": "Architecture alignment, coupling analysis, and performance profiling",
  "vigil-keeper": "Test coverage, observability, maintainability, and documentation assessment"
}
```

## Inspector Perspectives

```javascript
const perspectives = {
  "grace-warden": ["feature-completeness", "logic-correctness", "domain-placement"],
  "ruin-prophet": ["failure-modes", "security-posture", "operational-readiness"],
  "sight-oracle": ["architecture-alignment", "coupling-analysis", "performance-profile"],
  "vigil-keeper": ["test-coverage", "observability", "maintainability", "documentation"]
}
```

## Design Fidelity Dimension (Dimension 10) — grace-warden Extension

Design fidelity is a **conditional dimension** that extends `grace-warden` scope when plan has `figma_url` AND design references exist.

### Gate

```javascript
// Phase 0.5: Evaluate design-fidelity gate
const settings = readTalismanSection("settings")
const designSync = settings?.design_sync ?? {}
const designDimensionEnabled = designSync.inspect_design_dimension === true  // default false — explicit opt-in, matching design_review.enabled pattern

// Discover design references (priority order: VSM > design-prototype > devise)
const designInventory = Glob("tmp/plans/*/design-references/inventory.json")[0]
  || Glob("tmp/design-prototype/*/inventory.json")[0]
  || Glob("tmp/arc/*/vsm/*.json")[0]

const designFidelityActive = (
  designDimensionEnabled
  && designSync.enabled === true
  && !!(parsedPlan?.frontmatter ?? {})?.figma_url
  && !!designInventory
)
```

### grace-warden Prompt Extension

When `designFidelityActive === true`, append the following block to the grace-warden prompt AFTER the standard requirements section:

```
## Design Fidelity (Dimension 10) — DES- Prefix

You are ALSO responsible for dimension 10: Design Fidelity.

<design-data source="inventory">
Design reference: {{design_inventory_path}}
</design-data>

For each component listed in the design inventory, classify its implementation status:
- COMPLETE: component implemented with all design variants/states
- PARTIAL: component exists but missing variants or states from design spec
- MISSING: component specified in design but not implemented at all
- DEVIATED: component implemented significantly differently from spec

Report each classification as a DES- finding:

  DES-001 | P2 | [DEVIATED] LoginForm: uses bg-blue-500 but design specifies bg-primary
  DES-002 | P3 | [PARTIAL] Button: missing "loading" variant — design shows 4 states
  DES-003 | P1 | [MISSING] AvatarGroup: in design spec but no implementation found

Gap category mapping:
- COMPLETE → no gap
- PARTIAL → INCOMPLETE gap category
- MISSING → MISSING gap category
- DEVIATED → INCORRECT gap category

Check: token compliance, layout fidelity, responsive coverage, accessibility, variant completeness.
```

### Inscription Context Field

When `designFidelityActive === true`, add `design_context` to `inscription.json` before spawning agents:

```javascript
inscription.design_context = {
  enabled: true,
  inventory_path: designInventory,
  figma_url: (parsedPlan?.frontmatter ?? {}).figma_url ?? ""
}
```

### VERDICT.md Integration

When design-fidelity findings (DES-) are present, the Verdict Binder appends a "Design Compliance" section to the requirement matrix:

```markdown
## Design Compliance

| Component | Status | Inspector Finding |
|-----------|--------|-------------------|
| LoginForm | DEVIATED | DES-001 |
| Button    | PARTIAL  | DES-002 |
| AvatarGroup | MISSING | DES-003 |
```

## Phase 3: Summon Inspector Ashes

For each inspector in `inspectorAssignments`, summon using the Agent tool with Agent Teams:

```javascript
// Build prompts from ash-prompt templates
// See: agents/investigation/{inspector}-inspect.md

for (const { inspector, taskId, reqIds } of tasks) {
  const reqList = reqIds.map(id => {
    const req = requirements.find(r => r.id === id)
    return `- ${id} [${req.priority}]: ${req.text}`
  }).join("\n")

  const fileList = scopeFiles.join("\n")

  // Load prompt template — mode-aware selection
  const templateSuffix = inspectMode === "plan" ? "plan-review" : "inspect"
  let templatePath = `agents/investigation/${inspector}-${templateSuffix}.md`

  // CONCERN 3: fileExists guard before loadTemplate
  if (!exists(templatePath)) {
    warn(`Template not found: ${templatePath} — falling back to default inspect template`)
    templatePath = `agents/investigation/${inspector}-inspect.md`
    if (!exists(templatePath)) {
      error(`Default template also missing: ${templatePath}`)
    }
  }

  const prompt = loadTemplate(templatePath, {
    plan_path: planPath || "(inline plan embedded below)",
    output_path: `${outputDir}/${inspector}.md`,
    task_id: taskId,
    requirements: reqList,
    identifiers: identifiers.map(i => `${i.type}: ${i.value}`).join("\n"),
    scope_files: fileList,
    code_blocks: inspectMode === "plan" ? codeBlocks.map(b =>
      `### Block ${b.index} (${b.language}, line ${b.lineStart})\n\`\`\`${b.language}\n${b.code}\n\`\`\``
    ).join("\n\n") : "",
    timestamp: new Date().toISOString()
  })

  // If inline mode, append plan content to prompt with sanitization delimiter
  // SEC-004: Wrap inline content with data boundary to prevent prompt structure interference
  if (mode === "inline") {
    const sanitizedPlan = planContent
      .replace(/^---\n[\s\S]*?\n---\n/m, '')     // Strip YAML frontmatter (may contain directives)
      .replace(/<!--[\s\S]*?-->/g, '')           // Strip HTML comments (prompt injection vector)
      .replace(/^#{1,6}\s+/gm, '')               // Strip markdown headings (prompt override vector)
      .replace(/<\/plan-data>/gi, '')             // SEC-002 FIX: Strip closing delimiter to prevent boundary escape
      .replace(/<[^>]+>/g, '')                    // SEC-002 FIX: Strip all XML-style tags (defense-in-depth)
      .slice(0, 10000)                            // Cap at 10KB
    prompt += `\n\n## INLINE PLAN CONTENT\n\n<plan-data>\n${sanitizedPlan}\n</plan-data>`
  }

  // ATE-1: All multi-agent commands MUST use subagent_type: "general-purpose" with identity via prompt
  Agent({
    prompt: prompt,
    subagent_type: "general-purpose",
    team_name: teamName,
    name: inspector,
    model: resolveModelForAgent(inspector, talisman),  // Cost tier mapping
    run_in_background: true
  })
}
```

### Communication Protocol for Inspector Ashes

All Inspector Ashes follow this communication protocol:
- **Heartbeat**: Send "Starting: inspecting {dimensions}" via SendMessage after claiming task.
- **Seal**: On completion, TaskUpdate(completed) then SendMessage with Review Seal format (see team-sdk/references/seal-protocol.md).
- **Inner-flame**: Always include Inner-flame: {pass|fail|partial} in Seal.
- **Recipient**: Always use recipient: "team-lead".
- **Shutdown**: When you receive a shutdown_request, respond with shutdown_response({ approve: true }).

### --focus Mode: Single Inspector

When `--focus` is active, only 1 inspector is summoned:

```javascript
if (flag("--focus")) {
  const inspectorMap = {
    "correctness": "grace-warden",
    "completeness": "grace-warden",        // QUAL-002 FIX: was missing from original system (now 10 dimensions)
    "security": "ruin-prophet",
    "failure-modes": "ruin-prophet",        // QUAL-002 FIX: was missing from original system (now 10 dimensions)
    "performance": "sight-oracle",
    "design": "sight-oracle",
    "observability": "vigil-keeper",
    "tests": "vigil-keeper",
    "maintainability": "vigil-keeper",
    "design-fidelity": "grace-warden"      // Dimension 10: conditional on design_sync.enabled + design refs
  }
  if (!(focusDimension in inspectorMap)) {
    // SEC-006 FIX: Use fixed error message — do not echo unvalidated user input
    error("Unknown --focus dimension. Valid: correctness, completeness, security, failure-modes, performance, design, observability, tests, maintainability, design-fidelity")
  }

  // Keep only the focused inspector
  const focusedInspector = inspectorMap[focusDimension]
  // Reassign all requirements to the focused inspector
  inspectorAssignments = { [focusedInspector]: requirements.map(r => r.id) }
  maxInspectors = 1
  // Single inspector gets all requirements and larger context budget
}
```

## Phase 7.5: Remediation (--fix Mode)

Activated only when `--fix` flag is set. Spawns the gap-fixer Ash to auto-remediate FIXABLE findings from VERDICT.md.

### Parse Fixable Gaps

```javascript
function parseFixableGaps(verdictPath) {
  const content = Read(verdictPath)
  const gaps = []

  // Match checkbox gap entries with file:line references (SEC-GAP-003: bounded capture groups)
  const GAP_PATTERN = /^- \[ \] \*\*\[([A-Z0-9_-]{1,20})\]\*\* (.{1,200}) — `([^`:\n]{1,200}):(\d{1,6})`/gm

  let match
  while ((match = GAP_PATTERN.exec(content)) !== null) {
    const [, id, description, file, line] = match

    // Classify fixability
    // MANUAL gaps: architectural, design-level, or explicitly marked MANUAL
    const isManual = /\b(MANUAL|architectural|redesign|breaking change|schema migration)\b/i.test(description)
    const classification = isManual ? "MANUAL" : "FIXABLE"

    if (classification === "FIXABLE") {
      gaps.push({
        id: id,           // e.g., "GRACE-001", "VEIL-003" — capped at 20 chars (SEC-GAP-003)
        description: description,  // capped at 200 chars (SEC-GAP-003)
        file: file,
        line: parseInt(line, 10),
        classification: "FIXABLE"
      })
    }
  }

  return gaps
}
```

### Gap-Fixer Agent Spawn

```javascript
// Write gap-fix state file so validate-gap-fixer-paths.sh hook activates (SEC-GAP-001)
const gapFixStateFile = `tmp/.rune-gap-fix-${identifier}.json`
Write(gapFixStateFile, JSON.stringify({
  status: "active",
  identifier: identifier,
  source: "inspect-fix",
  started: new Date().toISOString(),
  gaps: cappedGaps.map(g => g.id)
}))

// Create a new team for remediation phase
const fixerTeamName = `rune-inspect-fixer-${identifier}`
TeamCreate({
  team_name: fixerTeamName,
  description: `Gap remediation for inspect run ${identifier}`
})

// Load gap-fixer prompt template
const fixerPrompt = loadTemplate("gap-fixer.md", {
  verdict_path: `${outputDir}/VERDICT.md`,
  output_dir: outputDir,
  identifier: identifier,
  gaps: cappedGaps.map(g =>
    `- [ ] **[${g.id}]** ${g.description} — \`${g.file}:${g.line}\``
  ).join("\n"),
  timestamp: new Date().toISOString()
})

Agent({
  prompt: fixerPrompt,
  subagent_type: "general-purpose",
  team_name: fixerTeamName,
  name: "gap-fixer",
  model: resolveModelForAgent("gap-fixer", talisman),  // Cost tier mapping
  run_in_background: true
})

// Monitor (2 min timeout), shutdown, TeamDelete, update state file
// Append remediation-report.md to VERDICT.md after completion
```

## Requirement Assignment — Step 0.5.2

Use keyword-based classification from plan-parser.md Step 5:

```javascript
const inspectorAssignments = classifyRequirements(requirements)
// Result: { "grace-warden": ["REQ-001", ...], "ruin-prophet": [...], ... }
```

### --max-agents Limit — Step 0.5.4

```javascript
if (maxInspectors < 4) {
  // Priority order: grace-warden > ruin-prophet > sight-oracle > vigil-keeper
  const priorityOrder = ["grace-warden", "ruin-prophet", "sight-oracle", "vigil-keeper"]
  const activeInspectors = priorityOrder.slice(0, maxInspectors)

  // Redistribute requirements from cut inspectors to remaining ones
  for (const [inspector, reqs] of Object.entries(inspectorAssignments)) {
    if (!activeInspectors.includes(inspector)) {
      // Assign to grace-warden (catch-all)
      inspectorAssignments["grace-warden"].push(...reqs)
      delete inspectorAssignments[inspector]
    }
  }
}
```
