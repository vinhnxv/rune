---
name: arc-quick
description: |
  Lightweight 4-phase pipeline: Plan -> Work+Evaluate -> Review -> Mend.
  Chains devise --quick -> strive (with evaluator loop) -> appraise -> mend in one command.
  Work phase iterates up to max_iterations (default 3) with ward checks and
  quality signal detection between passes. Stagnation detection prevents infinite loops.
  Mend phase auto-fixes P1/P2 findings from the review TOME.
  Accepts a prompt string or existing plan file path.
  Recommends /rune:arc for complex plans (8+ tasks) unless --force is passed.
  Use when: "quick run", "fast pipeline", "plan and build", "nhanh",
  "chay nhanh", "quick arc", "simple pipeline", "4 steps",
  "plan work review mend", "quick", "arc-quick".

  <example>
  user: "/rune:arc-quick add a health check endpoint"
  assistant: "Starting quick pipeline: plan -> work -> review..."
  </example>

  <example>
  user: "/rune:arc-quick plans/my-plan.md"
  assistant: "Running quick pipeline on existing plan..."
  </example>

  <example>
  user: "/rune:arc-quick plans/complex-plan.md --force"
  assistant: "Force-running quick pipeline (skipping complexity warning)..."
  </example>
user-invocable: true
argument-hint: "[prompt or plan-path] [--force]"
---

# /rune:arc-quick --- Lightweight 4-Phase Pipeline

Runs **Plan -> Work -> Review -> Mend** (`devise --quick` -> `strive` -> `appraise` -> `mend`) in one command.
A simplified alternative to `/rune:arc` (45 phases) for small-to-medium features.

**Load skills**: `polling-guard`, `zsh-compat`

## Usage

```bash
/rune:arc-quick add a health check endpoint           # From prompt (runs devise first)
/rune:arc-quick plans/my-plan.md                       # From existing plan (skips devise)
/rune:arc-quick plans/complex-plan.md --force           # Skip complexity warning
/rune:quick add dark mode toggle                       # Beginner alias
```

## Flags

| Flag | Effect |
|------|--------|
| `--force` | Skip complexity gate warning (run quick pipeline even on complex plans) |

## Pipeline

```
Input Resolution
  -> is it a .md file path?
    YES -> planPath = input, skip to Complexity Gate
    NO  -> treat as prompt, go to Phase 1

Phase 1: PLAN (conditional --- only when input is a prompt)
  Skill("rune:devise", "--quick {prompt}")
  Output: plans/YYYY-MM-DD-{type}-{name}-plan.md

Complexity Gate (always, after plan is available)
  Score plan complexity
  If complex AND NOT --force: suggest /rune:arc
  If user accepts arc: Skill("rune:arc", planPath) --- then STOP

Phase 2: WORK + EVALUATE LOOP (max_iterations from talisman, default 3)
  Loop:
    Skill("rune:strive", planPath)       // iteration 1: full, 2+: --resume
    evaluateIteration(planPath, N, baseRef)
    Break on: PASS, stagnation, or max iterations
  Output: implemented code on feature branch

Phase 3: REVIEW
  Skill("rune:appraise")
  Output: TOME with findings

Phase 4: MEND (conditional --- only when TOME has P1/P2 findings)
  Skill("rune:mend", tomePath)
  Output: findings resolved, code updated

Summary: present results + iteration history + next steps
```

## Execution

### Step 1: Parse Arguments

```javascript
const rawArgs = "$ARGUMENTS".trim()
const force = rawArgs.includes("--force")
const args = rawArgs.replace(/--force/g, "").trim()
```

### Step 2: Input Resolution

```javascript
let planPath = null
let mode = "prompt"  // "prompt" or "plan"

if (args.endsWith(".md") && !args.includes(" ")) {
  // Input is a plan file path
  if (!/^[a-zA-Z0-9._\-\/]+$/.test(args) || args.includes("..")) {
    // Path validation failed
    error("Invalid plan path. Use a relative path like plans/my-plan.md")
    return
  }
  planPath = args
  mode = "plan"

  // Verify plan exists
  try {
    Read(planPath)
  } catch (e) {
    error(`Plan file not found: ${planPath}\nCreate one with /rune:plan`)
    return
  }
} else if (args === "") {
  // No args --- auto-detect recent plan or ask for prompt
  const plans = Glob("plans/*.md")
  if (plans.length > 0) {
    // Offer latest plan or ask for new prompt
    AskUserQuestion({
      question: `Found ${plans.length} recent plan(s). Latest: ${plans[0]}`,
      options: [
        { label: `Use ${plans[0]}`, description: "Run quick pipeline on this plan" },
        { label: "Describe a new feature", description: "Create a new plan first" }
      ]
    })
    // If user picks existing plan:
    //   planPath = plans[0]; mode = "plan"
    // If user wants new feature:
    //   Ask for description, set mode = "prompt"
  } else {
    AskUserQuestion({
      question: "No plans found. Describe the feature you want to build:"
    })
    // mode = "prompt", use response as prompt
  }
} else {
  // Input is a prompt string
  mode = "prompt"
}
```

