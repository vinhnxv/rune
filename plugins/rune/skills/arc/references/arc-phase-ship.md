# Phase 9: SHIP — PR Creation

Orchestrator-only phase (no team). Creates a GitHub PR after test completes.

**Team**: None (orchestrator-only — runs inline after Phase 7.7 TEST)
**Tools**: Bash (git + gh), Read, Write
**Timeout**: 5 min (PHASE_TIMEOUTS.ship = 300_000)

**Inputs**:
- Checkpoint (with `plan_file`, `id`, `phases`, `convergence`)
- `arcConfig.ship` (resolved via `resolveArcConfig()`)
- TOME (`tmp/arc/{id}/tome.md`) — from Phase 6 deep review
- Resolution report (`tmp/arc/{id}/resolution-report.md`) — unfixed findings from convergence

**Outputs**: `tmp/arc/{id}/pr-body.md`, `checkpoint.pr_url`

**Consumers**: Phase 9.5 MERGE (needs `checkpoint.pr_url`), Completion Report, Completion Stamp

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

0. Check `checkpoint.parent_plan.skip_ship_pr` -- if true, skip phase (child arc, parent manages PR)
1. Check `arcConfig.ship.auto_pr` -- if false, skip phase entirely
2. Verify `gh` CLI availability and authentication (`gh auth status`)
3. Set `GH_PROMPT_DISABLED=1` environment variable before ALL `gh` commands (SEC-DECREE-003 / concern C-7) — disables interactive prompts in automation
4. Verify current branch is not main/master (detached HEAD also skipped)
5. Verify there are commits to push (`git rev-list --count`)
6. Validate branch names against `BRANCH_RE`

## Algorithm

```javascript
updateCheckpoint({ phase: "ship", status: "in_progress", phase_sequence: 9, team_name: null })

// ENV: Disable gh interactive prompts in automation (SEC-DECREE-003 / concern C-7)
// Set before ALL gh commands in this phase
const GH_ENV = 'GH_PROMPT_DISABLED=1'

// 0. Child arc guard (v1.79.0+): Skip PR creation when running as child under hierarchy
// The parent arc-hierarchy session manages the single feature PR after all children complete.
// This prevents N spurious PRs (one per child) when running a hierarchical plan.
if (checkpoint?.parent_plan?.skip_ship_pr === true) {
  warn("Ship phase: Skipping PR creation — child arc delegates to parent hierarchy")
  warn(`Parent hierarchy will create the feature PR on branch: ${checkpoint.parent_plan.feature_branch ?? "unknown"}`)
  updateCheckpoint({ phase: "ship", status: "skipped" })
  return
}

// 1. Pre-checks
if (!arcConfig.ship.auto_pr) {
  log("Ship phase skipped -- auto_pr is disabled in config")
  updateCheckpoint({ phase: "ship", status: "skipped" })
  return
}

const ghAvailable = Bash(`${GH_ENV} command -v gh >/dev/null 2>&1 && gh auth status 2>&1 | grep -q 'Logged in' && echo 'ok'`).trim() === "ok"
if (!ghAvailable) {
  warn("Ship phase: gh CLI not available or not authenticated. Skipping PR creation.")
  warn("Install: https://cli.github.com/ -- then run: gh auth login")
  updateCheckpoint({ phase: "ship", status: "skipped" })
  return
}

// GH-ACCOUNT-001: Ensure the active gh account has access to this repository.
// When multiple GitHub accounts are authenticated, the default may lack repo access.
// This resolves the correct account before any gh operation (push, pr create).
const ghAccountResolved = Bash(`${GH_ENV} source "\${CLAUDE_PLUGIN_ROOT}/scripts/lib/gh-account-resolver.sh" && rune_gh_ensure_correct_account`).trim()
if (ghAccountResolved.includes("ERROR: No authenticated GitHub account")) {
  warn("Ship phase: No authenticated GitHub account has access to this repository.")
  warn("Run 'gh auth login' with an account that has access, then retry.")
  updateCheckpoint({ phase: "ship", status: "failed" })
  return
}

const currentBranch = Bash("git branch --show-current").trim()
const defaultBranch = Bash("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'").trim()
  || (Bash("git rev-parse --verify origin/main 2>/dev/null").exitCode === 0 ? "main" : "master")

if (currentBranch === defaultBranch || currentBranch === "") {
  warn("Ship phase: On default branch or detached HEAD -- skipping")
  updateCheckpoint({ phase: "ship", status: "skipped" })
  return
}

// Validate branch names (security -- before any shell interpolation)
const BRANCH_RE = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/
if (!BRANCH_RE.test(currentBranch) || !BRANCH_RE.test(defaultBranch)) {
  warn("Ship phase: Invalid branch name -- skipping")
  updateCheckpoint({ phase: "ship", status: "skipped" })
  return
}

// Verify there are commits to push
const commitCount = Bash(`git rev-list --count "${defaultBranch}".."${currentBranch}"`).trim()
if (commitCount === "0") {
  warn("Ship phase: No commits to push -- skipping PR creation")
  updateCheckpoint({ phase: "ship", status: "skipped" })
  return
}

// 2. Push branch
const pushResult = Bash(`git push -u origin -- "${currentBranch}"`)
if (pushResult.exitCode !== 0) {
  warn(`Ship phase: Push failed. Create PR manually: git push -u origin \`${currentBranch}\``)
  updateCheckpoint({ phase: "ship", status: "failed" })
  return
}

