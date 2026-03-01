# Rune User Guide (English): `/rune:arc-hierarchy`, `/rune:arc-issues`, and `/rune:echoes`

This guide covers Rune's advanced workflows for power users:
- `/rune:arc-hierarchy` for executing hierarchical parent/child plan decompositions.
- `/rune:arc-issues` for GitHub Issues-driven batch execution.
- `/rune:echoes` for managing persistent agent memory.
- `/rune:learn` for session self-learning (v1.126.0+).
- `/rune:test-browser` for standalone browser E2E testing (v1.126.0+).
- `/rune:debug` for parallel hypothesis debugging.

Related guides:
- [Arc and batch guide (arc/arc-batch)](rune-arc-and-batch-guide.en.md)
- [Planning guide (devise/forge/plan-review/inspect)](rune-planning-and-plan-quality-guide.en.md)
- [Code review and audit guide (appraise/audit/mend)](rune-code-review-and-audit-guide.en.md)
- [Work execution guide (strive/goldmask)](rune-work-execution-guide.en.md)

---

## 1. Quick Command Selection

| Situation | Recommended command |
|---|---|
| Execute parent plan with ordered child plans | `/rune:arc-hierarchy plans/parent-plan.md` |
| Process GitHub issues as work queue | `/rune:arc-issues --label "rune:ready"` |
| Process specific issue numbers | `/rune:arc-issues 42 55 78` |
| Initialize agent memory for project | `/rune:echoes init` |
| View memory state across roles | `/rune:echoes show` |
| Remember something permanently | `/rune:echoes remember "Always use UTC timestamps"` |
| Prune stale memory entries | `/rune:echoes prune` |
| Extract learnings from current session | `/rune:learn` |
| Run browser E2E tests without arc | `/rune:test-browser` |
| Run browser tests for a specific PR | `/rune:test-browser 42` |
| Debug a complex bug with parallel agents | `/rune:debug "bug description"` |

---

## 2. `/rune:arc-hierarchy` — Hierarchical Plan Execution

### 2.1 When to use

Use hierarchical plans when a feature has:
- Multiple implementation phases that must run in strict order.
- Cross-phase artifact dependencies (one phase produces types/files another consumes).
- Tasks too large for a single arc run but too coupled for independent plans.

### 2.2 Workflow

1. **Plan** — run `/rune:devise` and select "Hierarchical" at Phase 2.5 (appears when complexity >= 0.65).
2. **Review** — inspect the parent plan's execution table and dependency contract matrix.
3. **Execute** — run `/rune:arc-hierarchy plans/parent-plan.md`.
4. **Each child** runs its own full 26-phase arc pipeline (forge → work → review → mend → test → ship).
5. **Single PR** to main is created after all children complete.

### 2.3 Flags

| Flag | Effect |
|---|---|
| `--resume` | Resume from current execution table state |
| `--dry-run` | Show execution order and contracts, exit without running |
| `--no-merge` | Pass `--no-merge` to each child arc run |

### 2.4 Contracts: requires and provides

Each child plan declares what it requires and provides:

```yaml
# In parent plan execution table
children:
  - name: "01-database-schema"
    provides: [User model, migration files]
  - name: "02-api-endpoints"
    requires: [User model]
    provides: [REST API, OpenAPI spec]
  - name: "03-frontend"
    requires: [REST API]
```

Before running each child, Rune verifies all required artifacts exist. After completion, it verifies all promised artifacts were produced.

### 2.5 Failure handling

| Failure | Resolution strategies |
|---|---|
| Missing prerequisite | `pause` (default, ask user), `self-heal` (inject recovery tasks), `backtrack` (re-run provider) |
| Provides verification failed | Mark completed anyway, re-run child, skip dependents, or abort |
| Circular dependency | Detect and warn, list blocked children |
| Child arc failed | Warn, offer to skip dependents or abort |

Configure in talisman:

```yaml
work:
  hierarchy:
    missing_prerequisite: "pause"    # pause | self-heal | backtrack
    max_children: 12
    max_backtracks: 1
```

### 2.6 Cancel

```bash
/rune:cancel-arc-hierarchy
```

The currently executing child will finish normally. No new children will start.

---

## 3. `/rune:arc-issues` — GitHub Issues Batch Execution

### 3.1 When to use

Use arc-issues when you have a backlog of GitHub issues ready for automated implementation. Each issue becomes a plan, runs through the full arc pipeline, and produces a PR that auto-closes the issue on merge.

