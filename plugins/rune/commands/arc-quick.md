---
name: rune:arc-quick
description: |
  Quick 4-phase pipeline shim. Typed-slash-command alias for /rune:arc --quick-mode.
  Use when the user types /rune:arc-quick explicitly.
  Forwards all arguments to /rune:arc --quick-mode.
user-invocable: true
disable-model-invocation: true
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

# /rune:arc-quick — Quick Pipeline (Typed-Slash-Command Shim)

Forwards to `/rune:arc --quick-mode $ARGUMENTS`.

A typed-slash-command shim that preserves the `/rune:arc-quick` surface. For natural-language
routing ("run a quick arc", "use quick mode"), the tarnished router resolves to
`/rune:arc --quick-mode` automatically. This shim exists for users who type the command directly.

## Usage

```
/rune:arc-quick add a settings page             # Plan + build + review from prompt
/rune:arc-quick plans/my-plan.md                # Build + review from existing plan
/rune:arc-quick plans/my-plan.md --force        # Skip complexity warning
```

## Execution

Read and execute the `/rune:arc --quick-mode` skill with all arguments passed through.
