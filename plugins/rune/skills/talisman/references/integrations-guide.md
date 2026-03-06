# Integrations Topic Guide

When topic matches `integrations`, `mcp`, `mcp-integration`, `untitledui`, or `untitled-ui`:

```
Explain 3 Integration Levels:

  Level 1 (Basic): .mcp.json only
    - Tools are available to Claude but NOT workflow-aware
    - No phase routing, no trigger conditions
    - Setup: claude mcp add --transport http my-tool https://api.example.com
    - Sufficient for simple tools used manually during conversation

  Level 2 (Talisman): + integrations section
    - Phase routing: which Rune phases can use the tools (devise/strive/forge/appraise/audit/arc)
    - Trigger conditions: auto-activate based on file types, paths, keywords
    - Skill binding: auto-load companion skill when active
    - Rules injection: inject project-specific rules into agent prompts
    - resolveMCPIntegrations() uses triple-gate: config + phase + trigger
    - Recommended for most MCP server integrations

  Level 3 (Full): + companion skill + rules files + metadata
    - Dedicated skill with deep domain knowledge (e.g., agent-conventions.md)
    - Project-specific rules for quality enforcement
    - Builder Protocol metadata: capabilities, conventions, library identifier
    - design-system-discovery auto-detection via discoverUIBuilder()
    - Metadata for discoverability (library_name, version, homepage, transport, auth)
    - Reference implementation: untitledui-mcp skill
    - Developer guide: docs/guides/mcp-integration-spec.en.md (repo root)

Show example YAML for Level 2 (generic):
  integrations:
    mcp_tools:
      my-tool:
        server_name: "my-tool"
        tools:
          - name: "my_tool_search"
            category: "search"
          - name: "my_tool_get"
            category: "details"
        phases:
          strive: true
          devise: true
          forge: true
        trigger:
          extensions: [".tsx", ".jsx"]
          keywords: ["frontend"]

Show example YAML for UntitledUI (Level 3 canonical):
  integrations:
    mcp_tools:
      untitledui:
        server_name: "untitledui"
        server_version: "2.1.0"
        tools:
          - { name: "search_components", category: "search" }
          - { name: "list_components", category: "search" }
          - { name: "get_component", category: "details" }
          - { name: "get_component_bundle", category: "details" }
          - { name: "get_page_templates", category: "search" }
          - { name: "get_page_template_files", category: "details" }
        phases:
          devise: true
          strive: true
          forge: true
          appraise: false
          audit: false
          arc: true
        skill_binding: "untitledui-mcp"
        trigger:
          extensions: [".tsx", ".ts", ".jsx"]
          paths: ["src/components/", "src/pages/"]
          keywords: ["frontend", "ui", "component", "design"]
        metadata:
          library_name: "UntitledUI"
          homepage: "https://www.untitledui.com"
          mcp_endpoint: "https://www.untitledui.com/react/api/mcp"
          transport: "http"
          auth: "oauth2.1-pkce | api-key | none"

Explain key configuration fields:
  - server_name: Must match key in .mcp.json exactly
  - server_version: Optional semver for schema drift detection (VEIL-EP-002)
  - tools[].category: One of: search, details, compose, suggest, generate, validate
  - phases: Which Rune phases can use these tools (true/false per phase)
  - skill_binding: Companion skill auto-loaded when integration is active
  - trigger.always: true overrides all other conditions (useful for universally-needed tools)
  - trigger.extensions: OR logic — any matching file extension activates
  - trigger.paths: OR logic — any matching path prefix activates
  - trigger.keywords: OR logic — any keyword in task description activates (case-insensitive)

Explain UntitledUI setup steps:
  1. Add MCP server:
     claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp
  2. (PRO) Add with API key:
     claude mcp add --transport http untitledui https://www.untitledui.com/react/api/mcp \
       --header "Authorization: Bearer YOUR_API_KEY"
  3. Run /rune:talisman init to auto-scaffold integrations config
     (or manually add integrations.mcp_tools.untitledui to talisman.yml)
  4. Run /rune:talisman audit to verify configuration is valid
  5. The untitledui-mcp skill is auto-loaded by design-system-discovery
     when @untitled-ui/* is detected in package.json

Explain MCP Integration Pipeline:
  resolveMCPIntegrations(phase, context) → triple-gated activation
    Gate 1: integrations.mcp_tools exists in talisman
    Gate 2: Phase match (integration enabled for current phase)
    Gate 3: Trigger match (file extension, path, keyword, or always:true)
  buildMCPContextBlock(integrations) → prompt injection for agents
  buildBuilderWorkflowBlock(uiBuilder) → structured SEARCH→GET→CUSTOMIZE→VALIDATE
  loadMCPSkillBindings(integrations) → companion skill preloading
```
