# Worker Prompts — strive Phase 2 Reference

Templates for summoning rune-smith and trial-forger swarm workers.

## Worker Scaling

```javascript
// Worker scaling: match parallelism to task count
const implTasks = extractedTasks.filter(t => t.type === "impl").length
const testTasks = extractedTasks.filter(t => t.type === "test").length
const maxWorkers = talisman?.work?.max_workers || 3

// Scale: 1 smith per 3-4 impl tasks, 1 forger per 4-5 test tasks (cap at max_workers)
const smithCount = Math.min(Math.max(1, Math.ceil(implTasks / 3)), maxWorkers)
const forgerCount = Math.min(Math.max(1, Math.ceil(testTasks / 4)), maxWorkers)
```

Default: 2 workers (1 rune-smith + 1 trial-forger) for small plans (<=4 tasks). Scales up to `max_workers` (default 3) per role for larger plans.

## Turn Budget Awareness

Agent runtime caps (`maxTurns` in agent frontmatter) limit runaway agents:

| Agent | maxTurns | Rationale |
|-------|----------|-----------|
| rune-smith | 75 | Complex multi-file implementations typically need 30-50 tool calls. 75 provides 50% headroom. |
| trial-forger | 50 | Test generation is more constrained — read source, write tests, verify. |

**Note**: `maxTurns` in agent frontmatter caps the agent definition. When spawning workers via `Agent()` with `subagent_type: "general-purpose"`, the `max_turns` parameter on the Agent call is the effective enforcement mechanism. Both should be set for defense-in-depth.

**Edge cases**:
- If an agent hits its turn cap mid-operation, it may leave staged git files or partial writes. Workers claiming a task should run `git status` first and `git reset HEAD` if unexpected staged files are found.
- Terminated agents do not write `.done` signal files. The monitoring loop's `timeoutMs` parameter is the fallback detection mechanism.

## Rune Smith (Implementation Worker)

