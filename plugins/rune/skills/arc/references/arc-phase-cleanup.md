# TEAM-002-IGNORE: Cleanup phase — Agent() refs are for shutdown/cleanup, not work spawning
# Post-Phase Cleanup — Full Algorithm

Guaranteed team cleanup after every delegated arc phase completes. Complements `prePhaseCleanup()` (before) with a trailing-edge guarantee (after). Together they form a before+after bracket around every phase.

**Inputs**: checkpoint object, phaseName (string)
**Outputs**: cleaned teams/tasks directories, SDK state cleared
**Error handling**: Non-blocking — try/catch around all operations, warn on failure, never halt pipeline
**Consumers**: SKILL.md (Phase stubs — called after checkpoint update for each delegated phase)

> **Design**: `prePhaseCleanup` handles SDK leadership state clearing (Strategy 1-4).
> `postPhaseCleanup` handles teammate/filesystem cleanup with prefix scan.
> `prePhaseCleanup` runs BEFORE the next phase; `postPhaseCleanup` runs AFTER the current phase.
> If arc crashes mid-phase, `postPhaseCleanup` is skipped — CDX-7 preflight scan at next arc run catches crash orphans.

## PHASE_PREFIX_MAP

Maps each delegated phase to its expected team name prefixes. Used by `postPhaseCleanup()` Step 2 for prefix-based orphan scanning.

**IMPORTANT**: New delegated phases MUST add their prefix here, or orphans won't be caught by postPhaseCleanup. Keep in sync with `ARC_TEAM_PREFIXES` in `arc-preflight.md`.

**DECREE-003 Validation — Pre-flight sync check**: Before arc execution, the preflight scan validates PHASE_PREFIX_MAP is synchronized with actual TeamCreate calls in the codebase. The validation script (`scripts/audit-agent-registry.sh`) cross-references:
1. All `TeamCreate({ team_name: "prefix-..." })` patterns in SKILL.md files
2. All `Agent({ team_name: "...", name: "prefix-..." })` spawn patterns
3. Expected prefixes in PHASE_PREFIX_MAP

If a mismatch is detected, the preflight warns but proceeds (non-blocking). Add new phases to PHASE_PREFIX_MAP when spawning new team types.

