# Phase 0: Gather Input (Brainstorm)

## Brainstorm Auto-Detection

Before asking for input, check for recent brainstorms that match:

```javascript
// Search for recent brainstorms in both locations
const brainstorms = [
  ...Glob("docs/brainstorms/*.md"),
  ...Glob("tmp/plans/*/brainstorm-decisions.md")
]
// Filter: created within last 14 days, topic matches feature
// If found: read and use as input, skip Phase 0 questioning
// If multiple match: AskUserQuestion to select
// If none: proceed with normal Phase 0 flow
```

**Matching thresholds**:
- Auto-use (>= 0.85): Exact/fuzzy title match or strong tag overlap (>= 2 tags)
- Ask user (0.70-0.85): Single semantic match, show with confirmation
- Skip (< 0.70): No relevant brainstorm found

**Recency decay**: >14 days: 0.7x, >30 days: 0.4x, >90 days: skip.

## With `--quick`

Skip brainstorm entirely. Ask the user for a feature description:

```javascript
AskUserQuestion({
  questions: [{
    question: "What would you like to plan?",
    header: "Feature",
    options: [
      { label: "New feature", description: "Add new functionality" },
      { label: "Bug fix", description: "Fix an existing issue" },
      { label: "Refactor", description: "Improve existing code" }
    ],
    multiSelect: false
  }]
})
```

Then ask for details. Collect until the feature is clear. Proceed directly to Phase 1.

## Default (Brainstorm)

Run a structured brainstorm session. Brainstorm ensures clarity before research.

### Step 1: Assess Requirement Clarity

Before asking questions, assess whether brainstorming is needed:

**Clear signals** (skip brainstorm, go to research):
- User provided specific acceptance criteria
- User referenced existing patterns to follow
- Scope is constrained and well-defined

**Brainstorm signals** (proceed with questions):
- User used vague terms ("make it better", "add something like")
- Multiple reasonable interpretations exist
- Trade-offs haven't been discussed

If clear: "Your requirements are clear. Proceeding directly to research."

### Step 2: Understand the Idea (3-5 questions, one at a time)

Ask questions using AskUserQuestion, one at a time:

| Topic | Example Questions |
|-------|-------------------|
| Purpose | What problem does this solve? What's the motivation? |
| Users | Who uses this? What's their context? |
| Constraints | Technical limitations? Timeline? Dependencies? |
| Success | How will you measure success? |
| Edge Cases | What shouldn't happen? Any error states? |

**Prefer multiple choice** when natural options exist.
**Exit condition**: Idea is clear OR user says "proceed".

### Step 3: Explore Approaches

Propose 2-3 concrete approaches with pros/cons:

```javascript
AskUserQuestion({
  questions: [{
    question: "Which approach do you prefer?",
    header: "Approach",
    options: [
      { label: "Approach A (Recommended)", description: "{brief + why recommended}" },
      { label: "Approach B", description: "{brief + tradeoff}" },
      { label: "Approach C", description: "{brief + tradeoff}" }
    ],
    multiSelect: false
  }]
})
```

### Step 3.2: Design Asset Detection (conditional)

After approach selection, scan user input for Figma URLs and design-related keywords. When design assets are detected, append a "## Design Assets" section to the brainstorm context for downstream phases.

