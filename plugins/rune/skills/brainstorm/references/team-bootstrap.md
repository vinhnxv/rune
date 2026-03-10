# Phase 1: Team Bootstrap (Team/Deep modes only)

Skip for Solo mode — proceed directly to Phase 2.

For Team or Deep mode, create the Agent Team and spawn advisors:

```javascript
const timestamp = Date.now().toString()
// SEC-001: Validate timestamp is exactly 13 digits, reject path traversal
if (!/^\d{13}$/.test(timestamp)) throw new Error("Invalid timestamp")

// teamTransition protocol (standard 6-step pattern):
const teamName = `rune-brainstorm-${timestamp}`
// STEP 1: Timestamp already validated above (SEC-001)
// STEP 2: TeamDelete retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s)
let teamDeleteSucceeded = false
for (const delay of [0, 5000, 10000, 15000]) {
  if (delay > 0) Bash(`sleep ${delay / 1000}`)
  try { TeamDelete(); teamDeleteSucceeded = true; break } catch (e) { /* retry */ }
}
// STEP 3: Filesystem fallback (gated on !teamDeleteSucceeded)
if (!teamDeleteSucceeded) {
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
}
// STEP 4: TeamCreate with "Already leading" catch-and-recover
try { TeamCreate({ team_name: teamName }) } catch (e) {
  if (e.message?.includes("Already leading")) { TeamDelete(); TeamCreate({ team_name: teamName }) }
  else throw e
}
// STEP 5: Post-create verification
const teamConfig = Read(`\${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${teamName}/config.json`)
if (!teamConfig) throw new Error("TeamCreate verification failed")

// STEP 6: Write workflow state file with session isolation fields
const configDir = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && cd "$CHOME" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write(`tmp/.rune-brainstorm-${timestamp}.json`, {
  team_name: `rune-brainstorm-${timestamp}`,
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  feature: featureDescription,
  mode: mode
})

// Create workspace directory
Bash(`mkdir -p "tmp/brainstorm-${timestamp}/"{rounds,advisors,research,elicitation,design}`)

// Spawn 3 Advisor agents — see references/advisor-prompts.md for full persona details
// ATE-1 COMPLIANT: agents join rune-brainstorm-{timestamp} team
for (const advisor of ["user-advocate", "tech-realist", "devils-advocate"]) {
  TaskCreate({
    subject: `Brainstorm Advisor: ${advisor}`,
    description: `${advisor} advisory role in brainstorm roundtable`,
    activeForm: `${advisor} analyzing`
  })
  // Read references/advisor-prompts.md for the full prompt for each advisor
  Agent({
    name: advisor,
    subagent_type: "general-purpose",
    team_name: `rune-brainstorm-${timestamp}`,
    prompt: advisorPrompt(advisor, featureDescription, timestamp),
    run_in_background: true
  })
}

// Signal directory for fast completion detection
// SEC-007: timestamp already validated as /^\d{13}$/ above (SEC-001)
const signalDir = `tmp/.rune-signals/rune-brainstorm-${timestamp}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
```

See [advisor-prompts.md](advisor-prompts.md) for full advisor persona definitions and prompt templates.
