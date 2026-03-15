# Phase 2: Synthesize

After research completes, the Tarnished consolidates findings.

## Plan Detail Level Selection

Before drafting, ask the user for detail level:

```javascript
AskUserQuestion({
  questions: [{
    question: "What detail level for this plan?",
    header: "Detail",
    options: [
      { label: "Standard (Recommended)", description: "Overview, solution, technical approach, criteria, references" },
      { label: "Minimal", description: "Brief description + acceptance criteria only" },
      { label: "Comprehensive", description: "Full spec with phases, alternatives, risks, ERD, metrics" }
    ],
    multiSelect: false
  }]
})
```

## Consolidation

**Inputs**: research output files (paths from `tmp/plans/{timestamp}/research/`), selected detail level
**Outputs**: plan file (`plans/YYYY-MM-DD-{type}-{feature}-plan.md`)
**Preconditions**: git repository initialized (or gracefully handles non-git context)
**Error handling**: git commands wrapped in `2>/dev/null || echo "null"` for non-git directories; detached HEAD sets `branch` to `null`

1. Read all research output files from `tmp/plans/{timestamp}/research/`
2. Identify common themes, conflicting advice, key patterns
3. Populate git metadata in plan frontmatter: include `git_sha` (from `git rev-parse HEAD`) and `branch` (from `git branch --show-current`). If the working directory is not a git repository, omit these fields. On a detached HEAD, set `branch` to `null`.
4. **Evidence population** (Standard and Comprehensive only): For each major factual claim in Proposed Solution and Technical Approach, search research outputs (`tmp/plans/{timestamp}/research/`) for supporting evidence. Populate the Evidence Chain table with claims and their verification status. Claims without supporting evidence in research outputs get `Verified: No`. Evidence types ordered by strength: CODEBASE > DOCUMENTATION > EXTERNAL > OBSERVED > NOVEL.
5. Draft the plan document using the template matching the selected detail level:

## Minimal Template

```markdown
---
title: "{type}: {feature description}"
type: feat | fix | refactor
date: YYYY-MM-DD
version_target: "{estimated version}"
complexity: "{Low|Medium|High}"
estimated_effort: "{S|M|L|XL} — ~{N} LOC, {N} files"
impact: "{N}/10"
strategic_intent: "long-term"  # Options: long-term | quick-win | auto
non_goals: []  # List of explicitly out-of-scope items (from brainstorm or manual entry)
git_sha: "{run: git rev-parse HEAD}"
branch: "{run: git branch --show-current}"
figma_url: ""          # Auto-populated when Figma URL detected in brainstorm (leave empty if none). MUST be double-quoted when populated: figma_url: "https://..."
figma_urls: []         # NEW — array of {url, role?, screen?}. role: auto|primary|variant (default: auto). screen: group label, null = auto-detect. Leave empty if none.
design_sync: false     # Set to true when figma_url is detected (enables design context in strive workers)
design_references_path: ""      # Auto-populated: path to design-references/ directory (e.g. "tmp/plans/{timestamp}/design-references/")
library_match_count: 0          # Number of components matched to UI library (from match-report.json)
ux_flow_mapped: false           # Whether flow-map.md was generated (>= 2 components)
page_compositions: 0            # Number of page-level prototypes generated
session_budget:
  max_concurrent_agents: 3      # Cap on simultaneous teammates (applied silently); see sizing guide
---

# {Feature Title}

{Brief problem/feature description in 2-3 sentences}

## Acceptance Criteria

- [ ] Core requirement 1
- [ ] Core requirement 2

## Context

{Any critical information -- constraints, dependencies, deadlines}

## Evidence Chain (optional)

{Omit for truly minimal plans. Include when upgrading to Standard for traceability.}

## References

- Related: {links}
```

## Standard Template (default)

