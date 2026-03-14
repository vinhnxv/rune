# Pre-flight — Full Algorithm

Pre-flight sequence: branch strategy, concurrent arc prevention, plan path validation,
inter-phase cleanup guard, and stale team scan.

**Inputs**: plan path, branch state, team registry
**Outputs**: feature branch (if on main), validated plan path, clean team state
**Error handling**: Abort arc on validation failure, warn on stale teams
**Consumers**: SKILL.md (Pre-flight stub), `--resume` path (partial re-run via prePhaseCleanup)

> **Note**: `prePhaseCleanup(checkpoint)` is defined here but called from 13+ phase stubs
> in SKILL.md. The orchestrator reads this file at dispatcher init (before phase loop).
> `FORBIDDEN_PHASE_KEYS` is defined inline in SKILL.md and available in the orchestrator's context.

## Branch Strategy (COMMIT-1)

Safety-first branch strategy. NEVER silently creates branches, discards changes, or force-checkouts.
Always pulls latest before branching. Always asks user before operating on a non-main branch.

**Core Principle**: The user's uncommitted work is sacred. Rune never discards it.

> **Design Rationale (VEIL-005)**: The 4-case matrix below is deliberate — each combination of
> (main vs feature branch) × (clean vs dirty working tree) requires distinct user prompts and
> safety guarantees. Collapsing cases would lose important UX distinctions (e.g., dirty+feature
> needs both stash and WIP-commit options, while dirty+main only needs stash). The shard branch
> path adds a 5th case for multi-shard coordination. This complexity is justified by the
> irreversibility of branch operations on user work.

| Current Branch | Working Tree | Action |
|---|---|---|
| main/master | Clean | `git pull --ff-only` → create feature branch → proceed |
| main/master | Dirty | WARN: offer Stash+proceed or Abort |
| Feature branch | Clean | ASK: Use current / Switch to main / Abort |
| Feature branch | Dirty | ASK: Stash+switch / Commit WIP+switch / Use current (risky) / Abort |
| Feature branch (shard) | Any | Reuse existing shard branch (`rune/arc-{feature}-shards-*`) or create new one |

```javascript
// ── SAFE BRANCH STRATEGY ──
const currentBranch = Bash("git branch --show-current 2>/dev/null").trim()
const dirtyFiles = Bash("git status --porcelain 2>/dev/null").trim()
const mainBranch = Bash("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo refs/remotes/origin/main").trim().replace(/.*\//, '')
const isMainBranch = (currentBranch === "main" || currentBranch === "master" || currentBranch === mainBranch)
const isDirty = !!dirtyFiles
const fileCount = isDirty ? dirtyFiles.split('\n').length : 0

// Helper: validate and create a feature branch name
function createFeatureBranch(planFile, shardInfo) {
  let branchName
  if (shardInfo) {
    // Shard mode: reuse existing shard branch or create new one
    const featureName = (shardInfo.featureName || "unnamed").replace(/[^a-zA-Z0-9]/g, '-')
    const existingBranch = Bash(
      `git for-each-ref --sort=-creatordate --format='%(refname:short)' ` +
      `"refs/heads/rune/arc-${featureName}-shards-*" 2>/dev/null | head -1`
    ).trim()

    if (existingBranch) {
      // DSEC-006: Validate branch name from git output (defense-in-depth against malformed refs)
      if (!/^[a-zA-Z0-9/_.-]+$/.test(existingBranch)) {
        throw new Error(`Existing shard branch has invalid characters: ${existingBranch}`)
      }
      Bash(`git checkout "${existingBranch}"`)
      Bash(`git pull --ff-only origin "${existingBranch}" 2>/dev/null || true`)
      return existingBranch
    }
    branchName = `rune/arc-${featureName}-shards-${Bash("date +%Y%m%d-%H%M%S").trim()}`
  } else {
    const planName = (planFile.replace(/.*\//, '').replace(/\.md$/, '') || "unnamed").replace(/[^a-zA-Z0-9]/g, '-')
    branchName = `rune/arc-${planName}-${Bash("date +%Y%m%d-%H%M%S").trim()}`
  }

  // SEC-006: Validate branch name using git's own ref validation
  if (Bash(`git check-ref-format --branch "${branchName}" 2>/dev/null; echo $?`).trim() !== "0") {
    throw new Error(`Invalid branch name: ${branchName}`)
  }
  // Guard against HEAD/special-ref collisions
  if (/HEAD|FETCH_HEAD|ORIG_HEAD|MERGE_HEAD/.test(branchName)) {
    throw new Error(`Branch name collides with Git special ref: ${branchName}`)
  }

  Bash(`git checkout -b "${branchName}"`)
  return branchName
}

// ── CASE 1: On main/master, clean working tree ──
if (isMainBranch && !isDirty) {
  // Pull latest — ensure we branch from up-to-date code
  const pullResult = Bash(`git pull --ff-only origin "${mainBranch}" 2>&1`).trim()
  if (pullResult.includes("fatal") || pullResult.includes("error")) {
    // Pull failed — diverged history or network issue
    const choice = AskUserQuestion({
      question:
        `Failed to pull latest from origin/${mainBranch}:\n\`\`\`\n${pullResult}\n\`\`\`\n\n` +
        "Options:\n" +
        "1. **Proceed anyway** — branch from current local main (may be outdated)\n" +
        "2. **Abort** — fix the issue manually first"
    })
    if (choice.toLowerCase().includes("abort")) {
      throw new Error("Aborted by user — fix git pull issue and retry.")
    }
  } else {
    // Inform user if new commits were pulled
    const commitsPulled = (pullResult.match(/(\d+) files? changed/) || [])[0]
    if (commitsPulled) {
      log(`Pulled latest from origin/${mainBranch}: ${commitsPulled}`)
    }
  }
  // Create feature branch
  const branch = createFeatureBranch(planFile, shardInfo)
  // branch variable is used by checkpoint init below
}

