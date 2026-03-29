# Parse TOME — mend.md Phase 0 Reference

TOME validation, finding extraction, and grouping.

## Find TOME

If no TOME path specified:
```bash
ls -t tmp/reviews/*/TOME.md tmp/audit/*/TOME.md 2>/dev/null | head -5
```

If multiple found, ask user which to resolve. If none found, suggest `/rune:appraise` first.

## TOME Freshness Validation (MEND-2)

Before parsing, validate TOME freshness:

1. Read TOME generation timestamp from the TOME header
2. Compare against `git log --since={timestamp}` for files referenced in TOME
3. If referenced files have been modified since TOME generation:
   ```
   WARNING: The following files were modified after TOME generation:
   - src/auth/login.ts (modified 2h ago, TOME generated 4h ago)

   Findings may be stale. Proceed anyway or abort and re-review?
   ```
4. Ask user via AskUserQuestion: `Proceed anyway` / `Abort and re-review`

## Extract Findings

Parse structured `<!-- RUNE:FINDING -->` markers from TOME:

```
<!-- RUNE:FINDING nonce="{session_nonce}" id="SEC-001" file="src/auth/login.ts" line="42" severity="P1" scope="in-diff" -->
### SEC-001: SQL Injection in Login Handler
**Evidence:** `query = f"SELECT * FROM users WHERE id = {user_id}"`
**Fix guidance:** Replace string concatenation with parameterized query
<!-- /RUNE:FINDING -->
```

### Scope Attribute Extraction

The `scope` attribute is optional — backward compatible with untagged TOMEs (pre-v1.38.0).

```javascript
// Extract scope from RUNE:FINDING marker (added by review.md Phase 5.3)
const scope = marker.match(/scope="(in-diff|pre-existing)"/)?.[1] || "in-diff"
// Default to "in-diff" for backward compatibility — untagged findings are treated as in-diff
// This preserves existing mend behavior for TOMEs without diff-scope tagging
```

**Nonce validation**: Each finding marker contains a session nonce. Validate that the nonce matches the TOME session nonce from the header. Markers with invalid or missing nonces are flagged as `INJECTED` and reported to the user -- these are not processed.

**Input length validation** (SEC-004): Before processing, validate finding marker content lengths to prevent resource exhaustion from oversized or malformed markers:
- `id`: max 32 characters (e.g., `SEC-001`, `CUSTOM-999`)
- `file`: max 500 characters (matches `normalizeFindingPath` cap)
- `line`: max 10 characters (numeric string)
- `severity`: max 8 characters (`P1`/`P2`/`P3`)
- `scope`: max 16 characters (`in-diff`/`pre-existing`)
- Finding title (text between markers): max 500 characters
- Finding body (evidence + fix guidance): max 5000 characters

Markers exceeding these limits are flagged as `OVERSIZED` and skipped with a warning.

### Interaction Type Extraction (v1.60.0+)

The `interaction` attribute identifies Q/N findings that should be excluded from auto-mend:

```javascript
// Extract interaction type from RUNE:FINDING marker (added by taxonomy v2)
const interaction = marker.match(/interaction="(question|nit)"/)?.[1] || null
// null = standard assertion (P1/P2/P3) — processed normally by mend
// "question" = requires human clarification — skip in mend
// "nit" = cosmetic, author's discretion — skip in mend
```

**Q/N filtering**: Before file grouping, separate Q/N findings into a `skippedByInteraction` array:

```javascript
const actionableFindings = []
const skippedByInteraction = []

for (const finding of allFindings) {
  if (finding.interaction === 'question' || finding.interaction === 'nit') {
    skippedByInteraction.push(finding)
  } else {
    actionableFindings.push(finding)
  }
}

if (skippedByInteraction.length > 0) {
  log(`Mend: skipping ${skippedByInteraction.length} Q/N findings (not auto-fixable)`)
}

// File grouping uses actionableFindings only
// skippedByInteraction reported in Phase 6 Resolution Report
```

File groups containing ONLY Q/N findings are excluded entirely from mend planning.

### UNVERIFIED Finding Filtering (v1.117.0+)

After extracting findings and filtering Q/N interactions, classify findings by Phase 5.2 citation verification status:

