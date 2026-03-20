---
name: self-audit
description: |
  Meta-QA self-audit for Rune's own workflow system. Audits agent definitions,
  workflow phases, rules, hooks for inconsistencies, contradictions, and drift.
  Produces SELF-AUDIT-REPORT.md with per-dimension scores and actionable findings.

  Use when: "audit rune itself", "check rune health", "self-audit", "meta-qa",
  "rune consistency check", "lint agents", "validate workflow", "check hooks".

  Covers: Workflow definition validation, agent prompt linting, rule consistency
  checking, hook integrity verification, echo-based recurrence tracking.

  <example>
  user: "/rune:self-audit"
  assistant: "The Tarnished turns the gaze inward, auditing Rune's own system integrity..."
  </example>

  <example>
  user: "/rune:self-audit --dimension workflow"
  assistant: "The Tarnished focuses on workflow definition validation only..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[--dimension D] [--verbose]"
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
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:self-audit — Meta-QA Self-Audit

Orchestrate a multi-agent audit that examines Rune's own workflow definitions, agent prompts, rules, and hooks for inconsistencies, contradictions, and drift. Each audit agent gets its own dedicated context window via Agent Teams.

**Load skills**: `rune-echoes`, `rune-orchestration`, `team-sdk`, `polling-guard`, `zsh-compat`, `context-weaving`

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--dimension <D>` | Focus on a single dimension: workflow, prompt, rule, hook | All 4 dimensions |
| `--verbose` | Include P3 (Info) findings in the report | Off (P1+P2 only) |

## Detection Dimensions

| # | Dimension | Agent | Output |
|---|-----------|-------|--------|
| 1 | Workflow Definition | `workflow-auditor` | `workflow-findings.md` |
| 2 | Prompt/Agent Consistency | `prompt-linter` | `prompt-findings.md` |
| 3 | Rule Consistency | `rule-consistency-auditor` | `rule-findings.md` |
| 4 | Hook Integrity | `hook-integrity-auditor` | `hook-findings.md` |

## Finding Format (All Agents)

```markdown
### SA-{DIM}-{NNN}: {Title}

- **Severity**: P1 (Critical) | P2 (Warning) | P3 (Info)
- **Dimension**: workflow | prompt | rule | hook
- **File**: `{file_path}:{line_number}`
- **Evidence**: {What was found, with exact quotes}
- **Expected**: {What the correct state should be}
- **Proposed Fix**: {Concrete change description}
- **Self-referential**: true | false
```

## Scoring Formula

```
dimension_score = 100 - (P1_count * 15 + P2_count * 5 + P3_count * 1)
clamped to [0, 100]

overall_score = avg(all dimension scores)
```

Verdicts:
- EXCELLENT (90-100): System is well-maintained
- GOOD (70-89): Minor issues, no action required
- NEEDS_ATTENTION (50-69): Several issues, review recommended
- CRITICAL (0-49): Significant issues, action required

---

## Phase 0: Pre-flight

Read talisman config for self_audit section:

```javascript
const talisman = readTalismanSection('misc')
const config = talisman?.self_audit ?? { enabled: true }
if (!config.enabled) { inform("Self-audit disabled via talisman"); return }
```

Parse arguments:

```javascript
const dimension = $ARGUMENTS match --dimension → extract value, else "all"
const verbose = $ARGUMENTS includes "--verbose"
const timestamp = Date.now()
const outputDir = `tmp/self-audit/${timestamp}`
```

Create output directory:

```bash
mkdir -p "${outputDir}"
```

Validate workspace — confirm we are in a Rune plugin directory:

```javascript
const hasPlugin = Glob("plugins/rune/.claude-plugin/plugin.json")
if (!hasPlugin) { error("Not in a Rune plugin workspace"); return }
```

## Phase 1: Team Bootstrap + Agent Spawn

Create team:

```javascript
const teamName = `rune-self-audit-${timestamp}`
TeamCreate({ team_name: teamName })
```

Determine which dimensions to audit:

```javascript
const DIMENSIONS = {
  workflow: { agent: "workflow-auditor", subagent: "rune:investigation:workflow-auditor", output: "workflow-findings.md" },
  prompt:   { agent: "prompt-linter", subagent: "rune:investigation:prompt-linter", output: "prompt-findings.md" },
  rule:     { agent: "rule-consistency-auditor", subagent: "rune:investigation:rule-consistency-auditor", output: "rule-findings.md" },
  hook:     { agent: "hook-integrity-auditor", subagent: "rune:investigation:hook-integrity-auditor", output: "hook-findings.md" }
}

const activeDimensions = dimension === "all"
  ? Object.keys(DIMENSIONS)
  : [dimension]
