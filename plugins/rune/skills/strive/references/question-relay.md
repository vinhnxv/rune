# Question Relay Protocol — Worker Question Handling (v1.106.0+)

Workers encounter ambiguity during implementation. This document defines the Worker Question Relay
Protocol: how workers surface questions to the Tarnished (orchestrator), how the Tarnished relays
answers, and how the orchestrator persists questions/answers for compaction recovery.

**Forge Revision 1 (authoritative)**: Workers use `SendMessage` to the Tarnished for questions —
NOT filesystem IPC. The orchestrator writes `.question`/`.answer` files for persistence only.
Workers are never aware of, and never read, these persistence files.

See also: [todo-protocol.md](todo-protocol.md), [worker-prompts.md](worker-prompts.md).

## Question Payload Schema (Worker → Tarnished via SendMessage)

Workers emit questions using `SendMessage` with the following structured content:

```
QUESTION: {question text — one paragraph, concrete and specific}
TASK: {task_id}
URGENCY: blocking | non-blocking
OPTIONS: [A: {option A description}, B: {option B description}, ...]
CONTEXT: {1-2 sentence summary of what you've discovered and why this blocks}
```

**Field definitions:**

| Field | Required | Description |
|-------|----------|-------------|
| `QUESTION` | Yes | Concrete question — avoid "what should I do?" — state the specific decision |
| `TASK` | Yes | Task ID from TaskList (e.g., `task-3`) — validates against `^[a-zA-Z0-9_-]+$` |
| `URGENCY` | Yes | `blocking` = cannot proceed without answer; `non-blocking` = can continue on other work |
| `OPTIONS` | Yes | At least 2 options — worker's proposed alternatives (A, B, or more) |
| `CONTEXT` | Yes | What you found, why you're stuck — 1-2 sentences maximum |

**Question cap**: Maximum 3 questions per worker per task (SEC-006). On cap, document as TODO,
make best-effort decision, mark as "assumed — needs review" in Seal message.

### Example Question Message

```javascript
SendMessage({
  type: "message",
  recipient: "the-tarnished",    // actual recipient name from team config
  content: `QUESTION: Should the auth module use bcrypt or argon2 for password hashing?
TASK: task-3
URGENCY: blocking
OPTIONS: [A: Use bcrypt (already in deps), B: Use argon2 (stronger but new dep)]
CONTEXT: Task requires password hashing. Found bcrypt in requirements.txt but plan doesn't specify. Adding argon2 would introduce a new dependency.`,
  summary: "Worker question on task #3"
})
```

## Answer Relay Pattern (Tarnished → Worker via SendMessage)

When the Tarnished receives a question:

1. **Task status verification** (ASYNC-001): Before surfacing to user, check that the task is
   still `in_progress` via `TaskList()`. If the task is `completed` or `pending`, discard the
   question (worker already resolved or abandoned it).

2. **Surface to user**: Present via `AskUserQuestion` with the worker's question, context, and
   options. Timeout after `question_relay.timeout_seconds` (default: 180s).

3. **On timeout**: If `question_relay.auto_answer_on_timeout === true`, select the worker's first
   option (option A) and relay as auto-answer. Log the auto-answer in the worker log.

4. **Relay answer to worker**:

```javascript
SendMessage({
  type: "message",
  recipient: workerName,
  content: `ANSWER: {answer text or selected option}
TASK: {task_id}
DECIDED_BY: user | auto-timeout`,
  summary: `Answer for task #${taskId} question`
})
```

**Worker behavior on receiving answer**: Continue from where the question was sent.
If `DECIDED_BY: auto-timeout`, worker notes this assumption in the Seal message.

**Worker-side timeout (FM-3 FIX)**: Workers should NOT wait indefinitely for answers. If no
answer arrives within ~3 minutes after sending a blocking question, the worker should:
1. Proceed with the first option (option A) as a best-effort decision
2. Log the assumption in the task file Worker Report: "Auto-proceeded after relay timeout"
3. Note the assumption in the Seal message for post-completion review
The orchestrator's relay timeout (`timeout_seconds: 180`) and `auto_answer_on_timeout` handle
the common case, but worker-side resilience ensures forward progress even if the relay fails.

## Persistence Layer (Compaction Recovery — Orchestrator Only)

**CRITICAL**: Workers do NOT write, read, or poll these files. The orchestrator writes them
immediately after receiving a question, for recovery if compaction occurs mid-session.

Signal directory (created in Phase 1):

```
tmp/.rune-signals/rune-work-{timestamp}/
  {taskId}.q{seq}.question   # question written by orchestrator
  {taskId}.q{seq}.answer     # answer written by orchestrator after receiving user input
