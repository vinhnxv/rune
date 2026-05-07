# TOME Aggregation — Phase 5+6 Reference

This reference covers Phase 4.5 (Doubt Seer), Phase 5 (Runebinder aggregation), Phase 5.3 (Diff-Scope Tagging), Phase 5.5 (Cross-Model Verification), and Phase 6 (Truthsight verification) of `/rune:appraise`.

## Phase 4.5: Doubt Seer (Conditional)

After Phase 4 Monitor completes, optionally spawn the Doubt Seer to cross-examine Ash findings. See `roundtable-circle` SKILL.md Phase 4.5 for the full specification.

```javascript
// readTalismanSection: "gates"
const doubtConfig = readTalismanSection("gates")?.doubt_seer
const doubtEnabled = doubtConfig?.enabled === true  // strict opt-in (default: false)
const doubtWorkflows = doubtConfig?.workflows ?? ["review", "audit"]

if (doubtEnabled && doubtWorkflows.includes("review")) {
  // Count P1+P2 findings across Ash output files
  let totalFindings = 0
  for (const ash of selectedAsh) {
    const ashPath = `tmp/reviews/${identifier}/${ash}.md`
    if (exists(ashPath)) {
      const content = Read(ashPath)
      totalFindings += (content.match(/severity="P1"/g) || []).length
      totalFindings += (content.match(/severity="P2"/g) || []).length
    }
  }

  if (totalFindings > 0) {
    // Increment .expected signal count for doubt-seer
    const signalDir = `tmp/.rune-signals/rune-review-${identifier}`
    if (exists(`${signalDir}/.expected`)) {
      const expected = parseInt(Read(`${signalDir}/.expected`), 10)
      Write(`${signalDir}/.expected`, String(expected + 1))
    }

    // Create task and spawn doubt-seer
    TaskCreate({
      subject: "Cross-examine findings as doubt-seer",
      description: `Challenge P1/P2 findings. Output: tmp/reviews/${identifier}/doubt-seer.md`,
      activeForm: "Doubt seer cross-examining..."
    })

    Agent({
      team_name: `rune-review-${identifier}`,
      name: "doubt-seer",
      subagent_type: "general-purpose",
      prompt: /* Load from agents/review/doubt-seer.md
                 Substitute: {output_dir}, {inscription_path}, {timestamp} */,
      run_in_background: true
    })

    // Poll for doubt-seer completion (5-min timeout)
    const DOUBT_TIMEOUT = 300_000  // 5 minutes
    const DOUBT_POLL = 30_000      // 30 seconds
    const maxPoll = Math.ceil(DOUBT_TIMEOUT / DOUBT_POLL)
    for (let i = 0; i < maxPoll; i++) {
      const tasks = TaskList()
      const doubtTask = tasks.find(t => t.subject.includes("doubt-seer"))
      if (doubtTask?.status === "completed") break
      if (i < maxPoll - 1) Bash("sleep 30", { run_in_background: true })
    }

    // Check if doubt-seer completed or timed out
    const doubtOutput = `tmp/reviews/${identifier}/doubt-seer.md`
    if (!exists(doubtOutput)) {
      Write(doubtOutput, "[DOUBT SEER: TIMEOUT — partial results preserved]\n")
      warn("Doubt seer timed out — proceeding with partial results")
    }

    // Parse verdict if output exists
    const doubtContent = Read(doubtOutput)
    if (/VERDICT:\s*BLOCK/i.test(doubtContent) && doubtConfig?.block_on_unproven === true) {
      warn("Doubt seer VERDICT: BLOCK — unproven P1 findings detected")
      // Set workflow_blocked flag for downstream handling
    }
  } else {
    log("[DOUBT SEER: No findings to challenge - skipped]")
  }
}
// Proceed to Phase 5 (Aggregate)
```

## Phase 5: Aggregate (Runebinder)

After all tasks complete (or timeout):

```javascript
Agent({
  team_name: "rune-review-{identifier}",
  name: "runebinder",
  subagent_type: "general-purpose",
  prompt: `Read all findings from tmp/reviews/{identifier}/.
    Deduplicate using hierarchy from settings.dedup_hierarchy (default: SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > CDX).
    Include custom Ash outputs in dedup — use their finding_prefix from config.
    Write unified summary to tmp/reviews/{identifier}/TOME.md.
    Use the TOME format from ../../../agents/utility/runebinder.md.
    Every finding MUST be wrapped in <!-- RUNE:FINDING nonce="{session_nonce}" ... --> markers.
    The session_nonce is from inscription.json. Without these markers, /rune:mend cannot parse findings.
    See roundtable-circle/references/dedup-runes.md for dedup algorithm.`
})
```

### Finding Prefixes

Each Ash produces findings with a specific prefix for deduplication and categorization:

| Prefix | Ash Role | Category |
|--------|----------|----------|
| `SEC` | Ward Sentinel | Security vulnerabilities |
| `BACK` | Forge Warden | Backend code quality |
| `FRONT` | Glyph Scribe | Frontend code quality |
| `VEIL` | Veil Piercer | Truthbinding/premise validation |
| `DOC` | Knowledge Keeper | Documentation issues |
| `QUAL` | Pattern Weaver | Code quality patterns |
| `DOUBT` | Doubt Seer | Meta-findings (exempt from dedup) |
| `UXH` | UX Heuristic Reviewer | UX heuristics (non-blocking) |
| `UXF` | UX Flow Validator | Flow validation (non-blocking) |
| `UXI` | UX Interaction Auditor | Interaction issues (non-blocking) |
| `UXC` | UX Cognitive Walker | Cognitive walkthrough (non-blocking) |

