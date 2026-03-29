# Ward Check — Shared Reference

Shared ward gate execution, bisection algorithm, and cross-file deduplication used by `/rune:strive` (Phase 4) and `/rune:mend` (Phase 5).

## Ward Discovery Protocol

Discover project-specific quality gates from build configuration files:

```
1. Makefile      -> targets: check, test, lint, format
2. package.json  -> scripts: test, lint, typecheck, build
3. pyproject.toml -> [tool.ruff], [tool.mypy], [tool.pytest]
4. Cargo.toml    -> cargo test, cargo clippy
5. go.mod        -> go test, go vet
6. .rune/talisman.yml -> ward_commands override
7. Fallback: skip wards, warn user
```

## Ward Gate Execution

```javascript
// Discover wards
wards = discoverWards()

// Security pattern: SAFE_WARD -- see security-patterns.md
const SAFE_WARD = /^[a-zA-Z0-9._\-\/ ]+$/
for (const ward of wards) {
  if (!SAFE_WARD.test(ward.command)) {
    warn(`Ward "${ward.name}": command contains unsafe characters -- skipping`)
    warn(`  Blocked command: ${ward.command.slice(0, 80)}`)
    continue
  }
  result = Bash(ward.command)
  if (result.exitCode !== 0) {
    // Ward failed -- recovery depends on context:
    // - work.md: create fix task, summon worker
    // - mend.md: bisect to identify failing fix
  }
}
```

## Post-Ward Verification Checklist

After ward commands pass, run a deterministic verification pass at zero LLM cost:

