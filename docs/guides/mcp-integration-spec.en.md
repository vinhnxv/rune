# Rune MCP Integration Spec --- Developer Guide

> Integrate third-party MCP tools into Rune workflows with declarative talisman configuration.

## Overview

The Rune MCP Integration Framework bridges the gap between raw MCP tool availability and workflow-aware tool usage. When you add an MCP server to `.mcp.json`, Claude gains access to the tools --- but Rune's workflow agents (reviewers, workers, researchers) have no context about _when_ or _how_ to use them. A component library search tool is useless to a security reviewer; a code generation tool is counterproductive during a read-only audit.

The framework solves this through **declarative talisman configuration**. You declare your MCP tools, categorize them, define which workflow phases should activate them, and specify trigger conditions (file extensions, paths, keywords). At runtime, the integration resolver reads this config, evaluates triggers against the current context, and injects a structured MCP context block into the appropriate agent prompts. No plugin code changes required.

This guide walks through the three integration levels, the full schema reference, trigger evaluation logic, and a complete worked example.

## 3 Integration Levels

### Level 1: Basic (`.mcp.json` only)

At this level, you register the MCP server and its tools become available to Claude. However, Rune workflow agents do not receive any guidance about when or how to use them. Tools may be invoked inconsistently --- or not at all --- depending on how the agent interprets its task.

**.mcp.json:**

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

> **Note**: UntitledUI provides an official HTTP MCP server at `https://www.untitledui.com/react/api/mcp`.
> Authentication: OAuth 2.1 with PKCE (auto browser login), API Key header, or none (free components only).
> For API key auth, add `"headers": { "Authorization": "Bearer YOUR_API_KEY" }`.
> The official MCP exposes 6 tools: `search_components`, `list_components`, `get_component`, `get_component_bundle`, `get_page_templates` (PRO), `get_page_template_files` (PRO).

**What you get:** Tools appear in Claude's tool list. Agents _can_ call them if they decide to.

**What you lack:** No phase routing, no trigger-based activation, no rules injection, no companion skill context. Agents may use component search tools during code review (wasting tokens) or skip them during implementation (missing the opportunity).

### Level 2: Talisman (`+ integrations section`)

Add an `integrations.mcp_tools` section to your `talisman.yml`. This gives Rune's orchestrator three critical capabilities:

1. **Phase routing** --- tools only activate in specified workflow phases (devise, strive, forge, appraise, audit, arc)
2. **Trigger conditions** --- tools only activate when the task context matches (file extensions, paths, keywords)
3. **Rules injection** --- coding rules files are injected into agent prompts when the integration is active

**talisman.yml (project-level `.claude/talisman.yml`):**

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

      skill_binding: "untitledui-mcp"

      rules: []

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["src/components/", "src/pages/"]
        keywords: ["frontend", "ui", "component", "untitledui"]
        always: false
```

**What you get:** Phase-aware tool activation. Workers see "Use `search_components` to find UntitledUI components" in their prompt only when implementing `.tsx` files in `src/components/`. Reviewers never see write-heavy tools. Conventions from the companion skill are injected for consistent usage patterns.

### Level 3: Full (`+ skill + rules + manifest`)

For deep integrations, add a companion skill and discovery metadata. This provides persistent knowledge injection, auto-detection, and richer documentation.

**Directory structure:**

```
# Built-in Rune plugin skill (no project-level skill needed):
plugins/rune/skills/untitledui-mcp/
  SKILL.md                      # Builder-protocol skill with conventions
  references/
    agent-conventions.md        # UntitledUI code conventions (from AGENT.md)
    mcp-tools.md                # Detailed MCP tool documentation

# Optional project-level override:
.claude/
  skills/
    untitledui-builder/         # Custom project-specific conventions (overrides built-in)
      SKILL.md
  rules/
    untitledui-conventions.md   # Project-specific coding rules
  talisman.yml            # Integration config
