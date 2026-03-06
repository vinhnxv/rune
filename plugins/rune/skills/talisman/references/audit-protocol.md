# AUDIT — Comparison Protocol

## Phase 2: Deep Comparison

For each top-level section in the example:

```
Categories:
  MISSING   — Section exists in example but not in project
  OUTDATED  — Section exists but has deprecated/removed keys
  PARTIAL   — Section exists but missing sub-keys
  DIVERGENT — Value differs significantly from example default
  OK        — Section present and up-to-date
```

### Phase 2.5: Integration Validation

If `integrations.mcp_tools` section exists, validate each entry:

```
For each integrations.mcp_tools.{namespace}:
  1. server_name → check exists as key in .mcp.json
     MISSING: "Server '{server_name}' not found in .mcp.json"
  2. tools[].category → validate each is one of:
     search, details, compose, suggest, generate, validate
     INVALID: "Unknown tool category '{cat}' for tool '{name}'"
  3. phases → validate keys are valid Rune phases:
     devise, strive, forge, appraise, audit, arc
     INVALID: "Unknown phase '{phase}' in {namespace}.phases"
  4. skill_binding → check .claude/skills/{skill_binding}/SKILL.md exists
     MISSING: "Companion skill '{skill_binding}' not found"
  5. rules[] → check each file path exists
     MISSING: "Rule file '{path}' not found"
  6. trigger → warn if all trigger conditions are empty AND always !== true
     WARNING: "No triggers configured — integration will never activate"
```

## Phase 3: Gap Report

Present findings in priority order:

```
1. CRITICAL gaps — missing sections that affect core functionality
   (codex.workflows missing entries, deprecated file_todos keys, etc.)
2. RECOMMENDED — sections that improve workflow quality
   (missing codex deep integration keys, missing arc timeouts, etc.)
3. OPTIONAL — nice-to-have sections
   (context_monitor, horizon, etc.)
4. DIVERGENT — intentional? values that differ from defaults
   (max_budget, max_turns, etc.)
```

### Suggest Actions

```
For each gap:
  - Show the example value
  - Explain why it matters
  - Offer to fix via UPDATE subcommand
```
