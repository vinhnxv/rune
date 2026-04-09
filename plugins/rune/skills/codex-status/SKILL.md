---
name: codex-status
description: |
  Show Codex activity summary for the current or most recent arc run.
  Displays which arc phases ran Codex, outcome per phase, finding counts,
  and simplified verification verdicts.
  Keywords: codex, status, activity, findings, cross-model, results.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

# /rune:codex-status — Codex Activity Summary

Shows a one-screen summary of all Codex activity in the current or most recent arc run.

## Usage

```
/rune:codex-status              # Show latest arc run's Codex activity
/rune:codex-status --arc-id ID  # Show specific arc run's Codex activity
```

## Implementation

### Step 1: Find Arc Checkpoint

```javascript
const args = "$ARGUMENTS".trim()
const arcIdMatch = args.match(/--arc-id\s+(\S+)/)

let checkpointPath = null

if (arcIdMatch) {
  // Specific arc ID requested
  const arcId = arcIdMatch[1]
  if (!/^[a-zA-Z0-9_-]+$/.test(arcId)) {
    output("Invalid arc ID format.")
    return
  }
  checkpointPath = `.rune/arc/${arcId}/checkpoint.json`
} else {
  // Find most recent checkpoint
  const checkpoints = Glob(".rune/arc/*/checkpoint.json")
  if (checkpoints.length === 0) {
    output("No Codex activity found — no arc runs detected in `.rune/arc/`.")
    return
  }
  checkpointPath = checkpoints[0]  // most recent by mtime
}

let checkpoint
try {
  checkpoint = JSON.parse(Read(checkpointPath))
} catch (e) {
  output(`No Codex activity found — checkpoint unreadable at \`${checkpointPath}\`.`)
  return
}
```

### Step 2: Extract Codex Phase Data

```javascript
const arcId = checkpoint.arc_id ?? checkpointPath.match(/arc\/([^/]+)\//)?.[1] ?? "unknown"
const planFile = checkpoint.plan_file ?? "unknown"

// Phase 2.8: Semantic Verification
const sv = checkpoint.phases?.semantic_verification ?? {}
// Phase 5.6: Gap Analysis
const ga = checkpoint.phases?.codex_gap_analysis ?? {}

// Check if any Codex phases ran
if (!sv.status && !ga.status) {
  output(`No Codex activity found in arc run \`${arcId}\`.`)
  return
}
```

### Step 3: Build Summary Table

```javascript
// Simplified verdict labels (AC-3)
function simplifyVerdict(phase) {
  if (phase.status === "skipped") return `⊘ Skipped (${phase.skip_reason ?? "unknown"})`
  if (phase.status !== "completed") return `⏳ ${phase.status ?? "unknown"}`

  // For semantic verification
  if (phase.has_findings === true) return "⚠ Findings detected"
  if (phase.has_findings === false) return "✓ No contradictions"

  // For gap analysis — use codex_needs_remediation as signal
  if (phase.codex_needs_remediation === true) return "⚠ Models disagree — review recommended"
  if (phase.codex_needs_remediation === false && phase.codex_finding_count === 0) return "✓ Both models agree"
  if (phase.codex_needs_remediation === false) return "✓ Both models agree"

  return "✓ Completed"
}

const svVerdict = simplifyVerdict(sv)
const gaVerdict = simplifyVerdict(ga)
const gaFindingCount = ga.codex_finding_count ?? 0
const svFindingCount = sv.has_findings ? "1+" : "0"
```

### Step 4: Read Finding Details (if gap analysis has findings)

```javascript
let findingDetails = ""
if (ga.status === "completed" && gaFindingCount > 0 && ga.artifact) {
  try {
    const gaContent = Read(ga.artifact)
    // Extract [CDX-GAP-NNN] lines
    const findings = gaContent.match(/\[CDX-GAP-\d+\].*/g) ?? []
    if (findings.length > 0) {
      findingDetails = "\n## Finding Details (Phase 5.6)\n" +
        findings.map(f => f.trim()).join("\n") +
        "\n"
    }
  } catch (e) {
    findingDetails = "\n## Finding Details (Phase 5.6)\n" +
      "_Output file not found — may have been cleaned up via /rune:rest._\n"
  }
}
```

### Step 5: Output Summary

```javascript
output(`# Codex Activity Summary

## Arc Run: ${arcId}
Plan: ${planFile}

| Phase | Status | Findings | Verdict |
|-------|--------|----------|---------|
| Semantic Verification (2.8) | ${sv.status ?? "not run"} | ${svFindingCount} | ${svVerdict} |
| Gap Analysis (5.6) | ${ga.status ?? "not run"} | ${gaFindingCount} | ${gaVerdict} |
${findingDetails}
> Full output:
> - Semantic Verification: \`tmp/arc/${arcId}/codex-semantic-verification.md\`
> - Gap Analysis: \`tmp/arc/${arcId}/codex-gap-analysis.md\`
`)
```

## Verdict Labels (AC-3)

| Technical Label | User-Facing Label |
|----------------|-------------------|
| `CROSS-VERIFIED` (both models agree, no issues) | ✓ Both models agree |
| `STANDARD` (only Claude reviewed) | Claude reviewed (Codex unavailable) |
| `DISPUTED` (models disagree) | ⚠ Models disagree — review recommended |
| Findings detected | ⚠ Findings detected |
| No findings | ✓ No contradictions |

## Fail-Forward

- Missing checkpoint → "No Codex activity found"
- Missing output files → "may have been cleaned up"
- Missing phase data → "not run"
- No Codex phases in checkpoint → clear message, not an error
