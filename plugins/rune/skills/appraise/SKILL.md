---
name: appraise
description: |
  Multi-agent code review using Agent Teams. Summons up to 8 built-in Ashes
  (plus custom Ash from talisman.yml), each with their own dedicated context window.
  Handles scope selection, team creation, review orchestration, aggregation, verification, and cleanup.
  Optional `--deep` runs multi-wave deep review with up to 18 Ashes across 3 waves.
  Phase 1.5 adds UX reviewers when `talisman.ux.enabled` + frontend files detected.
  Phase 1.6 adds design fidelity reviewer (DES prefix) when `talisman.design_review.enabled` + frontend files detected.
  Phase 1.7 adds data flow integrity reviewer (FLOW prefix) when 2+ stack layers detected in diff.

  <example>
  user: "/rune:appraise"
  assistant: "The Tarnished convenes the Roundtable Circle for review..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[--deep | --partial | --dry-run | --max-agents <N> | --no-chunk | --chunk-size <N> | --no-converge | --cycles <N> | --scope-file <path> | --no-lore | --auto-mend]"
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
- Active workflows: !`find tmp -maxdepth 1 -name '.rune-*-*.json' -exec grep -l '"running"' {} + 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:appraise — Multi-Agent Code Review

Orchestrate a multi-agent code review using the Roundtable Circle architecture. Each Ash gets its own dedicated context window via Agent Teams.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `codex-cli`, `team-sdk`, `polling-guard`, `zsh-compat`

## Spec-Aware Review (Discipline Integration)

When a `plan_file_path` is available (passed via arc Phase 6, or set in the inscription context), reviewers receive plan acceptance criteria in their inscription context. This enables spec-aware review — checking "does code match spec" in addition to "is code good".

**Plan context injection** (3 items added to reviewer inscription):
1. **Plan file path** + extracted acceptance criteria (AC-N entries)
2. **Plan type** (feat/fix/refactor from frontmatter) — affects what to look for
3. **Reviewer SOW**: Which criteria this reviewer is responsible for checking

**Review findings can reference plan criteria IDs** (AC-N) when applicable:
```
BACK-003 (P2): AC-2.3 (rate limiting) not fully implemented — missing 429 response code
```

**Without plan**: Standard code quality review ("Code is clean, LGTM")
**With plan**: Spec-aware review ("AC-3 timeout handling not implemented in src/api.ts")

**Activation**: Automatic when `plan_file_path` is in the orchestration params or inscription context. No flag needed — the presence of plan context activates spec-aware behavior.

## Orchestration Parameters

Appraise sets these parameters before delegating to the shared [orchestration-phases.md](../roundtable-circle/references/orchestration-phases.md):

```javascript
const params = {
  scope: "diff",                          // Always diff for appraise (changed files only)
  depth: flags['--deep'] ? "deep" : "standard",  // Standard by default, deep with --deep
  teamPrefix: "rune-review",
  outputDir: `tmp/reviews/${identifier}/`,
  stateFilePrefix: "tmp/.rune-review",
  identifier,                              // "{gitHash}-{shortSession}"
  timeoutMs: 600_000,                      // 10 min
  label: "Review",
  workflow: "rune-review",
  focusArea: "full",                       // Appraise has no --focus flag
  // + configDir, ownerPid, sessionId (session isolation)
  // + selectedAsh, fileList, maxAgents, flags, talisman
}
```

**Standard depth** (default): Single-pass review with up to 7 Wave 1 Ashes. Identical to pre-deep behavior.

**Deep depth** (`--deep`): Multi-wave review. Phase 3 loops over waves from `selectWaves()`. Each wave creates its own team, tasks, and monitor cycle. See [orchestration-phases.md](../roundtable-circle/references/orchestration-phases.md) for the full wave execution loop.

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--deep` | Run multi-wave deep review: Wave 1 (core, up to 7 Ashes) + Wave 2 (investigation, 4 Ashes) + Wave 3 (dimension, up to 7 Ashes). Each wave runs as a full Roundtable Circle pass. | Off |
| `--partial` | Review only staged files (`git diff --cached`) instead of full branch diff | Off |
| `--dry-run` | Execute Phase 0 (Pre-flight) and Phase 1 (Rune Gaze) only. Display changed files, Ash selections, chunk plan, then exit. Does NOT create teams, tasks, state files, or spawn agents. | Off |
| `--max-agents <N>` | Limit total Ash summoned (1-8). Priority: Ward Sentinel > Forge Warden > Veil Piercer > Pattern Weaver > Glyph Scribe > Knowledge Keeper > Codex Oracle | All selected |
| `--no-chunk` | Force single-pass review (disable chunking) | Off |
| `--chunk-size <N>` | Override chunk threshold — file count that triggers chunking (default: 20) | 20 |
| `--no-converge` | Disable convergence loop — single review pass per chunk | Off |
| `--cycles <N>` | Run N standalone review passes with TOME merge (1-5, numeric only) | 1 |
| `--scope-file <path>` | Override `changed_files` with a JSON file `{ focus_files: [...] }`. Used by arc convergence controller | None |
| `--no-lore` | Disable Phase 0.5 Lore Layer (git history risk scoring) | Off |
| `--auto-mend` | Automatically invoke `/rune:mend` after review if P1/P2 findings exist | Off |

