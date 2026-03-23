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

### Phase 2.7: Semantic Consistency Validation

Cross-field consistency checks that detect logical contradictions between config values.
Run `validate-talisman-consistency.sh` and present findings inline with Phase 3 report.

```
result = Bash("bash ${RUNE_PLUGIN_ROOT}/scripts/validate-talisman-consistency.sh \
  .rune/talisman.yml . ${RUNE_PLUGIN_ROOT}")
parsed = JSON.parse(result)

Checks (6 rules):
  TC-001: max_ashes >= 7 (built-in) + len(ashes.custom[])
          CRITICAL if under — custom agents silently trimmed
  TC-002: ashes.custom[].source: local → .claude/agents/{agent}.md must exist
          CRITICAL if missing — agent never spawns (silent failure)
  TC-003: ashes.custom[].source: plugin → agent file in registry/ or agents/
          HIGH if missing — agent reference broken
  TC-004: sum(ashes.custom[].context_budget) <= 100%
          HIGH if over — each agent receives less than requested
  TC-005: audit.deep.max_dimension_agents >= len(audit.deep.dimensions)
          HIGH if under, INFO if exact match (no buffer)
  TC-006: dedup_hierarchy entries match known built-in + custom prefixes
          INFO for orphaned entries (retired agents)
```

### Phase 2.8: Companion File Validation

When companion files (`talisman.ashes.yml`, `talisman.integrations.yml`) exist alongside the main `talisman.yml`, validate cross-file consistency.

```
Checks:
  DUP-001 (CRITICAL) — Same top-level key in multiple files
    Scan all files for duplicate top-level keys.
    Example: `ashes:` in both talisman.yml and talisman.ashes.yml
    Action: BLOCK — duplicate keys cause undefined merge behavior

  VER-001 (HIGH) — `version:` found in companion file
    The `version:` key must only appear in the main talisman.yml.
    Companion files inherit the version from main.
    Action: WARN — suggest removing from companion

  LOC-001 (INFO) — Section in "wrong" file
    A section exists in a file that doesn't match the expected mapping.
    Example: `codex:` in main talisman.yml instead of talisman.integrations.yml
    Action: SUGGEST — offer to move via /rune:talisman split

  ORP-001 (INFO) — Orphaned companion sections
    Companion file contains sections that don't match expected mapping.
    Example: `arc:` in talisman.ashes.yml (should be in main)
    Action: SUGGEST — offer to move to correct file
```

#### Expected Section Mapping

Sections are assigned to companion files by audience:

**`talisman.ashes.yml`** (agent registry):
- `ashes` — custom review agent definitions
- `user_agents` — inline agent definitions
- `extra_agent_dirs` — additional agent directories
- `doubt_seer` — cross-agent claim verification config

**`talisman.integrations.yml`** (external tools):
- `codex` — cross-model verification
- `codex_review` — codex review workflow settings
- `elicitation` — reasoning method configuration
- `horizon` — strategic assessment
- `evidence` — evidence verification
- `echoes` — agent memory configuration
- `state_weaver` — state machine validation
- `file_todos` — structured todo tracking

All other sections belong in the main `talisman.yml`.

**Note**: Single-file layouts (no companions) skip this phase entirely. LOC-001 findings are purely informational — single-file is always valid.

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