### 3.2 Input methods

```bash
# Label-driven (most common)
/rune:arc-issues --label "rune:ready"

# Page through ALL matching issues
/rune:arc-issues --label "rune:ready" --all

# File-based queue
/rune:arc-issues issues-queue.txt

# Inline issue numbers
/rune:arc-issues 42 55 78
```

### 3.3 Flags

| Flag | Effect |
|---|---|
| `--label <label>` | Fetch open issues with this label |
| `--all` | Page through all matching issues (not just first page) |
| `--page-size <N>` | Issues per page with `--all` (default: 10) |
| `--limit <N>` | Max issues to fetch (single batch, default: 20) |
| `--milestone <name>` | Filter by milestone |
| `--no-merge` | Skip auto-merge in each arc run |
| `--dry-run` | List issues and exit without running |
| `--force` | Skip plan quality gate (body < 50 chars) |
| `--resume` | Resume from progress file |
| `--cleanup-labels` | Remove orphaned `rune:in-progress` labels (> 2h old) |

### 3.4 Label lifecycle

| Label | Meaning | What to do |
|---|---|---|
| `rune:ready` | Issue ready for processing | (trigger label — you add this) |
| `rune:in-progress` | Currently being processed by Rune | Wait for completion |
| `rune:done` | Completed — PR linked via `Fixes #N` | Issue auto-closes on PR merge |
| `rune:failed` | Arc failed, needs human fix | Fix issue body → remove label → re-run |
| `rune:needs-review` | Plan quality low or conflicts detected | Add detail → remove label → re-run |

### 3.5 What happens per issue

1. Issue body is sanitized and converted to a plan file in `tmp/gh-plans/`.
2. Plan quality is validated (body >= 50 chars, or `--force` to skip).
3. Full 26-phase arc pipeline runs (forge → work → review → mend → test → ship → merge).
4. On success: PR with `Fixes #{number}`, success comment, `rune:done` label.
5. On failure: error comment, `rune:failed` label.

### 3.6 Resume and cancel

```bash
/rune:arc-issues --resume            # Continue from batch-progress.json
/rune:cancel-arc-issues              # Stop after current issue completes
```

### 3.7 Cleanup orphaned labels

If a session crashes mid-processing, issues may retain the `rune:in-progress` label:

```bash
/rune:arc-issues --cleanup-labels    # Remove labels on issues > 2h old
```

---

## 4. `/rune:echoes` — Agent Memory

### 4.1 What are echoes

Rune Echoes is a persistent memory system stored in `.claude/echoes/`. After reviews, audits, and implementations, agents persist patterns and learnings. Future sessions read these echoes to improve quality over time.

### 4.2 Five-tier lifecycle

| Tier | Name | Duration | How it works |
|---|---|---|---|
| Structural | **Etched** | Permanent | Architecture decisions, tech stack. Never auto-pruned |
| User-Explicit | **Notes** | Permanent | Created via `/rune:echoes remember`. Never auto-pruned |
| Tactical | **Inscribed** | 90 days unreferenced | Patterns from reviews/audits. Multi-factor scoring prunes bottom 20% |
| Agent-Observed | **Observations** | 60 days last access | Agent-discovered patterns. Auto-promoted to Inscribed after 3 references |
| Session | **Traced** | 30 days | Session-specific observations. Utility-based pruning |

### 4.3 Commands

```bash
/rune:echoes init                    # Initialize memory directories for project
/rune:echoes show                    # Display statistics per role
/rune:echoes prune                   # Score and archive stale entries
/rune:echoes reset                   # Clear all echoes (with backup)
/rune:echoes remember <text>         # Create a permanent Notes entry
/rune:echoes promote <ref> --category <cat>  # Promote to Remembrance doc
/rune:echoes remembrance [category]  # Query Remembrance documents
/rune:echoes migrate                 # Migrate echoes after upgrade
```

### 4.4 The `remember` command

```bash
/rune:echoes remember "Always use UTC for timestamps in this project"
/rune:echoes remember "The auth module uses bcrypt, not argon2"
```

Creates a Notes-tier entry that is permanent and never auto-pruned. Use this for project conventions, team decisions, or anything you want agents to always know.

### 4.5 How echoes improve workflows

| Workflow | How echoes are used |
|---|---|
| `/rune:appraise` | Reviewers read past findings to avoid duplicate reports |
| `/rune:audit` | Auditors build on previous audit knowledge |
| `/rune:devise` | Echo Reader agent surfaces relevant past learnings |
| `/rune:strive` | Workers read implementation patterns from past sessions |

