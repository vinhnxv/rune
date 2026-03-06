# Phase 0.3 UX Research + Phase 0.5 Design System + MCP Discovery

## Phase 0.3: UX Research (conditional)

Spawns `ux-pattern-analyzer` to assess current UX maturity when `ux.enabled` is true and frontend files are detected. Runs AFTER Design System Discovery (Phase 0.5), BEFORE Phase 1 Research. Zero cost when UX is disabled or no frontend files exist.

Integrates with the existing [ui-ux-planning-protocol.md](ui-ux-planning-protocol.md) — the protocol's Step 0 (UX Process Selection) gates greenfield/brownfield routing. This phase adds codebase-level UX pattern analysis to complement that routing.

```javascript
// Phase 0.3: UX Pattern Analysis
const uxConfig = readTalismanSection("ux")
const uxEnabled = uxConfig?.enabled === true
const hasFrontendFiles = Glob("src/components/**/*.{tsx,jsx}").length > 0
  || Glob("components/**/*.{tsx,jsx}").length > 0
  || Glob("app/**/*.{tsx,jsx}").length > 10

if (uxEnabled && hasFrontendFiles) {
  // Spawn ux-pattern-analyzer (utility agent) to inventory existing UX patterns
  // Output: structured UX maturity assessment (7 pattern categories, 4-level scale)
  // Spawned with team_name from Phase -1 team creation
  Agent({
    name: "ux-pattern-analyzer",
    team_name: `rune-plan-${timestamp}`,
    prompt: `Analyze the codebase for UX pattern usage and maturity.
      Scan frontend files for: loading patterns, error handling, form validation,
      navigation, empty states, confirmation/undo, and feedback patterns.
      Send your analysis via SendMessage to the Tarnished.`,
    subagent_type: "general-purpose"
  })

  // Store UX context for Phase 2 synthesis
  brainstormContext.ux_maturity = {
    analyzed: true,
    process: brainstormContext.ux_process?.type ?? null,  // from ui-ux-planning-protocol Step 0
    cognitive_walkthrough: uxConfig.cognitive_walkthrough === true,
  }
} else {
  brainstormContext.ux_maturity = { analyzed: false }
}
```

**Skip conditions**: `talisman.ux.enabled` is not `true`, or no frontend files detected.

**Output**: `brainstormContext.ux_maturity` — consumed by Phase 2 (Synthesize) to enrich the plan with UX pattern recommendations. When `ux_maturity.analyzed` is true, the synthesizer includes a "UX Considerations" section in the plan output.

## Phase 0.5: Design System & Builder Discovery

Runs design system and UI builder discovery after Figma URL detection, before Phase 1.
Zero cost when no design system or builder is detected.

See [design-system-discovery/SKILL.md](../../design-system-discovery/SKILL.md) for the full algorithms.

```javascript
// Phase 0.5: Discover design system and UI builder
// discoverDesignSystem() and discoverUIBuilder() run in ui-ux-planning-protocol.md Step 1
// when design_sync_candidate === true or frontend stack is detected.

// When uiBuilder is found, load its companion skill for research context
if (brainstormContext.ui_builder?.builder_skill) {
  loadedSkills.push(brainstormContext.ui_builder.builder_skill)
  // e.g., loads untitledui-mcp skill for conventions and builder protocol knowledge
}
```

## MCP Integration Discovery (Phase 0, conditional)

Resolve active MCP integrations for the `devise` phase. Zero cost when no integrations configured.

See `strive/references/mcp-integration.md` for the shared resolver algorithm.

```javascript
// After Figma URL detection, before Phase 1
const mcpIntegrations = resolveMCPIntegrations("devise", {
  changedFiles: [],  // No changed files during planning
  taskDescription: userDescription
})

// If active integrations found:
// - Load companion skills for research context
const mcpSkills = loadMCPSkillBindings(mcpIntegrations)
if (mcpSkills.length > 0) loadedSkills.push(...mcpSkills)

// - Build context block for research agent prompts
const mcpContextBlock = buildMCPContextBlock(mcpIntegrations)
// Passed to Phase 1 research agents and Phase 2 synthesis
```

## MCP Tool Context in Research Agents (Phase 1)

When `mcpIntegrations.length > 0`, append to research agent spawn prompts:
- **practice-seeker**: Include MCP tool names in "available tools" for best-practice research
- **lore-scholar**: Include MCP metadata (library_name, version) for framework-specific documentation lookup
- **repo-surveyor**: Include integration config awareness to discover talisman.yml patterns

```javascript
// Append to research agent prompt when MCP active
if (mcpContextBlock) {
  researchPrompt += mcpContextBlock
}
```

## MCP Integration Context in Synthesis (Phase 2)

When active MCP integrations are available, include in the synthesis prompt:
- Available MCP tools with categories (for "Implementation Context" section)
- Companion skill references (for "Dependencies" section)
- Library metadata (for external resource references)

```javascript
// Inject into synthesis agent prompt
if (mcpContextBlock) {
  synthesisPrompt += `\n## Available MCP Tool Integrations\n${mcpContextBlock}`
}
```
