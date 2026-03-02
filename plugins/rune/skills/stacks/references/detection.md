# Stack Detection Engine

Deterministic tech stack detection from project manifest files. Zero LLM cost.

## detectStack(repoRoot)

```
detectStack(repoRoot):
  evidence = {}

  # Step 1: Scan manifest files (deterministic, fast)
  manifests = {
    "pyproject.toml":   detectPythonStack,
    "setup.py":         detectPythonStack,
    "requirements.txt": detectPythonStack,
    "Pipfile":          detectPythonStack,
    "package.json":     detectTypeScriptStack,
    "tsconfig.json":    detectTypeScriptStack,
    "Cargo.toml":       detectRustStack,
    "composer.json":    detectPHPStack,
  }

  # Step 1b: Scan design tool config files
  design_manifests = {
    ".figmarc":          detectDesignTools,
    "figma.config.json": detectDesignTools,
  }

  for manifest, detector in design_manifests:
    if exists(repoRoot + "/" + manifest):
      result = detector(Read(manifest))
      evidence[manifest] = result

  # Step 1c: Check for design tool directories
  if exists(repoRoot + "/.storybook/"):
    evidence[".storybook/"] = { language: null, frameworks: ["storybook"], databases: [], libraries: [], tooling: [] }

  # SECURITY: Raw manifest content is untrusted input.
  # Only propagate the structured result object downstream — never raw content strings.
  for manifest, detector in manifests:
    if exists(repoRoot + "/" + manifest):
      result = detector(Read(manifest))
      evidence[manifest] = result

  # Step 2: Merge evidence → primary stack
  stack = {
    primary_language: null,
    languages: [],
    frameworks: [],
    databases: [],
    libraries: [],
    tooling: [],
    confidence: 0.0,
    evidence_files: [],
    design_system: null,    # Populated by Step 5 when frontend stack detected (see design-system-discovery skill)
  }

  # Merge all evidence results
  for file, result in evidence:
    stack.evidence_files.push(file)
    if result.language AND result.language not in stack.languages:
      stack.languages.push(result.language)
    stack.frameworks = dedupe(stack.frameworks + result.frameworks)
    stack.databases = dedupe(stack.databases + result.databases)
    stack.libraries = dedupe(stack.libraries + result.libraries)
    stack.tooling = dedupe(stack.tooling + result.tooling)

  # Step 3: Determine primary language (by evidence count)
  lang_counts = count occurrences of each language across evidence
  stack.primary_language = language with highest count
  # Tie-break: pyproject.toml > package.json > Cargo.toml > composer.json

  # Step 4: Confidence scoring
  # Multiple evidence sources → higher confidence
  evidence_count = len(stack.evidence_files)
  has_lock_file = exists("poetry.lock") OR exists("package-lock.json")
    OR exists("Cargo.lock") OR exists("composer.lock")
  has_config = exists("mypy.ini") OR exists("tsconfig.json")
    OR exists("rustfmt.toml") OR exists("phpstan.neon")

  if evidence_count >= 2 AND (has_lock_file OR has_config):
    stack.confidence = 0.95
  elif evidence_count >= 2:
    stack.confidence = 0.85
  elif evidence_count == 1 AND has_lock_file:
    stack.confidence = 0.8
  elif evidence_count == 1:
    stack.confidence = 0.7
  else:
    # Extension-only heuristic (no manifest found)
    stack.confidence = 0.4

  # Step 5: Design system sub-pipeline
  # Runs after framework detection so stack.languages and stack.frameworks are populated.
  # Sequential (not parallel) — shares evidence_files with parent stack for unified provenance.
  # Gated by talisman.devise.design_system_discovery.enabled (default: true).
  is_frontend = (
    stack.languages intersects ["typescript", "javascript"]
    AND stack.frameworks intersects ["react", "nextjs", "vuejs", "nuxt", "vite"]
  )

  if is_frontend:
    talisman = readTalismanSection("devise")
    dsd_enabled = talisman?.design_system_discovery?.enabled ?? true

    if dsd_enabled:
      # discoverDesignSystem() is a sub-pipeline defined in design-system-discovery skill.
      # It runs Tier 0 → Tier 1 → Tier 2 scanning internally and early-exits when confident.
      ds_profile = discoverDesignSystem(repoRoot)

      # Merge evidence files from design system scan into parent stack provenance
      for f in ds_profile.evidence_files:
        if f not in stack.evidence_files:
          stack.evidence_files.push(f)

      # Store the full profile on the returned stack for downstream consumers
      # (context-router, strive Phase 1.5, arc Phase 2.8)
      stack.design_system = ds_profile

      # Elevate confidence if design system was conclusively identified
      # (high-confidence design system detection is strong evidence of a real TS/JS frontend)
      if ds_profile.confidence >= 0.90 AND stack.confidence < 0.95:
        stack.confidence = 0.95
    else:
      # Discovery disabled — leave stack.design_system unset
      stack.design_system = null
  else:
    # Non-frontend stack — skip discovery entirely
    stack.design_system = null

  return stack
```

