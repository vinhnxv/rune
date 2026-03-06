# Phase 5.4: Todo Generation from TOME

**MANDATORY — DO NOT SKIP.** Generate per-finding todo files from TOME. This phase MUST execute after Phase 5.2 and before Phase 6.

```javascript
// Resolve todosDir (arc-aware) — reuses workflowOutputDir from Phase 2
const source = scope === "full" ? "audit" : "review"
let todosOutputDir = outputDir
const arcCkpts = Glob(".claude/arc/*/checkpoint.json")
for (const ckpt of arcCkpts) {
  try {
    const c = JSON.parse(Read(ckpt))
    if (c.phases?.code_review?.status === "in_progress" && c.todos_base) {
      todosOutputDir = c.todos_base.replace(/todos\/?$/, '')
      break
    }
  } catch {}
}
const todosDir = `${todosOutputDir.replace(/\/?$/, '/')}todos/${source}/`
Bash(`mkdir -p "${todosDir}"`)

// Extract findings from TOME (marker-based)
const tomeContent = Read(`${outputDir}TOME.md`)
const findingPattern = /<!-- RUNE:FINDING.*?id="([^"]+)".*?severity="([^"]+)".*?-->/g
const findings = []
let match
while ((match = findingPattern.exec(tomeContent)) !== null) {
  findings.push({ id: match[1], severity: match[2], position: match.index })
}

// Filter non-actionable (questions, nits)
const actionable = findings.filter(f =>
  !f.id.includes('-Q') && f.severity !== 'nit'
)

// Write per-finding todo files
let todoCount = 0
for (const finding of actionable) {
  todoCount++
  const priority = finding.severity === 'P1' ? 'p1' : finding.severity === 'P2' ? 'p2' : 'p3'
  const filename = `${String(todoCount).padStart(3, '0')}-pending-${priority}-${finding.id.toLowerCase()}.md`
  Write(`${todosDir}${filename}`, [
    '---',
    `finding_id: "${finding.id}"`,
    `status: pending`,
    `priority: ${priority}`,
    `source: ${source}`,
    `source_ref: "${outputDir}TOME.md"`,
    `created_at: "${new Date().toISOString()}"`,
    '---'
  ].join('\n'))
}
// Log count for verification
warn(`Phase 5.4: created ${todoCount} todo files from ${findings.length} findings (${actionable.length} actionable)`)
```

## Verification (REQUIRED)

Check before proceeding to Phase 6:

1. `todosDir` exists and contains `[0-9][0-9][0-9]-*.md` files (or log "0 actionable findings")
2. `todos_base` recorded in state file

If verification fails (todosDir empty despite TOME having findings), re-execute the inline code block above as recovery. See [todo-generation.md](todo-generation.md) for the full 3-layer extraction reference (retained for documentation).
