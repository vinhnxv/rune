# Structured Reasoning for Multi-Agent Orchestration

> Reasoning principles for the Tarnished and Ash teammates in multi-agent workflows.

Applies Sequential Thinking principles to multi-agent workflows at both the **lead orchestration** and **Ash reasoning** levels. All guidance here is prompt engineering — no new tools or infrastructure required.

## Why Linear Processes Degrade

Multi-agent workflows follow a linear pipeline: summon → work → collect → aggregate. Without iterative reasoning:

| Gap | Impact |
|-----|--------|
| No self-correction | Hallucinated Rune Traces persist through aggregation |
| No revision loops | Low-confidence findings never improve, only get flagged |
| No branching | Conflicting findings resolved mechanically by priority, losing nuance |
| No dynamic scope | Pre-summon is write-once; can't adapt when conditions change mid-work |

## 5 Principles for Multi-Agent Reasoning

### Principle 1: Forced Serialization

**Break decisions into numbered steps instead of producing output in one pass.**

| Level | Application |
|-------|-------------|
| Lead (pre-summon) | 8-thought checklist before summoning Ash (see `context-weaving`) |
| Lead (post-aggregate) | Numbered conflict resolution steps when Ash disagree |
| Ash | Numbered analysis phases during self-review |

### Principle 2: Revision Permission

**Allow self-correction without losing context.**

| Level | Application |
|-------|-------------|
| Lead (aggregation) | "Finding X from Forge Warden contradicts Y from Ward Sentinel — revise priority assignment" |
| Lead (monitoring) | "Ash timed out — revise inscription expectations, mark as partial" |
| Ash (self-review) | Re-read output file, fix weak Rune Traces, downgrade or delete hallucinated findings |

**Key constraint**: Ash get ONE revision pass to prevent infinite loops. Lead can revise multiple times during aggregation.

### Principle 3: Branching

**Explore alternative analysis paths without losing the main thread.**

| Level | Application |
|-------|-------------|
| Lead (aggregation) | When 2+ Ashes flag same code differently, branch to explore both interpretations before choosing |
| Ash | **Not applicable** — Ash work in isolation and don't benefit from branching |

### Principle 4: Dynamic Scope

**Adjust scope mid-work when conditions change.**

| Level | Application |
|-------|-------------|
| Lead (pre-summon) | Thought 6 of extended checklist: "Can I merge redundant Ash? Split overloaded ones?" |
| Lead (monitoring) | Ash timeout → revise expectations. New file patterns discovered → add conditional Ash |
| Ash (self-calibration) | Found 0 issues in 10 files → broaden review lens. Found 50+ issues → narrow to P1 only |

### Principle 5: State Externalization

**Write intermediate state to files to reduce cognitive load.**

| Level | Application |
|-------|-------------|
| Lead | Checkpoint reasoning to `tmp/scratch/` during complex orchestration decisions |
| Ash | Already externalized via output files. Self-review reads the written file, not memory |

## Three Reasoning Checkpoints

### 1. Pre-Summon (Tarnished)

Before launching Ash, use the 8-thought pre-summon checklist from `context-weaving`:

| Thought | Purpose | Key Question |
|---------|---------|-------------|
| 1 | Count and Estimate | How many Ash? What's the token budget? |
| 2 | Choose Strategy | Agent Teams (all Rune commands). Verify inscription + Glyph Budget. |
| 3 | Output Directory + Inscription | Where do Ash write? Generate inscription.json |
| 4 | Verify Protocol Injection | Does each Ash prompt include Glyph Budget + Seal format? |
| 5 | Post-Completion Validation | How will I verify outputs after completion? |
| **6** | **Revision Checkpoint** | Can I merge redundant Ash? Split overloaded Ash? Is the context budget per Ash appropriate? |
| **7** | **Fallback Strategies** | If an Ash times out or MCP is unavailable, what's Plan B? Document in inscription |
| **8** | **Verification Planning** | Which layers of Truthsight to enable? When to summon verifier? |

**When to use**: Always use for all Rune multi-agent commands. Use Thoughts 1-5 for small teams (1-2 teammates), add Thoughts 6-8 for larger teams (3+) or complex workflows.

### 2. Mid-Monitor (Tarnished)

Use structured reasoning when these conditions arise during execution:

| Trigger | Reasoning Action |
|---------|-----------------|
| Ash timeout (no response after expected duration) | Revise inscription: mark Ash as `partial`, decide whether to re-summon or continue without |
| Tier 2 clarification request from Ash | Assess: Can I answer from context? If not, degrade to Tier 1 (flag + proceed) |
| Partial failure (1 of N Ash failed) | Evaluate: Is the failed Ash's scope critical? If yes, re-summon. If no, document gap in TOME |
| Unexpected patterns discovered | Dynamic scope: Should I add a conditional Ash? (e.g., payment code found mid-review) |

### 3. Post-Aggregate (Tarnished)

Use structured reasoning when Ash produce conflicting findings:

```
Step 1: Identify the conflict
  - Forge Warden says X about file:line
  - Ward Sentinel says Y about same file:line

Step 2: Verify evidence
  - Read the actual source file
  - Which Ash's Rune Trace matches reality?

Step 3: Branch if both are valid
  - If both interpretations have merit, document both perspectives
  - Use branching: explore resolution A (keep Forge Warden's view) vs resolution B (keep Ward Sentinel's view)

Step 4: Resolve
  - Apply priority hierarchy (ward-sentinel P1 > other P1 > P2 > P3)
  - If same priority: keep the finding with stronger Rune Trace evidence
  - Document resolution reasoning in TOME.md
```

