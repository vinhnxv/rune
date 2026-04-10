# Configuration Guide

## Configuration Resolution Chain

When Rune reads `talisman.yml`, it resolves configuration from three sources in priority order (highest to lowest):

1. **`.rune/talisman.yml`** — project-local configuration (highest priority)
2. **`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/talisman.yml`** — global user configuration
3. **Built-in defaults** — hardcoded values used when neither file exists

If both files are present, they are merged with project values overriding global values. Keys present only in the global file are inherited by the project. Keys absent from both files use the built-in defaults listed in the reference tables below.

---

## Complete Config Key Reference

All talisman config keys grouped by section with types, defaults, and descriptions. Use this as the canonical lookup when writing or auditing `talisman.yml`.

### Root Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `version` | number | `1` | Schema version (only `1` valid) |
| `cost_tier` | string | `"balanced"` | Agent model selection: `opus`, `balanced`, `efficient`, `minimal` |

> **`/effort` shorthand**: The `/effort` command is a quick alias for adjusting `cost_tier` interactively without editing talisman.yml directly. It maps effort levels to cost tiers: `/effort high` → `opus`, `/effort medium` → `balanced`, `/effort low` → `efficient`, `/effort minimal` → `minimal`. See [cost-tier-mapping.md](cost-tier-mapping.md) for the full category-to-model resolution logic.

### `rune-gaze` — File Classification

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `rune-gaze.backend_extensions` | string[] | `[.py, .go, .rs, .rb]` | Extensions mapped to backend Ash |
| `rune-gaze.frontend_extensions` | string[] | `[.tsx, .ts, .jsx]` | Extensions mapped to frontend Ash |
| `rune-gaze.infra_extensions` | string[] | `[.sh, .tf, .hcl, ...]` | Extensions mapped to infrastructure |
| `rune-gaze.skip_patterns` | string[] | `[]` | Glob patterns to skip during review |
| `rune-gaze.always_review` | string[] | `[]` | Files always included in review |
| `rune-gaze.extra_backend_extensions` | string[] | `[]` | Additional backend extensions (merged) |
| `rune-gaze.extra_frontend_extensions` | string[] | `[]` | Additional frontend extensions (merged) |

