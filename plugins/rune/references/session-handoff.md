# Session Handoff Template

Write to `tmp/scratch/session-state.md` before compaction or at session end.

## Session State

```markdown
- Workflow: {review|audit|plan|forge|work|mend|arc}
- Phase: {current phase number and name}
- Team: {team-name}
- Checkpoint: {path to checkpoint.json if arc}
- Active teammates: {list of teammate names still running}
- Completed artifacts: {list of output files already written}
- Files to read next: {specific files needed to resume}
- Files NOT to re-read: {completed research/review outputs}
- Open questions: {any unresolved decisions}
- Gap analysis: {summary of missing/partial items from Phase 5.5, if arc}
- Next action: {exact next step}

## Arc-specific fields (optional, for /rune:arc workflows):
- Convergence round: {current mend retry count, e.g., 0/2}
- Flags: {--approve, --no-forge, etc.}
- Phase sequence position: {index in PHASE_ORDER array, e.g., 5/10}
```

## Teammate Non-Persistence Warning

Teammates spawned via Agent Teams do **not** persist across session boundaries. When a session ends (compaction, crash, user exit), all teammates are terminated.

### What Persists vs What Is Lost

| Artifact | Persists? | Location |
|----------|-----------|----------|
| Files written to `tmp/` | Yes | Filesystem |
| Git commits | Yes | `.git/` |
| Arc checkpoint | Yes | `.rune/arc/{id}/checkpoint.json` |
| Rune Echoes | Yes | `.rune/echoes/` |
| Task list state | Yes | `~/.claude/tasks/{team}/` |
| Per-worker todo files | Yes | `tmp/work/{team}/todos/{worker}.md` |
| Worker todo summary | Yes | `tmp/work/{team}/todos/_summary.md` |
| **Teammate processes** | **No** | Terminated on session end |
| **Teammate context windows** | **No** | Lost per agent, unrecoverable |
| **In-progress work (uncommitted)** | **Partial** | May exist in working tree |

### Recovery After Session Loss

1. Check `git status` for uncommitted changes from terminated teammates
2. Read arc checkpoint for last completed phase
3. Resume with `/rune:arc --resume` (if arc workflow)
4. For standalone workflows, use `/rune:rest --heal` to clean orphaned teams