```javascript
const checks = []

// 1. All tasks completed
const tasks = TaskList()
const incomplete = tasks.filter(t => t.status !== "completed")
if (incomplete.length > 0) {
  checks.push(`WARN: ${incomplete.length} tasks not completed: ${incomplete.map(t => t.subject).join(", ")}`)
}

// 2. Plan/TOME checkboxes all checked (context-specific)
// work: plan checkboxes
// mend: resolution entries

// 3. No BLOCKED tasks
const blocked = tasks.filter(t => t.status === "pending" && t.blockedBy?.length > 0)
if (blocked.length > 0) {
  checks.push(`WARN: ${blocked.length} tasks still blocked`)
}

// 4. No uncommitted patches (work-specific, skip in mend)

// 5. No merge conflict markers in tracked files
const conflictMarkers = Bash("git diff --check HEAD 2>&1 || true").trim()
if (conflictMarkers !== "") {
  checks.push(`WARN: Merge conflict markers detected in working tree`)
}

// 6. No uncommitted changes in tracked files
const dirtyTracked = (Bash("git diff --name-only HEAD").trim() + "\n" +
                      Bash("git diff --cached --name-only").trim()).trim()
if (dirtyTracked !== "") {
  const fileCount = dirtyTracked.split('\n').filter(Boolean).length
  checks.push(`WARN: Uncommitted changes in tracked files (${fileCount} files)`)
}

// 7. Documentation: new public functions/classes missing docstrings
// Validate defaultBranch before shell interpolation
if (!/^[a-zA-Z0-9._\/-]+$/.test(defaultBranch)) throw new Error("Invalid branch name")
const changedFiles = Bash(`git diff --name-only "${defaultBranch}"...HEAD 2>/dev/null`).trim().split('\n').filter(Boolean)
const codeFiles = changedFiles.filter(f => /\.(py|ts|js|rs|go|rb)$/.test(f))
for (const file of codeFiles) {
  const content = Read(file)
  if (file.endsWith('.py')) {
    const missing = content.match(/^(def|class) (?!_).*:\n(\s*\n)*(?!\s*("""|'''))/gm)
    if (missing && missing.length > 0) {
      checks.push(`WARN: ${file}: ${missing.length} public function(s)/class(es) missing docstrings`)
    }
  }
}

// 8. Import hygiene: unused imports in changed files
const wardIncludesLinter = wards.some(w => /ruff|eslint|flake8|pylint|clippy/.test(w.command))
if (!wardIncludesLinter) {
  checks.push(`INFO: No linter in ward commands -- consider adding ruff/eslint for import hygiene`)
}

// 9. Code duplication: new files that may duplicate existing functionality
const newFiles = Bash(`git diff --name-only --diff-filter=A "${defaultBranch}"...HEAD 2>/dev/null`).trim().split('\n').filter(Boolean)
for (const file of newFiles) {
  const fileBase = file.split('/').pop().replace(/\.(py|ts|js|rs|go|rb)$/, '')
  if (fileBase.length < 4) continue
  const safeBase = fileBase.replace(/[[\]{}*?~]/g, '\\$&')
  const similar = Glob(`**/*${safeBase}*`).filter(f => f !== file)
  if (similar.length > 0) {
    checks.push(`INFO: New file ${file} has similar existing file(s): ${similar.slice(0, 3).join(", ")}`)
  }
}

// readTalismanSection: "plan"
const plan = readTalismanSection("plan")
const customPatterns = plan?.verification_patterns || []
// Security patterns: SAFE_REGEX_PATTERN, SAFE_PATH_PATTERN -- see security-patterns.md
// SEC-FIX: Pattern interpolation uses safeRgMatch() (rg -f) to prevent $() command substitution. See security-patterns.md for safeRgMatch() implementation.
const SAFE_REGEX_PATTERN = /^[a-zA-Z0-9._\-\/ \\|()[\]{}^$+?]+$/
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
for (const pattern of customPatterns) {
  const phases = pattern.phase || ["plan"]
  // Phase filter: work uses "post-work", mend uses "post-mend"
  if (!phases.includes(phaseTag)) continue

  if (!SAFE_REGEX_PATTERN.test(pattern.regex) ||
      !SAFE_PATH_PATTERN.test(pattern.paths) ||
      (pattern.exclusions && !SAFE_PATH_PATTERN.test(pattern.exclusions))) {
    checks.push(`WARN: Skipping verification pattern "${pattern.description}": contains unsafe characters`)
    continue
  }
  const result = safeRgMatch(pattern.regex, pattern.paths, { exclusions: pattern.exclusions, timeout: 5 })
  if (pattern.expect_zero && result.trim().length > 0) {
    checks.push(`WARN: Stale reference: ${pattern.description}`)
  }
}

// 11. Agent frontmatter validation
const agentFiles = Glob("agents/**/*.md").concat(Glob(".claude/agents/**/*.md"))
for (const file of agentFiles) {
  const content = Read(file)
  const frontmatter = extractYamlFrontmatter(content)

  if (!frontmatter) {
    checks.push(`WARN: ${file}: No YAML frontmatter found`)
    continue
  }

  // Required fields
  if (!frontmatter.name) checks.push(`WARN: ${file}: Missing required 'name' field`)
  if (!frontmatter.description) checks.push(`WARN: ${file}: Missing required 'description' field`)

  // Name format validation
  if (frontmatter.name && !/^[a-z][a-z0-9-]*$/.test(frontmatter.name)) {
    checks.push(`WARN: ${file}: name '${frontmatter.name}' must be lowercase-with-hyphens`)
  }

  // Name-filename consistency
  const expectedName = file.split('/').pop().replace('.md', '')
  if (frontmatter.name && frontmatter.name !== expectedName) {
    checks.push(`WARN: ${file}: frontmatter name '${frontmatter.name}' != filename '${expectedName}'`)
  }

  // Tools validation (field name is 'tools' in Rune agents)
  const toolsList = frontmatter.tools || frontmatter['allowed-tools']
  if (toolsList) {
    if (!Array.isArray(toolsList)) {
      checks.push(`WARN: ${file}: 'tools' field must be an array, got ${typeof toolsList}`)
      continue
    }
    const KNOWN_TOOLS = new Set([
      'Read', 'Write', 'Edit', 'MultiEdit', 'Glob', 'Grep', 'Bash',
      'Task', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet',
      'SendMessage', 'TeamCreate', 'TeamDelete', 'AskUserQuestion',
      'EnterPlanMode', 'ExitPlanMode', 'WebFetch', 'WebSearch',
      'NotebookEdit', 'Skill', 'TodoWrite'
    ])
    for (const tool of toolsList) {
      // Skip MCP tools (dynamically registered)
      if (typeof tool === 'string' && tool.startsWith('mcp__')) continue
      if (!KNOWN_TOOLS.has(tool)) {
        checks.push(`WARN: ${file}: unknown tool '${tool}' in tools list`)
      }
    }
  }
}

