---
name: untitledui-mcp
description: |
  UntitledUI official MCP integration for Rune workflows. Provides 6 MCP tools
  for searching, browsing, and installing UntitledUI React components (free + PRO).
  Includes code conventions (React Aria, Tailwind v4.1, semantic colors, kebab-case),
  component patterns, and builder protocol metadata for automated pipeline integration.
  Use when agents build UI with UntitledUI components, when design-sync resolves
  components against UntitledUI library, or when workers need UntitledUI conventions.
  Trigger keywords: untitledui, untitled ui, untitled-ui, UntitledUI PRO,
  react aria, component library, ui builder, mcp component search.
user-invocable: false
disable-model-invocation: false
builder-protocol:
  library: untitled_ui
  mcp_server: untitledui
  capabilities:
    search: search_components
    list: list_components
    details: get_component
    bundle: get_component_bundle
    templates: get_page_templates
    template_files: get_page_template_files
  conventions: references/agent-conventions.md
---

# UntitledUI Official MCP Integration

UntitledUI provides an official MCP server with 6 tools for AI-assisted component development.
This skill provides background knowledge for Rune agents working with UntitledUI components.

## Prerequisites

- MCP server configured in `.mcp.json` with server name `untitledui`
- For PRO components: `UNTITLEDUI_ACCESS_TOKEN` env var OR OAuth authentication
- For free components: no authentication required

**Setup** (Claude Code):
```bash
# Free + OAuth (recommended — auto-handles login flow):
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp

# PRO with API key (set UNTITLEDUI_ACCESS_TOKEN in your shell profile):
export UNTITLEDUI_ACCESS_TOKEN="your-api-key-here"
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp \
  --header "Authorization: Bearer $UNTITLEDUI_ACCESS_TOKEN"
```

**Access detection**: When `UNTITLEDUI_ACCESS_TOKEN` is set, agents have PRO access
(all components, page templates). Without it, agents use free tier (base components only)
or fall back to Tailwind + conventions. See [agent-conventions.md](references/agent-conventions.md)
for the full tier behavior matrix.

## MCP Tools (6)

### Search & Discovery

#### `search_components`
Natural language component search. Primary tool for finding components by functionality.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | Yes | Natural language search (e.g., "sidebar navigation with icons") |
| `category_filter` | string | No | Filter: base, application, marketing, foundations, shared-assets, examples |
| `limit` | number | No | Max results (default: 20) |
| `key` | string | No | API key (alternative to OAuth) |

**When to use**: First step when implementing any UI component. Search before building from scratch.

**Search tips**:
- Use descriptive queries: "file upload with drag and drop" > "upload"
- Include context: "pricing table with toggle" > "table"
- Specify domain: "settings page sidebar" > "sidebar"

#### `list_components`
Browse components by category. Use when exploring available components or building a full page.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `category` | string | No | base, application, marketing, foundations, shared-assets, examples |
| `skip` | number | No | Pagination offset |
| `limit` | number | No | Results per page |
| `key` | string | No | API key |

**Categories**:
- `base` — Core UI: Button, Input, Select, Checkbox, Badge, Avatar, Toggle, etc.
- `application` — Complex: DatePicker, Modal, Table, Tabs, Pagination, etc.
- `marketing` — Landing pages, CTAs, testimonials, pricing, features, etc.
- `foundations` — Design tokens, icons, logos, FeaturedIcon
- `shared-assets` — Login, signup, 404, error pages (PRO)
- `examples` — Complete page examples (PRO)

### Installation

#### `get_component`
Install a single component with its full source code.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | Yes | Component name to install |
| key | string | No | API key for PRO components |

**Returns**: Full component source code, imports, dependencies, and usage examples.

#### `get_component_bundle`
Install multiple components simultaneously. Use for page-level implementations.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| names | string[] | Yes | Array of component names |
| key | string | No | API key for PRO components |

### Templates (PRO Only)

#### `get_page_templates`
Browse available page templates. Requires PRO subscription.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| key | string | No | API key |

**Templates include**: Dashboard layouts, settings pages, auth flows, landing pages, etc.

#### `get_page_template_files`
Install a complete page template with all component files. Requires PRO subscription.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| template | string | Yes | Template identifier |
| key | string | No | API key |

## Free vs PRO Feature Matrix

| Feature | Free | PRO |
|---------|------|-----|
| `search_components` | All categories | All categories |
| `list_components` | All categories | All categories |
| `get_component` (base) | Yes | Yes |
| `get_component` (application) | Partial | Yes |
| `get_component` (marketing) | No | Yes |
| `get_component_bundle` | Free components only | All components |
| `get_page_templates` | No | Yes |
| `get_page_template_files` | No | Yes |
| Shared assets (login, 404) | No | Yes |

**Rune behavior**: Workers always attempt search/list (free). If `get_component` fails with auth error on a PRO component, worker falls back to building from scratch with Tailwind + conventions from this skill.

## Core Conventions (Quick Reference)

These conventions are injected into worker prompts when UntitledUI is the active builder.
For the complete reference, see [agent-conventions.md](references/agent-conventions.md).

### Critical Rules

1. **React Aria imports MUST use `Aria*` prefix**:
   ```typescript
   // CORRECT
   import { Button as AriaButton } from "react-aria-components";
   // WRONG
   import { Button } from "react-aria-components";
   ```

