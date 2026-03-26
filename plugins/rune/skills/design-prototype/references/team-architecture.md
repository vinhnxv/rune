# Agent Team Architecture

When >= 3 components AND `--no-team` is NOT set, the pipeline uses Agent Teams for parallel extraction and synthesis.

```
if components.length >= 3 AND NOT flags.noTeam:
  teamName = "rune-prototype-{timestamp}"
  try:
    TeamCreate({ team_name: teamName })

  // Create extraction tasks
  for component in components:
    TaskCreate({
      subject: "Extract + synthesize {component.name}",
      description: "Run figma_to_react, match against builder, synthesize prototype + story",
      metadata: { phase: "extract-synthesize", component: component.name }
    })

  // Spawn workers (max 5)
  workerCount = min(components.length, 5)
  for i in range(workerCount):
    Agent(team_name=teamName, name="proto-worker-{i+1}", ...)
  finally:
```

## Team Cleanup

### Teammate Fallback Array

```javascript
allMembers = ["proto-worker-1", "proto-worker-2", "proto-worker-3", "proto-worker-4", "proto-worker-5"]
```

### Protocol

Follow standard shutdown from [engines.md](../../../skills/team-sdk/references/engines.md#shutdown).

### Post-Cleanup

No skill-specific post-cleanup steps.

## Worker Trust Hierarchy

| Source | Priority | Usage |
|--------|----------|-------|
| Figma design (via figma_to_react) | 1 (highest) | Visual structure, layout, spacing |
| Design tokens (tokens-snapshot) | 2 | Colors, typography, spacing values |
| UI library match (builder search) | 3 | Real component API, props, variants |
| Stack conventions (detected) | 4 | Import paths, naming, file structure |
| Storybook patterns (project) | 5 | Story format, decorator usage |
| Generic defaults | 6 (lowest) | Fallback when no other source available |
