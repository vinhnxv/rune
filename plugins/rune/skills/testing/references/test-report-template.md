# Test Report Template

## File Hierarchy

```
tmp/arc/{id}/
├── test-strategy.md                    # Pre-execution analysis (STEP 1.5)
├── testing-plan.json                   # Batch plan + checkpoint (batch-execution.md)
├── testing-plan.md                     # Human-readable batch plan rendering
├── test-report.md                      # Final aggregated report (STEP 9)
├── test-results-unit-batch-{N}.md      # Unit tier per-batch raw output
├── test-results-integration-batch-{N}.md  # Integration tier per-batch raw output
├── test-results-e2e-batch-{N}.md       # E2E tier per-batch output
├── test-results-contract-batch-{N}.md  # Contract validation per-batch results
├── test-results-extended-batch-{N}.md  # Extended tier per-batch scenario outcomes
├── extended-checkpoint.json            # Extended tier checkpoint for crash recovery
├── e2e-checkpoint-route-{N}.json       # Per-route checkpoint (crash recovery)
├── e2e-route-{N}-result.md             # Per-route detailed trace
├── evidence/                           # Per-batch evidence records (evidence-protocol.md)
│   ├── batch-1-evidence.json
│   ├── batch-2-evidence.json
│   └── ...
├── failure-journal.md                  # Cumulative failure analysis (evidence-protocol.md)
├── screenshots/
│   └── route-{N}-step-{S}.png
├── docker-containers.json              # For crash recovery cleanup
│
# Persistent test history (stored at PROJECT ROOT, not under tmp/arc/):
.rune/test-history/
└── test-history.jsonl                  # Rolling window (JSONL single-file)
```

## Main Report Format (test-report.md)

```markdown
# Test Report — Arc {id}

## Strategy vs Results
| Prediction | Actual Result | Match? |
|------------|---------------|--------|
| Unit: N tests, expect pass | N pass, M fail | YES/NO |

## Summary
| Tier | Status | Tests | Passed | Failed | Flaky | Diff Coverage | Duration |
|------|--------|-------|--------|--------|-------|---------------|----------|
| Unit | PASS/FAIL/SKIP/TIMEOUT | N | N | N | N | N% | Ns |
| Integration | PASS/FAIL/SKIP/TIMEOUT | N | N | N | N | — | Ns |
| E2E/Browser | PASS/FAIL/SKIP/TIMEOUT | N routes | N | N | N | — | Ns |

**Overall**: {PASS/WARN/FAIL}
**Pass Rate**: {0.0-1.0 | null if 0 tests}
**Diff Coverage**: {N}% (warning threshold: 70%)
**Duration**: {total}
**Tiers Run**: [{list}]

## Pre-Scan Checklist
> Read from `tmp/arc/{id}/test-pre-scan.json` written during STEP 2

| Check | Status | Detail |
|-------|--------|--------|
| Unit test files exist | {PASS/FAIL} | {N}/{M} valid |
| Integration test files exist | {PASS/FAIL} | {N}/{M} valid |
| E2E routes discovered | {PASS/FAIL} | {N} routes |
| Test framework detected | {PASS/FAIL} | {frameworks per component} |
| No missing test files | {PASS/FAIL} | {N} missing |

**Frameworks**: {component → framework map from pre-scan}
**Missing files**: {list of files discovered but not found on disk}

## Integrity Checks
- Stale test detection (WF-1): {PASS/WARNING}
- Shallow verification (WF-2): {N/A or routes with depth=0}
- Data contamination (WF-3): {PASS/WARNING}
- Misattribution check (WF-5): {PASS/WARNING}
- Budget utilization: {time per tier vs allocated}

## Uncovered Implementations
- {file_path} — no test file found

## Batch Execution Summary
> Each batch ran as a dedicated teammate agent in its own context turn.
> Timing computed from `started_at`/`completed_at` in testing-plan.json.

| # | Label | Component | Type | Files | Duration | Status | Retries | Fixed Files |
|---|-------|-----------|------|-------|----------|--------|---------|-------------|
| 0 | backend-unit-1/2 | backend | unit | 18 | 45s | PASS | 0 | — |
| 1 | backend-unit-2/2 | backend | unit | 12 | 38s | PASS | 0 | — |
| 2 | dashboard-unit | dashboard | unit | 15 | 22s | PASS | 0 | — |
| 3 | backend-integration | backend | integration | 6 | 2m 10s | PASS (after fix) | 1 | src/api/auth.ts |
| 4 | dashboard-e2e | dashboard | e2e | 3 | 3m 20s | FAIL | 2 | — |

**Batches**: {passed}/{total} passed · {failed} failed · {skipped} skipped
**Fix loop**: {fixes_applied} fix(es) applied · {batches_fixed} batch(es) recovered
**Avg batch duration**: {avg_ms}ms

## Timing Breakdown
> Wall-clock times from testing-plan.json batch timestamps

| Component | Tier | Batches | Total Duration | Avg per Batch |
|-----------|------|---------|----------------|---------------|
| backend | unit | 2 | 1m 23s | 41s |
| dashboard | unit | 1 | 22s | 22s |
| backend | integration | 1 | 2m 10s | 2m 10s |
| dashboard | e2e | 1 | 3m 20s | 3m 20s |
| **Total** | | **5** | **7m 15s** | **1m 27s** |

**Phase wall-clock**: {total from phase started_at to completed_at}
**Overhead** (setup, compaction, stop hook): {phase_wall_clock - sum_batch_durations}

## Fix History
> Aggregated from `tmp/arc/{id}/evidence/batch-{N}-evidence.json` fix_loop entries

| Batch | Attempt | File Fixed | Description | Rerun Result |
|-------|---------|------------|-------------|--------------|
| 3 | 1 | src/api/auth.ts | Add expiry check before refresh | PASSED |
| 4 | 1 | src/ui/form.tsx | Fix null check on submit | FAILED |
| 4 | 2 | src/ui/form.tsx | Handle empty state edge case | FAILED (stagnated) |

**Total fixes applied**: {N}
**Recovery rate**: {batches_recovered}/{batches_with_fixes} ({pct}%)

## Flaky Tests
- {test_name} — passed on retry (flaky: true, tier: {tier})

## [Tier Details - per tier sections]

## Acceptance Criteria Traceability
| Plan AC | Test(s) Covering | Status |
|---------|------------------|--------|
| AC-001: {description} | test_name_1, test_name_2 | COVERED |
| AC-002: {description} | — | NOT COVERED |

## Regression Analysis
**Trend**: {improving|stable|mixed|declining}

| Signal | Severity | Detail |
|--------|----------|--------|
| Pass rate drop | WARNING | 95% → 88% (7% drop, threshold 5%) |
| New failure signature | INFO | `a3f2b1c4d5e6` never seen in last 5 runs |
| Duration regression | WARNING | Avg batch 45s → 72s (1.6x above historical) |
| Fix rate increase | WARNING | 4 fixes (2.0x above avg 2.0) |

When no regressions: "No regressions detected. Trend: stable."

## [Failure Analysis - if failures detected]

## [Screenshots - if E2E ran]

## Evidence Files
- Testing plan: `tmp/arc/{id}/testing-plan.json`
- Failure journal: `tmp/arc/{id}/failure-journal.md`
- Batch evidence: `tmp/arc/{id}/evidence/batch-{N}-evidence.json`
- Test history: `.rune/test-history/test-history.jsonl`

<!-- SEAL: test-report-complete -->
```

