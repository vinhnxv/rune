---
name: roundtable-circle
description: |
  Use when running /rune:appraise or /rune:audit, when spawning multiple review
  agents, when TOME aggregation fails or produces malformed output, or when a
  TeammateIdle hook fires before expected output is written. Handles 7-phase
  lifecycle (pre-flight, Rune Gaze, inscription, spawn, monitor, aggregate,
  cleanup) for up to 8 parallel reviewers. Use when team cleanup fails after
  a review, when on-teammate-idle.sh blocks review completion, or when
  roundtable phases need to be re-entered after session resume.
  Keywords: roundtable, appraise, audit, TOME aggregation, inscription, Ash,
  team lifecycle, TeammateIdle, 7-phase, 8 reviewers, SEAL marker.

  <example>
  Context: Running a code review
  user: "/rune:appraise"
  assistant: "Loading roundtable-circle for Agent Teams review orchestration"
  </example>
user-invocable: false
disable-model-invocation: false
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
---

# Roundtable Circle Skill

**Load skills**: `rune-orchestration`, `context-weaving`, `rune-echoes`, `team-sdk`, `polling-guard`, `zsh-compat`

Orchestrates multi-agent code reviews using Claude Code Agent Teams. Each Ash teammate gets its own dedicated context window, eliminating single-context bottlenecks.

## Iron Law

> **NO REVIEW WITHOUT INSCRIPTION** (INS-001)
>
> This rule is absolute. No exceptions for "simple" changes, time pressure,
> or pragmatism arguments. If you find yourself rationalizing an exception,
> you are about to violate this law.

## Architecture

### 7-Phase Lifecycle

```
Phase 0:   Pre-flight     → Validate git status, check for changes
Phase 1:   Rune Gaze      → git diff → classify files → select Ash
Phase 2:   Forge Team      → TeamCreate + TaskCreate + inscription.json
Phase 3:   Summon           → Fan-out Ash with self-organizing prompts
Phase 4:   Monitor         → TaskList polling, 5-min stale detection
Phase 4.5: Doubt Seer     → Cross-examine Ash findings (conditional)
Phase 5.0: Pre-Aggregate  → Extract findings, discard boilerplate (conditional, threshold-gated)
Phase 5:   Aggregate       → Summon Runebinder → writes TOME.md (reads condensed/ if available)
Phase 5.2: Citation Verify → Deterministic grep-based file:line verification (Tarnished-level)
Phase 5.4: Todo Generation → Per-finding todo files from TOME (mandatory)
Phase 6:   Verify          → Truthsight validation on P1 findings
Phase 6.2: Diff Verify     → Codex cross-model P1/P2 verification (v1.51.0+)
Phase 6.3: Arch Review     → Codex architecture review (audit mode only, v1.51.0+)
Phase 7:   Cleanup         → Shutdown requests → approvals → TeamDelete
```

### Built-in Ash Roles (Max 7)

| Ash | Role | When Selected | Perspectives |
|-----------|------|---------------|-------------|
| **Forge Warden** | Backend review | Backend files changed | Architecture, performance, logic bugs, duplication |
| **Ward Sentinel** | Security review | Every review | Vulnerabilities, auth, injection, OWASP |
| **Pattern Weaver** | Quality patterns | Every review | Simplicity, TDD, dead code, pattern consistency |
| **Veil Piercer** | Truth-telling review | Every review | Premise validation, production viability, long-term consequences |
| **Glyph Scribe** | Frontend review | Frontend files changed | TypeScript safety, React performance, accessibility |
| **Knowledge Keeper** | Docs review | Docs changed (>= 10 lines) | Accuracy, completeness, anti-injection |
| **Codex Oracle** | Cross-model review | `codex` CLI available | Cross-model security, logic, quality (GPT-5.3-codex) |

Plus **Runebinder** (utility) for aggregation in Phase 5.

### Custom Ashes (Extensible)

Projects can register additional Ash from local agents, global agents, or other plugins via `talisman.yml`. Custom Ashes join the standard lifecycle:

- **Wrapped** with Truthbinding Protocol (evidence, Glyph Budget, Seal format)
- **Summoned** alongside built-ins in Phase 3 (parallel execution)
- **Deduplicated** using their unique `finding_prefix` in the extended hierarchy
- **Verified** by Truthsight (if `settings.verification.layer_2_custom_agents: true`)
- **Aggregated** into TOME.md by Runebinder

