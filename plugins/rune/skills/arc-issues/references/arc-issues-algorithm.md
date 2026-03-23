# arc-issues Algorithm Reference

Full pseudocode for the `/rune:arc-issues` skill orchestration.

## Security Constants

```javascript
// SEC-DECREE-003: Disable gh interactive prompts in all automation contexts
const GH_ENV = 'GH_PROMPT_DISABLED=1'

// All 4 Rune status labels excluded from issue fetch queries
// RUNE_STATUS_EXCLUSION: Skip issues already marked by Rune
const RUNE_LABEL_EXCLUSION = '-label:rune:in-progress -label:rune:done -label:rune:failed -label:rune:needs-review'
```

## Helper Functions

```javascript
// Parse a raw issue reference line (URL, #N shorthand, or bare number)
function parseIssueRef(line) {
  // Full GitHub URL: https://github.com/owner/repo/issues/42
  const urlMatch = line.match(/github\.com\/([^/]+)\/([^/]+)\/issues\/(\d+)/)
  if (urlMatch) return { owner: urlMatch[1], repo: urlMatch[2], number: parseInt(urlMatch[3]) }

  // Shorthand: #42 or bare 42 (max 7 digits for safety)
  const numMatch = line.match(/^#?(\d{1,7})$/)
  if (numMatch) return { owner: null, repo: null, number: parseInt(numMatch[1]) }

  return null  // Invalid line — skip with warning
}

// Title sanitization: blocklist approach — preserve Unicode, strip shell-dangerous chars only
// NOT ASCII-only regex (would break Vietnamese, Chinese, Japanese, etc.)
function sanitizeTitle(rawTitle) {
  return (rawTitle || '')
    .replace(/[\x00-\x1F\x7F]/g, '')          // Strip control characters
    .replace(/[`$\\{}|;<>&"']/g, '')           // Strip shell-dangerous chars only
    .replace(/<\/?[^>]+>/g, '')                // Strip HTML tags
    .slice(0, 100)
}

// URL-safe slug from sanitized title
function slugify(title) {
  return title
    .toLowerCase()
    .replace(/\s+/g, '-')
    .replace(/[^a-z0-9-]/g, '')
    .replace(/-+/g, '-')
    .slice(0, 40)
}

