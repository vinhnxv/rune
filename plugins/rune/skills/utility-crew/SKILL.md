---
name: utility-crew
description: |
  Agent-based context composition and review system for Rune workflows.
  Manages the Utility Crew lifecycle: context-scribe composes per-teammate
  context packs, prompt-warden validates via 12-point checklist, and
  dispatch-herald tracks pack staleness across arc phases.
  Reduces team lead context consumption from O(N) to O(1) for spawning.

  Use when: Parent workflow needs to compose and validate spawn prompts
  for multiple teammates. Loaded automatically by appraise, audit, strive,
  and devise workflows when utility_crew.enabled is true.
  Keywords: utility crew, context pack, prompt composition, spawn prompt,
  context scribe, prompt warden, dispatch herald, pack validation.
user-invocable: false
disable-model-invocation: false
---

# Utility Crew — Agent Context Composition & Review System

Composes, validates, and manages per-teammate context packs via 3 specialized utility agents. Replaces inline prompt composition in the team lead's context with file-based handoff.

**Context load reduction**: ~4000*N tokens (inline) to ~600 tokens (fixed) for the lead.

## Distinction from utility-crew-extract.sh

The shell-based `utility-crew-extract.sh` script is a DIFFERENT system. It extracts lightweight digests from existing artifacts (condensing). The agent-based Utility Crew composes NEW context packs from templates and runtime data (composition). Both systems coexist — they serve different purposes.

## Talisman Configuration

Read via `readTalismanSection("settings")?.utility_crew` — the `utility_crew` namespace lives INSIDE the `settings` shard, not as a separate shard.

```yaml
utility_crew:
  enabled: true                    # Master gate (default: true)
  fallback_on_failure: true        # Fall back to inline composition on Crew failure
  context_scribe:
    timeout_ms: 90000              # Max time for scribe to compose all packs
    max_packs: 12                  # Safety cap on packs per invocation
  prompt_warden:
    enabled: true                  # Can disable review step (not recommended)
    block_on_critical: true        # BLOCK when critical checks fail
    warn_threshold: 2              # Number of HIGH issues before WARN
  dispatch_herald:
    enabled: true                  # Only relevant for arc/arc-batch
    staleness_check_ms: 30000     # Time budget for staleness check
```

## Crew Agents

| Agent | Model | maxTurns | Purpose |
|-------|-------|----------|---------|
| [context-scribe](../../agents/utility/context-scribe.md) | inherit | 30 | Compose context packs from templates + runtime data |
| [prompt-warden](../../agents/utility/prompt-warden.md) | haiku | 15 | Validate context packs via 12-point checklist |
| [dispatch-herald](../../agents/utility/dispatch-herald.md) | haiku | 10 | Track pack staleness across arc phases |

## spawnUtilityCrew(config)

Pseudo-function for parent workflows to invoke the Utility Crew. Called BEFORE spawning worker/reviewer teammates.

### Parameters

```
config = {
  workflow:          string    // "review"|"audit"|"strive"|"devise"|...
  identifier:        string    // Session identifier
  team_name:         string    // Current team name (Crew agents join this team)
  phase:             string    // Current workflow phase
  selected_agents:   string[]  // Agent names that need context packs
  talisman_shards:   string    // Path to tmp/.talisman-resolved/
  output_dir:        string    // Path to tmp/{workflow}/{id}/
  changed_files_path: string   // Path to changed file list
  plan_path:         string?   // Path to plan file (optional)
  inscription_path:  string?   // Path to inscription.json (optional)
  extra_context:     string?   // Free-form phase-specific notes (optional)
}
```

### Algorithm

