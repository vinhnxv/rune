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
| `design-sync` | `/rune:design-sync` | — | Figma URL | Design specs + implementation |
| `elevate` | `/rune:elevate` | — | None (scans echoes) | Promoted global echoes |
| `file-todos` | `/rune:file-todos` | — | Subcommand | TODO files in `tmp/` |
| `learn` | `/rune:learn` | — | None (scans session) | Correction patterns → echoes |
| `resolve-all-gh-pr-comments` | `/rune:resolve-all-gh-pr-comments` | — | PR number (auto) | Resolved PR threads |
| `resolve-gh-pr-comment` | `/rune:resolve-gh-pr-comment` | — | PR comment URL/ID | Resolved thread |
| `resolve-todos` | `/rune:resolve-todos` | — | TODO file path | Fixed code |
| `skill-testing` | `/rune:skill-testing` | — | Skill name | Test results |
| `team-status` | `/rune:team-status` | — | None | Team health report |
| `test-browser` | `/rune:test-browser` | — | PR# or branch | E2E test results |
| `ux-design-process` | `/rune:ux-design-process` | — | None (auto-loaded) | UX evaluation |
| `self-audit` | `/rune:self-audit` | — | `--dimension`, `--verbose` | `tmp/self-audit/*/SELF-AUDIT-REPORT.md` |

## MCP Integration Skills (Non-Invocable)

| Skill | Triggers | Purpose |
|-------|----------|---------|
| `untitledui-mcp` | Auto-loaded by design-system-discovery | UntitledUI 6-tool MCP integration, code conventions, builder protocol |
| `figma-to-react` | Auto-loaded during design-sync workflows | Figma MCP 4-tool integration for design extraction |

MCP integration is configured via `talisman.yml` → `integrations.mcp_tools`. Use `/rune:talisman guide integrations` for setup help.

## Skill Flags Quick Reference

| Skill | Key Flags |
|-------|-----------|
| `brainstorm` | `--quick`, `--deep` |
| `devise` | `--quick`, `--brainstorm-context PATH`, `--no-brainstorm`, `--no-forge`, `--exhaustive` |
| `appraise` | `--deep` |
| `audit` | `--deep`, `--standard`, `--incremental`, `--dirs`, `--focus` |
| `arc` | `--resume`, `--no-forge`, `--skip-freshness` |
| `arc-batch` | `--auto-merge`, `--no-merge` |
| `arc-issues` | `--label`, `--issue`, `--max-issues` |
| `strive` | `--approve`, `--worktree` |
| `self-audit` | `--dimension <D>`, `--verbose` |

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
| `design-sync` | Per phase | 10-30 min |
| `elevate` | None | 1-2 min |
| `file-todos` | None | < 1 min |
| `learn` | None | 2-5 min |
| `resolve-all-gh-pr-comments` | Per comment | 5-20 min |
| `resolve-gh-pr-comment` | None | 1-3 min |
| `resolve-todos` | Per batch | 5-15 min |
| `skill-testing` | None | 2-10 min |
| `team-status` | None | < 1 min |
| `test-browser` | None | 3-10 min |
| `ux-design-process` | None | 2-5 min |
| `rest` | None | < 1 min |
