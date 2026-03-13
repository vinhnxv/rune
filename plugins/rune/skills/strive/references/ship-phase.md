# Ship Phase — strive Phase 6.5 Reference

Push branch and create PR after work completion.

## Pre-check: gh CLI Availability

```javascript
const ghAvailable = Bash("command -v gh >/dev/null 2>&1 && gh auth status 2>&1 | grep -q 'Logged in' && echo 'ok'").trim() === "ok"
if (!ghAvailable) {
  warn("GitHub CLI (gh) not available or not authenticated. PR creation will be skipped.")
  warn("Install: https://cli.github.com/ -- then run: gh auth login")
}
```

## Ship Decision

```javascript
// Track PR state for Smart Next Steps
let prCreated = false
let prUrl = ""

const currentBranch = Bash("git branch --show-current").trim()
const defaultBranch = Bash("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'").trim()
  || (Bash("git rev-parse --verify origin/main 2>/dev/null").exitCode === 0 ? "main" : "master")
// Validate branch names before display interpolation
if (currentBranch === "") { warn("Detached HEAD -- skipping ship phase"); return }
if (!/^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/.test(currentBranch) || !/^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/.test(defaultBranch)) {
  warn("Invalid branch name detected -- skipping ship phase")
  return
}

if (currentBranch !== defaultBranch) {
  const options = [
    { label: "Skip", description: "Don't push -- review locally first" }
  ]
  if (ghAvailable) {
    options.unshift(
      { label: "Create PR (Recommended)", description: "Push branch and open a pull request" }
    )
  } else {
    options.unshift(
      { label: "Push only", description: "Push to remote (gh CLI not available for PR)" }
    )
  }
  AskUserQuestion({
    questions: [{
      question: `Work complete on \`${currentBranch}\`. Ship it?`,
      header: "Ship",
      options: options,
      multiSelect: false
    }]
  })
  // Default on timeout: Skip (fail-safe -- do not push without explicit consent)
}
```

## PR Template

When user selects "Create PR":

```javascript
// 1. Push branch
if (!/^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/.test(currentBranch)) {
  throw new Error(`Invalid branch name for push: ${currentBranch}`)
}
const pushResult = Bash(`git push -u origin -- "${currentBranch}"`)
if (pushResult.exitCode !== 0) {
  warn("Push failed. Check remote access and try manually: git push -u origin " + currentBranch)
  return
}

// 2. Generate PR title from plan
const planContent = Read(planPath)
const titleMatch = planContent.match(/^---\n[\s\S]*?^title:\s*(.+?)$/m)
const planTitle = titleMatch ? titleMatch[1].trim() : basename(planPath, '.md').replace(/^\d{4}-\d{2}-\d{2}-/, '')
const typeMatch = planContent.match(/^type:\s*(\w+)/m) || planPath.match(/\/(\w+)-/)
const planType = typeMatch ? typeMatch[1] : 'feat'
const prTitle = `${planType}: ${planTitle}`
const safePrTitle = prTitle.replace(/[^a-zA-Z0-9 ._\-:()]/g, '').slice(0, 70) || "Work completed"

// 3. Build file change summary
if (!/^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/.test(defaultBranch)) {
  throw new Error(`Invalid default branch name: ${defaultBranch}`)
}
const diffStat = Bash(`git diff --stat "${defaultBranch}"..."${currentBranch}"`).trim()

// readTalismanSection: "work"
const work = readTalismanSection("work")
const monitoringRequired = work?.pr_monitoring ?? false
const coAuthors = work?.co_authors ?? []

// 5. Build co-author lines
const validCoAuthors = coAuthors.filter(a => /^[^<>\n]+\s+<[^@\n]+@[^>\n]+>$/.test(a))
const coAuthorLines = validCoAuthors.map(a => `Co-Authored-By: ${a}`).join('\n')

// 6. Capture variables from earlier phases
const commitCount = committedTaskIds.size
const verificationWarnings = checks

