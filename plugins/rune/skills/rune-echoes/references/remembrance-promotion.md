# Remembrance Channel + Promotion Rules

Remembrance is a parallel knowledge axis alongside Echoes. While Echoes are agent-internal memory (`.rune/echoes/`), Remembrance documents are version-controlled solutions in `docs/solutions/` designed for human consumption.

**Inputs**: ETCHED echo entries from `.rune/echoes/`
**Outputs**: Promoted documents in `docs/solutions/{category}/{slug}.md`
**Preconditions**: Echo entry meets all promotion criteria (problem-solution pair, confidence, actionability)

## Axis Comparison

| Axis | Audience | Storage | Versioned | Based On |
|------|----------|---------|-----------|----------|
| **Echoes** | Agents | `.rune/echoes/` | Optional | Confidence-based lifecycle |
| **Remembrance** | Humans | `docs/solutions/` | Always | Actionability-based promotion |

## Directory Structure

```
docs/solutions/
  build-errors/       # Build, compile, and dependency resolution
  test-failures/      # Test setup, flaky tests, assertion patterns
  runtime-errors/     # Production/development runtime issues
  configuration/      # Config files, environment, deployment
  performance/        # Query optimization, caching, scaling
  security/           # Auth, OWASP, secrets, permissions
  architecture/       # Design patterns, refactoring, migrations
  tooling/            # IDE, CLI, CI/CD, dev workflow
```

## Promotion Conditions

An ETCHED echo becomes a Remembrance document when ALL conditions are met:

1. Contains a clear problem-solution pair (`symptom` + `root_cause` + `solution_summary`)
2. Has been validated (`confidence: high` OR referenced by 2+ sessions)
3. Is actionable for humans (not agent-internal optimization)
4. **Security category**: Require `verified_by: human` before promotion. Agents promoting security echoes use `AskUserQuestion` to obtain explicit human confirmation. Do not set `verified_by: human` autonomously.

## Promotion Flow

```
ETCHED Echo (agent memory)
  |
  +-- Has problem-solution pair? ---- No --> Skip
  |   Yes v
  +-- Confidence high OR 2+ refs? -- No --> Skip
  |   Yes v
  +-- Human-actionable? ------------ No --> Skip
  |   Yes v
  +-- Category = security?
  |   +-- Yes --> Requires verified_by: human -- Not verified --> BLOCKED
  |   +-- No  --> Proceed
  |   v
  +-- Compute content hash (SHA-256) for echo_ref cross-reference
  |   v
  +-- Check for duplicates (title match, root_cause similarity, 3+ tag overlap)
  |   v
  +-- Write to docs/solutions/{category}/{slug}.md
```

## Decision Tree Summary

The promotion flow enforces a strict quality gate: only echoes with clear problem-solution pairs, high confidence or multi-session validation, and human actionability can be promoted. Security-category promotions require explicit human verification via `AskUserQuestion`.