// Format duration as Xh Ym
function formatDuration(startedAt, endedAt) {
  const ms = new Date(endedAt).getTime() - new Date(startedAt).getTime()
  const h = Math.floor(ms / 3600000)
  const m = Math.floor((ms % 3600000) / 60000)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

// Today's date as YYYY-MM-DD
function today() {
  return new Date().toISOString().slice(0, 10)
}

// Extract acceptance criteria from issue body
// CC-5: Defense-in-depth — always sanitize input even if caller pre-sanitized
function extractAcceptanceCriteria(inputBody) {
  // Defense-in-depth: strip injection vectors even if caller sanitized
  const body = (inputBody || '')
    .replace(/[\x00-\x1F\x7F]/g, '')
    .replace(/<\/?acceptance-criteria[^>]*>/gi, '')
    .replace(/<\/?issue-content[^>]*>/gi, '')

  if (!body.trim()) return '- [ ] Implement feature as described in issue'

  // Look for existing checkboxes in issue body
  const checkboxes = body.match(/^[\s]*[-*]\s*\[[ x]\]\s*.+$/gm)
  if (checkboxes && checkboxes.length > 0) {
    return checkboxes.map(cb => cb.trim()).join('\n')
  }

  // Look for "Acceptance Criteria" section
  const acMatch = body.match(/#+\s*acceptance\s*criteria[\s\S]*?(?=\n#|\n---|\Z)/i)
  if (acMatch) {
    return acMatch[0].replace(/#+\s*acceptance\s*criteria\s*/i, '').trim()
  }

  // Fallback: extract bullet points (max 10)
  const bullets = body.match(/^[\s]*[-*]\s+.+$/gm)
  if (bullets && bullets.length > 0) {
    return bullets.slice(0, 10).map(b => `- [ ] ${b.replace(/^[\s]*[-*]\s+/, '')}`).join('\n')
  }

  return '- [ ] Implement feature as described in issue'
}
```

## Phase 0: Parse Arguments

```javascript
const args = "$ARGUMENTS".trim()

// Detect flags
const flags = {
  label:         args.match(/--label\s+["']?([^"'\s]+)["']?/)?.[1] || null,
  all:           args.includes('--all'),
  pageSize:      parseInt(args.match(/--page-size\s+(\d+)/)?.[1] || '10'),
  limit:         parseInt(args.match(/--limit\s+(\d+)/)?.[1] || '20'),
  milestone:     args.match(/--milestone\s+["']?([^"'\s]+)["']?/)?.[1] || null,
  noMerge:       args.includes('--no-merge'),
  dryRun:        args.includes('--dry-run'),
  force:         args.includes('--force'),
  resume:        args.includes('--resume'),
  cleanupLabels: args.includes('--cleanup-labels')
}

// Strip all flags to get positional args
const positionalArgs = args
  .replace(/--label\s+["']?[^"'\s]+["']?/g, '')
  .replace(/--page-size\s+\d+/g, '')
  .replace(/--limit\s+\d+/g, '')
  .replace(/--milestone\s+["']?[^"'\s]+["']?/g, '')
  .replace(/--\S+/g, '')
  .trim()

let inputMethod = null  // 'label' | 'file' | 'inline' | 'resume' | 'cleanup'
let issueRefs = []      // Array of { owner, repo, number }

// -- Method E: Cleanup Orphaned Labels --
if (flags.cleanupLabels) {
  inputMethod = 'cleanup'
  // See "Cleanup Mode" section below
}

// -- Method D: Resume --
else if (flags.resume) {
  // ── RESUME GUARD: Validate session ownership before proceeding ──
  // Mirrors rune:arc Decision Matrix 2 (R1-R5) from arc-resume.md
  const CHOME = Bash('echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"').trim()
  const currentPid = Bash('echo $PPID').trim()
  const stateFile = Read('.rune/arc-issues-loop.local.md')

  // R1: No state file → check progress file fallback
  if (!stateFile) {
    const progressExists = Read('tmp/gh-issues/batch-progress.json')
    if (!progressExists) {
      error('No issues state or progress file found. Cannot resume.')
      error('Start a new batch instead of resuming.')
      return
    }
    warn('State file missing but progress file exists. Proceeding with fresh ownership claim.')
  } else {
    const storedCfg = stateFile.match(/config_dir:\s*(.+)/)?.[1]?.trim()
    const storedPid = stateFile.match(/owner_pid:\s*(\d+)/)?.[1]

    // R5: config_dir mismatch → HARD BLOCK
    if (storedCfg && storedCfg !== CHOME) {
      error(`Cannot resume: issues batch belongs to different config dir`)
      error(`  Stored:  ${storedCfg}`)
      error(`  Current: ${CHOME}`)
      error(`Delete .rune/arc-issues-loop.local.md manually to force-claim, or use the original CLAUDE_CONFIG_DIR.`)
      return
    }

    // R2/R3: Check PID ownership
    // SEC-1: Numeric PID guard before kill -0 interpolation
    if (storedPid && /^\d+$/.test(storedPid) && storedPid !== currentPid) {
      const alive = Bash(`kill -0 ${storedPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
      if (alive === 'alive') {
        // R3: Another session is actively running this batch
        error(`Cannot resume: issues batch is owned by live PID ${storedPid} (current: ${currentPid})`)
        error(`Cancel it first with /rune:cancel-arc-issues, or wait for it to finish.`)
        return
      }
      // R4: Dead PID → safe to claim (orphan recovery)
      warn(`Previous issues batch owner (PID ${storedPid}) is dead. Claiming ownership for resume.`)
    }

    // ── TRANSIENT STATE RESET (G3 race mitigation) ──
    // compact_pending and max_iterations are handled by Phase 6 state file rewrite.
    // Dispatch counts are per-child-arc, cleaned by child rune:arc's STSM-005.
    // Quick-patch: reset compact_pending before Phase 6 rewrites to prevent
    // stop hook race if it fires between ownership claim and Phase 6.
    const patchedState = stateFile.replace(/compact_pending:\s*true/, 'compact_pending: false')
    if (patchedState !== stateFile) {
      Write('.rune/arc-issues-loop.local.md', patchedState)
      warn('Reset stale compact_pending in state file.')
    }
  }

  // ── PROGRESS FILE VALIDATION (EC-3, EC-7) ──
  inputMethod = 'resume'
  const progressPath = 'tmp/gh-issues/batch-progress.json'
  const progressContent = Read(progressPath)

  if (!progressContent) {
    error(`Progress file not found at ${progressPath}`)
    error('The tmp/ directory may have been deleted. Cannot resume without progress tracking.')
    error('Start a new batch instead of resuming.')
    return
  }

  let progress
  try {
    progress = JSON.parse(progressContent)
  } catch (e) {
    error(`Progress file is corrupt (invalid JSON): ${e.message}`)
    error(`File: ${progressPath}`)
    error('Delete the file and start a new batch, or fix the JSON manually.')
    return
  }

  if (!progress.plans || !Array.isArray(progress.plans)) {
    error('Progress file has invalid structure (missing plans array).')
    return
  }

  // Filter to pending issues only — don't re-execute completed
  const pendingPlans = progress.plans.filter(p => p.status === 'pending')
  if (pendingPlans.length === 0) {
    log('All issues already completed. Nothing to resume.')
    return
  }
  issueRefs = pendingPlans.map(p => ({ owner: null, repo: null, number: p.number }))
  log(`Resuming: ${progress.plans.filter(p => p.status === 'completed').length}/${progress.plans.length} completed, ${issueRefs.length} remaining`)
}

// -- Method A: Label-Driven (primary) --
else if (flags.label) {
  inputMethod = 'label'
  if (flags.all) {
    // Paging loop — handled in Phase 0 paging section below
    inputMethod = 'label-all'
  }
}

// -- Method B: File-Based --
else if (positionalArgs.endsWith('.txt') || positionalArgs.endsWith('.md')) {
  inputMethod = 'file'
  const lines = Read(positionalArgs).split('\n')
  for (const rawLine of lines) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue  // skip blanks and comments
    const ref = parseIssueRef(line)
    if (ref) {
      issueRefs.push(ref)
    } else {
      warn(`Skipping invalid line: ${line}`)
    }
  }
}

// -- Method C: Inline Args --
else if (positionalArgs.trim()) {
  inputMethod = 'inline'
  const parts = positionalArgs.trim().split(/\s+/)
  for (const part of parts) {
    const ref = parseIssueRef(part)
    if (ref) {
      issueRefs.push(ref)
    } else {
      warn(`Skipping invalid argument: ${part}`)
    }
  }
}

else {
  error('Usage: /rune:arc-issues --label LABEL | file.txt | #N ... | --resume')
  error('See /rune:arc-issues --help or the skill description for full options.')
  return
}
```

### Label-Driven: Single Batch

```javascript
if (inputMethod === 'label') {
  const rawIssues = JSON.parse(Bash(`${GH_ENV} gh issue list \
    --label "${flags.label}" \
    --search "${RUNE_LABEL_EXCLUSION}" \
    ${flags.milestone ? `--milestone "${flags.milestone}"` : ''} \
    --state open \
    --limit ${flags.limit} \
    --sort created --order asc \
    --json number,title,body,labels,assignees,milestone \
    --jq '.[] | {number, title, body: .body, labels: [(.labels // [])[] | .name]}'`))

  issueRefs = rawIssues.map(i => ({ owner: null, repo: null, number: i.number, _raw: i }))
}
```

### Label-Driven: Paging Loop (`--all` mode)

```javascript
if (inputMethod === 'label-all') {
  const PAGE_SIZE = flags.pageSize
  const MAX_PAGES = 50  // Safety cap: 50 pages × PAGE_SIZE = up to 500 issues max
  let pageNum = 0
  let allIssueRefs = []

  while (pageNum < MAX_PAGES) {
    pageNum++

    const pageIssues = JSON.parse(Bash(`${GH_ENV} gh issue list \
      --label "${flags.label}" \
      --search "${RUNE_LABEL_EXCLUSION}" \
      ${flags.milestone ? `--milestone "${flags.milestone}"` : ''} \
      --state open \
      --limit ${PAGE_SIZE} \
      --sort created --order asc \
      --json number,title,body,labels`))

    if (pageIssues.length === 0) {
      log(`All matching issues fetched. Total: ${allIssueRefs.length} issues across ${pageNum - 1} pages.`)
      break
    }

    // CC-6: Cost gate — capture response and branch on Cancel
    if (pageNum === 1) {
      // Peek total count (cheap — count only, no body)
      const totalOpen = parseInt(Bash(`${GH_ENV} gh issue list \
        --label "${flags.label}" \
        --search "${RUNE_LABEL_EXCLUSION}" \
        --state open --limit 1 \
        --json number --jq 'length'`) || '0')

      if (totalOpen > 10) {
        const estCost = totalOpen * 8
        const estHours = Math.round(totalOpen * 45 / 60)
        const userChoice = AskUserQuestion({
          question: `Found ~${totalOpen} unprocessed issues (~$${estCost}, ~${estHours}h). Process all in pages of ${PAGE_SIZE}?`,
          options: [
            { label: `Process all (~${totalOpen})`, description: `Pages of ${PAGE_SIZE}, estimated ~${estHours}h` },
            { label: `First page only (${PAGE_SIZE})`, description: 'Process one page, re-run for more' },
            { label: 'Cancel', description: 'Exit without processing' }
          ]
        })
        // CC-6: Branch on user response
        if (userChoice?.label === 'Cancel' || userChoice?.includes?.('Cancel')) {
          log('Cancelled by user.')
          return
        }
        if (userChoice?.label?.startsWith('First page') || userChoice?.includes?.('First page')) {
          // Process first page only, then stop
          allIssueRefs.push(...pageIssues.map(i => ({ owner: null, repo: null, number: i.number, _raw: i })))
          break
        }
        // Otherwise: process all — continue loop
      }
    }

    log(`\n--- Page ${pageNum}: fetched ${pageIssues.length} issues ---`)
    allIssueRefs.push(...pageIssues.map(i => ({ owner: null, repo: null, number: i.number, _raw: i })))
  }

  if (pageNum >= MAX_PAGES) {
    warn(`Safety cap reached: ${MAX_PAGES} pages. Re-run to process remaining issues.`)
  }

  issueRefs = allIssueRefs
}
```

### Cleanup Mode

```javascript
if (inputMethod === 'cleanup') {
  log('Sweeping orphaned rune:in-progress labels (older than 2 hours)...')

  const inProgressRaw = Bash(`${GH_ENV} gh issue list --label "rune:in-progress" \
    --state open --json number,updatedAt --jq '.[]'`)

  for (const issue of JSON.parse(`[${inProgressRaw}]`)) {
    const age = Date.now() - new Date(issue.updatedAt).getTime()
    if (age > 2 * 60 * 60 * 1000) {  // > 2 hours
      Bash(`${GH_ENV} gh issue edit ${issue.number} --remove-label "rune:in-progress" 2>/dev/null || true`)
      warn(`Cleaned orphaned label from #${issue.number} (stale ${Math.round(age / 3600000)}h)`)
    }
  }

  log('Cleanup complete.')
  return
}
```

### Dedup Logic

```javascript
// Dedup by issue number (retain first occurrence)
const seen = new Set()
issueRefs = issueRefs.filter(ref => {
  if (seen.has(ref.number)) {
    warn(`Duplicate issue #${ref.number} — skipping`)
    return false
  }
  seen.add(ref.number)
  return true
})

if (issueRefs.length === 0) {
  log('No issues to process.')
  return
}
```

## Phase 1: Pre-flight Validation

```javascript
Bash('mkdir -p tmp/gh-issues tmp/gh-plans')

// Write issue numbers to temp file (avoid shell injection from inline args)
const preflight_input = issueRefs.map(r => r.number).join('\n')
Write('tmp/gh-issues/preflight-input.txt', preflight_input)

const validated = Bash(`"${CLAUDE_PLUGIN_ROOT}/scripts/arc-issues-preflight.sh" < "tmp/gh-issues/preflight-input.txt"`)
if (validated.exitCode !== 0) {
  error('Pre-flight validation failed. Fix errors above and retry.')
  return
}

// Parse validated issue numbers (script outputs JSON object: { ok: bool, valid: number[] })
const result = JSON.parse(validated.trim())
if (!result.ok) {
  error('Pre-flight validation returned not-ok. Fix errors above and retry.')
  return
}
const validatedNumbers = result.valid
issueRefs = issueRefs.filter(r => validatedNumbers.includes(r.number))
```

## Phase 2: Issue → Plan Generation

For each issue, fetch full content from GitHub, sanitize, and generate a plan file.

```javascript
const validatedIssues = []  // enriched with fetched data

for (const ref of issueRefs) {
  const issueNum = ref.number

  // 1. Fetch full issue content and cache as JSON
  const issueJson = Bash(`${GH_ENV} gh issue view ${issueNum} \
    --json number,title,body,url,labels,assignees,milestone,comments`)

  if (!issueJson || issueJson.trim() === '') {
    warn(`Issue #${issueNum}: failed to fetch. Skipping.`)
    continue
  }

  Write(`tmp/gh-issues/issue-${issueNum}.json`, issueJson)
  const issueData = JSON.parse(issueJson)

  // SEC-003: Claim lock — immediately label as in-progress to prevent concurrent
  // session conflicts (TOCTOU race). Another session fetching the same issue will
  // see the rune:in-progress label and skip it via RUNE_LABEL_EXCLUSION.
  Bash(`${GH_ENV} gh issue edit ${issueNum} --add-label "rune:in-progress" 2>/dev/null || true`)

  // 2. Resolve canonical GitHub issue URL
  const issueUrl = issueData.url
    || `https://github.com/${issueData.owner || 'owner'}/${issueData.repo || 'repo'}/issues/${issueNum}`

  // 3. Sanitize issue body using codebase standard sanitizer
  // sanitizeUntrustedText() is defined in security-patterns.md — handles 8 attack vectors
  // See plugins/rune/skills/roundtable-circle/references/security-patterns.md
  // <!-- KNOWN-LIMITATION: sanitizeUntrustedText is pseudocode, not enforced at runtime.
  //    This algorithm is a reference document — the actual sanitization depends on Claude
  //    following these instructions. Consider implementing as a deterministic shell script
  //    (e.g., scripts/sanitize-issue-body.sh) for defense-in-depth. -->
  const safeBody = sanitizeUntrustedText(issueData.body || '', 4000)
    .replace(/<\/?issue-content[^>]*>/gi, '')           // Strip wrapper-breaking tags
    .replace(/<\/?acceptance-criteria[^>]*>/gi, '')     // Strip AC wrapper tags

  // 4. Plan quality gate — warn on vague issues
  const textLength = safeBody.replace(/!\[.*?\]\(.*?\)/g, '').trim().length
  if (textLength < 50) {
    warn(`Issue #${issueNum}: body is very short (${textLength} chars). Plan may be too vague.`)
    if (!flags.force) {
      // Post GitHub comment and label as needs-review
      const commentBody = `## Plan Generation — Needs Human Input

This issue was processed by \`/rune:arc-issues\` but skipped because the description is too brief for automated plan generation.

**Action needed**: Add more detail to the issue body (acceptance criteria, technical context, expected behavior) then re-run \`/rune:arc-issues\`.

_Generated by Rune Plugin (/rune:arc-issues) — plan quality gate_`

      const commentFile = Bash('mktemp').trim()
      Write(commentFile, commentBody)
      Bash(`${GH_ENV} gh issue comment "${issueNum}" --body-file "${commentFile}" 2>/dev/null || true`)
      Bash(`rm -f "${commentFile}"`)
      Bash(`${GH_ENV} gh issue edit "${issueNum}" --add-label "rune:needs-review" 2>/dev/null || true`)

      validatedIssues.push({
        ...ref,
        title: issueData.title || '',
        status: 'skipped',
        error: 'Body too short for meaningful plan generation (use --force to override)'
      })
      continue
    }
  }

  // 5. Extract Figma URLs from sanitized issue body
  // SYNC: figma-url-pattern — shared with devise/references/design-signal-detection.md line 9
  const FIGMA_URL_PATTERN = /https?:\/\/[^\s]*figma\.com\/[^\s]+/g
  const FIGMA_DOMAIN_PATTERN = /^https:\/\/(www\.)?figma\.com\//

  const miscConfig = readTalismanSection("misc") || {}
  const maxFigmaUrls = miscConfig.design_sync?.max_figma_urls ?? 10

  // Strip code blocks BEFORE scanning (prevent false positives from code examples)
  const bodyWithoutCodeBlocks = safeBody.replace(/```[\s\S]*?```/g, '').replace(/`[^`]+`/g, '')

  const figmaUrls = [...new Set(  // Dedup identical URLs
    (bodyWithoutCodeBlocks.match(FIGMA_URL_PATTERN) || [])
      .map(url => url.replace(/[\r\n)>\]|"]/g, ''))  // Strip newlines + trailing markdown chars
      .map(url => url.replace(/&amp;/g, '&'))         // Decode HTML entities in query params
      .filter(url => FIGMA_DOMAIN_PATTERN.test(url))  // SSRF: domain whitelist
  )].slice(0, maxFigmaUrls)                           // Cap URL count
  const figmaUrl = figmaUrls.length > 0 ? figmaUrls[0] : null
  const hasDesignReference = figmaUrl !== null

  // Observability: log extraction result
  if (hasDesignReference) {
    log(`  Figma URL(s) detected in issue body: ${figmaUrls.length} URL(s) extracted`)
  } else {
    log(`  No Figma URLs found in issue #${issueNum} body`)
  }

  // 5.5. Design system & UI builder discovery (conditional)
  // Only when Figma URLs detected AND design_sync enabled
  let designSystemProfile = null
  let uiBuilderInfo = null

  if (hasDesignReference) {
    const designSyncEnabled = miscConfig.design_sync?.enabled === true
    if (designSyncEnabled) {
      // Design system discovery (scans repo for component libraries)
      try {
        const repoRoot = Bash('git rev-parse --show-toplevel 2>/dev/null || pwd').trim()
        designSystemProfile = discoverDesignSystem(repoRoot)
        if (designSystemProfile && designSystemProfile.confidence >= 0.50) {
          log(`  Design system detected: ${designSystemProfile.library || 'custom'} (confidence: ${designSystemProfile.confidence})`)
        } else {
          designSystemProfile = null  // Below confidence threshold
        }
      } catch (e) {
        warn(`  Design system discovery failed: ${e.message}`)
      }

      // UI builder discovery (detects MCP servers like UntitledUI)
      try {
        uiBuilderInfo = discoverUIBuilder()
        if (uiBuilderInfo) {
          log(`  UI builder detected: ${uiBuilderInfo.builder_mcp} (source: ${uiBuilderInfo.source})`)
        }
      } catch (e) {
        // Builder detection failed — proceed without (non-blocking)
      }
    }
  }

  // 6. Title sanitization (blocklist approach — preserve Unicode)
  const safeTitle = sanitizeTitle(issueData.title || '')
  if (!safeTitle.trim()) {
    warn(`Issue #${issueNum}: title is empty after sanitization. Using fallback.`)
  }
  const displayTitle = safeTitle.trim() || `Issue ${issueNum}`

  // 7. Generate plan file path
  const planSlug = `issue-${issueNum}-${slugify(displayTitle)}`
  const planPath = `tmp/gh-plans/${today()}-${planSlug}-plan.md`

  // 7. Determine plan type from labels
  const labels = issueData.labels?.map(l => l.name || l) || []
  const isBug = labels.some(l => l === 'bug' || l === 'fix')
  const planType = isBug ? 'fix' : 'feat'

  // 8. Build plan content with stub sections for forge enrichment
  const planContent = `---
title: "${planType}: ${displayTitle}"
type: ${planType}
date: ${today()}
source_issue: ${issueNum}
source_url: "${issueUrl}"
source_repo: "${ref.owner ? `${ref.owner}/${ref.repo}` : 'current'}"
complexity: "Medium"
estimated_effort: "M"
${figmaUrls.length > 0 ? `figma_urls:\n${figmaUrls.map(url => `  - "${url.replace(/"/g, '').replace(/\\/g, '')}"`).join('\n')}` : ''}
${hasDesignReference ? `design_sync: true` : ''}
${designSystemProfile ? `design_system:\n  library: "${designSystemProfile.library || 'custom'}"\n  version: "${designSystemProfile.version || 'unknown'}"\n  confidence: ${designSystemProfile.confidence}` : ''}
${uiBuilderInfo ? `ui_builder:\n  builder_mcp: "${uiBuilderInfo.builder_mcp}"\n  source: "${uiBuilderInfo.source}"\n  companion_skill: "${uiBuilderInfo.companion_skill || ''}"` : ''}
---

# ${displayTitle}

> **GitHub Issue**: [#${issueNum}](${issueUrl})

## Overview

Implementing GitHub Issue [#${issueNum}](${issueUrl}).

## Problem Statement

${safeBody}

${hasDesignReference ? `
## Design References

${figmaUrls.map((url, i) => `- **Figma Design ${i + 1}**: [${url}](${url})`).join('\n')}

> _Design URLs auto-extracted from GitHub Issue #${issueNum}. Enable \`design_sync.enabled: true\` in talisman.yml to activate Arc design extraction phases._

${designSystemProfile ? `
## Design System Context

- **Library**: ${designSystemProfile.library || 'custom'} ${designSystemProfile.version || ''}
- **Token system**: ${designSystemProfile.token_system || 'unknown'}
- **Variant system**: ${designSystemProfile.variant_system || 'unknown'}
${uiBuilderInfo ? `- **UI Builder MCP**: ${uiBuilderInfo.builder_mcp} (companion skill: ${uiBuilderInfo.companion_skill || 'none'})` : ''}
- **Confidence**: ${designSystemProfile.confidence}

> _Auto-discovered from repository. Workers should use \`${uiBuilderInfo?.builder_mcp || 'figma_to_react'}\` MCP tools for component matching._
` : ''}
` : ''}
## Acceptance Criteria

<acceptance-criteria type="DATA">
${extractAcceptanceCriteria(safeBody)}
</acceptance-criteria>

## Technical Approach

<!-- Stub for forge enrichment — agents will analyze codebase for relevant patterns -->
To be determined based on codebase analysis.

## Implementation Considerations

<!-- Stub for forge enrichment — agents will identify risks and dependencies -->
See issue context below for labels and milestone.

## Dependencies & Risks

<!-- Stub for forge enrichment — agents will assess blast radius -->
| Risk | Severity | Mitigation |
|------|----------|------------|
| TBD  | TBD      | TBD        |

## Context

- **Source Issue**: [#${issueNum} — ${issueData.title || displayTitle}](${issueUrl})
- Labels: ${labels.join(', ') || 'none'}
- Milestone: ${issueData.milestone?.title || 'none'}
- Assignees: ${issueData.assignees?.map(a => a.login || a).join(', ') || 'none'}

## References

- GitHub Issue: [#${issueNum}](${issueUrl})
`

  Write(planPath, planContent)

  validatedIssues.push({
    ...ref,
    title: displayTitle,
    labels,
    planPath,
    issueUrl,
    figmaUrls,
    figmaUrl,
    status: 'pending'
  })

  log(`  Generated plan: ${planPath}`)
}

// Filter out skipped issues from the run queue
const issuesForArc = validatedIssues.filter(i => i.status !== 'skipped')

if (issuesForArc.length === 0) {
  log('No issues to process after quality gate. Use --force to process all issues.')
  return
}
```

## Phase 3: Dry Run

```javascript
if (flags.dryRun) {
  log('\nDry run — issues that would be processed:\n')
  for (const issue of validatedIssues) {
    const status = issue.status === 'skipped' ? ' [SKIPPED — body too short]' : ''
    log(`  #${issue.number}: ${issue.title} [${issue.labels?.join(', ') || 'no labels'}]${status}`)
    if (issue.planPath) {
      log(`    Plan: ${issue.planPath}`)
    }
  }
  log(`\nDry run complete. ${issuesForArc.length} issues would be processed.`)
  if (validatedIssues.length > issuesForArc.length) {
    log(`${validatedIssues.length - issuesForArc.length} issue(s) would be skipped (body too short — use --force).`)
  }
  return
}
```

## Phase 4: Initialize Progress File

```javascript
const progressFile = 'tmp/gh-issues/batch-progress.json'

if (!flags.resume) {
  Bash('mkdir -p tmp/gh-issues tmp/gh-plans')
  Write(progressFile, JSON.stringify({
    schema_version: 2,
    status: 'running',
    started_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    total_plans: issuesForArc.length,
    repo: Bash('git remote get-url origin 2>/dev/null | sed "s/.*github.com[:/]//;s/\\.git$//"').trim() || 'current',
    plans: issuesForArc.map(issue => ({
      number: issue.number,
      title: issue.title,
      source_url: issue.issueUrl || '',
      path: issue.planPath,        // CC-1: use 'path' not 'plan_path'
      status: 'pending',
      pr_created: false,           // CC-8: intermediate status for crash-resume dedup
      error: null,
      started_at: null,
      completed_at: null,
      arc_session_id: null,
      pr_url: null,
      comment_posted: false,
      label_updated: false
    }))
  }, null, 2))
}
```

## Phase 5: Confirm Batch with User

```javascript
// Cost estimate
const estimatedMinutes = issuesForArc.length * 45
const estimatedCost = issuesForArc.length * 8

if (issuesForArc.length > 10) {
  warn(`Batch estimate: ${issuesForArc.length} issues, ~${estimatedMinutes} min, ~$${estimatedCost}`)
  AskUserQuestion({
    question: `Processing ${issuesForArc.length} issues (~$${estimatedCost}, ~${Math.round(estimatedMinutes / 60)}h). Continue?`,
    options: [
      { label: 'Start batch', description: `Process ${issuesForArc.length} issues sequentially with arc` },
      { label: 'Cancel', description: 'Abort' }
    ]
  })
} else {
  AskUserQuestion({
    question: `Start arc-issues for ${issuesForArc.length} issue(s)? Estimated ~${estimatedMinutes} min.`,
    options: [
      { label: 'Start', description: `Process ${issuesForArc.length} issues` },
      { label: 'Cancel', description: 'Abort' }
    ]
  })
}
```

## Phase 6: Start Batch Loop (Stop Hook Pattern)

```javascript
const pluginDir = Bash(`echo "${CLAUDE_PLUGIN_ROOT}"`).trim()
const issueListFile = 'tmp/gh-issues/issue-list.json'
Write(issueListFile, JSON.stringify(issuesForArc.map(i => ({
  number: i.number,
  title: i.title,
  path: i.planPath,      // CC-1: use 'path'
  source_url: i.issueUrl
})), null, 2))

// Resolve session identity for cross-session isolation
// Two isolation layers: config_dir (installation) + owner_pid (session)
const configDir = Bash(`cd "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

// Pre-creation guard: check for active batch from another session
const existingState = Read('.rune/arc-issues-loop.local.md')
if (existingState && existingState.includes('active: true')) {
  const existingPid = existingState.match(/owner_pid:\s*(\d+)/)?.[1]
  const existingCfg = existingState.match(/config_dir:\s*(.+)/)?.[1]?.trim()

  let ownedByOther = false
  if (existingCfg && existingCfg !== configDir) {
    ownedByOther = true
  }
  if (!ownedByOther && existingPid && /^\d+$/.test(existingPid) && existingPid !== ownerPid) {
    const alive = Bash(`kill -0 ${existingPid} 2>/dev/null && echo "alive" || echo "dead"`).trim()
    if (alive === 'alive') {
      ownedByOther = true
    }
  }

  if (ownedByOther) {
    error('Another session is already running arc-issues on this repo.')
    error('Cancel it first with /rune:cancel-arc-issues, or wait for it to finish.')
    return
  }
  warn('Found orphaned arc-issues state file (previous session crashed). Overwriting.')
}

// readTalismanSection: "arc"
const arc = readTalismanSection("arc")
const batchConfig = arc?.batch || {}
const autoMerge = flags.noMerge ? false : (batchConfig.auto_merge ?? true)
const summaryEnabled = batchConfig?.summaries?.enabled !== false  // default: true

// Write state file for Stop hook
Write('.rune/arc-issues-loop.local.md', `---
active: true
iteration: 1
total_plans: ${issuesForArc.length}
max_iterations: ${issuesForArc.length}
no_merge: ${!autoMerge}
plugin_dir: ${pluginDir}
config_dir: ${configDir}
owner_pid: ${ownerPid}
session_id: ${CLAUDE_SESSION_ID || Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'}
issues_file: ${issueListFile}
progress_file: ${progressFile}
summary_enabled: ${summaryEnabled}
summary_dir: tmp/gh-issues/summaries
started_at: "${new Date().toISOString()}"
---

Arc issues loop state. Do not edit manually.
Use /rune:cancel-arc-issues to stop the batch loop.
`)

// Label first issue as in-progress
const firstIssue = issuesForArc[0]
Bash(`${GH_ENV} gh issue edit ${firstIssue.number} --add-label "rune:in-progress" 2>/dev/null || true`)

// Mark first plan as in_progress in progress file
const progress = JSON.parse(Read(progressFile))
const firstPlanEntry = progress.plans.find(p => p.number === firstIssue.number)
if (firstPlanEntry) {
  firstPlanEntry.status = 'in_progress'
  firstPlanEntry.started_at = new Date().toISOString()
  progress.updated_at = new Date().toISOString()
  Write(progressFile, JSON.stringify(progress, null, 2))
}

// Invoke arc for first issue
// NOTE: GH API actions (comment, label updates) for completed issues are handled
// at the BEGINNING of the next arc turn (CC-2/BACK-008) to avoid Stop hook 15s timeout
// ARC-BATCH-001 FIX: Use "rune:arc" prefix for reliable plugin skill resolution.
const mergeFlag = !autoMerge ? ' --no-merge' : ''
Skill('rune:arc', `${firstIssue.planPath} --skip-freshness --accept-external${mergeFlag}`)

// CRITICAL — SKILL INVOCATION REQUIRED:
// - /rune:arc is a SKILL. You MUST call it via the Skill tool.
// - DO NOT implement the plan code directly. DO NOT skip to coding.
// - Only the arc skill should orchestrate execution.

// After the first arc completes, Claude's response ends.
// The Stop hook fires, reads .rune/arc-issues-loop.local.md,
// posts GitHub comment for completed issue, updates labels,
// marks it done in batch-progress.json, finds next issue,
// and re-injects the arc prompt. This repeats until all done.
```

## Final Summary (injected by Stop hook after last issue)

```javascript
const progress = JSON.parse(Read('tmp/gh-issues/batch-progress.json'))
const completed = progress.plans.filter(p => p.status === 'completed')
const failed = progress.plans.filter(p => p.status === 'failed')
const skipped = progress.plans.filter(p => p.status === 'skipped')
const needsReview = progress.plans.filter(p => p.status === 'needs_review')
const now = new Date().toISOString()

const summary = `
## /rune:arc-issues — Batch Complete

| Metric | Value |
|--------|-------|
| Total issues | ${progress.total_plans} |
| Completed | ${completed.length} |
| Failed | ${failed.length} |
| Skipped (quality gate) | ${skipped.length} |
| Needs human review | ${needsReview.length} |
| Duration | ${formatDuration(progress.started_at, now)} |

### Completed Issues
${completed.map(p => `- [#${p.number}](${p.source_url}): ${p.title} → [PR](${p.pr_url || '(pending)'})`).join('\n')}

${failed.length > 0 ? `### Failed Issues (commented on GitHub)\n${failed.map(p => `- [#${p.number}](${p.source_url}): ${p.title} — ${p.error}`).join('\n')}` : ''}

${skipped.length > 0 ? `### Skipped Issues (needs more detail)\n${skipped.map(p => `- [#${p.number}](${p.source_url}): ${p.title}`).join('\n')}` : ''}

${needsReview.length > 0 ? `### Needs Human Review (commented on GitHub)\n${needsReview.map(p => `- [#${p.number}](${p.source_url}): ${p.title}`).join('\n')}` : ''}
`

// Add rune:done label to completed issues
for (const plan of progress.plans) {
  if (plan.status === 'completed') {
    Bash(`${GH_ENV} gh issue edit ${plan.number} --add-label "rune:done" --remove-label "rune:in-progress" 2>/dev/null || true`)
  }
}
```

## Progress File Schema (v2)

```json
{
  "schema_version": 2,
  "status": "running | completed | failed",
  "started_at": "ISO8601",
  "updated_at": "ISO8601",
  "total_plans": 3,
  "repo": "owner/repo",
  "plans": [
    {
      "number": 42,
      "title": "Add user authentication",
      "source_url": "https://github.com/owner/repo/issues/42",
      "path": "tmp/gh-plans/2026-02-24-issue-42-add-user-auth-plan.md",
      "status": "pending | in_progress | completed | failed | skipped | needs_review",
      "pr_created": false,
      "error": null,
      "started_at": null,
      "completed_at": null,
      "arc_session_id": null,
      "pr_url": null,
      "comment_posted": false,
      "label_updated": false
    }
  ]
}
```

**CC-1 Schema corrections** (aligned with arc-batch):
- `total_plans` (not `total_issues`)
- `plans[]` array (not `issues[]`)
- `path` field (not `plan_path`)
- `max_iterations` in state file (equals `total_plans`)
- `schema_version: 2` (distinguishes arc-issues from arc-batch v1)

**QUAL-009 Schema version disambiguation**: `arc-issues` uses `schema_version: 2` while `arc-batch` uses `schema_version: 1`. Both share the same `batch-progress.json` file structure and field names (plans[], path, total_plans), but the schema version allows consumers (stop hooks, resume logic, reporting) to distinguish which skill generated the progress file and apply the correct parsing rules. When reading a progress file, always check `schema_version` before assuming field semantics.

**CC-8 `pr_created` field**: Intermediate status for crash-resume dedup. If arc completes SHIP phase (PR created) then crashes before updating progress, resume detects `pr_created: true` and skips re-running arc (avoiding duplicate PRs).