## Failure Trace Structure (TEST-NNN)

Every TEST-NNN finding MUST include:

| Field | Required | Description |
|-------|----------|-------------|
| Step failed | YES | Which operation failed |
| Expected | YES | What was expected |
| Actual | YES | What happened |
| Log source | YES | BACKEND / FRONTEND / BACKEND_VIA_FRONTEND / TEST_FRAMEWORK / INFRASTRUCTURE / UNKNOWN |
| Error type | YES | validation / regression / crash / timeout / flaky / missing_dep |
| Stack trace | if available | Max 10 lines |
| Backend logs | if available | Last 5-10 lines around failure |
| Frontend console | if available | JS errors from agent-browser |
| Scope | YES | Which changed file(s) relate |
| Retry | YES | Was it retried? Result? |

## Machine-Readable Fields

For audit phase consumption:
- `pass_rate`: 0.0-1.0 or `null` (no tests / timed out — NOT 0.0)
- `coverage_pct`: DIFF coverage (not overall)
- `no_tests_found`: boolean
- `tiers_run`: array of tier names
- `uncovered_implementations`: files with code but no tests
- `flaky_tests`: tests that passed on retry
- `log_sources`: finding → log attribution map
- `strategy_match`: predicted vs actual comparison
- `contract_results`: `{pass_count, fail_count, mismatch_details[]}` — only if contract tier ran
- `extended_results`: `{pass_count, fail_count, checkpoint_file}` — only if extended tier ran
<!-- Visual regression and accessibility result fields: add when batch executor implements these tiers -->
- `production_readiness`: `{mock_patterns_found, missing_env_vars[], health_checks[]}` — only if production_readiness ran
- `history_signals`: `{regression_detected, flaky_count, trend}` — only if history enabled
- `batch_evidence`: `{total_batches, passed, failed, skipped, fixes_applied, batches_fixed, avg_duration_ms}` — only if batched execution ran
<!-- regression_analysis: deferred — batch-level fields are persisted in history for future detection -->
- `scenario_coverage`: `{total_declared, exercised, pass_count, fail_count, not_run[]}` — only if scenarios enabled

## Contract Validation Results

Only present when `testing.contract.enabled` is true in talisman.yml. Written to `test-results-contract.md`.

