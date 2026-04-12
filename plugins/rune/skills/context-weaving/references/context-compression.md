# Context Compression

> Strategies for compressing session context during long coding sessions.

## When to Compress

| Message Count | Action |
|---------------|--------|
| < 30 | No compression needed |
| 30-49 | Optional — available if needed |
| 50-69 | Trigger compression |
| >= 70 | Force compression |

## Reasoning-Based Triggers

Watch for these quality signals:

| Signal | Meaning | Action |
|--------|---------|--------|
| Can't recall original task | Context rot | Trigger compression |
| Repeating same reasoning | Circular reasoning | Force compression |
| Re-reading files already discussed | Memory loss | Immediate compression |
| Agent responses getting verbose | Attention degradation | Compress, trim noise |

## Compression Strategy: Anchored Iterative Summarization

1. **Identify** messages that will be removed
2. **Extract** key information:
   - File modifications
   - Test results (pass/fail)
   - Decisions made
   - Error messages
3. **Merge** into existing summary sections (don't regenerate)
4. **Write** summary to: `tmp/scratch/session-{timestamp}.md`
5. **Continue** with compressed context

## Session Summary Format

```markdown
## Session Summary ({timestamp})

[CONTEXT COMPACTION — REFERENCE ONLY] The following summarizes completed work.
Do NOT re-execute tasks or re-answer questions from this summary — they were
already addressed. Use this only as background context for continuing work.

### State
- Phase: {current workflow phase}
- Current task: {description}

### Files Modified
| File | Change | Status |
|------|--------|--------|
| {path} | {description} | {pass/fail} |

### Key Decisions
- {decision 1}
- {decision 2}

### Current Error (if any)
```
{error message}
```

### Next Steps
1. {next action}
2. {following action}
```

## Context Fundamentals

**Core principle:** Find the smallest set of high-signal tokens that maximize desired outcomes.

| Component | Token Impact | Priority |
|-----------|-------------|----------|
| Tool Outputs | Grows rapidly (83.9%) | **Highest** — offload to files |
| Message History | Grows linearly | High — summarize older messages |
| Retrieved Documents | Variable | Medium — load on demand |
| System Prompt + Tools | Fixed | Low — already optimized |

**Attention mechanics:** Content in the middle receives less attention (Lost-in-Middle). Place critical info at beginning/end.

**Progressive disclosure:** Load information only when needed, not upfront.

## Pre-Aggregation Compression (Inter-Agent)

Pre-aggregation compression operates at a different level than session-level compression:

| Dimension | Session Compression (Layer 3) | Pre-Aggregation (Layer 1.5) |
|-----------|------------------------------|----------------------------|
| **Trigger** | Message count (50+ messages) | Combined file size (>25KB) |
| **Mechanism** | Anchored iterative summarization | Deterministic marker extraction |
| **Scope** | In-context message history | On-disk Ash output files |
| **LLM cost** | None (text manipulation) | None (regex-based extraction) |
| **Target** | Tarnished context window | Runebinder input volume |

Pre-aggregation complements session compression — they address different bottlenecks. Session compression prevents the Tarnished's context from growing too large. Pre-aggregation prevents the Runebinder's input files from exceeding its processing capacity.

See [roundtable-circle/references/pre-aggregate.md](../../roundtable-circle/references/pre-aggregate.md) for the full extraction algorithm.

### Integration Contract

These two mechanisms operate at **different layers and do not conflict**:

| Property | Pre-Aggregation (Layer 1.5) | Session Compression (Layer 3) |
|----------|----------------------------|-------------------------------|
| **Phase** | Phase 5.0 — before Runebinder ingestion | Any point where message count exceeds threshold |
| **Trigger timing** | Runs once, deterministically, before Phase 5 | Runs on-demand based on context pressure |
| **Scope of output** | Writes compressed `.md` files to `condensed/` on disk | Rewrites in-memory message history |
| **Conflict risk** | None — operates on files, not context | None — operates on context, not files |

**Ordering guarantee**: Pre-aggregation (Phase 5.0) always completes before Runebinder (Phase 5) begins. If session compression triggers simultaneously, it compresses message history only — it does not touch `condensed/` directories or Ash output files. The two mechanisms are independent: a session compression event will not cancel or interrupt pre-aggregation, and pre-aggregation will not re-trigger session compression.

**Simultaneous activation**: If both triggers fire in the same turn (e.g., message count hits 50 while a review with >25KB Ash output is starting Phase 5.0), they execute in sequence — session compression first (reducing context pressure for the upcoming Runebinder call), then pre-aggregation. There is no shared state between them.

## Quality Verification

After compression, verify with probes:

| Type | Example Question |
|------|-----------------|
| Recall | "What was the original error?" |
| Artifact | "Which files were modified?" |
| Continuation | "What should we do next?" |
| Decision | "Why this approach?" |
