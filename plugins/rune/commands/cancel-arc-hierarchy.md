---
name: rune:cancel-arc-hierarchy
description: |
  Alias for /rune:cancel-arc --variant=hierarchy. Cancel an active arc-hierarchy
  execution loop. Marks the state file as cancelled so the next child arc invocation
  does not proceed. The currently-executing child arc (if any) will finish normally.

  Delegates to /rune:cancel-arc with --variant=hierarchy for all logic.

  <example>
  user: "/rune:cancel-arc-hierarchy"
  assistant: "Arc hierarchy loop cancelled. Currently executing child [03] will finish normally."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
---

# /rune:cancel-arc-hierarchy — Cancel Active Arc Hierarchy Loop (Alias)

This command is a thin alias. All cancellation logic lives in `/rune:cancel-arc`.

**Delegates to**: `/rune:cancel-arc --variant=hierarchy`

## Action

```javascript
// Redirect to the unified cancel-arc command with hierarchy variant
Skill("rune:cancel-arc", "--variant=hierarchy")
```

Invoke `/rune:cancel-arc --variant=hierarchy` to cancel only the arc-hierarchy loop.

The state file (`.claude/arc-hierarchy-loop.local.md`) is **marked** as cancelled (not deleted),
so the EXEC_TABLE_JSON is preserved for resume via `/rune:arc-hierarchy {parentPlan} --resume`.

Session isolation is enforced — only cancels loops owned by this session.

The current child arc run (if any) will finish normally. No further child plans will be executed.

To also cancel the currently-running child arc: `/rune:cancel-arc`
