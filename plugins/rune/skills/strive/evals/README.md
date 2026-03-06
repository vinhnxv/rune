# Strive Skill Eval Tests

This directory contains evaluation tests for the `/rune:strive` multi-agent work execution skill.

## Overview

The strive skill orchestrates Agent Teams to execute implementation plans. These evals test:

1. **Basic Execution** - Plan parsing, team creation, worker spawning, cleanup
2. **Dependency Handling** - Tasks with `blockedBy` relationships
3. **Ambiguity Detection** - Clarification flow for vague plans
4. **File Conflict Resolution** - Serialization of tasks touching same files
5. **Branch Safety** - Warning when committing to main/master
6. **Auto-detection** - Finding recent plans when no path specified
7. **Worktree Mode** - `--worktree` flag for isolated parallel execution
8. **Quality Gates** - Ward execution after implementation
9. **Proposal Approval** - `--approve` flag for per-task approval flow
10. **Error Recovery** - Cleanup on worker crash

## Running the Evals

### Prerequisites

- Claude Code CLI installed
- Agent Teams enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- This plugin loaded in your project

### Using skill-creator

```bash
# Run all evals with skill
claude -p "Use skill-creator to evaluate plugins/rune/skills/strive"

# Run specific eval
claude -p "Use skill-creator to evaluate plugins/rune/skills/strive --eval-id 1"
```

### Manual Execution

1. Copy test plan files to your project's `plans/` directory:
   ```bash
   cp plugins/rune/skills/strive/evals/files/*.md plans/
   ```

2. Run each eval manually:
   ```bash
   # Eval 1: Basic execution
   /rune:strive plans/test-simple-feature-plan.md

   # Eval 2: Dependencies
   /rune:strive plans/test-dependent-tasks-plan.md

   # Eval 3: Ambiguity
   /rune:strive plans/test-ambiguous-plan.md

   # Eval 4: File conflicts
   /rune:strive plans/test-conflict-plan.md

   # Eval 5: Branch safety (run on main branch)
   git checkout main
   /rune:strive plans/test-simple-feature-plan.md

   # Eval 6: Auto-detect
   /rune:strive

   # Eval 7: Worktree mode
   /rune:strive plans/test-isolated-work-plan.md --worktree

   # Eval 8: Quality gates
   /rune:strive plans/test-quality-gates-plan.md

   # Eval 9: Proposal approval
   /rune:strive plans/test-proposal-plan.md --approve

   # Eval 10: Error recovery
   /rune:strive plans/test-cleanup-on-error-plan.md
   ```

## Test Plan Descriptions

| Eval ID | Plan File | Tests |
|---------|-----------|-------|
| 1 | `test-simple-feature-plan.md` | Basic plan execution with 3 tasks |
| 2 | `test-dependent-tasks-plan.md` | Task dependencies via `Depends on` field |
| 3 | `test-ambiguous-plan.md` | Vague plan triggers clarification flow |
| 4 | `test-conflict-plan.md` | Three tasks modifying same file |
| 5 | `test-simple-feature-plan.md` | Branch safety warning on main |
| 6 | (none) | Auto-detect plans in directory |
| 7 | `test-isolated-work-plan.md` | Worktree mode with `--worktree` flag |
| 8 | `test-quality-gates-plan.md` | Quality gate execution |
| 9 | `test-proposal-plan.md` | Proposal approval with `--approve` flag |
| 10 | `test-cleanup-on-error-plan.md` | Cleanup on error handling |

## Expected Behaviors

### Eval 1: Basic Execution
- TeamCreate with `strive-` prefix
- 3 tasks parsed from plan
- Workers spawned (rune-smith, trial-forger)
- TeamDelete on completion
- Completion report generated

### Eval 2: Dependencies
- Tasks 2, 3, 4 have `blockedBy` relationships
- Sequential execution order
- Task 4 can potentially run in parallel with Task 2

### Eval 3: Ambiguity
- Ambiguous descriptions detected in Phase 0
- AskUserQuestion for clarification
- No workers spawned until resolved

### Eval 4: File Conflicts
- All 3 tasks target `src/api/users.py`
- Tasks serialized via `blockedBy`
- `inscription.json` reflects ownership

### Eval 5: Branch Safety
- Warning about main branch
- Offer to create feature branch
- User choice respected

### Eval 6: Auto-detect
- Plans directory scanned
- Most recent or list presented
- User selection required

### Eval 7: Worktree Mode
- `--worktree` flag detected
- `git-worktree` skill loaded
- Merge broker instead of commit broker
- Workers in isolated worktrees

### Eval 8: Quality Gates
- Wards discovered from project manifest
- All wards executed
- Failures trigger fix tasks

### Eval 9: Proposal Approval
- Workers write proposals
- AskUserQuestion presents options
- Implementation waits for approval

### Eval 10: Error Recovery
- Graceful error handling
- TeamDelete in finally block
- Partial progress reported

## Adding New Evals

1. Add test plan file to `evals/files/`
2. Add eval entry to `evals/evals.json`:
   ```json
   {
     "id": 11,
     "prompt": "/rune:strive plans/new-test-plan.md",
     "expected_output": "Description of expected behavior",
     "files": ["evals/files/new-test-plan.md"],
     "expectations": [
       "First expectation to verify",
       "Second expectation to verify"
     ]
   }
   ```
3. Update this README with the new eval description

## Eval Results

Results are stored in `strive-workspace/` directory:
- `iteration-1/` - First run
- `iteration-2/` - Second run (after improvements)
- `benchmark.json` - Aggregated metrics
- `benchmark.md` - Human-readable summary