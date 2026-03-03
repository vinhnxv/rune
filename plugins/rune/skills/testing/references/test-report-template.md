# Test Report Template

## File Hierarchy

```
tmp/arc/{id}/
├── test-strategy.md                    # Pre-execution analysis (STEP 1.5)
├── test-report.md                      # Final aggregated report (STEP 9)
├── test-results-unit.md                # Unit tier raw output
├── test-results-integration.md         # Integration tier raw output
├── test-results-e2e.md                 # E2E tier aggregated output
├── test-results-contract.md            # Contract validation results (when contract.enabled)
├── test-results-extended.md            # Extended tier scenario outcomes
├── extended-checkpoint.json            # Extended tier checkpoint for crash recovery
├── e2e-checkpoint-route-{N}.json       # Per-route checkpoint (crash recovery)
├── e2e-route-{N}-result.md             # Per-route detailed trace
├── screenshots/
│   └── route-{N}-step-{S}.png
├── docker-containers.json              # For crash recovery cleanup
│
# Persistent test history (stored at PROJECT ROOT, not under tmp/arc/):
.claude/test-history/
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

## Integrity Checks
- Stale test detection (WF-1): {PASS/WARNING}
- Shallow verification (WF-2): {N/A or routes with depth=0}
- Data contamination (WF-3): {PASS/WARNING}
- Misattribution check (WF-5): {PASS/WARNING}
- Budget utilization: {time per tier vs allocated}

## Uncovered Implementations
- {file_path} — no test file found

## Flaky Tests
- {test_name} — passed on retry (flaky: true, tier: {tier})

## [Tier Details - per tier sections]

## Acceptance Criteria Traceability
| Plan AC | Test(s) Covering | Status |
|---------|------------------|--------|
| AC-001: {description} | test_name_1, test_name_2 | COVERED |
| AC-002: {description} | — | NOT COVERED |

## [Failure Analysis - if failures detected]

## [Screenshots - if E2E ran]

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
- `visual_regression_results`: `{pass_count, fail_count, threshold, failed_routes[]}` — only if visual regression ran
- `accessibility_results`: `{critical_count, serious_count, moderate_count, pages_checked[]}` — only if accessibility ran
- `production_readiness`: `{mock_patterns_found, missing_env_vars[], health_checks[]}` — only if production_readiness ran
- `history_signals`: `{regression_detected, flaky_count, trend}` — only if history enabled
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

## Visual Regression Results

Only present when `testing.visual_regression.enabled` is true in talisman.yml.

```markdown
## Visual Regression Results

| Route / Component | Baseline | Pixel Diff | Score | Status |
|-------------------|----------|-----------|-------|--------|
| /dashboard | baseline-v2.png | 0.3% | 0.997 | PASS |
| /checkout | baseline-v2.png | 6.1% | 0.939 | FAIL |
| Button (mobile) | baseline-v2.png | 0.0% | 1.000 | PASS |

**Threshold**: {talisman.testing.visual_regression.threshold} (e.g., 0.95)
**Viewports tested**: {list of viewports if responsive.enabled}

**Summary**: {N}/{Total} comparisons within threshold. Visual regression: {PASS/FAIL}.
```

## Accessibility Results

Only present when `testing.accessibility.enabled` is true in talisman.yml.

```markdown
## Accessibility Results

**WCAG Level**: {AA/AAA}

| Page / Component | Critical | Serious | Moderate | Minor | Status |
|------------------|---------|---------|---------|-------|--------|
| /home | 0 | 0 | 1 | 2 | WARN |
| /checkout | 1 | 2 | 0 | 0 | FAIL |
| Button | 0 | 0 | 0 | 0 | PASS |

**Violations:**
- /checkout [CRITICAL]: Missing form label on card number input (WCAG 1.3.1)
- /checkout [SERIOUS]: Insufficient color contrast on error text (WCAG 1.4.3)
- /home [MODERATE]: Heading hierarchy skips H2 to H4 (WCAG 1.3.1)

**Summary**: {N} critical, {N} serious violations across {N} pages. Accessibility: {PASS/WARN/FAIL}.
```

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

Only present when `testing.history.enabled` is true in talisman.yml. Data sourced from `.claude/test-history/`.

```markdown
## Test History

**Regression threshold**: {talisman.testing.history.regression_threshold} minimum recent passes (out of last 10 runs) to classify as regression
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
- `<!-- SEAL: visual-regression-complete -->`
- `<!-- SEAL: accessibility-check-complete -->`
- `<!-- SEAL: production-readiness-complete -->`
- `<!-- SEAL: test-report-complete -->`

Missing SEAL = incomplete report. Audit falls back to per-tier files.
