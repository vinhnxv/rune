# Test Strategy Template

Reference template for `generateTestStrategy()`. The team lead fills in each section
based on the inputs from scope detection (STEP 1) and scenario discovery (STEP 0.5).
Output is written to `tmp/arc/{id}/test-strategy.md` and consumed by downstream test runners.

## Input Contract

```
generateTestStrategy({
  diffFiles,                // string[] — all changed files from diff
  backendFiles,             // string[] — backend implementation files (.py, .go, .rs, .rb)
  frontendFiles,            // string[] — frontend implementation files (.ts, .tsx, .js, .jsx)
  testFiles,                // string[] — existing test files in the diff
  has_frontend,             // boolean  — whether frontend files were detected
  enrichedPlan,             // string   — contents of enriched-plan.md
  tiers,                    // { unit: boolean, integration: boolean, e2e: boolean, contract?: boolean, extended?: boolean }
  uncoveredImplementations, // string[] — implementation files with no matching test file
  scopeLabel,               // string   — scope classification (e.g., "backend-only", "full-stack")
  scenarios,                // Scenario[] — from STEP 0.5 scenario discovery (see scenario-schema.md)
})
```

## Output Template

The lead generates a markdown document with the following sections.

---

### 1. Scope Summary

Describe what changed and what needs testing.

```markdown
## Scope Summary
- **Scope**: {scopeLabel}
- **Changed files**: {diffFiles.length} total ({backendFiles.length} backend, {frontendFiles.length} frontend, {testFiles.length} tests)
- **Has frontend**: {has_frontend}
- **Key changes**: (1-3 bullet summary from enrichedPlan)
```

### 2. Tier Configuration

Which tiers are active for this run.

```markdown
## Active Tiers
| Tier | Enabled | Rationale |
|------|---------|-----------|
| unit | {tiers.unit} | (why enabled/disabled based on scope) |
| integration | {tiers.integration} | (why) |
| e2e | {tiers.e2e} | (why) |
| contract | {tiers.contract ?? false} | (why) |
| extended | {tiers.extended ?? false} | (why) |
```

### 3. Test Files Per Tier

Map each existing test file to its tier. Runners use this to know which tests to execute.

```markdown
## Test File Assignment
### Unit
- tests/test_auth.py
### Integration
- tests/integration/test_auth_flow.py
### E2E
- (none — or list files)
```

### 4. Uncovered Implementation Files

Files with changes but no corresponding test file. Runners should generate tests for these.

```markdown
## Uncovered Files
| File | Suggested test path | Priority |
|------|-------------------|----------|
| src/auth/login.py | tests/test_login.py | high |
```

### 5. Scenario Integration

Test scenarios from the plan (STEP 0.5). Runners merge these with auto-discovered tests.
See `scenario-schema.md` for the Scenario type definition.

```markdown
## Scenarios
| ID | Description | Tier | Target files |
|----|-------------|------|-------------|
| S1 | User login with valid credentials | integration | src/auth/login.py |
```

### 6. Risk Areas

High-risk files based on change complexity, number of dependents, or historical flakiness.

```markdown
## Risk Areas
| File | Risk | Reason |
|------|------|--------|
| src/auth/session.py | high | Core auth path, 12 dependents |
```

---

## Notes

- The lead fills in this template by reading the inputs and exercising judgment.
  There is no deterministic function — the lead synthesizes scope, plan context, and
  scenarios into a coherent strategy document.
- Runners receive the completed strategy via `tmp/arc/{id}/test-strategy.md` and use
  the tier assignments and uncovered file list to drive test generation and execution.
- When `scenarios` is non-empty, runners MUST include scenario-driven tests alongside
  auto-discovered tests. Scenarios take priority on conflict.
