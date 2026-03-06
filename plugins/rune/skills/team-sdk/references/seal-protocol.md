# Seal Completion Protocol

> Standardized completion messages sent by teammates to the team lead when finishing work. Every teammate MUST emit a Seal as their LAST action before going idle.

## Overview

A Seal is a structured completion summary that tells the team lead exactly what happened, what files were touched, and whether quality checks passed. Seals enable deterministic completion detection and progress tracking.

### Lifecycle Position

```
TaskUpdate(completed) → Seal (SendMessage) → idle/exit
```

**Critical ordering**: `TaskUpdate({ status: "completed" })` MUST happen BEFORE the Seal message. The Seal is the LAST action a teammate takes.

### Delivery Method

| Context | Method | Recipient |
|---------|--------|-----------|
| Agent Teams (SendMessage available) | `SendMessage({ type: "message", recipient: "team-lead", ... })` | `team-lead` |
| Subagent context (no SendMessage) | `<seal>TAG</seal>` tag in output | Orchestrator reads output file |

When both are available, prefer `SendMessage`. The `<seal>` tag variant is for subagents that lack access to `SendMessage`.

## Seal Variants

Four Seal variants cover all Rune workflow types. Each variant shares a common structure with workflow-specific fields.

### Common Fields

| Field | Required | Values | Description |
|-------|----------|--------|-------------|
| Status | Yes | `done`, `failed`, `partial` | Final outcome |
| Inner-flame | Yes | `pass`, `fail`, `partial` | Self-review result (3-layer check) |
| Summary | Yes | 1 sentence, max 50 words | Top-level outcome description |

### Status Definitions

| Status | Meaning | When to use |
|--------|---------|-------------|
| `done` | All assigned work completed successfully | Task fully finished, all checks pass |
| `failed` | Work could not be completed | Blocking error, missing dependencies, unresolvable issue |
| `partial` | Some work completed, some remains | Timeout, partial coverage, non-critical failures |

---

### 1. Work Seal

Used by implementation workers (strive, forge, mend-fixer, gap-fixer, resolve-fixer).

```
Seal: task #{id} {done|failed|partial} | {status}
Files: {file1}, {file2}
Ward: {pass|fail|skip}
Inner-flame: {pass|fail|partial}
Summary: {1-sentence}
```

**Optional fields** (append when available):

```
Branch: {name}
Tests: {pass}/{total}
Confidence: {0-100}
```

**Field descriptions:**

| Field | Description |
|-------|-------------|
| `task #{id}` | Task ID from TaskList |
| `status` | Brief status label (e.g., "implemented", "refactored") |
| `Files` | Comma-separated list of modified files |
| `Ward` | Whether tests/linting passed (`pass`), failed (`fail`), or were skipped (`skip`) |
| `Inner-flame` | Self-review protocol result |
| `Branch` | Git branch name (if applicable) |
| `Tests` | Test pass count / total count |
| `Confidence` | Self-assessed confidence score (0-100) |

**Example:**

```
Seal: task #3 done | implemented
Files: src/auth.ts, src/auth.test.ts
Ward: pass
Inner-flame: pass
Summary: Added JWT refresh token rotation with 7-day expiry.
Tests: 12/12
Confidence: 95
```

---

### 2. Review Seal

Used by review Ashes (appraise, audit, code-review workflows).

```
Seal: {agent-name} {done|failed|partial} | {dimension}
Findings: {total} ({P1} P1, {P2} P2, {P3} P3)
Output: {output_path}
Inner-flame: {pass|fail|partial}
Summary: {1-sentence top finding}
```

**Field descriptions:**

| Field | Description |
|-------|-------------|
| `{agent-name}` | Ash name (e.g., `truth-teller`, `rot-seeker`) |
| `{dimension}` | Review dimension (e.g., `correctness`, `security`, `performance`) |
| `Findings` | Total count with priority breakdown (P1=critical, P2=important, P3=minor) |
| `Output` | Path to TOME output file |
| `Inner-flame` | Self-review protocol result |
| `Summary` | Most important finding in one sentence |

