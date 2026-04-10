# Audit Deep Mode — Reference

Detailed protocols for the Lore Layer implementation, `--deep` second pass, Doubt Seer implementation, and TOME merge algorithm for `/rune:audit`.

## Lore Layer Full Implementation (Phase 0.5)

```javascript
const goldmaskEnabled = talisman?.goldmask?.enabled !== false
const loreEnabled = talisman?.goldmask?.layers?.lore?.enabled !== false
const isGitRepo = Bash("git rev-parse --is-inside-work-tree 2>/dev/null").exitCode === 0

if (goldmaskEnabled && loreEnabled && isGitRepo && !flags['--no-lore']) {
  // SEC-001 FIX: Numeric validation before shell interpolation
  // QUAL-102 FIX: Added --no-lore flag support
  const rawLookbackDays = Number(talisman?.goldmask?.layers?.lore?.lookback_days)
  const lookbackDays = (Number.isFinite(rawLookbackDays) && rawLookbackDays >= 1 && rawLookbackDays <= 730)
    ? Math.floor(rawLookbackDays) : 180
  const commitCount = parseInt(
    Bash(`git rev-list --count --since="${lookbackDays} days ago" HEAD 2>/dev/null`).trim(), 10
  )

  if (Number.isNaN(commitCount) || commitCount < 5) {
    log(`Lore Layer: skipped — only ${commitCount ?? 0} commits in ${lookbackDays}d window (minimum: 5)`)
  } else {
    // Two-tier scoping: Tier 1 (default) = Ash-relevant extensions only, Tier 2 (--deep-lore) = all files
    const ASH_RELEVANT_EXTENSIONS = new Set([
      'py', 'go', 'rs', 'rb', 'java', 'kt', 'scala',    // Backend (Forge Warden)
      'ts', 'tsx', 'js', 'jsx', 'vue', 'svelte',          // Frontend (Glyph Scribe)
      'md',                                                 // Docs (Knowledge Keeper)
      'sql', 'sh', 'bash', 'zsh',                          // DB/shell
      'yml', 'yaml', 'json', 'toml',                       // Config (Ward Sentinel)
      'dockerfile', 'tf', 'hcl',                            // Infra (Ward Sentinel)
    ])
    const deepLore = flags['--deep-lore'] === true
    const loreFiles = deepLore ? all_files : all_files.filter(f => {
      const ext = (f ?? '').split('.').pop()?.toLowerCase() ?? ''
      return ASH_RELEVANT_EXTENSIONS.has(ext)
    })

    if (loreFiles.length === 0) {
      log(`Lore Layer: skipped — no Ash-relevant files found (use --deep-lore for full scan)`)
    } else {
      if (!deepLore && loreFiles.length < all_files.length) {
        log(`Lore Layer: Tier 1 — analyzing ${loreFiles.length}/${all_files.length} Ash-relevant files (use --deep-lore for full scan)`)
      }

      // SPAWN-001 FIX: Lore Analyst must be part of the audit team for proper lifecycle management
      Agent({
        name: "lore-analyst",
        subagent_type: "general-purpose",
        team_name: `rune-audit-${audit_id}`,
        prompt: `You are lore-analyst — git history risk scoring specialist.
          Read agents/investigation/lore-analyst.md for your full protocol.
          Analyze git history for risk scoring of these files:
            ${loreFiles.join('\n')}
          Write risk-map.json to: tmp/audit/${audit_id}/risk-map.json
          Write summary to: tmp/audit/${audit_id}/lore-analysis.md
          Lookback window: ${lookbackDays} days
          Execute all guard checks (G1-G5) before analysis.
          When done, write files and exit.`
      })

      // Read risk-map.json and re-sort all_files for prioritization
      // All-or-nothing: either all files get risk annotations or none do
      try {
        const riskMapContent = Read(`tmp/audit/${audit_id}/risk-map.json`)
        const riskMap = JSON.parse(riskMapContent)
        const TIER_ORDER = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3, STALE: 4 }
        const fileRiskMap = {}
        for (const entry of (riskMap.files ?? [])) {
          fileRiskMap[entry.path] = { score: entry.risk_score, tier: entry.tier }
        }
        // Re-sort all_files: tier-then-score composite sort
        all_files.sort((a, b) => {
          const riskA = fileRiskMap[a], riskB = fileRiskMap[b]
          const tierA = TIER_ORDER[riskA?.tier ?? 'STALE'] ?? 4
          const tierB = TIER_ORDER[riskB?.tier ?? 'STALE'] ?? 4
          if (tierA !== tierB) return tierA - tierB
          return (riskB?.score ?? 0) - (riskA?.score ?? 0)
        })
        auditRiskMap = fileRiskMap
        const scoredCount = (riskMap.files ?? []).length
        const criticalCount = (riskMap.files ?? []).filter(f => f.tier === 'CRITICAL').length
        log(`Lore Layer: ${scoredCount} files scored, ${criticalCount} CRITICAL`)
      } catch (e) {
        warn(`Lore Layer: Failed to read risk-map — falling back to static prioritization`)
        // All-or-nothing: do not partially annotate. all_files retains original order.
      }
    }
  }
}
```

