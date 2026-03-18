# Phase 7: Cleanup & Echo Persist

## Teammate Fallback Array

```javascript
// FALLBACK: built-in Ashes + runebinder (safe to send shutdown to absent members)
allMembers = ["forge-warden", "ward-sentinel", "pattern-weaver", "veil-piercer",
  "glyph-scribe", "knowledge-keeper", "codex-oracle", "runebinder",
  "doubt-seer", "elicitation-sage-security-1", "elicitation-sage-security-2",
  "ux-heuristic-reviewer", "ux-flow-validator", "ux-interaction-auditor", "ux-cognitive-walker",
  "design-implementation-reviewer",
  "shard-reviewer-a", "shard-reviewer-b", "shard-reviewer-c", "shard-reviewer-d", "shard-reviewer-e"]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "appraise"`)

// 3.6. Update state file to "completed" (preserve config_dir, owner_pid, session_id)

// 4. Persist P1/P2 patterns to .rune/echoes/reviewer/MEMORY.md (if exists)

// 5. Read and present TOME.md to user

// 6. Auto-mend or interactive prompt based on findings
// Auto-mend triggers when P1 (Critical) or P2 (Important) findings exist:
// - SEC-* (security vulnerabilities)
// - BACK-* with severity P1/P2 (critical backend bugs)
// - VEIL-* with severity P1/P2 (truthbinding violations)
// Does NOT trigger for: P3 (Minor) only, DOC-* (documentation), UXH-* (UX heuristic, non-blocking)
const autoMend = flags['--auto-mend'] || (talisman?.review?.auto_mend === true)
const hasP1P2Findings = /* check TOME.md for P1/P2 severity attributes */
if (hasP1P2Findings && autoMend) {
  Skill("rune:mend", `tmp/reviews/${identifier}/TOME.md`)
} else if (hasP1P2Findings) {
  AskUserQuestion({
    options: ["/rune:mend (Recommended)", "Review TOME manually", "/rune:rest"]
  })
} else {
  log("No P1/P2 findings. Codebase looks clean.")
}
```
