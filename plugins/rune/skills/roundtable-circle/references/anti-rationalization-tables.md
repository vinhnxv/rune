# Anti-Rationalization Tables

> Before dismissing a potential finding, check the table for your review category.
> If your reasoning matches any row, you are rationalizing — report the finding.

> **Note**: Agent names in parentheses indicate primary consumers. Agents in `agents/investigation/` and `agents/utility/` (e.g., breach-hunter, knowledge-keeper, vigil-keeper) are listed for reference but do NOT receive automatic injection via `buildAshPrompt()` — only `agents/review/` Ashes receive auto-injection at spawn time.

## Security (ward-sentinel, breach-hunter, supply-chain-sentinel)

| Rationalization | Why it's invalid | What to do instead |
|----------------|-------------------|---------------------|
| "The framework sanitizes this" | Verify the EXACT framework function and version. Many frameworks have known bypass patterns. | Read the sanitization code. Cite the specific function. |
| "This is behind authentication" | Authenticated users can still be attackers. IDOR, privilege escalation, session fixation all require auth. | Report it with the auth context as a factor, not a dismissal. |
| "The input is validated elsewhere" | Upstream validation may not cover all cases, may be bypassable, or may change. Defense in depth requires each layer to validate. | Trace the validation chain. If you can't find it, report the gap. |
| "This only affects the current user" | Self-XSS becomes real XSS via social engineering. Self-SSRF becomes real SSRF via redirect chains. | Report with reduced severity, not as a non-issue. |
| "This is an internal API" | Internal APIs get exposed. Network segmentation fails. Zero-trust means treating internal as untrusted. | Report it. Internal ≠ safe. |

## Logic & Correctness (flaw-hunter, doubt-seer, type-warden, forge-keeper, flow-integrity-tracer)

| Rationalization | Why it's invalid | What to do instead |
|----------------|-------------------|---------------------|
| "This edge case is unlikely" | Unlikely ≠ impossible. Edge cases compound. One-in-a-million events happen daily at scale. | Report it with severity proportional to impact, not probability. |
| "The caller always provides valid input" | Today's caller might. Tomorrow's caller won't. APIs should validate their own contracts. | Report the missing validation. |
| "This works for the test cases" | Test cases represent the happy path. The bug IS the untested path. | Ask: what input BREAKS this? Report that. |
| "It's just an off-by-one" | Off-by-one errors cause buffer overflows, fence-post bugs, and infinite loops. They are real bugs. | Report with the specific failure scenario. |
| "This was probably intentional" | Probably. But also probably not. Without a comment explaining the intention, report it. | Flag it with "POSSIBLE_INTENTION" and let the developer confirm. |

## Performance (ember-oracle, ux-interaction-auditor)

| Rationalization | Why it's invalid | What to do instead |
|----------------|-------------------|---------------------|
| "This is only called once" | Code paths change. Once-called functions get moved to loops. Initialization code runs per-request in serverless. | Report with context: "Currently single-call. Monitor if moved to hot path." |
| "The dataset is small" | Datasets grow. O(n²) on 100 items is fine. O(n²) on 100,000 items is a production incident. | Report with scaling projections. |
| "We can optimize later" | Premature optimization is bad. But known O(n²) in a hot path IS a bug, not an optimization opportunity. | Report it as a scalability finding, not a premature optimization concern. |
| "The database handles this" | The database is not magic. Missing indexes, N+1 queries, and full table scans happen regardless of DBMS. | Verify the query plan. Report missing indexes and N+1 patterns. |

## Architecture & Patterns (pattern-seer, rune-architect, wraith-finder, refactor-guardian, design-system-compliance-reviewer)

| Rationalization | Why it's invalid | What to do instead |
|----------------|-------------------|---------------------|
| "This is how the rest of the codebase does it" | Consistency with a bad pattern is still a bad pattern. | Report it as a PATTERN finding, not a single-file issue. |
| "Refactoring this would be too large" | The scope of the fix doesn't determine whether the finding is valid. Report the finding. Let humans scope the fix. | Report it. Note "fix requires broader refactor" in the finding. |
| "This abstraction will be cleaned up later" | Tech debt with no tracking is invisible. "Later" usually means "never." | Report it as a QUAL finding with "track as tech debt" suggestion. |
| "The interface is already used everywhere" | Widespread usage of a broken interface is a widespread problem, not a reason to accept it. | Report with blast radius estimation. |

## Documentation (knowledge-keeper, vigil-keeper)

| Rationalization | Why it's invalid | What to do instead |
|----------------|-------------------|---------------------|
| "The code is self-documenting" | Complex business logic, non-obvious error handling, and integration contracts are NEVER self-documenting. | Report missing docs for non-obvious behavior. |
| "The PR description explains this" | PR descriptions are ephemeral. Future maintainers won't read them. | Report inline documentation gaps. |
| "There's a README somewhere" | Outdated READMEs are worse than no README — they actively mislead. | Verify the README matches current behavior. |

## Maintenance Guide

To add a new category or update tables:
1. Add/edit the table section in this file
2. Add the category key to `categoryMap` in `references/orchestration-phases.md` (buildAshPrompt section)
3. Add the category to the valid list in `agents/meta-qa/prompt-linter.md` (AGT-016 rule)
4. Ensure at least one review agent has the new category in its frontmatter `categories:` field
