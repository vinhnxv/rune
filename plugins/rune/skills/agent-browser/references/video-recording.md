# Video Recording

Video capture for failure evidence in the arc test pipeline. Available in v0.21+.

## Basic Usage

```bash
agent-browser record start                           # begin recording
# ... perform interactions ...
agent-browser record stop test-recording.webm        # save recording
```

Output format: WebM (VP8/VP9). Configurable via `AGENT_BROWSER_VIDEO_FORMAT`.

## Conditional Recording (Record on Failure)

Record only when a test fails to save disk space:

```bash
agent-browser record start
agent-browser open <url> && agent-browser snapshot -i

# ... test interactions ...
TEST_RESULT=$?

if [ $TEST_RESULT -ne 0 ]; then
  agent-browser record stop "tmp/test/${TIMESTAMP}/videos/failure-${ROUTE}.webm"
else
  agent-browser record stop /dev/null  # discard on success
fi
```

## Arc Phase 7.7 Integration

During the arc test phase, save videos to the standard output directory:

```
tmp/test/{timestamp}/videos/
```

Video filenames should include the route or test name for traceability:
- `failure-login.webm`
- `failure-checkout-flow.webm`
- `failure-settings-page.webm`

## File Size Management

Typical recording sizes:
- ~2-5 MB per minute of interaction
- A full E2E test of 5 routes: ~10-25 MB total

To cap recording length:

```bash
# Set max duration (prevents runaway recordings)
timeout 60 agent-browser record stop output.webm
```

## Debugging with Video

Video recordings are useful for:
1. **Flaky test diagnosis** — see exactly what the browser rendered at failure time
2. **Visual regression evidence** — compare expected vs actual UI state
3. **CI artifact attachment** — upload as test report attachments
4. **Cross-team communication** — share browser behavior without reproducing locally
