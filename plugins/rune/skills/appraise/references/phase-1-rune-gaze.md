# Phase 1: Rune Gaze (Scope Selection) + Phase 1.5: UX Reviewer Selection

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

Check for project overrides in `.claude/talisman.yml`.

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

### Dry-Run Exit Point

If `--dry-run` flag is set, display the plan and stop. Do NOT proceed to Phase 2.

**Displays:**
- Changed files grouped by classification (backend, frontend, docs, infra, config)
- Selected Ashes with file assignments per Ash
- Estimated team size (total Ash count)
- Chunk plan if file count exceeds CHUNK_THRESHOLD (default: 20)
- Dedup hierarchy preview: `SEC > BACK > VEIL > DOUBT > DOC > QUAL > FRONT > CDX`
- Warnings (e.g., `--deep + --partial` sparse findings warning)

**Does NOT create:**
- Teams (TeamCreate not called)
- Tasks (TaskCreate not called)
- State files (no `tmp/.rune-review-*.json`)
- inscription.json
- Signal directories (`tmp/.rune-signals/`)
- Agents (Agent tool not invoked)

**Use case:** Preview review scope before committing to full execution cost.
