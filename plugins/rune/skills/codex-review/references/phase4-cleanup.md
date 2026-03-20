# Phase 4: Cleanup

Standard 5-component team cleanup for codex-review.

## Teammate Fallback Array

```javascript
// FALLBACK: all possible Claude + Codex agents (safe to send shutdown to absent members)
allMembers = ["claude-security-reviewer", "claude-bug-hunter", "claude-quality-analyzer",
  "claude-dead-code-finder", "claude-performance-analyzer",
  "codex-security", "codex-bugs", "codex-quality", "codex-performance"]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// Remove readonly marker (review complete)
Bash(`rm -f tmp/.rune-signals/${teamName}/.readonly-active`)

// Update state file
updateStateFile(identifier, { phase: "completed", status: "completed" })

// Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "codex-review"`)
```
