---
name: post-findings
description: |
  Post Rune review findings to a GitHub PR as a formatted comment.
  Parses TOME.md findings, formats as collapsible markdown, posts via gh api.
  Use after /rune:appraise or /rune:arc to share findings with team.
  Trigger keywords: post findings, PR comments, share review, post to PR,
  post review to GitHub, comment on PR with findings, share findings.
user-invocable: true
disable-model-invocation: false
argument-hint: "[TOME path] [PR#] [--dry-run] [--force]"
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:post-findings -- Post Review Findings to GitHub PR

Post structured review findings from a TOME file to a GitHub PR as a formatted, collapsible markdown comment. Supports auto-detection of TOME path and PR number, talisman-based filtering, dry-run preview, and idempotency.

## Usage

```
/rune:post-findings                                    # Auto-detect latest TOME + current branch PR
/rune:post-findings tmp/reviews/abc123/TOME.md         # Specific TOME, auto-detect PR
/rune:post-findings tmp/reviews/abc123/TOME.md 42      # Specific TOME + specific PR#
/rune:post-findings --dry-run                          # Preview comment without posting
/rune:post-findings --force                            # Post even if already posted (skip idempotency)
```

## Algorithm

### Phase 0: Parse Arguments

```javascript
const args = "$ARGUMENTS".split(/\s+/).filter(Boolean)
let tomePath = null
let prNumber = null
let dryRun = false
let forcePost = false

for (const arg of args) {
  if (arg === "--dry-run") { dryRun = true; continue }
  if (arg === "--force") { forcePost = true; continue }
  if (arg.endsWith(".md") || arg.includes("TOME") || arg.includes("tome")) {
    tomePath = arg
  } else if (/^[1-9]\d*$/.test(arg)) {
    prNumber = arg
  }
}
```

### Phase 1: Resolve TOME Path

If no TOME path provided, auto-detect the latest TOME from known output directories.

```javascript
if (!tomePath) {
  // Search order: arc output → review output → audit output
  const searchDirs = ["tmp/arc/", "tmp/reviews/", "tmp/audit/"]
  const tomeNames = ["TOME.md", "tome.md"]

  for (const dir of searchDirs) {
    // Glob for TOME files, sort by modification time (newest first)
    const candidates = Glob(`${dir}**/TOME.md`) || Glob(`${dir}**/tome.md`) || []
    if (candidates.length > 0) {
      tomePath = candidates[0] // Most recently modified
      break
    }
  }

  if (!tomePath) {
    error("No TOME file found. Run /rune:appraise or /rune:arc first, or specify a path.")
    return
  }
  log(`Auto-detected TOME: ${tomePath}`)
}

// Validate TOME exists and is non-empty
if (!exists(tomePath)) {
  error(`TOME file not found: ${tomePath}`)
  return
}
```

### Phase 2: Resolve PR Number

If no PR number provided, detect from the current branch.

```javascript
if (!prNumber) {
  // Use gh pr view to find PR for current branch
  const prResult = Bash(`GH_PROMPT_DISABLED=1 gh pr view --json number -q '.number' 2>/dev/null`).trim()
  if (prResult && /^[1-9]\d*$/.test(prResult)) {
    prNumber = prResult
    log(`Auto-detected PR: #${prNumber}`)
  } else {
    error("No PR found for current branch. Specify a PR number or push your branch first.")
    return
  }
}

// Validate PR number format (SEC: injection guard)
if (!/^[1-9]\d*$/.test(prNumber)) {
  error(`Invalid PR number: ${prNumber}`)
  return
}
```

### Phase 3: Read Talisman Config

```javascript
// Read pr_comment config for filtering preferences
// readTalismanSection reads pre-resolved JSON shards from tmp/.talisman-resolved/
const config = readTalismanSection("pr_comment") || {}

// Apply defaults
const severityFilter = config.severity_filter || ["P1", "P2"]
const confidenceThreshold = config.confidence_threshold || 50
const maxFindings = config.max_findings || 30
const includeTraces = config.include_traces !== false
const includeFixSuggestions = config.include_fix_suggestions !== false
const collapseThreshold = config.collapse_threshold || 5
const showFooter = config.footer !== false
```

### Phase 4: Parse TOME

```javascript
// Use tome-parser.sh to extract structured findings as JSON
const configJson = JSON.stringify({
  severity_filter: severityFilter,
  confidence_threshold: confidenceThreshold,
  max_findings: maxFindings,
  include_traces: includeTraces,
  include_fix_suggestions: includeFixSuggestions
})

// SEC-001: Validate tomePath against strict allowlist (no shell metacharacters)
if (!/^[a-zA-Z0-9._\-\/]+\.md$/.test(tomePath)) {
  error(`Invalid TOME path (contains disallowed characters): ${tomePath}`)
  return
}
// SEC-004: Pass configJson via env var to avoid single-quote injection
const findingsJson = Bash(`RUNE_PR_CONFIG='${configJson.replace(/'/g, "'\\''")}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tome-parser.sh" "${tomePath}" "$RUNE_PR_CONFIG"`)

