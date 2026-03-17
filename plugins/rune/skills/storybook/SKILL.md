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

- **Arc Phase 3.2**: Design prototype phase — generates React prototypes from Figma + UI builder, bootstraps `tmp/storybook/`
- **Arc Phase 3.3**: Storybook verification phase (after work, before design verification)
- **Design Prototype Phase 4.5**: Standalone `/rune:design-prototype` — auto-bootstraps `tmp/storybook/`, copies prototypes, launches preview
- **Shared runtime**: `tmp/storybook/` — ephemeral Storybook environment used by design-prototype, arc Phase 3.2, and arc Phase 3.3. Bootstrapped via `scripts/storybook/bootstrap.sh`
- **Talisman config**: `storybook.enabled`, `storybook.port`, `storybook.max_rounds`
- **Agents**: `storybook-reviewer` (read-only) + `storybook-fixer` (write-capable)
- **agent-browser**: Used for screenshot capture and DOM snapshot analysis

### Bootstrap Script (`scripts/storybook/bootstrap.sh`)

Shared entry point for all Storybook operations. Idempotent — only scaffolds once.

```bash
# Design prototype: copy prototype directories
bootstrap.sh --src-dir tmp/design-prototype/{ts}/prototypes

# Arc storybook verification: copy individual story files
bootstrap.sh --story-files src/Button.stories.tsx src/Card.stories.tsx

# Scaffold only (no files)
bootstrap.sh
```

Returns JSON: `{ storybook_dir, full_page_component, server_running, ready }`

## Discipline Integration

When discipline engineering is enabled (`discipline.enabled` in talisman), Phase 3.3 (Storybook Verification) runs design-specific proofs via `execute-discipline-proofs.sh` for each verified component:

| Proof Type | What It Checks | Graceful Degradation |
|------------|---------------|---------------------|
| `storybook_renders` | Storybook build smoke test passes | INCONCLUSIVE (F4) if Storybook not installed |
| `axe_passes` | axe-core accessibility scan (WCAG AA) | INCONCLUSIVE (F4) if axe-core unavailable |
| `story_exists` | Story file + variant exports exist | FAIL (F3) if missing |
| `token_scan` | No hardcoded hex colors in component | FAIL (F3) if violations found |

Evidence artifacts are written to `tmp/arc/{id}/storybook-verification/storybook-verification.json` with per-check results. Gate behavior is non-blocking by default (WARN on failures). Configure `discipline.design.block_on_fail: true` in talisman to block the pipeline on design proof failures.
