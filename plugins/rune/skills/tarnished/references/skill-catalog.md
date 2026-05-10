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
| `arc-quick` | `/rune:arc-quick` | — | Plan file path | Lightweight 4-phase pipeline |
| `forge` | `/rune:forge` | — | Plan file path | Enriched plan |
| `mend` | `/rune:mend` | — | TOME file path | Fixed code |
| `verify` | `/rune:verify` | — | TOME file path | Verified findings |
| `inspect` | `/rune:inspect` | — | Plan file path | `tmp/inspect/*/VERDICT.md` |
| `goldmask` | `/rune:goldmask` | — | Diff spec / file list | Impact report |
| `debug` | `/rune:debug` | — | Failure description | ACH parallel investigation |
| `elicit` | `/rune:elicit` | — | Topic (optional) | Structured reasoning output |
| `rest` | `/rune:rest` | — | None | Cleans tmp/ |
| `file-todos` | `/rune:file-todos` | — | Subcommand | TODO files in `tmp/` |
| `resolve-all-gh-pr-comments` | `/rune:resolve-all-gh-pr-comments` | — | PR number (auto) | Resolved PR threads |
| `resolve-gh-pr-comment` | `/rune:resolve-gh-pr-comment` | — | PR comment URL/ID | Resolved thread |
| `resolve-todos` | `/rune:resolve-todos` | — | TODO file path | Fixed code |
| `skill-testing` | `/rune:skill-testing` | — | Skill name | Test results |
| `team-status` | `/rune:team-status` | — | None | Team health report |
| `runs` | `/rune:runs` | — | Subcommand (list/show/stats/failures) | Workflow run history |
| `supply-chain-audit` | `/rune:supply-chain-audit` | — | None | Dependency risk report |
| `variant-hunt` | `/rune:variant-hunt` | — | Finding ID / pattern | Variant findings |
| `pr-guardian` | `/rune:pr-guardian` | — | None (cron) | Auto-merge loop |
| `post-findings` | `/rune:post-findings` | — | TOME file | PR comment |
| `cc-inspect` | `/rune:cc-inspect` | — | None | Claude Code inspection |
| `self-audit` | `/rune:self-audit` | — | `--dimension`, `--verbose` | `tmp/self-audit/*/SELF-AUDIT-REPORT.md` |

> v3.0.0-alpha.2: removed routing rows for `arc-batch`, `arc-issues`, `arc-hierarchy`,
> `echoes`, `design-sync`, `elevate`, `learn`, `test-browser`, `ux-design-process`,
> `untitledui-mcp`, `figma-to-react` — those skills no longer ship with the plugin.

## Skill Flags Quick Reference

| Skill | Key Flags |
|-------|-----------|
| `brainstorm` | `--quick`, `--deep` |
| `devise` | `--quick`, `--brainstorm-context PATH`, `--no-brainstorm`, `--no-forge`, `--exhaustive` |
| `appraise` | `--deep` |
| `audit` | `--deep`, `--standard`, `--incremental`, `--dirs`, `--focus` |
| `arc` | `--resume`, `--no-forge`, `--skip-freshness` |
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
| `arc-quick` | Per phase | 10-30 min |
| `forge` | Per section | 5-15 min |
| `mend` | Per file | 3-10 min |
| `goldmask` | 8 tracers | 5-10 min |
| `elicit` | None | 2-5 min |
| `file-todos` | None | < 1 min |
| `resolve-all-gh-pr-comments` | Per comment | 5-20 min |
| `resolve-gh-pr-comment` | None | 1-3 min |
| `resolve-todos` | Per batch | 5-15 min |
| `skill-testing` | None | 2-10 min |
| `team-status` | None | < 1 min |
| `pr-guardian` | None (cron) | 5 min/tick |
| `rest` | None | < 1 min |
