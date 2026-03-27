---
name: context-weaving
description: |
  Use when spawning 4+ agents, when "Prompt is too long" errors appear, when sessions
  exceed 50 messages, or when context feels degraded. Prevents overflow before agent
  summoning, compresses long sessions, and offloads verbose content to filesystem.
  Keywords: context overflow, prompt too long, glyph budget, compression, long session.

  <example>
  Context: About to launch 4 review agents
  user: "Review this PR with multiple agents"
  assistant: "I'll use context-weaving to enforce Glyph Budgets and plan agent orchestration"
  </example>

  <example>
  Context: Long coding session
  user: "Context is getting long, I'm losing track"
  assistant: "Loading context-weaving for session compression"
  </example>
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Agent
  - Read
  - Write
---

# Context Weaving Skill

Unified context management combining overflow prevention, compression strategies, and filesystem offloading into a single skill. Prevents both context overflow (too many tokens from agent returns) and context rot (attention degradation in long sessions).

## Core Principle

**Control what returns to the Tarnished context, not what agents produce.**

Agents can write unlimited detail to files. The overflow comes from what they _return_ to the caller. This skill ensures returns are minimal (file path + 1-sentence summary).

## Seven Layers of Context Management

| Layer | Problem | Solution | When |
|-------|---------|----------|------|
| **Overflow Prevention** | Agent returns flood lead context | Glyph Budget: file-only output | Before any Rune multi-agent command |
| **Inter-Agent Output Compression** | Ash file outputs too verbose for Runebinder | Phase 5.0 Pre-Aggregate: marker-based extraction | Before aggregation (threshold-gated) |
| **Context Rot** | Attention degrades in long contexts | Instruction anchoring, re-anchoring signals | Always (in prompts) |
| **Compression** | Session grows beyond 50+ messages | Anchored iterative summarization | During long sessions |
| **Filesystem Offloading** | Tool outputs consume 83.9% of context | Write outputs to files, read on demand | During any workflow |
| **Compaction Recovery** | Auto-compaction truncates earlier context | PreCompact checkpoint + SessionStart recovery | During long arc/arc-batch sessions |
| **Runtime Context Monitoring** | Context exhaustion during active workflows | Statusline bridge + PostToolUse warnings | Any session with monitoring enabled |

## Layer 1: Overflow Prevention (Glyph Budget)

### When to Use

| Condition | Action |
|-----------|--------|
| Any Rune multi-agent command | Agent Teams + Glyph Budget + inscription (loaded automatically) |
| Custom multi-agent orchestration (3+ agents) | Agent Teams + Glyph Budget + inscription |

### Pre-Summon Checklist (8 Thoughts)

**BEFORE summoning agents**, complete the 8-step checklist: Count & Estimate → Choose Strategy → Plan Output Dir → Verify Protocol Injection → Post-Completion Validation → Revision Checkpoint → Fallback Strategies → Verification Planning.

See [pre-summon-checklist.md](references/pre-summon-checklist.md) for the full checklist with templates.

### IPC Token Cost Awareness

The Glyph Budget is one half of context overflow prevention — it controls what *returns* to the orchestrator. The other half is **IPC token cost accounting**, which controls what goes *into* agent spawn prompts. Bloated spawn prompts displace reasoning capacity: every token of inlined content (file bodies, plan text, criteria YAML) is a token the agent cannot use for analysis. Apply the Reference Don't Inline principle — pass file paths, not file contents — to keep spawn prompts under 500 tokens. See [spec-continuity.md § 8.7](../discipline/references/spec-continuity.md) for the five IPC principles.

### Glyph Budget Protocol

**Inject this text into EVERY agent prompt** when summoning in a multi-agent workflow:

```
GLYPH BUDGET PROTOCOL:
- Write ALL detailed findings to: {output-directory}/{agent-name}.md
- Return to caller ONLY: the output file path + 1-sentence summary (max 50 words)
- DO NOT include full analysis, code examples, or detailed recommendations in return message

Example return:
"Findings written to {output-directory}/{agent-name}.md. Found 2 P1 issues (SQL injection, missing auth) and 4 P2 issues across 3 files."
```

### Runebinder Pattern (Aggregation)

After all agents complete, summon the Runebinder to process raw files:

