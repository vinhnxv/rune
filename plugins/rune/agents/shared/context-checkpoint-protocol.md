<!-- Source: extracted from rune-smith, trial-forger on 2026-03-20 -->
<!-- This file is a shared reference. Do NOT duplicate this content in agent .md files. -->
<!-- Agents that Read() this file: rune-smith, trial-forger, and other swarm worker agents -->

# Context Checkpoint (Post-Task)

After completing each task and before claiming the next, apply a reset proportional to your task position.

## Adaptive Reset Depth

| Completed Tasks | Reset Level | What To Do |
|----------------|-------------|------------|
| 1-2 | **Light** | Write Seal with 2-sentence summary. Proceed to next task normally. |
| 3-4 | **Medium** | Write Seal summary. Re-read the plan file before claiming next task. Do NOT rely on memory of details from earlier tasks — re-read target files fresh. |
| 5+ | **Aggressive** | Write Seal summary. Re-read plan file AND re-discover project conventions (ward commands, naming patterns, test patterns) as if starting fresh. Treat yourself as a new agent. |

## What MUST be in your Seal summary

Every Seal summary must include these 3 elements (not just "task done"):
1. **Pattern followed**: Which existing codebase pattern did you replicate?
2. **Source of truth**: Which file(s) are the canonical reference for what you built?
3. **Decision made**: Any non-obvious choice you made and why.

## Context Rot Detection

If you notice yourself:
- Referring to code you wrote 3+ tasks ago without re-reading the file
- Assuming a function exists because you "remember" writing it (verify with Grep first)
- Copying patterns from memory instead of from actual source files
- Your confidence score (from Seal) drops below 70 for 2 consecutive tasks

...you are experiencing context rot. Immediately apply **Aggressive** reset regardless of task count.

**Tarnished monitoring**: The Tarnished should also track confidence scores across your Seal messages. If the Tarnished observes confidence < 70 for 2 consecutive Seals, it should instruct you to apply Aggressive reset — do not rely solely on self-detection.

**Why**: In long swarm sessions (4+ tasks), conversation history grows until context overflow (DC-1 Glyph Flood). Adaptive reset sheds context proportionally — light early, aggressive late — instead of one-size-fits-all.
