---
name: talisman
description: |
  Deep talisman.yml configuration expertise. Initialize, audit, update, and guide
  talisman configuration for any project. Scaffolds project-specific talisman.yml
  from the canonical example template, detects missing sections, and provides
  expert guidance on every configuration key.

  Use when the user says "init talisman", "setup talisman", "create talisman",
  "talisman audit", "check talisman", "talisman guide", "explain talisman",
  "update talisman", "talisman status", "what's in talisman", "configure rune",
  "rune config", "rune setup".

  Subcommands:
    /rune:talisman init          — Scaffold new talisman.yml for current project
    /rune:talisman audit         — Compare existing talisman against latest template
    /rune:talisman update        — Add missing sections to existing talisman
    /rune:talisman guide [topic] — Explain talisman sections and best practices
    /rune:talisman status        — Show current talisman summary

  Keywords: talisman, config, configuration, setup, init, initialize, scaffold,
  customize, rune config, rune setup, talisman audit, talisman gap, mcp,
  mcp integration, mcp setup, untitledui, untitled-ui, mcp tools, integrations.

  <example>
  user: "/rune:talisman init"
  assistant: "Detects project stack, scaffolds talisman.yml..."
  </example>

  <example>
  user: "/rune:talisman audit"
  assistant: "Comparing project talisman against latest template..."
  </example>

  <example>
  user: "/rune:talisman guide codex"
  assistant: "Explains Codex configuration keys..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[init|audit|update|guide|status]"
---

# /rune:talisman — Configuration Mastery

Deep expertise for `.rune/talisman.yml` — the project-level configuration
that controls all Rune agent behavior.

**References**:
- [Talisman sections](references/talisman-sections.md) — top-level sections with key descriptions
- [Configuration guide](../../references/configuration-guide.md) — full schema with types and defaults
- [Example template](../../talisman.example.yml) — canonical 950+ line example

## Subcommand Routing

Parse `$ARGUMENTS` to determine subcommand:

| First Word | Subcommand | Action |
|-----------|-----------|--------|
| `init` | INIT | Scaffold new talisman.yml |
| `audit` | AUDIT | Compare existing vs template |
| `update` | UPDATE | Add missing sections |
| `guide` | GUIDE | Explain configuration |
| `status` | STATUS | Show talisman summary |
| (empty) | STATUS | Default to status |

## INIT — Scaffold New Talisman

### Phase 1: Pre-flight Check

```
1. Check if .rune/talisman.yml already exists
   → If exists: warn and offer AUDIT instead
   → If not: proceed

2. Check if .claude/ directory exists
   → If not: create it
```

### Phases 2-5: Stack Detection, Template Read, Generate, Write

Detects project stack from manifest files (10 languages + CI/Docker/ORM signals), queries agent-search MCP for stack-relevant agents (Phase 2.3), reads canonical `talisman.example.yml`, generates stack-customized talisman with core + optional sections, detects MCP integrations from `.mcp.json`, scaffolds `stack_awareness.priority` from detected stack, writes to `.rune/talisman.yml`, and shows summary with next steps.

See [init-protocol.md](references/init-protocol.md) for the full Phase 2-5 pseudocode (stack signals, agent recommendations, customization table, MCP detection).

## AUDIT — Compare Against Template

### Phase 1: Read Both Files

```
1. Read project talisman: .rune/talisman.yml
   → If missing: suggest INIT instead
2. Read example template: ${CLAUDE_PLUGIN_ROOT}/talisman.example.yml
```

### Phases 2-4: Deep Comparison, Integration Validation, Gap Report

Classifies each section as MISSING/OUTDATED/PARTIAL/DIVERGENT/OK. Validates MCP integration entries (6 checks: server existence, tool categories, phase keys, skill bindings, rule files, trigger configuration). Runs semantic consistency validation (Phase 2.7: 6 cross-field checks via `validate-talisman-consistency.sh` — max_ashes capacity, source resolution, context budget totals, dimension agent caps, dedup hierarchy orphans). Presents gaps in priority order (CRITICAL → RECOMMENDED → OPTIONAL → DIVERGENT) with suggested actions.

See [audit-protocol.md](references/audit-protocol.md) for the full comparison and gap report pseudocode.

## UPDATE — Add Missing Sections

### Phase 1: Run AUDIT internally

Same as AUDIT Phase 1-3, but automated.

### Phase 2: Present Changes

```
Show what will be added/changed:
  - New sections to add
  - Keys to update
  - Deprecated keys to remove

AskUserQuestion: "Apply these changes?"
  - "Apply all"
  - "Apply critical only"
  - "Review each section"
```