## Language Detectors

### detectPythonStack(content)

```
detectPythonStack(content):
  result = { language: "python", frameworks: [], databases: [], libraries: [], tooling: [] }

  # Framework detection
  if contains(content, "fastapi"):     result.frameworks.push("fastapi")
  if contains(content, "django"):      result.frameworks.push("django")
  if contains(content, "flask"):       result.frameworks.push("flask")

  # Database detection
  if contains(content, "sqlalchemy"):  result.frameworks.push("sqlalchemy")
  if contains(content, "psycopg") OR contains(content, "asyncpg"):
    result.databases.push("postgresql")
  if contains(content, "mysqlclient") OR contains(content, "aiomysql"):
    result.databases.push("mysql")

  # Library detection
  if contains(content, "pydantic"):    result.libraries.push("pydantic")
  if contains(content, '"returns"') OR contains(content, "dry-python"):
    result.libraries.push("returns")
  if contains(content, "dishka"):      result.libraries.push("dishka")
  if contains(content, "dependency-injector"):
    result.libraries.push("dependency-injector")

  # Tooling detection
  if contains(content, "pytest"):      result.tooling.push("pytest")
  if contains(content, "mypy"):        result.tooling.push("mypy")
  if contains(content, "ruff"):        result.tooling.push("ruff")
  if contains(content, "black"):       result.tooling.push("black")

  return result
```

### detectTypeScriptStack(content)

```
detectTypeScriptStack(content):
  result = { language: "typescript", frameworks: [], databases: [], libraries: [], tooling: [] }

  # Framework detection
  if contains(content, "next"):        result.frameworks.push("nextjs")
  if contains(content, "react"):       result.frameworks.push("react")
  if contains(content, "vue"):         result.frameworks.push("vuejs")
  if contains(content, "nuxt"):        result.frameworks.push("nuxt")
  if contains(content, "express"):     result.frameworks.push("express")
  if contains(content, "nestjs") OR contains(content, "@nestjs"):
    result.frameworks.push("nestjs")

  # Database detection
  if contains(content, "prisma"):      result.databases.push("prisma")
  if contains(content, "typeorm"):     result.databases.push("typeorm")
  if contains(content, "drizzle"):     result.databases.push("drizzle")

  # Design tool detection (from package.json deps)
  if contains(content, "@figma") OR contains(content, "figma-api"):
    result.frameworks.push("figma")
  if contains(content, "storybook") OR contains(content, "@storybook"):
    result.frameworks.push("storybook")

  # Library detection
  if contains(content, "zod"):         result.libraries.push("zod")
  if contains(content, "pinia"):       result.libraries.push("pinia")
  if contains(content, "vue-router"):  result.libraries.push("vue-router")
  if contains(content, "tsyringe"):    result.libraries.push("tsyringe")
  if contains(content, "inversify"):   result.libraries.push("inversify")

  # Tooling detection
  if contains(content, "vite") OR contains(content, "@vitejs"):
    result.tooling.push("vite")
  if contains(content, "vitest"):      result.tooling.push("vitest")
  if contains(content, "jest"):        result.tooling.push("jest")
  if contains(content, "eslint"):      result.tooling.push("eslint")
  if contains(content, "prettier"):    result.tooling.push("prettier")
  if contains(content, "biome"):       result.tooling.push("biome")

  return result
```

