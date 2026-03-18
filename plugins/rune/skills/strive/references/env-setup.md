# Phase 0.5: Environment Setup

Verifies the git environment is safe for work before forging the team. Checks branch safety, handles dirty working trees, and validates worktree prerequisites.

**Inputs**: `talisman` (config), `worktreeMode` (boolean from Phase 0)
**Outputs**: `didStash` (boolean — consumed by Phase 6 cleanup), feature branch (if created)
**Preconditions**: Phase 0 (Parse Plan) complete

**Skip condition**: When invoked via `/rune:arc`, skip Phase 0.5 entirely — arc handles branch creation in its Pre-flight phase (COMMIT-1). Detection: check for active arc checkpoint at `.rune/arc/*/checkpoint.json` with any phase status `"in_progress"`.

**Talisman override**: `work.skip_branch_check: true` disables this phase for experienced users who manage branches manually.

## Branch Check

```javascript
const currentBranch = Bash("git branch --show-current").trim()
const defaultBranch = Bash("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'").trim()
  || (Bash("git rev-parse --verify origin/main 2>/dev/null").exitCode === 0 ? "main" : "master")
if (currentBranch === "") {
  throw new Error("Detached HEAD detected. Checkout a branch before running /rune:strive: git checkout -b <branch>")
}
const BRANCH_RE = /^[a-zA-Z0-9][a-zA-Z0-9._\/-]*$/
if (!BRANCH_RE.test(currentBranch)) throw new Error(`Invalid current branch name: ${currentBranch}`)
if (!BRANCH_RE.test(defaultBranch)) throw new Error(`Unexpected default branch name: ${defaultBranch}`)

if (currentBranch === defaultBranch) {
  AskUserQuestion({
    questions: [{
      question: `You're on \`${defaultBranch}\`. Workers will commit here. Create a feature branch?`,
      header: "Branch",
      options: [
        { label: "Create branch (Recommended)", description: "Create a feature branch from current HEAD" },
        { label: "Continue on " + defaultBranch, description: "Workers commit directly to " + defaultBranch }
      ],
      multiSelect: false
    }]
  })
  // If create branch: derive slug from plan name, validate, checkout -b
  // If continue on default: require explicit "yes" confirmation (fail-closed)
}
```

## Dirty Working Tree Check

```javascript
const status = Bash("git status --porcelain").trim()
if (status !== "") {
  AskUserQuestion({
    questions: [{
      question: "Uncommitted changes found. How to proceed?",
      header: "Git state",
      options: [
        { label: "Stash changes (Recommended)", description: "git stash -- restore after work completes" },
        { label: "Continue anyway", description: "Workers may conflict with uncommitted changes" }
      ],
      multiSelect: false
    }]
  })
  // Default on timeout: stash (fail-safe)
}
let didStash = false  // Set to true if stash was applied above; consumed by Phase 6 cleanup
```

**Branch name derivation**: `rune/work-{slugified-plan-name}-{YYYYMMDD-HHMMSS}` matching arc skill's COMMIT-1 convention.

**Worktree validation**: When `worktreeMode === true`, validate git version >= 2.5, run `git worktree list`, and perform SDK canary test (C3). All three steps fall back to patch mode instead of aborting. See worktree validation pseudocode in the full command for details.