| Raw files | Action |
|-----------|--------|
| 1-3 files | Read directly |
| 4+ files | Summon Runebinder agent |
| 10+ files | MUST summon Runebinder (never read all directly) |

After aggregation, read ONLY the TOME.md file. Do NOT also read raw files.

### Quality Probes (Post-Aggregation)

| Probe | Check | If Failed |
|-------|-------|-----------|
| **Circuit Breaker** | ALL output files missing? | Systemic failure — abort |
| **Inscription Validation** | All expected files exist and > 100 bytes? | Report gaps |
| **Agent Count** | Does TOME.md mention all summoned agents? | Read missing agent's raw file |
| **P1 Completeness** | Are P1 findings specific (file path + line)? | Spot-check one raw file |
| **Truthbinding Spot-Check** | Verify Rune Traces in 1-2 P1 findings per agent | Compare against actual source |

### Token Budget Reference

| Component | Tokens | Notes |
|-----------|--------|-------|
| CLAUDE.md + rules + MCP tools | ~30k | Fixed, always present |
| Each agent return (without budget) | 3-5k | The overflow source |
| Each agent return (with budget) | ~100-200 | File path + 50-word summary |
| TOME.md (aggregated) | ~1k | Replaces reading all raw files |
| Context window | Full | Claude's per-session limit |

## Layer 1.5: Inter-Agent Output Compression (Pre-Aggregation)

**Problem**: Ash output files are verbose — 15-25% is non-finding overhead (Self-Review Log,
Unverified Observations, boilerplate). When 5-8 Ashes produce 100-270 lines each,
combined size exceeds 30KB, causing Runebinder stalling.

**Solution**: Phase 5.0 (Pre-Aggregate) extracts structured findings from Ash outputs
before Runebinder ingestion. Deterministic marker-based extraction — no LLM call.

**Trigger**: Combined Ash output size >= `review.pre_aggregate.threshold_bytes` (default 25KB)

**Mechanism**:
1. Measure combined Ash output file size
2. If under threshold → skip (fast path, exact existing behavior)
3. If over threshold → for each Ash file:
   - Extract RUNE:FINDING marker blocks (full fidelity for P1/P2)
   - Extract ## Reviewer Assumptions and ## Summary
   - Apply priority-based trace truncation (P3: truncate to 3 lines; N: 1-line summary)
   - Discard: Self-Review Log, Unverified Observations, methodology prose
4. Write condensed files to `{output_dir}/condensed/`
5. Runebinder reads from condensed/ instead of raw output directory

**Expected reduction**: 40-60% byte savings (non-finding sections + trace truncation)

**Config**:
```yaml
review:
  pre_aggregate:
    enabled: true               # Master toggle (default: true)
    threshold_bytes: 25000      # Auto-trigger threshold (default: 25KB)
    preserve_priorities: [P1, P2]  # Full preservation priorities
    truncate_trace_lines: 3     # Max Rune Trace lines for P3
    nit_summary_only: true      # 1-line summaries for N findings
```

See [roundtable-circle/references/pre-aggregate.md](../roundtable-circle/references/pre-aggregate.md) for the extraction algorithm.

## Layer 2: Context Rot Prevention

### The Problem

Context rot occurs when the model's attention degrades on important instructions placed in the middle of long contexts (Lost-in-Middle effect). This is different from overflow — it happens even within token limits.

### Prevention Strategies

**Instruction Anchoring:** Duplicate critical rules at BEGINNING and END of prompts.

```markdown
# ANCHOR — TRUTHBINDING PROTOCOL
[critical rules here]

## TASK
[main instructions]

# RE-ANCHOR — TRUTHBINDING REMINDER
[repeat critical rules]
```

**Read Ordering:** Source files FIRST, agent references LAST. Keeps review criteria fresh near output generation.

**Re-anchoring Signals:** After every 5 files reviewed, re-check evidence rules.

**Context Budget per Teammate:**
- Backend review: max 30 source files
- Security review: max 20 files (all types)
- Frontend review: max 25 source files
- Docs review: max 25 markdown files

## Layer 3: Compression

### When to Use

| Message Count | Action |
|---------------|--------|
| < 30 | No compression needed |
| 30-49 | Optional — available if needed |
| 50-69 | Trigger compression |
| >= 70 | Force compression |

### Compression Strategy: Anchored Iterative Summarization