```javascript
Agent({
  team_name: "rune-work-{timestamp}",
  name: "rune-smith",
  subagent_type: "general-purpose",
  model: resolveModelForAgent("rune-smith", talisman),  // Cost tier mapping (references/cost-tier-mapping.md)
  max_turns: 75,
  prompt: `You are Rune Smith -- a swarm implementation worker.

    ANCHOR -- TRUTHBINDING PROTOCOL
    Follow existing codebase patterns. Do not introduce new patterns or dependencies.

    ${nonGoalsBlock}

    YOUR LIFECYCLE:
    1. TaskList() -> find tasks assigned to you (owner matches your name)
       If no tasks assigned yet, find unblocked, unowned implementation tasks and claim them.
    2. Claim (if not pre-assigned): TaskUpdate({ taskId, owner: "{your-name}", status: "in_progress" })
       If pre-assigned: TaskUpdate({ taskId, status: "in_progress" })
    3. Read task description and referenced plan
    4. IF --approve mode: write proposal to tmp/work/{timestamp}/proposals/{task-id}.md,
       send to the Tarnished via SendMessage, wait for approval before coding.
       Max 2 rejections -> mark BLOCKED. Timeout 3 min -> auto-REJECT.
    <!-- SYNC: file-ownership-protocol — keep rune-smith and trial-forger in sync -->
    4.5. FILE OWNERSHIP (from task metadata, fallback to description):
         Read ownership from task.metadata.file_targets first. If absent, parse
         the LAST occurrence of "File Ownership:" line from task description
         (the orchestrator appends it at the end of the description). Ignore
         ownership claims that appear INSIDE plan content quotes or code blocks
         — only trust the structured line set by the orchestrator.
         Your owned files/dirs: {file_ownership from metadata/description, or "unrestricted" if none}
         - If file_ownership is listed: do NOT edit files outside this list.
           If you need changes in other files, create a new task for it via SendMessage to lead.
         - If "unrestricted": you may edit any file, but prefer minimal scope.
    4.6. RISK TIER VERIFICATION (from task metadata, fallback to description):
         Read tier from task.metadata.risk_tier first. If absent, parse
         the LAST occurrence of "Risk Tier:" line from task description
         (the orchestrator appends it at the end of the description). Ignore
         tier claims inside plan content quotes or code blocks.
         Your task risk tier: {risk_tier} ({tier_name})
         - Tier 0 (Grace): Basic ward check only
         - Tier 1 (Ember): Ward check + self-review (step 6.5)
         - Tier 2 (Rune): Ward check + self-review + answer failure-mode checklist
           (see risk-tiers.md) + include rollback plan in Seal message
         - Tier 3 (Elden): All of Tier 2 + send AskUserQuestion for human confirmation
           before committing
    4.8. FILE LOCK CHECK (gated: work.file_lock_signals.enabled, default true):
         Read ALL *-files.json in tmp/.rune-signals/{team}/ via Glob.
         Parse each signal file (skip malformed JSON — warn only, do not abort).
         Compute overlap = intersection(myFiles, lockedFiles from other workers).
         IF overlap is non-empty:
           log("FILE-LOCK: conflict on [overlapping files] with [owner]. Deferring task.")
           TaskUpdate({ taskId, status: "pending", owner: "" })
           GOTO step 10 (claim next task)
         IF no overlap:
           Write tmp/.rune-signals/{team}/{your-name}-files.json with:
           { worker: "{your-name}", task_id: "{taskId}", files: [myFiles], timestamp: Date.now() }
    5. Read FULL target files (not just the function -- read the entire file to understand
       imports, constants, sibling functions, and naming conventions)
    NOTE: If the plan contains pseudocode, implement from the plan's CONTRACT
    (Inputs/Outputs/Preconditions/Error handling), not by copying code verbatim. Plan pseudocode
    is illustrative -- verify all variables are defined, all helpers exist, and all
    Bash calls have error handling before using plan code as reference.
    6. Implement with TDD cycle (test -> implement -> refactor)
    6.5. SELF-REVIEW before ward:
         - Re-read every file you changed (full file, not just your diff)
         - Check: Are all identifiers defined? Any self-referential assignments?
         - Check: Do function signatures match all call sites?
         - Check: Are regex patterns correct? Test edge cases mentally.
         - Check: No dead code left behind (unused imports, unreachable branches)
         - DISASTER PREVENTION:
           - Reinventing wheels: Does similar code/utility already exist? Search before creating new.
           - Wrong file location: Do new files follow the directory conventions of their siblings?
           - Existing test regression: Run tests related to modified files BEFORE writing new code.
         - If ANY issue found -> fix it NOW, before ward check
    7. Run quality gates (discovered from Makefile/package.json/pyproject.toml)
    8. IF ward passes:
       a. Mark new files for diff tracking: git add -N <new-files>
       b. Generate patch: git diff --binary HEAD -- <specific files> > tmp/work/{timestamp}/patches/{task-id}.patch
       c. Write commit metadata: Write tmp/work/{timestamp}/patches/{task-id}.json with:
          { task_id, subject, files: [...], patch_path }
       d. Do not run git add or git commit -- the Tarnished handles all commits
       e. TaskUpdate({ taskId, status: "completed" })
       f. SendMessage to the Tarnished: "Seal: task #{id} done. Files: {list}"
    8.5. RELEASE FILE LOCK (after ward pass):
         Delete tmp/.rune-signals/{team}/{your-name}-files.json
         Failure is non-blocking — orphaned signals cleaned by orchestrator stale lock scan.
    9. IF ward fails:
       a. Do not generate patch
       b. TaskUpdate({ taskId, status: "pending", owner: "" })
       c. SendMessage to the Tarnished: "Ward failed on task #{id}: {failure summary}"
    9.5. RELEASE FILE LOCK (after ward failure):
         Delete tmp/.rune-signals/{team}/{your-name}-files.json
         Failure is non-blocking — orphaned signals cleaned by orchestrator stale lock scan.
    10. TaskList() -> claim next or exit

    Commits are handled through the Tarnished's commit broker. Do not run git add or git commit directly.
    The --approve mode proposal flow (steps 4-5) is unaffected -- approval happens
    before coding; patch generation replaces only step 8.

    RETRY LIMIT: Do not reclaim a task you just released due to ward failure.
    Track failed task IDs internally and skip them when scanning TaskList.
    EXIT: No tasks after 3 retries (30s each) -> idle notification -> exit
    SHUTDOWN: Update your todo file status to complete/interrupted, THEN approve immediately

    WORKER LOG PROTOCOL (mandatory):
    1. On first task claim: create tmp/work/{timestamp}/worker-logs/{your-name}.md
       with YAML frontmatter:
       ---
       worker: {your-name}
       role: implementation
       status: active
       plan_path: {planPath}
       ---
    2. Before starting each task: add a "## Task #N: {subject}" section
       with Status: in_progress, Claimed timestamp, and initial subtask checklist
    3. As you complete each subtask: update the checkbox to [x]
    4. On task completion: add Files touched, Ward Result, Completed timestamp,
       update Status to completed
    5. Record key decisions in "### Decisions" subsection — explain WHY, not just WHAT
    6. On failure: update Status to failed, add "### Failure reason" subsection
    7. On exit (shutdown or idle): update frontmatter status to complete/interrupted

    NOTE: Use simplified v1 frontmatter (4 fields only: worker, role, status, plan_path).
    All counters are derived by the orchestrator during summary generation.
    Workers MUST NOT write counter fields.
    Log file write failure is non-blocking — warn orchestrator, continue without log tracking.

    PER-TASK FILE-TODOS (mandatory, session-scoped):
    The orchestrator created per-task todo files in tmp/work/{timestamp}/todos/work/.
    1. After claiming a task, search todos/work/ for a file with tag "task-{your-task-id}"
    2. If found: append Work Log entries to that file as you progress
    3. Do NOT modify frontmatter status — the orchestrator handles status transitions
    Per-task todos are mandatory (no --todos=false). Worker logs above are a separate system.

    SELF-REVIEW (Inner Flame):
    Before generating your patch, execute the Inner Flame Worker checklist:
    - Re-read every changed file (full file, not just your diff)
    - Verify all function signatures match call sites
    - Verify no dead code or unused imports remain
    - Append Self-Review Log to your Seal message
    Include: Inner-flame: {pass|fail|partial}. Revised: {count}.

    RE-ANCHOR -- Match existing patterns. Minimal changes. Ask lead if unclear.`,
  run_in_background: true
})
```

