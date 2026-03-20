---
name: self-audit
description: |
  Meta-QA self-audit for Rune's own workflow system. Audits agent definitions,
  workflow phases, rules, hooks for inconsistencies, contradictions, and drift.
  Produces SELF-AUDIT-REPORT.md with per-dimension scores and actionable findings.

  Use when: "audit rune itself", "check rune health", "self-audit", "meta-qa",
  "rune consistency check", "lint agents", "validate workflow", "check hooks".

  Covers: Workflow definition validation, agent prompt linting, rule consistency
  checking, hook integrity verification, echo-based recurrence tracking.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, TaskCreate, TaskList, TaskGet, TaskUpdate, TeamCreate, TeamDelete, SendMessage, AskUserQuestion
argument-hint: "[--mode static|runtime|all] [--dimension D] [--apply] [--verbose] [--dry-run] [--history] [--arc-id ID]"
---

# Self-Audit — Meta-Quality Analysis

Rune's self-improvement feedback loop. Analyzes the plugin's own infrastructure
for stale references, missing metadata, rule contradictions, and workflow
inconsistencies — then proposes fixes.

## Usage

```
/rune:self-audit                        # Default: static analysis
/rune:self-audit --mode static          # Analyze agents, skills, hooks, config
/rune:self-audit --mode runtime         # Analyze recent arc artifacts
/rune:self-audit --mode all             # Both static + runtime
/rune:self-audit --apply                # Propose and interactively apply fixes
/rune:self-audit --dry-run              # Show what --apply would propose without prompting
```

## Pre-flight: Concurrent Audit Guard

Before starting any analysis, check for an active self-audit from this or another session:

```javascript
// Check for active self-audit state files
const stateFiles = Glob('tmp/.rune-self-audit-*.json')
for (const sf of stateFiles) {
  const state = JSON.parse(Read(sf))
  // Skip if owned by a dead session
  const ownerAlive = Bash(`kill -0 ${state.owner_pid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
  if (ownerAlive === "alive" && state.status === "running") {
    const CHOME = Bash('echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"').trim()
    if (state.config_dir === CHOME) {
      log(`Another self-audit is already running (PID: ${state.owner_pid}, started: ${state.started_at}).`)
      log(`Wait for it to complete or cancel it first.`)
      return
    }
  }
  // Clean up orphaned state from dead sessions
  if (ownerAlive === "dead") {
    Bash(`rm -f "${sf}"`)
  }
}

// Write our own state file with session isolation fields
const timestamp = Date.now()
const CHOME = Bash('echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"').trim()
Write(`tmp/.rune-self-audit-${timestamp}.json`, JSON.stringify({
  status: "running",
  started_at: new Date().toISOString(),
  config_dir: CHOME,
  owner_pid: Bash('echo $PPID').trim(),
  session_id: CLAUDE_SESSION_ID,
  mode: mode
}))
```

On completion (success or error), update state file status to `"completed"` or `"failed"` and clean up.

## Static Mode Orchestration Protocol

The static analysis pipeline follows 7 phases using Agent Teams for parallel execution.

**Load skills**: `team-sdk`, `polling-guard`, `zsh-compat`, `rune-echoes`

### Phase 0: Pre-flight

```
Read talisman config:
  const talisman = readTalismanSection('misc')
  const config = talisman?.self_audit ?? { enabled: true }
  if (!config.enabled) { inform("Self-audit disabled via talisman"); return }

Parse arguments:
  const mode = $ARGUMENTS match --mode → extract value, else "static"
  const dimension = $ARGUMENTS match --dimension → extract value, else "all"
  const verbose = $ARGUMENTS includes "--verbose"
  const timestamp = Date.now()
  const outputDir = `tmp/self-audit/${timestamp}`

Create output directory:
  Bash(`mkdir -p "${outputDir}"`)
