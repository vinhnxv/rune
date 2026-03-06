---
name: appraise
description: |
  Multi-agent code review using Agent Teams. Summons up to 7 built-in Ashes
  (plus custom Ash from talisman.yml), each with their own dedicated context window.
  Handles scope selection, team creation, review orchestration, aggregation, verification, and cleanup.
  Optional `--deep` runs multi-wave deep review with up to 18 Ashes across 3 waves.

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
- Active workflows: !`ls tmp/.rune-*-*.json 2>/dev/null | grep -c '"active"' || echo 0`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:appraise — Multi-Agent Code Review

Orchestrate a multi-agent code review using the Roundtable Circle architecture. Each Ash gets its own dedicated context window via Agent Teams.

**Load skills**: `roundtable-circle`, `context-weaving`, `rune-echoes`, `rune-orchestration`, `codex-cli`, `team-sdk`, `polling-guard`, `zsh-compat`

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
| `--dry-run` | Show scope selection, Ash plan, and chunk plan without summoning agents | Off |
| `--max-agents <N>` | Limit total Ash summoned (1-8). Priority: Ward Sentinel > Forge Warden > Veil Piercer > Pattern Weaver > Glyph Scribe > Knowledge Keeper > Codex Oracle | All selected |
| `--no-chunk` | Force single-pass review (disable chunking) | Off |
| `--chunk-size <N>` | Override chunk threshold — file count that triggers chunking (default: 20) | 20 |
| `--no-converge` | Disable convergence loop — single review pass per chunk | Off |
| `--cycles <N>` | Run N standalone review passes with TOME merge (1-5, numeric only) | 1 |
| `--scope-file <path>` | Override `changed_files` with a JSON file `{ focus_files: [...] }`. Used by arc convergence controller | None |
| `--no-lore` | Disable Phase 0.5 Lore Layer (git history risk scoring) | Off |
| `--auto-mend` | Automatically invoke `/rune:mend` after review if P1/P2 findings exist | Off |

**Partial mode** is useful for reviewing a subset of changes before committing.

**Deep mode** runs 3 waves of review with up to 18 Ashes total. See [orchestration-phases.md](../roundtable-circle/references/orchestration-phases.md) for the wave execution pattern and [wave-scheduling.md](../roundtable-circle/references/wave-scheduling.md) for wave selection logic.

**Dry-run mode** executes Phase 0 (Pre-flight) and Phase 1 (Rune Gaze) only, then displays changed files classified by type, which Ash would be summoned, file assignments per Ash, estimated team size, and chunk plan if file count exceeds `CHUNK_THRESHOLD`. No teams, tasks, state files, or agents are created.

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

After file collection — route to chunked path if `changed_files.length > CHUNK_THRESHOLD` and `--no-chunk` is not set. Route to multi-pass if `--cycles N` with N > 1.

## Phase 0.3: Context Intelligence

Gather PR metadata and linked issue context for downstream Ash consumption. Runs AFTER Phase 0, BEFORE Phase 0.5.

**Skip conditions**: `talisman.review.context_intelligence.enabled === false`, no `gh` CLI, `--partial` mode, non-git repo.

See [context-intelligence.md](../roundtable-circle/references/context-intelligence.md) for the full contract, schema, and security model.

```javascript
// sanitizeUntrustedText — canonical sanitization for user-authored content
// Used by: Phase 0.3 (PR body, issue body), plan.md (plan content)
// Security: CDX-001 (prompt injection), CVE-2021-42574 (Trojan Source)
function sanitizeUntrustedText(text, maxChars) {
  return (text || '')
    .replace(/<!--[\s\S]*?-->/g, '')              // Strip HTML comments
    .replace(/```[\s\S]*?```/g, '[code-block]')    // Neutralize code fences
    .replace(/!\[.*?\]\(.*?\)/g, '')               // Strip image/link injection
    .replace(/^#{1,6}\s+/gm, '')                   // Strip heading overrides
    .replace(/[\u200B-\u200F\uFEFF\uFE00-\uFE0F]/g, '')  // Strip zero-width chars + variation selectors
    .replace(/\uDB40[\uDC00-\uDC7F]/g, '')         // Strip tag block characters (U+E0000-E007F)
    .replace(/[\u202A-\u202E\u2066-\u2069]/g, '')  // Strip Unicode directional overrides (CVE-2021-42574)
    .replace(/&[a-zA-Z0-9#]+;/g, '')               // Strip HTML entities
    .slice(0, maxChars)
}
```

Context intelligence result (`contextIntel`) is injected into inscription.json in Phase 2, making PR metadata available to all Ashes without increasing per-Ash prompt size.

