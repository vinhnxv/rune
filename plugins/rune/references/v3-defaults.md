# v3.x Baked-In Defaults

Reading aid for refactored code paths that used to read `talisman.<section>.<key>`.
Replaces the deleted `talisman.example.yml` and `references/configuration-guide.md`.

This is **dev-facing**. Values are inlined at consumer call sites; if a literal in a skill
disagrees with this file, the **skill is canonical** — update this file to match.

The header comment `<!-- v3.x: defaults baked from former talisman.<section>; see references/v3-defaults.md -->`
on a refactored file points the next reader here.

Sections (every former talisman config section name): `arc`, `audit`, `devise`,
`discipline`, `gates`, `goldmask`, `inspect`, `integrations`, `misc`, `plan`, `pr_comment`,
`process_management`, `review`, `settings`, `teammate_lifecycle`, `testing`, `ux`, `work`.

## arc

| Key path | Value |
|---|---|
| `defaults.no_forge / approve / skip_freshness / confirm / no_test / no_browser_test / step_groups` | `false` |
| `defaults.accept_external_changes` | `true` |
| `ship.auto_pr / rebase_before_merge / merge_verification.enabled / pre_merge_checks.*` | `true` |
| `ship.auto_merge / wait_ci / draft / pr_monitoring / ci_check.enabled / ci_check.retrigger_on_push / bot_review` | `false` (bot_review handled by external pr-guardian) |
| `ship.merge_strategy` | `"squash"` (allowlist `squash` \| `rebase` \| `merge`) |
| `ship.labels / pre_merge_checks.migration_paths / skip_phases` | `[]` |
| `ship.ci_check.{timeout_ms,poll_interval_ms,fix_timeout_ms,escalation_timeout_ms,fix_retries}` | `900000 / 30000 / 300000 / 1800000 / 2` |
| `ship.ci_check.conclusion_allowlist` | `["success","skipped","neutral"]` |
| `ship.merge_verification.timeout_ms` | `60000` |
| `timeouts.{forge,work,code_review,mend,test}` | `900000 / 2100000 / 900000 / 1380000 / 900000` |
| `timeouts.{gap_analysis,gap_remediation,audit,merge,ship}` | `720000 / 900000 / 1200000 / 600000 / 300000` |
| `timeouts.{plan_review,plan_refine,verify_mend,verification}` | `900000 / 180000 / 240000 / 30000` |
| `gap_analysis.{halt_threshold,inspectors}` | `50 / 2` |
| `gap_analysis.remediation.{enabled,max_fixes,timeout}` | `true / 20 / 600000` |
| `inspect.enabled / verify.enabled` | `true` |
| `state_file.{stale_multiplier,heartbeat_interval_sec}` | `3 / 60` |

## audit

| Key | Value |
|---|---|
| `always_deep / incremental.enabled` | `false` |
| `deep.enabled` | `true` |
| `deep.timeout_multiplier / max_deep_ashes / max_dimension_agents` | `1.5 / 4 / 7` |
| `deep.ashes` | `["rot-seeker","strand-tracer","decree-auditor","fringe-watcher"]` |
| `deep.dimensions` | `["truth-seeker","ruin-watcher","breach-hunter","order-auditor","ember-seer","signal-watcher","decay-tracer"]` |

## devise / integrations / pr_comment / ux

All empty `{}`. Devise behaviour comes from `goldmask.devise.{enabled,depth}` + CLI flags. Cross-cutting integrations live under `misc`. Bot-review wait moved to the external pr-guardian harness. UX subsystem retained for inspector heuristics; no user knobs consumed (`industry: null`).

## discipline

| Key | Value |
|---|---|
| `enabled / context_isolation / block_on_fail` | `true` (v3.x defaults discipline ON) |
| `iteration_timeout_ms` | `1200000` |
| `max_convergence_iterations / scr_threshold` | `3 / 100` |

## gates

