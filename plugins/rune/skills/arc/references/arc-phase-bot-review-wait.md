# Phase 9.1: BOT_REVIEW_WAIT — Bot Review Detection

Orchestrator-only phase (no team). Polls for bot review completion using multi-signal
hybrid detection with stability window. **Disabled by default** — opt-in via talisman
or `--bot-review` CLI flag.

**Team**: None (orchestrator-only — runs inline after Phase 9 SHIP)
**Tools**: Bash (gh), Write
**Timeout**: 15 min (PHASE_TIMEOUTS.bot_review_wait = 900_000)
**Error handling**: Non-blocking. Disabled by default. Skip on missing PR URL, invalid PR number, or no bots detected.

**Inputs**:
- Checkpoint (with `pr_url` from Phase 9 SHIP)
- `arcConfig.ship.bot_review` (resolved via `resolveArcConfig()`)
- CLI flags: `--bot-review` / `--no-bot-review`

**Outputs**: `tmp/arc/{id}/bot-review-wait-report.md`, `checkpoint.bot_review`

**Consumers**: Phase 9.2 PR_COMMENT_RESOLUTION (needs `checkpoint.bot_review`)

> **Note**: `sha256()`, `updateCheckpoint()`, and `warn()` are dispatcher-provided utilities
> available in the arc orchestrator context. Phase reference files call these without import.

## Pre-checks

1. Skip gate — bot review is DISABLED by default (opt-in)
   - Priority: `--no-bot-review` (force off) > `--bot-review` (force on) > talisman `enabled` > default (`false`)
2. Verify `checkpoint.pr_url` exists (Phase 9 SHIP must have created a PR)
3. Extract PR number from URL — validate as positive integer

## Algorithm

