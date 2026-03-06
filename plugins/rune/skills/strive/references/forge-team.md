# Phase 1: Forge Team — Inline Implementation

Detailed implementation code for Phase 1 of `/rune:strive`. Called after plan parsing (Phase 0)
and environment setup (Phase 0.5).

## Team Creation

```javascript
// Pre-create guard: teamTransition protocol (see team-sdk/references/engines.md)
// STEP 1: Validate (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid work identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected in work identifier')

// STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
// STEP 3: Filesystem fallback (only when STEP 2 failed)
// STEP 4: TeamCreate with "Already leading" catch-and-recover
// STEP 5: Post-create verification

// Create signal directory for event-driven sync
const signalDir = `tmp/.rune-signals/rune-work-${timestamp}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(extractedTasks.length))
Write(`${signalDir}/inscription.json`, JSON.stringify({
  workflow: "rune-work",
  timestamp: timestamp,
  output_dir: `tmp/work/${timestamp}/`,
  teammates: [
    { name: "rune-smith", output_file: "work-summary.md" },
    { name: "trial-forger", output_file: "work-summary.md" }
  ]
}))

// Create output directories (worker-logs replaces todos/ for per-worker session logs)
Bash(`mkdir -p "tmp/work/${timestamp}/patches" "tmp/work/${timestamp}/proposals" "tmp/work/${timestamp}/worker-logs"`)
```

## Per-Task File-Todos (Mandatory)

```javascript
// Per-task file-todos: always created (mandatory, session-scoped)
// See file-todos/references/integration-guide.md for resolveTodosBase() contract
const workflowOutputDir = `tmp/work/${timestamp}/`

// Arc context detection: when running inside arc, redirect todos to arc's directory
// so all phases (work, review, mend) share a single todos_base at tmp/arc/{id}/todos/
// Detection: check for active arc checkpoint with work phase in_progress
let todosOutputDir = workflowOutputDir  // default: "tmp/work/{timestamp}/"
const arcCheckpoints = Glob(".claude/arc/*/checkpoint.json")
for (const ckpt of arcCheckpoints) {
  try {
    const c = JSON.parse(Read(ckpt))
    if (c.phases?.work?.status === "in_progress" && c.todos_base) {
      // Extract arc output dir from todos_base: "tmp/arc/{id}/todos/" → "tmp/arc/{id}/"
      todosOutputDir = c.todos_base.replace(/todos\/?$/, '')
      break
    }
  } catch {}
}
const todosBase = resolveTodosBase(todosOutputDir)   // arc: "tmp/arc/{id}/todos/", standalone: "tmp/work/{timestamp}/todos/"
const todosDir = resolveTodosDir(todosOutputDir, "work")  // arc: "tmp/arc/{id}/todos/work/", standalone: "tmp/work/{timestamp}/todos/work/"
Bash(`mkdir -p "${todosDir}"`)

// --- Per-task file-todo creation (inline, mandatory) ---
const today = new Date().toISOString().slice(0, 10)
for (const task of extractedTasks) {
  const priority = task.risk_tier === 'critical' ? 'p1' : task.risk_tier === 'high' ? 'p2' : 'p3'
  const slug = task.subject.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
  const filename = `task-${task.id}-${slug}.md`
  Write(`${todosDir}${filename}`, [
    '---',
    `id: task-${task.id}-${slug}`,
    `title: "${task.subject}"`,
    `status: ready`,
    `priority: ${priority}`,
    `source: work`,
    `task_id: "${task.id}"`,
    `files:`, ...(task.fileTargets?.map(f => `  - ${f}`) || []),
    `created_at: "${new Date().toISOString()}"`,
    '---', '',
    `## Task`, '', task.description || task.subject, '',
    `## Checklist`, '', '- [ ] Implementation', '- [ ] Verification',
  ].join('\n'))
}
```

## Complexity-Aware Task Ordering

```javascript
// --- Complexity-aware task ordering (sort before wave computation) ---
// Gate: readTalismanSection("work")?.complexity_ordering?.enabled !== false
//
// Scoring is additive: Score = (fileCount × wFile) + (wTest if test task) + (wRefactor if refactor keyword)
//                             + (wLargeScope if fileCount > 5)
// Tasks are sorted descending by score so highest-complexity tasks start first.
// Score is a relative ranking, not a time estimate — use estimateTaskMinutes() for time budgeting.
// Default weights (overridable via talisman complexity_ordering.weights):
//   wFile=2: cost per touched file — more files → more risk of conflicts
//   wTest=3: test tasks are slightly harder (require understanding existing coverage)
//   wRefactor=5: refactors touch structural patterns and carry high regression risk
//   wLargeScope=3: bonus for >5 files — coordination overhead grows super-linearly
// Used in both scoreTaskComplexity() and estimateTaskMinutes()
const REFACTOR_KEYWORDS = ["refactor", "restructure", "extract", "migrate", "rename", "reorganize"]