Each ash-prompt template receives a conditional `## PR Context` section when `context_intelligence.available === true`, injected during Phase 3 prompt construction.

**Note**: During arc `code_review` (Phase 6), no PR exists yet if Phase 9 SHIP hasn't run. Context Intelligence correctly reports `available: false` — this is expected.

## Phase 0.4: Linter Detection

Discover project linters from config files and provide linter awareness context to Ashes. Prevents Ashes from flagging issues that project linters already handle (formatting, import order, unused vars).

**Position**: After Phase 0.3, before Phase 0.5.
**Skip conditions**: `talisman.review.linter_awareness.enabled === false`.

Detects: eslint, prettier, biome, typescript (JS/TS), ruff, black, flake8, mypy, pyright, isort (Python), rubocop, standard (Ruby), golangci-lint (Go), clippy, rustfmt (Rust), editorconfig (general).

```javascript
// linterContext is injected into inscription.json in Phase 2 (linter_context field)
// Ashes receive suppression list in their prompts — DO NOT flag in suppressed categories
// SEC-* and VEIL-* findings are NEVER suppressed by linter awareness
```

Talisman config:
```yaml
review:
  linter_awareness:
    enabled: true
    always_review:          # Categories to review even if linter covers them
      - type-checking
```

## Phase 0.5: Lore Layer (Risk Intelligence)

Runs BEFORE team creation. Summons `lore-analyst` as a bare Agent (no team yet — ATE-1 exemption). Outputs `risk-map.json` and `lore-analysis.md`. Re-sorts `changed_files` by risk tier (CRITICAL → HIGH → MEDIUM → LOW → STALE).

**Skip conditions**: non-git repo, `--no-lore`, `talisman.goldmask.layers.lore.enabled === false`, fewer than 5 commits in lookback window (G5 guard).

## Phase 1: Rune Gaze (Scope Selection)

Classify changed files by extension. See [rune-gaze.md](../roundtable-circle/references/rune-gaze.md).

```
for each file in changed_files:
  - *.py, *.go, *.rs, *.rb, *.java, etc.           → select Forge Warden
  - *.ts, *.tsx, *.js, *.jsx, etc.                  → select Glyph Scribe
  - Dockerfile, *.sh, *.sql, *.tf, CI/CD configs    → select Forge Warden (infra)
  - *.yml, *.yaml, *.json, *.toml, *.ini            → select Forge Warden (config)
  - *.md (>= 10 lines changed)                      → select Knowledge Keeper
  - .claude/**/*.md                                  → Knowledge Keeper + Ward Sentinel
  - Unclassified                                     → Forge Warden (catch-all)
  - Always: Ward Sentinel, Pattern Weaver, Veil Piercer
  - CLI-backed: detectAllCLIAshes() from talisman
  - Agent-backed custom: talisman ashes.custom[] trigger matching (see rune-gaze.md)
```

Check for project overrides in `.claude/talisman.yml`.

**Custom Ash discovery** happens HERE in Phase 1 (not Phase 3). The Rune Gaze algorithm reads `talisman.yml` → `ashes.custom[]`, validates agent names, matches triggers against `changed_files`, and adds matching custom Ashes to `selectedAsh`. This ensures custom Ashes have tasks created for them in Phase 2 and are spawned in Phase 3. See [rune-gaze.md](../roundtable-circle/references/rune-gaze.md) for the full agent-backed custom Ash discovery algorithm.

### Phase 1.5: UX Reviewer Selection

Conditional UX agent spawning. Gated by `talisman.ux.enabled` AND frontend files detected in `changed_files`.

```javascript
// UX Reviewer Gate — follows the same pattern as design-implementation-reviewer (rune-gaze.md §4)
const uxEnabled = talisman?.ux?.enabled === true
const hasFrontendFiles = changed_files.some(f =>
  [".tsx", ".jsx", ".vue", ".svelte", ".css", ".scss"].some(ext => f.endsWith(ext))
)

if (uxEnabled && hasFrontendFiles) {
  ash_selections.add("ux-heuristic-reviewer")  // UXH-prefixed findings, non-blocking

  // Optional deep UX agents (--deep flag or talisman overrides)
  if (flags['--deep']) {
    ash_selections.add("ux-flow-validator")       // UXF-prefixed findings
    ash_selections.add("ux-interaction-auditor")   // UXI-prefixed findings

    // Cognitive walker: expensive (opus), opt-in only
    if (talisman?.ux?.cognitive_walkthrough === true) {
      ash_selections.add("ux-cognitive-walker")    // UXC-prefixed findings
    }
  }
}
```

**Skip conditions**: `talisman.ux.enabled` is not `true`, or no frontend files in diff.

### Dry-Run Exit Point

