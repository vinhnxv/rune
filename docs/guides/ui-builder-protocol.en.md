# Rune UI Builder Protocol — Developer Guide

Integrate any component library MCP (UntitledUI, shadcn/ui, custom) into Rune's workflow pipeline with automatic detection, phase routing, and conventions injection.

Related guides:
- [MCP Integration Spec](mcp-integration-spec.en.md)
- [Talisman deep dive](rune-talisman-deep-dive-guide.en.md)
- [Custom agents and extensions](rune-custom-agents-and-extensions-guide.en.md)
- [Troubleshooting and optimization](rune-troubleshooting-and-optimization-guide.en.md)

---

## 1. What is the UI Builder Protocol?

The UI Builder Protocol is a pluggable abstraction layer that lets any component library ecosystem (UntitledUI, shadcn/ui, custom MCPs) register its capabilities and inject structured workflows into Rune's pipeline phases.

### The Gap It Closes

Without the protocol, Rune's `figma-to-react` output is treated as the final implementation:

```
BEFORE:  Figma → figma_to_react (~50-60% match) → workers apply as-is → manual fixes
         (Rune generates from scratch, ignores component libraries)

AFTER:   Figma → figma_to_react (~50-60%) → analyze intent → search library MCP
                → match real components → compose layout → Code (~85-95%)
         (workers import real library components via MCP)
```

### What the Protocol Is Not

- **Not a new talisman section** — it extends `integrations.mcp_tools` and `builder-protocol` skill frontmatter
- **Not a UI builder itself** — Rune orchestrates external builders (UntitledUI MCP, shadcn registry)
- **Not a component library** — Rune does not bundle component libraries
- **Not breaking** — with no builder detected, the pipeline is identical to before

### The Two-Part System

The protocol has two complementary parts:

| Part | Location | What it does |
|------|----------|-------------|
| `integrations.mcp_tools` (talisman) | `.claude/talisman.yml` | Tool routing, phase gating, trigger conditions |
| `builder-protocol` frontmatter (skill) | `skills/{name}/SKILL.md` | Capability mapping, conventions file, workflow instructions |

The `skill_binding` field in talisman links these two parts together. Together they form a **Builder Profile** — resolved at runtime by `discoverUIBuilder()`.

---

## 2. Creating a Builder Skill (Minimal Example)

A builder skill is a standard Rune skill with two additions: `builder-protocol` frontmatter declaring its capabilities, and a `conventions` reference file.

### Minimal Builder Skill

```
.claude/
  skills/
    my-builder/
      SKILL.md
      references/
        conventions.md
```

**`.claude/skills/my-builder/SKILL.md`:**

```yaml
---
name: my-builder
description: |
  My component library MCP integration for Rune workflows.
  Provides MCP tools for searching and installing components.
  Use when agents build UI with my-library components.
  Trigger keywords: my-library, component library.
user-invocable: false
disable-model-invocation: false
builder-protocol:
  library: my_library            # Must match design-system-discovery output
  mcp_server: my-library         # Must match .mcp.json server key
  capabilities:
    search: my_search_tool       # MCP tool name for natural-language search
    list: my_list_tool           # MCP tool name for browsing by category
    details: my_get_tool         # MCP tool name for getting component source
    bundle: my_bundle_tool       # MCP tool name for batch install (optional)
  conventions: references/conventions.md  # Path relative to skill dir
---

# My Library MCP Integration

Background knowledge for Rune agents working with my-library components.

## MCP Tools

### `my_search_tool`
Search for components by natural language description.

### `my_get_tool`
Install a component's full source code.

## Core Conventions

1. Always import from `@my-org/my-library`
2. Use the design token scale — never raw CSS values
3. ...
```

**`.claude/skills/my-builder/references/conventions.md`:**

