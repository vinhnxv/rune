# Output Conventions

| Workflow | Directory | Files |
|----------|----------|-------|
| Reviews | `tmp/reviews/{id}/` | `{ash}.md`, `TOME.md` (with RUNE:FINDING markers), `inscription.json` |
| Audits | `tmp/audit/{id}/` | Same pattern |
| Brainstorms | `docs/brainstorms/YYYY-MM-DD-{name}-brainstorm.md` (persistent) | Brainstorm document with decisions, questions, insights |
| Brainstorm Workspace | `tmp/brainstorm-{timestamp}/` (session-scoped) | Advisor outputs, round transcripts, quality scores |
| Plans | `tmp/plans/{id}/research/`, `plans/YYYY-MM-DD-{type}-{name}-plan.md` | Research findings, brainstorm decisions, plan document |
| Forge | `tmp/forge/{id}/` | `{section-slug}-{agent-name}.md` enrichment files, `inscription.json`, `original-plan.md` (backup) |
| Work | `tmp/work/{timestamp}/` | `inscription.json`, `patches/*.patch`, `patches/*.json`, `proposals/*.md`, `codex-advisory.md` |
| Mend | `tmp/mend/{id}/` | `resolution-report.md`, fixer outputs |
| Arc | `tmp/arc/{id}/` | Phase artifacts (`enriched-plan.md`, `plan-review.md`, `concern-context.md`, `verification-report.md`, `work-summary.md`, `tome.md`, `tome-round-{N}.md`, `resolution-report.md`, `resolution-report-round-{N}.md`, `review-focus-round-{N}.json`, `audit-report.md`, `gap-analysis.md`) |
| Arc State | `.claude/arc/{id}/` | `checkpoint.json` (persistent, NOT in tmp/) |
| Scratch | `tmp/scratch/` | Session state |
| Codex | Per-workflow (see codex-cli skill) | `codex-oracle.md`, `codex-analysis.md`, `codex-plan-review.md`, `codex-advisory.md` |
| File-Todos | `todos/` (project root) | `{NNN}-{status}-{slug}.md` with YAML frontmatter. Persistent, project-scoped. Always active (suppress with `--todos=false`). Distinct from `tmp/work/*/todos/` (session-scoped per-worker logs) |
| Echoes | `.claude/echoes/{role}/` | `MEMORY.md`, `knowledge.md`, `archive/` |

All `tmp/` directories are ephemeral and can be safely deleted after workflows complete.

Brainstorm documents in `docs/brainstorms/` are persistent project knowledge and survive `/rune:rest`.

Echo files in `.claude/echoes/` are persistent and survive across sessions.