const complexityConfig = readTalismanSection("work")?.complexity_ordering
if (complexityConfig?.enabled !== false) {
  const weights = complexityConfig?.weights ?? {}
  const wFile = weights.file_count ?? 2
  const wTest = weights.test ?? 3
  const wRefactor = weights.refactor ?? 5
  const wLargeScope = weights.large_scope ?? 3

  function scoreTaskComplexity(task) {
    const fileCount = (task.fileTargets?.length ?? 0) + (task.dirTargets?.length ?? 0)
    if (fileCount === 0 && !task.subject && !task.description) return 0  // missing metadata → 0

    let estimate = fileCount * wFile
    if (task.type === "test") estimate += wTest
    const text = `${task.subject ?? ''} ${task.description ?? ''}`.toLowerCase()
    if (REFACTOR_KEYWORDS.some(kw => text.includes(kw))) estimate += wRefactor
    if (fileCount > 5) estimate += wLargeScope
    return estimate
  }

  // Score and sort descending (highest complexity first)
  for (const task of extractedTasks) {
    task._complexityScore = scoreTaskComplexity(task)
    log(`COMPLEXITY-SCORE: task #${task.id} "${task.subject}" → ${task._complexityScore}`)
  }
  extractedTasks.sort((a, b) => b._complexityScore - a._complexityScore)
}
```

## Task Time Estimation

```javascript
// --- Task time estimation (stored in metadata for Phase 3 reassignment) ---
function estimateTaskMinutes(task) {
  const fileCount = (task.fileTargets?.length ?? 0) + (task.dirTargets?.length ?? 0)
  let estimate = fileCount <= 2 ? 5 : fileCount <= 5 ? 10 : 15
  if (task.type === "test") estimate = 8
  const text = `${task.subject ?? ''} ${task.description ?? ''}`.toLowerCase()
  if (REFACTOR_KEYWORDS.some(kw => text.includes(kw))) estimate = Math.min(20, Math.round(estimate * 1.5))
  return estimate
}
for (const task of extractedTasks) {
  task.metadata = task.metadata ?? {}
  task.metadata.estimated_minutes = estimateTaskMinutes(task)
}
```

## Wave Configuration and State File

```javascript
// Wave-based execution: bounded batches with fresh worker context
const TODOS_PER_WORKER = talisman?.work?.todos_per_worker ?? 3
const totalTodos = extractedTasks.length
const maxWorkers = talisman?.work?.max_workers ?? 3
const waveCapacity = maxWorkers * TODOS_PER_WORKER  // e.g. 3 workers * 3 = 9
const totalWaves = Math.ceil(totalTodos / waveCapacity)

// Compute total worker count (scaling logic in worker-prompts.md)
const workerCount = smithCount + forgerCount

// Write state file with session identity for cross-session isolation
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write("tmp/.rune-work-{timestamp}.json", {
  team_name: "rune-work-{timestamp}",
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}",
  plan: planPath,
  expected_workers: workerCount,
  total_waves: totalWaves,
  todos_per_worker: TODOS_PER_WORKER,
  todos_base: todosBase,  // session-scoped todos base for resume support
  ...(worktreeMode && { worktree_mode: true, waves: [], current_wave: 0, merged_branches: [] })
})
```
