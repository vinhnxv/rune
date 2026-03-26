# Pre-Flight: State File Conflict Detection

Before creating a new state file, check if one already exists from a previous or concurrent session. This enforces Rule 2 (ONE arc at a time) and prevents data corruption from concurrent arcs.

| Case | State File | Plan Match | Owner Alive | Session Match | Action |
|------|-----------|------------|-------------|--------------|--------|
| F1 | No | — | — | — | **Proceed**: create state file, start arc |
| F2 | Yes | Same | Yes | Same | **BLOCKED**: already running in this session |
| F3 | Yes | Same | Yes | Different | **BLOCKED**: running in another session |
| F4 | Yes | Same | No | — | **Auto-decide**: resume if checkpoint has completed phases, else fresh start |
| F5 | Yes | Different | Yes | — | **BLOCKED**: different plan is running |
| F6 | Yes | Different | No | — | **Auto-fresh**: clean up stale state silently |

> **F2, F3, F5 are hard blocks** — no "proceed anyway" option. The user MUST cancel the existing arc first via `/rune:cancel-arc`.

```javascript
// ── Pre-flight: State file conflict detection (runs BEFORE state file creation) ──
const stateFile = ".rune/arc-phase-loop.local.md"
const stateExists = Bash(`test -f "${stateFile}" && echo "yes" || echo "no"`).trim() === "yes"

if (stateExists) {
  const stateContent = Read(stateFile)
  const statePlanFile = extractYamlField(stateContent, "plan_file")
  const stateOwnerPid = extractYamlField(stateContent, "owner_pid")
  const stateSessionId = extractYamlField(stateContent, "session_id")
  const stateActive = extractYamlField(stateContent, "active")

  // Inactive state file → clean up silently and proceed
  if (stateActive !== "true") {
    Bash(`rm -f "${stateFile}"`)
    // F1 equivalent: proceed to create new state file
  } else {
    // Check owner PID liveness (cross-platform: works on macOS + Linux)
    const pidAlive = stateOwnerPid
      ? Bash(`kill -0 ${stateOwnerPid} 2>/dev/null && echo yes || echo no`).trim() === "yes"
      : false
    const samePlan = (statePlanFile === planFile)
    const sameSession = (stateSessionId === "${CLAUDE_SESSION_ID}")

    if (samePlan && pidAlive && sameSession) {
      // F2: Already running in this session
      throw new Error(
        "Arc already running for this plan in this session. " +
        "Run `/rune:cancel-arc` to stop it first."
      )
    }
    if (samePlan && pidAlive && !sameSession) {
      // F3: Running in another live session
      throw new Error(
        `Arc running for this plan in another session (PID ${stateOwnerPid}). ` +
        "Only that session or `/rune:cancel-arc` can stop it."
      )
    }
    if (samePlan && !pidAlive) {
      // F4: Same plan, owner dead → auto-decide based on checkpoint progress
      // Check if checkpoint exists and has completed phases
      const checkpointFiles = Bash(
        `find "${CWD}/.rune/arc" -maxdepth 2 -name checkpoint.json -not -path "*/archived/*" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1`
      ).trim()
      let completedPhaseCount = 0
      if (checkpointFiles) {
        try {
          const cpContent = Read(checkpointFiles)
          const cp = JSON.parse(cpContent)
          // Count phases with status "completed" or "skipped"
          if (cp.phases) {
            completedPhaseCount = Object.values(cp.phases)
              .filter(p => p.status === "completed" || p.status === "skipped").length
          }
        } catch (e) { /* corrupted checkpoint → fresh start */ }
      }

      if (completedPhaseCount > 0) {
        // Auto-resume: checkpoint has progress worth preserving
        // Log the decision for transparency (not a blocking prompt)
        warn(`F4 auto-resume: Found interrupted arc with ${completedPhaseCount} completed/skipped phases. Resuming automatically.`)
        args = args.replace(planFile, "--resume")
        Read("references/arc-resume.md")
        // Execute resume algorithm and return — do not create new state file
        return
      } else {
        // Auto-fresh: no completed phases → nothing to preserve, clean start is better
        warn("F4 auto-fresh: Interrupted arc has no completed phases. Starting fresh.")
        Bash(`rm -f "${stateFile}"`)
      }
    }
    if (!samePlan && pidAlive) {
      // F5: Different plan, still running
      throw new Error(
        `Another arc is running a different plan (${statePlanFile}). ` +
        "Only one arc can run at a time. Cancel it first with `/rune:cancel-arc`."
      )
    }
    if (!samePlan && !pidAlive) {
      // F6: Different plan, owner dead → auto-clean silently
      // Dead owner + different plan = stale orphan, no reason to keep it
      warn(`F6 auto-clean: Removing stale arc state for different plan (${statePlanFile}, owner PID ${stateOwnerPid} is dead).`)
      Bash(`rm -f "${stateFile}"`)
      // Proceed to create new state file
    }
  }
}
// F1: No state file exists → proceed normally to create one below
```
