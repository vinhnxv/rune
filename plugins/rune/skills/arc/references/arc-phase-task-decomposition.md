# Phase 4.5: TASK DECOMPOSITION — Full Algorithm

Cross-model validation of plan task structure using Codex. Checks granularity, dependencies, file ownership conflicts, and missing tasks. Gated by 5-condition detection.

**Team**: `arc-codex-td-{id}` (delegated to codex-phase-handler teammate)
**Tools**: Read, Write, Bash, TeamCreate, TeamDelete, Agent, SendMessage, TaskCreate, TaskUpdate, TaskList
**Timeout**: 10 min (600s — includes team lifecycle overhead)
**Inputs**: id (string), enriched plan (`tmp/arc/{id}/enriched-plan.md`), talisman config
**Outputs**: `tmp/arc/{id}/task-validation.md`
**Error handling**: Non-blocking — skip path always writes output MD. Cascade circuit breaker prevents repeated Codex failures from stalling the pipeline. Teammate timeout → fallback skip file.
**Consumers**: SKILL.md (Phase 4.5 stub)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, `warn()`, `detectCodex()`, `resolveCodexConfig()`, `classifyCodexError()`, `updateCascadeTracker()`, `sanitizePlanContent()`, and `formatReport()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Entry Gate (5-Condition Detection)

```javascript
// Phase 4.5: TASK DECOMPOSITION
// 4-condition detection gate (canonical pattern)
const codexAvailable = detectCodex()
const codexDisabled = talisman?.codex?.disabled === true
const taskDecompEnabled = talisman?.codex?.task_decomposition?.enabled !== false
const workflowIncluded = (talisman?.codex?.workflows ?? []).includes("arc")