Identify truncation point → Extract key info (files, tests, decisions, errors) → Merge into existing summary → Write to `tmp/scratch/session-{timestamp}.md` → Continue. See [context-compression.md](references/context-compression.md) for session summary format and quality verification dimensions.

## Layer 4: Filesystem Offloading

### Core Principle

Tool outputs consume up to 83.9% of context. Offload large outputs to files.

### When to Offload

| Output Size | Action |
|------------|--------|
| < 10 lines | Keep inline |
| 10-50 lines | Consider offloading |
| > 50 lines | MUST offload to file |

### Offload Pattern

```
1. Write output to tmp/{workflow}/{descriptive-name}.md
2. Reference: "Output written to {path}. Key finding: {1-sentence summary}"
3. Read file only when needed for next step
```

## Layer 5: Compaction Recovery

### The Problem

Claude's auto-compaction fires during long sessions (especially `/rune:arc` with 43 phases), truncating earlier context. This can cause the Tarnished to lose awareness of active teams, task state, workflow phase, and arc checkpoint — leading to orphaned teams, duplicated work, or pipeline restarts.

### How It Works

Two hooks form a checkpoint/recovery pair:

1. **PreCompact** (`scripts/pre-compact-checkpoint.sh`) — Fires before compaction (manual or auto). Captures a snapshot of:
   - Team config.json (active team name, members, creation time)
   - Task list state (pending/in_progress/completed counts)
   - Current workflow phase (from arc checkpoint if available)
   - Arc checkpoint path and metadata
   - Arc-batch state: current iteration, total plans, latest summary path (v1.72.0)
   - Writes to `tmp/.rune-compact-checkpoint.json`

2. **SessionStart:compact** (`scripts/session-compact-recovery.sh`) — Fires when session resumes after compaction. Re-injects the saved checkpoint as `additionalContext` so the Tarnished can resume seamlessly. Includes a correlation guard that verifies the team still exists before injection. One-time use — deletes the checkpoint file after injection to prevent stale state.

### Three Ground Truth Sources

After compaction recovery, the Tarnished reconciles three sources:

| Source | Contains | Priority |
|--------|----------|----------|
| Team config.json | Team name, members, creation time | Authoritative for team existence |
| Task list | Task status, assignments, dependencies | Authoritative for work state |
| Arc checkpoint | Phase, artifacts, SHA-256 hashes | Authoritative for pipeline progress |

### Layer 5.1: Arc-Batch Inter-Iteration Summaries (v1.72.0)

When arc-batch is active, the Stop hook writes structured summary files between iterations to `tmp/arc-batch/summaries/iteration-{N}.md`. These summaries are captured in the pre-compact checkpoint (`arc_batch_state` field) and referenced in compact recovery context. Summary files are on disk (not in context), so they survive compaction and are available for `Read()` after recovery.

The compact recovery message includes batch iteration number, total plans, and the path to the latest summary file — giving the Tarnished immediate awareness of batch progress after compaction.

**Edge case**: During arc-batch, teams are created and destroyed per phase. Compaction may hit between phases when no team is active. The pre-compact hook captures batch state even without an active team, writing a minimal checkpoint. The recovery hook handles teamless checkpoints by injecting batch context directly without the team correlation guard.

### Relationship to Rule #5

This layer automates what Rule #5 ("On compaction or session resume: re-read team config, task list, and inscription contract") previously required manually. The PreCompact hook captures state proactively, and the SessionStart:compact hook re-injects it — ensuring Rule #5 compliance even when compaction truncates the original context.

## Layer 6: Runtime Context Monitoring (v1.78.0)

### The Problem

Even with overflow prevention and compression, a session can creep toward context exhaustion during long workflows without visible feedback. By the time the model notices degraded output quality, significant context has already been lost.

### Components

- **Statusline Bridge** — A statusline script that writes context metrics (percentage used, token counts) to a shared bridge file at `/tmp/rune-ctx-{session_id}.json`. Runs as a color-coded statusline with git branch and active workflow detection. The bridge file is the producer half of a producer/consumer pattern.
- **Context Monitor** — A `PostToolUse` hook (`scripts/rune-context-monitor.sh`) that reads the bridge file and injects agent-visible warnings when context usage crosses thresholds. Non-blocking (exits 0). Only injects when the bridge file is fresh (staleness guard: 5 minutes). The monitor is the consumer half of the pattern.
- **Plan Budget** — An optional `session_budget` frontmatter field in plan files that caps simultaneous agent spawning (`max_concurrent_agents`). Validated silently by `strive`/`arc` worker orchestration to prevent context saturation from large teams.

