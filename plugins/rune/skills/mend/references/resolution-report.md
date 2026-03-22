# Resolution Report — mend.md Phase 6 Reference

Resolution report format, convergence logic, P1 escalation, and Codex verification integration.

## Phase 6: RESOLUTION REPORT

Write `tmp/mend/{id}/resolution-report.md`:

```markdown
# Resolution Report -- rune-mend-{id}
Generated: {timestamp}
TOME: {tome_path}

## Summary
- Total findings: {N}
- Fixed: {X}
- Fixed (cross-file): {XC}
- Consistency fix: {C}
- False positive: {Y}
- Failed: {Z}
- Skipped: {W}
- Questions (awaiting author): {Q}
- Nits (author's discretion): {Nit}

## Fixed Findings
<!-- RESOLVED:SEC-001:FIXED -->
### SEC-001: SQL Injection in Login Handler
**Status**: FIXED
**File**: src/auth/login.ts:42
**Change**: Replaced string concatenation with parameterized query
<!-- /RESOLVED:SEC-001 -->

## False Positives
<!-- RESOLVED:BACK-005:FALSE_POSITIVE -->
### BACK-005: Unused Variable in Config
**Status**: FALSE_POSITIVE
**Evidence**: Variable is used via dynamic import at runtime (line 88)
<!-- /RESOLVED:BACK-005 -->

## Failed Findings
<!-- RESOLVED:QUAL-002:FAILED -->
### QUAL-002: Missing Error Handling
**Status**: FAILED
**Reason**: Ward check failed after implementing fix
<!-- /RESOLVED:QUAL-002 -->

## Skipped Findings
<!-- RESOLVED:DOC-001:SKIPPED -->
### DOC-001: Missing API Documentation
**Status**: SKIPPED
**Reason**: Blocked by SEC-001 (same file, lower priority)
<!-- /RESOLVED:DOC-001 -->

## Consistency Fixes
<!-- RESOLVED:CONSIST-001:CONSISTENCY_FIX -->
### CONSIST-001: version_sync -- README.md
**Status**: CONSISTENCY_FIX
**Source**: .claude-plugin/plugin.json (version: "1.2.0")
**Target**: README.md
**Old value**: 1.1.0, **New value**: 1.2.0
<!-- /RESOLVED:CONSIST-001 -->

## WONTFIX (Deferred)
<!-- RESOLVED:BACK-004:WONTFIX -->
### BACK-004: evaluateReaction call-order contract not enforced
**Status**: WONTFIX
**Severity**: P2
**Reason**: Design choice — acceptable for initial release. Tracked for future improvement.
<!-- /RESOLVED:BACK-004 -->

## Questions (awaiting author clarification)
<!-- RESOLVED:BACK-010:QUESTION -->
### BACK-010: Custom token validator diverges from framework
**Status**: QUESTION
**File**: src/auth/handler.py:45
**Question**: Why was this approach chosen over framework.validate_token()?
**Fallback**: If no response, treating as P3 suggestion to align with convention.
<!-- /RESOLVED:BACK-010 -->

## Nits (author's discretion)
<!-- RESOLVED:QUAL-011:NIT -->
### QUAL-011: Variable naming preference
**Status**: NIT
**File**: src/utils/format.py:12
**Nit**: Variable `x` could be `formatted_output` for clarity.
**Author's call**: Cosmetic only — no functional impact.
<!-- /RESOLVED:QUAL-011 -->
```

## Per-Finding Section Constraint

**CONSTRAINT**: Every finding ID from the TOME MUST have its own `<!-- RESOLVED:ID:STATUS -->` section. Bulk ranges (e.g., "BACK-004-009") are PROHIBITED — they prevent QA verification. If a group of findings share the same disposition, each still gets its own section with a shared justification reference.

**Valid statuses**: `FIXED`, `FALSE_POSITIVE`, `FAILED`, `SKIPPED`, `WONTFIX`, `CONSISTENCY_FIX`, `QUESTION`, `NIT`.

## Convergence Logic

When building the resolution summary, aggregate statuses from fixer SendMessage reports:

