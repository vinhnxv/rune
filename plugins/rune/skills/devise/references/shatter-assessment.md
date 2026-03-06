# Phase 2.5: Shatter Assessment

Skipped when `--quick` is passed. After synthesis produces a plan, assesses its complexity. If the plan is large enough to benefit from decomposition, offers to "shatter" it into smaller sub-plans (shards). Each shard is then forged and implemented independently.

**Inputs**: `planPath` (string), `planContent` (string), `planDir` (string, dirname of planPath), `timestamp` (string), `talisman` (config object)
**Outputs**: Shard files (`plans/YYYY-MM-DD-{type}-{name}-shard-N-{phase-name}-plan.md`) or child plans (`{planDir}/children/`), `tmp/plans/{timestamp}/coherence-check.md`
**Preconditions**: Phase 2 synthesize completed, plan file exists at `planPath`

## Complexity Scoring

| Signal | Weight | Threshold |
|--------|--------|-----------|
| Task count | 40% | >= 8 tasks |
| Phase count | 30% | >= 3 phases |
| Cross-cutting concerns | 20% | >= 2 shared dependencies |
| Estimated effort (sum of S/M/L) | 10% | >= 2 L-size phases |

Complexity score >= 0.65: Offer shatter. Score < 0.65: Skip, proceed to forge.

**Codex cross-model scoring** (optional): When Codex available, blends Claude + Codex scores (default weight: 0.3). Controlled via `talisman.codex.shatter.enabled`.

## Shatter Decision

When complexity >= 0.65, AskUserQuestion with three options:

```javascript
AskUserQuestion({
  questions: [{
    question: "This plan is complex (score: ${complexityScore.toFixed(2)}). How would you like to proceed?",
    header: "Plan Decomposition",
    options: [
      {
        label: "Shatter (Recommended)",
        description: "Split into independent shard files executed separately. Best for parallel or loosely coupled work."
      },
      {
        label: "Hierarchical (parent + children)",
        description: "Decompose into parent plan with child sub-plans. Each child gets its own arc run with dependency DAG, requires/provides contracts, and feature branch per child (e.g., feature/{id}/child-N-{phase-slug})."
      },
      {
        label: "Keep as one plan",
        description: "Proceed without decomposition. Best for tightly coupled work that must stay together."
      },
      {
        label: "Let me choose sections",
        description: "Select which sections to split and which to keep together."
      }
    ],
    multiSelect: false
  }]
})
```

## Shard Generation

When "Shatter" is selected:

1. Identify natural boundaries (implementation phases)
2. Create shard files: `plans/YYYY-MM-DD-{type}-{name}-shard-N-{phase-name}-plan.md`
3. Each shard: shared context section, specific phase tasks and acceptance criteria, dependencies on other shards
4. Parent plan updated with shard index and cross-shard dependency graph

After forge, `/rune:strive` can target individual shards independently.

## Hierarchical Plan Generation

When "Hierarchical (parent + children)" is selected:

### Phase 2.5A — Auto-generate requires/provides from task analysis

