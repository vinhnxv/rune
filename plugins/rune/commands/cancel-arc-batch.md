---
name: rune:cancel-arc-batch
description: |
  Alias for /rune:cancel-arc --variant=batch. Cancel an active arc batch loop.
  Removes the state file so the Stop hook allows the session to end after the
  current arc completes.

  Delegates to /rune:cancel-arc with --variant=batch for all logic.

  <example>
  user: "/rune:cancel-arc-batch"
  assistant: "Arc batch loop cancelled at iteration 2/4."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# /rune:cancel-arc-batch — Cancel Active Arc Batch Loop (Alias)

This command is a thin alias. All cancellation logic lives in `/rune:cancel-arc`.

**Delegates to**: `/rune:cancel-arc --variant=batch`

## Action

```javascript
// Redirect to the unified cancel-arc command with batch variant
Skill("rune:cancel-arc", "--variant=batch")
```

Invoke `/rune:cancel-arc --variant=batch` to cancel only the arc-batch loop state file
(`.rune/arc-batch-loop.local.md`). Session isolation is enforced — only cancels loops
owned by this session.

The currently-running arc will finish normally, but no further plans will be started.

To also cancel the current arc run: `/rune:cancel-arc`