// ── CASE 2: On main/master, dirty working tree ──
if (isMainBranch && isDirty) {
  const choice = AskUserQuestion({
    question:
      `You have ${fileCount} uncommitted change(s) on \`${mainBranch}\`.\n` +
      "Arc needs a clean main to create a feature branch.\n\n" +
      "Options:\n" +
      "1. **Stash & proceed** — `git stash` your changes, pull latest, create branch\n" +
      "   (restore later with `git stash pop`)\n" +
      "2. **Abort** — commit or stash your changes manually first"
  })
  if (choice.toLowerCase().includes("stash")) {
    Bash("git stash push -m 'rune-arc: auto-stash before branch creation'")
    const pullResult = Bash(`git pull --ff-only origin "${mainBranch}" 2>&1`).trim()
    if (pullResult.includes("fatal") || pullResult.includes("error")) {
      // Restore stash before aborting
      Bash("git stash pop 2>/dev/null || true")
      throw new Error(`Pull failed after stash: ${pullResult}. Your changes were restored.`)
    }
    warn("Your changes were stashed. Run `git stash pop` after arc completes to restore them.")
    const branch = createFeatureBranch(planFile, shardInfo)
  } else {
    throw new Error("Aborted by user — handle uncommitted changes and retry.")
  }
}

// ── CASE 3: On feature branch, clean working tree ──
if (!isMainBranch && !isDirty) {
  const choice = AskUserQuestion({
    question:
      `You're on branch \`${currentBranch}\`, not \`${mainBranch}\`.\n\n` +
      "Options:\n" +
      `1. **Use current branch** — arc will make commits directly on \`${currentBranch}\`\n` +
      `2. **Switch to main** — checkout \`${mainBranch}\`, pull latest, create a new feature branch\n` +
      "3. **Abort** — handle branch management yourself first"
  })
  if (choice.toLowerCase().includes("current branch") || choice.toLowerCase().includes("use current")) {
    // Use current branch as-is — no new branch created
    log(`Using existing branch: ${currentBranch}`)
    // branch = currentBranch (set for checkpoint)
  } else if (choice.toLowerCase().includes("switch") || choice.toLowerCase().includes("main")) {
    Bash(`git checkout "${mainBranch}"`)
    const pullResult = Bash(`git pull --ff-only origin "${mainBranch}" 2>&1`).trim()
    if (pullResult.includes("fatal") || pullResult.includes("error")) {
      warn(`Pull failed: ${pullResult}. Proceeding with local ${mainBranch}.`)
    }
    const branch = createFeatureBranch(planFile, shardInfo)
  } else {
    throw new Error("Aborted by user.")
  }
}

// ── CASE 4: On feature branch, dirty working tree ──
if (!isMainBranch && isDirty) {
  const choice = AskUserQuestion({
    question:
      `You're on branch \`${currentBranch}\` with ${fileCount} uncommitted change(s).\n` +
      "Arc will make commits on this branch — your work could get mixed in.\n\n" +
      "**Recommended**: Handle your changes first.\n\n" +
      "Options:\n" +
      `1. **Stash & switch** — stash changes, checkout \`${mainBranch}\`, pull latest, create new branch\n` +
      `2. **Commit WIP & switch** — commit tracked files as WIP on \`${currentBranch}\`, checkout \`${mainBranch}\`, pull, create new branch\n` +
      `   ⚠️ Only tracked files are committed. Untracked files remain in the working tree.\n` +
      `3. **Use current branch (risky)** — arc commits on \`${currentBranch}\` alongside your uncommitted changes\n` +
      "4. **Abort** — handle it yourself first"
  })
  if (choice.toLowerCase().includes("stash")) {
    Bash("git stash push -m 'rune-arc: auto-stash before branch switch'")
    Bash(`git checkout "${mainBranch}"`)
    const pullResult = Bash(`git pull --ff-only origin "${mainBranch}" 2>&1`).trim()
    if (pullResult.includes("fatal") || pullResult.includes("error")) {
      warn(`Pull failed: ${pullResult}. Proceeding with local ${mainBranch}.`)
    }
    warn(`Your changes on \`${currentBranch}\` were stashed. Run \`git checkout ${currentBranch} && git stash pop\` to restore them.`)
    const branch = createFeatureBranch(planFile, shardInfo)
  } else if (choice.toLowerCase().includes("commit wip") || choice.toLowerCase().includes("wip")) {
    // SEC-002: Use git add -u (tracked files only) instead of git add -A to avoid
    // staging untracked files that may contain sensitive data (.env, credentials, etc.)
    Bash(`git add -u && git commit -m "WIP: auto-committed by rune-arc before branch switch"`)
    Bash(`git checkout "${mainBranch}"`)
    const pullResult = Bash(`git pull --ff-only origin "${mainBranch}" 2>&1`).trim()
    if (pullResult.includes("fatal") || pullResult.includes("error")) {
      warn(`Pull failed: ${pullResult}. Proceeding with local ${mainBranch}.`)
    }
    warn(`Your WIP was committed on \`${currentBranch}\`. You can amend or squash it later.`)
    const branch = createFeatureBranch(planFile, shardInfo)
  } else if (choice.toLowerCase().includes("current branch") || choice.toLowerCase().includes("risky")) {
    warn("Proceeding on dirty branch — your uncommitted changes may be mixed with arc's commits.")
    // Use current branch as-is
  } else {
    throw new Error("Aborted by user.")
  }
}
```

**Edge Cases**:
- `git pull --ff-only` fails (diverged history): warn user, offer proceed-anyway or abort
- Remote unreachable (offline): pull fails gracefully, offer proceed with local main
- Stash fails (nothing to stash, permission error): error propagates to user
- Shard mode: if sibling shard already created a branch, checkout + pull existing branch (skip creation)
- Multiple shard branches for same feature: use most recent (sort by creator date)
- Branch was force-deleted between shard runs: create new branch
- User selects "Commit WIP": uses `git add -u` (tracked files only) to avoid staging untracked sensitive files (.env, credentials). Untracked files remain in the working tree.

## Concurrent Arc Prevention

```bash
# SEC-007: Use find instead of ls glob to avoid ARG_MAX issues
# SEC-007 (P2): Cross-command concurrency is now handled by the shared workflow lock library
# (scripts/lib/workflow-lock.sh). Each /rune:* command acquires a lock at entry and releases
# it at cleanup. The lock check in arc/SKILL.md "Workflow Lock (writer)" section runs
# rune_check_conflicts("writer") and rune_acquire_lock("arc", "writer") before reaching
# this pre-flight code. The checks below are arc-specific concurrent session detection
# (checkpoint-based) that complement the shared lock library.
const MAX_CHECKPOINT_AGE = 604_800_000  // 7 days in ms — abandoned checkpoints ignored

