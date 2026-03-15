---
name: testing
description: |
  Test orchestration pipeline for arc Phase 7.7. Provides 3-tier testing
  (unit, integration, E2E/browser) with diff-scoped discovery, service startup,
  and structured reporting. Includes extended tier with checkpoint/resume,
  contract validation, visual regression, design token compliance, accessibility
  checks, test history persistence, regression detection, and flaky test
  identification. Auto-loaded by arc orchestrator during test phase.
  Trigger keywords: testing, test pipeline, unit test, integration test, E2E test,
  test discovery, test report, QA, quality assurance, scenario schema, checkpoint,
  fixture, visual regression, design token, accessibility, test history,
  regression detection, flaky test, extended tier, contract validation.
user-invocable: false
disable-model-invocation: false
---

# Testing Orchestration — Arc Phase 7.7

This skill provides the knowledge base for the arc pipeline's testing phase.
It is auto-loaded by the arc orchestrator and injected into test runner agents.

## Testing Pyramid Hierarchy

```
       /\
      /E2E\         ← Slow, few (max 3 routes)
     /------\
    /Integr. \      ← Moderate speed, moderate count
   /----------\
  / Unit Tests \    ← Fast, many (diff-scoped)
 /--------------\
```

**Execution order**: Unit → Integration → E2E (serial by tier, parallel within tier)
**Failure cascade**: Tiers execute serially (unit → integration → E2E). Tier failures are non-blocking — all enabled tiers execute regardless of prior tier results, based on scope detection and service health.

## Model Routing Rules

| Role | Model | Rationale |
|------|-------|-----------|
| Test orchestration (team lead) | Opus | Complex coordination, strategy |
| Unit test runner | Sonnet | Fast execution, low complexity |
| Contract validator | Sonnet | API/schema validation, non-blocking |
| Integration test runner | Sonnet | Moderate complexity, service interaction |
| E2E browser tester | Sonnet | Browser interaction, snapshot analysis |
| Extended test runner | Sonnet | Long-running scenarios, checkpoint support |
| Failure analyst | Opus (inherit) | Root cause analysis, multi-file reasoning |

**Strict enforcement**: Team lead (Opus) NEVER executes test commands directly.
All test execution happens via Sonnet teammates.

## Scope Detection

See [scope-detection.md](references/scope-detection.md) for the shared `resolveTestScope()` algorithm.

Summary:
- Input: PR number string, branch name, or empty (auto-detect current branch)
- Output: `{ files: string[], source: "pr"|"branch"|"current", label: string }`
- Priority: PR files (via `gh`) → branch diff → current-branch diff → fallback warn
- Security: PR numbers must be digit-only; branch names validated against `[a-zA-Z0-9._/-]+`
- Shared between arc Phase 7.7 and `/rune:test-browser` standalone

## Diff-Scoped Test Discovery

See [test-discovery.md](references/test-discovery.md) for the full algorithm.

Summary:
1. Get changed files from `resolveTestScope()` — NOT from raw `git diff`
2. Map each source file to its test counterpart by convention
3. If no test file found → flag as "uncovered implementation"
4. Include changed test files directly
5. For shared utilities (`lib/`, `utils/`, `core/`) → trigger full unit suite

## Service Startup Patterns

See [service-startup.md](references/service-startup.md) for the full protocol.

Summary:
1. Auto-detect: docker-compose.yml → Docker; package.json → npm; Makefile → make
2. Health check: HTTP GET every 2s, max 30 attempts (60s total)
3. Hard timeout: 3 minutes for Docker startup
4. **Snapshot verification**: after health check, open browser and check page is not blank/error
   - Arc mode: WARN and proceed if verification fails
   - Standalone mode: abort with framework-specific fix instructions
5. Failure → skip integration/E2E tiers, unit tests still run

## File-to-Route Mapping

See [file-route-mapping.md](references/file-route-mapping.md) for framework patterns.

## Test Report Format

See [test-report-template.md](references/test-report-template.md) for the output spec.

## Failure Escalation Protocol