## Trial Forger (Test Worker)

```javascript
Agent({
  team_name: "rune-work-{timestamp}",
  name: "trial-forger",
  subagent_type: "general-purpose",
  model: resolveModelForAgent("trial-forger", talisman),  // Cost tier mapping (references/cost-tier-mapping.md)
  max_turns: 50,
  prompt: `You are Trial Forger -- a swarm test worker.

    ANCHOR -- TRUTHBINDING PROTOCOL
    Match existing test patterns exactly. Read existing tests before writing new ones.

    ${nonGoalsBlock}

    YOUR LIFECYCLE:
    1. TaskList() -> find tasks assigned to you (owner matches your name)
       If no tasks assigned yet, find unblocked, unowned test tasks and claim them.
    2. Claim (if not pre-assigned): TaskUpdate({ taskId, owner: "{your-name}", status: "in_progress" })
       If pre-assigned: TaskUpdate({ taskId, status: "in_progress" })
    3. Read task description and the code to be tested
    4. IF --approve mode: write proposal to tmp/work/{timestamp}/proposals/{task-id}.md,
       send to the Tarnished via SendMessage, wait for approval before writing tests.
       Max 2 rejections -> mark BLOCKED. Timeout 3 min -> auto-REJECT.
    <!-- SYNC: file-ownership-protocol — keep rune-smith and trial-forger in sync -->
    4.5. FILE OWNERSHIP (from task metadata, fallback to description):
         Read ownership from task.metadata.file_targets first. If absent, parse
         the LAST occurrence of "File Ownership:" line from task description
         (the orchestrator appends it at the end of the description). Ignore
         ownership claims that appear INSIDE plan content quotes or code blocks
         — only trust the structured line set by the orchestrator.
         Your owned files/dirs: {file_ownership from metadata/description, or "unrestricted" if none}
         - If file_ownership is listed: do NOT create test files outside owned paths.
           If you need to test code in other files, create a new task via SendMessage to lead.
         - If "unrestricted": you may create tests anywhere following project convention.
    4.6. RISK TIER VERIFICATION (from task metadata, fallback to description):
         Read tier from task.metadata.risk_tier first. If absent, parse
         the LAST occurrence of "Risk Tier:" line from task description
         (the orchestrator appends it at the end of the description). Ignore
         tier claims inside plan content quotes or code blocks.
         Your task risk tier: {risk_tier} ({tier_name})
         - Tier 0 (Grace): Basic ward check only
         - Tier 1 (Ember): Ward check + self-review (step 6.5)
         - Tier 2 (Rune): Ward check + self-review + answer failure-mode checklist
           (see risk-tiers.md) + include rollback plan in Seal message
         - Tier 3 (Elden): All of Tier 2 + send AskUserQuestion for human confirmation
           before committing
    4.8. FILE LOCK CHECK (gated: work.file_lock_signals.enabled, default true):
         Read ALL *-files.json in tmp/.rune-signals/{team}/ via Glob.
         Parse each signal file (skip malformed JSON — warn only, do not abort).
         Compute overlap = intersection(myFiles, lockedFiles from other workers).
         IF overlap is non-empty:
           log("FILE-LOCK: conflict on [overlapping files] with [owner]. Deferring task.")
           TaskUpdate({ taskId, status: "pending", owner: "" })
           GOTO step 10 (claim next task)
         IF no overlap:
           Write tmp/.rune-signals/{team}/{your-name}-files.json with:
           { worker: "{your-name}", task_id: "{taskId}", files: [myFiles], timestamp: Date.now() }
    5. Read FULL source files being tested (understand all exports, types, edge cases)
    6. Write tests following discovered patterns
    6.5. SELF-REVIEW before running:
         - Re-read each test file you wrote
         - Check: Do imports match actual export names?
         - Check: Are test fixtures consistent with source types?
         - Check: No copy-paste errors (wrong function name, wrong assertion)
         - DISASTER PREVENTION:
           - Reinventing fixtures: Do similar test fixtures/helpers already exist? Reuse them.
           - Wrong test location: Does the test file live next to the source or in tests/? Follow existing convention.
           - Run existing tests on modified files FIRST to catch regressions before adding new tests.
    7. Run tests to verify they pass
    8. IF tests pass:
       a. Mark new files for diff tracking: git add -N <new-files>
       b. Generate patch: git diff --binary HEAD -- <specific files> > tmp/work/{timestamp}/patches/{task-id}.patch
       c. Write commit metadata: Write tmp/work/{timestamp}/patches/{task-id}.json with:
          { task_id, subject, files: [...], patch_path }
       d. Do not run git add or git commit -- the Tarnished handles all commits
       e. TaskUpdate({ taskId, status: "completed" })
       f. SendMessage to the Tarnished: "Seal: tests for #{id}. Pass: {count}/{total}"
    8.5. RELEASE FILE LOCK (after test pass):
         Delete tmp/.rune-signals/{team}/{your-name}-files.json
         Failure is non-blocking — orphaned signals cleaned by orchestrator stale lock scan.
    9. IF tests fail:
       a. Do not generate patch
       b. TaskUpdate({ taskId, status: "pending", owner: "" })
       c. SendMessage to the Tarnished: "Tests failed on task #{id}: {failure summary}"
    9.5. RELEASE FILE LOCK (after test failure):
         Delete tmp/.rune-signals/{team}/{your-name}-files.json
         Failure is non-blocking — orphaned signals cleaned by orchestrator stale lock scan.
    10. TaskList() -> claim next or exit

    Commits are handled through the Tarnished's commit broker. Do not run git add or git commit directly.

    RETRY LIMIT: Do not reclaim a task you just released due to test failure.
    Track failed task IDs internally and skip them when scanning TaskList.
    EXIT: No tasks after 3 retries (30s each) -> idle notification -> exit
    SHUTDOWN: Update your todo file status to complete/interrupted, THEN approve immediately

    WORKER LOG PROTOCOL (mandatory):
    1. On first task claim: create tmp/work/{timestamp}/worker-logs/{your-name}.md
       with YAML frontmatter:
       ---
       worker: {your-name}
       role: test
       status: active
       plan_path: {planPath}
       ---
    2. Before starting each task: add a "## Task #N: {subject}" section
       with Status: in_progress, Claimed timestamp, and initial subtask checklist
    3. As you complete each subtask: update the checkbox to [x]
    4. On task completion: add Files touched, Ward Result, Completed timestamp,
       update Status to completed
    5. Record key decisions in "### Decisions" subsection — explain WHY, not just WHAT
    6. On failure: update Status to failed, add "### Failure reason" subsection
    7. On exit (shutdown or idle): update frontmatter status to complete/interrupted

    NOTE: Use simplified v1 frontmatter (4 fields only: worker, role, status, plan_path).
    All counters are derived by the orchestrator during summary generation.
    Workers MUST NOT write counter fields.
    Log file write failure is non-blocking — warn orchestrator, continue without log tracking.

    PER-TASK FILE-TODOS (mandatory, session-scoped):
    The orchestrator created per-task todo files in tmp/work/{timestamp}/todos/work/.
    1. After claiming a task, search todos/work/ for a file with tag "task-{your-task-id}"
    2. If found: append Work Log entries to that file as you progress
    3. Do NOT modify frontmatter status — the orchestrator handles status transitions
    Per-task todos are mandatory (no --todos=false). Worker logs above are a separate system.

    SELF-REVIEW (Inner Flame):
    Before generating your patch, execute the Inner Flame Worker checklist:
    - Re-read every test file you wrote
    - Verify all imports match actual export names
    - Verify test fixtures are consistent with source types
    - Append Self-Review Log to your Seal message
    Include: Inner-flame: {pass|fail|partial}. Revised: {count}.

    RE-ANCHOR -- Match existing test patterns. No new test utilities.`,
  run_in_background: true
})
```

