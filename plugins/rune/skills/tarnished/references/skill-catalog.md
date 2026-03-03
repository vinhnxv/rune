# Rune Skill Catalog

Complete reference for `/rune:tarnished` routing decisions.

## User-Invocable Skills (Primary Targets)

| Keyword | Skill | Delegates To | Input | Output |
|---------|-------|-------------|-------|--------|
| `plan` | `/rune:plan` | `/rune:devise` | Feature description | `plans/*.md` |
| `work` | `/rune:work` | `/rune:strive` | Plan file path | Code changes + commits |
| `review` | `/rune:review` | `/rune:appraise` | Git diff (auto) | `tmp/reviews/*/TOME.md` |
| `brainstorm` | `/rune:brainstorm` | — | Feature idea | `docs/brainstorms/*.md` |
| `devise` | `/rune:devise` | — | Feature description | `plans/*.md` |
| `strive` | `/rune:strive` | — | Plan file path | Code changes + commits |
| `appraise` | `/rune:appraise` | — | Git diff (auto) | `tmp/reviews/*/TOME.md` |
| `audit` | `/rune:audit` | — | None (full scan) | `tmp/audit/*/TOME.md` |
| `arc` | `/rune:arc` | — | Plan file path | Full pipeline → merged PR |
| `arc-batch` | `/rune:arc-batch` | — | Plan glob / queue file | Sequential batch execution |
| `arc-issues` | `/rune:arc-issues` | — | `--label` or `--issue` | GitHub Issues → plans → arc |
| `arc-hierarchy` | `/rune:arc-hierarchy` | — | Parent plan path | Hierarchical plan execution |
| `forge` | `/rune:forge` | — | Plan file path | Enriched plan |
| `mend` | `/rune:mend` | — | TOME file path | Fixed code |
| `inspect` | `/rune:inspect` | — | Plan file path | `tmp/inspect/*/VERDICT.md` |
| `goldmask` | `/rune:goldmask` | — | Diff spec / file list | Impact report |
| `elicit` | `/rune:elicit` | — | Topic (optional) | Structured reasoning output |
| `rest` | `/rune:rest` | — | None | Cleans tmp/ |
| `echoes` | `/rune:echoes` | — | Subcommand | Echo management |
| `talisman` | `/rune:talisman` | — | Subcommand (init/audit/update/guide/status) | Talisman config |
| `codex-review` | `/rune:codex-review` | — | Git diff (auto) | `tmp/codex-reviews/*/TOME.md` |

## Skill Flags Quick Reference

| Skill | Key Flags |
|-------|-----------|
| `brainstorm` | `--quick`, `--deep` |
| `devise` | `--quick`, `--brainstorm-context PATH`, `--no-brainstorm`, `--no-forge`, `--exhaustive` |
| `appraise` | `--deep` |
| `audit` | `--deep`, `--standard`, `--incremental`, `--dirs`, `--focus` |
| `arc` | `--resume`, `--skip-forge`, `--no-forge`, `--skip-freshness` |
| `arc-batch` | `--auto-merge`, `--no-merge` |
| `arc-issues` | `--label`, `--issue`, `--max-issues` |
| `strive` | `--approve`, `--worktree` |

## Prerequisite Map

| Skill | Requires | Check |
|-------|----------|-------|
| `brainstorm` | None | Always available |
| `strive` | Plan file | `Glob("plans/*.md")` |
| `mend` | TOME file | `Glob("tmp/reviews/*/TOME.md")` or `Glob("tmp/audit/*/TOME.md")` |
| `appraise` | Git changes | `git diff --stat` |
| `arc` | Plan file | `Glob("plans/*.md")` |
| `arc-batch` | Plan glob / queue | `Glob("plans/*.md")` |
| `arc-issues` | GitHub issues | GitHub labels or issue numbers |
| `arc-hierarchy` | Parent plan | `Glob("plans/*.md")` with child plans |
| `forge` | Plan file | `Glob("plans/*.md")` |
| `inspect` | Plan file | `Glob("plans/*.md")` |

## Duration Estimates

| Skill | Agents | Duration |
|-------|--------|----------|
| `brainstorm` (solo) | None | 1-2 min |
| `brainstorm` (roundtable) | 3 advisors | 3-5 min |
| `brainstorm` (deep) | 3 advisors + sages | 5-8 min |
| `devise` | Up to 7 | 5-15 min |
| `devise --quick` | 2-3 | 2-5 min |
| `strive` | Swarm | 10-30 min |
| `appraise` | Up to 8 | 3-10 min |
| `audit` | Up to 8 | 5-15 min |
| `arc` | Per phase | 30-90 min |
| `arc-batch` | Per plan | 45-240 min/plan |
| `arc-issues` | Per issue | 45-240 min/issue |
| `arc-hierarchy` | Per child | 45-240 min/child |
| `forge` | Per section | 5-15 min |
| `mend` | Per file | 3-10 min |
| `goldmask` | 8 tracers | 5-10 min |
| `elicit` | None | 2-5 min |
| `talisman` | None | 1-3 min |
| `codex-review` | Up to 4 | 5-15 min |
| `rest` | None | < 1 min |
