---
name: audit
description: |
  Full codebase audit using Agent Teams. Sets scope=full and depth=deep (by default),
  then delegates to the shared Roundtable Circle orchestration phases.
  Summons up to 7 built-in Ashes (plus custom from talisman.yml). Optional `--deep`
  runs multi-wave investigation with deep Ashes. Supports `--focus` for targeted audits.
  Supports `--incremental` for stateful, prioritized batch auditing with 3-tier coverage
  tracking (file, workflow, API) and session-persistent audit history.

  <example>
  user: "/rune:audit"
  assistant: "The Tarnished convenes the Roundtable Circle for audit..."
  </example>

  <example>
  user: "/rune:audit --incremental"
  assistant: "The Tarnished initiates incremental audit — scanning manifest, scoring priorities..."
  </example>

  <example>
  user: "/rune:audit --incremental --status"
  assistant: "Incremental Audit Coverage Report: 55.3% file coverage..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[--deep] [--focus <area>] [--max-agents <N>] [--dry-run] [--no-lore] [--deep-lore] [--standard] [--incremental] [--resume] [--status] [--reset] [--tier <file|workflow|api|all>] [--force-files <glob>] [--dirs <path,...>] [--exclude-dirs <path,...>] [--prompt <text>] [--prompt-file <path>]"
allowed-tools:
  - Agent
  - TaskCreate
  - TaskList
  - TaskUpdate
  - TaskGet
  - TeamCreate
  - TeamDelete
  - SendMessage
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

**Runtime context** (preprocessor snapshot):
- Active workflows: !`ls tmp/.rune-*-*.json 2>/dev/null | grep -c '"active"' || echo 0`
- Current branch: !`git branch --show-current 2>/dev/null || echo "n/a"`

# /rune:audit — Full Codebase Audit

Thin wrapper that sets audit-specific parameters, then delegates to the shared Roundtable Circle orchestration. Unlike `/rune:appraise` (which reviews changed files via git diff), `/rune:audit` scans the entire project.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `codex-cli`, `team-sdk`, `polling-guard`, `zsh-compat`

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--focus <area>` | Limit audit to specific area: `security`, `performance`, `quality`, `frontend`, `docs`, `backend`, `full` | `full` |
| `--max-agents <N>` | Cap maximum Ash summoned (1-8, including custom) | All selected |
| `--dry-run` | Show scope selection and Ash plan without summoning agents | Off |
| `--no-lore` | Disable Phase 0.5 Lore Layer (git history risk scoring) | Off |
| `--deep-lore` | Run Lore Layer on ALL files (default: Tier 1 only) | Off |
| `--deep` | Run multi-wave deep audit with deep investigation Ashes | On (default for audit) |
| `--standard` | Override default deep mode — run single-wave standard audit | Off |
| `--incremental` | Enable incremental stateful audit — prioritized batch selection with persistent audit history | Off |
| `--resume` | Resume interrupted incremental audit from checkpoint | Off |
| `--status` | Show coverage report only (no audit performed) | Off |
| `--reset` | Reset incremental audit history and start fresh | Off |
| `--tier <tier>` | Limit incremental audit to specific tier: `file`, `workflow`, `api`, `all` | `all` |
| `--force-files <glob>` | Force specific files into incremental batch regardless of priority score | None |
| `--dirs <path,...>` | Comma-separated list of directories to audit (relative to project root). Overrides talisman `audit.dirs`. Merged with talisman defaults when both are set. | All dirs (talisman or full scan) |
| `--exclude-dirs <path,...>` | Comma-separated list of directories to exclude from audit. Merged with talisman `audit.exclude_dirs`. Flag values take precedence over talisman defaults. | None (plus talisman defaults) |
| `--prompt <text>` | Inline custom inspection criteria injected into every Ash prompt. Sanitized via `sanitizePromptContent()`. Findings use standard prefixes with `source="custom"` attribute. | None |
| `--prompt-file <path>` | Path to a Markdown file containing custom inspection criteria. Loaded, sanitized, and injected into Ash prompts. Takes precedence over `--prompt` when both are set. See [prompt-audit.md](references/prompt-audit.md). | None (or talisman `audit.default_prompt_file`) |

**Note:** Unlike `/rune:appraise`, there is no `--partial` flag. Audit always scans the full project.

**Flag interactions**: `--dirs` and `--exclude-dirs` are pre-filters on the Phase 0 `find` command — they narrow the `all_files` set before it reaches Rune Gaze, the incremental layer, or the Lore Layer (those components receive a smaller array and require zero changes). `--dirs` and `--exclude-dirs` can be combined; `--exclude-dirs` is applied after `--dirs` (intersection then exclusion). `--incremental` and `--deep` are orthogonal. `--incremental --deep` runs incremental file selection (batch) followed by deep investigation Ashes on the selected batch. `--incremental --focus` applies focus filtering BEFORE priority scoring (reduces candidate set, then scores within that set).

**Focus mode** selects only the relevant Ash (see [circle-registry.md](../roundtable-circle/references/circle-registry.md) for the mapping).

**Max agents** reduces team size when context or cost is a concern. Priority order: Ward Sentinel > Forge Warden > Veil Piercer > Pattern Weaver > Glyph Scribe > Knowledge Keeper > Codex Oracle.

## Preamble: Set Parameters

```javascript
// Parse depth: audit defaults to deep (unlike appraise which defaults to standard)
const depth = flags['--standard']
  ? "standard"
  : (flags['--deep'] !== false && (talisman?.audit?.always_deep !== false))
    ? "deep"
    : "standard"