**Example:**

```
Seal: truth-teller done | correctness
Findings: 5 (1 P1, 2 P2, 2 P3)
Output: tmp/review/1709876543/truth-teller.md
Inner-flame: pass
Summary: Unchecked null dereference in payment handler on line 142.
```

---

### 3. Research Seal

Used by research agents (lore-scholar, practice-seeker, plan researchers).

```
Seal: {agent-name} {done|failed|partial}
Output: {output_path}
Inner-flame: {pass|fail|partial}
Summary: {1-sentence, max 50 words}
```

**Field descriptions:**

| Field | Description |
|-------|-------------|
| `{agent-name}` | Research agent name |
| `Output` | Path to research output file |
| `Inner-flame` | Self-review protocol result |
| `Summary` | Key finding or conclusion (max 50 words) |

**Example:**

```
Seal: lore-scholar done
Output: tmp/plan/1709876543/lore-scholar.md
Inner-flame: pass
Summary: Found 3 existing auth patterns in codebase, recommends JWT with httpOnly cookies.
```

---

### 4. Mend Seal

Used by mend-fixer agents resolving TOME findings.

```
Seal: mend-fixer {done|failed|partial} | {task_id}
Fixed: {count} | False-positive: {count} | Failed: {count} | Skipped: {count}
Files: {file_list}
Inner-flame: {pass|fail|partial}
Summary: {1-sentence}
```

**Field descriptions:**

| Field | Description |
|-------|-------------|
| `{task_id}` | Mend task identifier |
| `Fixed` | Number of findings successfully resolved |
| `False-positive` | Number of findings identified as false positives |
| `Failed` | Number of findings that could not be fixed |
| `Skipped` | Number of findings intentionally skipped |
| `Files` | Comma-separated list of modified files |
| `Inner-flame` | Self-review protocol result |

**Example:**

```
Seal: mend-fixer done | task-3
Fixed: 4 | False-positive: 1 | Failed: 0 | Skipped: 0
Files: src/auth.ts, src/db.ts, src/utils.ts
Inner-flame: pass
Summary: Resolved 4 P2 findings including SQL injection and missing input validation.
```

## Common Rules

1. **Recipient**: Always `"team-lead"` for SendMessage-based Seals.
2. **Summary field**: Every Seal variant MUST include a `Summary` line.
3. **TaskUpdate before Seal**: Call `TaskUpdate({ taskId, status: "completed" })` BEFORE sending the Seal.
4. **Seal is LAST action**: No tool calls or messages after the Seal.
5. **Inner-flame is mandatory**: Every Seal MUST include `Inner-flame`. See [inner-flame](../../inner-flame/SKILL.md) for the 3-layer self-review protocol.
6. **Status accuracy**: Use `done` only when ALL assigned work is complete. Use `partial` for incomplete work, `failed` for blocked work.

## Dual Seal — SendMessage vs Tag

| Mechanism | Format | When |
|-----------|--------|------|
| SendMessage | Structured fields as message content | Agent Teams with SendMessage access |
| `<seal>` tag | `<seal>DONE</seal>` as last line of output file | Subagent context without SendMessage |

The `<seal>` tag is detected by `on-teammate-idle.sh` for completion validation. The tag value is one of: `DONE`, `FAILED`, `PARTIAL`.

When using SendMessage, the full structured Seal (with all fields) goes in the `content` parameter. The `summary` parameter gets a 5-10 word preview.

```javascript
// SendMessage Seal example
SendMessage({
  type: "message",
  recipient: "team-lead",
  content: "Seal: task #3 done | implemented\nFiles: src/auth.ts\nWard: pass\nInner-flame: pass\nSummary: Added JWT refresh token rotation.",
  summary: "Seal: task #3 done"
})
```

## Cross-References

- [inner-flame](../../inner-flame/SKILL.md) — 3-layer self-review protocol (Grounding, Completeness, Self-Adversarial)
- [monitoring.md](monitoring.md) — Signal-based completion detection using Seals
- [protocols.md](protocols.md) — Session isolation and handle serialization