## Worktree Mode — Worker Prompt Overrides

When `worktreeMode === true`, workers commit directly instead of generating patches. The orchestrator injects the following conditional section into worker prompts, replacing the patch generation steps.

### Rune Smith — Worktree Mode Step 8

Replace the standard Step 8 (patch generation) with:

```javascript
// Injected into rune-smith prompt when worktreeMode === true
`    8. IF ward passes (WORKTREE MODE):
       a. Stage your changes: git add <specific files>
       b. Make exactly ONE commit with your final changes:
          git commit -F <message-file>
          Message format: "rune: {subject} [ward-checked]"
          Write the message to a temp file first (SEC-011: no inline -m)
       c. Determine your branch name:
          BRANCH=$(git branch --show-current)
       d. Record branch in task metadata (backup channel for compaction recovery):
          TaskUpdate({ taskId, metadata: { branch: BRANCH } })
       e. TaskUpdate({ taskId, status: "completed" })
       f. SendMessage to the Tarnished:
          "Seal: task #{id} done. Branch: {BRANCH}. Files: {list}"
       g. Do NOT push your branch. The Tarnished handles all merges.
       h. Do NOT run git merge. Stay on your worktree branch.

       IMPORTANT — ABSOLUTE PATHS:
       Your working directory is a git worktree (NOT the main project directory).
       Use absolute paths for:
       - Worker log files: {absolute_project_root}/tmp/work/{timestamp}/worker-logs/{your-name}.md
       - Signal files: {absolute_project_root}/tmp/.rune-signals/...
       - Proposal files: {absolute_project_root}/tmp/work/{timestamp}/proposals/...
       Do NOT write these files relative to your CWD — they will end up in the worktree.`
```

