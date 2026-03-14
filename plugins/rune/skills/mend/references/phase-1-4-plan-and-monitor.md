# Phase 1: PLAN + Phase 4: MONITOR

## Phase 1: PLAN

### Analyze Dependencies

Check for cross-file dependencies between findings:

1. If finding A (in file X) depends on finding B (in file Y): B's file group completes before A's
2. Within a file group, order by severity (P1 -> P2 -> P3), then by line number (top-down)
3. Triage threshold enforcement (v1.163.0+):
   When total findings > 20:
     P1: FIX (mandatory — always processed)
     P2: SHOULD FIX (processed, but may be deferred via p2Threshold)
     P3: MAY SKIP (only processed in round 0, deferred in retries)

### Determine Fixer Count and Waves

```javascript
fixer_count = min(file_groups.length, 5)
totalWaves = Math.ceil(file_groups.length / fixer_count)
```

| File Groups | Fixers per Wave | Waves |
|-------------|-----------------|-------|
| 1 | 1 | 1 |
| 2-5 | file_groups.length | 1 |
| 6-10 | 5 | 2 |
| 11+ | 5 | ceil(groups / 5) |

**Zero-fixer guard**: If all findings were deduplicated, skipped, or marked FALSE_POSITIVE, skip directly to Phase 6 with "no actionable findings" summary.

### Risk-Overlaid Severity Ordering (Goldmask Enhancement)

When `parsedRiskMap` is available from Phase 0.5, overlay risk tiers on finding severity ordering: annotate findings with risk tier/score, sort within same priority by tier (CRITICAL first, alphabetical tiebreaker), promote P3 in CRITICAL-tier files to effective P2. Skip when `parsedRiskMap` is `null`.

See [risk-overlay-ordering.md](risk-overlay-ordering.md) for the full algorithm.

## Phase 4: MONITOR

Poll TaskList to track fixer progress per wave. Each wave has its own monitoring cycle with proportional timeout (`totalTimeout / totalWaves`).

```javascript
const SETUP_BUDGET = 300_000        // 5 min
const MEND_EXTRA_BUDGET = 180_000   // 3 min
const DEFAULT_MEND_TIMEOUT = 900_000 // 15 min standalone
const innerPollingTimeout = timeoutFlag
  ? Math.max(timeoutFlag - SETUP_BUDGET - MEND_EXTRA_BUDGET, 120_000)
  : DEFAULT_MEND_TIMEOUT

const result = waitForCompletion(teamName, Object.keys(fileGroups).length, {
  timeoutMs: innerPollingTimeout,
  staleWarnMs: 300_000,
  autoReleaseMs: 600_000,
  pollIntervalMs: 30_000,
  label: "Mend"
})
```

See [monitor-utility.md](../../roundtable-circle/references/monitor-utility.md) for the shared polling utility.

**Anti-pattern**: NEVER `Bash("sleep 60 && echo poll check")` — call `TaskList` every cycle.

**zsh compatibility**: Never use `status` as a variable name — read-only in zsh. Use `task_status` or `tstat`.
