# Plan Freshness Gate (FRESH-1)

Zero-LLM-cost structural drift detection for Rune Arc. Detects when a plan was written against a significantly different codebase state using 5 weighted signals.

**Consumers**: SKILL.md (pre-flight), SKILL.md (--resume re-check)

## Inputs / Outputs

- **Inputs**: `planFile` (validated path), talisman config (optional `plan.freshness.*`)
- **Outputs**: `freshnessResult` object stored in checkpoint, `tmp/arc/{id}/freshness-report.md`
- **Error handling**: Plan without `git_sha` → skip check (backward compat). Invalid SHA → skip with warning. SHA unreachable → max commit distance.

## Algorithm

```javascript
// Security pattern: SAFE_SHA_PATTERN — see security-patterns.md
// SEC-6 NOTE: Intentionally case-sensitive (lowercase hex only). Git SHAs are canonical
// lowercase. Plans with uppercase git_sha (e.g., "ABCDEF1") skip the freshness check
// entirely — this is the safe default (no enforcement, same as legacy plans without git_sha).
const SAFE_SHA_PATTERN = /^[0-9a-f]{7,40}$/

const planContent = Read(planFile)
const frontmatter = extractYamlFrontmatter(planContent)
// extractYamlFrontmatter: parses YAML between --- delimiters. Returns object or null on parse error.
const planSha = frontmatter?.git_sha
const planBranch = frontmatter?.branch
const planDate = frontmatter?.date
let freshnessResult = null  // FLAW-001 FIX: declare at outer scope for all code paths

// G1: Backward compatibility — plans without git_sha skip the check
if (!planSha) {
  log("Plan predates freshness gate — skipping check")
  // freshnessResult = null — proceed to Initialize Checkpoint
}

// E8: Validate SHA format before any git command
if (planSha && !SAFE_SHA_PATTERN.test(planSha)) {
  warn(`Invalid git_sha format in plan: ${planSha.slice(0, 20)}`)
  // Treat as missing — skip freshness check
}

if (planSha && SAFE_SHA_PATTERN.test(planSha)) {
  // Overall 10-second deadline for entire freshness check
  const freshnessDeadline = Date.now() + 10_000
  const checkBudget = () => Date.now() > freshnessDeadline
  // clamp: returns value bounded to [min, max]. If NaN, returns min.
  const clamp = (v, min, max) => !Number.isFinite(v) ? min : Math.min(Math.max(v, min), max)

  // readTalismanSection: "plan"
  const plan = readTalismanSection("plan")
  const config = {
    // BACK-008: warn min=0.01 (can't be 0 — use enabled:false to disable warnings)
    // block min=0.0 (set 0 to disable blocking while keeping warnings)
    warn_threshold:       clamp(plan?.freshness?.warn_threshold ?? 0.7, 0.01, 1.0),
    block_threshold:      clamp(plan?.freshness?.block_threshold ?? 0.4, 0.0, 0.99),
    max_commit_distance:  Math.min(Math.max(plan?.freshness?.max_commit_distance ?? 100, 1), 10000),
    enabled:              plan?.freshness?.enabled ?? true
  }
  // G8: Ensure block < warn (swap if inverted)
  if (config.block_threshold >= config.warn_threshold) {
    warn("Talisman: block_threshold >= warn_threshold — swapping")
    ;[config.warn_threshold, config.block_threshold] = [config.block_threshold, config.warn_threshold]
    // LOGIC-5 FIX: Ensure WARN band exists after swap
    if (config.block_threshold === config.warn_threshold) {
      config.warn_threshold = Math.min(config.block_threshold + 0.1, 1.0)
    }
  }

  // LOGIC-1: Early exit when freshness check disabled (--skip-freshness flag or talisman config)
  if (!config.enabled || skipFreshnessFlag) {
    log("Freshness check disabled — skipping")
    freshnessResult = null
    // Skip all signal computation — proceed to Initialize Checkpoint
  } else {

  // G2: Verify SHA exists in git history
  const shaExists = Bash(`git cat-file -t "${planSha}" 2>/dev/null`)
  const shaReachable = shaExists.trim() === "commit"

  // ── Signal 1: Commit Distance (weight 0.25) ──
  let commitDistance = 0
  if (checkBudget()) { /* budget exhausted — use defaults */ }
  else if (shaReachable) {
    const timeoutMs = Math.max(100, freshnessDeadline - Date.now())
    const countResult = Bash(`git rev-list --count "${planSha}..HEAD" 2>/dev/null`, { timeout: Math.min(5000, timeoutMs) })
    commitDistance = countResult.exitCode === 0
      ? parseInt(countResult.trim(), 10) || 0
      : config.max_commit_distance  // E3: shallow clone fallback
  } else {
    commitDistance = config.max_commit_distance  // G2: unreachable SHA
    warn(`Plan source commit ${planSha.slice(0,8)} not found in git history`)
  }
  const commitSignal = clamp(commitDistance / config.max_commit_distance, 0, 1)

  // ── Signal 2: File Drift Ratio (weight 0.35) ──
  // Security pattern: SAFE_FILE_PATH — see security-patterns.md
  const SAFE_FILE_PATH = /^[a-zA-Z0-9._\-\/]+$/
  // extractFileReferences: extracts file paths from markdown (backtick paths, links). Returns string[].
  const referencedFiles = extractFileReferences(planContent)
    .filter(fp => SAFE_FILE_PATH.test(fp) && !fp.includes('..') && !fp.startsWith('/'))
  let fileDriftSignal = 0
  let driftCount = 0
  if (!checkBudget() && referencedFiles.length > 0 && shaReachable) {
    const diffResult = Bash(`git diff --name-status "${planSha}..HEAD" 2>/dev/null`)
    const changedFiles = new Set()
    const renameMap = {}
    const diffOutput = diffResult.trim()
    for (const line of (diffOutput ? diffOutput.split('\n') : [])) {
      const [tstat, ...paths] = line.split('\t')
      if (tstat?.startsWith('R') && paths.length >= 2) {
        // Pure renames (R100) still count as drift — file path changed
        renameMap[paths[0]] = paths[1]
        changedFiles.add(paths[0])
      } else if (tstat === 'M' || tstat === 'A' || tstat === 'D' || tstat === 'T' || tstat?.startsWith('C')) {
        changedFiles.add(paths[0])
      }
    }
    for (const fp of referencedFiles) {
      if (renameMap[fp] || changedFiles.has(fp)) driftCount++
    }
    fileDriftSignal = clamp(driftCount / referencedFiles.length, 0, 1)
  }

  // ── Signal 3: Identifier Loss (weight 0.25) ──
  const identifierRegex = /`([a-zA-Z_][a-zA-Z0-9_.]{2,})`/g
  const STOPWORDS = new Set(['null', 'true', 'false', 'error', 'string', 'number',
    'object', 'function', 'const', 'return', 'import', 'export', 'undefined', 'Promise'])
  const identifiers = [...new Set([...planContent.matchAll(identifierRegex)].map(m => m[1]))]
    .filter(id => !STOPWORDS.has(id) && !id.includes(' ') && id.length <= 100)
    .slice(0, 20)  // Reduced from 30 for 10s budget safety

  let identifierLossSignal = 0
  let lostCount = 0
  const rgAvailable = Bash('command -v rg 2>/dev/null').exitCode === 0
  if (!checkBudget() && identifiers.length > 0 && rgAvailable) {
    const batchSize = 10
    for (let i = 0; i < identifiers.length; i += batchSize) {
      if (checkBudget()) { identifierLossSignal = 0.5; break }
      const batch = identifiers.slice(i, i + batchSize)
      const pattern = batch.map(id => id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')
      const timeoutMs = Math.max(100, freshnessDeadline - Date.now())
      const grepResult = Bash(`rg -l --max-count 1 --glob '!node_modules' --glob '!vendor' --glob '!tmp' --glob '!.git' "${pattern}" 2>/dev/null | head -1`, { timeout: Math.min(3000, timeoutMs) })
      if (grepResult.timedOut) { identifierLossSignal = 0.5; break }
      if (grepResult.trim().length === 0) {
        lostCount += batch.length
      } else {
        for (const id of batch) {
          if (checkBudget()) break
          const singleResult = Bash(`rg -l --max-count 1 --glob '!node_modules' --glob '!vendor' --glob '!tmp' --glob '!.git' "${id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}" 2>/dev/null | head -1`, { timeout: 1000 })
          if (singleResult.timedOut || singleResult.trim().length === 0) lostCount++
        }
      }
    }
    if (identifierLossSignal !== 0.5) identifierLossSignal = clamp(lostCount / identifiers.length, 0, 1)
  }

  // ── Signal 4: Branch Divergence (weight 0.10) ──
  const currentBranch = Bash('git branch --show-current 2>/dev/null').trim() || null
  let branchSignal = 0
  if (planBranch && currentBranch && planBranch !== currentBranch) {
    branchSignal = 0.5
  }

  // ── Signal 5: Time Decay (weight 0.05) ──
  let timeSignal = 0
  if (shaReachable) {
    const commitTime = Bash(`git show -s --format=%ct "${planSha}" 2>/dev/null`)
    const commitEpoch = parseInt(commitTime.trim(), 10) || 0
    if (!isNaN(commitEpoch) && commitEpoch > 0) {
      const daysSince = (Date.now() / 1000 - commitEpoch) / 86400
      if (daysSince > 90) timeSignal = 1.0
      else if (daysSince > 60) timeSignal = 0.6
      else if (daysSince > 30) timeSignal = 0.3
    }
  } else if (planDate) {
    const planEpoch = new Date(planDate).getTime() / 1000
    if (!isNaN(planEpoch)) {
      const daysSince = (Date.now() / 1000 - planEpoch) / 86400
      if (daysSince > 90) timeSignal = 1.0
      else if (daysSince > 60) timeSignal = 0.6
      else if (daysSince > 30) timeSignal = 0.3
    } else {
      timeSignal = 0.5  // Malformed date — neutral fallback
    }
  }

  // ── Composite Score ──
  const weights = { commit_distance: 0.25, file_drift: 0.35, identifier_loss: 0.25, branch_divergence: 0.10, time_decay: 0.05 }
  const weightedSum =
    commitSignal * weights.commit_distance +
    fileDriftSignal * weights.file_drift +
    identifierLossSignal * weights.identifier_loss +
    branchSignal * weights.branch_divergence +
    timeSignal * weights.time_decay

  const freshnessScore = clamp(1 - weightedSum, 0, 1)

  // ── Decision ──
  freshnessResult = {
    score: freshnessScore,
    signals: {
      commit_distance: { raw: commitDistance, normalized: commitSignal },
      file_drift: { files_checked: referencedFiles.length, drifted: driftCount, normalized: fileDriftSignal },
      identifier_loss: { ids_checked: identifiers.length, lost: lostCount, normalized: identifierLossSignal },
      branch_divergence: { plan_branch: planBranch, current_branch: currentBranch, normalized: branchSignal },
      time_decay: { normalized: timeSignal }
    },
    git_sha: planSha, sha_reachable: shaReachable,
    status: "PASS", checked_at: new Date().toISOString()
  }

  if (freshnessScore < config.block_threshold) {
    freshnessResult.status = "STALE"
    const answer = AskUserQuestion({
      questions: [{
        question: `Plan freshness: ${freshnessScore.toFixed(2)}/1.0 (STALE). ${commitDistance} commits, ${fileDriftSignal > 0 ? Math.round(fileDriftSignal * 100) + '% file drift' : 'no file drift'}. Proceed?`,
        header: "Staleness",
        options: [
          { label: "Re-plan (Recommended)", description: "Run /rune:devise to create fresh plan" },
          { label: "Show drift details", description: "Display full signal breakdown" },
          { label: "Override and proceed", description: "Accept stale plan risk — logged to checkpoint" },
          { label: "Abort arc", description: "Cancel the arc pipeline" }
        ], multiSelect: false
      }]
    })
    if (!answer || answer.startsWith("Abort")) {
      // BACK-005 FIX: update checkpoint on null/abort (matches Phase 2.5 pattern)
      updateCheckpoint({ phase: "freshness", status: "failed", phase_sequence: 0, team_name: null })
      error(!answer ? "Arc halted — freshness dialog returned null" : "Arc halted by user at freshness check")
      return
    }
    if (answer.startsWith("Re-plan")) { /* exit arc, suggest /rune:devise */ return }
    if (answer.startsWith("Show drift")) {
      // FLAW-002 FIX: Display signal breakdown, then re-prompt without "Show drift details"
      log(`Signal breakdown:\n` +
        `  Commit Distance: ${commitDistance} commits (normalized: ${commitSignal.toFixed(3)})\n` +
        `  File Drift: ${driftCount}/${referencedFiles.length} files (normalized: ${fileDriftSignal.toFixed(3)})\n` +
        `  Identifier Loss: ${lostCount}/${identifiers.length} ids (normalized: ${identifierLossSignal.toFixed(3)})\n` +
        `  Branch Divergence: ${planBranch || 'n/a'} → ${currentBranch || 'n/a'} (normalized: ${branchSignal.toFixed(3)})\n` +
        `  Time Decay: ${timeSignal.toFixed(3)}`)
      const followUp = AskUserQuestion({
        questions: [{
          question: `Plan freshness: ${freshnessScore.toFixed(2)}/1.0 (STALE). What would you like to do?`,
          header: "Staleness",
          options: [
            { label: "Re-plan (Recommended)", description: "Run /rune:devise to create fresh plan" },
            { label: "Override and proceed", description: "Accept stale plan risk — logged to checkpoint" },
            { label: "Abort arc", description: "Cancel the arc pipeline" }
          ], multiSelect: false
        }]
      })
      if (!followUp || followUp.startsWith("Abort")) { return }
      if (followUp.startsWith("Re-plan")) { return }
      if (followUp.startsWith("Override")) { freshnessResult.status = "STALE-OVERRIDE" }
    }
    if (answer.startsWith("Override")) { freshnessResult.status = "STALE-OVERRIDE" }
  } else if (freshnessScore < config.warn_threshold) {
    freshnessResult.status = "WARN"
    warn(`Plan freshness: ${freshnessScore.toFixed(2)}/1.0 — ${commitDistance} commits since plan creation`)
  }

  // G14: Write freshness report artifact
  const report = `# Plan Freshness Report\n\n` +
    `**Score**: ${freshnessScore.toFixed(3)}/1.0\n` +
    `**Status**: ${freshnessResult.status}\n` +
    `**Plan SHA**: ${planSha}\n` +
    `**Current HEAD**: ${Bash('git rev-parse --short HEAD').trim()}\n` +
    `**Checked at**: ${freshnessResult.checked_at}\n\n` +
    `## Signal Breakdown\n\n` +
    `| Signal | Weight | Raw | Normalized |\n|--------|--------|-----|------------|\n` +
    `| Commit Distance | 0.25 | ${commitDistance} commits | ${commitSignal.toFixed(3)} |\n` +
    `| File Drift | 0.35 | ${driftCount}/${referencedFiles.length} files | ${fileDriftSignal.toFixed(3)} |\n` +
    `| Identifier Loss | 0.25 | ${lostCount}/${identifiers.length} ids | ${identifierLossSignal.toFixed(3)} |\n` +
    `| Branch Divergence | 0.10 | ${planBranch || 'n/a'} → ${currentBranch || 'n/a'} | ${branchSignal.toFixed(3)} |\n` +
    `| Time Decay | 0.05 | — | ${timeSignal.toFixed(3)} |\n`
  Write(`tmp/arc/${id}/freshness-report.md`, report)

  // FLAW-003 FIX: Persist freshnessResult to checkpoint for Layer 2 re-check in verification-gate.md
  // Without this, checkpoint?.freshness is always undefined and verification gate's
  // freshness re-check (section 8) silently fails on first term.
  updateCheckpoint({ freshness: freshnessResult })
  } // end else — signal computation (LOGIC-1: skip guard)
}
```

## Signal Weights

| Signal | Weight | Description |
|--------|--------|-------------|
| Commit Distance | 0.25 | `git rev-list --count {planSha}..HEAD` / max_commit_distance |
| File Drift | 0.35 | Files referenced in plan that changed since planSha |
| Identifier Loss | 0.25 | Backtick identifiers in plan no longer found in codebase |
| Branch Divergence | 0.10 | Plan branch vs current branch |
| Time Decay | 0.05 | Days since plan commit (30/60/90 day tiers) |

## Talisman Configuration

```yaml
plan:
  freshness:
    enabled: true              # Set false to disable check entirely
    warn_threshold: 0.7        # Score below this triggers warning (min 0.01)
    block_threshold: 0.4       # Score below this triggers STALE dialog (min 0.0)
    max_commit_distance: 100   # Denominator for commit distance signal (1-10000)
```

## Decision Matrix

| Condition | Status | Action |
|-----------|--------|--------|
| score >= warn_threshold | PASS | Proceed silently |
| block_threshold <= score < warn_threshold | WARN | Warn user, proceed |
| score < block_threshold | STALE | AskUserQuestion: Re-plan / Show details / Override / Abort |
| Plan has no `git_sha` | — | Skip check (backward compat) |
| `--skip-freshness` flag | — | Skip check |
| `plan.freshness.enabled: false` | — | Skip check |

## Resume Re-check

On `--resume`, the freshness check is re-run if the plan's `git_sha` differs from the stored `checkpoint.freshness?.git_sha`. If the previous status was `STALE-OVERRIDE`, the override decision is preserved (no re-prompt).
