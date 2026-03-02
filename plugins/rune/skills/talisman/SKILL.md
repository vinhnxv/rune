---
name: talisman
description: |
  Deep talisman.yml configuration expertise. Initialize, audit, update, and guide
  talisman configuration for any project. Scaffolds project-specific talisman.yml
  from the canonical example template, detects missing sections, and provides
  expert guidance on every configuration key.

  Use when the user says "init talisman", "setup talisman", "create talisman",
  "talisman audit", "check talisman", "talisman guide", "explain talisman",
  "update talisman", "talisman status", "what's in talisman", "configure rune",
  "rune config", "rune setup".

  Subcommands:
    /rune:talisman init          — Scaffold new talisman.yml for current project
    /rune:talisman audit         — Compare existing talisman against latest template
    /rune:talisman update        — Add missing sections to existing talisman
    /rune:talisman guide [topic] — Explain talisman sections and best practices
    /rune:talisman status        — Show current talisman summary

  Keywords: talisman, config, configuration, setup, init, initialize, scaffold,
  customize, rune config, rune setup, talisman audit, talisman gap.

  <example>
  user: "/rune:talisman init"
  assistant: "Detects project stack, scaffolds talisman.yml..."
  </example>

  <example>
  user: "/rune:talisman audit"
  assistant: "Comparing project talisman against latest template..."
  </example>

  <example>
  user: "/rune:talisman guide codex"
  assistant: "Explains Codex configuration keys..."
  </example>
user-invocable: true
disable-model-invocation: false
argument-hint: "[init|audit|update|guide|status]"
---

# /rune:talisman — Configuration Mastery

Deep expertise for `.claude/talisman.yml` — the project-level configuration
that controls all Rune agent behavior.

**References**:
- [Talisman sections](references/talisman-sections.md) — top-level sections with key descriptions
- [Configuration guide](../../references/configuration-guide.md) — full schema with types and defaults
- [Example template](../../talisman.example.yml) — canonical 950+ line example

## Subcommand Routing

Parse `$ARGUMENTS` to determine subcommand:

| First Word | Subcommand | Action |
|-----------|-----------|--------|
| `init` | INIT | Scaffold new talisman.yml |
| `audit` | AUDIT | Compare existing vs template |
| `update` | UPDATE | Add missing sections |
| `guide` | GUIDE | Explain configuration |
| `status` | STATUS | Show talisman summary |
| (empty) | STATUS | Default to status |

## INIT — Scaffold New Talisman

### Phase 1: Pre-flight Check

```
1. Check if .claude/talisman.yml already exists
   → If exists: warn and offer AUDIT instead
   → If not: proceed

2. Check if .claude/ directory exists
   → If not: create it
```

### Phase 2: Detect Project Stack

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

### Phase 3: Read Example Template

```
Read the canonical example:
  Read("${CLAUDE_PLUGIN_ROOT}/talisman.example.yml")

This is the SINGLE SOURCE OF TRUTH for all talisman keys.
```

### Phase 4: Generate Project Talisman

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

### Phase 5: Write and Confirm

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

## AUDIT — Compare Against Template

### Phase 1: Read Both Files

```
1. Read project talisman: .claude/talisman.yml
   → If missing: suggest INIT instead
2. Read example template: ${CLAUDE_PLUGIN_ROOT}/talisman.example.yml
```

### Phase 2: Deep Comparison

For each top-level section in the example:

```
Categories:
  MISSING   — Section exists in example but not in project
  OUTDATED  — Section exists but has deprecated/removed keys
  PARTIAL   — Section exists but missing sub-keys
  DIVERGENT — Value differs significantly from example default
  OK        — Section present and up-to-date
```

### Phase 3: Gap Report

Present findings in priority order:

```
1. CRITICAL gaps — missing sections that affect core functionality
   (codex.workflows missing entries, deprecated file_todos keys, etc.)
2. RECOMMENDED — sections that improve workflow quality
   (missing codex deep integration keys, missing arc timeouts, etc.)
3. OPTIONAL — nice-to-have sections
   (context_monitor, horizon, etc.)
4. DIVERGENT — intentional? values that differ from defaults
   (max_budget, max_turns, etc.)
```

### Phase 4: Suggest Actions

```
For each gap:
  - Show the example value
  - Explain why it matters
  - Offer to fix via UPDATE subcommand
```

## UPDATE — Add Missing Sections

### Phase 1: Run AUDIT internally

Same as AUDIT Phase 1-3, but automated.

### Phase 2: Present Changes

```
Show what will be added/changed:
  - New sections to add
  - Keys to update
  - Deprecated keys to remove

AskUserQuestion: "Apply these changes?"
  - "Apply all"
  - "Apply critical only"
  - "Review each section"
```

### Phase 3: Apply Changes

```
Use Edit tool to modify .claude/talisman.yml:
  - Add missing sections at appropriate positions
  - Update deprecated keys
  - Preserve existing project-specific values
  - Add YAML comments for context
```

### Phase 4: Verify

```
Re-read the file to verify YAML validity
Show summary of changes applied
```

## GUIDE — Expert Configuration Guidance

### Routing

Parse remaining args after "guide":

```
/rune:talisman guide           → Overview of all sections
/rune:talisman guide codex     → Codex integration keys
/rune:talisman guide arc       → Arc pipeline configuration
/rune:talisman guide review    → Review/sharding/convergence
/rune:talisman guide work      → Work/strive settings
/rune:talisman guide ashes     → Custom Ashes configuration
/rune:talisman guide goldmask  → Goldmask per-workflow integration
/rune:talisman guide mend      → Mend settings
/rune:talisman guide [topic]   → Match to closest section
```

### Response Format

For each topic:
1. What it controls
2. Key configuration keys with types and defaults
3. When to change from defaults
4. Common pitfalls
5. Example configuration snippet

Load details from:
- [talisman-sections.md](references/talisman-sections.md) for section summaries
- [configuration-guide.md](../../references/configuration-guide.md) for full schema
- [talisman.example.yml](../../talisman.example.yml) for canonical values

## STATUS — Talisman Summary

### Phase 1: Locate Talisman

```
1. Check .claude/talisman.yml (project)
2. Check ${CHOME}/talisman.yml (global) where CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
3. Report which level is active
```

### Phase 2: Parse and Summarize

```
For each top-level section present:
  - Section name
  - Key count
  - Notable overrides from defaults

Also report:
  - Total sections: N/[schema total]
  - Codex workflows enabled: [list]
  - Cost tier: [tier]
  - Custom Ashes: [count]
  - Ward commands: [list]
```

### Phase 3: Health Check

```
Quick health indicators:
  ✓ codex.workflows includes arc
  ✓ file_todos uses schema v2 (no deprecated keys)
  ✓ dedup_hierarchy has stack-appropriate prefixes
  ✓ arc.timeouts defined
  ✗ Missing: [sections not present]
```

## readTalisman Pattern

Always use SDK Read() — NEVER Bash for talisman access:

```javascript
// Project level
Read(".claude/talisman.yml")

// Global level (fallback)
Read("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/talisman.yml")

// NEVER: Bash("cat ~/.claude/talisman.yml") — ZSH tilde bug
```

## Persona

Use Rune's Elden Ring-inspired tone:

```
The Tarnished studies the Talisman...
  Section map loaded, 17 active in your project.
  4 gaps detected — 1 critical, 2 recommended, 1 optional.
```

```
A new Talisman is forged for this project.
  Stack detected: Python + FastAPI
  Ward commands: pytest, mypy --strict
  Codex enabled for: review, audit, plan, forge, work, arc
```
