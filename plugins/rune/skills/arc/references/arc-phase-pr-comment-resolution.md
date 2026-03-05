# Phase 9.2: PR_COMMENT_RESOLUTION — Bot Comment Resolution

Orchestrator-only phase (no team). Fetches bot comments with pagination, verifies
findings against actual code (hallucination check), and resolves actionable comments.
Supports multi-round review loop when fixes retrigger bots. **Disabled by default** —
opt-in via talisman or `--bot-review` CLI flag.

**Team**: None (orchestrator-only — runs inline after Phase 9.1 BOT_REVIEW_WAIT)
**Tools**: Bash (gh, git, jq), Read, Write, Edit
**Timeout**: 20 min (PHASE_TIMEOUTS.pr_comment_resolution = 1_200_000)
**Error handling**: Non-blocking. Skip on missing PR URL, zero unresolved comments, or API failure.

**Inputs**:
- Checkpoint (with `pr_url`, `bot_review` from Phase 9.1)
- `arcConfig.ship.bot_review` (resolved via `resolveArcConfig()`)
- CLI flags: `--bot-review` / `--no-bot-review`

**Outputs**: `tmp/arc/{id}/pr-comment-resolution-report.md`

**Consumers**: Phase 9.5 MERGE, Completion Report

> **Note**: `sha256()`, `updateCheckpoint()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Skip gate — same logic as Phase 9.1 (`--no-bot-review` > `--bot-review` > talisman > default false)
2. Check Phase 9.1 bot_review data — skip if no bots detected (comments=0, check_runs=0)
3. Extract PR number from `checkpoint.pr_url` — validate as positive integer
4. Resolve owner/repo explicitly (CONCERN 5)

## Algorithm

```javascript
updateCheckpoint({ phase: "pr_comment_resolution", status: "in_progress", phase_sequence: 9.2, team_name: null })

const GH_ENV = 'GH_PROMPT_DISABLED=1'
const botReviewConfig = arcConfig.ship?.bot_review ?? {}

// 0. Skip gate — bot review is DISABLED by default (opt-in)
// Same priority logic as Phase 9.1
const botReviewEnabled = flags.no_bot_review ? false
  : flags.bot_review ? true
  : botReviewConfig.enabled === true
if (!botReviewEnabled) {
  updateCheckpoint({ phase: "pr_comment_resolution", status: "skipped" })
  return
}

// 1. Check if bot reviews were detected in Phase 9.1
const botReviewData = checkpoint.phases?.bot_review_wait?.bot_review ?? {}
if ((botReviewData.comments ?? 0) === 0 && (botReviewData.check_runs ?? 0) === 0) {
  log("No bot reviews detected in Phase 9.1. Skipping comment resolution.")
  updateCheckpoint({ phase: "pr_comment_resolution", status: "skipped" })
  return
}

// 2. Extract and validate PR number
const prNumber = checkpoint.pr_url.match(/\/pull\/(\d+)$/)?.[1]
if (!prNumber || !/^[1-9][0-9]*$/.test(prNumber)) {
  warn("PR comment resolution: Cannot extract valid PR number. Skipping.")
  updateCheckpoint({ phase: "pr_comment_resolution", status: "skipped" })
  return
}
const safePrNumber = parseInt(prNumber, 10)

// CONCERN 5: Explicitly extract owner/repo
const owner = Bash(`${GH_ENV} gh repo view --json owner -q '.owner.login'`).trim()
const repo = Bash(`${GH_ENV} gh repo view --json name -q '.name'`).trim()
if (!owner || !repo) {
  warn("PR comment resolution: Cannot resolve repository owner/name. Skipping.")
  updateCheckpoint({ phase: "pr_comment_resolution", status: "skipped" })
  return
}

