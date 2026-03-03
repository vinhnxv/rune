---
name: runs
description: |
  Inspect per-agent structured artifacts from Rune workflow runs.
  List recent runs, show agent inputs/outputs, view timing statistics,
  and find failed agents for retry.
  Trigger keywords: runs, artifacts, agent history, workflow runs.

  <example>
  user: "/rune:runs list"
  assistant: "Scanning tmp/ for workflow run artifacts..."
  </example>

  <example>
  user: "/rune:runs failures"
  assistant: "Searching for failed/crashed agents across all runs..."
  </example>

user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash
argument-hint: "[list|show <agent>|stats|failures]"
---

# /rune:runs -- Per-Agent Artifact Inspector

Inspect structured artifacts (meta.json, input.md) written by Rune workflows for every spawned agent.

## Usage

```
/rune:runs list               -- List recent workflow runs with agent counts
/rune:runs show <agent-name>  -- Show details for a specific agent run
/rune:runs stats              -- Aggregate timing statistics from run-index.jsonl
/rune:runs failures           -- List failed/crashed agents with input for retry
```

## Commands

### 1. `/rune:runs list`

Discover and list all workflow runs that contain per-agent artifacts.

```javascript
const subcommand = "$ARGUMENTS".split(/\s+/)[0] || "list"

if (subcommand === "list") {
  // Scan for run directories across all workflow output dirs
  const metaFiles = Glob("tmp/**/runs/*/meta.json")

  if (metaFiles.length === 0) {
    log("No run artifacts found. Artifacts are created by /rune:appraise, /rune:audit, /rune:strive, and /rune:devise.")
    return
  }

  // Group by workflow run (parent of runs/ directory)
  const runsByWorkflow = {}
  for (const metaPath of metaFiles) {
    // Extract workflow output dir: everything before /runs/agent/meta.json
    const runDir = metaPath.replace(/\/runs\/[^/]+\/meta\.json$/, '')
    if (!runsByWorkflow[runDir]) {
      runsByWorkflow[runDir] = []
    }
    const meta = JSON.parse(Read(metaPath))
    runsByWorkflow[runDir].push(meta)
  }

  // Render table
  log("## Recent Workflow Runs\n")
  log("| Workflow | Timestamp/ID | Agents | Completed | Failed | Avg Duration |")
  log("|----------|-------------|--------|-----------|--------|-------------|")

  for (const [dir, agents] of Object.entries(runsByWorkflow).sort().reverse()) {
    const workflow = agents[0]?.workflow || "unknown"
    const dirParts = dir.split('/')
    const timestamp = dirParts[dirParts.length - 1] || "?"
    const completed = agents.filter(a => a.status === "completed").length
    const failed = agents.filter(a => a.status === "failed" || a.status === "crashed").length
    const durations = agents.filter(a => a.duration_seconds > 0).map(a => a.duration_seconds)
    const avgDur = durations.length > 0
      ? Math.round(durations.reduce((a,b) => a+b, 0) / durations.length)
      : "-"
    log(`| ${workflow} | ${timestamp} | ${agents.length} | ${completed} | ${failed} | ${avgDur}s |`)
  }
}
```

### 2. `/rune:runs show <agent-name>`

Show detailed information for a specific agent's run.