If `--dry-run` flag is set, display the plan (file counts per Ash, chunk plan, dedup hierarchy) and stop. Do NOT proceed to Phase 2.

## Phase 2: Forge Team

```javascript
// 0. Construct session-scoped identifier (prevents team name collision across sessions)
const gitHash = Bash(`git rev-parse --short HEAD`).trim()
const shortSession = "${CLAUDE_SESSION_ID}".slice(0, 4)
const identifier = `${gitHash}-${shortSession}`
// Result: e.g., "abc1234-a1b2" → team name "rune-review-abc1234-a1b2"

// 1. Check for concurrent review (tmp/.rune-review-{identifier}.json < 30 min old → abort)

// 2. Create output directory
Bash("mkdir -p tmp/reviews/{identifier}")

// 3. Write state file with session isolation fields
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write("tmp/.rune-review-{identifier}.json", {
  team_name: "rune-review-{identifier}",
  started: timestamp,
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}",
  expected_files: selectedAsh.map(r => `tmp/reviews/${identifier}/${r}.md`)
})

// 4. Generate inscription.json — includes diff_scope, context_intelligence, linter_context
// See roundtable-circle/references/inscription-schema.md

// 5. Pre-create guard: teamTransition protocol (see team-sdk/references/engines.md)
//    STEP 1: Validate identifier (/^[a-zA-Z0-9_-]+$/)
//    STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
//    STEP 3: Filesystem fallback if TeamDelete failed (CDX-003 gate: !teamDeleteSucceeded)
//    STEP 4: TeamCreate with "Already leading" catch-and-recover
//    STEP 5: Post-create verification (config.json exists)

// 6. Create signal dir for event-driven sync
const signalDir = `tmp/.rune-signals/rune-review-${identifier}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(selectedAsh.length))

// 7. Create tasks (one per Ash)
for (const ash of selectedAsh) {
  TaskCreate({
    subject: `Review as ${ash}`,
    description: `Files: [...], Output: tmp/reviews/{identifier}/${ash}.md`,
    activeForm: `${ash} reviewing...`
  })
}
```

## Phase 3: Summon Ash

Read and execute [ash-summoning.md](references/ash-summoning.md) for the full prompt generation contract, inscription contract, talisman custom Ashes, CLI-backed Ashes, and elicitation sage security context.

**Key rules:**
- Summon ALL selected Ash in a **single message** (parallel execution)
- Built-in Ash: load prompt from `roundtable-circle/references/ash-prompts/{role}.md`
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
- **Phase 5 (Runebinder)**: Aggregates all Ash findings. Deduplicates using `SEC > BACK > VEIL > DOUBT > DOC > QUAL > FRONT > CDX` hierarchy. Writes `TOME.md`. Every finding MUST be wrapped in `<!-- RUNE:FINDING ... -->` markers for mend parsing.
- **Phase 5.3 (Diff-Scope Tagging)**: Orchestrator-only. Tags findings with `scope="in-diff"` or `scope="pre-existing"`.
- **Phase 5.5 (Cross-Model Verification)**: Only if Codex Oracle was summoned. Verifies CDX findings against source. Removes HALLUCINATED + UNVERIFIED findings.
- **Phase 6 (Truthsight)**: Layer 0 inline checks + Layer 2 verifier for P1 findings.

## Phase 7: Cleanup & Echo Persist

```javascript
// 1. Dynamic teammate discovery from team config
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: built-in Ashes + runebinder (safe to send shutdown to absent members)
  allMembers = ["forge-warden", "ward-sentinel", "pattern-weaver", "veil-piercer",
    "glyph-scribe", "knowledge-keeper", "codex-oracle", "runebinder"]
}
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Review complete" })
}

// 2. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 20`)
}

// 3. TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s — CLEANUP_DELAYS: [0, 5000, 10000, 15000])
//    On failure: process-level kill (SIGTERM→3s→SIGKILL) then filesystem fallback (CHOME pattern)

// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "appraise"`)

// 3.6. Update state file to "completed" (preserve config_dir, owner_pid, session_id)

// 4. Persist P1/P2 patterns to .claude/echoes/reviewer/MEMORY.md (if exists)

// 5. Read and present TOME.md to user

// 6. Auto-mend or interactive prompt based on findings
const autoMend = flags['--auto-mend'] || (talisman?.review?.auto_mend === true)
if (totalFindings > 0 && autoMend) {
  Skill("rune:mend", `tmp/reviews/${identifier}/TOME.md`)
} else if (totalFindings > 0) {
  AskUserQuestion({
    options: ["/rune:mend (Recommended)", "Review TOME manually", "/rune:rest"]
  })
} else {
  log("No P1/P2 findings. Codebase looks clean.")
}
```

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