```markdown
---
title: "{type}: {feature description}"
type: feat | fix | refactor
date: YYYY-MM-DD
version_target: "{estimated version}"
complexity: "{Low|Medium|High}"
scope: "{description of files affected}"
risk: "{Low|Medium|High} — {brief explanation}"
estimated_effort: "{S|M|L|XL} — ~{N} LOC, {N} files"
impact: "{N}/10"
strategic_intent: "long-term"  # Options: long-term | quick-win | auto
non_goals: []  # List of explicitly out-of-scope items (from brainstorm or manual entry)
git_sha: "{run: git rev-parse HEAD}"
branch: "{run: git branch --show-current}"
figma_url: ""          # Auto-populated when Figma URL detected in brainstorm (leave empty if none). MUST be double-quoted when populated: figma_url: "https://..."
figma_urls: []         # NEW — array of {url, role?, screen?}. role: auto|primary|variant (default: auto). screen: group label, null = auto-detect. Leave empty if none.
design_sync: false     # Set to true when figma_url is detected (enables design context in strive workers)
design_references_path: ""      # Auto-populated: path to design-references/ directory (e.g. "tmp/plans/{timestamp}/design-references/")
library_match_count: 0          # Number of components matched to UI library (from match-report.json)
ux_flow_mapped: false           # Whether flow-map.md was generated (>= 2 components)
page_compositions: 0            # Number of page-level prototypes generated
design_system_library: ""       # Auto-detected: "shadcn" | "untitled-ui" | "generic" | "" (non-frontend)
design_system_confidence: 0.0   # Detection confidence 0.0–1.0 (from discoverDesignSystem())
component_count_new: 0          # Number of CREATE-strategy components (from UI/UX protocol Step 3)
component_count_extend: 0       # Number of EXTEND-strategy components
component_count_reuse: 0        # Number of REUSE-strategy components
ui_builder:                     # Auto-populated by discoverUIBuilder() — omit when no builder detected
  builder_skill: ""             # Builder skill name (e.g. "untitledui-mcp" or project override)
  builder_mcp: ""               # MCP server name in .mcp.json (e.g. "untitledui")
  conventions: ""               # Path to conventions file (relative to skill dir)
  capabilities: {}              # Map of capability → tool name from builder-protocol frontmatter
session_budget:
  max_concurrent_agents: 5      # Cap on simultaneous teammates (applied silently); see sizing guide
---

# {Feature Title}

## Overview

{What and why -- informed by research findings}

## Problem Statement

{Why this matters, who is affected}

## Proposed Solution

{High-level approach informed by research}

## Solution Selection
{If Arena ran: include arena-selection findings below. If Arena was skipped but brainstorm ran: write "Approach selected during brainstorm — no competitive evaluation." If both Arena and brainstorm were skipped (--quick with direct feature description): omit this section entirely.}
- **Chosen approach**: {solution name} ({weighted score}/10, range 1-10)
- **Rationale**: {1-sentence why this approach won}
- **Top concern**: {highest-severity DA challenge}

## Technical Approach

{Implementation details referencing codebase patterns discovered by repo-surveyor}

### Stakeholders

{Who is affected: end users, developers, operations}

## Frontend Architecture (conditional — omit when no frontend stack detected by stacks)

{Omit this entire section when design_system_library is empty or stacks detects no frontend files.}

### Design System Profile

{Always emitted when frontend stack is detected. Populated from discoverDesignSystem() output and brainstorm UI/UX Decisions.}

| Property | Value |
|----------|-------|
| Library | {design_system_library — e.g. shadcn, untitled-ui, generic} |
| Token system | {CSS vars / Tailwind / Style Dictionary / none} |
| Variant system | {CVA / CSS classes / explicit map / none} |
| Accessibility layer | {Radix UI / React Aria / manual / none} |
| Tailwind version | {v3 / v4 / not used} |
| Class merge utility | {cn() / clsx / none} |
| Dark mode strategy | {CSS vars (.dark) / data-theme attr / media query / none} |
| Path convention | {src/components/ui/ / src/components/base/ / other} |
| Existing components | {component_count_reuse} reuse + {component_count_extend} extend + {component_count_new} new |

### Component Strategy (conditional — omit when ui_builder is absent)

{Omit this entire section when `ui_builder` frontmatter is empty. Only emit when discoverUIBuilder() returned a builder profile.}

**UI Builder**: {ui_builder.builder_skill} via {ui_builder.builder_mcp} MCP
**Capabilities**: {comma-separated list of capability names from ui_builder.capabilities}

#### Component Mapping

{Populated from builder search during devise Phase 1 — flow-seer + repo-surveyor search for UI elements and match against library.}
{If no search was performed, write "Pending — will be populated during arc Phase 1.5 Component Match."}

| UI Element | Library Component | Search Query | Confidence | Notes |
|------------|------------------|-------------|-----------|-------|
| {sidebar navigation} | {SidebarNav} | {search_components("sidebar navigation with icons")} | High | |
| {data table with pagination} | {Table + Pagination} | {search_components("data table pagination")} | Medium | PRO |
| {form with email field} | {FormField + Input} | {search_components("form email input")} | High | |

#### Conventions Summary

{Key conventions from ui_builder.conventions — pull 3-5 most critical rules. Full conventions in the builder skill reference.}

- {e.g. React Aria imports use Aria* prefix: `import { Button as AriaButton } from "react-aria-components"`}
- {e.g. Files MUST be kebab-case: date-picker.tsx not DatePicker.tsx}
- {e.g. Colors MUST be semantic: text-primary not text-gray-900}

### Component Hierarchy

{Emitted when component_count_new >= 1. Populated from UI/UX protocol Step 3 decomposition.}

| Component | Tier | Strategy | Base Component | File Path |
|-----------|------|----------|---------------|-----------|
| {ComponentName} | atom \| molecule \| organism \| page | REUSE \| EXTEND \| CREATE \| COMPOSE | {base or —} | {src/components/...} |

### Component Dependency Graph

{Emitted when component_count_new >= 1. Shows which components compose which.}

~~~mermaid
graph TD
    A[PageComponent] --> B[OrganismA]
    A --> C[OrganismB]
    B --> D[MoleculeX]
    B --> E[AtomY]
    D --> E
    D --> F[AtomZ]
~~~

### Design Token Constraints

{Emitted when component_count_new >= 1.}

**Allowed tokens** (from detected design system):

| Token | Value | Usage |
|-------|-------|-------|
| {--color-primary or bg-primary} | {CSS var or Tailwind class} | {usage description} |
| {--spacing-4 or p-4} | {value} | {usage description} |

**Forbidden patterns** (from design-system-rules.md):
- No hex/RGB literals — all colors via tokens
- No arbitrary px values — all spacing on the scale
- No inline styles with magic numbers

### Responsive Behavior

{Emitted when component_count_new >= 1. Per-component mobile/tablet/desktop strategy.}

| Component | Mobile (<640px) | Tablet (640–1024px) | Desktop (>1024px) |
|-----------|----------------|---------------------|-------------------|
| {Component} | {layout/behavior} | {layout/behavior} | {layout/behavior} |

### State Management Map

{Emitted when component_count_new >= 1. Per-component data source and state scope.}

| Component | Data Source | State Type | Mutation | Cache Strategy |
|-----------|------------|------------|---------|----------------|
| {Component} | {API endpoint or local} | server \| URL \| local \| global | {action} | {invalidation strategy} |

### Accessibility Matrix

{Emitted when component_count_new >= 1. Per-component WCAG 2.1 AA requirements.}

| Component | Semantic Element | ARIA Role / Attr | Keyboard Nav | Focus Management |
|-----------|-----------------|------------------|-------------|-----------------|
| {Component} | {button/dialog/nav/...} | {role= / aria-*} | {keys} | {trap / return / none} |

### Animation & Interaction Spec

{Emitted when component_count_new >= 1. Only include when interactions are non-trivial.}

| Component | Trigger | Animation | Duration | Easing |
|-----------|---------|-----------|---------|--------|
| {Component} | {hover/click/mount/unmount} | {fade/slide/scale/none} | {ms} | {ease-in-out/...} |

### User Flow

{Emitted when component_count_new >= 1. Mermaid flowchart of primary user journey.}

~~~mermaid
flowchart LR
    A([Start]) --> B[{Step 1}]
    B --> C{Decision?}
    C -- Yes --> D[{Step 2a}]
    C -- No --> E[{Step 2b}]
    D --> F([End])
    E --> F
~~~

## Boundary Map

{Required for Standard and Comprehensive plans. Omit for Minimal.}
{For each phase or major section in Technical Approach, specify what it
produces and what it consumes from upstream. Forces interface thinking
before implementation — downstream strive workers use this to verify
upstream outputs exist before starting.}

### {Phase/Section 1} → {Phase/Section 2}

**Produces:**
- `{file path}` → `{export name}` ({type}: function | interface | class | endpoint | config)

**Consumes:** nothing (leaf node)

### {Phase/Section 2} → {Phase/Section 3}

**Produces:**
- `{file path}` → `{export name}` ({type})

**Consumes from {Phase/Section 1}:**
- `{file path}` → `{import name}` ({verified by}: grep | import | test)

## Acceptance Criteria

- [ ] Functional requirement 1
- [ ] Functional requirement 2
- [ ] Testing requirement

### Task Verification Protocol

{Required for Standard and Comprehensive plans. Omit for Minimal.}
{Each task in the Acceptance Criteria section should include structured
must-haves that enable mechanical verification. Ward check validates
these during strive Phase 4.}

**Must-have format per task:**

- [ ] **Task description**
  - **Truths**: Observable behaviors that must be true when done
    - "{User can X}" or "{System does Y when Z}"
  - **Artifacts**: Files that must exist with real implementation
    - `{path}` — {description} (min {N} LOC, exports: {names})
  - **Key Links**: Import/wiring between artifacts
    - `{file A}` → `{file B}` via `import { name }`

## Non-Goals

{Explicitly out-of-scope items from brainstorm. Populate from `non_goals` frontmatter field.}
{(No brainstorm -- add manually if needed)}

- {item 1 -- why excluded}

## Success Criteria

{Measurable outcomes that determine whether this feature is successful. Distinct from Acceptance Criteria -- these measure business/user impact, not implementation completeness.}
{(No brainstorm -- add manually if needed)}

- {criterion 1 -- metric and target}

## Success Metrics

{How we measure success}

## Dependencies & Risks

{What could block or complicate this}

## Evidence Chain

{Populated during Phase 2 Synthesize. For each major claim in Proposed Solution and Technical Approach, record the evidence found in research outputs. Claims without evidence get Verified: No. evidence-verifier agent validates this table during Phase 4C.}

| # | Claim | Evidence Type | Source | Verified |
|---|-------|--------------|--------|----------|
| E-1 | "{factual claim from Proposed Solution}" | CODEBASE | {tool + query + result summary} | Yes/No |
| E-2 | "{factual claim from Technical Approach}" | DOCUMENTATION | {doc file + relevant section} | Yes/No |
| E-3 | "{dependency or API claim}" | EXTERNAL | {registry/docs URL} | Yes/No |

**Evidence types** (ordered by strength): CODEBASE (verified in source code) > DOCUMENTATION (verified in project docs) > EXTERNAL (verified via external sources) > OBSERVED (indirect evidence found) > NOVEL (new, with justification)

## Design Implementation (conditional — auto-generated when figma_url is detected)

{Omit this entire section when figma_url is empty or design_sync is false.}

- **Figma URL**: [{figma_url}]({figma_url})
- **Design sync**: enabled (design_sync: true in frontmatter)
- **Fidelity target**: {from talisman design_sync.fidelity_target or "0.85 (default)"}
- **Design references**: {design_references_path} (generated by design-pipeline-agent during Phase 0)
- **Design extraction**: Arc Phase 3 (design_extraction) will generate VSM/DCD artifacts
- **Fidelity review**: design-implementation-reviewer will score across 6 dimensions
- **Iteration**: Arc Phase 7.6 (design_iteration) for visual refinement loop

### Component Inventory

{Auto-populated from design-references/inventory.json during Phase 0. If design-prototype skill is installed, includes extraction paths and library match status. Otherwise "Pending — will be populated during arc design_extraction phase."}

| Component | Figma Node | Type | Extraction | Status |
|-----------|-----------|------|------------|--------|
| {component-name} | {node-id} | {frame/component/instance} | {extraction_path or "—"} | pending |

### Library Component Recommendations

{Auto-populated from design-references/match-report.json when UI builder MCP is available. Otherwise omit this subsection.}

| Component | Library Match | Confidence | Install Command |
|-----------|--------------|------------|-----------------|
| {component-name} | {matched library component or "No match"} | {High/Medium/Low} | {npm install command or "—"} |

### User Flow Map

{Auto-populated from design-references/flow-map.md when >= 2 components extracted. Otherwise omit this subsection.}

| Screen | Action | Target | Trigger | Feedback |
|--------|--------|--------|---------|----------|
| {screen-name} | {user action} | {destination screen} | {button/link/gesture} | {toast/redirect/modal} |

### Data State Requirements

{Inferred from design-references/prototypes/*/prototype.stories.tsx data state stories. Otherwise omit this subsection.}

| Component | Happy Path | Empty State | Loading State | Error State |
|-----------|-----------|-------------|---------------|-------------|
| {component-name} | {default render} | {empty message/illustration} | {spinner/skeleton} | {error message + retry} |

### Notification & Status Patterns

{Auto-populated from design-references/ux-patterns.md. Otherwise omit this subsection.}

- **Toast**: {which actions use toast? success/error patterns}
- **Modal**: {which actions require confirmation? destructive operations}
- **Inline validation**: {form validation approach — live/onBlur/onSubmit}
- **Loading indicators**: {spinner vs skeleton vs progress bar per context}

### Page Compositions

{Auto-populated from design-references/prototypes/ page-level outputs. Otherwise omit this subsection.}

| Page | Components Used | Key Interactions |
|------|----------------|------------------|
| {page-name} | {component1, component2, ...} | {primary action descriptions} |

### Design Reference Summary

{Auto-populated from design-references/SUMMARY.md — per-component visual intent + recommendation. Otherwise omit this subsection.}

### Token Snapshot

{Auto-populated from design-references/tokens-snapshot.json — colors, fonts, spacing. Otherwise omit this subsection.}

### Design References

- Design tokens: {from tokens-snapshot.json or "auto-detect from Figma"}
- Responsive breakpoints: {from brainstorm or "extract from Figma frames"}
- Accessibility target: {from brainstorm or "WCAG 2.1 AA"}

## Documentation Impact

Files that must be updated when this feature ships:

### Files Referencing This Feature
- [ ] {file}: {what reference needs updating}

### Count/Version Changes
- [ ] plugin.json: version bump to {target}
- [ ] CLAUDE.md: {count or version reference}
- [ ] README.md: {count or version reference}
- [ ] CHANGELOG.md: new entry for {version}

### Priority/Registry Updates
- [ ] {registry file}: add/update entry for {feature}

## Cross-File Consistency

Files that must stay in sync when this plan's changes are applied:

- [ ] Version: plugin.json, CLAUDE.md, README.md
- [ ] Counts: {list files where counts change}
- [ ] References: {list files that cross-reference each other}

## References

- Codebase patterns: {repo-surveyor findings}
- Past learnings: {echo-reader findings}
- Git history: {git-miner findings}
- Best practices: {practice-seeker findings, if run}
- Framework docs: {lore-scholar findings, if run}
- Cross-model research: {codex-researcher findings, if run}
- Spec analysis: {flow-seer findings}
```

