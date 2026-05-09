<!-- Source: Extracted from agents/review/ward-sentinel.md, agents/review/pattern-seer.md,
     agents/review/flaw-hunter.md, agents/investigation/grace-warden.md (Mode: inspect),
     agents/utility/knowledge-keeper.md -->

# Finding Format Template — Shared Reference

Standard finding format used by all review and investigation agents.

## Severity Levels

| Level | Meaning | Action Required |
|-------|---------|-----------------|
| P1 (Critical) | Blocks merge/deployment | Must fix before proceeding |
| P2 (High) | Significant issue | Should fix, workaround may exist |
| P3 (Medium) | Improvement opportunity | Fix when convenient |

## Finding Format

Each finding follows this structure:

```markdown
- [ ] **[PREFIX-NNN] Title** in `file:line`
  - **Category:** {category}
  - **Confidence:** PROVEN | LIKELY | UNCERTAIN
  - **Evidence:** {actual code snippet or observation}
  - **Assumption:** {what was assumed — "None" if fully verified}
  - **Impact:** {consequence of the issue}
  - **Recommendation:** {specific fix}
```

### Finding ID Prefixes

Each agent uses a unique prefix for its findings:

| Prefix | Agent | Domain |
|--------|-------|--------|
| SEC | ward-sentinel | Security vulnerabilities |
| PAT / QUAL | pattern-seer | Design patterns, consistency |
| FLAW / BACK | flaw-hunter | Logic bugs, edge cases |
| DOC | knowledge-keeper | Documentation gaps |
| GRACE | grace-warden | Correctness, completeness |
| SIGHT | sight-oracle | Architecture, performance |
| WIRE | grace-warden | Wiring map verification |
| UXF | ux-flow-validator | User flow completeness |
| UXC | ux-cognitive-walker | Cognitive walkthrough |
| FLOW | flow-integrity-tracer | Data flow integrity |
| DES | aesthetic-quality-reviewer | Design fidelity / aesthetic quality (v3.0.0-alpha.2 reassignment from removed design-implementation-reviewer) |

> **v3.0.0-alpha.1+alpha.2 removed**: `UXH` (ux-heuristic-reviewer),
> `UXI` (ux-interaction-auditor) — agents retired with their consumers.
> If `UXH-` or `UXI-` findings appear in a TOME from older runs, treat them as
> historical and route to `aesthetic-quality-reviewer` for triage.

### Confidence Calibration

- **PROVEN**: Read the file, traced the logic, confirmed the behavior
- **LIKELY**: Read the file, pattern matches known issue, didn't trace full call chain
- **UNCERTAIN**: Noticed based on naming/structure/partial reading — not sure if intentional

**Rule**: If >50% of findings are UNCERTAIN, re-read source files and either
upgrade to LIKELY or move to Unverified Observations.

## Agent-Specific Content (NOT in this shared file)

- Agent-specific finding categories and subcategories
- Hypothesis protocol (flaw-hunter specific)
- Rune Trace format variations (blockquote vs code block)
- Q/N interaction taxonomy (see `plugins/rune/agents/shared/phase-review.md`)
