# Parse Plan — strive Phase 0 Reference

Task extraction and parsing from plan files.

## Find Plan

If no plan specified:
```bash
ls -t plans/*.md 2>/dev/null | head -5
```

If multiple found, ask user which to execute. If none found, suggest `/rune:devise` first.

## Validate Plan Path

```javascript
// Validate plan path before any Read or display
if (!/^[a-zA-Z0-9._\/-]+$/.test(planPath) || planPath.includes('..')) {
  throw new Error(`Invalid plan path: ${planPath}`)
}
```

## Extract Tasks

Read the plan and extract implementation tasks:

1. Look for checkbox items (`- [ ]`), numbered lists, or "Tasks" sections
2. Identify dependencies between tasks (Phase ordering, explicit "depends on" references)
3. Classify each task:
   - **Implementation task**: Writing code (assigned to rune-smith)
   - **Test task**: Writing tests (assigned to trial-forger)
   - **Independent**: Can run in parallel
   - **Sequential**: Must wait for dependencies

```javascript
tasks = [
  { subject: "Write User model", type: "impl", blockedBy: [] },
  { subject: "Write User model tests", type: "test", blockedBy: [] },
  { subject: "Write UserService", type: "impl", blockedBy: ["#1"] },
  { subject: "Write UserService tests", type: "test", blockedBy: ["#3"] },
  { subject: "Write API routes", type: "impl", blockedBy: ["#3"] },
  { subject: "Write API route tests", type: "test", blockedBy: ["#5"] },
]
```

## Previous Shard Context (Multi-Shard Plans Only)

When the plan is a shard (filename matches `*-shard-N-*`), inject context from completed sibling shards into worker prompts.

**Inputs**: planPath (string), dirname/basename (stdlib path utilities)
**Outputs**: shardContext (string, injected into worker prompts in Phase 2)
**Preconditions**: Plan file exists and matches shard naming pattern (`-shard-\d+-`)
**Error handling**: Read(sibling) failure -> skip sibling, log warning, continue with remaining shards

```javascript
const shardMatch = planPath.match(/-shard-(\d+)-/)
if (shardMatch) {
  const shardNum = parseInt(shardMatch[1])
  const planDir = dirname(planPath)
  const planBase = basename(planPath).replace(/-shard-\d+-[^-]+-plan\.md$/, '')

  const siblingShards = Glob(`${planDir}/${planBase}-shard-*-plan.md`)
    .filter(p => {
      const n = parseInt(p.match(/-shard-(\d+)-/)?.[1] ?? "0")
      return n < shardNum
    })
    .sort()

  let shardContext = ""
  for (const sibling of siblingShards) {
    const content = Read(sibling)
    const checked = content.match(/- \[x\].+/g) || []
    const techMatch = content.match(/## Technical Approach\n([\s\S]{0,500})/)
    shardContext += `\n### Shard: ${basename(sibling)}\nCompleted: ${checked.length} criteria\n`
    if (techMatch) shardContext += `Patterns: ${techMatch[1].trim().slice(0, 300)}\n`
  }
  // shardContext is injected into worker spawn prompts (Phase 2) as:
  // "PREVIOUS SHARD CONTEXT:\n{shardContext}\nReuse patterns from earlier shards."
}
```

## Child Plan Context Injection (Hierarchical Plans)

When a plan is a child plan (has `parent` and `sequence` in frontmatter), inject completed sibling context into worker prompts. This gives workers awareness of what prior children produced so they can reuse artifacts and avoid duplication.

**Inputs**: frontmatter (object, parsed from plan YAML), tasks (Task[], extracted from plan), workerContext (string, mutable — passed to Phase 2 worker spawn prompts)
**Outputs**: workerContext (string, enriched with sibling artifacts and prerequisites)
**Preconditions**: `frontmatter.parent` is a valid relative path (validated inline below); parent plan file exists
**Error handling**: Read(parentPlan) failure → log warning, skip context injection; parseExecutionTable failure → skip context injection; missing `requires`/`provides` → treat as empty arrays

```javascript
// Detect child plan via frontmatter discriminator
const isChildPlan = !!(frontmatter.parent && frontmatter.sequence)

