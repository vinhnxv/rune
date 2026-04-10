---
name: variant-hunt
description: |
  Find similar bugs across the codebase based on a confirmed finding.
  Takes a TOME finding ID or pattern description, extracts the root cause,
  and systematically searches for variants using progressive generalization.
  Use when: "find more like this", "variant analysis", "similar bugs",
  "same pattern elsewhere", "hunt for variants", "variant hunt".
user-invocable: true
disable-model-invocation: false
argument-hint: "<finding-id | pattern-description | TOME-path>"
---

# /rune:variant-hunt — Find Similar Bugs

Systematic variant analysis: given a confirmed finding, search the codebase for
similar patterns that may have the same defect.

**Load skills**: `team-sdk`, `polling-guard`, `zsh-compat`

## Usage

```
/rune:variant-hunt SEC-003                              # Hunt variants of a specific TOME finding
/rune:variant-hunt "missing null check before .access"  # Hunt by pattern description
/rune:variant-hunt tmp/reviews/abc/TOME.md              # Hunt variants for all P1 findings
```

## Workflow

```javascript
const args = "$ARGUMENTS".trim()
const timestamp = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, "")
const outputDir = `tmp/variant-hunt/${timestamp}/`

// Step 1: Parse input — determine what we're hunting for
let findings = []

if (args.endsWith(".md") && args.includes("TOME")) {
  // Input is a TOME path — extract all P1 findings
  const tome = Read(args)
  // Parse RUNE:FINDING markers for P1 findings
  const p1Regex = /<!-- RUNE:FINDING.*?-->([\s\S]*?)<!-- \/RUNE:FINDING -->/g
  let match
  while ((match = p1Regex.exec(tome)) !== null) {
    if (match[1].includes("P1")) {
      findings.push({ source: "tome", content: match[1].trim() })
    }
  }
  if (findings.length === 0) {
    log("No P1 findings in TOME — nothing to hunt variants for.")
    return
  }
} else if (/^[A-Z]+-\d+$/.test(args)) {
  // Input is a finding ID — look up in most recent TOME
  const tomes = Glob("tmp/reviews/*/TOME.md")
  if (tomes.length === 0) {
    error("No TOME found. Run /rune:review first, then hunt variants.")
    return
  }
  const tome = Read(tomes[0])
  const findingRegex = new RegExp(`\\[${args}\\].*?(?=\\n### |\\n## |$)`, "s")
  const findingMatch = tome.match(findingRegex)
  if (!findingMatch) {
    error(`Finding ${args} not found in ${tomes[0]}`)
    return
  }
  findings.push({ source: "finding-id", id: args, content: findingMatch[0] })
} else {
  // Input is a pattern description
  findings.push({ source: "description", content: args })
}

// Step 2: Create output directory and team
Bash(`mkdir -p ${outputDir}`)

const teamName = `rune-variant-${timestamp.slice(0, 8)}`
TeamCreate({ team_name: teamName })

// Step 3: Spawn variant-hunter for each finding (max 3 concurrent)
const maxHunters = Math.min(findings.length, 3)
for (let i = 0; i < maxHunters; i++) {
  const finding = findings[i]
  const outputPath = `${outputDir}variants-${i + 1}.md`

  TaskCreate({
    subject: `Hunt variants for finding ${finding.id ?? (i + 1)}`,
    description: `Source finding:\n${finding.content}\n\nOutput: ${outputPath}`
  })

  Agent({
    prompt: `Hunt for variants of this finding across the codebase.

## Source Finding
${finding.content}

## Output
Write variant report to: ${outputPath}
Team: ${teamName}. Claim your task via TaskList.`,
    subagent_type: "rune:investigation:variant-hunter",
    team_name: teamName,
    name: `variant-hunter-${i + 1}`
  })
}

// Step 4: Monitor
waitForCompletion(teamName, maxHunters, {
  timeoutMs: 300_000,  // 5 min
  pollIntervalMs: 30_000,
  label: "Variant Hunt"
})

// Step 5: Collect and present results
let totalVariants = 0
for (let i = 0; i < maxHunters; i++) {
  const outputPath = `${outputDir}variants-${i + 1}.md`
  try {
    const report = Read(outputPath)
    const variantCount = (report.match(/### VARIANT-/g) || []).length
    totalVariants += variantCount
  } catch (e) {
    log(`Variant report ${i + 1} not available`)
  }
}

// Step 6: Cleanup — 5-component standard pattern (CLAUDE.md Agent Team Cleanup)
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()

// 1. Dynamic member discovery
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // Fallback: hardcoded list of all possible variant hunters
  allMembers = ["variant-hunter-1", "variant-hunter-2", "variant-hunter-3"]
}

// 2. shutdown_request to all members — track delivery failures for adaptive grace
let confirmedAlive = 0
let confirmedDead = 0
const aliveMembers = []

// Step 2a: Force-reply — put all teammates in message-processing state
for (const member of allMembers) {
  try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { confirmedDead++ }
}

// Step 2b: Single shared pause
if (aliveMembers.length > 0) { Bash("sleep 2") }

// Step 2c: Send shutdown_request to alive members
for (const member of aliveMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Variant hunt complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
}

// 3. Adaptive grace period — scale based on confirmed-alive members
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`)
} else {
  Bash("sleep 2")
}

// 4. TeamDelete with retry-with-backoff (4 attempts: 0s, 3s, 6s, 10s = 19s total)
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) log(`cleanup: TeamDelete failed after ${CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!cleanupTeamDeleteSucceeded) {
  // Process-level kill — READ-FIRST, KILL-SECOND (MCP-PROTECT-003)
  const processListOutput = Bash(`ps -o pid,ppid,comm,args -p $(pgrep -P $PPID 2>/dev/null | head -30 | tr '\n' ',') 2>/dev/null || echo "NO_CHILDREN"`)
  // Classify each process: TEAMMATE (kill) vs MCP_SERVER/CONNECTOR/OTHER (protect)
  // TEAMMATE = comm is node|claude|claude-* AND args has NO --stdio/--lsp/mcp-server/connector
  // Only kill PIDs classified as TEAMMATE — NEVER blind for-loop over pgrep output
  // Bash("sleep 5")  // Commented: no kill calls surround this sleep
  // Filesystem cleanup
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// Step 7: Present summary
log(`Variant hunt complete: ${totalVariants} variant(s) found across ${maxHunters} finding(s).`)
log(`Reports: ${outputDir}`)
```

## Talisman Configuration

```yaml
variant_analysis:
  enabled: false             # Opt-in (adds time to review cycle)
  auto_trigger: "p1_only"   # "p1_only" | "p1_p2" | "all"
  max_variants_per_finding: 10
```

## Error Handling

| Error | Recovery |
|-------|----------|
| No TOME found | Stop, suggest `/rune:review` first |
| Finding ID not found | Stop, list available finding IDs |
| Variant hunter timeout | Proceed with partial results |
| No variants found | Report "clean" — pattern is isolated |
