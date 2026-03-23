# Session Management

Advanced session patterns for E2E testing with agent-browser.

## Session Lifecycle

```bash
agent-browser --session-name arc-e2e-001 open <url>   # create or reuse session
agent-browser session list                              # list active sessions
agent-browser close                                     # release current session
```

## Multi-Route Testing Pattern

Persistent sessions save 3-8 seconds per route by reusing the browser process and preserving auth state:

```bash
agent-browser --session-name arc-e2e open http://localhost:3000/login
# ... test login ...
agent-browser --session-name arc-e2e open http://localhost:3000/dashboard
# Same browser — cookies/auth preserved
agent-browser --session-name arc-e2e open http://localhost:3000/settings
# Still same session — no re-auth needed
agent-browser close  # ALWAYS close to release resources
```

## Session Naming Convention

For Rune's arc test phase (Phase 7.7), use the convention:

```
arc-e2e-{timestamp}
```

Example: `arc-e2e-20260323-143000`

This matches the `/rune:test-browser` skill's expected naming pattern.

## Resource Cleanup

**Always** close sessions when done. Leaked sessions consume ~100MB RAM each.

```bash
# In test scripts, use a trap for cleanup
trap 'agent-browser close 2>/dev/null' EXIT

# Check for leaked sessions
agent-browser session list
```

Arc test phase should close sessions in a finally-block pattern to prevent leaks even on test failure.

## Concurrent Sessions

Multiple named sessions can run simultaneously for parallel route testing:

```bash
# Worker 1
agent-browser --session-name worker-1-session open http://localhost:3000/page-a

# Worker 2 (different terminal / agent)
agent-browser --session-name worker-2-session open http://localhost:3000/page-b
```

Each session has its own browser instance with independent state.

## State Persistence

Sessions preserve within a session lifetime:
- Cookies
- localStorage
- sessionStorage

For cross-session persistence, combine with `state save/restore`:

```bash
# End of session 1 — save state
agent-browser state save session-state.json
agent-browser close

# Start of session 2 — restore state
agent-browser --session-name new-session open <url>
agent-browser state restore session-state.json
```

## Session vs Profile

| Feature | Session (`--session-name`) | Profile (`--profile`) |
|---------|---------------------------|----------------------|
| Scope | Ephemeral — until `close` | Persistent — across runs |
| Storage | In-memory | On-disk |
| Use case | Single test run, multi-route | Repeated runs with same auth |
| Cleanup | `agent-browser close` | Delete profile directory |