const audit_id = Bash(`date +%Y%m%d-%H%M%S`).trim()
const isIncremental = flags['--incremental'] === true
  && (talisman?.audit?.incremental?.enabled !== false)
let incrementalLockAcquired = false  // Tracks whether THIS session owns the lock (Finding 1/2 fix)
const sessionId = "${CLAUDE_SESSION_ID}"  // Standalone variable for use in state writes (Finding 3 fix)
```

## Workflow Lock (reader)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "reader"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "audit" "reader"`)
```

## Phase 0: Pre-flight

<!-- DELEGATION-CONTRACT: Changes to Phase 0 steps must be reflected in skills/arc/references/arc-delegation-checklist.md -->

```javascript
// ── Directory Scope Resolution (Phase 0 pre-filter) ──
// Security pattern: SAFE_PATH_PATTERN — rejects path traversal and absolute escape
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9._\/-]+$/

// 1. Parse flag values (comma-separated lists)
const flagDirs     = (flags['--dirs']         || "").split(",").map(s => s.trim()).filter(Boolean)
const flagExcludes = (flags['--exclude-dirs'] || "").split(",").map(s => s.trim()).filter(Boolean)

// 2. Merge with talisman defaults (flags override when both present)
//    Array.isArray() guard: talisman values may be strings or undefined
const talismanDirs     = Array.isArray(talisman?.audit?.dirs)         ? talisman.audit.dirs         : []
const talismanExcludes = Array.isArray(talisman?.audit?.exclude_dirs) ? talisman.audit.exclude_dirs : []
const includeDirs  = flagDirs.length     > 0 ? flagDirs     : talismanDirs      // flags override talisman
const excludeDirs  = [...new Set([...talismanExcludes, ...flagExcludes])]        // merge both exclude lists

// 3. Validate paths — reject absolute paths and path traversal
const validateDir = (p) => {
  if (p === "." || p === "./") throw `Rejected "." as dir — use explicit subdirectory paths (e.g., "src/")`
  if (p.startsWith("/"))    throw `Rejected absolute path: "${p}" — use paths relative to project root`
  if (p.includes(".."))     throw `Rejected path traversal: "${p}" — ".." not allowed`
  if (!SAFE_PATH_PATTERN.test(p)) throw `Rejected unsafe path characters in: "${p}"`
  // SECURITY INVARIANT: SAFE_PATH_PATTERN must be checked BEFORE this Bash call.
  // The regex eliminates shell metacharacters, making the interpolation safe.
  const resolved  = Bash(`realpath -m "${p}" 2>/dev/null || echo "INVALID"`).trim()
  const projectRoot = Bash(`pwd -P`).trim()
  if (!resolved.startsWith(projectRoot)) throw `Rejected path escaping project root: "${p}"`
  return true
}
;[...includeDirs, ...excludeDirs].forEach(validateDir)

