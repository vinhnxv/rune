# Phase 2: Forge Team

```javascript
// 0. Construct session-scoped identifier (prevents team name collision across sessions)
const gitHash = Bash(`git rev-parse --short HEAD`).trim()
const shortSession = "${CLAUDE_SESSION_ID}".slice(0, 4)
const identifier = `${gitHash}-${shortSession}`
// Result: e.g., "abc1234-a1b2" → team name "rune-review-abc1234-a1b2"

// 1. Check for concurrent review (tmp/.rune-review-{identifier}.json < 30 min old → abort)

// 2. Create output directory
Bash("mkdir -p tmp/reviews/{identifier}")

// 3. Write state file with session isolation fields
const configDir = Bash(`cd "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null && pwd -P`).trim()
const ownerPid = Bash(`echo $PPID`).trim()
Write("tmp/.rune-review-{identifier}.json", {
  team_name: "rune-review-{identifier}",
  started: timestamp,
  status: "active",
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}",
  expected_files: selectedAsh.map(r => `tmp/reviews/${identifier}/${r}.md`)
})

// 4. Generate inscription.json — includes diff_scope, context_intelligence, linter_context
// See roundtable-circle/references/inscription-schema.md

// 5. Pre-create guard: teamTransition protocol (see team-sdk/references/engines.md)
//    STEP 1: Validate identifier (/^[a-zA-Z0-9_-]+$/)
//    STEP 2: TeamDelete with retry-with-backoff (3 attempts: 0s, 3s, 8s)
//    STEP 3: Filesystem fallback if TeamDelete failed (CDX-003 gate: !teamDeleteSucceeded)
//    STEP 4: TeamCreate with "Already leading" catch-and-recover
//    STEP 5: Post-create verification (config.json exists)

// 6. Create signal dir for event-driven sync
const signalDir = `tmp/.rune-signals/rune-review-${identifier}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(selectedAsh.length))

// 7. Create tasks (one per Ash)
for (const ash of selectedAsh) {
  TaskCreate({
    subject: `Review as ${ash}`,
    description: `Files: [...], Output: tmp/reviews/{identifier}/${ash}.md`,
    activeForm: `${ash} reviewing...`
  })
}
```