1. Collect SEAL lines from all fixer messages: `FIXED:N FAILED:N SKIPPED:N FALSE_POSITIVE:N`
2. Cross-reference with `inscription.json` finding IDs for each fixer
3. For each finding: last reported status wins (FIXED > CONSISTENCY_FIX > FALSE_POSITIVE > WONTFIX > FAILED > SKIPPED > QUESTION > NIT)
4. Cross-file fixes (Phase 5.5) add `FIXED_CROSS_FILE` status
5. Doc-consistency fixes (Phase 5.7) add `CONSISTENCY_FIX` status

## Summary Arithmetic Validation

After writing the resolution report, validate that summary counts match actual RESOLVED marker counts:

```javascript
const VALID_STATUSES = ['FIXED', 'FALSE_POSITIVE', 'FAILED', 'SKIPPED', 'WONTFIX', 'QUESTION', 'NIT', 'CONSISTENCY_FIX']
const sectionCounts = {}
for (const status of VALID_STATUSES) {
  const re = new RegExp(`<!-- RESOLVED:[A-Z]+-\\d+:${status} -->`, 'g')
  sectionCounts[status] = (report.match(re) || []).length
}
const computedTotal = Object.values(sectionCounts).reduce((a, b) => a + b, 0)
if (computedTotal !== tomeFindings.length) {
  warn(`Resolution report count mismatch: ${computedTotal} sections vs ${tomeFindings.length} TOME findings`)
}
```

If there is a mismatch, review the report for missing findings or duplicate entries before finalizing.

## P1 Escalation

If any P1 (crashes, data corruption, security) finding ends in FAILED or SKIPPED:

```
⚠️  P1 Escalation: {N} critical finding(s) remain unresolved.
   FAILED: {ids}
   SKIPPED: {ids}

These require immediate attention before merging.
```

Present escalation prominently in the completion report (before next-steps).

## Phase 5.8: Codex Fix Verification

Cross-model post-fix validation to catch regressions and validate fix quality.

**Preconditions**: Phase 5.7 complete, Codex available, `mend` in `talisman.codex.workflows`, `talisman.codex.mend_verification.enabled !== false`, `.codexignore` present.

**Inputs**: Git diff against `preMendSha` (captured at Phase 2), original TOME findings
**Outputs**: `tmp/mend/{id}/codex-mend-verification.md` with `[CDX-MEND-NNN]` findings

### Finding Verdicts

| Verdict | Meaning | Action |
|---------|---------|--------|
| `GOOD_FIX` | Fix resolves finding correctly | None |
| `WEAK_FIX` | Fix addresses symptom, not root cause | Warn user in resolution report |
| `REGRESSION` | Fix introduces new issue | WARN — flag for human review |
| `CONFLICT` | Two fixes contradict each other | WARN — flag for human review |

### Codex Section in Resolution Report

When Phase 5.8 produces results:

```markdown
## Codex Verification (Cross-Model)
- Regressions: {N}
- Weak fixes: {N}
- Conflicts: {N}
- Good fixes: {N}

{detailed CDX-MEND findings if any REGRESSION or CONFLICT detected}
```

### Edge Cases

| Scenario | Handling |
|----------|----------|
| No fixes applied (all FALSE_POSITIVE/SKIPPED) | Skip Phase 5.8 entirely |
| Ward check failed | Still run Codex verification — may explain WHY ward failed |
| Fix diff > max_diff_size | Truncated via `head -c`, prioritize most recent changes |
| Codex finds regression in P1 fix | Elevate to WARN in resolution report |
| Codex timeout | Proceed without verification, log warning |
| .codexignore missing | Skip verification (required for --full-auto) |

## Completion Report Format

```
Mend complete!

TOME: {tome_path}
Report: tmp/mend/{id}/resolution-report.md

Findings: {total}
  FIXED: {X} ({finding_ids})
  CONSISTENCY_FIX: {C} (doc-consistency drift corrections)
  FALSE_POSITIVE: {Y} (flagged NEEDS_HUMAN_REVIEW)
  FAILED: {Z}
  SKIPPED: {W}

Fixers: {fixer_count}
Ward check: {PASSED | FAILED (bisected)}
Doc-consistency: {PASSED | SKIPPED | CYCLE_DETECTED} ({C} fixes)
Time: {duration}

Next steps:
1. Review resolution report: tmp/mend/{id}/resolution-report.md
2. /rune:appraise -- Re-review to verify fixes
3. git diff -- Inspect changes
4. /rune:rest -- Clean up tmp/ artifacts when done
```
