# Phase 0: Gather Input (Brainstorm)

This phase delegates to the brainstorm skill protocol defined in `skills/brainstorm/SKILL.md`. All brainstorm logic (auto-detection, Roundtable Advisors, elicitation sages, decision capture, quality gate) lives there.

## When `--brainstorm-context` is provided

Skip brainstorm entirely. Read existing workspace for rich research context:

```javascript
const workspacePath = brainstormContextFlag // e.g., "tmp/brainstorm-1709482222000"

// Read workspace metadata
const meta = JSON.parse(Read(`${workspacePath}/workspace-meta.json`))

// Determine confidence level from quality score
const highConfidence = (meta.quality?.score ?? 0) >= 0.70

// Inject advisor research into Phase 1 research agents:
// - repo-surveyor gets: patterns-found.md + approach context
// - echo-reader gets: feature keyword for echo search
// - git-miner gets: related-files.md for churn focus

const advisorResearch = Read(`${workspacePath}/advisors/tech-realist.md`)
const patternsFound = Read(`${workspacePath}/research/patterns-found.md`)
const riskSignals = Read(`${workspacePath}/research/risk-signals.md`)
const brainstormDecisions = Read(`${workspacePath}/brainstorm-decisions.md`)

// Extract design URLs from brainstorm workspace metadata
// Validate design_urls is actually an array (defensive against schema mismatch)
const designUrlsFromBrainstorm = Array.isArray(meta.design_urls) ? meta.design_urls : []
const designUrlPrimary = meta.design_url_primary || null

if (designUrlsFromBrainstorm.length > 0 && !designAware) {
  // Brainstorm detected Figma URLs that weren't in the initial user description
  figmaUrls = designUrlsFromBrainstorm
  figmaUrl = designUrlPrimary || designUrlsFromBrainstorm[0]
  designAware = true
  design_sync_candidate = true
  log(`Devise Phase 0: Recovered ${designUrlsFromBrainstorm.length} Figma URL(s) from brainstorm workspace.`)

  // Also load design-related skills
  loadedSkills.push('design-sync')
  loadedSkills.push('frontend-design-patterns')
}

// Also copy decisions to legacy location for pipeline compatibility
Write(`tmp/plans/${timestamp}/brainstorm-decisions.md`, brainstormDecisions)

// Add brainstorm references to plan frontmatter (Phase 2)
// brainstorm_ref: meta.output_path (docs/brainstorms/... path)
// brainstorm_workspace: workspacePath
// Pre-populate Non-Goals, Success Criteria, Scope Boundary from brainstorm

// If not high-confidence: flag as "exploratory" in research context
// Research agents should validate assumptions rather than trust them
```

## When `--quick` is provided

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

## Default (Brainstorm Delegation)

Follow the brainstorm protocol from `skills/brainstorm/SKILL.md` with these devise-specific overrides:

1. **Team reuse**: Advisors join the existing `rune-plan-{timestamp}` team created in Phase -1, NOT a separate `rune-brainstorm-{timestamp}` team. Skip TeamCreate/TeamDelete in brainstorm — devise owns the team lifecycle.

2. **Workspace co-location**: Brainstorm workspace is created at `tmp/brainstorm-{timestamp}/` alongside the plan workspace at `tmp/plans/{timestamp}/`. Both share the same timestamp.

3. **Legacy output location**: In addition to the brainstorm workspace, ALSO write decisions to `tmp/plans/{timestamp}/brainstorm-decisions.md` for pipeline compatibility with Phase 1 research agents and Phase 2 synthesize.

4. **Persistent output**: Write persistent copy to `docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md` (same as standalone mode).

5. **Skip handoff**: Do NOT run brainstorm Phase 6 handoff (AskUserQuestion with next steps). Devise continues to Phase 1 research automatically after decisions are captured.

6. **Mid-pipeline advisor cleanup**: After brainstorm decisions are captured and before Phase 1 starts, shutdown brainstorm-specific teammates that are no longer needed. They joined the `rune-plan-{timestamp}` team but have no role in subsequent phases.

```javascript
// Shutdown brainstorm advisors + sages (they're done — no role in Phase 1+)
const brainstormMembers = [
  "user-advocate", "tech-realist", "devils-advocate",
  "elicitation-sage-1", "elicitation-sage-2", "elicitation-sage-3"
]
for (const member of brainstormMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Brainstorm complete — devise continuing to research" })
}
// Brief grace period for deregistration (shorter than full cleanup — no TeamDelete needed)
Bash("sleep 10", { run_in_background: true })
```

7. **Quality gate influences research**: If brainstorm quality score < 0.70, Phase 1 research agents should treat brainstorm decisions as "exploratory" and validate assumptions independently.

### Design Asset Detection

Design Signal Detection (Figma URLs and design keywords) runs during brainstorm Phase 3.5. Results flow through to devise:
- `designAware`, `figmaUrls` (full array), and `figmaUrl` (first entry, backward compat) are set based on brainstorm output
- The brainstorm context object stores `design_urls: figmaUrls` — the full URL array, not just the first match
- If detected, `design-sync` and `frontend-design-patterns` skills are loaded
- Design Inventory Agent spawning (in devise SKILL.md Phase 0 post-step) iterates `figmaUrls` for multi-file component inventory

### Elicitation Sages

Elicitation sages in devise brainstorm join `rune-plan-{timestamp}` team (not the brainstorm team). The sage spawning protocol from `brainstorm/SKILL.md` Phase 4 is followed with the team name override.

### UI/UX Investigation

When brainstorm detects frontend keywords or design systems, it runs the UI/UX investigation protocol. Results are captured in `brainstorm-decisions.md` under "## UI/UX Decisions" and consumed by:
- Phase 2 (Synthesize) for Frontend Architecture sections
- Phase 4 (Strive workers) for design system profile injection

See [ui-ux-planning-protocol.md](ui-ux-planning-protocol.md) for the full 7-step protocol.

## When `--no-brainstorm` is provided

Skip Phase 0 entirely. No brainstorm, no workspace. Proceed directly to Phase 1.
Feature description comes from the user prompt arguments.
