# UntitledUI MCP Tools — Detailed Reference

## Server Configuration

**Endpoint**: `https://www.untitledui.com/react/api/mcp`
**Transport**: HTTP (Streamable HTTP)
**Authentication**: OAuth 2.1 with PKCE (recommended) | `UNTITLEDUI_ACCESS_TOKEN` env var | None (free only)

### `.mcp.json` Configuration

```json
{
  "mcpServers": {
    "untitledui": {
      "type": "http",
      "url": "https://www.untitledui.com/react/api/mcp"
    }
  }
}
```

With API key (`UNTITLEDUI_ACCESS_TOKEN`):
```json
{
  "mcpServers": {
    "untitledui": {
      "type": "http",
      "url": "https://www.untitledui.com/react/api/mcp",
      "headers": {
        "Authorization": "Bearer ${UNTITLEDUI_ACCESS_TOKEN}"
      }
    }
  }
}
```

> **Environment variable**: Set `export UNTITLEDUI_ACCESS_TOKEN="<your-token-here>"` in your shell
> profile. This is the same key used in `Authorization: Bearer` headers and the per-call `key`
> parameter. When set, agents gain PRO access (all components, page templates, shared assets).

## Tool Details

### 1. `search_components` — Primary Search Tool

**Category**: search
**Free**: Yes
**Purpose**: Natural language component search. This is the FIRST tool to call when implementing UI.

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `query` | string | Yes | — | Natural language search query |
| `category_filter` | string | No | all | Filter by category |
| `limit` | number | No | 20 | Max results |
| `key` | string | No | — | API key (alternative to OAuth) |

**Search Strategy Tips**:

| Context | Good Query | Bad Query |
|---------|-----------|-----------|
| Navigation | "sidebar navigation with icons and nested items" | "nav" |
| Data display | "data table with sorting pagination and filters" | "table" |
| Forms | "multi-step form wizard with validation" | "form" |
| Auth | "login page with social sign-in" | "login" |
| Pricing | "pricing comparison table with toggle annual monthly" | "pricing" |
| Dashboard | "analytics dashboard metric cards with charts" | "dashboard" |

**Domain-specific keywords** to improve search relevance:

| Domain | Keywords to include |
|--------|-------------------|
| SaaS/B2B | "settings", "team management", "billing", "onboarding" |
| E-commerce | "product card", "cart", "checkout", "order" |
| Finance | "transaction", "portfolio", "statement", "balance" |
| Healthcare | "patient", "appointment", "record", "schedule" |
| Developer tools | "API explorer", "code editor", "log viewer", "pipeline" |

### 2. `list_components` — Browse by Category

**Category**: search
**Free**: Yes
**Purpose**: Paginated browsing of all components in a category.

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `category` | string | No | all | base, application, marketing, foundations, shared-assets, examples |
| `skip` | number | No | 0 | Pagination offset |
| `limit` | number | No | 20 | Results per page |
| `key` | string | No | — | API key |

**Response shape**:
```json
{
  "total": 768,
  "skip": 0,
  "limit": 20,
  "has_more": true,
  "components": [...]
}
```

**Category overview**:
| Category | Content | Count (approx) |
|----------|---------|----------------|
| `base` | Core UI primitives: buttons, inputs, selects, checkboxes, badges, avatars, toggles | ~80 |
| `application` | Complex patterns: date pickers, modals, tables, tabs, pagination, file upload | ~120 |
| `marketing` | Landing sections: heroes, features, CTAs, testimonials, pricing, FAQs, footers | ~200 |
| `foundations` | Design tokens, FeaturedIcon, icons, logos | ~30 |
| `shared-assets` | Complete pages: login, signup, 404, error (PRO) | ~50 |
| `examples` | Full page implementations (PRO) | ~50+ |

### 3. `get_component` — Install Single Component

**Category**: details
**Free**: Partial (base + some application free, marketing/shared-assets PRO)
**Purpose**: Get full source code, imports, dependencies for a named component.

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `name` | string | Yes | — | Component name (from search/list results) |
| `key` | string | No | — | API key for PRO components |

**Returns**: Full component source code with:
- TypeScript component file
- Import statements
- Props interface
- Style definitions
- Usage examples
- Dependencies list

**Error handling for Rune workers**:
- Auth error on PRO component → fall back to conventions-guided Tailwind
- Component not found → re-search with broader query
- Network error → retry once, then fall back

### 4. `get_component_bundle` — Install Multiple Components

**Category**: details
**Free**: Free components only
**Purpose**: Batch install for page-level implementations. More efficient than individual `get_component` calls.

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `names` | string[] | Yes | — | Array of component names |
| `key` | string | No | — | API key for PRO components |

**When to use**:
- Building a full page that needs 3+ components
- After `search_components` identifies multiple matches
- After `get_page_templates` identifies the components in a template

### 5. `get_page_templates` — Browse Templates (PRO)

**Category**: search
**Free**: No (PRO only)
**Purpose**: Browse available page-level templates. Use BEFORE building full pages.

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `key` | string | No | — | API key |

**Returns**: List of page templates with:
- Template name and description
- Component list (what components the template uses)
- Preview thumbnail
- Layout structure

**Rune integration**: During `design-sync` Phase 1.5, check templates FIRST for page-level Figma designs before searching individual components. A template match can cover 70-90% of a page in one tool call.

### 6. `get_page_template_files` — Install Template (PRO)

**Category**: details
**Free**: No (PRO only)
**Purpose**: Install all files for a complete page template.

**Parameters**:
| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `template` | string | Yes | — | Template identifier (from get_page_templates) |
| `key` | string | No | — | API key |

**Returns**: Complete set of files for the template:
- Page component file
- All component dependencies
- Layout structure
- Route configuration hints

## Tool Selection Decision Tree

```
Need to implement UI?
├── Full page → get_page_templates() first (PRO)
│   ├── Template match → get_page_template_files()
│   └── No match → search_components() for each section
├── Specific component → search_components("description")
│   ├── Match found → get_component("name")
│   └── No match → list_components(category) to explore
├── Multiple components → search each, then get_component_bundle([names])
└── Exploring library → list_components(category, limit=50)
```

## Rune Pipeline Integration

### As figma-to-react Reference Enhancement

```
figma_to_react() → reference code (~50-60% match)
        ↓
ANALYZE reference → extract component types needed
        ↓
search_components("sidebar nav") → find real UntitledUI component
        ↓
get_component("SidebarNavigation") → get real source code
        ↓
Worker implements with REAL component → ~85-95% match
```

### In Worker Prompts (injected by strive Phase 1.5)

When UntitledUI MCP is active, workers receive this workflow guidance:
1. **SEARCH** before building: `search_components("description of needed UI")`
2. **GET** the matching component: `get_component("ComponentName")`
3. **CUSTOMIZE** following conventions (semantic colors, Aria* prefix, kebab-case)
4. **VALIDATE** against the checklist in agent-conventions.md

### MCP Tool Name Resolution

In Claude Code, MCP tools are accessed with namespace prefix:
```
mcp__untitledui__search_components
mcp__untitledui__list_components
mcp__untitledui__get_component
mcp__untitledui__get_component_bundle
mcp__untitledui__get_page_templates
mcp__untitledui__get_page_template_files
```

In talisman.yml tool lists, use SHORT names (without prefix):
```yaml
tools:
  - name: "search_components"      # NOT mcp__untitledui__search_components
    category: "search"
```