### `ashes.custom[]` — Custom Review Agents

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ashes.custom[].name` | string | — | Unique Ash name (required) |
| `ashes.custom[].agent` | string | — | Agent file name in `.claude/agents/` |
| `ashes.custom[].source` | string | `"local"` | `local` \| `global` \| `plugin` |
| `ashes.custom[].workflows` | string[] | `[review]` | Workflows: `review`, `audit`, `forge` |
| `ashes.custom[].trigger.extensions` | string[] | `[]` | File extensions to match |
| `ashes.custom[].trigger.paths` | string[] | `[]` | Path prefixes to match |
| `ashes.custom[].trigger.topics` | string[] | `[]` | Topic keywords for forge matching |
| `ashes.custom[].forge.subsection` | string | — | Forge section name |
| `ashes.custom[].forge.perspective` | string | — | Enrichment perspective |
| `ashes.custom[].forge.budget` | string | `"enrichment"` | Budget allocation |
| `ashes.custom[].context_budget` | number | `20` | Max files in context |
| `ashes.custom[].finding_prefix` | string | — | Finding prefix (e.g., `"DOM"`) |
| `ashes.custom[].cli` | object | — | CLI-backed Ash config (v1.57.0+) |

### `settings` — Global Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `settings.max_ashes` | number | `9` | Hard cap on total Ashes (built-in + custom) |
| `settings.max_cli_ashes` | number | `2` | Sub-cap on CLI-backed Ashes |
| `settings.dedup_hierarchy` | string[] | `[SEC, BACK, ...]` | Finding dedup priority order |
| `settings.convergence_threshold` | number | `0.7` | Global convergence threshold |

### `audit` — Audit Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `audit.dirs` | string[] | `[]` | Directory whitelist for scoped audits |
| `audit.exclude_dirs` | string[] | `[]` | Directory blacklist |
| `audit.deep_wave_count` | number | `2` | Deep audit wave count |
| `audit.max_file_cap` | number | `200` | Max files per audit session |

### `defaults` — Default Overrides

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `defaults.scope` | string | `"diff"` | `diff` \| `full` |
| `defaults.depth` | string | `"standard"` | `standard` \| `deep` |

### `forge` — Forge Gaze Selection

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `forge.threshold` | number | `0.30` | Gaze score threshold (0.0–1.0) |
| `forge.max_per_section` | number | `3` | Max agents per forge section (cap: 5) |
| `forge.max_total_agents` | number | `8` | Max total forge agents (cap: 15) |
| `forge.model` | string | — | Override forge agent model |

### `brainstorm` — Brainstorm Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `brainstorm.default_mode` | string | `"roundtable"` | Default mode: `solo`, `roundtable`, `deep` |
| `brainstorm.max_rounds` | number | `5` | Max discussion rounds in roundtable/deep mode |
| `brainstorm.advisor_timeout_ms` | number | `60000` | Per-round advisor response timeout (ms) |
| `brainstorm.persistent_output` | boolean | `true` | Save output to `docs/brainstorms/` (false = `tmp/` only) |

### `plan` — Plan Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `plan.template` | string | `"standard"` | Plan template: `minimal`, `standard`, `comprehensive` |
| `plan.brainstorm_agents` | number | `3` | Brainstorm agent count |
| `plan.research_agents` | number | `4` | Research agent count |
| `plan.synthesis_model` | string | — | Override synthesis model |
| `plan.shatter.enabled` | boolean | `true` | Enable shatter assessment |
| `plan.shatter.threshold` | number | `70` | Min shatter score to proceed |
| `plan.forge_after_synthesis` | boolean | `true` | Auto-forge after synthesis |

### `integrations` — MCP Tool Integrations

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `integrations.mcp_tools.{namespace}.server_name` | string | — | MCP server key (must match `.mcp.json`). Required. |
| `integrations.mcp_tools.{namespace}.tools` | array | — | Tool declarations. Each: `{ name: string, category: string }`. Required. |
| `integrations.mcp_tools.{namespace}.tools[].name` | string | — | MCP tool name (must match MCP server tool). |
| `integrations.mcp_tools.{namespace}.tools[].category` | string | — | Semantic category: `search`, `details`, `compose`, `suggest`, `generate`, `validate`. |
| `integrations.mcp_tools.{namespace}.phases` | object | — | Phase routing. Keys: `devise`, `strive`, `forge`, `appraise`, `audit`, `arc`. Values: boolean. Required. |
| `integrations.mcp_tools.{namespace}.trigger` | object | — | Activation conditions. Required. |
| `integrations.mcp_tools.{namespace}.trigger.extensions` | string[] | `[]` | File extensions to match (e.g., `[".tsx", ".ts"]`). |
| `integrations.mcp_tools.{namespace}.trigger.paths` | string[] | `[]` | Path prefixes to match (e.g., `["src/api/"]`). |
| `integrations.mcp_tools.{namespace}.trigger.keywords` | string[] | `[]` | Task description keywords (case-insensitive). |
| `integrations.mcp_tools.{namespace}.trigger.always` | boolean | `false` | Override: skip all trigger checks. |
| `integrations.mcp_tools.{namespace}.skill_binding` | string | — | Companion skill name (auto-loaded when active). Optional. |
| `integrations.mcp_tools.{namespace}.rules` | string[] | `[]` | Rule file paths (project-relative, no `..`). Optional. Max 5 per integration. Truncated to 2000 chars. |
| `integrations.mcp_tools.{namespace}.metadata` | object | `{}` | Discovery metadata. Optional. Known keys: `library_name`, `component_count`, `version`, `homepage`. |

See [docs/guides/mcp-integration-spec.en.md](../../../docs/guides/mcp-integration-spec.en.md) for the full developer guide.

### `inspect` — Plan-vs-Code Audit

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `inspect.requirement_match_threshold` | number | `0.7` | Requirement matching confidence |
| `inspect.completeness_threshold` | number | `0.8` | Min completeness to pass |
| `inspect.dimension_weights` | object | — | Per-dimension scoring weights |
| `inspect.model` | string | — | Override inspector model |
| `inspect.max_inspectors` | number | `4` | Max inspector agents |

### `arc` — Pipeline Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `arc.defaults.no_forge` | boolean | `false` | Skip forge phase (CLI: `--no-forge`) |
| `arc.defaults.approve` | boolean | `false` | Auto-approve tasks (CLI: `--approve`) |
| `arc.defaults.skip_freshness` | boolean | `false` | Skip freshness gate (CLI: `--skip-freshness`) |
| `arc.defaults.confirm` | boolean | `false` | Require confirmation (CLI: `--confirm`) |
| `arc.defaults.accept_external_changes` | boolean | `true` | Accept external commits on branch without prompting (CLI: `--no-accept-external` to disable). |
| `arc.sharding.enabled` | boolean | `true` | Enable plan sharding |
| `arc.sharding.exclude_parent` | boolean | `true` | Auto-exclude parent plans |
| `arc.sharding.prerequisite_check` | boolean | `true` | Verify shard prerequisites |
| `arc.sharding.shared_branch` | boolean | `true` | Share feature branch across shards |
| `arc.ship.auto_pr` | boolean | `true` | Auto-create PR |
| `arc.ship.auto_merge` | boolean | `false` | Auto-merge PR |
| `arc.ship.merge_strategy` | string | `"squash"` | `squash` \| `merge` \| `rebase` |
| `arc.ship.wait_ci` | boolean | `false` | Wait for CI before merge |
| `arc.ship.draft` | boolean | `false` | Create PR as draft |
| `arc.ship.labels` | string[] | `[]` | PR labels |
| `arc.ship.pr_monitoring` | boolean | `false` | Post-deploy monitoring in PR |
| `arc.ship.rebase_before_merge` | boolean | `true` | Rebase before merge |
| `arc.ship.co_authors` | string[] | `[]` | Co-Authored-By for arc PRs (falls back to `work.co_authors`) |
| `arc.pre_merge_checks.migration_conflict` | boolean | `true` | Check migration conflicts |
| `arc.pre_merge_checks.schema_conflict` | boolean | `true` | Check schema drift |
| `arc.pre_merge_checks.lock_file_conflict` | boolean | `true` | Check lock file conflicts |
| `arc.pre_merge_checks.uncommitted_changes` | boolean | `true` | Check uncommitted changes |
| `arc.pre_merge_checks.migration_paths` | string[] | `[]` | Additional migration scan paths |
| `arc.gap_analysis.inspectors` | number\|string[] | `2` | Inspector count or name list |
| `arc.gap_analysis.halt_threshold` | number | `50` | Score below this = halt |
| `arc.gap_analysis.inspect_enabled` | boolean | `true` | Enable Inspector Ashes in gap analysis |
| `arc.gap_analysis.remediation.enabled` | boolean | `true` | Enable auto-fix of gaps |
| `arc.gap_analysis.remediation.max_fixes` | number | `20` | Cap on fixable gaps |
| `arc.gap_analysis.remediation.timeout` | number | `600000` | Inner timeout (ms) |
| `arc.batch.smart_ordering.enabled` | boolean | `true` | Enable smart plan ordering |
| `arc.consistency.checks[]` | object[] | `[]` | Cross-file consistency checks |
| `arc.quick.max_iterations` | number | `3` | Max work+evaluate iterations (0 = skip evaluator) |
| `arc.quick.evaluate_timeout_ms` | number | `60000` | Evaluator timeout per iteration |
| `arc.quick.skip_evaluate` | boolean | `false` | Disable evaluator (revert to linear behavior) |

### `arc.timeouts` — Per-Phase Timeouts (ms)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `arc.timeouts.forge` | number | `900000` | Phase 1: Forge (15 min) |
| `arc.timeouts.plan_review` | number | `900000` | Phase 2: Plan review (15 min) |
| `arc.timeouts.plan_refine` | number | `180000` | Phase 2.5: Refinement (3 min) |
| `arc.timeouts.verification` | number | `30000` | Phase 2.7: Verification (30s) |
| `arc.timeouts.semantic_verification` | number | `180000` | Phase 2.8: Semantic (3 min) |
| `arc.timeouts.task_decomposition` | number | `180000` | Phase 4.5: Task decomposition (3 min) |
| `arc.timeouts.work` | number | `2100000` | Phase 5: Work (35 min) |
| `arc.timeouts.gap_analysis` | number | `720000` | Phase 5.5: Gap analysis (12 min) |
| `arc.timeouts.codex_gap_analysis` | number | `660000` | Phase 5.6: Codex gap (11 min) |
| `arc.timeouts.gap_remediation` | number | `900000` | Phase 5.8: Remediation (15 min) |
| `arc.timeouts.goldmask_verification` | number | `900000` | Phase 5.9: Goldmask verify (15 min) |
| `arc.timeouts.code_review` | number | `900000` | Phase 6: Code review (15 min) |
| `arc.timeouts.goldmask_correlation` | number | `60000` | Phase 6.5: Correlation (1 min) |
| `arc.timeouts.mend` | number | `1380000` | Phase 7: Mend (23 min) |
| `arc.timeouts.verify_mend` | number | `240000` | Phase 7.5: Verify mend (4 min) |
| `arc.timeouts.test` | number | `900000` | Phase 7.7: Test (15 min) |
| `arc.timeouts.browser_test` | number | `900000` | Phase 7.7.5: Browser E2E test (15 min) |
| `arc.timeouts.browser_test_fix` | number | `900000` | Phase 7.7.6: Browser test fix (15 min) |
| `arc.timeouts.verify_browser_test` | number | `240000` | Phase 7.7.7: Verify browser test (4 min) |
| `arc.timeouts.ship` | number | `300000` | Phase 9: Ship (5 min) |
| `arc.timeouts.merge` | number | `600000` | Phase 9.5: Merge (10 min) |
| `arc.timeouts.design_extraction` | number | `300000` | Phase 3: Design extraction (5 min) |
| `arc.timeouts.design_prototype` | number | `600000` | Phase 3.2: Design prototype generation (10 min) |
| `arc.timeouts.design_verification` | number | `300000` | Phase 5.2: Design fidelity (5 min) |
| `arc.timeouts.design_iteration` | number | `600000` | Phase 7.6: Design iteration (10 min) |

### `solution_arena` — Devise Arena Phase

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `solution_arena.enabled` | boolean | `true` | Enable Arena in `/rune:devise` |
| `solution_arena.skip_for_types` | string[] | `["fix"]` | Types that skip Arena |
| `solution_arena.weights.feasibility` | number | `0.25` | Feasibility weight |
| `solution_arena.weights.complexity` | number | `0.20` | Complexity weight |
| `solution_arena.weights.risk` | number | `0.20` | Risk weight |
| `solution_arena.weights.maintainability` | number | `0.15` | Maintainability weight |
| `solution_arena.weights.performance` | number | `0.10` | Performance weight |
| `solution_arena.weights.innovation` | number | `0.10` | Innovation weight |
| `solution_arena.convergence_threshold` | number | `0.05` | Tied-score margin |

### `deployment_verification` — Deploy Artifact Generation

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `deployment_verification.enabled` | boolean | `true` | Enable deployment verification |
| `deployment_verification.go_no_go` | boolean | `true` | Generate Go/No-Go checklist |
| `deployment_verification.rollback_plan` | boolean | `true` | Generate rollback procedure |
| `deployment_verification.monitoring_plan` | boolean | `true` | Generate monitoring plan |

### `schema_drift` — Migration/Model Consistency

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `schema_drift.enabled` | boolean | `true` | Enable schema drift detection |
| `schema_drift.frameworks` | string[] | `[auto]` | Framework auto-detection or explicit list |
| `schema_drift.strict` | boolean | `false` | Strict mode (block on any drift) |
| `schema_drift.ignore_patterns` | string[] | `[]` | Patterns to ignore in drift checks |

### `elicitation` — Reasoning Methods

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `elicitation.enabled` | boolean | `true` | Enable sage invocations |

### `echoes` — Memory Persistence

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `echoes.version_controlled` | boolean | `false` | Track echoes in git |
| `echoes.fts_enabled` | boolean | `true` | Enable FTS5/MCP echo search |
| `echoes.auto_observation` | boolean | `true` | Auto-record Observations after tasks |
| `echoes.scoring.validation_mode` | boolean | `false` | Dual scoring for validation |
| `echoes.groups.enabled` | boolean | `true` | Enable semantic groups |
| `echoes.groups.similarity_threshold` | number | `0.60` | Clustering threshold |
| `echoes.groups.max_group_size` | number | `10` | Max entries per group |
| `echoes.groups.score_discount` | number | `0.85` | Score discount for expanded entries |
| `echoes.reranking.enabled` | boolean | `true` | Enable Haiku reranking |
| `echoes.reranking.top_n` | number | `10` | Entries to rerank |
| `echoes.retry.enabled` | boolean | `true` | Enable retry injection |
| `echoes.retry.max_retries` | number | `2` | Max retry suggestions |

### `mend` — Finding Resolution

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `mend.cross_file_batch_size` | number | `3` | Files per cross-file batch |

### `review` — Review Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `review.diff_scope.enabled` | boolean | `true` | Enable diff range generation |
| `review.diff_scope.expansion` | number | `8` | Context lines per hunk |
| `review.diff_scope.tag_pre_existing` | boolean | `true` | Tag pre-existing findings |
| `review.diff_scope.fix_pre_existing_p1` | boolean | `true` | Fix pre-existing P1 |
| `review.convergence.smart_scoring` | boolean | `true` | Smart convergence scoring |
| `review.convergence.convergence_threshold` | number | `0.7` | Score threshold |
| `review.large_diff_threshold` | number | `25` | Chunked mode file threshold |
| `review.chunk_size` | number | `15` | Files per chunk |
| `review.shard_threshold` | number | `15` | Sharding activation threshold |
| `review.shard_size` | number | `12` | Max files per shard |
| `review.max_shards` | number | `5` | Max parallel shards |
| `review.cross_shard_sentinel` | boolean | `true` | Enable cross-shard sentinel |
| `review.shard_model_policy` | string | `"auto"` | Shard model selection |
| `review.reshard_threshold` | number | `30` | Re-review shard guard |
| `review.arc_convergence_tier_override` | string\|null | `null` | Force convergence tier |
| `review.arc_convergence_max_cycles` | number\|null | `null` | Hard max cycles |
| `review.arc_convergence_min_cycles` | number\|null | `null` | Min cycles before convergence |
| `review.arc_convergence_finding_threshold` | number | `0` | P1 threshold for convergence |
| `review.arc_convergence_p2_threshold` | number | `0` | P2 threshold |
| `review.arc_convergence_improvement_ratio` | number | `0.5` | Required improvement ratio |
| `review.context_building` | string | `"auto"` | Context building gate: `auto` (trigger on large diffs), `always`, `never` |
| `review.context_building_threshold.lines` | number | `500` | Diff line count threshold for auto mode (50-10000) |
| `review.context_building_threshold.files` | number | `5` | File count threshold for auto mode (2-100) |
| `review.context_building_timeout` | number | `60000` | Context builder timeout in ms (10000-300000) |

### `work` — Swarm Execution

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `work.ward_commands` | string[] | `[]` | Quality gate commands |
| `work.max_workers` | number | `3` | Max parallel workers |
| `work.approve_timeout` | number | `180` | Task approval timeout (s) |
| `work.commit_format` | string | `"rune: {subject} [ward-checked]"` | Commit template |
| `work.skip_branch_check` | boolean | `false` | Skip branch check |
| `work.branch_prefix` | string | `"rune/work"` | Branch name prefix |
| `work.pr_monitoring` | boolean | `false` | PR monitoring section |
| `work.co_authors` | string[] | `[]` | Co-Authored-By lines |
| `work.unrestricted_shared_files` | string[] | `[]` | Files bypassing SEC-STRIVE-001 |
| `work.worktree.enabled` | boolean | `false` | Default worktree mode |
| `work.worktree.max_workers_per_wave` | number | `3` | Workers per worktree wave |
| `work.worktree.merge_strategy` | string | `"sequential"` | Merge strategy |
| `work.worktree.auto_cleanup` | boolean | `true` | Remove worktrees after merge |
| `work.worktree.conflict_resolution` | string | `"escalate"` | `escalate` \| `abort` |
| `work.hierarchy.enabled` | boolean | `true` | Hierarchical plan support |
| `work.complexity_ordering.enabled` | boolean | `true` | Enable complexity-aware task ordering in Phase 0 |
| `work.complexity_ordering.weights.file` | number | `2` | Weight for file count in complexity score |
| `work.complexity_ordering.weights.test_bonus` | number | `3` | Bonus weight for tasks involving test files |
| `work.complexity_ordering.weights.refactor_bonus` | number | `5` | Bonus weight for refactoring tasks |
| `work.complexity_ordering.weights.large_scope_bonus` | number | `3` | Bonus weight for large-scope tasks (many files) |
| `work.file_lock_signals.enabled` | boolean | `true` | Enable file lock signals for worker file ownership |
| `work.file_lock_signals.stale_threshold_ms` | number | `600000 (10 minutes)` | Stale lock threshold — locks older than this are considered orphaned |
| `work.reassignment.enabled` | boolean | `false` | Enable smart task reassignment in Phase 3 monitoring |
| `work.reassignment.multiplier` | number | `2` | Time multiplier before a task is eligible for reassignment |
| `work.reassignment.grace_seconds` | number | `30` | Grace period (s) after reassignment before re-checking |
| `work.adaptive_wave.enabled` | boolean | `false` | Enable adaptive wave sizing (dynamic worker count per wave) _(reference pseudocode — requires SKILL.md wiring to take effect)_ |
| `work.adaptive_wave.failure_threshold` | number | `0.3` | Failure rate above which worker count shrinks by 1 _(reference pseudocode — requires SKILL.md wiring to take effect)_ |
| `work.adaptive_wave.speed_threshold` | number | `0.5` | Completion ratio below which worker count grows by 1 _(reference pseudocode — requires SKILL.md wiring to take effect)_ |
| `work.adaptive_wave.min_workers` | number | `1` | Minimum workers per wave — floor for adaptive sizing _(reference pseudocode — requires SKILL.md wiring to take effect)_ |

### `teammate_lifecycle` — Teammate Runtime Limits

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `teammate_lifecycle.max_runtime_minutes` | number | `20` | Maximum runtime per teammate (minutes) before it is considered stale and eligible for cleanup |

### `file_todos` — Todo Tracking

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `file_todos.triage.auto_approve_p1` | boolean | `false` | Auto-approve P1 items |
| `file_todos.manifest.auto_build` | boolean | `true` | Auto-rebuild manifest |
| `file_todos.manifest.dedup_on_build` | boolean | `false` | Dedup on build |
| `file_todos.manifest.dedup_threshold` | number | `0.70` | Dedup confidence |
| `file_todos.history.enabled` | boolean | `true` | Status History tracking |

### `horizon` — Strategic Assessment

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `horizon.enabled` | boolean | `true` | Kill switch |
| `horizon.intent_default` | string | `"long-term"` | Default strategic intent |

### `testing` — Arc Phase 7.7

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `testing.enabled` | boolean | `true` | Master toggle |
| `testing.tiers.unit.enabled` | boolean | `true` | Run unit tests |
| `testing.tiers.unit.timeout_ms` | number | `300000` | Unit test timeout |
| `testing.tiers.unit.coverage` | boolean | `true` | Collect coverage |
| `testing.tiers.integration.enabled` | boolean | `true` | Run integration tests |
| `testing.tiers.integration.timeout_ms` | number | `300000` | Integration timeout |
| `testing.tiers.e2e.enabled` | boolean | `true` | Run E2E tests |
| `testing.browser_test.enabled` | boolean | `true` | Master switch for browser test convergence loop (Arc Phase 7.7.5-7.7.7) |
| `testing.browser_test.max_cycles` | number | `3` | Max test→fix→verify iterations before halting |
| `testing.browser_test.max_routes` | number | `5` | Max routes per browser test run |
| `testing.browser_test.auto_start_server` | boolean | `true` | Try to start dev server if not running |
| `testing.browser_test.fix_timeout` | number | `900000` | Timeout per fix round in milliseconds (15 min) |

### `inner_flame` — Self-Review Protocol

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `inner_flame.enabled` | boolean | `true` | Kill switch |
| `inner_flame.block_on_fail` | boolean | `false` | Block on missing self-review |
| `inner_flame.confidence_floor` | number | `60` | Minimum confidence |
| `inner_flame.completeness_scoring.enabled` | boolean | `true` | Enable completeness scoring |

### `doubt_seer` — Evidence Challenger

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `doubt_seer.enabled` | boolean | `false` | Opt-in |
| `doubt_seer.workflows` | string[] | `[review, audit]` | Active workflows |
| `doubt_seer.challenge_threshold` | string | `"P2"` | Min severity to challenge |
| `doubt_seer.max_challenges` | number | `20` | Max findings to challenge |
| `doubt_seer.block_on_unproven` | boolean | `false` | Block on unproven P1 |
| `doubt_seer.unproven_threshold` | number | `0.8` | Evidence ratio threshold |

### `state_weaver` — Plan State Machine Validation

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `state_weaver.enabled` | boolean | `true` | Kill switch — set false to disable state-weaver globally |

### `codex` — Cross-Model Verification

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `codex.disabled` | boolean | `false` | Kill switch |
| `codex.model` | string | `"gpt-5.3-codex"` | Codex model |
| `codex.reasoning` | string | `"xhigh"` | Reasoning effort |
| `codex.sandbox` | string | `"read-only"` | Sandbox mode |
| `codex.context_budget` | number | `20` | Max files per session |
| `codex.confidence_threshold` | number | `80` | Min confidence % |
| `codex.timeout` | number | `600` | GNU timeout (s) |
| `codex.stream_idle_timeout` | number | `540` | Stream idle timeout (s) |
| `codex.workflows` | string[] | `[review, audit, arc, ...]` | Active workflows |
| `codex.work_advisory.enabled` | boolean | `true` | Work advisory |
| `codex.review_diff.enabled` | boolean | `true` | Diff-focused review |
| `codex.verification.enabled` | boolean | `true` | Cross-model verification |
| `codex.diff_verification.enabled` | boolean | `true` | Appraise diff verify |
| `codex.test_coverage_critique.enabled` | boolean | `true` | Test coverage gaps |
| `codex.release_quality_check.enabled` | boolean | `true` | CHANGELOG validation |
| `codex.section_validation.enabled` | boolean | `true` | Forge section check |
| `codex.research_tiebreaker.enabled` | boolean | `true` | Conflict resolution |
| `codex.task_decomposition.enabled` | boolean | `true` | Task granularity |
| `codex.risk_amplification.enabled` | boolean | `false` | Risk chains (opt-in) |
| `codex.drift_detection.enabled` | boolean | `false` | Drift detection (opt-in) |
| `codex.architecture_review.enabled` | boolean | `false` | Architecture review (opt-in) |
| `codex.post_monitor_critique.enabled` | boolean | `false` | Post-work critique (opt-in) |
| `codex.gap_analysis.enabled` | boolean | `true` | Gap analysis |
| `codex.gap_analysis.remediation_threshold` | number | `5` | Remediation trigger |
| `codex.trial_forger.enabled` | boolean | `true` | Test generation |
| `codex.rune_smith.enabled` | boolean | `false` | Implementation advisory |

### `context_monitor` — Token Usage Monitoring

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `context_monitor.enabled` | boolean | `true` | Master toggle |
| `context_monitor.warning_threshold` | number | `35` | Warning at remaining% |
| `context_monitor.critical_threshold` | number | `25` | Critical stop at remaining% |
| `context_monitor.caution_threshold` | number | `40` | Advisory caution at remaining% |
| `context_monitor.stale_seconds` | number | `60` | Bridge file max age |
| `context_monitor.debounce_calls` | number | `5` | Calls between warnings |
| `context_monitor.degradation_suggestions` | boolean | `true` | Inject degradation suggestions |
| `context_monitor.workflows` | string[] | `[review, audit, ...]` | Active workflows |
| `context_monitor.pretooluse_guard.enabled` | boolean | `true` | CTX-GUARD-001 toggle |

### `context_weaving` — Context Management

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `context_weaving.glyph_budget.enabled` | boolean | `true` | Glyph budget monitoring |
| `context_weaving.glyph_budget.word_limit` | number | `300` | Word limit per SendMessage |
| `context_weaving.offload_threshold` | number | `0.6` | Context offload activation ratio |

### `goldmask` — Impact Analysis

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `goldmask.enabled` | boolean | `true` | Master switch |
| `goldmask.forge.enabled` | boolean | `true` | Lore Layer in forge |
| `goldmask.mend.enabled` | boolean | `true` | Mend integration |
| `goldmask.mend.inject_context` | boolean | `true` | Risk context in fixer prompts |
| `goldmask.mend.quick_check` | boolean | `true` | Quick check after mend |
| `goldmask.devise.depth` | string | `"enhanced"` | `basic` \| `enhanced` \| `full` |
| `goldmask.inspect.enabled` | boolean | `true` | Lore Layer in inspect |
| `goldmask.inspect.wisdom_passthrough` | boolean | `true` | Wisdom advisories |

### `stack_awareness` — Stack Detection

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `stack_awareness.enabled` | boolean | `true` | Master switch |
| `stack_awareness.confidence_threshold` | number | `0.6` | Detection threshold |
| `stack_awareness.max_stack_ashes` | number | `3` | Max specialist Ashes |
| `stack_awareness.override.primary_language` | string | — | Override detected language |
| `stack_awareness.override.frameworks` | string[] | — | Override detected frameworks |
| `stack_awareness.custom_rules[]` | object[] | `[]` | Project-specific routing rules |

### `design_sync` — Figma Design Sync

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `design_sync.enabled` | boolean | `false` | Master switch |
| `design_sync.max_extraction_workers` | number | `2` | Extraction workers |
| `design_sync.max_implementation_workers` | number | `3` | Implementation workers |
| `design_sync.max_iteration_workers` | number | `2` | Iteration workers |
| `design_sync.max_iterations` | number | `5` | Max fidelity rounds |
| `design_sync.iterate_enabled` | boolean | `false` | Enable iteration loop |
| `design_sync.fidelity_threshold` | number | `80` | Min fidelity score |
| `design_sync.token_snap_distance` | number | `20` | Color token snapping |
| `design_sync.figma_cache_ttl` | number | `1800` | API cache TTL (s) |
| `design_sync.design_tools` | string[] | `[figma]` | Tool integrations |

### `debug` — ACH Parallel Debugging

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `debug.max_investigators` | number | `4` | Max parallel investigators (1-6) |
| `debug.timeout_ms` | number | `420000` | Per-round timeout (7 min) |
| `debug.model` | string | `"sonnet"` | Investigator model |
| `debug.re_triage_rounds` | number | `1` | Max re-triage rounds |
| `debug.echo_on_verdict` | boolean | `true` | Persist verdict to echoes |

---

Projects can override defaults via `.rune/talisman.yml` (project) or `~/.claude/talisman.yml` (global, via CLAUDE_CONFIG_DIR):

```yaml
rune-gaze:
  backend_extensions: [.py, .go]
  frontend_extensions: [.tsx, .ts]
  skip_patterns: ["**/migrations/**"]
  always_review: ["CLAUDE.md", ".rune/**/*.md", ".claude/**/*.md"]

