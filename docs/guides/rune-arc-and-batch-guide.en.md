# Rune User Guide (English): `/rune:arc` and `/rune:arc-batch`

This guide explains practical usage of Rune's two delivery workflows:
- `/rune:arc` for one plan end-to-end.
- `/rune:arc-batch` for multiple plans in sequence.

It focuses on execution safety, recovery, and real delivery scenarios.

Related guide:
- [Rune planning guide (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.en.md)

---

## 1. Quick Command Selection

| Situation | Recommended command |
|---|---|
| You want to implement one plan with full quality gates | `/rune:arc plans/my-plan.md` |
| You have many plans and want sequential automation | `/rune:arc-batch plans/*.md` |
| You need to continue interrupted work | `/rune:arc ... --resume` or `/rune:arc-batch --resume` |
| You want PRs but no auto-merge | Add `--no-merge` |

---

## 2. Prerequisites

### Required
- Claude Code with Rune plugin installed.
- Agent Teams enabled.
- Valid plan files in repository.

### Recommended
- `gh` CLI installed and authenticated for auto PR/merge.
- Run from a clean branch (Rune can create feature branch when started on `main`).
- Sufficient token budget for multi-agent workflows.

### Optional
- `codex` CLI for cross-model verification phases.
- `.rune/talisman.yml` for tuning (timeouts, bot review, merge behavior, testing policy).

---

## 3. Plan Path and Plan Quality Rules

### Plan path safety
Use plan paths that are:
- Relative paths.
- Non-symlink paths.
- Free of `..` traversal.
- Limited to safe characters (`a-zA-Z0-9._-/`).

### Plan quality
For better arc reliability:
- Include acceptance criteria checkboxes (`- [ ]`).
- Keep file references current.
- Include `git_sha` in frontmatter for freshness scoring.

---

## 4. `/rune:arc` Step-by-Step

### 4.1 Start arc

```bash
/rune:arc plans/my-plan.md
```

### 4.2 Useful arc flags

| Flag | Effect |
|---|---|
| `--resume` | Resume from checkpoint |
| `--no-forge` | Skip plan enrichment |
| `--skip-freshness` | Skip freshness gate |
| `--approve` | Human approval per work task |
| `--confirm` | Pause when plan review is all-CONCERN |
| `--no-test` | Skip test phase |
| `--no-pr` | Skip PR creation |
| `--no-merge` | Skip auto merge |
| `--draft` | Create draft PR |
| `--bot-review` | Force-enable bot review phases |
| `--no-bot-review` | Force-disable bot review phases |

### 4.3 What arc checks before implementation
Arc pre-flight validates:
- Concurrent active arc sessions.
- Plan path safety.
- Branch safety and branch creation strategy.
- Plan freshness (unless explicitly skipped).

### 4.4 What arc executes
Arc runs a phased pipeline including:
- Plan readiness: Forge, Plan Review, Plan Refinement, Verification, Semantic Verification, Design Extraction, Task Decomposition.
- Implementation quality: Work, Design Verification, Gap Analysis, Codex Gap Analysis, Gap Remediation, Goldmask Verification.
- Convergence: Code Review (--deep), Goldmask Correlation, Mend, Verify Mend, Design Iteration loops.
- Delivery: Test (3-tier: unit/integration/E2E), Test Coverage Critique, Pre-Ship Validation, Release Quality Check, Ship, Bot Review Wait, PR Comment Resolution, Merge.

> **Note (v1.120.2+):** The arc pipeline now has 43 phases (up from the original 23), with the addition of Design Extraction, Design Prototype, Design Verification, Design Iteration, UX Verification, and Pre-Ship Validation phases.

### 4.5 Where to inspect state
- Checkpoint: `.rune/arc/{arc-id}/checkpoint.json`
- Artifacts/reports: `tmp/arc/{arc-id}/`

### 4.6 Resume behavior
`--resume` validates checkpoint schema and artifact integrity. If an artifact is missing/tampered, related phases are demoted and re-run safely.

---

## 5. `/rune:arc-batch` Step-by-Step

### 5.1 Start batch

```bash
/rune:arc-batch plans/*.md
```

Queue file variant:

```bash
/rune:arc-batch batch-queue.txt
```

### 5.2 Useful batch flags

| Flag | Effect |
|---|---|
| `--dry-run` | Preview queue only |
| `--no-merge` | Keep PRs open |
| `--resume` | Continue pending plans |
| `--no-shard-sort` | Preserve raw input order |
| `--smart-sort` | Force smart ordering on any input type (v1.117.0+) |

### 5.3 Batch pre-flight
Rune validates each plan file for:
- Existence.
- Symlink rejection.
- Traversal rejection.
- Non-empty content.
- Character allowlist path safety.
- Duplicate path handling.

### 5.4 Batch loop behavior
Batch uses a stop-hook loop (not subprocess polling):
- First plan is started.
- On each stop event, hook updates progress and injects next arc prompt.
- Loop continues until no pending plans remain.

Important behavior:
- Internal arc invocation in batch includes `--skip-freshness`.
- Smart ordering (v1.117.0+) is **opt-in** — glob inputs prompt with 3 options: Smart / Alphabetical / As-discovered. Queue files respect user order by default.

### 5.4.1 Smart ordering modes

| Mode | Behavior | Configure via |
|---|---|---|
| `ask` (default) | Prompt user for ordering preference on glob inputs | `arc.batch.smart_ordering.mode: "ask"` |
| `auto` | Always apply smart ordering | `arc.batch.smart_ordering.mode: "auto"` |
| `off` | Never apply smart ordering | `arc.batch.smart_ordering.mode: "off"` |

Resume guard runs before talisman checks to prevent reordering partial batches.

### 5.5 Batch state files
- Loop state: `.rune/arc-batch-loop.local.md`
- Progress ledger: `tmp/arc-batch/batch-progress.json`
- Iteration summaries (if enabled): `tmp/arc-batch/summaries/iteration-{N}.md`

### 5.6 Resume and cancellation
Resume pending plans:

```bash
/rune:arc-batch --resume
```

Stop future iterations:

```bash
/rune:cancel-arc-batch
```

Stop current arc as well:

```bash
/rune:cancel-arc
```

---

## 6. Special Cases and Operational Notes

### Arc freshness outcomes
- `PASS`: continue.
- `WARN`: continue with warning.
- `STALE`: interactive decision (re-plan, inspect drift, override, abort).

### Plan review all-CONCERN
- Default: proceed with warning after concern context generation.
- With `--confirm`: enforce explicit user decision.

### Pre-ship validator behavior
Pre-ship can emit WARN/BLOCK diagnostics for visibility but is designed non-halting in normal arc flow.

### Ship/merge skip conditions
Common skip reasons:
- Missing or unauthenticated `gh` CLI.
- No commits to push.
- Auto PR/merge disabled via flags/config.
- Unsafe/invalid branch context.

### Bot review is opt-in by default
Bot wait/comment-resolution phases run only when enabled via talisman or CLI flags.

### Batch resume scope
`/rune:arc-batch --resume` continues only plans still marked `pending`.

---

## 7. Use Cases: Greenfield and Brownfield

### 7.1 Greenfield Use Cases

#### Use case A: New feature from zero (single PR)
When to use:
- You are building a new capability with low legacy coupling.

Recommended flow:
1. Write plan (or generate one).
2. Run full arc.

```bash
/rune:arc plans/2026-02-24-feat-notifications-plan.md
```

Why this works:
- Full pipeline gives architecture checks, implementation, review, remediation, and testing before shipping.

Risk controls:
- Use `--draft` if you want early PR visibility.
- Keep `--no-merge` when stakeholder review is required.

#### Use case B: Greenfield launch sprint (multiple isolated plans)
When to use:
- You have many independent plans and want throughput.

Recommended flow:
1. Validate queue.
2. Run batch without auto-merge.
3. Merge manually after human review.

```bash
/rune:arc-batch plans/launch/*.md --dry-run
/rune:arc-batch plans/launch/*.md --no-merge
```

Why this works:
- Sequential automation reduces manual orchestration overhead while preserving plan-level traceability.

Risk controls:
- Keep plans small and independent.
- Use `/rune:arc-batch --resume` after interruptions.

#### Use case C: Hierarchical new system rollout with shards
When to use:
- Large greenfield initiative decomposed into shard plans.

Recommended flow:
- Prepare shard plans and run batch (default shard sorting on).

```bash
/rune:arc-batch plans/shards/*.md
```

Risk controls:
- Keep shard metadata consistent.
- Do not disable shard sorting unless order is intentionally manual.

### 7.2 Brownfield Use Cases

#### Use case D: Legacy module refactor with high blast radius
When to use:
- Existing module has unclear constraints and hidden coupling.

Recommended flow:
1. Optional pre-analysis (`/rune:goldmask`, `/rune:inspect`).
2. Execute arc with strict human control.

```bash
/rune:goldmask
/rune:arc plans/refactor-auth-legacy-plan.md --approve --no-merge --confirm --bot-review
```

Why this works:
- Goldmask + arc convergence catches regressions and unresolved risk before merge.

Risk controls:
- Keep `--no-merge` mandatory.
- Require explicit approvals for implementation tasks.

#### Use case E: Brownfield hotfix in production-sensitive area
When to use:
- You need fast remediation with guarded quality.

Recommended flow:

```bash
/rune:arc plans/hotfix-payment-timeout-plan.md --no-forge --confirm --no-merge
```

Why this works:
- Skipping forge can reduce cycle time; convergence and test phases still protect delivery quality.

Risk controls:
- Avoid `--skip-freshness` unless urgency is critical and plan correctness is confirmed.
- Keep manual merge gate.

#### Use case F: Backlog modernization on legacy codebase
When to use:
- You have many brownfield cleanup/refactor plans.

Recommended flow:

```bash
/rune:arc-batch plans/modernization/*.md --dry-run
/rune:arc-batch plans/modernization/*.md --no-merge
```

Operational guidance:
- Review each PR before merge.
- If interrupted, resume pending queue:

```bash
/rune:arc-batch --resume
```

---

## 8. Quick Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Arc does not start | Active arc session exists | `/rune:cancel-arc` or wait |
| Ship skipped | `gh` missing/auth missing, or ship disabled | Authenticate `gh` and review config |
| Batch stopped after one plan | Loop state removed/cancelled | Check batch state + progress files |
| Resume runs nothing | No `pending` plans | Inspect `tmp/arc-batch/batch-progress.json` |
| Plan rejected in pre-flight | Unsafe path/symlink/invalid file | Fix plan path and retry |
| Design phases skipped | No Figma URL in plan | Expected — design phases only run when `design_sync.enabled` and Figma URL present |
| Stop hook timeout | Arc phase exceeds staleness threshold | Thresholds are now 90min (phase) / 150min (batch) as of v1.125.1 |
| Workers stuck in infinite loop | maxTurns too high or idle bypass missing | Fixed in v1.119.0 — workers now have maxTurns=60 with runtime budget enforcement |

---

## 9. Compact Command Reference

```bash
# Arc
/rune:arc plans/my-plan.md
/rune:arc plans/my-plan.md --resume --no-merge

# Arc batch
/rune:arc-batch plans/*.md --dry-run
/rune:arc-batch plans/*.md --no-merge
/rune:arc-batch --resume

# Cancel
/rune:cancel-arc
/rune:cancel-arc-batch

# Arc batch with smart ordering
/rune:arc-batch plans/*.md --smart-sort          # Force smart ordering
```