.mcp.json                 # MCP server registration
```

**Full talisman.yml config (Level 3 additions):**

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

      skill_binding: "untitledui-mcp"

      rules:
        - ".claude/rules/untitledui-button-icons.md"

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["dashboard/src/", "admin/src/"]
        keywords: ["frontend", "ui", "component", "design"]
        always: false

      metadata:
        library_name: "UntitledUI PRO"
        component_count: 768
        version: "1.9.1"
        homepage: "https://untitledui.com"
```

**What you get:** Everything from Level 2, plus: companion skill is auto-loaded when integration activates (providing persistent component knowledge), metadata enables discovery via `/rune:talisman audit`, and rules ensure consistent coding patterns across all agents.

## Quick Start Guide

Follow these steps to add a Level 2 integration for any MCP tool:

### Step 1: Register MCP Server

Add your MCP server to `.mcp.json` (project root or `~/.claude/.mcp.json` for global):

```json
{
  "mcpServers": {
    "my-tool": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@my-org/mcp-server@1.0.0"]
    }
  }
}
```

### Step 2: Add Integration Config

Add `integrations.mcp_tools` to `.claude/talisman.yml`:

```yaml
integrations:
  mcp_tools:
    my-tool:
      server_name: "my-tool"
      tools:
        - name: "my_tool_search"
          category: "search"
        - name: "my_tool_generate"
          category: "generate"
      phases:
        devise: true
        strive: true
        forge: false
        appraise: false
        audit: false
        arc: true
      trigger:
        extensions: [".ts", ".tsx"]
        paths: ["src/"]
        keywords: ["widget"]
        always: false
```

### Step 3: Verify Configuration

Run the talisman audit to validate:

```
/rune:talisman audit
```

The audit checks:
- `server_name` matches a key in `.mcp.json`
- All tool names are valid identifiers
- Categories are from the allowed set
- At least one phase is enabled
- Trigger has at least one condition (or `always: true`)
- Rules files exist on disk (if specified)
- `skill_binding` skill exists (if specified)

### Step 4: Use in Any Workflow

No workflow changes needed. Run any Rune command and matching tools auto-activate:

```
/rune:strive "Build the dashboard settings page"
```

If the task touches `.tsx` files in `src/`, the workers receive the MCP context block with tool guidance.

## Schema Reference

### `integrations.mcp_tools.{namespace}`

The namespace key (e.g., `untitledui`) is a logical identifier. It should match or closely correspond to your `.mcp.json` server key.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `server_name` | string | Yes | Must match a key in `.mcp.json`. Validates server exists at audit time. |
| `tools` | array | Yes | Tool declarations. Each entry has `name` (string) and `category` (string). |
| `phases` | object | Yes | Workflow phase routing. Keys: `devise`, `strive`, `forge`, `appraise`, `audit`, `arc`. Values: boolean. |
| `skill_binding` | string | No | Companion skill name. Must exist in `.claude/skills/`. Auto-loaded when integration activates. |
| `rules` | array | No | Paths to rule files (relative to project root). Injected into agent prompts when active. |
| `trigger` | object | Yes | Activation conditions. See Trigger System below. |
| `metadata` | object | No | Discovery metadata (library name, version, homepage). Informational only. Open-ended — additional keys are preserved but not used by the resolver. |

### Metadata Fields

Known metadata keys (all optional):

| Key | Type | Description |
|-----|------|-------------|
| `library_name` | string | Human-readable library name (e.g., "UntitledUI PRO"). Used as display name in agent prompts. |
| `component_count` | number | Total component count. Informational for `/rune:talisman status`. |
| `version` | string | Library version (e.g., "1.9.1"). Informational. |
| `homepage` | string | Library homepage URL. Informational. |

Additional keys are allowed and passed through in the integration object, but the resolver and context builder only use `library_name` for display.

### Tool Declarations

Each entry in the `tools` array declares a single MCP tool with its semantic category:

```yaml
tools:
  - name: "search_components"    # Must match the MCP tool name exactly
    category: "search"           # Semantic category (see table below)
```

### Tool Categories

Categories provide semantic meaning that helps agents understand tool purpose without reading documentation:

