# Phase Loop State File

> **Co-located (v2.6.0)**: This write is now embedded at the end of [arc-checkpoint-init.md](arc-checkpoint-init.md),
> immediately after the checkpoint `Write()` call. This reference file documents the schema
> for the state file. The SKILL.md "First Phase Invocation" section has a safety guard that
> recreates the file from checkpoint data if it is missing.

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
const sessionId = "${CLAUDE_SESSION_ID}" || Bash('echo "${RUNE_SESSION_ID:-}"').trim() || 'unknown'
const stateContent = `---
active: true
iteration: 0
max_iterations: 65
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