```

### Phase 1: Team Bootstrap + Agent Spawn

```
const teamName = `rune-self-audit-${timestamp}`
TeamCreate({ team_name: teamName })

// Create tasks (1 per dimension, or 4 if --dimension all)
const dimensions = dimension === "all"
  ? ["workflow", "prompt", "rule", "hook"]
  : [dimension]

for (const dim of dimensions) {
  TaskCreate({ subject: `${dim}-audit`, description: `Run ${dim} dimension checks` })
  Agent({
    name: `${dim}-auditor`,
    team_name: teamName,
    subagent_type: "general-purpose",
    prompt: buildAuditPrompt(dim, outputDir),
    run_in_background: true
  })
}
```

### Phase 2: Monitor

```
waitForCompletion(teamName, dimensions.length, {
  timeoutMs: 300000,
  pollIntervalMs: 30000
})
```

### Phase 3: Aggregate + Ground

```
Read all *-findings.md files from outputDir.
For each finding with a file:line citation:
  Verify file exists via Glob/Read
  Verify line content matches evidence quote
  Mark verified: true | false
  Drop findings with verified: false (hallucinated)

Calculate per-dimension scores:
  dimension_score = 100 - (P1_count * 15 + P2_count * 5 + P3_count * 1)
  clamped to [0, 100]

Generate SELF-AUDIT-REPORT.md using [aggregation.md](references/aggregation.md) template.
```

### Phase 4: Echo Persist

```
Read existing .rune/echoes/meta-qa/MEMORY.md (create if absent).
For each P1/P2 finding:
  Search existing echoes for matching finding ID pattern
  If found: increment recurrence_count, update last_seen date
  If new: append as Observations-tier entry
  If recurrence_count >= 3: promote to Inscribed tier
    confidence = min(0.95, confidence + 0.1)

Write updated MEMORY.md.
```

Echo entry format:

```markdown
### [YYYY-MM-DD] Pattern: {description}
- **layer**: observations | inscribed
- **source**: rune:self-audit {timestamp}
- **confidence**: 0.7-0.9
- **evidence**: `{file}:{line}` — {finding summary}
- **recurrence_count**: {N}
- **first_seen**: {date}
- **last_seen**: {date}
- **finding_ids**: [SA-WF-001, SA-AGT-003]
- {The actual pattern in 1-2 sentences}
```

### Phase 5: Present

```
Display summary:
  Overall score: {N}/100 ({verdict})
  Per-dimension: workflow={N}, prompt={N}, rule={N}, hook={N}
  Findings: {P1_count} critical, {P2_count} warnings, {P3_count} info
  Report: {outputDir}/SELF-AUDIT-REPORT.md
  Echoes: {N} new, {N} recurrent, {N} promoted

Offer next steps via AskUserQuestion:
  - "Review full report" → open report
  - "Show critical findings only" → filter P1
  - "Done" → proceed to cleanup
```

### Phase 6: Cleanup

Teammate fallback array (when config.json unreadable):
```javascript
// FALLBACK: all possible self-audit agents (safe to send shutdown to absent members)
allMembers = [
  // Static analysis agents
  "rule-consistency-auditor", "prompt-linter", "workflow-auditor",
  "hook-integrity-auditor",
  // Runtime analysis agents (conditional — --mode runtime or --mode all)
  "hallucination-detector", "effectiveness-analyzer", "convergence-analyzer",
  // Improvement advisor (conditional — --apply)
  "improvement-advisor"
]
```

Follow standard shutdown from [engines.md](../team-sdk/references/engines.md#shutdown).

Post-cleanup:
```javascript
// Update state file to completed
const stateFiles = Glob(`tmp/.rune-self-audit-*.json`)
if (stateFiles.length > 0) {
  const state = JSON.parse(Read(stateFiles[0]))
  state.status = "completed"
  state.completed = new Date().toISOString()
  Write(stateFiles[0], JSON.stringify(state, null, 2))
}

// Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "self-audit"`)
```

---

## Modes

### Static Analysis (`--mode static`, default)

Scans plugin source files for structural issues:

| Dimension | What it checks |
|-----------|---------------|
| **Workflow** (SA-WF) | Phase counts, phase ordering, missing phases, dead references |
| **Agent** (SA-AGT) | Missing frontmatter fields, orphaned agents, stale tool lists |
| **Hook** (SA-HK) | CLAUDE.md table vs hooks.json drift, missing scripts, timeout mismatches |
| **Rule Consistency** (SA-RC) | Contradictions between CLAUDE.md, skills, and agent prompts |
| **Prompt Quality** (SA-PQ) | Stale counts, outdated examples, broken cross-references |

### Runtime Analysis (`--mode runtime`)

Requires recent arc artifacts in `tmp/arc/` and checkpoints in `.rune/arc/`. Spawns 3 runtime agents in parallel (read-only):

| Agent | Dimension | Output |
|-------|-----------|--------|
| `hallucination-detector` | Phantom claims, inflated scores, evidence fabrication | `hallucination-findings.md` |
| `effectiveness-analyzer` | Per-agent accuracy, false-positive rates, unique contribution | `effectiveness-findings.md` |
| `convergence-analyzer` | Retry efficiency, stagnation, phase bottlenecks | `convergence-findings.md` |

Analyzes:
- TOME findings recurrence across runs
- Worker completion patterns and failure modes
- Phase timing anomalies
- QA score trends

See [runtime-mode.md](references/runtime-mode.md) for the full R0–R3 phase protocol and auto-detection algorithm.

### Combined (`--mode all`)

Runs both static and runtime analysis, then performs cross-role echo correlation
to detect pipeline-spanning patterns.

## --apply Interactive Approval Flow

The `--apply` flag activates the fix proposal pipeline. See [apply-mode.md](references/apply-mode.md) for full protocol.

### Flow

```
/rune:self-audit --apply
  1. Run full audit (static + runtime if available)
  2. Filter: only Etched-tier findings AND recurrence >= 3
  3. Spawn improvement-advisor agent for eligible findings
  4. For each proposal:
     a. Display preview via AskUserQuestion
     b. User selects: Apply / Skip / Reject (with reason)
     c. If Apply: Edit target file, create atomic commit
     d. If Reject: Record reason in meta-qa echo (suppresses future proposals)
  5. Summary: N applied, N skipped, N rejected
