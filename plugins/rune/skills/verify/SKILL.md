---
name: verify
description: |
  Verify TOME findings before mend resolution. Classifies each finding as
  TRUE_POSITIVE, FALSE_POSITIVE, or NEEDS_CONTEXT with evidence chains.
  Prevents wasted mend-fixer effort on false positives.

  <example>
  user: "/rune:verify tmp/reviews/abc123/TOME.md"
  assistant: "The Tarnished verifies each finding against the actual code..."
  </example>

  <example>
  user: "/rune:verify"
  assistant: "No TOME specified. Looking for recent TOME files..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[tome-path] [--output-dir <path>] [--timeout <ms>]"
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
  - Grep
  - AskUserQuestion
---

# /rune:verify -- Finding Verification Gate

Parses a TOME file for structured findings, groups them by file, spawns finding-verifier teammates to classify each as TRUE_POSITIVE / FALSE_POSITIVE / NEEDS_CONTEXT, and produces a VERDICTS.md with evidence chains.

**Load skills**: `context-weaving`, `rune-echoes`, `rune-orchestration`, `team-sdk`, `polling-guard`, `zsh-compat`

## Usage

```
/rune:verify tmp/reviews/abc123/TOME.md    # Verify findings from specific TOME
/rune:verify                                # Auto-detect most recent TOME
/rune:verify --output-dir tmp/verify/custom # Specify output directory
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--output-dir <path>` | Custom output directory for verdicts | `tmp/verify/{id}/` |
| `--timeout <ms>` | Outer time budget in milliseconds | `600_000` (10 min) |

## Pipeline Overview

```
Phase 0: PARSE    -> Extract and validate TOME findings
    |
Phase 1: BATCH    -> Group findings by file (max 5 per batch)
    |
Phase 2: VERIFY   -> TeamCreate + spawn finding-verifier per batch
    |
Phase 3: AGGREGATE -> Collect verdicts, compute stats
    |
Phase 4: OUTPUT   -> Write VERDICTS.md + mend-ready filtered list
    |
Phase 5: ECHO     -> Persist FALSE_POSITIVE patterns to Rune Echoes
    |
Phase 6: CLEANUP  -> Shutdown teammates, TeamDelete
```

## Phase 0: PARSE — Extract Findings from TOME

```pseudocode
// 0.1 Resolve TOME path
const args = parseArguments($ARGUMENTS)
let tomePath = args.positional[0]

if (!tomePath) {
  // Auto-detect: search recent TOME files
  const candidates = Glob("tmp/{reviews,arc}/*/TOME.md")
  if (candidates.length === 0) {
    error("No TOME file found. Usage: /rune:verify <tome-path>")
    return
  }
  // Pick most recent by modification time
  tomePath = candidates.sortByMtime().last()
  log(`Auto-detected TOME: ${tomePath}`)
}

// 0.2 Validate TOME exists and is readable
const tome = Read(tomePath)
if (!tome) {
  error(`Cannot read TOME at: ${tomePath}`)
  return
}

// 0.3 Parse structured findings using RUNE:FINDING markers
// Reuse the same parsing approach as mend's parse-tome.md
const findings = []
for (const marker of tome.matchAll(/<!-- RUNE:FINDING.*?-->/gs)) {
  const finding = {
    id: marker.attr("id"),           // e.g., "SEC-003"
    file: marker.attr("file"),       // e.g., "src/api/users.py"
    line: marker.attr("line"),       // e.g., "42"
    severity: marker.attr("severity"), // P1/P2/P3
    ashPrefix: marker.attr("id").split("-")[0], // e.g., "SEC"
    title: extractTitle(marker),     // Finding title text
    body: extractBody(marker),       // Full finding body
    nonce: marker.attr("nonce")      // Nonce for validation
  }
  findings.push(finding)
}

// 0.4 Filter: skip [UNVERIFIED] findings (citation not verified — nothing to verify verdict-wise)
const verifiableFindings = findings.filter(f => !f.title.includes("[UNVERIFIED"))

if (verifiableFindings.length === 0) {
  log("No verifiable findings in TOME. Nothing to verify.")
  return
}

log(`Parsed ${verifiableFindings.length} verifiable findings from ${findings.length} total`)

// 0.5 Generate identifier
const id = generateBase36Id()  // e.g., "k7m2x"
const outputDir = args.flags["--output-dir"] || `tmp/verify/${id}`
Bash(`mkdir -p "${outputDir}"`)

// 0.6 Arc context detection
const isArcContext = tomePath.startsWith("tmp/arc/")
const arcId = isArcContext ? tomePath.match(/arc-(\d+)/)?.[1] : null
// In arc context: skip interactive prompts, use arc team prefix
```