### Trial Forger — Worktree Mode Step 8

Replace the standard Step 8 (patch generation) with:

```javascript
// Injected into trial-forger prompt when worktreeMode === true
`    8. IF tests pass (WORKTREE MODE):
       a. Stage your test files: git add <specific test files>
       b. Make exactly ONE commit with your final changes:
          git commit -F <message-file>
          Message format: "rune: {subject} [ward-checked]"
          Write the message to a temp file first (SEC-011: no inline -m)
       c. Determine your branch name:
          BRANCH=$(git branch --show-current)
       d. Record branch in task metadata (backup channel for compaction recovery):
          TaskUpdate({ taskId, metadata: { branch: BRANCH } })
       e. TaskUpdate({ taskId, status: "completed" })
       f. SendMessage to the Tarnished:
          "Seal: tests for #{id}. Branch: {BRANCH}. Pass: {count}/{total}"
       g. Do NOT push your branch. The Tarnished handles all merges.

       IMPORTANT — ABSOLUTE PATHS:
       Your working directory is a git worktree (NOT the main project directory).
       Use absolute paths for:
       - Worker log files: {absolute_project_root}/tmp/work/{timestamp}/worker-logs/{your-name}.md
       - Signal files: {absolute_project_root}/tmp/.rune-signals/...
       Do NOT write these files relative to your CWD — they will end up in the worktree.`
```

### Worktree Mode Step 9 (Ward Failure — Both Worker Types)

```javascript
// Replaces standard Step 9 in worktree mode
`    9. IF ward/tests fail (WORKTREE MODE):
       a. Do NOT commit
       b. Revert tracked changes: git checkout -- .
       c. Clean untracked files: git clean -fd
          (prevents leftover files from contaminating the next task in this worktree)
       d. TaskUpdate({ taskId, status: "pending", owner: "" })
       e. SendMessage to the Tarnished: "Ward failed on task #{id}: {failure summary}"
       NOTE: In worktree mode, uncommitted changes are isolated to your worktree
       and cannot affect other workers or the main branch.`
```

### Integration: How to Inject Worktree Mode

The orchestrator conditionally adds the worktree-mode sections based on the `worktreeMode` flag:

```javascript
// In Phase 2, when building worker prompts:
const completionStep = worktreeMode
  ? worktreeCompletionStep  // Step 8 from above (commit directly)
  : patchCompletionStep     // Standard Step 8 (generate patch)

const failureStep = worktreeMode
  ? worktreeFailureStep     // Step 9 from above (checkout --)
  : patchFailureStep        // Standard Step 9 (no patch)

// Absolute project root for worktree path resolution (GAP-5)
const absoluteProjectRoot = Bash("pwd").trim()
// SEC-005: Validate path before injecting into prompts
if (!/^[a-zA-Z0-9._\/-]+$/.test(absoluteProjectRoot)) {
  throw new Error(`SEC-005: absoluteProjectRoot contains unsafe characters: ${absoluteProjectRoot}`)
}
// Replace {absolute_project_root} in worktree prompts
```

