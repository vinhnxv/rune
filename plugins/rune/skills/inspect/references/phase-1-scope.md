# Phase 1: Scope + Phase 1.3: Lore Layer

## Step 1.1 — Identify Relevant Codebase Files

```javascript
scopeFiles = []

for (const id of identifiers):
  if (id.type === "file"):
    matches = Glob(id.value)
    scopeFiles.push(...matches)
  elif (id.type === "code"):
    matches = Grep(id.value, { output_mode: "files_with_matches", head_limit: 10 })
    scopeFiles.push(...matches)
  elif (id.type === "config"):
    matches = Grep(id.value, { glob: "*.{yml,yaml,json,toml,env}", output_mode: "files_with_matches", head_limit: 5 })
    scopeFiles.push(...matches)

// Deduplicate
scopeFiles = [...new Set(scopeFiles)]

// Plan mode: plan file is primary scope; only keep existing files
if (inspectMode === "plan" && planPath):
  scopeFiles = scopeFiles.filter(f => f === planPath || exists(f))

// Cap at 120 files (30 per inspector max)
if (scopeFiles.length > 120):
  scopeFiles = scopeFiles.slice(0, 120)
```

### Step 1.2 — Dry-Run Output

If `--dry-run`, display scope + assignments and stop. No teams, tasks, or agents created.

## Phase 1.3: Lore Layer (Risk Intelligence)

Runs AFTER scope is known (Phase 1) but BEFORE team creation (Phase 2). Discovers existing risk-map or spawns `lore-analyst` as a bare Agent (no team yet — ATE-1 exemption). Re-sorts `scopeFiles` by risk tier and enriches requirement classification.

See [data-discovery.md](../../goldmask/references/data-discovery.md) for the discovery protocol and [risk-context-template.md](../../goldmask/references/risk-context-template.md) for prompt injection format.

### Skip Conditions

| Condition | Effect |
|-----------|--------|
| `talisman.goldmask.enabled === false` | Skip Phase 1.3 entirely |
| `talisman.goldmask.inspect.enabled === false` | Skip Phase 1.3 entirely |
| `talisman.goldmask.layers.lore.enabled === false` | Skip Phase 1.3 entirely |
| `--no-lore` flag | Skip Phase 1.3 entirely |
| Non-git repo | Skip Phase 1.3 |
| < 5 commits in lookback window (G5 guard) | Skip Phase 1.3 |
| `talisman.goldmask.inspect.wisdom_passthrough === false` | Skip wisdom injection in Phase 3 only |
| Existing risk-map found (>= 30% scope overlap) | Reuse instead of spawning agent |

### Steps 1.3.1–1.3.2 — Skip Gate, Discovery, and Spawning

See [lore-layer-integration.md](../../goldmask/references/lore-layer-integration.md) for the shared skip gate, data discovery, lore-analyst spawning, and polling timeout protocol.

**inspect-specific**: Also loads wisdom data for Phase 3 injection when `config.goldmask.inspect.wisdom_passthrough !== false`.

**Output**: `tmp/inspect/{identifier}/risk-map.json` + `tmp/inspect/{identifier}/lore-analysis.md`

### Step 1.3.3 — Risk-Weighted Scope Sorting and Requirement Enhancement

See [risk-tier-sorting.md](../../goldmask/references/risk-tier-sorting.md) for the shared tier enumeration, `getMaxRiskTier` helper, and sorting algorithm.

**inspect-specific dual-inspector gate**: When a requirement touches CRITICAL-tier files AND the plan has security-sensitive sections (or `inspectConfig.dual_inspector_gate` is enabled), assign both `grace-warden` AND `ruin-prophet` to the requirement:

```javascript
if (maxRiskTier === 'CRITICAL') {
  req.inspectionPriority = 'HIGH'
  req.riskNote = "Touches CRITICAL-tier files — requires thorough inspection"
  const hasSecurity = requirements.some(r => /security|auth|crypt|token|inject|xss|sqli/i.test(r.text))
  const dualGateEnabled = inspectConfig.dual_inspector_gate ?? hasSecurity
  if (dualGateEnabled) {
    req.assignedInspectors = ['grace-warden', 'ruin-prophet']
  }
} else if (maxRiskTier === 'HIGH') {
  req.inspectionPriority = 'ELEVATED'
}
```
