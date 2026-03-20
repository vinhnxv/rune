# Phase 6: Cleanup & Present

Standard 5-component team cleanup with devise-specific member discovery fallback.

## Teammate Fallback Array

```javascript
// FALLBACK: known teammates across all devise phases (some are conditional — safe to send shutdown to absent members)
allMembers = [
  // Phase 0: Brainstorm (advisors + sages — normally shutdown mid-pipeline, listed here as safety net)
  "user-advocate", "tech-realist", "devils-advocate",
  "elicitation-sage-1", "elicitation-sage-2", "elicitation-sage-3",
  "design-inventory-agent", "design-pipeline-agent",
  // Phase 0.3: UX Research (conditional — ux.enabled)
  "ux-pattern-analyzer",
  // Phase 1A: Local Research
  "repo-surveyor", "echo-reader", "git-miner",
  "wiring-cartographer", "activation-pathfinder",
  // Phase 1C: External Research (conditional)
  "practice-seeker", "lore-scholar", "codex-researcher",
  // Phase 1C.5: Research Verification (conditional)
  "research-verifier",
  // Phase 1D: Spec Validation
  "flow-seer",
  // Phase 1.8: Solution Arena (conditional)
  "devils-advocate", "innovation-scout", "codex-arena-judge",
  // Phase 2.3: Predictive Goldmask (conditional, 2-8 agents)
  "devise-lore", "devise-wisdom", "devise-business", "devise-data", "devise-api", "devise-coordinator",
  // Phase 4A: Scroll Review
  "scroll-reviewer",
  // Phase 4C: Technical Review (conditional)
  "decree-arbiter", "knowledge-keeper", "veil-piercer-plan",
  "horizon-sage", "evidence-verifier", "state-weaver", "doubt-seer", "codex-plan-reviewer",
  "elicitation-sage-review-1", "elicitation-sage-review-2", "elicitation-sage-review-3",
  // Phase 4D: Grounding Gate (ALWAYS — even with --quick)
  "grounding-evidence-verifier", "grounding-assumption-slayer",
  // Phase 3: Forge Gaze agents (conditional — skipped with --quick or --no-forge)
  "ward-sentinel", "ember-oracle", "rune-architect", "flaw-hunter", "pattern-seer",
  "simplicity-warden", "mimic-detector", "void-analyzer", "wraith-finder", "phantom-checker",
  "type-warden", "trial-oracle", "depth-seer", "blight-seer", "forge-keeper", "tide-watcher",
  "refactor-guardian", "reference-validator", "reality-arbiter", "assumption-slayer", "entropy-prophet",
  "elicitation-sage-forge-1", "elicitation-sage-forge-2", "elicitation-sage-forge-3",
  "elicitation-sage-forge-4", "elicitation-sage-forge-5", "elicitation-sage-forge-6"
]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// CRITICAL: Validate timestamp (/^[a-zA-Z0-9_-]+$/) before rm -rf — path traversal guard
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid plan identifier")
if (timestamp.includes('..')) throw new Error('Path traversal detected')

// 3. Mark state file as completed AFTER team cleanup (deactivates ATE-1 enforcement)
// FIX: Moved after TeamDelete — previously at step 2.5, which caused downstream safety nets
// (CDX-7 detect-workflow-complete.sh, STOP-001 on-session-stop.sh) to skip team cleanup
// when they saw status="completed" even though TeamDelete had failed.
try {
  const stateFile = `tmp/.rune-plan-${timestamp}.json`
  const state = JSON.parse(Read(stateFile))
  Write(stateFile, { ...state, status: "completed" })
} catch (e) { /* non-blocking — state file may already be cleaned */ }

// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "devise"`)

// 4. Present plan to user
Read("plans/YYYY-MM-DD-{type}-{feature-name}-plan.md")
```