| Category | Purpose | Example Tools |
|----------|---------|---------------|
| `search` | Find/discover resources | `search_components`, `list_components`, `get_page_templates` |
| `details` | Get detailed information about a specific resource | `get_component`, `get_component_bundle`, `figma_inspect_node` |
| `compose` | Plan multi-resource layouts or assemblies | `get_page_template_files` |
| `generate` | Generate code or artifacts | `figma_to_react` |
| `suggest` | AI-powered recommendations | (custom tool) |
| `validate` | Check, verify, or lint resources | `storybook_validate` |

Categories influence prompt injection. For example, `search` tools receive "Use X to find..." phrasing, while `generate` tools receive "Use X to produce..." phrasing. Workers receive all active categories; reviewers only receive `search` and `details` categories (read-only).

### Trigger System

Triggers determine _when_ an integration activates. Evaluation follows this logic:

```
activation = (extension_match OR path_match OR keyword_match) AND phase_match
```

If `always: true` is set, the trigger check is bypassed --- only phase routing applies.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `extensions` | string[] | `[]` | File extensions to match (e.g., `[".tsx", ".ts"]`). Compared against changed files (review/audit) or task-referenced files (strive/devise). |
| `paths` | string[] | `[]` | Path prefixes to match (e.g., `["src/api/", "lib/"]`). Any changed/referenced file under these paths triggers activation. |
| `keywords` | string[] | `[]` | Task description keywords (e.g., `["frontend", "ui"]`). Matched case-insensitively against the user's task description or plan content. |
| `always` | boolean | `false` | Override: skip all trigger checks. Use for tools that should always be available in their configured phases. |

**Evaluation examples:**

```yaml
# Activates when ANY .tsx/.ts file is changed AND current phase is strive
trigger:
  extensions: [".tsx", ".ts"]
  always: false

# Activates when files in src/api/ are changed OR task mentions "api"
trigger:
  paths: ["src/api/"]
  keywords: ["api", "endpoint"]
  always: false

# Always active in configured phases (use sparingly --- wastes tokens if irrelevant)
trigger:
  always: true
```

### Phase Definitions

Phases map to Rune workflow commands. Each phase has different agent roles and tool needs:

| Phase | Rune Command | Agent Role | Typical Tool Categories |
|-------|-------------|------------|------------------------|
| `devise` | `/rune:devise` | Research, planning | `search`, `details`, `suggest` | *Note: `changedFiles` is empty during planning. Only `keywords` and `always: true` triggers fire in devise. Use `keywords` alongside `extensions`/`paths` for devise activation.* |
| `strive` | `/rune:strive` | Implementation | `search`, `details`, `compose`, `generate` |
| `forge` | `/rune:forge` | Plan enrichment | `search`, `details`, `suggest` |
| `appraise` | `/rune:appraise` | Code review (read-only) | `search`, `details` |
| `audit` | `/rune:audit` | Full codebase analysis | `search`, `details`, `validate` |
| `arc` | `/rune:arc` | Full pipeline | Inherits per-phase settings |

**The `arc` phase:** When `arc: true`, the integration remains active throughout the entire arc pipeline. Each sub-phase within arc respects its own phase setting. For example, if `strive: true` and `appraise: false`, the integration activates during the work phase of arc but deactivates during the review phase.

## Workflow Integration Details

### How `/rune:strive` Uses Integrations

During the strive workflow, the orchestrator resolves MCP integrations at worker prompt injection time:

1. **`resolveMCPIntegrations("strive", { changedFiles, taskDescription })`** --- reads `integrations.mcp_tools`, filters to entries where `phases.strive: true`
2. **`evaluateTriggers(trigger, context)`** --- for each integration, checks trigger conditions against the task's file scope and description keywords
3. **`buildMCPContextBlock(activeIntegrations)`** --- builds a structured prompt block listing active tools by category, with usage guidance
4. **Inject into worker prompts** --- the context block is appended to each worker's system prompt, alongside any bound skill content and rules files