# Custom Ashes — extend the built-in 7
ashes:
  custom:
    - name: "domain-logic-reviewer"
      agent: "domain-logic-reviewer"    # local .claude/agents/ or plugin namespace
      source: local                     # local | global | plugin
      workflows: [review, audit, forge] # forge enables Forge Gaze matching
      trigger:
        extensions: [".py", ".rb"]
        paths: ["src/domain/"]
        topics: [domain, business-logic, models, services]  # For forge
      forge:
        subsection: "Domain Logic Analysis"
        perspective: "domain model integrity and business rule correctness"
        budget: enrichment
      context_budget: 20
      finding_prefix: "DOM"

settings:
  max_ashes: 9                   # Hard cap (7 built-in + custom)
  dedup_hierarchy: [SEC, BACK, VEIL, DOUBT, "SH{X}", DOC, QUAL, FRONT, CDX, XSH]

forge:                                 # Forge Gaze selection overrides
  threshold: 0.30                      # Score threshold (0.0-1.0)
  max_per_section: 3                   # Max agents per section (cap: 5)
  max_total_agents: 8                  # Max total agents (cap: 15)

codex:                                 # Codex CLI integration (see codex-cli skill for full details)
  disabled: false                      # Kill switch — skip Codex entirely
  model: "gpt-5.3-codex"        # Model for codex exec
  reasoning: "xhigh"                  # Reasoning effort (xhigh | high | medium | low)
  timeout: 600                         # Outer GNU timeout in seconds for codex exec (default: 600, range: 300-3600)
  stream_idle_timeout: 540             # Inner stream idle timeout — kills codex if no output for this duration (default: 540, range: 10-timeout)
  workflows: [review, audit, plan, forge, work, mend, goldmask, inspect]  # Which pipelines use Codex
  work_advisory:
    enabled: true                      # Codex advisory in /rune:strive
  gap_analysis:
    remediation_threshold: 5           # Actionable Codex findings (MISSING/INCOMPLETE/DRIFT, excluding EXTRA) to trigger Phase 5.8 via Codex gate (default: 5, range: [1, 20] — RUIN-001 clamp)
  # ── Codex Expansion (v1.51.0+) — 17 new inline cross-model verification points ──
  diff_verification:                   # Appraise Phase 6.2 — 3-way verdict on P1/P2 findings vs diff hunks
    enabled: true                      # ON by default (CDX-VERIFY prefix)
  test_coverage_critique:              # Arc Phase 7.8 — test coverage gaps after test phase
    enabled: true                      # ON by default (CDX-TEST prefix)
  release_quality_check:               # Arc Phase 8.55 — CHANGELOG + breaking changes validation
    enabled: true                      # ON by default (CDX-RELEASE prefix, advisory only)
  section_validation:                  # Forge Phase 1.7 — plan section coverage check
    enabled: true                      # ON by default (CDX-SECTION prefix)
  research_tiebreaker:                 # Devise Phase 2.3.5 — conflict resolution (conditional)
    enabled: true                      # ON by default, usually skips (CDX-TIEBREAKER tag)
  task_decomposition:                  # Arc Phase 4.5 — task granularity + dependency validation
    enabled: true                      # ON by default (CDX-TASK prefix)
  risk_amplification:                  # Goldmask Phase 3.5 — 2nd/3rd-order risk chains
    enabled: false                     # OFF — greenfield, opt-in (CDX-RISK prefix)
  drift_detection:                     # Inspect Phase 1.5 — plan-vs-code semantic drift
    enabled: false                     # OFF — greenfield, opt-in (CDX-INSPECT-DRIFT prefix)
  architecture_review:                 # Audit Phase 6.3 — cross-cutting TOME analysis
    enabled: false                     # OFF — audit-only niche (CDX-ARCH prefix)
  post_monitor_critique:               # Strive Phase 3.7 — post-work architectural critique
    enabled: false                     # OFF — limited actionability (CDX-ARCH-STRIVE prefix)