### detectRustStack(content)

```
detectRustStack(content):
  result = { language: "rust", frameworks: [], databases: [], libraries: [], tooling: [] }

  # Framework detection
  if contains(content, "actix"):       result.frameworks.push("actix-web")
  if contains(content, "axum"):        result.frameworks.push("axum")
  if contains(content, "rocket"):      result.frameworks.push("rocket")

  # Database detection
  if contains(content, "diesel"):      result.databases.push("diesel")
  if contains(content, "sqlx"):        result.databases.push("sqlx")
  if contains(content, "sea-orm"):     result.databases.push("sea-orm")

  # Library detection
  if contains(content, "serde"):       result.libraries.push("serde")
  if contains(content, "tokio"):       result.libraries.push("tokio")
  if contains(content, "thiserror"):   result.libraries.push("thiserror")
  if contains(content, "anyhow"):      result.libraries.push("anyhow")

  # Tooling detection
  if contains(content, "clippy"):      result.tooling.push("clippy")
  if contains(content, "rustfmt"):     result.tooling.push("rustfmt")

  return result
```

### detectPHPStack(content)

```
detectPHPStack(content):
  result = { language: "php", frameworks: [], databases: [], libraries: [], tooling: [] }

  # Framework detection
  if contains(content, "laravel"):     result.frameworks.push("laravel")
  if contains(content, "symfony"):     result.frameworks.push("symfony")

  # Database detection
  if contains(content, "doctrine"):    result.databases.push("doctrine")
  # Laravel uses Eloquent (bundled)

  # Library detection
  if contains(content, "php-di"):      result.libraries.push("php-di")

  # Tooling detection
  if contains(content, "phpunit"):     result.tooling.push("phpunit")
  if contains(content, "phpstan"):     result.tooling.push("phpstan")
  if contains(content, "psalm"):       result.tooling.push("psalm")

  return result
```

### detectDesignTools(content)

```
detectDesignTools(content):
  result = { language: null, frameworks: [], databases: [], libraries: [], tooling: [] }

  # Figma detection
  if contains(content, "figma") OR contains(content, "@figma"):
    result.frameworks.push("figma")

  # Storybook detection (from package.json deps)
  if contains(content, "storybook") OR contains(content, "@storybook"):
    result.frameworks.push("storybook")

  return result
```

**Note**: Design tools are language-agnostic (`language: null`). They do not set a primary language. Detection also runs against `package.json` via `detectTypeScriptStack` for `@storybook/*` and `@figma/*` dependencies.

## Design Stack Detection

Design tools are detected through multiple signal types beyond manifest files. Unlike language stacks, design tools are **language-agnostic** and populate `detected_stack.frameworks` (not `tooling`).

### Figma Detection Signals

| Signal | Source | Detection Method |
|--------|--------|-----------------|
| Config files | `.figmarc`, `figma.config.js` | `detectDesignTools()` manifest scan |
| Dependencies | `@figma/*`, `figma-api` in `package.json` | `detectTypeScriptStack()` |
| Env vars | `FIGMA_TOKEN`, `FIGMA_ACCESS_TOKEN` | Environment check (pre-detection) |
| MCP tools | `figma_fetch_design`, `figma_inspect_node` | MCP tool availability probe |

When any signal is positive, `"figma"` is added to `detected_stack.frameworks`.

### Storybook Detection Signals

| Signal | Source | Detection Method |
|--------|--------|-----------------|
| Config dir | `.storybook/main.js`, `.storybook/main.ts` | Directory existence scan (Step 1c) |
| Dependencies | `@storybook/react`, `@storybook/vue3` | `detectTypeScriptStack()` |
| Story files | `*.stories.tsx`, `*.stories.jsx` | Heuristic (not in primary scan) |

When any signal is positive, `"storybook"` is added to `detected_stack.frameworks`.

### Design Detection Integration

Design detection merges into the main `detectStack()` flow at four points:
1. **Step 1b** — Standalone design config files (`.figmarc`, `figma.config.json`)
2. **Step 1c** — Design tool directories (`.storybook/`)
3. **Within `detectTypeScriptStack`** — `@figma/*` and `@storybook/*` dependencies in `package.json`
4. **Step 5** — `discoverDesignSystem()` sub-pipeline for component library, token system, and variant framework detection (frontend stacks only)

