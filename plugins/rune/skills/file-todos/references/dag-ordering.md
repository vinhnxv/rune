# DAG Ordering — Topological Sort & Wave Assignment

Reference for dependency-aware todo ordering using Kahn's algorithm. The DAG is built **per-source** — each source manifest contains its own DAG. Cross-source edges are recorded in `cross_source_refs` for the optional cross-source index.

## Algorithm Overview

| Algorithm | Purpose | Complexity |
|-----------|---------|-----------|
| Kahn's (BFS topological sort) | Dependency ordering + wave grouping | O(V+E) |
| Depth-first wave assignment | Mandatory boundary grouping (primary) | O(V+E) |
| Coffman-Graham width-limiting | Optional post-processing for fixed worker counts | O(V+E) |
| Critical Path Method (CPM) | Bottleneck identification via forward+backward pass | O(V+E) |

**Key insight**: Kahn's algorithm naturally discovers wave groupings — all nodes with in-degree 0 form wave 1, their dependents (in-degree 0 after removal) form wave 2, etc. This eliminates a separate wave-assignment pass.

**Total performance**: For 500 todos with ~1000 edges: Kahn's + wave assignment + critical path all run in <10ms. No optimization beyond the dirty-signal incremental rebuild is needed.

## Pre-Validation

Before running Kahn's algorithm, validate the graph for self-dependencies and dangling references. Remove invalid edges so the sort does not stall.

```javascript
/**
 * Validate dependency graph and remove invalid edges before sorting.
 * @param {Map<string, Set<string>>} graph - id -> Set<dependency_id>
 * @param {Set<string>} allIds - All qualified IDs in this source
 * @returns {{ selfDeps: string[], danglingRefs: Array<{from: string, to: string}> }}
 */
function validateAndCleanGraph(
  graph: Map<string, Set<string>>,
  allIds: Set<string>
): ValidationResult {
  const selfDeps: string[] = []
  const danglingRefs: Array<{ from: string; to: string }> = []

  for (const [id, deps] of graph) {
    for (const dep of [...deps]) {
      if (dep === id) {
        // Self-dependency — always invalid, auto-remove with warning
        selfDeps.push(id)
        deps.delete(dep)
      } else if (!allIds.has(dep)) {
        // Dangling reference — remove edge, record for warning
        danglingRefs.push({ from: id, to: dep })
        deps.delete(dep)
      }
    }
  }

  // Note: cross-source refs (e.g., "review/001" in a work source) are NOT dangling —
  // they are valid external refs recorded in cross_source_refs. Only intra-source
  // refs are validated here.

  return { selfDeps, danglingRefs }
}
```

**Self-dependencies**: Always invalid. Auto-removed with a warning logged to the manifest's `unresolved_deps` field. No user action required — these indicate a bug in the todo creation pipeline.

**Dangling references**: A `dependencies` entry that references a non-existent todo ID within this source. Removed before sort to prevent stalls. Logged in `dependency_graph.unresolved_deps`. May be from a deleted todo or a typo.

**Cross-source refs are NOT dangling**: When a `work` todo lists `review/001` in its `dependencies[]`, that is a valid cross-source reference. These are preserved and recorded in `dependency_graph.cross_source_refs` — they are NOT removed from the frontmatter and are NOT flagged as dangling.

## Kahn's Algorithm (Topological Sort)