// Configuration
const BATCH_SIZE = botReviewConfig.max_comment_batch_size ?? 10
const HALLUCINATION_CHECK = botReviewConfig.hallucination_check ?? true
const AUTO_RESOLVE_OUTDATED = botReviewConfig.auto_resolve_outdated !== false
const MAX_ROUNDS = botReviewConfig.max_review_rounds ?? 3
// M-1 FIX: Validate quality commands against allowlist before execution.
// Prevents command injection if talisman.yml is compromised.
const SAFE_COMMAND_RE = /^[a-zA-Z0-9_\-\.]+(\s+[a-zA-Z0-9_\-\.\/]+)*$/
const QUALITY_COMMANDS = (botReviewConfig.quality_commands ?? []).filter(cmd => {
  if (typeof cmd !== 'string' || !SAFE_COMMAND_RE.test(cmd)) {
    warn(`Quality command rejected (unsafe pattern): "${cmd}"`)
    return false
  }
  return true
})
const outputDir = `tmp/arc/${id}/pr-comments`
Bash(`mkdir -p "${outputDir}"`)

// M-3 FIX: Explicit allowlist of known bot names — prevents spoofing via attacker[bot].
// Talisman overrides are validated against this allowlist (union, not replacement).
const TRUSTED_BOTS = new Set([
  "gemini-code-assist[bot]",
  "coderabbitai[bot]",
  "copilot[bot]",
  "cubic-dev-ai[bot]",
  "chatgpt-codex-connector[bot]",
  "github-actions[bot]",
  "dependabot[bot]",
  "renovate[bot]",
  "sonarcloud[bot]"
])
const talismanBots = botReviewConfig.known_bots ?? []
const knownBots = talismanBots.length > 0
  ? talismanBots.filter(b => {
      if (!TRUSTED_BOTS.has(b)) {
        warn(`Bot "${b}" not in trusted allowlist — ignored. Add to TRUSTED_BOTS if legitimate.`)
        return false
      }
      return true
    })
  : [...TRUSTED_BOTS]
const botPattern = knownBots
  .map(b => b.replace(/\[/g, '\\[').replace(/\]/g, '\\]'))
  .join('|')

// ──────────────────────────────────────
// Multi-round review loop (CONCERN 8)
// When fixes are pushed, bots may re-review. Loop until stable.
// ──────────────────────────────────────
let round = 0
let totalResolved = 0
let totalDismissed = 0
let totalSkipped = 0
let lastCommitSha = ""

