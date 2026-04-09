# Phase 2: Forge Team

```javascript
// 0. Construct session-scoped identifier (prevents team name collision across sessions)
const gitHash = Bash(`git rev-parse --short HEAD`).trim()
const shortSession = ("${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()).slice(0, 8)
const identifier = `${gitHash}-${shortSession}`
// Result: e.g., "abc1234-a1b2c3d4" → team name "rune-review-abc1234-a1b2c3d4"

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
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim(),
  expected_files: selectedAsh.map(r => `tmp/reviews/${identifier}/${r}.md`)
})

// 4. Generate inscription.json — includes diff_scope, context_intelligence, linter_context, context_map
// See roundtable-circle/references/inscription-schema.md

// 5. Pre-create guard: teamTransition protocol (see team-sdk/references/engines.md)
//    STEP 1: Validate identifier (/^[a-zA-Z0-9_-]+$/)
//    STEP 2: TeamDelete with retry-with-backoff (3 attempts: delays [0s, 3s, 8s])
//    STEP 3: Filesystem fallback if TeamDelete failed (QUAL-012 gate: !teamDeleteSucceeded)
//    STEP 4: TeamCreate with "Already leading" catch-and-recover (idempotent)
//    STEP 5: Post-create verification (read config.json to confirm team exists)

// 6. Create signal dir for event-driven sync
const signalDir = `tmp/.rune-signals/rune-review-${identifier}`
Bash(`mkdir -p "${signalDir}" && find "${signalDir}" -mindepth 1 -delete`)
Write(`${signalDir}/.expected`, String(selectedAsh.length))

// Signal file format: {task_id}.signal containing completion timestamp
// Example: forge-warden.signal → "2026-03-07T02:30:00Z"
// Enables 5-second completion detection via TaskCompleted hook
// The .expected file tracks total expected signals for completion tracking

// 7. Create tasks (one per Ash)
for (const ash of selectedAsh) {
  TaskCreate({
    subject: `Review as ${ash}`,
    description: `Files: [...], Output: tmp/reviews/{identifier}/${ash}.md`,
    activeForm: `${ash} reviewing...`
  })
}
```

## Inscription Contract

The inscription.json written in Phase 2 contains all data needed for Ash spawning and output validation:

```javascript
// inscription.json — full schema
{
  workflow: "rune-review",
  timestamp: timestamp,
  team_name: "rune-review-{identifier}",
  output_dir: `tmp/reviews/${identifier}/`,
  diff_scope: diffScope,                    // File paths with line ranges for Phase 5.3 scope tagging
  context_intelligence: contextIntel,       // PR metadata, linked issues from Phase 0.3
  linter_context: linterContext,            // Discovered linters from Phase 0.4
  risk_map: riskMap,                        // From Phase 0.5 Lore Layer (if enabled)
  context_map: contextMap || null,          // From Phase 0.6 Context Building (if enabled)
  verification: {                           // For Phase 5.5 cross-model verification
    enabled: true,
    fuzzy_match_threshold: 0.7
  },
  expected_files: [                         // Output validation: each Ash's expected output path
    "tmp/reviews/{identifier}/forge-warden.md",
    "tmp/reviews/{identifier}/ward-sentinel.md",
    // ... one per Ash
  ],
  teammates: selectedAsh.map(name => ({
    name: name,
    output_file: `${name}.md`
  }))
}
```

**Output validation**: The `expected_files` array enables Phase 4 Monitor to track completion and Phase 7 Cleanup to verify all expected outputs exist.