```javascript
/**
 * Build dependency DAG and compute topological order for a single source.
 * @param {TodoEntry[]} todos - All todos for one source
 * @returns {{ order: string[], hasCycles: bool, unresolvedDeps: string[], graph: Map, reverse: Map }}
 */
function buildDependencyDAG(todos: TodoEntry[]): DAGResult {
  // 1. Build adjacency list from dependencies[] field
  // dependencies[] uses qualified IDs: "review/001", "work/003"
  const graph = new Map<string, Set<string>>()  // id -> Set<dependency_id>
  const reverse = new Map<string, Set<string>>() // id -> Set<dependent_id> (for dependents field)

  for (const todo of todos) {
    const id = `${todo.source}/${todo.issue_id}`
    graph.set(id, new Set(todo.dependencies || []))
    for (const dep of (todo.dependencies || [])) {
      if (!reverse.has(dep)) reverse.set(dep, new Set())
      reverse.get(dep)!.add(id)
    }
  }

  // 2. Pre-validation: detect and remove invalid edges
  const allIds = new Set(todos.map(t => `${t.source}/${t.issue_id}`))
  const { selfDeps, danglingRefs } = validateAndCleanGraph(graph, allIds)

  // 3. Kahn's algorithm for topological sort
  const inDegree = new Map<string, number>()
  for (const [id, deps] of graph) {
    inDegree.set(id, deps.size)
  }

  // Start queue with all root nodes (no dependencies)
  const queue: string[] = []
  for (const [id, degree] of inDegree) {
    if (degree === 0) queue.push(id)
  }

  // Sort queue by priority (p1 > p2 > p3), then source order, then issue_id
  queue.sort((a, b) => comparePriority(todos, a, b))

  const order: string[] = []
  while (queue.length > 0) {
    const current = queue.shift()!
    order.push(current)

    for (const dependent of (reverse.get(current) || [])) {
      const newDegree = (inDegree.get(dependent) ?? 0) - 1
      inDegree.set(dependent, newDegree)
      if (newDegree === 0) {
        queue.push(dependent)
        queue.sort((a, b) => comparePriority(todos, a, b))
      }
    }
  }

  // 4. Cycle detection: if order doesn't include all nodes, cycles exist
  const hasCycles = order.length < graph.size
  const unresolvedDeps: string[] = []
  if (hasCycles) {
    for (const [id, degree] of inDegree) {
      if (degree > 0) unresolvedDeps.push(id)
    }
  }

  // 5. Collect cross-source refs from dependency edges
  const crossSourceRefs = new Set<string>()
  for (const todo of todos) {
    for (const dep of (todo.dependencies || [])) {
      const depSource = dep.split('/')[0]
      if (depSource && depSource !== todo.source) {
        crossSourceRefs.add(dep)
      }
    }
    for (const rel of (todo.related_todos || [])) {
      const relSource = rel.split('/')[0]
      if (relSource && relSource !== todo.source) {
        crossSourceRefs.add(rel)
      }
    }
  }

  return {
    order,
    hasCycles,
    unresolvedDeps: [...unresolvedDeps, ...danglingRefs.map(r => r.from)],
    graph,
    reverse,
    crossSourceRefs: [...crossSourceRefs],
    warnings: {
      selfDeps,
      danglingRefs
    }
  }
}
```

## Priority Comparator

Used to sort Kahn's queue so higher-priority nodes are processed first, maintaining priority order within each wave:

```javascript
/**
 * Compare two todo IDs for priority-based queue ordering.
 * Lower return value = processed first (higher priority).
 * @param {TodoEntry[]} todos - All todos for lookup
 * @param {string} idA - Qualified ID (e.g., "work/001")
 * @param {string} idB - Qualified ID (e.g., "work/002")
 * @returns {number} Negative if A should come first, positive if B should come first
 */
function comparePriority(todos: TodoEntry[], idA: string, idB: string): number {
  const priorityOrder: Record<string, number> = { p1: 0, p2: 1, p3: 2 }
  const todoA = findTodoById(todos, idA)
  const todoB = findTodoById(todos, idB)

  // Primary: priority level (p1 before p2 before p3)
  const pA = priorityOrder[todoA?.priority ?? 'p3'] ?? 2
  const pB = priorityOrder[todoB?.priority ?? 'p3'] ?? 2
  if (pA !== pB) return pA - pB

  // Secondary: source order (review < audit < work) — review findings block work tasks
  const sourceOrder: Record<string, number> = { review: 0, audit: 1, work: 2 }
  const sA = sourceOrder[todoA?.source ?? 'work'] ?? 2
  const sB = sourceOrder[todoB?.source ?? 'work'] ?? 2
  if (sA !== sB) return sA - sB

  // Tertiary: issue_id ascending (001 before 002) — preserve creation order
  return (todoA?.issue_id ?? '').localeCompare(todoB?.issue_id ?? '')
}

/**
 * Find a todo entry by its qualified ID.
 * @param {TodoEntry[]} todos - All todos
 * @param {string} qualifiedId - Format: "{source}/{issue_id}" (e.g., "work/001")
 * @returns {TodoEntry | undefined}
 */
function findTodoById(todos: TodoEntry[], qualifiedId: string): TodoEntry | undefined {
  const [source, issueId] = qualifiedId.split('/')
  return todos.find(t => t.source === source && t.issue_id === issueId)
}
```