## Phase 1: BATCH — Group Findings by File

```pseudocode
// 1.1 Group findings by target file
const fileGroups = {}
for (const finding of verifiableFindings) {
  const file = finding.file
  if (!fileGroups[file]) fileGroups[file] = []
  fileGroups[file].push(finding)
}

// 1.2 Create batches (max 5 findings per batch)
const batches = []
let currentBatch = { files: [], findings: [] }

for (const [file, fileFindings] of Object.entries(fileGroups)) {
  // Split single-file groups that exceed batch cap
  if (fileFindings.length > 5) {
    if (currentBatch.findings.length > 0) batches.push(currentBatch)
    currentBatch = { files: [], findings: [] }
    for (let i = 0; i < fileFindings.length; i += 5) {
      batches.push({ files: [file], findings: fileFindings.slice(i, i + 5) })
    }
    continue
  }
  if (currentBatch.findings.length + fileFindings.length > 5) {
    if (currentBatch.findings.length > 0) batches.push(currentBatch)
    currentBatch = { files: [], findings: [] }
  }
  currentBatch.files.push(file)
  currentBatch.findings.push(...fileFindings)
}
if (currentBatch.findings.length > 0) batches.push(currentBatch)

// 1.3 Cap concurrent verifiers at 3
const maxConcurrent = Math.min(batches.length, 3)
log(`Created ${batches.length} batches for ${maxConcurrent} concurrent verifiers`)
```

## Phase 2: VERIFY — Spawn Finding-Verifier Team

```pseudocode
// 2.1 Resolve config for session isolation
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
const teamName = isArcContext
  ? `arc-fv-${arcId}`
  : `rune-verify-${id}`
const timeoutMs = parseInt(args.flags["--timeout"] || "600000")

// 2.2 Write state file (session isolation: config_dir, owner_pid, session_id)
const stateFile = `tmp/.rune-verify-${id}.json`
Write(stateFile, JSON.stringify({
  workflow: "verify",
  id,
  tomePath,
  teamName,
  startedAt: new Date().toISOString(),
  config_dir: CHOME,
  owner_pid: Bash("echo $PPID").trim(),
  session_id: "${CLAUDE_SESSION_ID}",
  status: "running",
  findingCount: verifiableFindings.length,
  batchCount: batches.length
}))

// 2.3 Write inscription.json
Write(`${outputDir}/inscription.json`, JSON.stringify({
  session_nonce: id,
  team_name: teamName,
  workflow: "verify",
  created_at: new Date().toISOString(),
  batches: batches.map((b, i) => ({
    id: i,
    files: b.files,
    finding_count: b.findings.length
  }))
}))

// 2.4 Create signal directory
Bash(`mkdir -p "tmp/.rune-signals/${teamName}"`)
Write(`tmp/.rune-signals/${teamName}/.expected`, String(batches.length))

// 2.5 TeamCreate
TeamCreate({ name: teamName })

// 2.6 Create tasks — one per batch (TEAM-002: TaskCreate BEFORE Agent)
for (let i = 0; i < batches.length; i++) {
  const batch = batches[i]
  const findingDetails = batch.findings.map(f =>
    `### ${f.id}: ${f.title}\n` +
    `**File**: ${f.file}:${f.line}\n` +
    `**Severity**: ${f.severity}\n` +
    `**Body**:\n${f.body}\n`
  ).join("\n---\n")

  TaskCreate({
    subject: `Verify batch ${i}: ${batch.files.join(", ")}`,
    description: `Verify ${batch.findings.length} findings in files: ${batch.files.join(", ")}\n\n` +
      `Output your verdicts via SendMessage to team-lead.\n\n` +
      `## Findings to Verify\n\n${findingDetails}`
  })
}