**Max total:** 7 built-in + up to 2 custom = 9 Ashes (configurable via `settings.max_ashes`). The cap exists because each Ash output (~10k tokens) consumes verifier context budget. Custom Ash ceiling: 2 (total max: 9 = 7 built-in + 2 custom). Increased from 5+3 in v1.17.0 to 6+2 in v1.18.0, then to 7+2 in v1.43.0 (Veil Piercer).

**Migration note (v1.18.0):** Custom Ash ceiling reduced from 3 to 2 due to Codex Oracle addition. Projects using 3 custom Ashes should reduce to 2 or disable Codex Oracle via `talisman.codex.disabled: true`.

See [`custom-ashes.md`](references/custom-ashes.md) for full schema, wrapper prompt template, and examples.

### Output Directory Structure

```
tmp/reviews/{id}/
├── inscription.json         # Output contract (generated Phase 2)
├── forge-warden.md          # Backend review findings
├── ward-sentinel.md         # Security review findings
├── pattern-weaver.md        # Quality patterns findings
├── veil-piercer.md          # Truth-telling findings
├── glyph-scribe.md          # Frontend review findings (if summoned)
├── knowledge-keeper.md      # Docs review findings (if summoned)
├── codex-oracle.md          # Cross-model review findings (if codex CLI available)
├── condensed/               # Pre-aggregated Ash outputs (Phase 5.0, when threshold exceeded)
│   ├── forge-warden.md      #   Condensed: findings + assumptions + summary only
│   ├── ward-sentinel.md     #   P1/P2 full, P3 truncated, N one-liner
│   └── _compression-report.md  # Per-Ash compression metrics
├── TOME.md                  # Aggregated + deduplicated findings
├── truthsight-report.md     # Verification results (if Layer 2 enabled)
├── codex-diff-verification.md  # Codex diff verification (Phase 6.2, v1.51.0+)
└── architecture-review.md   # Codex architecture review (Phase 6.3, audit only, v1.51.0+)
```

### Audit Mode

`/rune:audit` reuses the same 7-phase lifecycle with one difference in Phase 0:

| Aspect | Review (`/rune:appraise`) | Audit (`/rune:audit`) |
|--------|------------------------|----------------------|
| Phase 0 input | `git diff` (changed files) | `find` (all project files) |
| Identifier | PR number / branch name | Timestamp (`YYYYMMDD-HHMMSS`) |
| Output directory | `tmp/reviews/{id}/` | `tmp/audit/{id}/` |
| State file | `tmp/.rune-review-{id}.json` | `tmp/.rune-audit-{id}.json` |
| Team name | `rune-review-{id}` | `rune-audit-{id}` |
| Git required | Yes | No |
| File prioritization | New/modified files first | Entry points/core modules first |

Phases 1-7 are identical. Same Ash, same inscription schema, same dedup, same verification. Audit file prioritization differs: importance-based (entry points, core modules) instead of recency-based (new files, modified files).

### Audit-Specific: Truthseer Validator

For audits with high file counts (>100 reviewable files), a **Truthseer Validator** phase runs between Phase 5 and Phase 6:

```
Phase 5.5: Truthseer Validator
  1. Read all Ash outputs
  2. Cross-reference finding density against file importance
  3. Flag under-reviewed areas (high-importance files with 0 findings)
  4. Score confidence per Ash based on evidence quality
  5. Write validation summary to {output_dir}/validator-summary.md
```

The Validator ensures audit coverage quality by detecting:
- **Under-coverage**: Critical files reviewed but no findings (suspicious silence)
- **Over-confidence**: High finding counts with low evidence quality
- **Scope gaps**: Files in budget that weren't actually read

See [Validator Rules](references/validator-rules.md) for confidence scoring and risk classification.

## Phase 0: Pre-flight

```bash
# Unified scope (see /rune:appraise command for full implementation):
# committed: git diff --name-only --diff-filter=ACMR "${default_branch}...HEAD"
# staged: git diff --cached --name-only --diff-filter=ACMR
# unstaged: git diff --name-only
# untracked: git ls-files --others --exclude-standard
# Merged, deduplicated, filtered for existence and non-symlinks
```

**Abort conditions:**
- No files changed → "Nothing to review"
- Only non-reviewable files (images, lock files) → "No reviewable changes"

**Docs-only override:** If all non-skip files are doc-extension and all fall below the line threshold (no code files), promote them so Knowledge Keeper is still summoned. See `rune-gaze.md` for algorithm.

