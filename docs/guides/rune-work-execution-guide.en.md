# Rune User Guide (English): `/rune:strive` and `/rune:goldmask`

This guide covers Rune's implementation and impact analysis workflows:
- `/rune:strive` for swarm-based plan execution with self-organizing workers.
- `/rune:goldmask` for cross-layer impact analysis before or after changes.

Related guides:
- [Arc and batch guide (arc/arc-batch)](rune-arc-and-batch-guide.en.md)
- [Planning guide (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.en.md)
- [Code review and audit guide (appraise/audit/mend)](rune-code-review-and-audit-guide.en.md)

---

## 1. Quick Command Selection

| Situation | Recommended command |
|---|---|
| Implement a plan with swarm workers | `/rune:strive plans/my-plan.md` |
| Implement with human approval per task | `/rune:strive plans/my-plan.md --approve` |
| Analyze blast radius of current changes | `/rune:goldmask` |
| Quick risk check (no agents) | `/rune:goldmask --quick` |
| Risk-sort files before editing | `/rune:goldmask --lore src/auth/` |
| Full pipeline (plan to merged PR) | `/rune:arc plans/my-plan.md` (uses strive internally) |

---

## 2. Prerequisites

### Required
- Claude Code with Rune plugin installed.
- Agent Teams enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).
- A plan file for strive (in `plans/` directory).

### Recommended
- Clean git branch (strive warns if on `main` and offers to create a feature branch).
- `gh` CLI installed for automatic PR creation (strive Phase 6.5).
- Sufficient token budget for multi-agent work.

### Optional
- `codex` CLI for cross-model verification after implementation.
- `.claude/talisman.yml` for tuning worker count, ward commands, and commit format.

---

## 3. `/rune:strive` — Swarm Execution

### 3.1 Basic usage

```bash
/rune:strive plans/my-plan.md
```

Rune parses the plan into tasks, spawns self-organizing workers, and implements the plan with quality gates.

### 3.2 Flags

| Flag | Effect |
|---|---|
| `--approve` | Require human approval before each task starts coding |
| `--worktree` | Use git worktree isolation — each worker gets its own copy of the repo (v1.122.0+) |

### 3.3 What happens during strive

1. **Parse plan** — extracts tasks with dependencies, clarifies ambiguities.
2. **Environment setup** — branch safety check (warns on `main`), stash dirty files.
3. **Create task pool** — `TaskCreate` with dependency chains (`blockedBy`).
4. **Summon workers** — Rune Smiths (implementation) and Trial Forgers (tests) claim tasks independently.
5. **Monitor progress** — polls TaskList every 30s, detects stalled workers (5-min warn, 10-min auto-release).
6. **Commit broker** — orchestrator applies patches and commits (prevents index.lock contention).
7. **Ward check** — runs auto-discovered quality gates + verification checklist.
8. **Doc-consistency** — detects version/count drift (non-blocking).
9. **Persist echoes** — saves implementation patterns to `.claude/echoes/workers/`.
10. **Cleanup** — shutdown workers, TeamDelete, restore stashed changes.
11. **Ship (optional)** — push + PR creation with generated template.

### 3.4 Worker types

| Worker | Role | When used |
|---|---|---|
| **Rune Smith** | Code implementation (TDD-aware) | Implementation tasks |
| **Trial Forger** | Test generation following project patterns | Test tasks |

Workers self-organize: they poll the task list, claim unblocked tasks, and work independently. The orchestrator (Tarnished) coordinates but never implements code directly.

### 3.5 Commit broker

Workers do not commit directly. Instead:
1. Worker generates a patch file after completing a task.
2. Orchestrator reads the patch and applies it with `git apply --3way` fallback.
3. One commit per task: `rune: <task-subject> [ward-checked]`.

This prevents git index.lock contention when multiple workers finish simultaneously.

### 3.6 Worktree isolation (v1.122.0+)

```bash
/rune:strive plans/my-plan.md --worktree
```

