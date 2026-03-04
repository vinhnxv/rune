---
name: rune:plan-review
description: |
  Review a plan's code samples for implementation correctness using inspect agents.
  Thin wrapper around /rune:inspect --mode plan. Combines inspect agents
  (grace-warden, ruin-prophet, sight-oracle, vigil-keeper) to review proposed code
  samples for bugs, pattern violations, and security issues.

  <example>
  user: "/rune:plan-review plans/feat-auth-plan.md"
  assistant: "Running plan review with inspect agents..."
  </example>

  <example>
  user: "/rune:plan-review --focus security plans/feat-x.md"
  assistant: "Running security-focused plan review..."
  </example>
user-invocable: true
allowed-tools:
  - Agent
  - TaskCreate
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamCreate
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Bash
  - Glob
  - Grep
---

# /rune:plan-review — Plan Code Sample Review

Delegates to `/rune:inspect --mode plan $ARGUMENTS`.

Combines inspect agents (grace-warden, ruin-prophet, sight-oracle, vigil-keeper) to review
proposed code samples in a plan document for bugs, pattern violations, and security issues.

## Usage

```
/rune:plan-review plans/feat-x-plan.md              # Full review
/rune:plan-review --focus security plans/feat-x.md   # Security-focused
/rune:plan-review --dry-run plans/feat-x.md           # Preview scope
/rune:plan-review --max-agents 2 plans/feat-x.md     # Limit inspectors
```

## Execution

Read and execute the /rune:inspect command with `--mode plan` prepended to $ARGUMENTS.
All /rune:inspect flags are supported: `--focus`, `--max-agents`, `--dry-run`, `--threshold`, `--fix`, `--max-fixes`.
