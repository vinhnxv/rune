# Phase 9.5: MERGE — Rebase & Auto Merge

Orchestrator-only phase (no team). Rebases onto main, runs pre-merge checklist, and optionally auto-merges the PR.

**Team**: None (orchestrator-only — runs inline after Phase 9 SHIP)
**Tools**: Bash (git + gh), Read, Write, AskUserQuestion (for HIGH severity issues)
**Timeout**: 10 min (PHASE_TIMEOUTS.merge = 600_000 — includes potential CI wait)

**Inputs**:
- Checkpoint (with `pr_url` from Phase 9, `id`, `plan_file`)
- `arcConfig.ship` (resolved via `resolveArcConfig()`)
- `arcConfig.pre_merge_checks` (talisman toggles for checklist items)

**Outputs**: `tmp/arc/{id}/merge-report.md`

**Consumers**: Completion Report, Completion Stamp

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Check `arcConfig.ship.auto_merge` -- if false, skip phase entirely
2. Verify PR was created in Phase 9 (`checkpoint.pr_url` exists)
3. Verify current branch is not main/master

## Pre-Merge Checklist

Before attempting merge, run a comprehensive pre-merge checklist. Each check is individually toggleable via talisman `arc.pre_merge_checks.*` keys (CHECK-DECREE-001).