## Comprehensive Template

```markdown
---
title: "{type}: {feature description}"
type: feat | fix | refactor
date: YYYY-MM-DD
version_target: "{estimated version}"
complexity: "{Low|Medium|High}"
scope: "{description of files affected}"
risk: "{Low|Medium|High} — {brief explanation}"
estimated_effort: "{S|M|L|XL} — ~{N} LOC, {N} files"
impact: "{N}/10"
strategic_intent: "long-term"  # Options: long-term | quick-win | auto
non_goals: []  # List of explicitly out-of-scope items (from brainstorm or manual entry)
git_sha: "{run: git rev-parse HEAD}"
branch: "{run: git branch --show-current}"
figma_url: ""          # Auto-populated when Figma URL detected in brainstorm (leave empty if none). MUST be double-quoted when populated: figma_url: "https://..."
figma_urls: []         # NEW — array of {url, role?, screen?}. role: auto|primary|variant (default: auto). screen: group label, null = auto-detect. Leave empty if none.
design_sync: false     # Set to true when figma_url is detected (enables design context in strive workers)
design_references_path: ""      # Auto-populated: path to design-references/ directory (e.g. "tmp/plans/{timestamp}/design-references/")
library_match_count: 0          # Number of components matched to UI library (from match-report.json)
ux_flow_mapped: false           # Whether flow-map.md was generated (>= 2 components)
page_compositions: 0            # Number of page-level prototypes generated
design_system_library: ""       # Auto-detected: "shadcn" | "untitled-ui" | "generic" | "" (non-frontend)
design_system_confidence: 0.0   # Detection confidence 0.0–1.0 (from discoverDesignSystem())
component_count_new: 0          # Number of CREATE-strategy components (from UI/UX protocol Step 3)
component_count_extend: 0       # Number of EXTEND-strategy components
component_count_reuse: 0        # Number of REUSE-strategy components
ui_builder:                     # Auto-populated by discoverUIBuilder() — omit when no builder detected
  builder_skill: ""             # Builder skill name (e.g. "untitledui-mcp" or project override)
  builder_mcp: ""               # MCP server name in .mcp.json (e.g. "untitledui")
  conventions: ""               # Path to conventions file (relative to skill dir)
  capabilities: {}              # Map of capability → tool name from builder-protocol frontmatter
session_budget:
  max_concurrent_agents: 8      # Cap on simultaneous teammates (applied silently); see sizing guide
---

# {Feature Title}

## Overview

{Executive summary}

## Problem Statement

{Detailed problem analysis with stakeholder impact}

## Proposed Solution

{Comprehensive solution design}

## Technical Approach

### Architecture

{Detailed technical design}

> Each implementation phase that includes pseudocode must follow the Plan Section Convention (Inputs/Outputs/Preconditions/Error handling before code blocks).

### Implementation Phases

#### Phase 1: {Foundation}

- Tasks and deliverables
- Success criteria
- Effort estimate: {S/M/L}

#### Phase 2: {Core Implementation}

- Tasks and deliverables
- Success criteria
- Effort estimate: {S/M/L}

#### Phase 3: {Polish & Hardening}

- Tasks and deliverables
- Success criteria
- Effort estimate: {S/M/L}

### Data Model Changes

{ERD mermaid diagram if applicable}

~~~mermaid
erDiagram
    ENTITY_A ||--o{ ENTITY_B : has
~~~

## Frontend Architecture (conditional — omit when no frontend stack detected by stacks)

{Omit this entire section when design_system_library is empty or stacks detects no frontend files.}

### Design System Profile

{Always emitted when frontend stack is detected. Populated from discoverDesignSystem() output and brainstorm UI/UX Decisions.}

| Property | Value |
|----------|-------|
| Library | {design_system_library — e.g. shadcn, untitled-ui, generic} |
| Token system | {CSS vars / Tailwind / Style Dictionary / none} |
| Variant system | {CVA / CSS classes / explicit map / none} |
| Accessibility layer | {Radix UI / React Aria / manual / none} |
| Tailwind version | {v3 / v4 / not used} |
| Class merge utility | {cn() / clsx / none} |
| Dark mode strategy | {CSS vars (.dark) / data-theme attr / media query / none} |
| Path convention | {src/components/ui/ / src/components/base/ / other} |
| Existing components | {component_count_reuse} reuse + {component_count_extend} extend + {component_count_new} new |

### Component Strategy (conditional — omit when ui_builder is absent)

{Omit this entire section when `ui_builder` frontmatter is empty. Only emit when discoverUIBuilder() returned a builder profile.}

**UI Builder**: {ui_builder.builder_skill} via {ui_builder.builder_mcp} MCP
**Capabilities**: {comma-separated list of capability names from ui_builder.capabilities}

#### Component Mapping

{Populated from builder search during devise Phase 1 — flow-seer + repo-surveyor search for UI elements and match against library.}
{If no search was performed, write "Pending — will be populated during arc Phase 1.5 Component Match."}

| UI Element | Library Component | Search Query | Confidence | Notes |
|------------|------------------|-------------|-----------|-------|
| {sidebar navigation} | {SidebarNav} | {search_components("sidebar navigation with icons")} | High | |
| {data table with pagination} | {Table + Pagination} | {search_components("data table pagination")} | Medium | PRO |
| {form with email field} | {FormField + Input} | {search_components("form email input")} | High | |

#### Conventions Summary

{Key conventions from ui_builder.conventions — pull 3-5 most critical rules. Full conventions in the builder skill reference.}

- {e.g. React Aria imports use Aria* prefix: `import { Button as AriaButton } from "react-aria-components"`}
- {e.g. Files MUST be kebab-case: date-picker.tsx not DatePicker.tsx}
- {e.g. Colors MUST be semantic: text-primary not text-gray-900}

### Component Hierarchy

{Emitted when component_count_new >= 1. Populated from UI/UX protocol Step 3 decomposition.}

| Component | Tier | Strategy | Base Component | File Path |
|-----------|------|----------|---------------|-----------|
| {ComponentName} | atom \| molecule \| organism \| page | REUSE \| EXTEND \| CREATE \| COMPOSE | {base or —} | {src/components/...} |

### Component Dependency Graph

{Emitted when component_count_new >= 1. Shows which components compose which.}

~~~mermaid
graph TD
    A[PageComponent] --> B[OrganismA]
    A --> C[OrganismB]
    B --> D[MoleculeX]
    B --> E[AtomY]
    D --> E
    D --> F[AtomZ]
~~~

### Design Token Constraints

{Emitted when component_count_new >= 1.}

**Allowed tokens** (from detected design system):

| Token | Value | Usage |
|-------|-------|-------|
| {--color-primary or bg-primary} | {CSS var or Tailwind class} | {usage description} |
| {--spacing-4 or p-4} | {value} | {usage description} |

**Forbidden patterns** (from design-system-rules.md):
- No hex/RGB literals — all colors via tokens
- No arbitrary px values — all spacing on the scale
- No inline styles with magic numbers

### Responsive Behavior

{Emitted when component_count_new >= 1. Per-component mobile/tablet/desktop strategy.}

| Component | Mobile (<640px) | Tablet (640–1024px) | Desktop (>1024px) |
|-----------|----------------|---------------------|-------------------|
| {Component} | {layout/behavior} | {layout/behavior} | {layout/behavior} |

### State Management Map

{Emitted when component_count_new >= 1. Per-component data source and state scope.}

| Component | Data Source | State Type | Mutation | Cache Strategy |
|-----------|------------|------------|---------|----------------|
| {Component} | {API endpoint or local} | server \| URL \| local \| global | {action} | {invalidation strategy} |

### Accessibility Matrix

{Emitted when component_count_new >= 1. Per-component WCAG 2.1 AA requirements.}

| Component | Semantic Element | ARIA Role / Attr | Keyboard Nav | Focus Management |
|-----------|-----------------|------------------|-------------|-----------------|
| {Component} | {button/dialog/nav/...} | {role= / aria-*} | {keys} | {trap / return / none} |

### Animation & Interaction Spec

{Emitted when component_count_new >= 1. Only include when interactions are non-trivial.}

| Component | Trigger | Animation | Duration | Easing |
|-----------|---------|-----------|---------|--------|
| {Component} | {hover/click/mount/unmount} | {fade/slide/scale/none} | {ms} | {ease-in-out/...} |

### User Flow

{Emitted when component_count_new >= 1. Mermaid flowchart of primary user journey.}

~~~mermaid
flowchart LR
    A([Start]) --> B[{Step 1}]
    B --> C{Decision?}
    C -- Yes --> D[{Step 2a}]
    C -- No --> E[{Step 2b}]
    D --> F([End])
    E --> F
~~~

## Solution Selection

### Arena Evaluation Matrix
{Full evaluation matrix from arena-matrix.md, if Arena ran}

### Alternative Approaches Considered
| Approach | Score | Top Concern | Why Not Selected |
|----------|-------|-------------|-----------------|
{Rejected arena solutions with scores and DA concerns}

## Boundary Map

{Required for Standard and Comprehensive plans. Omit for Minimal.}
{For each phase or major section in Technical Approach, specify what it
produces and what it consumes from upstream. Forces interface thinking
before implementation — downstream strive workers use this to verify
upstream outputs exist before starting.}

### {Phase/Section 1} → {Phase/Section 2}

**Produces:**
- `{file path}` → `{export name}` ({type}: function | interface | class | endpoint | config)

**Consumes:** nothing (leaf node)

### {Phase/Section 2} → {Phase/Section 3}

**Produces:**
- `{file path}` → `{export name}` ({type})

**Consumes from {Phase/Section 1}:**
- `{file path}` → `{import name}` ({verified by}: grep | import | test)

## Acceptance Criteria

### Functional Requirements

- [ ] Detailed functional criteria

### Non-Functional Requirements

- [ ] Performance targets
- [ ] Security requirements

### Quality Gates

- [ ] Test coverage requirements
- [ ] Documentation completeness

### Task Verification Protocol

{Required for Standard and Comprehensive plans. Omit for Minimal.}
{Each task in the Acceptance Criteria section should include structured
must-haves that enable mechanical verification. Ward check validates
these during strive Phase 4.}

**Must-have format per task:**

- [ ] **Task description**
  - **Truths**: Observable behaviors that must be true when done
    - "{User can X}" or "{System does Y when Z}"
  - **Artifacts**: Files that must exist with real implementation
    - `{path}` — {description} (min {N} LOC, exports: {names})
  - **Key Links**: Import/wiring between artifacts
    - `{file A}` → `{file B}` via `import { name }`

## Non-Goals

{Explicitly out-of-scope items from brainstorm. Populate from `non_goals` frontmatter field.}
{(No brainstorm -- add manually if needed)}

- {item 1 -- why excluded}
- {item 2 -- why excluded}

## Success Criteria

{Measurable outcomes that determine whether this feature is successful. Distinct from Acceptance Criteria -- these measure business/user impact, not implementation completeness.}
{(No brainstorm -- add manually if needed)}

- {criterion 1 -- metric and target}
- {criterion 2 -- metric and target}

## Success Metrics

{Detailed KPIs and measurement methods}

## Dependencies & Prerequisites

{Detailed dependency analysis}

## Risk Analysis & Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| {Risk 1} | H/M/L | H/M/L | {Strategy} |

## Evidence Chain

{Populated during Phase 2 Synthesize. For each major claim in Proposed Solution, Architecture, and Technical Approach, record the evidence found in research outputs. Claims without evidence get Verified: No. evidence-verifier agent validates this table during Phase 4C.}

| # | Claim | Evidence Type | Source | Verified |
|---|-------|--------------|--------|----------|
| E-1 | "{factual claim from Proposed Solution}" | CODEBASE | {tool + query + result summary} | Yes/No |
| E-2 | "{factual claim from Architecture}" | CODEBASE | {file path + relevant code} | Yes/No |
| E-3 | "{factual claim from Technical Approach}" | DOCUMENTATION | {doc file + relevant section} | Yes/No |
| E-4 | "{dependency or API claim}" | EXTERNAL | {registry/docs URL} | Yes/No |
| E-5 | "{pattern or convention claim}" | OBSERVED | {indirect evidence description} | Yes/No |

**Evidence types** (ordered by strength): CODEBASE (verified in source code) > DOCUMENTATION (verified in project docs) > EXTERNAL (verified via external sources) > OBSERVED (indirect evidence found) > NOVEL (new, with justification)

## Design Implementation (conditional — auto-generated when figma_url is detected)

{Omit this entire section when figma_url is empty or design_sync is false.}

- **Figma URL**: [{figma_url}]({figma_url})
- **Design sync**: enabled (design_sync: true in frontmatter)
- **Fidelity target**: {from talisman design_sync.fidelity_target or "0.85 (default)"}
- **Design references**: {design_references_path} (generated by design-pipeline-agent during Phase 0)
- **Design extraction**: Arc Phase 3 (design_extraction) will generate VSM/DCD artifacts
- **Fidelity review**: design-implementation-reviewer will score across 6 dimensions
- **Iteration**: Arc Phase 7.6 (design_iteration) for visual refinement loop

### Component Inventory

{Auto-populated from design-references/inventory.json during Phase 0. If design-prototype skill is installed, includes extraction paths and library match status. Otherwise "Pending — will be populated during arc design_extraction phase."}

| Component | Figma Node | Type | Extraction | Status |
|-----------|-----------|------|------------|--------|
| {component-name} | {node-id} | {frame/component/instance} | {extraction_path or "—"} | pending |

### Library Component Recommendations

{Auto-populated from design-references/match-report.json when UI builder MCP is available. Otherwise omit this subsection.}

| Component | Library Match | Confidence | Install Command |
|-----------|--------------|------------|-----------------|
| {component-name} | {matched library component or "No match"} | {High/Medium/Low} | {npm install command or "—"} |

### User Flow Map

{Auto-populated from design-references/flow-map.md when >= 2 components extracted. Otherwise omit this subsection.}

| Screen | Action | Target | Trigger | Feedback |
|--------|--------|--------|---------|----------|
| {screen-name} | {user action} | {destination screen} | {button/link/gesture} | {toast/redirect/modal} |

### Data State Requirements

{Inferred from design-references/prototypes/*/prototype.stories.tsx data state stories. Otherwise omit this subsection.}

| Component | Happy Path | Empty State | Loading State | Error State |
|-----------|-----------|-------------|---------------|-------------|
| {component-name} | {default render} | {empty message/illustration} | {spinner/skeleton} | {error message + retry} |

### Notification & Status Patterns

{Auto-populated from design-references/ux-patterns.md. Otherwise omit this subsection.}

- **Toast**: {which actions use toast? success/error patterns}
- **Modal**: {which actions require confirmation? destructive operations}
- **Inline validation**: {form validation approach — live/onBlur/onSubmit}
- **Loading indicators**: {spinner vs skeleton vs progress bar per context}

### Page Compositions

{Auto-populated from design-references/prototypes/ page-level outputs. Otherwise omit this subsection.}

| Page | Components Used | Key Interactions |
|------|----------------|------------------|
| {page-name} | {component1, component2, ...} | {primary action descriptions} |

### Design Reference Summary

{Auto-populated from design-references/SUMMARY.md — per-component visual intent + recommendation. Otherwise omit this subsection.}

### Token Snapshot

{Auto-populated from design-references/tokens-snapshot.json — colors, fonts, spacing. Otherwise omit this subsection.}

### Design References

- Design tokens: {from tokens-snapshot.json or "auto-detect from Figma"}
- Responsive breakpoints: {from brainstorm or "extract from Figma frames"}
- Accessibility target: {from brainstorm or "WCAG 2.1 AA"}

## Cross-File Consistency

Files that must stay in sync when this plan's changes are applied:

### Version Strings
- [ ] plugin.json `version` field
- [ ] CLAUDE.md version reference
- [ ] README.md version badge / header

### Counts & Registries
- [ ] {list files where counts change}
- [ ] {list registry files that enumerate items}

### Cross-References
- [ ] {list files that reference each other}
- [ ] {list docs that cite the same source of truth}

### Talisman Sync
- [ ] talisman.example.yml reflects any new config fields
- [ ] CLAUDE.md configuration section matches talisman schema

## Documentation Impact & Plan

Files that must be updated when this feature ships:

### Files Referencing This Feature
- [ ] {file}: {what reference needs updating}

### Count/Version Changes
- [ ] plugin.json: version bump to {target}
- [ ] CLAUDE.md: {count or version reference}
- [ ] README.md: {count or version reference}
- [ ] CHANGELOG.md: new entry for {version}

### Priority/Registry Updates
- [ ] {registry file}: add/update entry for {feature}

### New Documentation
- [ ] {new doc file}: {purpose}

### Updated Documentation
- [ ] {existing doc}: {what changes}

### Inline Comments / Migration Guides
- [ ] {migration guide or inline comment updates}

## AI-Era Considerations (optional)

- AI tools used during research: {list tools and what they found}
- Prompts/patterns that worked well: {any useful prompt patterns}
- Areas needing human review: {sections that require domain expertise validation}
- Testing emphasis: {areas where AI-accelerated implementation needs extra testing}

## References

### Internal

- Architecture: {file_path:line_number}
- Similar features: {file_path:line_number}
- Past learnings: {echo findings}

### External

- Framework docs: {urls}
- Best practices: {urls}

### Related Work

- PRs: #{numbers}
- Issues: #{numbers}
```