while (round < MAX_ROUNDS) {
  round++
  log(`Bot review round ${round}/${MAX_ROUNDS}`)

  // ── STEP 1: Paginated fetch — write to tmp files ──

  // 1a. Review threads via GraphQL (cursor pagination)
  // CRITICAL: Use $endCursor (not $cursor) for gh --paginate compatibility
  Bash(`${GH_ENV} gh api graphql --paginate -f query='
  query($endCursor: String) {
    repository(owner: "${owner}", name: "${repo}") {
      pullRequest(number: ${safePrNumber}) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 10) {
              nodes {
                id
                databaseId
                author { login }
                body
                path
                line
                url
                createdAt
                updatedAt
              }
            }
          }
        }
      }
    }
  }' > "${outputDir}/review-threads-r${round}.json"`)

  // 1b. Issue comments (REST, paginated) — bot summary comments
  Bash(`${GH_ENV} gh api --paginate "repos/${owner}/${repo}/issues/${safePrNumber}/comments?per_page=100" > "${outputDir}/issue-comments-r${round}.json"`)

  // 1c. PR review comments (REST, paginated) — inline bot comments
  Bash(`${GH_ENV} gh api --paginate "repos/${owner}/${repo}/pulls/${safePrNumber}/comments?per_page=100" > "${outputDir}/review-comments-r${round}.json"`)

  // ── STEP 2: Categorize from tmp files ──

  // 2a. Extract unresolved, non-outdated review threads
  Bash(`jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)]' "${outputDir}/review-threads-r${round}.json" > "${outputDir}/unresolved-threads-r${round}.json"`)

  // 2b. Extract outdated threads (candidates for auto-resolve)
  Bash(`jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == true)]' "${outputDir}/review-threads-r${round}.json" > "${outputDir}/outdated-threads-r${round}.json"`)

  // 2c. Extract bot issue comments
  Bash(`jq '[.[] | select(.user.login | test("${botPattern}"))]' "${outputDir}/issue-comments-r${round}.json" > "${outputDir}/bot-comments-r${round}.json"`)

  // ── STEP 3: Auto-resolve outdated threads ──
  if (AUTO_RESOLVE_OUTDATED) {
    const outdatedCount = parseInt(Bash(`jq 'length' "${outputDir}/outdated-threads-r${round}.json"`).trim(), 10)
    if (outdatedCount > 0) {
      // M-2 FIX: Tighten thread ID regex — GitHub GraphQL node IDs are base64-encoded,
      // typically 20+ chars of [A-Za-z0-9+/] with optional = padding.
      Bash(`jq -r '.[].id' "${outputDir}/outdated-threads-r${round}.json" | while read tid; do
        if echo "$tid" | grep -qE '^[A-Za-z0-9+/]{20,}={0,2}$'; then
          ${GH_ENV} gh api graphql -f query="mutation { resolveReviewThread(input: {threadId: \\"$tid\\"}) { thread { isResolved } } }" 2>/dev/null
        fi
      done`)
      log(`Round ${round}: Auto-resolved ${outdatedCount} outdated review threads.`)
      totalResolved += outdatedCount
    }
  }

  // ── STEP 4: Count actionable comments ──
  const totalBotComments = parseInt(Bash(`jq 'length' "${outputDir}/bot-comments-r${round}.json"`).trim(), 10)
  const totalUnresolved = parseInt(Bash(`jq '[.[] | select(.isOutdated == false)] | length' "${outputDir}/unresolved-threads-r${round}.json"`).trim(), 10)
  const totalActionable = totalBotComments + totalUnresolved

  if (totalActionable === 0) {
    log(`Round ${round}: No actionable bot comments or unresolved threads found.`)
    break
  }

  // ── STEP 5: Batch-process comments ──
  // Merge into single actionable list, split into batches
  Bash(`jq -s 'add // []' "${outputDir}/bot-comments-r${round}.json" "${outputDir}/unresolved-threads-r${round}.json" > "${outputDir}/actionable-r${round}.json"`)
  const numBatches = Math.ceil(totalActionable / BATCH_SIZE)

  for (let b = 0; b < numBatches; b++) {
    const start = b * BATCH_SIZE
    Bash(`jq '.[${start}:${start + BATCH_SIZE}]' "${outputDir}/actionable-r${round}.json" > "${outputDir}/batch-r${round}-${b}.json"`)
  }

  // For each batch: read, verify against actual code, classify
  let roundResults = []
  for (let b = 0; b < numBatches; b++) {
    const batchContent = Read(`${outputDir}/batch-r${round}-${b}.json`)

    // For each comment in batch:
    // - Determine type (review thread vs issue comment)
    // - Read referenced file at the path/line
    // - If HALLUCINATION_CHECK: verify concern against actual code
    // - Classify: VALID / FALSE_POSITIVE / ALREADY_ADDRESSED / NOT_APPLICABLE
    // - Record result
    // See "Hallucination Check" section below for details

    Write(`${outputDir}/batch-r${round}-${b}-results.json`, JSON.stringify(batchResults))
    roundResults = roundResults.concat(batchResults)
  }

  // ── STEP 6: Implement fixes ──
  const validFindings = roundResults.filter(r => r.verdict === "VALID")
  const dismissed = roundResults.filter(r => r.verdict !== "VALID")
  totalDismissed += dismissed.length

  if (validFindings.length === 0) {
    log(`Round ${round}: All findings dismissed (no code changes needed). Exiting loop.`)
    // Reply to dismissed comments
    for (const d of dismissed) {
      replyToComment(d, `Reviewed and dismissed: ${d.reason}`)
    }
    break
  }

  // Group fixes by file, apply in reverse line order (avoid offset drift)
  const fixesByFile = groupBy(validFindings, 'file')
  for (const [file, fixes] of Object.entries(fixesByFile)) {
    Read(file)
    for (const fix of fixes.sort((a, b) => b.line - a.line)) {
      Edit(file, fix.oldCode, fix.newCode)
    }
  }

  // Run quality checks (once after all fixes)
  for (const cmd of QUALITY_COMMANDS) {
    const result = Bash(cmd)
    if (result.exitCode !== 0) {
      warn(`Quality check failed: ${cmd}`)
      // Continue — do not block on quality check failure in arc context
    }
  }

  // Single commit + push
  Bash(`git add -A && git commit -m "fix: resolve PR bot review comments (round ${round})"`)
  Bash("git push")
  lastCommitSha = Bash("git rev-parse HEAD").trim()
  totalResolved += validFindings.length

  // ── STEP 7: Reply to resolved comments ──
  for (const fix of validFindings) {
    replyToComment(fix, `Addressed in ${lastCommitSha}`)
    if (fix.threadId) {
      resolveThread(fix.threadId)
    }
  }
  for (const d of dismissed) {
    replyToComment(d, `Reviewed and dismissed: ${d.reason}`)
  }

  // ── STEP 8: Check for more rounds ──
  // Update checkpoint with round progress (CONCERN 8: flat fields)
  updateCheckpoint({
    phases: {
      pr_comment_resolution: {
        current_round: round,
        max_rounds: MAX_ROUNDS,
        comments_resolved: totalResolved,
        comments_dismissed: totalDismissed,
        last_commit: lastCommitSha
      }
    }
  })

  if (round === MAX_ROUNDS) {
    warn(`Max review rounds (${MAX_ROUNDS}) reached. Proceeding to MERGE.`)
    // Reply to remaining unresolved comments
    replyToRemainingComments(`Max review rounds (${MAX_ROUNDS}) reached for automated resolution. This comment deferred to manual review.`)
    break
  }

  // Wait for bots to re-review after push (reduced initial wait)
  const reducedWait = Math.round((botReviewConfig.initial_wait_ms ?? 120_000) * 0.5)
  log(`Round ${round} complete. Waiting ${reducedWait / 1000}s for bots to re-review...`)
  Bash(`sleep ${Math.round(reducedWait / 1000)}`)

  // Quick check: any new bot activity?
  const newBotComments = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/issues/${safePrNumber}/comments" --jq '[.[] | select(.user.login | test("${botPattern}"))] | length'`).trim()
  if (parseInt(newBotComments, 10) <= totalBotComments) {
    log(`Round ${round}: No new bot comments after push. Exiting review loop.`)
    break
  }
}