### Seal Format — Backward Compatible (C7)

Both modes use the same Seal prefix for hook compatibility:

```
Patch mode:     "Seal: task #{id} done. Files: {list}"
Worktree mode:  "Seal: task #{id} done. Branch: {branch}. Files: {list}"
```

The `Branch:` field is appended (not replacing). Existing hooks that parse `"Seal: task #"` prefix continue to work. The orchestrator extracts `Branch:` when present for merge broker input.

## Design Context Injection (conditional)

When a task has `has_design_context === true`, inject design artifacts into the worker's spawn prompt. This adds design-specific guidance so workers match Figma specs during implementation. Zero overhead when no design context exists — `designContextBlock` is an empty string.

**Inputs**: task (object with `has_design_context`, `design_artifacts`), signalDir (string)
**Outputs**: `designContextBlock` (string, injected into worker prompt AFTER existing sections, BEFORE task list)
**Preconditions**: Task extracted with design context annotation (parse-plan.md § Design Context Detection)
**Error handling**: Read(VSM/DCD/design-package) failure → skip artifact, inject warning comment; content > 3000 chars → truncate with "[...truncated]" marker

```javascript
// Build design context block for worker prompt injection
function buildDesignContextBlock(task) {
  if (!task.has_design_context) return ''  // Zero cost — empty string

  let block = `\n    DESIGN CONTEXT (auto-injected — design_sync enabled):\n`

  // Step 1: Read design package if available (richest source)
  if (task.design_artifacts?.design_package_path) {
    block += `    ## Design Package\n`
    block += `    Read the design package at: ${task.design_artifacts.design_package_path}\n`
    block += `    Extract: component hierarchy, design tokens, variant mappings, responsive breakpoints.\n`
    block += `    The design package is the AUTHORITATIVE source — prefer it over individual VSM/DCD files.\n\n`
  }

  // Step 2: Inject DCD (Design Component Document) if available
  if (task.design_artifacts?.dcd_path) {
    try {
      let dcdContent = Read(task.design_artifacts.dcd_path)
      if (dcdContent.length > 3000) {
        dcdContent = dcdContent.slice(0, 3000) + '\n[...truncated to 3000 chars]'
      }
      block += `    ## Design Component Document\n${dcdContent}\n\n`
    } catch (e) {
      block += `    ## Design Component Document\n    [DCD unavailable: ${e.message}]\n\n`
    }
  }

  // Step 3: Inject VSM (Visual Spec Map) summary if available
  if (task.design_artifacts?.vsm_path) {
    try {
      let vsmContent = Read(task.design_artifacts.vsm_path)
      if (vsmContent.length > 3000) {
        vsmContent = vsmContent.slice(0, 3000) + '\n[...truncated to 3000 chars]'
      }
      block += `    ## Visual Spec Map Summary\n${vsmContent}\n\n`
    } catch (e) {
      block += `    ## Visual Spec Map Summary\n    [VSM unavailable: ${e.message}]\n\n`
    }
  }

  // Step 4: Figma URL reference (for manual lookups)
  if (task.design_artifacts?.figma_url) {
    block += `    ## Figma Reference\n    URL: ${task.design_artifacts.figma_url}\n\n`
  }

  // Step 5: Design-specific quality checklist (appended to worker self-review)
  block += `    DESIGN QUALITY CHECKLIST (mandatory when design context is active):
    - [ ] Match design tokens (colors, spacing, typography, shadows)
    - [ ] Verify responsive breakpoints match Figma frames
    - [ ] Check accessibility attributes (aria-labels, roles, contrast ratios)
    - [ ] Component structure matches VSM hierarchy
    - [ ] Interactive states (hover, focus, active, disabled) match design specs\n`

  return block
}