// 2.7 Spawn verifiers — parallel, up to maxConcurrent
// Spawn in a single message for parallel execution
for (let i = 0; i < Math.min(batches.length, maxConcurrent); i++) {
  const batch = batches[i]
  Agent({
    description: `Verify batch ${i}: ${batch.findings.length} findings`,
    subagent_type: "rune:utility:finding-verifier",
    team_name: teamName,
    name: `verifier-${i}`,
    run_in_background: true,
    model: resolveModelForAgent("finding-verifier", talisman),
    prompt: `You are finding-verifier for batch ${i}.
Team: ${teamName}

Your task: verify ${batch.findings.length} findings in files: ${batch.files.join(", ")}.

1. TaskList() to find your assigned task
2. TaskGet() to read the full finding details
3. For each finding, run the 5-step verification protocol
4. Send your verdicts via SendMessage to team-lead
5. TaskUpdate status: "completed"

Output format per finding:
## Finding: {ID}
**Claim**: {restated}
**Verdict**: TRUE_POSITIVE | FALSE_POSITIVE | NEEDS_CONTEXT
**Confidence**: HIGH | MEDIUM | LOW
**Evidence**:
- {file:line} — {proof}
**Reasoning**: {2-3 sentences}
`
  })
}

// 2.8 If more batches than maxConcurrent, spawn remaining as earlier ones complete
// (wave-based — poll for completion then spawn next wave)
if (batches.length > maxConcurrent) {
  // Wait for first wave, then spawn remaining
  waitForCompletion(teamName, maxConcurrent, {
    pollIntervalMs: 30000,
    timeoutMs: timeoutMs * 0.6
  })

  for (let i = maxConcurrent; i < batches.length; i++) {
    const batch = batches[i]
    Agent({
      description: `Verify batch ${i}: ${batch.findings.length} findings`,
      subagent_type: "rune:utility:finding-verifier",
      team_name: teamName,
      name: `verifier-${i}`,
      run_in_background: true,
      model: resolveModelForAgent("finding-verifier", talisman),
      prompt: `You are finding-verifier for batch ${i}. Team: ${teamName}.
Verify ${batch.findings.length} findings. Follow 5-step protocol. Send verdicts via SendMessage.`
    })
  }
}
```

## Phase 3: AGGREGATE — Collect Verdicts

```pseudocode
// 3.1 Wait for all verifiers to complete
waitForCompletion(teamName, batches.length, {
  pollIntervalMs: 30000,
  timeoutMs: timeoutMs * 0.8,
  staleThreshold: 3  // 3 consecutive no-progress polls → warning
})

