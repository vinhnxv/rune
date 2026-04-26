# Phase 7.9: DEPLOYMENT VERIFICATION — Full Algorithm

Conditional deployment artifact generation via `deployment-verifier` agent. Spawns when diff contains migration, API route, or config/env changes.

**Team**: `arc-deploy-{id}` (single teammate: deployment-verifier)
**Tools**: Read, Glob, Grep (inherited from agent definition)
**Timeout**: 5 min (PHASE_TIMEOUTS.deploy_verify = 300_000)
**Inputs**: id, baseBranch, workBranch (from checkpoint), git diff stat
**Outputs**: `tmp/arc/{id}/deploy-checklist.md`
**Error handling**: Non-blocking. Phase failure → status "skipped" with reason. Team cleanup via ARC_TEAM_PREFIXES "arc-deploy-".
**Consumers**: Phase 8.5 PRE-SHIP VALIDATION (artifact integrity check), Phase 9 SHIP (PR body injection)

> **Note**: `sha256()`, `updateCheckpoint()`, `exists()`, and `warn()` are dispatcher-provided utilities available in the arc orchestrator context. Phase reference files call these without import.

## Activation Gate

Phase 7.9 runs between Phase 7.7 TEST and Phase 8.5 PRE-SHIP VALIDATION. Conditional on both talisman config and diff content.

**Talisman gate**: `readTalismanSection("misc").deployment_verification?.enabled !== false` (default: enabled)

**Diff content gate**: At least one changed file matches deployment-relevant patterns:
- Migration files: `**/migrations/**`, `**/migrate/**`, `*.sql`
- API route changes: `**/routes/**`, `**/controllers/**`, `**/handlers/**`, `**/api/**`
- Config/env changes: `*.env*`, `**/config/**`, `docker-compose*`, `Dockerfile*`, `*.yml` (CI/CD)
- Infrastructure: `**/deploy/**`, `**/infra/**`, `**/terraform/**`, `**/k8s/**`

If neither gate passes, the phase is skipped with zero overhead.

## Algorithm

```javascript
// ═══════════════════════════════════════════════════════
// STEP 0: PRE-FLIGHT GUARDS
// ═══════════════════════════════════════════════════════

if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error(`Phase 7.9: unsafe id value: "${id}"`)

const miscConfig = readTalismanSection("misc") || {}
const deployEnabled = miscConfig.deployment_verification?.enabled !== false

if (!deployEnabled) {
  warn(`Phase 7.9: skipped — deployment_verification.enabled is false in talisman`)
  updateCheckpoint({
    phase: "deploy_verify", status: "skipped",
    phase_sequence: 7.9
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 1: DIFF CONTENT GATE
// ═══════════════════════════════════════════════════════

const workBranch = checkpoint.phases.work?.branch ?? 'HEAD'
const baseBranch = checkpoint.base_branch ?? 'main'
const diffFiles = Bash(`git diff --name-only ${baseBranch}...${workBranch} 2>/dev/null`).trim().split('\n').filter(Boolean)

const DEPLOY_PATTERNS = [
  /migrations?\//i,
  /migrate\//i,
  /\.sql$/i,
  /routes?\//i,
  /controllers?\//i,
  /handlers?\//i,
  /\/api\//i,
  /\.env/i,
  /\/config\//i,
  /docker-compose/i,
  /Dockerfile/i,
  /\/deploy\//i,
  /\/infra\//i,
  /\/terraform\//i,
  /\/k8s\//i
]

const hasDeployRelevantFiles = diffFiles.some(f => DEPLOY_PATTERNS.some(p => p.test(f)))

if (!hasDeployRelevantFiles) {
  warn(`Phase 7.9: skipped — no deployment-relevant files in diff (${diffFiles.length} files checked)`)
  updateCheckpoint({
    phase: "deploy_verify", status: "skipped",
    phase_sequence: 7.9,
    skip_reason: "no deployment-relevant files in diff"
  })
  return
}

// ═══════════════════════════════════════════════════════
// STEP 2: SPAWN DEPLOYMENT-VERIFIER
// ═══════════════════════════════════════════════════════

prePhaseCleanup(checkpoint)

updateCheckpoint({
  phase: "deploy_verify", status: "in_progress",
  phase_sequence: 7.9
})

const teamName = `arc-deploy-${id}`
TeamCreate({ team_name: teamName })
TaskCreate({
  subject: "Generate deployment verification checklist",
  description: "Analyze diff for deployment risks and generate Go/No-Go checklist"
})

const deployRelevantFiles = diffFiles.filter(f => DEPLOY_PATTERNS.some(p => p.test(f)))

Agent({
  name: "deployment-verifier",
  team_name: teamName,
  // deployment-verifier is registry-only — use general-purpose + inject body via agent_detail()
  subagent_type: "general-purpose",
  prompt: `You are deployment-verifier for arc Phase 7.9.

