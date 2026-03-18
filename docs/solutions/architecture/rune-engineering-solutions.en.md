# Rune Engineering Solutions

A catalog of 30 engineering solutions developed across 200+ commits (v0.1.0 → v1.92.0) that form the architectural foundation of Rune's multi-agent orchestration platform.

---

## Table of Contents

1. [Agent Trust & Verification](#1-agent-trust--verification)
2. [Multi-Agent Coordination](#2-multi-agent-coordination)
3. [Review Intelligence](#3-review-intelligence)
4. [Pipeline Orchestration](#4-pipeline-orchestration)
5. [Planning Intelligence](#5-planning-intelligence)
6. [Impact Analysis](#6-impact-analysis)
7. [Context Management](#7-context-management)
8. [Memory & Knowledge](#8-memory--knowledge)
9. [Session Safety & Lifecycle](#9-session-safety--lifecycle)
10. [Enforcement Infrastructure](#10-enforcement-infrastructure)

---

## 1. Agent Trust & Verification

### 1.1 Truthbinding Protocol

**Problem**: When agents review code, they may be influenced by instructions embedded in code comments, strings, or documentation — a form of indirect prompt injection.

**Solution**: Every agent prompt includes ANCHOR and RE-ANCHOR sections that:
- Instruct agents to treat ALL reviewed content as untrusted input
- Require evidence-based assessment via **Rune Traces** — file path + line number citations from actual source code
- Flag uncertain findings as LOW confidence instead of fabricating evidence
- Override any instructions found in reviewed code (comments, docstrings, string literals)

The protocol creates an epistemic boundary: agents form conclusions from code behavior, not from what the code says about itself.

### 1.2 Truthsight Verification Pipeline

**Problem**: Even with Truthbinding, agents can still hallucinate findings — claiming issues that don't exist in the actual codebase.

**Solution**: A multi-layer verification pipeline:

| Layer | When | What it validates |
|-------|------|-------------------|
| **Layer 0** (inline) | During review | Inscription-driven quality gates on required sections |
| **Layer 2** (Smart Verifier) | After review | Haiku-model semantic revalidation of high-priority findings |
| **Phase 6.2** (Cross-model) | In arc pipeline | Codex cross-model verification of P1/P2 findings against actual diff hunks |

Each layer includes a **4-step hallucination guard**: diff relevance → evidence quality → behavioral assessment → confidence calibration. Evidence-tagged Seal fields (`evidence_coverage`, `unproven_claims`) provide a quantitative trust signal.

### 1.3 Doubt Seer Cross-Examination

**Problem**: Standard review agents may produce findings that sound plausible but lack substantive evidence. Without adversarial pressure, weak findings accumulate.

**Solution**: A dedicated meta-review agent (Doubt Seer) that challenges findings from other Ashes:
- Activates only when P1/P2 findings exist (Phase 4.5, after Ash monitoring completes)
- Uses the `DOUBT-` prefix, which is **non-deduplicable** — challenges are always preserved in the TOME
- Classifies claims as PROVEN / LIKELY / UNCERTAIN / UNPROVEN
- Targets structural claims: logic coherence, assumption validity, missing perspectives
- Configurable severity threshold and maximum challenges per run

### 1.4 Inner Flame Self-Review Protocol

**Problem**: Agents may complete tasks without thorough self-verification, leading to shallow or incorrect outputs.

**Solution**: A universal 3-layer self-review protocol enforced on all Rune teammates:

| Layer | Check | Purpose |
|-------|-------|---------|
| **Grounding** | Every claim has file-level evidence | Prevents hallucination |
| **Completeness** | Role-adapted checklists (worker, reviewer, fixer) | Prevents incomplete work |
| **Self-Adversarial** | Reimagine as a critic reviewing your own output | Catches blind spots |

Enforcement: `validate-inner-flame.sh` hook checks for Self-Review Log presence in task outputs. Configurable: `block_on_fail: true` makes it a hard gate; `confidence_floor: 60` sets the minimum post-review confidence threshold.

---

## 2. Multi-Agent Coordination

### 2.1 Inscription Protocol

**Problem**: When multiple agents work in parallel, they need a shared contract defining what each must produce, in what format, and how completion is detected.

**Solution**: A JSON contract file (`inscription.json`) created by the orchestrator before spawning agents:
- **Required sections**: Lists exactly which output sections each Ash must produce (e.g., P1/P2/P3 findings, Reviewer Assumptions, Self-Review Log)
- **Output paths**: Where each Ash writes its output file
- **Verification settings**: Which Truthsight layers to apply
- **Diff scope data**: Line ranges from `git diff` enriched into the inscription so Ashes know which code changed
- **Seal format**: The completion signal format for deterministic detection

The rule is absolute: **no review without inscription**. The inscription is the single source of truth for agent coordination.

### 2.2 Seal Convention

**Problem**: Detecting when an agent has truly finished (vs. partially completed or crashed) requires a reliable signal that works across different output formats.

**Solution**: Agents emit `<seal>TAG</seal>` as the **last line** of their output file. The Seal contains structured metadata:
- Sections completed, findings count, evidence-verified flag
- Confidence score (0-100)
- Audit coverage fields: `skimmed_files`, `deep_read_files`

Detection mechanism: `on-task-completed.sh` writes signal files to `tmp/.rune-signals/{team}/{task_id}.done`. A sentinel file `.all-done` is created when all expected tasks complete. This enables **5-second filesystem polling** instead of 30-second API calls — a 6x speedup in completion detection with near-zero token cost.

### 2.3 Dedup-Runes Hierarchy

**Problem**: When 5-8 agents review the same codebase, they inevitably find overlapping issues. Without deduplication, the TOME would contain redundant findings.

**Solution**: A priority-based deduplication system:
- Each Ash uses a unique 2-5 character **finding prefix** (e.g., SEC, BACK, QUAL)
- A configurable hierarchy defines which prefix wins on conflict: `SEC > BACK > VEIL > DOUBT > DOC > QUAL > FRONT > CDX`
- **5-line proximity window**: If two Ashes report findings within 5 lines of each other in the same file, the higher-priority prefix wins
- The losing Ash's confidence is preserved in an `also_flagged_by` annotation
- Deep audit adds 12 additional prefixes (CORR, FAIL, DSEC, DEBT, etc.)
- **Cross-wave dedup**: In multi-wave reviews, later wave findings SUPERSEDE earlier waves (deeper analysis wins)
- Custom Ash prefixes can be inserted at any position in the hierarchy via `talisman.yml`

### 2.4 Runebinder Aggregation

**Problem**: After parallel Ash agents complete their reviews, findings exist across multiple output files in different formats.

**Solution**: A dedicated utility agent (Runebinder) that:
1. Reads all Ash output files from `tmp/reviews/{id}/ash-outputs/`
2. Applies the dedup hierarchy to eliminate duplicates
3. Produces a unified **TOME** (Table of Merged Evidence) with structured `<!-- RUNE:FINDING -->` markers
4. Organizes findings by severity: P1 (Critical) → P2 (High) → P3 (Medium)
5. Preserves full Rune Traces and evidence for downstream mend + audit traceability
6. For chunked reviews, merges chunk-level TOMEs into a single final TOME

### 2.5 Glyph Budget Protocol

**Problem**: When agents return large outputs (full file contents, extensive findings), they consume the orchestrator's context window, causing degradation for subsequent phases.

**Solution**: A strict output protocol:
- **File-only output**: Agents write to filesystem, return only a ~150-token summary to the orchestrator
- **Pre-summon checklist**: 8-thought planning before spawning agents (do we need this agent? what output format? what context budget?)
- **Post-completion validation**: Inscription-driven quality gates verify output completeness
- Context budget per Ash (`context_budget: 20`) limits the number of files each agent reviews

---

## 3. Review Intelligence

### 3.1 Diff-Scope Engine

**Problem**: Standard review agents analyze entire files, producing findings on code that wasn't changed — noise that wastes mend effort and delays convergence.

**Solution**: Line-level diff intelligence:
1. Generates expanded line ranges from `git diff --unified=0`
2. Enriches `inscription.json` with per-file scope data (changed line ranges + N lines of context)
3. Tags TOME findings as `scope="in-diff"` (changed code) or `scope="pre-existing"` (unchanged code)
4. **Scope-aware mend priority**: P1 always fixed regardless of scope; P2 fixed only for in-diff; P3 skipped for pre-existing
5. **Smart convergence scoring**: Uses scope composition (P3 dominance, pre-existing noise ratio) to detect early convergence

Configuration: `review.diff_scope.expansion: 8` (context lines), `review.diff_scope.tag_pre_existing: true`, `review.diff_scope.fix_pre_existing_p1: true`.

### 3.2 Convergence Loop

**Problem**: A single review-mend pass may not resolve all issues. But unlimited passes waste tokens. The system needs to converge — reviewing only until quality is sufficient.

**Solution**: A 3-tier adaptive convergence loop in arc Phase 7.5:

| Tier | Max cycles | Min cycles | Auto-selected when |
|------|-----------|-----------|-------------------|
| LIGHT | 2 | 1 | Small changes, low-risk PRs |
| STANDARD | 3 | 2 | Normal feature work |
| THOROUGH | 5 | 2 | High-risk, security-critical code |

The `evaluateConvergence()` function uses a composite score:
- 40% minimum cycles gate (has the loop run enough times?)
- 30% P1 finding threshold (zero P1 = eligible)
- 20% P2 finding threshold (configurable, default 0 = any P2 blocks)
- 10% improvement ratio (findings must decrease by configurable ratio)

Each cycle reviews only mend-modified files + their dependencies, progressively narrowing scope.

### 3.3 Chunk Scoring and Orchestration

**Problem**: Large PRs (20+ files, 1000+ lines) overflow a single agent's context window.

**Solution**: Intelligent chunking:
1. `computeChunkScore()` scores each file: Lines (40%) + file importance (30%) + risk hotspots (20%) + cross-cutting potential (10%)
2. Greedy bin packing: files sorted by importance, packed into chunks below a 1000-line-per-Ash threshold
3. Semantic boundary detection: respects function and class definitions
4. Per-chunk inscription validation ensures each chunk agent knows its scope
5. Parallel chunk Runebinders merge findings into the final TOME
6. Optional `cross_cutting_pass: true` runs an additional inter-module consistency check

### 3.4 Enforcement Asymmetry

**Problem**: Not all code changes deserve the same review strictness. A brand-new file warrants different scrutiny than a one-line fix in a well-tested module.

**Solution**: Variable strictness based on change context:
- **Change classification**: NEW_FILE / MAJOR_EDIT (>30% lines changed) / MINOR_EDIT / DELETION
- **Risk classification**: HIGH (core/shared paths, files imported by >N others) / NORMAL
- **Security is always strict** — `security_always_strict: true` cannot be overridden
- Review agents receive context about the change type and risk level, adjusting their finding thresholds accordingly

### 3.5 Stack-Aware Intelligence

**Problem**: A Python project and a TypeScript project have different review concerns, conventions, and anti-patterns. Generic reviewers miss stack-specific issues.

**Solution**: A 4-layer detection and routing system:

| Layer | Function | Implementation |
|-------|----------|----------------|
| **Layer 0** (Context Router) | Decides what knowledge to load | `computeContextManifest()` |
| **Layer 1** (Detection Engine) | Scans manifests with confidence scoring | `detectStack()` — reads package.json, Cargo.toml, pyproject.toml, etc. |
| **Layer 2** (Knowledge Skills) | 20 reference docs per stack | Language, framework, database conventions |
| **Layer 3** (Enforcement Agents) | 11 specialist reviewers | Python, TypeScript, Rust, PHP, FastAPI, Django, Laravel, SQLAlchemy, TDD, DDD, DI |

Specialist reviewers are auto-summoned when stack confidence exceeds the threshold (default 0.6). They join the Roundtable Circle alongside generic Ashes.

---

## 4. Pipeline Orchestration

### 4.1 Arc 26-Phase Pipeline

**Problem**: End-to-end code delivery (from plan to merged PR) involves many sequential steps with dependencies, quality gates, and potential failures at each stage.

**Solution**: A 26-phase orchestration pipeline with modular phase delegation:

```
Phase 1     FORGE              — Research enrichment of plan
Phase 2     PLAN REVIEW        — 3-reviewer circuit breaker
Phase 2.5   REFINEMENT         — Concern extraction, orchestrator-only
Phase 2.7   VERIFICATION       — Deterministic checks, zero LLM
Phase 2.8   SEMANTIC CHECK     — Codex cross-model analysis
Phase 3     DESIGN EXTRACT     — Figma/design context extraction
Phase 4.5   TASK DECOMP        — Task granularity validation
Phase 5     WORK               — Swarm implementation
Phase 5.3   DESIGN VERIFY      — Design implementation verification
Phase 5.5   GAP ANALYSIS       — Plan-to-code compliance (deterministic)
Phase 5.6   CODEX GAP          — Cross-model gap detection
Phase 5.8   GAP FIX            — Auto-remediation team
Phase 5.9   GOLDMASK VERIFY    — Blast-radius verification
Phase 6     CODE REVIEW        — Roundtable Circle (--deep)
Phase 6.5   GOLDMASK CORR      — Investigation findings synthesis
Phase 7     MEND               — Parallel finding resolution
Phase 7.5   VERIFY MEND        — Convergence gate (adaptive)
Phase 7.6   DESIGN ITERATE     — Design refinement loop
Phase 7.7   TEST               — Diff-scoped 3-tier testing
Phase 7.8   TEST CRITIQUE      — Coverage gap analysis
Phase 8.5   PRE-SHIP           — Validation checks
Phase 8.55  RELEASE CHECK      — CHANGELOG + breaking changes
Phase 9     SHIP               — PR creation
Phase 9.1   BOT REVIEW         — Wait for external review bots
Phase 9.2   PR COMMENTS        — Resolve bot findings
Phase 9.5   MERGE              — Rebase + squash merge
```

Each phase summons a fresh team with **per-phase tool restrictions** and **per-phase time budgets** for least-privilege execution.

### 4.2 Checkpoint-Resume System

**Problem**: A 26-phase pipeline running for 30-90 minutes will inevitably encounter interruptions — crashes, token limits, session timeouts.

**Solution**: Persistent checkpointing at `.rune/arc/{id}/checkpoint.json`:
- Saves after each phase completion with **SHA-256 hashes** for artifact integrity
- Schema versioning with auto-migration (v2 → v6 across 4 migration steps)
- `PHASE_ORDER` array defines canonical execution order (non-sequential numbering for backward compatibility)
- Per-phase timing tracking (start time, duration automatically recorded)
- Resume with `--resume` skips completed phases and validates artifact hashes

### 4.3 Stop-Hook Loop Pattern

**Problem**: Batch operations (`arc-batch`, `arc-hierarchy`, `arc-issues`) need to execute multiple arc runs sequentially, but each arc run is a full session. Traditional subprocesses add complexity.

**Solution**: Leveraging Claude Code's `Stop` hook event to create persistent execution loops:
1. State file (`.rune/arc-batch-loop.local.md`) tracks progress: current plan index, completed plans, failed plans
2. When an arc run completes, the `Stop` hook fires, reads state, advances the index, and **re-injects the next arc prompt** via blocking JSON output
3. This creates a loop without subprocess management
4. Session isolation guard ensures each loop belongs to its owner session
5. Cancel commands (`/rune:cancel-arc-batch`) remove the state file, allowing the Stop hook to exit cleanly

This pattern is shared across three batch workflows: arc-batch (multiple plans), arc-hierarchy (parent-child plans), arc-issues (GitHub issue-driven arcs).

### 4.4 Bisection Algorithm for Mend

**Problem**: When mend applies fixes from multiple Ashes and the ward check (lint/test/typecheck) fails, it's unclear which fix introduced the failure.

**Solution**: Binary search over fixer outputs:
1. After all fixers complete, run ward check
2. If ward fails: bisect modified files — split into halves
3. Apply fixes from each half independently, re-run ward check
4. Recursively narrow to the failing fix
5. Report the specific failing fix with file path and Ash attribution
6. Apply only the passing fixes; mark the failing fix as FAILED

Resolution categories: FIXED, FALSE_POSITIVE, FAILED, SKIPPED, CONSISTENCY_FIX.

### 4.5 Phase Order Execution Model

**Problem**: Over 200+ commits, phases were added, removed, and reordered. Sequential numbering (1, 2, 3...) would break checkpoint compatibility on every change.

**Solution**: Non-sequential phase numbering with a canonical `PHASE_ORDER` array:
- Phase IDs are stable identifiers (1, 2, 2.5, 2.7, 5, 5.5, 5.6, 5.8, 5.7, 6, 7, 7.5, 7.7, 9, 9.5, etc.)
- `PHASE_ORDER` array defines actual iteration order (not numeric sort)
- Non-monotonic ordering is intentional: Phase 5.8 (GAP REMEDIATION) executes BEFORE Phase 5.7 (GOLDMASK VERIFICATION) because gap fixes must land before blast-radius analysis
- Reserved phase IDs (3, 4, 8, 8.7) are skipped gracefully in checkpoint migration

---

## 5. Planning Intelligence

### 5.1 Forge Gaze (Topic-Aware Agent Selection)

**Problem**: Plan enrichment requires different specialist agents for different sections (security section needs security experts, performance section needs performance experts). Manual selection doesn't scale.

**Solution**: Deterministic keyword-overlap scoring:
1. Each agent has a topic keyword set (e.g., `[security, auth, owasp, xss, injection]`)
2. Each plan section title is tokenized into keywords
3. Score = keyword overlap count + title bonus (if section title contains agent's primary keyword)
4. Agents scoring above threshold (default 0.30) are selected
5. Caps: `max_per_section: 3`, `max_total_agents: 8`
6. Stack affinity bonus (0.2) for agents matching the detected tech stack

The entire selection is **zero token cost** — purely deterministic string matching. Agents receive only the sections they matched against, not the entire plan.

### 5.2 Solution Arena

**Problem**: Planning agents tend to propose the first reasonable solution without exploring alternatives. This produces local optima.

**Solution**: Competitive evaluation at Phase 1.8 of `/rune:devise`:
1. Generate 2-5 alternative solution approaches
2. Deploy adversarial challenger agents:
   - **Devil's Advocate**: Analyzes failure modes and worst-case scenarios
   - **Innovation Scout**: Proposes novel alternatives the planner didn't consider
3. Score each solution on a 6-dimension weighted matrix:
   - Feasibility (20%), Complexity (15%), Risk (20%), Maintainability (20%), Performance (15%), Innovation (10%)
4. Convergence detection flags tied solutions for user tiebreaking
5. Champion solution feeds into Phase 2 (Synthesize) as the committed approach

Auto-skipped for bug fixes (`skip_for_types: ["fix"]`) and quick mode (`--quick`).

### 5.3 Plan Freshness Gate

**Problem**: Plans written days or weeks ago may reference files, functions, or patterns that no longer exist in the codebase. Executing a stale plan wastes tokens and produces wrong code.

**Solution**: Pre-flight freshness scoring in arc:
1. Plans store `git_sha` in frontmatter (set by `/rune:devise`)
2. Before arc runs, compute drift: `git rev-list --count {plan_sha}..HEAD`
3. Score inversely proportional to commit distance (configurable `max_commit_distance: 100`)
4. Two thresholds: `warn_threshold: 0.7` (advisory) and `block_threshold: 0.4` (blocks arc)
5. Plans without `git_sha` gracefully skip the check
6. Override with `--skip-freshness` when intentional

---

## 6. Impact Analysis

### 6.1 Goldmask Three-Layer Impact Analysis

**Problem**: Before making changes, teams need to understand: what WILL break (dependencies), WHY the code was written this way (intent), and HOW RISKY the area is (churn history).

**Solution**: Three orthogonal analysis layers:

| Layer | Question | Agents | Method |
|-------|----------|--------|--------|
| **Impact** | WHAT changes? | 5 Haiku tracers | Dependency tracing across data, API, business logic, events, and config layers |
| **Wisdom** | WHY was it built this way? | 1 Sonnet agent | Git blame archaeology + intent classification + caution scoring |
| **Lore** | HOW RISKY is this area? | 1 Haiku agent | Quantitative git analysis: churn metrics, co-change clustering, ownership concentration |

Outputs: `GOLDMASK.md` (human-readable report), `findings.json` (machine-parseable), `risk-map.json` (per-file risk scores).

**Universal integration**: Goldmask runs in 6 workflows:
- **Devise**: Predictive mode — risk-score files the plan WILL touch (before any code is written)
- **Forge**: Lore Layer boosts Forge Gaze scores for high-risk files
- **Inspect**: Risk-aware gap prioritization (CRITICAL requirements get dual inspector coverage)
- **Mend**: Risk context injected into fixer prompts + post-mend quick check
- **Arc**: Dedicated phases 5.7 (verification) and 6.5 (correlation)
- **Standalone**: `/rune:goldmask` for ad-hoc impact analysis

### 6.2 Collateral Damage Detection

**Problem**: First-order dependencies are visible, but changes often cascade through 2nd and 3rd-order relationships that aren't obvious.

**Solution**: The Goldmask Coordinator synthesizes findings from all 7-8 tracer agents to detect:
- **2nd-order effects**: Changes to module A affect module B, which in turn affects module C
- **Risk chain amplification**: When a CRITICAL-risk file depends on another CRITICAL-risk file
- **Ownership gaps**: Files with single-author ownership where the author is no longer active
- **Co-change clustering**: Files that historically change together but aren't directly linked

---

## 7. Context Management

### 7.1 Context Weaving (4-Layer System)

**Problem**: Long-running multi-agent sessions accumulate context — prior messages, tool results, agent outputs — until the context window overflows and quality degrades.

**Solution**: Four defensive layers:

| Layer | Trigger | Action |
|-------|---------|--------|
| **Overflow Prevention** | Before spawning agents | Glyph Budget: enforce file-only output, pre-summon planning |
| **Context Rot Prevention** | During execution | Instruction anchoring (re-read contracts after compaction), read ordering |
| **Compression** | Messages exceed threshold | Session summaries compress prior turns |
| **Filesystem Offloading** | Output exceeds inline threshold | Large outputs written to `tmp/` files with summary reference |

Additionally, a **Context Critical Guard** (`guard-context-critical.sh`) blocks TeamCreate and Task at critical context levels (25% remaining), preventing agents from spawning when there isn't enough room.

### 7.2 Compaction Resilience

**Problem**: Claude Code automatically compacts conversations when approaching context limits. During compaction, team state, task lists, and workflow progress can be lost.

**Solution**: Two hooks working together:
1. **`pre-compact-checkpoint.sh`** (PreCompact event): Saves team state to `tmp/.rune-compact-checkpoint.json` — team config, task list snapshot, current workflow phase, arc checkpoint reference
2. **`session-compact-recovery.sh`** (SessionStart:compact event): Re-injects the checkpoint as `additionalContext` after compaction — the orchestrator regains full awareness of team state
3. Correlation guard verifies the team still exists before injection
4. One-time injection: the checkpoint is deleted after use to prevent stale re-injection

---

## 8. Memory & Knowledge

### 8.1 Rune Echoes (5-Tier Agent Memory)

**Problem**: Agents rediscover the same patterns, make the same mistakes, and re-learn the same project conventions across sessions.

**Solution**: Persistent agent memory in `.rune/echoes/{role}/MEMORY.md` with a 5-tier lifecycle:

| Tier | Durability | Pruning | Created by |
|------|-----------|---------|------------|
| **Etched** | Permanent | Never auto-pruned | Human-verified architecture decisions |
| **Notes** | Permanent | Never auto-pruned | User-created via `/rune:echoes remember` |
| **Inscribed** | Long-term | 90 days unreferenced | High-confidence review/audit patterns |
| **Observations** | Medium-term | 60 days (auto-promote after 3 refs) | Session observations from workflows |
| **Traced** | Short-term | 30 days | Temporary session-specific notes |

Multi-factor pruning: importance (40%) x relevance (30%) x recency (30%). Auto-promotion: Observations referenced 3+ times automatically promote to Inscribed.

### 8.2 Echo Search with FTS5

**Problem**: With hundreds of echo entries across roles, finding the relevant one requires more than file scanning.

**Solution**: SQLite FTS5 full-text search exposed via MCP server:
- BM25 ranking as the base relevance signal
- **5-factor composite scoring**: BM25 relevance + importance tier + recency + file proximity + access frequency
- **Dirty-signal auto-reindex**: `annotate-hook.sh` writes a dirty marker when echo files are modified; the server auto-reindexes before the next search
- **Advanced features** (opt-in): semantic group expansion, query decomposition, Haiku reranking, failed-entry retry

### 8.3 Remembrance Channel

**Problem**: Some learnings are so fundamental they should be accessible outside of agent sessions — in human-readable documentation.

**Solution**: ETCHED echoes with high confidence and 2+ session references are promoted to `docs/solutions/` as human-readable knowledge documents. Security-category documents require `verified_by: human` before promotion. YAML frontmatter tracks provenance: source echo, confidence, verification status.

---

## 9. Session Safety & Lifecycle

### 9.1 Session Isolation

**Problem**: Multiple Claude Code sessions working on the same repository must not interfere with each other — reading each other's state files, cancelling each other's workflows, or cleaning up active teams.

**Solution**: Three-field ownership on all state files:
- `config_dir` — resolved `CLAUDE_CONFIG_DIR` (installation isolation)
- `owner_pid` — Claude Code process PID via `$PPID` (session isolation)
- `session_id` — `CLAUDE_SESSION_ID` (diagnostic identifier)

Every hook script that reads state files must:
1. Check `config_dir` matches the current session
2. Check `owner_pid` matches `$PPID` with `kill -0` liveness check
3. Skip silently if state belongs to another live session
4. Clean up if state belongs to a dead session (orphan recovery)

### 9.2 Team Lifecycle Guards

**Problem**: Agent teams can become orphaned (session crashed, user interrupted), blocking future workflows.

**Solution**: A 4-hook guard system:

| Hook | Code | Purpose |
|------|------|---------|
| `enforce-team-lifecycle.sh` | TLC-001 | Validates team names, detects stale teams (30-min threshold), auto-cleans orphans |
| `verify-team-cleanup.sh` | TLC-002 | Verifies team directory removal after TeamDelete, reports zombies |
| `session-team-hygiene.sh` | TLC-003 | Scans for orphaned teams and stale state files at session start/resume |
| `stamp-team-session.sh` | TLC-004 | Writes `.session` marker inside team directory for ownership verification |

### 9.3 Nonce Validation

**Problem**: TOME findings from one review session could be incorrectly consumed by a mend session from a different review, leading to fixes applied to the wrong findings.

**Solution**: Session-scoped nonce embedded in TOME findings:
1. Each review session generates a unique nonce
2. Findings are tagged: `nonce={nonce}` in the `<!-- RUNE:FINDING -->` markers
3. Mend extracts findings only with the matching nonce via regex
4. Cross-session finding contamination is prevented

### 9.4 Post-Completion Advisory

**Problem**: After an arc pipeline completes, the orchestrator might continue using heavy tools (TeamCreate, Task) instead of finishing the session, wasting tokens.

**Solution**: `advise-post-completion.sh` (POST-COMP-001) emits an advisory warning when heavy tools are used after arc completion. Debounced to fire once per session. Fail-open — never blocks, only advises.

---

## 10. Enforcement Infrastructure

### 10.1 Security Enforcement Hooks

**Problem**: Review agents must be read-only (they analyze code, they don't modify it). Mend fixers must only modify their assigned files. Gap fixers must not touch sensitive paths.

**Solution**: A family of PreToolUse hooks:

| Hook | Code | Enforcement |
|------|------|-------------|
| `enforce-readonly.sh` | SEC-001 | Blocks Write/Edit/Bash for review/audit Ashes when `.readonly-active` marker exists |
| `validate-mend-fixer-paths.sh` | SEC-MEND-001 | Blocks mend fixers from writing files outside their assigned file group (inscription lookup) |
| `validate-gap-fixer-paths.sh` | SEC-GAP-001 | Blocks gap fixers from writing to `.claude/`, `.github/`, CI YAML, `.env`, `node_modules/` |

Security-critical hooks exit 2 (blocking) if `jq` is missing. Non-security hooks exit 0 (non-blocking).

### 10.2 Fidelity Enforcement Hooks

**Problem**: Agents can develop anti-patterns that degrade workflow quality — busy-wait polling, using zsh-incompatible shell syntax, spawning agents outside of team context.

**Solution**: Pattern-detection hooks that intercept tool calls:

| Hook | Code | Pattern detected | Action |
|------|------|-----------------|--------|
| `enforce-polling.sh` | POLL-001 | `sleep N && echo check` | Block — must use TaskList for monitoring |
| `enforce-zsh-compat.sh` | ZSH-001 | 5 zsh anti-patterns | Auto-fix: status=, glob NOMATCH, `! [[`, `\!=`, argument globs |
| `enforce-teams.sh` | ATE-1 | Bare `Task` without `team_name` | Block — prevents context explosion from subagent output |

### 10.3 Quality Gate Hooks

**Problem**: Agents may mark tasks as complete prematurely, without producing the required output or performing self-review.

**Solution**: Two TaskCompleted/TeammateIdle hooks:
- **`on-task-completed.sh`**: Writes signal files + runs a **haiku-model quality gate** that validates task completion legitimacy (blocks premature/generic completions)
- **`on-teammate-idle.sh`**: Validates teammate wrote expected output file before going idle; checks for Seal markers on review/audit workflows (hard gate)

---

## Summary Statistics

| Category | Count |
|----------|-------|
| Total unique solutions | 30 |
| Hook scripts | 28 |
| Specialized agents | 90 |
| Skills | 43 |
| Arc pipeline phases | 26 |
| Review convergence tiers | 3 |
| Impact analysis layers | 3 |
| Memory tiers | 5 |
| Stack specialist reviewers | 11 |
| Enforcement hooks | 8 |

These solutions evolved iteratively across 200+ commits, each addressing a real failure mode discovered during production use. The overarching principles: **treat agent output as untrusted**, **enforce quality at every boundary**, **isolate sessions from each other**, **recover from crashes gracefully**, and **minimize token cost through deterministic preprocessing**.
