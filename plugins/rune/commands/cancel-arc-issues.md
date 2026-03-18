---
name: rune:cancel-arc-issues
description: |
  Alias for /rune:cancel-arc --variant=issues. Cancel an active arc-issues batch
  loop. Removes the state file so the Stop hook allows the session to end after
  the current arc completes.

  Delegates to /rune:cancel-arc with --variant=issues for all logic.

  <example>
  user: "/rune:cancel-arc-issues"
  assistant: "Arc issues loop cancelled at iteration 2/4."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Bash
  - Glob
---

# /rune:cancel-arc-issues — Cancel Active Arc Issues Loop (Alias)

This command is a thin alias. All cancellation logic lives in `/rune:cancel-arc`.

**Delegates to**: `/rune:cancel-arc --variant=issues`

## Action

```javascript
// Redirect to the unified cancel-arc command with issues variant
Skill("rune:cancel-arc", "--variant=issues")
```

Invoke `/rune:cancel-arc --variant=issues` to cancel only the arc-issues loop state file
(`.claude/arc-issues-loop.local.md`). Session isolation is enforced — only cancels loops
owned by this session.

The currently-running arc will finish normally, but no further issues will be started.

To see batch progress: Read `tmp/gh-issues/batch-progress.json`
To resume later: `/rune:arc-issues --resume`
To also cancel the current arc run: `/rune:cancel-arc`