```javascript
// Pre-merge checklist -- runs before rebase/merge
// Each check gated by talisman config (default: all enabled)
function runPreMergeChecklist(currentBranch, defaultBranch, arcConfig) {
  const issues = []
  const checks = arcConfig?.pre_merge_checks ?? {}

  // 1. Migration conflict detection (CHECK-DECREE-001: toggleable)
  if (checks.migration_conflict !== false) {
    // Support custom migration paths from talisman (CHECK-DECREE-002)
    // SEC-002 FIX: Validate each migration path against safe glob regex before shell interpolation.
    // Reject entries containing shell metacharacters that could break double-quote quoting.
    const SAFE_GLOB_RE = /^[a-zA-Z0-9._\/*\-]+$/
    const rawGlobs = (Array.isArray(checks.migration_paths) && checks.migration_paths.length > 0)
      ? checks.migration_paths
      : ["**/migrations/**", "**/db/migrate/**", "**/alembic/**", "**/prisma/migrations/**"]
    const migrationGlobs = rawGlobs.filter(g => {
      if (typeof g !== 'string' || !SAFE_GLOB_RE.test(g)) {
        warn(`Pre-merge: Invalid migration_path entry rejected: "${g}"`)
        return false
      }
      return true
    })

    // FIX-2: Guard against empty globs (all entries filtered by SAFE_GLOB_RE)
    if (migrationGlobs.length === 0) {
      warn("Pre-merge: No valid migration paths after filtering — skipping migration conflict check")
    } else {
    const migrationPathArgs = migrationGlobs.map(g => `"${g}"`).join(' ')

    // Check if both main and feature branch have new migration files
    const featureMigrations = Bash(`git diff --name-only "origin/${defaultBranch}"..."${currentBranch}" -- ${migrationPathArgs}`)
      .trim().split('\n').filter(Boolean)

    if (featureMigrations.length > 0) {
      const remoteMigrations = Bash(`git diff --name-only "${currentBranch}"..."origin/${defaultBranch}" -- ${migrationPathArgs}`)
        .trim().split('\n').filter(Boolean)

      if (remoteMigrations.length > 0) {
        // Both branches have new migrations -- potential conflict
        issues.push({
          severity: "HIGH",
          type: "migration_conflict",
          message: `Both branches have new migrations:\n  Feature: ${featureMigrations.join(', ')}\n  Main: ${remoteMigrations.join(', ')}\nCheck for: duplicate timestamps, conflicting schema changes, ordering issues.`
        })
      }

      // Check for duplicate migration numbers/timestamps
      const migrationNumbers = featureMigrations
        .map(f => f.split('/').pop().match(/^(\d+)/)?.[1])
        .filter(Boolean)
      const remoteMigrationNumbers = remoteMigrations
        .map(f => f.split('/').pop().match(/^(\d+)/)?.[1])
        .filter(Boolean)
      const duplicates = migrationNumbers.filter(n => remoteMigrationNumbers.includes(n))
      if (duplicates.length > 0) {
        issues.push({
          severity: "CRITICAL",
          type: "migration_timestamp_conflict",
          message: `Duplicate migration numbers detected: ${duplicates.join(', ')}.\nThis WILL cause database migration failures. Renumber before merge.`
        })
      }
    }
    } // end FIX-2 migrationGlobs guard
  }

  // 2. Schema file conflict detection (CHECK-DECREE-001: toggleable)
  if (checks.schema_conflict !== false) {
    const schemaFiles = Bash(`git diff --name-only "origin/${defaultBranch}"..."${currentBranch}" -- "**/schema.rb" "**/structure.sql" "**/schema.prisma" "**/schema.sql"`)
      .trim().split('\n').filter(Boolean)
    const remoteSchemaChanges = Bash(`git diff --name-only "${currentBranch}"..."origin/${defaultBranch}" -- "**/schema.rb" "**/structure.sql" "**/schema.prisma" "**/schema.sql"`)
      .trim().split('\n').filter(Boolean)

    if (schemaFiles.length > 0 && remoteSchemaChanges.length > 0) {
      issues.push({
        severity: "HIGH",
        type: "schema_conflict",
        message: `Both branches modified schema files: ${schemaFiles.join(', ')}.\nSchema drift detected -- may need manual reconciliation after merge.`
      })
    }
  }

  // 3. Lock file conflicts (CHECK-DECREE-001: toggleable)
  if (checks.lock_file_conflict !== false) {
    const lockFiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Gemfile.lock", "poetry.lock", "Cargo.lock", "go.sum"]
    const lockConflicts = lockFiles.filter(f => {
      const local = Bash(`git diff --name-only "origin/${defaultBranch}"..."${currentBranch}" -- "${f}"`).trim()
      const remote = Bash(`git diff --name-only "${currentBranch}"..."origin/${defaultBranch}" -- "${f}"`).trim()
      return local && remote
    })
    if (lockConflicts.length > 0) {
      issues.push({
        severity: "MEDIUM",
        type: "lock_file_conflict",
        message: `Lock files modified on both branches: ${lockConflicts.join(', ')}.\nRegenerate after rebase to ensure dependency consistency.`
      })
    }
  }

  // 4. Uncommitted changes (CHECK-DECREE-001: toggleable)
  if (checks.uncommitted_changes !== false) {
    const uncommitted = Bash("git status --porcelain").trim()
    if (uncommitted) {
      issues.push({
        severity: "HIGH",
        type: "uncommitted_changes",
        message: "Uncommitted changes detected. Commit or stash before merge."
      })
    }
  }

  return issues
}
```

### Merge Readiness Validation

```javascript
// Validates PR is ready to merge via GitHub API
// Checks: open state, mergeable flag, mergeable_state not blocked
function validateMergeReadiness(owner, repo, prNumber) {
  const prData = JSON.parse(
    Bash(`${GH_ENV} gh api repos/${owner}/${repo}/pulls/${prNumber} --jq '{state,mergeable,mergeable_state}'`).trim()
  )

  if (prData.state !== "open") {
    return { ready: false, reason: `PR is ${prData.state} (expected: open). It may have been closed or already merged.` }
  }

  if (prData.mergeable === false) {
    return { ready: false, reason: "PR has merge conflicts. Rebase or resolve conflicts before merging." }
  }

  if (prData.mergeable_state === "blocked") {
    // Identify which protection rules are blocking
    const checks = JSON.parse(
      Bash(`${GH_ENV} gh api repos/${owner}/${repo}/commits/$(gh pr view ${prNumber} --json headRefOid -q .headRefOid)/check-runs --jq '[.check_runs[] | {name,status,conclusion}]'`).trim() || "[]"
    )
    const failedChecks = checks.filter(c => c.conclusion === "failure" || c.conclusion === "cancelled")
    const pendingChecks = checks.filter(c => c.status !== "completed")
    const blockReasons = []
    if (failedChecks.length > 0) {
      blockReasons.push(`Failed checks: ${failedChecks.map(c => c.name).join(', ')}`)
    }
    if (pendingChecks.length > 0) {
      blockReasons.push(`Pending checks: ${pendingChecks.map(c => c.name).join(', ')}`)
    }
    if (blockReasons.length === 0) {
      blockReasons.push("Branch protection rules are blocking merge (review approvals or other requirements)")
    }
    return { ready: false, reason: `PR is blocked by protection rules:\n  ${blockReasons.join('\n  ')}` }
  }

  return { ready: true, reason: "PR is ready to merge" }
}
```

