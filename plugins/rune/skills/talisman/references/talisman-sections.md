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
| 15 | `echoes` | Agent memory | `version_controlled`, `session_summary`, `fts_enabled`, `auto_observation`, `scoring`, `groups`, `reranking`, `retry` |
| 16 | `mend` | Finding resolution | `cross_file_batch_size` |
| 17 | `review` | Review settings | `diff_scope`, `convergence`, `arc_convergence_*`, `shard_*` |
| 18 | `work` | Work/strive settings | `ward_commands`, `max_workers`, `commit_format`, `co_authors`, `branch_prefix`, `unrestricted_shared_files`, `worktree.*` |
| 20 | `horizon` | Strategic assessment | `enabled`, `min_score`, `dimensions` |
| 21 | `testing` | Test orchestration | `browser.*` (`headed`, `deep`, `infrastructure_discovery`, `test_plan`, `ui_first`, `report_out_of_scope`), `tiers.unit`, `tiers.integration`, `tiers.e2e`, `service.*`, `scenarios.*`, `extended_tier.*`, `contract.*`, `visual_regression.*`, `accessibility.*`, `history.*`, `fixtures.*`, `flaky_detection.*`, `production_readiness.*` |
| 22 | `doubt_seer` | Claim verification | `enabled`, `min_claims`, `verdict_threshold` |
| 23 | `codex` | Cross-model verification | `model`, `workflows`, `timeout`, 17 deep integration keys |
| 24 | `context_monitor` + `context_weaving` | Context management | `enabled`, `warning_threshold`, `glyph_budget`, `offload_threshold`, `pretooluse_guard.enabled` |
| 25 | `debug` | ACH parallel debugging | `max_investigators`, `timeout_ms`, `model`, `re_triage_rounds`, `echo_on_verdict` |
| 26 | `plan` | Research & planning config | `verification_patterns[]`, `freshness` (`enabled`, `warn_threshold`, `block_threshold`, `max_commit_distance`), `external_research` (`"always"` / `"auto"` / `"never"`), `research_urls[]` |
| 27 | `integrations` | MCP tool integrations | `mcp_tools.{namespace}.server_name`, `server_version`, `tools[]`, `phases{}`, `trigger{}`, `skill_binding`, `rules[]`, `metadata{}` |
| 28 | `design_sync` | Figma design synchronization | `enabled`, `figma_provider`, `max_figma_urls`, `max_extraction_workers`, `max_implementation_workers`, `max_iteration_workers`, `max_iterations`, `iterate_enabled`, `trust_hierarchy.*`, `verification_gate.*`, `backend_impact.*`, `codegen_profile` |
| 29 | `inner_flame` | Self-review protocol | `enabled`, `block_on_fail`, `elegance_check` |
| 30 | `discipline` | Proof validation | `enabled`, `block_on_fail`, `proof_timeout`, `max_convergence_iterations`, `echo_back_required` |
| 31 | `stack_awareness` | Stack detection & specialist selection | `enabled`, `confidence_threshold`, `max_stack_ashes`, `design_compliance`, `override.*`, `custom_rules[]`, `priority.*` |
| 32 | `data_flow` | Field-level persistence verification | `enabled`, `min_layers`, `auto_fields[]`, `exclude_fields[]`, `severity.*`, `generate_tests`, `devise_scanning`, `inspect_dimension` |
| 33 | `arc.persistence` | Arc pipeline retry on API failures | `enabled`, `max_retries`, `max_budget_cents` |
| 34 | `blind_verification` | Post-strive AC-only verification | `enabled`, `model`, `fail_on_partial`, `max_remediation`, `timeout_ms` |

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

### `stack_awareness.priority` (v1.178.0+)
**Impact**: Boosts MCP-discovered agent scores for specified languages/frameworks during agent discovery.
**Key fields**:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `priority.languages` | list | `[]` | Language names to boost (e.g., `[python, typescript]`). Matched against agent `languages` field (case-insensitive) |
| `priority.frameworks` | list | `[]` | Framework names to boost (e.g., `[fastapi, django]`). Matched against agent tags (case-insensitive) |
| `priority.boost_factor` | float | `1.5` | Score multiplier for matching agents. Higher = more likely to survive trim. Range: 1.0-3.0 recommended |

**Consumer**: `rune-gaze.md` Phase 1C (MCP-First Agent Discovery), Step 3.5.

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

## MCP Integrations (`integrations.mcp_tools`)