```

### Sequence Numbering (ASYNC-002, FLAW-002)

Multiple questions from the same task use monotonically increasing sequence numbers:

```
task-3.q1.question   # first question from task-3
task-3.q1.answer     # answer to first question
task-3.q2.question   # second question from task-3 (if first wasn't blocking enough to wait)
task-3.q2.answer
```

The orchestrator tracks per-task sequence numbers in memory:
`const questionSeq = {}  // { taskId: number }`

### Atomic Write Pattern (SEC-003, ARCH-004)

All persistence file writes MUST use atomic pattern to prevent partial reads during compaction:

```bash
# CORRECT — atomic write via jq + mktemp + mv
TASK_ID="task-3"
SEQ=1
SIGNAL_DIR="tmp/.rune-signals/rune-work-${TIMESTAMP}"

# SEC-002: Validate TASK_ID before path construction
if [[ ! "${TASK_ID}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: invalid task ID — aborting question persistence" >&2
  exit 1
fi

# SEC-003: Build JSON with jq --arg (never inline interpolation)
TMPFILE=$(mktemp "${SIGNAL_DIR}/.q-XXXXXX.tmp")
jq -n \
  --arg task_id  "${TASK_ID}" \
  --arg question "${QUESTION_TEXT}" \
  --arg urgency  "${URGENCY}" \
  --arg options  "${OPTIONS_JSON}" \
  --arg context  "${CONTEXT_TEXT}" \
  --arg seq      "${SEQ}" \
  '{task_id: $task_id, question: $question, urgency: $urgency,
    options: $options, context: $context, seq: ($seq | tonumber)}' \
  > "${TMPFILE}"

# Atomic rename
mv "${TMPFILE}" "${SIGNAL_DIR}/${TASK_ID}.q${SEQ}.question"
```

```bash
# Answer write (same atomic pattern)
TMPFILE=$(mktemp "${SIGNAL_DIR}/.a-XXXXXX.tmp")
jq -n \
  --arg task_id    "${TASK_ID}" \
  --arg answer     "${ANSWER_TEXT}" \
  --arg decided_by "${DECIDED_BY}" \
  --arg seq        "${SEQ}" \
  '{task_id: $task_id, answer: $answer, decided_by: $decided_by,
    seq: ($seq | tonumber)}' \
  > "${TMPFILE}"
mv "${TMPFILE}" "${SIGNAL_DIR}/${TASK_ID}.q${SEQ}.answer"
```

### Signal Directory Initialization (SEC-005)

```bash
# Restricted permissions (SEC-005) — created in Phase 1 alongside existing signal dir setup
mkdir -m 700 -p "tmp/.rune-signals/rune-work-${TIMESTAMP}"
```

### TOCTOU Protection (FLAW-003)

When reading persistence files during compaction recovery, wrap reads in try/catch:

```javascript
// Orchestrator reads question files ONLY for compaction recovery
try {
  const qPath = `${signalDir}/${taskId}.q${seq}.question`
  const qContent = Read(qPath)           // throws if file doesn't exist
  const question = JSON.parse(qContent)  // throws if JSON is malformed
  // ... process recovery
} catch (e) {
  warn(`Question recovery failed for ${taskId}.q${seq}: ${e.message} — skipping`)
}
```

## Orchestrator: Question Detection in Polling Loop

The orchestrator receives worker questions via `SendMessage` (auto-delivered). Detection is
built into the Phase 3 polling loop — no additional polling is needed.

### 5-Second Fast-Path Signal Scan (ASYNC-004)

During the fast-path cycle (before TaskList), the orchestrator scans for unanswered `.question`
files as a compaction recovery mechanism only:

