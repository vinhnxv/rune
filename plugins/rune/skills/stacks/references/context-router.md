# Context Router

Smart context loading algorithm. Classifies changed files into domains, then selects which reference docs and agents to load based on the detected stack and task type.

## computeContextManifest(task_type, file_scope, detected_stack, task_description)

```
computeContextManifest(task_type, file_scope, detected_stack, task_description):
  # Define lang at the TOP of function scope (C-3 fix)
  lang = detected_stack?.primary_language ?? null

  manifest = {
    domains: {},
    skills_to_load: [],
    skills_excluded: {},
    agents_selected: [],
    loading_strategy: "domain-scoped",
  }

  # Step 1: Classify files into domains
  domains = { backend: false, frontend: false, database: false, testing: false, infra: false, docs: false, design: false, mobile: false }

  for file in file_scope:
    ext = file.extension
    path = file.path

    # Backend detection
    if ext in [".py", ".rs", ".go", ".rb", ".java", ".php"]:
      domains.backend = true
    elif ext in [".ts", ".tsx", ".js", ".jsx"]:
      # Could be backend (Node) or frontend — check path
      if path.includes("src/api/") OR path.includes("server/") OR path.includes("backend/"):
        domains.backend = true
      elif path.includes("src/components/") OR path.includes("pages/") OR path.includes("app/"):
        domains.frontend = true
      else:
        # Ambiguous — mark both
        domains.backend = true
        domains.frontend = true
    elif ext in [".css", ".scss", ".less", ".html", ".svelte", ".vue"]:
      domains.frontend = true

    # Database detection
    if ext == ".sql" OR path.includes("migrations/") OR path.includes("alembic/"):
      domains.database = true

    # Testing detection
    if path.includes("test") OR path.includes("spec") OR path.includes("__tests__"):
      domains.testing = true

    # Infra detection
    if ext in [".yml", ".yaml", ".tf", ".toml", ".ini", ".cfg"]:
      if path.includes("docker") OR path.includes("ci") OR path.includes(".github/"):
        domains.infra = true
    if file.name in ["Dockerfile", "docker-compose.yml", ".gitlab-ci.yml"]:
      domains.infra = true

    # Docs detection
    if ext == ".md" AND NOT path.includes("test"):
      domains.docs = true

    # Design detection
    if ext in [".figma", ".sketch"] OR path.includes(".storybook/"):
      domains.design = true
    elif ext in [".css", ".scss", ".less"] AND path.includes("design-tokens/"):
      domains.design = true
    elif file.name in [".figmarc", "figma.config.json"]:
      domains.design = true

    # Mobile detection
    if path.includes("/android/") OR path.includes("/ios/") OR path.includes("/native/") OR path.includes("/expo/"):
      domains.mobile = true
    elif ext in [".swift", ".kt", ".m", ".mm", ".java"] AND (path.includes("ios/") OR path.includes("android/")):
      domains.mobile = true

  # Design domain inference: if Figma/Storybook detected in stack, mark design domain
  if detected_stack?.frameworks:
    if "figma" in detected_stack.frameworks OR "storybook" in detected_stack.frameworks:
      domains.design = true

  manifest.domains = domains

  # Step 2: Select language profile
  if lang AND domains.backend:
    skill = "languages/" + lang
    manifest.skills_to_load.push(skill)
  elif lang:
    manifest.skills_excluded["languages/" + lang] = "No backend files in scope"

  # Step 3: Select framework skills
  if detected_stack?.frameworks:
    for fw in detected_stack.frameworks:
      skill_path = "frameworks/" + fw
      if fw in ["fastapi", "django", "flask"] AND domains.backend:
        manifest.skills_to_load.push(skill_path)
      elif fw in ["laravel", "symfony"] AND domains.backend:
        manifest.skills_to_load.push(skill_path)
      elif fw in ["sqlalchemy"] AND (domains.backend OR domains.database):
        manifest.skills_to_load.push(skill_path)
      elif fw in ["axum", "actix-web", "rocket"] AND domains.backend:
        manifest.skills_to_load.push(skill_path)
      elif fw in ["nextjs", "react", "express", "nestjs"]:
        if domains.frontend OR domains.backend:
          manifest.skills_to_load.push(skill_path)
        else:
          manifest.skills_excluded[skill_path] = "No matching domain files"
      elif fw in ["vuejs", "nuxt"]:
        if domains.frontend:
          manifest.skills_to_load.push(skill_path)
        else:
          manifest.skills_excluded[skill_path] = "No frontend files in scope"
      elif fw == "vite":
        # Vite is a build tool — load when frontend OR infra (build config) is in scope
        if domains.frontend OR domains.infra:
          manifest.skills_to_load.push(skill_path)
        else:
          manifest.skills_excluded[skill_path] = "No frontend/infra files in scope"
      else:
        manifest.skills_excluded[skill_path] = "Domain mismatch"

  # Step 3.5: Select build tool skills (from tooling[], not frameworks[])
  if detected_stack?.tooling:
    if "vite" in detected_stack.tooling AND "vite" not in detected_stack.frameworks:
      # Vite is detected as tooling — load its framework skill when frontend/infra in scope
      if domains.frontend OR domains.infra:
        manifest.skills_to_load.push("frameworks/vite")
      else:
        manifest.skills_excluded["frameworks/vite"] = "No frontend/infra files in scope"

  # Step 4: Select database skills
  if detected_stack?.databases AND (domains.database OR domains.backend):
    for db in detected_stack.databases:
      if db == "postgresql":
        manifest.skills_to_load.push("databases/postgres")
      elif db == "mysql":
        manifest.skills_to_load.push("databases/mysql")
  elif detected_stack?.databases:
    for db in detected_stack.databases:
      manifest.skills_excluded["databases/" + db] = "No database files in scope"

  # Step 5: Select library skills
  if detected_stack?.libraries AND domains.backend:
    for lib in detected_stack.libraries:
      if lib == "pydantic":
        manifest.skills_to_load.push("libraries/pydantic")
      elif lib == "returns":
        manifest.skills_to_load.push("libraries/returns")
      elif lib == "dishka":
        manifest.skills_to_load.push("libraries/dishka")

  # Step 5.5: Select pattern skills
  if domains.testing:
    manifest.skills_to_load.push("patterns/tdd")
  if has_ddd_structure(repoRoot):
    manifest.skills_to_load.push("patterns/ddd")
  if has_di_framework(detected_stack):
    manifest.skills_to_load.push("patterns/di")

  # Step 5.7: Select design skills
  if domains.design OR domains.frontend:
    manifest.skills_to_load.push("frontend-design-patterns")
    if detected_stack?.frameworks:
      if "figma" in detected_stack.frameworks:
        manifest.skills_to_load.push("design/figma")
      if "storybook" in detected_stack.frameworks:
        manifest.skills_to_load.push("design/storybook")
    # Conditionally load design-sync agent when talisman enables it
    if talisman?.design_sync?.enabled:
      manifest.agents_selected.push("design-implementation-reviewer")

    # Conditionally load design-system compliance reviewer
    # Triggered when: frontend detected AND design system confidence >= 0.5 AND not disabled
    ds_confidence = detected_stack.design_system?.confidence ?? 0
    ds_disabled = talisman?.stack_awareness?.design_compliance == false
    if NOT ds_disabled AND ds_confidence >= 0.5:
      manifest.agents_selected.push("design-system-compliance-reviewer")

  # Step 6: Select frontend knowledge skills (v2.36.0+)
  # These skills provide deep domain knowledge for React, web UI, and mobile development.

  if detected_stack?.frameworks:
    fw_names = [f for f in detected_stack.frameworks]

    # react-performance-rules: React/Next.js performance optimization
    if ("react" in fw_names OR "nextjs" in fw_names) AND (domains.frontend OR domains.backend):
      manifest.skills_to_load.push("react-performance-rules")
    elif "react" in fw_names OR "nextjs" in fw_names:
      manifest.skills_excluded["react-performance-rules"] = "No frontend/backend files in scope"

    # react-composition-patterns: compound components, React 19 APIs
    if ("react" in fw_names OR "nextjs" in fw_names):
      if domains.frontend:
        manifest.skills_to_load.push("react-composition-patterns")
      else:
        manifest.skills_excluded["react-composition-patterns"] = "No frontend files in scope"

    # react-view-transitions: View Transition API (React 19+ or explicit usage)
    lib_names = [l for l in (detected_stack?.libraries ?? [])]
    if "react-19" in lib_names AND domains.frontend:
      manifest.skills_to_load.push("react-view-transitions")
    elif domains.frontend:
      has_view_transitions = any(f for f in file_scope if "ViewTransition" in f.path OR "ViewTransition" in f.content_hint)
      if has_view_transitions:
        manifest.skills_to_load.push("react-view-transitions")

    # react-native-patterns: React Native / Expo best practices
    if "react-native" in fw_names OR "expo" in fw_names:
      if domains.frontend OR domains.mobile:
        manifest.skills_to_load.push("react-native-patterns")
      else:
        manifest.skills_excluded["react-native-patterns"] = "No frontend/mobile files in scope"

  # web-interface-rules: broad web UI quality rules (works for any frontend framework)
  if domains.frontend:
    manifest.skills_to_load.push("web-interface-rules")

  # Step 7: Load custom rules from talisman
  custom_rules = talisman?.stack_awareness?.custom_rules ?? []
  for rule in custom_rules:
    # SEC-001: Validate custom rule path against path traversal
    if NOT rule.path matches /^[a-zA-Z0-9_.\/\-]+$/ OR rule.path contains "..":
      log warning: "Skipping custom_rule with invalid path: " + rule.path
      manifest.skills_excluded[rule.path] = "Rejected: invalid path characters or traversal"
      continue

    rule_domains = rule.domains ?? ["all"]
    if "all" in rule_domains OR domains intersects rule_domains:
      rule_workflows = rule.workflows ?? ["all"]
      if "all" in rule_workflows OR task_type in rule_workflows:
        rule_stacks = rule.stacks ?? []
        if rule_stacks is empty
           OR detected_stack.primary_language in rule_stacks
           OR detected_stack.frameworks intersects rule_stacks:
          manifest.skills_to_load.push(rule.path)
        else:
          manifest.skills_excluded[rule.path] =
            "Stack filter: requires " + rule_stacks.join("/") +
            " but detected " + detected_stack.primary_language
      else:
        manifest.skills_excluded[rule.path] =
          "Workflow filter: requires " + rule_workflows.join("/") +
          " but current workflow is " + task_type
    else:
      manifest.skills_excluded[rule.path] =
        "Domain filter: requires " + rule_domains.join("/") +
        " but current domains are " + Object.keys(domains).filter(k => domains[k]).join("/")

  # Step 8: Select specialists from SKILL_TO_PROMPT_MAP
  # Note: Specialist names are prompt template identifiers (specialist-prompts/), not agent files.
  for skill in manifest.skills_to_load:
    agent = SKILL_TO_PROMPT_MAP[skill]  # Returns specialist name for buildAshPrompt() dispatch
    if agent:
      manifest.agents_selected.push(agent)

  # Step 9: Deduplicate
  manifest.skills_to_load = dedupe(manifest.skills_to_load)
  manifest.agents_selected = dedupe(manifest.agents_selected)

  return manifest
```