```javascript
updateCheckpoint({ phase: "bot_review_wait", status: "in_progress", phase_sequence: 9.1, team_name: null })

const GH_ENV = 'GH_PROMPT_DISABLED=1'

// 0. Skip gate — bot review is DISABLED by default (opt-in)
// Priority: --no-bot-review (force off) > --bot-review (force on) > talisman enabled > default (false)
const botReviewConfig = arcConfig.ship?.bot_review ?? {}
const botReviewEnabled = flags.no_bot_review ? false
  : flags.bot_review ? true
  : botReviewConfig.enabled === true
if (!botReviewEnabled) {
  log("Bot review wait skipped — disabled by default. Enable via arc.ship.bot_review.enabled: true or --bot-review flag.")
  log("Human can run /rune:resolve-all-gh-pr-comments manually after arc completes.")
  updateCheckpoint({ phase: "bot_review_wait", status: "skipped" })
  return
}

// 1. Verify PR exists
if (!checkpoint.pr_url) {
  warn("Bot review wait: No PR URL — Phase 9 (ship) did not create a PR. Skipping.")
  updateCheckpoint({ phase: "bot_review_wait", status: "skipped" })
  return
}

// Extract PR number from URL and validate
const prNumber = checkpoint.pr_url.match(/\/pull\/(\d+)$/)?.[1]
if (!prNumber || !/^[1-9][0-9]*$/.test(prNumber)) {
  warn("Bot review wait: Cannot extract valid PR number from URL. Skipping.")
  updateCheckpoint({ phase: "bot_review_wait", status: "skipped" })
  return
}

// CONCERN 5: Explicitly extract owner/repo for API calls
// gh api REST auto-resolves {owner}/{repo}, but we need explicit values for
// reliable cross-API calls. GraphQL requires explicit owner/repo.
const owner = Bash(`${GH_ENV} gh repo view --json owner -q '.owner.login'`).trim()
const repo = Bash(`${GH_ENV} gh repo view --json name -q '.name'`).trim()
if (!owner || !repo) {
  warn("Bot review wait: Cannot resolve repository owner/name. Skipping.")
  updateCheckpoint({ phase: "bot_review_wait", status: "skipped" })
  return
}

// 2. Get known bots list — M-3 FIX: explicit allowlist replaces regex-based validation.
// Prevents bot name spoofing via attacker[bot] usernames.
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

// Escape special regex chars in bot names for jq test()
const botLoginPattern = knownBots
  .map(b => b.replace(/\[/g, '\\[').replace(/\]/g, '\\]'))
  .join('|')

// 3. Configuration — all from talisman with defaults
const INITIAL_WAIT_MS = botReviewConfig.initial_wait_ms ?? 120_000   // 2 min
const POLL_INTERVAL_MS = botReviewConfig.poll_interval_ms ?? 30_000  // 30s
const STABILITY_WINDOW_MS = botReviewConfig.stability_window_ms ?? 120_000  // 2 min
const HARD_TIMEOUT_MS = botReviewConfig.timeout_ms ?? 900_000        // 15 min
const phaseStart = Date.now()

// 4. Initial wait — let bots start processing
log(`Waiting ${INITIAL_WAIT_MS / 1000}s for review bots to start...`)
Bash(`sleep ${Math.round(INITIAL_WAIT_MS / 1000)}`)

// 5. Get head commit SHA for check runs
const headSha = Bash("git rev-parse HEAD").trim()

// 6. Multi-signal polling loop
// CONCERN 6: Track updated_at timestamps for stability window, not just counts.
// Bots like coderabbitai edit existing comments — count stays the same but
// updated_at changes. We track the maximum updated_at across all signals.
let lastActivityTimestamp = new Date().toISOString()
let detectedBots = new Set()
let lastCommentCount = 0
let lastCheckRunCount = 0
let lastMaxUpdatedAt = ""

while (Date.now() - phaseStart < HARD_TIMEOUT_MS) {
  // L-6 FIX: Check GitHub API rate limit before polling cycle (4 API calls per cycle).
  // If remaining < 50, back off with exponential delay to avoid hitting the limit.
  const rateLimitRaw = Bash(`${GH_ENV} gh api rate_limit --jq '.rate.remaining' 2>/dev/null || echo "5000"`).trim()
  const rateLimitRemaining = parseInt(rateLimitRaw, 10)
  if (rateLimitRemaining < 50) {
    const resetRaw = Bash(`${GH_ENV} gh api rate_limit --jq '.rate.reset' 2>/dev/null || echo "0"`).trim()
    const resetTime = parseInt(resetRaw, 10)
    const waitSecs = Math.max(0, resetTime - Math.floor(Date.now() / 1000)) + 5
    warn(`GitHub API rate limit low (${rateLimitRemaining} remaining). Waiting ${waitSecs}s for reset.`)
    Bash(`sleep ${Math.min(waitSecs, 120)}`)  // Cap at 2 min wait
  }

  // Signal 1: Check Runs (definitive for copilot, gemini-code-assist)
  const totalCheckRuns = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/commits/${headSha}/check-runs" --jq '[.check_runs[] | select(.app.slug != null)] | length'`).trim()
  const completedCheckRuns = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/commits/${headSha}/check-runs" --jq '[.check_runs[] | select(.status == "completed")] | length'`).trim()
  const inProgressCheckRuns = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/commits/${headSha}/check-runs" --jq '[.check_runs[] | select(.status == "in_progress")] | length'`).trim()
  // Track latest check run completion time
  const checkRunUpdatedAt = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/commits/${headSha}/check-runs" --jq '[.check_runs[].completed_at // empty] | sort | last // empty'`).trim()

  // Signal 2: Issue Comments from known bots (summary comments)
  const botCommentCount = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/issues/${prNumber}/comments" --jq '[.[] | select(.user.login | test("${botLoginPattern}"))] | length'`).trim()
  // CONCERN 6: Track latest updated_at from bot comments
  const commentUpdatedAt = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/issues/${prNumber}/comments" --jq '[.[] | select(.user.login | test("${botLoginPattern}")) | .updated_at] | sort | last // empty'`).trim()

  // Signal 3: PR Reviews from bots (formal reviews)
  const botReviewCount = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/pulls/${prNumber}/reviews" --jq '[.[] | select(.user.type == "Bot")] | length'`).trim()
  const reviewUpdatedAt = Bash(`${GH_ENV} gh api "repos/${owner}/${repo}/pulls/${prNumber}/reviews" --jq '[.[] | select(.user.type == "Bot") | .submitted_at] | sort | last // empty'`).trim()

  const currentCommentCount = parseInt(botCommentCount || "0", 10)
  const currentCheckRunCount = parseInt(completedCheckRuns || "0", 10)
  const inProgressCount = parseInt(inProgressCheckRuns || "0", 10)

  // Compute maximum updated_at across all signals
  const timestamps = [checkRunUpdatedAt, commentUpdatedAt, reviewUpdatedAt].filter(Boolean)
  const currentMaxUpdatedAt = timestamps.length > 0 ? timestamps.sort().pop() : ""

  // Detect new activity — either count increased OR updated_at changed
  const countChanged = currentCommentCount > lastCommentCount || currentCheckRunCount > lastCheckRunCount
  const timestampChanged = currentMaxUpdatedAt && currentMaxUpdatedAt !== lastMaxUpdatedAt

  if (countChanged || timestampChanged) {
    lastActivityTimestamp = new Date().toISOString()
    if (countChanged) {
      log(`Bot activity detected: ${currentCommentCount} comments, ${currentCheckRunCount} completed checks`)
    }
    if (timestampChanged && !countChanged) {
      log(`Bot activity detected: existing comment/review updated (updated_at changed)`)
    }
  }
  lastCommentCount = currentCommentCount
  lastCheckRunCount = currentCheckRunCount
  lastMaxUpdatedAt = currentMaxUpdatedAt

  // Check if all in-progress check runs are done
  if (inProgressCount === 0 && currentCheckRunCount > 0) {
    log("All check runs completed.")
  }

  // Stability window check — no new activity for STABILITY_WINDOW_MS
  const timeSinceLastActivity = Date.now() - new Date(lastActivityTimestamp).getTime()
  if (timeSinceLastActivity >= STABILITY_WINDOW_MS && (currentCommentCount > 0 || currentCheckRunCount > 0)) {
    log(`Stability window reached: ${Math.round(timeSinceLastActivity / 1000)}s with no new bot activity.`)
    break
  }

  // If no bots detected at all after 50% of timeout, skip
  if ((Date.now() - phaseStart) > (HARD_TIMEOUT_MS * 0.5) && currentCommentCount === 0 && currentCheckRunCount === 0) {
    log("No bot reviews detected after 50% of timeout. Proceeding without bot review wait.")
    break
  }

  log(`Polling... ${currentCommentCount} bot comments, ${currentCheckRunCount}/${totalCheckRuns} checks complete, ${inProgressCount} in-progress. Stability: ${Math.round(timeSinceLastActivity / 1000)}s/${Math.round(STABILITY_WINDOW_MS / 1000)}s`)
  Bash(`sleep ${Math.round(POLL_INTERVAL_MS / 1000)}`)
}

