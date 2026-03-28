# Phase Loop State File

> **Co-located (v2.6.0)**: This write is now embedded at the end of [arc-checkpoint-init.md](arc-checkpoint-init.md),
> immediately after the checkpoint `Write()` call. This reference file documents the schema
> for the state file. The SKILL.md "First Phase Invocation" section has a safety guard that
> recreates the file from checkpoint data if it is missing.

## Integrity Validation (v2.29.8)

The state file is validated at **three layers** to prevent LLM variable drift and cross-run contamination:

### Layer 1: Pre-Write Assertions (INTEG-INIT / INTEG-RESUME)
In `arc-checkpoint-init.md` and `arc-resume.md`, assertions fire BEFORE `Write()`:
- `config_dir` must NOT be a `tmp/` path (must be CLAUDE_CONFIG_DIR)
- `owner_pid` must be non-empty and numeric
- `id` must match `arc-{timestamp}` format
- `checkpointPath` must use the same `id`
- `planFile` must not be empty/null
- `sessionId` must not be 'unknown'

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
