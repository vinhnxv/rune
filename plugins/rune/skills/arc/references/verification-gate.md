# Phase 2.7: Verification Gate — Full Algorithm

Zero-LLM-cost deterministic checks on the enriched plan. Orchestrator-only -- no team, no agents.

**Team**: None (orchestrator-only)
**Tools**: Read, Glob, Grep, Write, Bash (for git history check)
**Duration**: Max 30 seconds

```javascript
updateCheckpoint({ phase: "verification", status: "in_progress", phase_sequence: 4, team_name: null })

const issues = []

// 1. Check plan file references exist
// Security pattern: SAFE_PATH_PATTERN (alias: SAFE_FILE_PATH) -- see security-patterns.md
const SAFE_FILE_PATH = /^[a-zA-Z0-9._\-\/]+$/
const filePaths = extractFileReferences(enrichedPlanPath)
for (const fp of filePaths) {
  if (!SAFE_FILE_PATH.test(fp) || fp.includes('..') || fp.startsWith('/')) {
    issues.push(`File reference with unsafe characters: ${fp.slice(0, 80)}`)
    continue
  }
  if (!exists(fp)) {
    const gitExists = Bash(`git log --all --oneline -- "${fp}" 2>/dev/null | head -1`)
    const annotation = gitExists.trim()
      ? `[STALE: was deleted -- see git history]`
      : `[PENDING: file does not exist yet -- may be created during WORK]`
    issues.push(`File reference: ${fp} -- ${annotation}`)
  }
}

// 2. Check internal heading links resolve
const headingLinks = extractHeadingLinks(enrichedPlanPath)
const headings = extractHeadings(enrichedPlanPath)
for (const link of headingLinks) {
  if (!headings.includes(link)) issues.push(`Broken heading link: ${link}`)
}

// 3. Check acceptance criteria present
const hasCriteria = Grep("- \\[ \\]", enrichedPlanPath)
if (!hasCriteria) issues.push("No acceptance criteria found (missing '- [ ]' items)")

// 4. Check no TODO/FIXME in plan prose (outside code blocks)
const todos = extractTodosOutsideCodeBlocks(enrichedPlanPath)
if (todos.length > 0) issues.push(`${todos.length} TODO/FIXME markers in plan prose`)

// readTalismanSection: "plan"
const plan = readTalismanSection("plan")
const customPatterns = plan?.verification_patterns || []
// Security patterns: SAFE_REGEX_PATTERN, SAFE_PATH_PATTERN -- see security-patterns.md
// SAFE_REGEX_PATTERN allows $ (for regex anchors). Shell interpolation risk mitigated by safeRgMatch() -- see security-patterns.md.
// which excludes $, |, (, ) for stricter contexts.
const SAFE_REGEX_PATTERN = /^[a-zA-Z0-9._\-\/ \\|()[\]{}^$+?]+$/
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\-\/]+$/
for (const pattern of customPatterns) {
  if (!SAFE_REGEX_PATTERN.test(pattern.regex) ||
      !SAFE_PATH_PATTERN.test(pattern.paths) ||
      (pattern.exclusions && !SAFE_PATH_PATTERN.test(pattern.exclusions))) {
    warn(`Skipping pattern "${pattern.description}": unsafe characters`)
    continue
  }
  // SEC-FIX: Pattern interpolation uses safeRgMatch() (rg -f) to prevent $() command substitution.
  // See security-patterns.md for safeRgMatch() implementation.
  const result = safeRgMatch(pattern.regex, pattern.paths, { exclusions: pattern.exclusions, timeout: 5 })
  if (pattern.expect_zero && result.trim().length > 0) {
    issues.push(`Stale reference: ${pattern.description}`)
  }
}

// 5.5. Criteria validation: check ### Task sections have acceptance_criteria blocks (criteria coverage)
const planContent = Read(enrichedPlanPath)
const taskSectionMatches = planContent.match(/^### Task\b[\s\S]*?(?=^### |^## |$)/gm) || []
let tasksWithCriteria = 0
for (const taskSection of taskSectionMatches) {
  const hasCriteriaBlock = /acceptance_criteria|criteria.*validation|criteria.*check/i.test(taskSection)
  if (hasCriteriaBlock) {
    tasksWithCriteria++
    // Warn (non-blocking) when criteria use only semantic_match -- missing machine-verifiable proof types
    // proof.*type|missing.*proof|semantic_match.*warn
    const hasMissingProof = /semantic_match/i.test(taskSection) &&
      !/pattern_matches|test_passes|file_exists/i.test(taskSection)
    if (hasMissingProof) {
      issues.push(`Criteria quality: task "${taskSection.split('\n')[0].trim()}" uses only semantic_match -- add pattern_matches/test_passes/file_exists for machine-verifiable proof (missing proof type)`)
    }
  }
}
const totalTaskCount = taskSectionMatches.length
if (totalTaskCount > 0 && tasksWithCriteria < totalTaskCount) {
  // criteria.*coverage|tasks_with_criteria
  issues.push(`Criteria coverage: ${tasksWithCriteria}/${totalTaskCount} tasks_with_criteria have acceptance_criteria blocks`)
}

// 6. Check pseudocode sections have contract headers (Plan Section Convention)
const sections = planContent.split(/^## /m).slice(1)
for (const section of sections) {
  const heading = section.split('\n')[0].trim()
  const hasCodeBlock = /```(?:javascript|bash|js)\n/i.test(section)
  if (!hasCodeBlock) continue
  const hasInputs = /\*\*Inputs\*\*:/.test(section)
  const hasOutputs = /\*\*Outputs\*\*:/.test(section)
  const hasBashCalls = /Bash\s*\(/.test(section)
  const hasErrorHandling = /\*\*Error handling\*\*:/.test(section)
  if (!hasInputs) issues.push(`Plan convention: "${heading}" has pseudocode but no **Inputs** header`)
  if (!hasOutputs) issues.push(`Plan convention: "${heading}" has pseudocode but no **Outputs** header`)
  if (hasBashCalls && !hasErrorHandling) {
    issues.push(`Plan convention: "${heading}" has Bash() calls but no **Error handling** header`)
  }
}