### Merge Completion Verification

```javascript
// Polls PR state to verify merge actually completed
// For immediate merge: short timeout (60s). For auto-merge: longer (ci_check.timeout_ms).
function verifyMergeCompleted(owner, repo, prNumber, timeoutMs) {
  // BUG FIX (v2.10.8): Use 10s interval for short timeouts (<=60s) to avoid missing merge state.
  // GitHub merge propagation takes 2-5s. With 30s interval + 60s timeout = only 2 polls.
  // With 10s interval + 60s timeout = 6 polls — much more likely to catch the merged state.
  const pollIntervalMs = timeoutMs <= 60_000 ? 10_000 : 30_000
  const maxIterations = Math.ceil(timeoutMs / pollIntervalMs)
  const startTime = Date.now()

  for (let i = 0; i < maxIterations; i++) {
    const prState = JSON.parse(
      Bash(`${GH_ENV} gh api repos/${owner}/${repo}/pulls/${prNumber} --jq '{state,merged,merged_at}'`).trim()
    )

    if (prState.merged === true) {
      return { merged: true, mergedAt: prState.merged_at, reason: "PR merged successfully" }
    }

    if (prState.state === "closed" && !prState.merged) {
      return { merged: false, mergedAt: null, reason: "PR was closed without merging" }
    }

    // PR still open — wait and poll again
    if (i < maxIterations - 1) {
      Bash(`sleep ${pollIntervalMs / 1000}`, { run_in_background: true })
    }
  }

  const elapsedSec = Math.round((Date.now() - startTime) / 1000)
  return { merged: false, mergedAt: null, reason: `Merge not confirmed after ${elapsedSec}s. PR may still be waiting for CI checks.` }
}
```

**Issue severity handling**:
- **CRITICAL** issues --> abort merge immediately, require manual resolution
- **HIGH** issues --> warn user, ask confirmation via AskUserQuestion
- **MEDIUM** issues --> warn in merge report, proceed

## Algorithm

