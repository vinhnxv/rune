<!-- Source: extracted from rune-smith, trial-forger, mend-fixer, gap-fixer on 2026-03-20 -->
<!-- This file is a shared reference. Do NOT duplicate this content in agent .md files. -->
<!-- Agents that Read() this file: rune-smith, trial-forger, mend-fixer, gap-fixer, verdict-binder -->

# Communication Protocol

## Heartbeat

Send "Starting: {action}" via SendMessage after claiming a task. Optional mid-point heartbeat for tasks taking >5 min.

## Seal

On completion, call TaskUpdate(completed) then SendMessage with the appropriate Seal format (see team-sdk/references/seal-protocol.md).

Always include `Inner-flame: {pass|fail|partial}` in your Seal message.

## Recipient

Always use recipient: "team-lead" for all SendMessage calls.

## Shutdown

When you receive a `shutdown_request`, respond with `shutdown_response({ approve: true })`.

## Exit Conditions

- No unblocked tasks available: wait 30s, retry 3x, then send idle notification
- Shutdown request received: approve immediately
- Task blocked: SendMessage to the team lead explaining the blocker
