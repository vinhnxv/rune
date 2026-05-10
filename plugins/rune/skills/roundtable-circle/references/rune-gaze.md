# Rune Gaze — Scope Selection

<!-- v3.x: defaults baked from former talisman.misc + talisman.settings + talisman.stack_awareness; see references/v3-defaults.md -->

> Extension-based file classification for Ash selection. Generic and configurable.

## Table of Contents

- [File Classification Algorithm](#file-classification-algorithm)
- [Extension Groups](#extension-groups)
  - [Backend Extensions](#backend-extensions)
  - [Frontend Extensions](#frontend-extensions)
  - [Infrastructure Extensions](#infrastructure-extensions)
  - [Config Extensions](#config-extensions)
  - [Documentation Extensions](#documentation-extensions)
  - [Skip Extensions (Never Review)](#skip-extensions-never-review)
- [Ash Selection Matrix](#ash-selection-matrix)
- [Configurable Overrides](#configurable-overrides)
- [Special File Handling](#special-file-handling)
  - [Critical Files (Always Review)](#critical-files-always-review)
  - [Critical Deletions](#critical-deletions)
- [Line Count Threshold for Docs](#line-count-threshold-for-docs)

## File Classification Algorithm

```
Input: list of changed files (from git diff)
Output: { code_files, doc_files, minor_doc_files, infra_files, skip_files, ash_selections }

for each file in changed_files:
  ext = file.extension
  classified = false

  if ext in SKIP_EXTENSIONS:
    skip_files.add(file)
    continue

  if ext in BACKEND_EXTENSIONS:
    code_files.add(file)
    ash_selections.add("forge-warden")
    classified = true

  if ext in FRONTEND_EXTENSIONS:
    code_files.add(file)
    ash_selections.add("glyph-scribe")
    classified = true

  if ext in DOC_EXTENSIONS:
    if lines_changed(file) >= DOC_LINE_THRESHOLD:
      doc_files.add(file)
      ash_selections.add("knowledge-keeper")
    else:
      minor_doc_files.add(file)  # Below threshold — may be promoted
    classified = true

  if ext in INFRA_EXTENSIONS OR file.name in INFRA_FILENAMES:
    infra_files.add(file)
    ash_selections.add("forge-warden")   # Infra → Forge Warden (backend-adjacent)
    classified = true

  if ext in CONFIG_EXTENSIONS:
    infra_files.add(file)                # Config grouped with infra
    ash_selections.add("forge-warden")   # Config → Forge Warden
    classified = true

  # Catch-all: file doesn't match any group and isn't skipped
  if NOT classified:
    infra_files.add(file)                # Unclassified → infra bucket
    ash_selections.add("forge-warden")   # Default to backend review

# Docs-only-and-all-below-threshold override: when the ENTIRE diff is documentation
# (no code/infra files) AND every doc file fell below DOC_LINE_THRESHOLD,
# promote minor doc files so they are still reviewed by Knowledge Keeper.
# Note: if ANY doc file exceeds the threshold, it goes to doc_files normally
# and the remaining below-threshold files are discarded as minor.
if code_files.empty AND infra_files.empty AND doc_files.empty AND minor_doc_files.not_empty:
  doc_files = minor_doc_files       # Promote all
  ash_selections.add("knowledge-keeper")
else:
  skip_files.addAll(minor_doc_files) # Discard as minor

# .claude/ path escalation: any .claude/ file gets Ward Sentinel with
# explicit security-boundary context (allowed-tools, prompt injection surface)
for each file in changed_files:
  if file.path starts with ".claude/":
    ash_selections.add("ward-sentinel")  # Already always-on, but marks priority
    ash_selections.add("knowledge-keeper")  # .claude/*.md are both docs AND security

# ── Phase 1A: Stack Detection (v1.86.0+) ──
# Runs before generic classification. Adds stack-specialist Ashes
# based on detected project stack (language, framework, patterns).
# See skills/stacks/references/detection.md for detectStack() algorithm.
# See skills/stacks/references/context-router.md for computeContextManifest().
#
# NOTE: Stack specialist prompts live in specialist-prompts/ (not agents/review/).
# buildAshPrompt() derives the prompt directory from the filesystem — if a name
# matches a file in specialist-prompts/, it loads from there; otherwise agents/.
# No hardcoded specialist list exists here — detection drives selection.

stack = detectStack(repoRoot)
# v3.x: hardcoded — formerly talisman.stack_awareness.{confidence_threshold,max_stack_ashes}
confidence_threshold = 0.6
max_stack_ashes = 3

if stack.confidence >= confidence_threshold:
  specialist_selections = []

  # 1. Language specialist (max 1)
  lang_map = { "python": "python-reviewer", "typescript": "typescript-reviewer",
               "rust": "rust-reviewer", "php": "php-reviewer" }
  if stack.primary_language in lang_map:
    lang_reviewer = lang_map[stack.primary_language]
    if any(file.ext matches lang_reviewer.extensions for file in changed_files):
      specialist_selections.add(lang_reviewer)

  # 2. Framework specialists (max 2, priority order)
  fw_priority = ["fastapi", "django", "laravel", "sqlalchemy"]
  selected_fw = 0
  for fw in fw_priority:
    if fw in stack.frameworks AND selected_fw < 2:
      specialist_selections.add(fw + "-reviewer")
      selected_fw++

  # 3. Pattern specialists (conditional)
  if any(file.path matches "test*" OR file.path matches "*_test*" for file in changed_files):
    specialist_selections.add("tdd-compliance-reviewer")
  if has_ddd_structure(repoRoot):
    specialist_selections.add("ddd-reviewer")
  if stack.libraries intersects ["dishka", "dependency-injector", "tsyringe"]:
    specialist_selections.add("di-reviewer")

  # 4. Design Fidelity Gate — REMOVED in v3.x.
  # talisman.design_sync was baked to {} (subsystem off). The Figma-to-code
  # fidelity reviewer is now opt-in via /rune:design-sync directly.
  hasFrontend = any(file.ext in [".tsx", ".jsx", ".css", ".scss", ".vue", ".svelte"] for file in changed_files)

  # 4.5. Design System Compliance Gate (always on in v3.x when frontend + design system detected)
  # Triggered by: frontend files (.tsx, .jsx, .css, .scss) AND design system confidence >= 0.5
  # Keywords: design system, tokens, CVA, cn(), tailwind, component patterns
  # Validates codebase conventions independent of Figma fidelity.
  ds_confidence = stack.design_system?.confidence ?? 0
  if hasFrontend AND ds_confidence >= 0.5:
    specialist_selections.add("design-system-compliance-reviewer")

  # 5. Enforce cap
  specialist_selections = specialist_selections[:max_stack_ashes]

  # 6. Add to ash_selections
  for specialist in specialist_selections:
    ash_selections.add(specialist)

  # 7. Store stack context in inscription
  inscription.detected_stack = stack
  inscription.specialist_ashes = specialist_selections

# ── Meta-audit: Plugin Sediment Detection (v1.161.0+) ──
# When scope is "full" (audit mode) AND repo is a Claude Code plugin,
# auto-select sediment-detector to scan for dead plugin infrastructure.
if scope === "full" AND exists(".claude-plugin/plugin.json"):
  ash_selections.add("sediment-detector")

# ── Schema Drift Detection (v1.161.0+) ──
# When diff contains schema or migration files, tag inscription so
# Forge Warden activates Perspective 10 (schema-drift-detector).
# v3.x: misc.schema_drift.enabled is baked to true — gate removed.
schema_patterns = [
  "db/schema.rb", "db/structure.sql", "db/migrate/",
  "prisma/schema.prisma", "prisma/migrations/",
  "alembic/versions/", "*/migrations/",
  "drizzle/schema.ts", "drizzle/migrations/",
  "src/migrations/", "migrations/",
  "*.changelog.xml", "*.changelog.yaml",
  "V*__*.sql"
]
has_schema_files = false
for each file in changed_files:
  if file.path matches any schema_patterns:
    has_schema_files = true
    break
if has_schema_files:
  inscription.schema_drift_active = true  # Forge Warden reads this to activate Perspective 10

# ── Static Ash selection only (v3.x+) ──
# CORE agents (agents/*.md) are selected via the hardcoded logic above.
# Dynamic discovery via agent-search MCP was removed in v3.0.0-alpha.1 —
# user-defined agents from talisman.yml user_agents[] are still loaded
# directly by the orchestrator via Read of the agents directory.

# Always-on Ash (regardless of file types)
# NOTE: pattern-weaver (always-on quality Ash) is distinct from pattern-seer
# (cross-cutting consistency specialist, triggered by file patterns in review)
ash_selections.add("ward-sentinel")   # Security: always
ash_selections.add("pattern-weaver")  # Quality: always
ash_selections.add("veil-piercer")    # Truth: always

# CLI-gated Ash (always-on when available, conditional on CLI, not file type)
# Check talisman first (user may have disabled)

# External model CLI-backed Ashes (multi-model adversarial review, v1.57.0+)
# Iterate ashes.custom[] entries where cli: is present (discriminated union — see custom-ashes.md).
#   1. Applies max_cli_ashes limit BEFORE detection (default: 2)
#   2. Runs detectExternalModel(config) for each candidate
#   3. Returns validated entries only
cli_ashes = detectAllCLIAshes(talisman, current_workflow)
for each cli_ash in cli_ashes:
  ash_selections.add(cli_ash.name)

# Agent-backed custom Ashes (from talisman.yml ashes.custom[], v1.17.0+)
# Iterate ashes.custom[] entries where cli: is NOT present (agent-backed — see custom-ashes.md).
# Discovery MUST happen here (Phase 1) so custom Ashes are included in selectedAsh
# BEFORE Phase 2 (TeamCreate + TaskCreate). Spawning happens in Phase 3 (ash-summoning.md).
current_workflow = "review"  # or "audit" depending on calling skill
custom_agent_ashes = []
if settings.ashes?.custom:
  for each entry in settings.ashes.custom:  // v3.x: defaults to []
    # Skip CLI-backed entries (handled above by detectAllCLIAshes)
    if entry.cli:
      continue

    # 1. Workflow filter: keep only entries matching current workflow
    if current_workflow not in entry.workflows:
      continue

    # 2. Validate agent name: must match /^[a-zA-Z0-9_:-]+$/
    if not /^[a-zA-Z0-9_:-]+$/.test(entry.agent):
      log("Invalid agent name '{entry.agent}' — skipping")
      continue

    # 3. Validate unique finding_prefix (2-5 uppercase, no reserved collisions)
    if entry.finding_prefix in RESERVED_PREFIXES or entry.finding_prefix in existing_prefixes:
      log("Duplicate/reserved prefix '{entry.finding_prefix}' — skipping")
      continue

    # 4. Resolve agent file existence
    if entry.source == "local":
      if not exists(".claude/agents/{entry.agent}.md"):
        log("Agent '{entry.agent}' not found in .claude/agents/ — skipping")
        continue
    elif entry.source == "global":
      if not exists("~/.claude/agents/{entry.agent}.md"):
        log("Agent '{entry.agent}' not found in ~/.claude/agents/ — skipping")
        continue

    # 5. Trigger matching against changed_files (or all_files for audit)
    if entry.trigger.always:
      # Always-on: bypass file matching, use all changed files up to context_budget
      matching_files = changed_files[:entry.context_budget]
    else:
      matching_files = []
      for each file in changed_files:
        ext_match = file.extension in entry.trigger.extensions OR entry.trigger.extensions == ["*"]
        path_match = entry.trigger.paths is empty OR file starts with any entry.trigger.paths entry
        if ext_match AND path_match:
          matching_files.add(file)

    if entry.trigger.always OR len(matching_files) >= (entry.trigger.min_files ?? 1):
      ash_selections.add(entry.name)
      custom_agent_ashes.add({
        name: entry.name,
        agent: entry.agent,
        source: entry.source,
        finding_prefix: entry.finding_prefix,
        context_budget: entry.context_budget,
        matching_files: matching_files[:entry.context_budget],
        required_sections: entry.required_sections,
        trigger_always: entry.trigger.always ?? false  # For trim priority ordering
      })
    else:
      # Skip silently (same as conditional built-in Ash)

  # 6. Enforce max_ashes cap (built-in + CLI + MCP-discovered + agent-backed custom)
  # Trim priority (lowest priority trimmed first):
  #   1. MCP-discovered registry/user agents
  #   2. Trigger-matched custom agents (trigger.always == false)
  #   3. trigger.always custom agents (last to trim — user explicitly wants these)
  total_ashes = len(ash_selections)
  max_ashes = 9  # v3.x: settings.max_ashes baked
  trimmed_agents = []  # Track all trimmed agents for inscription

  if total_ashes > max_ashes:
    log("Too many Ashes ({total_ashes}). Max: {max_ashes}. Trimming entries.")

    # Tier 1: Trim MCP-discovered registry/user agents first (lowest priority)
    mcp_agent_names = list(registry_agent_details.keys()) if registry_agent_details else []
    while len(ash_selections) > max_ashes and mcp_agent_names:
      removed = mcp_agent_names.pop()
      ash_selections.remove(removed)
      registry_agent_details.pop(removed, None)
      trimmed_agents.add({ name: removed, reason: "MCP-discovered (lowest priority)", tier: 1 })
      warn("Trimmed MCP-discovered Ash '{removed}' — over max_ashes limit ({max_ashes})")

    # Tier 2+3: Trim custom_agent_ashes if still over cap
    # Sort: trigger-matched (always=false) first, then trigger.always last
    custom_agent_ashes.sort(key=lambda a: 1 if a.trigger_always else 0)
    while len(ash_selections) > max_ashes and custom_agent_ashes:
      removed = custom_agent_ashes.pop(0)  # Pop from front (lowest priority first)
      ash_selections.remove(removed.name)
      if removed.trigger_always:
        trimmed_agents.add({ name: removed.name, reason: "trigger.always (last resort — hard limit reached)", tier: 3 })
        warn("Trimmed trigger.always Ash '{removed.name}' — max_ashes hard limit ({max_ashes}) exceeded. Consider increasing settings.max_ashes in talisman.yml")
      else:
        trimmed_agents.add({ name: removed.name, reason: "trigger-matched custom (mid priority)", tier: 2 })
        warn("Trimmed custom Ash '{removed.name}' — over max_ashes limit ({max_ashes})")

    # Summary warning with actionable suggestion
    if len(trimmed_agents) > 0:
      warn("{len(trimmed_agents)} Ash(es) trimmed to meet max_ashes={max_ashes}. To keep all agents, set settings.max_ashes: {total_ashes} in talisman.yml")

  # 7. Store custom ash context for Phase 3 summoning
  inscription.custom_agent_ashes = custom_agent_ashes
  inscription.trimmed_agents = trimmed_agents  # Record which agents were dropped and why
```

**`DOC_LINE_THRESHOLD`**: 10 (hardcoded in v3.x).

## Extension Groups

### Backend Extensions

```
.py, .go, .rs, .rb, .java, .kt, .scala, .cs, .php, .ex, .exs, .erl, .hs, .ml
```

### Frontend Extensions

```
.ts, .tsx, .js, .jsx, .vue, .svelte, .astro
```

### Infrastructure Extensions

```
# Container / orchestration
Dockerfile, docker-compose.yml, docker-compose.yaml
.dockerfile

# IaC
.tf, .hcl, .tfvars

# CI/CD (matched by path, see INFRA_FILENAMES)
.github/workflows/*.yml, .gitlab-ci.yml, Jenkinsfile

# Scripts
.sh, .bash, .zsh

# Database
.sql
```

**`INFRA_FILENAMES`** (matched by exact filename, not extension):
```
Dockerfile, Makefile, Procfile, Vagrantfile, Rakefile, Taskfile.yml
docker-compose.yml, docker-compose.yaml
```

### Config Extensions

```
.yml, .yaml, .json, .toml, .ini, .cfg, .conf, .env.example, .env.template
```

**Exclusion**: Files already matched by SKIP_EXTENSIONS (e.g., `package-lock.json`) are excluded before CONFIG_EXTENSIONS is checked. Also, `.json` files under `node_modules/` or `vendor/` are skipped.

**Overlap note**: A file like `docker-compose.yml` matches both INFRA_FILENAMES and CONFIG_EXTENSIONS. Both branches add to `infra_files` → `forge-warden`. This is harmless (set dedup) — the file is reviewed once, not twice.

### Documentation Extensions

```
.md, .mdx, .rst, .txt, .adoc
```

### Skip Extensions (Never Review)

```
# Binary / generated
.png, .jpg, .jpeg, .gif, .svg, .ico, .woff, .woff2, .ttf, .eot
.pdf, .zip, .tar, .gz

# Lock files
package-lock.json, yarn.lock, bun.lockb, Cargo.lock, poetry.lock, uv.lock
Gemfile.lock, pnpm-lock.yaml, go.sum, composer.lock

# Build output (generated files — hand-written .d.ts may need review, use skip_patterns to customize)
.min.js, .min.css, .map, .d.ts

# Secrets (should never be reviewed — may contain credentials)
.env

# Config (usually boilerplate)
.gitignore, .editorconfig, .prettierrc, .eslintrc
```

## Ash Selection Matrix

<!-- NOTE: This hardcoded selection is the BASELINE. MCP-First Discovery (below) adds registry/user agents. -->

|--------------|:------------:|:-------------:|:--------------:|:------------:|:------------:|:-----------:|:------------:|
| Only backend | Selected | **Always** | **Always** | **Always** | - | - | **CLI-gated** |
| Only frontend | - | **Always** | **Always** | **Always** | Selected | - | **CLI-gated** |
| Only docs (>= threshold) | - | **Always** | **Always** | **Always** | - | Selected | **CLI-gated** |
| Only docs (< threshold, promoted) | - | **Always** | **Always** | **Always** | - | Selected | **CLI-gated** |
| Only infra/scripts | Selected | **Always** | **Always** | **Always** | - | - | **CLI-gated** |
| Only config | Selected | **Always** | **Always** | **Always** | - | - | **CLI-gated** |
| Only `.claude/` files | - | **Always** | **Always** | **Always** | - | Selected | **CLI-gated** |
| Backend + frontend | Selected | **Always** | **Always** | **Always** | Selected | - | **CLI-gated** |
| Backend + docs | Selected | **Always** | **Always** | **Always** | - | Selected | **CLI-gated** |
| Infra + docs | Selected | **Always** | **Always** | **Always** | - | Selected | **CLI-gated** |
| All types | Selected | **Always** | **Always** | **Always** | Selected | Selected | **CLI-gated** |

**Note:** The "Only `.claude/` files" row assumes `.claude/**/*.md`. Non-md files in `.claude/` follow standard classification rules and may also select Forge Warden via CONFIG_EXTENSIONS.

**External CLI-backed Ashes (v1.57.0+):** Custom Ashes with `cli:` field are detected via `detectAllCLIAshes()`. Each validated CLI-backed Ash is added to `ash_selections`. Subject to `max_cli_ashes` sub-partition (2) within `max_ashes`.

**Max built-in Ash:** 7. With custom Ashes, total can reach 9 (`settings.max_ashes` baked to 9 in v3.x). CLI-backed Ashes are capped at `max_cli_ashes` (2) within that total. Plus 1 Runebinder (utility) for aggregation.

## Defaults (Hardcoded in v3.x)

The extension groups, skip patterns, and `always_review` list are now hardcoded in this skill — they are no longer overridable per-project. To customise them, fork this skill.

## Special File Handling

### Critical Files (Always Review)

Some files should always be reviewed regardless of extension:
- `CLAUDE.md` — Agent instructions (security-sensitive)
- `.claude/**/*.md` — Agent/skill definitions (security-sensitive). Gets dual classification: Documentation (Knowledge Keeper) + Security (Ward Sentinel). The `.claude/` path escalation in the algorithm ensures both Ashes see these files, since they define `allowed-tools` security boundaries, Truthbinding prompts, and orchestration logic.
- `Dockerfile`, `docker-compose.yml` — Infrastructure (now classified via INFRA_EXTENSIONS/INFRA_FILENAMES → Forge Warden)
- CI/CD configs (`.github/workflows/`, `.gitlab-ci.yml`) — Infrastructure (now classified via INFRA_FILENAMES)

Ward Sentinel (always-on) reviews all critical files for security. Forge Warden reviews infrastructure files for correctness.

### Critical Deletions

Files that were deleted should be flagged:
- Deletion of test files → Pattern Weaver alert
- Deletion of security configs → Ward Sentinel alert
- Deletion of any `.claude/` file → Ward Sentinel + Pattern Weaver alert

## Line Count Threshold for Docs

The `>= DOC_LINE_THRESHOLD` (default: 10 lines) threshold for Knowledge Keeper prevents summoning a full doc reviewer for trivial edits (typo fixes, whitespace).

**Exception**: Docs-only diffs bypass threshold — all doc files are promoted when no code files exist.

Calculate with:
```bash
git diff --stat main..HEAD -- "*.md" | grep -E "\d+ insertion|\d+ deletion"
```