```javascript
updateCheckpoint({ phase: "merge", status: "in_progress", phase_sequence: 9.5, team_name: null })

// ENV: Disable gh interactive prompts in automation (SEC-DECREE-003 / concern C-7)
const GH_ENV = 'GH_PROMPT_DISABLED=1'

// 1. Pre-checks
if (!arcConfig.ship.auto_merge) {
  log("Merge phase skipped -- auto_merge is disabled in config")
  updateCheckpoint({ phase: "merge", status: "skipped" })
  return
}

if (!checkpoint.pr_url) {
  warn("Merge phase: No PR URL found -- PR was not created in Phase 9. Skipping merge.")
  updateCheckpoint({ phase: "merge", status: "skipped" })
  return
}

const currentBranch = Bash("git branch --show-current").trim()
const defaultBranch = Bash("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'").trim()
  || (Bash("git rev-parse --verify origin/main 2>/dev/null").exitCode === 0 ? "main" : "master")

// Validate branch names (security)
const BRANCH_RE = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/
if (!BRANCH_RE.test(currentBranch) || !BRANCH_RE.test(defaultBranch)) {
  warn("Merge phase: Invalid branch name -- skipping")
  updateCheckpoint({ phase: "merge", status: "skipped" })
  return
}

// 2. Fetch latest main
log("Fetching latest code from main branch...")
const fetchResult = Bash(`git fetch origin "${defaultBranch}"`)
if (fetchResult.exitCode !== 0) {
  warn("Merge phase: git fetch failed -- skipping merge")
  updateCheckpoint({ phase: "merge", status: "failed" })
  return
}

// 2.5. Run pre-merge checklist
log("Running pre-merge checklist...")
const checklistIssues = runPreMergeChecklist(currentBranch, defaultBranch, arcConfig)

const criticalIssues = checklistIssues.filter(i => i.severity === "CRITICAL")
const highIssues = checklistIssues.filter(i => i.severity === "HIGH")
const mediumIssues = checklistIssues.filter(i => i.severity === "MEDIUM")

if (criticalIssues.length > 0) {
  warn("Pre-merge checklist: CRITICAL issues found -- aborting merge")
  for (const issue of criticalIssues) {
    warn(`  [${issue.type}] ${issue.message}`)
  }
  const reportContent = `# Merge Report\n\nStatus: BLOCKED\nBranch: ${currentBranch}\nTarget: ${defaultBranch}\nPR: ${checkpoint.pr_url}\n\n## Critical Issues\n${criticalIssues.map(i => `- **${i.type}**: ${i.message}`).join('\n')}\n\nManual resolution required before merge.`
  Write(`tmp/arc/${id}/merge-report.md`, reportContent)
  updateCheckpoint({
    phase: "merge", status: "failed",
    artifact: `tmp/arc/${id}/merge-report.md`,
    artifact_hash: sha256(reportContent)
  })
  return
}

if (highIssues.length > 0) {
  warn("Pre-merge checklist: HIGH severity issues detected:")
  for (const issue of highIssues) {
    warn(`  [${issue.type}] ${issue.message}`)
  }
  // BACK-001 FIX: Capture user response and handle abort path
  const userResponse = AskUserQuestion({
    questions: [{
      question: `Pre-merge found ${highIssues.length} high-severity issue(s). Proceed with merge?`,
      header: "Pre-Merge",
      options: [
        { label: "Proceed anyway", description: "Continue merge despite warnings" },
        { label: "Abort merge", description: "Stop -- resolve issues manually first" }
      ],
      multiSelect: false
    }]
  })
  // FIX-3: Standardize answer check — use includes() pattern consistent with
  // freshness-gate.md (startsWith) and arc-phase-plan-refine.md (includes)
  const userAnswer = typeof userResponse === 'string' ? userResponse : JSON.stringify(userResponse)
  if (!userResponse || userAnswer.includes("Abort")) {
    warn("User chose to abort merge due to HIGH severity pre-merge issues.")
    const abortReport = `# Merge Report\n\nStatus: ABORTED\nReason: User aborted due to ${highIssues.length} HIGH severity issue(s).\n\n## Issues\n${highIssues.map(i => `- **${i.type}**: ${i.message}`).join('\n')}`
    Write(`tmp/arc/${id}/merge-report.md`, abortReport)
    updateCheckpoint({
      phase: "merge", status: "failed",
      artifact: `tmp/arc/${id}/merge-report.md`,
      artifact_hash: sha256(abortReport)
    })
    return
  }
}

if (mediumIssues.length > 0) {
  log(`Pre-merge checklist: ${mediumIssues.length} medium-severity advisory(s) -- proceeding`)
}