```markdown
# My Library Conventions

- Import: `import { Button } from "@my-org/my-library"`
- Tokens: use `--color-brand-500`, never `#3B82F6`
- Files: kebab-case only (my-component.tsx)
```

### Link the Skill in Talisman

Add to `.claude/talisman.yml`:

```yaml
integrations:
  mcp_tools:
    my-library:
      server_name: "my-library"
      tools:
        - name: "my_search_tool"
          category: "search"
        - name: "my_list_tool"
          category: "search"
        - name: "my_get_tool"
          category: "details"
        - name: "my_bundle_tool"
          category: "details"
      phases:
        devise: true
        strive: true
        forge: true
        appraise: false
        audit: false
        arc: true
      skill_binding: "my-builder"       # Links to your builder skill
      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/"]
        keywords: ["ui", "component", "my-library"]
        always: false
```

---

## 3. Builder Frontmatter Contract

The `builder-protocol` YAML block is the core of the protocol. It declares what a skill is and what it can do.

### Schema

```yaml
builder-protocol:
  library: string           # REQUIRED. Design system identifier from design-system-discovery.
  mcp_server: string        # REQUIRED. MCP server key — must match a key in .mcp.json.
  capabilities:             # REQUIRED. Map of semantic capability to MCP tool name.
    search: string          # Tool for natural-language component search (REQUIRED)
    list: string            # Tool for browsing components by category (REQUIRED)
    details: string         # Tool for getting a single component's source (REQUIRED)
    bundle: string          # Tool for batch install of multiple components (OPTIONAL)
    templates: string       # Tool for browsing page templates (OPTIONAL, often PRO)
    template_files: string  # Tool for installing a full page template (OPTIONAL, often PRO)
  conventions: string       # REQUIRED. Path to conventions file, relative to skill directory.
```

### `library` Values

The `library` field must match the identifier emitted by `discoverDesignSystem()`. Known values:

| Library | `library` value |
|---------|----------------|
| UntitledUI | `untitled_ui` |
| shadcn/ui | `shadcn_ui` |
| Radix UI | `radix_ui` |
| Custom/Unknown | `custom` |

For custom/unknown libraries, use `custom`. The protocol will match via MCP server heuristics.

### `capabilities` Required vs Optional

| Capability | Required | Purpose |
|------------|----------|---------|
| `search` | YES | Natural-language component search — used by devise and design-sync Phase 1.5 |
| `list` | NO | Browse components by category — used by strive worker browse workflow |
| `details` | YES | Fetch component source code — used by strive implementation and design-sync Phase 2 |
| `bundle` | NO | Batch install multiple components — used by design-sync Phase 2 |
| `templates` | NO | Page/screen templates — used by design-sync Phase 1.5 |
| `template_files` | NO | Template asset files — used by design-sync Phase 2 full page install |

**Minimum viable builder**: `search` + `details` only. The protocol degrades gracefully — omitting `bundle`, `templates`, and `template_files` disables their respective pipeline optimisations but does not break the integration.

---

## 4. Capability Interface Reference

### `search` — Natural Language Component Search

The primary tool for finding components. Workers call this before building from scratch.

**Expected behavior**: accepts a natural language query string, returns a ranked list of components with names and descriptions.

**Usage pattern in workers**:
```
1. search(query) → matches
2. IF matches found AND score > threshold → proceed to details
3. IF no match → build from scratch using conventions
```

### `list` — Category Browse

Used when workers need to explore what's available without a specific query.

**Expected behavior**: accepts optional category filter, returns paginated component list.

**When used**: full-page implementations where the worker needs to survey available building blocks.

### `details` — Component Source Install

The install tool. Workers call this to get a component's full source code.

**Expected behavior**: accepts component name/identifier, returns source code + imports + dependencies.

**On auth error (PRO components)**: Rune falls back to conventions-guided Tailwind implementation.

### `bundle` — Batch Component Install

Batch version of `details`. Reduces MCP round-trips for page-level implementations.

**Expected behavior**: accepts array of component names, returns all their source code in a single call.

**When used**: design-sync Phase 2 when multiple components are needed for a page section.

### `templates` — Page Template Browse

Lists available full-page templates. Often a PRO-tier feature.

**Expected behavior**: returns list of template identifiers and descriptions.

**When used**: design-sync Phase 1.5 — checked first before individual component matching (a page-level match is more efficient than assembling components individually).

### `template_files` — Full Page Template Install

Installs an entire page template with all component files.

**Expected behavior**: accepts template identifier, returns all files needed for the page.

**When used**: design-sync Phase 2 when a high-confidence page template match was found in Phase 1.5.

---

## 5. Conventions File Format

The conventions file is the knowledge base for workers. It is:
- Injected into worker prompts when your builder is active (truncated to 2000 characters at line boundary)
- Loaded by the design-system-compliance-reviewer as additional review rules
- Used as fallback guidance when component retrieval fails (PRO gate, network error)

### Recommended Structure

```markdown
# [Library Name] Conventions