// 7. Write PR body to file
const safeSubject = (s) => s.replace(/[^a-zA-Z0-9 ._\-:()]/g, '').slice(0, 120)
const safePlanPath = planPath.replace(/[`$]/g, '\\$&')
const prBody = `## Summary

Implemented from plan: \`${safePlanPath}\`

### Changes
\`\`\`
${diffStat}
\`\`\`

### Tasks Completed
${completedTasks.map(t => `- [x] ${safeSubject(t.subject)}`).join("\n")}
${blockedTasks.length > 0 ? `\n### Blocked Tasks\n${blockedTasks.map(t => `- [ ] ${safeSubject(t.subject)}`).join("\n")}` : ""}

## Testing
- Ward checks passed: ${wardResults.map(w => w.name).join(", ")}
- ${commitCount} incremental commits, each ward-checked

## Quality
- All plan checkboxes checked
- ${verificationWarnings.length === 0 ? "No verification warnings" : `${verificationWarnings.length} warnings`}
${(() => {
  // Read todo summary if it exists
  const todoSummaryPath = `tmp/work/${timestamp}/worker-logs/_summary.md`
  const hasSummary = Bash(`test -f "${todoSummaryPath}" && echo "yes"`).trim() === "yes"
  if (hasSummary) {
    const summaryContent = Read(todoSummaryPath)
    // Extract Progress Overview and Key Decisions sections
    const progressMatch = summaryContent.match(/## Progress Overview[\s\S]*?(?=##|$)/)
    const decisionsMatch = summaryContent.match(/## Key Decisions[\s\S]*?(?=##|$)/)
    const progress = progressMatch ? progressMatch[0].trim() : ""
    const decisions = decisionsMatch ? decisionsMatch[0].trim() : ""
    return `
## Work Session

<details>
<summary>Per-worker todo tracking</summary>

${progress}

${decisions ? decisions : ""}

</details>
`
  }
  return ""
})()}
${Bash(`test -f "tmp/work/${timestamp}/codex-advisory.md" && echo "yes"`).trim() === "yes" ? `
## Codex Advisory
See [codex-advisory.md](tmp/work/${timestamp}/codex-advisory.md) for cross-model implementation review.` : ""}
${monitoringRequired ? `
## Post-Deploy Monitoring
<!-- Fill in before merging -->
- **What to monitor**:
- **Expected healthy behavior**:
- **Failure signals / rollback trigger**:
- **Validation window**:
` : ""}
---
Generated with [Claude Code](https://claude.ai/code) via Rune Plugin
${coAuthorLines}`

if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid work timestamp")
Write(`tmp/work/${timestamp}/pr-body.md`, prBody)
const prResult = Bash(`gh pr create --title "${safePrTitle}" --body-file "tmp/work/${timestamp}/pr-body.md"`)
if (prResult.exitCode !== 0) {
  warn("PR creation failed. Branch was pushed successfully. Create PR manually: gh pr create")
} else {
  prUrl = prResult.trim()
  prCreated = true
  log(`PR created: ${prUrl}`)
}
```

## Smart Next Steps

After the completion report, present interactive next steps. Re-derives branch names independently (not from Phase 6.5 scope, which is conditional).

```javascript
const snCurrentBranch = Bash("git branch --show-current").trim()
const snDefaultBranch = Bash("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'").trim()
  || (Bash("git rev-parse --verify origin/main 2>/dev/null").exitCode === 0 ? "main" : "master")
const BRANCH_RE_SN = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/
if (!snCurrentBranch || !BRANCH_RE_SN.test(snCurrentBranch) || !BRANCH_RE_SN.test(snDefaultBranch) || snCurrentBranch === snDefaultBranch) {
  var filesChanged = 0, hasSecurityFiles = false, hasConfigFiles = false
} else {
  const diffFiles = Bash(`git diff --name-only "${snDefaultBranch}"..."${snCurrentBranch}"`).trim().split('\n').filter(Boolean)
  var filesChanged = diffFiles.length
  var hasSecurityFiles = diffFiles.some(f => /auth|secret|token|crypt|password|session|\.env/i.test(f))
  var hasConfigFiles = diffFiles.some(f => /\.claude\/|talisman|CLAUDE\.md/i.test(f))
}
const taskCount = completedTasks.length

let reviewRecommendation
if (hasSecurityFiles) {
  reviewRecommendation = "/rune:appraise (Recommended) -- security-sensitive files changed"
} else if (filesChanged >= 10 || taskCount >= 8) {
  reviewRecommendation = "/rune:appraise (Recommended) -- large changeset"
} else if (hasConfigFiles) {
  reviewRecommendation = "/rune:appraise (Suggested) -- configuration files changed"
} else {
  reviewRecommendation = "/rune:appraise (Optional) -- small, focused changeset"
}

AskUserQuestion({
  questions: [{
    question: `Work complete. What next?`,
    header: "Next",
    options: [
      { label: reviewRecommendation.split(" -- ")[0], description: reviewRecommendation.split(" -- ")[1] || "Review the implementation" },
      ...(prCreated
        ? [{ label: "View PR", description: `Open ${prUrl} in browser` }]
        : [{ label: "Create PR", description: "Push and open a pull request" }]),
      { label: "/rune:rest", description: "Clean up tmp/ artifacts" }
    ],
    multiSelect: false
  }]
})
```