// 7. Write bot review wait report
const elapsed = Math.round((Date.now() - phaseStart) / 1000)
const timedOut = (Date.now() - phaseStart) >= HARD_TIMEOUT_MS
const waitReport = `# Bot Review Wait Report

Phase: 9.1 BOT_REVIEW_WAIT
Status: ${timedOut ? "TIMED_OUT" : "COMPLETED"}
Elapsed: ${elapsed}s
Timeout: ${HARD_TIMEOUT_MS / 1000}s

## Detection Results
- Bot comments detected: ${lastCommentCount}
- Check runs completed: ${lastCheckRunCount}
- Last bot activity: ${lastActivityTimestamp}
- Stability window: ${STABILITY_WINDOW_MS / 1000}s
`
Write(`tmp/arc/${id}/bot-review-wait-report.md`, waitReport)

updateCheckpoint({
  phase: "bot_review_wait", status: "completed",
  artifact: `tmp/arc/${id}/bot-review-wait-report.md`,
  artifact_hash: sha256(waitReport),
  phase_sequence: 9.1, team_name: null,
  bot_review: {
    comments: lastCommentCount,
    check_runs: lastCheckRunCount,
    elapsed_ms: Date.now() - phaseStart,
    timed_out: timedOut,
    last_activity: lastActivityTimestamp
  }
})
```

## Dynamic Timeout Budget

**CONCERN 7**: Phase 9.1 adds conditional budget to `calculateDynamicTimeout()`.
When `botReviewEnabled` is true, the function signature becomes:

```javascript
calculateDynamicTimeout(tier, botReviewEnabled)
```

Budget contribution when enabled:
- `bot_review_wait`: +15 min (900_000 ms)
- `pr_comment_resolution`: +20 min (1_200_000 ms)
- Total additional: +35 min

When disabled (default), these phases contribute 0 ms to total pipeline timeout.
All existing call sites must pass the `botReviewEnabled` parameter.

## Error Handling

| Condition | Action |
|-----------|--------|
| Bot review disabled (default) | Phase skipped — proceed to MERGE |
| No PR URL from Phase 9 | Phase skipped — nothing to poll |
| Invalid PR number | Phase skipped — cannot poll |
| Cannot resolve owner/repo | Phase skipped — API calls would fail |
| Hard timeout reached | Phase completed — proceed with whatever was detected |
| No bots after 50% timeout | Phase completed — early exit, no bots configured for this repo |
| API rate limit | gh CLI handles rate limiting with automatic retry |

## Failure Policy

Phase 9.1 never fails the pipeline. All error conditions result in skip or completed
status. If bots are never detected, arc proceeds to MERGE (Phase 9.5) without comment
resolution. The human can always run `/rune:resolve-all-gh-pr-comments` manually.

## Crash Recovery

Orchestrator-only phase with no team — minimal crash surface.

| Resource | Location |
|----------|----------|
| Wait report | `tmp/arc/{id}/bot-review-wait-report.md` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "bot_review_wait") |

Recovery: On `--resume`, if bot_review_wait phase is `in_progress`, re-run from
the beginning. Polling is idempotent. Initial wait restarts from zero.
