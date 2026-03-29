# Output Format — Ash Finding Specifications

> Defines raw finding format, validated format, and dual output modes (Markdown + JSON).

## Raw Finding Format (Written by Ash)

Each finding follows this template:

```markdown
- [ ] **[{PREFIX}-{NUM}] {Title}** in `{file}:{line}`
  - **Rune Trace:**
    ```{language}
    # Lines {start}-{end} of {file}
    {actual code from the source file — copy-pasted, NOT paraphrased}
    ```
  - **Issue:** {description of what's wrong and why it matters}
  - **Fix:** {specific recommendation with code example if applicable}
  - **Confidence:** PROVEN | LIKELY | UNCERTAIN
  - **Assumption:** {what the agent assumed about this code — or "None" if fully verified}
  - **Evidence:**                          _(optional)_
    - type: grep_match | file_read | negative_grep | agent_output | reasoning_chain
    - source: {file:line or grep command or agent reference}
    - confidence: PROVEN | LIKELY | UNCERTAIN
    - counter_argument: {why this might be wrong, or "None"}
```

### Finding Prefixes

| Ash | Prefix | Example |
|-----------|--------|---------|
| Forge Warden | `BACK` | `BACK-001` |
| Ward Sentinel | `SEC` | `SEC-001` |
| Veil Piercer | `VEIL` | `VEIL-001` |
| Pattern Weaver | `QUAL` | `QUAL-001` |
| Glyph Scribe | `FRONT` | `FRONT-001` |
| Knowledge Keeper | `DOC` | `DOC-001` |
| Codex Oracle | `CDX` | `CDX-001` |
| Doubt Seer | `DOUBT` | `DOUBT-001` |

### Rune Trace Requirements

1. **MUST quote actual code** — 3-5 lines from the source file
2. **MUST include file:line reference** — exact location
3. **MUST be copy-pasted** — not reconstructed from memory
4. If evidence cannot be provided → move to `## Unverified Observations`

## Validated Finding Format (After Self-Review)

After self-review, findings may be annotated:

```markdown
- [x] **[SEC-001] SQL Injection** in `routes.py:42` — ✅ CONFIRMED
- [ ] **[SEC-002] Missing Auth Check** in `admin.py:15` — ⚠️ REVISED (downgraded from P1)
- ~~**[SEC-003] Hardcoded Secret** in `config.py:3`~~ — ❌ DELETED (env var confirmed)
```

## JSON Output (Optional, for Programmatic Consumption)

In addition to Markdown, Ash MAY write a companion JSON file for tooling integration:

```json
{
  "ash": "forge-warden",
  "workflow": "rune-review",
  "identifier": "PR #142",
  "timestamp": "2026-02-11T10:45:00Z",
  "findings": [
    {
      "id": "BACK-001",
      "priority": "P1",
      "title": "Race condition in payment processing",
      "file": "services/payment.py",
      "line": 78,
      "rune_trace": "async def process_payment(self, order):\n    balance = await self.get_balance()\n    # No lock between read and write",
      "issue": "Balance read and debit are not atomic",
      "fix": "Add async lock around balance operations",
      "confidence": "PROVEN | LIKELY | UNCERTAIN",
      "assumption": "string — what the agent assumed, or null if fully verified",
      "status": "confirmed"
    }
  ],
  "taxonomy_version": 2,
  "summary": {
    "p1": 2,
    "p2": 3,
    "p3": 1,
    "q": 1,
    "n": 2,
    "total": 9,
    "evidence_verified": 9,
    "confidence": 0.85
  }
}
```

JSON output file: `{output_dir}/{ash}-findings.json`

### When to Use JSON Output

| Scenario | MD Only | MD + JSON |
|----------|---------|-----------|
| Standard review | Default | Optional |
| CI/CD integration | ✗ | Required |
| Automated fix tooling | ✗ | Required |
| Human-only review | Default | Optional |

## Docs-Specific Format (Knowledge Keeper)

Knowledge Keeper uses blockquotes instead of code blocks for evidence:

```markdown
- [ ] **[DOC-001] Outdated API endpoint** in `docs/api.md:45`
  - **Rune Trace:**
    > Line 45: "POST /api/v1/users — Creates a new user"
    > Line 46: "Required fields: name, email"
  - **Issue:** Endpoint was renamed to `/api/v2/users` in backend refactor
  - **Fix:** Update to match current API routes
```

## TOME Format (Aggregated by Runebinder)

```markdown
# TOME — Review Summary

**PR:** #{pr-number}
**Date:** {timestamp}
**Ash:** {count} summoned, {count} completed

## P1 (Critical) — {count} findings

{All P1 findings from all Ash, deduplicated}

## P2 (High) — {count} findings

{All P2 findings, deduplicated}

## P3 (Medium) — {count} findings

{All P3 findings, deduplicated}

## Coverage Gaps

| Ash | Status | Uncovered Scope |
|-----------|--------|-----------------|
| {name} | {complete/partial/missing} | {files not reviewed due to budget} |

## Verification Status

| Ash | Confidence | Spot-Checked | Result |
|-----------|-----------|-------------|--------|
| {name} | {0.X} | {N findings} | {all confirmed/N hallucinated} |

## Assumption Summary

| Ash | PROVEN | LIKELY | UNCERTAIN | UNTAGGED | Key Assumptions |
|-----------|--------|--------|-----------|----------|-----------------|
| {name} | {count} | {count} | {count} | {count} | {brief list of assumptions made} |

### High-Risk Assumptions (from UNCERTAIN findings)

- {Ash}: {assumption text} — impacts {finding IDs}

### Potential Assumption Conflicts (requires human review)

- {Ash A} assumes {X} but {Ash B} assumes {Y} — affects {file}

## Questions — {count} items

{Findings with interaction="question" — clarification needed before concluding}

## Nits — {count} items

{Findings with interaction="nit" — cosmetic, author's discretion}

## Summary

- Total findings: {count}
- P1: {count}, P2: {count}, P3: {count}, Q: {count}, N: {count}
- Ash: {completed}/{summoned}
- Evidence coverage: {verified}/{total}
```

## Dedup Hierarchy

When the same finding appears from multiple Ash:

```
SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > CDX
```

Keep the finding from the higher-priority Ash. DOUBT- prefix is non-deduplicable — DOUBT findings target meta-review claims about other agents' findings and should never be merged with findings from other prefixes during deduplication. See [Dedup Runes](dedup-runes.md) for full algorithm.

## References

- [Dedup Runes](dedup-runes.md) — Deduplication algorithm
- [Inscription Schema](inscription-schema.md) — inscription.json `required_sections`
