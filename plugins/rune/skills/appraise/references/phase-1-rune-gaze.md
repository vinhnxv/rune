# Phase 1: Rune Gaze (Scope Selection) + Phase 1.5: UX Reviewer Selection + Phase 1.6: Design Fidelity Reviewer Selection

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

**Custom Ash discovery** happens HERE in Phase 1 (not Phase 3). The Rune Gaze algorithm reads `talisman.yml` → `ashes.custom[]`, validates agent names, matches triggers against `changed_files`, and adds matching custom Ashes to `selectedAsh`. This ensures custom Ashes have tasks created for them in Phase 2 and are spawned in Phase 3. See [rune-gaze.md](../../roundtable-circle/references/rune-gaze.md) for the full agent-backed custom Ash discovery algorithm.

## Phase 1.5: UX Reviewer Selection

Conditional UX agent spawning. Gated by `talisman.ux.enabled` AND frontend files detected in `changed_files`.

```javascript
// UX Reviewer Gate — follows the same pattern as design-implementation-reviewer (rune-gaze.md §4)
const uxEnabled = talisman?.ux?.enabled === true
const hasFrontendFiles = changed_files.some(f =>
  [".tsx", ".jsx", ".vue", ".svelte", ".css", ".scss"].some(ext => f.endsWith(ext))
)

if (uxEnabled && hasFrontendFiles) {
  // Default: ux-heuristic-reviewer (UXH-prefixed findings, non-blocking by default)
  ash_selections.add("ux-heuristic-reviewer")

  // Optional deep UX agents (--deep flag or talisman overrides)
  if (flags['--deep']) {
    ash_selections.add("ux-flow-validator")       // UXF-prefixed findings
    ash_selections.add("ux-interaction-auditor")   // UXI-prefixed findings

    // Cognitive walker: expensive (opus), opt-in only
    if (talisman?.ux?.cognitive_walkthrough === true) {
      ash_selections.add("ux-cognitive-walker")    // UXC-prefixed findings
    }
  }
}
```

**Skip conditions**: `talisman.ux.enabled` is not `true`, or no frontend files in diff.

**UX findings are non-blocking by default** — they inform but don't block workflows. Prefixes:
- `UXH` — heuristic evaluation (Nielsen Norman 10 + Baymard guidelines)
- `UXF` — flow validation (loading/error/empty states)
- `UXI` — interaction audit (hover/focus/touch targets)
- `UXC` — cognitive walkthrough (first-time user simulation)

## Phase 1.6: Design Fidelity Reviewer Selection

Conditional design fidelity agent spawning. Gated by `talisman.design_review.enabled` AND frontend files detected in `changed_files`. Uses the `design-implementation-reviewer` specialist prompt loaded via `buildAshPrompt()`.

```javascript
// Design Fidelity Reviewer Gate — follows the same pattern as Phase 1.5 UX gate
// Requires BOTH design_review.enabled AND design_sync.enabled.
// design_review controls the appraise gate; design_sync provides the design artifacts.
// Without design_sync, the reviewer would spawn with broken context (no inventory).
const designReviewEnabled = talisman?.design_review?.enabled === true
const designSyncEnabled = talisman?.design_sync?.enabled === true
const hasFrontendFiles = changed_files.some(f =>
  [".tsx", ".jsx", ".vue", ".svelte", ".css", ".scss"].some(ext => f.endsWith(ext))
)

if (designReviewEnabled && designSyncEnabled && hasFrontendFiles) {
  ash_selections.add("design-implementation-reviewer")

  // Write design_context to inscription.json at Phase 2 (Forge Team)
  // Schema: { inventory_path: string, figma_url: string, component_count: number }
  // inventory_path — path to design inventory artifact from Shard 2 (arc design extraction)
  // figma_url     — Figma source URL from talisman.design_sync.figma_url (if set)
  // component_count — number of components in inventory (0 if inventory absent)
  //
  // Soft warning: if Shard 2 dependency artifacts are absent (inventory_path not found):
  if (!Glob(`${outputDir}design-inventory*.json`).length) {
    warn("Phase 1.6: design_context inventory not found — design-implementation-reviewer will run without component inventory context.")
  }
}
```

**Skip conditions**: `talisman.design_review.enabled` is not `true`, `talisman.design_sync.enabled` is not `true`, or no frontend files in diff.

**Finding prefix**: `DES` — design fidelity findings (non-blocking by default).

**Timeout dead-end**: If `design-implementation-reviewer` task times out during Phase 4 Monitor, treat its contribution as empty findings. Runebinder proceeds with whatever other Ash outputs are present — deterministic behavior, no blocking.

**Prefix switching**: `design-implementation-reviewer` emits `DES-` prefixed findings when spawned via Phase 1.6 gate. The `FIDE-` prefix in the standalone specialist template is overridden by inscription metadata field `finding_prefix: "DES"` injected at Phase 2.

## Phase 1.7: Data Flow Integrity Reviewer Selection

Conditional data flow integrity agent spawning. Gated by `talisman.data_flow.enabled` (default: true, opt-out) AND 2+ stack layers detected in `changed_files`. Uses the `flow-integrity-tracer` review agent.

```javascript
// Data Flow Integrity Reviewer Gate — follows the same pattern as Phase 1.6
const dataFlowEnabled = talisman?.data_flow?.enabled !== false  // default: true (opt-out)
const minLayers = talisman?.data_flow?.min_layers ?? 2

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

if (dataFlowEnabled && layersTouched.size >= minLayers) {
  ash_selections.add("flow-integrity-tracer")
  log(`Phase 1.7: flow-integrity-tracer activated — ${layersTouched.size} layers: ${[...layersTouched].join(', ')}`)
} else {
  log(`Phase 1.7: flow-integrity-tracer skipped — ${layersTouched.size}/${minLayers} layers`)
}
```

**Skip conditions**: `talisman.data_flow.enabled` is `false`, or fewer than `min_layers` (default 2) stack layers detected in diff.

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
