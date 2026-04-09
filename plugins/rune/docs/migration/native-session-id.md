# Migration: Native CLAUDE_SESSION_ID

Tracks: [anthropics/claude-code#25642](https://github.com/anthropics/claude-code/issues/25642)

## Background

Rune's session identity system uses a 3-layer model to isolate concurrent sessions:

1. **config_dir** (CLAUDE_CONFIG_DIR) — installation/account isolation
2. **session_id** (CLAUDE_SESSION_ID/RUNE_SESSION_ID) — session isolation
3. **owner_pid** ($PPID) — fallback liveness check

Layer 2 relies on workarounds because `$CLAUDE_SESSION_ID` is not available in
Bash tool context. The current bridge injects `RUNE_SESSION_ID` via
`CLAUDE_ENV_FILE` in `session-start.sh`, with a PID-scoped cache in
`resolve-session-identity.sh` and a "claim on first touch" mechanism in
`stop-hook-common.sh`.

## When to migrate

After Claude Code ships `$CLAUDE_SESSION_ID` as a native environment variable
available in Bash tool context (not just hook context).

## Phase 1: Verify (0 code changes)

Before removing any workarounds, verify the new env var works correctly:

- [ ] Confirm `CLAUDE_SESSION_ID` is available in Bash tool context (`echo $CLAUDE_SESSION_ID`)
- [ ] Confirm format matches hook JSON `session_id` (same UUID format)
- [ ] Confirm teammates inherit the same value
- [ ] Confirm value persists across session resume/clear/compact
- [ ] Check format consistency assertion logs (RUNE_TRACE=1) for any mismatches

## Phase 2: Simplify (remove workarounds)

Once Phase 1 confirms compatibility:

- [ ] Remove `RUNE_SESSION_ID` bridge from `session-start.sh` (env file injection)
- [ ] Remove cache mechanism from `resolve-session-identity.sh` (lines 46-96)
- [ ] Remove claim-on-first-touch from `stop-hook-common.sh` (lines 230-290)
- [ ] Simplify `resolve-session-identity.sh` to: `RUNE_CURRENT_SID="$CLAUDE_SESSION_ID"`
- [ ] Remove TTL guard (added in v2.39.1 — no longer needed with native env var)
- [ ] Remove staleness guard (added in v2.39.1 — claim-on-first-touch removed entirely)

## Phase 3: Cleanup (after 2 minor versions)

After Phase 2 has been stable for 2 minor version releases:

- [ ] Remove `RUNE_SESSION_ID` references across scripts (grep for occurrences)
- [ ] Remove format consistency assertion (added in v2.39.1)
- [ ] Simplify 3-layer to 2-layer identity (config_dir + session_id)
- [ ] Remove `rune_pid_alive()` if no longer used as fallback
- [ ] Update CLAUDE.md session isolation documentation

## Backward compatibility

Keep the fallback chain for 2 minor versions after Phase 2:

```
CLAUDE_SESSION_ID > RUNE_SESSION_ID > PPID fallback
```

The `resolve-session-identity.sh` priority chain already implements this:
```bash
RUNE_CURRENT_SID="${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-}}"
```

## Files affected

| File | Current workaround | Phase 2 change |
|------|-------------------|----------------|
| `scripts/session-start.sh` | RUNE_SESSION_ID env bridge | Remove bridge |
| `scripts/resolve-session-identity.sh` | PID-scoped cache + TTL | Remove cache |
| `scripts/lib/stop-hook-common.sh` | Claim-on-first-touch + staleness guard | Remove both |
| `scripts/lib/rune-state.sh` | References RUNE_SESSION_ID | Update to CLAUDE_SESSION_ID |
| 54 hook/lib scripts | 341 occurrences of session_id patterns | Audit each |

## Risk assessment

- **Low risk**: The native env var will be more reliable than the current bridge
- **Testing**: Run `test-resolve-session-identity.sh` and `test-session-ownership.sh` after each phase
- **Rollback**: Keep old code commented for 1 release, then delete
