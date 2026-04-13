# Phase 7: CLEANUP

1. **Dynamic member discovery** — read team config for ALL teammates (fallback: static worst-case array covering base, deep, and wave-based fixer names)
2. **Shutdown all members** — force-reply pre-message (Step 2a) → sleep 2s (Step 2b) → `SendMessage(shutdown_request)` (Step 2c). See [engines.md](../../team-sdk/references/engines.md) `shutdown()` for the force-reply rationale (GitHub #31389).
3. **Adaptive grace period** — `Math.min(20, Math.max(5, confirmedAlive * 5))` (or 2s if all confirmed dead)
4. **ID validation** — defense-in-depth `..` check + regex guard (SEC-003)
5. **TeamDelete with retry-with-backoff** (4 attempts: 0s, 3s, 6s, 10s) + process kill + filesystem fallback
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

// 8. Persist mend learnings to Rune Echoes
// Only persist if meaningful work was done (fixed + false positives + failed >= 1)
const totalFindings = fixedCount + falsePositiveCount + failedCount
if (totalFindings >= 1) {
  const echoLib = `\${RUNE_PLUGIN_ROOT}/scripts/lib/echo-append.sh`
  const mendContent = `Fixed: ${fixedCount}, False positives: ${falsePositiveCount}, Failed: ${failedCount}, Skipped: ${skippedCount}`
  Bash(`source "${echoLib}" && rune_echo_append \
    --role reviewer --layer inscribed \
    --source "rune:mend ${id}" \
    --title "Fix patterns: ${tomeSource} remediation" \
    --content "${mendContent}" \
    --confidence HIGH \
    --tags "mend,fixes,convergence"`)
}
```