solution_arena:
  enabled: true                    # Enable Arena phase in /rune:devise
  skip_for_types: ["fix"]          # Feature types that skip Arena
  # weights:                         # Arena scoring dimension weights (must sum to 1.0)
  #   feasibility: 0.25
  #   complexity: 0.20
  #   risk: 0.20
  #   maintainability: 0.15
  #   performance: 0.10
  #   innovation: 0.10
  # convergence_threshold: 0.05      # Top 2 solutions within this margin = "tied"

echoes:
  version_controlled: false
  fts_enabled: true                    # Enable FTS5/MCP echo search. Set false to disable MCP server.
  # auto_observation: true             # Auto-record Observations-tier echoes after task completion

review:
  # Context building (v2.44.0+) — architectural comprehension before Ash review
  context_building: "auto"               # "auto" | "always" | "never" — gate context-builder agent
  context_building_threshold:
    lines: 500                           # Trigger when diff exceeds N lines (50-10000)
    files: 5                             # Trigger when N+ files changed (2-100)
  context_building_timeout: 60000        # Max ms for context-builder agent (10000-300000)
  # Diff-scope tagging (v1.38.0+) — generates line-level diff ranges for scope-aware review
  diff_scope:
    enabled: true                        # Enable diff range generation and TOME tagging
    expansion: 8                         # Context lines above/below each hunk (0-50)
    tag_pre_existing: true               # Tag unchanged-code findings as "pre-existing"
    fix_pre_existing_p1: true            # Always fix pre-existing P1 findings in mend
  # Smart convergence scoring (v1.38.0+) — scope-aware composite scoring
  convergence:
    smart_scoring: true                  # Enable smart convergence scoring
    convergence_threshold: 0.7           # Score >= this = converged (0.1-1.0)
  # Arc convergence (v1.37.0+, enhanced v1.41.0) — controls Phase 6→7→7.5 loop
  # arc_convergence_min_cycles: null     # Min re-review cycles (1-maxCycles, default: tier-based)
  # arc_convergence_p2_threshold: 0      # P2 findings below this count = eligible (default: 0)