```javascript
// Analyze plan content for file references, imports, API routes, exported types
function extractContracts(planContent) {
  const contracts = { requires: [], provides: [] }

  // Detect file references (e.g., "src/models/User.ts")
  for (const match of planContent.matchAll(/`([^`]+\.\w{1,10})`/g)) {
    const fp = match[1]
    if (fp.includes('/') && !fp.includes('..')) {
      contracts.provides.push({ type: "file", name: fp })
    }
  }

  // Detect exported type/function references (e.g., "export interface UserDTO")
  for (const match of planContent.matchAll(/\bexport\s+(?:interface|type|class|function|const)\s+(\w+)/g)) {
    contracts.provides.push({ type: "export", name: match[1] })
  }

  // Detect API route references (e.g., "GET /api/users", "POST /auth/login")
  for (const match of planContent.matchAll(/\b(GET|POST|PUT|DELETE|PATCH)\s+(\/[\w/{}:]+)/g)) {
    contracts.provides.push({ type: "endpoint", name: `${match[1]} ${match[2]}` })
  }

  // Detect import dependencies (e.g., "depends on UserService")
  for (const match of planContent.matchAll(/\b(?:depends on|requires|imports?)\s+["`]?(\w[\w/.-]+)["`]?/gi)) {
    contracts.requires.push({ type: "file", name: match[1] })
  }

  return contracts
}
```

### Phase 2.5B — Create children/ directory and generate child plans

```javascript
const childrenDir = `${planDir}/children`
Bash(`mkdir -p "${childrenDir}"`)

// Identify natural boundaries — each phase or major section becomes a child
const phases = extractImplementationPhases(planContent)
// phases: [{ name: "Foundation", tasks: [...], effort: "M" }, ...]

const childPlans = []
let prevChildPath = null

for (let i = 0; i < phases.length; i++) {
  const phase = phases[i]
  const childFileName = `${basename(planPath).replace('-plan.md', '')}-child-${i + 1}-${slugify(phase.name)}-plan.md`
  const childPath = `${childrenDir}/${childFileName}`

  // Determine depends_on from sequential ordering (each child depends on previous)
  // For parallel phases (same-level non-sequential tasks), depends_on = []
  const dependsOn = phase.canRunParallel ? [] : (prevChildPath ? [prevChildPath] : [])

  // Extract contracts from this phase's content
  const phaseContracts = extractContracts(phase.content)

  // Build requires from prior sibling provides
  const priorProvides = childPlans.flatMap(c => c.provides)
  const myRequires = phaseContracts.requires.filter(r =>
    priorProvides.some(p => p.type === r.type && p.name === r.name)
  )

  const childFrontmatter = `---
title: "${planFrontmatter.type}: ${phase.name} (child ${i + 1}/${phases.length})"
type: ${planFrontmatter.type}
date: ${today}
parent: "${planPath}"
sequence: ${i + 1}
depends_on: ${JSON.stringify(dependsOn)}
requires:
${myRequires.map(r => `  - type: ${r.type}\n    name: "${r.name}"`).join('\n')}
provides:
${phaseContracts.provides.map(p => `  - type: ${p.type}\n    name: "${p.name}"`).join('\n')}
status: pending
branch_suffix: "child-${i + 1}-${slugify(phase.name)}"
---`

  const childContent = `${childFrontmatter}

# ${phase.name} (Child ${i + 1} of ${phases.length})

> Part of hierarchical plan: [${basename(planPath)}](${planPath})

## Overview

${phase.description || `Implementation of ${phase.name} phase.`}

## Tasks

${phase.tasks.map(t => `- [ ] ${t}`).join('\n')}

## Acceptance Criteria

${phase.criteria.map(c => `- [ ] ${c}`).join('\n')}

## Requires (from prior children)

${myRequires.length > 0
    ? myRequires.map(r => `- **${r.type}**: \`${r.name}\``).join('\n')
    : '*(No prerequisites — this child can start immediately)*'}

## Provides (for subsequent children)

${phaseContracts.provides.map(p => `- **${p.type}**: \`${p.name}\``).join('\n')}

## References

- Parent plan: ${planPath}
`

  Write(childPath, childContent)
  childPlans.push({ path: childPath, name: phase.name, provides: phaseContracts.provides, requires: myRequires, dependsOn })
  prevChildPath = childPath
}
```

### Phase 2.5C — Update parent plan with execution table and DAG

```javascript
// Build execution table for parent plan
const executionTable = `## Child Execution Table

| # | Child Plan | Status | Depends On | Branch |
|---|-----------|--------|------------|--------|
${childPlans.map((c, i) =>
  `| ${i + 1} | [${c.name}](${c.path}) | pending | ${c.dependsOn.length > 0 ? c.dependsOn.map(d => basename(d)).join(', ') : '—'} | feature/{id}/child-${i + 1} |`
).join('\n')}

## Dependency Contract Matrix

| Child | Requires | Provides |
|-------|---------|---------|
${childPlans.map(c =>
  `| ${c.name} | ${c.requires.map(r => `${r.type}:${r.name}`).join(', ') || '—'} | ${c.provides.map(p => `${p.type}:${p.name}`).join(', ') || '—'} |`
).join('\n')}
`

// Inject into parent plan before "## References"
const parentContent = Read(planPath)
Edit(planPath, {
  old_string: "## References",
  new_string: `${executionTable}\n## References`
})

// Also update parent frontmatter to mark it as hierarchical
const newFrontmatter = parentContent.replace(
  /^(---\n[\s\S]*?\n)---/,
  `$1children_dir: "${childrenDir}"\nhierarchical: true\n---`
)
Write(planPath, newFrontmatter)
```

### Phase 2.5D — Cross-child coherence check

```javascript
// Validate: all children exist, no circular deps, task coverage
const coherenceFindings = []
const childPaths = new Set(childPlans.map(c => c.path))

// Check 1: All depends_on reference known children
for (const child of childPlans) {
  for (const dep of child.dependsOn) {
    if (!childPaths.has(dep)) {
      coherenceFindings.push(`MISSING_DEP: ${child.name} depends on unknown child: ${dep}`)
    }
  }
}

// Check 2: No circular dependencies (topological sort)
function hasCycle(nodes) {
  const visited = new Set()
  const inStack = new Set()
  function dfs(node) {
    visited.add(node)
    inStack.add(node)
    const deps = childPlans.find(c => c.path === node)?.dependsOn || []
    for (const dep of deps) {
      if (!visited.has(dep) && dfs(dep)) return true
      if (inStack.has(dep)) return true
    }
    inStack.delete(node)
    return false
  }
  return nodes.some(n => !visited.has(n) && dfs(n))
}
if (hasCycle(childPlans.map(c => c.path))) {
  coherenceFindings.push("CIRCULAR_DEP: Cycle detected in child dependency graph — halt generation")
}

// Check 3: Contract deduplication (same provides across children = conflict)
const allProvides = childPlans.flatMap(c => c.provides.map(p => ({ ...p, child: c.name })))
const seen = new Map()
for (const p of allProvides) {
  const key = `${p.type}:${p.name}`
  if (seen.has(key)) {
    coherenceFindings.push(`DUPLICATE_PROVIDES: Both ${seen.get(key)} and ${p.child} provide ${key}`)
  }
  seen.set(key, p.child)
}

// Check 4: All parent plan acceptance criteria covered by at least one child
const parentCriteria = extractAcceptanceCriteria(parentContent)
const childCriteria = childPlans.flatMap(c => extractAcceptanceCriteria(Read(c.path)))
for (const criterion of parentCriteria) {
  const covered = childCriteria.some(cc => cc.includes(criterion.slice(0, 40)))
  if (!covered) {
    coherenceFindings.push(`UNCOVERED_CRITERION: "${criterion.slice(0, 60)}..." not present in any child plan`)
  }
}

// Write coherence check output
const coherencePath = `tmp/plans/${timestamp}/coherence-check.md`
Bash(`mkdir -p "tmp/plans/${timestamp}"`)
Write(coherencePath, `# Coherence Check — ${today}\n\n${coherenceFindings.length === 0
  ? "All checks passed. No issues found."
  : coherenceFindings.map(f => `- [ ] ${f}`).join('\n')}\n`)

if (coherenceFindings.some(f => f.startsWith("CIRCULAR_DEP"))) {
  throw new Error("Hierarchical plan generation halted: circular dependency detected. See " + coherencePath)
}

if (coherenceFindings.length > 0) {
  warn(`Phase 2.5: ${coherenceFindings.length} coherence issue(s) found. Review ${coherencePath} before running arc-hierarchy.`)
}
```

### Post-Generation AskUserQuestion

```javascript
AskUserQuestion({
  questions: [{
    question: `Generated ${childPlans.length} child plans in ${childrenDir}/\n\nCoherence check: ${coherenceFindings.length === 0 ? "PASSED" : `${coherenceFindings.length} issues (see ${coherencePath})`}\n\nWhat would you like to do next?`,
    header: "Hierarchical Plan Ready",
    options: [
      { label: "Execute with /rune:arc-hierarchy", description: `Orchestrate all ${childPlans.length} children in dependency order` },
      { label: "Review child plans first", description: "Open parent plan and review the execution table" },
      { label: "Forge each child plan", description: "Run /rune:forge on each child to enrich with research" }
    ],
    multiSelect: false
  }]
})
```