2. **Files MUST be kebab-case**:
   ```
   date-picker.tsx    // correct
   DatePicker.tsx     // wrong
   ```

3. **Icons MUST include `data-icon` when passed as JSX**:
   ```typescript
   // As reference (preferred)
   <Button iconLeading={ChevronDown}>Options</Button>
   // As element (must have data-icon)
   <Button iconLeading={<ChevronDown data-icon className="size-4" />}>Options</Button>
   ```

4. **Colors MUST be semantic** — never raw Tailwind colors:
   ```
   text-primary       // correct
   text-gray-900      // WRONG
   bg-brand-solid     // correct
   bg-blue-700        // WRONG
   ```

5. **Button icons use `iconLeading`/`iconTrailing` props** — never pass icons as children.

## Component Implementation Workflow

When a Rune worker needs to implement a UI component with UntitledUI:

```
1. SEARCH: search_components("descriptive query")
   ├── Match found → proceed to step 2
   └── No match → build from scratch with Tailwind + conventions

2. GET: get_component("ComponentName")
   ├── Success → use component source as implementation base
   └── Auth error (PRO) → fall back to conventions-guided Tailwind

3. CUSTOMIZE: Apply project-specific modifications
   ├── Follow import conventions (Aria* prefix)
   ├── Use semantic color classes (text-primary, bg-secondary)
   ├── Add proper icon handling (data-icon attribute)
   └── Ensure kebab-case file naming

4. VALIDATE: Check against conventions
   ├── No raw color classes (text-gray-*, bg-blue-*)
   ├── No react-aria imports without Aria* prefix
   ├── No PascalCase file names
   └── All icons use data-icon when passed as JSX
```

For full-page implementations, check `get_page_templates` first (PRO), then fall back to `get_component_bundle` for composing individual components.

## Rune Integration Points

### `/rune:devise` — Planning Phase
- **Phase 0.5**: `discoverDesignSystem()` detects `untitled_ui` → `discoverUIBuilder()` finds this skill
- **Phase 1**: Research agents receive UntitledUI tool availability context
- **Phase 2**: Plan frontmatter includes `ui_builder.builder_mcp: untitledui`
- **Phase 2**: Plan includes "Component Strategy" section with library component mapping

### `/rune:design-sync` — Figma Pipeline
- **Phase 1**: `figma_to_react()` generates reference code (~50-60% match)
- **Phase 1.5**: Reference code analyzed → `search_components()` finds real UntitledUI matches
- **Phase 2**: Workers import REAL UntitledUI components instead of generated approximations
- **Result**: Match rate improves from ~50-60% to ~85-95%

### `/rune:strive` — Worker Execution
- **Phase 1.5**: Worker prompts injected with:
  - Builder workflow block (search → get → customize → validate)
  - Conventions from [agent-conventions.md](references/agent-conventions.md) (truncated to 2000 chars)
  - MCP tool context block (tool names + categories)

### `/rune:appraise` — Code Review
- `design-system-compliance-reviewer` loads UntitledUI conventions as additional review rules
- Generates `DSYS-BLD-*` findings for convention violations (P2)

### `/rune:arc` — Full Pipeline
- Inherits all above integrations across phases
- Phase 2.8 (Semantic Verification) confirms UntitledUI MCP availability

## Talisman Configuration

```yaml
# talisman.yml — UntitledUI official MCP integration
integrations:
  mcp_tools:
    untitledui:
      server_name: "untitledui"                  # Must match .mcp.json key

      tools:
        - name: "search_components"
          category: "search"
        - name: "list_components"
          category: "search"
        - name: "get_component"
          category: "details"
        - name: "get_component_bundle"
          category: "details"
        - name: "get_page_templates"
          category: "search"
        - name: "get_page_template_files"
          category: "details"

      phases:
        devise: true
        strive: true
        forge: true
        appraise: false
        audit: false
        arc: true

      skill_binding: "untitledui-mcp"            # This skill

      rules: []                                   # Conventions loaded via skill, not rule files

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/", "src/pages/"]
        keywords: ["frontend", "ui", "component", "design", "untitledui"]
        always: false                             # Set to true if ALL tasks should use UntitledUI

      metadata:
        library_name: "UntitledUI"
        homepage: "https://www.untitledui.com"
        mcp_endpoint: "https://www.untitledui.com/react/api/mcp"
        transport: "http"
        auth: "oauth2.1-pkce"                     # or "api-key" or "none"
        access_token_env: "UNTITLEDUI_ACCESS_TOKEN"  # env var for PRO API key (optional — free tier works without it)
```

## Design System Discovery Integration

When `design-system-discovery` runs, UntitledUI is detected via:

| Signal | Weight | Source |
|--------|--------|--------|
| `@untitled-ui/*` in package.json | 1.0 (conclusive) | Tier 0 — Root Manifests |
| `untitledui` MCP server in `.mcp.json` | 0.9 | Tier 0 — MCP Detection |
| `@untitledui/icons` imports in source | 0.8 | Tier 1 — Shallow Scan |
| `sortCx` utility usage | 0.6 | Tier 2 — Deep Content Scan |

When both library AND MCP are detected, `discoverUIBuilder()` returns this skill's builder-protocol metadata automatically.

## References

- [agent-conventions.md](references/agent-conventions.md) — Complete UntitledUI code conventions (from official AGENT.md)
- [mcp-tools.md](references/mcp-tools.md) — Detailed MCP tool documentation with search strategies
