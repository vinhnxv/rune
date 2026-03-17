# Phase 9.05: POST_REVIEW_FINDINGS — Full Algorithm

Post review findings from TOME to the GitHub PR as a formatted summary comment. Orchestrator-only — no team creation, no agents.

**Team**: None (orchestrator-only)
**Tools**: Read, Write, Bash, Glob
**Timeout**: 3 min (PHASE_TIMEOUTS.post_findings = 180_000 — orchestrator-only, no team)
**Trigger**: `pr_comment.enabled: true` in talisman AND `checkpoint.pr_url` exists from Phase 9 (SHIP)
**Inputs**: id (string), checkpoint object (with `pr_url` from ship phase), talisman config
**Outputs**: PR comment posted via `gh issue comment`, checkpoint updated with `comment_id` and `findings_posted`
**Error handling**: Non-blocking — proceed to bot_review_wait even if posting fails
**Consumers**: SKILL.md (Phase 9.05 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Skip Conditions

This phase is skipped (status: "skipped") when ANY of the following are true:

1. **`pr_comment.enabled` is not `true`** — feature is opt-in via talisman config
2. **`checkpoint.pr_url` is missing** — no PR was created in Phase 9 (SHIP)
3. **PR number cannot be parsed** — `pr_url` doesn't match `/pull/(\d+)$`
4. **No TOME found** — `tmp/arc/${id}/tome.md` (or `TOME.md`) does not exist
5. **TOME has 0 findings** — after parsing, no findings matched filters
6. **`gh auth status` fails** — not authenticated (cannot post)

Skip reason is recorded in checkpoint for diagnostic visibility.

## Algorithm

```javascript
updateCheckpoint({ phase: "post_findings", status: "in_progress", phase_sequence: 9.05, team_name: null })

// STEP 1: Check pr_comment config gate
const prCommentConfig = readTalismanSection("review") || {}
const config = prCommentConfig.pr_comment || {}

if (!config.enabled) {
  updateCheckpoint({
    phase: "post_findings", status: "skipped", phase_sequence: 9.05, team_name: null,
    skip_reason: "pr_comment.enabled is false"
  })
  return
}

// STEP 2: Extract PR number from checkpoint
const prUrl = checkpoint.pr_url
if (!prUrl) {
  updateCheckpoint({
    phase: "post_findings", status: "skipped", phase_sequence: 9.05, team_name: null,
    skip_reason: "no PR URL in checkpoint (ship phase may have been skipped)"
  })
  return
}

const prMatch = prUrl.match(/\/pull\/(\d+)$/)
if (!prMatch) {
  warn(`Cannot parse PR number from URL: ${prUrl}`)
  updateCheckpoint({
    phase: "post_findings", status: "skipped", phase_sequence: 9.05, team_name: null,
    skip_reason: `unparseable PR URL: ${prUrl}`
  })
  return
}
const prNumber = prMatch[1]

// STEP 3: Locate TOME
// Arc uses lowercase tome.md in some pipelines, TOME.md in others
let tomePath = null
const candidates = [`tmp/arc/${id}/TOME.md`, `tmp/arc/${id}/tome.md`]
for (const candidate of candidates) {
  if (exists(candidate)) {
    tomePath = candidate
    break
  }
}

if (!tomePath) {
  warn("No TOME found for this arc run — skipping post_findings")
  updateCheckpoint({
    phase: "post_findings", status: "skipped", phase_sequence: 9.05, team_name: null,
    skip_reason: "no TOME file found"
  })
  return
}

// STEP 4: Parse TOME findings via shell script
const configJson = JSON.stringify({
  severity_filter: config.severity_filter || ["P1", "P2"],
  confidence_threshold: config.confidence_threshold || 50,
  max_findings: config.max_findings || 30,
  include_traces: config.include_traces !== false,
  include_fix_suggestions: config.include_fix_suggestions !== false
})

let findingsJson
try {
  findingsJson = Bash(`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tome-parser.sh" "${tomePath}" '${configJson}'`)
} catch (e) {
  warn(`TOME parser failed: ${e.message}`)
  updateCheckpoint({
    phase: "post_findings", status: "failed", phase_sequence: 9.05, team_name: null,
    error: "TOME parser script failed"
  })
  return
}