### Phase 3: Apply Changes

```
Use Edit tool to modify .rune/talisman.yml:
  - Add missing sections at appropriate positions
  - Update deprecated keys
  - Preserve existing project-specific values
  - Add YAML comments for context
```

### Phase 4: Verify

```
Re-read the file to verify YAML validity
Show summary of changes applied
```

## GUIDE — Expert Configuration Guidance

### Routing

Parse remaining args after "guide":

```
/rune:talisman guide              → Overview of all sections
/rune:talisman guide codex        → Codex integration keys
/rune:talisman guide arc          → Arc pipeline configuration
/rune:talisman guide review       → Review/sharding/convergence
/rune:talisman guide work         → Work/strive settings
/rune:talisman guide ashes        → Custom Ashes configuration
/rune:talisman guide goldmask     → Goldmask per-workflow integration
/rune:talisman guide mend         → Mend settings
/rune:talisman guide integrations → MCP tool integrations (aliases: mcp, mcp-integration)
/rune:talisman guide reactions    → Declarative reaction engine policies (v2.5.1+)
/rune:talisman guide [topic]      → Match to closest section
```

### Response Format

For each topic:
1. What it controls
2. Key configuration keys with types and defaults
3. When to change from defaults
4. Common pitfalls
5. Example configuration snippet

Load details from:
- [talisman-sections.md](references/talisman-sections.md) for section summaries
- [configuration-guide.md](../../references/configuration-guide.md) for full schema
- [talisman.example.yml](../../talisman.example.yml) for canonical values

### Integrations Topic

Covers 3 integration levels (Basic `.mcp.json` only → Talisman phase routing + triggers → Full companion skill + builder protocol metadata), YAML examples for generic Level 2 and UntitledUI Level 3 canonical, all configuration fields, UntitledUI setup steps, and the `resolveMCPIntegrations()` triple-gate pipeline.

See [integrations-guide.md](references/integrations-guide.md) for the full integrations topic guide.

## STATUS — Talisman Summary

### Phase 1: Locate Talisman

```
1. Check .rune/talisman.yml (project)
2. Check ${CHOME}/talisman.yml (global) where CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
3. Report which level is active
```

### Phase 2: Parse and Summarize

```
For each top-level section present:
  - Section name
  - Key count
  - Notable overrides from defaults

Also report:
  - Total sections: N/[schema total]
  - Codex workflows enabled: [list]
  - Cost tier: [tier]
  - Custom Ashes: [count]
  - Ward commands: [list]
```

### Phase 2.5: Integration Status

```
If integrations.mcp_tools exists:
  For each integration:
    Show: namespace, server_name, tool count, phase bindings
    Show: trigger summary (extensions/paths/keywords or "always")
    Check: server_name found in .mcp.json? (✓ connected / ✗ not in .mcp.json)
    Check: skill_binding exists? (✓ loaded / ✗ missing / — not configured)

  Example output:
    MCP Integrations: 2 configured
      untitledui  → 5 tools, phases: devise/strive/forge
                    triggers: .tsx,.ts,.jsx | keywords: frontend,ui
                    server: ✓ connected | skill: untitledui-mcp ✓
      my-api      → 2 tools, phases: strive/arc
                    triggers: always
                    server: ✗ not in .mcp.json | skill: — not configured
```

### Phase 3: Health Check

```
Quick health indicators:
  ✓ codex.workflows includes arc
  ✓ file_todos uses schema v2 (no deprecated keys)
  ✓ dedup_hierarchy has stack-appropriate prefixes
  ✓ arc.timeouts defined
  ✓ integrations: N configured, N connected (if present)
  ✗ Missing: [sections not present]
```

## readTalisman Pattern

Always use SDK Read() — NEVER Bash for talisman access:

```javascript
// Primary: .rune/talisman.yml
try { return parseYaml(Read(".rune/talisman.yml")) } catch {}
// Legacy fallback: .claude/talisman.yml
try { return parseYaml(Read(".claude/talisman.yml")) } catch {}

// Global level (fallback)
Read("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/talisman.yml")

// NEVER: Bash("cat ~/.claude/talisman.yml") — ZSH tilde bug
```

## Persona

Use Rune's Elden Ring-inspired tone:

```
The Tarnished studies the Talisman...
  Section map loaded, 17 active in your project.
  4 gaps detected — 1 critical, 2 recommended, 1 optional.
```

```
A new Talisman is forged for this project.
  Stack detected: Python + FastAPI
  Ward commands: pytest, mypy --strict
  Codex enabled for: review, audit, plan, forge, work, arc
```
