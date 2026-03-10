---
name: rune:team-spawn
description: |
  Spawn an Agent Team using presets (review, work, plan, fix, debug, audit) or custom composition.
  Wraps team-sdk TeamEngine.ensureTeam() and spawnWave().
  Use when you need a standalone agent team for ad-hoc work outside of workflow skills.

  <example>
  user: "/rune:team-spawn review"
  assistant: "Spawning review team with 4 agents..."
  </example>

  <example>
  user: "/rune:team-spawn custom --name my-research"
  assistant: "Custom team -- select agents to spawn..."
  </example>
user-invocable: true
disable-model-invocation: true
argument-hint: "[preset|custom] [--name team-name]"
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
  - AskUserQuestion
---

# /rune:team-spawn — Spawn Agent Team

Spawn an Agent Team using presets or custom composition. Wraps `TeamEngine.ensureTeam()` and `spawnWave()` from team-sdk.

## Usage

```
/rune:team-spawn <preset>          # review, work, plan, fix, debug, audit
/rune:team-spawn custom --name X   # Custom composition with named team
```

## Steps

### Step 0: Parse Arguments

```javascript
const args = "$ARGUMENTS"
const parts = args.trim().split(/\s+/)
const presetName = parts[0] || null
const nameMatch = args.match(/--name\s+(\S+)/)
const nameFlag = nameMatch ? nameMatch[1] : null

// Validate preset name
if (!presetName) {
  error("Usage: /rune:team-spawn <preset|custom> [--name team-name]")
  log("Available presets: review, work, plan, fix, debug, audit, custom")
  return
}

// Validate --name flag if provided (SEC-4 + path traversal guard)
if (nameFlag) {
  if (!/^[a-zA-Z0-9_-]+$/.test(nameFlag)) {
    error("Invalid team name. Must match [a-zA-Z0-9_-]+.")
    return
  }
  if (nameFlag.includes("..")) {
    error("Team name must not contain '..'.")
    return
  }
}
```

### Step 1: Check Existing Teams

```javascript
// One-team-per-lead constraint: check if a team already exists
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()

const stateFiles = Glob("tmp/.rune-*.json") || []
const activeStates = stateFiles
  .map(f => { try { return { path: f, state: JSON.parse(Read(f)) } } catch { return null } })
  .filter(Boolean)
  .filter(s => s.state.status === "active")
  .filter(s => {
    // Session ownership: only flag teams owned by THIS session
    if (s.state.config_dir && s.state.config_dir !== configDir) return false
    if (s.state.owner_pid && /^\d+$/.test(s.state.owner_pid) && s.state.owner_pid !== ownerPid) {
      const alive = Bash(`kill -0 ${s.state.owner_pid} 2>/dev/null && echo alive`).trim()
      if (alive === "alive") return false  // Another live session owns this
    }
    return true
  })

if (activeStates.length > 0) {
  const choice = AskUserQuestion({
    questions: [{
      question: `Active team detected: ${activeStates[0].state.team_name}. You can only lead one team at a time. Shutdown existing team first?`,
      header: "Conflict",
      options: [
        { label: "Shutdown and proceed", description: "Gracefully shutdown the existing team, then spawn the new one" },
        { label: "Cancel", description: "Keep the existing team running" }
      ],
      multiSelect: false
    }]
  })
  // If "Cancel": return
  // If "Shutdown and proceed": run 5-component cleanup on existing team
  // (see team-shutdown.md Step 5 — apply to activeStates[0].state.team_name)
}
```

### Step 2: Resolve Preset

