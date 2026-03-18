# Audit-Specific Post-Orchestration: Incremental Write-Back (Phase 7.5)

After shared orchestration (Phases 1-7) completes, the audit skill runs audit-specific post-processing.

## Truthseer Validator

```javascript
// 1. Truthseer Validator (for high file counts)
if (reviewableFileCount > 100) {
  // Summon Truthseer Validator — see roundtable-circle SKILL.md Phase 5.5
  // Cross-references finding density against file importance
}
```

## Incremental Result Write-Back

**Gate**: Only run when this session actually acquired the lock and created a checkpoint. If we fell back to full audit (lock held by another session), skip write-back entirely.

```javascript
if (isIncremental && incrementalLockAcquired) {
  // Read current state
  const state = Read(".rune/audit-state/state.json")
  const checkpoint = Read(".rune/audit-state/checkpoint.json")

  // Parse TOME for findings per file
  const tome = Read(`${outputDir}/TOME.md`)
  const findingsPerFile = parseTomeFindings(tome)

  // Determine which files actually completed vs failed (Finding 4 fix)
  // Files present in TOME with findings (even zero) are completed; files absent from TOME are failed
  const tomeFilePaths = new Set(Object.keys(findingsPerFile))
  const filesCompleted = checkpoint.batch.filter(f => tomeFilePaths.has(f))
  const filesFailed = checkpoint.batch.filter(f => !tomeFilePaths.has(f))

  // Update state.json for each audited file
  const fileManifestData = Read(".rune/audit-state/manifest.json")
  for (const filePath of checkpoint.batch) {
    const wasCompleted = tomeFilePaths.has(filePath)
    const findings = findingsPerFile[filePath] || { P1: 0, P2: 0, P3: 0, total: 0 }
    const fileManifest = fileManifestData?.files?.[filePath]

    if (wasCompleted) {
      state.files[filePath] = {
        ...state.files[filePath],
        last_audited: new Date().toISOString(),
        last_audit_id: audit_id,
        last_git_hash: fileManifest?.git?.current_hash || null,
        changed_since_audit: false,
        audit_count: (state.files[filePath]?.audit_count || 0) + 1,
        audited_by: [...new Set([...(state.files[filePath]?.audited_by || []), ...selectedAsh])],
        findings,
        status: "audited",
        consecutive_error_count: 0
      }
      // Remove from coverage_gaps if present
      delete state.coverage_gaps?.[filePath]
    } else {
      // File was in batch but absent from TOME — mark as error for re-queue
      const errorCount = (state.files[filePath]?.consecutive_error_count || 0) + 1
      state.files[filePath] = {
        ...state.files[filePath],
        status: errorCount >= 3 ? "error_permanent" : "error",
        consecutive_error_count: errorCount,
        last_audit_id: audit_id
      }
    }
  }

  // Recompute stats
  const auditable = Object.values(state.files).filter(f => !["excluded","deleted"].includes(f.status))
  const audited = auditable.filter(f => f.status === "audited")
  state.stats = {
    total_auditable: auditable.length,
    total_audited: audited.length,
    total_never_audited: auditable.filter(f => f.status === "never_audited").length,
    coverage_pct: auditable.length > 0 ? Math.round(audited.length / auditable.length * 1000) / 10 : 0,
    freshness_pct: 0, // Computed from staleness window
    avg_findings_per_file: audited.length > 0
      ? Math.round(audited.reduce((s, f) => s + (f.findings?.total || 0), 0) / audited.length * 10) / 10 : 0,
    avg_ashes_per_file: 0
  }
  state.total_sessions = (state.total_sessions || 0) + 1
  state.updated_at = new Date().toISOString()

  // Atomic write state
  Write(".rune/audit-state/state.json", state)

  // Write session history
  const coverageBefore = checkpoint.coverage_before || 0
  Write(`.rune/audit-state/history/audit-${audit_id}.json`, {
    audit_id, timestamp: new Date().toISOString(),
    mode: "incremental", depth,
    batch_size: checkpoint.batch.length,
    files_planned: checkpoint.batch,
    files_completed: filesCompleted,
    files_failed: filesFailed,
    total_findings: Object.values(findingsPerFile).reduce((s, f) => s + f.total, 0),
    findings_by_severity: {
      P1: Object.values(findingsPerFile).reduce((s, f) => s + f.P1, 0),
      P2: Object.values(findingsPerFile).reduce((s, f) => s + f.P2, 0),
      P3: Object.values(findingsPerFile).reduce((s, f) => s + f.P3, 0)
    },
    coverage_before: coverageBefore,
    coverage_after: state.stats.coverage_pct,
    config_dir: configDir, owner_pid: ownerPid, session_id: sessionId
  })

  // Complete checkpoint
  Write(".rune/audit-state/checkpoint.json", {
    ...checkpoint, status: "completed",
    completed: checkpoint.batch, current_file: null
  })

  // Release advisory lock (ownership-checked per incremental-state-schema.md protocol)
  const lockMeta = Read(".rune/audit-state/.lock/meta.json")
  if (lockMeta?.pid == ownerPid) {
    Bash(`rm -rf .rune/audit-state/.lock`)
  } // else: not our lock — skip (Finding 2 fix)

  // Generate coverage report
  // See references/coverage-report.md
  log(`Incremental audit complete: ${checkpoint.batch.length} files audited`)
  log(`Coverage: ${state.stats.coverage_pct}% (${state.stats.total_audited}/${state.stats.total_auditable})`)

  // Persist echo
  // Write coverage summary to .rune/echoes/auditor/MEMORY.md
}

// 2. Auto-mend or interactive prompt (same as appraise)
if (totalFindings > 0) {
  AskUserQuestion({
    options: ["/rune:mend (Recommended)", "Review TOME manually", "/rune:rest"]
  })
}
```