// 7. Check for undocumented security pattern declarations (R1 enforcement)
const commandFiles = [
  ...Glob("plugins/rune/commands/*.md"),
  ...Glob("plugins/rune/skills/*/SKILL.md")
]
for (const cmdFile of commandFiles) {
  const rawContent = Read(cmdFile)
  const content = rawContent.replace(/```[\s\S]*?```/g, '')
  const lines = content.split('\n')
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (/const\s+(SAFE_|CODEX_\w*ALLOWLIST|BRANCH_RE|FORBIDDEN_KEYS|VALID_EXTRACTORS)/.test(line)) {
      const context = lines.slice(Math.max(0, i - 3), i + 1).join('\n')
      if (!context.includes('security-patterns.md')) {
        issues.push(`Undocumented security pattern at ${cmdFile}:${i + 1} -- missing security-patterns.md reference`)
      }
    }
  }
}

// 8. Plan freshness re-check (Layer 2 — post-forge references)
// Only runs if pre-flight freshness was checked and plan has git_sha
// Security pattern: SAFE_SHA_PATTERN — see security-patterns.md
const SAFE_SHA_PATTERN = /^[0-9a-f]{7,40}$/
// Security pattern: SAFE_FILE_PATH — see security-patterns.md
if (checkpoint?.freshness?.git_sha
    && checkpoint.freshness.sha_reachable
    && SAFE_SHA_PATTERN.test(checkpoint.freshness.git_sha)
    && talisman?.plan?.freshness?.enabled !== false) {
  const enrichedRefs = extractFileReferences(Read(enrichedPlanPath))
    .filter(fp => SAFE_FILE_PATH.test(fp) && !fp.includes('..') && !fp.startsWith('/'))
  const originalPlanRefs = extractFileReferences(Read(checkpoint.plan_file))
    .filter(fp => SAFE_FILE_PATH.test(fp) && !fp.includes('..') && !fp.startsWith('/'))
  const newRefs = enrichedRefs.filter(fp => !originalPlanRefs.includes(fp))
  if (newRefs.length > 0) {
    const sha = checkpoint.freshness.git_sha
    let newDriftCount = 0
    // SEC-002 FIX: derive budget from remaining Phase 2.7 time (30s total) instead of hardcoded 25s
    const phase27Deadline = checkpoint?.phase_start_time
      ? checkpoint.phase_start_time + PHASE_TIMEOUTS.verification
      : Date.now() + 30_000
    const budgetDeadline = Math.min(Date.now() + 25_000, phase27Deadline - 2_000)
    for (const fp of newRefs) {
      if (Date.now() > budgetDeadline) { break }  // budget exhausted — use partial count
      const diff = Bash(`git diff --name-only "${sha}..HEAD" -- "${fp}" 2>/dev/null`)
      if (diff.trim().length > 0) newDriftCount++
    }
    if (newDriftCount > 0) {
      issues.push(`Freshness: ${newDriftCount}/${newRefs.length} forge-expanded file references modified since plan creation`)
    }
  }
}

// Report: Write verification report
const verificationReport = `# Verification Gate Report\n\n` +
  `Status: ${issues.length === 0 ? "PASS" : "WARN"}\n` +
  `Issues: ${issues.length}\n` +
  `Checked at: ${new Date().toISOString()}\n\n` +
  (issues.length > 0 ? issues.map(i => `- ${i}`).join('\n') : 'All checks passed.')
Write(`tmp/arc/${id}/verification-report.md`, verificationReport)

const writtenReport = Read(`tmp/arc/${id}/verification-report.md`)
updateCheckpoint({
  phase: "verification",
  status: "completed",
  artifact: `tmp/arc/${id}/verification-report.md`,
  artifact_hash: sha256(writtenReport),
  phase_sequence: 4,
  team_name: null
})
```

**Output**: `tmp/arc/{id}/verification-report.md`

**Failure policy**: Non-blocking -- proceed with warnings. Log issues but do not halt. Verification is informational.