Multi-prefix entries cover both arc-owned and sub-command-owned team variants (EC-7, rune-architect #2: audited against actual TeamCreate calls per phase).

```javascript
const PHASE_PREFIX_MAP = {
  forge:                  ["rune-forge-", "arc-forge-"],        // /rune:forge + arc variant
  plan_review:            ["arc-plan-review-", "arc-plan-inspect-"],  // Layer 1 + Layer 2 inspect (conditional)
  design_extraction:      ["arc-design-"],                       // Phase 3 (conditional — design_sync)
  work:                   ["rune-work-"],
  storybook_verification: ["arc-storybook-"],                   // Phase 3.3 (conditional — storybook.enabled)
  design_verification:    ["arc-design-verify-"],               // Phase 5.2 (conditional — VSM fidelity check)
  ux_verification:        ["arc-ux-"],                           // Phase 5.3 (conditional — ux.enabled + frontend files)
  gap_analysis:           ["rune-inspect-", "arc-inspect-"],    // both prefix variants
  semantic_verification:  ["arc-codex-sv-"],                    // delegated to codex-phase-handler teammate
  task_decomposition:     ["arc-codex-td-"],                    // delegated to codex-phase-handler teammate
  codex_gap_analysis:     ["arc-codex-ga-"],                    // delegated to codex-phase-handler teammate
  test_coverage_critique: ["arc-codex-tc-"],                    // delegated to codex-phase-handler teammate
  release_quality_check:  ["arc-codex-rq-"],                    // delegated to codex-phase-handler teammate
  gap_remediation:        ["arc-gap-fix-"],
  inspect:                ["arc-inspect-full-"],
  inspect_fix:            ["arc-inspect-fix-"],
  goldmask_verification:  ["goldmask-"],
  code_review:            ["rune-review-"],
  mend:                   ["rune-mend-", "arc-sage-"],          // mend sub-command + ephemeral elicitation sage
  design_iteration:       ["arc-design-iter-"],                 // Phase 7.6 (conditional — fidelity < threshold)
  test:                   ["arc-test-"],
  browser_test:           ["arc-browser-test-"],               // Phase 7.7.5 (conditional — frontend + agent-browser)
  browser_test_fix:       ["arc-browser-fix-"],                // Phase 7.7.6 (conditional — browser_test failures)
  verify_browser_test:    [],                                   // Phase 7.7.7 (no team — orchestrator-only convergence check)
  design_prototype:       ["arc-prototype-", "rune-prototype-"],  // Phase 3.2 arc prototype + /rune:design-prototype standalone (conditional — design_sync.enabled)
  deploy_verify:          ["arc-deploy-"],                        // Phase 7.9 (conditional — deployment-relevant files in diff)
  forge_qa:               ["arc-qa-"],                             // QA gate for forge phase (conditional — qa_gates.enabled)
  work_qa:                ["arc-qa-"],                             // QA gate for work phase
  gap_analysis_qa:        ["arc-qa-"],                             // QA gate for gap_analysis phase
  code_review_qa:         ["arc-qa-"],                             // QA gate for code_review phase
  mend_qa:                ["arc-qa-"],                             // QA gate for mend phase
  test_qa:                ["arc-qa-"],                             // QA gate for test phase
  design_verification_qa: ["arc-qa-"],                             // QA gate for design_verification phase
}
// NOTE: 23 delegated phases (9 original + 1 storybook phase + 3 design phases + 1 UX phase + 5 Codex handler phases + 1 design-prototype + 1 deploy-verify + 2 browser test phases). Phases removed in v1.67.0 (audit, audit_mend) are NOT listed.
// Multi-prefix entries: plan_review has Layer 2 inspect team (arc-plan-inspect-), mend has ephemeral sage team (arc-sage-).
// Design phases are conditional — only create teams when design_sync.enabled === true.
// UX verification is conditional — only creates teams when ux.enabled === true + frontend files detected.
// Codex handler phases: delegated to codex-phase-handler teammate (5 phases: 2.8, 4.5, 5.6, 7.8, 8.55). Conditional on Codex availability.
// Orchestrator-only phases (plan_refine, verification,
// goldmask_correlation, verify_mend, ship, merge) do not create teams — no entries needed.
//
```

## postPhaseCleanup(checkpoint, phaseName)

```javascript
// postPhaseCleanup(checkpoint, phaseName): Clean up after a phase completes.
// Runs AFTER every delegated phase. Complements prePhaseCleanup (before) with
// post-phase guarantee (after). Uses prefix-based scan as primary mechanism.
//
// DESIGN: prePhaseCleanup handles SDK leadership state clearing (Strategy 1-4).
// postPhaseCleanup handles teammate/filesystem cleanup with prefix scan.
// Together they form a before+after bracket around every phase.

function postPhaseCleanup(checkpoint, phaseName) {
  try {
    const phaseInfo = checkpoint.phases?.[phaseName]
    if (!phaseInfo) return  // Unknown phase — nothing to clean

    // Step 1: Targeted cleanup if team_name is known
    if (phaseInfo.team_name && typeof phaseInfo.team_name === 'string'
        && /^[a-zA-Z0-9_-]+$/.test(phaseInfo.team_name)) {
      const teamName = phaseInfo.team_name

      // Dynamic member discovery + shutdown
      try {
        const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
        const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
        const members = Array.isArray(teamConfig?.members) ? teamConfig.members : []
        for (const m of members) {
          if (m.name && /^[a-zA-Z0-9_-]+$/.test(m.name)) {
            try { SendMessage({ type: "shutdown_request", recipient: m.name, content: `Phase ${phaseName} complete — cleanup` }) } catch (e) { /* member may already be gone */ }
          }
        }
        if (members.length > 0) Bash(`sleep 20`)  // Grace period — 20s covers slow tool calls
      } catch (e) { /* team config unreadable — proceed to filesystem cleanup */ }

      // SDK state clear + filesystem rm-rf — retry-with-backoff pattern (4 attempts: 0s, 3s, 6s, 10s)
      let phaseCleanupSucceeded = false
      const PHASE_CLEANUP_DELAYS = [0, 3000, 6000, 10000]
      for (let attempt = 0; attempt < PHASE_CLEANUP_DELAYS.length; attempt++) {
        if (attempt > 0) Bash(`sleep ${PHASE_CLEANUP_DELAYS[attempt] / 1000}`)
        try { TeamDelete(); phaseCleanupSucceeded = true; break } catch (e) {
          if (attempt === PHASE_CLEANUP_DELAYS.length - 1) warn(`postPhaseCleanup: TeamDelete failed after ${PHASE_CLEANUP_DELAYS.length} attempts for ${teamName}`)
        }
      }
      // Filesystem fallback — only if TeamDelete never succeeded (QUAL-012)
      if (!phaseCleanupSucceeded) {
        // Process-level kill before filesystem cleanup to prevent zombie processes
        Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
        Bash(`sleep 5`)
        Bash(`for pid in $(pgrep -P $PPID 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -KILL "$pid" 2>/dev/null ;; esac; done`)
        // SEC: teamName validated above with /^[a-zA-Z0-9_-]+$/ — shell injection not possible
        Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && rm -rf "$CHOME/teams/${teamName}/" "$CHOME/tasks/${teamName}/" 2>/dev/null`)
        try { TeamDelete() } catch (e) { /* best effort — clear SDK leadership state */ }
      }
    }

    // Step 2: Prefix-based scan for this phase's expected prefixes
    // Even if team_name was null, scan by prefix to catch orphans
    const prefixes = PHASE_PREFIX_MAP[phaseName] || []
    for (const prefix of prefixes) {
      if (!/^[a-z][a-z-]*-$/.test(prefix)) { warn(`postPhaseCleanup: invalid prefix format: ${prefix} — skipping`); continue }
      const dirs = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && find "$CHOME/teams" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null`).split('\n').filter(Boolean)
      for (const dir of dirs) {
        const orphanName = dir.split('/').pop()
        if (!orphanName || !/^[a-zA-Z0-9_-]+$/.test(orphanName)) continue
        // Cross-session safety: check .session marker before cleaning
        // .session contains session_id (written by stamp-team-session.sh TLC-004)
        // If session_id differs from ours, skip — belongs to another session
        // (EC-1/EC-2: CRITICAL — must not delete concurrent session's teams)
        const sessionCheck = Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && jq -r '.session_id // empty' "$CHOME/teams/${orphanName}/.session" 2>/dev/null`).trim()
        const arcSessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
        if (!sessionCheck || sessionCheck !== arcSessionId) {
          warn(`postPhaseCleanup: Skipping ${orphanName} — no session marker or belongs to another session`)
          continue
        }
        warn(`postPhaseCleanup: Cleaning orphan team ${orphanName} from phase ${phaseName}`)
        // SEC: Atomic symlink guard + rm-rf in single Bash call (closes TOCTOU window)
        // orphanName validated above with /^[a-zA-Z0-9_-]+$/ — shell injection not possible
        // ZSH-FIX: Avoid [[ ! ]] — use positive symlink check with || (history expansion safe)
        Bash(`CHOME="\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" && { [[ -L "$CHOME/teams/${orphanName}" ]] || rm -rf "$CHOME/teams/${orphanName}/" "$CHOME/tasks/${orphanName}/" 2>/dev/null; }`)
      }
    }

    // Step 3: Final SDK state clear (only needed if Step 1 was skipped — team_name was null)
    // EC-3: After Step 2's prefix scan, clear any residual SDK state.
    // EC-9: Redundant with prePhaseCleanup Strategy 1 — intentional defense-in-depth.
    if (!phaseInfo.team_name) {
      try { TeamDelete() } catch (e) { /* expected if no active team */ }
    }

    // Step 4: Clean up signal files from this phase's team
    // Removes team-specific signals and session-owned shutdown signals
    if (phaseInfo.team_name && typeof phaseInfo.team_name === 'string'
        && /^[a-zA-Z0-9_-]+$/.test(phaseInfo.team_name)) {
      Bash(`rm -rf "tmp/.rune-signals/${phaseInfo.team_name}/" 2>/dev/null`)
    }
    // Clean session-owned shutdown signal (Layer 1 defense — written by guard-context-critical.sh)
    const sessionId = "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
    if (sessionId && /^[a-zA-Z0-9_-]+$/.test(sessionId)) {
      Bash(`rm -f "tmp/.rune-shutdown-signal-${sessionId}.json" 2>/dev/null`)
    }

  } catch (e) {
    warn(`postPhaseCleanup(${phaseName}): ${e.message} — proceeding`)
  }
}
```
