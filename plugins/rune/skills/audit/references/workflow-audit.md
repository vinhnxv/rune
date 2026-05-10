# Workflow Audit — Tier 2 Cross-File Review Protocol

> Protocol for auditing cross-file workflows with Ash prompt injection for cross-boundary analysis.

## Overview

When a workflow is selected for audit, the system loads all workflow files as a cohesive group and instructs Ashes to analyze cross-file interactions (not just individual files).

## Workflow Audit Execution

1. Load all files in the workflow (including `shared_files`)
2. Pass them to the audit engine as `--focus-workflow <workflow-id>`
3. Inject cross-file analysis instructions into Ash system prompts
4. Generate workflow-specific findings in TOME alongside file-level findings
5. Update `workflows.json` with results

## Cross-File Prompt Extension

Injected into Ash system prompts when `--focus-workflow` is active:

```
In addition to per-file review, analyze these cross-file workflow concerns:

- **Data flow**: Does data transform correctly as it crosses file boundaries?
- **Error propagation**: Are errors caught and re-raised appropriately at each boundary?
- **State consistency**: Can the overall flow reach an inconsistent state?
- **Security**: Are auth/authz checks enforced at every entry point of this flow?
- **Contract compliance**: Do interfaces between files match (parameter types, return types)?
- **Transactions**: Are database transactions scoped correctly? Check for transactions
  spanning multiple service calls without rollback on partial failure.
- **Race conditions**: Can concurrent requests cause lost updates, double processing,
  or inconsistent state? Check for read-modify-write without locking.
- **Traceability**: Can a single request be traced across all files via logging or
  correlation IDs?
- **Ordering**: Are there implicit ordering dependencies between services not enforced
  in code?

Report cross-file findings with prefix "WF-" followed by finding type.
```

## Finding Prefixes

| Prefix | Description |
|--------|-------------|
| `WF-DATAFLOW` | Data transformation error across boundaries |
| `WF-ERROR` | Missing or incorrect error propagation |
| `WF-STATE` | State consistency violation |
| `WF-SEC` | Security boundary gap (auth/authz) |
| `WF-CONTRACT` | Interface mismatch between files |
| `WF-TX` | Transaction scope issue |
| `WF-RACE` | Concurrency/race condition risk |
| `WF-TRACE` | Missing traceability (logging, correlation IDs) |
| `WF-ORDER` | Implicit ordering dependency not enforced |
| `WF-CYCLE` | Circular import dependency (informational) |

## Result Write-Back

After workflow audit completes:

```
1. Parse TOME.md for WF-prefixed findings
2. Update workflows.json:
   - workflow.last_audited = now
   - workflow.last_audit_id = audit_id
   - workflow.audit_count += 1
   - workflow.findings = { cross_file: N, per_file: M }
   - workflow.status = "audited"
3. Update stats (total_workflows, audited_workflows, coverage_pct)
```

## Batch Selection

Workflows are selected independently from files:

```
max_per_batch = 3   // v3.x baked-in
scored = scoreAllWorkflows(workflows)
selected = sorted(scored, descending).slice(0, max_per_batch)
```

## Integration with File-Level Audit

Workflow audit is complementary to file-level:
- File-level audit focuses on individual file quality
- Workflow audit focuses on cross-file interaction correctness
- Both run in the same audit session (sequential: files first, then workflows)
- Workflow findings reference specific files but analyze interactions
