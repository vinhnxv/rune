---
name: goldmask
description: |
  Use when assessing blast radius of changes, when understanding WHY code was written a
  certain way, when planning risky modifications, or when a refactor could have hidden
  side effects. Traces WHAT changes, WHY it exists (git archaeology), and HOW RISKY
  the area is (churn + ownership metrics). Keywords: impact analysis, blast radius,
  risk assessment, code archaeology, why was this written.

  <example>
  Context: Running standalone impact analysis
  user: "/rune:goldmask HEAD~3..HEAD"
  assistant: "Loading goldmask for cross-layer impact analysis"
  </example>

  <example>
  Context: Checking blast radius before a refactor
  user: "/rune:goldmask src/auth/ src/payment/"
  assistant: "Loading goldmask for impact + wisdom + lore analysis on specified files"
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[diff-spec or file list]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Agent
  - TeamCreate
  - TeamDelete
  - TaskCreate
  - TaskList
  - TaskGet
  - TaskUpdate
  - SendMessage
---

# Goldmask Skill — Cross-Layer Impact Analysis

**Load skills**: `rune-orchestration`, `context-weaving`, `team-sdk`, `polling-guard`, `zsh-compat`

Three-layer investigation that answers: **WHAT** must change (Impact), **WHY** it was built that way (Wisdom), and **HOW RISKY** the area is (Lore). Includes Collateral Damage Detection (CDD) to predict blast radius.

## ATE-1 ENFORCEMENT

**CRITICAL**: Every `Agent` call in this skill MUST include `team_name`. Bare `Agent` calls without `team_name` cause context explosion and are blocked by the `enforce-teams.sh` hook.

## Architecture — Goldmask's Three Eyes

```
                    +---------------------------------------+
                    |       GOLDMASK COORDINATOR            |
                    |       (Sonnet)                        |
                    |                                       |
                    |  Synthesize all three layers:          |
                    |  1. WHAT must change (Impact)          |
                    |  2. WHY it was built (Wisdom)          |
                    |  3. HOW RISKY is this area (Lore)      |
                    |                                       |
                    |  Produce: GOLDMASK.md + findings.json  |
                    +-------------------+-------------------+
                                        | reads all layer outputs
            +--------------------------++--------------------------+
            |                           |                           |
    +-------v--------+   +-------------v---------+   +-------------v------+
    |  IMPACT LAYER   |   |   WISDOM LAYER         |   |  LORE LAYER        |
    |  5 Tracers      |   |   1 Sage (Sonnet)       |   |  1 Analyst (Haiku) |
    |  (Haiku each)   |   |   - git blame            |   |  - git log          |
    |  - grep/glob    |   |   - commit context       |   |  - risk scoring     |
    |  - dependency   |   |   - intent classify      |   |  - co-change graph  |
    |    tracing      |   |   - caution scoring      |   |  - hotspot detect   |
    +----------------+   +------------------------+   +-------------------+
```

## Modes

| Mode | Trigger | Agents | Output |
|------|---------|--------|--------|
| **Full investigation** | `/rune:goldmask <diff-spec>` | 8 (5+1+1+1) | GOLDMASK.md + findings.json + risk-map.json |
| **Quick check** | `/rune:goldmask --quick <files>` | 0 (deterministic) | Warnings only — compares predicted vs actual |
| **Intelligence** | `/rune:goldmask --lore <diff-spec>` | 1 (Lore only) | risk-map.json for file sorting |

## Phase Sequencing