## Assignment
Generate a deployment verification checklist for the current changes.

## Context
- Arc ID: ${id}
- Base branch: ${baseBranch}
- Work branch: ${workBranch}
- Diff spec: ${baseBranch}...${workBranch}
- Deployment-relevant files:
${deployRelevantFiles.map(f => `  - ${f}`).join('\n')}

## Instructions
1. Claim the task via TaskUpdate
2. Read all deployment-relevant files listed above
3. Run \`git diff ${baseBranch}...${workBranch} -- <file>\` for each to see actual changes
4. Generate artifacts following your Deployment Verifier protocol:
   - Go/No-Go Checklist
   - Data Invariants (if migrations present)
   - Pre-Deploy Audit Queries (if database changes)
   - Migration Step Table (if migrations present)
   - Post-Deploy Verification queries
   - Rollback Plan
   - 24-Hour Monitoring Plan
5. Write output to: tmp/arc/${id}/deploy-checklist.md
6. Mark task complete

## Output Path
tmp/arc/${id}/deploy-checklist.md

## Quality Rules
- Every claim must reference specific file:line evidence
- All SQL queries must be read-only (SELECT only)
- Include SCAFFOLD comments on SQL outputs
- If no migration files found, focus on API/config change verification`
})

// ═══════════════════════════════════════════════════════
// STEP 3: MONITOR COMPLETION
// ═══════════════════════════════════════════════════════

// waitForCompletion: pollIntervalMs=30000, timeoutMs=300000
let completed = false
const maxIterations = Math.ceil(300000 / 30000) // 10 iterations
for (let i = 0; i < maxIterations && !completed; i++) {
  const tasks = TaskList()
  // Guard against vacuous truth: tasks.every() returns true on empty array
  completed = tasks.length > 0 && tasks.every(t => t.status === "completed")
  if (!completed) Bash("sleep 30", { run_in_background: true })
}

// Fallback: if teammate timed out, write skip file
if (!exists(`tmp/arc/${id}/deploy-checklist.md`)) {
  Write(`tmp/arc/${id}/deploy-checklist.md`, "# Deployment Verification\n\nSkipped: deployment-verifier teammate timed out.")
}

// ═══════════════════════════════════════════════════════
// STEP 4: CLEANUP — canonical 5-component pattern (CLAUDE.md compliance)
// ═══════════════════════════════════════════════════════
//
// VP-001 FIX: Even though this is a single-member team (deployment-verifier),
// the canonical pattern is applied for consistency and to protect against
// GitHub #31389 (teammates silently dropping shutdown_request after a long
// Bash() turn). Prior flat 12s sleep was replaced with adaptive grace.

// 1. Dynamic member discovery
let allMembers = []
try {
  const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  // SEC-4: filter names before SendMessage
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: single known member for this phase
  allMembers = ["deployment-verifier"]
}

// 2a. Force-reply — put teammates in message-processing state before shutdown_request
let confirmedAlive = 0
let confirmedDead = 0
const aliveMembers = []
for (const member of allMembers) {
  try { SendMessage({ type: "message", recipient: member, content: "Acknowledge: workflow completing" }); aliveMembers.push(member) } catch (e) { confirmedDead++ }
}