Workers receive guidance like:

```
## Available MCP Tools (UntitledUI)

**Search**: Use `search_components` to find components by natural language description.
**Browse**: Use `list_components` to browse components by category.
**Details**: Use `get_component` to install a component's full source code.
**Bundle**: Use `get_component_bundle` to install multiple components at once.

Conventions: React Aria Aria* prefix, semantic colors only, kebab-case files.
```

### How `/rune:devise` Uses Integrations

Research agents (lore-scholar, practice-seeker) receive MCP context during Phase 1C external research. The integration resolver filters to `phases.devise: true` entries and injects tool references into research agent prompts. This enables researchers to discover available components, API capabilities, or design resources during the planning phase.

### How `/rune:forge` Uses Integrations

Forge enrichment agents receive MCP context when deepening plan sections. If a plan section covers frontend implementation and the trigger matches, forge agents can use `search` and `details` tools to enrich the plan with specific component recommendations, API references, or design patterns.

### How `/rune:arc` Uses Integrations

The arc pipeline inherits integration settings across all sub-phases. When `arc: true`, the orchestrator evaluates triggers once at pipeline start and passes the active integrations through each phase. Individual phase settings (`strive`, `appraise`, etc.) still control activation within each arc sub-phase --- `arc: true` does not override `appraise: false`.

## Best Practices

- **Start with Level 2, upgrade to Level 3 when needed.** Most integrations work well with just talisman config. Add a companion skill only when agents need persistent domain knowledge beyond tool descriptions.

- **Use `appraise: false` for write-heavy tools.** Review agents in the Roundtable Circle operate under `enforce-readonly.sh` (SEC-001). Tools that generate or modify code should only be active in `strive` and `forge` phases.

- **Match trigger paths to actual project structure.** Use path prefixes that correspond to real directories. Overly broad paths (e.g., `["src/"]`) may activate integrations for unrelated tasks.

- **Keep rules files focused.** Rules files injected via `rules:` are appended to agent prompts. **Rule files are truncated to 2000 characters** (at the nearest line boundary) when injected into agent prompts. Keep them concise and focused on patterns that prevent common mistakes (e.g., "always use UntitledUI Button instead of raw HTML buttons"). Maximum 5 rule files per integration.

- **Use specific trigger keywords over broad ones.** Keywords like `"code"` or `"build"` match too many tasks. Prefer domain-specific terms like `"dashboard"`, `"component-library"`, `"figma"`.

- **Set `arc: true` to inherit settings across the full pipeline.** If your integration should be active during arc execution, enable `arc: true` alongside the specific phases. Arc respects individual phase settings for sub-phase filtering.

- **Pin MCP server versions.** In `.mcp.json`, pin package versions (e.g., `@untitledui/mcp-server@1.9.1`) to avoid breaking changes. Supply chain safety applies to MCP servers just as it does to npm dependencies.

- **One namespace per server.** Each `mcp_tools` key should correspond to exactly one MCP server. Do not combine tools from different servers under one namespace.

## Anti-Patterns

- **Do not set `always: true` for niche tools.** This forces the integration active on every task in the configured phases, wasting tokens on irrelevant context. Reserve `always: true` for foundational tools used in nearly every task (e.g., a company-wide design system).

- **Do not bind write-heavy tools to `appraise` phase.** Reviewers operate under strict read-only enforcement. Tools in categories `generate`, `compose`, or `validate` (with side effects) should be restricted to `strive` and `forge`.

- **Do not create rules that override CLAUDE.md instructions.** Rules files supplement agent behavior --- they should not contradict project-level or plugin-level CLAUDE.md. If a conflict exists, CLAUDE.md takes precedence.

- **Do not use overlapping tool categories.** If a tool both searches and generates, pick the primary purpose. A tool categorized as `search` receives read-oriented prompt framing; miscategorizing a `generate` tool as `search` confuses agents about its side effects.

- **Do not skip `server_name` validation.** Always run `/rune:talisman audit` after adding or modifying integrations. A typo in `server_name` silently disables the integration (no error, tools just never activate).