## Critical Rules

1. **Import pattern**: Always import from `@org/package`
   ```typescript
   import { Button } from "@org/package"
   ```

2. **File naming**: kebab-case only
   ```
   my-component.tsx    // correct
   MyComponent.tsx     // wrong
   ```

3. **Color tokens**: use semantic tokens, not raw values
   ```
   bg-brand-500       // correct
   bg-blue-500        // wrong (raw Tailwind)
   ```

## Anti-Patterns

- Do NOT mix library components with custom HTML for the same UI primitive
- Do NOT override tokens with inline styles
- Do NOT import component styles — use the token system

## Fallback Strategy

If component retrieval fails:
1. Use the library's base primitives (Button, Input, etc.) with token styles
2. Build with Tailwind + token classes only
3. Never use raw CSS values
```

### Size Constraint

**Keep the conventions file under ~150 lines.** The injector truncates at 2000 characters (nearest line boundary). Put critical rules first. Move detailed API documentation to a separate reference file and load it on demand.

---

## 6. Testing Your Builder Integration

### Step 1: Validate Frontmatter

```bash
# Read your skill's frontmatter
cat .claude/skills/my-builder/SKILL.md | head -30
```

Verify `builder-protocol` has `library`, `mcp_server`, `capabilities.search`, `capabilities.details`, and `conventions`.

### Step 2: Validate Talisman Config

```
/rune:talisman audit
```

The audit checks:
- `server_name` matches a key in `.mcp.json`
- `skill_binding` resolves to an installed skill
- At least one `phases` flag is `true`
- Trigger has at least one condition

**Builder skill alignment** (3-component drift check): `/rune:talisman audit` also validates that the three protocol components are in sync:
1. Every `skill_binding` in talisman references an installed skill in `.claude/skills/` or the plugin
2. Each referenced skill has `builder-protocol:` frontmatter
3. The `conventions:` path in that frontmatter exists relative to the skill root

If any of these three are out of sync, the audit emits a warning rather than failing silently at runtime.

### Step 3: Verify MCP Server

```bash
claude mcp list
```

Confirm your server appears and its status is connected.

### Step 4: Run Design System Discovery

Use `/rune:devise` on a small task that references your component library. Check the plan frontmatter for a `ui_builder` section:

```yaml
ui_builder:
  builder_skill: my-builder
  builder_mcp: my-library
  conventions: references/conventions.md
  capabilities:
    search: my_search_tool
    details: my_get_tool
    bundle: my_bundle_tool
```

If this section is present, auto-detection succeeded.

### Step 5: Run a Worker Task

```
/rune:strive "Add a settings page with form fields"
```

In worker output, look for:

```
## Available MCP Tools (My Library)

**Search**: Use `my_search_tool` to find components by description.
**Details**: Use `my_get_tool` to install a component's full source code.

Conventions: kebab-case files, @org/package imports, semantic tokens.
```

If this block appears in worker context, the integration is active.

### Step 6: Check Compliance Reviewer

Run `/rune:appraise` on a file that uses your library. The compliance reviewer should emit `DSYS-BLD-*` findings if convention violations are detected.

---

## 7. Examples

### Example A: UntitledUI (Built-in)

UntitledUI is the reference implementation. Rune ships a built-in `untitledui-mcp` skill — no project-level skill needed.

**Setup:**
```bash
# Free + OAuth (recommended — auto-handles login flow):
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp

# PRO with API key (set UNTITLEDUI_ACCESS_TOKEN in your shell profile):
export UNTITLEDUI_ACCESS_TOKEN="your-api-key-here"
claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp \
  --header "Authorization: Bearer $UNTITLEDUI_ACCESS_TOKEN"
