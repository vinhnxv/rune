---
name: rune:verify
description: |
  TOME-finding classifier shim. Typed-slash-command alias for /rune:inspect --verify-tome.
  Use when the user types /rune:verify explicitly.
  Forwards all arguments to /rune:inspect --verify-tome.
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

# /rune:verify — TOME Finding Verifier (Typed-Slash-Command Shim)

Forwards to `/rune:inspect --verify-tome $ARGUMENTS`.

A typed-slash-command shim that preserves the `/rune:verify` surface. For natural-language
routing ("verify TOME findings", "classify review findings"), the tarnished router resolves to
`/rune:inspect --verify-tome` automatically. This shim exists for users who type the command
directly.

Classifies TOME findings as TRUE_POSITIVE / FALSE_POSITIVE / NEEDS_CONTEXT before mend dispatch.

## Usage

```
/rune:verify tmp/reviews/abc123/TOME.md          # Classify all findings
/rune:verify tmp/arc/arc-20260516-xyz/tome.md    # Classify arc TOME findings
```

## Execution

Read and execute the `/rune:inspect --verify-tome` skill with all arguments passed through.
