# Rune Advanced Guide: Talisman Configuration Deep Dive

Master every configuration knob in `talisman.yml` to tailor Rune's multi-agent workflows to your project.

Related guides:
- [Getting started](rune-getting-started.en.md)
- [Arc and batch guide](rune-arc-and-batch-guide.en.md)
- [Planning guide](rune-planning-and-plan-quality-guide.en.md)
- [Code review and audit guide](rune-code-review-and-audit-guide.en.md)
- [Custom agents and extensions guide](rune-custom-agents-and-extensions-guide.en.md)
- [Troubleshooting and optimization guide](rune-troubleshooting-and-optimization-guide.en.md)

---

## Quick Setup: `/rune:talisman` (v1.103.0+)

The fastest way to get a properly configured talisman is the `/rune:talisman` skill:

```bash
# Scaffold a new talisman.yml for your project (auto-detects stack)
/rune:talisman init

# Check existing talisman for missing/outdated config
/rune:talisman audit

# Add missing sections to existing talisman
/rune:talisman update

# Learn about a specific configuration section
/rune:talisman guide codex
/rune:talisman guide arc
/rune:talisman guide review

# View talisman health summary
/rune:talisman status
```

The `init` subcommand detects your project stack (Python, TypeScript, Rust, PHP, Go, etc.) and generates a customized talisman with appropriate `ward_commands`, `backend_extensions`, and `dedup_hierarchy` prefixes.

---

## 1. Configuration Resolution Order

Talisman follows a **3-layer priority chain** (highest wins):

| Priority | Location | Scope |
|----------|----------|-------|
| 1 (highest) | `.rune/talisman.yml` | Project-level |
| 2 | `~/.rune/talisman.yml` | User-global |
| 3 | Plugin defaults | Built-in (7 Ashes) |

For arc flags, there is an additional layer: **CLI flags always override talisman values**.

```
CLI flags  >  .rune/talisman.yml  >  ~/.rune/talisman.yml  >  hardcoded defaults
```

**Tip**: Use project-level talisman for team-shared settings. Use global talisman for personal preferences (e.g., disabling forge enrichment on side projects).

---

## 2. File Classification: `rune-gaze`

Rune Gaze classifies changed files into categories that determine which Ashes get summoned. Override the defaults to match your project structure.

```yaml
rune-gaze:
  # Map extensions to backend Ash (Forge Warden)
  backend_extensions:
    - .py
    - .go
    - .rs
    - .rb

  # Map extensions to frontend Ash (Glyph Scribe)
  frontend_extensions:
    - .tsx
    - .ts
    - .jsx

  # Glob patterns to skip entirely — never reviewed
  skip_patterns:
    - "**/migrations/**"
    - "**/*.generated.ts"
    - "**/vendor/**"
    - "**/node_modules/**"

  # Files that are always reviewed regardless of extension
  always_review:
    - "CLAUDE.md"
    - ".claude/**/*.md"
```

### When to customize

| Scenario | What to change |
|----------|---------------|
| Monorepo with Go backend + React frontend | Set `backend_extensions: [.go]`, `frontend_extensions: [.tsx, .ts, .jsx]` |
| Auto-generated code you don't want reviewed | Add patterns to `skip_patterns` |
| Critical config files that must always be reviewed | Add to `always_review` |
| Unusual file extensions (e.g., `.svelte`, `.astro`) | Add to `frontend_extensions` |

---

## 3. Review Settings

### 3.1 Diff-Scope Engine

The diff-scope engine tells Ashes exactly which lines changed, enabling scope-aware findings.

```yaml
review:
  diff_scope:
    enabled: true           # Enable line-level diff intelligence
    expansion: 8            # Context lines above/below each hunk (0-50)
    tag_pre_existing: true  # Tag unchanged-code findings as "pre-existing"
    fix_pre_existing_p1: true  # Always fix pre-existing P1 (security) issues
```

**Key behavior**: When `tag_pre_existing: true`, mend skips pre-existing P2/P3 findings to focus on PR-relevant issues. P1 findings are always fixed regardless of scope.

### 3.2 Convergence Loop

Controls how the review-mend cycle converges in arc pipelines.

