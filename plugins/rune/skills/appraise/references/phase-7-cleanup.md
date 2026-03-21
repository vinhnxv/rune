# Phase 7: Cleanup & Echo Persist

## Teammate Fallback Array

```javascript
// FALLBACK: built-in Ashes + runebinder + all conditional agents (safe to send shutdown to absent members)
// CLEAN-006 FIX: "pattern-weaver" → "pattern-seer" (correct registered name)
allMembers = ["forge-warden", "ward-sentinel", "pattern-seer", "veil-piercer",
  "glyph-scribe", "knowledge-keeper", "codex-oracle", "runebinder",
  "doubt-seer", "elicitation-sage-security-1", "elicitation-sage-security-2",
  // Phase 1.5 UX reviewers (conditional — ux.enabled + frontend files)
  "ux-heuristic-reviewer", "ux-flow-validator", "ux-interaction-auditor", "ux-cognitive-walker",
  // Phase 1.6 Design fidelity reviewer (conditional — design_review.enabled + frontend files)
  "design-implementation-reviewer",
  // Deep-mode agents (--deep: Wave 2 investigators + deep aggregation)
  "rot-seeker", "strand-tracer", "decree-auditor", "fringe-watcher",
  "lore-analyst", "runebinder-deep", "runebinder-merge",
  // Sharding mode agents
  "cross-shard-sentinel",
  "shard-reviewer-a", "shard-reviewer-b", "shard-reviewer-c", "shard-reviewer-d", "shard-reviewer-e",
  // Custom Ashes from talisman.yml — hardcoded fallback (safe to send to absent members)
  "team-lifecycle-reviewer", "agent-spawn-reviewer",
  "dead-prompt-detector", "cleanup-completeness-reviewer", "phantom-warden"]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "appraise"`)

// 3.6. Update state file to "completed" (preserve config_dir, owner_pid, session_id)

// 4. Persist P1/P2 patterns to .rune/echoes/reviewer/MEMORY.md
// Extract recurring P1/P2 patterns from TOME and persist as echo entry
const tome = Read(`tmp/reviews/${identifier}/TOME.md`)
const p1Findings = extractFindings(tome, "P1")
const p2Findings = extractFindings(tome, "P2")

// Only persist if significant findings exist (>= 2 P1/P2)
if (p1Findings.length + p2Findings.length >= 2) {
  const patterns = [...p1Findings, ...p2Findings]
    .map(f => `- [${f.prefix}] ${f.title}: ${f.summary}`)
    .slice(0, 5)  // Max 5 patterns per review
    .join("\\n")

  const echoLib = `\${CLAUDE_PLUGIN_ROOT}/scripts/lib/echo-append.sh`
  Bash(`source "${echoLib}" && rune_echo_append \
    --role reviewer --layer inscribed \
    --source "rune:appraise ${identifier}" \
    --title "Review patterns: ${scope}" \
    --content "${patterns}" \
    --confidence MEDIUM \
    --tags "review,patterns,${scopeSlug}"`)
}

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
