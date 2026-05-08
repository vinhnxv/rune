# Arc Naming Conventions

Canonical taxonomy for arc pipeline terminology. Ensures consistent naming across all 35+ reference files.

## Phase Validation Suffixes

| Suffix | Meaning | Behavior on Failure | Example |
|--------|---------|---------------------|---------|
| **Gate** | Binary pass/fail checkpoint | Halts pipeline (unless overridden by `--confirm`) | Freshness Gate, Verification Gate |
| **Validator** | Checks conformance to rules | Writes findings; non-blocking | Pre-Ship Validator, Truthseer Validator |
| **Sentinel** | Monitors ongoing condition | Advisory warnings; never blocks | Stagnation Sentinel |
| **Guard** | Prevents unsafe entry | Blocks phase start if precondition unmet | Entry Guard (verify-mend.md) |
| **Check** | Quick deterministic verification | Advisory or blocking depending on context | Ward Check, Goldmask Quick Check |

## Phase Name Patterns

| Pattern | Convention | Example |
|---------|-----------|---------|
| `arc-phase-{name}.md` | Standard phase reference file | `arc-phase-work.md`, `arc-phase-mend.md` |
| `arc-phase-{name}-{qualifier}.md` | Conditional or variant phase | `arc-phase-design-extraction.md` |
| `arc-{utility}.md` | Cross-phase utility | `arc-checkpoint-init.md`, `arc-resume.md` |
| `{concept}.md` | Standalone algorithm | `stagnation-sentinel.md`, `verify-mend.md` |

### Documented exceptions (unprefixed phase reference files)

The phases below are full-fledged arc phases (registered in `PHASE_ORDER`) but their reference files **drop the `arc-phase-` prefix**. The dispatcher case statement in [`scripts/arc-phase-stop-hook.sh`](../../../scripts/arc-phase-stop-hook.sh) handles each as an explicit special-case, so behaviour is unaffected — but a `grep arc-phase-*` search will not surface them. Do not add new phases under this exception; new phases should follow the `arc-phase-{name}.md` standard.

| File | PHASE_ORDER key | Why unprefixed |
|------|-----------------|----------------|
| `verify-inspect.md` | `verify_inspect` | "Verify" family is a standalone correctness algorithm; predates the `arc-phase-` standard |
| `verify-mend.md` | `verify_mend` | Same as above — sibling to `verify-inspect.md` |
| `verification-gate.md` | `verification` | Phase **2.7** Verification Gate — gating algorithm reused by other phases, not a phase-specific handler |
| `gap-analysis.md` | `gap_analysis` | "Gap" family is a standalone delta-detection algorithm; reused by `gap-remediation.md` |
| `gap-remediation.md` | `gap_remediation` | Same as above — sibling to `gap-analysis.md` |

**Rule for new phase reference files**: prefer `arc-phase-{name}.md`. Only drop the prefix if the file represents a reusable algorithm that is invoked from more than one phase, AND register the file in this table.

## Checkpoint Phase Keys

Phase keys in `checkpoint.phases` use snake_case and match PHASE_ORDER entries:

```
forge, plan_review, plan_refine, verification, semantic_verification,
work, gap_analysis, gap_remediation,
code_review, mend, verify_mend,
test, test_coverage_critique, pre_ship_validation, release_quality_check,
ship, merge
```

> **v3.0.0-alpha.2**: `goldmask_verification`, `goldmask_correlation`,
> `bot_review_wait`, `pr_comment_resolution` removed from the default order.
> Goldmask remains as `/rune:goldmask`; bot-review/PR-comment work moves to
> external pr-guardian harness territory.

Conditional phases (gated by talisman):
```
design_extraction, design_verification, design_iteration, ux_verification
```

## Finding Prefixes

| Prefix | Source | Used By |
|--------|--------|---------|
| `SEC-` | Security findings | TOME.md (review/audit) |
| `BACK-` | Backend/logic findings | TOME.md |
| `QUAL-` | Code quality findings | TOME.md |
| `PAT-` | Pattern consistency | TOME.md |
| `DOC-` | Documentation findings | TOME.md |
| `FRONT-` | Frontend findings | TOME.md |
| `UXH-` | UX heuristic findings | TOME.md (ux_verification) |
| `UXF-` | UX flow findings | TOME.md (ux_verification) |
| `UXI-` | UX interaction findings | TOME.md (ux_verification) |
| `UXC-` | UX cognitive findings | TOME.md (ux_verification) |
| `PERF-` | Performance findings | TOME.md |

## Team Name Patterns

| Pattern | Phase(s) | Example |
|---------|----------|---------|
| `arc-forge-{id}` | Phase 1 Forge | `arc-forge-1772843794749` |
| `arc-plan-review-{id}` | Phase 2 Plan Review | `arc-plan-review-1772843794749` |
| `arc-plan-inspect-{id}` | Phase 2 Plan Inspect | `arc-plan-inspect-1772843794749` |
| `arc-design-{id}` | Phase 3 Design Extraction | `arc-design-1772843794749` |
| `arc-test-{id}` | Phase 7.7 Test | `arc-test-1772843794749` |


## Status Values

### Phase Status
`pending` → `in_progress` → `completed` | `skipped` | `failed`

### Mend Finding Resolution
`FIXED` | `FIXED_CROSS_FILE` | `FALSE_POSITIVE` | `FAILED` | `SKIPPED` | `CONSISTENCY_FIX`

### Convergence Verdicts
`converged` | `retry` | `halted`

## Talisman Key Naming

Arc-related talisman keys follow dot-notation nesting:

```yaml
  disabled: false
  task_decomposition:
    enabled: true          # Feature toggle
  workflows: ["arc"]       # Workflow allowlist

review:
  diff_scope:
    enabled: true          # Scope tagging toggle

goldmask:
  enabled: true            # Master switch
  mend:
    enabled: true          # Mend integration
    inject_context: true   # Fixer prompt injection
    quick_check: true      # Phase 5.95
```

**Convention**: Boolean toggles default to `true` (opt-out). Use `!== false` pattern for safe defaults.