```markdown
## Contract Validation Results

| Endpoint | Spec Version | Schema Match | Mismatches | Status |
|----------|-------------|-------------|------------|--------|
| GET /api/users | v2.1.0 | YES | — | PASS |
| POST /api/orders | v2.1.0 | NO | 2 | FAIL |

**Mismatches:**
- POST /api/orders: response field `orderId` type mismatch — spec: string, actual: integer
- POST /api/orders: missing required response field `createdAt`

**Summary**: {N}/{Total} endpoints schema-compliant. Contract: {PASS/FAIL}.
```

## Extended Tier Results

Only present when `testing.extended_tier.enabled` is true in talisman.yml. Written to `test-results-extended.md`.

```markdown
## Extended Tier Results

| Scenario | Checkpoints | Passed | Status | Duration |
|----------|-------------|--------|--------|----------|
| high-volume-import | 3/3 | YES | PASS | 42m |
| overnight-batch-job | 2/3 | NO | FAIL | 61m |

**Checkpoint Details:**
- overnight-batch-job checkpoint 3/3: timed out at 61m (limit: 60m)
- Checkpoint file: `extended-checkpoint.json`

**Summary**: {N}/{Total} scenarios passed. Timeout budget: {allocated}. Actual: {used}.
```

<!-- Visual Regression and Accessibility template sections: add when batch executor implements these tiers -->

## Production Readiness

Only present when `testing.production_readiness.enabled` is true in talisman.yml.

```markdown
## Production Readiness

| Check | Result | Detail |
|-------|--------|--------|
| Mock pattern scan | {PASS/FAIL} | {N} mock patterns found in production code |
| Env var validation | {PASS/FAIL} | {N} required env vars missing: {list} |
| Health check — /api/health | {PASS/FAIL} | Status {200/N}, latency {Nms} |
| Health check — /api/ready | {PASS/FAIL} | Status {200/N} |

**Mock pattern findings (if any):**
- `src/services/payment.ts:42` — `jest.mock(` found outside test directory
- `src/utils/db.ts:17` — `__mocks__/` reference in production import

**Missing env vars (if any):**
- `DATABASE_URL` — required by `src/db/connection.ts`
- `STRIPE_SECRET_KEY` — required by `src/services/payment.ts`

**Summary**: Production readiness: {PASS/WARN/FAIL}. {N} issues detected.
```

## Test History

Only present when `testing.history.enabled` is true in talisman.yml. Data sourced from `.rune/test-history/`.

```markdown
## Test History

**Regression threshold**: {talisman.testing.history.regression_threshold} — minimum recent passes (out of last 10) for a currently-failing test to be classified as a per-test regression (high-confidence flip from stable to failing)
**Flaky threshold**: {talisman.testing.history.flaky_threshold} (failure rate)

| Test | Last {N} Runs | Trend | Flaky? | Regression? |
|------|--------------|-------|--------|------------|
| unit:UserService.create | ✓✓✓✓✓ | stable | NO | NO |
| unit:PaymentService.charge | ✓✗✓✗✓ | unstable | YES (40%) | NO |
| integration:OrderFlow | ✓✓✓✓✓✓✓✓✗ | declining | NO | YES (8/10 passes, now failing) |

**Regression signals**: {N} tests newly failing across {N} consecutive runs.
**Flaky indicators**: {N} tests with failure rate ≥ {threshold}.

**Summary**: History trend: {STABLE/DEGRADING}. Regressions detected: {YES/NO}. Flaky tests: {N}.
```

## Scenario Coverage

Only present when `testing.scenarios.enabled` is true in talisman.yml.

```markdown
## Scenario Coverage

**Scenario directory**: {talisman.testing.scenarios.directory}
**Max scenarios per run**: {talisman.testing.scenarios.max_per_run}

| Scenario | Declared In | Exercised | Result |
|----------|------------|-----------|--------|
| user-registration-happy-path | scenarios/auth.yaml | YES | PASS |
| user-registration-duplicate-email | scenarios/auth.yaml | YES | FAIL |
| checkout-with-coupon | scenarios/checkout.yaml | YES | PASS |
| refund-expired-order | scenarios/orders.yaml | NO | NOT RUN |

**Coverage**: {N}/{Total} declared scenarios exercised ({N}%).
**Not run**: {N} scenarios skipped (over max_per_run limit or filtered).

**Summary**: Scenario coverage: {N}%. All exercised scenarios: {PASS/FAIL}.
```

## SEAL Markers

Each tier and the main report end with a SEAL marker:
- `<!-- SEAL: unit-test-complete -->`
- `<!-- SEAL: integration-test-complete -->`
- `<!-- SEAL: e2e-test-complete -->`
- `<!-- SEAL: contract-test-complete -->`
- `<!-- SEAL: extended-test-complete -->`
<!-- Visual regression and accessibility SEALs: add when implemented -->
- `<!-- SEAL: production-readiness-complete -->`
- `<!-- SEAL: test-report-complete -->`

Missing SEAL = incomplete report. Audit falls back to per-tier files.
