---
name: rune:work
description: |
  Implement a plan. Beginner-friendly alias for /rune:strive.
  Use when the user says "work on this", "implement", "build it",
  "execute the plan", "start working", or wants to implement a plan file.
  Forwards all arguments to /rune:strive.

  <example>
  user: "/rune:work plans/2026-02-24-feat-auth-plan.md"
  assistant: "Starting implementation with swarm workers..."
  </example>

  <example>
  user: "/rune:work"
  assistant: "Looking for recent plans to implement..."
  </example>
user-invocable: true
allowed-tools:
  - Task
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

# /rune:work — Implement a Plan (Beginner Alias)

Delegates to `/rune:strive $ARGUMENTS`.

A beginner-friendly shortcut for `/rune:strive`. Takes a plan file and implements it
using a swarm of AI workers.

## Usage

```
/rune:work plans/my-plan.md            # Implement the specified plan
/rune:work                             # Auto-detect the most recent plan
/rune:work --approve plans/my-plan.md  # Require your approval before each task
```

## What Happens

1. **Parse** — Reads the plan and creates a task list
2. **Spawn workers** — AI teammates claim and implement tasks independently
3. **Quality gates** — Runs linting and type checks
4. **Complete** — All tasks done, code committed

## Prerequisites

You need a plan file first. Create one with `/rune:plan`.

## After Working

- `/rune:review` — Review the code changes

## Execution

Read and execute the `/rune:strive` skill with all arguments passed through.
All `/rune:strive` flags are supported: `--approve`, `--worktree`.