```
1. Read talisman config:
   talisman = readTalismanSection("settings")
   crew_config = talisman?.utility_crew ?? { enabled: true }

2. Check master gate:
   IF NOT crew_config.enabled:
     RETURN { mode: "inline", reason: "utility_crew.enabled is false" }

3. Prepare context-packs directory:
   packs_dir = "{config.output_dir}/context-packs/"
   Ensure packs_dir exists (Write a placeholder if needed)

4. Compose Crew Request message:
   crew_request = format Crew Request from config parameters

5. Spawn context-scribe:
   Agent("context-scribe", team_name=config.team_name,
         prompt="Read your Crew Request via SendMessage. {crew_request}")

6. Wait for scribe completion:
   timeout = crew_config.context_scribe?.timeout_ms ?? 90000
   Poll TaskList every 30s until scribe completes or timeout reached
   IF timeout:
     GOTO fallback

7. Spawn prompt-warden (if enabled):
   IF crew_config.prompt_warden?.enabled !== false:
     Agent("prompt-warden", team_name=config.team_name,
           prompt="Validate context packs at {packs_dir}. Read manifest.json first.")
     Wait for warden completion (30s timeout)
     IF timeout:
       GOTO fallback

8. Read verdict:
   verdict = Read("{packs_dir}/verdict.json")
   Sanity checks:
     - recommendation is one of PROCEED/WARN/BLOCK
     - checks_passed <= checks_total
     - critical_blocks > 0 implies recommendation !== "PROCEED"

9. Decision gate:
   IF verdict.recommendation === "BLOCK" AND crew_config.prompt_warden?.block_on_critical:
     Log which checks failed (check_id + check_name from verdict.issues)
     GOTO fallback
   IF verdict.recommendation === "WARN":
     Log warning but continue

10. Shutdown Crew agents:
    SendMessage(type="shutdown_request", recipient="context-scribe")
    SendMessage(type="shutdown_request", recipient="prompt-warden")
    Sleep 10-15s for deregistration (free teammate slots before spawning workers)

11. Read manifest:
    manifest = Read("{packs_dir}/manifest.json")
    RETURN { mode: "crew", manifest: manifest, verdict: verdict }

fallback:
  Log warning with reason (timeout/BLOCK/error)
  Set crew_fallback: true in workflow state file
  Shutdown any active Crew agents
  RETURN { mode: "inline", reason: "{failure_reason}" }
```

### Spawn Prompt Modification

When Crew succeeds, modify teammate spawn prompts:

**Before (inline)**: Full prompt embedded in Agent() call (~4000 tokens per teammate)
**After (crew)**: `"Read your context from: {packs_dir}/{agent-name}.context.md. Start by reading that file."`

## refreshStalePacks(herald_report)

Pseudo-function for incremental pack refresh during arc workflows. Called when dispatch-herald reports staleness.

### Algorithm

```
1. Read herald_report (staleness-report.json)

2. IF herald_report.recommendation === "fresh":
   RETURN  // No refresh needed

3. Determine affected agents:
   affected = herald_report.affected_packs.map(p => p.agent)

4. Compose targeted Crew Request:
   Only include affected agents in selected_agents list

5. Re-invoke context-scribe for affected packs:
   Same spawnUtilityCrew flow but with reduced agent list

6. Re-invoke prompt-warden on refreshed packs

7. Update manifest.json with refreshed pack entries
```

## dispatch-herald Integration (arc only)

Between arc phases, spawn the dispatch-herald to check pack freshness:

```
1. Check talisman gate:
   IF NOT crew_config.dispatch_herald?.enabled:
     SKIP staleness check

2. Spawn dispatch-herald:
   Agent("dispatch-herald", team_name=team_name,
         prompt="Check staleness: context_packs_dir={packs_dir},
                 current_phase={next_phase}, previous_phase={completed_phase},
                 tome_path={tome_path}, plan_path={plan_path},
                 mend_round={mend_round}")

3. Wait for herald completion (staleness_check_ms timeout)

4. Read staleness-report.json

5. IF stale:
   refreshStalePacks(staleness_report)

6. Shutdown dispatch-herald
```

## Cleanup Integration

All 3 Crew agent names MUST be included in the parent workflow's shutdown fallback array:

```javascript
// Add to existing fallback arrays in Phase 6/7 cleanup
const crewAgents = ["context-scribe", "prompt-warden", "dispatch-herald"];
allMembers = [...existingMembers, ...crewAgents];
```

Safe because `shutdown_request` is a no-op for already-exited agents. dispatch-herald is only included in arc/arc-batch workflows.

## Fallback Behavior

When Crew fails (timeout, error, or BLOCK that cannot be resolved):

1. Log warning with reason to workflow state file
2. Set `crew_fallback: true` in state file for diagnostics
3. Fall back to existing inline prompt composition (zero-change to current code path)
4. The exact existing `buildAshPrompt()` / inline prompt code runs — no new behavior

**Zero regression guarantee**: When fallback activates, the identical pre-Crew code path executes.

## References

- [context-pack-schema.md](references/context-pack-schema.md) — Pack format, manifest, verdict schemas
- [review-checklist.md](references/review-checklist.md) — Detailed 12-point checklist with regex patterns
- [scribe-template-map.md](references/scribe-template-map.md) — Per-workflow template sources and variables