```javascript
// Fast-path: scan for unanswered .question files (compaction recovery)
// SEC-014 FIX: Remove (N) zsh qualifier — Glob() tool natively returns empty array on no match
const questionFiles = Glob(`${signalDir}/*.question`)
for (const qFile of questionFiles) {
  const baseName = qFile.split('/').pop()
  const answerFile = qFile.replace('.question', '.answer')
  const answerExists = Glob(answerFile).length > 0
  if (!answerExists) {
    // Unanswered question detected from persistence layer
    // This means compaction occurred while a question was pending
    // Re-surface to user as compaction recovery
    try {
      const question = JSON.parse(Read(qFile))
      // SEC-002: validate task_id from file content
      if (!/^[a-zA-Z0-9_-]+$/.test(question.task_id)) {
        warn(`Invalid task_id in question file ${qFile} — skipping`)
        continue
      }
      await relayQuestionToUser(question, signalDir)
    } catch (e) {
      warn(`Compaction recovery failed for ${qFile}: ${e.message}`)
    }
  }
}
```

### Question Cap Enforcement (SEC-006)

```javascript
// Track per-worker question counts in orchestrator state
const workerQuestionCounts = {}  // { workerName: number }

function onWorkerQuestion(workerName, taskId, question) {
  const cap = talisman?.question_relay?.max_questions_per_worker ?? 3  // SEC-006 FIX: define cap variable
  const count = (workerQuestionCounts[workerName] || 0) + 1
  if (count > cap) {
    // Cap exceeded — relay advisory to worker (not a hard block)
    SendMessage({
      type: "message",
      recipient: workerName,
      content: `ANSWER: Question cap exceeded (max ${cap} per worker). Make best-effort decision and mark as "assumed — needs review" in your Seal.
TASK: ${taskId}
DECIDED_BY: cap-exceeded`,
      summary: `Question cap exceeded for ${workerName}`
    })
    return
  }
  workerQuestionCounts[workerName] = count
  // ... process question normally
}
```

### Task Status Verification Before Surfacing (ASYNC-001, ASYNC-003)

```javascript
async function relayQuestionToUser(question, signalDir) {
  // Verify task is still active before presenting to user
  const tasks = TaskList()
  const task = tasks.find(t => t.id === question.task_id)

  if (!task || task.status !== 'in_progress') {
    warn(`Task ${question.task_id} is no longer in_progress (status: ${task?.status ?? 'not found'}) — discarding question`)
    return
  }

  // Surface to user
  const answer = await AskUserQuestion(
    `Worker question for task #${question.task_id}:\n\n${question.question}\n\nOptions:\n${question.options}\n\nContext: ${question.context}`,
    { timeout: talisman?.question_relay?.timeout_seconds ?? 180 }
  )

  const decidedBy = answer ? "user" : "auto-timeout"
  const answerText = answer ?? (question.options?.split(",")[0] ?? "proceed with best judgment")

  // Relay answer to worker
  SendMessage({
    type: "message",
    recipient: question.worker_name,
    content: `ANSWER: ${answerText}\nTASK: ${question.task_id}\nDECIDED_BY: ${decidedBy}`,
    summary: `Answer for task #${question.task_id} question`
  })

  // SEC-002: Validate task_id before file path construction
  if (!/^[a-zA-Z0-9_-]+$/.test(question.task_id)) {
    warn(`Invalid task_id ${question.task_id} — skipping answer persistence`)
    return
  }

  // Persist answer for compaction recovery (atomic write)
  // SEC-002 FIX: Write answer to temp file, then use jq --rawfile to avoid shell injection
  const seq = question.seq
  const answerTmpFile = `${signalDir}/.answer-content.tmp`
  Write(answerTmpFile, answerText)
  const tmpFile = Bash(`mktemp "${signalDir}/.a-XXXXXX.tmp"`).trim()
  Bash(`jq -n \
    --arg task_id    "${question.task_id}" \
    --rawfile answer "${answerTmpFile}" \
    --arg decided_by "${decidedBy}" \
    --arg seq        "${seq}" \
    '{task_id: $task_id, answer: $answer, decided_by: $decided_by, seq: ($seq | tonumber)}' \
    > "${tmpFile}" && mv "${tmpFile}" "${signalDir}/${question.task_id}.q${seq}.answer"`)
  Bash(`rm -f "${answerTmpFile}"`)
}
```

## Talisman Configuration

```yaml
question_relay:
  enabled: true                      # Master switch. Default: true
  timeout_seconds: 180               # Seconds to wait for user input. Default: 180
  poll_interval_seconds: 15          # Fast-path signal scan interval. Default: 15
  auto_answer_on_timeout: true       # Select option A when user doesn't respond. Default: true
  max_questions_per_worker: 3        # Cap per worker per task (SEC-006). Default: 3
```

**Talisman field reference** (used by strive SKILL.md Phase 3):

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `enabled` | bool | `true` | Disable to suppress all question relay (workers proceed on best-effort) |
| `timeout_seconds` | int | `180` | AskUserQuestion timeout before auto-answer |
| `poll_interval_seconds` | int | `15` | How often to scan signal dir in fast-path |
| `auto_answer_on_timeout` | bool | `true` | If false: worker blocks indefinitely until answered |
| `max_questions_per_worker` | int | `3` | Max questions per worker. Cap prevents runaway question spam |

## Security Summary

| Concern | Control |
|---------|---------|
| SEC-002: Path traversal via task_id | Validate `^[a-zA-Z0-9_-]+$` before ANY path construction |
| SEC-003: Shell injection in JSON writes | Use `jq -n --arg` exclusively — never inline interpolation |
| SEC-005: Signal dir permissions | `mkdir -m 700` on creation |
| SEC-006: Question spam | `max_questions_per_worker` cap (default: 3) |
| FLAW-003: TOCTOU on file read | Wrap all persistence file reads in try/catch |
| ASYNC-001: Stale task answer | Verify task is `in_progress` before surfacing question |
| ASYNC-002: Sequence collision | Monotonic per-task sequence counter in orchestrator memory |
| ARCH-004: Partial writes | `mktemp` + `mv` atomic rename for all persistence files |
