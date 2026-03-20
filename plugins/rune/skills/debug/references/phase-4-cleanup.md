# Phase 4: Cleanup

## Step 4.1 — Shutdown Team

### Teammate Fallback Array

```javascript
// Fallback: known investigators from Phase 2 spawning (static worst-case, safe to send to absent members)
const MAX_HYPOTHESES = 6
allMembers = Array.from({ length: MAX_HYPOTHESES }, (_, i) => `investigator-${i + 1}`)
```

### Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

### Post-Cleanup

```javascript
// Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "debug"`)
```

## Step 4.2 — Report

Present final summary to user:
- Bug description
- Winning hypothesis with confidence
- Fix applied
- Defense-in-depth layers added
- Alternative hypotheses investigated and why they were rejected