```

### Commit Format

Each applied fix gets its own atomic commit:

```
self-audit-fix(prompt): [SA-AGT-001] Add missing maxTurns to phase-qa-verifier
self-audit-fix(workflow): [SA-WF-004] Update phase count from 29 to 34
self-audit-fix(rule): [SA-RC-001] Sync plugin version in marketplace.json
self-audit-fix(hook): [SA-HK-006] Add missing hook to CLAUDE.md table
```

Context types: `prompt`, `workflow`, `rule`, `hook`, `config`, `agent`.

### Rejection Tracking

When a user rejects a proposal, the rejection reason is recorded in
`.rune/echoes/meta-qa/MEMORY.md` with `suppress_future: true`. This prevents
the same proposal from being surfaced in future audits:

```markdown
### [2026-03-19] Rejected: SA-AGT-001 maxTurns for phase-qa-verifier
- **layer**: notes
- **source**: rune:self-audit apply-{run_id}
- **confidence**: 1.0
- **rejection_reason**: "Intentionally low — QA agents are lightweight"
- **suppress_future**: true
```

### Active Arc Conflict Check

Before applying fixes, check for active arc state:

```javascript
// Defer if an arc is currently running
const arcActive = Glob('.rune/arc-phase-loop.local.md')
if (arcActive.length > 0) {
  // Save proposals to deferred file instead of applying
  Write('.rune/echoes/meta-qa/deferred-proposals.md', proposals)
  // Inform user
  log('Active arc detected. Proposals saved to deferred-proposals.md.')
  log('Run /rune:self-audit --apply again after the arc completes.')
  return
}
```

Deferred proposals are saved to `.rune/echoes/meta-qa/deferred-proposals.md`
and surfaced on the next `--apply` invocation.

## Cross-Role Echo Correlation

After dimension analysis, the self-audit correlates patterns across echo roles
to detect pipeline-spanning issues. See [cross-role-correlation.md](references/cross-role-correlation.md).

### Echo Roles

| Role | Echo Path | What it captures |
|------|-----------|-----------------|
| `planner` | `.rune/echoes/planner/MEMORY.md` | Planning gaps, specification omissions |
| `orchestrator` | `.rune/echoes/orchestrator/MEMORY.md` | Coordination failures, phase issues |
| `workers` | `.rune/echoes/workers/MEMORY.md` | Implementation patterns, worker failures |
| `reviewer` | `.rune/echoes/reviewer/MEMORY.md` | Review findings, recurring issues |
| `meta-qa` | `.rune/echoes/meta-qa/MEMORY.md` | Self-audit findings, fix effectiveness |
| `team` | `.rune/echoes/team/MEMORY.md` | Cross-role correlations (output) |

### Pipeline Pattern Detection

The correlation engine detects patterns like:
- **Planner gap -> Worker miss -> Reviewer catch**: A specification omission
  flows through the entire pipeline before being caught at review
- **Recurring reviewer findings**: The same issue found across multiple arcs
  suggests a systemic planner or worker gap
- **Fix regression**: An applied fix that causes new findings in a different dimension

## Echo Comparison (Delta Analysis)

Each audit run compares current findings against previous run's entries in
`meta-qa/MEMORY.md` to produce:

| Section | Description |
|---------|-------------|
| **New findings** | First-time detections in this run |
| **Resolved findings** | Previously tracked issues no longer present |
| **Persistent findings** | Issues seen across multiple consecutive runs |
| **Score delta** | Per-dimension score changes since last audit |

## Effectiveness Tracking

When `--apply` fixes are applied, the system tracks pre/post metrics:

1. At fix time: Record current finding set and dimension scores
2. After next arc + self-audit: Compare against recorded baseline
3. Verdict: `EFFECTIVE` (score improved), `NO_CHANGE`, or `REGRESSION`

Regression verdicts are auto-flagged for review in the next audit report.

## Phase-Specific Echo Injection

Enabled by `talisman.self_audit.phase_injection` (default: `true`).

During arc runs, the stop hook reads meta-qa echoes tagged for the current phase
and injects them as warnings into the phase prompt. This surfaces recurring
issues exactly where they're relevant.

**Budget**: Max 3 entries, max 500 tokens (~2000 chars) per injection.

See [phase-injection.md](references/phase-injection.md) for implementation details.

## Auto-Suggestion

When 3+ recent arc runs have marginal QA scores (<70), the stop hook suggests
running `/rune:self-audit --mode all`. Debounced to once per 24 hours.

Controlled by:
- `talisman.self_audit.auto_suggest_threshold` (default: 3)
- `talisman.self_audit.auto_suggest_debounce_hours` (default: 24)

## Configuration

All settings in `talisman.yml` under `self_audit:`:

```yaml
self_audit:
  enabled: true
  phase_injection: true
  max_injection_entries: 3
  max_injection_tokens: 500
  auto_suggest_threshold: 3
  auto_suggest_debounce_hours: 24
  apply_mode:
    require_high_confidence: true
    min_recurrence: 3
    atomic_commits: true
  effectiveness:
    track: true
    regression_alert: true