**Partial mode** is useful for reviewing a subset of changes before committing.

**Deep mode** runs 3 waves of review with up to 18 Ashes total (excludes Phase 1.6 design reviewer — that activates in standard mode too). See [orchestration-phases.md](../roundtable-circle/references/orchestration-phases.md) for the wave execution pattern and [wave-scheduling.md](../roundtable-circle/references/wave-scheduling.md) for wave selection logic.

**Dry-run mode** executes Phase 0 (Pre-flight) and Phase 1 (Rune Gaze) only, then displays changed files classified by type, which Ash would be summoned, file assignments per Ash, estimated team size, and chunk plan if file count exceeds `CHUNK_THRESHOLD`. No teams, tasks, state files, or agents are created. If `--deep + --partial` is used, displays a warning about sparse findings from investigation Ashes.

### Flag Interactions

| Combination | Behavior |
|-------------|----------|
| `--deep + --partial` | Warning: "Deep review on staged-only changes may produce sparse findings from investigation Ashes." Proceeds (not a hard error). |
| `--deep + --cycles N` (N > 1) | Warning: "Deep review with N cycles runs N x 3 waves (up to {N*18} agent invocations). This is expensive." Proceeds. |
| `--deep + --max-agents N` | Applies to Wave 1 only. Wave 2/3 agents are not subject to --max-agents cap (they are deepOnly). |
| `--deep + --no-converge` | Deep waves still execute. `--no-converge` affects per-chunk convergence, not wave scheduling. |