work:
  ward_commands: ["make check", "npm test"]
  max_workers: 3
  approve_timeout: 180                   # Seconds (default 3 min)
  commit_format: "rune: {subject} [ward-checked]"
  skip_branch_check: false               # Skip Phase 0.5 branch check
  branch_prefix: "rune/work"             # Branch name prefix (alphanumeric, _, -, / only)
  pr_monitoring: false                    # Post-deploy monitoring in PR body
  # pr_template: default                 # Reserved for a future release (default | minimal)
  # auto_push: false                     # Reserved for a future release (auto-push without confirmation)
  co_authors: []                         # Co-Authored-By lines in "Name <email>" format

inner_flame:
  enabled: true                   # Kill switch (default: true)
  block_on_fail: false            # Hook blocks on missing Self-Review Log (default: false = warn only)
  confidence_floor: 60            # Prompt-enforced confidence minimum (default: 60)
```

## Platform Environment Configuration

Agent Teams workflows operate under platform-level timeouts that are configured
via environment variables in `~/.claude/settings.json`, NOT in `talisman.yml`.
These affect ALL teammates.

### Recommended Settings

Add to `~/.claude/settings.json` (or `.claude/settings.local.json` for project-specific overrides):

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "BASH_DEFAULT_TIMEOUT_MS": "600000",
    "BASH_MAX_TIMEOUT_MS": "3600000"
  }
}
```