# ZSH-COMPAT: Resolve CHOME for CLAUDE_CONFIG_DIR support (avoids ~ expansion issues in zsh)
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

if command -v jq >/dev/null 2>&1; then
  # SEC-5 FIX: Place -maxdepth before -name for POSIX portability (BSD find on macOS)
  # FIX: Search CWD-scoped .claude/arc/ (where checkpoints live), not $CHOME/arc/ (wrong directory)
  active=$(find "${CWD}/.claude/arc" -maxdepth 2 -name checkpoint.json 2>/dev/null | while read f; do
    # Skip checkpoints older than 7 days (abandoned)
    started_at=$(jq -r '.started_at // empty' "$f" 2>/dev/null)
    if [ -n "$started_at" ]; then
      # BSD date (-j -f) with GNU fallback (-d).
      # Parse failure → epoch=0 → age=now-0=currentTimestamp → exceeds 7-day threshold → skipped as stale.
      epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%%.*}" +%s 2>/dev/null || date -d "${started_at}" +%s 2>/dev/null || echo 0)
      # SEC-002 FIX: Validate epoch is numeric before arithmetic (defense against malformed started_at)
      # ZSH-FIX: Use POSIX case instead of [[ =~ ]] — avoids zsh history expansion and regex quirks
      case "$epoch" in *[!0-9]*|'') continue ;; esac
      [ "$epoch" -eq 0 ] && echo "WARNING: Failed to parse started_at: $started_at" >&2
      age_s=$(( $(date +%s) - epoch ))
      # Skip if age is negative (future timestamp = suspicious) or > 7 days (abandoned)
      [ "$age_s" -lt 0 ] 2>/dev/null && continue
      [ "$age_s" -gt 604800 ] 2>/dev/null && continue
    fi
    # EXIT-CODE FIX: || true normalizes exit code when select() filters out everything
    # (no in_progress phases). Without this, jq exits non-zero → loop exit code propagates →
    # LLM sees "Error: Exit code 5" and may cascade-fail parallel sibling tool calls.
    jq -r 'select(.phases | to_entries | map(.value.status) | any(. == "in_progress")) | .id' "$f" 2>/dev/null || true
  done)
else
  # NOTE: grep fallback is imprecise — matches "in_progress" anywhere in file, not field-specific.
  # Acceptable as degraded-mode check when jq is unavailable. The jq path above is the robust check.
  active=$(find "${CWD}/.claude/arc" -maxdepth 2 -name checkpoint.json 2>/dev/null | while read f; do
    if grep -q '"status"[[:space:]]*:[[:space:]]*"in_progress"' "$f" 2>/dev/null; then basename "$(dirname "$f")"; fi
  done)
fi

if [ -n "$active" ]; then
  echo "Active arc session detected: $active"
  echo "Cancel with /rune:cancel-arc or wait for completion"
  exit 1
fi

# Cross-command concurrency check (via shared workflow lock library)
# Supersedes the old state-file-scan advisory. The lock library provides:
#   - Writer vs writer → CONFLICT (hard block with user prompt)
#   - Writer vs reader/planner → ADVISORY (informational)
#   - Reader vs reader → OK (no conflict)
#   - PID liveness check (dead PIDs auto-cleaned)
#   - Session re-entrancy (arc delegating to strive = same PID, no conflict)
# The lock is acquired in arc/SKILL.md "Workflow Lock (writer)" section
# BEFORE this pre-flight code runs. No additional check needed here.
# See scripts/lib/workflow-lock.sh for the full API.
```

## Resolve Plan Path (FIX-001: arc-batch fallback)

```javascript
// FIX-001: When invoked from arc-batch, the plan path may be missing from $ARGUMENTS
// due to a known model behavior issue where Skill() is called without the second argument.
// Fallback: read from tmp/.rune-arc-batch-next-plan.txt (written by arc-batch stop hook).
if (!planFile || planFile.trim() === '') {
  const fallbackFile = "tmp/.rune-arc-batch-next-plan.txt"
  try {
    const fallbackContent = Read(fallbackFile).trim()
    if (fallbackContent) {
      // Parse: first token is plan path, rest are flags
      const parts = fallbackContent.split(/\s+/)
      planFile = parts[0]
      // Re-parse flags from fallback content
      const fallbackFlags = parts.slice(1).join(' ')
      warn(`Plan path recovered from ${fallbackFile}: ${planFile} ${fallbackFlags}`)
      // Clean up fallback file after consumption
      Bash(`rm -f "${fallbackFile}" 2>/dev/null`)
    }
  } catch (e) {
    // Fallback file doesn't exist — not an arc-batch invocation
  }
}

