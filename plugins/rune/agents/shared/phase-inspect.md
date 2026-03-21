<!-- Source: Extracted from agents/investigation/grace-warden-inspect.md,
     agents/investigation/sight-oracle-inspect.md -->

# Phase Inspect — Shared Reference

Common patterns for inspect-mode agents (plan-vs-implementation assessment).

## Inspect Agent Lifecycle

```
1. TaskList() → find available tasks
2. Claim task: TaskUpdate({ taskId, owner, status: "in_progress" })
3. Read the plan file from task context
4. For EACH assigned requirement, assess against codebase
5. Write findings to output_path
6. Mark complete: TaskUpdate({ taskId, status: "completed" })
7. Send Seal to team-lead
```

## Inspector Ashes

Four Inspector Ashes assess implementation from different dimensions:

| Inspector | Dimensions | Finding Prefix |
|-----------|-----------|----------------|
| grace-warden-inspect | Correctness, Completeness | GRACE, WIRE |
| sight-oracle-inspect | Architecture, Performance | SIGHT |
| ruin-prophet-inspect | Failure Modes, Security | RUIN |
| vigil-keeper-inspect | Observability, Maintainability | VIGIL |

## Assessment Criteria (grace-warden)

For each requirement, determine status:

| Status | When to Assign | Score |
|--------|---------------|-------|
| COMPLETE | Code exists, matches plan intent, correct behavior | 100% |
| PARTIAL | Some code exists — specify what's done vs missing | 25-75% |
| MISSING | No evidence found after thorough search | 0% |
| DEVIATED | Code works but differs from plan | 50% |

### Sub-Classifications

Each status has sub-types with adjusted scores:

- **COMPLETE**: COMPLETE_VERIFIED (100), COMPLETE_EXCEEDS (100)
- **DEVIATED**: DEVIATED_INTENTIONAL (100), DEVIATED_SUPERSEDED (100), DEVIATED_DRIFT (50)
- **PARTIAL**: PARTIAL_IN_PROGRESS (25-75), PARTIAL_BLOCKED (75), PARTIAL_DEFERRED (90)
- **MISSING**: MISSING_NOT_STARTED (0), MISSING_EXCLUDED (100), MISSING_PLAN_INACCURATE (100)

**Default rule**: When evidence is insufficient, assign the worst sub-type.

## Architecture & Performance (sight-oracle)

Four perspectives assessed simultaneously:

1. **Architectural Alignment** — layers, modules, dependency direction
2. **Coupling Analysis** — circular deps, interface surface, god objects
3. **Performance Profile** — N+1 queries, missing indexes, blocking I/O
4. **Design Pattern Compliance** — planned patterns implemented correctly

## Dimension Scores

Each inspector provides scores on its dimensions (X/10 with justification):

```markdown
## Dimension Scores

### {Dimension Name}: {X}/10
{Justification with evidence}
```

## Wiring Map Verification (Conditional)

If the plan contains `## Integration & Wiring Map`, grace-warden verifies:

- **Entry Points**: New code targets exist, existing files modified
- **Existing File Modifications**: Files in git diff, expected patterns found
- **Registration & Discovery**: Described patterns found in codebase
- **Layer Traversal**: Modified/new files exist per table

Findings use `WIRE-NNN` prefix. Skip entirely if plan has no wiring section.

## Quality Gates

After writing findings, ONE revision pass:

1. Re-read output file
2. For MISSING: did you search at least 3 ways? (Grep, Glob, Read nearby)
3. For COMPLETE: is the file:line reference real?
4. Self-calibration: if >80% MISSING, re-verify search strategy

## Seal Formats

**grace-warden:**
```
DONE
file: {output_path}
requirements: {N} ({complete} complete, {partial} partial, {missing} missing)
completion: {N}%
findings: {N} ({P1} P1, {P2} P2)
```

**sight-oracle:**
```
DONE
file: {output_path}
findings: {N} ({P1} P1, {P2} P2)
architecture: aligned|drifted|diverged
performance: optimized|adequate|concerning
```

## Agent-Specific Content (NOT in this shared file)

- Full sub-classification protocol with 3-step checks (grace-warden)
- Classification output contract details (grace-warden)
- FLAW-001 truthbinding exemption for comment reading (grace-warden)
- Specific performance anti-patterns checklist (sight-oracle)
- Coupling detection algorithms (sight-oracle)
- Gap analysis table format (sight-oracle)