// ── FINAL: Write resolution report ──
const resolutionReport = `# PR Comment Resolution Report

Phase: 9.2 PR_COMMENT_RESOLUTION
PR: #${safePrNumber}
Repository: ${owner}/${repo}

## Statistics
- Rounds completed: ${round}/${MAX_ROUNDS}
- Comments resolved: ${totalResolved}
- Comments dismissed: ${totalDismissed}
- Comments skipped: ${totalSkipped}
- Last commit: ${lastCommitSha || "N/A (no fixes needed)"}
`
Write(`tmp/arc/${id}/pr-comment-resolution-report.md`, resolutionReport)

updateCheckpoint({
  phase: "pr_comment_resolution", status: "completed",
  artifact: `tmp/arc/${id}/pr-comment-resolution-report.md`,
  artifact_hash: sha256(resolutionReport),
  phase_sequence: 9.2, team_name: null
})
```

## Hallucination Check

Bot review bots often flag false positives because they lack full project context.
When `hallucination_check: true` (default), each finding is verified:

```javascript
function verifyBotFinding(finding) {
  // 1. Read the actual file at the referenced path
  const fileContent = Read(finding.path)
  if (!fileContent) return { verdict: "NOT_APPLICABLE", reason: "File not found" }

  // 2. Check if the referenced line still exists
  const lines = fileContent.split('\n')
  if (finding.line && finding.line > lines.length) {
    return { verdict: "ALREADY_ADDRESSED", reason: "Line no longer exists" }
  }

  // 3. Check if a recent commit already addressed the concern
  const recentCommits = Bash(`git log --oneline -5 -- "${finding.path}"`)
  // Parse commit messages for fix-related keywords

  // 4. Analyze actual code vs bot's concern
  // Read surrounding context (finding.line +/- 10 lines)
  // Compare bot's claim against actual code behavior

  // 5. Return verdict: VALID | FALSE_POSITIVE | ALREADY_ADDRESSED | NOT_APPLICABLE
}
```

Verdicts:
- **VALID**: Bot finding is correct, code fix needed
- **FALSE_POSITIVE**: Bot misunderstands project conventions or context
- **ALREADY_ADDRESSED**: Referenced code no longer exists or was already fixed
- **NOT_APPLICABLE**: File deleted, finding about non-existent construct

## Helper Pseudo-Functions

```javascript
function replyToComment(comment, body) {
  if (comment.type === "review_thread" && comment.commentId) {
    // Reply to review thread comment
    if (/^[0-9]+$/.test(String(comment.commentId))) {
      Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/pulls/${safePrNumber}/comments/${comment.commentId}/replies" -f body="${body}"`)
    }
  } else if (comment.type === "issue_comment" && comment.issueCommentId) {
    // Reply to issue comment (bot summary)
    if (/^[0-9]+$/.test(String(comment.issueCommentId))) {
      Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/issues/${safePrNumber}/comments" -f body="${body}"`)
    }
  }
}

