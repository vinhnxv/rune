# Proof Manifest Persistence (Discipline Integration, v1.173.0)

After ship/merge, persist the proof manifest beyond `tmp/` lifecycle. The manifest is generated
at Phase 8.5 (pre-ship validation) and contains per-criterion PASS/FAIL/UNTESTED status,
SCR, failure codes, convergence iterations, and evidence file references.

The proof manifest includes both code compliance (SCR) and design compliance (DSR) when
`design_sync.enabled` is true. The `design_compliance` section is omitted entirely when
design sync is disabled — DSR is `null`, not `1.0`.

```json
{
  "code_compliance": { "SCR": 0.92, "criteria": ["AC-1.1: PASS", "AC-1.2: FAIL"] },
  "design_compliance": {
    "DSR": 0.85,
    "components": [
      { "name": "Button", "criteria_pass": 6, "criteria_total": 7, "failing": ["DES-Button-responsive"] }
    ],
    "dimensions": {
      "token_compliance": 1.0,
      "accessibility": 0.9,
      "variant_coverage": 0.85,
      "story_coverage": 1.0,
      "responsive": 0.6,
      "fidelity": 0.8
    }
  }
}
```

The overall verdict uses `Math.min(scr_gate, dsr_gate)` — both code and design compliance
must pass for an overall PASS. Per-component DSR breakdown enables targeted remediation.

```javascript
// Persist proof manifest as PR comment (survives in GitHub, searchable, linked to code)
const manifestPath = `tmp/arc/${id}/proof-manifest.json`
try {
  const manifest = JSON.parse(Read(manifestPath))
  const prUrl = checkpoint.pr_url
  if (prUrl && manifest) {
    const prNumber = prUrl.match(/\/pull\/(\d+)/)?.[1]
    if (prNumber) {
      const hasDsr = manifest.dsr !== null && manifest.dsr !== undefined
      const manifestComment = [
        '## Discipline Proof Manifest',
        '',
        `**Plan**: \`${manifest.plan_file}\``,
        `**Arc ID**: ${manifest.arc_id}`,
        `**SCR**: ${manifest.scr !== null ? (manifest.scr * 100).toFixed(1) + '%' : 'N/A'}`,
        hasDsr ? `**DSR**: ${(manifest.dsr * 100).toFixed(1)}%` : null,
        `**Criteria**: ${manifest.criteria_count} total`,
        `**Convergence**: ${manifest.convergence_rounds} round(s)`,
        `**Verdict**: ${manifest.verdict}`,
        `**Timestamp**: ${manifest.timestamp}`,
      ].filter(Boolean).join('\n')
      // SEC-S8-004 FIX: Use --body-file instead of heredoc to prevent content injection
      const tmpManifestFile = Bash('mktemp "${TMPDIR:-/tmp}/rune-manifest-XXXXXX"').trim()
      Write(tmpManifestFile, manifestComment)
      Bash(`gh pr comment ${prNumber} --body-file "${tmpManifestFile}" && rm -f "${tmpManifestFile}"`)
    }
  }
} catch (e) {
  warn(`Proof manifest persistence failed: ${e.message} — non-blocking`)
}
```
