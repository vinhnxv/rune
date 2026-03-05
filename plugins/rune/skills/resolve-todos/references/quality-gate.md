# Quality Gate — Phase 5

Quality check configuration and talisman integration.

## Quality Commands

Read from talisman configuration:

```javascript
const qualityCommands = readTalismanSection("gates")?.quality_commands ?? []

// Default quality checks (if no talisman config)
if (qualityCommands.length === 0) {
  // Auto-detect from project
  if ((Glob("package.json") ?? []).length > 0) {
    qualityCommands.push("npm run lint --if-present")
    qualityCommands.push("npm run typecheck --if-present")
  }
  if ((Glob("pyproject.toml") ?? []).length > 0) {
    qualityCommands.push("python -m ruff check . --fix")
  }
}
```

## Execution

```javascript
let qualityPassed = true
const results = []

for (const cmd of qualityCommands) {
  const result = Bash(cmd, { timeout: 120000 })
  results.push({
    command: cmd,
    passed: result.exitCode === 0,
    output: result.stderr || result.stdout
  })
  if (result.exitCode !== 0) {
    qualityPassed = false
    warn(`Quality check failed: ${cmd}`)
  }
}

// Write results (path prefix matches all other phases: resolve-todos-)
Write(`tmp/resolve-todos-${timestamp}/quality-results.json`, JSON.stringify(results))
```

## Failure Handling

```javascript
if (!qualityPassed) {
  const answer = AskUserQuestion({
    question: "Quality gate failed. What would you like to do?",
    options: [
      { label: "Fix quality issues and continue", value: "fix" },
      { label: "Commit anyway (with warning)", value: "commit_anyway" },
      { label: "Abort (revert all changes)", value: "abort" }
    ]
  })

  if (answer === "abort") {
    // Revert ONLY files modified by fixer agents (not ALL uncommitted changes).
    // Fixer reports list the files they modified — use those for targeted revert.
    const fixFiles = Glob(`tmp/resolve-todos-${timestamp}/fixes/*.json`) ?? []
    const modifiedFiles = new Set()
    for (const ff of fixFiles) {
      const data = JSON.parse(Read(ff))
      for (const f of data.fixes ?? []) {
        if (f.status === "FIXED") modifiedFiles.add(f.file)
      }
    }
    if (modifiedFiles.size > 0) {
      const fileList = [...modifiedFiles].map(f => `"${f}"`).join(' ')
      Bash(`git checkout -- ${fileList}`)
    }
    log(`Reverted ${modifiedFiles.size} file(s) modified by fixers.`)
    return
  }

  if (answer === "fix") {
    // Create quality fix tasks and spawn workers
  }
}
```

## Talisman Configuration

```yaml
# .claude/talisman.yml
gates:
  quality_commands:
    - "npm run lint"
    - "npm run typecheck"
    - "npm run test -- --passWithNoTests"
```

## Single Execution Guarantee

Quality gate runs **once** after ALL fixers complete:

```javascript
// Wait for all fixers to complete
await allFixersComplete

// Run quality gate once
const qualityResult = runQualityGate()
```