if (!planFile || planFile.trim() === '') {
  error("No plan path provided. Usage: /rune:arc <plan-file.md>")
  error("If running from arc-batch, check that the Skill tool was called with both arguments.")
  return
}
```

## Validate Plan Path

```javascript
if (!/^[a-zA-Z0-9._\/-]+$/.test(planFile)) {
  error(`Invalid plan path: ${planFile}. Only alphanumeric, dot, slash, hyphen, and underscore allowed.`)
  return
}
// CDX-005 MITIGATION (P2): Explicit .. rejection — PRIMARY defense against path traversal.
// The regex above intentionally allows . and / for valid paths like "plans/2026-01-01-plan.md".
// This check is the real barrier against ../../../etc/passwd style traversal.
if (planFile.includes('..')) {
  error(`Path traversal detected in plan path: ${planFile}`)
  return
}
// CDX-009 MITIGATION: Reject leading-hyphen paths (option injection in cp, ls, etc.)
if (planFile.startsWith('-')) {
  error(`Plan path starts with hyphen (option injection risk): ${planFile}`)
  return
}
// Reject absolute paths — plan files must be relative to project root
if (planFile.startsWith('/')) {
  error(`Absolute paths not allowed: ${planFile}. Use a relative path from project root.`)
  return
}
// CDX-010 FIX: Reject symlinks — a symlink at plans/evil.md -> /etc/passwd would
// pass all regex/traversal checks above but read arbitrary files via Read().
// Use Bash test -L (not stat) for portability across macOS/Linux.
if (Bash(`test -L "${planFile}" && echo "symlink"`).includes("symlink")) {
  error(`Plan path is a symlink (not following): ${planFile}`)
  return
}
```

## Talisman Shard Verification (v1.163.1+)

Verifies talisman shards are available before checkpoint init. Prevents silent fallback to
hardcoded defaults when shards are missing or stale (root cause: LLM checking `.yml` instead
of `.json` — see CHANGELOG v1.163.1).

**Inputs**: None (reads `tmp/.talisman-resolved/_meta.json`)
**Outputs**: Verified talisman meta, diagnostic log of key config values
**Error handling**: Missing shards → re-resolve inline via `talisman-resolve.sh`. Resolution failure → warn and proceed (fallback to `readTalisman()` at checkpoint init).

```javascript
// ── TALISMAN SHARD VERIFICATION (pre-flight) ──
// Ensures talisman context is available before checkpoint init.
// Prevents silent fallback to hardcoded defaults when shards are missing.
// Root cause fix: LLM bypassed readTalismanSection() and checked arc.yml (wrong extension)
// instead of arc.json. This verification ensures shards exist and logs key values for
// self-verification by the LLM executor.

const metaPath = "tmp/.talisman-resolved/_meta.json"
let talismanMeta = null
try {
  talismanMeta = JSON.parse(Read(metaPath))
} catch (e) {
  // Shards missing — re-resolve inline
  // BACK-001 FIX: Wrap Bash() in try-catch to prevent exception propagation from catch block.
  // BACK-002 FIX: Guard CWD — undefined CWD would produce `cd "" && ...` which silently succeeds
  // on some shells but changes to $HOME on others.
  warn("Talisman shards missing — re-resolving inline")
  try {
    if (typeof CWD === 'undefined' || !CWD) throw new Error("CWD not set — cannot run talisman-resolve.sh")
    Bash(`cd "${CWD}" && bash plugins/rune/scripts/talisman-resolve.sh`)
  } catch (resolveErr) {
    warn(`Talisman inline re-resolution failed: ${resolveErr.message}`)
  }
  try { talismanMeta = JSON.parse(Read(metaPath)) } catch (e2) {
    warn("Talisman resolution failed — using readTalisman() fallback for all config")
  }
}

if (talismanMeta) {
  const resolvedAt = talismanMeta.resolved_at ?? null
  let status = talismanMeta.merge_status ?? "unknown"

  // Check shard freshness (stale if older than 5 minutes)
  if (resolvedAt) {
    const shardAge = Date.now() - new Date(resolvedAt).getTime()
    if (Number.isFinite(shardAge) && shardAge > 300_000) {
      warn(`Talisman shards are ${Math.round(shardAge / 60000)}m old — re-resolving`)
      // BACK-002 FIX: Wrap stale-shard re-resolution in try-catch (same pattern as missing-shard path)
      try {
        if (typeof CWD === 'undefined' || !CWD) throw new Error("CWD not set")
        Bash(`cd "${CWD}" && bash plugins/rune/scripts/talisman-resolve.sh`)
      } catch (resolveErr) {
        warn(`Talisman stale re-resolution failed: ${resolveErr.message} — proceeding with stale shards`)
      }
      // Re-read meta after re-resolution to get updated status
      try {
        talismanMeta = JSON.parse(Read(metaPath))
        status = talismanMeta.merge_status ?? "unknown"
      } catch (e) {
        warn("Talisman re-resolution failed — proceeding with stale shards")
      }
    }
  }

  if (status === "defaults_only") {
    warn("Talisman: using defaults only (no .claude/talisman.yml found)")
  }
  log(`Talisman resolved: ${status} (resolver: ${talismanMeta.resolver_status ?? "unknown"})`)

  // Diagnostic: log key arc config values for LLM self-verification
  try {
    const arcShard = JSON.parse(Read("tmp/.talisman-resolved/arc.json"))
    log(`Arc config resolved: auto_merge=${arcShard?.ship?.auto_merge}, no_forge=${arcShard?.defaults?.no_forge}, auto_pr=${arcShard?.ship?.auto_pr}`)
  } catch (e) {
    warn("Could not read arc shard for diagnostic — will be resolved at checkpoint init")
  }
}
```

## Git Instructions Check (v2.1.69+)

Warn if `includeGitInstructions` is disabled — arc ship/merge phases (23-27) depend on
built-in git workflow instructions for commit, PR, and merge operations.

```javascript
// ── GIT INSTRUCTIONS CHECK ──
// Claude Code 2.1.69 added includeGitInstructions setting and
// CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS env var. When disabled, the system
// prompt omits built-in commit/PR workflow instructions — arc's ship and
// merge phases may fail or produce malformed commits/PRs.

