# Phase 7: CLEANUP

1. **Dynamic member discovery** — read team config for ALL teammates (fallback: static worst-case array covering base, deep, and wave-based fixer names)
2. **Shutdown all members** — `SendMessage(shutdown_request)` to each
3. **Grace period** — `sleep 20` for teammate deregistration
4. **ID validation** — defense-in-depth `..` check + regex guard (SEC-003)
5. **TeamDelete with retry-with-backoff** (4 attempts: 0s, 5s, 10s, 15s) + process kill + filesystem fallback
6. **Update state file** — status → `"completed"` or `"partial"`
7. **Release workflow lock** — `rune_release_lock "mend"`
8. **Persist learnings** to Rune Echoes (TRACED layer)

## Teammate Fallback Array

```javascript
// FALLBACK: config.json read failed — static worst-case array.
// Dynamic spawnedFixerNames may be empty after context compaction (CLEAN-002).
const MAX_FIXERS = 8  // matches maxConcurrentFixers cap
allMembers = [
  ...Array.from({length: MAX_FIXERS}, (_, i) => `mend-fixer-${i + 1}`),
  ...Array.from({length: MAX_FIXERS}, (_, i) => `mend-fixer-deep-${i + 1}`),
  // Wave-based names (v1.163.0+)
  ...Array.from({length: 3}, (_, w) => Array.from({length: MAX_FIXERS}, (_, i) => `mend-fixer-w${w + 1}-${i + 1}`)).flat(),
  "ward-sentinel"
]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// ID validation (SEC-003)
if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Invalid mend id: ${id}`)

// 7. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "mend"`)
```
