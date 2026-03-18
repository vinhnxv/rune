# Arc Recovery Architecture — SessionStart Hook

This document describes the arc crash recovery architecture using `SessionStart` hook detection
for cross-session crash recovery.

## Heartbeat Integration (v1.146.0)

The arc heartbeat system tracks activity during arc phases to enable stuck detection:

- **Heartbeat writer**: `scripts/arc-heartbeat-writer.sh` (PostToolUse hook)
- **Tracked tools**: Read, Write, Edit, Bash, Glob, Grep
- **Throttle**: 30-second minimum interval between writes
- **Location**: `tmp/arc/{arc_id}/heartbeat.json` with `last_activity` timestamp
- **Used by**: SessionStart hygiene reports `last_activity` for resumable checkpoints

### Heartbeat Format

```json
{
  "arc_id": "arc-abc123",
  "phase": "work",
  "last_tool": "Edit",
  "last_activity": "2026-03-10T15:30:45Z"
}
```

### Stuck Detection Heuristics

A phase is considered potentially stuck when:
1. Arc is active (not completed/cancelled)
2. A phase has status "in_progress"
3. `last_activity` is older than 15 minutes
4. No recent Claude responses (session idle)

## SessionStart Hook Recovery (v1.145.0)

When the session crashes (OOM, SIGKILL, terminal closure, machine reboot), the checkpoint
file persists on disk at `.rune/arc/{id}/checkpoint.json`. On the next session start,
`session-team-hygiene.sh` detects orphaned checkpoints (dead `owner_pid`, not
cancelled/completed) and advises the user to resume via `/rune:arc --resume`.

**When it helps**: Session crashes, OOM kills, terminal closure, machine reboot — any
scenario where the checkpoint survives but the session doesn't.

**Implementation**: See `session-team-hygiene.sh` "Layer 2: Resumable arc detection" block.

### Recovery Matrix

| Failure Scenario | Recovery |
|------------------|----------|
| Session OOM / SIGKILL | Detects on next session start |
| Terminal closed mid-arc | Detects on next session start |
| Machine reboot | Detects on next session start |
| User cancels arc | Skips (reads cancellation flags) |
| Arc completes normally | Skips (stop_reason=completed) |

### Limitations

1. **Requires user action**: Advises user to resume — does not auto-resume by default
2. **Requires new session**: Recovery only triggers when a new Claude Code session starts

## Resume Tracking

The `resume_tracking` object in the checkpoint tracks:

```javascript
resume_tracking: {
  total_resume_count: 0,      // Total resume attempts across arc lifetime
  resume_history: [],          // Array of { timestamp, trigger, phase }
  last_resume_at: null,        // ISO timestamp of last resume attempt
  consecutive_failures: 0      // Failures since last successful phase completion
}
```

### When to Reset `consecutive_failures`

After a **successful phase completion** following a resume, reset `consecutive_failures` to 0. This distinguishes between:
- Transient failures (network, timeout) → reset on success
- Systemic failures (corrupt checkpoint, missing files) → accumulate

## Security Considerations

1. **Session isolation**: `session-team-hygiene.sh` verifies `owner_pid` is dead and `config_dir` matches before flagging a checkpoint as resumable. Live sessions' checkpoints are never flagged.

## Interaction with Cancel Commands

When `/rune:cancel-arc` is invoked:

1. Sets `user_cancelled=true` in state file and checkpoint
2. Sets `stop_reason="user_cancel"`

The SessionStart hook checks these flags and skips cancelled/completed arcs.

## Error Handling

| Error | Recovery |
|-------|----------|
| Checkpoint read fails | Skip, try again on next session start |
| Resume fails | Increment `consecutive_failures`, check limits |
| State file missing | Skip (arc was cleaned up) |