function resolveThread(threadId) {
  if (/^[A-Za-z0-9_=-]+$/.test(threadId)) {
    Bash(`${GH_ENV} gh api graphql -f query="mutation { resolveReviewThread(input: {threadId: \\"${threadId}\\"}) { thread { isResolved } } }"`)
  }
}

function replyToRemainingComments(message) {
  // Fetch current unresolved threads and reply with max-rounds message
  const remaining = Bash(`jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' "${outputDir}/review-threads-r${round}.json"`)
  if (parseInt(remaining, 10) > 0) {
    Bash(`jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .comments.nodes[0].databaseId] | .[]' "${outputDir}/review-threads-r${round}.json" | while read cid; do
      if echo "$cid" | grep -qE '^[0-9]+$'; then
        ${GH_ENV} gh api "repos/${owner}/${repo}/pulls/${safePrNumber}/comments/$cid/replies" -f body="${message}" 2>/dev/null
      fi
    done`)
  }
}
```

## Multi-Round Loop Exit Conditions

The review loop exits when **any** of these conditions is met:

| # | Condition | Exit Type |
|---|-----------|-----------|
| 1 | No actionable comments found (round start) | Clean exit |
| 2 | All findings dismissed (no code changes) | Clean exit, no push |
| 3 | No new bot comments after push | Clean exit |
| 4 | `max_review_rounds` reached | Warn, reply to remaining |

## Checkpoint Schema (CONCERN 8)

Round tracking uses flat fields in `phases.pr_comment_resolution`:

```json
{
  "phases": {
    "pr_comment_resolution": {
      "status": "in_progress",
      "current_round": 2,
      "max_rounds": 3,
      "comments_resolved": 5,
      "comments_dismissed": 3,
      "last_commit": "abc123"
    }
  }
}
```

## Error Handling

| Condition | Action |
|-----------|--------|
| Bot review disabled (default) | Phase skipped |
| No bot reviews in Phase 9.1 | Phase skipped |
| Invalid PR number | Phase skipped |
| Cannot resolve owner/repo | Phase skipped |
| GraphQL pagination timeout | Process what was fetched |
| Quality check fails | Warn, continue (non-blocking) |
| Max rounds reached | Warn, reply to remaining, proceed to MERGE |
| All findings dismissed | Clean exit (no push needed) |

## Failure Policy

Phase 9.2 never fails the pipeline. All error conditions result in skip or completed
status. If comment resolution fails mid-round, the fixes already committed are
preserved and the pipeline proceeds to MERGE. Remaining unresolved comments can be
addressed manually via `/rune:resolve-all-gh-pr-comments`.

## Crash Recovery

Orchestrator-only phase with no team — minimal crash surface.

| Resource | Location |
|----------|----------|
| Per-round fetch data | `tmp/arc/{id}/pr-comments/review-threads-rN.json` |
| Per-round batch results | `tmp/arc/{id}/pr-comments/batch-rN-B-results.json` |
| Resolution report | `tmp/arc/{id}/pr-comment-resolution-report.md` |
| Checkpoint state | `.claude/arc/{id}/checkpoint.json` (phase: "pr_comment_resolution") |

Recovery: On `--resume`, if pr_comment_resolution phase is `in_progress`, check
`current_round` in checkpoint. If a commit was pushed (`last_commit` exists), verify
it exists on remote. Resume from next round. If no commit was pushed, re-run the
current round from scratch.
