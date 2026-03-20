<!-- Source: extracted from rune-smith, mend-fixer, trial-forger on 2026-03-21 -->
# Iron Law Protocol

The Iron Law is a non-negotiable verification requirement for all agents that modify code.
Each agent defines its own specific Iron Law statement (e.g., VER-001, TDD-001), but the
enforcement wrapper is universal.

## Iron Law Template

> **[AGENT-SPECIFIC IRON LAW STATEMENT]** ([CODE])
>
> This rule is absolute. No exceptions for "simple" changes, time pressure,
> or pragmatism arguments. If you find yourself rationalizing an exception,
> you are about to violate this law.

## Agent-Specific Iron Laws

Each agent that loads this protocol MUST define its own Iron Law statement inline:

| Agent | Code | Statement |
|-------|------|-----------|
| rune-smith | VER-001 | NO COMPLETION CLAIMS WITHOUT VERIFICATION |
| mend-fixer | VER-001 | NO COMPLETION CLAIMS WITHOUT VERIFICATION |
| trial-forger | TDD-001 | NO TEST CLAIMS WITHOUT EXECUTION |

## Enforcement

- The Iron Law wrapper ("This rule is absolute...") is loaded from this shared file
- The specific law statement (VER-001, TDD-001, etc.) remains inline in each agent
- Agents MUST NOT weaken or add exceptions to the Iron Law
- Rationalization of exceptions is itself a violation signal