```
Test runner detects failure
  → Write structured failure to tier result file
  → Continue remaining tests in tier
  → After all tiers complete:
    → Team lead reads tier results (summary only — Glyph Budget pattern)
    → If failures detected:
      → Spawn test-failure-analyst (Opus, 3-min deadline)
      → Analyst reads: failure traces + source code + error logs
      → Analyst produces: root cause + fix proposal + confidence
    → If analyst times out: attach raw test output instead
```

## Batch Execution Model (v1.165.0+)

Phase 7.7 uses sequential batched execution instead of parallel background agents.
Each batch = 1 foreground agent (blocking call, zero idle risk).

**Execution order**: unit batches → contract → integration → e2e → extended
**Batch sizing**: TARGET_BATCH_DURATION_MS / avg_test_duration (clamped to 1-20)
**Fix loop**: On failure, lead analyzes + fixes + reruns (max 2 retries)
**Checkpoint**: testing-plan.json is both plan AND checkpoint (atomic writes)
**Fresh context**: Stop hook re-injects per batch for unlimited context budget

See [batch-execution.md](references/batch-execution.md) for the full algorithm.
See [testing-plan-schema.md](references/testing-plan-schema.md) for the JSON schema.

## Anti-Skip Enforcement Rules

These rules are MANDATORY — not suggestions. Violation halts the pipeline.

1. NEVER skip tests because they "take too long"
2. NEVER mark testing as "done" with unfixed failures (unless max retries exceeded)
3. ALL diff-scoped test files MUST be executed
4. Fix-before-continue is MANDATORY — failed batch enters fix loop before proceeding
5. Testing plan MUST exist before any execution begins
6. Budget exhaustion is the ONLY valid skip reason — log explicitly as `skipped_budget_exhausted`

### Completeness Check
After all batches complete, verify:
- No batches with status "pending" remain (all executed or explicitly skipped)
- Skipped batches have skip_reason logged
- Warning emitted if any batch failed after max retries

## Test Scenario Schema

See [scenario-schema.md](references/scenario-schema.md) for the YAML test scenario format.

Summary:
- Scenarios live in `.claude/test-scenarios/*.yml`
- Required fields: `name`, `tier` (unit/integration/e2e/extended/contract)
- Discovered in STEP 0.5, merged into strategy in STEP 1.5
- Capped at `testing.scenarios.max_per_run` (default 50)
- Gate: `testing.scenarios.enabled` (default true)

## Extended Tier Checkpoint/Resume

See [checkpoint-protocol.md](references/checkpoint-protocol.md) for the checkpoint/resume protocol.

Summary:
- Extended scenarios write progress to `tmp/arc/{id}/extended-checkpoint.json`
- On resume: orchestrator reads checkpoint and passes as `extendedResumeState`
- Checkpoint interval: `testing.extended_tier.checkpoint_interval_ms` (default 300_000ms)
- Budget: `testing.extended_tier.timeout_ms` (default 3_600_000ms)
- Gate: `testing.extended_tier.enabled` AND extended scenarios exist

## Test Data Fixtures

See [fixture-protocol.md](references/fixture-protocol.md) for test data fixture execution.

Summary:
- Fixtures define seed data for integration and E2E tiers
- Applied before scenario steps, within the test runner agent (STEPs 5/6/7)
- Teardown runs after each scenario completes (regardless of pass/fail), not per-tier
- Gate: `testing.fixtures.enabled`

## Visual Regression

See [visual-regression.md](references/visual-regression.md) for the visual regression protocol.

Summary:
- E2E browser tester captures screenshots during STEP 7
- Inline comparison against baselines in `testing.visual_regression.baseline_dir`
- Comparison tool: `agent-browser compare --baseline <path> --current <path> --format json`
- Metric: similarity score (higher = better; 1.0 = identical)
- Similarity threshold: `testing.visual_regression.threshold` (default 0.95 = 95% similarity)
- Fail condition: `diffData.similarity < threshold` (below 95% similarity)
- Failures appended as WARN section in `test-results-e2e.md` (non-blocking)
- Gate: `testing.visual_regression.enabled`
- Canonical implementation: arc-phase-test.md lines 381–407

