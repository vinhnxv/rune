---
name: storybook
description: |
  Storybook integration knowledge for component verification.
  Teaches agents how to use Storybook MCP tools, CSF3 story format,
  story generation patterns, and visual verification workflows.
  Trigger keywords: storybook, stories, CSF3, component preview,
  visual verification, story coverage, addon-mcp.
user-invocable: false
disable-model-invocation: false
---

# Storybook Integration — Component Verification Knowledge

Provides agents with knowledge about Storybook component verification workflows,
CSF3 story format conventions, MCP tool usage, and visual quality heuristics.

## Storybook MCP Tools

When `@storybook/addon-mcp` is installed in the project, agents can use these MCP tools:

| Tool | Purpose | Notes |
|------|---------|-------|
| `get_ui_building_instructions` | CSF3 conventions and story linking guidelines | Call first for context |
| `preview-stories` | Get direct story URLs by path or component ID | Returns navigable URLs |
| `list-all-documentation` | Component and docs inventory | Experimental, React-only |
| `get-documentation` | Full component docs with prop types, JSDoc, examples | Per-component detail |

**MCP availability check**: Before calling Storybook MCP tools, verify the server is accessible.
MCP tools will fail with connection errors if the Storybook server is not running or addon-mcp
is not configured. The phase reference file handles server health checks.

For detailed tool documentation, see [mcp-tools.md](references/mcp-tools.md).

## CSF3 Story Format

Stories use Component Story Format 3 (CSF3) — the standard since Storybook 7+.

Key conventions:
- Default export = component meta (title, component, args, decorators)
- Named exports = individual stories
- Stories are objects with `args`, not render functions (unless complex composition needed)
- Use `satisfies Meta<typeof Component>` for TypeScript type checking

For the complete CSF3 authoring guide, see [csf3-format.md](references/csf3-format.md).

## Story Generation

When generating stories for components:

1. **Read the component first** — understand props, variants, states
2. **Match existing patterns** — check for `.stories.tsx` siblings
3. **Cover all states** — default, loading, error, empty, disabled
4. **Use realistic mock data** — not lorem ipsum
5. **Test responsive** — add viewport decorators for mobile/tablet/desktop

Framework-specific templates: [story-templates.md](references/story-templates.md).

## Visual Quality Checks (Mode B)

When no Figma/VSM spec exists, use heuristic checks to catch common UI issues:

| Category | What to Check |
|----------|--------------|
| Rendering | No blank areas, no error boundaries triggered |
| Text | No overlap, no clipping, readable contrast |
| Layout | Consistent spacing, correct flex/grid behavior |
| Responsive | No horizontal scroll at mobile, touch targets >= 44px |
| States | Loading, error, empty, disabled all render correctly |
| Accessibility | Focus indicators visible, ARIA labels present |

Full heuristic checklist: [visual-checks.md](references/visual-checks.md).

## Two Verification Modes

### Mode A: Design Fidelity (requires VSM from Figma extraction)

Compares rendered component against Visual Spec Map (VSM):
- Token compliance (colors, spacing, typography match design tokens)
- Layout structure (flex direction, grid areas, alignment)
- Variant coverage (all design variants have matching stories)
- Responsive behavior (breakpoints match design spec)
- Accessibility (matches design-specified a11y requirements)

### Mode B: UI Quality Audit (no Figma required)

Heuristic-based quality checks:
- Render integrity (no blank/error screens)
- Visual correctness (text readable, elements visible, spacing uniform)
- Responsive behavior (mobile/tablet/desktop work)
- State coverage (loading/error/empty/disabled)
- Accessibility basics (contrast, focus, ARIA)

## Integration Points

- **Arc Phase 3.3**: Storybook verification phase (after work, before design verification)
- **Talisman config**: `storybook.enabled`, `storybook.port`, `storybook.max_rounds`
- **Agents**: `storybook-reviewer` (read-only) + `storybook-fixer` (write-capable)
- **agent-browser**: Used for screenshot capture and DOM snapshot analysis