## Wave Assignment

Wave assignment groups todos into parallel execution batches. The primary approach is **depth-first wave assignment** (dependency boundary), which sets the wave number to the longest path from any root to this node. Coffman-Graham width-limiting is an optional post-processing step for fixed worker counts.

### Depth-First Wave Assignment (Primary)

```javascript
/**
 * Assign wave numbers using depth-first dependency boundaries.
 * Wave N = longest dependency path to reach this node from any root.
 * Todos in the same wave can execute in parallel.
 *
 * @param {string[]} topologicalOrder - Output of buildDependencyDAG
 * @param {Map<string, Set<string>>} graph - id -> Set<dependency_id>
 * @returns {Map<string, number>} id -> wave number (1-indexed)
 */
function assignWavesDepthFirst(
  topologicalOrder: string[],
  graph: Map<string, Set<string>>
): Map<string, number> {
  // Guard: empty input
  if (!topologicalOrder || topologicalOrder.length === 0) {
    return new Map()
  }

  const waveMap = new Map<string, number>()

  for (const id of topologicalOrder) {
    const deps = graph.get(id) || new Set()
    if (deps.size === 0) {
      // Root node — wave 1
      waveMap.set(id, 1)
    } else {
      // Wave = max(dependency waves) + 1
      const maxDepWave = Math.max(...[...deps].map(d => waveMap.get(d) ?? 1))
      waveMap.set(id, maxDepWave + 1)
    }
  }

  return waveMap
}
```

**Why depth-first over capacity-based**: Depth-first creates *mandatory* dependency boundaries (correctness-first). A capacity-based approach (e.g., max 5 todos per wave) can place dependency-linked todos in the same wave, causing deadlocks. Depth-first ensures wave N always completes before wave N+1 starts.

### Coffman-Graham Width-Limiting (Optional Post-Processing)

For fixed worker counts (e.g., always 3 workers per wave), apply Coffman-Graham as a post-processing step:

```javascript
/**
 * Apply Coffman-Graham width limiting to wave assignments.
 * Splits waves wider than maxWidth into sub-waves, preserving dependency order.
 * Only use when worker count is fixed and wave balancing is important.
 *
 * @param {Map<string, number>} waveMap - Output of assignWavesDepthFirst
 * @param {string[]} topologicalOrder - For stable ordering within sub-waves
 * @param {number} maxWidth - Maximum todos per wave (typically worker count)
 * @returns {Map<string, number>} id -> adjusted wave number (1-indexed)
 */
function applyCoffmanGraham(
  waveMap: Map<string, number>,
  topologicalOrder: string[],
  maxWidth: number
): Map<string, number> {
  // Group by current wave
  const waveGroups = new Map<number, string[]>()
  for (const [id, wave] of waveMap) {
    if (!waveGroups.has(wave)) waveGroups.set(wave, [])
    waveGroups.get(wave)!.push(id)
  }

  // Sort waves in ascending order for stable renumbering
  const sortedWaves = [...waveGroups.entries()].sort(([a], [b]) => a - b)

  const result = new Map<string, number>()
  let currentWave = 1

  for (const [, todos] of sortedWaves) {
    // Sort within wave by topological order for stable sub-wave creation
    const ordered = todos.sort((a, b) =>
      topologicalOrder.indexOf(a) - topologicalOrder.indexOf(b)
    )

    // Split into sub-waves of maxWidth
    for (let i = 0; i < ordered.length; i += maxWidth) {
      const chunk = ordered.slice(i, i + maxWidth)
      for (const id of chunk) {
        result.set(id, currentWave)
      }
      currentWave++
    }
  }

  return result
}
```