let gitInstructionsDisabled = false

for (const settingsFile of [
  `${CWD}/.claude/settings.json`,
  `${CWD}/.claude/settings.local.json`
]) {
  try {
    const settings = JSON.parse(Read(settingsFile))
    if (settings.includeGitInstructions === false) {
      gitInstructionsDisabled = true
      break
    }
  } catch (e) { /* file missing or invalid JSON — OK */ }
}

// Also check env var (takes precedence in Claude Code)
const envDisabled = Bash('echo "${CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS:-}"').trim()
if (envDisabled === "1" || envDisabled === "true") {
  gitInstructionsDisabled = true
}

if (gitInstructionsDisabled) {
  warn("includeGitInstructions is disabled — arc ship/merge phases (23-27) may fail without built-in git workflow instructions. Consider re-enabling for arc runs.")
}
```

## Shard Detection (v1.66.0+)

Detect shard plans via filename regex and verify prerequisite shards are complete.
Runs after plan path validation, before freshness gate. Non-shard plans bypass entirely (zero overhead).

```javascript
// ── SHARD DETECTION (after path validation, before freshness gate) ──

// readTalismanSection: "arc"
const arc = readTalismanSection("arc")
const shardConfig = arc?.sharding ?? {}
const shardEnabled = shardConfig.enabled !== false  // default: true
const prereqCheck = shardConfig.prerequisite_check !== false  // default: true
const sharedBranch = shardConfig.shared_branch !== false  // default: true

const shardMatch = shardEnabled ? planFile.match(/-shard-(\d+)-/) : null
let shardInfo = null