| Key | Value |
|---|---|
| `qa_gates.enabled / elicitation.enabled / state_weaver.enabled / horizon.enabled / evidence.enabled / evidence.require_evidence_chain` | `true` |
| `qa_gates.pass_threshold / max_phase_retries / max_global_retries / max_infra_global_retries` | `70 / 2 / 6 / 12` |
| `horizon.intent_default` | `"long-term"` |
| `evidence.block_threshold / concern_threshold` | `0.4 / 0.6` |
| `evidence.external_search / doubt_seer.enabled / doubt_seer.block_on_unproven` | `false` |
| `doubt_seer.challenge_threshold / unproven_threshold / max_challenges` | `"P2" / 0.8 / 20` |
| `doubt_seer.workflows` | `["review","audit"]` |

## goldmask

| Key | Value |
|---|---|
| `enabled / forge.enabled / inspect.enabled / mend.enabled / devise.enabled / inspect.wisdom_passthrough / mend.inject_context / mend.quick_check` | `true` |
| `coordinator_model / layers.wisdom.model` | `"sonnet"` |
| `layers.lore.model / layers.impact.tracer_model` | `"haiku"` |
| `double_check_top_n` | `5` |
| `priority_weights` | `{ impact: 0.4, lore: 0.25, wisdom: 0.35 }` |
| `layers.cdd.{enabled,swarm_detection} / layers.impact.enabled / layers.lore.enabled / layers.wisdom.{enabled,intent_classification}` | `true` |
| `layers.cdd.noisy_or_threshold / swarm_lookback_commits` | `0.6 / 50` |
| `layers.impact.max_tracers / tracer_timeout` | `5 / 120000` |
| `layers.lore.churn_threshold / co_change_min_support / lookback_days / ownership_concentration_warn` | `10 / 3 / 180 / 0.8` |
| `layers.wisdom.caution_threshold / max_blame_files / max_findings_to_investigate` | `0.7 / 50 / 20` |
| `devise.depth` | `"basic"` |

## inspect

| Key | Value |
|---|---|
| `completion_threshold / gap_threshold / max_inspectors / max_fixes / fix_timeout` | `80 / 20 / 4 / 20 / 600000` |
| `detect_wiring_heuristics` | `true` |
| `wiring_patterns / wiring_exclusions` | `["barrel_exports","migrations"] / ["**/__fixtures__/**","**/__mocks__/**"]` |

## misc

Catch-all; sub-sections enabled by default unless noted.