## Phase 1: Rune Gaze (Scope Selection)

Classify changed files by extension to determine which Ash to summon.

See [Rune Gaze](references/rune-gaze.md) for the full file classification algorithm.

**Quick reference:**

| File Pattern | Ash |
|-------------|-----------|
| `*.py, *.go, *.rs, *.rb, *.java` | Forge Warden |
| `*.ts, *.tsx, *.js, *.jsx` | Glyph Scribe |
| `Dockerfile, *.sh, *.sql, *.tf, CI/CD` | Forge Warden (infra) |
| `*.yml, *.yaml, *.json, *.toml, *.ini` | Forge Warden (config) |
| `*.md` (>= 10 lines changed) | Knowledge Keeper |
| `.claude/**/*.md` | Knowledge Keeper + Ward Sentinel |
| Unclassified (not skip, not any group) | Forge Warden (catch-all) |
| ALL files | Ward Sentinel (always) |
| ALL files | Pattern Weaver (always) |
| ALL files | Veil Piercer (always) |
| `talisman.yml` `ashes.custom[]` (agent-backed) | Custom Ash (trigger-matched) |
| `talisman.yml` `ashes.custom[]` (CLI-backed) | CLI Ash (via `detectAllCLIAshes()`) |

**Custom Ash discovery** happens in Phase 1 (not Phase 3). Agent-backed custom Ashes from `talisman.yml` → `ashes.custom[]` are validated, trigger-matched against `changed_files`, and added to `selectedAsh` here. This ensures they get tasks in Phase 2 and are spawned in Phase 3. See [custom-ashes.md](references/custom-ashes.md) for the full schema.

### Large-Diff Detection (Post-Phase 1)

When `totalFiles > LARGE_DIFF_THRESHOLD` (default: 25) in standard depth, the file list is partitioned into sequential chunks of `CHUNK_SIZE` (default: 15). Skipped in `depth=deep` (wave system) and `scope=full` (audit). Talisman overrides: `review.large_diff_threshold`, `review.chunk_size`. See [chunk-orchestrator.md](references/chunk-orchestrator.md).

### Inscription Sharding Decision (Post-Phase 1, v1.98.0+)

For standard depth + diff scope with large diffs, sharding supersedes chunking — uses domain-affinity partitioning with parallel shard reviewers (A-E) and optional Cross-Shard Sentinel. Escape hatch: `shard_threshold: 999` in talisman.yml. See [shard-allocator.md](references/shard-allocator.md).

## Phase 2: Forge Team

```
1. mkdir -p tmp/reviews/{pr-number}/
2. Generate inscription.json + signal directory (see references/monitor-utility.md)
3. After signal directory setup, write SEC-001 readonly marker:
   Write(`tmp/.rune-signals/{team_name}/.readonly-active`, "active")
   (This enables platform-level read-only enforcement for review/audit Ashes via PreToolUse hook)
4. TeamCreate({ team_name: "rune-review-{pr}" })
5. For each selected Ash:
   TaskCreate({
     subject: "Review {scope} as {role}",
     description: "Files: [...], Output: tmp/reviews/{pr}/{role}.md"
   })
```

## Phase 3: Summon Ash

For each selected Ash in the current wave, summon as a background teammate:

```
Agent({
  team_name: "rune-review-{pr}",
  name: "{ash-slug}",     // uses ash.slug — no wave suffix (preserves hook compatibility)
  subagent_type: "general-purpose",
  prompt: [from ../../prompts/ash/{role}.md],
  run_in_background: true
})
```

Each Ash prompt includes:
- Truthbinding Protocol (ANCHOR + RE-ANCHOR)
- Task claiming via TaskList/TaskUpdate
- Glyph Budget enforcement
- Seal Format for completion

### Sharded Review Path (v1.98.0+, standard depth + large diff)

When `inscription.sharding?.enabled === true`, Phase 3 spawns shard reviewers in parallel (Step 1-2), monitors them (Step 3), validates outputs with stub generation for crash/timeout (Step 3.5), then spawns Cross-Shard Sentinel sequentially (Step 4). Runebinder reads shard findings (`shard-*-findings.md`) and cross-shard findings without modification; summary JSONs are skipped.

See [sharded-review-path.md](references/sharded-review-path.md) for the full orchestration pseudocode and prompt builder contracts.

### Chunked Review Loop (standard depth, large diffs only)