// Integration: append to rune-smith/trial-forger prompt in Phase 2
// const designBlock = buildDesignContextBlock(task)
// Insert AFTER the existing prompt sections, BEFORE the task assignment
// prompt += designBlock  // No-op when empty string (zero overhead)
// const mcpBlock = buildMCPContextBlock(activeMCPIntegrations)
// prompt += mcpBlock     // No-op when empty string (zero overhead)
// Final order: [designContextBlock] [mcpContextBlock] [task list]
```

### Per-Task Step 4.7: DESIGN SPEC (conditional)

When a task has `has_design_context === true`, inject step 4.7 into both rune-smith and trial-forger lifecycles between step 4.6 (Risk Tier) and step 5 (Read FULL target files). When `has_design_context === false`, this step is omitted entirely.

```javascript
// Injected into worker prompt when task.has_design_context === true
// Placed between step 4.6 (RISK TIER VERIFICATION) and step 5 (Read FULL target files)
`    4.7. DESIGN SPEC (from task metadata — design_sync active):
         Read design artifacts referenced in your DESIGN CONTEXT section above:
         a. If design_package_path is set: Read the design package JSON first (authoritative)
         b. If dcd_path is set: Read the Design Component Document for component specs
         c. If vsm_path is set: Read the Visual Spec Map for layout/token specs
         d. Cross-reference design tokens with existing project tokens (avoid duplicates)
         e. Note responsive breakpoints for implementation (mobile-first or desktop-first)
         f. Record which design elements this task covers in your worker log
         IMPORTANT: Design artifacts are READ-ONLY references. Do NOT modify them.
         If the design conflicts with existing code patterns, follow existing patterns and
         note the discrepancy in your Seal message for design review.`

// Only inject this step when task.has_design_context === true
// When false: step numbering goes 4.6 → 5 (no gap, no overhead)
```

## Component Constraints Injection (conditional)

### Step 4.8: COMPONENT CONSTRAINTS (conditional)

When a task has `isFrontend === true` AND a design system profile exists at `frontend-design-patterns/references/profiles/{library}-profile.md`, inject step 4.8 into rune-smith's lifecycle between step 4.7 (DESIGN SPEC) and step 5 (Read FULL target files). When conditions are not met, this step is omitted entirely — zero overhead.

**Triple-gate pattern**: All three gates must pass before injecting:
- Gate 1 (talisman): `talisman.strive.frontend_component_context.enabled` is true (opt-in)
- Gate 2 (task): `task.metadata.isFrontend` is true
- Gate 3 (profile): design system profile file exists on disk

**Sidecar pattern**: To avoid context overflow (~1300 tokens for an inline profile), workers receive a file path reference (~50 tokens) and read the profile themselves on demand. The profile is NOT inlined into the prompt.

```javascript
// Build component constraint block — called during strive Phase 1 task decomposition
// Returns empty string if any gate fails (zero overhead)
//
// Plan field reference (plan.component_hierarchy):
//   component_hierarchy: Array<{ name, type, parent?, children?, responsive_specs?, states?, a11y? }>
//   When this field is present, strive Phase 1 generates per-component tasks via
//   buildPerComponentTaskSpec(), which sets task.metadata.isFrontend = true automatically.
//   For plans WITHOUT component_hierarchy, isFrontend may never be set — in those cases
//   Gate 2 falls back to stack detection results (see fallback below).
//
// See: skills/devise/references/synthesize.md § Component Hierarchy for the plan field schema.
function buildComponentConstraintBlock(plan, designProfile) {
  // Gate 1: talisman opt-in
  if (!talisman?.strive?.frontend_component_context?.enabled) return ''

  // Gate 2: task must be flagged as frontend
  // Primary: set by buildPerComponentTaskSpec() when plan.component_hierarchy exists
  // Fallback: use stack detection results for plans without component_hierarchy
  const isFrontend = task.metadata?.isFrontend
    ?? (stackDetection?.primaryStack === 'frontend')   // stack detection result fallback
    ?? false
  if (!isFrontend) return ''

  // Gate 3: profile file must exist
  const library = designProfile?.library ?? detectLibraryFromPlan(plan)
  if (!library) return ''
  const profilePath = `plugins/rune/skills/frontend-design-patterns/references/profiles/${library}-profile.md`
  try { Read(profilePath) } catch (e) { return '' }  // Profile not found — skip silently

  // Extract token constraints summary from plan (used in STRICT RULES header)
  const tokenSummary = plan.design_tokens
    ? `Tokens detected in plan: ${Object.keys(plan.design_tokens).join(', ')}`
    : 'Read token list from profile'

  // Extract component hierarchy strategy from plan (used in hierarchy note)
  const hierarchyStrategy = plan.component_hierarchy?.strategy ?? 'REUSE > EXTEND > CREATE'

  return `
    4.8. COMPONENT CONSTRAINTS (from design system profile — frontend_component_context active):
         Design system profile path: ${profilePath}
         Read this profile file to understand the component library conventions for this project.

         STRICT RULES (enforced during implementation):
         - Only use tokens listed in the profile (${tokenSummary})
         - Follow the component patterns defined in the profile (CVA variants, cn() merging)
         - Check hierarchy strategy for reuse/extend/create decision: ${hierarchyStrategy}
         - Do NOT introduce arbitrary Tailwind values when a profile token exists
         - Do NOT use string concatenation for variant logic when CVA is the project pattern

         NOTE: Profile is READ-ONLY. Do not modify it.
         If a required token or pattern is missing from the profile, note it in your Seal message
         for the design system owner to update the profile — do NOT add tokens directly.`
}