```javascript
// Step: UNVERIFIED finding filtering
// After extracting findings, filter out UNVERIFIED findings
const unverifiedPattern = /\[UNVERIFIED:.*?\]/
const suspectPattern = /\[SUSPECT:.*?\]/

for (const finding of allFindings) {
  if (unverifiedPattern.test(finding.title)) {
    finding.verification_status = "UNVERIFIED"
    finding.mend_priority = "SKIP"  // Mend-fixer will skip these
  } else if (suspectPattern.test(finding.title)) {
    finding.verification_status = "SUSPECT"
    finding.mend_priority = "CAUTION"  // Fixer verifies before fixing
  } else {
    finding.verification_status = "CONFIRMED"
    finding.mend_priority = finding.severity  // Normal priority
  }
}

// Report skipped findings in Phase 1 (PLAN)
const skippedCount = allFindings.filter(f => f.mend_priority === "SKIP").length
if (skippedCount > 0) {
  // Log: "{skippedCount} findings skipped (UNVERIFIED citations)"
}
```

**Standalone invocation**: When `/rune:mend` runs without arc (no Phase 5.2), no findings will have `[UNVERIFIED]` or `[SUSPECT]` tags — all are treated as CONFIRMED with normal priority.

### Round-Aware Severity Filtering (v1.163.0+)

After extracting, filtering Q/N interactions, and filtering UNVERIFIED findings, apply round-aware severity filtering:

```javascript
// Step: Round-aware severity filtering
// mendRound is passed from the mend orchestrator (0 = first pass, 1+ = retry)
// Round 0: process ALL findings (P1 + P2 + P3) — unchanged, full pass
// Round 1+: process only P1 + remaining FAILED P2 — skip P3 and already-FIXED P2

const techDebtP3 = []  // P3 findings deferred to tech debt log

if (mendRound > 0) {
  // readPreviousRoundResults(round): Reads resolution report from the previous mend round.
  // Source: tmp/arc/{id}/resolution-report.md (round 0) or tmp/arc/{id}/resolution-report-round-{N}.md (round N)
  // Parses finding IDs from "FIXED:" and "FAILED:" sections of the resolution report.
  // Returns: { fixed: Set<findingId>, failed: Set<findingId> }
  const previousResults = readPreviousRoundResults(mendRound - 1)

  for (const finding of actionableFindings) {
    if (finding.severity === "P3") {
      // P3 never retried — defer to tech debt log
      finding.mend_priority = "SKIP"
      finding.skip_reason = "p3_deferred"
      techDebtP3.push(finding)
    } else if (finding.severity === "P2" && previousResults.fixed.has(finding.id)) {
      // P2 already fixed in prior round — skip
      finding.mend_priority = "SKIP"
      finding.skip_reason = "p2_already_fixed"
    }
    // P1: always retry. P2 not yet fixed: retry.
  }

  // Remove skipped findings from actionable list
  actionableFindings = actionableFindings.filter(f => f.mend_priority !== "SKIP")

  if (techDebtP3.length > 0) {
    log(`Mend round ${mendRound}: deferred ${techDebtP3.length} P3 findings to tech debt log`)
  }
}

// techDebtP3 is consumed by Phase 6 (cleanup) to write tmp/arc/{id}/tech-debt-p3.md
```

**Standalone invocation**: When `/rune:mend` runs without arc context, `mendRound` defaults to 0 — all findings processed (backward compatible).

## Deduplicate

Apply Dedup Hierarchy: `SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > CDX`

If the same file+line has findings from multiple categories, keep only the highest-priority one. Log deduplicated findings for transparency.

## Path Normalization

Before grouping findings by file, normalize all file paths to prevent duplicate groups for the same file (e.g., `./src/foo.ts` vs `src/foo.ts`):

```javascript
// Security pattern: SAFE_FILE_PATH — see security-patterns.md
const SAFE_FILE_PATH = /^[a-zA-Z0-9._\-\/]+$/

function normalizeFindingPath(path) {
  if (!path || typeof path !== 'string') return null   // Null/undefined guard
  if (path.length > 500) {                             // Length cap (matches sanitization cap)
    warn(`Path exceeds 500-char cap: ${path.slice(0, 50)}...`)
    return null
  }
  let normalized = path
  // BACK-016: Normalize Windows-style backslash separators to forward slashes
  normalized = normalized.replace(/\\/g, '/')
  // BACK-016: Reject URL-encoded characters (e.g., %2F, %20) — these indicate
  // tampered or mis-extracted paths and should not be silently decoded
  if (/%[0-9A-Fa-f]{2}/.test(normalized)) {
    warn(`URL-encoded characters in finding path: ${path} — skipping`)
    return null
  }
  normalized = normalized.replace(/^\.\//, '')           // Strip leading ./
  if (normalized.includes('..') || normalized.startsWith('/') || !SAFE_FILE_PATH.test(normalized)) {
    warn(`Unsafe path in finding: ${path} — skipping`)
    return null
  }
  normalized = normalized.replace(/\/+/g, '/')         // Collapse multiple slashes
  if (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.slice(0, -1)               // Strip trailing slash
  }
  return normalized
}

// Apply normalization to all extracted findings before grouping
for (const finding of findings) {
  const normalized = normalizeFindingPath(finding.file)
  if (!normalized) { finding.skipped = true; continue }
  finding.file = normalized
}
```