All design signals land in `frameworks` — not `tooling`. This ensures Rune Gaze Phase 1A correctly routes to `design-implementation-reviewer` via framework matching.

Step 5 runs **after** Steps 1–4 so that `stack.languages` and `stack.frameworks` are populated before the frontend gate check (`is_frontend`). The sub-pipeline is sequential — it uses `Read()` calls internally (no Bash), and merges its `evidence_files` list back into the parent stack for unified provenance.

**Output field**: `detectedStack.design_system` — a `design-system-profile.yaml` object. Null when:
- Stack is not frontend (no react/nextjs/vuejs/nuxt/vite framework)
- `talisman.devise.design_system_discovery.enabled` is `false`
- `discoverDesignSystem()` runs but returns `confidence: 0.0` (no signals found)

**Downstream consumers** of `detectedStack.design_system`:
- `computeContextManifest()` — loads design-system-discovery skill when profile is present
- `strive` Phase 1.5 — injects component constraints into worker prompts
- `arc` Phase 2.8 — validates implementation against detected token/variant system

See [design/figma.md](design/figma.md) and [design/storybook.md](design/storybook.md) for full knowledge files.
See [design-system-discovery skill](../../design-system-discovery/SKILL.md) for the full `discoverDesignSystem()` algorithm.

## Helper Functions

### has_ddd_structure(repoRoot)

```
has_ddd_structure(repoRoot):
  # Check for DDD directory conventions
  ddd_dirs = ["domain/", "src/domain/", "entities/", "bounded_contexts/",
              "app/Domain/", "src/Domain/"]
  for dir in ddd_dirs:
    if exists(repoRoot + "/" + dir):
      return true
  return false
```

### has_di_framework(detected_stack)

```
has_di_framework(detected_stack):
  di_libs = ["dishka", "dependency-injector", "tsyringe", "inversify", "php-di"]
  return detected_stack.libraries intersects di_libs
```

### prioritize(specialist_selections, max_stack_ashes)

```
prioritize(specialist_selections, max_stack_ashes):
  # Ordering: language > framework > pattern specialists
  priority_order = [
    # Language specialists (max 1)
    "python-reviewer", "typescript-reviewer", "rust-reviewer", "php-reviewer",
    # Framework specialists (max 2)
    "fastapi-reviewer", "django-reviewer", "laravel-reviewer", "sqlalchemy-reviewer",
    # Pattern specialists (conditional)
    "tdd-compliance-reviewer", "ddd-reviewer", "di-reviewer",
    # Design specialists (conditional on talisman.design_sync.enabled)
    "design-implementation-reviewer"
  ]

  sorted = []
  for agent in priority_order:
    if agent in specialist_selections:
      sorted.push(agent)

  return sorted[:max_stack_ashes]
```

## Talisman Override

When `talisman.stack_awareness.override` is set, skip detection and use the override values directly with confidence = 1.0:

```
VALID_LANGUAGES = ["python", "typescript", "rust", "php"]
VALID_FRAMEWORKS = ["fastapi", "django", "flask", "laravel", "symfony", "sqlalchemy",
                    "nextjs", "react", "vuejs", "nuxt", "express", "nestjs",
                    "actix-web", "axum", "rocket",
                    "figma", "storybook"]

if talisman?.stack_awareness?.override:
  override = talisman.stack_awareness.override

  # SEC-003: Validate override values against known enumerations
  if override.primary_language NOT IN VALID_LANGUAGES:
    log warning: "Invalid override.primary_language '" + override.primary_language + "' — ignoring override"
    # Fall through to normal detection

  if override.frameworks:
    override.frameworks = filter(override.frameworks, fw => fw IN VALID_FRAMEWORKS)

  return {
    primary_language: override.primary_language,
    languages: [override.primary_language],
    frameworks: override.frameworks ?? [],
    databases: override.databases ?? [],
    libraries: override.libraries ?? [],
    tooling: [],
    confidence: 1.0,
    evidence_files: ["talisman.yml (override)"]
  }
```
