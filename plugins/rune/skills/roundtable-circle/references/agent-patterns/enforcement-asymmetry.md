# Enforcement Asymmetry Protocol

Shared protocol for applying variable strictness levels based on change context. Import from any review agent to reduce noise on new isolated code while maintaining rigor on modifications to shared/core modules.

## Context Classification

Before analyzing each file, classify its change context using the two-step matrix below.

### Step 1: Determine Change Type

Use git diff to classify each file in scope:

| Git Status | Classification | Strictness |
|------------|---------------|------------|
| `A` (added) | NEW_FILE | Pragmatic |
| `M` (modified) with <30% lines changed | MINOR_EDIT | Standard |
| `M` (modified) with >=30% lines changed | MAJOR_EDIT | Strict |
| `R` (renamed) | REFACTOR | Strict |
| `D` (deleted) | DELETION | Strict (verify no orphans) |

The 30% threshold is configurable via `talisman.yml` → `review.enforcement_asymmetry.new_file_threshold`.

### Step 2: Determine Scope Risk

| Signal | Risk Level |
|--------|-----------|
| File imported by >5 other files | HIGH (shared code) |
| File in `core/`, `shared/`, `lib/`, `common/` | HIGH (foundation) |
| File contains auth/payment/data-mutation logic | HIGH (security-critical) |
| File is a test file (`*_test.*`, `*.spec.*`) | LOW (isolated) |
| File in `scripts/`, `tools/`, `migrations/` | LOW (operational) |
| New file not imported by anything yet | LOW (isolated) |

Import count threshold configurable via `review.enforcement_asymmetry.high_risk_import_count` (default: 5). High-risk directory patterns configurable via `review.enforcement_asymmetry.high_risk_paths`.

### Step 3: Apply Strictness Matrix

| Change Type | Scope Risk | Strictness | Behavior |
|-------------|-----------|------------|----------|
| NEW_FILE | LOW | **Pragmatic** | Flag only P1 issues. Skip style/convention findings. Accept reasonable patterns even if not project-standard. |
| NEW_FILE | HIGH | **Standard** | Flag P1 + P2. Enforce naming conventions and core patterns. Skip minor style. |
| MINOR_EDIT | LOW | **Standard** | Flag P1 + P2. Enforce consistency with surrounding code. |
| MINOR_EDIT | HIGH | **Strict** | Flag all priorities. Enforce full project standards. |
| MAJOR_EDIT | any | **Strict** | Flag all priorities. Require full compliance. |
| REFACTOR | any | **Strict** | Flag all priorities. Verify no behavioral changes. |

### Integration into Analysis

When generating findings, apply the strictness filter:

- **Pragmatic mode**: Only emit findings with severity P1. Downgrade P2 to P3, skip P3.
- **Standard mode**: Emit P1 and P2. Downgrade P3 to informational.
- **Strict mode**: Emit all findings at their natural severity.

### Hard Override: Security Always Strict

Regardless of change type or scope risk, security-related findings (SEC-*, injection, auth bypass, secrets exposure) are ALWAYS evaluated at **Strict** level. Security has no pragmatic mode. This override cannot be disabled — `review.enforcement_asymmetry.security_always_strict` is locked to `true`.

### Output Annotation

When enforcement asymmetry is active, annotate findings with the applied mode:

```markdown
- [ ] **[PREFIX-001] Finding title** in `file.py:42` *(Strict)*
  - **Evidence:** ...
```

This allows reviewers to understand why certain files received more lenient treatment.

## Talisman Configuration

```yaml
review:
  enforcement_asymmetry:
    enabled: true                    # Master toggle (default: true)
    security_always_strict: true     # Cannot be disabled
    new_file_threshold: 0.30         # % lines changed to classify as MAJOR_EDIT (default: 0.30)
    high_risk_import_count: 5        # Files imported by >N = HIGH risk (default: 5)
    high_risk_paths:                 # Glob patterns for HIGH risk directories
      - "core/**"
      - "shared/**"
      - "lib/**"
      - "common/**"
```

> **Cross-reference**: This protocol is integrated into review agent checklists via the Pre-Analysis step. See `simplicity-warden.md`, `pattern-seer.md`, and `type-warden.md` for per-agent adaptations. The `talisman.example.yml` `enforcement_asymmetry:` section documents the full configuration schema.