### Environment Variable Reference

| Variable | Default | Recommended | Purpose |
|----------|---------|-------------|---------|
| `BASH_DEFAULT_TIMEOUT_MS` | 120,000 (2 min) | 600,000 (10 min) | Bash command timeout. Ward checks often exceed 2 min. |
| `BASH_MAX_TIMEOUT_MS` | 120,000 (2 min) | 3,600,000 (60 min) | Max allowed Bash timeout. Caps per-call timeout parameter. |
| `MCP_TIMEOUT` | ~10,000 (10 sec) | 30,000 (30 sec) | MCP server connection timeout. Increase for slow-starting servers. |
| `MCP_TOOL_TIMEOUT` | ~60,000 (60 sec) | 60,000 (60 sec) | Single MCP tool invocation timeout. Default is usually sufficient. |
| `MAX_MCP_OUTPUT_TOKENS` | 25,000 | 50,000 | Max tokens from a single MCP tool response. |

> **Note**: These values are approximate as of Claude Code v1.x. Platform defaults may change between versions. Periodically verify against official Claude Code documentation.

### Timeout Layer Model

Agent Teams workflows have concurrent timeout layers. The shortest applicable
timeout wins. Rune controls layers 5-7 (application level). Layers 1-4 are platform-level:

| Layer | Mechanism | Default | Config | Rune Interaction |
|-------|-----------|---------|--------|------------------|
| 1 | Bash tool timeout | 2 min | `BASH_DEFAULT_TIMEOUT_MS` | Ward checks, test suites, build commands |
| 2a | MCP connection | 10 sec | `MCP_TIMEOUT` | Context7 queries, Codex detection |
| 2b | MCP tool invocation | 60 sec | `MCP_TOOL_TIMEOUT` | Per-tool call timeout |
| 3 | Teammate heartbeat | 5 min | Not configurable (SDK hardcoded) | DC-3 Fading Ash detection aligns at 5 min |
| 4 | SSE/API connection | ~5 min | Not configurable | Empty responses on long MCP calls |
| 5 | Polling stale detection | 5 min | `staleWarnMs` in monitor-utility | DC-3 auto-release at 10 min (work/mend/forge) |
| 6 | Phase timeout | 15-35 min | `PHASE_TIMEOUTS` in arc.md, talisman.yml | Circuit breaker per phase |
| 7 | Arc total timeout | 162-240 min | Dynamic per tier | Pipeline ceiling |

> **Important**: `staleWarnMs` (configurable) should be >= SDK heartbeat (5 min, hardcoded). Setting `staleWarnMs` below 5 min creates false-positive stale warnings because the SDK hasn't had time to report heartbeat failure yet.

### Pre-flight Checklist

Before running your first Agent Teams workflow, verify:

1. `BASH_DEFAULT_TIMEOUT_MS` >= 600000 (10 min) — prevents ward check timeout kills
2. Ward commands in `talisman.yml` complete within the configured bash timeout
3. If using MCP servers beyond Context7, consider `MCP_TIMEOUT` >= 30000
4. Ensure `BASH_DEFAULT_TIMEOUT_MS` < `autoReleaseMs` (10 min for work/mend) to prevent task release during error recovery
5. Verify `staleWarnMs` >= 300000 (5 min) — setting lower creates false-positive stale warnings before SDK heartbeat can report (see DC-3 SDK Heartbeat Interaction)

### Cost Awareness

Team workflows consume more tokens than single-session execution:

| Team Size | Approximate Multiplier | Typical Workflows |
|-----------|----------------------|-------------------|
| 1 teammate | ~1.2x (overhead only) | Quick review, single-worker mend |
| 3 teammates | ~3-4x | Standard review (5 Ashes), work (3 workers) |
| 6+ teammates | ~5-8x | Exhaustive forge, full audit |

**Cost mitigation**: Use `--quick` for plan, skip `--exhaustive` unless needed,
prefer review over audit for incremental changes. Use `.claude/settings.local.json`
for project-specific overrides to avoid affecting other Claude Code sessions.

### SDK Heartbeat

The Agent SDK has a hardcoded 5-minute teammate heartbeat. If a teammate
crashes or stops responding, it is marked inactive after 5 minutes and its
tasks are released to the pool. This aligns with Rune's DC-3 (Fading Ash)
stale detection threshold.

Key behaviors:
- Heartbeat is not configurable — fixed at ~5 minutes (approximate, may vary between SDK versions)
- Crashed teammates waste up to 5 minutes before detection
- Tasks from crashed teammates become claimable by other workers
- Rune's `autoReleaseMs` (10 min for work/mend) provides a second safety net

---

## arc

Arc pipeline configuration lives under the `arc:` key. Config resolution follows a 3-layer priority chain: **hardcoded defaults** → **talisman.yml** → **CLI flags** (CLI always wins).

### `arc.defaults` — CLI flag defaults

| Key | Type | Default | CLI flag |
|-----|------|---------|----------|
| `no_forge` | boolean | `false` | `--no-forge` |
| `approve` | boolean | `false` | `--approve` |
| `skip_freshness` | boolean | `false` | `--skip-freshness` |
| `confirm` | boolean | `false` | `--confirm` |

### `arc.ship` — Phase 9 (SHIP) settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `auto_pr` | boolean | `true` | Create PR automatically after audit. CLI: `--no-pr` to disable. |
| `auto_merge` | boolean | `false` | Merge PR automatically (see `wait_ci` for CI gate). CLI: `--no-merge` to disable. |
| `merge_strategy` | string | `"squash"` | Merge strategy: `squash`, `merge`, or `rebase`. |
| `wait_ci` | boolean | `false` | Wait for CI checks before merge. |
| `draft` | boolean | `false` | Create PR as draft. CLI: `--draft`. |
| `labels` | string[] | `[]` | Labels to apply to PR. |
| `pr_monitoring` | boolean | `false` | Include post-deploy monitoring section in PR body. Note: distinct from `work.pr_monitoring` — `arc.ship.pr_monitoring` only applies to arc-created PRs. |
| `rebase_before_merge` | boolean | `true` | Rebase onto target branch before merge. |
| `co_authors` | string[] | `[]` | Co-Authored-By lines in `"Name <email>"` format. Falls back to `work.co_authors` if not set here. |

### `arc.pre_merge_checks` — Phase 9.5 (MERGE) pre-merge checklist

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `migration_conflict` | boolean | `true` | Check for migration file conflicts. |
| `schema_conflict` | boolean | `true` | Check for schema drift. |
| `lock_file_conflict` | boolean | `true` | Check for lock file conflicts (package-lock.json, yarn.lock, etc.). |
| `uncommitted_changes` | boolean | `true` | Check for uncommitted changes. |
| `migration_paths` | string[] | `[]` | Additional paths to scan for migration conflicts. |

### `arc.timeouts` — Per-phase timeout overrides (activated v1.40.0)