if (isChildPlan) {
  // Validate parent path (path traversal guard)
  if (!/^[a-zA-Z0-9._\/-]+$/.test(frontmatter.parent) || frontmatter.parent.includes('..')) {
    warn("Child plan: invalid parent path — skipping sibling context injection")
  } else {
    let parentContent = null
    try {
      parentContent = Read(frontmatter.parent)
    } catch (e) {
      warn(`Child plan: could not read parent plan at "${frontmatter.parent}" — skipping context injection`)
    }

    if (parentContent) {
      // Parse execution table from parent plan to find completed siblings
      // BACK-014: This regex assumes Markdown link format: | N | [name](path) | status | ... |
      // The hierarchy-parser.md uses plain text format. This function only handles strive's table format.
      const executionTableRows = []
      const tableRegex = /\|\s*(\d+)\s*\|\s*\[([^\]]+)\]\(([^)]+)\)\s*\|\s*(\w[\w-]*)\s*\|/g
      for (const match of parentContent.matchAll(tableRegex)) {
        executionTableRows.push({
          sequence: parseInt(match[1]),
          name: match[2],
          path: match[3],
          status: match[4]   // pending | in-progress | completed | partial | failed | skipped
        })
      }

      const mySequence = parseInt(frontmatter.sequence)
      const completedSiblings = executionTableRows.filter(row =>
        row.sequence < mySequence && row.status === 'completed'
      )

      // Collect provides from completed siblings (what artifacts are available)
      const availableArtifacts = []
      for (const sibling of completedSiblings) {
        if (!/^[a-zA-Z0-9._\/-]+$/.test(sibling.path) || sibling.path.includes('..')) continue
        try {
          const siblingContent = Read(sibling.path)
          // Parse "## Provides" section from sibling frontmatter
          const providesMatch = siblingContent.match(/^provides:\n([\s\S]*?)(?=^\w|\n---)/m)
          if (providesMatch) {
            for (const line of providesMatch[1].split('\n')) {
              const m = line.match(/\s*-\s*type:\s*(\w+)/)
              const n = line.match(/\s*name:\s*"([^"]+)"/)
              if (m && n) availableArtifacts.push({ type: m[1], name: n[1], from: sibling.name })
            }
          }
        } catch (e) {
          // Non-blocking: skip sibling if unreadable
          warn(`Child plan: could not read sibling "${sibling.path}" — skipping its provides`)
        }
      }

      // Extract requires from this child's frontmatter
      const prerequisites = Array.isArray(frontmatter.requires) ? frontmatter.requires : []

      // Identify self-heal tasks (prepended with [SELF-HEAL] marker)
      // Self-heal tasks fix prerequisite failures discovered at runtime
      const selfHealTasks = tasks.filter(t =>
        typeof t.subject === 'string' && t.subject.startsWith('[SELF-HEAL]')
      )

      // Build enriched worker context string
      // This is injected into each worker's spawn prompt in Phase 2
      let childWorkerContext = `\n## Hierarchical Plan — Child Context\n`
      childWorkerContext += `This is child ${mySequence} of a hierarchical parent plan.\n`
      childWorkerContext += `Parent plan: ${frontmatter.parent}\n\n`

      if (completedSiblings.length > 0) {
        childWorkerContext += `### Completed Siblings (${completedSiblings.length})\n`
        for (const s of completedSiblings) {
          childWorkerContext += `- Child ${s.sequence}: ${s.name} — status: ${s.status}\n`
        }
        childWorkerContext += '\n'
      } else {
        childWorkerContext += `### Completed Siblings\nNo prior siblings completed — this is the first child.\n\n`
      }

      if (availableArtifacts.length > 0) {
        // DOC-3: Inline comment explaining artifact injection logic
        // Available artifacts = provides from ALL completed prior siblings.
        // Workers should import/use these rather than re-implementing them.
        childWorkerContext += `### Available Artifacts (from completed siblings)\n`
        childWorkerContext += `The following artifacts were produced by prior children and are available to use:\n`
        for (const a of availableArtifacts) {
          childWorkerContext += `- **${a.type}**: \`${a.name}\` (from: ${a.from})\n`
        }
        childWorkerContext += `\nDo NOT re-implement these — import or reference them directly.\n\n`
      }

      if (prerequisites.length > 0) {
        childWorkerContext += `### Prerequisites (this child requires)\n`
        childWorkerContext += `These artifacts MUST exist before this child's tasks run.\n`
        for (const r of prerequisites) {
          const satisfied = availableArtifacts.some(a => a.type === r.type && a.name === r.name)
          childWorkerContext += `- **${r.type}**: \`${r.name}\` — ${satisfied ? 'AVAILABLE' : 'MISSING (check prior siblings)'}\n`
        }
        childWorkerContext += '\n'

        // Prerequisite verification — warn if required artifacts are missing
        const missingPrereqs = prerequisites.filter(r =>
          !availableArtifacts.some(a => a.type === r.type && a.name === r.name)
        )
        if (missingPrereqs.length > 0) {
          const missingList = missingPrereqs.map(r => `${r.type}:${r.name}`).join(', ')
          warn(`Child plan: ${missingPrereqs.length} prerequisite(s) missing: ${missingList}`)
          warn(`Child plan: missing prerequisites may indicate a prior sibling failed or was skipped.`)
          warn(`Child plan: resolve via talisman work.hierarchy.missing_prerequisite strategy (pause | self-heal | backtrack)`)
        }
      }

      if (selfHealTasks.length > 0) {
        childWorkerContext += `### Self-Heal Tasks (elevated priority)\n`
        childWorkerContext += `These tasks repair prerequisite failures from prior siblings. Complete them FIRST:\n`
        for (const t of selfHealTasks) {
          childWorkerContext += `- ${t.subject}\n`
        }
        childWorkerContext += '\n'
      }

      // Append to workerContext (prepended to all worker spawn prompts in Phase 2)
      workerContext = childWorkerContext + (workerContext || '')
    }
  }
}
```

## Task Coverage Assertion (v1.169.0 — CRITICAL)

After extracting tasks, verify that ALL plan tasks are covered. This gate prevents the "silent deferral" problem where the LLM orchestrator self-selects only "easy" tasks and drops the rest without telling anyone.

**Why this exists**: PR #310 shipped with 40% plan completion because the LLM extracted only 5 of 18 plan tasks, deferring 13 as "too risky" or "depends on later phases". No mechanism detected the gap. This assertion ensures every plan task becomes a work item.

```javascript
// STEP A: Extract plan task headings (### Task X.Y:) — ground truth from plan
const planContent = Read(planPath)
const planTaskPattern = /^###\s+Task\s+(\d+\.\d+):?\s*(.+)/gm
const planTaskHeadings = []
let ptMatch
while ((ptMatch = planTaskPattern.exec(planContent)) !== null) {
  planTaskHeadings.push({ id: ptMatch[1], title: ptMatch[2].trim() })
}