// 3. Generate PR title from plan frontmatter (shard-aware v1.66.0+)
const planContent = Read(checkpoint.plan_file)
const titleMatch = planContent.match(/^---\n[\s\S]*?^title:\s*(.+?)$/m)
const planTitle = titleMatch ? titleMatch[1].trim() : basename(checkpoint.plan_file, '.md').replace(/^\d{4}-\d{2}-\d{2}-/, '')
const typeMatch = planContent.match(/^type:\s*(\w+)/m)
const planType = typeMatch ? typeMatch[1] : 'feat'

let prTitle
if (checkpoint.shard) {
  const s = checkpoint.shard
  // CONCERN-3 FIX: Use "of" instead of "/" and hyphen instead of em dash
  // safePrTitle sanitizer strips both / and — characters
  prTitle = `feat(shard ${s.num} of ${s.total}): ${s.name} - ${s.feature.replace(/-/g, ' ')}`
} else {
  // Existing behavior — preserve planType (not hardcode feat:)
  prTitle = `${planType}: ${planTitle}`
}
const safePrTitle = prTitle.replace(/[^a-zA-Z0-9 ._\-:()]/g, '').slice(0, 70) || "Arc: work completed"

// 4. Build PR body
const diffStat = Bash(`git diff --stat "${defaultBranch}"..."${currentBranch}"`).trim()

// SEC-006 FIX: Wrap review summary in code fence to prevent markdown injection from reviewed content.
// TOME may contain content from compromised agents or tampered files.
const rawReviewSummary = exists(`tmp/arc/${id}/tome.md`)
  ? Read(`tmp/arc/${id}/tome.md`).split('\n').slice(0, 20).join('\n')
  : "Review TOME not available"