## Hierarchical Plan Frontmatter

Used when a plan has been decomposed into parent + children via Phase 2.5 "Hierarchical" option.

### Parent Plan Additional Fields

Add these fields to the Standard or Comprehensive frontmatter after hierarchical generation completes:

```yaml
---
# ... standard frontmatter fields ...
hierarchical: true                          # Marks this as a parent of child plans
children_dir: "plans/children/"            # Relative path to child plans directory
---
```

### Child Plan Frontmatter Template

Each child plan generated in `plans/children/` uses this frontmatter:

```yaml
---
title: "{type}: {phase name} (child {N}/{total})"
type: feat | fix | refactor                 # Inherited from parent plan
date: YYYY-MM-DD
parent: "plans/YYYY-MM-DD-{type}-{name}-plan.md"   # Relative path to parent plan
sequence: {N}                               # 1-indexed position in execution order
depends_on:                                 # Child plan paths this must wait for (empty = can start immediately)
  - "plans/children/YYYY-MM-DD-{type}-{name}-child-1-{phase}-plan.md"
requires:                                   # Artifacts needed from prior children
  - type: file                              # file | export | type | endpoint | migration
    name: "src/models/User.ts"
  - type: export
    name: "UserDTO"
  - type: endpoint
    name: "GET /api/users"
provides:                                   # Artifacts produced by this child (consumed by later children)
  - type: file
    name: "src/services/UserService.ts"
  - type: export
    name: "UserService"
status: pending                             # pending | in-progress | completed | partial | failed | skipped
branch_suffix: "child-{N}-{phase-slug}"    # Appended to feature branch: feature/{id}/{branch_suffix}
---
```