Per-phase timeout values in milliseconds. Values are clamped to 10s–3600s range. Total pipeline timeout is computed dynamically by `calculateDynamicTimeout(tier)` and is not configurable.

| Key | Type | Default (ms) | Description |
|-----|------|-------------|-------------|
| `forge` | number | 900000 | Phase 1: Research enrichment (15 min) |
| `plan_review` | number | 900000 | Phase 2: Plan review (15 min) |
| `plan_refine` | number | 180000 | Phase 2.5: Plan refinement (3 min) |
| `verification` | number | 30000 | Phase 2.7: Verification gate (30 sec) |
| `semantic_verification` | number | 180000 | Phase 2.8: Codex semantic check (3 min) |
| `work` | number | 2100000 | Phase 5: Work execution (35 min) |
| `gap_analysis` | number | 60000 | Phase 5.5: Gap analysis (1 min) |
| `codex_gap_analysis` | number | 660000 | Phase 5.6: Codex gap analysis (11 min) |
| `code_review` | number | 900000 | Phase 6: Code review (15 min) |
| `mend` | number | 1380000 | Phase 7: Mend (23 min) |
| `verify_mend` | number | 240000 | Phase 7.5: Verify mend (4 min) |
| `browser_test` | number | 900000 | Phase 7.7.5: Browser E2E test (15 min, v2.21.0+) |
| `browser_test_fix` | number | 900000 | Phase 7.7.6: Browser test fix (15 min, v2.21.0+) |
| `verify_browser_test` | number | 240000 | Phase 7.7.7: Verify browser test (4 min, v2.21.0+) |
<!-- v1.67.0: audit/audit_mend/audit_verify removed (unified into Phase 6 --deep) -->
| `ship` | number | 300000 | Phase 9: PR creation (5 min, v1.40.0+) |
| `merge` | number | 600000 | Phase 9.5: Merge (10 min, v1.40.0+) |

### `arc.batch.smart_ordering` — Smart plan ordering (v1.104.0, opt-in v1.118.0)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Master kill switch for smart plan ordering. When `false`, Phase 1.5 is skipped entirely regardless of `mode` or CLI flags. |
| `mode` | string | `"ask"` | Controls ordering behavior. `"ask"` (default): prompt user on glob input, skip on queue files. `"auto"`: always apply smart ordering (pre-v1.118.0 behavior). `"off"`: disable ordering (equivalent to `enabled: false` but preferred for new configs). CLI flags `--smart-sort` and `--no-smart-sort` override this setting. |

### `review` — Chunked review settings (v1.51.0+)

Controls how large diffs are split into reviewable chunks to limit per-step context cost.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `large_diff_threshold` | number | `25` | File count above which standard-depth review triggers chunked mode (range: 5-200). When changed file count exceeds this value, the diff is automatically split into chunks before review agents are summoned. |
| `chunk_size` | number | `15` | Target number of files per chunk in chunked review mode (range: 3-50). Actual chunk sizes may vary slightly to respect directory boundaries when `chunk_strategy: "directory"` is used. |

### `review.arc_convergence_*` — Review-mend convergence (v1.37.0+, enhanced v1.41.0)

Arc convergence keys live under the `review:` section (not `arc:`) and use the `arc_` prefix to avoid collision with chunked review convergence keys.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `arc_convergence_tier_override` | string \| null | `null` | Force tier: `"light"`, `"standard"`, `"thorough"`, or `null` (auto-detect). |
| `arc_convergence_max_cycles` | number \| null | `null` | Hard override for max review-mend cycles (1-5). Overrides tier, use sparingly. |
| `arc_convergence_min_cycles` | number \| null | `null` | Min re-review cycles before convergence allowed (1-maxCycles). Default: tier-based (LIGHT=1, STANDARD=2, THOROUGH=2). v1.41.0+. |
| `arc_convergence_finding_threshold` | number | `0` | P1 findings at or below this count = converged (0-100). |
| `arc_convergence_p2_threshold` | number | `0` | P2 findings at or below this count = eligible for convergence (0-100). Default 0 = any P2 blocks convergence. v1.41.0+. |
| `arc_convergence_improvement_ratio` | number | `0.5` | Findings must decrease by this ratio to continue (0.1-0.9). |

### `review` — Inscription Sharding settings (v1.98.0+)

Sharding supersedes `large_diff_threshold` / `chunk_size` for `scope=diff` + standard-depth review. When `totalFiles > shard_threshold`, the diff is partitioned into non-overlapping domain-affinity shards reviewed in parallel. Chunked review continues to apply for `scope=full` audits.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `shard_threshold` | number | `15` | File count above which sharded review activates (range: 5-50). Set to `999` to disable sharding entirely (restore chunked behavior). |
| `shard_size` | number | `12` | Max files per shard reviewer (range: 5-20). Lower = less context pressure per reviewer; higher = fewer shards = lower cost. |
| `max_shards` | number | `5` | Maximum parallel shard reviewers (range: 2-8). Capped by available context budget. |
| `cross_shard_sentinel` | boolean | `true` | Enable Cross-Shard Sentinel after shard reviewers complete. When true, spawns one extra agent that reads only shard summary JSONs for cross-file issues. |
| `shard_model_policy` | string | `"auto"` | Model selection per shard: `auto` (sonnet for security/code, haiku for docs-only), `all-sonnet`, or `all-haiku`. |
| `reshard_threshold` | number | `30` | Re-review scope guard for convergence loop. When mend re-review scope exceeds this, force standard review instead of re-sharding (preserves finding prefix continuity). |

### `arc.consistency` — Cross-file consistency checks (v1.17.0+)

See the consistency checks section in `talisman.example.yml` for schema and examples.

---

## mend — Parallel finding resolution settings (v1.51.0+)

Top-level `mend:` configuration controls the parallel finding resolution pipeline (`/rune:mend` and arc Phase 7).

### `mend` — Cross-file mend settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cross_file_batch_size` | number | `3` | Max files read per batch during orchestrator-only cross-file mend (Phase 5.5, range: 1-10). Lower values reduce per-step context cost; higher values reduce round-trips for multi-file findings. |

**Usage**:
```yaml
mend:
  cross_file_batch_size: 4     # Increase for faster cross-file operations on large codebases
```

---

## goldmask — Per-workflow integration (v1.71.0+)

Per-workflow Goldmask configuration lives under the `goldmask:` key as flat siblings to `goldmask.layers:`. All defaults are `true` — Goldmask is always on unless explicitly disabled. The master switch `goldmask.enabled` takes precedence over per-workflow switches.

### `goldmask` — Top-level settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Master switch. When `false`, disables ALL Goldmask integration across all workflows (forge, mend, devise, inspect, arc, appraise, audit). Per-workflow switches are ignored when this is `false`. |

### `goldmask.forge` — Lore Layer in forge

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Enable Lore Layer risk scoring in forge. Runs before Forge Gaze selection. CRITICAL/HIGH files boost Gaze scores and forge agents receive risk context. Skip chain: talisman → git guard → G5 guard → `--no-lore`. |

### `goldmask.mend` — Data passthrough + quick check in mend

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Master switch for all mend Goldmask integration. When false, skips data discovery (Phase 0.5) and quick check (Phase 5.9). |
| `inject_context` | boolean | `true` | Inject risk/wisdom context into fixer prompts. Fixer agents receive file risk tiers, wisdom advisories, and blast-radius warnings from prior Goldmask outputs. |
| `quick_check` | boolean | `true` | Run deterministic quick check after mend (Phase 5.9). Compares MUST-CHANGE files from GOLDMASK.md against actual mend modifications. Reports untouched and unexpected changes. |