```yaml
review:
  # Smart scoring uses finding composition, not just raw count
  convergence:
    smart_scoring: true
    convergence_threshold: 0.7    # Score >= 0.7 = converged

  # Arc convergence (Phase 6 → 7 → 7.5 loop)
  arc_convergence_tier_override: null   # null = auto-detect, or force: light/standard/thorough
  arc_convergence_max_cycles: null      # Hard cap on re-review cycles (1-5)
  arc_convergence_min_cycles: null      # Min cycles before convergence allowed
  arc_convergence_finding_threshold: 0  # P1 count below this = converged
  arc_convergence_p2_threshold: 0       # P2 count below this = eligible
  arc_convergence_improvement_ratio: 0.5  # Findings must decrease by 50%
```

### Tier behavior

| Tier | Max cycles | Min cycles | Best for |
|------|-----------|-----------|----------|
| LIGHT | 2 | 1 | Small changes, low-risk PRs |
| STANDARD | 3 | 2 | Normal feature work |
| THOROUGH | 5 | 2 | High-risk changes, security-critical code |

### 3.3 Chunked Reviews

For large PRs (20+ files), Rune splits review into chunks:

```yaml
review:
  chunk_threshold: 20       # Trigger chunking above this file count
  chunk_target_size: 15     # Target files per chunk
  max_chunks: 5             # Circuit breaker
  cross_cutting_pass: true  # Cross-module consistency check after chunks
```

### 3.4 Enforcement Asymmetry

Variable strictness based on change context (new file vs edit, shared vs isolated):

```yaml
review:
  enforcement_asymmetry:
    enabled: true
    security_always_strict: true     # Security findings are always strict
    new_file_threshold: 0.30         # >30% lines changed = MAJOR_EDIT
    high_risk_import_count: 5        # Files imported by >5 others = HIGH risk
    high_risk_paths:
      - "core/**"
      - "shared/**"
      - "lib/**"
```

---

## 4. Work Execution Settings

```yaml
work:
  ward_commands:              # Quality gate commands (run after each commit)
    - "npm run lint"
    - "npm run typecheck"
    - "npm test"
  max_workers: 3              # Parallel swarm workers (2-6 recommended)
  commit_format: "rune: {subject} [ward-checked]"
  branch_prefix: "rune/work"  # Feature branch prefix
  co_authors:                 # Co-author attribution
    - "Claude <noreply@anthropic.com>"
```

### Ward commands best practices

| Project type | Recommended ward commands |
|-------------|--------------------------|
| Node.js/TypeScript | `["npm run lint", "npm run typecheck", "npm test"]` |
| Python | `["ruff check .", "mypy .", "pytest --tb=short"]` |
| Rust | `["cargo clippy", "cargo test"]` |
| Go | `["go vet ./...", "go test ./..."]` |

**Important**: Ward commands must complete within `BASH_DEFAULT_TIMEOUT_MS` (recommend 600000 = 10 min). If your test suite takes longer, increase the timeout in `.claude/settings.json`.

---

## 5. Arc Pipeline Configuration

### 5.1 Default flags

Set project-wide defaults for arc flags:

```yaml
arc:
  defaults:
    no_forge: false         # Skip forge enrichment
    approve: false          # Require human approval per task
    skip_freshness: false   # Bypass plan freshness gate
    confirm: false          # Pause between phases for confirmation
```

### 5.2 Ship settings (PR creation)

```yaml
arc:
  ship:
    auto_pr: true             # Create PR automatically
    auto_merge: false         # Merge after CI passes
    merge_strategy: "squash"  # squash | merge | rebase
    wait_ci: false            # Wait for CI before merge
    draft: false              # Create draft PR
    labels: ["rune"]          # Labels on PR
    rebase_before_merge: true # Rebase onto target before merge
```

### 5.3 Bot review integration

When using external review bots (CodeRabbit, Gemini Code Assist, etc.):

```yaml
arc:
  ship:
    bot_review:
      enabled: true                   # Enable Phase 9.1 + 9.2
      timeout_ms: 900000              # 15 min wait for bots
      initial_wait_ms: 120000         # 2 min for bots to start
      stability_window_ms: 120000     # 2 min of no new activity = done
      hallucination_check: true       # Verify bot findings against code
      known_bots:
        - "coderabbitai[bot]"
        - "gemini-code-assist[bot]"
        - "copilot[bot]"
```

