# Phase Loop State File

> **Co-located (v2.6.0)**: This write is now embedded at the end of [arc-checkpoint-init.md](arc-checkpoint-init.md),
> immediately after the checkpoint `Write()` call. This reference file documents the schema
> for the state file. The SKILL.md "First Phase Invocation" section has a safety guard that
> recreates the file from checkpoint data if it is missing.

## Integrity Validation (v2.29.8)

The state file is validated at **three layers** to prevent LLM variable drift and cross-run contamination:

### Layer 1: Pre-Write Assertions (INTEG-INIT / INTEG-RESUME / INTEG-RECOVERY)
In `arc-checkpoint-init.md`, `arc-resume.md`, AND `SKILL.md` safety guard, assertions fire BEFORE `Write()`:
- `config_dir` must NOT be a `tmp/` path (must be CLAUDE_CONFIG_DIR)
- `owner_pid` must be non-empty and numeric
- `id` must match `arc-{timestamp}` format
- `checkpointPath` must use the same `id`
- `planFile` must not be empty/null
- `sessionId` must not be 'unknown'

**CRITICAL**: The SKILL.md recovery path resolves `config_dir` from `CLAUDE_CONFIG_DIR` directly — it does NOT trust `checkpoint.config_dir`. This prevents propagation of corrupt config_dir from a bad checkpoint.

### Layer 2: Post-Write Cross-Field Verification (INTEG-POST)
After `Write()`, reads back the state file and verifies every field matches the source variable.
Catches template interpolation bugs where `${configDir}` resolves to the wrong value.

### Layer 3: Runtime Validation (GUARD 5.8 + GUARD 8.5)
In `arc-phase-stop-hook.sh`, before processing:
- **GUARD 5.8**: `validate_state_file_integrity()` checks all 15 INTEG rules
- **GUARD 8.5**: `validate_checkpoint_json_integrity()` checks 6 CKPT-INT rules
On failure: writes diagnostic to `.rune/arc-integrity-failure.txt`, halts phase loop.

### Known Corruption Vectors (Root Cause)
| Vector | Example | Detection |
|--------|---------|-----------|
| LLM variable drift | `config_dir: tmp/arc/arc-123` instead of `/Users/x/.claude` | INTEG-001 |
| Cross-run mixing | checkpoint_path from run A, config_dir from run B | INTEG-011 |
| Empty session identity | `owner_pid:` (blank) | INTEG-004, INTEG-005 |
| Wrong checkpoint path | `.rune/arc-checkpoint.local.md` | INTEG-002, CKPT-001 |
| Partial cancel write | `user_cancelled: true` + `active: true` | INTEG-012 |
| Zombie loop | `stop_reason: context_limit` + `active: true` | INTEG-013 |
| Branch drift | State says `feat-x` but git on `main` | INTEG-014 |
| Cancel inconsistency | `cancel_reason` set but `user_cancelled: false` | INTEG-015 |

After checkpoint initialization (or resume), write the phase loop state file that drives `arc-phase-stop-hook.sh`:

```javascript
// Write the phase loop state file for the Stop hook driver.
// The Stop hook reads this file, finds the next pending phase in the checkpoint,
// and re-injects the phase-specific prompt with fresh context.
//
// CRITICAL: session_id MUST use SKILL.md substitution ("${CLAUDE_SESSION_ID}") as primary source.
// DO NOT use Bash('echo $CLAUDE_SESSION_ID') — it is NOT available in Bash tool context
// (anthropics/claude-code#25642). The SKILL.md preprocessor replaces ${CLAUDE_SESSION_ID}
// at skill load time, providing the real session ID without Bash.
const sessionId = "${CLAUDE_SESSION_ID}" || Bash('echo "${RUNE_SESSION_ID:-}"').trim()
if (!sessionId) {
  throw new Error('BIZL-002: session_id is required for session isolation — neither CLAUDE_SESSION_ID nor RUNE_SESSION_ID is available. Cannot create arc state file without session identity.')
}
// IRON LAW CKPT-001: checkpoint_path MUST be `.rune/arc/${id}/checkpoint.json`.
// Extension MUST be .json (JSON content requires .json extension — NEVER .md).
// NEVER use `.rune/arc-checkpoint.local.md` or any flat file path.
// The stop hook (GUARD 5.6) validates this format and auto-recovers non-canonical paths.
const stateContent = `---
active: true
iteration: 0
max_iterations: 66
checkpoint_path: .rune/arc/${id}/checkpoint.json
plan_file: ${planFile}
branch: ${branch}
arc_flags: ${args.replace(/\s+/g, ' ').trim()}
config_dir: ${configDir}
owner_pid: ${ownerPid}
session_id: ${sessionId}
compact_pending: false
user_cancelled: false
cancel_reason: null
cancelled_at: null
stop_reason: null
---
`
Write('.rune/arc-phase-loop.local.md', stateContent)
```

## Cross-Machine Migration

The phase-loop state file is **intentionally not committed**. The checkpoint (`.rune/arc/{id}/checkpoint.json`) is the only durable artifact shared across machines; the state file is hydrated on demand from the checkpoint at session start or resume.

This split exists because the state file includes three identity fields that are machine- or session-scoped:

- `owner_pid` — `$PPID` of the Claude Code process; different on every machine and every session.
- `config_dir` — resolved from `CLAUDE_CONFIG_DIR`; may vary between operator setups (e.g., `~/.claude-work` vs `~/.claude-personal`).
- `session_id` — the Claude Code runtime session identifier; unique per session.

If a state file was committed, the Stop hook on a second machine would read those foreign-owned fields, fail its ownership check, and silent-exit at GUARD 4 — leaving the arc pipeline frozen with no visible error.

### Hand-off lifecycle

1. **On the origin machine** — the orchestrator writes the state file atomically (via `rune-arc-init-state.sh create --source skill`) after writing the checkpoint. Fields: `owner_pid`, `config_dir`, `session_id` reflect the current machine. The state file never leaves `.rune/arc-phase-loop.local.md` (gitignored).
2. **On the destination machine** — after `git pull`, the state file is absent. The `SessionStart:resume` hook (v2.54.0+) calls `rune-arc-init-state.sh create --source session-start` to rebuild the file with the *destination* machine's identity. The checkpoint's `session_id` is **not** copied into the new state file — the resume pipeline rewrites it to the current session so subsequent Stop hook cycles see an `OWNED` state.

For the troubleshooting workflow (what `doctor` reports and which `create` flags to run), see [arc-resume.md](./arc-resume.md#cross-machine-migration).

### Why this is not a `/rune:arc-doctor` slash command

The child-2 plan (`2026-04-18-fix-arc-state-file-long-term-hardening-plan`, §"Open Questions") intentionally keeps diagnostics inside `rune-arc-init-state.sh doctor` rather than introducing a new top-level skill. Reasons: the command is a low-frequency operator tool (not a pipeline phase), it must run without a live team (hence no `/rune:*` wrapping), and it participates in the canary evidence gate (AC-4) via `arc-state-health.sh --canary-gate` — both tools are invoked from shell, not from the skill runtime.
