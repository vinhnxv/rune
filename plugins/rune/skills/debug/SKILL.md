---
name: debug
description: |
  ACH-based parallel debugging. Spawns multiple hypothesis-investigator agents to
  investigate competing hypotheses simultaneously. Use when bugs are complex,
  when single-agent debugging hits 3+ failures, or when root cause is unclear.
  Also triggers when test-failure-analyst returns LOW confidence during arc Phase 7.7.
  Keywords: debug, investigate, hypothesis, root cause, parallel debugging, ACH,
  competing hypotheses, falsify, evidence, multi-agent debug.

  <example>
  user: "/rune:debug test suite fails intermittently on auth module"
  assistant: "The Tarnished initiates the ACH Protocol — triaging, generating hypotheses, and summoning investigators..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[bug description or test command]"
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

**Runtime context** (preprocessor snapshot):
- Active workflows: !`find tmp -maxdepth 1 -name '.rune-*-*.json' -exec grep -l '"running"' {} + 2>/dev/null | wc -l | tr -d ' '`
- Current branch: !`git branch --show-current 2>/dev/null || echo "unknown"`

# /rune:debug — ACH-Based Parallel Debugging

Implements Analysis of Competing Hypotheses (ACH) methodology for multi-agent debugging.
Instead of sequential hypothesis testing (systematic-debugging), this spawns parallel
investigators — each assigned ONE hypothesis to confirm or falsify with evidence.

**Load skills**: `systematic-debugging`, `rune-orchestration`, `context-weaving`, `team-sdk`, `zsh-compat`

## When to Use

| Scenario | Use `/rune:debug` | Use `systematic-debugging` |
|----------|-------------------|---------------------------|
| Complex bug, unclear root cause | Yes | No |
| Multiple possible causes | Yes | No |
| Simple deterministic bug | No | Yes |
| Single obvious hypothesis | No | Yes |
| 3+ failures in single-agent debug | Yes (escalation) | No |
| test-failure-analyst LOW confidence | Yes (arc trigger) | No |

## Configuration (talisman.yml)

```yaml
debug:
  max_investigators: 4        # 1-6, default 4
  timeout_ms: 420_000         # 7 min per investigation round
  model: sonnet               # default investigators model; overridden by cost_tier via resolveModelForAgent()
  re_triage_rounds: 1         # max re-triage rounds before escalating to user
  echo_on_verdict: true       # persist verdict to rune-echoes after resolution
```

Read config via `readTalismanSection("misc")` — see [read-talisman.md](../../references/read-talisman.md).

---

## Phase 0: TRIAGE (Lead Agent)

**Goal**: Reproduce, classify, and generate competing hypotheses.

### Step 0.1 — Parse Input

```
bugDescription = $ARGUMENTS
```

If `$ARGUMENTS` is empty, use `AskUserQuestion` to get:
- Bug description or failing test command
- Error output (if available)
- When it last worked (if known)

### Step 0.2 — Reproduce the Bug

Run the failing test or reproduce the error:

```
testOutput = Bash("{test_command}")
```

If reproduction fails:
- Ask user for reproduction steps via `AskUserQuestion`
- If still cannot reproduce: report and exit

Record:
- **First error**: Exact error message at file:line
- **Deterministic**: Run 3x — same result each time?
- **Recent changes**: `git log --oneline -10 -- {affected_files}`

### Step 0.3 — Classify Failure Category

Use trigger heuristics from [ach-methodology.md](references/ach-methodology.md):

1. Check CONCURRENCY first (intermittent failure?)
2. Check REGRESSION (recent commits to affected files?)
3. Check INTEGRATION (cross-module stack trace?)
4. Check ENVIRONMENT (env-specific error messages?)
5. Check DATA/FIXTURE (data-dependent, non-deterministic?)
6. Default: LOGIC ERROR

Record primary category and note any secondary matches.

### Step 0.4 — Generate Hypotheses

Using templates from [hypothesis-templates.md](references/hypothesis-templates.md):

1. Generate 3-5 hypotheses from the primary category
2. Include at least 1 hypothesis from a different category (guard against misclassification)
3. Each hypothesis must be testable and falsifiable
4. Assign hypothesis IDs: `{H-PREFIX}-{NNN}` (e.g., H-REG-001)

**Graceful degradation**: If <2 hypotheses can be generated (bug is too simple or too unclear),
fall back to single-agent `systematic-debugging` methodology. Do NOT spawn a team for 1 hypothesis.

### Step 0.5 — Read Config

```
// readTalismanSection: "misc"
const misc = readTalismanSection("misc")
maxInvestigators = misc?.debug?.max_investigators ?? 4
timeoutMs = misc?.debug?.timeout_ms ?? 420000
investigatorModel = misc?.debug?.model ?? "sonnet"
maxReTriageRounds = misc?.debug?.re_triage_rounds ?? 1
```

