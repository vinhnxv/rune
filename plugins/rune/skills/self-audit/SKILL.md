---
name: self-audit
description: |
  Meta-quality analysis of Rune's own plugin infrastructure.
  Detects stale references, missing metadata, rule contradictions,
  and workflow inconsistencies across agents, skills, hooks, and config.

  Phase 3 adds: echo injection, fix proposals (--apply), cross-role
  correlation, effectiveness tracking, and auto-suggestion.

  Use when: "self-audit", "meta-qa", "check rune health", "audit rune itself"
user-invocable: true
disable-model-invocation: false
argument-hint: "[--mode static|runtime|all] [--apply] [--dry-run]"
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

Requires recent arc artifacts in `tmp/arc/`. Analyzes:
- TOME findings recurrence across runs
- Worker completion patterns and failure modes
- Phase timing anomalies
- QA score trends

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

## Output

Reports are written to `tmp/self-audit/{timestamp}/`:

| File | Contents |
|------|----------|
| `report.md` | Full audit report with all dimensions |
| `findings.json` | Machine-readable findings list |
| `metrics.json` | Dimension scores and deltas |
| `proposals.md` | Fix proposals (when `--apply`) |
| `correlation.md` | Cross-role patterns |

## References

- [apply-mode.md](references/apply-mode.md) — Interactive approval protocol
- [cross-role-correlation.md](references/cross-role-correlation.md) — Correlation algorithm
- [phase-injection.md](references/phase-injection.md) — Echo injection into arc phases
- [echo-comparison.md](references/echo-comparison.md) — Delta analysis between runs
- [effectiveness-tracking.md](references/effectiveness-tracking.md) — Fix effectiveness loop
