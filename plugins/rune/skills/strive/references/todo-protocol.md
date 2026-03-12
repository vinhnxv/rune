# Todo Protocol — Per-Worker Session Logs (v1.43.0+)

All worker spawn prompts MUST include the following TODO FILE PROTOCOL block. Workers create per-worker session log files that persist after work completion for cross-session resume, post-mortem review, and accountability tracking.

## Log File Location

`tmp/work/{timestamp}/worker-logs/{worker-name}.md`

## Required YAML Frontmatter (4 fields only)

```yaml
---
worker: {your-name}
role: implementation | test
status: active
plan_path: {planPath}
---
```

**IMPORTANT**: Workers MUST NOT write counter fields (`tasks_completed`, `subtasks_total`, etc.). All counters are derived by the orchestrator during summary generation at Phase 4.1.

## Worker Protocol (Steps 1–7)

```
TODO FILE PROTOCOL (mandatory):
1. On first task claim: create tmp/work/{timestamp}/worker-logs/{your-name}.md
   with YAML frontmatter:
   ---
   worker: {your-name}
   role: implementation | test
   status: active
   plan_path: {planPath}
   ---
2. Before starting each task: add a "## Task #N: {subject}" section
   with Status: in_progress, Claimed timestamp, and initial subtask checklist
3. As you complete each subtask: update the checkbox to [x]
4. On task completion: add Files touched, Ward Result, Completed timestamp,
   update Status to complete
5. Record key decisions in "### Decisions" subsection — explain WHY, not just WHAT
6. On failure: update Status to failed, add "### Failure reason" subsection
7. On exit (shutdown or idle): update frontmatter status to complete/interrupted

NOTE: Use simplified v1 frontmatter (4 fields only: worker, role, status, plan_path).
All counters (tasks_completed, subtasks_total, etc.) are derived by the orchestrator
during summary generation. Workers MUST NOT write counter fields.
```

**Error handling**: Todo file write failure is non-blocking — warn orchestrator, continue without todo tracking. Worker should not halt work execution due to todo file issues.

## Orchestrator: Summary Generation (Phase 4.1)

After ward check passes and all workers have exited, the orchestrator generates `worker-logs/_summary.md`.

**Inputs**: All `{worker-name}.md` files in `tmp/work/{timestamp}/worker-logs/`
**Outputs**: `tmp/work/{timestamp}/worker-logs/_summary.md`
**Preconditions**: Ward check passed (Phase 4), all workers completed/shutdown
**Error handling**: Missing or unparseable log file → skip that worker in summary (warn). Empty worker-logs dir → skip summary generation entirely (non-blocking).

