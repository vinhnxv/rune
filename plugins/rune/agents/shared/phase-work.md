<!-- Source: Extracted from agents/work/rune-smith.md, agents/work/trial-forger.md -->

# Phase Work — Shared Reference

Common patterns for all work-phase agents (swarm workers).

## Swarm Worker Lifecycle

```
1. TaskList() → find unblocked, unowned tasks
2. Claim task: TaskUpdate({ taskId, owner: "$CLAUDE_CODE_AGENT_NAME", status: "in_progress" })
3. Read task file: Read(`tmp/work/{timestamp}/tasks/task-{id}.md`)
   - Parse YAML frontmatter for metadata (risk_tier, proof_count)
   - Read ## Source for full task description
   - Read ## Acceptance Criteria for verification contract
   - Read ## File Targets for scope
4. Update task file status: status: IN_PROGRESS, assigned_to: "$CLAUDE_CODE_AGENT_NAME"
5. Echo-Back (COMPREHENSION): Before writing code/tests, echo each acceptance
   criterion in your own words. Write to task file ## Worker Report → ### Echo-Back.
   Ask via SendMessage if anything is unclear — do not guess.
6. Implement with appropriate cycle (TDD for code, discovery for tests)
7. Run Ward checks (quality gates)
8. Collect evidence per criterion
9. Write Worker Report to task file:
   - ### Critical Review Findings
   - ### Implementation Notes
   - ### Evidence (table with per-criterion results)
   - ### Code Changes (files modified with line counts)
   - ### Self-Review (Inner Flame output)
10. Update task file status: status: COMPLETED, completed_at: now
11. Mark complete: TaskUpdate({ taskId, status: "completed" })
12. SendMessage Seal to team-lead
13. TaskList() → claim next unblocked task or exit
```

## Ward Check (Quality Gates)

Before marking a task complete, discover and run project quality gates:

```
1. Check Makefile: targets 'check', 'test', 'lint'
2. Check package.json: scripts 'test', 'lint', 'typecheck'
3. Check pyproject.toml: ruff, mypy, pytest configs
4. Fallback: skip wards with warning
5. Override: check .rune/talisman.yml for ward_commands
```

Run discovered gates. If any fail, fix the issues before marking complete.

## Implementation Rules (Common)

1. **Read before write**: Read the FULL target file before modifying
2. **Match patterns**: Follow existing naming, structure, and style conventions
3. **Small changes**: Prefer minimal, focused changes over sweeping refactors
4. **No new deps**: Do not add new dependencies without explicit task instruction
5. **Type annotations required**: All function signatures MUST have explicit types
6. **Documentation on ALL definitions**: Every function, class, method MUST have docs
7. **Maximum function length: 40 lines**: Split longer functions into helpers
8. **Plan pseudocode is guidance, not gospel**: Implement from contracts, not copy-paste

## Iron Law (VER-001)

> **NO COMPLETION CLAIMS WITHOUT VERIFICATION**
>
> This rule is absolute. No exceptions for "simple" changes, time pressure,
> or pragmatism arguments.

## Question Relay Protocol

Four message types for communicating with team-lead:

| Type | Blocks work? | Cap (SEC-006) |
|------|-------------|---------------|
| QUESTION | Yes | Counts toward 3-msg cap |
| CHALLENGE | Yes | Counts toward 3-msg cap |
| STUCK | Yes | Counts toward 3-msg cap |
| CONCERN | No | Exempt from cap |

On cap: stop sending blocking messages. Mark task pending, claim next task.

## Failure Escalation Protocol

| Attempt | Action |
|---------|--------|
| 1st-2nd | Retry with careful error analysis |
| 3rd | Load systematic-debugging skill |
| 4th | Continue if progress; escalate if stuck |
| 5th | Escalate to Tarnished with debug log |
| 7th | Create blocking task for human intervention |

## Seal Format

```
Seal: task #{id} done. Files: {changed_files}. Tests: {pass_count}/{total}.
Confidence: {0-100}. Inner-flame: {pass|fail|partial}. Revised: {count}.
```

## Exit Conditions

- No unblocked tasks: wait 30s, retry 3x, then send idle notification
- Shutdown request: approve immediately
- Task blocked: SendMessage to Tarnished explaining the blocker

## Agent-Specific Content (NOT in this shared file)

- TDD cycle details (rune-smith: RED/GREEN/REFACTOR)
- Test discovery and quality rules (trial-forger)
- Language-specific mandatory quality checks (Python/TypeScript/Rust)
- Codex inline advisory (rune-smith optional step 6.5)
- Worktree mode lifecycle (rune-smith)
- Pre-completion quality gate details (rune-smith)
- Test pattern matching and edge case generation (trial-forger)