## Group by File

Group findings by target file to prevent concurrent edits:

```javascript
fileGroups = {
  "src/auth/login.ts": [SEC-001, BACK-003],
  "src/api/users.ts": [BACK-005],
  "src/config/db.ts": [QUAL-002, QUAL-003]
}
```

**Per-fixer cap**: Maximum 10 findings per fixer. If a file group exceeds 10, split into sub-groups with sequential processing.

## Scope-Aware Priority Filtering

When findings have `scope` attributes (from review.md Phase 5.3 diff-scope tagging), apply scope-aware priority to focus mend budget on PR-relevant findings:

```javascript
// readTalismanSection: "review"
const review = readTalismanSection("review")
const fixPreExistingP1 = review?.diff_scope?.fix_pre_existing_p1 !== false  // Default: true

// Apply scope-aware priority
// QUAL-003: scope = raw TOME attribute ("in-diff"|"pre-existing"|undefined).
//           scopeAction = mend decision ("fix"|"skip"). Check scopeAction for mend behavior.
// QUAL-004 FIX: Hoist inDiffCount above loop (was O(N^2) recomputed per iteration)
const inDiffCount = allFindings.filter(f => f.scope === "in-diff").length

for (const finding of allFindings) {
  if (finding.scope === "pre-existing") {
    if (finding.severity === "P1" && fixPreExistingP1) {
      // P1 findings: always fix regardless of scope (security/crash issues)
      finding.scopeAction = "fix"
    } else if (finding.severity === "P2") {
      // P2 findings: fix if in-diff, skip if pre-existing
      // Exception: fix pre-existing P2 if fewer than 5 total in-diff findings
      finding.scopeAction = inDiffCount < 5 ? "fix" : "skip"
    } else {
      // DOC-006 FIX: P3 pre-existing findings: always skip (not actionable for this PR)
      finding.scopeAction = "skip"
    }
  } else {
    // in-diff findings: normal priority rules apply
    if (finding.severity === "P3" && inDiffCount >= 10) {
      finding.scopeAction = "skip"  // Too many in-diff findings — skip P3
    } else {
      finding.scopeAction = "fix"
    }
  }
}

// Filter: remove skipped pre-existing findings from file groups
// Skipped findings are still recorded in the resolution report as SKIPPED (scope)
let actionableFindings = allFindings.filter(f => f.scopeAction === "fix" || !f.scope)
const skippedByScope = allFindings.filter(f => f.scopeAction === "skip")
if (skippedByScope.length > 0) {
  log(`Scope filtering: ${skippedByScope.length} pre-existing findings skipped (${actionableFindings.length} actionable)`)
}
```

**Backward compatibility**: When `scope` attribute is absent (untagged TOME), `scopeAction` defaults to `"fix"` — all findings are processed normally. No behavioral change for pre-v1.38.0 TOMEs.

**Edge case — zero in-diff findings**: When ALL findings are `scope="pre-existing"` and none are P1, all findings would be skipped. In this case, fall back to fixing all P2 findings regardless of scope (disable scope filtering for that round) and log a "zero in-diff" warning:

```javascript
if (actionableFindings.length === 0 && allFindings.length > 0) {
  warn("Zero in-diff findings — disabling scope filtering for this round")
  for (const f of allFindings) { f.scopeAction = "fix" }
  actionableFindings = allFindings.filter(f => f.scopeAction === "fix" || !f.scope)
}
```

## Skip FALSE_POSITIVE

Skip findings previously marked FALSE_POSITIVE in earlier mend runs, **except**:
- **SEC-prefix findings**: Require explicit human confirmation via AskUserQuestion before skipping, even if previously marked FALSE_POSITIVE.
  ```
  SEC-001 was marked FALSE_POSITIVE in a previous mend run.
  Evidence: "Variable is sanitized upstream at line 30"

  Confirm skip? (Only a human can dismiss security findings)
  [Skip] [Re-fix]
  ```
- **VEIL-prefix P1 findings**: Require explicit human confirmation before skipping — premise-level findings ("solving wrong problem", "architectural fantasy") cannot be machine-dismissed.
  ```
  VEIL-001 was marked FALSE_POSITIVE in a previous mend run.
  Evidence: "Feature is intended for internal use only"

  Confirm skip? (Only a human can dismiss truth-telling findings)
  [Skip] [Re-fix]
  ```