```
Phase 1: LORE ANALYSIS (parallel with Phase 2)
    |  Lore Analyst --> risk-map.json
    |  (Haiku, ~15-30s)
    |
Phase 2: IMPACT TRACING (parallel with Phase 1, 5 tracers)
    |  Data, API, Business, Event, Config Tracers --> 5 reports
    |  (Haiku x 5, ~30-60s)
    |
    +-- Lore + Impact complete --> Phase 3 starts
    |
Phase 3: WISDOM INVESTIGATION (sequential — needs Impact output)
    |  Wisdom Sage receives:
    |    - All MUST-CHANGE + SHOULD-CHECK findings from Impact
    |    - risk-map.json from Lore (for risk tier context)
    |  Wisdom Sage --> intent classifications + caution scores
    |  (Sonnet, ~60-120s)
    |
Phase 3.5: CODEX RISK AMPLIFICATION (parallel with Phase 3, v1.51.0+)
    |  Codex traces 2nd/3rd-order risk chains
    |  Reads Impact outputs + risk-map.json
    |  --> risk-amplification.md (CDX-RISK prefix)
    |  (codex exec, opt-in, ~600s)
    |
Phase 4: COORDINATION + CDD
    |  Goldmask Coordinator merges all three layers
    |  --> GOLDMASK.md + findings.json
    |  (Sonnet, ~60-90s)
    |
Total estimated time: 3-5 minutes
Total agents: 8 (5 Haiku tracers + 1 Haiku lore-analyst + 1 Sonnet wisdom-sage + 1 Sonnet coordinator)
```

## Orchestration Protocol

### 0. Parse Input

```
$ARGUMENTS = diff-spec (e.g., HEAD~3..HEAD) or file list (e.g., src/auth/ src/payment/)

If --quick flag: skip to Quick Check mode (no agents).
If --lore flag: skip to Intelligence mode (Lore only).
Otherwise: Full investigation.
```

Validate input:
```
// Strip own operational flags before validation
const ownFlags = ['--quick', '--lore']
let cleanArgs = $ARGUMENTS
for (const flag of ownFlags) {
  cleanArgs = cleanArgs.replace(new RegExp(flag + '\\b', 'g'), '').trim()
}

if (!/^[a-zA-Z0-9._\/ ~^:-]+$/.test(cleanArgs))
  → reject with "Invalid input characters"
// SEC-10: Reject git flag injection — no unknown token may start with '-'
const tokens = cleanArgs.split(/\s+/).filter(t => t.length > 0)
if (tokens.some(token => token.startsWith('-')))
  → reject with "Git flag injection detected — arguments must not start with '-'"
// SEC-10: Reject path traversal (per-token check — allows git range operator '..')
if (tokens.some(t => t === '..' || t.includes('/../') || t.startsWith('../') || t.endsWith('/..')))
  → reject with "Path traversal detected — '..' tokens are not allowed"
```

### 1. Resolve Changed Files

```bash
# For diff-spec (MUST quote $ARGUMENTS in all Bash interpolation):
git diff --name-only -- "${diff_spec}"

# For file list:
# Use provided paths directly
```

If no changed files found, report "No changes detected" and exit.

### 2. Generate Session ID + Output Directory

```
session_id = "goldmask-" + Date.now()
// SEC-5: Validate session_id immediately after generation (defense-in-depth)
if (!/^[a-zA-Z0-9_-]+$/.test(session_id)) { error("Invalid session_id"); return }
output_dir = "tmp/goldmask/{session_id}/"

# If invoked from arc:
# SEC-5: Validate arc_id before path construction (same guard as session_id)
if (!/^[a-zA-Z0-9_-]+$/.test(arc_id)) { error("Invalid arc_id"); return }
output_dir = "tmp/arc/{arc_id}/goldmask/"
```

Create output directory and write `inscription.json`:
```json
{
  "session_id": "{session_id}",
  "output_dir": "{output_dir}",
  "changed_files": ["..."],
  "mode": "full|quick|intelligence",
  "layers": {
    "impact": { "expected_files": ["data-layer.md", "api-contract.md", "business-logic.md", "event-message.md", "config-dependency.md"] },
    "wisdom": { "expected_files": ["wisdom-report.md"] },
    "lore":   { "expected_files": ["risk-map.json"] }
  }
}
```

### 2.5. Workflow Lock (reader)

