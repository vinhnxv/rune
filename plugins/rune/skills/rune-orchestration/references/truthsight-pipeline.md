# Truthsight Pipeline

> 4-layer verification pipeline for Ash outputs.

## Overview

Truthsight validates that Ash findings are grounded in actual code, not hallucinated. Each layer adds a verification level, with earlier layers being cheaper and later layers more thorough.

## 4 Layers

### Phase 5.2: Citation Verification (pre-Truthsight)

A grep-first structural verification pass that runs BEFORE Truthsight Layers 0-2.
Catches the most common hallucination type (non-existent files, out-of-range lines)
at near-zero cost, reducing the load on the more expensive Layer 2 Smart Verifier.

| Check | Method | Cost |
|-------|--------|------|
| File exists | Glob | ~0ms |
| Line in range | Read + line count | ~5ms |
| Pattern match | Grep first trace line | ~10ms |

Phase 5.2 is complementary to Layer 2 — it handles structural validity while
Layer 2 handles semantic correctness (does the code actually exhibit the described
behavior?).

See [orchestration-phases.md](../../roundtable-circle/references/orchestration-phases.md) Phase 5.2 for full pseudocode.

### Layer 0: Inline Checks (Tarnished)

**Cost:** ~0 extra tokens (lead runs Grep directly)
**When:** Always active for 3+ Ashes workflows
**Output:** `{output_dir}/inline-validation.json`

The Tarnished performs grep-based validation on each output file:

### Procedure

```
For each Ash output file:
  1. Read required_sections from inscription.teammates.find(t => t.name === ash).required_sections
  2. Grep for each "## Section Name" header in the output file
  3. Parse Seal for required fields:
     - findings, evidence_verified, confidence,
       self_reviewed, self_review_actions
  4. Check Self-Review Log exists: Grep for "confirmed|REVISED|DELETED"
  5. Check evidence blocks exist: Grep for "Rune Trace" patterns
  6. Record result per Ash
```

### Output Format

```json
{
  "timestamp": "2026-02-11T10:30:00Z",
  "results": {
    "forge-warden": {
      "checks": {
        "P1 (Critical)": true,
        "P2 (High)": true,
        "P3 (Medium)": true,
        "Summary": true,
        "Self-Review Log": true,
        "Rune Traces": true,
        "Seal": true
      }
    }
  },
  "ash_checked": 4
}
```

### Failure Semantics

| Outcome | Action |
|---------|--------|
| ALL PASS | Proceed to Layer 2 (summon verifier) |
| PARTIAL | Proceed with skip list (verifier skips invalid files) |
| ALL FAIL | Skip verification, flag workflow for human review |
| TOOL ERROR | Treat as PASS, rely on Layer 2 |

### Circuit Breaker

| State | Behavior | Transition |
|-------|----------|------------|
| CLOSED (normal) | Run all checks | → OPEN after 3 consecutive ALL FAIL |
| OPEN (bypassed) | Skip Layer 0, warn lead | → HALF_OPEN after 60s recovery |
| HALF_OPEN (testing) | Run checks on 1 Ash only | → CLOSED if pass, → OPEN if fail |

Configuration: `layer_0_circuit: { failure_threshold: 3, recovery_seconds: 60 }`

### Layer 1: Verifiable Self-Review (Each Ash)

**Cost:** ~0 extra tokens (Ash do it themselves)
**When:** Always active (embedded in Ash prompts)
**Output:** `## Self-Review Log` table appended to each Ash's output file

Before sending the Seal, each Ash:
1. Re-reads their P1 and P2 findings
2. For each finding: verifies evidence exists in the actual source file
3. Actions: `confirmed` / `REVISED` / `DELETED`
4. Logs actions in Self-Review Log section

### Self-Review Log Format

```markdown
## Self-Review Log

| # | Finding | Action | Notes |
|---|---------|--------|-------|
| 1 | P1: SQL injection in user_queries.py:45 | confirmed | Rune Trace re-verified against source |
| 2 | P2: Missing auth check in admin_routes.py:112 | confirmed | |
| 3 | P2: Unused import in models.py:3 | DELETED | Import is used in type annotation |
| 4 | P1: Race condition in payment_service.py:78 | REVISED | Downgraded to P2, async lock exists |
```

### Actions

| Action | Meaning | Effect on Output |
|--------|---------|-----------------|
| `confirmed` | Re-verified, finding is accurate | No change |
| `REVISED` | Corrected in-place | Update finding text + evidence in output |
| `DELETED` | Removed (was fabricated/incorrect) | Remove from findings section |

### Seal Field

```
self_review_actions: "confirmed: 10, revised: 1, deleted: 1"
```

### Verification Checks (performed by Layer 0 or Layer 2)

1. Row count in Self-Review Log matches P1 + P2 finding count
2. DELETED items actually removed from findings section
3. `self_review_actions` counts match log table totals