### Parent Execution Table Template

Injected into the parent plan before the References section after hierarchical generation:

```markdown
## Child Execution Table

| # | Child Plan | Status | Depends On | Branch |
|---|-----------|--------|------------|--------|
| 1 | [Foundation](plans/children/...-child-1-foundation-plan.md) | pending | — | feature/{id}/child-1-foundation |
| 2 | [Core Implementation](plans/children/...-child-2-core-plan.md) | pending | child-1 | feature/{id}/child-2-core |
| 3 | [Polish & Hardening](plans/children/...-child-3-polish-plan.md) | pending | child-2 | feature/{id}/child-3-polish |

## Dependency Contract Matrix

| Child | Requires | Provides |
|-------|---------|---------|
| Foundation | — | file:src/models/User.ts, export:UserDTO |
| Core Implementation | file:src/models/User.ts, export:UserDTO | file:src/services/UserService.ts, export:UserService, endpoint:GET /api/users |
| Polish & Hardening | export:UserService, endpoint:GET /api/users | — |
```

### Artifact Type Reference

| Type | Description | Example |
|------|-------------|---------|
| `file` | A source file produced by a child | `src/models/User.ts` |
| `export` | A named export (class, interface, function, constant) | `UserDTO`, `createUser` |
| `type` | A TypeScript/Flow type definition | `UserRecord` |
| `endpoint` | An HTTP API endpoint | `POST /api/users` |
| `migration` | A database migration file | `20240201_create_users` |