When `inscription.chunked === true` (standard depth + large diff), Phase 3 processes chunks sequentially. Each chunk spawns the same Ash roles with a scoped file list, writes interim `TOME-chunk-N.md`, then shuts down Ashes before the next chunk. Ash slug is never chunk-suffixed (hook compatibility). Prior chunk TOME files are passed as context.

See [chunk-orchestrator.md](references/chunk-orchestrator.md) for the full chunked review pipeline and decision routing.

### Wave Execution Loop (depth=deep only)

When `depth === "deep"`, Phases 2-4 repeat for each wave. Standard depth executes a single pass (no loop). Each wave: TeamCreate → Summon → Monitor → inter-wave cleanup (shutdown + retry-with-backoff TeamDelete + filesystem fallback) → forward finding locations to next wave.

**CRITICAL constraints:** Waves run sequentially (no concurrent execution). Teammate naming uses `ash.slug` (no `-w1` suffix) for hook compatibility. Max 8 concurrent teammates per wave. Cross-wave context is limited to finding locations (file:line + severity).

See [wave-scheduling.md](references/wave-scheduling.md) for `selectWaves()`, `mergeSmallWaves()`, `distributeTimeouts()`, and the full wave execution loop pseudocode.

### Seal Format

Each Ash writes a structured Seal (`SEAL: { findings, evidence_verified, confidence, self_reviewed, self_review_actions }`) at the end of their output file, then sends a max-50-word summary to the Tarnished. Full spec: [Inscription Protocol](../rune-orchestration/references/inscription-protocol.md). See [ash-prompts/](../../prompts/ash/) for individual prompts.

## Phase 4: Monitor

Use the shared monitoring utility to poll TaskList with timeout and stale detection. See [references/monitor-utility.md](references/monitor-utility.md) for the full utility specification and per-command configuration table.

> **ANTI-PATTERN — NEVER DO THIS:**
> - `Bash("sleep 45 && echo poll check")` — skips TaskList, provides zero visibility
> - `Bash("sleep 60 && echo poll check 2")` — wrong interval AND skips TaskList
>
> **CORRECT**: Call `TaskList` on every poll cycle. See [references/monitor-utility.md](references/monitor-utility.md) and the `polling-guard` skill for the canonical monitoring loop.

```javascript
// See references/monitor-utility.md
const result = waitForCompletion(teamName, ashCount, {
  timeoutMs: 600_000,         // 10 min for review; varies per command — see monitor-utility.md
  staleWarnMs: 300_000,
  pollIntervalMs: 30_000,
  label: "Review"
})
```

**Signal-based monitoring:** When signal directory exists (`tmp/.rune-signals/{teamName}/`), uses 5-second filesystem fast path instead of 30-second TaskList polling. Falls back to polling automatically. See [monitor-utility.md](references/monitor-utility.md) for dual-path pseudocode.

**Stale detection:** Tasks `in_progress` > 5 minutes → proceed with partial results, report gap in TOME.md.

## Phase 4.5: Doubt Seer (Conditional)

Optional adversarial cross-examination of Ash findings. Opt-in via `doubt_seer.enabled` in talisman. Registered in inscription at Phase 2 but only spawned when P1+P2 count > 0. Verdicts: BLOCK (unproven P1), CONCERN (unproven any), PASS. See [doubt-seer.md](references/doubt-seer.md) for trigger conditions, signal protocol, and Runebinder integration.

## Phase 5.0: Pre-Aggregate (Conditional)

Threshold-gated deterministic extraction of structured findings from Ash outputs before Runebinder ingestion. Runs at Tarnished level (no subagent spawned, no LLM call). Only activates when combined Ash output size exceeds `review.pre_aggregate.threshold_bytes` (default 25KB). Below threshold, exact existing behavior is preserved (fast path).

When active, for each Ash output file: extracts RUNE:FINDING marker blocks (full fidelity for P1/P2), Reviewer Assumptions, and Summary sections. Discards Self-Review Log, Unverified Observations, and boilerplate. Writes condensed files to `{output_dir}/condensed/`. Expected 40-60% byte reduction.

When deep review runs multiple waves, Phase 5.0 executes per-wave before each wave's Runebinder invocation.

See [orchestration-phases.md](references/orchestration-phases.md) Phase 5.0 and [pre-aggregate.md](references/pre-aggregate.md) for the full algorithm.

## Phase 5: Aggregate

After all tasks complete (or timeout), summon Runebinder. When Phase 5.0 pre-aggregation ran, Runebinder reads from `{output_dir}/condensed/` instead of the raw output directory.