### Detection Heuristics

| Metric | Healthy | Warning | Rotted |
|--------|---------|---------|--------|
| Confirmed rate | >80% | 50-80% | <50% |
| Delete rate | <10% | 10-25% | >25% |
| Log completeness | 100% of P1+P2 | >80% | <80% |
| REVISED with changes | All REVISED have edits | Some missing | No edits visible |

### Layer 2: Smart Verifier (Summoned by Lead)

**Cost:** ~5-15k tokens (verifier reads outputs + samples source files)
**When:** Roundtable Circle with 3+ Ashes, or audit with 5+ Ashes
**Output:** `{output_dir}/truthsight-report.md`

### Summoning Conditions

| Workflow | Condition | Model |
|----------|-----------|-------|
| `/rune:appraise` | `inscription.verification.enabled` AND 3+ Ashes | haiku |
| `/rune:audit` | `inscription.verification.enabled` AND 5+ Ashes | haiku |
| Custom | Configurable via inscription `verification` block | haiku |

### Sampling Strategy

| Finding Priority | Default Rate | If Ash confidence < 70 | If inline checks FAILED |
|-----------------|-------------|-------------------------------|------------------------|
| P1 (Critical) | 100% | 100% | 100% |
| P2 (High) | ~30% (every 3rd) | 100% | 100% |
| P3 (Medium) | 0% | 0% | 50% |

### Verification Tasks

The verifier performs 5 tasks in order:

1. **Rune Trace Resolvability Scan** — Extract every `**Rune Trace:**` code block, parse file:line references, use Grep to check if cited pattern exists
2. **Sampling Selection** — Select specific findings to deep-verify based on sampling rates above
3. **Deep Verification** — Read source files at cited lines (offset/limit), compare against Rune Trace, assign verdict: CONFIRMED / INACCURATE / HALLUCINATED
4. **Cross-Ash Conflict Detection** — Group findings by file path, identify overlapping assessments, flag conflicts and groupthink
5. **Self-Review Log Validation** — Verify log row counts match finding counts, DELETED items removed, action counts consistent

### Hallucination Criteria

**HALLUCINATED:**
- Cited file doesn't exist
- Cited line is out of range
- Code at cited location doesn't match the Rune Trace block
- Finding describes behavior contradicted by actual code

**INACCURATE (CONTESTED):**
- Rune Trace partially matches but finding overstates severity
- Code has changed since review (uncommon in same-session)

### Context Budget

| Component | Tokens | Limit |
|-----------|--------|-------|
| Ash output files | ~10k each | Max 8 files per run |
| Source files (sampled) | ~3k each | Max 15 files per run |
| Metadata (inscription, inline-validation) | ~5k | 1 per run |
| **Total input** | ~100k | |
| **Remaining for reasoning + output** | ~100k | |

### Read Constraints

**Allowed:**
- `Grep "pattern" file.py` at stated line ranges
- `Read file.py` with `offset`/`limit` to check specific lines

**Prohibited:**
- `Read file.py` without offset/limit (wastes verifier context)
- Reading files not referenced in findings (scope creep)

### Verifier Output Format

```markdown
# Truthsight Report

**Workflow:** {workflow_type}
**Date:** {timestamp}
**Verifier model:** haiku

## Summary
- Ash verified: {verified}/{total}
- Findings sampled: {sampled}/{total_findings} ({percentage}%)
- Verified correct: {correct}/{sampled} ({accuracy}%)
- Hallucinations found: {count}
- Conflicts found: {count}
- Re-verifications recommended: {count}

## Per-Ash Results

### {ash-name} (confidence: {confidence})
- Inline validation: {PASS/WARN/FAIL}
- Rune Trace resolvability: {resolvable}/{total} ({percentage}%)
- Sampled: {count} findings ({breakdown by priority})
- Results:
  - {Finding ID} ({file}:{line}): {CONFIRMED/HALLUCINATED/INACCURATE}
- Self-Review Log: {reviewed}/{expected} findings reviewed, {deleted} deleted

## Conflicts
{List of cross-Ash conflicts, or "None detected."}

## Hallucination Details
{For each hallucinated finding: what was claimed vs actual}

## Re-Verification Recommendations
{Max 2 re-verify agents per workflow run}
```

### Circuit Breaker

| State | Behavior | Transition |
|-------|----------|------------|
| CLOSED (normal) | Summon verifier agent | → OPEN after 2 consecutive failures/timeouts |
| OPEN (bypassed) | Skip verification, rely on Layer 0 only | → HALF_OPEN after 120s recovery |
| HALF_OPEN (testing) | Summon verifier with reduced scope (P1s only) | → CLOSED if success, → OPEN if fail |

Configuration: `layer_2_circuit: { failure_threshold: 2, recovery_seconds: 120 }`

### Timeout Recovery