## Workflow Lock (reader)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "reader"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
} else if (lockConflicts.includes("ADVISORY")) {
  // ADVISORY = reader/planner + writer coexistence (see workflow-lock.sh compatibility matrix)
  // SEC-6 FIX: sanitize lockConflicts output before interpolation
  const sanitizedConflicts = lockConflicts.replace(/[<>&"']/g, '')
  log(`Other workflow(s) detected in separate session(s):\n${sanitizedConflicts}\nCross-session concurrency is supported — proceeding normally.`)
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "appraise" "reader"`)
```

## Phase 0: Pre-flight

Collect changed files and generate diff ranges. For detailed scope algorithms, staged/unstaged/HEAD~N detection, chunk routing, and `--scope-file` override logic — see [review-scope.md](references/review-scope.md).

**Core steps:**
1. Detect `default_branch` from git remote/fallback
2. Build `changed_files` — committed + staged + unstaged + untracked (or staged-only for `--partial`)
3. Filter: remove non-existent files, symlinks
4. Generate diff ranges for Phase 5.3 scope tagging (see [diff-scope.md](../rune-orchestration/references/diff-scope.md))

**Abort conditions:**
- No changed files → "Nothing to review. Make some changes first."
- Only non-reviewable files → "No reviewable changes found."

After file collection — route to chunked path if `changed_files.length > CHUNK_THRESHOLD` and `--no-chunk` is not set. Route to multi-pass if `--cycles N` with N > 1. Note: `--cycles N` is an alternative to chunking — it runs N standalone review passes with TOME merge between passes, useful for catching issues that require multiple passes.

## Phase 0.3: Context Intelligence

Gathers PR metadata and linked issue context. Injects `contextIntel` into inscription.json (Phase 2). Includes `sanitizeUntrustedText()` for CDX-001/CVE-2021-42574 protection. Skipped when no `gh` CLI, `--partial`, or disabled in talisman.

## Phase 0.4: Linter Detection

Discovers project linters (eslint, prettier, ruff, clippy, etc.) to suppress duplicate findings. SEC-*/VEIL-* findings are NEVER suppressed. Configurable via `talisman.review.linter_awareness`.

See [phase-0.3-0.4-context-and-linter.md](references/phase-0.3-0.4-context-and-linter.md) for full pseudocode, sanitization function, and talisman config.

## Phase 0.5: Lore Layer (Risk Intelligence)

Runs BEFORE team creation. Summons `lore-analyst` as a bare Agent (no team yet — ATE-1 exemption). Outputs `risk-map.json` and `lore-analysis.md`. Re-sorts `changed_files` by risk tier (CRITICAL → HIGH → MEDIUM → LOW → STALE).

**Skip conditions**: non-git repo, `--no-lore`, `talisman.goldmask.layers.lore.enabled === false`, fewer than 5 commits in lookback window (G5 guard).

## Phase 0.6: Context Building (Conditional)

Runs BEFORE team creation. Spawns `context-builder` as a bare Agent (no TaskCreate, no team_name — same pattern as Phase 0.5 Lore Layer). Produces `context-map.md` for injection into Ash prompts.

**Gate logic** (talisman `review.context_building`):
```
const reviewConfig = readTalismanSection("review")
const contextBuilding = reviewConfig?.context_building ?? "auto"
const threshold = reviewConfig?.context_building_threshold ?? { lines: 500, files: 5 }
const timeoutMs = reviewConfig?.context_building_timeout ?? 60000

if (contextBuilding === "never") → skip
if (flags['--dry-run']) → skip
if (contextBuilding === "always") → run
if (contextBuilding === "auto" && (diffLineCount > threshold.lines || fileCount >= threshold.files)) → run
else → skip("[Context] Skipped — diff below threshold ({diffLineCount} lines, {fileCount} files)")
```

**Execution** (blocking bare Agent with timeout enforcement — CONCERN-1, CONCERN-2):
```
const contextOutputPath = `${outputDir}context-map.md`

// Use blocking Agent call with elapsed-time timeout check (AC-6)
const contextStartTime = Date.now()
Agent({
  subagent_type: "rune:research:context-builder",
  prompt: `Build a LIGHTWEIGHT context map for code review (not full audit).

SCOPE: Only analyze these changed files and their direct imports:
${changedFiles.map(f => '- ' + f).join('\n')}

OUTPUT: Write to ${contextOutputPath}. Format:
## Trust Boundaries (max 5 entries)
- [BOUNDARY-N] {description} at {file:line} via {mechanism}
## Data Flow Paths (max 5 entries)
- [FLOW-N] {source} → {transform} → {sink} (files: {list})
## State Invariants (max 5 entries)
- [INV-N] {description} — ENFORCED|ASSUMED at {file:line}
## Entry Points (max 5 entries)
- [ENTRY-N] {route/handler} at {file:line} — reaches changed code via {path}
## Key Dependencies (max 5 entries)
- [DEP-N] {module} — guarantees: {what it provides}

CONSTRAINTS:
- Total output MUST be under 80 lines (2000 token budget)
- ONLY map architecture relevant to the changed files
- Cite file:line for every claim
- COMPREHENSION ONLY — do NOT report vulnerabilities
- Time budget: 45 seconds (leave 15s buffer for I/O)`,
  model: "sonnet"
})

// Check timeout after blocking call returns (timeoutMs from talisman, default 60000)
const contextElapsed = Date.now() - contextStartTime
if (contextElapsed > timeoutMs) {
  warn(`[Context] Context building exceeded ${timeoutMs}ms (took ${contextElapsed}ms)`)
}

// Read output with existence check
contextMap = null
try {
  const content = Read(contextOutputPath)
  if (content && content.trim().length >= 100) {
    contextMap = content
    log(`[Context] Built context map — ${countEntries(content)} entries (${contextElapsed}ms)`)
  } else {
    log("[Context] Context map too small or empty — proceeding without context")
  }
} catch {
  log("[Context] Context builder timed out or failed — proceeding without context")
}
```

**Skip conditions**: `--dry-run`, `review.context_building === "never"`, diff below auto thresholds.

## Phase 1: Rune Gaze (Scope Selection)

Classifies changed files by extension → selects Ashes. Custom Ash discovery (agent-backed + CLI-backed) happens here. Phase 1.5 adds UX reviewers when `talisman.ux.enabled` + frontend files detected. Phase 1.6 adds design fidelity reviewer (`DES`-prefixed findings) when `talisman.design_review.enabled` + frontend files detected. `--dry-run` exits after this phase.

See [phase-1-rune-gaze.md](references/phase-1-rune-gaze.md) for full classification table, UX gate, and dry-run exit. See [rune-gaze.md](../roundtable-circle/references/rune-gaze.md) for the base algorithm.

## Phase 2: Forge Team

Creates session-scoped identifier (`{gitHash}-{shortSession}`), writes state file with session isolation, generates inscription.json (diff_scope + context_intelligence + linter_context), runs teamTransition protocol, creates signal dir, and creates one task per Ash.

See [phase-2-forge-team.md](references/phase-2-forge-team.md) for full pseudocode. See [engines.md](../team-sdk/references/engines.md) for teamTransition protocol.

## Phase 3: Summon Ash

Read and execute [ash-summoning.md](references/ash-summoning.md) for the full prompt generation contract, inscription contract, talisman custom Ashes, CLI-backed Ashes, and elicitation sage security context.

**Key rules:**
- Summon ALL selected Ash in a **single message** (parallel execution)
- Built-in Ash: load prompt from `../../agents/{category}/{role}.md`
- Custom Ash: use wrapper template from `roundtable-circle/references/custom-ashes.md`
- Write file list to `tmp/reviews/{identifier}/changed-files.txt` — do NOT embed raw paths in prompts (SEC-006)

## Phase 4: Monitor

Poll TaskList with timeout guard until all tasks complete. Uses the shared polling utility — see [`skills/roundtable-circle/references/monitor-utility.md`](../roundtable-circle/references/monitor-utility.md).

```
POLL_INTERVAL = 30          // seconds
MAX_ITERATIONS = 20         // ceil(600_000 / 30_000) = 20 cycles = 10 min timeout
STALE_WARN = 300_000        // 5 minutes

for iteration in 1..MAX_ITERATIONS:
  1. Call TaskList tool            ← MANDATORY every cycle
  2. Count completed vs ashCount
  3. If completed >= ashCount → break
  4. Check stale: any task in_progress > 5 min → log warning
  5. Call Bash("sleep 30")
```

**Stale detection**: If a task is `in_progress` for > 5 minutes, log a warning. No auto-release — review Ash findings are non-fungible.

## Phase 4.5 + Phase 5 + Phase 5.3 + Phase 5.5 + Phase 6

Read and execute [tome-aggregation.md](references/tome-aggregation.md) for the full Runebinder aggregation, Doubt Seer cross-examination, diff-scope tagging, Codex Oracle verification, and Truthsight verification protocols.

**Summary of phases:**
- **Phase 4.5 (Doubt Seer)**: Conditional. Strict opt-in (`talisman.doubt_seer.enabled = true`). Cross-examines P1/P2 findings. 5-min timeout. VERDICT: BLOCK sets `workflow_blocked` flag.
- **Phase 5 (Runebinder)**: Aggregates all Ash findings. Deduplicates using `SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > DES > AESTH > UXH > UXF > UXI > UXC > CDX` hierarchy. Writes `TOME.md`. Every finding MUST be wrapped in `<!-- RUNE:FINDING ... -->` markers for mend parsing.
- **Phase 5.3 (Diff-Scope Tagging)**: Orchestrator-only. Tags findings with `scope="in-diff"` or `scope="pre-existing"`.
- **Phase 5.5 (Cross-Model Verification)**: Only if Codex Oracle was summoned. Verifies CDX findings against source. Removes HALLUCINATED + UNVERIFIED findings.
- **Phase 6 (Truthsight)**: Layer 0 inline checks + Layer 2 verifier for P1 findings.

## Phase 7: Cleanup & Echo Persist

Dynamic member discovery → shutdown_request → grace period → TeamDelete with retry-with-backoff (4 attempts) → filesystem fallback → release workflow lock → update state file → persist P1/P2 patterns to echoes → present TOME → auto-mend or interactive prompt.

See [phase-7-cleanup.md](references/phase-7-cleanup.md) for full pseudocode.

## Error Handling

| Error | Recovery |
|-------|----------|
| Ash timeout (>5 min) | Proceed with partial results |
| Total timeout (>10 min) | Final sweep, collect partial results, report incomplete |
| Ash crash | Report gap in TOME.md |
| ALL Ash fail | Abort, notify user |
| Concurrent review running | Warn, offer to cancel previous |
| Codex CLI not installed | Skip Codex Oracle, log: "CLI not found" |
| Codex not authenticated | Skip Codex Oracle, log: "run `codex login`" |
| Codex disabled in talisman.yml | Skip Codex Oracle, log: "disabled via talisman.yml" |
| Codex exec timeout (>10 min) | Codex Oracle partial results, log: "timeout — reduce context_budget" |
| jq unavailable | Codex Oracle uses raw text fallback instead of JSONL parsing |