Cap hypotheses at `maxInvestigators`.

---

## Phase 1: INVESTIGATE (Parallel Agents)

### Step 1.0 — Workflow Lock (writer)

```bash
CWD="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
source "${CWD}/plugins/rune/scripts/lib/workflow-lock.sh"
conflicts=$(rune_check_conflicts "writer")
if echo "$conflicts" | grep -q "CONFLICT"; then
  AskUserQuestion({ question: "Active workflow conflict:\n${conflicts}\nProceed anyway?" })
fi
rune_acquire_lock "debug" "writer"
```

### Step 1.1 — Create Team

```
teamName = "rune-debug-{timestamp}"
TeamCreate({ team_name: teamName })
```

**Fallback**: If `TeamCreate` fails, fall back to single-agent `systematic-debugging`.

### Step 1.2 — Create Investigation Tasks

For each hypothesis, create a task:

```
TaskCreate({
  subject: "Investigate {hypothesis_id}: {one-line summary}",
  description: `
    ## Assignment

    Investigate this ONE hypothesis. Gather confirming AND falsifying evidence.

    **Hypothesis ID**: {hypothesis_id}
    **Hypothesis**: {full hypothesis statement}
    **Category**: {category}

    ## Bug Context

    **Description**: {bugDescription}
    **Error output**: {testOutput}
    **Affected files**: {file_list}

    ## Evidence Standards

    Classify each evidence item by tier:
    - DIRECT (1.0): Uniquely produces/eliminates failure
    - CORRELATIONAL (0.6): Associated but alternate explanations exist
    - TESTIMONIAL (0.3): Reasoning without direct observation
    - ABSENCE (0.8/0.2): Expected evidence not found (0.8 exhaustive, 0.2 shallow)

    ## Output

    Write evidence report to: tmp/debug/{teamName}/{hypothesis_id}.md
    Use the format from your agent instructions.
  `,
  activeForm: "Investigating {hypothesis_id}"
})
```

### Step 1.3 — MCP-First Investigator Discovery (v1.171.0+)

Before spawning investigators, query agent-search MCP for investigation agents:

```
// MCP-first investigator discovery — enables user-defined investigators
// (e.g., "perf-profiler" for performance-specific debugging)
let investigatorType = "hypothesis-investigator"  // default
try {
  const candidates = agent_search({
    query: "hypothesis investigation debugging root cause analysis evidence",
    phase: "goldmask",
    category: "investigation",
    limit: 5
  })
  Bash("mkdir -p tmp/.rune-signals && touch tmp/.rune-signals/.agent-search-called")

  if (candidates?.results?.length > 0) {
    // User-defined investigator can supplement default for specific debug contexts
    const userInvestigator = candidates.results.find(c =>
      (c.source === "user" || c.source === "project") &&
      c.name !== "hypothesis-investigator"
    )
    if (userInvestigator) investigatorType = userInvestigator.name
  }
} catch (e) {
  // MCP unavailable — use default hypothesis-investigator
}
```

### Summon Investigators

For each hypothesis, spawn an investigator agent (all investigators use `general-purpose` subagent type — agent specialization comes from the prompt, not from the subagent type):

```
Agent({
  subagent_type: "general-purpose",
  team_name: teamName,
  name: "investigator-{N}",
  model: resolveModelForAgent("hypothesis-investigator", talisman),  // Cost tier mapping (../../references/cost-tier-mapping.md)
  prompt: "You are assigned hypothesis {hypothesis_id}. Claim your task from the task list, investigate, and report findings to tmp/debug/{teamName}/{hypothesis_id}.md"
})
```

### Step 1.4 — Monitor Progress

Use polling loop (see `polling-guard` skill):

```
pollIntervalMs = 30000
maxIterations = ceil(timeoutMs / pollIntervalMs)

for iteration in 1..maxIterations:
  TaskList()  // MUST call TaskList every cycle (POLL-001)
  count completed tasks
  if all tasks completed: break
  if stale (no progress for 3 cycles): warn and continue
  Bash("sleep 30")
```

### Step 1.5 — Collect Reports

Read all evidence reports from `tmp/debug/{teamName}/`:

```
for each hypothesis_id:
  report = Read("tmp/debug/{teamName}/{hypothesis_id}.md")
  parse: verdict, confidence, evidence[], cross_signals
```

Handle missing reports (investigator timeout): proceed with available reports, note gap.

---

## Phase 2: ARBITRATE (Lead Agent)

Execute the deterministic arbitration algorithm from [ach-methodology.md](references/ach-methodology.md).

### Step 2.1 — Compute Scores

For each hypothesis with a report:

```
WES(H) = sum(supporting × tier_weight) - sum(refuting × tier_weight)
penalty = 0.4 × count(DIRECT cross-refutations)
FCS(H) = clamp((WES - penalty) × confidence_raw, 0, 1)
```