// 12. Cross-reference integrity for renamed/moved files
// Precondition: defaultBranch validated by /^[a-zA-Z0-9._\/-]+$/ at line 84
const deletedFiles = Bash(`git diff --name-only --diff-filter=D "${defaultBranch}"...HEAD 2>/dev/null`).split('\n').filter(Boolean)
for (const deleted of deletedFiles) {
  const basename = deleted.split('/').pop().replace(/\.[^.]+$/, '')
  if (basename.length < 5) continue  // Skip short names (api, app, lib, cmd) to avoid false positives
  const refs = Grep(basename, { path: ".", glob: "*.{py,ts,js,rs,go,rb,md,yml,yaml,json}" })
  if (refs.length > 0) {
    checks.push(`WARN: Deleted file '${deleted}' still referenced in: ${refs.slice(0, 5).join(', ')}`)
  }
}

// Report -- non-blocking, report to user but do not halt
if (checks.length > 0) {
  warn("Verification warnings:\n" + checks.join("\n"))
}
```

## Bisection Algorithm (on ward failure) -- Worktree Isolation

Bisection uses a git worktree so the user's working tree is unmodified during bisection. All destructive operations happen in a disposable worktree.

```javascript
// PRE-CREATE: Clean stale worktree entries
Bash(`git worktree prune 2>/dev/null`)
Bash(`git worktree remove "tmp/mend/${id}/bisect-worktree" --force 2>/dev/null`)
Bash(`rm -rf "tmp/mend/${id}/bisect-worktree" 2>/dev/null`)

// CREATE: Isolated worktree
const wtResult = Bash(`git worktree add "tmp/mend/${id}/bisect-worktree" HEAD`)
if (wtResult.exitCode !== 0) {
  // FALLBACK: Worktree unavailable (shallow clone, bare repo, etc.)
  warn("Worktree isolation unavailable. Bisection will use pre-mend patches, " +
       "which temporarily reverts ALL local changes (not just mend fixes).")
  const proceed = AskUserQuestion({ questions: [{
    question: "Proceed with patch-based bisection?",
    header: "Fallback",
    options: [
      { label: "Proceed", description: "Use pre-mend.patch to revert and bisect" },
      { label: "Abort", description: "Skip bisection, mark all as NEEDS_REVIEW" }
    ],
    multiSelect: false
  }]})
  if (proceed === "Abort") { markAllNeedsReview(); return }
}

// POST-CREATE: Initialize submodules if present
// Precondition: ${id} validated by /^[a-zA-Z0-9_-]+$/ in mend.md Phase 1
Bash(`cd "tmp/mend/${id}/bisect-worktree" && \
  [ -f .gitmodules ] && git submodule update --init --recursive 2>/dev/null || true`)

// BISECTION: Cumulative strategy (apply fixes incrementally in worktree)
// 1. Apply fix A alone -> run ward -> pass -> keep A
// 2. Apply fix B on top of A -> run ward -> pass -> keep A+B
// 3. Apply fix C on top of A+B -> run ward -> FAILS -> C is culprit in context of A+B
// 4. If interaction effects are non-linear -> NEEDS_REVIEW
// Order: Dedup Hierarchy (SEC -> BACK -> DOC -> QUAL -> FRONT -> CDX)

// Ward execution: Copy each bisection state back to main tree for ward compatibility
// (main tree has node_modules, .venv, vendor -- worktree may not)

// CLEANUP (always runs -- try/finally):
try {
  // ... bisection logic ...
} finally {
  Bash(`git worktree remove "tmp/mend/${id}/bisect-worktree" --force 2>/dev/null`)
  Bash(`rm -rf "tmp/mend/${id}/bisect-worktree" 2>/dev/null`)
  Bash(`git worktree prune 2>/dev/null`)
}
```

**Key safety property**: The user's working tree is unmodified during bisection. All destructive operations happen in the disposable worktree. If bisection crashes, the worktree is simply deleted with no impact on the user's state.

After bisection completes:
1. Re-apply all FIXED fixes to the user's working tree (skip FAILED ones)
2. Stage and present changes for user review

## Cross-File Deduplication

Apply Dedup Hierarchy: `SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > CDX`

If the same file+line has findings from multiple categories, keep only the highest-priority one. Log deduplicated findings for transparency.

## Security Patterns

All ward-related security patterns reference `security-patterns.md`:

| Pattern | Usage |
|---------|-------|
| `SAFE_WARD` | Ward command validation |
| `SAFE_PATH_PATTERN` | File path validation in verification checks |
| `SAFE_REGEX_PATTERN` | Talisman verification pattern validation |
| `FORBIDDEN_KEYS` | JSON field traversal (prototype pollution prevention) |