// 3. Rebase onto main (conflict check)
if (arcConfig.ship.rebase_before_merge) {
  // BACK-007 FIX: Save pre-rebase SHA for recovery if push fails after rebase
  const preRebaseSha = Bash("git rev-parse HEAD").trim()
  log("Rebasing onto main to check for conflicts...")
  const rebaseResult = Bash(`git rebase "origin/${defaultBranch}"`)

  if (rebaseResult.exitCode !== 0) {
    // Conflicts detected -- abort rebase and warn user
    Bash("git rebase --abort")
    warn(`Merge phase: Rebase conflicts detected with ${defaultBranch}.`)
    warn("Resolve conflicts manually:")
    warn(`  1. git fetch origin ${defaultBranch}`)
    warn(`  2. git rebase origin/${defaultBranch}`)
    warn("  3. Fix conflicts, then: git rebase --continue")
    warn(`  4. git push --force-with-lease origin ${currentBranch}`)
    warn(`  5. Merge PR manually: gh pr merge --squash`)

    const conflictReport = `# Merge Report\n\nStatus: CONFLICT\nBranch: ${currentBranch}\nTarget: ${defaultBranch}\nPR: ${checkpoint.pr_url}\n\nRebase onto ${defaultBranch} failed with conflicts.\nManual resolution required.`
    Write(`tmp/arc/${id}/merge-report.md`, conflictReport)
    updateCheckpoint({
      phase: "merge", status: "failed",
      artifact: `tmp/arc/${id}/merge-report.md`,
      artifact_hash: sha256(conflictReport)
    })
    return
  }

  // Rebase succeeded -- push force-with-lease to update PR
  // Use --force-with-lease (not --force) to prevent overwriting teammate commits
  log("Rebase successful. Pushing updated branch...")
  const pushResult = Bash(`git push --force-with-lease origin -- "${currentBranch}"`)
  if (pushResult.exitCode !== 0) {
    // BUG FIX (v2.10.8): Auto-restore pre-rebase state instead of leaving repo rebased.
    // Without this, --resume would try to rebase already-rebased commits → conflict.
    warn("Merge phase: Force-push after rebase failed. Restoring pre-rebase state...")
    Bash(`git reset --hard ${preRebaseSha}`)
    warn(`Restored to pre-rebase SHA: ${preRebaseSha}`)
    updateCheckpoint({ phase: "merge", status: "failed" })
    return
  }
}

// BACK-005 FIX: Verify gh CLI availability before merge (mirrors Phase 9 ship check)
const ghMergeAvailable = Bash(`${GH_ENV} command -v gh >/dev/null 2>&1 && gh auth status 2>&1 | grep -q 'Logged in' && echo 'ok'`).trim() === "ok"
if (!ghMergeAvailable) {
  warn("Merge phase: gh CLI not available or not authenticated. Skipping merge.")
  warn("Install: https://cli.github.com/ then run: gh auth login")
  updateCheckpoint({ phase: "merge", status: "skipped" })
  return
}

// GH-ACCOUNT-001: Ensure the active gh account has access to this repository.
// Re-resolve account before merge — session may have changed since ship phase.
const ghMergeAccountResolved = Bash(`${GH_ENV} source "\${RUNE_PLUGIN_ROOT}/scripts/lib/gh-account-resolver.sh" && rune_gh_ensure_correct_account`).trim()
if (ghMergeAccountResolved.includes("ERROR: No authenticated GitHub account")) {
  warn("Merge phase: No authenticated GitHub account has access to this repository.")
  warn("Run 'gh auth login' with an account that has access, then retry.")
  updateCheckpoint({ phase: "merge", status: "failed" })
  return
}

// BACK-004 FIX: Verify Phase 9 (SHIP) completed successfully before attempting merge
if (checkpoint.phases.ship?.status !== "completed") {
  warn(`Merge phase: Ship phase status is "${checkpoint.phases.ship?.status}" (expected "completed"). Skipping merge.`)
  updateCheckpoint({ phase: "merge", status: "skipped" })
  return
}

// SEC-003 FIX: Validate pr_url format before use in reports and commands
const PR_URL_RE = /^https:\/\/[a-zA-Z0-9._\/-]+\/pull\/\d+$/
if (!PR_URL_RE.test(checkpoint.pr_url)) {
  warn(`Merge phase: Invalid PR URL format: "${checkpoint.pr_url}". Skipping merge.`)
  updateCheckpoint({ phase: "merge", status: "skipped" })
  return
}