With `--worktree`, each worker gets its own git worktree — an isolated copy of the repository. Benefits:
- **No index.lock contention** — workers commit independently.
- **No merge conflicts during work** — each worktree is independent.
- **Automatic cleanup** — orphaned worktrees are garbage-collected by 3 safety nets:
  1. `on-session-stop.sh` auto-cleans on session exit (capped at 3).
  2. `session-team-hygiene.sh` detects orphans at session start.
  3. `/rune:rest` includes manual worktree cleanup.

PID liveness checks ensure worktrees from live sessions are never cleaned.

Configure via talisman:

```yaml
work:
  worktree:
    enabled: true        # Enable worktree isolation by default
```

### 3.7 Worker safety caps (v1.119.0+)

Workers have built-in safety limits to prevent infinite loops:
- **maxTurns: 60** — hard cap on agentic turns (reduced from 120 in v1.119.0).
- **Runtime budget enforcement** — `force_shutdown` signal triggers emergency worker shutdown.
- **TeammateIdle bypass** — work teams skip idle quality gates to prevent false stalls.

### 3.8 Worker scaling

| Task count | Workers |
|---|---|
| 1-5 tasks | 2 workers |
| 6-10 tasks | 3 workers |
| 11-19 tasks | 4 workers |
| 20+ tasks | 5 workers |

Configure max workers via `talisman.yml`:

```yaml
work:
  max_workers: 3
```

### 3.9 Human approval mode

```bash
/rune:strive plans/my-plan.md --approve
```

With `--approve`, the orchestrator presents each task via `AskUserQuestion` before workers start coding. This gives you control over task-level decisions for high-risk implementations.

### 3.10 Ship phase

After all tasks are complete and wards pass, strive optionally:
1. Pushes the branch to remote.
2. Creates a PR via `gh pr create` with a generated template.

This phase is opt-in. Without `gh` CLI or on an unsafe branch, it is skipped.

---

## 4. `/rune:goldmask` — Impact Analysis

### 4.1 Basic usage

```bash
/rune:goldmask
```

Analyzes the current diff across three layers: what changes (Impact), why it was built that way (Wisdom), and how risky the area is (Lore).

### 4.2 Modes

| Mode | Command | Agents | Use case |
|---|---|---|---|
| **Full investigation** | `/rune:goldmask` | 8 agents | Comprehensive analysis before risky refactors |
| **Quick check** | `/rune:goldmask --quick` | 0 (deterministic) | Fast verification after implementation |
| **Intelligence** | `/rune:goldmask --lore <files>` | 1 agent | Risk-sort files before manual editing |

### 4.3 Flags

| Flag | Effect |
|---|---|
| *(no flags)* | Full 3-layer investigation of current diff |
| `--quick` | Deterministic checks only (compare predicted vs committed files) |
| `--lore <files>` | Lore analysis only (output: risk-sorted file list) |
| `<diff-spec>` | Git range (`HEAD~3..HEAD`) or file paths |

### 4.4 Three layers

**Impact Layer** (5 tracers, Haiku):
Traces what must change across the dependency graph.
- Data layer tracer — schema, ORM, serializers, migrations
- API contract tracer — routes, handlers, validators, docs
- Business logic tracer — services, domain rules, state machines
- Event/message tracer — publishers, subscribers, dead letter queues
- Config/dependency tracer — env vars, config files, CI pipelines

**Wisdom Layer** (1 sage, Sonnet):
Investigates why the code was written this way.
- Git blame analysis, commit message intent classification
- Caution scores for safe modification

**Lore Layer** (1 analyst, Haiku):
Quantifies how risky the area is.
- Git churn metrics, co-change clustering
- Ownership concentration, hotspot detection
- Outputs `risk-map.json` for downstream use by forge, mend, and inspect

### 4.5 Output files

```
tmp/goldmask/{session_id}/
├── GOLDMASK.md          # Unified synthesis report
├── findings.json        # Machine-readable findings
├── risk-map.json        # Per-file risk scores
├── wisdom-report.md     # Wisdom Layer analysis
├── data-layer.md        # Impact tracer outputs
├── api-contract.md
├── business-logic.md
├── event-message.md
└── config-dependency.md
```