### 5.4 Pre-merge checks

```yaml
arc:
  pre_merge_checks:
    migration_conflict: true
    schema_conflict: true
    lock_file_conflict: true
    uncommitted_changes: true
    migration_paths:          # Additional migration paths to scan
      - "db/migrate/"
      - "alembic/versions/"
```

### 5.5 Per-phase timeouts

Override individual phase timeouts (in milliseconds):

```yaml
arc:
  timeouts:
    forge: 900000          # 15 min
    work: 2100000          # 35 min
    code_review: 900000    # 15 min
    mend: 1380000          # 23 min
    test: 900000           # 15 min (40 min with E2E: 2400000)
    ship: 300000           # 5 min
    merge: 600000          # 10 min
```

---

## 6. Forge Gaze Tuning

Forge Gaze selects specialist agents for plan enrichment based on topic-keyword matching.

```yaml
forge:
  threshold: 0.30          # Score threshold (lower = more agents)
  max_per_section: 3       # Agents per plan section (cap: 5)
  max_total_agents: 8      # Total agents across all sections (cap: 15)
  stack_affinity_bonus: 0.2  # Bonus for stack-matching agents
```

| Mode | Threshold | Max/section | Budget | Use case |
|------|-----------|-------------|--------|----------|
| Default | 0.30 | 3 | enrichment | Daily feature work |
| `--exhaustive` | 0.15 | 5 | enrichment + research | Complex features, architecture changes |
| Conservative | 0.50 | 2 | enrichment | Quick plans, low-risk changes |

---

## 7. Goldmask Impact Analysis

Per-workflow Goldmask controls:

```yaml
goldmask:
  enabled: true              # Master switch

  forge:
    enabled: true            # Lore Layer risk scoring in forge

  mend:
    enabled: true            # Master switch for mend integration
    inject_context: true     # Risk context in fixer prompts
    quick_check: true        # Post-mend deterministic check

  devise:
    depth: "enhanced"        # basic (2 agents) | enhanced (6) | full (8)

  inspect:
    enabled: true            # Lore Layer in inspect
    wisdom_passthrough: true # Wisdom advisories in inspector prompts
```

**Token impact by depth**:

| Depth | Agents | Token cost | Recommended for |
|-------|--------|------------|----------------|
| `basic` | 2 | Low | Quick plans, small features |
| `enhanced` | 6 | Medium | Standard feature work (default) |
| `full` | 8 | High | High-risk changes, security-critical |

---

## 8. Testing Configuration

```yaml
testing:
  enabled: true
  tiers:
    unit:
      enabled: true
      timeout_ms: 300000     # 5 min per suite
      coverage: true
    integration:
      enabled: true
      timeout_ms: 300000
    e2e:
      enabled: true
      timeout_ms: 300000     # 5 min per route
      base_url: "http://localhost:3000"
      max_routes: 3
      headed: false          # Set true for debugging

  service:
    startup_command: null     # Override: "bin/dev" or "docker compose up -d"
    health_endpoint: null     # Override: "/api/health"
    startup_timeout: 180000   # 3 min max startup wait
```

---

## 9. Audit Configuration

### Standard vs Deep audit

```yaml
audit:
  deep:
    enabled: true
    ashes:                   # Investigation agents for deep pass
      - rot-seeker
      - strand-tracer
      - decree-auditor
      - fringe-watcher
    max_deep_ashes: 4
    dimensions:              # Deep analysis dimensions
      - truth-seeker         # Correctness
      - ruin-watcher         # Failure modes
      - breach-hunter        # Security-deep
      - order-auditor        # Design
      - ember-seer           # Performance
      - signal-watcher       # Observability
      - decay-tracer         # Maintainability
  always_deep: false         # Set true to always run deep pass
```

### Incremental audit (stateful)

```yaml
audit:
  incremental:
    enabled: true
    batch_size: 30            # Files per batch
    weights:                  # Priority scoring weights (sum = 1.0)
      staleness: 0.30
      recency: 0.25
      risk: 0.20
      complexity: 0.10
      novelty: 0.10
      role: 0.05
    always_audit:             # Always include in every batch
      - "CLAUDE.md"
      - "**/auth/**"
    coverage_target: 0.80
    staleness_window_days: 90
```

