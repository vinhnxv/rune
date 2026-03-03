# Talisman Sections Reference

Top-level talisman sections with purpose and key fields.
This list reflects the documented schema used by Rune (including default-injected sections), not only uncommented keys in `plugins/rune/talisman.example.yml`.

## Section Map

| # | Section | Purpose | Key Fields |
|---|---------|---------|------------|
| 1 | `version` | Schema version | `1` (only valid value) |
| 2 | `cost_tier` | Agent model selection | `opus` / `balanced` / `efficient` / `minimal` |
| 3 | `rune-gaze` | File classification | `backend_extensions`, `frontend_extensions`, `skip_patterns`, `always_review` |
| 4 | `ashes` | Custom review agents | `custom[].name`, `agent`, `source`, `workflows`, `trigger`, `forge`, `finding_prefix` |
| 5 | `settings` | Global settings | `max_ashes`, `max_cli_ashes`, `dedup_hierarchy`, `convergence_threshold` |
| 6 | `audit` | Audit configuration | `dirs`, `exclude_dirs`, `deep_wave_count`, `max_file_cap` |
| 7 | `defaults` | Default overrides | `scope`, `depth`, `no_merge`, `no_pr` |
| 8 | `inspect` | Plan-vs-code audit | `requirement_match_threshold`, `completeness_threshold`, `dimension_weights` |
| 9 | `arc` | Pipeline config | `defaults`, `ship` (+ `co_authors`), `pre_merge_checks`, `timeouts`, `batch` (+ `smart_ordering`), `gap_analysis` (+ `inspect_enabled`), `sharding`, `consistency` |
| 10 | `solution_arena` | Devise arena phase | `enabled`, `skip_for_types`, `weights.*`, `convergence_threshold` |
| 11 | `devise` | Planning/design system discovery | `design_system_discovery.enabled`, `confidence_threshold` |
| 12 | `deployment_verification` | Deploy artifact generation | `enabled`, `go_no_go`, `rollback_plan`, `monitoring_plan` |
| 13 | `schema_drift` | Migration/model consistency | `enabled`, `frameworks`, `strict`, `ignore_patterns` |
| 14 | `elicitation` | Reasoning methods | `max_parallel_sages`, `phase_filter` |
| 15 | `echoes` | Agent memory | `version_controlled`, `fts_enabled`, `auto_observation`, `scoring`, `groups`, `reranking`, `retry` |
| 16 | `mend` | Finding resolution | `cross_file_batch_size`, `todos_per_fixer` |
| 17 | `review` | Review settings | `diff_scope`, `convergence`, `arc_convergence_*`, `shard_*` |
| 18 | `work` | Work/strive settings | `ward_commands`, `max_workers`, `commit_format`, `co_authors`, `branch_prefix`, `unrestricted_shared_files`, `worktree.*` |
| 19 | `file_todos` | Todo tracking (v2) | `triage`, `manifest`, `history` |
| 20 | `horizon` | Strategic assessment | `enabled`, `min_score`, `dimensions` |
| 21 | `testing` | Test orchestration | `tiers.unit`, `tiers.integration`, `tiers.e2e`, `service.*`, `scenarios.*`, `extended_tier.*`, `contract.*`, `visual_regression.*`, `accessibility.*`, `history.*`, `fixtures.*`, `flaky_detection.*`, `production_readiness.*` |
| 22 | `doubt_seer` | Claim verification | `enabled`, `min_claims`, `verdict_threshold` |
| 23 | `codex` | Cross-model verification | `model`, `workflows`, `timeout`, 17 deep integration keys |
| 24 | `context_monitor` + `context_weaving` | Context management | `enabled`, `warning_threshold`, `glyph_budget`, `offload_threshold`, `pretooluse_guard.enabled` |
| 25 | `debug` | ACH parallel debugging | `max_investigators`, `timeout_ms`, `model`, `re_triage_rounds`, `echo_on_verdict` |
| 26 | `plan` | Research & planning config | `verification_patterns[]`, `freshness` (`enabled`, `warn_threshold`, `block_threshold`, `max_commit_distance`), `external_research` (`"always"` / `"auto"` / `"never"`), `research_urls[]` |
| 27 | `integrations` | MCP tool integrations | `mcp_tools.{namespace}.server_name`, `tools[]`, `phases{}`, `trigger{}`, `skill_binding`, `rules[]`, `metadata{}` |

## Critical Sections (Must-Have)

These sections affect core workflow correctness:

### `codex.workflows`
**Impact**: Controls which Rune workflows can use Codex cross-model verification.
**Critical key**: Must include `arc` for arc phases to use Codex (v1.87.0+).
**Default**: `[review, audit, plan, forge, work, mend, goldmask, inspect, arc]`

### `settings.dedup_hierarchy`
**Impact**: Finding dedup priority order. Missing prefixes = duplicate findings.
**Must include**: All built-in prefixes + stack-specific prefixes.
**Base**: `[SEC, BACK, VEIL, DOUBT, "SH{X}", DOC, QUAL, FRONT, CDX, XSH]`
**Stack prefixes**: PY, TSR, RST, PHP, FAPI, DJG, LARV, SQLA, TDD, DDD, DI

