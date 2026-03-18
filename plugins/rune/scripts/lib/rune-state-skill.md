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
| `.rune/test-history/` | Persistent test history |
| `.rune/test-scenarios/` | Declarative test scenarios |
| `.rune/visual-baselines/` | Visual regression baselines |
| `.rune/design-sync/` | Design sync VSM/DCD state |
| `.rune/design-system-profile.yaml` | Design system profile |

### In pseudocode (skills)
- Use `.rune/` prefix: `Write(".rune/arc/${id}/checkpoint.json", ...)`
- Use `.rune/talisman.yml` (NOT `.claude/talisman.yml`)
- Use `.rune/echoes/` (NOT `.claude/echoes/`)

### Talisman fallback (dual-support)
- Primary: `.rune/talisman.yml`
- Fallback: `.claude/talisman.yml` (legacy, with deprecation warning in trace log)
- Both paths are supported by `talisman-resolve.sh` (line 86-90)
- Migration: `_rune_migrate_legacy()` moves `.claude/talisman.yml` → `.rune/talisman.yml` on first run

### In shell scripts
- Source `lib/rune-state.sh` and use `${RUNE_STATE}` or `${RUNE_STATE_ABS}`