```bash
CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source "${CWD}/plugins/rune/scripts/lib/workflow-lock.sh"
conflicts=$(rune_check_conflicts "reader")
if echo "$conflicts" | grep -q "CONFLICT"; then
  AskUserQuestion({ question: "Active workflow conflict:\n${conflicts}\nProceed anyway?" })
fi
rune_acquire_lock "goldmask" "reader"
```

### 3. Pre-Create Guard + Team Lifecycle

Follow the 3-step pre-create guard from [engines.md](../team-sdk/references/engines.md) § createTeam:

```
Step 0: Try TeamDelete("{session_id}") — may succeed if leftover
Step A: rm -rf target team/task dirs (use CHOME pattern)
Step B: Cross-workflow find scan for stale goldmask-* dirs
Step C: Retry TeamDelete if Step A found dirs
```

Then:
```
TeamCreate("{session_id}")
```

Create state file for session hook discovery (STOP-001, TLC-003):
```javascript
// EC-12, ward-sentinel #3: resolve CLAUDE_SESSION_ID via Bash, not literal string
const sessionId = Bash(`echo "$CLAUDE_SESSION_ID"`).trim()
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash("echo $PPID").trim()
if (!/^[0-9]+$/.test(ownerPid)) { warn("goldmask: invalid PPID — using fallback"); }
Write(`tmp/.rune-goldmask-${session_id}.json`, JSON.stringify({
  status: "active",
  team_name: session_id,  // session_id = "goldmask-{timestamp}" (workflow ID)
  started: new Date().toISOString(),
  config_dir: configDir,
  owner_pid: /^[0-9]+$/.test(ownerPid) ? ownerPid : "0",
  session_id: sessionId
}))
```

### 4. Create Tasks + Spawn Agents

Create 8 tasks (one per agent), then spawn via `Agent` with `team_name`:

**Phase 1+2 (parallel — Lore + 5 Impact tracers):**

```
TaskCreate("Lore analysis — compute risk-map.json from git history")
TaskCreate("Data layer tracing — schema, ORM, migrations")
TaskCreate("API contract tracing — endpoints, request/response shapes")
TaskCreate("Business logic tracing — services, domain rules, validators")
TaskCreate("Event/message tracing — event schemas, pub/sub, DLQ")
TaskCreate("Config/dependency tracing — env vars, config reads, CI/CD")
```

Spawn all 6 in parallel using `Agent` with:
- `team_name: "{session_id}"`
- `subagent_type: "general-purpose"`
- Agent identity via prompt (not agent file reference)
- Include changed files list and output path in prompt
- Include reference to `investigation-protocol.md` for tracers
- Include reference to `lore-protocol.md` for Lore Analyst

**Phase 3 (sequential — after Impact + Lore complete):**

```
TaskCreate("Wisdom investigation — intent classification + caution scoring")
```

Spawn Wisdom Sage after all Phase 1+2 tasks complete:
- Include all MUST-CHANGE and SHOULD-CHECK findings from Impact reports
- Include risk-map.json from Lore
- Include reference to `wisdom-protocol.md`

**Phase 3.5: Codex Risk Amplification (parallel with Phase 3, v1.51.0+):**

Traces 2nd/3rd-order risk chains via Codex (transitive dependencies, runtime config cascades, deployment topology). 4-condition gate: `detectCodex()` + `!codex.disabled` + `risk_amplification.enabled` + `goldmask` in `codex.workflows`. Outputs `risk-amplification.md` with CDX-RISK prefix findings.

See [codex-risk-amplification.md](references/codex-risk-amplification.md) for the full protocol.

**Phase 4 (sequential — after Wisdom + Phase 3.5 complete):**

```
TaskCreate("Coordinator synthesis — merge all layers into GOLDMASK.md")
```

Spawn Coordinator after Wisdom (and optional Risk Amplification) completes:
- Include all layer outputs
- Include `risk-amplification.md` if it exists (Coordinator reads alongside other layers)
- Include reference to `output-format.md` and `confidence-scoring.md`

### 5. Monitor with Polling

Use correct polling pattern (POLL-001 compliant):