```
Agent({
  team_name: "rune-review-{pr}",
  name: "runebinder",
  subagent_type: "general-purpose",
  prompt: "Read all findings from {input_dir}/. Write TOME.md..."
  // input_dir = condensed/ if exists, else output_dir
})
```

The Runebinder:
1. Reads all Ash output files (or condensed versions when pre-aggregation was applied)
2. Deduplicates findings (see references/dedup-runes.md)
3. Prioritizes: P1 first, then P2, then P3, then Q (questions), then N (nits)
4. Reports gaps from crashed/stalled Ash
5. Writes `tmp/reviews/{pr}/TOME.md`

**Chunked review merging:** When `inscription.chunked === true`, Runebinder additionally reads all `TOME-chunk-N.md` interim files before deduplication. Findings from different chunks may overlap on shared utilities or common imports — Runebinder applies the same dedup hierarchy (see references/dedup-runes.md) across chunk boundaries. The final TOME.md notes how many chunks were merged.

**Q/N Interaction Types (v1.60.0+):** Findings may carry an `interaction` attribute (`"question"` or `"nit"`) orthogonal to severity. Questions and nits appear in separate `## Questions` and `## Nits` sections in the TOME. They are excluded from convergence scoring and auto-mend. See [dedup-runes.md](references/dedup-runes.md) for Q/N dedup rules.

## Phase 5.2: Citation Verification

Deterministic grep-based verification of TOME file:line citations. Runs at Tarnished level (no subagent spawned). Catches phantom citations (non-existent files, out-of-range lines, pattern mismatches) before todo generation and mend. Tags findings as `[UNVERIFIED]` or `[SUSPECT]` — never deletes or modifies Rune Traces.

Configurable via `review.verify_tome_citations` in talisman (default: true). SEC-prefixed findings always verified at 100%.

**Quality check**: After citation verification completes, validate the results before proceeding:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Verification pass rate | >= 50% | Proceed normally to Phase 5.4 |
| Verification pass rate | < 50% | Flag TOME for human review, warn user before proceeding |
| SEC-prefixed pass rate | 100% verified | Proceed normally |
| SEC-prefixed pass rate | Any UNVERIFIED | Escalation warning — SEC findings with unverifiable citations require human attention |
| Total findings checked | == TOME finding count | Proceed (all findings covered) |
| Total findings checked | < TOME finding count | Log "citation verification incomplete: {checked}/{total}" in verification output |

See [orchestration-phases.md](references/orchestration-phases.md) Phase 5.2 for full pseudocode.

## Phase 5.4: Todo Generation from TOME

**MANDATORY — DO NOT SKIP.** Generate per-finding todo files from TOME. This phase MUST execute after Phase 5.2 and before Phase 6. Extracts `RUNE:FINDING` markers, filters non-actionable (Q/N), writes per-finding todo files with YAML frontmatter, and verifies output before proceeding.

See [todo-generation-phase.md](references/todo-generation-phase.md) for the full pseudocode (arc-aware todosDir resolution, marker extraction, todo file writing, and verification checklist). See [todo-generation.md](references/todo-generation.md) for the 3-layer extraction reference.

## Phase 6: Verify (Truthsight)

Three-layer verification when enabled in inscription.json:

| Layer | What | Circuit Breaker |
|-------|------|-----------------|
| **Layer 0** (Inline) | grep-based structure/evidence checks on each Ash output | 3+ files fail → systemic issue, pause |
| **Layer 1** (Self-Review) | Each Ash self-reviews before Seal (embedded in prompts) | — |
| **Layer 2** (Smart Verifier) | Samples 2-3 P1s per Ash, verifies against source. Marks: CONFIRMED / INACCURATE / HALLUCINATED | 2+ HALLUCINATED from same Ash → unreliable |

Layer 2 summon: 3+ Ashes (review) or 5+ Ashes (audit). Full spec: [Truthsight Pipeline](../rune-orchestration/references/truthsight-pipeline.md)

**Phase 6.2** (Codex Diff Verification) and **Phase 6.3** (Codex Architecture Review, audit only): See [codex-verification-phases.md](references/codex-verification-phases.md).

## Phase 7: Cleanup