### Step 2.2 — Rank and Threshold

1. Rank by FCS descending
2. Exclude REFUTED verdicts
3. Check thresholds:
   - All FCS < 0.35: **Re-triage** (go to Step 2.4)
   - FCS gap < 0.1 between top two: **Tiebreaker** (go to Step 2.3)
   - Clear winner: **Accept** (go to Step 2.5)

### Step 2.3 — Tiebreaker

Apply tiebreaker rules in order (see [ach-methodology.md](references/ach-methodology.md)):
1. DIRECT evidence count
2. Absence of DIRECT refutation
3. Echo corroboration
4. Disproof test specificity
5. Compound hypothesis declaration

### Step 2.4 — Re-Triage (if needed)

```
reTriageCount += 1
if reTriageCount > maxReTriageRounds:
  AskUserQuestion("All hypotheses scored below threshold. Here are the findings: {summary}. Can you provide additional context?")
  // Use user input to generate new hypotheses or exit
else:
  // Extract cross-hypothesis signals from all investigators
  // Generate new hypotheses
  // Return to Phase 1 (new investigation round)
```

### Step 2.5 — Emit Verdict

Write verdict to `tmp/debug/{teamName}/verdict.md`:

```markdown
# Debug Verdict — {teamName}

## Primary Hypothesis

**ID**: {winner_id}
**Statement**: {hypothesis}
**Confidence**: {HIGH|MEDIUM|LOW} (FCS: {score})
**Category**: {category}

## Evidence Summary

### Supporting (top 3 by weight)
1. [{evidence_id}] {description} — `{file:line}` (DIRECT, 1.0)
2. ...

### Refuting
- {refuting evidence if any}

## Refuted Alternatives

| Hypothesis | FCS | Reason |
|-----------|-----|--------|
| {H-XXX-NNN} | {score} | {key refuting evidence} |

## Cross-Hypothesis Signals

{signals that emerged during investigation}

## Recommended Fix

{Specific fix approach based on the winning hypothesis}

## Defense-in-Depth Layers

Based on category {category}, apply:
{layers from ach-methodology.md Defense-in-Depth Mapping}
```

---

## Phase 3: FIX (Lead Agent)

### Step 3.1 — Apply Fix

Based on the verdict, implement the fix:
- For REGRESSION: Revert or correct the regressed change
- For LOGIC: Fix the identified logic error
- For ENVIRONMENT: Add environment validation or documentation
- For DATA: Fix data source or add validation
- For INTEGRATION: Fix the boundary contract
- For CONCURRENCY: Add synchronization or fix ordering

### Step 3.2 — Verify Fix

Run the original failing test/reproduction:

```
Bash("{original_test_command}")
```

If fix fails:
- Check if secondary hypothesis might be the actual cause
- If compound bug suspected, address both causes
- If stuck, escalate to user

### Step 3.3 — Defense-in-Depth

Apply defensive layers per the failure category mapping in [ach-methodology.md](references/ach-methodology.md).
Reference [defense-in-depth.md](../systematic-debugging/references/defense-in-depth.md) for layer implementation details.

### Step 3.4 — Echo Persistence

If `talisman?.debug?.echo_on_verdict`:
- Persist the verdict summary to rune-echoes for future debugging reference
- Include: bug description, winning hypothesis, category, fix applied

---

## Phase 4: CLEANUP

Standard 5-component team cleanup (QUAL-012): dynamic member discovery (fallback: `investigator-{1..N}`), shutdown broadcast, grace period, retry-with-backoff TeamDelete (4 attempts), process kill + filesystem fallback gated on `!cleanupTeamDeleteSucceeded`. Releases workflow lock. Then presents final summary (bug, hypothesis, fix, defense layers, rejected alternatives).

See [phase-4-cleanup.md](references/phase-4-cleanup.md) for the full cleanup pseudocode.

---

## Arc Phase 7.7 Integration

When triggered by arc (test-failure-analyst returned LOW confidence):

1. Skip `AskUserQuestion` — use the test output and failure context from arc
2. Write verdict to `tmp/debug/{teamName}/verdict.md` for arc consumption
3. Do NOT apply fix directly — return verdict to arc for mend phase to handle
4. Set exit signal for arc dispatcher: write `tmp/.rune-signals/{arc-team}/debug-complete.signal`

---

## Graceful Degradation

| Condition | Fallback |
|-----------|----------|
| <2 hypotheses generated | Single-agent `systematic-debugging` |
| TeamCreate fails | Single-agent `systematic-debugging` |
| All investigators timeout | Partial arbitration with available reports |
| All hypotheses falsified (after max rounds) | Escalate to user with all evidence collected |
| Fix fails after dominant hypothesis confirmed | Check runner-up hypothesis, then escalate |
