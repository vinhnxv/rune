# Phase 1.5: Codex Drift Detection

Cross-model comparison of plan intent vs code semantics before inspector team creation. Flags semantic drift where code implements something different from what the plan specified.

**Inputs**: `config` (talisman object), `scopeFiles` (string[]), `planContent` (string), `outputDir` (string)
**Outputs**: `tmp/inspect/{identifier}/drift-report.md`, `driftContext` (string, for Phase 3 injection)
**Preconditions**: Phase 1 scope identification completed, Codex CLI available

**GREENFIELD**: Inspect has no prior Codex integration — this adds the full detection infrastructure.

**Team**: None (orchestrator-only, inline codex exec — runs before Phase 2 team creation)
**Failure**: Non-blocking — drift report is additional context, not a gate.

## Independence from Lore Layer

Phase 1.5 MUST be independent of `risk-map.json` — the `--no-lore` flag may skip Phase 1.3 entirely. When Lore Layer is skipped, drift detection uses scope files from Phase 1 directly (not risk-sorted files).

## Protocol

```javascript
// Phase 1.5: CODEX DRIFT DETECTION
// Full Codex detection infrastructure (canonical pattern from codex-detection.md)
const codexAvailable = detectCodex()  // CLI available + authenticated + jq check
const codexDisabled = config?.codex?.disabled === true
const driftEnabled = config?.codex?.drift_detection?.enabled === true  // Default OFF (greenfield, unproven value)
const workflowIncluded = (config?.codex?.workflows ?? []).includes("inspect")

if (codexAvailable && !codexDisabled && driftEnabled && workflowIncluded) {
  const { timeout, reasoning, model: codexModel } = resolveCodexConfig(config, "drift_detection", {
    timeout: 600, reasoning: "xhigh"  // xhigh — deep semantic comparison
  })

  // Use scope files directly (NOT risk-sorted — independent of Phase 1.3 Lore Layer)
  const driftScopeFiles = scopeFiles.slice(0, 20)  // Cap scope for prompt budget
  const planExcerpt = planContent.substring(0, 10000)

  // Read top scope files content (cap total at 10K chars)
  let scopeContent = ""
  for (const f of driftScopeFiles) {
    if (scopeContent.length >= 10000) break
    try {
      const content = Read(f)
      scopeContent += `\n--- ${f} ---\n${content.substring(0, 2000)}\n`
    } catch (e) { continue }
  }

  // SEC-003: Prompt via temp file (NEVER inline string interpolation)
  const promptTmpFile = `${outputDir}/.codex-prompt-drift-detect.tmp`
  try {
    const sanitizedPlan = sanitizePlanContent(planExcerpt)
    const sanitizedScope = sanitizePlanContent(scopeContent)
    const nonce = Bash(`openssl rand -hex 16`).trim()
    const promptContent = `SYSTEM: You are a cross-model drift detector.

Compare plan intent vs code semantics. Flag semantic drift where code implements something different from what the plan specifies.

=== PLAN INTENT ===
<<<NONCE_${nonce}>>>
${sanitizedPlan}
<<<END_NONCE_${nonce}>>>
=== END PLAN ===

=== CODE SCOPE ===
<<<NONCE_${nonce}>>>
${sanitizedScope}
<<<END_NONCE_${nonce}>>>
=== END CODE ===

For each drift finding, provide:
- CDX-INSPECT-DRIFT-NNN: [CRITICAL|HIGH|MEDIUM] - description
- Plan says: <what the plan specified>
- Code does: <what the code actually implements>
- Drift type: Semantic mismatch / Missing implementation / Extra implementation / Wrong approach

Base findings on actual code and plan content, not assumptions.
Only report genuine semantic drift — not stylistic differences.`

    Write(promptTmpFile, promptContent)
    const result = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g "${promptTmpFile}"`)
    const classified = classifyCodexError(result)

    // Write drift report (even on error)
    Write(`${outputDir}/drift-report.md`, formatReport(classified, result, "Drift Detection"))
  } finally {
    Bash(`rm -f "${promptTmpFile}"`)  // Guaranteed cleanup
  }
} else {
  // Skip-path: MUST write output MD even when skipped
  const skipReason = !codexAvailable ? "codex not available"
    : codexDisabled ? "codex.disabled=true"
    : !driftEnabled ? "codex.drift_detection.enabled=false (default OFF)"
    : "inspect not in codex.workflows"
  Write(`${outputDir}/drift-report.md`, `# Drift Detection (Codex)\n\nSkipped: ${skipReason}`)
}

// Inject drift report into inspector Ash prompts (Phase 3)
// Cap at 2000 chars to prevent prompt inflation (rune-architect CONDITION 3)
let driftContext = ""
try {
  const driftReport = Read(`${outputDir}/drift-report.md`)
  if (driftReport && !driftReport.includes("Skipped:")) {
    driftContext = driftReport.length > 2000
      ? driftReport.substring(0, 2000) + "\n[truncated]"
      : driftReport
  }
} catch (e) { /* no drift report — skip injection */ }
```

## Drift Report Injection

When `driftContext` is non-empty, it is injected into inspector Ash prompts in Phase 3 as nonce-bounded additional context:

```
=== CODEX DRIFT CONTEXT ===
${driftContext}
=== END DRIFT CONTEXT ===

Note: This drift report was generated by a cross-model analysis (Codex).
Verify drift claims independently — Codex is a witness, not a judge.
```