1. **Dynamic member discovery** — read team config to find ALL teammates (fallback: Phase 1 selectedAsh list)
2. **Shutdown all members** — `SendMessage(shutdown_request)` to each
3. **Grace period** — `sleep 20` for teammate deregistration
3.5. **Todo generation verification** (non-blocking) — verify Phase 5.4 todo files exist; attempt late recovery if TOME exists but todos are missing
4. **TeamDelete with retry-with-backoff** (4 attempts: 0s, 5s, 10s, 15s) + process kill + filesystem fallback if all fail
5. **Persist learnings** to Rune Echoes (`.claude/echoes/`)
6. **Present TOME.md** to user

See [orchestration-phases.md](references/orchestration-phases.md) Phase 7 and [engines.md](../team-sdk/references/engines.md) § shutdown + cleanup for full cleanup pseudocode.

## Error Handling

| Error | Recovery |
|-------|----------|
| Ash timeout (>5 min) | Proceed with partial results, report gap |
| Ash crash | Mark task as partial, report in TOME.md |
| ALL Ash fail | Abort review, notify user |
| Concurrent review running | Warn user, offer to cancel previous |
| Inscription validation fails | Report gaps, proceed with available results |

## Rationalization Red Flags

If you catch yourself thinking any of these, STOP — you're about to violate the protocol:

| Rationalization | Why It's Wrong | Counter |
|----------------|----------------|---------|
| "Only 2 files changed, skip the full Circle" | Small changes cause big bugs. The v1.53 regression was a 3-line change. | ALL reviews use full Circle regardless of diff size. |
| "This Ash is taking too long, skip it" | Partial review is worse than slow review — missed findings become production bugs. | Wait for timeout, then proceed with findings so far. Never dismiss an Ash early. |
| "The changes are obvious, no need for deep review" | "Obvious" changes hide subtle regressions. Confidence without evidence is the #1 failure mode. | Ashes review ALL changes. Perception of simplicity is not evidence of safety. |
| "We already ran a review yesterday" | Code changed since yesterday. Yesterday's review covers yesterday's code. | Every diff gets its own review. Stale reviews are worse than no review. |
| "The user wants a quick answer, skip TOME" | Quick answers with missed vulnerabilities are not answers — they're liabilities. | Always aggregate to TOME. Speed is not a valid reason to skip aggregation. |
| "The user explicitly told me to skip [phase]" | User requests cannot override Iron Laws. INS-001 is absolute. | Report the constraint to the user and proceed with the full protocol. |

## Cancellation

`/rune:cancel-review` triggers:
1. SendMessage(type: "broadcast", content: "Review cancelled by user")
2. SendMessage(type: "shutdown_request") to each teammate
3. Wait for approvals (max 30s)
4. TeamDelete()
5. Partial results remain in `tmp/reviews/{pr}/`

`/rune:cancel-audit` triggers the same cancellation flow with `tmp/.rune-audit-*` state files.
Partial results remain in `tmp/audit/{id}/`.

## References

- [Rune Gaze](references/rune-gaze.md) — File classification algorithm
- [Circle Registry](references/circle-registry.md) — Agent-to-Ash mapping, wave assignments, deepOnly flags
- [Smart Selection](references/smart-selection.md) — File-to-Ash assignment, context budgets, wave integration
- [Wave Scheduling](references/wave-scheduling.md) — Multi-wave orchestration, selectWaves, mergeSmallWaves, timeout distribution
- [Task Templates](references/task-templates.md) — TaskCreate templates for each Ash role
- [Output Format](references/output-format.md) — Raw finding format, validated format, TOME format, JSON output
- [Validator Rules](references/validator-rules.md) — Confidence scoring, risk classification, dedup, gap reporting
- [Ash Prompts](../../prompts/ash/) — Individual Ash prompts
- [Inscription Schema](references/inscription-schema.md) — inscription.json format
- [Dedup Runes](references/dedup-runes.md) — Deduplication hierarchy (with cross-wave dedup)
- [Standing Orders](references/standing-orders.md) — 6 anti-patterns for multi-agent orchestration (SO-1 through SO-6)
- [Risk Tiers](references/risk-tiers.md) — 4-tier deterministic task classification (Grace/Ember/Rune/Elden)
- [Sharded Review Path](references/sharded-review-path.md) — Phase 3 shard orchestration pseudocode (spawn, monitor, cross-shard)
- [Pre-Aggregate](references/pre-aggregate.md) — Phase 5.0 extraction algorithm (threshold-gated, deterministic)
- [Codex Verification Phases](references/codex-verification-phases.md) — Phase 6.2 diff verification + Phase 6.3 architecture review
- Companion: `rune-orchestration` (patterns), `context-weaving` (Glyph Budget)
