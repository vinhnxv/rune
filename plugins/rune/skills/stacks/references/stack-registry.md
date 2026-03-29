# Stack Registry

Complete registry of supported languages, frameworks, databases, libraries, and patterns. Used by `detectStack()` and `computeContextManifest()` for evidence-based stack detection.

## Languages

| Language | Manifest Files | Config Files | Lock Files | Extensions |
|----------|---------------|--------------|------------|------------|
| Python | `pyproject.toml`, `setup.py`, `requirements.txt`, `Pipfile` | `mypy.ini`, `pyrightconfig.json`, `.flake8` | `poetry.lock`, `Pipfile.lock` | `.py`, `.pyi` |
| TypeScript | `package.json`, `tsconfig.json` | `.eslintrc.*`, `biome.json` | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml` | `.ts`, `.tsx`, `.js`, `.jsx` |
| Rust | `Cargo.toml` | `rustfmt.toml`, `clippy.toml`, `.cargo/config.toml` | `Cargo.lock` | `.rs` |
| PHP | `composer.json` | `phpstan.neon`, `psalm.xml`, `.php-cs-fixer.php` | `composer.lock` | `.php` |

## Frameworks

| Framework | Language | Detection Signal | Knowledge Skill | Prompt Template |
|-----------|----------|-----------------|-----------------|-----------------|
| FastAPI | Python | `fastapi` in deps | `frameworks/fastapi.md` | `specialist-prompts/fastapi-reviewer.md` (FAPI) |
| Django | Python | `django` in deps | `frameworks/django.md` | `specialist-prompts/django-reviewer.md` (DJG) |
| Flask | Python | `flask` in deps | (none — covered by python profile) | (none) |
| SQLAlchemy | Python | `sqlalchemy` in deps | `frameworks/sqlalchemy.md` | `specialist-prompts/sqlalchemy-reviewer.md` (SQLA) |
| Next.js | TypeScript | `next` in deps | `frameworks/nextjs.md` | (none — future) |
| React | TypeScript | `react` in deps | `frameworks/react.md` | (none — future) |
| Vue.js | TypeScript | `vue` in deps | `frameworks/vuejs.md` | (none — future) |
| Vite | TypeScript | `vite` in deps/tooling | `frameworks/vite.md` | (none — future) |
| Express | TypeScript | `express` in deps | (none — covered by typescript profile) | (none) |
| NestJS | TypeScript | `nestjs` or `@nestjs` in deps | (none — covered by typescript profile) | (none) |
| Actix-web | Rust | `actix` in deps | (none — covered by rust profile) | (none) |
| Axum | Rust | `axum` or `axum-extra` in deps (tower, sqlx corroborate) | `frameworks/axum.md` | `specialist-prompts/axum-reviewer.md` (AXUM) |
| Rocket | Rust | `rocket` in deps | (none — covered by rust profile) | (none) |
| Laravel | PHP | `laravel` in deps | `frameworks/laravel.md` | `specialist-prompts/laravel-reviewer.md` (LARV) |
| Symfony | PHP | `symfony` in deps | (none — covered by php profile) | (none) |

## Databases

| Database | Detection Signal | Knowledge Skill |
|----------|-----------------|-----------------|
| PostgreSQL | `psycopg`, `asyncpg`, `pg` in deps | `databases/postgres.md` |
| MySQL | `mysqlclient`, `aiomysql`, `mysql2` in deps | `databases/mysql.md` |
| Prisma | `prisma` in deps | (ORM, not DB — covered by typescript profile) |
| Diesel | `diesel` in deps | (ORM — covered by rust profile) |
| SQLx | `sqlx` in deps | (covered by rust profile) |
| Doctrine | `doctrine` in deps | (covered by php profile) |

## Libraries

| Library | Language | Detection Signal | Knowledge Skill |
|---------|----------|-----------------|-----------------|
| Pydantic | Python | `pydantic` in deps | `libraries/pydantic.md` |
| dry-python/returns | Python | `"returns"` or `dry-python` in deps | `libraries/returns.md` |
| Dishka | Python | `dishka` in deps | `libraries/dishka.md` |
| dependency-injector | Python | `dependency-injector` in deps | (covered by di pattern) |
| Zod | TypeScript | `zod` in deps | (covered by typescript profile) |
| Pinia | TypeScript | `pinia` in deps | (covered by vuejs framework) |
| Vue Router | TypeScript | `vue-router` in deps | (covered by vuejs framework) |
| Nuxt | TypeScript | `nuxt` in deps | (covered by vuejs framework) |
| tsyringe | TypeScript | `tsyringe` in deps | (covered by di pattern) |
| inversify | TypeScript | `inversify` in deps | (covered by di pattern) |
| Serde | Rust | `serde` in deps | (covered by rust profile) |
| Tokio | Rust | `tokio` in deps | (covered by rust profile) |
| thiserror | Rust | `thiserror` in deps | (covered by rust profile) |
| anyhow | Rust | `anyhow` in deps | (covered by rust profile) |

## Cross-Cutting Patterns

| Pattern | Trigger Condition | Knowledge Skill | Prompt Template |
|---------|------------------|-----------------|-----------------|
| TDD | Test files present in changed files | `patterns/tdd.md` | `specialist-prompts/tdd-compliance-reviewer.md` (TDD) |
| DDD | `domain/`, `src/domain/`, `entities/`, `bounded_contexts/`, `app/Domain/`, `src/Domain/` directory exists | `patterns/ddd.md` | `specialist-prompts/ddd-reviewer.md` (DDD) |
| DI | `dishka`, `dependency-injector`, `tsyringe`, `inversify`, or `php-di` in detected libraries | `patterns/di.md` | `specialist-prompts/di-reviewer.md` (DI) |

## Design Tools

| Tool | Detection Signal | Knowledge Skill | Agent |
|------|-----------------|-----------------|-------|
| Figma | `.figmarc`, `figma.config.json`, `@figma/` in deps | `design/figma.md` | `design-implementation-reviewer` (FIDE) |
| Design System | `tailwind.config.*`, `class-variance-authority` in deps, `@radix-ui/*` in deps, `components/ui/` with shadcn-style files (2+ signals) | `design/design-system.md` | `design-system-compliance-reviewer` (DSYS) |
| Storybook | `.storybook/` dir, `storybook` or `@storybook/` in deps | `design/storybook.md` | (covered by frontend-design-patterns skill) |

## Finding Prefixes

All specialist agents produce findings with unique prefixes to enable dedup:

| Prefix | Agent | Category |
|--------|-------|----------|
| PY | python-reviewer | Language |
| TSR | typescript-reviewer | Language |
| RST | rust-reviewer | Language |
| AXUM | axum-reviewer | Framework |
| PHP | php-reviewer | Language |
| FAPI | fastapi-reviewer | Framework |
| DJG | django-reviewer | Framework |
| LARV | laravel-reviewer | Framework |
| SQLA | sqlalchemy-reviewer | Framework |
| REACT | (future) react-reviewer | Framework |
| VUE | (future) vuejs-reviewer | Framework |
| NEXT | (future) nextjs-reviewer | Framework |
| VTE | (future) vite-reviewer | Framework |
| TDD | tdd-compliance-reviewer | Pattern |
| DDD | ddd-reviewer | Pattern |
| DI | di-reviewer | Pattern |
| FIDE | design-implementation-reviewer | Design |
| DSYS | design-system-compliance-reviewer | Design |

**Dedup hierarchy position**: Stack specialist prefixes are positioned BELOW the core Roundtable Circle prefixes:

```
SEC > BACK > VEIL > DOUBT > FLOW > DOC > QUAL > FRONT > FIDE > DSYS > CDX > PY > TSR > RST > AXUM > PHP > FAPI > DJG > LARV > SQLA > REACT > VUE > NEXT > VTE > TDD > DDD > DI
```

When a stack specialist and a core Ash find the same issue, the core Ash's finding takes priority.

## Skill-to-Prompt Mapping

> Stack specialists are prompt templates loaded by `buildAshPrompt()`, not registered agents.
> Values are specialist slug names used by `buildAshPrompt()` dispatch (not file paths).
> Design reviewers are full registered agents loaded via `computeContextManifest()` Step 5 — not listed here.

```
SKILL_TO_PROMPT_MAP = {
  "languages/python":      "python-reviewer",
  "languages/typescript":   "typescript-reviewer",
  "languages/rust":         "rust-reviewer",
  "languages/php":          "php-reviewer",
  "frameworks/axum":        "axum-reviewer",
  "frameworks/fastapi":     "fastapi-reviewer",
  "frameworks/django":      "django-reviewer",
  "frameworks/laravel":     "laravel-reviewer",
  "frameworks/sqlalchemy":  "sqlalchemy-reviewer",
  "patterns/tdd":           "tdd-compliance-reviewer",
  "patterns/ddd":           "ddd-reviewer",
  "patterns/di":            "di-reviewer",
}
```