### Status Values for Child Plans

| Status | Meaning |
|--------|---------|
| `pending` | Not started — waiting for prerequisites |
| `in-progress` | Currently running in arc-hierarchy |
| `completed` | Successfully finished with all acceptance criteria met |
| `partial` | Finished but some tasks failed or were skipped |
| `failed` | Arc run failed — may need manual intervention |
| `skipped` | Deliberately excluded from this run |

## How to Fill New Header Fields

During Phase 2 Synthesize, after consolidating research:

1. **version_target**: Read current version from `plugins/rune/.claude-plugin/plugin.json`. For `type: feat`, bump minor. For `type: fix`, bump patch. Label as "estimated" since implementation may reveal scope changes.

2. **complexity**: Score based on task count (>=8 = High), file count (>=6 = High), cross-cutting concerns.

3. **scope** (Standard/Comprehensive only): Human-readable description of files affected. Format: "{N} files ({description})".

4. **risk** (Standard/Comprehensive only): Assess from research findings. Format: "{Low|Medium|High} — {brief explanation}". Note: The risk value includes quotes in YAML (see templates) — preserve them when filling.

**Size guide for `estimated_effort`:**

| Size | LOC Range | File Count | Examples |
|------|-----------|------------|----------|
| S    | < 200     | 1-2        | Bug fixes, minor refactors |
| M    | 200-800   | 2-4        | Feature additions, medium refactors |
| L    | 800-2000  | 4-8        | New subsystems, major features |
| XL   | > 2000    | 8+         | Architectural changes, multi-phase features |