```

> **Access tiers**: When `UNTITLEDUI_ACCESS_TOKEN` is set, agents have PRO access (all components,
> page templates, shared assets). Without it, agents use free tier or fall back to Tailwind + conventions.

**Talisman config (`.claude/talisman.yml`):**
```yaml
integrations:
  mcp_tools:
    untitledui:
      server_name: "untitledui"
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
      skill_binding: "untitledui-mcp"    # Built-in plugin skill
      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/", "src/pages/"]
        keywords: ["frontend", "ui", "component", "design", "untitledui"]
        always: false
      metadata:
        library_name: "UntitledUI"
        homepage: "https://www.untitledui.com"
        access_token_env: "UNTITLEDUI_ACCESS_TOKEN"
```

The `untitledui-mcp` built-in skill provides:
- 6 MCP tool definitions with search strategies
- React Aria conventions (Aria* import prefix)
- Tailwind v4.1 semantic color rules
- kebab-case file naming
- data-icon attribute requirements
- Free/PRO fallback handling

> **Project-level override**: create `.claude/skills/untitledui-builder/SKILL.md` with your project-specific conventions and set `skill_binding: "untitledui-builder"`. Project skills take priority over plugin skills.

---

### Example B: shadcn/ui

shadcn/ui does not ship an official HTTP MCP server. If a community MCP or the `21st.dev` registry MCP is available, register it and create a project-level builder skill.

**`.mcp.json`:**
```json
{
  "mcpServers": {
    "shadcn": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@your-org/shadcn-mcp@1.0.0"]
    }
  }
}
```

**`.claude/skills/shadcn-builder/SKILL.md`:**
```yaml
---
name: shadcn-builder
description: |
  shadcn/ui component library integration for Rune workflows.
  Provides tools for browsing and installing shadcn/ui components.
  Use when agents build UI with shadcn/ui components.
  Trigger keywords: shadcn, shadcn/ui, radix, @shadcn.
user-invocable: false
builder-protocol:
  library: shadcn_ui
  mcp_server: shadcn
  capabilities:
    search: shadcn_search
    list: shadcn_list
    details: shadcn_install
    bundle: shadcn_install_many
  conventions: references/conventions.md
---

# shadcn/ui Integration

Background knowledge for Rune agents working with shadcn/ui.

## Component Model

shadcn/ui components are installed into your project — they are owned code, not a dependency.
Install via the CLI or MCP tool, then modify freely.

## Core Conventions

1. Import from local path: `import { Button } from "@/components/ui/button"`
2. Use `cn()` for conditional classes
3. Tailwind CSS v3/v4 variable-based tokens (`--background`, `--foreground`)
4. Never import directly from `@radix-ui/*` — use the shadcn wrapper
```

**`.claude/skills/shadcn-builder/references/conventions.md`:**
```markdown
# shadcn/ui Conventions

## Imports
- Always: `import { Button } from "@/components/ui/button"`
- Never: `import * as RadixDialog from "@radix-ui/react-dialog"`

## Styling
- Use `cn()` utility for conditional classes: `cn("base-class", { "active": isActive })`
- CSS variables: `bg-background`, `text-foreground`, `border-border`
- Never raw Tailwind color values: `bg-gray-100` → use `bg-muted`

## File Structure
- Components live in `src/components/ui/` after install
- Custom variants go in the same file, not a separate file
```

**Talisman config:**
```yaml
integrations:
  mcp_tools:
    shadcn:
      server_name: "shadcn"
      tools:
        - name: "shadcn_search"
          category: "search"
        - name: "shadcn_list"
          category: "search"
        - name: "shadcn_install"
          category: "details"
        - name: "shadcn_install_many"
          category: "details"
      phases:
        devise: true
        strive: true
        forge: false
        appraise: false
        audit: false
        arc: true
      skill_binding: "shadcn-builder"
      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/", "app/"]
        keywords: ["shadcn", "ui", "component", "radix"]
        always: false