### 4.6 Memory structure

```
.claude/echoes/
├── planner/MEMORY.md      # Planning patterns
├── workers/MEMORY.md      # Implementation patterns
├── reviewer/MEMORY.md     # Review findings
├── auditor/MEMORY.md      # Audit findings
├── notes/MEMORY.md        # User-created memories
├── observations/MEMORY.md # Agent-observed patterns
└── team/MEMORY.md         # Cross-role knowledge
```

Each MEMORY.md file has a 150-line cap with automatic pruning.

### 4.7 Remembrance (promotion)

High-confidence learnings can be promoted to human-readable solution documents:

```bash
/rune:echoes promote "N+1 query pattern in UserService" --category performance
```

Promoted entries become versioned docs in `docs/solutions/`. Categories: `build-errors`, `test-failures`, `runtime-errors`, `configuration`, `performance`, `security`, `architecture`, `tooling`.

### 4.8 Configuration

```yaml
# .claude/talisman.yml
echoes:
  version_controlled: false    # Set true to track echoes in git
  decomposition:
    enabled: true              # Query decomposition for search
  reranking:
    enabled: true              # Haiku reranking for search results
  semantic_groups:
    expansion_enabled: true    # Group expansion in search
```

---

## 5. `/rune:learn` — Session Self-Learning (v1.126.0+)

### 5.1 What it does

`/rune:learn` extracts reusable patterns from your current session and persists them to Rune Echoes. It runs a 4-phase pipeline:

1. **Scan** — reads the session transcript for patterns worth inscribing.
2. **Detect** — two specialized detectors:
   - **CLI Correction Detector** — finds cases where Claude corrected a CLI command, revealing API behavior.
   - **Review Recurrence Detector** — finds review findings that recurred across multiple arc cycles.
3. **Report** — presents discovered patterns for your review.
4. **Confirm + Write** — writes confirmed patterns to the Echo search index.

### 5.2 Usage

```bash
/rune:learn
```

This is a user-invocable skill with `disable-model-invocation: true` — Claude will not auto-invoke it. Run it manually at the end of productive sessions.

### 5.3 What it captures

| Pattern type | Example |
|---|---|
| CLI corrections | `git rebase --no-edit` doesn't work → use `--no-verify` instead |
| Review recurrences | "Missing null check on user.email" found in 3 consecutive reviews |
| Implementation patterns | Discovered that auth module uses bcrypt, not argon2 |

---

## 6. `/rune:test-browser` — Standalone Browser Testing (v1.126.0+)

### 6.1 When to use

Use standalone browser testing when you want to verify UI flows without running the full arc pipeline. This is a 9-step inline workflow (no agent teams needed).

### 6.2 Usage

```bash
# Test changed routes from current branch
/rune:test-browser

# Test a specific PR
/rune:test-browser 42

# Test with visible browser window
/rune:test-browser --headed

# Limit routes tested
/rune:test-browser --max-routes 5
```

### 6.3 Flags

| Flag | Effect |
|---|---|
| `<PR#>` | Test routes changed in a specific PR |
| `<branch>` | Test routes changed on a branch |
| `--headed` | Run browser tests with visible browser |
| `--max-routes <N>` | Limit number of routes tested |

### 6.4 What happens

1. **Scope detection** — discovers changed routes from PR, branch, or current HEAD.
2. **Route discovery** — maps file changes to UI routes.
3. **Server verification** — confirms dev server is running.
4. **Per-route test loop** — navigates each route, captures screenshots, verifies expected elements.
5. **Human gate handling** — detects OAuth, payment, and 2FA gates. Pauses for manual intervention.
6. **Interactive failure recovery** — for each failure, offers: Fix / Todo / Skip.
7. **Summary report** — presents pass/fail results.

Requires `agent-browser` CLI.

---

## 7. `/rune:debug` — Parallel Hypothesis Debugging

### 7.1 When to use

Use when bugs are complex, when single-agent debugging hits 3+ failures, or when root cause is unclear. Uses the **Analysis of Competing Hypotheses (ACH)** method.

### 7.2 Usage

```bash
/rune:debug "The API returns 500 when creating a user with special characters"
```

### 7.3 What happens