// 4. Normalize: strip trailing slashes, ensure relative, deduplicate
const normalize = (p) => p.replace(/\/+$/, "").replace(/^\.\//, "")
const normInclude  = [...new Set(includeDirs.map(normalize))]
const normExclude  = [...new Set(excludeDirs.map(normalize))]

// 5. Remove subdirs already covered by a parent (dedup overlapping dirs)
const removeRedundant = (dirs) => dirs.filter(d =>
  !dirs.some(parent => parent !== d && d.startsWith(parent + "/"))
)
const dedupedInclude = removeRedundant(normInclude)

// 6. Verify dirs exist — warn and skip missing, abort if ALL missing
const verifiedInclude = dedupedInclude.filter(d => {
  const exists = Bash(`test -d "${d}" && echo yes || echo no`).trim() === "yes"
  if (!exists) log(`[warn] --dirs path not found, skipping: ${d}`)
  return exists
})
if (dedupedInclude.length > 0 && verifiedInclude.length === 0) {
  throw "All --dirs paths are missing or invalid — nothing to audit."
}

// 7. Record dir_scope metadata for downstream phases
// Contract: when include=null, full repo scope. Excludes are already applied at the find step
// and need not be re-applied by Ashes. Ashes receiving dir_scope in inscription should check
// include !== null before scoping — a truthy object with include=null means "full repo with excludes".
const dir_scope = {
  include: verifiedInclude.length > 0 ? verifiedInclude : null,  // null = scan everything
  exclude: normExclude
}
```

```bash
# Scan all project files (excluding non-project directories)
# When --dirs provided, scope find to verified include paths instead of '.'
# dir_scope.include and dir_scope.exclude are resolved from the JavaScript block above.
all_files=$(find ${dir_scope.include ? dir_scope.include.map(p => `"${p}"`).join(" ") : "."} -type f \
  ! -path '*/.git/*' \
  ! -path '*/node_modules/*' \
  ! -path '*/__pycache__/*' \
  ! -path '*/tmp/*' \
  ! -path '*/dist/*' \
  ! -path '*/build/*' \
  ! -path '*/.next/*' \
  ! -path '*/.venv/*' \
  ! -path '*/venv/*' \
  ! -path '*/target/*' \
  ! -path '*/.tox/*' \
  ! -path '*/vendor/*' \
  ! -path '*/.cache/*' \
$(dir_scope.exclude.map(d => `  ! -path '*/${d}/*'`).join(" \\\n")) \
  | sort)

# Optional: get branch name for metadata (not required — audit works without git)
branch=$(git branch --show-current 2>/dev/null || echo "n/a")
```

**Abort conditions:**
- No files found -> "No files to audit in current directory."
- Only non-reviewable files -> "No auditable code found."

**Note:** Unlike `/rune:appraise`, audit does NOT require a git repository.

## Phase 0.1-0.4: Incremental Layer (conditional)

**Gate**: Only runs when `isIncremental === true`. When `--incremental` is NOT set, these phases are skipped entirely with zero overhead — the full `all_files` list passes directly to Phase 0.5.

See [incremental-phases.md](references/incremental-phases.md) for the full Phase 0.0-0.4 pseudocode (8 sub-phases: Status-Only Exit, Reset, Lock Acquire, Resume Check, Build Manifest, Manifest Diff, Priority Scoring, Batch Selection).

**Tier 2/3 integration**: See [workflow-discovery.md](references/workflow-discovery.md) and [workflow-audit.md](references/workflow-audit.md) for Tier 2 (cross-file workflow) execution details. See [api-discovery.md](references/api-discovery.md) and [api-audit.md](references/api-audit.md) for Tier 3 (endpoint contract) execution details.

### Load Custom Ashes

After scanning files, check for custom Ash config:

```
1. Read .claude/talisman.yml (project) or ~/.claude/talisman.yml (global)
2. If ashes.custom[] exists:
   a. Validate: unique prefixes, unique names, resolvable agents, count <= max
   b. Filter by workflows: keep only entries with "audit" in workflows[]
   c. Match triggers against all_files (extension + path match)
   d. Skip entries with fewer matching files than trigger.min_files
3. Merge validated custom Ash with built-in selections
4. Apply defaults.disable_ashes to remove any disabled built-ins
```

See [custom-ashes.md](../roundtable-circle/references/custom-ashes.md) for full schema and validation rules.

### Detect Codex Oracle

See [codex-detection.md](../roundtable-circle/references/codex-detection.md) for the canonical detection algorithm.

## Phase 0.5: Lore Layer (Risk Intelligence)

See [deep-mode.md](references/deep-mode.md) for the full Lore Layer implementation.

**Skip conditions**: non-git repo, `--no-lore`, `talisman.goldmask.layers.lore.enabled === false`, fewer than 5 commits in lookback window (G5 guard).

## Phase 1: Rune Gaze (Scope Selection)

Classify ALL project files by extension. See [rune-gaze.md](../roundtable-circle/references/rune-gaze.md).

**Apply `--focus` filter:** If `--focus <area>` is set, only summon Ash matching that area.
**Apply `--max-agents` cap:** If `--max-agents N` is set, limit selected Ash to N.

**Large codebase warning:** If total reviewable files > 150, log a coverage note.

### Dry-Run Exit Point

If `--dry-run` flag is set, display the plan and stop. No teams, tasks, state files, or agents are created.

## Delegate to Shared Orchestration

Set parameters and execute shared phases from [orchestration-phases.md](../roundtable-circle/references/orchestration-phases.md).

```javascript
// ── Resolve session identity ──
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

const params = {
  scope: "full",
  depth,
  teamPrefix: "rune-audit",
  outputDir: `tmp/audit/${audit_id}/`,
  stateFilePrefix: "tmp/.rune-audit",
  identifier: audit_id,
  selectedAsh,
  fileList: all_files,
  timeoutMs: 900_000,   // 15 min (audits cover more files than reviews)
  label: "Audit",
  configDir, ownerPid,
  sessionId: "${CLAUDE_SESSION_ID}",
  maxAgents: flags['--max-agents'],
  workflow: "rune-audit",
  focusArea: flags['--focus'] || "full",
  dirScope: dir_scope,      // #20: { include: string[]|null, exclude: string[] } — resolved in Phase 0
  customPromptBlock: resolveCustomPromptBlock(flags, talisman),  // #21: from --prompt / --prompt-file (null if not set). See references/prompt-audit.md
  flags, talisman
}

// Execute Phases 1-7 from orchestration-phases.md
// Phase 1: Setup (state file, output dir)
// Phase 2: Forge Team (inscription, signals, tasks)
// Phase 3: Summon (single wave or multi-wave based on depth)
// Phase 4: Monitor (waitForCompletion with audit timeouts)
// Phase 4.5: Doubt Seer (conditional)
// Phase 5: Aggregate (Runebinder → TOME.md)
// Phase 6: Verify (Truthsight)
// Phase 7: Cleanup (shutdown, TeamDelete, state update, Echo persist)
//   Includes: Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "audit"`)
```

### Audit-Specific Post-Orchestration

After orchestration completes:

```javascript
// 1. Truthseer Validator (for high file counts)
if (reviewableFileCount > 100) {
  // Summon Truthseer Validator — see roundtable-circle SKILL.md Phase 5.5
  // Cross-references finding density against file importance
}

// ── Incremental Result Write-Back (Phase 7.5) ──
// Gate: only run when this session actually acquired the lock and created a checkpoint.
// If we fell back to full audit (lock held by another session), skip write-back entirely.
if (isIncremental && incrementalLockAcquired) {
  // Read current state
  const state = Read(".claude/audit-state/state.json")
  const checkpoint = Read(".claude/audit-state/checkpoint.json")

  // Parse TOME for findings per file
  const tome = Read(`${outputDir}/TOME.md`)
  const findingsPerFile = parseTomeFindings(tome)

  // Determine which files actually completed vs failed (Finding 4 fix)
  // Files present in TOME with findings (even zero) are completed; files absent from TOME are failed
  const tomeFilePaths = new Set(Object.keys(findingsPerFile))
  const filesCompleted = checkpoint.batch.filter(f => tomeFilePaths.has(f))
  const filesFailed = checkpoint.batch.filter(f => !tomeFilePaths.has(f))

  // Update state.json for each audited file
  const fileManifestData = Read(".claude/audit-state/manifest.json")
  for (const filePath of checkpoint.batch) {
    const wasCompleted = tomeFilePaths.has(filePath)
    const findings = findingsPerFile[filePath] || { P1: 0, P2: 0, P3: 0, total: 0 }
    const fileManifest = fileManifestData?.files?.[filePath]

    if (wasCompleted) {
      state.files[filePath] = {
        ...state.files[filePath],
        last_audited: new Date().toISOString(),
        last_audit_id: audit_id,
        last_git_hash: fileManifest?.git?.current_hash || null,
        changed_since_audit: false,
        audit_count: (state.files[filePath]?.audit_count || 0) + 1,
        audited_by: [...new Set([...(state.files[filePath]?.audited_by || []), ...selectedAsh])],
        findings,
        status: "audited",
        consecutive_error_count: 0
      }
      // Remove from coverage_gaps if present
      delete state.coverage_gaps?.[filePath]
    } else {
      // File was in batch but absent from TOME — mark as error for re-queue
      const errorCount = (state.files[filePath]?.consecutive_error_count || 0) + 1
      state.files[filePath] = {
        ...state.files[filePath],
        status: errorCount >= 3 ? "error_permanent" : "error",
        consecutive_error_count: errorCount,
        last_audit_id: audit_id
      }
    }
  }

  // Recompute stats
  const auditable = Object.values(state.files).filter(f => !["excluded","deleted"].includes(f.status))
  const audited = auditable.filter(f => f.status === "audited")
  state.stats = {
    total_auditable: auditable.length,
    total_audited: audited.length,
    total_never_audited: auditable.filter(f => f.status === "never_audited").length,
    coverage_pct: auditable.length > 0 ? Math.round(audited.length / auditable.length * 1000) / 10 : 0,
    freshness_pct: 0, // Computed from staleness window
    avg_findings_per_file: audited.length > 0
      ? Math.round(audited.reduce((s, f) => s + (f.findings?.total || 0), 0) / audited.length * 10) / 10 : 0,
    avg_ashes_per_file: 0
  }
  state.total_sessions = (state.total_sessions || 0) + 1
  state.updated_at = new Date().toISOString()

  // Atomic write state
  Write(".claude/audit-state/state.json", state)

  // Write session history
  const coverageBefore = checkpoint.coverage_before || 0
  Write(`.claude/audit-state/history/audit-${audit_id}.json`, {
    audit_id, timestamp: new Date().toISOString(),
    mode: "incremental", depth,
    batch_size: checkpoint.batch.length,
    files_planned: checkpoint.batch,
    files_completed: filesCompleted,
    files_failed: filesFailed,
    total_findings: Object.values(findingsPerFile).reduce((s, f) => s + f.total, 0),
    findings_by_severity: {
      P1: Object.values(findingsPerFile).reduce((s, f) => s + f.P1, 0),
      P2: Object.values(findingsPerFile).reduce((s, f) => s + f.P2, 0),
      P3: Object.values(findingsPerFile).reduce((s, f) => s + f.P3, 0)
    },
    coverage_before: coverageBefore,
    coverage_after: state.stats.coverage_pct,
    config_dir: configDir, owner_pid: ownerPid, session_id: sessionId
  })

  // Complete checkpoint
  Write(".claude/audit-state/checkpoint.json", {
    ...checkpoint, status: "completed",
    completed: checkpoint.batch, current_file: null
  })

  // Release advisory lock (ownership-checked per incremental-state-schema.md protocol)
  const lockMeta = Read(".claude/audit-state/.lock/meta.json")
  if (lockMeta?.pid == ownerPid) {
    Bash(`rm -rf .claude/audit-state/.lock`)
  } // else: not our lock — skip (Finding 2 fix)

  // Generate coverage report
  // See references/coverage-report.md
  log(`Incremental audit complete: ${checkpoint.batch.length} files audited`)
  log(`Coverage: ${state.stats.coverage_pct}% (${state.stats.total_audited}/${state.stats.total_auditable})`)

  // Persist echo
  // Write coverage summary to .claude/echoes/auditor/MEMORY.md
}

// 2. Auto-mend or interactive prompt (same as appraise)
if (totalFindings > 0) {
  AskUserQuestion({
    options: ["/rune:mend (Recommended)", "Review TOME manually", "/rune:rest"]
  })
}
```

## Error Handling

| Error | Recovery |
|-------|----------|
| Ash timeout (>5 min) | Proceed with partial results |
| Total timeout (>15 min) | Final sweep, collect partial results, report incomplete |
| Ash crash | Report gap in TOME.md |
| ALL Ash fail | Abort, notify user |
| Concurrent audit running | Warn, offer to cancel previous |
| File count exceeds 150 | Warn about partial coverage, proceed with capped budgets |
| Not a git repo | Works fine — audit uses `find`, not `git diff`. Incremental degrades to mtime-based scoring. |
| Codex CLI not installed | Skip Codex Oracle |
| Codex not authenticated | Skip Codex Oracle |
| Codex disabled in talisman.yml | Skip Codex Oracle |
| State file corrupted | Rebuild from `history/` snapshots (see incremental-state-schema.md) |
| State file locked (dead PID) | Detect dead PID via `kill -0`, remove stale lock, proceed |
| Concurrent incremental sessions | Second session warns, falls back to full audit |
| Manifest too large (>10k files) | Still functional; consider sharding for performance |
| Checkpoint from dead session | Clean up, start fresh batch |
| Disk full during state write | Pre-flight check: skip incremental if <10MB available |
| Error file infinite re-queue | 1st error re-queue, 2nd skip-one-batch, 3rd+ mark `error_permanent` |

## Migration Guide (Concern 6)

**Upgrading from non-incremental to incremental audit:**

1. No migration needed — `--incremental` is opt-in and does not affect default behavior
2. First `--incremental` run creates `.claude/audit-state/` and runs a fresh scan
3. All files start as `never_audited` and are prioritized by the scoring algorithm
4. State accumulates across sessions — coverage improves with each run
5. Use `--reset` to clear state and start fresh at any time

**Recovery from state corruption:**

1. `--reset` clears all state files but preserves history
2. If `state.json` is corrupted, it auto-rebuilds from `history/` snapshots
3. If `manifest.json` is corrupted, next run regenerates it from the filesystem
4. Manual recovery: delete `.claude/audit-state/` entirely and start fresh

## References

- [Deep Mode](references/deep-mode.md) — Lore Layer, deep pass, TOME merge
- [Orchestration Phases](../roundtable-circle/references/orchestration-phases.md) — Shared parameterized orchestration
- [Circle Registry](../roundtable-circle/references/circle-registry.md) — Ash-to-scope mapping, focus mode
- [Smart Selection](../roundtable-circle/references/smart-selection.md) — File assignment, budget enforcement
- [Wave Scheduling](../roundtable-circle/references/wave-scheduling.md) — Multi-wave deep scheduling
- [Incremental Phases](references/incremental-phases.md) — Full Phase 0.0-0.4 pseudocode (extracted from SKILL.md)
- [Incremental State Schema](references/incremental-state-schema.md) — State files, locking, atomic writes, schema migration
- [Codebase Mapper](references/codebase-mapper.md) — File inventory, git metadata, manifest diff
- [Priority Scoring](references/priority-scoring.md) — 6-factor composite algorithm, batch selection
- [Workflow Discovery](references/workflow-discovery.md) — Tier 2 cross-file flow detection
- [Workflow Audit](references/workflow-audit.md) — Tier 2 cross-file review protocol
- [API Discovery](references/api-discovery.md) — Tier 3 endpoint contract detection
- [API Audit](references/api-audit.md) — Tier 3 endpoint contract review, OWASP checks
- [Coverage Report](references/coverage-report.md) — Human-readable dashboard, freshness tiers
