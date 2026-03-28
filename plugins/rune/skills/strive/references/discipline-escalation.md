# Discipline Escalation Chain (Phase 3 — Planned)

> **⚠️ NOT IMPLEMENTED**: This document describes a **planned design** — none of the escalation behavior below is implemented in code. Current behavior when discipline proofs fail: the TaskCompleted hook blocks the task (exit 2) and the worker receives stderr feedback. There is no automatic Retry → Decompose → Reassign → Escalate chain. Only activates when `discipline.enabled: true` AND `discipline.block_on_fail: true` in talisman.

When the discipline proof hook exits 2 (BLOCK), the worker receives feedback via stderr. The escalation chain provides structured recovery with a maximum of 4 attempts before human intervention:

1. **ATTEMPT 1 — Retry**: Worker receives the hook's failure message (which criteria failed, what evidence is missing). Worker retries the task with the discipline feedback, addressing the specific failing proofs.

2. **ATTEMPT 2 — Decompose**: If retry fails, the orchestrator splits the task into smaller sub-tasks. Each sub-task gets its own evidence path (`tmp/work/{timestamp}/evidence/{sub-task-id}/`). Decomposed tasks inherit the parent's acceptance criteria subset.

3. **ATTEMPT 3 — Reassign**: If decomposed tasks still fail, reassign to a different worker (fresh context window). The new worker receives the full failure history and prior evidence attempts.

4. **ATTEMPT 4 — Human escalation**: If all automated attempts fail, invoke `AskUserQuestion` with the failure details including: task description, all prior attempt results, failing criteria IDs, and evidence paths. Includes `silence_timeout` (default 5 min, separate from `max_convergence_iterations`) — if no human response within the timeout, mark task as FAILED and continue with remaining tasks.

## Configuration

- `discipline.max_convergence_iterations`: Controls automated attempts (default: 3). Total attempts = `max_convergence_iterations` + 1 (human).
- `discipline.block_on_fail: false` (WARN mode): No escalation triggered — hook warnings are advisory only.
- `discipline.enabled: false`: Entire escalation chain is skipped. Existing smart reassignment still operates independently.

## Attempt Tracking

Per-task attempt count tracked via task metadata field `discipline_attempts`. Incremented on each TaskCompleted hook rejection.