// SEC-004 FIX: Extract PR number from validated URL for explicit gh pr merge target
const prNumber = checkpoint.pr_url.match(/\/pull\/(\d+)$/)?.[1]

// Extract owner/repo from PR URL for API calls (used by readiness check and verification)
const prUrlParts = checkpoint.pr_url.match(/github\.com\/([^/]+)\/([^/]+)\/pull\//)
const owner = prUrlParts?.[1]
const repo = prUrlParts?.[2]

// 3.5. Validate merge readiness before attempting merge
const mergeReadiness = validateMergeReadiness(owner, repo, prNumber)
if (!mergeReadiness.ready) {
  warn(`Merge phase: PR not ready to merge — ${mergeReadiness.reason}`)
  const readinessReport = `# Merge Report\n\nStatus: NOT READY\nBranch: ${currentBranch}\nTarget: ${defaultBranch}\nPR: ${checkpoint.pr_url}\n\n## Merge Readiness Failure\n${mergeReadiness.reason}\n\nResolve the blocking condition, then retry or merge manually.`
  Write(`tmp/arc/${id}/merge-report.md`, readinessReport)
  updateCheckpoint({
    phase: "merge", status: "failed",
    artifact: `tmp/arc/${id}/merge-report.md`,
    artifact_hash: sha256(readinessReport)
  })
  return
}

// 4. Merge PR
// SEC-001 FIX: Validate merge_strategy against allowlist (warns on invalid, defaults to squash)
const MERGE_STRATEGIES = { squash: "--squash", rebase: "--rebase", merge: "--merge" }
const strategy = arcConfig.ship.merge_strategy
if (!MERGE_STRATEGIES[strategy]) {
  warn(`Merge phase: Invalid merge_strategy "${strategy}" -- defaulting to squash`)
}
const strategyFlag = MERGE_STRATEGIES[strategy] ?? "--squash"

let mergeVerification = null

if (arcConfig.ship.wait_ci) {
  // Use --auto: merge when all required checks pass
  // BACK-003 NOTE: --auto enables GitHub's auto-merge. The phase reports "completed" immediately.
  // If CI checks never pass, the PR remains in "auto-merge pending" state indefinitely.
  // The merge report documents this as AUTO-MERGE REQUESTED (not MERGED).
  log("Enabling auto-merge (waiting for CI checks)...")
  const autoResult = Bash(`${GH_ENV} gh pr merge "${prNumber}" ${strategyFlag} --auto`)
  if (autoResult.exitCode !== 0) {
    warn("Merge phase: gh pr merge --auto failed. Check PR status and merge manually.")
    updateCheckpoint({ phase: "merge", status: "failed" })
    return
  }
  log("Auto-merge enabled. Polling for CI completion and merge...")
  const ciTimeout = arcConfig.ci_check?.timeout_ms ?? 900_000  // default 15 min
  mergeVerification = verifyMergeCompleted(owner, repo, prNumber, ciTimeout)
  if (!mergeVerification.merged) {
    log(`Auto-merge verification: ${mergeVerification.reason}`)
  }
} else {
  // Merge immediately without waiting for CI
  log("Merging PR immediately (CI wait disabled)...")
  const mergeResult = Bash(`${GH_ENV} gh pr merge "${prNumber}" ${strategyFlag} --delete-branch`)
  if (mergeResult.exitCode !== 0) {
    warn("Merge phase: Merge failed. Check PR and merge manually: gh pr merge --squash")
    updateCheckpoint({ phase: "merge", status: "failed" })
    return
  }
  log("PR merged. Verifying merge completion...")
  mergeVerification = verifyMergeCompleted(owner, repo, prNumber, 60_000)  // 60s for immediate
  if (!mergeVerification.merged) {
    warn(`Merge verification: ${mergeVerification.reason}`)
  }
}

// 5. Determine final merge status from verification
const mergeStatus = mergeVerification?.merged
  ? "MERGED"
  : arcConfig.ship.wait_ci
    ? "AUTO-MERGE PENDING (CI checks incomplete)"
    : "MERGE UNCONFIRMED"

// 6. Write merge report
const ciStatusSection = checkpoint.ci_status != null ? `
## CI Status
CI Result: ${checkpoint.ci_status.passed ? "PASSED" : "FAILED"}
Fix Attempts: ${checkpoint.ci_status.fix_attempts ?? 0}
${checkpoint.ci_status.fixed_checks?.length > 0 ? `Fixed Checks: ${checkpoint.ci_status.fixed_checks.join(', ')}` : ''}
${checkpoint.ci_status.remaining_failures?.length > 0 ? `Remaining Failures: ${checkpoint.ci_status.remaining_failures.join(', ')}` : ''}
` : ''

const mergeVerificationSection = `
## Merge Verification
Merged: ${mergeVerification?.merged ? 'Yes' : 'No'}
${mergeVerification?.mergedAt ? `Merged At: ${mergeVerification.mergedAt}` : ''}
${mergeVerification?.reason ? `Details: ${mergeVerification.reason}` : ''}
`

const mergeReport = `# Merge Report

Status: ${mergeStatus}
Branch: ${currentBranch}
Target: ${defaultBranch}
Strategy: ${arcConfig.ship.merge_strategy}
PR: ${checkpoint.pr_url}
CI Wait: ${arcConfig.ship.wait_ci}
Rebase: ${arcConfig.ship.rebase_before_merge ? "Yes (clean)" : "Skipped"}

## Pre-Merge Checklist Results
${checklistIssues.length === 0
  ? "All checks passed."
  : checklistIssues.map(i => `- [${i.severity}] **${i.type}**: ${i.message}`).join('\n')
}
${ciStatusSection}${mergeVerificationSection}`

Write(`tmp/arc/${id}/merge-report.md`, mergeReport)
updateCheckpoint({
  phase: "merge", status: "completed",
  artifact: `tmp/arc/${id}/merge-report.md`,
  artifact_hash: sha256(mergeReport),
  phase_sequence: 9.5, team_name: null
})

```

## Error Handling

| Condition | Action |
|-----------|--------|
| `auto_merge` disabled | Phase skipped -- PR remains open for manual merge |
| No PR URL | Phase skipped -- cannot merge without PR |
| git fetch fails | Phase failed -- network/auth issue |
| Pre-merge CRITICAL issue | Phase failed -- abort, write report |
| Pre-merge HIGH issue | AskUserQuestion -- user decides |
| Rebase conflicts | Phase failed -- abort rebase, write conflict report, manual resolution |
| Force-push fails | Phase failed -- someone else pushed to the branch |
| PR not mergeable (blocked/conflicts) | Phase failed -- readiness check writes NOT READY report |
| PR closed without merging | Merge verification detects -- reported in merge report |
| gh pr merge fails | Phase failed -- check PR status manually |
| Merge verification timeout | Phase completes with MERGE UNCONFIRMED or AUTO-MERGE PENDING status |

## Failure Policy

Skip merge, PR remains open. User merges manually via `gh pr merge --squash` or GitHub UI. The merge report at `tmp/arc/{id}/merge-report.md` documents what went wrong.

## Crash Recovery

Orchestrator-only phase with no team -- minimal crash surface.

| Resource | Location |
|----------|----------|
| Merge report | `tmp/arc/{id}/merge-report.md` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "merge") |
| Possible in-progress rebase | `.git/rebase-merge/` or `.git/rebase-apply/` |

Recovery: On `--resume`, if merge phase is `in_progress`:
1. Check for stuck rebase state: `test -d .git/rebase-merge || test -d .git/rebase-apply` -- if found, `git rebase --abort`
2. Re-run from the beginning. Fetch and rebase are safe to re-run.
3. If PR was already merged (check via `gh pr view --json state -q .state`), mark phase completed.
