# Multi-Factor Pruning Algorithm + Concurrent Write Protocol

## Multi-Factor Pruning Algorithm

When MEMORY.md exceeds 150 lines, calculate Echo Score for each entry:

```
Echo Score = (Importance × 0.4) + (Relevance × 0.3) + (Recency × 0.3)

Where:
  Importance = layer weight (etched=1.0, notes=0.9, inscribed=0.7, observations=0.5, traced=0.3)
  Relevance  = times referenced in recent workflows / total workflows (0.0-1.0)
  Recency    = 1.0 - (days_since_verified / max_age_for_layer)
```

### Pruning Rules

- **Etched**: Score locked at 1.0 — never pruned automatically
- **Notes**: Score locked at 0.9 — never auto-pruned (user-created = permanent)
- **Inscribed**: Archive if score < 0.3 AND age > 90 days unreferenced
- **Observations**: Auto-prune when days_since_last_access > 60 (EDGE-025). Auto-promote to Inscribed when access_count >= 3
- **Traced**: Archive if score < 0.2 AND age > 30 days
- Prune ONLY between workflows, never during active phases
- Always backup before pruning: copy MEMORY.md to `archive/MEMORY-{date}.md`

### Active Context Compression

When a role's `knowledge.md` exceeds 300 lines:
1. Group related entries by topic
2. Compress each group into a "knowledge block" (3-5 line summary)
3. Preserve evidence references but remove verbose descriptions
4. Expected savings: ~22% token reduction

## Concurrent Write Protocol

Multiple Ash may discover learnings simultaneously. To prevent write conflicts:

1. **During workflow**: Each Ash writes to `.claude/echoes/{role}/{agent-name}-findings.md` (unique file per agent)
2. **Post-workflow**: The Tarnished consolidates all `{agent-name}-findings.md` into `.claude/echoes/{role}/MEMORY.md`
3. **Cross-role learnings**: Only lead writes to `.claude/echoes/team/MEMORY.md`
4. **Consolidation protocol**: Read existing MEMORY.md → append new entries → check 150-line limit → prune if needed → write

### Write Protocol Steps

```
1. Read .claude/echoes/{role}/MEMORY.md (or create if missing)
2. Read all .claude/echoes/{role}/*-findings.md files
3. For each finding:
   a. Check if it duplicates an existing entry (same evidence + pattern)
   b. If duplicate: update verified date and confidence (higher wins)
   c. If new: append with entry format
4. If MEMORY.md > 150 lines: run pruning algorithm
5. Write updated MEMORY.md
6. Delete processed *-findings.md files
```
