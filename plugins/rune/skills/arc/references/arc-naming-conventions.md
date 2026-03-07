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

## Checkpoint Phase Keys

Phase keys in `checkpoint.phases` use snake_case and match PHASE_ORDER entries:

```
forge, plan_review, plan_refine, verification, semantic_verification,
task_decomposition, work, gap_analysis, codex_gap_analysis, gap_remediation,
goldmask_verification, code_review, goldmask_correlation, mend, verify_mend,
test, test_coverage_critique, pre_ship_validation, release_quality_check,
bot_review_wait, pr_comment_resolution, ship, merge
```

Conditional phases (gated by talisman):
```
design_extraction, design_verification, design_iteration, ux_verification
```

## Finding Prefixes

| Prefix | Source | Used By |
|--------|--------|---------|
| `CDX-TASK` | Codex task decomposition (Phase 4.5) | task-validation.md |
| `CDX-GAP` | Codex gap analysis (Phase 5.6) | codex-gap-analysis.md |
| `CDX-SEM` | Codex semantic verification (Phase 2.8) | codex-semantic-verification.md |
| `CDX-TEST` | Codex test coverage critique (Phase 7.8) | test-critique.md |
| `CDX-RELEASE` | Codex release quality check (Phase 8.55) | release-quality.md |
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
| `arc-codex-sv-{id}` | Phase 2.8 Semantic Verification | `arc-codex-sv-1772843794749` |
| `arc-codex-td-{id}` | Phase 4.5 Task Decomposition | `arc-codex-td-1772843794749` |
| `arc-codex-ga-{id}` | Phase 5.6 Codex Gap Analysis | `arc-codex-ga-1772843794749` |
| `arc-codex-tc-{id}` | Phase 7.8 Test Coverage Critique | `arc-codex-tc-1772843794749` |
| `arc-codex-rq-{id}` | Phase 8.55 Release Quality Check | `arc-codex-rq-1772843794749` |
| `arc-design-{id}` | Phase 3 Design Extraction | `arc-design-1772843794749` |
| `arc-test-{id}` | Phase 7.7 Test | `arc-test-1772843794749` |

Codex handler teams (`arc-codex-*`) use the `codex-phase-handler` utility agent and are created only when Codex is available.

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
codex:
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