### Step 3: Phase 1 --- PLAN (conditional)

```javascript
if (mode === "prompt") {
  const prompt = args  // or user's response from AskUserQuestion

  // Run devise --quick to create a plan
  Skill("rune:devise", `--quick ${prompt}`)

  // After devise completes, find the generated plan
  const plans = Glob("plans/*.md")
  if (plans.length === 0) {
    error("Planning failed --- no plan file generated. Try /rune:plan manually.")
    return
  }
  planPath = plans[0]  // most recent (Glob returns sorted by mtime)
}
```

### Step 4: Complexity Gate

```javascript
const planContent = Read(planPath)

// Count tasks and sections
const taskCount = (planContent.match(/^###\s+Task/gm) || []).length
const sectionCount = (planContent.match(/^##\s+/gm) || []).length
const effortMatch = planContent.match(/estimated_effort:\s*(S|M|L|XL)/i)
const effort = effortMatch ? effortMatch[1].toUpperCase() : "M"

// Simplified complexity check
const isComplex = taskCount >= 8 || (sectionCount >= 6 && effort !== "S")

if (isComplex && !force) {
  AskUserQuestion({
    question: `This plan has ${taskCount} tasks and ${sectionCount} sections --- it looks complex.\n\nThe quick pipeline (plan -> work -> review -> mend) skips forge enrichment, gap analysis, testing, and ship/merge. For complex plans, these steps catch issues early.\n\nWhat would you like to do?`,
    options: [
      { label: "Switch to /rune:arc (full 45-phase pipeline)",
        description: "Recommended for complex plans --- thorough but takes 1-3 hours" },
      { label: "Continue with quick pipeline",
        description: "Plan -> Work -> Review -> Mend --- faster but less thorough" }
    ]
  })
  // If user picks arc:
  //   Skill("rune:arc", planPath)
  //   return  // arc handles everything from here
}
```

### Step 5: Phase 2 --- WORK + EVALUATE LOOP

```javascript
// readTalismanSection: "arc"
const arcQuickConfig = readTalismanSection("arc")?.quick ?? {}
let maxIterations = Math.max(1, Math.min(arcQuickConfig.max_iterations ?? 3, 10))
let skipEvaluate = arcQuickConfig.skip_evaluate ?? false

// FLAW-002: max_iterations:0 means "skip evaluator", not "skip work phase"
if ((arcQuickConfig.max_iterations ?? 3) === 0) {
  maxIterations = 1
  skipEvaluate = true
}

let iteration = 0
const iterationHistory = []

while (iteration < maxIterations) {
  iteration++

  // Record git ref before this strive pass for diff scoping
  const baseRef = Bash("git rev-parse HEAD").trim()

  if (iteration === 1) {
    // First pass: full strive
    Skill("rune:strive", planPath)
  } else {
    // Subsequent passes: write evaluator feedback to sidecar file, then resume
    const prevResult = iterationHistory[iterationHistory.length - 1]
    const feedbackSection = `## Evaluator Feedback — Iteration ${iteration}\n\n` +
      `Previous iteration found ${prevResult.findings.length} issue(s):\n` +
      prevResult.findings.map(f =>
        `- **${f.type}**: ${f.name ?? f.pattern ?? "unknown"} ${f.file ? `in \`${f.file}\`` : ""}`
      ).join("\n") +
      `\n\nFix these issues. Do not introduce new regressions.\n`
    // BACK-004: Write to sidecar instead of Edit(append) which is invalid
    // FLAW-006: Prevents unbounded plan file growth
    Write(`tmp/arc-quick-feedback-${iteration}.md`, feedbackSection)
    Skill("rune:strive", `${planPath} --resume`)
  }

  // FLAW-005: Detect strive producing no commits (empty diff = strive failure, not success)
  const headAfterStrive = Bash("git rev-parse HEAD").trim()
  if (headAfterStrive === baseRef) {
    iterationHistory.push({ verdict: "ITERATE", findings: [{ type: "strive", name: "no-commits" }],
                            confidence: 0.3, iteration, timestamp: new Date().toISOString(),
                            reason: "Strive produced no commits — no changes to evaluate" })
    if (iteration >= maxIterations) break
    continue
  }

  // Skip evaluation if configured
  if (skipEvaluate) {
    // BACK-003: Confidence normalized to 0.0-1.0 per AC-5
    iterationHistory.push({ verdict: "PASS", findings: [], confidence: 1.0,
                            iteration, timestamp: new Date().toISOString(),
                            reason: "Evaluation skipped (skip_evaluate: true)" })
    break
  }

  // Evaluate this iteration's changes
  const evalResult = evaluateIteration(planPath, iteration, baseRef)
  iterationHistory.push(evalResult)

  if (evalResult.verdict === "PASS") break

  // Stagnation detection: findings not decreasing → stop iterating
  if (iteration >= 2) {
    const prevCount = iterationHistory[iteration - 2].findings.length
    if (evalResult.findings.length >= prevCount) {
      evalResult.reason += " (stagnation detected — findings not decreasing)"
      break
    }
  }
}
```

