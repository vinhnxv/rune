# Remembrance Schema — Human-Facing Knowledge Documents

Remembrance is the human-readable knowledge channel that lives alongside Rune Echoes. While Echoes are agent-internal memory (`.rune/echoes/`), Remembrance documents are version-controlled solutions in `docs/solutions/` designed for human consumption.

## Directory Structure

```
docs/solutions/
  build-errors/
  test-failures/
  runtime-errors/
  configuration/
  performance/
  security/
  architecture/
  tooling/
```

## Categories

| Category | Directory | Description |
|----------|-----------|-------------|
| `build-errors` | `docs/solutions/build-errors/` | Build, compile, and dependency resolution |
| `test-failures` | `docs/solutions/test-failures/` | Test setup, flaky tests, assertion patterns |
| `runtime-errors` | `docs/solutions/runtime-errors/` | Production/development runtime issues |
| `configuration` | `docs/solutions/configuration/` | Config files, environment, deployment |
| `performance` | `docs/solutions/performance/` | Query optimization, caching, scaling |
| `security` | `docs/solutions/security/` | Auth, OWASP, secrets, permissions |
| `architecture` | `docs/solutions/architecture/` | Design patterns, refactoring, migrations |
| `tooling` | `docs/solutions/tooling/` | IDE, CLI, CI/CD, dev workflow |

## Document Schema (YAML Frontmatter)

```yaml
---
title: "Descriptive title of the problem and solution"
category: architecture  # one of the 8 categories above
tags: [n-plus-one, eager-loading, activerecord]
date: 2026-02-12
symptom: "User list endpoint takes 5+ seconds"
root_cause: "N+1 query pattern in user.posts association"
solution_summary: "Added includes(:posts) to User.list scope"
echo_ref: ".rune/echoes/reviewer/MEMORY.md#etched-004@sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"  # cross-ref with SHA-256 content hash (64 hex chars)
confidence: high  # high | medium
verified_by: human  # human | agent — REQUIRED for security category
requires_human_approval: false  # true for security category promotions
---
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Descriptive title (problem + solution) |
| `category` | enum | One of the 8 categories |
| `tags` | string[] | Searchable tags for discovery |
| `date` | date | Creation date |
| `symptom` | string | Observable problem (what the user sees) |
| `root_cause` | string | Underlying cause |
| `solution_summary` | string | Brief solution description |
| `confidence` | enum | `high` or `medium` |
| `verified_by` | enum | `human` or `agent` |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `echo_ref` | string | Cross-reference to source echo with content hash |
| `requires_human_approval` | bool | Gate for security promotions |
| `affected_files` | string[] | Files involved in the fix |
| `superseded_by` | string | Path to newer solution that replaces this one |
| `related_echoes` | string[] | Links to related echo entries |

## Echo Cross-Reference Format

The `echo_ref` field cross-references version-controlled Remembrance to non-version-controlled echoes using a content hash for integrity:

```
echo_ref: ".rune/echoes/reviewer/MEMORY.md#etched-004@sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
```

Format: `{echo_path}#{entry_id}@sha256:{hash}`

The promotion process MUST compute and store the SHA-256 hash. Consumers MUST validate the hash before trusting referenced echo content. If hash mismatch is detected, flag the cross-reference as stale.

## Promotion Rules

An ETCHED echo becomes a Remembrance document when ALL conditions are met:

1. Contains a clear problem-solution pair (`symptom` + `root_cause` + `solution_summary`)
2. Has been validated (`confidence: high` OR referenced by 2+ sessions)
3. Is actionable for humans (not agent-internal optimization)
4. **Security category gate**: Require `verified_by: human` before promotion. Enforcement: agents promoting security echoes use `AskUserQuestion` to obtain explicit human confirmation before setting `verified_by: human`. Do not set this field autonomously.

### Promotion Flow

```
ETCHED Echo (agent memory)
  │
  ├─ Has problem-solution pair? ──── No → Skip
  │   Yes ↓
  ├─ Confidence high OR 2+ refs? ── No → Skip
  │   Yes ↓
  ├─ Human-actionable? ──────────── No → Skip
  │   Yes ↓
  ├─ Category = security?
  │   ├─ Yes → Requires verified_by: human ── Not verified → BLOCKED
  │   └─ No  → Proceed
  │   ↓
  └─ Write to docs/solutions/{category}/{slug}.md
```

## Document Body Template

```markdown
---
{YAML frontmatter}
---

# {title}

## Symptom

{What the user or agent observed}

## Root Cause

{Why this happened — with evidence}

## Solution

{Step-by-step fix}

## Prevention

{How to avoid this in the future}

## References

- Echo source: {echo_ref}
- Related: {links to related docs or issues}
```

## Deduplication

When promoting, check for existing Remembrance documents:

1. **Exact title match** → Update existing instead of creating new
2. **Root cause similarity** → Link as `related_echoes` if different solutions
3. **Tag overlap (3+ tags)** → Flag for manual review before creating

## Invalidation

When a Remembrance document becomes outdated:

1. Set `superseded_by: "docs/solutions/{category}/{new-doc}.md"`
2. Add a notice at the top: `> Superseded by [{new title}]({path})`
3. Do NOT delete — old solutions may still be referenced
