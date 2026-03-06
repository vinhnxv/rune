# Quick Check Mode + Intelligence Mode + Output Paths

## Quick Check Mode (--quick)

No agents spawned. Deterministic checks only:

```
1. Read existing GOLDMASK.md — discovery order: `tmp/goldmask/*/GOLDMASK.md` (most recent), `tmp/arc/*/goldmask/GOLDMASK.md`, or `--report <path>` argument
2. Compare predicted MUST-CHANGE files vs committed files
3. For each missing file: emit WARNING with risk tier + caution level
4. Exit — non-blocking
```

## Intelligence Mode (--lore)

Single agent (Lore Analyst) only:

```
1. Spawn Lore Analyst with file list
2. Wait for risk-map.json
3. Output risk-sorted file list with tier annotations
4. Cleanup
```

## Output Paths

```
tmp/goldmask/{session_id}/
+-- inscription.json
+-- data-layer.md
+-- api-contract.md
+-- business-logic.md
+-- event-message.md
+-- config-dependency.md
+-- risk-map.json
+-- wisdom-report.md
+-- risk-amplification.md  (Codex Phase 3.5, v1.51.0+)
+-- GOLDMASK.md
+-- findings.json
```