### `file_todos` (schema v2)
**Impact**: Deprecated v1 keys cause warnings. v2 is mandatory since v1.101.0.
**Removed keys**: `enabled`, `dir`, `auto_generate` — delete if present.
**v2 keys**: `triage`, `manifest`, `history`

### `arc.timeouts`
**Impact**: Per-phase timeout controls for arc pipeline.
**Must have**: All 24 phase timeout entries for predictable behavior.

## Stack-Specific Configuration

### Python Projects
```yaml
rune-gaze:
  backend_extensions: [.py]
work:
  ward_commands: ["pytest", "mypy --strict"]
settings:
  dedup_hierarchy: [SEC, BACK, VEIL, DOUBT, PY, "SH{X}", DOC, QUAL, FRONT, CDX, XSH]
  # Add FAPI if FastAPI detected, DJG if Django detected, SQLA if SQLAlchemy detected
```

### TypeScript/Node.js Projects
```yaml
rune-gaze:
  backend_extensions: [.ts]
  frontend_extensions: [.tsx, .jsx]
work:
  ward_commands: ["npm test", "npm run lint"]
settings:
  dedup_hierarchy: [SEC, BACK, VEIL, DOUBT, TSR, "SH{X}", DOC, QUAL, FRONT, CDX, XSH]
```

### Rust Projects
```yaml
rune-gaze:
  backend_extensions: [.rs]
work:
  ward_commands: ["cargo test", "cargo clippy -- -D warnings"]
settings:
  dedup_hierarchy: [SEC, BACK, VEIL, DOUBT, RST, "SH{X}", DOC, QUAL, FRONT, CDX, XSH]
```

### PHP/Laravel Projects
```yaml
rune-gaze:
  backend_extensions: [.php]
  frontend_extensions: [.blade.php]
work:
  ward_commands: ["composer test", "php artisan test"]
settings:
  dedup_hierarchy: [SEC, BACK, VEIL, DOUBT, PHP, LARV, "SH{X}", DOC, QUAL, FRONT, CDX, XSH]
```

### Go Projects
```yaml
rune-gaze:
  backend_extensions: [.go]
work:
  ward_commands: ["go test ./...", "go vet ./..."]
```

## Codex Deep Integration Keys

17 inline cross-model verification points:

| Key | Phase | Default | Purpose |
|-----|-------|---------|---------|
| `elicitation` | Devise/Forge | `true` | Structured reasoning via Codex |
| `mend_verification` | Mend Phase 5.9 | `true` | Post-mend correctness check |
| `arena` | Devise Phase 2.4 | `true` | Solution arena verification |
| `trial_forger` | Testing | `true` | Test generation advisory |
| `rune_smith` | Strive | `true` | Implementation advisory |
| `shatter` | Devise Phase 3.5 | `true` | Shatter assessment scoring |
| `echo_validation` | Echoes | `true` | Echo quality verification |
| `diff_verification` | Appraise Phase 6.2 | `true` | 3-way verdict on findings |
| `test_coverage_critique` | Arc Phase 7.8 | `true` | Test coverage gaps |
| `release_quality_check` | Arc Phase 8.55 | `true` | CHANGELOG validation |
| `section_validation` | Forge Phase 1.7 | `true` | Plan section coverage |
| `research_tiebreaker` | Devise Phase 2.3.5 | `true` | Conflict resolution |
| `task_decomposition` | Arc Phase 4.5 | `true` | Task granularity check |
| `risk_amplification` | Goldmask Phase 3.5 | `false` | 2nd/3rd-order risk chains |
| `drift_detection` | Inspect Phase 1.5 | `false` | Plan-vs-code drift |
| `architecture_review` | Audit Phase 6.3 | `false` | Cross-cutting analysis |
| `post_monitor_critique` | Strive Phase 3.7 | `false` | Post-work architectural critique |

## Arc Timeouts

All 24 phase timeouts (ms):

| Phase | Key | Default |
|-------|-----|---------|
| 1 Forge | `forge` | 900000 |
| 2 Plan Review | `plan_review` | 900000 |
| 2.5 Plan Refine | `plan_refine` | 180000 |
| 2.7 Verification | `verification` | 30000 |
| 2.8 Semantic | `semantic_verification` | 180000 |
| 4.5 Task Decomposition | `task_decomposition` | 180000 |
| 5 Work | `work` | 2100000 |
| 5.5 Gap Analysis | `gap_analysis` | 60000 |
| 5.6 Codex Gap | `codex_gap_analysis` | 660000 |
| 5.8 Gap Remediation | `gap_remediation` | 900000 |
| 5.9 Goldmask Verify | `goldmask_verification` | 300000 |
| 6 Code Review | `code_review` | 900000 |
| 6.2 Audit | `audit` | 1200000 |
| 6.5 Goldmask Corr. | `goldmask_correlation` | 300000 |
| 7 Mend | `mend` | 1380000 |
| 7.5 Verify Mend | `verify_mend` | 240000 |
| 7.7 Test | `test` | 600000 |
| 9 Ship | `ship` | 300000 |
| 9.5 Merge | `merge` | 600000 |
| D1 Design Extraction | `design_extraction` | 300000 |
| D2 Design Iteration | `design_iteration` | 600000 |
| D3 Design Verification | `design_verification` | 300000 |
| — Bot Review Wait | `bot_review_wait` | 900000 |
| — PR Comment Resolution | `pr_comment_resolution` | 1200000 |