// STEP B: Compare against extracted work tasks
const extractedTaskCount = extractedTasks.length
const planTaskCount = planTaskHeadings.length

if (planTaskCount > 0 && extractedTaskCount < planTaskCount) {
  const missingCount = planTaskCount - extractedTaskCount
  const coverageRatio = extractedTaskCount / planTaskCount

  // FLAW-001 FIX: Match per-task instead of join(" ") + includes() to avoid
  // cross-task substring false positives. Each plan task must match against
  // individual extracted tasks, not the concatenated blob.
  const missingPlanTasks = planTaskHeadings.filter(pt => {
    // Check each extracted task individually
    return !extractedTasks.some(et => {
      const etText = (et.subject + " " + (et.description || "")).toLowerCase()
      // Match 1: Plan task ID appears as word boundary in extracted task
      const idRegex = new RegExp(`\\b${pt.id.replace(/\./g, '\\.')}\\b`)
      const idFound = idRegex.test(etText)
      // Match 2: Majority of title words (length > 2, excluding stopwords) found in same task
      const stopwords = new Set(['the', 'and', 'for', 'with', 'from', 'into', 'that', 'this'])
      const titleWords = pt.title.toLowerCase().split(/\s+/)
        .filter(w => w.length > 2 && !stopwords.has(w))
      const matchCount = titleWords.filter(w => etText.includes(w)).length
      const titleFound = titleWords.length > 0 && matchCount >= Math.ceil(titleWords.length * 0.5)
      return idFound || titleFound
    })
  })

  // readTalismanSection: "work"
  const workConfig = readTalismanSection("work")
  const taskCoverageFloor = Math.max(50, Math.min(100,
    workConfig?.task_coverage_floor ?? 100))  // Default: 100%

  const coveragePct = Math.round(coverageRatio * 100)

  if (coveragePct < taskCoverageFloor) {
    // HARD STOP — cannot proceed with missing tasks
    const missingList = missingPlanTasks.slice(0, 15).map(t =>
      `  - Task ${t.id}: ${t.title}`
    ).join('\n')

    error(
      `TASK COVERAGE ASSERTION FAILED: Plan has ${planTaskCount} tasks but ` +
      `strive only extracted ${extractedTaskCount} (${coveragePct}%).\n\n` +
      `Missing tasks:\n${missingList}\n\n` +
      `All plan tasks MUST become work items. Options:\n` +
      `1. Re-extract: ensure every ### Task heading produces a work item\n` +
      `2. Split large tasks: break oversized tasks into sub-tasks\n` +
      `3. Serialize dependencies: use blockedBy instead of skipping\n` +
      `4. Lower floor: set work.task_coverage_floor in talisman (range: 50-100, default: 100)\n\n` +
      `This check prevents shipping incomplete implementations (PR #310 incident).`
    )
  } else if (missingPlanTasks.length > 0) {
    // Below 100% but above floor — warn but proceed
    warn(
      `Task coverage: ${extractedTaskCount}/${planTaskCount} plan tasks extracted (${coveragePct}%). ` +
      `${missingPlanTasks.length} plan task(s) not found in work items: ` +
      missingPlanTasks.map(t => `Task ${t.id}`).join(', ')
    )
  }
}