1. **Observe** — gathers evidence about the bug (error logs, stack traces, reproduction steps).
2. **Hypothesize** — generates multiple competing hypotheses.
3. **Investigate** — spawns parallel `hypothesis-investigator` agents, one per hypothesis.
4. **Synthesize** — merges evidence, assigns confidence scores, identifies most likely root cause.

Each investigator gathers both **confirming** and **falsifying** evidence with file:line citations. The structured output uses categorical verdicts: CONFIRMED / LIKELY / UNCERTAIN / FALSIFIED.

---

## 8. Use Cases

### 8.1 Large feature with shattered child plans

```bash
/rune:devise                                              # Select "Hierarchical" when offered
/rune:arc-hierarchy plans/2026-02-24-feat-auth-plan.md    # Execute all children in order
```

### 8.2 Sprint backlog from GitHub Issues

```bash
# Label issues as ready
/rune:arc-issues --label "rune:ready" --dry-run    # Preview queue
/rune:arc-issues --label "rune:ready" --no-merge   # Run with manual merge gate
```

### 8.3 Building project memory from scratch

```bash
/rune:echoes init                    # Set up directories
/rune:echoes remember "Use pnpm, not npm"
/rune:echoes remember "API responses follow JSON:API spec"
/rune:appraise                       # Review writes findings to echoes
/rune:echoes show                    # Check what was learned
```

### 8.4 Processing specific issues

```bash
/rune:arc-issues 42 55 78           # Process these three issues
/rune:arc-issues --resume           # Continue if interrupted
```

---

### 8.5 Debug a complex regression

```bash
/rune:debug "Payment processing times out intermittently on checkout"
```

### 8.6 End-of-session learning

```bash
/rune:learn                    # Extract patterns from this session
/rune:echoes show              # Verify learnings were persisted
```

---

## 9. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Hierarchy child fails | Complex dependency or implementation issue | Check child arc logs. Use `--resume` to retry |
| "Circular dependency detected" | Child plans have mutual requires | Fix contract matrix in parent plan |
| Missing prerequisite | Prior child did not produce expected artifact | Choose pause/self-heal/backtrack strategy |
| `rune:in-progress` label stuck | Session crashed during processing | `/rune:arc-issues --cleanup-labels` |
| Issue body too short | Body < 50 chars fails quality gate | Add detail or use `--force` |
| `gh` CLI errors | Not installed or not authenticated | Install `gh` and run `gh auth login` |
| Echoes not improving results | Memory not initialized | `/rune:echoes init` first |
| MEMORY.md too large | Exceeds 150-line cap | `/rune:echoes prune` to archive stale entries |
| Batch stopped after one issue | Stop hook state file removed | Check `.claude/arc-issues-loop.local.md` |
| `/rune:learn` finds no patterns | Short session or no corrections | Run after productive sessions with multiple iterations |
| Browser test fails to start | `agent-browser` CLI not installed | Install agent-browser: `npm install -g @anthropic-ai/agent-browser` |
| Debug agents return low confidence | Bug is not in the codebase | Check if bug is environment-specific or in dependencies |

---

## 10. Compact Command Reference

```bash
# Hierarchical execution
/rune:arc-hierarchy plans/parent-plan.md              # Execute children in order
/rune:arc-hierarchy plans/parent-plan.md --dry-run    # Preview execution order
/rune:arc-hierarchy plans/parent-plan.md --resume     # Resume from checkpoint
/rune:cancel-arc-hierarchy                            # Stop after current child

# GitHub Issues batch
/rune:arc-issues --label "rune:ready"                 # Label-driven
/rune:arc-issues --label "rune:ready" --all           # All matching issues
/rune:arc-issues 42 55 78                             # Specific issues
/rune:arc-issues --dry-run --label "rune:ready"       # Preview queue
/rune:arc-issues --resume                             # Continue batch
/rune:arc-issues --cleanup-labels                     # Remove orphaned labels
/rune:cancel-arc-issues                               # Stop batch

# Agent memory
/rune:echoes init                                     # Initialize
/rune:echoes show                                     # View state
/rune:echoes remember "Convention or decision"        # Permanent memory
/rune:echoes prune                                    # Archive stale entries
/rune:echoes reset                                    # Clear all (with backup)

# Session self-learning
/rune:learn                                           # Extract patterns from session

# Standalone browser testing
/rune:test-browser                                    # Test changed routes
/rune:test-browser 42                                 # Test PR #42
/rune:test-browser --headed --max-routes 5            # Visible browser, limit routes

# Parallel debugging
/rune:debug "Bug description"                         # ACH-based parallel debugging
```