```

---

### Example C: Custom Internal Component Library

For a custom company design system with its own MCP server:

**`.mcp.json`:**
```json
{
  "mcpServers": {
    "acme-design": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@acme/design-system-mcp@2.1.0"]
    }
  }
}
```

**`.claude/skills/acme-builder/SKILL.md`:**
```yaml
---
name: acme-builder
description: |
  ACME company design system MCP integration.
  Provides search and install for ACME components (800+ components, 3 tiers).
  Use when agents build UI with ACME Design System components.
  Trigger keywords: acme, acme-ds, design-system, acme component.
user-invocable: false
builder-protocol:
  library: custom
  mcp_server: acme-design
  capabilities:
    search: acme_search_components
    list: acme_list_category
    details: acme_get_component
    bundle: acme_get_bundle
  conventions: references/conventions.md
---

# ACME Design System Integration

...conventions and workflow instructions...
```

> **Note on `library: custom`**: When `library` is `custom` or unknown, `discoverUIBuilder()` cannot match via `discoverDesignSystem()` output alone. Instead it falls back to scanning `.mcp.json` for servers with component-library-like tool names (heuristic: tools containing `search`, `get_component`, or `install`). Ensure your server's tool names include at least one of these patterns, or set `always: true` in the trigger to force activation.

---

## 8. Troubleshooting

### Builder not detected

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No `ui_builder` section in plan frontmatter | `discoverUIBuilder()` returned null | Check if MCP server is registered + skill has `builder-protocol` frontmatter |
| Workers don't mention library components | Builder detected but trigger not firing | Check `trigger.extensions`, `trigger.paths`, `trigger.keywords` |
| `skill_binding` resolves to nothing | Skill not installed or wrong name | Verify skill exists in `.claude/skills/` or plugin; check `skill_binding` spelling |
| `library: custom` not auto-detected | No heuristic match on tool names | Set `trigger.always: true` or add `search`/`get_component` to your tool names |

### Workers ignore builder MCP

Workers see the MCP context block but fall back to generic Tailwind:

1. Check if `capabilities.search` tool is callable: does the MCP server respond?
2. Check PRO gating: workers fall back when `get_component` returns an auth error
3. Check conventions file: workers may misunderstand the API if conventions are incorrect

```bash
# Verify MCP server is connected
claude mcp list

# Check if talisman resolves the integration
/rune:talisman status
```

### Convention violations in review

The `design-system-compliance-reviewer` generates `DSYS-BLD-*` findings only when:
1. Builder is active (builder profile detected)
2. The reviewer loads the conventions file from `builder-protocol.conventions`
3. The changed file is in scope for the review

If `DSYS-BLD-*` findings are missing when expected:
- Verify `builder-protocol.conventions` path is correct (relative to skill dir)
- Check the conventions file is under 2000 characters or critical rules are in the first 150 lines
- Verify the file under review matches the trigger extensions/paths

### Conventions Not Applied (Silent Failure)

If builder conventions are not injected into worker context despite the builder being detected:

**Root causes:**

| Cause | Symptom |
|-------|---------|
| `skill_binding` points to non-existent skill | Builder detected but conventions block absent from worker prompts |
| Skill exists but lacks `builder-protocol:` frontmatter | `discoverUIBuilder()` finds the skill but reads no capabilities |
| `conventions:` path is wrong | Builder active, no conventions text in worker context |

**Important**: `conventions:` is relative to the **skill directory**, not the repo root. `.claude/skills/my-builder/references/conventions.md` → set `conventions: references/conventions.md`, not `.claude/skills/my-builder/references/conventions.md`.

**Debug steps:**

```bash
# 1. Verify the skill exists
ls .claude/skills/{skill_name}/

# 2. Verify builder-protocol frontmatter is present
grep -n "builder-protocol:" .claude/skills/{skill_name}/SKILL.md