- **Do not add metadata without a server.** The `metadata` field is informational. It does not substitute for a working MCP server in `.mcp.json`. Metadata without a valid `server_name` passes audit but provides no runtime value.

## Example: UntitledUI Integration

A complete walkthrough of integrating UntitledUI --- a component library with 768+ components accessible via the official MCP server.

### 1. Register MCP Server

Add to `.mcp.json` (project root):

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

> **Authentication options**:
> - **OAuth 2.1 with PKCE** (recommended): Auto browser login, no API key needed
> - **API Key**: Add `"headers": { "Authorization": "Bearer YOUR_API_KEY" }`
> - **None**: Free components only (base UI, some application components)

### 2. Add Talisman Integration

Add to `.claude/talisman.yml`:

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

      skill_binding: "untitledui-mcp"

      rules:
        - ".claude/rules/untitledui-button-icons.md"

      trigger:
        extensions: [".tsx", ".ts", ".jsx"]
        paths: ["dashboard/src/", "admin/src/"]
        keywords: ["frontend", "ui", "component", "design"]
        always: false

      metadata:
        library_name: "UntitledUI PRO"
        component_count: 768
        version: "1.9.1"
        homepage: "https://untitledui.com"
```

### 3. Companion Skill (Built-in)

The Rune plugin includes a built-in `untitledui-mcp` skill that provides:
- Complete code conventions from the official UntitledUI AGENT.md (React Aria, Tailwind v4.1, semantic colors, kebab-case files, icon rules)
- MCP tool documentation with search strategies and usage patterns
- Builder protocol metadata for automated pipeline integration
- Component implementation workflow (search → get → customize → validate)

This skill is auto-loaded when the `skill_binding: "untitledui-mcp"` is set in talisman config. No project-level skill creation is required.

> **For advanced customization**: You can still create a project-level `.claude/skills/untitledui-builder/SKILL.md` with project-specific conventions. Project skills take priority over plugin skills. Set `skill_binding: "untitledui-builder"` in talisman to use your custom skill instead.

### 4. Create Rules File (Optional)

For project-specific coding rules, create `.claude/rules/untitledui-conventions.md`:

```markdown
# UntitledUI Project Rules

