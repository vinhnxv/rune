# Rune Gaze — Scope Selection

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
# matches a file in specialist-prompts/, it loads from there; otherwise ash-prompts/.
# No hardcoded specialist list exists here — detection drives selection.

stack = detectStack(repoRoot)
confidence_threshold = talisman.stack_awareness.confidence_threshold ?? 0.6
max_stack_ashes = talisman.stack_awareness.max_stack_ashes ?? 3

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

  # 4. Design Fidelity Gate (conditional on talisman + frontend + VSM)
  hasFrontend = any(file.ext in [".tsx", ".jsx", ".css", ".scss", ".vue", ".svelte"] for file in changed_files)
  hasVSM = exists("tmp/arc/*/vsm/") OR exists("tmp/design/")
  if talisman.design_sync?.enabled AND hasFrontend:
    if "figma" in stack.frameworks OR hasVSM:
      specialist_selections.add("design-implementation-reviewer")
      # Write design context to inscription
      inscription.design_context = {
        enabled: true,
        vsm_dir: find_vsm_dir() ?? null,
        dcd_dir: find_dcd_dir() ?? null,
        figma_url: talisman.design_sync?.figma_url ?? null,
        fidelity_threshold: talisman.design_sync?.fidelity_threshold ?? 0.8,
        components: parse_vsm_components() ?? [],
        token_system: detect_token_system() ?? null
      }

  # 4.5. Design System Compliance Gate (conditional on frontend + design system detection)
  # Triggered by: frontend files (.tsx, .jsx, .css, .scss) AND design system confidence >= 0.5
  # Keywords: design system, tokens, CVA, cn(), tailwind, component patterns
  # Separate from design-implementation-reviewer (FIDE): DSYS validates codebase conventions;
  # FIDE validates Figma-to-code fidelity. Both can be active simultaneously without overlap.
  ds_confidence = stack.design_system?.confidence ?? 0
  ds_disabled = talisman.stack_awareness?.design_compliance == false
  if hasFrontend AND NOT ds_disabled AND ds_confidence >= 0.5:
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
# Gate: readTalismanSection("misc").schema_drift?.enabled !== false
schema_drift_disabled = readTalismanSection("misc").schema_drift?.enabled === false
if NOT schema_drift_disabled:
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

# Always-on Ash (regardless of file types)
# NOTE: pattern-weaver (always-on quality Ash) is distinct from pattern-seer
# (cross-cutting consistency specialist, triggered by file patterns in review)
ash_selections.add("ward-sentinel")   # Security: always
ash_selections.add("pattern-weaver")  # Quality: always
ash_selections.add("veil-piercer")    # Truth: always

# CLI-gated Ash (always-on when available, conditional on CLI, not file type)
# Check talisman first (user may have disabled)
if talisman.codex.disabled is not true:
  if Bash("command -v \"codex\" >/dev/null 2>&1 && echo 'yes' || echo 'no'") == "yes":
    ash_selections.add("codex-oracle")  # Cross-model: when codex CLI available

# External model CLI-backed Ashes (multi-model adversarial review, v1.57.0+)
# Iterate ashes.custom[] entries where cli: is present (discriminated union — see custom-ashes.md).
# Uses detectAllCLIAshes() from codex-detection.md which:
#   1. Applies max_cli_ashes limit BEFORE detection (default: 2)
#   2. Runs detectExternalModel(config) for each candidate
#   3. Returns validated entries only
# Codex Oracle is separately gated above — NOT counted toward max_cli_ashes.
cli_ashes = detectAllCLIAshes(talisman, current_workflow)
for each cli_ash in cli_ashes:
  ash_selections.add(cli_ash.name)