const reviewSummary = '```\n' + rawReviewSummary.replace(/```/g, "'''") + '\n```'

// QA Dashboard injection (reads dashboard.md generated by generateQADashboard)
let qaSection = ""
const qaDashboardPath = `tmp/arc/${id}/qa/dashboard.md`
if (exists(qaDashboardPath)) {
  // SEC-006: Wrap in code fence to prevent markdown injection from QA agent output
  const rawDashboard = Read(qaDashboardPath)
  qaSection = '\n```\n' + rawDashboard.replace(/```/g, "'''") + '\n```\n'
} else {
  // Fallback: build inline summary from checkpoint phase data if dashboard unavailable
  const qaPhases = ["forge", "work", "gap_analysis", "code_review", "mend", "test"]
  const qaResults = []
  for (const phase of qaPhases) {
    const verdictPath = `tmp/arc/${id}/qa/${phase}-verdict.json`
    if (exists(verdictPath)) {
      try {
        const v = JSON.parse(Read(verdictPath))
        qaResults.push(`${phase}: ${v.verdict ?? "?"} (${v.scores?.overall_score ?? "?"}%)`)
      } catch (_) {}
    }
  }
  if (qaResults.length > 0) {
    qaSection = `\n### QA Gate Results\n- ${qaResults.join('\n- ')}\n`
  }
}

// Unfixed findings from convergence (if any remain after mend cycles)
let unfixedSection = ""
const resolutionPath = `tmp/arc/${id}/resolution-report.md`
if (exists(resolutionPath)) {
  const resReport = Read(resolutionPath)
  const failedMatch = resReport.match(/FAILED:\s*(\d+)/i)
  const failedCount = failedMatch ? parseInt(failedMatch[1], 10) : 0
  if (failedCount > 0) {
    unfixedSection = `\n- **Unfixed findings**: ${failedCount} (see resolution-report.md)`
  }
}

// Read talisman PR settings
const monitoringRequired = arcConfig.ship.pr_monitoring
// BACK-012 FIX: Read co_authors from arcConfig.ship (resolved via resolveArcConfig)
// instead of raw talisman?.work?.co_authors, so the 3-layer resolution chain applies.
const coAuthors = arcConfig.ship.co_authors ?? []
const validCoAuthors = coAuthors.filter(a => /^[^<>\n]+\s+<[^@\n]+@[^>\n]+>$/.test(a))
const coAuthorLines = validCoAuthors.map(a => `Co-Authored-By: ${a}`).join('\n')

// SEC-005 FIX: Re-validate plan_file from checkpoint before PR body interpolation.
// On resume, the checkpoint may have been tampered — re-validate same regex as arc init.
const SAFE_PATH_RE = /^[a-zA-Z0-9._\/-]+$/
const safePlanFile = SAFE_PATH_RE.test(checkpoint.plan_file) && !checkpoint.plan_file.includes('..')
  ? checkpoint.plan_file
  : "(invalid plan path)"

// NEW (v1.66.0): Shard context section for PR body
let prBodyShardSection = ""
if (checkpoint.shard) {
  const s = checkpoint.shard
  prBodyShardSection = `
## Shard Context

- **Shard**: ${s.num} of ${s.total} (${s.name})
- **Parent plan**: \`${s.parent}\`
- **Dependencies**: ${s.dependencies.length > 0 ? s.dependencies.map(n => \`shard-\${n}\`).join(', ') : 'None (foundation)'}
- **Feature**: ${s.feature}

> This PR implements one shard of a shattered plan. See parent plan for full scope.
`
}

const prBody = `## Summary

Implemented from plan: \`${safePlanFile}\`
Pipeline: \`/rune:arc\` (${Object.values(checkpoint.phases).filter(p => p.status === "completed").length} phases completed)
${prBodyShardSection}

### Changes
\`\`\`
${diffStat}
\`\`\`

### Arc Pipeline Results
- **Commits**: ${commitCount} incremental commits, each ward-checked
- **Code Review**: ${exists(`tmp/arc/${id}/tome.md`) ? "TOME generated (deep review)" : "N/A"}
- **Mend**: ${checkpoint.convergence?.history?.length ?? 0} convergence cycle(s)${unfixedSection}
${qaSection}
### Review Summary
${reviewSummary}

${monitoringRequired ? `## Post-Deploy Monitoring
<!-- Fill in before merging -->
- **What to monitor**:
- **Expected healthy behavior**:
- **Failure signals / rollback trigger**:
- **Validation window**:
` : ""}
---
Generated with [Claude Code](https://claude.ai/code) via Rune Plugin (/rune:arc)
${coAuthorLines}`

// Known Issues from deep review (v1.67.0+: formerly from audit)
// v1.67.0+: audit phases removed (v13 schema). These paths are dead for new arcs
// but may exist for resumed v12 checkpoints where audit ran before migration.
const knownIssuesPath = `tmp/arc/${id}/audit-known-issues.md`
const knownIssuesP3Path = `tmp/arc/${id}/audit-known-issues-p3.md`
let knownIssuesSection = ''

if (exists(knownIssuesPath)) {
  knownIssuesSection += '\n\n## Known Issues (from deep review)\n\n'
  knownIssuesSection += Read(knownIssuesPath)
}
if (exists(knownIssuesP3Path)) {
  knownIssuesSection += '\n\n<details>\n<summary>P3 findings (informational)</summary>\n\n'
  knownIssuesSection += Read(knownIssuesP3Path)
  knownIssuesSection += '\n</details>'
}

// Append to PR body
prBody += knownIssuesSection

Write(`tmp/arc/${id}/pr-body.md`, prBody)

// 5. Create PR
// Validate labels array before .map() (SEC-DECREE-002 / concern #13)
const labelsArray = Array.isArray(arcConfig.ship.labels) ? arcConfig.ship.labels : []
const draftFlag = arcConfig.ship.draft ? "--draft" : ""
const labelFlag = labelsArray.length > 0
  ? labelsArray.map(l => `--label "${l.replace(/[^a-zA-Z0-9 ._\-]/g, '')}"`).join(' ')
  : ""

// Always specify --base explicitly (concern C-2 / cross-reviewer agreement)
const prResult = Bash(`${GH_ENV} gh pr create --title "${safePrTitle}" --base "${defaultBranch}" --body-file "tmp/arc/${id}/pr-body.md" ${draftFlag} ${labelFlag}`.trim())

if (prResult.exitCode !== 0) {
  // Check if PR already exists (branch already has an open PR)
  const existingPr = Bash(`${GH_ENV} gh pr view --json url -q .url 2>/dev/null`).trim()
  if (existingPr) {
    log(`PR already exists: ${existingPr}`)
    checkpoint.pr_url = existingPr
    updateCheckpoint({
      phase: "ship", status: "completed",
      artifact: `tmp/arc/${id}/pr-body.md`,
      artifact_hash: sha256(Read(`tmp/arc/${id}/pr-body.md`)),
      phase_sequence: 9, team_name: null
    })
    return
  }
  warn("Ship phase: PR creation failed. Branch was pushed. Create PR manually: gh pr create")
  updateCheckpoint({ phase: "ship", status: "failed" })
  return
}

// BACK-009 FIX: Validate PR URL format from gh output before storing
const prUrl = prResult.trim()
if (!/^https:\/\//.test(prUrl)) {
  warn(`Ship phase: gh pr create returned unexpected output (not a URL): "${prUrl.slice(0, 100)}"`)
}
log(`PR created: ${prUrl}`)

// 6. Update checkpoint
checkpoint.pr_url = prUrl
updateCheckpoint({
  phase: "ship", status: "completed",
  artifact: `tmp/arc/${id}/pr-body.md`,
  artifact_hash: sha256(Read(`tmp/arc/${id}/pr-body.md`)),
  phase_sequence: 9, team_name: null
})
```

## Error Handling

| Condition | Action |
|-----------|--------|
| `parent_plan.skip_ship_pr` true | Phase skipped -- child arc, parent hierarchy creates single PR |
| `auto_pr` disabled | Phase skipped -- proceed to merge (also skipped) or completion |
| gh CLI missing/unauthenticated | Phase skipped -- warn user, proceed to completion |
| On default branch | Phase skipped -- no PR needed |
| No commits to push | Phase skipped -- nothing to ship |
| Push fails | Phase failed -- branch not pushed, user creates PR manually |
| PR creation fails | Check for existing PR; if none, phase failed -- branch was pushed, user creates PR manually |
| Invalid branch name | Phase skipped -- security guard prevents shell injection |

## Failure Policy

Skip PR creation, proceed to completion report. User creates PR manually. Branch is pushed (if push succeeded), so `gh pr create` from terminal works.

## Crash Recovery

Orchestrator-only phase with no team -- minimal crash surface.

| Resource | Location |
|----------|----------|
| PR body file | `tmp/arc/{id}/pr-body.md` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "ship") |

Recovery: On `--resume`, if ship phase is `in_progress`, re-run from the beginning. Push is idempotent. PR creation checks for existing PR first.
