# Phase 4: Create Tasks + Spawn Agents / Phase 5: Monitor / Phase 6: Graceful Degradation

## Phase 4: Create Tasks + Spawn Agents

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

See [codex-risk-amplification.md](codex-risk-amplification.md) for the full protocol.

**Phase 4 (sequential — after Wisdom + Phase 3.5 complete):**

```
TaskCreate("Coordinator synthesis — merge all layers into GOLDMASK.md")
```

Spawn Coordinator after Wisdom (and optional Risk Amplification) completes:
- Include all layer outputs
- Include `risk-amplification.md` if it exists (Coordinator reads alongside other layers)
- Include reference to `output-format.md` and `confidence-scoring.md`

## Phase 5: Monitor with Polling

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

## Phase 6: Graceful Degradation

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