### `goldmask.devise` — Predictive Goldmask depth

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `depth` | string | `"enhanced"` | Predictive Goldmask depth. `basic`: 2 agents (lore-analyst + wisdom-sage, legacy). `enhanced`: 6 agents (lore + 3 impact tracers + wisdom + coordinator). `full`: 8 agents (all 5 impact tracers + lore + wisdom + coordinator). **Warning**: `full` mode is token-intensive — 8 parallel agents each with their own context window. Use only for high-risk changes. |

### `goldmask.inspect` — Lore Layer + wisdom passthrough in inspect

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Enable Lore Layer risk scoring in inspect. Runs before inspector assignment. CRITICAL requirements get dual inspector coverage (grace-warden + ruin-prophet). Skip chain: talisman → git guard → G5 guard → `--no-lore`. |
| `wisdom_passthrough` | boolean | `true` | Inject wisdom advisories from prior Goldmask runs into inspector prompts. Each inspector receives role-specific guidance notes alongside risk data. |

---

## file_todos — File-based todo tracking (v1.101.0+)

All todos are session-scoped (mandatory). No project-root override. Todos always live in `tmp/{workflow}/{id}/todos/{source}/`.

### Deprecated Keys (removed in v1.101.0)

| Key | Removed In | Migration |
|-----|-----------|-----------|
| `file_todos.dir` | v1.101.0 | Remove from talisman.yml — todos are session-scoped, no project-root override needed |
| `file_todos.enabled` | v1.101.0 | Remove from talisman.yml — todos are mandatory for all workflows |
| `file_todos.auto_generate.work` | v1.101.0 | Remove from talisman.yml — work todos are always generated |

When `readTalisman()` encounters these removed keys, it emits a one-time warning:

```javascript
const deprecated = {
  'file_todos.dir': 'REMOVED in v1.101.0 — todos are session-scoped, no project-root override needed',
  'file_todos.enabled': 'REMOVED in v1.101.0 — todos are now mandatory for all workflows',
  'file_todos.auto_generate.work': 'REMOVED in v1.101.0 — work todos are always generated'
}
for (const [key, message] of Object.entries(deprecated)) {
  if (getNestedKey(talisman, key) !== undefined) {
    warn(`Deprecated talisman key "${key}": ${message}. Remove from .rune/talisman.yml.`)
  }
}
```

### `file_todos.triage` — Triage behavior

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `file_todos.triage.auto_approve_p1` | boolean | `false` | Auto-approve P1 items during triage without prompting |

### `file_todos.manifest` — Per-source manifest settings (v1.101.0+)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `file_todos.manifest.auto_build` | boolean | `true` | Auto-rebuild per-source manifest when dirty signal is set |
| `file_todos.manifest.dedup_on_build` | boolean | `false` | Run dedup candidate detection on every manifest build |
| `file_todos.manifest.dedup_threshold` | float | `0.70` | Confidence threshold (0.0-1.0) for dedup candidates (Jaro-Winkler + Jaccard scoring) |

### `file_todos.history` — Status History tracking (v1.101.0+)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `file_todos.history.enabled` | boolean | `true` | Track Status History entries (markdown table) on every status transition |

---

## debug — ACH parallel debugging (v1.90.0+)

Top-level `debug:` configuration controls the `/rune:debug` ACH-based parallel debugging pipeline. Multiple hypothesis-investigator agents run in parallel to test competing hypotheses.

### `debug` settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_investigators` | number | `4` | Max parallel investigators per round (1-6). More investigators = broader hypothesis coverage but higher cost. |
| `timeout_ms` | number | `420000` | Per-investigation-round timeout in milliseconds (7 min). |
| `model` | string | `"sonnet"` | Default investigator model; overridden by `cost_tier` setting. |
| `re_triage_rounds` | number | `1` | Max re-triage rounds before escalating to user. After each round, unresolved hypotheses are re-triaged. |
| `echo_on_verdict` | boolean | `true` | Persist debugging verdict to Rune Echoes after resolution. Enables learning from past debugging sessions. |

**Usage**:
```yaml
debug:
  max_investigators: 6     # More investigators for complex, multi-cause bugs
  timeout_ms: 600000       # 10 min for deep investigation rounds
  echo_on_verdict: true    # Learn from debugging sessions
```

---

## work.worktree — Worktree isolation (v1.95.0+)

Nested under the `work:` section. Controls worktree-based parallel execution for `/rune:strive --worktree` or when `work.worktree.enabled: true`.

### `work.worktree` settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `false` | Make worktree mode the default for `/rune:strive`. When true, workers run in isolated git worktrees instead of the main working directory. |
| `max_workers_per_wave` | number | `3` | Max parallel workers per wave. Each worker gets its own worktree. |
| `merge_strategy` | string | `"sequential"` | Only `"sequential"` currently supported. Workers merge back one at a time. |
| `auto_cleanup` | boolean | `true` | Remove worktrees after successful merge. Set false to preserve for debugging. |
| `conflict_resolution` | string | `"escalate"` | `"escalate"` (ask user) or `"abort"` (skip conflicting worker). |

### `work.unrestricted_shared_files`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `unrestricted_shared_files` | string[] | `[]` | Files all workers can write to, bypassing SEC-STRIVE-001 path validation. Useful for shared config files that multiple tasks touch (e.g., `package.json`, `requirements.txt`). |

---

## solution_arena — Expanded settings (v1.105.0+)

### `solution_arena.weights` — Arena scoring dimensions

Weights must sum to 1.0. When omitted, default weights apply.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `weights.feasibility` | number | `0.25` | Can we build this with existing patterns? |
| `weights.complexity` | number | `0.20` | Resource cost and difficulty (lower = higher score) |
| `weights.risk` | number | `0.20` | Likelihood and severity of failure |
| `weights.maintainability` | number | `0.15` | Long-term upkeep, readability |
| `weights.performance` | number | `0.10` | Runtime efficiency under load |
| `weights.innovation` | number | `0.10` | Novel approach longevity |

### `solution_arena.convergence_threshold`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `convergence_threshold` | number | `0.05` | When the top 2 solutions are within this margin, they are considered "tied" and presented to the user for manual selection. |

---

## stack_awareness — Expanded settings (v1.105.0+)

### `stack_awareness.override` — Manual stack override

Use when auto-detection fails (monorepos, custom frameworks, polyglot projects).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `override.primary_language` | string | — | Override detected primary language (e.g., `python`, `typescript`, `rust`). |
| `override.frameworks` | string[] | — | Override detected frameworks (e.g., `[fastapi, sqlalchemy]`). |

### `stack_awareness.custom_rules[]` — Project-specific routing

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `custom_rules[].path` | string | — | Path to custom skill SKILL.md |
| `custom_rules[].domains` | string[] | — | Domain triggers: `backend`, `frontend`, `infra` |
| `custom_rules[].workflows` | string[] | — | Active workflows: `review`, `work`, `audit` |
| `custom_rules[].stacks` | string[] | — | Stack triggers: `python`, `typescript`, etc. |

## supply_chain — Dependency Risk Analysis (v2.29.0+)

### `supply_chain` settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `supply_chain.enabled` | boolean | `true` | Enable supply chain analysis in review/audit |
| `supply_chain.max_dependencies` | number | `50` | Cap on dependencies to analyze (API rate limits) |
| `supply_chain.risk_threshold` | string | `"medium"` | Minimum risk level to report: `low`, `medium`, `high` |
| `supply_chain.registries.npm` | string | `"https://registry.npmjs.org"` | Override npm registry API endpoint |
| `supply_chain.registries.pypi` | string | `"https://pypi.org/pypi"` | Override PyPI registry API endpoint |

---

See `../skills/roundtable-circle/references/custom-ashes.md` for full schema and `talisman.example.yml` at plugin root.
