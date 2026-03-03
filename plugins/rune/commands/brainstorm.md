---
name: rune:brainstorm
description: |
  Explore a feature idea through dialogue. Beginner-friendly alias for /rune:brainstorm skill.
  Use when the user says "brainstorm", "explore idea", "discuss feature",
  "what should we build", "let's think about", or wants to brainstorm before planning.
  Forwards all arguments to /rune:brainstorm.

  <example>
  user: "/rune:brainstorm add user authentication"
  assistant: "Starting brainstorm session..."
  </example>

  <example>
  user: "/rune:brainstorm --quick fix the search bug"
  assistant: "Starting a quick solo brainstorm..."
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

# /rune:brainstorm — Explore Ideas (Beginner Alias)

Delegates to `/rune:brainstorm $ARGUMENTS`.

A beginner-friendly shortcut for the brainstorm skill. Explore features and ideas through
structured dialogue before committing to a full planning pipeline.

## Usage

```
/rune:brainstorm add user authentication     # Interactive mode choice
/rune:brainstorm --quick fix the search bug  # Solo mode (conversation only)
/rune:brainstorm --deep redesign the API     # Deep mode (advisors + sages)
```

## What Happens

1. **Mode Selection** — Choose Solo, Roundtable Advisors, or Deep analysis
2. **Exploration** — Structured dialogue exploring WHAT to build
3. **Synthesis** — Captures insights, decisions, and open questions
4. **Output** — Persistent brainstorm document saved to `docs/brainstorms/`

## After Brainstorming

- `/rune:plan docs/brainstorms/...` — Turn the brainstorm into a full plan
- `/rune:devise --brainstorm-context docs/brainstorms/...` — Plan with brainstorm context

## Execution

Load and execute the brainstorm skill (`skills/brainstorm/SKILL.md`) with all arguments passed through.
All brainstorm flags are supported: `--quick`, `--deep`.