// STEP C: Auto-create missing tasks (when plan tasks have ### Task headings)
// For any plan task NOT represented in extractedTasks, create a work item automatically.
// This ensures no plan task is silently dropped.
// FLAW-003 FIX: Track auto-created plan IDs to avoid duplicates from stale extractedTasks
const autoCreatedPlanIds = new Set()
if (planTaskCount > 0) {
  for (const pt of planTaskHeadings) {
    if (autoCreatedPlanIds.has(pt.id)) continue

    // FLAW-001 FIX: Per-task matching (same logic as STEP B)
    const stopwords = new Set(['the', 'and', 'for', 'with', 'from', 'into', 'that', 'this'])
    const alreadyExtracted = extractedTasks.some(et => {
      const etText = (et.subject + " " + (et.description || "")).toLowerCase()
      const idRegex = new RegExp(`\\b${pt.id.replace(/\./g, '\\.')}\\b`)
      const idFound = idRegex.test(etText)
      const titleWords = pt.title.toLowerCase().split(/\s+/)
        .filter(w => w.length > 2 && !stopwords.has(w))
      const matchCount = titleWords.filter(w => etText.includes(w)).length
      const titleFound = titleWords.length > 0 && matchCount >= Math.ceil(titleWords.length * 0.5)
      return idFound || titleFound
    })

    if (!alreadyExtracted) {
      // Extract task section from plan for context
      const taskSectionPattern = new RegExp(
        `### Task ${pt.id.replace('.', '\\.')}[:\\s][\\s\\S]*?(?=###|##[^#]|$)`
      )
      const sectionMatch = planContent.match(taskSectionPattern)
      const taskDescription = sectionMatch
        ? sectionMatch[0].slice(0, 2000)
        : pt.title

      // Extract effort from task section
      const effortMatch = (sectionMatch?.[0] || "").match(/\*\*Effort\*\*:\s*(\w+)/i)
      const effort = effortMatch ? effortMatch[1] : "M"

      // Extract dependencies from task section
      const depMatch = (sectionMatch?.[0] || "").match(/\*\*Depend\w*\*\*:\s*(.+)/i)
      const blockedBy = depMatch
        ? (depMatch[1].match(/Task\s+(\d+\.\d+)/g) || []).map(d => d.replace('Task ', ''))
        : []

      // FLAW-007 FIX: Classify type based on title keywords
      const taskType = /\btest/i.test(pt.title) ? "test" : "impl"

      extractedTasks.push({
        subject: `Task ${pt.id}: ${pt.title}`,
        description: taskDescription,
        type: taskType,
        blockedBy: blockedBy,
        effort: effort,
        autoCreated: true  // Flag for logging
      })

      autoCreatedPlanIds.add(pt.id)
      log(`Auto-created work item for plan Task ${pt.id}: ${pt.title} (type: ${taskType})`)
    }
  }
}
```

**Key design decisions**:
- **Default floor: 100%** — every plan task MUST become a work item. No silent deferrals.
- **Auto-create missing tasks**: Rather than just failing, strive auto-creates work items from plan `### Task` sections. This converts the error into a recovery.
- **Dependencies preserved**: `blockedBy` is extracted from `**Dependency**:` lines in plan task sections. Workers serialize naturally instead of skipping.
- **Configurable floor**: `work.task_coverage_floor` in talisman (50-100). Lower values are escape hatches for intentionally phased plans.

