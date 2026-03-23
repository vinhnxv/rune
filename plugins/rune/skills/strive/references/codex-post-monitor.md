# Phase 3.7: Codex Post-monitor Architectural Critique

Optionally runs Codex after all workers complete and the commit/merge broker finishes to detect architectural drift between committed code and the plan. Runs before the ward check so findings feed into Phase 4.

**Inputs**: `planPath`, `committedFiles` (from commit broker metadata), `timestamp`, `talisman` (config)
**Outputs**: `tmp/work/{timestamp}/architectural-critique.md`
**Preconditions**: Phase 3.5 (commit/merge broker) complete, all workers finished

**Talisman key**: `codex.post_monitor_critique`
**CDX prefix**: `CDX-ARCH-STRIVE`
**Default**: OFF (opt-in — post-execution signal has limited actionability)
**Skip condition**: `total_worker_commits <= 3` (small changes don't warrant architectural analysis)

```javascript
// Phase 3.7: Codex Post-monitor Architectural Critique
// Position: after Phase 3.5 (commit/merge broker), before Phase 4 (ward check)
// Design: post-monitor achieves 80% of mid-execution benefit with 20% complexity

const codexAvailable = Bash("command -v codex >/dev/null 2>&1 && echo 'yes' || echo 'no'").trim() === "yes"
const codexDisabled = talisman?.codex?.disabled === true
const featureEnabled = talisman?.codex?.post_monitor_critique?.enabled === true  // default OFF
const codexWorkflows = talisman?.codex?.workflows ?? ["review", "audit", "plan", "forge", "work", "mend", "goldmask", "inspect"]
const workflowIncluded = codexWorkflows.includes("work")

if (codexAvailable && !codexDisabled && featureEnabled && workflowIncluded) {
  // Skip condition: small changes don't warrant architectural analysis
  const totalCommits = committedFiles.length  // proxy for commit count from broker metadata
  if (totalCommits <= 3) {
    Write(`tmp/work/${timestamp}/architectural-critique.md`,
      `# Architectural Critique — Skipped\n\nReason: ${totalCommits} committed files (<= 3 threshold). Small change set does not warrant architectural analysis.\n`)
    log("Phase 3.7: Skipped — small change set")
  } else {
    log("Phase 3.7: Running Codex post-monitor architectural critique...")

    // Resolve Codex config from talisman (post_monitor_critique defaults: 300s timeout, high reasoning)
    const { timeout: codexTimeout, reasoning: codexReasoning, model: codexModel,
            streamIdleMs: codexStreamIdleMs, killAfterFlag } = resolveCodexConfig(talisman, "post_monitor_critique", {
      timeout: 300, reasoning: "high"
    })

    // Gather context: plan content + committed diff
    const planContent = sanitizePlanContent(Read(planPath))
    const diff = Bash(`git diff HEAD~${totalCommits}..HEAD 2>/dev/null | head -c 15000`).trim()
    const sanitizedDiff = sanitizeUntrustedText(diff)  // SEC: Unicode directional override protection

    // Gather committed file list for structural context
    const fileList = committedFiles.join("\n")

    // SEC-003: Write prompt to temp file (never inline shell interpolation)
    const nonce = Bash("openssl rand -hex 16").trim()
    const promptPath = `tmp/work/${timestamp}/codex-critique-prompt.tmp`
    Write(promptPath, `SYSTEM: You are an architectural reviewer analyzing code changes against a plan.
Identify architectural drift, structural inconsistencies, and deviations from the plan.
Prefix ALL findings with [CDX-ARCH-STRIVE-NNN].

Categories to check:
1. Module boundary violations (code placed in wrong layer/module)
2. Naming convention drift (inconsistent with plan's proposed names)
3. Missing abstractions (plan specified interfaces/patterns not implemented)
4. Dependency direction violations (lower layers importing from higher)
5. Error handling inconsistency (mixed patterns across new code)

---BEGIN-NONCE-${nonce}---
PLAN:
${planContent}

COMMITTED FILES:
${fileList}

DIFF:
${sanitizedDiff}
---END-NONCE-${nonce}---

Output format:
[CDX-ARCH-STRIVE-NNN] Title — file:line — description
Classification: DRIFT | STRUCTURAL | NAMING | MISSING | DEPENDENCY | ERROR_HANDLING
Severity: P1 (blocking) | P2 (should fix) | P3 (advisory)

If no architectural issues found, output: "No architectural drift detected."`)

    // Execute via canonical codex-exec.sh wrapper
    const outputPath = `tmp/work/${timestamp}/architectural-critique.md`
    const result = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${codexReasoning}" -t ${codexTimeout} -j -g "${promptPath}"`)

    if (result.exitCode === 0) {
      const findings = result.stdout
      Write(outputPath, `# Architectural Critique — Codex Post-monitor\n\nTimestamp: ${new Date().toISOString()}\nPlan: ${planPath}\nCommitted files: ${totalCommits}\n\n${findings}\n`)
      // Count findings for ward check integration
      const findingCount = (findings.match(/\[CDX-ARCH-STRIVE-\d+\]/g) || []).length
      if (findingCount > 0) {
        log(`Phase 3.7: ${findingCount} architectural finding(s) — see ${outputPath}`)
      } else {
        log("Phase 3.7: No architectural drift detected")
      }
    } else {
      // Classify error per codex-detection.md ## Runtime Error Classification
      const stderr = Read(`tmp/work/${timestamp}/codex-critique-stderr.tmp`)
      warn(`Phase 3.7: Codex error (exit ${result.exitCode}) — skipping. See stderr for details.`)
      Write(outputPath, `# Architectural Critique — Codex Error\n\nReason: Codex exited with code ${result.exitCode}.\nPipeline continues without architectural critique.\n`)
    }

    // Cleanup temp files
    Bash(`rm -f "tmp/work/${timestamp}/codex-critique-prompt.tmp" "tmp/work/${timestamp}/codex-critique-stderr.tmp"`)
  }
} else {
  // Feature disabled or Codex unavailable — write skip output (mandatory per success criteria)
  const skipReason = !codexAvailable ? "Codex CLI not available"
    : codexDisabled ? "Codex disabled in talisman"
    : !featureEnabled ? "codex.post_monitor_critique.enabled is false (opt-in)"
    : "work not in codex.workflows"
  Write(`tmp/work/${timestamp}/architectural-critique.md`,
    `# Architectural Critique — Skipped\n\nReason: ${skipReason}\n`)
}
```

**Ward check integration**: Phase 4 reads `architectural-critique.md` if it exists and has findings. CDX-ARCH-STRIVE findings are treated as advisory (INFO-level) — they do not block the ward check. See [quality-gates.md](quality-gates.md) Phase 3.7 integration section.
