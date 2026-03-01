---
name: testing
description: |
  Test orchestration pipeline for arc Phase 7.7. Provides 3-tier testing
  (unit, integration, E2E/browser) with diff-scoped discovery, service startup,
  and structured reporting. Auto-loaded by arc orchestrator during test phase.
  Trigger keywords: testing, test pipeline, unit test, integration test, E2E test,
  test discovery, test report, QA, quality assurance.
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
| Integration test runner | Sonnet | Moderate complexity, service interaction |
| E2E browser tester | Sonnet | Browser interaction, snapshot analysis |
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