## Design Token Compliance

See [design-token-check.md](references/design-token-check.md) for design token compliance checks.

Summary:
- Validates that changed frontend files use token-based values (not hardcoded colors/spacing)
- Runs inline after E2E tier (team lead only)
- Findings appended to test report as WARN
- Gate: `testing.design_tokens.enabled`

## Accessibility Validation

See [accessibility-check.md](references/accessibility-check.md) for accessibility validation protocol.

Summary:
- WCAG 2.1 AA compliance checks on rendered routes
- Runs via e2e-browser-tester (injected instructions)
- Findings appended to `test-results-e2e.md`
- Gate: `testing.accessibility.enabled`

## Test History Persistence

See [history-protocol.md](references/history-protocol.md) for test history persistence format.

Summary:
- Written to `.claude/test-history/test-history.jsonl` (JSONL rolling window)
- Includes: pass/fail counts, durations, tier breakdown, flaky scores, PR number
- Rolling window: `testing.history.max_entries` (default 50)
- Gate: `testing.history.enabled` (default true)
- Inline in STEP 9.5 (no agent spawn)
- Canonical implementation: arc-phase-test.md STEP 9.5 (lines 580–635)

## Regression Detection

See [regression-detection.md](references/regression-detection.md) for regression signal detection.

Two complementary regression signals are evaluated in STEP 9.5. They use different config keys,
different algorithms, and different data granularities — they are NOT the same check:

**Signal 1 — Global pass-rate drop** (arc-phase-test.md STEP 9.5, inline):
- Compares current run pass rate against the immediately preceding history entry
- Config: `testing.history.pass_rate_drop_threshold` (float, 0.0–1.0, default `0.05` = 5% drop)
- Algorithm: `passRateDrop = previousPassRate - currentPassRate; if passRateDrop > threshold → warn`
- On detection: `updateCheckpoint({ test_regression_detected: true, regression_pass_rate_drop: passRateDrop })` + warn
- Gate: history must have ≥ 2 entries

**Signal 2 — Per-test historical series** (regression-detection.md, per-test algorithm):
- Evaluates each currently-failing test against its pass/fail history over last 10 runs
- Config: `testing.history.regression_threshold` (integer, default `7`) — minimum recent passing runs out of last 10 to classify as a regression
- Algorithm: `passCount = recentRuns.filter(passed).length; if passCount >= threshold → regression`
- On detection: test listed in regression report with confidence score
- Gate: history must have ≥ 2 entries; test must exist in history (skips new tests)

## Flaky Test Identification

See [flaky-detection.md](references/flaky-detection.md) for flaky test identification.

Summary:
- Computes per-test flaky scores from history: `pass_in_some_runs AND fail_in_others`
- Scores persisted in history entries as `flaky_scores` map
- High-flaky tests surfaced in test report for human review
- Gate: `testing.flaky_detection.enabled` (default true)

## Security Patterns

### SAFE_TEST_COMMAND_PATTERN
```
/^[a-zA-Z0-9._\-\/ ]+$/
```
Validates test runner commands. Blocks semicolons, pipes, backticks, `$()`.
Applied to ALL commands parsed from project config files (package.json, pytest.ini).

### SAFE_PATH_PATTERN
```
/^[a-zA-Z0-9._\-\/]+$/
```
Validates all file paths. Rejects `..` traversal. Always quote: `"$file"`.

### E2E URL Scope Restriction
E2E URLs MUST be scoped to `localhost` or the `talisman.testing.tiers.e2e.base_url` host.
External URLs are rejected to prevent agent-browser from navigating to untrusted sites.

### Output Truncation
- 500-line ceiling for AI agent context
- Full output written to artifact file
- Summary (last 20-50 lines) extracted for agent context
- Secret scrubbing: `AWS_*`, `*_KEY`, `*_SECRET`, `*_TOKEN`, `Bearer `, `sk-*`, `ghp_*`, JWT tokens, emails redacted before agent ingestion. See [secret-scrubbing.md](references/secret-scrubbing.md) for regex patterns and `scrubSecrets()` implementation
