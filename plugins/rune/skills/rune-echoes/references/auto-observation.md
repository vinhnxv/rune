# Auto-Observation Recording Protocol

Auto-observation is the automatic capture of agent task completions into the Echoes Observations tier. It requires zero orchestrator involvement — the `TaskCompleted` hook fires automatically and appends lightweight entries to the appropriate role `MEMORY.md`.

## When It Fires

The `on-task-observation.sh` script runs on every `TaskCompleted` event. Guards narrow it to meaningful observations:

| Guard | Condition | Action |
|-------|-----------|--------|
| Rune workflow only | `team_name` starts with `rune-` or `arc-` | Skip non-Rune teams |
| Skip meta tasks | Subject contains shutdown/cleanup/aggregate/monitor | Skip silently |
| Echoes dir exists | `.rune/echoes/` is present | Skip if echoes not initialized |
| Role MEMORY.md exists | `{role}/MEMORY.md` exists | Skip if role not initialized |
| Dedup check | `.obs-{TEAM_NAME}_{TASK_ID}` signal file | Skip if already recorded |

## What It Records

Each recorded observation follows the Observations tier format (weight=0.5):

```markdown
## Observations — Task: {task_subject} ({date})
- **layer**: observations
- **source**: `{team_name}/{agent_name}`
- **Confidence**: LOW (auto-generated, unverified)
- Task completed: {task_subject}
- Context: {task_description (truncated to 500 chars)}
```

Observations are Tier 4 (lowest persistent tier). They auto-promote to Inscribed after 3 access_count references via `echo_record_access`. They are auto-pruned when `days_since_last_access > 60`.

## Dedup Strategy

Dedup key: `${TEAM_NAME}_${TASK_ID}` — stored as a signal file at `tmp/.rune-signals/.obs-{key}`.

**Why not md5?** `md5` behaves differently across platforms (`md5 -q` on macOS, `md5sum` on Linux). A direct `{team}_{task_id}` key is:
- Portable (pure bash, no external commands)
- Directly mapped to unique task identity (one team + one task = one observation)
- Human-readable in the signal directory for debugging

## Role Detection

Role is inferred from the team name pattern:

| Pattern | Role | MEMORY.md |
|---------|------|-----------|
| `*review*`, `*appraise*`, `*audit*` | `reviewer` | `.rune/echoes/reviewer/MEMORY.md` |
| `*plan*`, `*devise*` | `planner` | `.rune/echoes/planner/MEMORY.md` |
| `*work*`, `*strive*`, `*arc*` | `workers` | `.rune/echoes/workers/MEMORY.md` |
| (default) | `orchestrator` | `.rune/echoes/orchestrator/MEMORY.md` |

## Dirty Signal

After appending the observation, the script touches `tmp/.rune-signals/.echo-dirty`. The `echo-search` MCP server detects this signal on the next `echo_search` call and auto-reindexes before returning results.

## Tier: Observations

Auto-observations land in the **Observations** tier (weight=0.5). They are NOT Inscribed entries. Promotion to Inscribed requires 3 access references via `echo_record_access`. This prevents low-quality auto-generated entries from polluting the higher-weight tiers.

## Configuration

Auto-observation runs unconditionally when the `TaskCompleted` hook fires and the role `MEMORY.md` exists. There is no talisman toggle — echoes must be initialized (`.rune/echoes/` present) for any recording to occur.

To disable: remove the `on-task-observation.sh` hook entry from `hooks/hooks.json`.

## Security

- All paths canonicalized via `cd && pwd -P` (no symlink follow)
- Symlink guard on both `ECHO_DIR` and `MEMORY_FILE`
- Input capped at 64KB (SEC-006)
- Task subject/description truncated to 500 chars before writing
- Signal directory created with `umask`-inherited permissions
- Dedup files stored in `tmp/.rune-signals/` (ephemeral, not persistent)
- Exit 0 on all error paths (non-blocking hook)
