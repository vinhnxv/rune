---
name: arc-quick
description: |
  Lightweight 3-phase pipeline: Plan -> Work -> Review.
  Chains devise --quick -> strive -> appraise in one command.
  Accepts a prompt string or existing plan file path.
  Recommends /rune:arc for complex plans (8+ tasks) unless --force is passed.
  Use when: "quick run", "fast pipeline", "plan and build", "nhanh",
  "chay nhanh", "quick arc", "simple pipeline", "3 steps",
  "plan work review", "quick", "arc-quick".

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

# /rune:arc-quick --- Lightweight 3-Phase Pipeline

Runs **Plan -> Work -> Review** (`devise --quick` -> `strive` -> `appraise`) in one command.
A simplified alternative to `/rune:arc` (43 phases) for small-to-medium features.

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

Phase 2: WORK
  Skill("rune:strive", planPath)
  Output: implemented code on feature branch

Phase 3: REVIEW
  Skill("rune:appraise")
  Output: TOME with findings

Summary: present results + next steps
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
    question: `This plan has ${taskCount} tasks and ${sectionCount} sections --- it looks complex.\n\nThe quick pipeline (plan -> work -> review) skips forge enrichment, gap analysis, mend loops, testing, and ship/merge. For complex plans, these steps catch issues early.\n\nWhat would you like to do?`,
    options: [
      { label: "Switch to /rune:arc (full 43-phase pipeline)",
        description: "Recommended for complex plans --- thorough but takes 1-3 hours" },
      { label: "Continue with quick pipeline",
        description: "Plan -> Work -> Review only --- faster but less thorough" }
    ]
  })
  // If user picks arc:
  //   Skill("rune:arc", planPath)
  //   return  // arc handles everything from here
}
```

### Step 5: Phase 2 --- WORK

```javascript
Skill("rune:strive", planPath)
```

### Step 6: Phase 3 --- REVIEW

```javascript
Skill("rune:appraise")
```

### Step 7: Summary

After all 3 phases complete, present results:

```javascript
// Find the TOME from the review
const tomes = Glob("tmp/reviews/*/TOME.md")
const latestTome = tomes.length > 0 ? tomes[0] : null

// Get current branch
const branch = Bash("git branch --show-current").trim()

// Present summary
const summary = `
## Quick Pipeline Complete

| Phase | Result |
|-------|--------|
| Plan | ${planPath} |
| Work | Implemented on branch \`${branch}\` |
| Review | ${latestTome ? `Findings in \`${latestTome}\`` : "No findings file found"} |

### Next Steps

${latestTome ? `- \`/rune:mend ${latestTome}\` --- auto-fix review findings` : ""}
- \`/rune:arc ${planPath}\` --- run full 43-phase pipeline if needed
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
| Complexity gate | User picks arc | Delegate to `/rune:arc`, stop quick pipeline |

## Design Decisions

1. **No Stop hook loop** --- 3 sequential Skill() calls. Simpler and more debuggable than a state machine.
2. **No checkpoint/resume** --- Total runtime is 25-60 min. If it fails, rerun the command.
3. **No parent team** --- Each Skill() creates and cleans up its own team independently.
4. **No forge, mend, test, ship** --- These make `/rune:arc` take 1-3 hours. Run them separately if needed.