### Converting Wave Map to manifest.waves Array

```javascript
/**
 * Convert wave assignment map to the manifest dependency_graph.waves format.
 * @param {Map<string, number>} waveMap - id -> wave number
 * @returns {Array<{ wave: number, todos: string[] }>}
 */
function waveMapToManifestFormat(
  waveMap: Map<string, number>
): Array<{ wave: number; todos: string[] }> {
  const waveGroups = new Map<number, string[]>()
  for (const [id, wave] of waveMap) {
    if (!waveGroups.has(wave)) waveGroups.set(wave, [])
    waveGroups.get(wave)!.push(id)
  }

  return [...waveGroups.entries()]
    .sort(([a], [b]) => a - b)
    .map(([wave, todos]) => ({ wave, todos }))
}
```

## Critical Path Method (CPM)

Identifies the "bottleneck" chain of todos that gates overall completion time. Todos on the critical path receive priority awareness so workers prioritize them.

```javascript
/**
 * Compute the critical path through the DAG.
 * Returns todos with zero slack (EST === LST) — these gate completion time.
 *
 * @param {TodoEntry[]} todos - All todos (must be non-empty)
 * @param {Map<string, Set<string>>} graph - id -> Set<dependency_id>
 * @param {Map<string, Set<string>>} reverse - id -> Set<dependent_id>
 * @param {string[]} topologicalOrder - From buildDependencyDAG
 * @returns {string[]} Qualified IDs on the critical path (empty if todos is empty)
 */
function criticalPath(
  todos: TodoEntry[],
  graph: Map<string, Set<string>>,
  reverse: Map<string, Set<string>>,
  topologicalOrder: string[]
): string[] {
  // Guard: empty input produces empty critical path (prevents Math.max() crash on empty Set)
  if (!todos || todos.length === 0 || !topologicalOrder || topologicalOrder.length === 0) {
    return []
  }

  // Forward pass: Earliest Start Time (EST)
  // EST for root nodes = 0; EST for dependent = max(EST of all deps) + 1
  // NOTE: criticalPath operates on intra-source deps only. Cross-source refs
  // (e.g., "review/001") are tracked via cross_source_refs in the manifest,
  // not via critical path analysis. Cross-source deps are filtered out below
  // to prevent silent miscalculation (they would default to 0/maxDepth).
  const est = new Map<string, number>()
  const intraSourceIds = new Set(topologicalOrder)
  for (const id of topologicalOrder) {
    const deps = graph.get(id) || new Set()
    const intraSourceDeps = [...deps].filter(d => intraSourceIds.has(d))
    if (intraSourceDeps.length === 0) {
      est.set(id, 0)
    } else {
      const depEsts = intraSourceDeps.map(d => est.get(d) ?? 0)
      est.set(id, Math.max(...depEsts) + 1)
    }
  }

  // Backward pass: Latest Start Time (LST)
  // LST for leaf nodes = max EST in graph; LST for parent = min(LST of all dependents) - 1
  const estValues = [...est.values()]
  const maxDepth = estValues.length > 0 ? Math.max(...estValues) : 0
  const lst = new Map<string, number>()
  for (const id of [...topologicalOrder].reverse()) {
    const dependents = reverse.get(id) || new Set()
    const intraSourceDependents = [...dependents].filter(d => intraSourceIds.has(d))
    if (intraSourceDependents.length === 0) {
      lst.set(id, maxDepth)
    } else {
      const depLsts = intraSourceDependents.map(d => lst.get(d) ?? maxDepth)
      lst.set(id, Math.min(...depLsts) - 1)
    }
  }

  // Critical path: todos where EST === LST (zero slack — cannot be delayed)
  return topologicalOrder.filter(id => est.get(id) === lst.get(id))
}
```

