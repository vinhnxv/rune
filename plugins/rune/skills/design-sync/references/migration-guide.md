# Design-Sync Accuracy Parity — Migration Guide

## Overview

This guide covers enabling the accuracy-parity features added in v1.139.0: Worker Trust Hierarchy, Verification Gate, Visual-First Protocol, Element Inventory, and Backend Impact Assessment.

## Enabling New Features

All accuracy features are **opt-in** via `talisman.yml` under `design_sync`:

```yaml
# talisman.yml
design_sync:
  enabled: true  # Required — master toggle for design-sync pipeline

  # Trust Hierarchy (default: enabled)
  trust_hierarchy:
    enabled: true
    low_confidence_threshold: 0.60   # Below this = LOW confidence (build from scratch)
    high_confidence_threshold: 0.80  # At or above this = HIGH confidence (import directly)

  # Verification Gate (default: enabled)
  verification_gate:
    enabled: true
    warn_threshold: 20   # % mismatch to trigger WARN
    block_threshold: 40  # % mismatch to trigger BLOCK

  # Backend Impact (default: disabled)
  backend_impact:
    enabled: false        # Set to true to enable auto-assessment
    auto_scope: frontend-only
```

## Migration from Implicit figma_to_react Passthrough

**Before accuracy-parity**: Workers received `figma_to_react()` output verbatim as implementation starting point.

**After accuracy-parity**: Workers receive enriched VSM with confidence scores. The trust hierarchy controls how workers use reference code:

| Confidence | Worker Behavior |
|------------|----------------|
| HIGH (>= 0.80) | Import library component directly |
| MEDIUM (0.60-0.79) | Import + verify against VSM tokens |
| LOW (< 0.60) | Do NOT import — build from scratch |
| FALLBACK | Use project design system + Tailwind |

**No action required** — the trust hierarchy is enabled by default with sensible thresholds. Workers automatically follow the hierarchy when `design_sync.enabled: true`.

## Rollback Path

### Disable Verification Gate (BLOCK storms)

If the verification gate is producing excessive BLOCK verdicts:

```yaml
design_sync:
  verification_gate:
    enabled: false  # Disables gate entirely — workers proceed without coverage check
```

Or adjust thresholds to be more permissive:

```yaml
design_sync:
  verification_gate:
    warn_threshold: 40   # More lenient WARN
    block_threshold: 80   # Only BLOCK at 80%+ mismatch
```

### Disable Trust Hierarchy

To revert to pre-accuracy-parity behavior where all reference code is treated equally:

```yaml
design_sync:
  trust_hierarchy:
    enabled: false  # Workers use reference code without confidence filtering
```

### Disable Backend Impact

```yaml
design_sync:
  backend_impact:
    enabled: false  # Default — no backend impact assessment
```

## Threshold Tuning

### Trust Hierarchy Thresholds

| Scenario | Recommendation |
|----------|---------------|
| High-quality design system (Shadcn, UntitledUI) | Keep defaults (0.60/0.80) |
| Custom/internal component library | Lower thresholds (0.50/0.70) |
| New/incomplete design system | Raise LOW threshold (0.70) to avoid bad imports |

**Constraint**: `low_confidence_threshold` must be less than `high_confidence_threshold`. If inverted, the system warns and reverts to defaults.

### Verification Gate Thresholds

| Scenario | Recommendation |
|----------|---------------|
| Complex multi-frame Figma files | Raise block_threshold to 60 |
| Simple single-component designs | Keep defaults (20/40) |
| Strict quality requirements | Lower thresholds (10/30) |

**Constraint**: `warn_threshold` must be less than `block_threshold`. If inverted, the system warns and reverts to defaults (20/40).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Constant BLOCK verdicts | Complex Figma nodes with many regions | Break into smaller nodes, or raise `block_threshold` |
| All regions classified LOW | Poor builder MCP match quality | Check builder MCP connectivity, consider disabling trust hierarchy |
| No enriched-vsm.json created | Phase 1.3 circuit breaker fired (3 consecutive MCP failures) | Check builder MCP server status, review warn() logs |
| Gate shows 0% but output is wrong | Zero regions extracted (empty VSM) | Check Figma URL validity, try different node selection |
| `enabled: "false"` doesn't disable | String vs boolean type mismatch | Use `enabled: false` (no quotes) in YAML |
