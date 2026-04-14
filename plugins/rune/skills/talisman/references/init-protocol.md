# INIT — Scaffold Protocol

## Phase 2: Detect Project Stack

Scan project root for stack signals:

```
Signal Detection:
  - package.json → Node.js/TypeScript (check for tsx/ts in dependencies)
  - requirements.txt / pyproject.toml / setup.py → Python
  - Cargo.toml → Rust
  - composer.json → PHP (check for laravel/framework)
  - go.mod → Go
  - Gemfile → Ruby
  - pom.xml / build.gradle → Java/Kotlin
  - .csproj → C#/.NET
  - Makefile / CMakeLists.txt → C/C++
  - mix.exs → Elixir

Also detect:
  - .github/workflows/ → CI/CD present
  - docker-compose.yml / Dockerfile → Docker present
  - prisma/ → Prisma ORM
  - alembic/ → Alembic migrations
  - db/migrate/ → Rails migrations
```

## Phase 2.3: Agent Recommendations (v1.178.0+)

After stack detection, query agent-search MCP for stack-relevant agents and scaffold `stack_awareness.priority`:

```
stack = detectStack()  # from Phase 2

# Query agent-search MCP for stack-relevant agents (skip if MCP unavailable)
recommendations = []
if agent-search MCP available:
  for lang in stack.languages:
    results = mcp__plugin_rune_agent-search__agent_search({
      query: "{lang} review specialist",
      phase: "appraise",
      language: lang,    # New language filter from Task 2
      limit: 3
    })
    if results:
      recommendations.append({ language: lang, agents: results })

# Present recommendations to user
if recommendations:
  Show: "Detected stack: {stack.primary_language} + {stack.frameworks}.
         Found relevant agents: {agent names}.
         Add to talisman.yml? [Yes/No]"

  if user confirms:
    # Build explicit YAML — do NOT use generate_custom_ash_config()
    for rec in recommendations:
      for agent in rec.agents:
        Append to ashes.custom section:
          """
          ashes:
            custom:
              - name: "{agent.name}"
                agent: "{agent.name}"
                source: {agent.source}
                workflows: [review, audit]
                finding_prefix: "{derive_prefix(agent.name)}"
          """

# Scaffold stack_awareness.priority based on detected stack
Append to generated talisman:
  """
  stack_awareness:
    priority:
      languages: [{stack.languages joined}]     # From manifest detection
      frameworks: [{stack.frameworks joined}]    # From dependency detection
      boost_factor: 1.5                          # Default multiplier
  """
```

## Phase 3: Read Example Template

```
Read the canonical example:
  Read("${RUNE_PLUGIN_ROOT}/talisman.example.yml")

This is the SINGLE SOURCE OF TRUTH for all talisman keys.
```

## Phase 4: Generate Project Talisman

Based on detected stack, customize the template:

**Core sections (always include):**
- `version: 1`
- `rune-gaze:` — with stack-appropriate extensions
- `settings:` — with dedup_hierarchy including stack prefixes
- `codex:` — with workflows including arc
- `review:` — diff_scope + convergence + sharding
- `work:` — ward commands from detected stack
- `arc:` — defaults + ship + timeouts
- `file_todos:` — schema v2 (triage, manifest, history)

**Stack-specific customization:**

| Stack | `backend_extensions` | `ward_commands` | `dedup_hierarchy` additions |
|-------|---------------------|-----------------|----------------------------|
| Python | `.py` | `make check`, `pytest` | PY, FAPI/DJG (if detected) |
| TypeScript | `.ts`, `.tsx` | `npm test`, `npm run lint` | TSR |
| Rust | `.rs` | `cargo test`, `cargo clippy` | RST |
| PHP | `.php` | `composer test` | PHP, LARV (if Laravel) |
| Go | `.go` | `go test ./...`, `go vet ./...` | — |
| Ruby | `.rb` | `bundle exec rspec` | — |

**Optional sections (include if relevant):**
- `ashes.custom:` — only if user has `.claude/agents/` with custom agents
- `audit:` — for projects with large codebases
- `testing:` — if test framework detected
- `context_monitor:` / `context_weaving:` — always include defaults
- `integrations:` — if `.mcp.json` contains custom MCP servers (not built-in like context7)
- `blind_verification:` — scaffolded when `discipline.enabled` or arc usage detected. Omit to use defaults (`enabled: false`). When enabled, runs AC-only verification within strive Phase 4.6 using a blind agent that receives acceptance criteria but no implementation context
- `echoes.skill_promotion:` — scaffolded with defaults (`enabled: true`, `min_access_count: 5`, `min_score: 0.6`, `target: project`) only when the `echoes:` section does NOT already contain a `skill_promotion:` subkey. Idempotent: preserves user customizations on re-run. See `plugins/rune/skills/talisman/references/talisman-sections.md` for the full schema and tier-eligibility table.

