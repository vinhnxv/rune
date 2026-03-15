# Phase 7: Cleanup

Standard 5-component cleanup pattern per CLAUDE.md Agent Team Cleanup (QUAL-012).

## Teammate Fallback Array

```javascript
// FALLBACK: hardcoded list of all known teammate name patterns for this workflow.
// Safe to send shutdown_request to absent members — no-op.
// Must list ALL possible teammates: context agents, verifiers, and fixers.
// Length matches MAX_TODOS (50) to cover worst-case (1 fixer per file).
allMembers = [
  ...Array.from({length: MAX_TODOS}, (_, i) => `context-${i}`),
  ...Array.from({length: MAX_TODOS}, (_, i) => `verifier-${i}`),
  ...Array.from({length: MAX_TODOS}, (_, i) => `fixer-${i}`),
  "quality-fixer"
]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

No skill-specific post-cleanup steps.