```

## --history — Audit History with Trends

```
/rune:self-audit --history
```

Lists past self-audit runs with scores and trends, reading from `tmp/self-audit/*/metrics.json`:

```
Self-Audit History (last 5 runs)
────────────────────────────────
2026-03-19  Static:82/Runtime:75  Overall:78  GOOD     ↑ +3 from last
2026-03-15  Static:79/Runtime:72  Overall:75  GOOD     → stable
2026-03-10  Static:76/Runtime:--  Overall:76  GOOD     (static only)
```

## Echo Entries with Metrics Snapshot

When runtime analysis produces findings, echo entries persisted to `.rune/echoes/meta-qa/MEMORY.md`
include a `metrics_snapshot` field with quantitative data alongside qualitative learnings:

```markdown
### [2026-03-19] Pattern: Code review consistently needs retry
- **layer**: inscribed
- **source**: rune:self-audit runtime-{run_id}
- **confidence**: 0.85
- **metrics_snapshot**:
  - avg_retry_count: 1.4
  - avg_score_before_retry: 62
  - avg_score_after_retry: 78
  - improvement_per_retry: 16
- Code review phase averages 1.4 retries. Pre-retry score 62 (MARGINAL), post-retry 78 (PASS).
```

The `metrics_snapshot` field is populated from `metrics.json` data at echo persist time.
Numeric fields enable cross-run trend comparison and effectiveness tracking.

## Output

Reports are written to `tmp/self-audit/{timestamp}/`:

| File | Contents |
|------|----------|
| `SELF-AUDIT-REPORT.md` | Full audit report with all dimensions, grounding verification, and improvement roadmap |
| `workflow-findings.md` | Workflow auditor dimension findings (SA-WF-*) |
| `prompt-findings.md` | Prompt linter dimension findings (SA-AGT-*) |
| `rule-findings.md` | Rule consistency dimension findings (SA-RC-*) |
| `hook-findings.md` | Hook integrity dimension findings (SA-HK-*) |
| `findings.json` | Machine-readable findings list |
| `metrics.json` | Dimension scores and deltas |
| `proposals.md` | Fix proposals (when `--apply`) |
| `correlation.md` | Cross-role patterns (when `--mode all`) |

## Scoring

```
dimension_score = 100 - (P1_count * 15 + P2_count * 5 + P3_count * 1)
clamped to [0, 100]

overall_score = avg(all active dimension scores)
```

| Score Range | Verdict | Meaning |
|-------------|---------|---------|
| 90-100 | EXCELLENT | System is well-maintained |
| 70-89 | GOOD | Minor issues, no action required |
| 50-69 | NEEDS_ATTENTION | Several issues, review recommended |
| 0-49 | CRITICAL | Significant issues, action required |

## Error Handling

| Error | Recovery |
|-------|----------|
| Agent timeout (>5 min) | Proceed with partial findings from completed agents |
| Agent produces no output file | Report dimension as "UNABLE TO AUDIT" with score N/A |
| Grounding check finds hallucinated citations | Drop finding, log in report "Grounding Verification" section |
| Echo MEMORY.md doesn't exist | Create with initial template |
| Echo MEMORY.md exceeds 150 lines | Trigger pruning per echo protocol |
| Talisman `self_audit.enabled` is false | Inform user and exit cleanly |
| Team creation fails | Retry with teamTransition protocol |
| Self-referential finding about meta-QA | Tag with `self_referential: true`, require human review |

## References

- [aggregation.md](references/aggregation.md) — SELF-AUDIT-REPORT.md template and grounding rules
- [apply-mode.md](references/apply-mode.md) — Interactive approval protocol
- [cross-role-correlation.md](references/cross-role-correlation.md) — Correlation algorithm
- [phase-injection.md](references/phase-injection.md) — Echo injection into arc phases
- [echo-comparison.md](references/echo-comparison.md) — Delta analysis between runs
- [effectiveness-tracking.md](references/effectiveness-tracking.md) — Fix effectiveness loop
- [runtime-mode.md](references/runtime-mode.md) — Runtime analysis phases (R0–R3)
- [metrics-schema.md](references/metrics-schema.md) — metrics.json schema and trend computation
