---
name: rune:review
description: |
  Review your code changes. Beginner-friendly alias for /rune:appraise.
  Use when the user says "review my code", "check my changes",
  "code review", "review this PR", or wants a multi-agent code review.
  Forwards all arguments to /rune:appraise.

  <example>
  user: "/rune:review"
  assistant: "Starting multi-agent code review..."
  </example>

  <example>
  user: "/rune:review --deep"
  assistant: "Starting deep multi-wave code review..."
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

# /rune:review — Review Your Code (Beginner Alias)

Delegates to `/rune:appraise $ARGUMENTS`.

A beginner-friendly shortcut for `/rune:appraise`. Reviews your code changes using
multiple specialized AI reviewers.

## Usage

```
/rune:review                           # Standard review of your git diff
/rune:review --deep                    # Deep multi-wave review (more thorough)
```

## What Happens

1. **Detect changes** — Reads your git diff automatically
2. **Summon reviewers** — Up to 7 specialized AI reviewers analyze your code
3. **Aggregate** — Findings are deduplicated and prioritized
4. **Report** — Produces a TOME with all findings

**Output**: `tmp/reviews/{id}/TOME.md`

## After Review

- `/rune:mend tmp/reviews/{id}/TOME.md` — Fix the findings automatically

## Execution

Read and execute the `/rune:appraise` skill with all arguments passed through.
All `/rune:appraise` flags are supported: `--deep`, `--partial`, `--dry-run`, `--max-agents`, `--auto-mend`.
