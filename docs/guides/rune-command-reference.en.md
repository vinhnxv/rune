# Rune Command Reference (English)

A practical command index for Rune users.

Verified against this repository on **March 22, 2026**:
- command specs in `plugins/rune/commands/*.md`
- workflow skills in `plugins/rune/skills/*/SKILL.md`

Related guides:
- [Getting started](rune-getting-started.en.md)
- [Arc and batch guide](rune-arc-and-batch-guide.en.md)
- [Planning guide](rune-planning-and-plan-quality-guide.en.md)
- [Review and audit guide](rune-code-review-and-audit-guide.en.md)
- [Work execution guide](rune-work-execution-guide.en.md)
- [Advanced workflows guide](rune-advanced-workflows-guide.en.md)

---

## 1. Fastest Command Choice

| If you want to... | Run |
|-------------------|-----|
| Start from natural language and let Rune route | `/rune:tarnished` |
| Plan new work | `/rune:plan` (alias of `/rune:devise`) |
| Implement a plan | `/rune:work` (alias of `/rune:strive`) |
| Review current code changes | `/rune:review` (alias of `/rune:appraise`) |
| Run full end-to-end pipeline | `/rune:arc plans/...` |

---

## 2. Starter Aliases

| Command | Canonical Command | Purpose |
|---------|-------------------|---------|
| `/rune:plan` | `/rune:devise` | Beginner planning entry point |
| `/rune:work` | `/rune:strive` | Beginner implementation entry point |
| `/rune:review` | `/rune:appraise` | Beginner code review entry point |
| `/rune:quick` | `/rune:arc-quick` | Beginner quick pipeline entry point |

---

## 3. Core Workflow Commands

| Command | Purpose | Common Flags |
|---------|---------|--------------|
| `/rune:brainstorm` | Collaborative idea exploration (solo, roundtable, deep) | `--quick`, `--deep` |
| `/rune:devise` | Multi-agent planning pipeline | `--quick`, `--no-brainstorm`, `--no-forge`, `--exhaustive` |
| `/rune:forge` | Deepen an existing plan | `--exhaustive` |
| `/rune:plan-review` | Review code blocks in a plan (`inspect --mode plan`) | `--focus`, `--dry-run` |
| `/rune:strive` | Execute tasks from a plan with workers | `--approve`, `--worktree` |
| `/rune:goldmask` | Impact/risk analysis before or after change | `--mode quick|deep` |
| `/rune:appraise` | Multi-agent code review of current diff | `--deep`, `--dry-run`, `--max-agents` |
| `/rune:audit` | Full-codebase audit | `--focus`, `--incremental`, `--deep`, `--dry-run` |
| `/rune:mend` | Resolve findings from TOME | `--all`, `--max-fixers` |
| `/rune:inspect` | Plan-vs-implementation gap audit | `--focus`, `--mode plan`, `--fix`, `--dry-run` |
| `/rune:arc` | Full pipeline from plan to ship/merge | `--resume`, `--no-forge`, `--approve`, `--no-pr`, `--no-merge` |
| `/rune:arc-quick` | Lightweight plan -> work -> review pipeline | `--force` |

---

## 4. Advanced and Batch Commands

| Command | Purpose | Common Flags |
|---------|---------|--------------|
| `/rune:arc-batch` | Run arc over many plans sequentially | `--resume`, `--dry-run`, `--no-merge`, `--smart-sort` |
| `/rune:arc-hierarchy` | Execute parent/child plan decomposition | `--resume`, `--dry-run` |
| `/rune:arc-issues` | Execute issue-driven arc batches from GitHub | `--label`, `--all`, `--resume`, `--cleanup-labels` |
| `/rune:echoes` | Manage persistent memory and Remembrance docs | `show`, `init`, `prune`, `remember`, `promote`, `remembrance`, `migrate` |
| `/rune:learn` | Extract reusable session learnings into Echoes | no required flags |
| `/rune:test-browser` | Standalone browser E2E checks | `[PR#]`, `--headed`, `--max-routes` |
| `/rune:debug` | ACH-based parallel hypothesis debugging | bug/problem description |

---

## 5. Utility Commands

| Command | Purpose |
|---------|---------|
| `/rune:tarnished` | Unified natural-language router across workflows |
| `/rune:talisman` | Configure and audit `talisman.yml` (`init`, `audit`, `update`, `guide`, `status`, `split`, `merge`) |
| `/rune:elicit` | Structured reasoning method selection |
| `/rune:file-todos` | Session-scoped file-based todo operations |
| `/rune:rest` | Clean completed workflow artifacts under `tmp/` |

---

## 6. Cancellation Commands

| Command | Stops |
|---------|-------|
| `/rune:cancel-review` | Active review session |
| `/rune:cancel-codex-review` | Active codex-review session |
| `/rune:cancel-audit` | Active audit session |
| `/rune:cancel-arc` | Active arc pipeline |
| `/rune:cancel-arc-batch` | Active arc-batch loop |
| `/rune:cancel-arc-hierarchy` | Active arc-hierarchy loop |
| `/rune:cancel-arc-issues` | Active arc-issues loop |

---

## 7. Suggested Paths

| Scenario | Sequence |
|----------|----------|
| First-time user | `/rune:plan` -> `/rune:work` -> `/rune:review` |
| High-control implementation | `/rune:devise` -> `/rune:plan-review` -> `/rune:strive --approve` -> `/rune:appraise` |
| Full autonomous delivery | `/rune:arc plans/...` |
| Backlog automation | `/rune:arc-issues --label "rune:ready"` |
| Post-session learning | `/rune:learn` -> `/rune:echoes show` |

---

## 8. Accuracy Notes

- This reference intentionally avoids hard-coding volatile internal counts (for example, exact talisman section totals).
- Use `/rune:talisman status` for live configuration health in your current project.
