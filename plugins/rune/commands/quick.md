---
name: rune:quick
description: |
  Quick 4-phase pipeline. Beginner-friendly alias for /rune:arc-quick.
  Use when the user says "quick", "fast", "nhanh", "quick run",
  "plan build review mend", or wants the simplified pipeline.
  Forwards all arguments to /rune:arc-quick.

  <example>
  user: "/rune:quick add a settings page"
  assistant: "Starting quick pipeline: plan -> work -> review..."
  </example>

  <example>
  user: "/rune:quick plans/my-plan.md"
  assistant: "Running quick pipeline on existing plan..."
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
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:quick --- Quick Pipeline (Beginner Alias)

Delegates to `/rune:arc-quick $ARGUMENTS`.

A beginner-friendly shortcut for `/rune:arc-quick`. Runs the lightweight 4-phase
pipeline: Plan -> Work -> Review -> Mend in one command.

## Usage

```
/rune:quick add a settings page             # Plan + build + review from prompt
/rune:quick plans/my-plan.md                # Build + review from existing plan
/rune:quick plans/my-plan.md --force        # Skip complexity warning
```

## What Happens

1. **Plan** --- Creates a quick plan from your prompt (skipped if you pass a plan file)
2. **Work** --- Swarm workers implement the plan
3. **Review** --- Multi-agent code review of the changes

**Output**: Feature branch with commits + review findings

## When to Use Full Arc Instead

If your plan has 8+ tasks or cross-cutting concerns, arc-quick will suggest switching
to `/rune:arc` for the full 45-phase pipeline (forge, gap analysis, mend, testing, ship).

## After Quick Pipeline

- `/rune:mend tmp/reviews/{id}/TOME.md` --- Fix review findings
- `/rune:arc plans/...` --- Run full pipeline if needed
- `git push` --- Push your changes

## Execution

Read and execute the `/rune:arc-quick` skill with all arguments passed through.