5. **estimated_effort**: Size from scope + complexity. Format: "{S|M|L|XL} — ~{N} LOC, {N} files". Use the size guide table above.

6. **impact**: Score 1-10. Anchor points: 1 = cosmetic, 5 = useful improvement, 10 = critical blocker.

7. **strategic_intent**: Declare the plan's strategic intent. Options: `"long-term"` (default — build correctly, minimize future debt), `"quick-win"` (ship fast, accept trade-offs), `"auto"` (let horizon-sage infer from type + complexity + scope). When in doubt, leave as `"long-term"`.

8. **session_budget** (optional): Cap on simultaneous agent teammates spawned during `strive`/`arc` execution. Set `max_concurrent_agents` based on plan effort using the sizing guide below. The cap is applied silently — workers respect it without surfacing it to the user.

```yaml
session_budget:
  max_concurrent_agents: 8       # Cap on simultaneous teammates (applied silently)
```

**Sizing guide for `max_concurrent_agents`:**

| Plan Effort | max_concurrent_agents |
|-------------|----------------------|
| S (<200 LOC) | 3 |
| M (200-800 LOC) | 5 |
| L (800-2000 LOC) | 8 |
| XL (>2000 LOC) | 12 (with shatter, per shard) |

## Formatting Best Practices

- Use collapsible `<details>` sections for lengthy logs or optional context
- Add syntax-highlighted code blocks with file path references: `app/services/foo.rb:42`
- Cross-reference related issues with `#number`, commits with SHA hashes
- For model changes, include ERD mermaid diagrams
- Code examples in plans are illustrative pseudocode. Sections with pseudocode include contract headers (Inputs/Outputs/Preconditions/Error handling) per the Plan Section Convention below