---

## 10. Echoes (Agent Memory)

```yaml
echoes:
  version_controlled: false   # Track echoes in git
  fts_enabled: true           # Full-text search via MCP
```

Advanced echo tuning (mostly opt-in):

| Feature | Key | Default | Purpose |
|---------|-----|---------|---------|
| Semantic groups | `semantic_groups.expansion_enabled` | false | Cluster related entries |
| Query decomposition | `decomposition.enabled` | false | Multi-facet BM25 search |
| Haiku reranking | `reranking.enabled` | false | Semantic re-scoring |
| Failed entry retry | `retry.enabled` | false | Token fingerprint matching |

---

## 11. Codex Oracle (Cross-Model Verification)

```yaml
codex:
  disabled: false              # Kill switch
  model: "gpt-5.3-codex"
  reasoning: "xhigh"          # xhigh | high | medium | low
  timeout: 600                 # Outer timeout in seconds
  stream_idle_timeout: 540     # Inner idle timeout

  # IMPORTANT: include "arc" for Codex to run in arc phases (v1.87.0+)
  workflows: [review, audit, plan, forge, work, mend, goldmask, inspect, arc]

  # 17 inline verification points (v1.51.0+, expanded v1.87.0+)
  diff_verification:
    enabled: true              # P1/P2 findings vs diff hunks
  test_coverage_critique:
    enabled: true              # Test coverage gaps
  section_validation:
    enabled: true              # Plan section coverage
  task_decomposition:
    enabled: true              # Task granularity validation
```

---

## 12. Platform Environment Variables

These go in `.claude/settings.json` (not talisman):

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "BASH_DEFAULT_TIMEOUT_MS": "600000",
    "BASH_MAX_TIMEOUT_MS": "3600000"
  }
}
```

| Variable | Default | Recommended | Why |
|----------|---------|-------------|-----|
| `BASH_DEFAULT_TIMEOUT_MS` | 120,000 | 600,000 | Ward checks, test suites often exceed 2 min |
| `BASH_MAX_TIMEOUT_MS` | 120,000 | 3,600,000 | Caps per-call timeout parameter |
| `MCP_TIMEOUT` | 10,000 | 30,000 | Slow-starting MCP servers |

---

## 13. Project-Type Recipes

### Recipe: Node.js/TypeScript project

```yaml
version: 1

rune-gaze:
  backend_extensions: [.ts]
  frontend_extensions: [.tsx, .jsx]
  skip_patterns: ["**/dist/**", "**/*.d.ts", "**/node_modules/**"]

work:
  ward_commands: ["npm run lint", "npm run typecheck", "npm test -- --passWithNoTests"]
  max_workers: 3
  branch_prefix: "rune/feat"

testing:
  enabled: true
  tiers:
    e2e:
      base_url: "http://localhost:3000"
  service:
    startup_command: "npm run dev"
    health_endpoint: "/api/health"
```

### Recipe: Python/FastAPI project

```yaml
version: 1

rune-gaze:
  backend_extensions: [.py]
  skip_patterns: ["**/__pycache__/**", "**/migrations/**", "**/.venv/**"]

work:
  ward_commands: ["ruff check .", "mypy . --ignore-missing-imports", "pytest --tb=short -q"]
  max_workers: 2

testing:
  tiers:
    unit:
      timeout_ms: 600000
    integration:
      enabled: true
  service:
    startup_command: "uvicorn app.main:app --port 8000"
    health_endpoint: "/health"
```

### Recipe: Monorepo (mixed stacks)

```yaml
version: 1

rune-gaze:
  backend_extensions: [.py, .go]
  frontend_extensions: [.tsx, .ts, .jsx, .vue]
  skip_patterns:
    - "**/vendor/**"
    - "**/dist/**"
    - "**/generated/**"
  always_review:
    - "CLAUDE.md"
    - ".claude/**/*.md"
    - "shared/**"

settings:
  max_ashes: 9

work:
  ward_commands: ["make lint", "make test"]
  max_workers: 4