// 5th condition: cascade circuit breaker (check before the 4-condition pattern)
if (checkpoint.codex_cascade?.cascade_warning === true) {
  Write(`tmp/arc/${id}/task-validation.md`, "# Task Decomposition Validation (Codex)\n\nSkipped: Codex cascade circuit breaker active")
  updateCheckpoint({ phase: "task_decomposition", status: "skipped", skip_reason: "cascade_circuit_breaker" })
  // Proceed to Phase 5 (WORK)
  return
}
```

**Gate conditions** (ALL must be true for execution):
1. `detectCodex()` — Codex CLI is installed and reachable
2. `codex.disabled !== true` — Not globally disabled in talisman
3. `codex.task_decomposition.enabled !== false` — Feature-level toggle (default: enabled)
4. `codex.workflows` includes `"arc"` — Arc is in the allowed workflow list
5. `codex_cascade.cascade_warning !== true` — No active cascade circuit breaker

## STEP 1: Delegate to codex-phase-handler Teammate

```javascript
if (codexAvailable && !codexDisabled && taskDecompEnabled && workflowIncluded) {
  const { timeout, reasoning, model: codexModel } = resolveCodexConfig(talisman, "task_decomposition", {
    timeout: 300, reasoning: "high"
  })

  const todosBase = checkpoint.todos_base ?? `tmp/arc/${id}/todos/`

  // ── Delegate to codex-phase-handler teammate ──
  // Token optimization: plan content (~10k chars) stays in teammate's context, not Tarnished's
  const teamName = `arc-codex-td-${id}`
  TeamCreate({ team_name: teamName })
  TaskCreate({
    subject: "Codex task decomposition validation",
    description: "Execute single-aspect task decomposition check via codex-exec.sh"
  })

  Agent({
    name: "codex-phase-handler-td",
    team_name: teamName,
    subagent_type: "general-purpose",
    prompt: `You are codex-phase-handler for Phase 4.5 TASK DECOMPOSITION.

## Assignment
- phase_name: task_decomposition
- arc_id: ${id}
- report_output_path: tmp/arc/${id}/task-validation.md
- recipient: Tarnished

## Codex Config
- model: ${codexModel}
- reasoning: ${reasoning}
- timeout: ${timeout}

## Aspects (single aspect — run sequentially)

### Aspect 1: task-structure
Output path: tmp/arc/${id}/task-validation.md
Prompt file path: tmp/arc/${id}/.codex-prompt-task-decomp.tmp

**IMPORTANT — Content Sanitization Required:**
Before writing the prompt, you MUST:
1. Read the enriched plan from: tmp/arc/${id}/enriched-plan.md
2. Sanitize the content:
   - Strip HTML comments (<!-- ... -->)
   - Strip zero-width characters (\\u200B, \\uFEFF, etc.)
   - Replace HTML entities (&amp; → &, &lt; → <, &gt; → >, &nbsp; → space)
   - Truncate to 10,000 characters
3. Then write the sanitized content into the prompt below where indicated

Prompt content (write to prompt file path):
"""
SYSTEM: You are a cross-model task decomposition validator.

Analyze this plan's task structure for decomposition quality:

=== PLAN ===
{INSERT SANITIZED PLAN CONTENT HERE — max 10,000 chars}
=== END PLAN ===

For each finding, provide:
- CDX-TASK-NNN: [CRITICAL|HIGH|MEDIUM] - description
- Category: Granularity / Dependency / File Conflict / Missing Task
- Suggested fix (brief)

Check for:
1. Tasks too large (>3 files or >200 lines estimated) — recommend splitting
2. Missing inter-task dependencies (task B reads output of task A but no blockedBy)
3. File ownership conflicts (multiple tasks modifying the same file)
4. Missing tasks (plan sections with no corresponding task)

Base findings on actual plan content, not assumptions.
"""

## Metadata Extraction
- Count findings matching pattern: CDX-TASK-\\d+
- Report finding_count in SendMessage

## Instructions
1. Claim the "Codex task decomposition validation" task
2. Gate check: command -v codex
3. Read and sanitize plan content from tmp/arc/${id}/enriched-plan.md
4. Write the prompt (with sanitized plan inserted) to the prompt file path
5. Run: "${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g -o tmp/arc/${id}/task-validation.md tmp/arc/${id}/.codex-prompt-task-decomp.tmp
6. Clean up prompt file
7. Compute sha256sum of final report
8. Count CDX-TASK findings in report
9. SendMessage to Tarnished:
   { "phase": "task_decomposition", "status": "completed", "artifact": "tmp/arc/${id}/task-validation.md", "artifact_hash": "{hash}", "finding_count": N }
10. Mark task complete`
  })

  // Monitor teammate completion (single agent, simple wait)
  // waitForCompletion: pollIntervalMs=30000, timeoutMs=600000
  let completed = false
  const maxIterations = Math.ceil(600000 / 30000) // 20 iterations
  for (let i = 0; i < maxIterations && !completed; i++) {
    const tasks = TaskList()
    completed = tasks.every(t => t.status === "completed")
    if (!completed) Bash("sleep 30")
  }

  // Fallback: if teammate timed out, check file directly
  if (!exists(`tmp/arc/${id}/task-validation.md`)) {
    Write(`tmp/arc/${id}/task-validation.md`, "# Task Decomposition Validation (Codex)\n\nSkipped: codex-phase-handler teammate timed out.")
  }

  // Cleanup team (single-member optimization: 5s grace instead of standard 20s)
  SendMessage({ type: "shutdown_request", recipient: "codex-phase-handler-td", content: "Phase complete" })
  Bash("sleep 5")
  // Retry-with-backoff pattern per CLAUDE.md cleanup standard (4 attempts: 0s, 5s, 10s, 15s)
  let tdCleanupSucceeded = false
  const TD_CLEANUP_DELAYS = [0, 5000, 10000, 15000]
  for (let attempt = 0; attempt < TD_CLEANUP_DELAYS.length; attempt++) {
    if (attempt > 0) Bash(`sleep ${TD_CLEANUP_DELAYS[attempt] / 1000}`)
    try { TeamDelete(); tdCleanupSucceeded = true; break } catch (e) {
      if (attempt === TD_CLEANUP_DELAYS.length - 1) warn(`cleanup: TeamDelete failed after ${TD_CLEANUP_DELAYS.length} attempts`)
    }
  }
  // Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
  if (!tdCleanupSucceeded) {
    Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
    Bash("sleep 3")
    Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
    Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
    try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
  }

  // Read metadata from teammate's SendMessage (structured JSON)
  // Extract error_class for cascade tracker (if teammate reported an error)
  // If no message received, use fallback classification
  const classified = teammateMetadata?.error_class
    ? { error_class: teammateMetadata.error_class }
    : classifyCodexError({ exitCode: 0 })  // assume success if file exists
  updateCascadeTracker(checkpoint, classified)

  // Read only hash from the report (not content — token optimization)
  const artifactHash = Bash(`sha256sum "tmp/arc/${id}/task-validation.md" | cut -d' ' -f1`).trim()

  updateCheckpoint({
    phase: "task_decomposition",
    status: "completed",
    artifact: `tmp/arc/${id}/task-validation.md`,
    artifact_hash: artifactHash,
    team_name: teamName
  })
```

### Finding Categories

| Category | Trigger | Example |
|----------|---------|---------|
| Granularity | Task touches >3 files or >200 estimated lines | "Split auth-setup into auth-middleware + auth-routes" |
| Dependency | Task B reads output of task A without `blockedBy` | "auth-tests should depend on auth-middleware" |
| File Conflict | Multiple tasks modify the same file | "Both user-model and user-api modify models/user.ts" |
| Missing Task | Plan section has no corresponding task | "Database migration section has no task" |

### Cascade Circuit Breaker

The cascade tracker (shared across all Codex phases) prevents repeated Codex failures from stalling the pipeline. If prior Codex phases (semantic verification, gap analysis) have accumulated failures, `cascade_warning` is set to `true` and task decomposition is skipped.

See [arc-codex-phases.md](arc-codex-phases.md) for the cascade tracker algorithm and threshold configuration.

### Token Savings

The Tarnished no longer reads plan content (~10k chars) or Codex output into its context. Only spawns the agent (~150 tokens) and receives metadata via SendMessage (~50 tokens). **Estimated savings: ~13k tokens** — the largest saving of any Codex phase, since plan content is 10k chars.

### Team Lifecycle

- Team `arc-codex-td-{id}` is created AFTER the gate check passes (zero overhead on skip path)
- Single teammate: 5s grace period before TeamDelete (single-member optimization)
- Crash recovery: `arc-codex-td-` prefix registered in `arc-preflight.md` and `arc-phase-cleanup.md`

## STEP 2: Skip Path

```javascript
} else {
  // Skip-path: MUST write output MD (depth-seer critical finding)
  const skipReason = !codexAvailable ? "codex not available"
    : codexDisabled ? "codex.disabled=true"
    : !taskDecompEnabled ? "codex.task_decomposition.enabled=false"
    : "arc not in codex.workflows"
  Write(`tmp/arc/${id}/task-validation.md`, `# Task Decomposition Validation (Codex)\n\nSkipped: ${skipReason}`)
  updateCheckpoint({ phase: "task_decomposition", status: "skipped", skip_reason: skipReason })
}
// Proceed to Phase 5 (WORK)
```

**Critical**: The skip path MUST always write `task-validation.md`. Downstream phases and gap analysis may reference this file. An empty skip produces a clear audit trail.

**Output**: `tmp/arc/{id}/task-validation.md` with CDX-TASK-prefixed findings (or skip reason)

**Failure policy**: Non-blocking. Codex errors are classified and recorded but never halt the pipeline. The cascade tracker ensures repeated failures trigger early skip in subsequent Codex phases.