### Step 6: Phase 3 --- REVIEW

```javascript
Skill("rune:appraise")
```

### Step 7: Phase 4 --- MEND (conditional)

```javascript
// Find the TOME from the review
const tomes = Glob("tmp/reviews/*/TOME.md")
const latestTome = tomes.length > 0 ? tomes[0] : null

if (latestTome) {
  const tomeContent = Read(latestTome)
  const hasActionableFindings = /\bP1\b|\bP2\b/.test(tomeContent)

  if (hasActionableFindings) {
    Skill("rune:mend", latestTome)
  } else {
    log("No P1/P2 findings in TOME — skipping mend phase")
  }
} else {
  log("No TOME found — skipping mend phase")
}
```

### Step 8: Summary

After all phases complete, present results with iteration history:

```javascript
// Get current branch
const branch = Bash("git branch --show-current").trim()

// Compute quality trajectory from iterationHistory
function computeTrajectory(history) {
  if (history.length <= 1) return "N/A"
  const counts = history.map(h => h.findings.length)
  const improving = counts.every((c, i) => i === 0 || c < counts[i - 1])
  const stagnating = counts.every((c, i) => i === 0 || c === counts[i - 1])
  if (improving) return "IMPROVING"
  if (stagnating) return "STAGNATING"
  return counts[counts.length - 1] > counts[0] ? "DEGRADING" : "MIXED"
}

const trajectory = computeTrajectory(iterationHistory)

// Build iteration history table rows
const iterationRows = iterationHistory.map(h =>
  `| ${h.iteration} | ${h.verdict} | ${h.findings.length} | ${h.confidence} | ${h.reason} |`
).join("\n")

// Check for mend resolution report
const mendReports = Glob("tmp/mend/*/resolution-report.md")
const mendReport = mendReports.length > 0 ? mendReports[0] : null
const mendStatus = mendReport ? "Resolved" : (latestTome ? "Skipped (no P1/P2)" : "Skipped (no TOME)")

// Present summary
const summary = `
## Quick Pipeline Complete

| Phase | Result |
|-------|--------|
| Plan | ${planPath} |
| Work | Implemented on branch \`${branch}\` (${iterationHistory.length} iteration${iterationHistory.length > 1 ? "s" : ""}) |
| Review | ${latestTome ? `Findings in \`${latestTome}\`` : "No findings file found"} |
| Mend | ${mendStatus}${mendReport ? ` — see \`${mendReport}\`` : ""} |

### Iteration History

| # | Verdict | Findings | Confidence | Reason |
|---|---------|----------|------------|--------|
${iterationRows}

**Quality trajectory**: ${trajectory}

### Next Steps