### 4.6 Integration with other workflows

Goldmask data is automatically consumed by:
- **Forge** — risk-aware section prioritization (Phase 1.5)
- **Mend** — risk-overlaid finding severity, risk context injection to fixers
- **Inspect** — risk-aware gap prioritization (Phase 1.3)
- **Devise** — predictive Goldmask for pre-implementation risk assessment
- **Arc** — Goldmask Verification (Phase 5.7) + Goldmask Correlation (Phase 6.5)

---

## 5. Combining Strive and Goldmask

### Pre-implementation risk assessment

```bash
/rune:goldmask                        # Understand blast radius
/rune:strive plans/my-plan.md         # Implement with risk awareness
```

### Post-implementation verification

```bash
/rune:strive plans/my-plan.md
/rune:goldmask --quick                # Verify predicted vs actual changes
```

### Full pipeline (recommended)

```bash
/rune:arc plans/my-plan.md
```

Arc runs goldmask and strive internally with checkpoint-based resume, so you get both automatically.

---

## 6. Use Cases

### 6.1 Feature implementation from plan

```bash
/rune:strive plans/2026-02-24-feat-user-auth-plan.md
```

Standard swarm execution. Workers parse the plan, claim tasks, and implement independently.

### 6.2 High-risk refactor with pre-analysis

```bash
/rune:goldmask
# Review GOLDMASK.md for blast radius
/rune:strive plans/refactor-auth-plan.md --approve
```

Run goldmask first to understand risk. Use `--approve` for task-level human oversight.

### 6.3 Quick risk check before manual editing

```bash
/rune:goldmask --lore src/auth/ src/middleware/
```

Risk-sort files by git history before you start editing manually.

### 6.4 Implementation with strict control

```bash
/rune:strive plans/my-plan.md --approve
```

Human approval per task. Good for critical paths or when onboarding to a new codebase.

---

## 7. Configuration

```yaml
# .claude/talisman.yml
work:
  max_workers: 3                    # Max parallel workers (default: auto-scaled)
  ward_commands:                    # Override quality gate commands
    - "make check"
    - "npm test"
  approve_timeout: 180              # Seconds (default: 3 min)
  commit_format: "rune: {subject} [ward-checked]"
  skip_branch_check: false          # Skip branch safety check
  branch_prefix: "rune/work"       # Feature branch prefix
  co_authors: []                    # Co-Authored-By lines

goldmask:
  enabled: true
  devise:
    enabled: true
    depth: basic                    # basic | enhanced | full
```

---

## 8. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Workers not claiming tasks | Tasks blocked by dependencies | Check task pool for `blockedBy` chains |
| Stalled worker (>5 min) | Complex task or worker stuck | Auto-released at 10 min. Lead re-assigns |
| Ward check fails | Implementation bug or test failure | Fix and re-run ward manually |
| Commit conflict | Two workers edited same file | File ownership via `blockedBy` should prevent this. Report if seen |
| Goldmask times out | Large diff or many files | Use `--lore` for lighter analysis |
| "No plan file" | Path incorrect or plan missing | Verify plan exists in `plans/` |
| Ship phase skipped | `gh` CLI missing or unsafe branch | Install `gh` and authenticate |
| Worktree cleanup stuck | Orphaned rune-work-* dirs | `/rune:rest` or restart session for auto-GC |
| Worker loops infinitely | maxTurns exceeded | v1.119.0+ caps at 60 turns with force_shutdown |
| Worker hangs after task | Idle bypass not active | Check TeammateIdle hook bypass for work teams |

---

## 9. Compact Command Reference

```bash
# Swarm execution
/rune:strive plans/my-plan.md                      # Standard execution
/rune:strive plans/my-plan.md --approve            # Human approval per task
/rune:strive plans/my-plan.md --worktree           # Worktree isolation

# Impact analysis
/rune:goldmask                                     # Full 3-layer investigation
/rune:goldmask --quick                             # Deterministic check
/rune:goldmask --lore src/auth/                    # Risk-sort files

# Full pipeline (includes both)
/rune:arc plans/my-plan.md
```
