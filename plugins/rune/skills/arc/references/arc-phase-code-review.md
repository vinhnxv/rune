# Phase 6: CODE REVIEW (deep) — Full Algorithm

Invoke `/rune:appraise --deep` on the implemented changes. Multi-wave review (Wave 1 core + Wave 2 investigation + Wave 3 dimension analysis) replaces the former separate audit phases (8/8.5/8.7).

**Team**: `arc-review-{id}` (delegated to `/rune:appraise` — manages its own TeamCreate/TeamDelete with guards)
**Tools**: Read, Glob, Grep, Write (own output file only)
**Timeout**: 15 min (PHASE_TIMEOUTS.code_review = 900_000 — inner 10m + 5m setup). Deep mode extends internally via wave timeout distribution.
**Inputs**: id (string), gap analysis path (optional: `tmp/arc/{id}/gap-analysis.md`)
**Outputs**: `tmp/arc/{id}/tome.md`
**Error handling**: Does not halt — review always produces findings or a clean report. Timeout → partial results collected. Team creation failure → cleanup fallback via `rm -rf` (see [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md)).
**Consumers**: SKILL.md (Phase 6 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, `warn()`, and `parseFrontmatter()` (from file-todos/references/subcommands.md Common Helpers) are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Progressive Focus (Re-Review Rounds)

On convergence retry (round > 0), Phase 6 uses a focused scope instead of the full branch diff:

```javascript
// Before delegating to /rune:appraise, check for re-review context
const round = checkpoint.convergence?.round ?? 0

if (round > 0) {
  // Re-review: use progressive focus scope from convergence controller
  const focusFile = `tmp/arc/${id}/review-focus-round-${round}.json`
  let focus = null
  if (exists(focusFile)) {
    try {
      focus = JSON.parse(Read(focusFile))
      if (!Array.isArray(focus?.focus_files) || focus.focus_files.length === 0) {
        warn(`Re-review focus file malformed or empty — using full scope`)
        focus = null
      }
    } catch (e) {
      warn(`Re-review focus file unparseable: ${e.message} — using full scope`)
      focus = null
    }
  }
  if (focus) {
    // SEC-009: Validate each focus_files entry before use
    const SAFE_FILE_PATH = /^[a-zA-Z0-9._\-\/]+$/
    changed_files = focus.focus_files.filter(f =>
      typeof f === 'string' && SAFE_FILE_PATH.test(f) && !f.includes('..') && !f.startsWith('/')
    )
    log(`Re-review round ${round}: ${changed_files.length} files (${focus.mend_modified.length} mend-modified + ${focus.dependency_files?.length ?? 0} dependencies)`)
  }
  // QUAL-017: Reduce Ash count for focused reviews — 3 is sufficient for mend-modified files.
  // Re-review still uses --deep (depth=deep) with reduced agent count for focused coverage.
  // Documented in CHANGELOG v1.37.0 and phase-tool-matrix.md.
  maxAgents = Math.min(3, maxAgents)  // Cap at 3 Ashes for re-review (applies to Wave 1 only)
  // Reduce timeout proportionally (minimum 5 min to allow meaningful review)
  // BACK-007 FIX: Floor prevents sub-minute timeout when PHASE_TIMEOUTS.code_review is small
  reviewTimeout = Math.max(300_000, Math.floor(PHASE_TIMEOUTS.code_review * 0.6))
  // NOTE: Focused re-review always runs single-pass (not chunked), regardless of CHUNK_THRESHOLD
}
```

## TOME Relocation Per Round

TOME output path varies by convergence round to prevent overwriting:
- Round 0: `tmp/arc/{id}/tome.md` (current behavior)
- Round N (N>0): `tmp/arc/{id}/tome-round-{N}.md` (preserves round 0 TOME for reference)

## CRITICAL — Delegation Contract

This phase is **delegated** to `/rune:appraise` via sub-command invocation (Agent tool). The arc orchestrator MUST NOT call `TeamCreate` for this phase. The `/rune:appraise` sub-command manages its own team lifecycle in a separate process. Attempting to create a team inline in the orchestrator would fail with "Already leading team X" if SDK leadership state leaked from Phase 2 (PLAN REVIEW).

The orchestrator's role in Phase 6 is limited to:
1. Run `prePhaseCleanup(checkpoint)` — clear stale teams and SDK state
2. Invoke `/rune:appraise` logic — the sub-command creates and manages its own team
3. Discover team name from state file — record in checkpoint for cancel-arc
4. Relocate TOME artifact — copy from review output dir to arc artifacts
5. Update checkpoint — record artifact path and hash

**DO NOT** create a team, create tasks, or spawn agents inline for this phase.

## Algorithm

```javascript
// STEP 1: Propagate gap analysis to reviewers as additional context
let reviewContext = ""
if (exists(`tmp/arc/${id}/gap-analysis.md`)) {
  const gapReport = Read(`tmp/arc/${id}/gap-analysis.md`)
  const missingMatch = gapReport.match(/\| MISSING \| (\d+) \|/)
  const missingCount = missingMatch ? parseInt(missingMatch[1], 10) : 0
  const partialMatch = gapReport.match(/\| PARTIAL \| (\d+) \|/)
  const partialCount = partialMatch ? parseInt(partialMatch[1], 10) : 0
  if (missingCount > 0 || partialCount > 0) {
    reviewContext = `\n\nGap Analysis Context: ${missingCount} MISSING, ${partialCount} PARTIAL criteria.\nSee tmp/arc/${id}/gap-analysis.md.`
  }
}

// STEP 1.5: Inject low-scoring dimensions from VERDICT.md as reviewer focus areas
// If Phase 5.5 produced a VERDICT.md (via Inspector Ashes), extract dimension scores.
// Dimensions with score < 7 are flagged as focus areas for code reviewers.
const verdictPath = `tmp/arc/${id}/gap-analysis-verdict.md`
if (exists(verdictPath)) {
  try {
    const verdictContent = Read(verdictPath)
    // Parse dimension score table rows: | Dimension Name | score/10 | ... |
    const dimensionRows = verdictContent.match(/\|\s*([A-Za-z &]+?)\s*\|\s*(\d+(?:\.\d+)?)\/10\s*\|/g) || []
    const lowScoringDimensions = []
    for (const row of dimensionRows) {
      const match = row.match(/\|\s*([A-Za-z &]+?)\s*\|\s*(\d+(?:\.\d+)?)\/10\s*\|/)
      if (match) {
        const dimName = match[1].trim()
        const score = parseFloat(match[2])
        if (!Number.isNaN(score) && score < 7) {
          lowScoringDimensions.push(`${dimName} (${score}/10)`)
        }
      }
    }
    if (lowScoringDimensions.length > 0) {
      reviewContext += `\n\nFocus areas from gap analysis: ${lowScoringDimensions.join(', ')}.\nThese dimensions scored below 7/10 in the inspection report — pay extra attention to these areas.`
    }
  } catch (e) {
    warn(`Failed to parse VERDICT.md for dimension scores: ${e.message}`)
  }
}

// STEP 2: Codex Oracle conditional inclusion
// Run Codex detection per roundtable-circle/references/codex-detection.md.
// If detected and "review" is in talisman.codex.workflows, include Codex Oracle.
// Codex Oracle findings use CDX prefix and participate in dedup and TOME aggregation.

// STEP 3: Delegate to /rune:appraise --deep
// /rune:appraise --deep runs multi-wave review (Wave 1 core + Wave 2 investigation + Wave 3 dimension).
// This replaces the former separate audit phases (8/8.5/8.7) by folding audit-depth analysis
// into the review pass. The appraise skill manages its own team lifecycle per wave.
// Arc records the team_name for cancel-arc discovery.
// Delegation pattern: /rune:appraise creates its own team (e.g., rune-review-{identifier}).
// Arc reads the team name from the review state file or teammate idle notification.
// PRE-DELEGATION: Record phase as in_progress with null team name.
// Actual team name will be discovered post-delegation from state file (see STEP 4.5 below).
updateCheckpoint({ phase: "code_review", status: "in_progress", phase_sequence: 6, team_name: null })

// No --todos-dir flag needed — appraise detects arc context automatically
// Roundtable-circle Phase 5.4 scans .claude/arc/*/checkpoint.json for code_review phase in_progress + todos_base
// When found, todo generation redirects to "tmp/arc/{id}/todos/review/" instead of "tmp/reviews/{review-id}/todos/review/"
// Arc reads todos_base from checkpoint post-delegation (see STEP 4.5 verification below)
// Invoke: /rune:appraise --deep {scopeFileFlag} {reviewContext}

// BACK-5 FIX: Pass gap analysis context and review context to /rune:appraise
// so reviewers can focus on areas where implementation may be incomplete.
// reviewContext was built in STEP 1 from gap-analysis.md.

// POST-DELEGATION: Read actual team name from state file
const postReviewStateFiles = Glob("tmp/.rune-review-*.json").filter(f => {
  try {
    const state = JSON.parse(Read(f))
    if (!state.status) return false
    const age = Date.now() - new Date(state.started).getTime()
    const isValidAge = !Number.isNaN(age) && age >= 0 && age < PHASE_TIMEOUTS.code_review
    const isRelevant = state.status === "active" ||
      (state.status === "completed" && age >= 0 && age < 5000)
    return isRelevant && isValidAge
  } catch (e) { return false }
})
if (postReviewStateFiles.length > 1) {
  warn(`Multiple review state files found (${postReviewStateFiles.length}) — using most recent`)
}
// NOTE: reviewTeamName variable needed for TOME relocation (STEP 4, line 81).
// Work/mend/audit don't need this — only code-review copies TOME to arc artifacts dir.
// SEC-003 FIX: Fallback uses Date.now() (numeric only — safe for filesystem/regex).
// BACK-012 FIX: TOME relocation uses glob discovery instead of team name derivation.
let reviewTeamName = `rune-review-${Date.now()}`  // fallback — only used for checkpoint, not TOME path
if (postReviewStateFiles.length > 0) {
  try {
    const actualTeamName = JSON.parse(Read(postReviewStateFiles[0])).team_name
    if (actualTeamName && /^[a-zA-Z0-9_-]+$/.test(actualTeamName)) {
      reviewTeamName = actualTeamName
      updateCheckpoint({ phase: "code_review", team_name: actualTeamName })
    }
  } catch (e) {
    warn(`Failed to read team_name from state file: ${e.message}`)
  }
}

// STEP 4: TOME relocation (copy, not move — original remains for debugging)
// Source: tmp/reviews/{review-id}/TOME.md (produced by /rune:appraise)
// Target: round-aware path (consumed by Phase 7: MEND)
// BACK-012 FIX: Discover TOME via glob — decoupled from team name resolution.
// SEC-012 FIX: Filter candidates by recency — only consider TOMEs created after this phase started.
// Without this filter, the glob matches ALL review TOMEs (including from prior arc sessions).
const phaseStartTime = checkpoint.phases.code_review?.started_at ? new Date(checkpoint.phases.code_review.started_at).getTime() : Date.now() - PHASE_TIMEOUTS.code_review
const tomeCandidates = Glob('tmp/reviews/review-*/TOME.md')
  .filter(f => {
    try { const mtime = parseInt(Bash(`stat -f %m "${f}" 2>/dev/null || stat -c %Y "${f}" 2>/dev/null`).trim(), 10); return Number.isNaN(mtime) ? true : mtime * 1000 >= phaseStartTime } catch (e) { return true }
  })
  .sort().reverse()
// BUG FIX: Lift tomeTarget to outer scope — needed by STEP 5 checkpoint update.
// Previously scoped inside else-block, causing undefined reference in STEP 5.
const convergenceRound = checkpoint.convergence?.round ?? 0
const tomeTarget = convergenceRound === 0
  ? `tmp/arc/${id}/tome.md`
  : `tmp/arc/${id}/tome-round-${convergenceRound}.md`
if (tomeCandidates.length === 0) {
  warn('No TOME found in tmp/reviews/ — code review may have produced no findings')
} else {
  Bash(`cp -- "${tomeCandidates[0]}" "${tomeTarget}"`)
}

// STEP 4.5: Read TOME content for checkpoint integrity hash
// BUG FIX: `sha256(tome)` referenced undefined variable `tome`.
// Now reads tomeTarget content explicitly.
const tomeContent = exists(tomeTarget) ? Read(tomeTarget) : ''

// STEP 5: Update checkpoint
// BUG FIX: artifact path was hardcoded to `tome.md` — wrong on convergence retry
// rounds where TOME is at `tome-round-{N}.md`. Now uses round-aware tomeTarget.
updateCheckpoint({
  phase: "code_review", status: "completed",
  artifact: tomeTarget, artifact_hash: sha256(tomeContent), phase_sequence: 6
})

// STEP 5.5: Post-Phase 6 todos verification (non-blocking)
// 3-step resolution: arc checkpoint → review state file → TOME path derivation
// QUAL-007 FIX: Previous single-step pattern failed silently if state file was missing.
// Now mirrors arc-phase-mend.md 3-step pattern for consistency and resilience.
let reviewTodosBase = null

// Step 1: Arc checkpoint (preferred — always available in arc context)
// Use exact arc checkpoint path to avoid picking a different arc's checkpoint in arc-batch/hierarchy.
const currentArcCheckpoint = `.claude/arc/${id}/checkpoint.json`
const arcCheckpoints = exists(currentArcCheckpoint)
  ? [currentArcCheckpoint]
  : Glob(".claude/arc/*/checkpoint.json").filter(f => f.includes(`/arc-${id.replace(/^arc-/, '')}/`)).sort().reverse()
for (const ckpt of arcCheckpoints) {
  try {
    const c = JSON.parse(Read(ckpt))
    if (c.todos_base && c.phases?.code_review?.status !== "pending") {
      reviewTodosBase = c.todos_base
      break
    }
  } catch {}
}

// Step 2: Review state file (fallback — state file may be missing or stale)
if (!reviewTodosBase) {
  const reviewStatePath = postReviewStateFiles.length > 0 ? postReviewStateFiles[0] : null
  if (reviewStatePath) {
    try { reviewTodosBase = JSON.parse(Read(reviewStatePath)).todos_base || null } catch {}
  }
  if (!reviewTodosBase) {
    warn(`Post-review todos verification: state file missing or todos_base not set — trying TOME path derivation`)
  }
}

// Step 3: Derive from TOME path (last resort)
// Use explicit dirname extraction to avoid regex silent failure on unexpected TOME path formats.
if (!reviewTodosBase) {
  const lastSlash = tomeTarget.lastIndexOf('/')
  const tomeDir = lastSlash > 0 ? tomeTarget.slice(0, lastSlash + 1) : null
  if (tomeDir && !tomeDir.includes('..') && tomeDir.startsWith('tmp/')) {
    reviewTodosBase = `${tomeDir}todos/`
  } else {
    warn(`Could not derive todos_base from TOME path: ${tomeTarget} — skipping todos verification`)
  }
}

if (reviewTodosBase) {
  const reviewTodos = Glob(`${reviewTodosBase}review/[0-9][0-9][0-9]-*.md`)
  log(`Todos verification: ${reviewTodos.length} review todos generated from TOME`)
  // Cross-check: TOME has findings but no todos generated → Phase 5.4 may have been skipped
  if (reviewTodos.length === 0 && tomeContent.includes('RUNE:FINDING')) {
    warn(`Post-review: TOME has findings but no review todos generated. Phase 5.4 may have been skipped by roundtable-circle.`)
  }
  // Spot-check first todo frontmatter schema (v2)
  if (reviewTodos.length > 0) {
    const fm = parseFrontmatter(Read(reviewTodos[0]))
    if (fm.schema_version !== 2 || !fm.source || !fm.status) {
      warn(`Todos verification: invalid v2 frontmatter in ${reviewTodos[0]}`)
    }
  }
}
```

**Output**: `tmp/arc/{id}/tome.md`

**Failure policy**: Review always produces findings or a clean report. Does not halt.

## Gap Analysis Context Propagation

If Phase 5.5 produced a gap analysis with MISSING or PARTIAL criteria, the counts are injected as context for reviewers. This helps reviewers focus on areas where the implementation may be incomplete relative to the plan. The full gap-analysis.md path is provided so reviewers can read details on demand.

## Delegation Steps (Phase 6 → appraise.md Phase 0 with --deep)

<!-- See arc-delegation-checklist.md Phase 6 for the canonical contract -->

When arc invokes `/rune:appraise --deep`, the delegated command MUST execute these Phase 0 steps
from appraise.md. Step ordering matters — scope building depends on default branch detection.

| # | appraise.md Phase 0 Step | Action | Notes |
|---|----------------------|--------|-------|
| 1 | Default branch detection | **RUN** | Review needs this to compute `git diff` base |
| 2 | Changed files scope building | **RUN** | Review needs file inventory for Ash assignment. Depends on step 1 |
| 3 | Abort conditions check | **RUN** | Graceful no-op if no reviewable changes |
| 4 | Custom Ash loading | **RUN** | `ashes.custom[]` filtered by `workflows: [review]` (no-op if none configured) |
| 5 | Codex Oracle detection | **RUN** | Per `codex-detection.md`, if `review` in `talisman.codex.workflows` |

**Steps SKIPPED** (arc handles or not applicable):
- Branch detection: arc already has the branch from pre-flight (COMMIT-1)
- Scope summary display: arc is automated — no user display needed
- Dry-run mode / `--partial` flag: arc always reviews full scope

## Codex Oracle

Conditional on two checks:
1. `codex` CLI is detected on the system (see [codex-detection.md](../../roundtable-circle/references/codex-detection.md))
2. `"review"` is listed in `talisman.codex.workflows` configuration

When both conditions are met, the Codex Oracle is included as an additional reviewer. Its findings use the `CDX` prefix and participate in the standard dedup hierarchy and TOME aggregation.

## TOME Relocation

`/rune:appraise` writes the TOME to its own output directory (`tmp/reviews/{review-id}/TOME.md`). The arc orchestrator relocates it to `tmp/arc/{id}/tome.md` so that Phase 7 (MEND) can find it at the canonical arc artifact path. This is a file copy, not a move -- the original remains for debugging.

## Team Lifecycle

Delegated to `/rune:appraise` — manages its own TeamCreate/TeamDelete with guards (see [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md)). Arc records the actual `team_name` in checkpoint for cancel-arc discovery.

Arc runs `prePhaseCleanup(checkpoint)` before delegation (ARC-6) and `postPhaseCleanup(checkpoint, "code_review")` after checkpoint update. See SKILL.md Inter-Phase Cleanup Guard section and [arc-phase-cleanup.md](arc-phase-cleanup.md).

## Docs-Only Work Output

If Phase 5 produced only documentation files, the review still runs correctly. Rune Gaze's docs-only override ensures Knowledge Keeper is summoned. The TOME will contain `DOC-` and `QUAL-` prefixed findings.

## Crash Recovery

If this phase crashes before reaching cleanup, the following resources are orphaned:

| Resource | Location |
|----------|----------|
| Team config | `$CHOME/teams/rune-review-{identifier}/` (where CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}") |
| Task list | `$CHOME/tasks/rune-review-{identifier}/` |
| State file | `tmp/.rune-review-*.json` (stuck in `"active"` status) |
| Signal dir | `tmp/.rune-signals/rune-review-{identifier}/` |

### Recovery Layers

If this phase crashes, the orphaned resources above are recovered by the 3-layer defense:
Layer 1 (ORCH-1 resume), Layer 2 (`/rune:rest --heal`), Layer 3 (arc pre-flight stale scan).
Review phase teams use `rune-review-*` prefix — handled by the sub-command's own pre-create guard (not Layer 3).

See [team-lifecycle-guard.md](../../rune-orchestration/references/team-lifecycle-guard.md) §Orphan Recovery Pattern for full layer descriptions and coverage matrix.