// 2b. Shared pause — gated on alive member presence
if (aliveMembers.length > 0) { Bash("sleep 2", { run_in_background: true }) }

// 2c. Send shutdown_request
for (const member of aliveMembers) {
  try { SendMessage({ type: "shutdown_request", recipient: member, content: "Phase complete" }); confirmedAlive++ } catch (e) { confirmedDead++ }
}

// 3. Adaptive grace period
if (confirmedAlive > 0) {
  Bash(`sleep ${Math.min(20, Math.max(5, confirmedAlive * 5))}`, { run_in_background: true })
} else {
  Bash("sleep 2", { run_in_background: true })
}

// 4. Retry-with-backoff TeamDelete (4 attempts: 0s, 3s, 6s, 10s = 19s total)
let deployCleanupSucceeded = false
const DEPLOY_CLEANUP_DELAYS = [0, 3000, 6000, 10000]
for (let attempt = 0; attempt < DEPLOY_CLEANUP_DELAYS.length; attempt++) {
  if (attempt > 0) Bash(`sleep ${DEPLOY_CLEANUP_DELAYS[attempt] / 1000}`, { run_in_background: true })
  try { TeamDelete(); deployCleanupSucceeded = true; break } catch (e) {
    if (attempt === DEPLOY_CLEANUP_DELAYS.length - 1) warn(`cleanup: TeamDelete failed after ${DEPLOY_CLEANUP_DELAYS.length} attempts`)
  }
}

// 5. Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
if (!deployCleanupSucceeded) {
  // MCP-PROTECT-003: Canonical _rune_kill_tree applies full MCP/LSP/connector classification.
  Bash(`source "${RUNE_PLUGIN_ROOT}/scripts/lib/process-tree.sh" && _rune_kill_tree "$PPID" "2stage" "5" "teammates" "${teamName}"`)
  Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
  try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
}

// ═══════════════════════════════════════════════════════
// STEP 5: UPDATE CHECKPOINT
// ═══════════════════════════════════════════════════════

const artifactHash = Bash(`sha256sum "tmp/arc/${id}/deploy-checklist.md" | cut -d' ' -f1`).trim()

updateCheckpoint({
  phase: "deploy_verify",
  status: "completed",
  artifact: `tmp/arc/${id}/deploy-checklist.md`,
  artifact_hash: artifactHash,
  phase_sequence: 7.9,
  team_name: teamName
})
```

## Phase 9 Integration

Phase 9 (SHIP) reads `deploy-checklist.md` to include deployment artifacts in PR body:

```javascript
// In arc-phase-ship.md:
const deployChecklist = exists(`tmp/arc/${id}/deploy-checklist.md`)
  ? Read(`tmp/arc/${id}/deploy-checklist.md`)
  : null

if (deployChecklist && !deployChecklist.includes('timed out')) {
  prBody += `\n\n## Deployment Checklist\n\n${deployChecklist}`
}
```

## Crash Recovery

| Resource | Location |
|----------|----------|
| Deploy checklist | `tmp/arc/{id}/deploy-checklist.md` |
| Checkpoint state | `.rune/arc/{id}/checkpoint.json` (phase: "deploy_verify") |
| Team directory | `$CHOME/teams/arc-deploy-{id}/` |

Recovery: On `--resume`, if deploy_verify is `in_progress`, clean up stale team and re-run from Step 0. The phase is idempotent — re-running overwrites the checklist file.

## Checkpoint Update

```javascript
updateCheckpoint({
  phase: "deploy_verify",
  status: "in_progress",
  phase_sequence: 7.9,
  team_name: `arc-deploy-${id}`
})

// ... run agent + monitor ...

updateCheckpoint({
  phase: "deploy_verify",
  status: "completed",
  artifact: `tmp/arc/${id}/deploy-checklist.md`,
  artifact_hash: sha256(Read(`tmp/arc/${id}/deploy-checklist.md`)),
  phase_sequence: 7.9,
  team_name: `arc-deploy-${id}`
})
```
