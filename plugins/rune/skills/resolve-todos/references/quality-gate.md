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
    qualityCommands.push("python -m ruff check .")
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
    // Re-run quality commands to collect specific failures
    const failedCommands = results.filter(r => !r.passed)
    const failureContext = failedCommands.map(r =>
      `Command: ${r.command}\nOutput:\n${r.output?.slice(0, 500)}`
    ).join('\n---\n')

    // Spawn a single fixer agent to address quality issues
    Agent({
      name: `quality-fixer`,
      subagent_type: "rune:utility:mend-fixer",
      team_name: teamName,
      prompt: `Fix the quality gate failures below. Only modify files that were
      changed by the resolve-todos fixers (check tmp/resolve-todos-${timestamp}/fixes/*.json
      for the list of modified files).

      Quality failures:
      ${failureContext}

      After fixing, re-run the failed commands to verify.`,
      run_in_background: true
    })

    // qualityFixerCount tracks agents spawned in quality fix phase (independent of Phase 4 fixers)
    waitForCompletion(teamName, contextTaskCount + totalVerifiersSpawned + totalFixersSpawned + 1, {
      timeoutMs: 180_000,
      pollIntervalMs: 30_000,
      staleWarnMs: 120_000,
      label: "QualityFix"
    })

    // Re-run quality gate after fix attempt
    let fixSucceeded = true
    for (const cmd of failedCommands.map(r => r.command)) {
      const recheck = Bash(cmd, { timeout: 120000 })
      if (recheck.exitCode !== 0) {
        warn(`Quality check still failing after fix attempt: ${cmd}`)
        qualityPassed = false
        fixSucceeded = false
      }
    }

    // If fix attempt failed, re-prompt user (don't silently continue)
    if (!fixSucceeded) {
      const retryAnswer = AskUserQuestion({
        question: "Quality fix attempt failed. Some checks still failing. What would you like to do?",
        options: [
          { label: "Commit anyway (with warning)", value: "commit_anyway" },
          { label: "Abort (revert all changes)", value: "abort" }
        ]
      })
      if (retryAnswer === "abort") {
        // Revert fixer-modified files (same logic as abort branch above)
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
        return
      }
    }
  }
}
```

## Talisman Configuration

```yaml
# .rune/talisman.yml
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