| Key | Value |
|---|---|
| `debug.max_investigators / re_triage_rounds / timeout_ms` | `4 / 1 / 420000` |
| `debug.model` | `"sonnet"` |
| `mend.cross_file_batch_size` | `4` |
| `stack_awareness.enabled` | `true`; `confidence_threshold / max_stack_ashes` `0.6 / 3` |
| `question_relay.max_questions_per_worker / timeout_seconds` | `3 / 120` |
| `context_monitor.enabled / degradation_suggestions` | `true` |
| `context_monitor.warning / caution / critical thresholds` | `35 / 40 / 25` |
| `context_monitor.debounce_calls / stale_seconds` | `5 / 60` |
| `context_monitor.workflows` | `["review","audit","work","mend","arc","devise"]` |
| `context_weaving.glyph_budget.enabled` | `true`; `enforcement / word_limit` `"advisory" / 300` |
| `inner_flame.enabled / assumption_gate.enabled / completeness_scoring.enabled` | `true` |
| `inner_flame.block_on_fail` | `false`; `confidence_floor` `60` |
| `inner_flame.assumption_gate.min_assumptions / block_on_missing` | `3 / true` |
| `inner_flame.completeness_scoring.threshold / research_threshold` | `0.7 / 0.5` |
| `solution_arena.enabled` | `true`; `skip_for_types` `["fix"]` |
| `schema_drift.enabled / strict_mode` | `true / false` |
| `data_flow.enabled / devise_scanning / inspect_dimension / generate_tests` | `true` |
| `data_flow.min_layers` | `2` |
| `data_flow.auto_fields` | `["id","pk","uuid","created_at","updated_at","deleted_at","version"]` |
| `data_flow.severity` | `display_ghost: P2`, `field_phantom: P1`, `persistence_gap: P1`, `roundtrip_asymmetry: P1`, `schema_drift: P2` |
| `self_audit.enabled / phase_injection` | `true` |
| `self_audit.auto_suggest_threshold / promotion_threshold / max_injection_entries` | `3` |
| `self_audit.auto_suggest_debounce_hours / max_injection_tokens` | `24 / 500` |
| `file_todos.history.enabled / manifest.auto_build` | `true` |
| `file_todos.manifest.dedup_on_build / triage.auto_approve_p1` | `false` |
| `file_todos.manifest.dedup_threshold` | `0.7` |
| `strive.frontend_component_context.enabled` | `true`; `max_profile_lines / token_cap_lines` `200 / 50` |
| `deployment_verification.enabled / auto_run_on_migrations` | `false`; `output_dir` `"tmp/deploy/"` |
| `design_sync / storybook / arc_hierarchy / integrations` | `{}` (subsystems off in v3.x) |
| `process_management` | see [process_management](#process_management) |
| `teammate_lifecycle` | see [teammate_lifecycle](#teammate_lifecycle) |

## plan

| Key | Value |
|---|---|
| `freshness.enabled` | `true` |
| `freshness.warn_threshold / block_threshold / max_commit_distance` | `0.7 / 0.4 / 100` |
| `verification_patterns` | `[]` |

## process_management

Lives under `misc.process_management` in resolved shards.

| Key | Value |
|---|---|
| `bash_timeout / bash_timeout_enabled` | `300 / true` |
| `bash_timeout_patterns` | `[]` |
| `poll_guard_enabled` | `false` |
| `process_kill_grace / teammate_stuck_threshold` | `5 / 180` (s) |
| `semantic_activity.enabled` | `true`; `window_seconds` `60` |
| `semantic_activity.error_loop_threshold / retry_loop_threshold / permission_threshold` | `3 / 5 / 3` |

## review

| Key | Value |
|---|---|
| `auto_mend` | `false` |
| `chunk_size / chunk_target_size / chunk_threshold` | `15 / 15 / 20` |
| `max_chunks / max_shards / shard_size / shard_threshold / reshard_threshold / large_diff_threshold` | `5 / 5 / 12 / 15 / 30 / 25` |
| `cross_cutting_pass / cross_shard_sentinel / verify_tome_citations` | `true` |
| `citation_verify_priorities` | `["P1"]` |
| `shard_model_policy / context_building` | `"auto"` |
| `context_building_threshold` | `{ lines: 500, files: 5 }` |
| `context_building_timeout` | `60000` |
| `arc_convergence_{finding_threshold,p2_threshold,improvement_ratio}` | `0 / 0 / 0.5` |
| `convergence.convergence_threshold / smart_scoring` | `0.7 / true` |
| `pre_aggregate.enabled` | `true`; `threshold_bytes` `25000` |
| `diff_scope.enabled / fix_pre_existing_p1 / tag_pre_existing` | `true`; `expansion` `8` |
| `enforcement_asymmetry.enabled / security_always_strict` | `true` |
| `enforcement_asymmetry.high_risk_import_count / new_file_threshold` | `5 / 0.3` |
| `linter_awareness.enabled` | `true`; `always_review` `[]` |
| `context_intelligence.enabled / fetch_linked_issues` | `true` |
| `context_intelligence.max_pr_body_chars / scope_warning_threshold` | `3000 / 1000` |

## settings

| Key | Value |
|---|---|
| `cost_tier` | `"balanced"` |
| `artifact_extraction.enabled / verification.layer_2_custom_agents` | `true` |
| `max_ashes / max_cli_ashes` | `9 / 2` |
| `defaults.disable_ashes / ashes.custom / user_agents / extra_agent_dirs` | `[]` |
| `dedup_hierarchy` | `["SEC","BACK","VEIL","DOUBT","PY","TSR","RST","PHP","FAPI","DJG","LARV","SQLA","TDD","DDD","DI","API","DOM","PERF","FLOW","DOC","QUAL","FRONT","DES","AESTH","UXF","UXC","CDX"]` |
| `rune-gaze.frontend_extensions` | `[".tsx",".ts",".jsx"]` |
| `rune-gaze.backend_extensions` | `[".py",".go",".rs",".rb"]` |
| `rune-gaze.always_review` | `["CLAUDE.md",".rune/**/*.md",".claude/**/*.md"]` |
| `rune-gaze.skip_patterns` | `["**/migrations/**","**/*.generated.ts","**/vendor/**"]` |

## teammate_lifecycle

Lives under `misc.teammate_lifecycle` in resolved shards.

| Key | Value |
|---|---|
| `cleanup.{enabled,process_cleanup} / stale_lead_wakeup.enabled` | `true` |
| `cleanup.{grace_period_seconds,escalation_timeout_seconds}` | `10 / 5` |
| `shutdown_signal_threshold / max_runtime_minutes` | `35 / 20` |
| `max_turns.{work,aggregation}` / `{research,utility}` / `review` | `60 / 40 / 30` |
| `max_turns.{investigation,testing}` | `0` (deprecated) |
| `stale_lead_wakeup.debounce_seconds` | `300` |

## testing

| Key | Value |
|---|---|
| `enabled / tiers.unit.{enabled,coverage} / tiers.integration.enabled / tiers.e2e.enabled / history.enabled / scenarios.enabled` | `true` |
| `tiers.unit.timeout_ms / tiers.integration.timeout_ms / tiers.e2e.timeout_ms` | `300000` |
| `tiers.e2e.headed / browser.headed / browser.deep` | `false` |
| `tiers.e2e.max_routes` | `3` |
| `tiers.e2e.base_url` | `"http://localhost:3000"` |
| `service.startup_timeout` | `180000` |
| `history.directory / scenarios.directory` | `".rune/test-history" / ".rune/test-scenarios"` |
| `history.max_entries / scenarios.max_per_run` | `50` |
| `history.flaky_threshold / pass_rate_drop_threshold / regression_threshold` | `0.1 / 0.05 / 7` |
| `browser.ui_first / test_plan / infrastructure_discovery / report_out_of_scope` | `true` |

## work

| Key | Value |
|---|---|
| `max_workers / approve_timeout` | `3 / 180` |
| `branch_prefix` | `"rune/work"` |
| `commit_format` | `"rune: {subject} [ward-checked]"` |
| `co_authors / unrestricted_shared_files` | `[]` |
| `pr_monitoring / skip_branch_check / worktree.enabled` | `false` |
| `ward_commands` | `["make check","npm test"]` |
| `sibling_awareness.enabled` | `true`; `max_sibling_files` `5` |
| `task_decomposition.{enabled,complexity_threshold,max_subtasks,model}` | `true / 5 / 4 / "haiku"` |
| `worktree.{auto_cleanup,conflict_resolution,merge_strategy,max_workers_per_wave}` | `true / "escalate" / "sequential" / 3` |

## reactions (schema v26)

Declarative reaction engine; v3.x uses the same defaults as the legacy fallback paths
(`gates.qa_gates.*` and `process_management.*`):

- `reactions.qa_gate_failed` → `{ action: "retry", retries: 2, pass_threshold: 70, max_global_retries: 6 }`
- `reactions.teammate_stuck` → `{ action: "escalate", threshold_ms: 180000, force_stop_after_ms: 300000 }`

## Substitution patterns (refactor cheatsheet)

| Old shape | New shape |
|---|---|
| `if (cfg.foo.enabled) { ... }`, default `true` | keep block, drop conditional |
| `if (cfg.foo.enabled) { ... }`, default `false` | delete block |
| `cfg.foo.timeout \|\| 300` | inline `300` |
| Multi-key object | inline `const FOO_DEFAULTS = { ... }` near consumer top |

When in doubt, inline the literal value rather than a named constant — fewer indirections
beats DRY in v3.x lean code.