## Identify Ambiguities

After extracting tasks, scan for potential issues before asking the user to confirm:

1. **Vague task descriptions**: Tasks with no file references, no acceptance criteria, or generic verbs ("improve", "update", "handle")
2. **Missing dependencies**: Tasks that reference components not covered by other tasks
3. **Unclear scope**: Tasks where the plan says "etc." or "and similar"
4. **Conflicting instructions**: Tasks where the plan gives contradictory guidance

If ambiguities found (>= 1):
```javascript
AskUserQuestion({
  questions: [{
    question: `Found ${count} ambiguities in the plan:\n${ambiguityList}\n\nClarify now or proceed as-is?`,
    header: "Clarify",
    options: [
      { label: "Clarify now (Recommended)", description: "Answer questions before workers start" },
      { label: "Proceed as-is", description: "Workers will interpret ambiguities on their own" }
    ],
    multiSelect: false
  }]
})
```

If user chooses to clarify: ask specific questions one at a time (max 3), then append clarifications to task descriptions before creating the task pool. Default on timeout: "Proceed as-is" (fail-safe).

## Risk Tier Classification

After extracting tasks, classify each task's risk tier using the deterministic decision tree from `risk-tiers.md`. This MUST happen before task creation.

```javascript
// SYNC: risk-tier-paths — update file regex below AND risk-tiers.md File-Path Fallback Heuristic table.
// Description keywords are intentionally broader than the decision tree (conservative over-classification).
function classifyRiskTier(task) {
  const desc = (task.subject + " " + task.description).toLowerCase()
  const files = task.fileTargets || []

  // Q1: Auth/security/encryption/credentials?
  // Conservative: over-classifies to higher tier. Manual override via plan metadata if needed.
  // NOTE: "token" is intentionally broad — it over-matches pagination tokens, lexer tokens, etc.
  // This is acceptable: conservative over-classification is safer than missing a secret token.
  if (/\b(auth|security|encrypt|credential|secret|token|password|oauth|jwt)\b/.test(desc)
      || files.some(f => /(auth|security|crypto|credentials|session|token|keys|secrets|signing)/.test(f))) {
    return { tier: 3, name: "Elden" }
  }
  // Q2: DB schemas/migrations/CI-CD/infrastructure?
  // Conservative: over-classifies to higher tier. Manual override via plan metadata if needed.
  if (/\b(migrat|schema|deploy|ci[\/-]cd|infrastructure|database|pipeline)\b/.test(desc)
      || files.some(f => /(migrations|deploy|\.github|infra)/.test(f))) {
    return { tier: 2, name: "Rune" }
  }
  // Q3: User-facing behavior (API/UI/validation/errors)?
  // NOTE: "request" and "response" are known broad matches (conservative over-classification).
  // Internal HTTP utility code may be classified as Tier 1 — acceptable for safety.
  if (/\b(api|route|endpoint|component|view|ui|validation|response|request)\b/.test(desc)
      || files.some(f => /(api|routes|components|views)/.test(f))) {
    return { tier: 1, name: "Ember" }
  }
  // Q4: Internal only (rename/comments/formatting/tests/docs)?
  if (/\b(test|doc|comment|format|rename|refactor|lint|readme|changelog)\b/.test(desc)
      || files.some(f => /(tests|docs|__mocks__)/.test(f) || /\.md$/.test(f))) {
    return { tier: 0, name: "Grace" }
  }
  // Default: Tier 1 (caution)
  return { tier: 1, name: "Ember" }
}
```