Controls workflow-aware third-party MCP tool routing. Each namespace represents one MCP server integration.

### Configuration Schema

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `server_name` | string | Yes | Must match key in `.mcp.json` |
| `server_version` | string | No | Semver for schema drift detection (VEIL-EP-002) |
| `tools[]` | array | Yes | Array of `{ name, category }` objects |
| `tools[].name` | string | Yes | Tool function name (alphanumeric + underscore/hyphen) |
| `tools[].category` | string | Yes | One of: `search`, `details`, `compose`, `suggest`, `generate`, `validate` |
| `phases` | object | Yes | Which Rune phases can use these tools |
| `phases.devise` | bool | No | Available during planning |
| `phases.strive` | bool | No | Available during implementation |
| `phases.forge` | bool | No | Available during enrichment |
| `phases.appraise` | bool | No | Available during review |
| `phases.audit` | bool | No | Available during full audit |
| `phases.arc` | bool | No | Available during arc pipeline (fallback for unset phases) |
| `skill_binding` | string | No | Companion skill auto-loaded when active |
| `rules[]` | array | No | Rule file paths injected into agent prompts |
| `trigger` | object | No | Activation conditions (OR logic within, AND with phase) |
| `trigger.extensions[]` | array | No | File extensions to match (e.g., `.tsx`) |
| `trigger.paths[]` | array | No | Path prefixes to match (e.g., `src/components/`) |
| `trigger.keywords[]` | array | No | Keywords in task description (case-insensitive) |
| `trigger.always` | bool | No | Override: always active when phase matches |
| `metadata` | object | No | Discoverability metadata |
| `metadata.library_name` | string | No | Display name for the library |
| `metadata.homepage` | string | No | Library documentation URL |
| `metadata.mcp_endpoint` | string | No | MCP server endpoint URL |
| `metadata.transport` | string | No | Transport type: `http`, `stdio` |
| `metadata.auth` | string | No | Auth method: `oauth2.1-pkce`, `api-key`, `none` |

### UntitledUI (Reference Implementation)

UntitledUI is the canonical Level 3 MCP integration with 6 tools, companion skill, and builder protocol:

```yaml
untitledui:
  server_name: "untitledui"
  tools:
    - { name: "search_components", category: "search" }
    - { name: "list_components", category: "search" }
    - { name: "get_component", category: "details" }
    - { name: "get_component_bundle", category: "details" }
    - { name: "get_page_templates", category: "search" }
    - { name: "get_page_template_files", category: "details" }
  phases:
    devise: true
    strive: true
    forge: true
    arc: true
  skill_binding: "untitledui-mcp"
  trigger:
    extensions: [".tsx", ".ts", ".jsx"]
    paths: ["src/components/", "src/pages/"]
    keywords: ["frontend", "ui", "component"]
  metadata:
    library_name: "UntitledUI"
    homepage: "https://www.untitledui.com"
    mcp_endpoint: "https://www.untitledui.com/react/api/mcp"
    transport: "http"
    auth: "oauth2.1-pkce | api-key | none"
```

### Activation Pipeline

```
resolveMCPIntegrations(phase, context)
  → Gate 1: integrations.mcp_tools exists?
  → Gate 2: phases[currentPhase] === true?
  → Gate 3: evaluateTriggers(trigger, context) === true?
  → All gates pass → integration ACTIVE
  → buildMCPContextBlock() → inject into agent prompts
```

### Validation Rules (checked by /rune:talisman audit)

1. `server_name` must exist as key in `.mcp.json`
2. `tools[].category` must be one of the 6 valid categories
3. `phases` keys must be valid Rune phases
4. `skill_binding` skill must exist at plugin or project level
5. `rules[]` file paths must exist
6. At least one trigger condition must be configured (or `always: true`)

## Design Sync (`design_sync`)

Figma design synchronization pipeline configuration. Gated by `enabled: true`.