// 3.2 Collect verdict messages from verifiers
// Verifiers send their verdicts via SendMessage — collect from conversation
// Parse each verdict block from verifier messages
const verdicts = []
for (const message of verifierMessages) {
  // Parse verdict blocks: ## Finding: {ID} ... **Verdict**: {verdict}
  for (const block of message.matchAll(/## Finding: (\S+).*?\*\*Verdict\*\*:\s*(TRUE_POSITIVE|FALSE_POSITIVE|NEEDS_CONTEXT).*?\*\*Confidence\*\*:\s*(HIGH|MEDIUM|LOW)/gs)) {
    verdicts.push({
      findingId: block[1],
      verdict: block[2],
      confidence: block[3],
      fullBlock: block[0],
      evidence: extractEvidence(block[0]),
      reasoning: extractReasoning(block[0])
    })
  }
}

// 3.3 Compute statistics
const stats = {
  total: verdicts.length,
  truePositive: verdicts.filter(v => v.verdict === "TRUE_POSITIVE").length,
  falsePositive: verdicts.filter(v => v.verdict === "FALSE_POSITIVE").length,
  needsContext: verdicts.filter(v => v.verdict === "NEEDS_CONTEXT").length,
  unverified: verifiableFindings.length - verdicts.length  // findings not reached
}
```

## Phase 4: OUTPUT — Write VERDICTS.md

```pseudocode
// 4.1 Build VERDICTS.md
const verdictsContent = `# Finding Verification Verdicts

**TOME**: ${tomePath}
**Date**: ${new Date().toISOString()}
**Identifier**: ${id}

## Summary

| Category | Count |
|----------|-------|
| TRUE_POSITIVE | ${stats.truePositive} |
| FALSE_POSITIVE | ${stats.falsePositive} |
| NEEDS_CONTEXT | ${stats.needsContext} |
| Unverified | ${stats.unverified} |
| **Total** | **${verifiableFindings.length}** |

## Mend-Ready Findings

The following TRUE_POSITIVE findings should be dispatched to mend-fixers:

${verdicts.filter(v => v.verdict === "TRUE_POSITIVE").map(v =>
  `- **${v.findingId}** (${v.confidence} confidence)`
).join("\n")}

## Excluded Findings (False Positives)

The following findings were classified as FALSE_POSITIVE and excluded from mend:

${verdicts.filter(v => v.verdict === "FALSE_POSITIVE").map(v =>
  `- **${v.findingId}**: ${v.reasoning}`
).join("\n")}

## Needs Context

The following findings require additional context for classification:

${verdicts.filter(v => v.verdict === "NEEDS_CONTEXT").map(v =>
  `- **${v.findingId}**: ${v.reasoning}`
).join("\n")}

---

## Detailed Verdicts

${verdicts.map(v => {
  // Include HTML comment marker for mend consumption (machine-parseable)
  const marker = `<!-- VERDICT id="${v.findingId}" verdict="${v.verdict}" confidence="${v.confidenceScore ?? 0.5}" -->`
  return `${marker}\n${v.fullBlock}`
}).join("\n\n---\n\n")}
`

Write(`${outputDir}/VERDICTS.md`, verdictsContent)
log(`Verdicts written to: ${outputDir}/VERDICTS.md`)

// 4.2 Write machine-readable verdicts for mend consumption
const verdictsJson = verdicts.map(v => ({
  findingId: v.findingId,
  verdict: v.verdict,
  confidence: v.confidence,
  reasoning: v.reasoning
}))
Write(`${outputDir}/verdicts.json`, JSON.stringify(verdictsJson, null, 2))
```

## Phase 5: ECHO — Persist FALSE_POSITIVE Patterns

```pseudocode
// 5.1 Persist FP patterns to Rune Echoes for future review suppression
const fpFindings = verdicts.filter(v => v.verdict === "FALSE_POSITIVE")

if (fpFindings.length > 0) {
  const echoLib = `\${RUNE_PLUGIN_ROOT}/scripts/lib/echo-append.sh`

  for (const fp of fpFindings) {
    // 5.2 Dedup check: search existing echoes before writing
    // Use echo-search MCP if available to avoid duplicate FP records
    let isDuplicate = false
    try {
      const existing = mcp__echo-search__echo_search({
        query: `false-positive ${fp.findingId} ${fp.finding?.file || ""}`,
        limit: 3,
        layer: "inscribed",
        role: "verifier"
      })
      // Check if an echo with matching ASH prefix + category already exists
      isDuplicate = existing?.results?.some(r =>
        r.content.includes(fp.findingId.split("-")[0]) &&
        r.tags?.includes("false-positive")
      )
    } catch (e) {
      // MCP unavailable — proceed without dedup (safe to write duplicate)
    }

    if (isDuplicate) {
      log(`Skipping echo for ${fp.findingId} — duplicate FP pattern already exists`)
      continue
    }

    // 5.3 Find the original finding for metadata
    const originalFinding = verifiableFindings.find(f => f.id === fp.findingId)
    let ashPrefix = fp.findingId.split("-")[0]
    let category = originalFinding?.file?.split("/").slice(-2, -1)[0] || "unknown"

    // SEC-001: Sanitize TOME-derived values before shell interpolation
    if (!/^[A-Z]+$/.test(ashPrefix)) ashPrefix = "UNKNOWN"
    if (!/^[a-zA-Z0-9_-]+$/.test(category)) category = "unknown"

    // 5.4 Write echo entry via temp file (safe from shell injection in content)
    const content = [
      `Finding: ${originalFinding?.title || fp.findingId}`,
      `File: ${originalFinding?.file || "unknown"}`,
      `Reason: ${fp.reasoning}`,
      `Pattern: ${ashPrefix} findings in this area are often false positives due to ${fp.reasoning}`
    ].join("\n")

    const contentTmpFile = `${outputDir}/.echo-content-${ashPrefix}-${i}.tmp`
    Write(contentTmpFile, content)
    Bash(`source "${echoLib}" && rune_echo_append \
      --role verifier --layer inscribed \
      --source "rune:verify ${id}" \
      --title "FP Pattern: ${ashPrefix}-${category}" \
      --content "$(head -c 1800 "${contentTmpFile}")" \
      --confidence HIGH \
      --tags "false-positive,${ashPrefix},${category}"`)
    Bash(`rm -f "${contentTmpFile}"`)
  }

  log(`Persisted ${fpFindings.length} FP patterns to echoes`)
}
```

## Phase 6: CLEANUP — Shutdown and TeamDelete

```pseudocode
// 6.1 Standard team cleanup (see team-sdk engines.md shutdown())

// Dynamic member discovery
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: generate from batch count (safe to send shutdown_request to absent members)
  allMembers = Array.from({ length: Math.max(batches.length, 3) }, (_, i) => `verifier-${i}`)
}