## Ash Self-Review Protocol

**Embedded inline in each Ash's prompt — no external file reads required.**

### The Process (ONE Pass)

After writing all findings to the output file, before sending the Seal:

1. **Re-read** your output file
2. **Verify** each P1 finding:
   - Is the Rune Trace an actual code snippet (copy-paste, not paraphrased)?
   - Does the `file:line` reference exist?
   - Is the confidence assessment honest?
3. **Fix** findings with weak Rune Traces:
   - Re-read the source file with `Read()`
   - **REVISE** with correct evidence, OR
   - **DOWNGRADE** to lower priority, OR
   - **DELETE** if hallucinated
4. **Update** confidence in Seal based on revision results

### Scope Rules (By Output Size)

| Total Findings | Self-Review Scope |
|----------------|-------------------|
| < 50 | Review ALL findings |
| 50-100 | Review all P1 + random 20% sample of P2 |
| > 100 | Review P1 only |

### Self-Calibration Signals

| Signal | Action |
|--------|--------|
| 0 issues found in 10+ files | Broaden review lens — re-read 2-3 files with fresh perspective |
| 50+ issues found | Narrow focus — likely over-flagging. Review P1 only, consolidate P2/P3 |
| All findings are P3 | Reconsider — is there a P1/P2 being missed? Re-read critical paths |
| Rune Trace blocks are >10 lines | Trim to 3-5 lines showing the core issue |

**Hard limit**: This is ONE revision pass. Do not iterate further. Accept remaining uncertainty and report it in the confidence field of the Seal.

## Decision Complexity Matrix

Not every decision needs structured reasoning. Use this matrix:

| Decision Type | Use Structured Reasoning | Use Heuristic/Lookup Table |
|---------------|-------------------------|---------------------------|
| Ash count → strategy | | Use table in context-weaving |
| File pattern → Ash mapping | | Use conditional Ash table in Rune Gaze |
| Confidence → spot-check count | | Use matrix in inscription-protocol |
| Merge redundant Ash? | When trade-offs are unclear | When Ash clearly overlap (same files, same checks) |
| Conflicting Ash findings | Always (Ash disagree on same code) | |
| Partial failure recovery | When impact is uncertain | When failed Ash was clearly non-critical |
| Scope revision mid-work | When new patterns change assumptions | When change is additive (just add a conditional Ash) |
| Compression timing | When reasoning quality unclear | Use message-count thresholds |

**Rule of thumb**: If the decision has a lookup table, use it. If it requires weighing trade-offs with uncertainty, use structured reasoning.

## Fallback Behavior

If Sequential Thinking MCP is unavailable:

| Checkpoint | Fallback |
|-----------|----------|
| Pre-summon (lead) | Use the 8-thought checklist as a manual checklist (think through each point without the MCP tool) |
| Mid-monitor (lead) | Use heuristic decision tables in inscription-protocol.md |
| Post-aggregate (lead) | Apply conflict resolution rules from rune-orchestration SKILL.md directly |
| Self-review (Ash) | The self-review protocol is inline prompt text — works regardless of MCP availability |

The self-review checkpoint does NOT depend on Sequential Thinking MCP. It is embedded directly in Ash prompts.

## Token Budget

| Component | Budget |
|-----------|--------|
| Per thought (lead) | 100-200 words max |
| Verbose reasoning | Offload to `tmp/scratch/{workflow}-reasoning.md` |
| Self-review (Ash) | ~10 lines of prompt text per template |
| Total overhead per review session | ~40 lines across up to 5 Ash templates |

Sequential Thinking adds minimal overhead because it structures existing reasoning rather than adding new content.

## When to Use Structured Reasoning vs. Lookup Tables

| Use Structured Reasoning | Use Lookup Table |
|-------------------------|-----------------|
| Trade-offs with uncertainty | Deterministic mappings |
| Conflicting Ash findings | File pattern → Ash mapping |
| Partial failure recovery | Confidence → spot-check count |
| Scope revision mid-work | Priority hierarchy |
| Novel situations | Repeated patterns |

## Integration with Sequential Thinking MCP

If the `mcp__sequential-thinking__sequentialthinking` tool is available, use it for the pre-summon checklist and post-aggregate conflict resolution. The structured reasoning checkpoints map directly to Sequential Thinking parameters:

| Checkpoint | `thoughtNumber` range | `totalThoughts` |
|-----------|----------------------|-----------------|
| Pre-summon | 1-8 | 8 |
| Mid-monitor | Varies | Varies (per intervention) |
| Post-aggregate | 1-6 | 6 (adjust for conflicts) |

Use `isRevision: true` when reconsidering a decision. Use `branchFromThought` when comparing alternatives.

## References

- Pre-summon checklist: `../../context-weaving/SKILL.md` (Thoughts 1-8)
- Conflict resolution: `../SKILL.md` → "Conflict Resolution Rules"
- Truthbinding Protocol: `inscription-protocol.md` → "Truthbinding Protocol"
- Prompt engineering: `prompt-weaving.md` → 7-section template
- Ash agents: `../../../agents/` → Self-Review Checkpoint