**Timeout**: If the Lore Analyst takes > 60s, the bare Agent call will complete with whatever output is available. The try/catch on risk-map read handles missing or partial output gracefully.

## Doubt Seer — Full Implementation (Phase 4.5)

After Phase 4 Monitor completes, optionally spawn the Doubt Seer to cross-examine Ash findings.

```javascript
// readTalismanSection: "gates"
const doubtConfig = readTalismanSection("gates")?.doubt_seer
const doubtEnabled = doubtConfig?.enabled === true  // strict opt-in (default: false)
const doubtWorkflows = doubtConfig?.workflows ?? ["review", "audit"]

if (doubtEnabled && doubtWorkflows.includes("audit")) {
  // Count P1+P2 findings across Ash output files
  let totalFindings = 0
  for (const ash of selectedAsh) {
    const ashPath = `tmp/audit/${audit_id}/${ash}.md`
    if (exists(ashPath)) {
      const content = Read(ashPath)
      totalFindings += (content.match(/severity="P1"/g) || []).length
      totalFindings += (content.match(/severity="P2"/g) || []).length
    }
  }

  if (totalFindings > 0) {
    // Increment .expected signal count for doubt-seer
    const signalDir = `tmp/.rune-signals/rune-audit-${audit_id}`
    if (exists(`${signalDir}/.expected`)) {
      const expected = parseInt(Read(`${signalDir}/.expected`), 10)
      Write(`${signalDir}/.expected`, String(expected + 1))
    }

    // Create task and spawn doubt-seer
    TaskCreate({
      subject: "Cross-examine findings as doubt-seer",
      description: `Challenge P1/P2 findings. Output: tmp/audit/${audit_id}/doubt-seer.md`,
      activeForm: "Doubt seer cross-examining..."
    })

    Agent({
      team_name: `rune-audit-${audit_id}`,
      name: "doubt-seer",
      subagent_type: "general-purpose",
      prompt: /* Load from agents/review/doubt-seer.md
                 Substitute: {output_dir}, {inscription_path}, {timestamp} */,
      run_in_background: true
    })

    // Poll for doubt-seer completion (5-min timeout)
    const DOUBT_TIMEOUT = 300_000  // 5 minutes
    const DOUBT_POLL = 30_000      // 30 seconds
    const maxPoll = Math.ceil(DOUBT_TIMEOUT / DOUBT_POLL)
    for (let i = 0; i < maxPoll; i++) {
      const tasks = TaskList()
      const doubtTask = tasks.find(t => t.subject.includes("doubt-seer"))
      if (doubtTask?.status === "completed") break
      if (i < maxPoll - 1) Bash("sleep 30", { run_in_background: true })
    }

    // Check if doubt-seer completed or timed out
    const doubtOutput = `tmp/audit/${audit_id}/doubt-seer.md`
    if (!exists(doubtOutput)) {
      Write(doubtOutput, "[DOUBT SEER: TIMEOUT — partial results preserved]\n")
      warn("Doubt seer timed out — proceeding with partial results")
    }

    // Parse verdict if output exists
    const doubtContent = Read(doubtOutput)
    if (/VERDICT:\s*BLOCK/i.test(doubtContent) && doubtConfig?.block_on_unproven === true) {
      warn("Doubt seer VERDICT: BLOCK — unproven P1 findings detected")
      // Set workflow_blocked flag for downstream handling
    }
  } else {
    log("[DOUBT SEER: No findings to challenge - skipped]")
  }
}
// Proceed to Phase 5 (Aggregate)
```

## Deep Investigation Pass (Phase 5.6)

When `--deep` is enabled, run a second Roundtable pass focused on four dedicated investigation Ashes:
- `rot-seeker` (DEBT): tech debt root-cause analysis
- `strand-tracer` (INTG): integration and wiring gaps
- `decree-auditor` (BIZL): business logic correctness and invariants
- `fringe-watcher` (EDGE): boundary and edge-case analysis

