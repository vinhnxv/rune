---
name: rune:plan
description: |
  Plan a feature or task. Beginner-friendly alias for /rune:devise.
  Use when the user says "plan", "plan this feature", "plan a task",
  "help me plan", or wants to create a plan for implementation.
  Forwards all arguments to /rune:devise.

  <example>
  user: "/rune:plan add user authentication"
  assistant: "Starting the planning workflow..."
  </example>

  <example>
  user: "/rune:plan --quick fix the search bug"
  assistant: "Starting a quick planning workflow..."
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

# /rune:plan — Plan a Feature (Beginner Alias)

Delegates to `/rune:devise $ARGUMENTS`.

A beginner-friendly shortcut for `/rune:devise`. Creates a detailed implementation plan
using multi-agent research and synthesis.

## Usage

```
/rune:plan add user authentication     # Full pipeline (brainstorm + research + synthesize + review)
/rune:plan --quick fix the search bug  # Quick mode (research + synthesize + review)
```

## What Happens

1. **Brainstorm** — Explores approaches and constraints (skipped with `--quick`)
2. **Research** — Analyzes your codebase, git history, and best practices
3. **Synthesize** — Consolidates findings into a structured plan
4. **Review** — Validates the plan for completeness

**Output**: `plans/YYYY-MM-DD-{type}-{name}-plan.md`

**Tip**: Not sure what to build? Use `/rune:brainstorm` first to explore ideas before planning.

## After Planning

- `/rune:work plans/...` — Implement the plan
- `/rune:forge plans/...` — Enrich the plan with more detail

## Execution

Read and execute the `/rune:devise` skill with all arguments passed through.
All `/rune:devise` flags are supported: `--quick`, `--no-brainstorm`, `--no-forge`, `--exhaustive`.