// Force-reply + shutdown_request
const aliveMembers = []
for (const member of allMembers) {
  try { SendMessage({ to: member, message: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { /* already exited */ }
}
if (aliveMembers.length > 0) Bash("sleep 2")
let confirmedAlive = 0
for (const member of aliveMembers) {
  try { SendMessage({ to: member, message: { type: "shutdown_request", reason: "Workflow complete" } }); confirmedAlive++ } catch (e) { /* already exited */ }
}

// Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`)
} else {
  Bash("sleep 2")
}

// TeamDelete with retry-with-backoff
let cleanupTeamDeleteSucceeded = false
const CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${CLEANUP_DELAYS[attempt] / 1000}`)
  try { TeamDelete(); cleanupTeamDeleteSucceeded = true; break } catch (e) {
    if (attempt === CLEANUP_DELAYS.length - 1) warn("cleanup: TeamDelete failed after 4 attempts")
  }
}

// Filesystem fallback (QUAL-012: only if TeamDelete never succeeded)
if (!cleanupTeamDeleteSucceeded) {
  const processListOutput = Bash(`ps -o pid,ppid,comm,args -p $(pgrep -P $PPID 2>/dev/null | head -30 | tr '\n' ',') 2>/dev/null || echo "NO_CHILDREN"`)
  // Classify: TEAMMATE (kill) vs MCP_SERVER/CONNECTOR/OTHER (protect)
  // Only kill PIDs classified as TEAMMATE
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort */ }
}

// 6.2 Update state file
const stateUpdate = JSON.parse(Read(stateFile))
stateUpdate.status = "completed"
stateUpdate.completedAt = new Date().toISOString()
stateUpdate.stats = stats
Write(stateFile, JSON.stringify(stateUpdate, null, 2))

// 6.3 Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "verify"`)

// 6.4 Present results
log(`\n## Verification Complete\n`)
log(`TRUE_POSITIVE: ${stats.truePositive} findings confirmed`)
log(`FALSE_POSITIVE: ${stats.falsePositive} findings excluded from mend`)
log(`NEEDS_CONTEXT: ${stats.needsContext} findings need more info`)
log(`\nVerdicts: ${outputDir}/VERDICTS.md`)

// 6.5 In standalone mode, offer next steps
if (!isArcContext) {
  if (stats.truePositive > 0) {
    AskUserQuestion({
      question: `${stats.truePositive} true positive findings confirmed. Run mend to fix them?`,
      options: [`/rune:mend ${tomePath} (with verification filter)`, "Review VERDICTS.md manually", "/rune:rest"]
    })
  }
}
```
