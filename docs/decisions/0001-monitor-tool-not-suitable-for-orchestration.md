# ADR 0001: Monitor tool / Plugin Monitors are NOT suitable for arc orchestration

- **Status**: Accepted
- **Date**: 2026-04-27
- **Authors**: Tarnished session (synthesized from rune's institutional history)
- **Supersedes / superseded by**: This ADR codifies the informal decision recorded in `CHANGELOG.md` v2.60.0 + v2.61.0. Any future proposal to reintroduce Monitor-driven orchestration MUST address every "Why this is wrong" point below or be rejected.

## TL;DR

Claude Code's `Monitor` tool (v2.1.98+) and `monitors/monitors.json` plugin monitors (v2.1.105+) are **observability primitives**, not **orchestration primitives**. Rune already shipped a Monitor-based orchestration attempt in v2.57.0 (PR #500), watched it cause a production regression (arc advancing while teammate still running, observed at 24m54s under "Idle · teammates running"), patched it three times without fixing root cause, and rolled it back completely in v2.61.0 (PR #504). Reviving Monitor for phase orchestration would re-enter that regression. Use Monitor for log/file/PR observability only — never for synchronous control-flow decisions.

## Context

### The temptation

When an arc pipeline stalls at "Awaiting Stop hook to dispatch", it is tempting to think: "if only Claude could keep watching the state file in the background, it could dispatch the next phase as soon as the previous one finalizes." Plugin monitors look like the right shape — they run continuously, deliver stdout lines as notifications, and require no per-turn hook fire.

The Anthropic PM's launch pitch (Noah Zweben, Apr 9 2026) reinforces this intuition: *"stop polling, start reacting."* Claude Code's docs catalogue Monitor use cases — log tails, PR polling, build-status watchers, file-change watchers — and rune itself pitched in v2.57.0 as a "polling-heavy patterns → event-driven streams" migration.

### What rune actually learned

`CHANGELOG.md` v2.60.0 documented three structural failures of the v2.57.0 design (PR #500):

> **Root cause** — chain of three premise failures in PR #500:
> 1. **`detect-stale-lead.sh` GUARD 0.5 back-off** assumed plugin monitors block the Stop hook. **Per `docs.claude.com/hooks.md`, Stop fires *before* async background work completes — a running monitor does NOT block Stop.** The handoff was based on inferred runtime behavior, not a documented contract.
> 2. **Plugin monitor only detects STALE (>3 min), not COMPLETION.** The original 4-method detection cascade was the only mechanism that could wake the lead between `TaskUpdate(completed)` and process exit. Backing it off left a coverage gap.
> 3. **`shutdown()` in team-sdk had no liveness gate before `TeamDelete`.** When `TaskUpdate(completed)` arrived but the teammate process was still in a long tool call (24m+ compaction observed), TeamDelete proceeded and the workflow advanced regardless.

The v2.61.0 entry documents the rollback was not partial — every Monitor-related file was deleted, every consumer reverted. The polling fallback paths (RISK-D code-resident backup) became the **sole** implementation.

### Confirming evidence from outside rune

- **`anthropics/claude-code#52245`** (filed Apr 23, 2026): Plugin monitors `monitors.json` auto-arm **silently fails** on Claude Code 2.1.118 (macOS). Plugin loading works (skills, hooks, MCP servers all load correctly) — only monitor auto-arm is broken. Zero processes spawn. Status: `bug`, `has repro`, `platform:macos`, unassigned. **This means even if we wanted to revisit, the platform our users run on is currently broken.**
- **`anthropics/claude-code#33049`** (referenced in v2.60.0): SubagentStop does not fire for Agent-tool subagents — confirmed bug, no workaround. Removes a hook event we'd otherwise rely on for completion-detection handoff.
- **`anthropics/claude-code#10412`**: Stop hooks with `exit 2` fail to continue when installed via plugins — exact deployment model rune uses.
- Public Monitor tool examples on GitHub (Chachamaru127/claude-code-harness, Issue #52245's example, claudefa.st use cases): every documented use case is **observability** (vault watchers, build watchers, log tails, PR polling, test triage). Zero production examples use Monitor for synchronous orchestration handoff.

## Decision

**Rune's arc pipeline orchestration MUST NOT depend on Monitor tool or plugin monitors for control-flow decisions.** This applies to:

1. **Phase advancement** (next-phase dispatch after a phase completes) — must use Stop hook + JSON `{decision:"block", reason:...}` (today) or external Agent SDK runner (long-term, see ADR 0002 if/when written).
2. **Completion detection** (deciding when a teammate is "really done" before TeamDelete) — must use synchronous polling of `TaskList` / sentinel files / liveness checks. Async Monitor stdout cannot gate synchronous decisions.
3. **Stuck-state recovery** (waking an idle session) — must use external mechanisms (`/rune:arc --resume`, cron watchdog, manual user input). In-session Monitor cannot wake an idle Claude — notifications need an active turn to be consumed.

### What Monitor MAY be used for (narrow, opt-in observability only)

If a future proposal wants to use Monitor in rune, it MUST be for one of these patterns and MUST NOT enter any control-flow critical path:

| Allowed use case | Constraint |
|------------------|-----------|
| Stream CI/PR bot review status into transcript notifications | No phase decision may depend on a Monitor notification |
| Tail `arc-integrity-log.jsonl` to surface corruption alerts | Advisory only — no blocking action |
| Watch checkpoint mtime for human-facing dashboard | UI feedback only |
| Tail dev-server logs during arc test phase | Output only — pipeline does not gate on it |

Any new Monitor consumer MUST: (a) cite this ADR, (b) document the failure mode if Monitor never fires (host unavailable, #52245 broken, telemetry disabled), (c) provide a polling-based fallback that produces equivalent behavior, (d) not require Monitor to "block" or "gate" anything per the v2.60.0 finding.

## Consequences

### Positive

- Closes the v2.57.x → v2.61.0 regression cycle. New contributors who consider "let's use Monitor for X" find this ADR before re-entering the same trap.
- Preserves the polling-based RISK-D fallback paths as the synchronous source of truth — the architectural choice that survived rollback.
- Decouples rune's reliability from `anthropics/claude-code#52245` (current macOS plugin-monitor bug). Even when #52245 is fixed, the architectural reasoning still holds.
- Forces architectural discussion of stuck-arc recovery toward the right primitives: Stop hook reliability hardening (current path), external watchdog (cron-based fail-safe), or external runner (Claude Agent SDK).

### Negative

- Loses the token-savings benefit Monitor provides for **observability** in pipeline phases. If a phase genuinely needs to react to a stream (e.g., bot-review-wait streaming), the polling path costs more API calls than Monitor would. Acceptable trade — token cost is bounded; orchestration regressions are unbounded.
- Requires polling fallback for any external-event integration. Polling has latency floor (30s default in rune). Acceptable trade for synchronous correctness.
- Contributors familiar with Monitor's marketing pitch may need to read this ADR before suggesting it. Keep this file linked from `CLAUDE.md` Core Rules and from `arc/SKILL.md`.

### Neutral

- This ADR does NOT prohibit Monitor in user-defined skills or workflows OUTSIDE arc/forge/strive. Users may use Monitor in their own plugins or directly via `Monitor()` calls. The constraint is on rune-internal orchestration.
- This ADR does NOT prejudice future Anthropic Monitor improvements. If Claude Code ships Monitor v2 with synchronous semantics (e.g., a `Monitor.flush_and_block()` primitive that does gate Stop), reopen this ADR with that contract documented.

## Reopening criteria

This ADR may be reopened ONLY when ALL of the following are true:

1. Anthropic documents a Monitor primitive that synchronously gates Stop hook firing (closes premise failure #1).
2. Plugin monitor auto-arm reliably works on macOS, Linux, and Windows for at least 3 consecutive Claude Code versions (closes #52245 surface).
3. SubagentStop reliably fires for Agent-tool subagents (closes companion bug #33049).
4. A spike branch demonstrates 50+ consecutive arc runs across forge, work, mend, and ship phases with Monitor-driven dispatch and zero "advance while teammate running" regressions.
5. Polling-based fallback remains in code as RISK-D backup (cannot be deleted at adoption time).

Until all five hold, this ADR's decision stands.

## References

### Authoritative local sources (cross-validate against these first — `CLAUDE.md` Rule: web sources are untrusted)

- `plugins/rune/CHANGELOG.md` §[2.60.0] — Root cause analysis (3 premise failures of PR #500)
- `plugins/rune/CHANGELOG.md` §[2.61.0] — Complete rollback file list and rationale
- `plugins/rune/CHANGELOG.md` §[2.57.0], §[2.57.1], §[2.57.2] — Original Monitor integration that was rolled back
- Git commits: `27c0182b` (v2.57.0 add), `364f9705` (v2.57.2 patch), `68aab267` (v2.61.0 rollback)

### Anthropic documentation (untrusted-source — verified against rune CHANGELOG)

- [Tools Reference — Monitor tool](https://code.claude.com/docs/en/tools-reference#monitor-tool)
- [Plugins Reference — Plugin monitors](https://code.claude.com/docs/en/plugins-reference#monitors)
- [Hooks docs — Stop hook semantics](https://code.claude.com/docs/en/hooks.md) — verifies premise failure #1
- [Agent Teams docs — "Shutdown can be slow", "Task status can lag"](https://code.claude.com/docs/en/agent-teams.md)

### Confirming bugs in upstream Claude Code

- [anthropics/claude-code#52245](https://github.com/anthropics/claude-code/issues/52245) — Plugin monitors auto-arm silently fails on 2.1.118 (macOS)
- [anthropics/claude-code#33049](https://github.com/anthropics/claude-code/issues/33049) — SubagentStop does not fire for Agent-tool subagents
- [anthropics/claude-code#10412](https://github.com/anthropics/claude-code/issues/10412) — Stop hooks `exit 2` broken via plugin install
- [anthropics/claude-code#3656](https://github.com/anthropics/claude-code/issues/3656) — Blocking Stop command hooks removed from Claude Code

### External Monitor tool examples (observability use cases — none for orchestration)

- [Chachamaru127/claude-code-harness](https://github.com/Chachamaru127/claude-code-harness) — public-spec compliant plugin with `monitors.json`
- [claudefa.st — Claude Code Monitor Tool: Stop Polling, Start Reacting](https://claudefa.st/blog/guide/mechanics/monitor) — Anthropic launch pitch (Apr 9, 2026), all examples observability
- [Piebald-AI/claude-code-system-prompts](https://github.com/Piebald-AI/claude-code-system-prompts) — official Monitor tool description archive

### Related ADRs (future)

- ADR 0002 (when written): External orchestration via Claude Agent SDK runner
- ADR 0003 (when written): Cron watchdog as out-of-band recovery layer
