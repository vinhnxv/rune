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

## Phase 3: Read Example Template

```
Read the canonical example:
  Read("${CLAUDE_PLUGIN_ROOT}/talisman.example.yml")

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
1. Write to .claude/talisman.yml
2. Show summary of what was generated:
   - Detected stack
   - Sections included
   - Key customizations made
3. Suggest next steps:
   - "Review the generated file"
   - "Run /rune:talisman audit to verify completeness"
   - "Customize further with /rune:talisman guide [section]"
```
