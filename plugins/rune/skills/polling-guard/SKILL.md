---
name: polling-guard
description: |
  Use when entering a monitoring loop for agent completion, when POLL-001 hook
  denies a sleep+echo command, or when translating waitForCompletion pseudocode
  into actual polling calls. Covers correct TaskList-based monitoring, per-command
  poll intervals, and anti-patterns that bypass task visibility.
  Keywords: waitForCompletion, polling loop, TaskList, sleep+echo, POLL-001.

  <example>
  Context: Orchestrator entering monitoring phase of a review workflow.
  user: (internal — poll loop about to start)
  assistant: "Following the canonical monitoring loop: TaskList every cycle, sleep 30 between checks."
  <commentary>Load polling-guard to ensure correct monitoring pattern.</commentary>
  </example>

  <example>
  Context: POLL-001 deny fired during arc workflow.
  user: (internal — hook denied sleep+echo)
  assistant: "Hook blocked the sleep+echo pattern. Switching to TaskList-based monitoring loop."
  <commentary>polling-guard skill explains why POLL-001 fires and the correct alternative.</commentary>
  </example>
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# Polling Guard — Monitoring Loop Fidelity

## Problem

During Rune multi-agent workflows, the LLM orchestrator frequently improvises `Bash("sleep 60 && echo poll check")` instead of following the `waitForCompletion` pseudocode that requires calling `TaskList` on every poll cycle. This anti-pattern:

1. **Provides zero visibility** into task progress (no TaskList call = no status check)
2. **Uses wrong intervals** (45s, 60s instead of configured 30s)
3. **Wastes tokens and time** — sleeping without checking means missed completions
4. **Persists despite text warnings** — instruction drift after 20+ turns makes text-only rules unreliable

## The Rule: Correct vs Incorrect Monitoring

### CORRECT — TaskList on every cycle

```
TaskList()          <- MANDATORY: check actual task status
  count completed
  log progress
  check if all done
  check stale tasks
Bash("sleep ${pollIntervalMs/1000}", { run_in_background: true })  <- MUST use run_in_background for sleeps >= 2s (harness blocks standalone sleep >= 2s)
```

### INCORRECT — sleep+echo proxy

```
Bash("sleep 60 && echo poll check")   <- BLOCKED: skips TaskList entirely
```

## Canonical Monitoring Loop

This is the 6-step inline template. Every `waitForCompletion` call MUST translate to this pattern:

```
POLL_INTERVAL = pollIntervalMs / 1000  // derive from per-command config (seconds)
MAX_ITERATIONS = ceil(timeoutMs / pollIntervalMs)

for iteration in 1..MAX_ITERATIONS:
  1. Call TaskList tool              <- MANDATORY every cycle
  2. Count completed vs expectedCount
  3. Log: "Progress: {completed}/{expectedCount} tasks"
  4. If completed >= expectedCount -> break
  5. Check stale: any task in_progress > staleWarnMs -> warn
  6. Call Bash("sleep ${POLL_INTERVAL}", { run_in_background: true })  <- MUST use run_in_background (harness blocks sleep >= 2s)
```

Parameters are derived from per-command config — never invented:
- `maxIterations = ceil(timeoutMs / pollIntervalMs)`
- `sleepSeconds = pollIntervalMs / 1000`

See [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) for the full utility specification and per-command configuration table.

## Classification Checklist

| Context | Action |
|---------|--------|
| `Bash("sleep 30", { run_in_background: true })` after TaskList call | CORRECT — monitoring cycle |
| `Bash("sleep 30")` without run_in_background | BLOCKED by harness — standalone sleep >= 2s is rejected |
| `Bash("sleep N && echo ...")` | BLOCKED — anti-pattern (hook will deny) |
| `Bash("sleep N; echo ...")` | BLOCKED — semicolon variant also caught |
| `Bash("sleep ${DELAY}")` in retry loop | LEGITIMATE — retry backoff, not monitoring |
| `sleep(pollIntervalMs)` in pseudocode | CORRECT — reference to config value |

## Anti-Patterns — NEVER DO

- **`Bash("sleep N")` without `run_in_background: true`** — Claude Code harness blocks standalone `sleep N` where N >= 2 seconds. Always use `Bash("sleep N", { run_in_background: true })`.
- **`Bash("sleep N && echo poll check")`** — blocks TaskList, provides zero visibility into task progress. This is the canonical anti-pattern. Also caught by POLL-001 hook.
- **`Bash("sleep N; echo poll check")`** — semicolon variant, same anti-pattern. Caught by enforcement hook.
- **`Bash("sleep 45")` or `Bash("sleep 60")`** — wrong interval. Config says 30s (`pollIntervalMs: 30_000`). Derive from config, don't invent.
- **Monitoring loop without TaskList call** — sleeping without checking means you cannot detect completed tasks or stale workers.
- **Arbitrary iteration counts** — must derive from `ceil(timeoutMs / pollIntervalMs)`. Don't hardcode `10` or `20` iterations.

## Enforcement

The `enforce-polling.sh` PreToolUse hook blocks sleep+echo anti-patterns at runtime during active Rune workflows. Deny code: **POLL-001**.

- **Detection**: `sleep N {&&|;} echo/printf` where N >= 10 seconds
- **Scope**: Only during active workflows (arc checkpoints or `.rune-*` state files — covers review, audit, work, mend, plan, forge, inspect, goldmask)
- **Recovery**: If POLL-001 fires, switch to the canonical monitoring loop above

If this skill is loaded correctly, the hook should rarely fire — the skill teaches the correct pattern before mistakes happen. The hook catches failures as a safety net.

## Additional Patterns

For advanced waiting patterns beyond TaskList polling (condition-based waiting,
exponential backoff, deadlock detection), see
[condition-based-waiting.md](references/condition-based-waiting.md).

## Reference

- [monitor-utility.md](../roundtable-circle/references/monitor-utility.md) — full monitoring utility specification, per-command config table, and Phase 2 event-driven fast path
- CLAUDE.md Rule #9 — inline polling fidelity rule
- `pollIntervalMs` is sourced from the per-command config table (don't hardcode 30s if config changes)