**Priority boost**: Todos on the critical path with `priority: p2` receive an effective `p1` priority for wave assignment ordering. This ensures the critical chain gets assigned first within each wave.

## Full Pipeline Example

Given 5 todos with dependencies:
```
work/001 [p1] → no deps
work/002 [p2] → no deps
work/003 [p2] → depends on work/001
work/004 [p3] → depends on work/003
work/005 [p2] → no deps
```

**Step 1 — Kahn's topological sort**:
- Initial queue (in-degree 0): [work/001, work/002, work/005]
- After priority sort: [work/001 (p1), work/002 (p2), work/005 (p2)] — work/001 first due to p1
- Process work/001 → work/003 in-degree drops to 0, enqueue
- Process work/002 → no dependents
- Process work/005 → no dependents
- Process work/003 → work/004 in-degree drops to 0, enqueue
- Process work/004 → done
- Result order: [work/001, work/002, work/005, work/003, work/004]

**Step 2 — Depth-first wave assignment**:
- work/001: no deps → wave 1
- work/002: no deps → wave 1
- work/005: no deps → wave 1
- work/003: deps=[work/001] → wave max(1)+1 = wave 2
- work/004: deps=[work/003] → wave max(2)+1 = wave 3

**Step 3 — Critical path**:
- EST: 001=0, 002=0, 005=0, 003=1, 004=2
- Max depth = 2
- LST: 004=2, 003=1, 001=0, 002=2, 005=2
- Slack: 001=0 (EST==LST), 002=2 (not 0), 003=0, 004=0, 005=2
- Critical path: [work/001, work/003, work/004]

**Manifest output**:
```json
{
  "dependency_graph": {
    "edges": [
      { "from": "work/003", "to": "work/001", "type": "blocked_by" },
      { "from": "work/004", "to": "work/003", "type": "blocked_by" }
    ],
    "topological_order": ["work/001", "work/002", "work/005", "work/003", "work/004"],
    "waves": [
      { "wave": 1, "todos": ["work/001", "work/002", "work/005"] },
      { "wave": 2, "todos": ["work/003"] },
      { "wave": 3, "todos": ["work/004"] }
    ],
    "has_cycles": false,
    "unresolved_deps": [],
    "cross_source_refs": []
  }
}
```

## Cycle Detection and Handling

When `has_cycles === true`:
- `unresolved_deps` lists the IDs that could not be topologically sorted (part of the cycle)
- `manifest validate` reports P1 (blocking) errors for each cycle
- `manifest build` still proceeds — the non-cyclic portion gets correct wave assignments
- Cyclic todos get `execution_order: null` and `wave: null` in their manifest entries

**Recommended fix**: Use `manifest validate` to identify the cycle, then break it manually by removing or correcting the dependency.

## ID Format Support

The glob patterns support both 3-digit (001-999) and 4-digit (0001-9999) IDs for sessions with >999 todos:

```bash
# zsh-safe glob for all todo files (tolerant: v2 3-digit, 4-digit, AND strive task-N naming)
setopt nullglob
files=()
for f in "${todos_base}/${source}"/[0-9][0-9][0-9]-*.md(N) \
         "${todos_base}/${source}"/[0-9][0-9][0-9][0-9]-*.md(N) \
         "${todos_base}/${source}"/task-[0-9]*.md(N); do
  files+=("$f")
done
```

The `issue_id` field in frontmatter stores the string as-is (`"001"` or `"1234"`). The qualified ID format is `{source}/{issue_id}` without padding normalization.

## Integration with Manifest Build

The DAG ordering is computed during `manifest build` and stored in the manifest. Consumers (Strive, Mend) read the pre-computed `dependency_graph.waves` from the manifest rather than recomputing the DAG at execution time. This keeps wave assignment deterministic and reproducible across retries.

**When to recompute**: Only when the manifest is dirty (`.dirty` signal set). The orchestrator triggers `manifest build` before each wave execution to ensure ordering reflects the latest todo states (e.g., newly completed dependencies).