```
// readTalismanSection: "goldmask"
const goldmask = readTalismanSection("goldmask")
pollIntervalMs = goldmask?.poll_interval_ms ?? 30000
timeoutMs = goldmask?.timeout_ms ?? 300000  // 5 minutes default
maxIterations = ceil(timeoutMs / pollIntervalMs)

for i in 1..maxIterations:
    TaskList()  # MUST call on every cycle
    count completed tasks
    if all_completed: break
    if stale (no progress for 3 cycles): warn
    Bash("sleep 30")  # NEVER combine with && echo — use bare sleep only (POLL-001)
```

### 6. Graceful Degradation

Each layer is independently valuable:
- **Impact alone** = Goldmask v1 (answers "what must change")
- **Lore alone** = risk sorting (answers "how risky is this area")
- **Wisdom alone** = intent context (answers "why was it built this way")
- **Any combination** = better than any single layer

If a layer fails:
- Impact 1-2 tracers fail: Coordinator uses available data (PARTIAL)
- Impact 3+ tracers fail: Mark Impact as FAILED, Wisdom + Lore still run
- Wisdom timeout (>120s): Skip wisdom annotations, produce Impact + Lore report
- Lore timeout (>60s): Emit partial risk-map, non-blocking
- Lore non-git: Skip entirely, use static fallback

### 7. Cleanup

Standard 5-component team cleanup with 8-member fallback array, SEC-5 session_id validation before rm-rf, state file removal, and workflow lock release.

See [phase7-cleanup.md](references/phase7-cleanup.md) for the full cleanup protocol.

### 8. Report

Read `{output_dir}/GOLDMASK.md` and present summary to user.

## Quick Check Mode (--quick)

No agents spawned. Deterministic checks only:

```
1. Read existing GOLDMASK.md — discovery order: `tmp/goldmask/*/GOLDMASK.md` (most recent), `tmp/arc/*/goldmask/GOLDMASK.md`, or `--report <path>` argument
2. Compare predicted MUST-CHANGE files vs committed files
3. For each missing file: emit WARNING with risk tier + caution level
4. Exit — non-blocking
```

## Intelligence Mode (--lore)

Single agent (Lore Analyst) only:

```
1. Spawn Lore Analyst with file list
2. Wait for risk-map.json
3. Output risk-sorted file list with tier annotations
4. Cleanup
```

## Output Paths

```
tmp/goldmask/{session_id}/
+-- inscription.json
+-- data-layer.md
+-- api-contract.md
+-- business-logic.md
+-- event-message.md
+-- config-dependency.md
+-- risk-map.json
+-- wisdom-report.md
+-- risk-amplification.md  (Codex Phase 3.5, v1.51.0+)
+-- GOLDMASK.md
+-- findings.json
```

## Reference Files

- [trace-patterns.md](references/trace-patterns.md) — Grep/Glob patterns per language per layer
- [confidence-scoring.md](references/confidence-scoring.md) — Noisy-OR formula + caution scoring
- [intent-signals.md](references/intent-signals.md) — Design intent classification patterns
- [output-format.md](references/output-format.md) — GOLDMASK.md + findings.json + risk-map.json schemas
- [investigation-protocol.md](references/investigation-protocol.md) — 5-step protocol for Impact tracers
- [wisdom-protocol.md](references/wisdom-protocol.md) — 6-step protocol for Wisdom Sage
- [lore-protocol.md](references/lore-protocol.md) — Risk scoring formula for Lore Analyst

### Shared Cross-Skill References

These files are consumed by other skills (forge, mend, inspect, devise) via cross-skill links:

- [goldmask-quick-check.md](references/goldmask-quick-check.md) — Quick check protocol (used by forge, mend)
- [lore-layer-integration.md](references/lore-layer-integration.md) — Lore Layer integration patterns (used by forge, inspect, devise, mend)
- [risk-tier-sorting.md](references/risk-tier-sorting.md) — Risk tier sorting utilities (used by forge, mend)