### Setup

Enable in `.rune/talisman.yml`:

```yaml
context_monitor:
  enabled: true                    # Master toggle for context monitoring
  warning_threshold: 35            # Warn when remaining% <= this (default: 35)
  critical_threshold: 25           # Critical stop when remaining% <= this (default: 25)
  stale_seconds: 60                # Bridge file max age before ignoring (default: 60)
  debounce_calls: 5                # Tool uses between repeated warnings (default: 5)
  workflows: [review, audit, work, mend, arc, devise]  # Which workflows emit warnings
```

### Thresholds

| Level | Context Remaining | Injected Message |
|-------|------------------|-----------------|
| WARNING | ≤ 35% | "Context at {pct}% remaining. Consider compacting or reducing agent scope." |
| CRITICAL | ≤ 25% | "Context CRITICAL at {pct}% remaining. Compact now or risk truncation." |

### Architecture Notes

- **Producer/Consumer pattern**: statusline writes, monitor reads via `/tmp/` bridge file. No shared memory — pure filesystem.
- **Session-isolated**: bridge files are keyed by `session_id` with `config_dir` + `owner_pid` ownership fields.
- **Non-blocking**: all errors exit 0 — the monitor never blocks tool execution.
- **Bridge file cleanup**: `on-session-stop.sh` scans `/tmp/rune-ctx-*.json` and removes files matching the current session's ownership markers.

## Layer 6.1: Glyph Budget Hook Enforcement (v1.102.0)

A `PostToolUse:SendMessage` hook (`scripts/enforce-glyph-budget.sh`) reinforces the Glyph Budget Protocol at the infrastructure layer. When any teammate sends a `SendMessage` call exceeding the word budget, the hook injects an advisory context message.

**Threshold**: 300 words (configurable via `RUNE_GLYPH_BUDGET` environment variable or talisman `context_weaving.glyph_budget.word_limit`).

**Behavior**: Advisory-only — PostToolUse cannot block. The advisory informs the orchestrator for corrective action on future messages.

**Guard**: Only active when Rune workflow state files exist in `tmp/` (detection via explicit file path checks — not globs).

```yaml
# talisman.yml schema (optional config)
context_weaving:
  glyph_budget:
    enabled: true              # Toggle enforcement
    word_limit: 300            # Max words before advisory
    enforcement: advisory      # advisory | warning | block (future)
```

## Layer 6.2: Adaptive Context Degradation (3-Tier System, v1.102.0)

The `guard-context-critical.sh` PreToolUse hook now implements a 3-tier context degradation system that provides graduated responses as context approaches exhaustion:

| Tier | Remaining % | Action | Block? |
|------|-------------|--------|--------|
| **Caution** | 35–40% | Advisory: compress messages, prefer file output | No |
| **Warning** | 25–35% | Workflow-specific degradation suggestions | No |
| **Critical** | ≤25% | Hard DENY for TeamCreate/Agent (except Explore/Plan) | Yes |

### Caution Tier (40% remaining)
Injects `additionalContext` with general compression suggestions. No block. Applies to all TeamCreate/Agent calls.

### Warning Tier (35% remaining)
Detects active workflow from state files (with session ownership check) and injects workflow-specific degradation suggestions:

| Workflow | Suggestion |
|----------|-----------|
| review/appraise/audit | Reduce team to 3-4 Ashes |
| work/strive | Complete current task, skip optional tasks |
| arc | Skip optional phases, proceed to ship |
| devise/plan | Skip forge enrichment |
| unknown | Reduce scope, prefer file-based output |

### Critical Tier (25% remaining, unchanged)
Hard DENY for TeamCreate and Agent tool calls. Explore/Plan agents remain exempt (read-only, minimal context cost). Escape hatches: `/rune:rest`, talisman disable flag, or Explore/Plan agent types.

## References

- [Overflow Wards](references/overflow-wards.md) — Detailed pre-summon protocol
- [Context Compression](references/context-compression.md) — Compression strategies and triggers
- [Filesystem Offloading](references/filesystem-offloading.md) — File-based output patterns
- Companion: `rune-orchestration` (architectural patterns, inscription protocol)
