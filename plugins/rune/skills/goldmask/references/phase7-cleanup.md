# Phase 7: Cleanup

Standard 5-component team cleanup for goldmask with session-specific state file removal.

## Teammate Fallback Array

```javascript
// FALLBACK: hardcoded list of all 8 goldmask teammates
allMembers = [
  "lore-analyst",
  "data-layer-tracer",
  "api-contract-tracer",
  "business-logic-tracer",
  "event-message-tracer",
  "config-dependency-tracer",
  "wisdom-sage",
  "goldmask-coordinator"
]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// SEC-5: Validate session_id before rm-rf (project convention)
if (!/^[a-zA-Z0-9_-]+$/.test(session_id)) { error("Invalid session_id"); return }

// 6. Clean up state file
Bash(`rm -f "tmp/.rune-goldmask-${session_id}.json" 2>/dev/null`)

// 7. Release workflow lock
Bash(`CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && source "\${CWD}/plugins/rune/scripts/lib/workflow-lock.sh" && rune_release_lock "goldmask"`)
```