```javascript
const workerLogsDir = `tmp/work/${timestamp}/worker-logs`
const todoFiles = Glob(`${workerLogsDir}/*.md`).filter(f => !f.endsWith('_summary.md'))

// SEC-002: Validate path containment — reject symlinks or paths outside workerLogsDir
const safeTodoFiles = todoFiles.filter(f => {
  const basename = f.split('/').pop().replace('.md', '')
  return /^[a-zA-Z0-9_-]+$/.test(basename) && f.startsWith(workerLogsDir)
})

if (safeTodoFiles.length === 0) {
  warn("No todo files found — skipping summary generation")
} else {
  const workers = []
  // SEC-001: sanitize worker-controlled values before embedding in markdown/YAML
  const sanitizeCell = (s) => String(s).replace(/\|/g, '\\|').replace(/\n.*/s, '').slice(0, 100)
  for (const todoFile of safeTodoFiles) {
    try {
      const content = Read(todoFile)
      // Parse YAML frontmatter
      const frontmatter = content.match(/^---\n([\s\S]*?)\n---/)
      if (!frontmatter) { warn(`Unparseable frontmatter in ${todoFile} — skipping`); continue }

      // Count checkboxes from markdown body
      const body = content.slice(frontmatter[0].length)
      const completed = (body.match(/- \[x\]/gi) || []).length
      const total = completed + (body.match(/- \[ \]/g) || []).length

      // Extract decisions
      const decisions = []
      const decisionMatches = body.matchAll(/### Decisions\n([\s\S]*?)(?=\n##|\n---|\s*$)/g)
      for (const match of decisionMatches) {
        const items = match[1].match(/^- .+$/gm) || []
        decisions.push(...items.map(d => d.replace(/^- /, '')))
      }

      // Count tasks by status
      const taskSections = body.split(/^## Task #\d+:/m).slice(1)
      const taskStatuses = taskSections.map(s => {
        const statusMatch = s.match(/\*\*Status\*\*:\s*(\w+)/)
        return statusMatch ? statusMatch[1] : 'unknown'
      })

      // Fix any stale "active" status to "interrupted" (FLAW-008 mitigation)
      const statusMatch = frontmatter[1].match(/status:\s*(\w+)/)
      const workerStatus = statusMatch ? statusMatch[1] : 'unknown'
      if (workerStatus === 'active') {
        warn(`Todo file ${todoFile} has status: active after worker exit — fixing to interrupted`)
        Edit(todoFile, { old_string: 'status: active', new_string: 'status: interrupted' })
      }

      workers.push({
        name: basename(todoFile, '.md'),
        role: frontmatter[1].match(/role:\s*(.+)/)?.[1]?.trim() || 'unknown',
        status: workerStatus === 'active' ? 'interrupted' : workerStatus,
        subtasks_completed: completed,
        subtasks_total: total,
        tasks_completed: taskStatuses.filter(s => s === 'completed').length,
        tasks_total: taskSections.length,
        decisions: decisions
      })
    } catch (e) {
      warn(`Failed to parse todo file ${todoFile}: ${e.message} — skipping`)
    }
  }

  if (workers.length > 0) {
    const totalTasks = workers.reduce((s, w) => s + w.tasks_total, 0)
    const completedTasks = workers.reduce((s, w) => s + w.tasks_completed, 0)
    const totalSubtasks = workers.reduce((s, w) => s + w.subtasks_total, 0)
    const completedSubtasks = workers.reduce((s, w) => s + w.subtasks_completed, 0)

    const summary = `---
generated: ${new Date().toISOString()}
plan: ${planPath}
workers: ${workers.length}
total_tasks: ${totalTasks}
completed_tasks: ${completedTasks}
total_subtasks: ${totalSubtasks}
completed_subtasks: ${completedSubtasks}
---

# Work Session Summary

## Progress Overview

| Worker | Role | Tasks | Subtasks | Status |
|--------|------|-------|----------|--------|
${workers.map(w => `| ${sanitizeCell(w.name)} | ${sanitizeCell(w.role)} | ${w.tasks_completed}/${w.tasks_total} | ${w.subtasks_completed}/${w.subtasks_total} | ${sanitizeCell(w.status)} |`).join('\n')}

## Key Decisions (across all workers)

${workers.flatMap(w => w.decisions.map(d => `- **${sanitizeCell(w.name)}**: ${sanitizeCell(d)}`)).join('\n') || '- No decisions recorded'}
`
    Write(`${workerLogsDir}/_summary.md`, summary)
  }
}
```

## PR Integration (Phase 6.5)

If `worker-logs/_summary.md` exists, append a collapsible Work Session section to the PR body:

```markdown
## Work Session

<details>
<summary>{workers} workers completed {completed_tasks}/{total_tasks} tasks ({completed_subtasks}/{total_subtasks} subtasks)</summary>

{contents of worker-logs/_summary.md Progress Overview table}

</details>

### Key Decisions
{3-5 decisions from worker-logs/_summary.md that introduced new dependencies, changed architecture, or deviated from plan}

### Known Issues
{any failed tasks or incomplete subtasks from summary}
```

**Error handling**: Missing summary → fall back to existing PR body generation (non-blocking).


## Phase 6 Safety Net (FLAW-008)

Workers may be killed before updating status. Phase 6 step 3.5 fixes any "active" files to "interrupted":

```javascript
const workerLogsDir = `tmp/work/${timestamp}/worker-logs`
const todoFiles = Glob(`${workerLogsDir}/*.md`).filter(f => !f.endsWith('_summary.md'))
  .filter(f => /^[a-zA-Z0-9_-]+\.md$/.test(f.split('/').pop()) && f.startsWith(workerLogsDir)) // SEC-002
for (const todoFile of todoFiles) {
  try {
    const content = Read(todoFile)
    if (content.includes('status: active')) {
      warn(`Fixing stale todo file: ${todoFile} (active → interrupted)`)
      Edit(todoFile, { old_string: 'status: active', new_string: 'status: interrupted' })
    }
  } catch (e) { /* non-blocking */ }
}
```
