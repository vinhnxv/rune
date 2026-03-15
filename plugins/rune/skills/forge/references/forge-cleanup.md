# Phase 6: Cleanup & Present

Shuts down all forge teammates, cleans up team resources, updates state file, presents completion report, and offers post-enhancement options.

**Inputs**: `timestamp`, `planPath`, `startedTimestamp`, `configDir`, `ownerPid`, `isArcContext`, `allMembers` (from team config)
**Outputs**: Updated state file (status: "completed"), completion report
**Preconditions**: Phase 5 (merge enrichments) complete

## Teammate Fallback Array

```javascript
// FALLBACK: config.json read failed — use exhaustive list of all possible forge agents.
// Includes: topic agents (from forge-gaze selection) + elicitation sages (up to 6).
// Safe to send shutdown_request to absent members — SendMessage is a no-op for unknown names.
allMembers = [
  // Topic agents (forge-gaze assigns from the full review agent pool)
  "rune-architect", "pattern-seer", "ward-sentinel", "flaw-hunter",
  "ember-oracle", "simplicity-warden", "depth-seer", "tide-watcher",
  "blight-seer", "wraith-finder", "void-analyzer", "mimic-detector",
  "forge-keeper", "type-warden", "trial-oracle", "assumption-slayer",
  "reality-arbiter", "entropy-prophet", "senior-engineer-reviewer",
  "phantom-checker", "refactor-guardian", "reference-validator",
  // Elicitation sages (up to MAX_FORGE_SAGES=6, indexed by section)
  "elicitation-sage-0", "elicitation-sage-1", "elicitation-sage-2",
  "elicitation-sage-3", "elicitation-sage-4", "elicitation-sage-5"
]
```

## Protocol

Follow standard shutdown from [engines.md](../../team-sdk/references/engines.md#shutdown).

## Post-Cleanup

```javascript
// Validate identifier before rm -rf
if (!/^[a-zA-Z0-9_-]+$/.test(timestamp)) throw new Error("Invalid forge identifier")

// FIX: Kill orphaned bare agent processes (lore-analyst, research agents)
// Bare agents spawned with run_in_background: true have no team, so
// SendMessage(shutdown_request) cannot reach them. Process-level kill
// is the only cleanup mechanism. Same pattern as engines.md step 5a.
const cleanupOwnerPid = Bash(`echo $PPID`).trim()
if (cleanupOwnerPid && /^\d+$/.test(cleanupOwnerPid)) {
  Bash(`for pid in $(pgrep -P ${cleanupOwnerPid} 2>/dev/null); do case "$(ps -p "$pid" -o comm= 2>/dev/null)" in node|claude|claude-*) kill -TERM "$pid" 2>/dev/null ;; esac; done`)
}

// Release workflow lock
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_release_lock "forge"`)

// Update state file to completed (preserve session identity)
Write(`tmp/.rune-forge-${timestamp}.json`, {
  team_name: `rune-forge-${timestamp}`,
  plan: planPath,
  started: startedTimestamp,
  status: "completed",
  completed: new Date().toISOString(),
  config_dir: configDir,
  owner_pid: ownerPid,
  session_id: "${CLAUDE_SESSION_ID}" || Bash(`echo "\${RUNE_SESSION_ID:-}"`).trim()
})
```

## Completion Report

```
The Tarnished has tempered the plan in forge fire.

Plan: {planPath}
Backup: tmp/forge/{timestamp}/original-plan.md
Sections enriched: {enrichedCount}/{totalSections}
Agents summoned: {agentCount}
Mode: {default|exhaustive}

Enrichments added:
- "Technical Approach" — rune-architect, pattern-seer, simplicity-warden
- "Security Requirements" — ward-sentinel, flaw-hunter
- ...
```

## Post-Enhancement Options

After presenting the completion report, offer next steps. **Skipped in arc context** — arc continues to Phase 2 (plan review) automatically.

```javascript
if (!isArcContext) {
  AskUserQuestion({
    questions: [{
      question: `Plan enriched at ${planPath}. What would you like to do next?`,
      header: "Next step",
      options: [
        { label: "/rune:strive (Recommended)", description: "Start implementing this plan with swarm workers" },
        { label: "View diff", description: "Show what the forge changed (diff against backup)" },
        { label: "Revert enrichment", description: "Restore the original plan from backup" },
        { label: "Deepen sections", description: "Re-run forge on specific sections for more depth" }
      ],
      multiSelect: false
    }]
  })
}
// In arc context: cleanup team and return — arc orchestrator handles next phase
```

**Action handlers**:
- `/rune:strive` → Invoke `Skill("rune:strive", planPath)`
- **View diff** → `Bash(\`diff -u "tmp/forge/{timestamp}/original-plan.md" "${planPath}" || true\`)` — display unified diff of all changes
- **Revert enrichment** → `Bash(\`cp "tmp/forge/{timestamp}/original-plan.md" "${planPath}"\`)` — restore original, confirm to user
- **Deepen sections** → Ask which sections to re-deepen via AskUserQuestion, then re-run Phase 2-5 targeting only those sections (reuse same `timestamp` and backup)
