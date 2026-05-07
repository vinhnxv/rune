# Wave Scheduling — Multi-Wave Review Orchestration

> Assigns Ashes to execution waves for depth=deep reviews. Standard depth bypasses wave scheduling entirely (single-pass, current behavior). Wave scheduling enables a Parameterized Roundtable Circle where `/rune:appraise --deep` and `/rune:audit` share the same phase orchestration with different scope/depth parameters.

## Constants

```javascript
const MAX_WAVES = 3           // Hard cap on wave count
const MERGE_THRESHOLD = 3     // Minimum agents for a wave to remain standalone
const TIMEOUT_FLOOR_MS = 120_000  // 2 min — minimum timeout per wave (prevents starvation)
```

## Wave Registry

Wave assignments are derived from `circle-registry.md` entries. Each Ash has a `wave` field and a `deepOnly` flag in the registry. The wave registry is NOT a separate data structure — it reads from circle-registry.md at runtime.

```javascript
// Derived from circle-registry.md — NOT duplicated here.
// Each Ash entry has: { name, wave, deepOnly, prefix, contextBudget }
//
// Wave assignments:
//   Wave 1: Core reviewers (always run first)
//     - forge-warden, ward-sentinel, pattern-weaver, veil-piercer
//     - glyph-scribe (conditional: frontend files), knowledge-keeper (conditional: docs)
//
//   Wave 2: Deep investigation (deepOnly: true)
//     - rot-seeker, strand-tracer, decree-auditor, fringe-watcher
//
//   Wave 3: Deep dimension analysis (deepOnly: true)
//     - truth-seeker, ruin-watcher, breach-hunter, order-auditor
//     - ember-seer, signal-watcher, decay-tracer
//
// Standard depth: Only Wave 1 runs (single-pass, identical to current behavior).
// Deep depth: All waves run sequentially (Wave 1 findings feed into Wave 2/3 context).
```

## `getWaveRegistry(circleEntries)`

Reads circle-registry entries and groups them by wave number.

**Inputs**: `circleEntries` — array of Ash entries from circle-registry.md, each with `{ name, wave, deepOnly, prefix, contextBudget }`
**Outputs**: `Map<number, AshEntry[]>` — wave number to list of Ash entries
**Error handling**: Entries without `wave` field default to wave 1. Entries with invalid wave (< 1 or > MAX_WAVES) are clamped.

```javascript
function getWaveRegistry(circleEntries) {
  const waves = new Map()

  for (const entry of circleEntries) {
    const wave = Math.max(1, Math.min(entry.wave ?? 1, MAX_WAVES))
    if (!waves.has(wave)) waves.set(wave, [])
    waves.get(wave).push(entry)
  }

  return waves
}
```

## `selectWaves(circleEntries, depth, selectedAsh)`

Filters the wave registry based on depth and which Ashes were selected by Rune Gaze.

**Inputs**:
- `circleEntries` — full registry from circle-registry.md
- `depth` — `"standard"` or `"deep"`
- `selectedAsh` — Set of Ash names selected by Rune Gaze / smart-selection

**Outputs**: `{ waveNumber: number, agents: AshEntry[] }[]` — ordered list of waves to execute
**Error handling**: Empty selectedAsh returns `[]`. Unknown depth treated as `"standard"`.

```javascript
function selectWaves(circleEntries, depth, selectedAsh) {
  // Standard depth: single-pass with Wave 1 agents only (current behavior)
  if (depth !== "deep") {
    const wave1 = circleEntries
      .filter(e => !e.deepOnly && selectedAsh.has(e.name))
    return wave1.length > 0 ? [{ waveNumber: 1, agents: wave1 }] : []
  }

  // Deep depth: all waves, filtered by selection + deepOnly gates
  const registry = getWaveRegistry(circleEntries)

  // Sort wave numbers ascending — CRITICAL: use spread to avoid mutation
  const sortedWaveNumbers = [...registry.keys()].sort((a, b) => a - b)

  const waves = []
  for (const waveNum of sortedWaveNumbers) {
    const agents = registry.get(waveNum).filter(entry => {
      // Wave 1: filter by Rune Gaze selection (conditional Ashes may be excluded)
      if (waveNum === 1) return selectedAsh.has(entry.name)
      // Wave 2+: deepOnly agents always included in deep mode
      return entry.deepOnly
    })

    if (agents.length > 0) {
      waves.push({ waveNumber: waveNum, agents })
    }
  }

  return mergeSmallWaves(waves)
}
```

## `mergeSmallWaves(waves)`

Merges undersized waves into adjacent waves. Wave 3 merges into Wave 2 when it has fewer than `MERGE_THRESHOLD` agents. Wave 1 is never merged (it always runs first).

**Inputs**: `waves` — `{ waveNumber, agents }[]` — ordered wave list
**Outputs**: `{ waveNumber, agents }[]` — potentially reduced wave list
**Error handling**: Single-wave input returned unchanged. Empty input returns `[]`.

