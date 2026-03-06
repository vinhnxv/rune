# Phase 3.5: Codex Risk Amplification

Runs in parallel with Wisdom Sage. Traces 2nd/3rd-order risk chains that single-model analysis likely misses.

```javascript
// Phase 3.5: Codex Risk Amplification
// 4-condition detection gate (canonical pattern)
// Reference: codex-detection.md for canonical detectCodex()
const codexAvailable = detectCodex()
const codexDisabled = talisman?.codex?.disabled === true
const riskAmpEnabled = talisman?.codex?.risk_amplification?.enabled === true
const workflowIncluded = (talisman?.codex?.workflows ?? []).includes("goldmask")

if (codexAvailable && !codexDisabled && riskAmpEnabled && workflowIncluded) {
  const { timeout, reasoning, model: codexModel } = resolveCodexConfig(talisman, "risk_amplification", {
    timeout: 600, reasoning: "xhigh"  // xhigh — deep transitive dependency tracing
  })

  // Read Impact tracer outputs + risk-map.json (both available from Phase 1+2)
  const impactOutputs = []
  for (const tracer of ["data-layer", "api-contract", "business-logic", "event-message", "config-dependency"]) {
    try { impactOutputs.push(Read(`${output_dir}${tracer}.md`)) } catch (e) { /* tracer may not exist */ }
  }
  const riskMapContent = exists(`${output_dir}risk-map.json`) ? Read(`${output_dir}risk-map.json`) : ""

  const combinedInput = (impactOutputs.join("\n\n") + "\n\n" + riskMapContent).substring(0, 30000)
  const nonce = Bash(`openssl rand -hex 16`).trim()
  const promptTmpFile = `${output_dir}.codex-prompt-risk-amplify.tmp`
  try {
    const sanitizedInput = sanitizePlanContent(combinedInput)
    const promptContent = `SYSTEM: You are a cross-model risk chain amplifier.

Trace 2nd-order (transitive dependency) and 3rd-order (runtime config, deployment topology)
risk chains for CRITICAL/HIGH files. Focus on chains that single-model analysis likely misses:
- Transitive dependencies (A→B→C where B is not in the diff)
- Runtime configuration cascades (env var changes that affect multiple services)
- Deployment topology risks (load balancer, circuit breaker, rate limiter implications)

=== IMPACT + RISK DATA ===
<<<NONCE_${nonce}>>>
${sanitizedInput}
<<<END_NONCE_${nonce}>>>

For each risk chain, output: CDX-RISK-NNN: [CRITICAL|HIGH|MEDIUM] — chain description
Include the full dependency path (A → B → C) for each chain.
Base findings on actual dependency data, not assumptions.`

    Write(promptTmpFile, promptContent)
    const result = Bash(`"${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g "${promptTmpFile}"`)
    const classified = classifyCodexError(result)

    Write(`${output_dir}risk-amplification.md`, formatRiskAmplificationReport(classified, result))
  } finally {
    Bash(`rm -f "${promptTmpFile}"`)  // Guaranteed cleanup
  }
} else {
  const skipReason = !codexAvailable ? "codex not available"
    : codexDisabled ? "codex.disabled=true"
    : !riskAmpEnabled ? "codex.risk_amplification.enabled=false"
    : "goldmask not in codex.workflows"
  Write(`${output_dir}risk-amplification.md`, `# Codex Risk Amplification\n\nSkipped: ${skipReason}`)
}
```