if (shardMatch) {
  const shardNum = parseInt(shardMatch[1])
  // F-001 FIX: Shard numbers are 1-indexed. Reject shard-0 as semantically invalid.
  if (shardNum < 1) {
    warn(`Invalid shard number ${shardNum} in filename — shard numbers must be >= 1. Skipping shard detection.`)
    // Fall through to non-shard path
  } else {
  log(`Shard detected: shard ${shardNum} of a shattered plan`)

  // Read shard plan frontmatter
  const planContent = Read(planFile)
  const frontmatter = extractYamlFrontmatter(planContent)

  if (!frontmatter?.parent) {
    warn(`Shard plan missing 'parent' field in frontmatter — skipping prerequisite check`)
  } else {
    // Validate parent plan exists
    const parentPath = frontmatter.parent
    if (!/^[a-zA-Z0-9._\/-]+$/.test(parentPath) || parentPath.includes('..')) {
      error(`Invalid parent plan path in frontmatter: ${parentPath}`)
      return
    }

    // CONCERN-2 FIX: Sibling-relative path fallback when absolute parent path fails.
    // Shard files in plans/shattering/ have parent: pointing to plans/ root.
    // F-006 FIX: Safe dirname extraction for bare filenames (no '/')
    const shardDir = planFile.includes('/') ? planFile.replace(/\/[^/]+$/, '') : '.'
    let parentContent = null
    try { parentContent = Read(parentPath) } catch (e) {
      // Sibling-relative fallback: use shardDir (computed above, F-006 safe)
      const parentBasename = parentPath.replace(/.*\//, '')
      // SEC-004 FIX: Independent traversal guard on extracted basename
      if (parentBasename.includes('/') || parentBasename.includes('..') || parentBasename === '') {
        warn(`Unsafe parent basename: ${parentBasename} — skipping sibling fallback`)
      } else {
        try { parentContent = Read(`${shardDir}/${parentBasename}`) } catch (e2) {
          warn(`Parent plan not found: ${parentPath} — skipping prerequisite check`)
        }
      }
    }

    if (parentContent) {
      const parentFrontmatter = extractYamlFrontmatter(parentContent)

      // Verify parent is actually shattered
      if (!parentFrontmatter?.shattered) {
        warn(`Parent plan does not have 'shattered: true' — treating as standalone shard`)
      }

      // Read dependency list from shard frontmatter
      const dependencies = frontmatter.dependencies || []
      // dependencies format: [shard-1, shard-2] or "none" or []
      const depNums = []
      if (Array.isArray(dependencies)) {
        for (const dep of dependencies) {
          const depMatch = String(dep).match(/shard-(\d+)/)
          if (depMatch) {
            const depNum = parseInt(depMatch[1])
            // SEC-005 FIX: Upper-bound validation on dependency shard numbers
            if (depNum >= 1 && depNum <= 999) depNums.push(depNum)
          }
        }
      }

      if (prereqCheck && depNums.length > 0) {
        // Find sibling shard files
        // F-006 FIX: Safe dirname for bare filenames
        const planDir = planFile.includes('/') ? planFile.replace(/\/[^/]+$/, '') : '.'
        // Consistent regex: matches parse-plan.md pattern (plugins/rune/skills/strive/references/parse-plan.md:60)
        const planBase = planFile.replace(/.*\//, '').replace(/-shard-\d+-[^-]+-plan\.md$/, '')

        const incompleteDeps = []
        for (const depNum of depNums) {
          const siblingPattern = `${planDir}/${planBase}-shard-${depNum}-*-plan.md`
          const siblings = Glob(siblingPattern)

          if (siblings.length === 0) {
            incompleteDeps.push({ num: depNum, reason: "file not found" })
            continue
          }

          const siblingContent = Read(siblings[0])
          const siblingFrontmatter = extractYamlFrontmatter(siblingContent)
          const siblingStatus = siblingFrontmatter?.status || "draft"

          // Check if dependency shard has been implemented
          // "completed" in frontmatter means /rune:strive finished
          // Also check git log for commits mentioning the shard
          if (siblingStatus !== "completed") {
            // Secondary check: look for arc completion stamp in the shard plan
            // Heading format: "## Arc Completion Record" (arc-phase-completion-stamp.md:162)
            const hasCompletionStamp = /^## Arc Completion Record/m.test(siblingContent)
            if (!hasCompletionStamp) {
              incompleteDeps.push({
                num: depNum,
                reason: `status: ${siblingStatus} (no completion stamp)`,
                file: siblings[0]
              })
            }
          }
        }

        if (incompleteDeps.length > 0) {
          const depList = incompleteDeps.map(d =>
            `  - Shard ${d.num}: ${d.reason}${d.file ? ` (${d.file})` : ''}`
          ).join('\n')

          AskUserQuestion({
            questions: [{
              question: `Shard ${shardNum} depends on incomplete shards:\n${depList}\n\nProceed anyway?`,
              header: "Shard deps",
              options: [
                { label: "Proceed (risk)", description: "Run anyway — earlier shard code may be missing" },
                { label: "Abort", description: "Run prerequisite shards first" }
              ],
              multiSelect: false
            }]
          })
          // If user chose "Abort": return
        }
      }

      // Store shard info for branch strategy and checkpoint
      // F-011 FIX: Warn if parent plan doesn't specify total shard count
      const totalShards = parentFrontmatter?.shards || 0
      if (totalShards === 0) {
        warn(`Parent plan missing 'shards:' count in frontmatter — PR title will show 'shard N of 0'`)
      }

      shardInfo = {
        shardNum,
        totalShards,
        parentPath,
        featureName: parentFrontmatter?.feature || frontmatter?.feature || "unknown",
        dependencies: depNums,
        shardName: frontmatter?.shard_name || `shard-${shardNum}`
      }
    }
  } // end shard-0 else guard
  }
}

// Store in checkpoint for downstream phases (branch strategy, ship phase PR title)
if (shardInfo) {
  updateCheckpoint({ shard: shardInfo })
}

// Set shell variables for Branch Strategy (above)
// SHARD_INFO and SHARD_FEATURE_NAME are consumed by the branch strategy block
if (shardInfo && sharedBranch) {
  // SHARD_INFO is truthy — triggers shard branch path
  // SHARD_FEATURE_NAME is used to construct branch name
}
```

**Edge Cases**:
- Shard plan with `dependencies: none` (shard-1 pattern): `Array.isArray("none")` is false, skip prerequisite check
- Parent plan deleted after shattering: warn but proceed (CONCERN-2 fallback path)
- Shard frontmatter missing `parent` field: warn, skip prerequisite check
- Shard number 0 or negative: regex `-shard-(\d+)-` won't match 0 or negative
- Non-numeric shard in filename (e.g., `-shard-abc-`): regex match fails, skip shard detection
- Parent path in subdirectory: sibling-relative fallback resolves `plans/shattering/` paths (CONCERN-2 fix)

## Inter-Phase Cleanup Guard (ARC-6)

Runs before every delegated phase to ensure no stale team blocks TeamCreate. Idempotent — harmless no-op when no stale team exists. Complements CDX-7 (crash recovery) — this handles normal phase transitions.

```javascript
// prePhaseCleanup(checkpoint): Clean stale teams from prior phases.
// Runs before EVERY delegated phase. See team-sdk/references/engines.md Pre-Create Guard.
// NOTE: Assumes checkpoint schema v5+ where each phase entry has { status, team_name, ... }
// SYNC-POINT: team_name validation regex must stay in sync with post-arc.md

function prePhaseCleanup(checkpoint) {
  try {
    // Guard: validate checkpoint.phases exists and is an object
    if (!checkpoint?.phases || typeof checkpoint.phases !== 'object' || Array.isArray(checkpoint.phases)) {
      warn('ARC-6: Invalid checkpoint.phases — skipping inter-phase cleanup')
      return
    }

    // Strategy 1: Clear SDK session leadership state FIRST (while dirs still exist)
    // TeamDelete() targets the CURRENT SESSION's active team. Must run BEFORE rm -rf
    // so the SDK finds the directory and properly clears internal leadership tracking.
    // If dirs are already gone, TeamDelete may not clear state — hence "first" ordering.
    // See team-sdk/references/engines.md "Team Completion Verification" section.
    // Retry-with-backoff (3 attempts: 0s, 3s, 8s)
    const CLEANUP_DELAYS = [0, 3000, 8000]
    for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
      if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
      try { TeamDelete(); break } catch (e) {
        warn(`ARC-6: TeamDelete attempt ${attempt + 1} failed: ${e.message}`)
      }
    }

    // Strategy 2: Checkpoint-aware filesystem cleanup for ALL prior-phase teams
    // rm -rf targets named teams from checkpoint (may include teams this session
    // never led). TeamDelete can't target foreign teams — only rm -rf works here.
    for (const [phaseName, phaseInfo] of Object.entries(checkpoint.phases)) {
      if (FORBIDDEN_PHASE_KEYS.has(phaseName)) continue
      if (!phaseInfo || typeof phaseInfo !== 'object') continue
      if (!phaseInfo.team_name || typeof phaseInfo.team_name !== 'string') continue
      // ARC-6 STATUS GUARD: Denylist approach — only "in_progress" is preserved.
      // All other statuses (completed, failed, skipped, timeout, pending) are eligible for cleanup.
      // If a new active-state status is added to PHASE_ORDER, update this guard.
      if (phaseInfo.status === "in_progress") continue  // Don't clean actively running phase

      const teamName = phaseInfo.team_name

      // SEC-003: Validate BEFORE any filesystem operations — see security-patterns.md
      if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) {
        warn(`ARC-6: Invalid team name for phase ${phaseName}: "${teamName}" — skipping`)
        continue
      }
      // Unreachable after regex — retained as defense-in-depth per SEC-003
      if (teamName.includes('..')) {
        warn('ARC-6: Path traversal detected in team name — skipping')
        continue
      }

      // SEC-002: rm -rf unconditionally — no exists() guard (eliminates TOCTOU window).
      // rm -rf on a nonexistent path is a no-op, so this is safe.
      // ARC-6: teamName validated above — contains only [a-zA-Z0-9_-]
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)

      // Post-removal verification: detect if cleaning happened or if dir persists
      // TOME-1 FIX: Use CHOME-based check instead of bare ~/.claude/ path
      const stillExists = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -d "$CHOME/teams/${teamName}/" && echo "exists"`)
      if (stillExists.trim() === "exists") {
        warn(`ARC-6: rm -rf failed for ${teamName} — directory still exists`)
      }
    }

    // Step C: Single TeamDelete after cross-phase filesystem cleanup
    // Single attempt is intentional — filesystem cleanup above should have unblocked
    // SDK state. If this doesn't work, more retries with sleep won't help.
    try { TeamDelete() } catch (e3) { /* SDK state cleared or was already clear */ }

    // Strategy 4 (SDK leadership nuclear reset): If Strategies 1-3 all failed because
    // a prior phase's cleanup already rm-rf'd team dirs before TeamDelete could clear
    // SDK internal leadership tracking, the SDK still thinks we're leading a ghost team.
    // Fix: temporarily recreate each checkpoint-recorded team's minimal dir so TeamDelete
    // can find it and release leadership. When TeamDelete succeeds, we've found the
    // ghost team and cleared state. Only iterates completed/failed/skipped phases.
    // This handles the Phase 2 → Phase 6+ leadership leak where Phase 2's rm-rf fallback
    // cleared dirs before TeamDelete could clear SDK state (see team-sdk/references/engines.md).
    let strategy4Resolved = false
    for (const [pn, pi] of Object.entries(checkpoint.phases)) {
      if (FORBIDDEN_PHASE_KEYS.has(pn)) continue
      if (!pi?.team_name || typeof pi.team_name !== 'string') continue
      if (pi.status === 'in_progress') continue
      if (!/^[a-zA-Z0-9_-]+$/.test(pi.team_name)) continue

      const tn = pi.team_name
      // Recreate minimal dir so SDK can find and release the team
      // SEC-001 TRUST BOUNDARY: tn comes from checkpoint.phases[].team_name (untrusted).
      // Validated above: FORBIDDEN_PHASE_KEYS, type check, status != in_progress, regex /^[a-zA-Z0-9_-]+$/.
      Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && mkdir -p "$CHOME/teams/${tn}" && printf '{"team_name":"%s","members":[]}' "${tn}" > "$CHOME/teams/${tn}/config.json" 2>/dev/null`)
      try {
        TeamDelete()
        // Success — SDK leadership state cleared. Clean up the recreated dir.
        Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${tn}/" "$CHOME/tasks/${tn}/" 2>/dev/null`)
        strategy4Resolved = true
        break  // SDK only tracks one team at a time — done
      } catch (e4) {
        // Not the team SDK was tracking, or TeamDelete failed for another reason.
        // Clean up the recreated dir and try the next checkpoint team.
        Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${tn}/" "$CHOME/tasks/${tn}/" 2>/dev/null`)
      }
    }
    // BACK-009 FIX: Warn if Strategy 4 exhausted all checkpoint phases without finding the ghost team.
    // Non-fatal — the ghost team may be from a different session not recorded in this checkpoint.
    if (!strategy4Resolved) {
      warn('ARC-6 Strategy 4: ghost team not found in checkpoint — may be from a different session. The phase pre-create guard will handle remaining cleanup.')
    }

  } catch (e) {
    // Top-level guard: defensive infrastructure must NEVER halt the pipeline.
    warn(`ARC-6: prePhaseCleanup failed (${e.message}) — proceeding anyway`)
  }
}
```

## Stale Arc Team Scan

CDX-7 Layer 3: Scan for orphaned arc-specific teams from prior sessions. Runs after checkpoint init (where `id` is available) for both new and resumed arcs. Covers both arc-owned teams (`arc-*` prefixes) and sub-command teams (`rune-*` prefixes).

```javascript
// CC-5: Placed after checkpoint init — id is available here
// CC-3: Use find instead of ls -d (SEC-007 compliance)
// SECURITY-CRITICAL: ARC_TEAM_PREFIXES must remain hardcoded string literals.
// These values are interpolated into shell `find -name` commands (see find loop below).
// If externalized to config (e.g., talisman.yml), shell metacharacter injection becomes possible.
//
// arc-* prefixes: teams created directly by arc (plan review, plan inspect, sage, design, gap, test, verify)
// rune-* prefixes: teams created by delegated sub-commands (forge, work, review, mend, audit)
const ARC_TEAM_PREFIXES = [
  "arc-forge-", "arc-plan-review-", "arc-plan-inspect-", "arc-verify-", "arc-gap-fix-", "arc-inspect-", "arc-test-",  // arc-owned teams
  "rune-inspect-",  // inspect skill teams (delegated sub-command)
  "arc-sage-",  // ephemeral elicitation sage team (mend Phase 7 — conditional on P1 findings)
  "arc-storybook-",  // Storybook verification team (conditional — storybook.enabled)
  "arc-design-", "arc-prototype-", "arc-design-verify-", "arc-design-iter-",  // design sync teams (conditional — design_sync.enabled)
  "arc-ux-",  // UX verification team (conditional — ux.enabled + frontend files)
  "arc-deploy-",  // deployment verification team (conditional — deployment-relevant files in diff)
  "arc-codex-sv-", "arc-codex-td-", "arc-codex-ga-", "arc-codex-tc-", "arc-codex-rq-",  // Codex phase handler teams (delegated to codex-phase-handler teammate)
  "rune-forge-", "rune-work-", "rune-review-", "rune-mend-", "rune-mend-deep-", "rune-audit-",  // sub-command teams
  "rune-brainstorm-",  // brainstorm skill teams (Solo/Roundtable/Deep modes)
  "rune-plan-",  // devise skill teams (orphaned from prior /rune:devise sessions)
  "rune-prototype-",  // design-prototype skill teams (conditional — design_sync.enabled)
  "goldmask-"  // goldmask skill teams (Phase 5.7 delegation)
]

