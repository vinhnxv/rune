# CREATION-LOG.md — resolve-todos skill

## Metadata

- **Skill name**: resolve-todos
- **Created**: 2026-03-05
- **Author**: Arc pipeline (arc-1772648384)
- **Plan**: plans/2026-03-04-feat-resolve-todos-skill-plan.md

## Purpose

Resolves file-based TODOs using Agent Teams with a verify-before-fix pipeline.
Each TODO is reviewed by a verifier agent before any fix is applied, preventing
hallucinated fixes from compound-engineering patterns.

## Design Decisions

### 1. Verify-Before-Fix Pattern

Unlike compound-engineering's `resolve_todo_parallel` which fixes immediately,
this skill adds a verification phase (Phase 3) where each TODO is classified
as VALID/FALSE_POSITIVE/ALREADY_FIXED/NEEDS_CLARIFICATION before any fixer
touches the code.

**Rationale**: AI-generated TODOs from reviews can be hallucinated. The verification
phase catches these before wasted effort.

### 2. Reuse mend-fixer Agent

Instead of creating a new `todo-fixer` agent, we reuse `mend-fixer` for Phase 4.
Both scenarios involve applying targeted fixes to files with quality gates.

**Rationale**: Reduces agent count, maintains consistency with mend workflow.

### 3. Custom todo-verifier Agent

Created a dedicated `todo-verifier` agent with staleness-specific checklist
rather than using bare `flaw-hunter`. Flaw-hunter's bug-detection checklist
would misroute toward null-dereference hunting rather than staleness classification.

### 4. 7-Verdict Taxonomy

Expanded from 4 verdicts to 7:
- VALID, FALSE_POSITIVE, ALREADY_FIXED, NEEDS_CLARIFICATION (original)
- PARTIAL (multi-part TODO only partially resolved)
- DUPLICATE (same file+line as another TODO)
- DEFERRED (valid but too risky to fix now)

### 5. SEC-RESOLVE-001 as Mandatory

The hook is registered unconditionally (like SEC-MEND-001 and SEC-STRIVE-001).
Fail-open design means zero cost in non-resolve-todos sessions.

## Files Created

| File | Purpose |
|------|---------|
| `skills/resolve-todos/SKILL.md` | Main skill orchestration |
| `skills/resolve-todos/references/discovery-algorithm.md` | Phase 0 implementation |
| `skills/resolve-todos/references/verify-protocol.md` | Phase 3 verifier prompts |
| `skills/resolve-todos/references/fixer-protocol.md` | Phase 4 fixer prompts |
| `skills/resolve-todos/references/quality-gate.md` | Phase 5 quality checks |
| `agents/utility/todo-verifier.md` | Custom verifier agent |
| `scripts/validate-resolve-fixer-paths.sh` | SEC-RESOLVE-001 hook |

## Dependencies

- **Skills**: file-todos, inner-flame, zsh-compat, rune-orchestration, polling-guard
- **Agents**: mend-fixer (reused), todo-verifier (new)
- **Hooks**: enforce-teams.sh, on-task-completed.sh, SEC-RESOLVE-001

## Review Concerns Addressed

From plan review (concern-context.md):

1. **Agent selection inconsistency**: Created dedicated `todo-verifier` agent
   (not bare flaw-hunter), reuse `mend-fixer` for fixes
2. **README.md/CHANGELOG.md updates**: Tracked in Task 11 equivalent
3. **Verdict taxonomy harmonized**: 7 verdicts with confidence thresholds

## Testing Notes

- Unit tests: Verify discovery algorithm handles empty/interrupted TODOs
- Integration tests: End-to-end resolve with mock TODO files
- Edge cases: EDGE-001 through EDGE-013 from plan

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-03-05 | Initial creation via arc pipeline |