```

Create tasks and spawn agents (parallel):

```javascript
for (const dim of activeDimensions) {
  const spec = DIMENSIONS[dim]

  TaskCreate({
    subject: `Self-Audit: ${dim} dimension`,
    description: `Run ${spec.agent} audit. Write findings to ${outputDir}/${spec.output}. Use SA-{DIM}-NNN finding format.`
  })

  Agent({
    name: spec.agent,
    team_name: teamName,
    subagent_type: spec.subagent,
    prompt: `You are the ${spec.agent} for Rune Meta-QA self-audit.

TASK CONTEXT:
- output_path: ${outputDir}/${spec.output}
- timestamp: ${timestamp}
- verbose: ${verbose}

Execute ALL checks defined in your agent protocol. Write structured findings to the output path. Include dimension score in summary.

After completion: TaskUpdate(completed), then SendMessage seal to team-lead.`
  })
}
```

## Phase 2: Monitor

Monitor via TaskList polling (30s interval per polling-guard):

```javascript
waitForCompletion(teamName, activeDimensions.length, {
  timeoutMs: 300000,   // 5 minutes
  pollIntervalMs: 30000 // 30 seconds
})
```

Per poll cycle:
1. `TaskList()` — count completed tasks
2. Check for stale agents (no progress in 2 minutes)
3. `Bash("sleep 30")` — wait before next cycle
4. Repeat until all complete or timeout

## Phase 3: Aggregate + Ground

Read all `*-findings.md` files from outputDir:

```javascript
const findingsFiles = Glob(`${outputDir}/*-findings.md`)
```

For each finding with a file:line citation:
1. Verify file exists via `Glob(filePath)`
2. Read the cited line via `Read(filePath, { offset: lineNum - 1, limit: 3 })`
3. Verify evidence quote matches actual content
4. Mark `verified: true | false`
5. Drop findings with `verified: false` (hallucinated)

Calculate per-dimension scores using scoring formula.

Generate SELF-AUDIT-REPORT.md using [aggregation.md](references/aggregation.md) template.

Write report to `${outputDir}/SELF-AUDIT-REPORT.md`.

## Phase 4: Echo Persist

Read talisman config:

```javascript
const config = readTalismanSection('misc')?.self_audit ?? {}
if (config.echo_persist === false) { skip echo persistence }
```

Read existing `.rune/echoes/meta-qa/MEMORY.md` (create role if absent).

For each P1/P2 finding:
1. Search existing echoes for matching finding ID pattern
2. If found: increment `recurrence_count`, update `last_seen` date
3. If new: append as Observations-tier entry with format:

```markdown
### [YYYY-MM-DD] Pattern: {description}
- **layer**: observations
- **source**: rune:self-audit {timestamp}
- **confidence**: 0.7
- **evidence**: `{file}:{line}` — {finding summary}
- **recurrence_count**: 1
- **first_seen**: {date}
- **last_seen**: {date}
- **finding_ids**: [SA-WF-001]
- {The actual pattern in 1-2 sentences}
```

4. If `recurrence_count >= promotion_threshold` (default 3): promote to Inscribed tier

```javascript
const threshold = config.promotion_threshold ?? 3
if (entry.recurrence_count >= threshold && entry.layer === "observations") {
  entry.layer = "inscribed"
  entry.confidence = Math.min(0.95, entry.confidence + 0.1)
}
```

Write updated MEMORY.md.

## Phase 5: Present

Display summary to user:

```
Overall score: {N}/100 ({verdict})
Per-dimension: workflow={N}, prompt={N}, rule={N}, hook={N}
Findings: {P1_count} critical, {P2_count} warnings, {P3_count} info
Grounding: {verified}/{total} findings verified ({pct}%)
Report: {outputDir}/SELF-AUDIT-REPORT.md
Echoes: {N} new, {N} recurrent, {N} promoted
```

Offer next steps via AskUserQuestion:

```javascript
AskUserQuestion({
  question: "What would you like to do next?",
  options: [
    "Review full report",
    "Show critical findings only",
    "Done"
  ]
})
```

- "Review full report" -> Read and display the SELF-AUDIT-REPORT.md
- "Show critical findings only" -> Filter and display P1 findings
- "Done" -> Proceed to cleanup

## Phase 6: Cleanup

Standard 5-component cleanup (per CLAUDE.md team cleanup protocol):

```javascript
// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: all possible teammates
  allMembers = ["workflow-auditor", "prompt-linter", "rule-consistency-auditor", "hook-integrity-auditor"]
}

// 2. shutdown_request to all members
let confirmedAlive = 0
let confirmedDead = 0
for (const member of allMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Self-audit complete" }); confirmedAlive++ }
  catch (e) { confirmedDead++ }
}

// 3. Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`)
} else {
  Bash("sleep 2")
}

// 4. TeamDelete with retry-with-backoff
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break }
  catch (e) { if (attempt === CLEANUP_DELAYS.length - 1) warn("cleanup: TeamDelete failed") }
}

// 5. Filesystem fallback (QUAL-012 gated)
if (!cleanupTeamDeleteSucceeded) {
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
  Bash(`sleep 5`)
  Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}
```
