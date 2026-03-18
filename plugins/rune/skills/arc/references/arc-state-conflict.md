# Pre-Flight: State File Conflict Detection

Before creating a new state file, check if one already exists from a previous or concurrent session. This enforces Rule 2 (ONE arc at a time) and prevents data corruption from concurrent arcs.

| Case | State File | Plan Match | Owner Alive | Session Match | Action |
|------|-----------|------------|-------------|--------------|--------|
| F1 | No | — | — | — | **Proceed**: create state file, start arc |
| F2 | Yes | Same | Yes | Same | **BLOCKED**: already running in this session |
| F3 | Yes | Same | Yes | Different | **BLOCKED**: running in another session |
| F4 | Yes | Same | No | — | **Prompt**: resume or fresh start? |
| F5 | Yes | Different | Yes | — | **BLOCKED**: different plan is running |
| F6 | Yes | Different | No | — | **Prompt**: clean up stale state? |

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
      // F4: Same plan, owner dead → ask user
      const choice = AskUserQuestion({
        question:
          "Found interrupted arc for the same plan (owner session is dead).\n" +
          "- **Resume**: continue from where it stopped\n" +
          "- **Fresh**: delete stale state and start from scratch\n\n" +
          "Choose: resume / fresh"
      })
      if (choice.toLowerCase().includes("resume")) {
        // Switch to --resume flow
        args = args.replace(planFile, "--resume")
        Read("references/arc-resume.md")
        // Execute resume algorithm and return — do not create new state file
        return
      } else {
        // Clean up stale state file + checkpoint, then proceed
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
      // F6: Different plan, owner dead → ask user
      const choice = AskUserQuestion({
        question:
          `Found stale arc state for a different plan (${statePlanFile}, owner PID ${stateOwnerPid} is dead).\n` +
          "Clean up stale state and start fresh? (yes / no)"
      })
      if (choice.toLowerCase().includes("yes")) {
        Bash(`rm -f "${stateFile}"`)
        // Proceed to create new state file
      } else {
        throw new Error("Aborted by user. Clean up manually or run `/rune:cancel-arc`.")
      }
    }
  }
}
// F1: No state file exists → proceed normally to create one below
```
