# Phase 2: Forge Team

```javascript
// Step 2.1 — Write state file with session isolation fields
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write(`tmp/.rune-inspect-${identifier}.json`, JSON.stringify({
  status: "active", identifier, mode: inspectMode, plan_path: planPath,
  output_dir: outputDir, started: new Date().toISOString(),
  config_dir: configDir, owner_pid: ownerPid, session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  inspectors: Object.keys(inspectorAssignments),
  requirement_count: requirements.length
}))

// Step 2.2 — Create output directory
Bash(`mkdir -p "tmp/inspect/${identifier}"`)

// Step 2.3 — Write inscription.json (output contract)
// Includes context budgets: grace-warden=40, ruin-prophet=30, sight-oracle=35, vigil-keeper=30
// instruction_anchoring: true, reanchor_interval: 5

// Step 2.3.5 — Workflow lock (reader)
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "reader"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "inspect" "reader"`)

// Step 2.4 — Pre-create guard (teamTransition pattern)
//   Step A: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
//   Step B: Filesystem fallback if Step A failed (CDX-003 gate: !teamDeleteSucceeded)
//   Step C: Cross-workflow scan (stale inspect teams only — mmin +30)
const teamName = `rune-inspect-${identifier}`
// Validate: /^[a-zA-Z0-9_-]+$/ before any rm -rf

// Step 2.5 — Create team and signal dir
TeamCreate({ team_name: teamName })
// SEC-003: .readonly-active NOT created for inspect — inspectors need Write for output files
const signalDir = `tmp/.rune-signals/${teamName}`
Bash(`mkdir -p "${signalDir}"`)
Write(`${signalDir}/.expected`, String(Object.keys(inspectorAssignments).length))

// Step 2.6 — Create tasks (one per inspector + aggregator)
// Aggregator task blocked by all inspector tasks
```
