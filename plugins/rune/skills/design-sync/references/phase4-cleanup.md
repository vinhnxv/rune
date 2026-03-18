# Phase 4: Cleanup

Standard 5-component team cleanup for design-sync workflow.

## Teammate Fallback Array

```javascript
// Fallback: known workers across all design-sync phases (max counts from talisman defaults)
// Phase 1 (extraction): design-syncer-1, design-syncer-2
// Phase 2 (implementation): rune-smith-1, rune-smith-2, rune-smith-3
// Phase 3 (iteration): design-iter-1, design-iter-2, design-reviewer-1
allMembers = ["design-syncer-1", "design-syncer-2",
  "rune-smith-1", "rune-smith-2", "rune-smith-3",
  "design-iter-1", "design-iter-2", "design-reviewer-1"]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// Step 1: Generate completion report (run before team shutdown)
Write("{workDir}/report.md", completionReport)

// Step 2: Persist echoes (run before team shutdown)
// Write design patterns learned to .rune/echoes/

// Step 5: Update state
updateState({ status: "completed", phase: "cleanup", fidelity_score: overallScore })

// Step 6: Report to user
"Design sync complete. Fidelity: {score}/100. Report: {workDir}/report.md"
```
