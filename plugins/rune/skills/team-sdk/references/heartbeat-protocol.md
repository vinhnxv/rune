# Heartbeat Protocol

> Lightweight progress messages from teammates to the team lead. Maximum 3 messages per task to minimize context consumption.

## Overview

Heartbeats provide visibility into teammate progress without flooding the team lead's context window. Each teammate sends at most 3 messages per task: START, optional MID-POINT, and COMPLETION (via Seal).

### Budget

| Message | When | Required |
|---------|------|----------|
| START | After claiming task (`TaskUpdate({ status: "in_progress" })`) | Yes |
| MID-POINT | Midway through tasks expected to take >5 minutes | Optional |
| COMPLETION | After finishing task (`TaskUpdate({ status: "completed" })`) | Yes (via Seal) |

**Hard limit: 3 messages per task.** No exceptions. Extra messages waste team lead context tokens.

## Message Format

All heartbeats use `SendMessage` with `type: "message"` and `recipient: "team-lead"`. Each message MUST be under 2 lines.

### START

Sent immediately after claiming a task.

```javascript
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "START task #{id}: {brief description of approach}",
  summary: "START task #{id}"
})
```

**Example:**

```javascript
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "START task #3: Implementing JWT refresh rotation in src/auth.ts",
  summary: "START task #3"
})
```

### MID-POINT

Optional. Only send for tasks expected to take more than 5 minutes. Use to report meaningful progress or flag blockers.

```javascript
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "MID task #{id}: {progress update or blocker}",
  summary: "MID task #{id}"
})
```

**Example:**

```javascript
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "MID task #3: Token rotation logic done, writing tests now.",
  summary: "MID task #3"
})
```

**When to send MID-POINT:**
- Task involves multiple files or steps
- Estimated duration exceeds 5 minutes
- A blocker or unexpected complexity is encountered

**When NOT to send MID-POINT:**
- Simple, single-file tasks
- Tasks completing in under 5 minutes
- Nothing meaningful to report

### COMPLETION

Delivered via the Seal protocol — not a separate heartbeat message. See [seal-protocol.md](seal-protocol.md) for the full Seal format.

The Seal serves as both the completion heartbeat and the structured outcome report.

## Rules

1. **Max 3 messages per task**: START + optional MID-POINT + Seal. Never exceed this.
2. **Under 2 lines each**: Keep heartbeats concise. Details belong in output files, not messages.
3. **Use SendMessage**: Always `type: "message"`, always `recipient: "team-lead"`.
4. **START is mandatory**: Every claimed task gets a START heartbeat.
5. **MID-POINT is optional**: Only for long-running tasks (>5 min) with meaningful updates.
6. **Seal replaces COMPLETION**: Do not send a separate "DONE" heartbeat — the Seal covers it.

## Anti-Patterns

### NEVER: Chatty Progress Updates

```javascript
// WRONG — too many messages, wastes context
SendMessage({ content: "Starting to read the file..." })
SendMessage({ content: "Found the function..." })
SendMessage({ content: "Making the change..." })
SendMessage({ content: "Running tests..." })
SendMessage({ content: "Tests passed!" })
SendMessage({ content: "Done!" })
```

### NEVER: Verbose Messages

```javascript
// WRONG — too long, should be under 2 lines
SendMessage({
  content: "I'm currently working on task #3 which involves implementing JWT refresh token rotation. I've analyzed the existing auth module and found that it uses a single access token without refresh capability. My plan is to add a refresh token endpoint, update the token validation middleware, and add tests for the new flow. So far I've completed the endpoint implementation and I'm moving on to the middleware changes."
})
```

### ALWAYS: Concise and Structured

```javascript
// CORRECT — concise START
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "START task #3: JWT refresh rotation in src/auth.ts",
  summary: "START task #3"
})

// CORRECT — concise MID (only if >5min task)
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "MID task #3: Rotation logic done, writing tests.",
  summary: "MID task #3"
})

// CORRECT — Seal as completion (see seal-protocol.md)
```

## Cross-References

- [seal-protocol.md](seal-protocol.md) — Seal completion protocol (serves as COMPLETION heartbeat)
- [monitoring.md](monitoring.md) — How the team lead monitors teammate progress
- [protocols.md](protocols.md) — Session isolation for teammate state