## Plan Section Convention -- Contracts Before Code

When a plan section includes pseudocode (JavaScript/Bash code blocks), include contract headers BEFORE the code block.

**Required structure for sections with pseudocode:**

```
## Section Name

**Inputs**: List all variables this section consumes (name, type, where defined)
**Outputs**: What this section produces (artifacts, state changes, return values)
**Preconditions**: What must be true before this section runs
**Error handling**: How failures are handled (for each Bash/external call)

```javascript
// Pseudocode -- illustrative only
// All variables must appear in Inputs list above (or be defined in this block)
// All Bash() calls must have error handling described above
```
```

**Rules for pseudocode in plans:**
1. Every variable used in a code block must either appear in the **Inputs** list or be defined within the block
2. Every `Bash()` call must have a corresponding entry in **Error handling**
3. Every helper function called (e.g., `extractPlanTitle()`) must either be defined in the plan or listed as "defined by worker" in **Inputs**
4. Pseudocode is *illustrative* -- workers implement from the contract (Inputs/Outputs/Preconditions), using pseudocode as guidance

**Example (good):**

```
## Phase 6.5: Ship

**Inputs**: currentBranch (string, from Phase 0.5), defaultBranch (string, from Phase 0.5),
planPath (string, from Phase 0), completedTasks (Task[], from TaskList before TeamDelete),
wardResults ({name, exitCode}[], from Phase 4)
**Outputs**: PR URL (string) or skip message; branch pushed to origin
**Preconditions**: On feature branch (not default), gh CLI authenticated
**Error handling**: git push failure -> warn + manual command; gh pr create failure -> warn (branch already pushed)

```javascript
// Validate branch before shell interpolation
// Push branch with error check
// Generate PR title from plan frontmatter (sanitize for shell safety)
// Build PR body from completedTasks + wardResults + diffStat
// Write body to file (not -m flag), create PR via gh CLI
```
```

**Example (bad -- causes bugs):**

```
## Phase 6.5: Ship

```javascript
const planTitle = extractPlanTitle(planPath)  // <- undefined function
const prTitle = `${planType}: ${planTitle}`    // <- planType undefined
Bash(`git push -u origin "${currentBranch}"`)  // <- no error handling
```

### Existing Issues Convention

Plans MUST include an "## Existing Issues" section BEFORE new feature sections when Phase 0.8 discovered issues. Format:

| Priority | Issue | Location | Impact | Root Cause Chain |
|----------|-------|----------|--------|------------------|
| Must Fix | [description] | [file:line] | [what breaks] | [A → B → C chain] |
| Should Fix | [description] | [file:line] | [risk level] | [dependency path] |
| Acknowledged | [description] | [file:line] | [deferred reason] | — |

Per-task annotations: prerequisite fixes, risk areas, test gaps.

5. Write to `plans/YYYY-MM-DD-{type}-{feature-name}-plan.md`

6. **Comprehensive only -- Second SpecFlow pass**: If detail level is Comprehensive, re-run flow-seer on the drafted plan (not just the raw spec from Phase 1D). Write to `tmp/plans/{timestamp}/research/specflow-post-draft.md`. Tarnished appends findings to the plan before scroll-reviewer runs.
