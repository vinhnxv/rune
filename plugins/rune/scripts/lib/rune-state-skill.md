## Rune State Directory

All Rune workflow state lives in `.rune/` at project root (NOT `.claude/`).

| Path | Content |
|------|---------|
| `.rune/arc/` | Arc checkpoints |
| `.rune/arc-phase-loop.local.md` | Phase loop state |
| `.rune/arc-batch-loop.local.md` | Batch loop state |
| `.rune/arc-hierarchy-loop.local.md` | Hierarchy loop state |
| `.rune/arc-issues-loop.local.md` | Issues loop state |
| `.rune/arc-hierarchy-exec-table.json` | Hierarchy exec table |
| `.rune/echoes/` | Rune Echoes memory |
| `.rune/talisman.yml` | Rune configuration |
| `.rune/audit-state/` | Incremental audit state |
| `.rune/worktrees/` | Worktree tracking |
| `.rune/.agent-search-index.db` | Agent search index |

### In pseudocode (skills)
- Use `.rune/` prefix: `Write(".rune/arc/${id}/checkpoint.json", ...)`
- Use `.rune/talisman.yml` (NOT `.claude/talisman.yml`)
- Use `.rune/echoes/` (NOT `.claude/echoes/`)

### In shell scripts
- Source `lib/rune-state.sh` and use `${RUNE_STATE}` or `${RUNE_STATE_ABS}`
