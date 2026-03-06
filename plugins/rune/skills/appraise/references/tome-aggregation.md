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
      if (i < maxPoll - 1) Bash("sleep 30")
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
    Deduplicate using hierarchy from settings.dedup_hierarchy (default: SEC > BACK > VEIL > DOUBT > DOC > QUAL > FRONT > CDX).
    Include custom Ash outputs and Codex Oracle (CDX prefix) in dedup — use their finding_prefix from config.
    Write unified summary to tmp/reviews/{identifier}/TOME.md.
    Use the TOME format from roundtable-circle/references/ash-prompts/runebinder.md.
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
| `CDX` | Codex Oracle | Cross-model findings (GPT) |
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

Tags each RUNE:FINDING in the TOME with `scope="in-diff"` or `scope="pre-existing"` based on diff ranges generated in Phase 0. Runs after aggregation and BEFORE Cross-Model Verification so Codex findings also get scope attributes.

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

<!-- NOTE: "Phase 5.5" in appraise.md refers to Cross-Model Verification (Codex Oracle).
     Other pipelines use 5.5 for different sub-phases (audit: Truthseer Validator, arc: Gap Analysis). -->

## Phase 5.5: Cross-Model Verification (Codex Oracle)

This phase only runs if Codex Oracle was summoned. It verifies Codex findings against actual source code before they enter the TOME, guarding against cross-model hallucinations.

**Why this is needed:** GPT models can fabricate file paths, invent code snippets, and reference non-existent patterns. Since Codex output is generated by a different model (GPT-5.3-codex), its findings are treated as untrusted until verified by Claude against the actual codebase.

**Note on Step 0 (Diff Relevance):** In review mode, Codex Oracle's Hallucination Guard includes a Step 0 that filters findings about unchanged code as OUT_OF_SCOPE before steps 1-3 run.

```
1. Read Codex Oracle output from tmp/reviews/{identifier}/codex-oracle.md
   - If the file is missing or empty (<100 chars): skip verification, log "Codex Oracle: no output to verify"
   - If Codex Oracle timed out (partial output): verify what is available, note partial status

2. Parse all CDX-prefixed findings from the output

3. For each CDX finding, verify against actual source:

   a. FILE EXISTS CHECK
      - Read the file referenced in the finding
      - If the file does NOT exist:
        → Mark finding as HALLUCINATED (reason: "File does not exist")
        → Do NOT include in TOME

   b. CODE MATCH CHECK
      - Read actual code at the referenced line number (±2 lines for context)
      - Compare the Rune Trace snippet in the finding with the actual code
      - Use fuzzy matching (threshold from talisman.codex.verification.fuzzy_match_threshold, default: 0.7)
      - If the code does NOT match:
        → Mark finding as UNVERIFIED (reason: "Code at referenced line does not match Rune Trace")
        → Do NOT include in TOME

   c. CROSS-ASH CORRELATION
      - Read findings from all other Ash outputs
      - Check if any other Ash flagged an issue in the same file within ±5 lines
      - If a cross-match is found:
        → Mark finding as CONFIRMED (reason: "Cross-validated by Claude Ash")
        → Apply cross-model confidence bonus (talisman.codex.verification.cross_model_bonus, default: +0.15)
      - If no cross-match but file and code verified:
        → Mark finding as CONFIRMED (reason: "Code verified, unique finding from Codex perspective")

4. Rewrite Codex Oracle output with verification annotations:
   - Only CONFIRMED findings are kept
   - HALLUCINATED and UNVERIFIED findings are removed from the output
   - Add verification summary header to the rewritten file

5. Log verification summary:
   Cross-Model Verification:
     Confirmed: {count} ({cross_validated_count} cross-validated with Claude Ash)
     Hallucinated: {count} (removed — fabricated file/code references)
     Unverified: {count} (removed — code mismatch at referenced lines)
```

**Timeout note:** The review pipeline has a 10-minute total timeout (Phase 4). If Codex Oracle produces partial results due to timeout, Phase 5.5 verifies whatever output is available. Partial results are acceptable.

**Performance:** Phase 5.5 is orchestrator-only (no additional teammates). It reads files already in the review scope.

## Phase 6: Verify (Truthsight)

If inscription.json has `verification.enabled: true`:

1. **Layer 0**: Lead runs grep-based inline checks (file paths exist, line numbers valid)
2. **Layer 2**: Summon Truthsight Verifier for P1 findings (see `rune-orchestration/references/verifier-prompt.md`)
3. Flag any HALLUCINATED findings