```javascript
// SYNC: figma-url-pattern — used in brainstorm-phase.md and devise SKILL.md Phase 0
const FIGMA_URL_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
const DESIGN_KEYWORD_PATTERN = /\b(figma|design|mockup|wireframe|prototype|ui\s*kit|design\s*system|style\s*guide|component\s*library|sketch|adobe\s*xd)\b/i

// Strategy 1: Explicit Figma URL detected
const figmaUrls = (featureDescription + " " + selectedApproach).match(FIGMA_URL_PATTERN) || []
const figmaUrl = figmaUrls.length > 0 ? figmaUrls[0] : null

// Strategy 2: Design keywords detected but no URL — prompt user
const hasDesignKeywords = DESIGN_KEYWORD_PATTERN.test(featureDescription + " " + selectedApproach)

let design_sync_candidate = false

if (figmaUrl) {
  // Figma URL found — auto-mark as design-sync candidate
  design_sync_candidate = true
  brainstormContext.figma_url = figmaUrl
  brainstormContext.design_urls = figmaUrls

  // Append Design Assets section to brainstorm context
  brainstormContext.design_assets = `## Design Assets\n- Figma URL: ${figmaUrl}\n- Status: auto-detected\n`

  // Inject design-specific brainstorm questions
  AskUserQuestion({
    questions: [{
      question: "Design tokens and responsive breakpoints?",
      header: "Design Context",
      options: [
        { label: "Auto-extract from Figma (Recommended)", description: "Colors, spacing, typography, breakpoints from Figma frames" },
        { label: "Specify manually", description: "I'll provide design token requirements" },
        { label: "Skip design details", description: "Handle during implementation" }
      ],
      multiSelect: false
    }]
  })
} else if (hasDesignKeywords) {
  // Design keywords but no Figma URL — ask user
  const designResponse = AskUserQuestion({
    questions: [{
      question: "Your description mentions design elements. Do you have a Figma file?",
      header: "Design Assets",
      options: [
        { label: "Yes — I'll provide the URL", description: "Paste your Figma URL" },
        { label: "No design file", description: "Proceed without design sync" },
        { label: "Will add later", description: "Skip for now, add Figma URL to plan later" }
      ],
      multiSelect: false
    }]
  })
  // If user provides URL, set design_sync_candidate = true
  if (designResponse === "Yes — I'll provide the URL") {
    // Follow-up: ask for the URL
    design_sync_candidate = true
  }
}
// When neither URL nor keywords detected: zero overhead
```

### Step 3.5: Elicitation Methods (Mandatory)

After approach selection, summon 1-3 elicitation-sage teammates for multi-perspective structured reasoning. Skippable via talisman key `elicitation.enabled: false` or user opt-out.

**Talisman check**: Read `.claude/talisman.yml` → if `elicitation.enabled` is explicitly `false`, skip this step entirely.

```javascript
// readTalismanSection: "gates"
const elicitEnabled = readTalismanSection("gates")?.elicitation?.enabled !== false
if (elicitEnabled) {
// ── BEGIN elicitation gate ──

// 1. Compute fan-out using simplified keyword count threshold (not float scoring)
//    Decree-arbiter P2: Float comparisons unreliable in LLM pseudocode.
//    Use keyword count → lookup table instead.
// NOTE: Brainstorm uses 15 keywords (wider activation) vs 10 in forge/review sites.
// Intentional: brainstorm is the first user-facing sage invocation — broader net catches
// more opportunities for structured reasoning before the plan is finalized.
// Canonical keyword list — see elicitation-sage.md § Canonical Keyword List for the source of truth
// Brainstorm extends base list with: breaking-change, auth, api, complex, novel-approach
const elicitKeywords = ["architecture", "security", "risk", "design", "trade-off",
  "migration", "performance", "decision", "approach", "comparison",
  "breaking-change", "auth", "api", "complex", "novel-approach"]
const contextText = (featureDescription + " " + selectedApproach).toLowerCase()
const keywordHits = elicitKeywords.filter(k => contextText.includes(k)).length

// Lookup table: keyword hits → sage count (capped at 3 for brainstorm)
let sageCount
if (keywordHits >= 4) sageCount = 3       // High complexity (4+ keywords → max sages)
else if (keywordHits >= 2) sageCount = 2  // Moderate
else sageCount = 1                         // Simple — still 1 sage minimum

// 2. Score and assign methods
//    Read methods.csv, filter for plan:0 phase, sort by keyword overlap
const methods = Read("skills/elicitation/methods.csv")
// Filter: phases contains "plan:0" AND auto_suggest = true
// Score against feature keywords (topic overlap from SKILL.md algorithm)
// Sort by score DESC → take top {sageCount} methods

// 3. Present to user (skip in --quick mode)
if (!quickMode) {
  AskUserQuestion({
    questions: [{
      question: `Apply ${sageCount} structured reasoning method(s) to deepen this brainstorm?`,
      header: "Elicitation",
      options: [
        { label: `Auto: ${sageCount} method(s) (Recommended)`,
          description: `${selectedMethods.map(m => m.method_name).join(", ")}` },
        { label: "Skip elicitation",
          description: "Proceed with current brainstorm output" }
      ],
      multiSelect: false
    }]
  })
}

// 4. Summon sages as Agent Team teammates
//    ATE-1 COMPLIANT: Plan team created in Phase -1 (Team Bootstrap).
//    Sages join rune-plan-{timestamp} and are tracked via TaskList.
//    ATE-1 COMPLIANCE: subagent_type MUST be "general-purpose", identity via prompt.

// Create tasks for each sage
for (let i = 0; i < sageCount; i++) {
  const method = selectedMethods[i]
  TaskCreate({
    subject: `Elicitation: ${method.method_name}`,
    description: `Apply ${method.method_name} structured reasoning to brainstorm context`,
    activeForm: `Applying ${method.method_name}`
  })
}

for (let i = 0; i < sageCount; i++) {
  const method = selectedMethods[i]

  Agent({
    name: `elicitation-sage-${i + 1}`,
    subagent_type: "general-purpose",
    team_name: `rune-plan-${timestamp}`,
    prompt: `You are elicitation-sage — a structured reasoning specialist.

      ## Bootstrap
      Read skills/elicitation/SKILL.md and skills/elicitation/methods.csv first.

      ## Assignment
      Phase: plan:0 (brainstorm)
      Assigned method: ${method.method_name} (method #${method.num})
      Feature: ${((featureDescription || '').replace(/<!--[\s\S]*?-->/g, '').replace(/\`\`\`[\s\S]*?\`\`\`/g, '[code-block-removed]').replace(/!\[.*?\]\(.*?\)/g, '').replace(/^#{1,6}\s+/gm, '').replace(/&[a-zA-Z0-9#]+;/g, '').replace(/[\u200B-\u200F\uFEFF\uFE00-\uFE0F]/g, '').replace(/\uDB40[\uDC00-\uDC7F]/g, '').slice(0, 2000))}
      Chosen approach: ${((selectedApproach || '').replace(/<!--[\s\S]*?-->/g, '').replace(/\`\`\`[\s\S]*?\`\`\`/g, '[code-block-removed]').replace(/!\[.*?\]\(.*?\)/g, '').replace(/^#{1,6}\s+/gm, '').replace(/&[a-zA-Z0-9#]+;/g, '').replace(/[\u200B-\u200F\uFEFF\uFE00-\uFE0F]/g, '').replace(/\uDB40[\uDC00-\uDC7F]/g, '').slice(0, 2000))}
      Brainstorm context: Read tmp/plans/{timestamp}/brainstorm-decisions.md

      ## Lifecycle
      1. Claim the "Elicitation: ${method.method_name}" task via TaskList/TaskUpdate
      2. Read skills/elicitation/SKILL.md and methods.csv (bootstrap)
      3. Apply ONLY the method "${method.method_name}" to the brainstorm context
      4. Write output to: tmp/plans/{timestamp}/elicitation-${method.method_name.toLowerCase().replace(/[^a-z0-9-]/g, '-')}.md
      5. Do not write implementation code. Structured reasoning output only.
      6. Mark task complete via TaskUpdate`,
    run_in_background: true
  })
}

// 5. After all sages complete:
//    Completion detection: TaskList-based monitoring via team task tracking.
//    Check TaskList for elicitation tasks to reach "completed" status.
//    Read all tmp/plans/{timestamp}/elicitation-*.md files
//    Merge structured reasoning insights into brainstorm-decisions.md
//    Include in research handoff context

// 6. In --quick mode: auto-summon 1 sage without AskUserQuestion

// ── END elicitation gate ──
} // end elicitEnabled guard
```

Exit condition: All sage outputs written (or user explicitly skips).

### Step 4: Capture Decisions

Record brainstorm output for research phase:
- What we're building
- Chosen approach and why
- Key constraints
- Open questions to resolve during research

The following structured sections are **mandatory** in every brainstorm output. Include them after the core decision capture above:

#### 4a. Non-Goals

```markdown
## Non-Goals

Explicitly out-of-scope items for this feature. List anything that a reasonable person might assume is included but is NOT.

- {item 1 — why it is excluded}
- {item 2 — why it is excluded}
```

**Validation**: If Non-Goals section is empty after brainstorm, warn: "Non-Goals section is empty — consider adding at least one exclusion to prevent scope creep."

#### 4b. Constraint Classification

```markdown
## Constraint Classification

| Constraint | Priority | Rationale |
|------------|----------|-----------|
| {constraint 1} | MUST | {why non-negotiable} |
| {constraint 2} | SHOULD | {why important but flexible} |
| {constraint 3} | NICE-TO-HAVE | {why desirable but deferrable} |
```

#### 4c. Success Criteria

```markdown
## Success Criteria

Measurable outcomes that determine whether this feature is successful (distinct from Acceptance Criteria — these measure business/user impact, not implementation completeness).

- {criterion 1 — metric and target}
- {criterion 2 — metric and target}
```

#### 4d. Scope Boundary

```markdown
## Scope Boundary

### In-Scope
- {item 1}
- {item 2}

### Out-of-Scope
- {item 1} (see Non-Goals)
- {item 2}
```

Persist brainstorm decisions to: `tmp/plans/{timestamp}/brainstorm-decisions.md`