// SECURITY: Validate all prefixes before use in shell commands
for (const prefix of ARC_TEAM_PREFIXES) {
  if (!/^[a-z-]+$/.test(prefix)) {
    throw new Error(`Invalid team prefix: ${prefix} (only lowercase letters and hyphens allowed)`)
  }
}

// Collect in-progress teams from checkpoint to exclude from cleanup
const activeTeams = Object.values(checkpoint.phases)
  .filter(p => p.status === "in_progress" && p.team_name)
  .map(p => p.team_name)

// SEC-004 NOTE: This cross-workflow scan runs unconditionally during prePhaseCleanup.
// Architecturally correct for arc (owns all phases, serial execution). Cross-command
// concurrency is now coordinated by the shared workflow lock library
// (scripts/lib/workflow-lock.sh) — concurrent non-arc workflows hold their own locks,
// preventing the stale team scan from interfering with active sessions (PID liveness check).
for (const prefix of ARC_TEAM_PREFIXES) {
  const dirs = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && find "$CHOME/teams" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null`).split('\n').filter(Boolean)
  for (const dir of dirs) {
    // basename() is safe — find output comes from trusted teams/ directory
    const teamName = basename(dir)

    // SEC-003: Validate team name before any filesystem operations
    if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) continue
    // Defense-in-depth: redundant with regex above, per safeTeamCleanup() contract
    if (teamName.includes('..')) continue

    // Don't clean our own team (current arc session)
    // BACK-002 FIX: Use exact prefix+id match instead of fragile substring includes()
    if (teamName === `${prefix}${id}`) continue
    // Don't clean teams that are actively in-progress in checkpoint
    if (activeTeams.includes(teamName)) continue
    // SEC: Symlink attack prevention — don't follow symlinks
    // SEC-006 FIX: Strict equality prevents matching "symlink" in stderr error messages
    if (Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && test -L "$CHOME/teams/${teamName}" && echo symlink`).trim() === "symlink") {
      warn(`ARC-SECURITY: Skipping ${teamName} — symlink detected`)
      continue
    }

    // CDX-7 SESSION MARKER CHECK: Verify owning session is dead before cleaning.
    // .session file is JSON (implemented in v1.124.0 by stamp-team-session.sh) or plain string (legacy).
    // JSON format: {"session_id":"...","owner_pid":"...","config_dir":"..."}
    // If owning session is still alive, skip — this team belongs to a concurrent session.
    const sessionMarker = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cat "$CHOME/teams/${teamName}/.session" 2>/dev/null || true`).trim()
    if (sessionMarker) {
      let markerPid = ""
      let markerCfg = ""
      try {
        const parsed = JSON.parse(sessionMarker)
        markerPid = parsed.owner_pid || ""
        markerCfg = parsed.config_dir || ""
      } catch (e) {
        // Plain string format — no PID info, fall through to cleanup
      }
      if (markerPid && /^\d+$/.test(markerPid)) {
        // Check config_dir first — different installation means not our concern
        const currentCfg = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P || echo "$CHOME"`).trim()
        if (markerCfg && markerCfg !== currentCfg) {
          continue  // Different installation — not our orphan
        }
        // PID liveness check: kill -0 returns 0 if process exists
        const pidAlive = Bash(`kill -0 ${markerPid} 2>/dev/null && echo alive || true`).trim()
        if (pidAlive === "alive") {
          continue  // Owning session still alive — skip cleanup
        }
      }
    }

    // This team is from a different arc session — orphaned (owner PID dead or no marker)
    warn(`CDX-7: Stale arc team from prior session: ${teamName} — cleaning`)
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  }
}
```
