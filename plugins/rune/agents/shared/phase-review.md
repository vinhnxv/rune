<!-- Source: Extracted from agents/review/ward-sentinel.md, agents/review/pattern-seer.md,
     agents/review/flaw-hunter.md, agents/utility/knowledge-keeper.md -->

# Phase Review — Shared Reference

Common patterns for all review-phase agents (Roundtable Circle Ashes).

## Review Agent Lifecycle

```
1. TaskList() → find available tasks
2. Claim task: TaskUpdate({ taskId, owner: "$CLAUDE_CODE_AGENT_NAME", status: "in_progress" })
3. Read changed files from inscription.json or task context
4. Review from ALL assigned perspectives simultaneously
5. Write findings to output_path
6. Mark complete: TaskUpdate({ taskId, status: "completed" })
7. Send Seal to team-lead
8. Check TaskList for more tasks → repeat or exit
```

## Read Ordering Strategy

1. Read agent/skill definition files FIRST (`.claude/` content — security-sensitive)
2. Read infrastructure files SECOND (configs, CI/CD, deployment)
3. Read source code THIRD
4. After every 5 files, re-check: Am I following evidence rules?

## Interaction Types (Q/N Taxonomy)

In addition to severity levels (P1/P2/P3), each finding may carry an
**interaction type** that signals how the author should engage with it.
Interaction types are orthogonal to severity.

### Question (Q)

Use `interaction="question"` when:
- You cannot determine if code is correct without understanding the author's intent
- A pattern diverges from the codebase norm but MAY be intentional
- An architectural choice seems unusual but you lack context to judge

**Question findings MUST include:**
- **Question:** The specific clarification needed
- **Context:** Why you are asking (evidence of divergence)
- **Fallback:** What you will assume if no answer is provided

### Nit (N)

Use `interaction="nit"` when:
- The issue is purely cosmetic (naming preference, whitespace, import order)
- A project linter or formatter SHOULD catch this
- The code works correctly but COULD be marginally more readable

**Nit findings MUST include:**
- **Nit:** The cosmetic observation
- **Author's call:** Why this is discretionary (no functional impact)

### Default: Assertion

When you have evidence the code is incorrect, insecure, or violates a project
convention, use a standard P1/P2/P3 finding WITHOUT an interaction attribute.

**Disambiguation rule:** If the issue could indicate a functional bug, use Q.
Only use N when confident the issue is purely cosmetic.

## Output Structure

All review agents write markdown with this common structure:

```markdown
# {Agent Name} — {Review Type}

**Branch:** {branch}
**Date:** {timestamp}

## P1 (Critical)
[findings with evidence...]

## P2 (High)
[findings...]

## P3 (Medium)
[findings...]

## Questions
[Q-type findings...]

## Nits
[N-type findings...]

## Unverified Observations
{Items where evidence could not be confirmed}

## Reviewer Assumptions
{Key assumptions that could affect finding accuracy}

## Self-Review Log
- Files reviewed: {count}
- P1 findings re-verified: {yes/no}
- Evidence coverage: {verified}/{total}
- Confidence breakdown: {PROVEN}/{LIKELY}/{UNCERTAIN}

## Summary
- P1: {count} | P2: {count} | P3: {count} | Q: {count} | N: {count}
- Evidence coverage: {verified}/{total}
```

## Diff Scope Awareness

When `diff_scope` data is present in inscription.json, limit review to files
listed in the diff scope. Do not review files outside the diff scope unless
they are direct dependencies of changed files.

## Quality Gates (Self-Review Before Seal)

After writing findings, perform ONE revision pass:

1. Re-read your output file
2. For each P1: verify evidence is concrete and actionable
3. Weak evidence → revise, downgrade, or delete
4. Self-calibration check: >50% UNCERTAIN → re-read sources

This is ONE pass. Do not iterate further.

## Seal Format

```
DONE
file: {output_path}
findings: {N} ({P1} P1, {P2} P2, {P3} P3, {Q} Q, {Nit} N)
evidence-verified: {V}/{N}
self-reviewed: yes
inner-flame: {pass|fail|partial}
revised: {count}
confidence: {PROVEN}/{LIKELY}/{UNCERTAIN}
summary: {1-sentence}
```

## Exit Conditions

- No tasks available: wait 30s, retry 3x, then exit
- Shutdown request: respond with `shutdown_response({ approve: true })`

## Agent-Specific Content (NOT in this shared file)

- Per-agent review perspectives and checklists
- Agent-specific finding categories and prefixes
- Hypothesis protocol (flaw-hunter)
- Pre-Flight checklist (pattern-seer)
- Security-specific OWASP mapping (ward-sentinel)