```javascript
// Call resolvePreset() from team-sdk/references/presets.md
// Built-in preset agents (always agents — conditional agents require workflow context)
const KNOWN_PRESETS = ["review", "work", "plan", "fix", "debug", "audit"]

let preset
if (presetName === "custom") {
  // Custom composition — ask user for agent selection
  const agentChoice = AskUserQuestion({
    questions: [{
      question: "Select agent roles for your team:",
      header: "Agents",
      options: [
        { label: "Reviewers", description: "Code review agents (ward-sentinel, pattern-weaver, forge-warden, veil-piercer)" },
        { label: "Workers", description: "Implementation agents (rune-smith, trial-forger)" },
        { label: "Researchers", description: "Research agents (repo-surveyor, echo-reader, git-miner)" },
        { label: "Investigators", description: "Investigation agents (hypothesis-investigator)" }
      ],
      multiSelect: true
    }]
  })

  // Map selections to concrete agent names
  const agentMap = {
    "Reviewers": ["ward-sentinel", "pattern-weaver", "forge-warden", "veil-piercer"],
    "Workers": ["rune-smith", "trial-forger"],
    "Researchers": ["repo-surveyor", "echo-reader", "git-miner"],
    "Investigators": ["hypothesis-investigator"]
  }

  const selectedAgents = agentChoice.flatMap(role => agentMap[role] || [])
  if (selectedAgents.length === 0) {
    error("No agents selected. Aborting.")
    return
  }

  preset = {
    prefix: nameFlag ? nameFlag : "rune-custom",
    agents: selectedAgents,
    readonly: false
  }
} else if (KNOWN_PRESETS.includes(presetName)) {
  // Use resolvePreset() from team-sdk — delegates to presets.md resolution order
  // team-sdk functions used: resolvePreset(), readTalismanSection(), TeamEngine.ensureTeam(), TeamEngine.spawnWave()
  preset = resolvePreset(presetName)
} else {
  // Check talisman custom presets
  const talisman = readTalismanSection("misc")
  const customPreset = talisman?.team?.custom_presets?.[presetName]
  if (!customPreset) {
    error(`Unknown preset: ${presetName}. Available: ${KNOWN_PRESETS.join(", ")}, custom`)
    return
  }
  preset = customPreset
}
```

### Step 3: Create Team (ensureTeam)

```javascript
const timestamp = Date.now().toString()

const teamName = nameFlag || `${preset.prefix}-${timestamp}`
// SEC-4: validate team name
if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) {
  error("Invalid team name: must match [a-zA-Z0-9_-]+.")
  return
}
// Defense-in-depth: path traversal guard
if (teamName.includes("..")) {
  error("Team name must not contain '..'.")
  return
}

// Use ensureTeam() for idempotent creation (handles "Already leading" recovery)
const handle = TeamEngine.ensureTeam({
  teamName: teamName,
  workflow: "standalone",
  identifier: timestamp,
  stateFilePrefix: "tmp/.rune-team",
  metadata: {
    preset: presetName,
    agents: preset.agents,
    spawned_by: "team-spawn"
  }
})

// Write state file with session isolation fields
Write(`tmp/.rune-team-${timestamp}.json`, JSON.stringify({
  team_name: teamName,
  started: new Date().toISOString(),
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  workflow: "standalone",
  preset: presetName,
  agents: preset.agents
}))
```

### Step 4: Spawn Agents

```javascript
// Signal directory for completion detection
const signalDir = `tmp/.rune-signals/${teamName}`
Bash(`mkdir -p "${signalDir}"`)

// Output directory
Bash(`mkdir -p "tmp/team-${timestamp}"`)

// Spawn agents from preset via spawnWave
const agentSpecs = preset.agents.map(agentName => {
  // SEC-4: validate each agent name
  if (!/^[a-zA-Z0-9_-]+$/.test(agentName)) throw new Error(`Invalid agent name: ${agentName}`)

  return {
    name: agentName,
    prompt: `You are ${agentName}, a team member in the ${teamName} team (standalone).
Await task assignments via messages from the team lead.
When you receive a task, claim it via TaskUpdate (set owner + status in_progress) and begin work.
Report completion via TaskUpdate (status completed) when done.
Write outputs to tmp/team-${timestamp}/${agentName}-output.md`,
    taskSubject: `${agentName} -- standalone team member`,
    taskDescription: "Awaiting task assignment via /rune:team-delegate",
    activeForm: `${agentName} standing by`
  }
})

const agents = TeamEngine.spawnWave(handle, agentSpecs)
```

### Step 5: Report

```
Team "${teamName}" spawned successfully!

Preset: ${presetName}
Members:
  - ${preset.agents.map(a => `${a} (standing by)`).join("\n  - ")}

Next steps:
  /rune:team-delegate            -- assign tasks to teammates
  /rune:team-delegate --create   -- create new tasks
  /rune:team-status              -- check team progress
  /rune:team-shutdown            -- gracefully shutdown when done
```

## Security Requirements

- **SEC-4**: All team/agent names validated against `/^[a-zA-Z0-9_-]+$/`
- **Path traversal**: `..` check on team names
- **Session isolation**: State file includes `config_dir`, `owner_pid`, `session_id`
- **CHOME pattern**: Uses `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` for config resolution
- **TEAM-001**: All Agent() calls include `team_name`

## Notes

- Uses `ensureTeam()` for idempotent team creation (safe to call multiple times)
- Uses `resolvePreset()` from team-sdk for preset resolution (supports talisman overrides)
- State file prefix: `tmp/.rune-team-{timestamp}.json`
- Workflow field set to `"standalone"` to distinguish from workflow-spawned teams
- One-team-per-lead constraint enforced in Step 1