## Domain Classification Reference

| Domain | Extensions / Paths | Description |
|--------|-------------------|-------------|
| backend | `.py`, `.rs`, `.go`, `.rb`, `.java`, `.php`, `server/`, `backend/`, `src/api/` | Server-side code |
| frontend | `.css`, `.scss`, `.html`, `.svelte`, `.vue`, `src/components/`, `pages/`, `app/` | Client-side code |
| database | `.sql`, `migrations/`, `alembic/` | Database schemas and migrations |
| testing | `test`, `spec`, `__tests__` in path | Test files |
| infra | `Dockerfile`, CI configs, `.tf`, `.github/` | Infrastructure and deployment |
| docs | `.md` (excluding test dirs) | Documentation |
| design | `.figma`, `.sketch`, `.storybook/`, `design-tokens/`, `.figmarc`, `figma.config.json` | Design system files, tokens, and tool configs |

## Loading Strategies

| Strategy | Description | When Used |
|----------|-------------|-----------|
| `domain-scoped` | Load only skills matching active domains | Default for reviews and audits |
| `full-stack` | Load all detected stack skills | Planning and forge workflows |
| `minimal` | Load only language profile | Quick reviews, `--partial` mode |

## Per-Workflow Behavior

| Workflow | Strategy | Max Skills | Notes |
|----------|----------|------------|-------|
| review | domain-scoped | No limit | Only loads skills for changed file domains |
| audit | domain-scoped | No limit | Scope = full, so all domains typically active |
| plan | full-stack | No limit | Planning benefits from full context |
| work | domain-scoped | No limit | Workers get skills relevant to their files |
| forge | full-stack | No limit | Enrichment benefits from broad context |

## Inscription Integration

The context manifest is written to `inscription.json` immediately after `detected_stack`:

```json
{
  "detected_stack": { ... },
  "context_manifest": {
    "domains": { "backend": true, "frontend": false, "database": true },
    "skills_loaded": ["languages/python", "frameworks/fastapi", "databases/postgres"],
    "skills_excluded": { "languages/typescript": "No TypeScript files in scope" },
    "agents_selected": ["python-reviewer", "fastapi-reviewer"],  // specialist prompt names, not agent files
    "loading_strategy": "domain-scoped"
  }
}
```

This gives full transparency into WHY certain skills were loaded and others were not.