### Idempotent Echo-Section Defaults

When writing or updating `echoes:`, always check for existing subkeys before emitting defaults — do NOT overwrite user configuration:

```python
# Pseudocode for idempotent talisman writes
talisman = read_talisman()
echoes = talisman.setdefault("echoes", {})

if "skill_promotion" not in echoes:
    echoes["skill_promotion"] = {
        "enabled": True,
        "min_access_count": 5,
        "min_score": 0.6,
        "target": "project",
    }
# If skill_promotion already exists, leave it untouched — user may have customized
```

This rule applies to ALL `echoes:` subkeys (skill_promotion, artifact_indexing, session_summary, etc.). Idempotent writes are a hard requirement for `init-protocol.md` because it runs on every `/rune:talisman init` and `/rune:talisman update` invocation.

**Design Review gates (v1.149.0) — under `design_review:`:**

Include these when `design_sync.enabled: true` and React/TypeScript frontend files are detected. The `design_review` section controls Phase 1.6 conditional gate in the appraise workflow.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `false` | Enable Phase 1.6 design fidelity gate in `/rune:appraise`. When true, spawns `design-implementation-reviewer` when frontend files are in the diff. |
| `prefix` | string | `"DES"` | Finding prefix for design fidelity findings. Always `DES` when activated via Phase 1.6. |
| `timeout_ms` | int | `300000` | Timeout for the design-implementation-reviewer Ash (ms). If it times out, treat as empty findings — Runebinder proceeds deterministically. |

**inscription.json `design_context` field schema** (written at Phase 2 when `design_review.enabled`):

```yaml
# inscription.json — design_context schema (injected at Phase 2 Forge Team)
# design_context:
#   inventory_path: string    — path to design inventory JSON from Shard 2 arc phase
#                               (e.g., tmp/reviews/{id}/design-inventory.json)
#   figma_url: string         — Figma source URL from talisman.design_sync.figma_url
#                               (empty string if not set)
#   component_count: number   — count of components in inventory (0 if inventory absent)
```

**Soft warning**: If `design_review.enabled` is true but Shard 2 dependency artifacts are absent (no `design-inventory*.json` found in `outputDir`), Phase 1.6 emits a warning and proceeds — `design-implementation-reviewer` runs without component inventory context. This is low risk in sequential arc pipelines where Shard 2 always precedes the design review phase.

**Prototype pipeline fields (v1.147.0) — under `design_sync:`:**

Include these when `design_sync.enabled: true` and React/TypeScript stack is detected:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `prototype_generation` | bool | `true` | Stage 3: synthesize prototypes from figma-ref + library-match. When false, pipeline stops at matching. |
| `storybook_preview` | bool | `true` | Generate Storybook CSF3 stories alongside prototypes. Creates Default, Loading, Error, Empty, Disabled stories. |
| `max_reference_components` | int | `5` | Max components to extract per Figma URL in Phase 1. Higher values increase pipeline duration. |
| `reference_timeout_ms` | int | `15000` | Per-component figma_to_react timeout in ms. Components exceeding this are skipped. |
| `library_timeout_ms` | int | `10000` | Per-component UntitledUI search timeout in ms for Phase 2 matching. |
| `library_match_threshold` | float | `0.5` | Minimum confidence for library match (0.0-1.0). Below threshold → no library-match.tsx generated. |

**MCP Integration Detection (Phase 2.5):**
```
If .mcp.json exists:
  Parse server names from .mcp.json
  Filter out built-in servers: sequential-thinking, context7, echo-search, figma-to-react
  If custom servers remain:
    Include integrations.mcp_tools scaffold with one entry per custom server
    Pre-fill server_name, empty tools[], default phases (devise+strive+forge=true)
    Add trigger.always: false with TODO comment for user to configure
```

## Phase 5: Write and Confirm

```
1. Write ONLY .rune/talisman.yml (single file)
   - Do NOT generate companion files (talisman.ashes.yml, talisman.integrations.yml)
   - Do NOT mention companion files or the split layout during init
   - Companion files are an advanced feature suggested contextually later:
     * When user adds custom ashes via /rune:talisman guide ashes
     * When user configures codex deep integration
     * When /rune:talisman audit detects the file exceeds ~500 lines
   - The split layout is always optional — single-file is the default

2. Show summary of what was generated:
   - Detected stack
   - Sections included
   - Key customizations made

3. Suggest next steps:
   - "Review the generated file"
   - "Run /rune:talisman audit to verify completeness"
   - "Customize further with /rune:talisman guide [section]"
```
