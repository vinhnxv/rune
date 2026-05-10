# Phase 1: Rune Gaze (Scope Selection) + Phase 1.5: UX Reviewer Selection + Phase 1.6: Design Fidelity Reviewer Selection + Phase 1.7: Data Flow Integrity Reviewer Selection

## Phase 1: Rune Gaze

Classify changed files by extension. See [rune-gaze.md](../../roundtable-circle/references/rune-gaze.md).

```
for each file in changed_files:
  - *.py, *.go, *.rs, *.rb, *.java, etc.           → select Forge Warden
  - *.ts, *.tsx, *.js, *.jsx, etc.                  → select Glyph Scribe
  - Dockerfile, *.sh, *.sql, *.tf, CI/CD configs    → select Forge Warden (infra)
  - *.yml, *.yaml, *.json, *.toml, *.ini            → select Forge Warden (config)
  - *.md (>= 10 lines changed)                      → select Knowledge Keeper
  - .claude/**/*.md                                  → Knowledge Keeper + Ward Sentinel
  - Unclassified                                     → Forge Warden (catch-all)
  - Always: Ward Sentinel, Pattern Weaver, Veil Piercer
  - CLI-backed: detectAllCLIAshes() from talisman
  - Agent-backed custom: talisman ashes.custom[] trigger matching (see rune-gaze.md)
```

Check for project overrides in `.rune/talisman.yml`.

**Custom Ash discovery** happens HERE in Phase 1 (not Phase 3). The Rune Gaze algorithm reads `settings.ashes.custom[]` (v3.x: defaults to `[]`), validates agent names, matches triggers against `changed_files`, and adds matching custom Ashes to `selectedAsh`. This ensures custom Ashes have tasks created for them in Phase 2 and are spawned in Phase 3. See [rune-gaze.md](../../roundtable-circle/references/rune-gaze.md) for the full agent-backed custom Ash discovery algorithm.

## Phase 1.5: UX Reviewer Selection

In v3.x the UX subsystem is **off by default** (no user opt-in layer). UX reviewer agents
remain available for explicit invocation but no longer auto-spawn during appraise.

The UX agents (`ux-heuristic-reviewer`, `ux-flow-validator`, `ux-interaction-auditor`,
`ux-cognitive-walker`) are retained as standalone agents for callers that explicitly
include them. UX findings are non-blocking — they inform but don't block workflows. Prefixes:
- `UXH` — heuristic evaluation (Nielsen Norman 10 + Baymard guidelines)
- `UXF` — flow validation (loading/error/empty states)
- `UXI` — interaction audit (hover/focus/touch targets)
- `UXC` — cognitive walkthrough (first-time user simulation)

## Phase 1.6: Design Fidelity Reviewer Selection

In v3.x the `design_sync` subsystem is **off by default** (no user opt-in layer). The
`design-implementation-reviewer` agent is retained for explicit invocation but no longer
auto-spawns during appraise. When invoked manually, the reviewer expects a design inventory
artifact at `${outputDir}design-inventory*.json`; if absent, it emits an empty-context warning.

**Finding prefix**: `DES` — design fidelity findings (non-blocking by default).

**Timeout dead-end**: If `design-implementation-reviewer` task times out during Phase 4 Monitor, treat its contribution as empty findings. Runebinder proceeds with whatever other Ash outputs are present — deterministic behavior, no blocking.

**Prefix switching**: `design-implementation-reviewer` emits `DES-` prefixed findings when spawned via Phase 1.6 gate. The `FIDE-` prefix in the standalone specialist template is overridden by inscription metadata field `finding_prefix: "DES"` injected at Phase 2.

## Phase 1.7: Data Flow Integrity Reviewer Selection

Conditional data flow integrity agent spawning. Gate: 2+ stack layers detected in `changed_files`. (v3.x: data_flow is unconditional with `min_layers = 2` baked-in.) Uses the `flow-integrity-tracer` review agent.

```javascript
// Data Flow Integrity Reviewer Gate — follows the same pattern as Phase 1.6
const minLayers = 2  // v3.x baked-in

// Classify changed files into stack layers
const LAYER_PATTERNS = {
  frontend:   [/components\//, /pages\//, /views\//, /app\//, /\.tsx$/, /\.vue$/, /\.svelte$/],
  api:        [/controllers\//, /handlers\//, /routes\//, /api\//, /endpoints\//],
  model:      [/models\//, /entities\//, /schema\//, /\.prisma$/],
  migration:  [/migrations\//, /alembic\//, /\.sql$/],
  serializer: [/serializers\//, /dto\//, /schemas\//, /validators\//],
}

const layersTouched = new Set()
for (const file of changed_files) {
  for (const [layer, patterns] of Object.entries(LAYER_PATTERNS)) {
    if (patterns.some(p => p.test(file))) {
      layersTouched.add(layer)
    }
  }
}

if (layersTouched.size >= minLayers) {
  ash_selections.add("flow-integrity-tracer")
  log(`Phase 1.7: flow-integrity-tracer activated — ${layersTouched.size} layers: ${[...layersTouched].join(', ')}`)
} else {
  log(`Phase 1.7: flow-integrity-tracer skipped — ${layersTouched.size}/${minLayers} layers`)
}
```

**Skip conditions**: fewer than 2 stack layers detected in diff.

**Finding prefix**: `FLOW` — data flow integrity findings.

**Timeout dead-end**: If `flow-integrity-tracer` task times out during Phase 4 Monitor, treat its contribution as empty findings. Runebinder proceeds with whatever other Ash outputs are present.

### Dry-Run Exit Point

If `--dry-run` flag is set, display the plan and stop. Do NOT proceed to Phase 2.

**Displays:**
- Changed files grouped by classification (backend, frontend, docs, infra, config)
- Selected Ashes with file assignments per Ash
- Estimated team size (total Ash count)
- Chunk plan if file count exceeds CHUNK_THRESHOLD (default: 20)
- Dedup hierarchy preview: `SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > DES > AESTH > UXH > UXF > UXI > UXC > CDX`
- Warnings (e.g., `--deep + --partial` sparse findings warning)

**Does NOT create:**
- Teams (TeamCreate not called)
- Tasks (TaskCreate not called)
- State files (no `tmp/.rune-review-*.json`)
- inscription.json
- Signal directories (`tmp/.rune-signals/`)
- Agents (Agent tool not invoked)

**Use case:** Preview review scope before committing to full execution cost.
