# Codex Verification Phases — Phase 6.2 + 6.3

> Cross-model verification layers added after Truthsight (Phase 6). Both phases use
> the canonical 4-condition Codex detection gate and `codex-exec.sh` for CLI invocation.
> See [codex-detection.md](codex-detection.md) for the detection pattern.

## Phase 6.2: Codex Diff Verification (Layer 3)

Cross-model verification of P1/P2 findings against actual diff hunks. Adds a third verification layer after Layer 2 (Smart Verifier).

```javascript
// Phase 6.2: Codex Diff Verification (Layer 3)
// 4-condition detection gate (canonical pattern)
const codexAvailable = detectCodex()
const codexDisabled = talisman?.codex?.disabled === true
const diffVerifyEnabled = talisman?.codex?.diff_verification?.enabled !== false
const workflowIncluded = (talisman?.codex?.workflows ?? []).includes("review")
  || (talisman?.codex?.workflows ?? []).includes("audit")  // audit shares Roundtable Circle

if (codexAvailable && !codexDisabled && diffVerifyEnabled && workflowIncluded) {
  const { timeout, reasoning, model: codexModel } = resolveCodexConfig(talisman, "diff_verification", {
    timeout: 300, reasoning: "high"  // high — structured 3-way verdict, not deep analysis
  })

  // Sample P1/P2 findings — prefer truthsight-report.md, fall back to TOME.md
  let findingsSource = `${outputDir}truthsight-report.md`
  if (!exists(findingsSource)) findingsSource = `${outputDir}TOME.md`  // Layer 2 skipped (<3 Ashes)
  const findings = sampleP1P2Findings(Read(findingsSource), 3)

  if (findings.length === 0) {
    Write(`${outputDir}codex-diff-verification.md`, "# Codex Diff Verification\n\nSkipped: No P1/P2 findings to verify.")
  } else {
    // SEC-003: Build prompt via temp file (never inline string interpolation)
    const nonce = Bash(`openssl rand -hex 16`).trim()
    const promptTmpFile = `${outputDir}.codex-prompt-diff-verify.tmp`
    try {
      const sanitizedFindings = sanitizePlanContent(findings)
      const diffContent = Bash(`git diff ${baseBranch}...HEAD`).substring(0, 15000)
      const sanitizedDiff = sanitizeUntrustedText(diffContent)  // Unicode directional override protection
      const promptContent = `SYSTEM: You are a cross-model diff verification specialist.

For each finding below, compare against the actual diff hunk and respond with one of:
- CONFIRMED: Finding accurately reflects code behavior in the diff
- WEAKENED: Finding is partially valid but overstated
- REFUTED: Finding does not match actual diff behavior

=== FINDINGS ===
<<<NONCE_${nonce}>>>
${sanitizedFindings}
<<<END_NONCE_${nonce}>>>

=== DIFF ===
<<<NONCE_${nonce}>>>
${sanitizedDiff}
<<<END_NONCE_${nonce}>>>

For each finding, output: CDX-VERIFY-NNN: CONFIRMED|WEAKENED|REFUTED — reason
Base verdicts on actual code, not assumptions.`

      Write(promptTmpFile, promptContent)
      const result = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g "${promptTmpFile}"`)
      const classified = classifyCodexError(result)

      if (classified === "SUCCESS") {
        const verdicts = parseVerdicts(result.stdout)  // loose regex /CONFIRMED|WEAKENED|REFUTED/i
        for (const v of verdicts) {
          if (v.verdict === "CONFIRMED") adjustConfidence(v.findingId, +0.15)
          else if (v.verdict === "REFUTED") demoteToP3(v.findingId)
          // WEAKENED: no change
        }
      }
      Write(`${outputDir}codex-diff-verification.md`, formatVerificationReport(classified, verdicts))
    } finally {
      Bash(`rm -f "${promptTmpFile}"`)  // Guaranteed cleanup
    }
  }
} else {
  const skipReason = !codexAvailable ? "codex not available"
    : codexDisabled ? "codex.disabled=true"
    : !diffVerifyEnabled ? "codex.diff_verification.enabled=false"
    : "review/audit not in codex.workflows"
  Write(`${outputDir}codex-diff-verification.md`, `# Codex Diff Verification\n\nSkipped: ${skipReason}`)
}
```

### Confidence Adjustments

- **CONFIRMED**: +0.15 confidence bonus (same as `codex.verification.cross_model_bonus`)
- **WEAKENED**: no change (finding is partially valid)
- **REFUTED**: demote to P3 with `[CDX-REFUTED]` tag (still visible, lower priority)

## Phase 6.3: Codex Architecture Review (Audit Mode Only)

Cross-model analysis of TOME findings for cross-cutting architectural patterns. Only runs in audit mode (`scope=full`).

```javascript
// Phase 6.3: Codex Architecture Review (audit mode only)
// 5-condition gate: 4-condition canonical + scope check
const codexAvailable = detectCodex()
const codexDisabled = talisman?.codex?.disabled === true
const archReviewEnabled = talisman?.codex?.architecture_review?.enabled !== false
const workflowIncluded = (talisman?.codex?.workflows ?? []).includes("audit")
const isAuditMode = scope === "full"

if (codexAvailable && !codexDisabled && archReviewEnabled && workflowIncluded && isAuditMode) {
  const { timeout, reasoning, model: codexModel } = resolveCodexConfig(talisman, "architecture_review", {
    timeout: 600, reasoning: "xhigh"  // xhigh — cross-cutting pattern analysis
  })

  const tomeContent = Read(`${outputDir}TOME.md`).substring(0, 20000)
  const nonce = Bash(`openssl rand -hex 16`).trim()
  const promptTmpFile = `${outputDir}.codex-prompt-arch-review.tmp`
  try {
    const sanitizedTome = sanitizePlanContent(tomeContent)
    const promptContent = `SYSTEM: You are a cross-model architecture consistency reviewer.

Analyze the aggregated TOME findings below for cross-cutting architectural patterns that
individual reviewers may have missed. Focus on:
1. Naming drift — inconsistent naming conventions across modules
2. Layering violations — direct dependencies between layers that should be decoupled
3. Error handling inconsistency — mixed error strategies across the codebase

=== TOME FINDINGS ===
<<<NONCE_${nonce}>>>
${sanitizedTome}
<<<END_NONCE_${nonce}>>>

For each finding, output: CDX-ARCH-NNN: [CRITICAL|HIGH|MEDIUM] — description
Include evidence from the TOME findings that support each architectural observation.
Base findings on actual patterns, not assumptions.`

    Write(promptTmpFile, promptContent)
    const result = Bash(`"${RUNE_PLUGIN_ROOT}/scripts/codex-exec.sh" -m "${codexModel}" -r "${reasoning}" -t ${timeout} -j -g "${promptTmpFile}"`)
    const classified = classifyCodexError(result)

    Write(`${outputDir}architecture-review.md`, formatArchReviewReport(classified, result))
  } finally {
    Bash(`rm -f "${promptTmpFile}"`)  // Guaranteed cleanup
  }
} else {
  const skipReason = !codexAvailable ? "codex not available"
    : codexDisabled ? "codex.disabled=true"
    : !archReviewEnabled ? "codex.architecture_review.enabled=false"
    : !isAuditMode ? "architecture review only runs in audit mode (scope=full)"
    : "audit not in codex.workflows"
  Write(`${outputDir}architecture-review.md`, `# Codex Architecture Review\n\nSkipped: ${skipReason}`)
}
```