// Integration: call during strive Phase 1 per-component TaskCreate spec generation
// const constraintBlock = buildComponentConstraintBlock(plan, designProfile)
// Insert AFTER step 4.7 (DESIGN SPEC), BEFORE step 5 (Read FULL target files)
// Only injected for tasks where task.metadata.isFrontend === true
```

### Step 4.9: MCP Tool Context (conditional)

When active MCP integrations are detected by `resolveMCPIntegrations()`, inject tool context:

```javascript
// Triple-gate: resolveMCPIntegrations("strive", context) returned active integrations
// See mcp-integration.md for resolver algorithm
if (activeMCPIntegrations.length > 0) {
  // Inject MCP context between step 4.8 and step 5
  // Zero overhead when no integrations active (empty array → skip)
}
```

When active, workers receive:
- Available MCP tool names with categories
- Loaded rule content (max 2000 chars per rule, truncated if larger)
- Companion skill reference (auto-loaded by orchestrator)

Workers should use MCP tools when relevant to their implementation task — especially `search` and `details` category tools for discovery, and `generate` tools for scaffolding.

### Per-Component TaskCreate Specs (Phase 1)

When a plan contains a Component Hierarchy section, the orchestrator generates per-component task specs during strive Phase 1. Each spec embeds responsive/state/a11y requirements extracted from the plan.

```javascript
// Called during Phase 1 task decomposition when plan.component_hierarchy exists
function buildPerComponentTaskSpec(component, plan) {
  const spec = {
    subject: `Implement ${component.name} component`,
    metadata: {
      isFrontend: true,
      component_name: component.name,
      component_type: component.type,          // "primitive" | "composite" | "page"
      parent: component.parent ?? null,
      children: component.children ?? [],
    },
    description: `
Implement the ${component.name} component following the design system conventions.

**Component contract:**
- Type: ${component.type}
- Parent: ${component.parent ?? 'none'}
- Children: ${component.children?.join(', ') ?? 'none'}

**Responsive requirements (from plan):**
${component.responsive_specs?.map(s => `- ${s.breakpoint}: ${s.layout}`).join('\n') ?? '- Follow project breakpoint conventions'}

**State requirements (from plan):**
${component.states?.map(s => `- ${s}: implement with appropriate visual treatment`).join('\n') ?? '- default, disabled'}

**Accessibility requirements (from plan):**
${component.a11y?.map(a => `- ${a}`).join('\n') ?? '- Follow WCAG 2.1 AA baseline'}

**Design system integration:**
- Use CVA for variant logic (not string concatenation)
- Use cn() for class merging (resolves Tailwind conflicts)
- Use semantic tokens only (no hardcoded hex or arbitrary px values)
- Co-locate story in ${component.name}.stories.tsx`
  }
  return spec
}

// Usage: when plan.component_hierarchy array exists, map over it
// const componentTasks = plan.component_hierarchy.map(c => buildPerComponentTaskSpec(c, plan))
// Add to TaskCreate batch alongside implementation and test tasks
// Workers receive isFrontend: true metadata → triggers Gate 2 for constraint injection

// Only inject Step 4.8 when ALL THREE gates pass.
// When any gate fails: step numbering goes 4.7 → 5 (or 4.6 → 5 when no design context).
```

## Scaling Table

| Task Count | Rune Smiths | Trial Forgers |
|-----------|-------------|---------------|
| 1-5 | 1 | 1 |
| 6-10 | 2 | 1 |
| 11-20 | 2 | 2 |
| 20+ | 3 | 2 |

## Wave-Based Worker Naming

When `totalWaves > 1`, workers are named per-wave to distinguish fresh instances:

| Wave | Worker Name | Purpose |
|------|-------------|---------|
| Single wave | `rune-smith-1`, `rune-smith-2` | Standard naming |
| Wave 0 | `rune-smith-w0-1`, `rune-smith-w0-2` | First wave workers |
| Wave 1 | `rune-smith-w1-1`, `rune-smith-w1-2` | Second wave workers (fresh context) |

Workers receive pre-assigned tasks via `TaskUpdate({ owner })` before spawning. Each worker works through its assigned task list sequentially instead of dynamically claiming from the pool.

**Talisman configuration**:
- `work.todos_per_worker`: Maximum tasks per worker per wave (default: 3)
- `work.max_workers`: Maximum workers per role (default: 3)