```javascript
function mergeSmallWaves(waves) {
  if (waves.length <= 1) return waves

  // Work backwards: merge small trailing waves into their predecessor
  const result = [...waves]

  for (let i = result.length - 1; i >= 1; i--) {
    if (result[i].agents.length < MERGE_THRESHOLD) {
      // Merge into previous wave
      result[i - 1].agents.push(...result[i].agents)
      result.splice(i, 1)
    }
  }

  // Re-number waves sequentially (1-indexed)
  result.forEach((w, idx) => { w.waveNumber = idx + 1 })

  return result
}
```

## Timeout Distribution

Total timeout budget is divided proportionally across waves, with carry-forward for under-budget waves.

**Inputs**:
- `waves` — output of `selectWaves()`
- `totalTimeoutMs` — total timeout budget (e.g., 900,000 for audit)

**Outputs**: `{ waveNumber, agents, timeoutMs }[]` — waves with allocated timeouts

```javascript
function distributeTimeouts(waves, totalTimeoutMs) {
  if (waves.length === 0) return []
  if (waves.length === 1) {
    waves[0].timeoutMs = totalTimeoutMs
    return waves
  }

  const totalAgents = waves.reduce((sum, w) => sum + w.agents.length, 0)
  if (totalAgents === 0) return waves

  // Proportional allocation by agent count
  for (const wave of waves) {
    const proportion = wave.agents.length / totalAgents
    const allocated = Math.floor(totalTimeoutMs * proportion)
    wave.timeoutMs = Math.max(allocated, TIMEOUT_FLOOR_MS)
  }

  // Budget warning: check if sum exceeds total (can happen due to TIMEOUT_FLOOR_MS)
  const allocated = waves.reduce((sum, w) => sum + w.timeoutMs, 0)
  if (allocated > totalTimeoutMs) {
    const overage = allocated - totalTimeoutMs
    // Reduce the largest wave's timeout to stay within budget
    const largest = [...waves].sort((a, b) => b.timeoutMs - a.timeoutMs)[0]
    largest.timeoutMs = Math.max(largest.timeoutMs - overage, TIMEOUT_FLOOR_MS)

    // If still over budget after adjustment, warn but proceed
    const finalTotal = waves.reduce((sum, w) => sum + w.timeoutMs, 0)
    if (finalTotal > totalTimeoutMs) {
      warn(`Wave timeout sum (${finalTotal}ms) exceeds budget (${totalTimeoutMs}ms) due to TIMEOUT_FLOOR_MS constraints`)
    }
  }

  return waves
}
```

## Carry-Forward Budget

When a wave completes under its allocated timeout, the remaining budget carries forward to subsequent waves.

```javascript
function executeWavesWithCarryForward(waves, totalTimeoutMs) {
  const scheduled = distributeTimeouts(waves, totalTimeoutMs)
  let carryForwardMs = 0

  for (const wave of scheduled) {
    const effectiveTimeout = wave.timeoutMs + carryForwardMs
    const startTime = Date.now()

    // Execute wave (see orchestration-phases.md for full execution pattern)
    const result = executeWave(wave, effectiveTimeout)

    const elapsed = Date.now() - startTime
    const saved = effectiveTimeout - elapsed

    // Carry forward saved time (only positive values — don't penalize for slow waves)
    carryForwardMs = Math.max(0, saved)

    if (result.timedOut) {
      warn(`Wave ${wave.waveNumber} timed out after ${effectiveTimeout}ms. Proceeding with partial results.`)
      carryForwardMs = 0  // No carry-forward from timed-out waves
    }
  }
}
```

## Integration with Existing Workflows

### Standard Depth (No Change)

When `depth === "standard"` (the default for `/rune:appraise`), `selectWaves()` returns a single wave containing Wave 1 agents. The orchestration is identical to the current single-pass behavior — no wave scheduling overhead.

### Deep Depth

When `depth === "deep"` (via `/rune:appraise --deep` or `/rune:audit`):

1. **Wave 1** runs first — core reviewers produce initial findings
2. **Wave 2** runs next — deep investigation agents receive Wave 1 findings as context
3. **Wave 3** (if not merged) — dimension analysis agents receive Wave 1+2 findings
4. Each wave has its own `TeamCreate` + `TaskCreate` + monitor cycle
5. Findings from all waves are aggregated by Runebinder in Phase 5

### Convergence Re-Review

When convergence triggers a re-review in deep mode, it uses `depth=deep` with `--max-agents 3` (not `depth=standard`). This ensures deep investigation agents participate in convergence passes.

## References

- [Circle Registry](circle-registry.md) — Source of truth for Ash wave assignments and deepOnly flags
- [Smart Selection](smart-selection.md) — File-to-Ash assignment, Rune Gaze selection
- [Monitor Utility](monitor-utility.md) — Per-wave timeout configuration and polling
- [Orchestration Phases](orchestration-phases.md) — Shared phase execution reference
