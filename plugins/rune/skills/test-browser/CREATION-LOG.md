# /rune:test-browser — Creation Log

## Problem Statement

Arc Phase 7.7 TEST provides comprehensive 3-tier testing (unit + integration + E2E)
using a 4-agent team. However, this heavyweight approach is overkill for a developer
who wants quick E2E feedback on their changes without triggering a full arc pipeline.

The gap: no lightweight standalone browser testing tool exists in Rune. Users resort
to manually running `agent-browser` commands or skipping E2E validation entirely.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Thin wrapper around arc Phase 7.7 TEST | Arc Phase 7.7 requires full arc pipeline setup (inscription.json, checkpoint, team lifecycle). Too heavy for quick feedback loops. |
| New agent team with 1-2 Ashes | Even 1-2 agents add team lifecycle overhead (TeamCreate + shutdown). ISOLATION CONTRACT explicitly forbids this for speed. |
| Shell script hook | Hooks can't call AskUserQuestion or Read files — too limited for interactive failure handling. |
| Extend arc with --quick flag | Blurs the boundary between standalone and pipeline testing. More complex for users to reason about. |

## Key Design Decisions

- **Inline execution (no agent teams)**: The ISOLATION CONTRACT is the central design
  decision. Spawning agents adds 3-8s per agent + team lifecycle overhead. For a developer
  iterating on a single route, this latency is unacceptable. Inline execution completes
  a 3-route test run in seconds rather than minutes.

- **E2E only (not 3-tier)**: Unit and integration tests don't require a browser or a live
  server — they can run with `pytest` or `jest` directly. The test-browser skill fills the
  specific gap of interactive browser testing, not general test orchestration.

- **Interactive failure handling**: Arc Phase 7.7 defers failures to a test-failure-analyst
  Ash. In standalone mode, the developer is present and can make decisions in real-time.
  The FIX/TODO/SKIP flow lets them triage failures without leaving the session.

- **Human gate AskUserQuestion limitation**: `AskUserQuestion` has no timeout. A gate
  pause (OAuth, SMS/2FA, payment) can hang indefinitely if the user walks away. This is
  documented as a known limitation rather than "fixed" — the correct fix is an async
  notification system outside Claude's current capabilities. Documented in human-gates.md.

- **scope-detection.md as shared module**: `resolveTestScope()` is used identically by
  both test-browser (standalone) and arc Phase 7.7. Extracting it to
  `testing/references/scope-detection.md` prevents drift between the two implementations.

- **Concrete pass criteria (Gap 6.1 fix)**: handleFixNow uses explicit criteria:
  `console errors == 0 AND snapshot.length > 50 AND no error patterns`. This prevents
  false passes where a blank page or error page would satisfy a vague "test passes" check.

- **mapRouteToSourceFiles (Gap 6.2 fix)**: Concretely implemented using the same
  framework-detection logic from `file-route-mapping.md`. Not a TODO placeholder.

- **Path containment in failure-handling**: All file paths from `mapRouteToSourceFiles`
  pass through `SAFE_PATH_PATTERN` validation in `handleFixNow`. Reuses the same pattern
  from the testing skill rather than defining a new one.

## Iteration History

| Date | Version | Change | Trigger |
|------|---------|--------|---------|
| 2026-03-01 | v1.0 | Initial creation — 9-step workflow, human gates, interactive failure handling, scope-detection integration | v1.126.0 standalone browser testing feature |