- \`/rune:arc ${planPath}\` --- run full 45-phase pipeline if needed
- \`git push\` --- push your changes
- \`/rune:rest\` --- clean up tmp/ artifacts
`
```

## Error Handling

| Phase | On Failure | Recovery |
|-------|-----------|----------|
| Phase 1 (devise) | No plan generated | Stop, suggest manual `/rune:plan` |
| Phase 2 (strive) | Workers fail | Stop, present partial results, suggest `--approve` |
| Phase 3 (appraise) | Review fails | Non-blocking --- warn, suggest manual `/rune:review` |
| Phase 4 (mend) | Mend fails | Non-blocking --- warn, suggest manual `/rune:mend` |
| Complexity gate | User picks arc | Delegate to `/rune:arc`, stop quick pipeline |

### Evaluator Function

```javascript
/**
 * Evaluate iteration quality after a strive pass.
 * Uses discoverWards() (see ward-check.md) — never hardcodes test commands.
 * Scopes quality signals to changed files only to avoid false positives.
 *
 * @param {string} planPath — path to the plan file
 * @param {number} iterationNumber — current iteration (1-based)
 * @param {string} baseRef — git ref before this strive pass
 * @returns {{ verdict, findings, confidence, iteration, timestamp, reason }}
 */
function evaluateIteration(planPath, iterationNumber, baseRef) {
  // BACK-001: Read evaluate_timeout_ms from talisman (default 60s)
  const evaluateTimeoutMs = (readTalismanSection("arc")?.quick?.evaluate_timeout_ms) ?? 60000
  log(`Evaluator iteration ${iterationNumber}: starting (timeout: ${evaluateTimeoutMs}ms)`)

  // SEC-004: Validate git ref before interpolation
  if (!/^[0-9a-f]{7,40}$/.test(baseRef)) {
    log(`Evaluator iteration ${iterationNumber}: invalid baseRef "${baseRef}", skipping`)
    return { verdict: "ITERATE", findings: [{ type: "error", name: "invalid-ref", detail: "baseRef failed validation" }],
             confidence: 0.3, iteration: iterationNumber, timestamp: new Date().toISOString(),
             reason: "Invalid git ref — cannot evaluate" }
  }

  const findings = []
  const changedFiles = Bash(`git diff --name-only ${baseRef}`).trim()

  // Empty diff = nothing to evaluate → auto-PASS
  if (changedFiles === "") {
    return { verdict: "PASS", findings: [], confidence: 1.0,
             iteration: iterationNumber, timestamp: new Date().toISOString(),
             reason: "No changes detected — nothing to evaluate" }
  }

  const fileList = changedFiles.split("\n").filter(Boolean)

  // 1. Run ward checks (project-agnostic quality gates)
  // SEC-001: discoverWards() returns project-defined commands already validated by ward-check.md
  const wards = discoverWards()  // see ward-check.md Ward Discovery Protocol
  for (const ward of wards) {
    const result = Bash(ward.command, { timeout: evaluateTimeoutMs })
    if (result.exitCode !== 0) {
      findings.push({ type: "ward", name: ward.name,
                       detail: result.stderr.slice(0, 500) })
    }
  }

  // 2. Grep quality signals scoped to changed files only
  // BACK-002: Known limitation — catches pre-existing signals in changed files, not just new ones.
  // Scoping to diff hunks deferred to v2.
  const patterns = [/TODO|FIXME|HACK|XXX/, /console\.log/, /debugger/]
  for (const file of fileList) {
    for (const pat of patterns) {
      const hits = Grep(pat.source, file)
      if (hits.length > 0) {
        findings.push({ type: "quality", file, pattern: pat.source,
                         count: hits.length })
      }
    }
  }

  const verdict = findings.length === 0 ? "PASS" : "ITERATE"
  // BACK-003: Confidence normalized to 0.0-1.0 per AC-5
  const confidence = findings.length === 0 ? 0.95
    : Math.max(0.3, 0.9 - findings.length * 0.1)

  // BACK-006: Log evaluator result for observability
  const reason = verdict === "PASS" ? "All wards passed, no quality signals"
    : `${findings.length} finding(s): ${findings.map(f => f.name ?? f.pattern ?? "unknown").join(", ")}`
  log(`Evaluator iteration ${iterationNumber}: verdict=${verdict} confidence=${confidence} findings=${findings.length}`)

  return { verdict, findings, confidence, iteration: iterationNumber,
           timestamp: new Date().toISOString(), reason }
}
```

## Design Decisions

1. **No Stop hook loop** --- 4 sequential Skill() calls. Simpler and more debuggable than a state machine.
2. **No checkpoint/resume** --- Total runtime is 25-60 min. If it fails, rerun the command.
3. **No parent team** --- Each Skill() creates and cleans up its own team independently.
4. **No forge, test, ship** --- These make `/rune:arc` take 1-3 hours. Run them separately if needed.
5. **Conditional mend** --- Only runs when TOME has P1/P2 findings. Skips gracefully otherwise.