```javascript
if (subcommand === "show") {
  const agentName = "$ARGUMENTS".split(/\s+/)[1]
  if (!agentName) {
    log("Usage: /rune:runs show <agent-name>")
    log("Example: /rune:runs show ward-sentinel")
    return
  }

  // SEC: validate agent name
  if (!/^[a-zA-Z0-9_-]+$/.test(agentName)) {
    error("Invalid agent name. Must be alphanumeric with hyphens/underscores only.")
    return
  }

  // Find all runs for this agent
  const metaFiles = Glob(`tmp/**/runs/${agentName}/meta.json`)

  if (metaFiles.length === 0) {
    log(`No run artifacts found for agent "${agentName}".`)
    log("Use /rune:runs list to see available agents.")
    return
  }

  // Show most recent run (last in list, Glob sorts by mtime)
  const metaPath = metaFiles[0]
  const runDir = metaPath.replace(/\/meta\.json$/, '')
  const meta = JSON.parse(Read(metaPath))

  log(`## Agent Run: ${agentName}\n`)
  log(`- **Workflow**: ${meta.workflow}`)
  log(`- **Team**: ${meta.team_name}`)
  log(`- **Status**: ${meta.status}`)
  log(`- **Started**: ${meta.started_at}`)
  log(`- **Completed**: ${meta.completed_at || "(still running)"}`)
  log(`- **Duration**: ${meta.duration_seconds != null ? meta.duration_seconds + "s" : "-"}`)
  log(`- **Output bytes**: ${meta.output_bytes != null ? meta.output_bytes : "-"}`)
  log(`- **Run dir**: ${runDir}`)
  log("")

  // Show input.md if present
  const inputPath = `${runDir}/input.md`
  const inputExists = Glob(inputPath).length > 0
  if (inputExists) {
    const inputContent = Read(inputPath)
    log("### Agent Input (first 2000 chars)\n")
    log("```")
    log(inputContent.substring(0, 2000))
    log("```")
  }

  // If multiple runs exist, list them
  if (metaFiles.length > 1) {
    log(`\n### Other runs for ${agentName} (${metaFiles.length - 1} more)\n`)
    for (const other of metaFiles.slice(1)) {
      const otherMeta = JSON.parse(Read(other))
      log(`- ${other.replace(/\/meta\.json$/, '')} (${otherMeta.status}, ${otherMeta.started_at})`)
    }
  }
}
```

### 3. `/rune:runs stats`

Aggregate timing statistics from run-index.jsonl files.

```javascript
if (subcommand === "stats") {
  const indexFiles = Glob("tmp/**/run-index.jsonl")

  if (indexFiles.length === 0) {
    log("No run-index.jsonl files found. Statistics are available after workflows write artifact data.")
    return
  }

  // Parse all JSONL entries
  const entries = []
  for (const indexFile of indexFiles) {
    const content = Read(indexFile)
    for (const line of content.split('\n').filter(l => l.trim())) {
      try {
        entries.push(JSON.parse(line))
      } catch (e) { /* skip malformed lines */ }
    }
  }

  // Filter to completed entries only (skip "running" start rows)
  const completed = entries.filter(e => e.status === "completed" && e.duration_seconds != null)
  const failed = entries.filter(e => e.status === "failed" || e.status === "crashed")

  if (completed.length === 0 && failed.length === 0) {
    log("No completed or failed runs to analyze.")
    return
  }

  // Group by agent_name
  const byAgent = {}
  for (const e of completed) {
    if (!byAgent[e.agent_name]) byAgent[e.agent_name] = { durations: [], totalBytes: 0 }
    byAgent[e.agent_name].durations.push(e.duration_seconds)
    byAgent[e.agent_name].totalBytes += (e.output_bytes || 0)
  }

  log("## Run Statistics\n")
  log(`Total completed: ${completed.length} | Total failed: ${failed.length}\n`)
  log("| Agent | Runs | Avg Duration | Min | Max | Total Output |")
  log("|-------|------|-------------|-----|-----|-------------|")

  for (const [agent, data] of Object.entries(byAgent).sort()) {
    const avg = Math.round(data.durations.reduce((a,b) => a+b, 0) / data.durations.length)
    const min = Math.min(...data.durations)
    const max = Math.max(...data.durations)
    const kb = Math.round(data.totalBytes / 1024)
    log(`| ${agent} | ${data.durations.length} | ${avg}s | ${min}s | ${max}s | ${kb}KB |`)
  }

  // Failure breakdown
  if (failed.length > 0) {
    log("\n### Failed/Crashed Agents\n")
    for (const e of failed) {
      log(`- ${e.agent_name}: ${e.status} at ${e.started_at}`)
    }
  }
}
```

### 4. `/rune:runs failures`

List agents that failed or crashed, with their input for retry analysis.

```javascript
if (subcommand === "failures") {
  const metaFiles = Glob("tmp/**/runs/*/meta.json")

  const failures = []
  for (const metaPath of metaFiles) {
    const meta = JSON.parse(Read(metaPath))
    if (meta.status === "failed" || meta.status === "crashed") {
      const runDir = metaPath.replace(/\/meta\.json$/, '')
      failures.push({ ...meta, runDir })
    }
  }

  if (failures.length === 0) {
    log("No failed or crashed agents found across all runs.")
    return
  }

  log(`## Failed/Crashed Agents (${failures.length})\n`)

  for (const f of failures) {
    log(`### ${f.agent_name} (${f.status})`)
    log(`- Workflow: ${f.workflow}`)
    log(`- Team: ${f.team_name}`)
    log(`- Started: ${f.started_at}`)
    log(`- Run dir: ${f.runDir}`)

    // Show input.md snippet if available
    const inputPath = `${f.runDir}/input.md`
    const inputExists = Glob(inputPath).length > 0
    if (inputExists) {
      const inputContent = Read(inputPath)
      log("\nInput (first 500 chars):")
      log("```")
      log(inputContent.substring(0, 500))
      log("```")
    }
    log("")
  }

  log("To retry a failed agent, re-run the workflow or use the input above to manually invoke the agent.")
}
```

## Security

- Agent names validated with `^[a-zA-Z0-9_-]+$` before path construction
- All file access is read-only (no writes)
- Path traversal rejected by the underlying run-artifacts.sh library

## Library Reference

Artifacts are written by `plugins/rune/scripts/lib/run-artifacts.sh`. See that file for the meta.json schema and JSONL index format.