# 3. Verify the conventions file path (relative to skill dir)
ls .claude/skills/{skill_name}/references/{path}
```

Then run `/rune:talisman audit` — it will flag missing skills and broken conventions paths.

### TrueDigital Migration Note

If you have project-level skills (`untitledui-builder`, `frontend-figma-sync`, `frontend-workflow`) from a pre-1.133.0 setup, they continue to work as project-level overrides — project skills take priority over plugin skills. You can:

1. **Keep them as-is** — they override the built-in plugin skill with your customizations
2. **Migrate gradually** — move conventions into the built-in skill pattern and delete project overrides once they're absorbed

To use a project skill as the builder, set `skill_binding` in talisman to your project skill name:
```yaml
skill_binding: "untitledui-builder"   # uses .claude/skills/untitledui-builder/ (project override)
# vs.
skill_binding: "untitledui-mcp"       # uses plugins/rune/skills/untitledui-mcp/ (built-in)
```

---

## 9. Upgrading from MCP Integration Level 2

Level 2 (talisman `integrations.mcp_tools` config) already handles tool routing and phase gating. The UI Builder Protocol adds Level 3 capabilities on top.

### What Level 2 gives you

- Phase-aware tool activation (tools only active in configured phases)
- Trigger conditions (only activate when context matches)
- Tool categories (workers understand tool purpose)
- Rules files injection (project-specific coding rules)

### What Level 3 adds (UI Builder Protocol)

- `discoverUIBuilder()` auto-detection from design-system-discovery
- `builder-protocol` frontmatter read by design-sync pipeline
- Phase 1.5 Component Match in design-sync (reference code → library component search)
- `ui_builder` section in plan frontmatter (capabilities available to all phases)
- `DSYS-BLD-*` findings from compliance reviewer

### Upgrade Path

**Before (Level 2 only):**
```yaml
integrations:
  mcp_tools:
    untitledui:
      server_name: "untitledui"
      tools: [...]
      phases: [...]
      skill_binding: "untitledui-builder"   # project skill without builder-protocol
      trigger: [...]
```

**After (Level 3 / Builder Protocol):**

1. Add `builder-protocol` frontmatter to your skill:
```yaml
# In .claude/skills/untitledui-builder/SKILL.md frontmatter:
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
```

2. Create/update the conventions reference file at `references/agent-conventions.md`

3. Run `/rune:talisman audit` to validate

No talisman config changes required — the `skill_binding` already links your skill. Once the skill has `builder-protocol` frontmatter, `discoverUIBuilder()` picks it up automatically.

### Alternatively: Switch to Built-in Skill

If you use UntitledUI and don't need project-specific customizations, switch to the built-in `untitledui-mcp` plugin skill:

```yaml
# Change skill_binding in talisman:
skill_binding: "untitledui-mcp"    # was: "untitledui-builder"
```

The built-in skill has full `builder-protocol` support and stays updated with official UntitledUI AGENT.md conventions.

---

## Quick Reference

### Builder Protocol Frontmatter (complete)

```yaml
builder-protocol:
  library: untitled_ui             # design-system identifier
  mcp_server: untitledui           # .mcp.json server key
  capabilities:
    search: search_components      # natural language search
    list: list_components          # category browse
    details: get_component         # single component install
    bundle: get_component_bundle   # batch install (optional)
    templates: get_page_templates  # page templates (optional)
    template_files: get_page_template_files  # template install (optional)
  conventions: references/agent-conventions.md
```

### Pipeline Integration Points

| Phase | What happens with a builder active |
|-------|-------------------------------------|
| `/rune:devise` Phase 0.5 | `discoverUIBuilder()` finds builder skill and capabilities |
| `/rune:devise` Phase 2 | Plan frontmatter gets `ui_builder` section + "Component Strategy" plan section |
| `/rune:strive` Phase 1.5 | Workers injected with builder workflow block + conventions |
| `/rune:design-sync` Phase 1.5 | Component Match: reference code → library search → annotated VSM |
| `/rune:design-sync` Phase 2 | Workers import real library components from annotated VSM |
| `/rune:appraise` | Compliance reviewer loads conventions, generates `DSYS-BLD-*` findings |
| `/rune:arc` | All above, across pipeline phases |

### Known Library Values

| Library | `library` | Default built-in skill |
|---------|----------|----------------------|
| UntitledUI | `untitled_ui` | `untitledui-mcp` (plugin built-in) |
| shadcn/ui | `shadcn_ui` | None (create project skill) |
| Radix UI | `radix_ui` | None (create project skill) |
| Custom | `custom` | None (create project skill) |