let findings
try {
  findings = JSON.parse(findingsJson)
} catch (e) {
  warn("TOME parser returned invalid JSON")
  updateCheckpoint({
    phase: "post_findings", status: "failed", phase_sequence: 9.05, team_name: null,
    error: "TOME parser returned invalid JSON"
  })
  return
}

if (!Array.isArray(findings) || findings.length === 0) {
  updateCheckpoint({
    phase: "post_findings", status: "skipped", phase_sequence: 9.05, team_name: null,
    skip_reason: "0 findings after filtering"
  })
  return
}

// STEP 5: Format comment via shell script
const findingsFile = `tmp/arc/${id}/pr-comment-findings.json`
Write(findingsFile, JSON.stringify(findings))

const commentFile = `tmp/arc/${id}/pr-comment.md`
const collapseThreshold = config.collapse_threshold || 5
const showFooter = config.footer !== false

try {
  Bash(`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/pr-comment-formatter.sh" "${findingsFile}" "${collapseThreshold}" "${showFooter}" > "${commentFile}"`)
} catch (e) {
  warn(`Comment formatter failed: ${e.message}`)
  updateCheckpoint({
    phase: "post_findings", status: "failed", phase_sequence: 9.05, team_name: null,
    error: "comment formatter failed"
  })
  return
}

// STEP 6: Post comment to PR
try {
  const postResult = Bash(`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/pr-comment-poster.sh" "${prNumber}" "${commentFile}"`)

  if (postResult.includes("ERROR")) {
    warn(`Poster reported error: ${postResult}`)
    updateCheckpoint({
      phase: "post_findings", status: "failed", phase_sequence: 9.05, team_name: null,
      error: postResult
    })
    return
  }
} catch (e) {
  warn(`Failed to post PR comment: ${e.message}`)
  updateCheckpoint({
    phase: "post_findings", status: "failed", phase_sequence: 9.05, team_name: null,
    error: "pr-comment-poster.sh failed"
  })
  return
}

// STEP 7: Update checkpoint with success
updateCheckpoint({
  phase: "post_findings", status: "completed",
  phase_sequence: 9.05, team_name: null,
  artifact: commentFile,
  artifact_hash: sha256(Read(commentFile)),
  comment_id: null, // gh issue comment doesn't return comment ID directly
  findings_posted: findings.length
})
```

## Checkpoint Shape

```json
{
  "status": "pending",
  "artifact": null,
  "comment_id": null,
  "findings_posted": 0,
  "skip_reason": null,
  "started_at": null,
  "completed_at": null
}
```

## Failure Policy

**Non-blocking** — if any step fails (parser error, formatter error, API error), the phase is marked `"failed"` in the checkpoint and the arc pipeline proceeds to the next phase (`bot_review_wait`). The PR comment is best-effort output; it should never block the pipeline.

## Phase Registration

To register this phase in the arc pipeline, the following files must be updated (handled by Worker 3):

1. **`arc-phase-constants.md`** — Add `post_findings` to `PHASE_ORDER` after `ship`, before `bot_review_wait`
2. **`arc-phase-stop-hook.sh`** — Add to PHASE_ORDER array, `_phase_ref()` case, `_phase_weight()` → `1`
3. **`arc-checkpoint-init.md`** — Add `phases.post_findings` initial shape to checkpoint schema
4. **`arc-resume.md`** — Add v24 → v25 migration for new phase field
5. **`arc-delegation-checklist.md`** — Add `post_findings` entry (orchestrator-only, conditional)
6. **Skip map**: Add to `computeSkipMap()` — skip when `auto_pr` is disabled (no PR = nowhere to post)
7. **Timeout**: `PHASE_TIMEOUTS.post_findings = 180000` (3 min)
8. **Skip reason**: `NO_PR_CREATED: "no_pr_created"` added to `SKIP_REASONS`

**NO team prefix registration needed** — this is an orchestrator-only phase (no `TeamCreate`, no agents).

## Cross-Phase Dependencies

| Phase | Relationship |
|-------|-------------|
| Phase 9 (SHIP) | **Requires** `checkpoint.pr_url` — the PR must exist before posting |
| Phase 9.1 (BOT_REVIEW_WAIT) | **Precedes** — post findings before waiting for bot reviews |
| Phase 4 (CODE_REVIEW) | **Consumes** — reads TOME artifact produced by review phase |