## File Target Extraction

Extract file paths mentioned in task descriptions to enable ownership conflict detection:

```javascript
function extractFileTargets(task) {
  const desc = task.subject + " " + (task.description || "")
  // Match file-like patterns: src/foo/bar.ts, path/to/file.py, etc.
  const filePattern = /(?:^|\s)([\w./-]+\.\w{1,10})\b/g
  const dirPattern = /(?:^|\s)([\w./-]+\/)\b/g
  const files = new Set()
  for (const match of desc.matchAll(filePattern)) {
    const path = match[1]
    if (path.includes('/') && !path.startsWith('http')) files.add(path)
  }
  // Post-match filter: remove false positives that look like file paths but aren't
  // (a) version strings like "v2.0", "1.2.3", (b) abbreviations like "e.g.", "i.e.", "etc.",
  // (c) URLs that slipped through the http check
  const falsePositiveFilter = (p) =>
    /^v?\d+\.\d+/.test(p) ||                     // version strings
    /^(e\.g|i\.e|etc|vs|ca|approx)\./i.test(p) || // common abbreviations
    /^https?:/.test(p) ||                          // URLs
    /\.\./.test(p) ||                              // path traversal (..) — reject any path with parent refs
    /(^|\/)(\.env|credentials|secrets|\.ssh|\.gnupg|\.aws\/credentials)(\b|$)/.test(p) // SEC-005: reject sensitive/hidden file paths
  for (const f of files) {
    if (falsePositiveFilter(f)) files.delete(f)
  }
  // Directory-level ownership as fallback
  const dirs = new Set()
  for (const match of desc.matchAll(dirPattern)) {
    const dir = match[1]
    // Apply same false-positive filter as files (path traversal, versions, URLs)
    if (falsePositiveFilter(dir)) continue
    // Require at least one internal path separator to avoid mid-line false matches
    // like "CI/CD" -> "CI/" or "input/output" -> "input/"
    if (dir.split('/').filter(Boolean).length < 2) continue
    dirs.add(dir)
  }
  return { files: [...files], dirs: [...dirs] }
}
```

For tasks with no extractable file targets, no ownership restriction is applied (treated as shared).

## Write task_ownership to inscription.json (SEC-STRIVE-001)

After extracting tasks and file targets, write `task_ownership` to `inscription.json` for runtime enforcement by the `validate-strive-worker-paths.sh` PreToolUse hook. This MUST happen in Phase 1 after task extraction and before worker spawning.

```javascript
// Build task_ownership from extracted file targets
const taskOwnership = {}
for (const task of tasks) {
  const { files, dirs } = extractFileTargets(task)
  if (files.length > 0 || dirs.length > 0) {
    taskOwnership[`task-${task.id}`] = {
      owner: "unassigned",  // Updated when worker claims task
      files: files,
      dirs: dirs
    }
  }
  // Tasks with no targets are omitted — treated as unrestricted by the hook
}

// Write to inscription.json (extends existing inscription written in Phase 1)
// The task_ownership key is NEW — older inscription formats lack it.
// The hook checks for task_ownership presence and fails open if missing.
const inscriptionPath = `tmp/.rune-signals/rune-work-${timestamp}/inscription.json`
const inscription = JSON.parse(Read(inscriptionPath))
inscription.task_ownership = taskOwnership
Write(inscriptionPath, JSON.stringify(inscription, null, 2))
```

**Key design decisions**:
- `task_ownership` is a NEW key (not an extension of existing format)
- Tasks with no extractable file targets are omitted from `task_ownership` (unrestricted)
- The hook uses a flat union of all entries — worker-A can write to worker-B's files, but files outside ALL tasks are blocked
- `owner` field is set to `"unassigned"` initially; can be updated when workers claim tasks (future enhancement)
- Talisman `work.unrestricted_shared_files` array supplements the allowlist at hook evaluation time (not stored in inscription)

## Frontend Task Classification

After risk tier classification, classify each task as frontend or backend to enable conditional design context injection. This runs unconditionally (lightweight check) but only affects downstream behavior when design_sync is enabled.

