# Phase 7: Cleanup & Echo Persist

```javascript
// 1. Dynamic teammate discovery from team config
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
let allMembers = []
try {
  const teamConfig = JSON.parse(Read(`${CHOME}/teams/${teamName}/config.json`))
  const members = Array.isArray(teamConfig.members) ? teamConfig.members : []
  allMembers = members.map(m => m.name).filter(n => n && /^[a-zA-Z0-9_-]+$/.test(n))
} catch (e) {
  // FALLBACK: built-in Ashes + runebinder (safe to send shutdown to absent members)
  allMembers = ["forge-warden", "ward-sentinel", "pattern-weaver", "veil-piercer",
    "glyph-scribe", "knowledge-keeper", "codex-oracle", "runebinder"]
}
for (const member of allMembers) {
  SendMessage({ type: "shutdown_request", recipient: member, content: "Review complete" })
}

// 2. Grace period — let teammates deregister before TeamDelete
if (allMembers.length > 0) {
  Bash(`sleep 20`)
}

// 3. TeamDelete with retry-with-backoff (4 attempts: 0s, 5s, 10s, 15s — CLEANUP_DELAYS: [0, 5000, 10000, 15000])
//    On failure: process-level kill (SIGTERM→3s→SIGKILL) then filesystem fallback (CHOME pattern)

// 3.5. Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "appraise"`)

// 3.6. Update state file to "completed" (preserve config_dir, owner_pid, session_id)

// 4. Persist P1/P2 patterns to .claude/echoes/reviewer/MEMORY.md (if exists)

// 5. Read and present TOME.md to user

// 6. Auto-mend or interactive prompt based on findings
const autoMend = flags['--auto-mend'] || (talisman?.review?.auto_mend === true)
if (totalFindings > 0 && autoMend) {
  Skill("rune:mend", `tmp/reviews/${identifier}/TOME.md`)
} else if (totalFindings > 0) {
  AskUserQuestion({
    options: ["/rune:mend (Recommended)", "Review TOME manually", "/rune:rest"]
  })
} else {
  log("No P1/P2 findings. Codebase looks clean.")
}
```