### Finding Wrap Format

Every finding MUST be wrapped in `<!-- RUNE:FINDING ... -->` markers for `/rune:mend` parsing:

```html
<!-- RUNE:FINDING nonce="abc123" id="SEC-001" file="src/auth.py" line="42" severity="P1" -->
## SEC-001: SQL Injection Vulnerability

The `query` parameter is directly interpolated into the SQL string...
<!-- /RUNE:FINDING id="SEC-001" -->
```

**Required attributes:**
- `nonce` — Session nonce from inscription.json (prevents cross-session injection)
- `id` — Unique finding identifier (e.g., `SEC-001`)
- `file` — File path relative to project root
- `line` — Line number (integer)
- `severity` — `P1` (Critical), `P2` (Important), or `P3` (Minor)

### Zero-Finding Warning

After Runebinder produces TOME.md, check for suspiciously empty Ash outputs:

```javascript
// For each Ash that reviewed >15 files but produced 0 findings: flag in TOME
// selectedAsh is string[] (ash names), not objects — use name directly and get file count from inscription
const inscription = JSON.parse(Read(`tmp/reviews/${identifier}/inscription.json`))
for (const ashName of selectedAsh) {
  const ashOutput = Read(`tmp/reviews/${identifier}/${ashName}.md`)
  const findingCount = (ashOutput.match(/<!-- RUNE:FINDING/g) || []).length
  const ashAssignment = inscription.assignments?.find(a => a.ash === ashName)
  const fileCount = ashAssignment?.files?.length || 0

  if (fileCount > 15 && findingCount === 0) {
    warn(`${ashName} reviewed ${fileCount} files with 0 findings — verify review thoroughness`)
    // Runebinder appends a NOTE (not a finding) to TOME.md:
    // "NOTE: {ashName} reviewed {fileCount} files and reported no findings.
    //  This may indicate a thorough codebase or an incomplete review."
  }
}
```

This is a transparency flag, not a hard minimum. Zero findings on a small changeset is normal. Zero findings on 20+ files warrants a second look.

## Phase 5.3: Diff-Scope Tagging (Orchestrator-Only)

Tags each RUNE:FINDING in the TOME with `scope="in-diff"` or `scope="pre-existing"` based on diff ranges generated in Phase 0. Runs after aggregation.

**Team**: None (orchestrator-only)
**Input**: `tmp/reviews/{identifier}/TOME.md`, `tmp/reviews/{identifier}/inscription.json` (diff_scope field)
**Output**: Modified `tmp/reviews/{identifier}/TOME.md` with scope attributes injected

See `rune-orchestration/references/diff-scope.md` "Scope Tagging (Phase 5.3)" for the full algorithm.

```javascript
// QUAL-001 FIX: Delegate to diff-scope.md canonical algorithm instead of reimplementing inline.
// See rune-orchestration/references/diff-scope.md "Scope Tagging (Phase 5.3)" for full algorithm
// (STEP 1-8: parse markers, validate attributes, tag scope, strip+inject, validate count, log summary).
const inscription = JSON.parse(Read(`tmp/reviews/${identifier}/inscription.json`))
const diffScope = inscription.diff_scope

if (diffScope?.enabled && diffScope?.ranges) {
  const taggedTome = scopeTagTome(identifier, diffScope)  // diff-scope.md STEP 1-8
  // taggedTome is null on validation failure (rollback to original TOME)
} else {
  log("Diff-scope tagging skipped: diff_scope not enabled or no ranges")
}
```


## Executive Summary

Brief overview of the review scope, key findings, and recommendations.
Generated by Runebinder after aggregating all Ash outputs.

## P1 Critical Findings

High-severity issues requiring immediate attention (security vulnerabilities,
data loss risks, critical bugs).

## P2 Important Findings

Medium-severity issues (bugs, performance problems, code quality concerns).

## P3 Minor Findings

Low-severity issues (style, suggestions, minor improvements).

## Per-File Summary

For each reviewed file, a summary of findings and their severities.
Format: `file:line` → finding ID → severity → brief description.

## Aggregation Metadata

- Total findings per severity
- Coverage statistics
- Ash completion status
- Verification status (if Phase 5.5 ran)
```

### Truthsight Verification Layers

1. **Layer 0**: Lead runs grep-based inline checks (file paths exist, line numbers valid)
2. **Layer 2**: Summon Truthsight Verifier for P1 findings (see `rune-orchestration/references/verifier-prompt.md`)

**For P1 findings specifically:**
- Layer 0: Fast file existence and line number validation
- Layer 2: Deep verification by a dedicated verifier agent that re-reads the actual code and confirms the finding is valid

3. Flag any HALLUCINATED findings (file doesn't exist or code doesn't match)

### Finding Status After Verification

| Status | Meaning | TOME Inclusion |
|--------|---------|----------------|
| **CONFIRMED** | Code verified, finding is valid | Yes |
| **HALLUCINATED** | File does not exist | No (removed) |
| **UNVERIFIED** | Code at line doesn't match description | No (removed) |
