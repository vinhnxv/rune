# Monitor Tool Patterns — Concrete Arc Phase Recipes

> **When to consult**: You are adding a new `Monitor({...})` call to a Rune skill or reference
> file. This document lists the canonical patterns Rune already uses (or has planned),
> with the exact command template, exit conditions, and fallback wiring for each.
>
> **When NOT to consult**: You are coordinating a multi-teammate Team — use TaskList polling
> instead. See `polling-guard/SKILL.md` § "Choose the Right Waiting Pattern".
>
> **Cross-link**: The decision table in `polling-guard/SKILL.md` is the entry-point contract.
> This file is the implementation cookbook behind it.

## Hard Prerequisites

1. **Claude Code v2.1.105+** (plugin monitors) / v2.1.98+ (LLM-invoked `Monitor` tool) —
   Rune declares v2.1.105 as the single floor for release-management simplicity. Older
   Claude Code receives a one-line upgrade advisory via `probe-monitor-availability.sh`
   and Monitor activation is skipped.
2. **Host capability**. Monitor is unavailable on:
   - Amazon Bedrock (`ANTHROPIC_BEDROCK_BASE_URL` set)
   - Google Vertex AI (`ANTHROPIC_VERTEX_PROJECT_ID` set)
   - Microsoft Foundry (relies on telemetry flags)
   - `DISABLE_TELEMETRY=1`
   - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
3. **Sentinel file consumption**. Every Monitor-invoking skill MUST read one of:
   - `tmp/.rune-monitor-available` (probe says Monitor is usable)
   - `tmp/.rune-monitor-unavailable` (probe reports a specific reason — use fallback)
   - No sentinel present → conservative path: skip Monitor, use pull-based fallback.

   The sentinel is written by `scripts/probe-monitor-availability.sh` at SessionStart.
   Do NOT re-probe inside a phase — trust the sentinel.

## Pattern Catalog

### Pattern A — State-change streaming (bot-review-wait)

**Used by**: `skills/arc/references/arc-phase-bot-review-wait.md` Phase 9.1

**Shape**:

```javascript
const reviewMonitor = Monitor({
  description: `PR #${prNumber} bot reviews + CI state`,
  timeout_ms: HARD_TIMEOUT_MS,     // preserve existing phase timeout
  persistent: false,
  env: {                            // injection-safe: pass identifiers via env, NEVER interpolate
    OWNER: owner,
    REPO: repo,
    PR_NUMBER: String(prNumber),
    HEAD_SHA: headSha,
    POLL_SECS: String(Math.round(POLL_INTERVAL_MS / 1000))
  },
  command: `
    last_signature=""
    fail_streak=0
    first_emit=1
    while true; do
      sig=$(gh api "repos/\${OWNER}/\${REPO}/issues/\${PR_NUMBER}/comments" \\
            --jq '[.[] | select(.user.type=="Bot") | .updated_at] | sort | last // "none"' 2>/dev/null || echo "__GH_API_FAIL__")
      ci=$(gh api "repos/\${OWNER}/\${REPO}/commits/\${HEAD_SHA}/check-runs" \\
            --jq '"\\(.check_runs|length)/\\([.check_runs[]|select(.status=="completed")]|length)/\\([.check_runs[]|select(.conclusion=="failure")]|length)"' 2>/dev/null || echo "__GH_API_FAIL__")
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)
      if [[ "\$sig" == "__GH_API_FAIL__" || "\$ci" == "__GH_API_FAIL__" ]]; then
        fail_streak=\$((fail_streak + 1))
        printf '%s STATE_ERROR gh_api_fail streak=%d\\n' "\$ts" "\$fail_streak"
        [[ "\$fail_streak" -ge 2 ]] && exit 1 || true
      else
        fail_streak=0
        current="bot=\$sig ci=\$ci"
        if [[ "\$current" != "\$last_signature" || "\$first_emit" == "1" ]]; then
          printf '%s STATE_CHANGE %s\\n' "\$ts" "\$current"
          last_signature="\$current"
          first_emit=0
        fi
      fi
      sleep "\$POLL_SECS"
    done
  `
})
```

**Exit conditions**:
- `timeout_ms` elapsed (command exits) → orchestrator sees stream end, proceeds to stability-window evaluation
- Command `exit 1` (2 consecutive STATE_ERROR) → orchestrator trips circuit breaker, falls back to polling
- PR fully reviewed and the script exits 0 (future enhancement: exit once all known bots have posted)

**Fallback**: The pull-based polling loop immediately below the Monitor block in the reference
file is the fallback path. It MUST remain code-resident (not commented out). Two consecutive
STATE_ERROR events trigger orchestrator-side circuit breaker, write
`tmp/arc/{id}/monitor-fallback.log`, and the polling loop takes over from scratch. Polling
does NOT inherit Monitor's `last_signature`; it re-reads current state. This is safe because
polling has always been the historical sole implementation.

**Emission rules** (from BP-1, BP-3, EC-5):
- Emit only on signature delta (BP-1) — heartbeat emission would defeat the whole point
- First cycle emits STATE_CHANGE even without prior signature (BP-3 LIST-then-WATCH baseline)
- Orchestrator must dedup duplicate events (EC-5): Monitor runtime restarts emit "first state" again

**Event budget assertion** (RISK-B): If `eventCount > 10` during a steady-state run, suspect
signature noise (non-deterministic timestamp field leaked into the signature). Log a warning
and investigate.

### Pattern B — Activity signal fanout (stale-teammate-watcher, plugin monitor)

**Used by**: `monitors/monitors.json` entry `stale-teammate-watcher` (plan Track B.1)

**Shape**: A plugin monitor declared in `monitors/monitors.json`:

```json
{
  "name": "stale-teammate-watcher",
  "description": "Teammate inactivity > 3 min during active workflows",
  "command": "${CLAUDE_PLUGIN_ROOT}/scripts/monitor-stale-teammates.sh",
  "when": "always"
}
```

**Companion script contract**:
- Fast-path exit (<50ms) when no Rune workflow signals exist — check for
  `tmp/.rune-signals/` directory or active workflow state files first
- Emit one stdout line per *new* stale teammate detected since the previous emission
- Read from `tmp/.rune-signals/{team}/activity-*` files (written by `track-teammate-activity.sh`)
- No heartbeat emission — state change only (BP-1)
- Respect the kill-switch: `process_management.monitors.enabled: false` (default true) means
  the script never starts; the Stop-hook `detect-stale-lead.sh` covers detection

**Host-capability coupling**: `probe-monitor-availability.sh` also governs plugin monitors.
On unsupported hosts, the AC-5 sentinel is absent or "unavailable"; the session's plugin
monitor manager is expected to skip declared monitors automatically. A sentinel check
inside the script provides defense-in-depth.

### Pattern C — On-demand reindex (echo-search-eager-reindex, plugin monitor)

**Used by**: `monitors/monitors.json` entry `echo-search-eager-reindex` (plan Track B.2)

**Shape**:

```json
{
  "name": "echo-search-eager-reindex",
  "description": "Eager echo index rebuild on signal",
  "command": "${CLAUDE_PLUGIN_ROOT}/scripts/echo-search/eager-reindex.sh",
  "when": "on-skill-invoke:rune-echoes"
}
```

`when: "on-skill-invoke:rune-echoes"` bounds lifetime to when echoes are actually in use.
The script watches `tmp/.rune-signals/.echo-dirty` and triggers the reindex MCP call
eagerly, so the first subsequent `echo_search` is not the one that pays the rebuild cost.

## Anti-patterns

| Anti-pattern | Why it breaks |
|--------------|---------------|
| `command: "... watching ${prNumber} ..."` (string interpolation) | Shell injection vector. ALWAYS use `env:` map. |
| Emit on every cycle (`echo "heartbeat"`) | Each line becomes a conversation message. Heartbeats = context cost without signal. |
| No `|| true` after `gh api` failures | Script exits silently; orchestrator sees dead stream, not error signal. Emit `STATE_ERROR` instead. |
| Grep only happy-path patterns (`grep PASS`) | Silence ≠ success. Include failure signatures too (FAIL, Traceback). |
| Missing `--line-buffered` in pipes | Pipe buffering delays events by minutes. Always pass `--line-buffered` to `grep`/`awk` in Monitor commands. |
| Nested Monitor inside Monitor | Unverified in docs (RISK-F). If you need this, enforce it with a Rune-side rule, not assumed framework behavior. |
| Using Monitor for one-shot waits (file appears, port opens) | Wrong tool. Use `Bash("until [ -f X ]; do sleep 2; done", { run_in_background: true })` instead. |

## Circuit Breaker Recipe

All state-streaming Monitor consumers in Rune follow the same breaker shape:

```
let consecutiveErrors = 0
for (const event of monitorStream) {
  const line = event.output.toString().trim()
  if (line.includes("STATE_ERROR")) {
    consecutiveErrors += 1
    if (consecutiveErrors >= 2) {
      // fire circuit breaker
      Write(`tmp/arc/{id}/monitor-fallback.log`, `breaker tripped at ${new Date().toISOString()}: ${line}\n`)
      break  // exit consumer loop → pull-based fallback runs
    }
    continue
  }
  consecutiveErrors = 0
  // ... handle STATE_CHANGE ...
}
```

**Fallback state does NOT persist across phase invocations** (RISK-C). Each arc run
re-attempts Monitor from scratch. This prevents a one-off network glitch from permanently
disabling the fast path.

## Testing Checklist

Before merging a new Monitor pattern:

- [ ] **Capability probe**: Sentinel check is present — no unconditional `Monitor()` calls
- [ ] **Fallback preserved**: The pre-existing pull-based path remains code-resident (not commented out, not feature-flagged)
- [ ] **Env, not interpolation**: All user-derived identifiers pass through the `env:` map
- [ ] **Circuit breaker**: 2 consecutive STATE_ERROR → fall back; log written to `tmp/arc/{id}/monitor-fallback.log`
- [ ] **Baseline emit**: First cycle emits STATE_CHANGE even without prior signature (BP-3)
- [ ] **Dedup**: Consumer idempotently handles repeat STATE_CHANGE with identical payload (EC-5)
- [ ] **Event budget**: Assertion warns if >10 events in a steady-state happy-path run (RISK-B)
- [ ] **Timeout alignment**: `timeout_ms` matches or is less than the calling phase's timeout (EC-3)
- [ ] **No `sleep N && echo`** anywhere in the consumer — POLL-001 hook would deny it anyway

## References

- `skills/polling-guard/SKILL.md` § "Choose the Right Waiting Pattern" — decision table entry-point
- `skills/arc/references/arc-phase-bot-review-wait.md` — concrete Pattern A consumer
- `monitors/monitors.json` — Patterns B and C declared as plugin monitors
- `scripts/probe-monitor-availability.sh` — AC-5 host capability probe (writes sentinel files)
- `skills/roundtable-circle/references/monitor-utility.md` — **different concept**: TaskList polling utility, NOT the Monitor tool. See its disambiguation note.
- [Claude Code Monitor tool docs](https://code.claude.com/docs/en/tools-reference#monitor-tool)
- [Claude Code plugin monitors docs](https://code.claude.com/docs/en/plugins-reference#monitors)