### Configuration Schema

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Enable design sync pipeline |
| `figma_provider` | string | `"auto"` | Figma MCP provider filter: `auto\|rune\|framelink\|desktop` (`"auto"` probes ALL providers and composes by capability — figma-context-mcp/Framelink for data, Rune for inspect+codegen) |
| `max_figma_urls` | number | `10` | Maximum Figma URLs per invocation |
| `max_extraction_workers` | number | `2` | Parallel workers for design extraction phase |
| `max_implementation_workers` | number | `3` | Parallel workers for implementation phase |
| `max_iteration_workers` | number | `2` | Parallel workers for iteration phase |
| `max_iterations` | number | `5` | Max screenshot-analyze-improve iterations |
| `iterate_enabled` | bool | `false` | Enable browser-based iteration loop |
| `codegen_profile` | string | `null` | Override codegen profile for workers |
| `trust_hierarchy.low_confidence_threshold` | number | `0.60` | Score below this = low confidence match |
| `trust_hierarchy.high_confidence_threshold` | number | `0.80` | Score at or above this = high confidence match |
| `verification_gate.enabled` | bool | `true` | Enable cross-verification gate on VSM files |
| `verification_gate.warn_threshold` | number | `20` | Mismatch % triggering WARN verdict |
| `verification_gate.block_threshold` | number | `40` | Mismatch % triggering BLOCK verdict |
| `backend_impact.enabled` | bool | `false` | Enable backend impact analysis |

## Inner Flame (`inner_flame`)

Universal self-review protocol configuration for all teammates. Controls grounding, completeness, and elegance checks.

### Configuration Schema

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Enable Inner Flame self-review protocol |
| `block_on_fail` | bool | `true` | Block task completion on Inner Flame failure |
| `elegance_check` | bool | `false` | Enable Layer 3B elegance checks for non-trivial changes (Worker/Fixer roles only) |

### Elegance Check Details

When `elegance_check: true` is enabled, the following additional checks activate for Worker and Fixer roles when changes are non-trivial (3+ files OR 50+ lines):

1. **Simplest solution?** — No unnecessary abstraction, no speculative generality
2. **Pattern reuse?** — Checked for existing patterns before inventing new ones
3. **Readability?** — Self-explanatory code, descriptive names
4. **YAGNI?** — No features added "just in case"

The elegance check is **opt-in** (default: false) because it adds overhead for code changes where elegance analysis would itself be inelegant (simple, obvious fixes).

## Companion Files (Optional 3-File Layout)

Talisman configuration can optionally be split into 3 files organized by audience:

```
.rune/
├── talisman.yml                  # Main config (~18 sections, ~350L)
├── talisman.ashes.yml            # Agent registry (~4 sections, ~150L)  [OPTIONAL]
└── talisman.integrations.yml     # External tools (~8 sections, ~200L)  [OPTIONAL]
```

### Section Mapping

| File | Sections | Audience |
|------|----------|----------|
| `talisman.yml` | `version`, `cost_tier`, `rune-gaze`, `settings`, `defaults`, `review`, `work`, `arc`, `testing`, `audit`, `inspect`, `plan`, `mend`, `inner_flame`, `teammate_lifecycle`, `context_monitor`, `context_weaving`, `devise`, `strive`, `discipline`, `solution_arena` | All users (core runtime config) |
| `talisman.ashes.yml` | `ashes`, `user_agents`, `extra_agent_dirs`, `doubt_seer` | Agent authors (custom review agents) |
| `talisman.integrations.yml` | `codex`, `codex_review`, `elicitation`, `horizon`, `evidence`, `echoes`, `state_weaver`, `file_todos` | Power users (external tool integrations) |

### Merge Behavior

- **Merge order**: `defaults` < `global talisman.yml + global companions` < `project talisman.yml + project companions`
- **Within a layer**: companions merge left-to-right (ashes first, then integrations)
- **Duplicate key detection**: Same top-level key in main file AND a companion = hard error (companion skipped, main preserved)
- **jq `*` semantics**: Recursive object merge but **replaces** arrays (not append). If main has `ashes.custom: [a]` and companion has `ashes.custom: [b]`, result is `[b]` not `[a, b]`
- **Missing companions**: Silently skipped — single-file layout remains fully supported
- **Empty companions**: Ignored (treated as `{}`)

### Companion vs Shard Boundaries

Companion file boundaries (authoring concern) do NOT align 1:1 with shard boundaries (consumption concern). For example:
- The `settings` shard aggregates from both `talisman.yml` (`version`, `settings`, `defaults`) and `talisman.ashes.yml` (`ashes`, `user_agents`)
- The `gates` shard aggregates from both `talisman.ashes.yml` (`doubt_seer`) and `talisman.integrations.yml` (`elicitation`, `horizon`, `evidence`)

This is architecturally correct because merge happens BEFORE sharding — the shard layer sees a single unified JSON regardless of how many source files contributed.