arc:
  ship:
    labels: ["rune", "auto-generated"]
  timeouts:
    work: 2400000   # 40 min for larger codebases
```

---

## 14. Disabling Built-in Ashes

Replace a built-in Ash with your own custom version:

```yaml
defaults:
  disable_ashes:
    - "knowledge-keeper"    # Replaced by custom doc reviewer
    - "veil-piercer"        # Not needed for this project
```

Valid names: `forge-warden`, `ward-sentinel`, `veil-piercer`, `pattern-weaver`, `glyph-scribe`, `knowledge-keeper`, `codex-oracle`.

---

## 15. Mend Settings

```yaml
mend:
  cross_file_batch_size: 3    # Max files read per batch for cross-file mend (1-10)
  todos_per_fixer: 5          # Max file-todos per fixer wave
```

---

## 16. File Todos (Schema v2, v1.101.0+)

All todos are session-scoped and mandatory. The following keys were **removed** in v1.101.0 — delete them if present:
- `file_todos.enabled` — todos are now always on
- `file_todos.dir` — todos live in `tmp/{workflow}/{id}/todos/`
- `file_todos.auto_generate.work` — work todos are always generated

Current schema:

```yaml
file_todos:
  triage:
    auto_approve_p1: false        # Auto-approve P1 items during triage
  manifest:
    auto_build: true              # Auto-rebuild manifest when dirty
    dedup_on_build: false         # Dedup detection on each build
    dedup_threshold: 0.70         # Jaro-Winkler + Jaccard threshold
  history:
    enabled: true                 # Track status transitions
```

---

## 17. Context Management

### Context Monitor

```yaml
context_monitor:
  enabled: true                   # Enable context monitoring
  warning_threshold: 0.4          # Warn at 40% context remaining
  critical_threshold: 0.25        # Hard deny at 25% context remaining
```

### Context Weaving

```yaml
context_weaving:
  glyph_budget: 300               # Max words per agent message
  offload_threshold: 500          # Lines above which content offloads to file
  rot_detection: true             # Detect stale context in long sessions
```

---

## 18. Quick Reference: All Top-Level Keys

| Key | Purpose | Default |
|-----|---------|---------|
| `version` | Config version | `1` |
| `rune-gaze` | File classification overrides | Auto-detect |
| `ashes` | Custom Ash definitions | None |
| `settings` | Global limits (max_ashes, dedup) | 7 Ashes |
| `defaults` | Disable built-in Ashes | None disabled |
| `audit` | Deep/incremental audit settings | Deep enabled |
| `forge` | Forge Gaze thresholds | 0.30 threshold |
| `plan` | Verification patterns, freshness gate | Enabled |
| `inspect` | Plan-vs-implementation audit | 4 inspectors |
| `arc` | Pipeline defaults, ship, timeouts | See per-key |
| `solution_arena` | Competitive solution evaluation | Enabled |
| `review` | Diff-scope, convergence, chunking | All enabled |
| `work` | Ward commands, workers, branch | 3 workers |
| `testing` | 3-tier test execution | All tiers on |
| `goldmask` | Per-workflow impact analysis | All enabled |
| `codex` | Cross-model verification (17 inline points) | Auto-detect |
| `codex_review` | Cross-model code review settings | Disabled |
| `teammate_lifecycle` | Agent runtime caps (max_turns, max_runtime_minutes) | Category defaults |
| `elicitation` | Structured reasoning | Enabled |
| `echoes` | Agent memory persistence | FTS enabled |
| `mend` | Parallel finding resolution | 3 batch, 5 per fixer |
| `file_todos` | File-based todo tracking (schema v2) | Mandatory |
| `horizon` | Strategic depth assessment | Enabled |
| `context_monitor` | Context budget monitoring | 40% warn, 25% deny |
| `context_weaving` | Glyph budget and offloading | 300 words budget |
| `inner_flame` | Self-review protocol | Enabled |
| `doubt_seer` | Evidence quality challenger | Disabled (opt-in) |

> **Tip**: Use `/rune:talisman audit` to compare your project config against the latest template and find missing keys.

See [`talisman.example.yml`](../../plugins/rune/talisman.example.yml) for the complete schema with all options and ranges.
