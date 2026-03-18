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
const sessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()  // Standalone variable for use in state writes (Finding 3 fix)
```

## Workflow Lock (reader)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "reader"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
} else if (lockConflicts.includes("ADVISORY")) {
  // ADVISORY = reader/planner + writer coexistence (see workflow-lock.sh compatibility matrix)
  const sanitizedConflicts = lockConflicts.replace(/[<>&"']/g, '')
  log(`Other workflow(s) detected in separate session(s):\n${sanitizedConflicts}\nCross-session concurrency is supported — proceeding normally.`)
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "audit" "reader"`)
```

## Phase 0: Pre-flight

<!-- DELEGATION-CONTRACT: Changes to Phase 0 steps must be reflected in skills/arc/references/arc-delegation-checklist.md -->

Directory scope resolution for `--dirs` and `--exclude-dirs` flags. Merges flag values with talisman defaults, validates paths (SEC: rejects traversal, absolute escape), normalizes, deduplicates, verifies existence, and records `dir_scope` metadata for downstream phases. Then scans project files via `find` (excluding `.git`, `node_modules`, `dist`, etc.).

See [phase-0-dir-scope.md](references/phase-0-dir-scope.md) for the full pseudocode (7-step validation + file scan).

## Phase 0.1-0.4: Incremental Layer (conditional)

**Gate**: Only runs when `isIncremental === true`. When `--incremental` is NOT set, these phases are skipped entirely with zero overhead — the full `all_files` list passes directly to Phase 0.5.

See [incremental-phases.md](references/incremental-phases.md) for the full Phase 0.0-0.4 pseudocode (8 sub-phases: Status-Only Exit, Reset, Lock Acquire, Resume Check, Build Manifest, Manifest Diff, Priority Scoring, Batch Selection).

**Tier 2/3 integration**: See [workflow-discovery.md](references/workflow-discovery.md) and [workflow-audit.md](references/workflow-audit.md) for Tier 2 (cross-file workflow) execution details. See [api-discovery.md](references/api-discovery.md) and [api-audit.md](references/api-audit.md) for Tier 3 (endpoint contract) execution details.

### Load Custom Ashes

After scanning files, check for custom Ash config:

```
1. Read .rune/talisman.yml (project) or ~/.rune/talisman.yml (global)
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
  sessionId: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
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

After orchestration completes: (1) Truthseer Validator for high file counts (>100), (2) incremental result write-back (Phase 7.5) — gated on `isIncremental && incrementalLockAcquired`. Write-back parses TOME findings per file, updates `state.json` with per-file audit status (completed vs error with 3-strike permanent marking), recomputes coverage stats, writes session history, completes checkpoint, releases advisory lock (ownership-checked), and generates coverage report. (3) Interactive prompt for mend/review/rest.

See [incremental-writeback.md](references/incremental-writeback.md) for the full pseudocode.

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
2. First `--incremental` run creates `.rune/audit-state/` and runs a fresh scan
3. All files start as `never_audited` and are prioritized by the scoring algorithm
4. State accumulates across sessions — coverage improves with each run
5. Use `--reset` to clear state and start fresh at any time

**Recovery from state corruption:**

1. `--reset` clears all state files but preserves history
2. If `state.json` is corrupted, it auto-rebuilds from `history/` snapshots
3. If `manifest.json` is corrupted, next run regenerates it from the filesystem
4. Manual recovery: delete `.rune/audit-state/` entirely and start fresh

## References

- [Phase 0 Dir Scope](references/phase-0-dir-scope.md) — Directory scope resolution (7-step validation + file scan)
- [Incremental Write-Back](references/incremental-writeback.md) — Post-orchestration Phase 7.5 (state update, history, checkpoint, lock release)
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
