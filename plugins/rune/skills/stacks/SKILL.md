---
name: stacks
description: |
  Stack-Aware Intelligence — auto-detects project tech stack (Python, TypeScript,
  Rust, PHP) from manifest files, routes context to domain-relevant skills, and
  selects specialist review agents. Covers detection, context routing, knowledge
  profiles, and enforcement agents. Trigger keywords: stack detection, context
  router, language profile, framework checklist, specialist agent, stack awareness.
user-invocable: false
disable-model-invocation: false
---

# Stack-Aware Intelligence System

Auto-detects project tech stack and loads domain-relevant context for reviews, audits, planning, and work.

## Architecture (4 Layers)

```
Layer 0: Context Router — computeContextManifest() decides WHAT to load
Layer 1: Detection Engine — detectStack() scans manifests for evidence
Layer 2: Knowledge Skills — 20 reference docs (languages, frameworks, databases, libraries, patterns)
Layer 3: Enforcement Agents — 13 specialist reviewers with unique finding prefixes
```

## How It Works

1. **Detection**: `detectStack()` scans manifest files (pyproject.toml, package.json, Cargo.toml, composer.json) to identify languages, frameworks, databases, and libraries with a confidence score (0.0-1.0).

2. **Routing**: `computeContextManifest()` classifies changed files into domains (backend, frontend, database, testing, infra, docs), then selects which reference docs and agents to load based on the detected stack and task type.

3. **Loading**: Selected reference docs are passed as `Read()` directives to workers and reviewers. Only domain-relevant docs are loaded (e.g., a frontend-only PR won't load Python/SQLAlchemy skills).

4. **Enforcement**: Specialist agents (python-reviewer, fastapi-reviewer, design-system-compliance-reviewer, etc.) are conditionally summoned when their stack is detected AND domain matches, producing findings with unique prefixes (PY-, FAPI-, etc.).

## Key Functions

### detectStack(repoRoot)

See [detection.md](references/detection.md) for the full algorithm.

**Input**: Repository root path
**Output**: `{ primary_language, languages[], frameworks[], databases[], libraries[], tooling[], confidence, evidence_files[] }`

### computeContextManifest(task_type, file_scope, detected_stack, task_description)

See [context-router.md](references/context-router.md) for the full algorithm.

**Input**: Workflow type (review/audit/plan/work/forge), changed files, detected stack, task description
**Output**: `{ domains, skills_to_load[], skills_excluded{}, agents_selected[], loading_strategy }`

## Supported Stacks

See [stack-registry.md](references/stack-registry.md) for all supported languages, frameworks, databases, and libraries.

| Category | Supported |
|----------|-----------|
| Languages | Python, TypeScript, Rust, PHP |
| Frameworks | FastAPI, Django, Laravel, SQLAlchemy, React, Vue.js, Next.js, Vite |
| Databases | PostgreSQL, MySQL |
| Libraries | Pydantic, dry-python/returns, Dishka, Pinia, Vue Router |
| Patterns | TDD, DDD, DI |

## Configuration

```yaml
# talisman.yml
stack_awareness:
  enabled: true                  # Master toggle (default: true)
  confidence_threshold: 0.5      # Min confidence to activate specialists
  max_stack_ashes: 3             # Max specialist Ashes per review

  # Override detected stack (monorepos, detection failures)
  # override:
  #   primary_language: python
  #   frameworks: [fastapi, sqlalchemy]

  # Custom project-specific rules
  # custom_rules:
  #   - path: ".claude/skills/my-patterns/SKILL.md"
  #     domains: [backend]
  #     workflows: [review, work]
  #     stacks: [python]
```

## References

- [detection.md](references/detection.md) — Stack detection algorithm
- [stack-registry.md](references/stack-registry.md) — Supported stacks registry
- [context-router.md](references/context-router.md) — Smart context loading algorithm
- [languages/](references/languages/) — Language profiles (Python, TypeScript, Rust, PHP)
- [frameworks/](references/frameworks/) — Framework checklists (FastAPI, Django, Laravel, SQLAlchemy, React, Vue.js, Next.js, Vite)
- [databases/](references/databases/) — Database patterns (PostgreSQL, MySQL)
- [libraries/](references/libraries/) — Library patterns (Pydantic, Returns, Dishka)
- [patterns/](references/patterns/) — Cross-cutting patterns (TDD, DDD, DI)