```javascript
if (flags['--deep']) {
  const deepAsh = ["rot-seeker", "strand-tracer", "decree-auditor", "fringe-watcher"]

  // Extend inscription for deep pass (same team, second task wave)
  Write("tmp/audit/{audit_id}/inscription-deep.json", {
    workflow: "rune-audit-deep",
    timestamp: timestamp,
    output_dir: "tmp/audit/{audit_id}/",
    deep_context: {
      standard_tome: "tmp/audit/{audit_id}/TOME-standard.md",
      coverage_map: "tmp/audit/{audit_id}/coverage-map.json"
    },
    teammates: deepAsh.map(name => ({
      name,
      output_file: `${name}.md`,
      required_sections: ["P1 (Critical)", "P2 (High)", "P3 (Medium)", "Reviewer Assumptions", "Self-Review Log"]
    })),
    verification: { enabled: true }
  })

  // Summon deep Ashes in parallel
  for (const ash of deepAsh) {
    Agent({
      team_name: "rune-audit-{audit_id}",
      name: ash,
      subagent_type: ash,
      prompt: `You are ${ash} in deep audit mode.
Read tmp/audit/{audit_id}/TOME-standard.md and tmp/audit/{audit_id}/coverage-map.json first.
Then investigate all project files assigned by Rune Gaze with your deep-audit protocol.
Use finding prefixes reserved for deep mode only: DEBT / INTG / BIZL / EDGE.
Write output to tmp/audit/{audit_id}/${ash}.md with P1/P2/P3 sections + Summary.`,
      run_in_background: true
    })
  }

  // Runebinder for deep pass output
  Agent({
    team_name: "rune-audit-{audit_id}",
    name: "runebinder-deep",
    subagent_type: "general-purpose",
    prompt: `Read deep Ash outputs (rot-seeker, strand-tracer, decree-auditor, fringe-watcher) from tmp/audit/{audit_id}/.
Deduplicate with deep prefixes enabled: DEBT > INTG > BIZL > EDGE (within deep pass only).
Write tmp/audit/{audit_id}/TOME-deep.md.`
  })
}
```

## TOME Merge (Phase 5.7)

When `--deep` is enabled, merge standard and deep TOMEs into the final output:

```javascript
if (flags['--deep']) {
  Agent({
    team_name: "rune-audit-{audit_id}",
    name: "runebinder-merge",
    subagent_type: "general-purpose",
    prompt: `Merge tmp/audit/{audit_id}/TOME-standard.md + tmp/audit/{audit_id}/TOME-deep.md.
Use category-bucketed merge with semantic dedup within category.
Severity reconciliation: max(pass1, pass2).
If contradictory findings remain unresolved, add CONFLICT markers with both finding IDs.
Write final merged output to tmp/audit/{audit_id}/TOME.md.`
  })
}
```

### Merge Strategy

The TOME merge uses a two-pass approach:

1. **Category bucketing**: Group findings by prefix (SEC, BACK, VEIL, DEBT, INTG, BIZL, EDGE, etc.) before dedup. Standard and deep findings in the same category compete directly.

2. **Semantic dedup within categories**: Within each category, compare findings for semantic similarity. Merge findings that describe the same root cause into a single entry with higher evidence count.

3. **Severity reconciliation**: When the same issue appears at different severity levels across passes, take `max(pass1_severity, pass2_severity)`.

4. **CONFLICT markers**: Findings that contradict each other (e.g., "this is intentional" vs "this is a bug") are preserved as-is with `<!-- CONFLICT: finding-a vs finding-b -->` annotation.

5. **Coverage gap section**: Merge coverage-map.json entries from both passes. Mark files as `reviewed` if either pass reviewed them.

### Deep Mode Output Layout

```
tmp/audit/{audit_id}/
├── inscription.json          # Standard pass inscription
├── inscription-deep.json     # Deep pass inscription
├── forge-warden.md           # Standard pass outputs
├── ward-sentinel.md
├── ...
├── TOME-standard.md          # Standard pass aggregation
├── coverage-map.json         # Standard pass coverage
├── rot-seeker.md             # Deep pass outputs
├── strand-tracer.md
├── decree-auditor.md
├── fringe-watcher.md
├── TOME-deep.md              # Deep pass aggregation
└── TOME.md                   # Final merged output
```

### Deep Mode Time Budget

| Phase | Component | Time Budget |
|-------|-----------|-------------|
| Standard pass (Phases 0-5) | 7 Ashes + Runebinder | ~15 min |
| Deep pass (Phase 5.6) | 4 Ashes + Runebinder-deep | ~10 min |
| TOME merge (Phase 5.7) | Runebinder-merge | ~5 min |
| **Total** | | **~30 min** |

The standard pass timeout of 15 minutes applies only to Phase 4 monitoring. The deep pass adds an additional 10-minute window after the standard TOME is written.