- Always use `<Button>` from UntitledUI instead of raw `<button>` elements
- Icons: use `iconLeading`/`iconTrailing` props, never pass as children
- Colors: use semantic classes (text-primary, bg-brand-solid) --- never raw Tailwind (text-gray-900)
- Files: kebab-case only (date-picker.tsx, not DatePicker.tsx)
- React Aria imports: always prefix with Aria* (import { Button as AriaButton })
```

### 5. Verify with Audit

```
/rune:talisman audit
```

Expected output includes validation of:
- `untitledui` server found in `.mcp.json`
- 6 tools declared with valid categories
- `skill_binding` resolves to built-in `untitledui-mcp` skill (or project override)
- Trigger has 4 conditions configured

### 6. Use in Workflow

```
/rune:strive "Build the settings page with toggle switches and a save button"
```

Because the task mentions "settings" and workers touch `.tsx` files, the integration activates. Workers receive the MCP context block, companion skill knowledge, and coding rules --- enabling them to search for UntitledUI toggle and button components instead of building from scratch.

## FAQ

**Q: Do I need to modify any Rune plugin files?**
A: No. Integrations are purely declarative via `talisman.yml` and `.mcp.json`. No changes to plugin skills, agents, or hooks are required.

**Q: What if my MCP server is not in `.mcp.json`?**
A: The integration will not activate. The `server_name` field must match a key in `.mcp.json`. Register the server first, then add the integration config. `/rune:talisman audit` will flag missing servers.

**Q: Can I use multiple MCP integrations simultaneously?**
A: Yes. Each namespace under `mcp_tools` is independent. All integrations whose triggers match the current context will activate. Their context blocks are concatenated in the agent prompt.

**Q: How do I disable an integration temporarily?**
A: Set all phases to `false` or remove the entry from `talisman.yml`. You can also set `trigger.always: false` and remove all trigger conditions --- but setting phases to `false` is cleaner.

**Q: Does `arc: true` override `appraise: false`?**
A: No. The `arc` phase flag enables the integration for the arc pipeline as a whole, but individual phase settings still control sub-phase activation. If `appraise: false`, the integration will not activate during the review sub-phase of arc, even with `arc: true`.

**Q: What happens if two integrations declare the same tool name?**
A: Each integration is namespaced. The same tool name can appear in multiple integrations (e.g., if two servers expose a `search` tool). The context block distinguishes them by namespace.

**Q: Can I override integration settings per-invocation?**
A: Not currently. Integrations are resolved from talisman config at workflow start. Per-invocation overrides are a potential future enhancement.

**Q: How do triggers interact with arc sub-phases?**
A: Triggers are evaluated once at workflow start against the initial context (changed files, task description). They are not re-evaluated per sub-phase. Phase routing controls sub-phase activation; triggers control initial activation.

**Q: Where do I put talisman.yml?**
A: Project-level config goes in `.claude/talisman.yml`. Global (user-level) config goes in `~/.claude/talisman.yml`. Project config takes precedence. The `integrations` section merges: project-level entries override global entries with the same namespace key.

**Q: What is the token cost of an integration?**
A: An active integration adds approximately 100-300 tokens to each agent prompt (tool list, categories, usage guidance). Rules files add their full content. Companion skills add their SKILL.md content. Use specific triggers to avoid activating integrations on irrelevant tasks.

---

## Troubleshooting & Error Behavior

### Integration Not Activating

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Integration not appearing in agent prompts | `server_name` not in `.mcp.json` | Register MCP server in `.mcp.json` first |
| Integration ignored for a phase | Phase flag set to `false` or missing | Set `phases.{phase}: true` in talisman config |
| Triggers not matching | File extensions or keywords don't match context | Check `trigger.file_extensions` and `trigger.keywords` against actual changed files |
| `server_name` silently skipped | Invalid format (contains spaces, special chars) | Use only `[a-zA-Z0-9_-]` characters |
| `namespace` silently skipped | Invalid format | Use only `[a-z0-9_-]` characters (lowercase) |

### Error Behavior by Component

| Component | Failure Mode | Behavior |
|-----------|-------------|----------|
| `readTalismanSection("integrations")` | Talisman unavailable or parse error | Returns `null` → `resolveMCPIntegrations()` returns `[]` (fail-open, zero overhead) |
| `evaluateTriggers()` | Trigger config malformed | Returns `false` → integration skipped for this context |
| `buildMCPContextBlock()` | Rule file not found | Inline error: `[rule unavailable: path]` — other rules still processed |
| `buildMCPContextBlock()` | Rule file blocked (path traversal) | Inline error: `[rule blocked: invalid path]` — security violation logged |
| `loadMCPSkillBindings()` | Companion skill not installed | Logged as warning — integration still activates without skill |
| MCP server unreachable | Server process crashed or not started | Tools listed in prompt but calls fail at runtime — not an integration framework error |

### Validation Errors

Run `/rune:talisman audit` to detect common configuration issues:

- **Missing `server_name`**: Every namespace must have a `server_name` that matches a key in `.mcp.json`
- **Invalid tool categories**: Only `search`, `details`, `compose`, `suggest`, `generate`, `validate` are accepted
- **Rule file paths**: Must be relative paths without `..` traversal — absolute paths and parent directory references are rejected
- **Skill binding format**: Must match `[a-z0-9-]+` (lowercase kebab-case)

### Debug Checklist

1. Verify MCP server is registered: check `.mcp.json` for `server_name` key
2. Verify talisman config: run `/rune:talisman audit` for schema validation
3. Check phase routing: ensure the workflow phase has `true` in `phases`
4. Check triggers: verify `file_extensions` or `keywords` match your context
5. Check agent prompts: look for `MCP TOOL INTEGRATIONS (Active)` section in agent output