- **Verifier timeout**: 15 minutes
- If timeout: check for partial output in `truthsight-report.md`
- If partial output exists: use whatever was verified, note incomplete coverage
- If no output: fallback to Layer 0 results only, flag for human review

### Phase 5.2: Citation Verification (pre-Truthsight)

A grep-first structural verification pass that runs BEFORE Truthsight Layers 0-2.
Catches the most common hallucination type (non-existent files, out-of-range lines)
at near-zero cost, reducing the load on the more expensive Layer 2 Smart Verifier.

| Check | Method | Cost |
|-------|--------|------|
| File exists | Glob | ~0ms |
| Line in range | Read + line count | ~5ms |
| Pattern match | Grep first trace line | ~10ms |

Phase 5.2 is complementary to Layer 2 — it handles structural validity while
Layer 2 handles semantic correctness (does the code actually exhibit the described
behavior?).

#### Validation Procedure

For each `<!-- RUNE:FINDING -->` marker in the TOME:

```
1. Extract file path and line number from marker attributes
2. FILE CHECK: Glob(file_path) — if no match → tag as [UNVERIFIED: file not found]
3. LINE CHECK: Read(file_path) → count lines — if line > total_lines → tag as [UNVERIFIED: line out of range]
4. PATTERN CHECK: Grep(first line of Rune Trace, file_path, offset=line-2, limit=5)
   - If no match → tag as [SUSPECT: pattern not found at cited location]
   - If match → VERIFIED (no tag added)
5. Record result per finding in citation-verification.json
```

**Aggregate validation**: After all findings are checked, compute pass rate.
If pass rate < 50%, flag the entire TOME for human review. Individual
`[UNVERIFIED]` findings are excluded from mend assignment; `[SUSPECT]` findings
proceed with extra verification instructions for the fixer.

### Layer 3: Reliability Tracking (Deferred to v2.0)

**Cost:** Write to `.rune/echoes/`
**When:** After each review session (future)

Track per-agent hallucination rates over time. Agents with high hallucination rates get additional verification in future runs.

## When to Enable Each Layer

| Workflow | Layer 0 | Layer 1 | Layer 2 | Layer 3 |
|----------|---------|---------|---------|---------|
| `/rune:appraise` (3+ teammates) | Always | Always | Enabled | v2.0 |
| `/rune:appraise` (1-2 teammates) | Always | Always | Optional | v2.0 |
| `/rune:audit` (8+ agents) | Always | Always | Enabled | v2.0 |
| `/rune:devise` | Skip | Skip | Skip | Skip |
| `/rune:strive` | Skip | Skip | Skip | Skip |

## Inscription Verification Block

Add to `inscription.json`:

```json
{
  "verification": {
    "enabled": true,
    "layer_0_circuit": {
      "failure_threshold": 3,
      "recovery_seconds": 60
    },
    "layer_2_circuit": {
      "failure_threshold": 2,
      "recovery_seconds": 120
    },
    "max_reverify_agents": 2
  }
}
```

## Re-Verification

When the verifier finds hallucinated Rune Traces, the Tarnished may summon targeted re-verify agents:

| Property | Value |
|----------|-------|
| Type | `general-purpose` Task subagent |
| Model | haiku |
| Max per workflow | 2 |
| Timeout | 3 minutes |
| Output | `{output_dir}/re-verify-{ash}-{finding-id}.md` |

**Decision logic:**
- If re-verify says HALLUCINATED: remove finding from TOME.md with note
- If re-verify says VALID: mark finding as CONTESTED, present both views
- If re-verify times out: keep original verifier assessment

## Integration Points

### Where Each Workflow Runs Verification

| Workflow | Phase | Trigger |
|----------|-------|---------|
| `/rune:appraise` | Phase 6 (Verify) | Steps 6a (Layer 0), 6b (Layer 1 review), 6c (Layer 2) |
| `/rune:audit` | Phase 5.5 (Truthseer Validator) + Phase 6 | Steps 5.5 (cross-reference), 6a-6c |
| `/rune:devise` | None | Verification not required for research |
| `/rune:strive` | None | Status-only output, no findings to verify |

### Output Files

```
{output_dir}/
├── inline-validation.json      # Layer 0 results
├── truthsight-report.md        # Layer 2 results
├── re-verify-{name}-{id}.md    # Re-verify agent results (if hallucination found)
└── {ash}.md             # Ash outputs (include Self-Review Log from Layer 1)
```

## References

- [Inscription Protocol](inscription-protocol.md) — Verification block in inscription.json, Truthbinding rules
- [Prompt Weaving](prompt-weaving.md) — Self-Review Log (Layer 1), 7-section prompt template
- [Verifier Prompt](verifier-prompt.md) — Smart Verifier prompt template with circuit breaker
- [Validator Rules](../../roundtable-circle/references/validator-rules.md) — Confidence scoring, risk classification