// Validate parser output
let findings
try {
  findings = JSON.parse(findingsJson)
} catch (e) {
  error(`TOME parser returned invalid JSON. Check ${tomePath} for valid RUNE:FINDING markers.`)
  return
}

if (!Array.isArray(findings) || findings.length === 0) {
  log("No findings matched the configured filters. Nothing to post.")
  return
}

log(`Parsed ${findings.length} findings (filter: ${severityFilter.join("+")} >= confidence ${confidenceThreshold})`)
```

### Phase 5: Format Comment

```javascript
// Use pr-comment-formatter.sh to transform findings into GitHub markdown
const findingsFile = `tmp/.rune-pr-comment-findings-${Date.now()}.json`
Write(findingsFile, findingsJson)

const commentFile = `tmp/.rune-pr-comment-body-${Date.now()}.md`
// QUAL-003: Formatter reads findings from stdin, config from $1
const formatterConfig = JSON.stringify({ collapse_threshold: collapseThreshold, footer: showFooter })
Bash(`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/pr-comment-formatter.sh" '${formatterConfig.replace(/'/g, "'\\''")}' < "${findingsFile}" > "${commentFile}"`)

// Validate output
if (!exists(commentFile) || Bash(`wc -c < "${commentFile}"`).trim() === "0") {
  error("Comment formatter produced empty output.")
  return
}
```

### Phase 6: Dry-Run Check

```javascript
if (dryRun) {
  const preview = Read(commentFile)
  log("=== DRY RUN — Comment Preview ===")
  log(preview)
  log("=== End Preview ===")
  log(`Would post to PR #${prNumber}. Run without --dry-run to post.`)
  // Cleanup temp files
  Bash(`rm -f "${findingsFile}" "${commentFile}"`)
  return
}
```

### Phase 7: Post to PR

```javascript
// Build poster arguments
const forceArg = forcePost ? "--force" : ""

const postResult = Bash(`bash "${CLAUDE_PLUGIN_ROOT}/scripts/lib/pr-comment-poster.sh" "${prNumber}" "${commentFile}" ${forceArg}`)

if (postResult.includes("ERROR")) {
  error(`Failed to post: ${postResult}`)
  // Cleanup temp files
  Bash(`rm -f "${findingsFile}" "${commentFile}"`)
  return
}

// Cleanup temp files
Bash(`rm -f "${findingsFile}" "${commentFile}"`)
```

### Phase 8: Report

```javascript
if (postResult.includes("already posted")) {
  log(`Findings already posted to PR #${prNumber}. Use --force to post again.`)
} else {
  // Get PR URL for user convenience
  const prUrl = Bash(`GH_PROMPT_DISABLED=1 gh pr view ${prNumber} --json url -q '.url' 2>/dev/null`).trim()
  log(`Review findings posted to PR #${prNumber}`)
  if (prUrl) log(`View: ${prUrl}`)
  log(`${findings.length} findings posted (${severityFilter.join("+")} severity, >= ${confidenceThreshold} confidence)`)
}
```

## Error Handling

| Error | Recovery |
|-------|----------|
| No TOME found | Suggest running `/rune:appraise` or `/rune:arc` first |
| No PR for branch | Suggest specifying PR# or pushing branch with `gh pr create` |
| `gh` not authenticated | Suggest `gh auth login` or `gh auth refresh -s repo` |
| TOME parse failure | Check TOME for valid `RUNE:FINDING` markers |
| Formatter empty output | Check TOME has findings matching configured filters |
| Post failure (API error) | Check `gh auth status` for `repo` scope |
| Comment already exists | Use `--force` flag to override idempotency check |
| Body exceeds 65K chars | Automatic truncation by poster script |

## Skip Conditions

The skill exits early (with a clear message) when:

1. **No TOME file found** — no argument provided and no TOME in `tmp/arc/`, `tmp/reviews/`, or `tmp/audit/`
2. **No PR exists** — no argument provided and `gh pr view` fails for current branch
3. **Invalid PR number** — argument doesn't match `^[1-9]\d*$`
4. **Empty findings** — TOME has 0 findings after applying severity/confidence filters
5. **Already posted** — idempotency marker found on PR (unless `--force`)

## Security

- **No `eval`** — all shell scripts use direct invocation, never `eval`
- **`GH_PROMPT_DISABLED=1`** — prevents interactive gh prompts (SEC-DECREE-003)
- **PR number validation** — must match `^[1-9]\d*$` (rejects injection attempts)
- **Path traversal guard** — poster rejects body files with `..` or outside `tmp/`
- **`--body-file`** — poster uses file-based body, never string interpolation
- **Idempotency** — `<!-- rune-review-findings -->` HTML marker prevents duplicate comments
- **Temp file cleanup** — findings JSON and comment body removed after posting