```javascript
// SYNC: frontend-task-patterns — update patterns below AND design-sync/references/phase2-design-implementation.md
const FRONTEND_FILE_PATTERN = /\.(tsx|jsx|css|scss|sass|less|svelte|vue|styled\.\w+)$/
const FRONTEND_KEYWORD_PATTERN = /\b(component|ui|layout|style|render|view|page|screen|modal|dialog|button|form|input|dropdown|sidebar|navbar|header|footer|card|grid|flex|responsive|breakpoint|theme|design.?token|figma|css|tailwind|styled|animation|transition)\b/i

function classifyFrontendTask(task) {
  const files = task.fileTargets || []
  const desc = (task.subject + " " + (task.description || "")).toLowerCase()

  // Strategy 1: File extension match (high confidence)
  const hasFeFiles = files.some(f => FRONTEND_FILE_PATTERN.test(f))

  // Strategy 2: Directory-based heuristic (medium confidence)
  const feDirs = files.some(f =>
    /(components|views|pages|screens|layouts|ui|styles|public|assets|app\/.*\/(page|layout|loading|error))/.test(f)
  )

  // Strategy 3: Keyword match in description (low confidence, tiebreaker)
  const hasFeKeywords = FRONTEND_KEYWORD_PATTERN.test(desc)

  // Frontend if ANY file-based signal, OR strong keyword signal without contradicting files
  const isFrontend = hasFeFiles || feDirs || (hasFeKeywords && files.length === 0)
  return { isFrontend }
}

// Apply to all extracted tasks
for (const task of tasks) {
  const { isFrontend } = classifyFrontendTask(task)
  task.isFrontend = isFrontend
}
```

## Design Context Detection (conditional)

After frontend classification, detect design signals from the plan. Triple-gated: `design_sync.enabled` + frontend task signals + design artifact presence. Zero cost when any gate is closed.

**Inputs**: frontmatter (object, parsed from plan YAML), tasks (Task[], with `isFrontend` flag), talisman (object), designContext (from `discoverDesignContext()` in SKILL.md Phase 1)
**Outputs**: `has_design_context` (boolean) per task, `design_artifacts` (object) per task
**Preconditions**: Tasks extracted, classified (impl/test), frontend-tagged, talisman loaded
**Error handling**: Glob failure → treat as no artifacts; Read failure on VSM/DCD → skip artifact, log warning

```javascript
// Gate 1: design_sync.enabled in talisman
const designSyncEnabled = talisman?.design_sync?.enabled === true

if (designSyncEnabled) {
  // Gate 2: Any frontend tasks exist?
  const hasFrontendTasks = tasks.some(t => t.isFrontend)

  if (hasFrontendTasks) {
    // Gate 3: Design artifacts discovered? (passed from discoverDesignContext() in SKILL.md)
    // designContext = { strategy, designPackagePath?, vsmFiles?, dcdFiles?, figmaUrl? }
    const hasArtifacts = designContext && designContext.strategy !== 'none'

    for (const task of tasks) {
      // Only frontend tasks get design context
      task.has_design_context = task.isFrontend && hasArtifacts

      if (task.has_design_context) {
        task.design_artifacts = {
          vsm_path: designContext.vsmFiles?.[0],
          dcd_path: designContext.dcdFiles?.[0],
          design_package_path: designContext.designPackagePath,
          figma_url: designContext.figmaUrl
        }
      }
    }
  } else {
    // No frontend tasks — skip annotation (zero overhead)
    for (const task of tasks) {
      task.has_design_context = false
    }
  }
} else {
  // design_sync disabled — no annotation (zero overhead)
  for (const task of tasks) {
    task.has_design_context = false
  }
}
```

## Confirm with User

Present extracted tasks with risk tiers and ask for confirmation:

```
Extracted {N} tasks from plan:

Implementation:
  1. [Tier 0: Grace] Write User model — src/models/
  3. [Tier 1: Ember] Write UserService (depends on #1) — src/services/user.ts
  5. [Tier 1: Ember] Write API routes (depends on #3) — src/api/users.ts

Tests:
  2. [Tier 0: Grace] Write User model tests — tests/
  4. [Tier 0: Grace] Write UserService tests (depends on #3) — tests/
  6. [Tier 0: Grace] Write API route tests (depends on #5) — tests/

Proceed with {N} tasks and {W} workers?
```