# Agent-backed custom Ashes (from talisman.yml ashes.custom[], v1.17.0+)
# Iterate ashes.custom[] entries where cli: is NOT present (agent-backed — see custom-ashes.md).
# Discovery MUST happen here (Phase 1) so custom Ashes are included in selectedAsh
# BEFORE Phase 2 (TeamCreate + TaskCreate). Spawning happens in Phase 3 (ash-summoning.md).
current_workflow = "review"  # or "audit" depending on calling skill
custom_agent_ashes = []
if talisman.ashes?.custom:
  for each entry in talisman.ashes.custom:
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
    matching_files = []
    for each file in changed_files:
      ext_match = file.extension in entry.trigger.extensions OR entry.trigger.extensions == ["*"]
      path_match = entry.trigger.paths is empty OR file starts with any entry.trigger.paths entry
      if ext_match AND path_match:
        matching_files.add(file)

    if len(matching_files) >= (entry.trigger.min_files ?? 1):
      ash_selections.add(entry.name)
      custom_agent_ashes.add({
        name: entry.name,
        agent: entry.agent,
        source: entry.source,
        finding_prefix: entry.finding_prefix,
        context_budget: entry.context_budget,
        matching_files: matching_files[:entry.context_budget],
        required_sections: entry.required_sections
      })
    else:
      # Skip silently (same as conditional built-in Ash)

  # 6. Enforce max_ashes cap (built-in + CLI + agent-backed custom)
  total_ashes = len(ash_selections)
  max_ashes = talisman.settings?.max_ashes ?? 9
  if total_ashes > max_ashes:
    log("Too many Ashes ({total_ashes}). Max: {max_ashes}. Trimming custom entries.")
    # Trim custom_agent_ashes from the end until within cap
    while len(ash_selections) > max_ashes and custom_agent_ashes:
      removed = custom_agent_ashes.pop()
      ash_selections.remove(removed.name)

  # 7. Store custom ash context for Phase 3 summoning
  inscription.custom_agent_ashes = custom_agent_ashes
```

**`DOC_LINE_THRESHOLD`**: Default 10. Configurable via `talisman.yml` → `rune-gaze.doc_line_threshold`.

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

| Changed Files | Forge Warden | Ward Sentinel | Pattern Weaver | Veil Piercer | Glyph Scribe | Knowledge Keeper | Codex Oracle |
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

**Note:** The "Only `.claude/` files" row assumes `.claude/**/*.md`. Non-md files in `.claude/` (e.g., `.claude/talisman.yml`) follow standard classification rules and may also select Forge Warden via CONFIG_EXTENSIONS.

**CLI-gated:** Codex Oracle is selected when `codex` CLI is available (`command -v codex` returns 0) AND `talisman.codex.disabled` is not true. It reviews all file types from a cross-model perspective.

**External CLI-backed Ashes (v1.57.0+):** Custom Ashes with `cli:` field are detected via `detectAllCLIAshes()`. Each validated CLI-backed Ash is added to `ash_selections`. Subject to `max_cli_ashes` sub-partition (default: 2) within `max_ashes`. Codex Oracle is separately gated and NOT counted toward `max_cli_ashes`.

**Max built-in Ash:** 7. With custom Ashes (via `talisman.yml`), total can reach 9 (`settings.max_ashes`). CLI-backed Ashes are capped at `max_cli_ashes` (default: 2) within that total. Plus 1 Runebinder (utility) for aggregation.

## Configurable Overrides

Projects can override the default extension groups via `.claude/talisman.yml`:

```yaml
# .claude/talisman.yml (optional)
rune-gaze:
  backend_extensions:
    - .py
    - .go
  frontend_extensions:
    - .tsx
    - .ts
  infra_extensions:
    - .tf
    - .sh
    - .sql
  config_extensions:
    - .yml
    - .yaml
    - .json
    - .toml
  doc_line_threshold: 10        # Min lines changed to summon Knowledge Keeper (default: 10)
  skip_patterns:
    - "**/*.generated.ts"
    - "**/migrations/**"
  always_review:
    - "CLAUDE.md"
    - ".claude/**/*.md"
```

If no config file exists, use the defaults above.

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
