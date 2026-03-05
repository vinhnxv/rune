# Team Presets — Built-in Configuration Templates

> Each Rune workflow has a built-in team preset that defines its agent composition, team name prefix, cleanup config, and monitoring parameters. The SDK resolves presets at team creation time via `resolvePreset()`.

## Table of Contents

- [Resolution Order](#resolution-order)
- [Built-in Presets](#built-in-presets)
- [Custom Presets](#custom-presets)
- [Integration with createTeam()](#integration-with-createteam)

## Resolution Order

Preset resolution follows highest-priority-wins:

```
1. Explicit preset override (passed to createTeam())
2. talisman.yml → team.custom_presets[name]
3. Built-in preset (this file)
4. Error — unknown preset name
```

When a custom preset in `talisman.yml` shares a name with a built-in preset, the custom version wins completely (no merging).

## Built-in Presets

### 1. `review`

Standard code review via Roundtable Circle.

```yaml
preset: review
prefix: "rune-review"
default_mode: team
agents:
  always:
    - forge-warden        # Backend review (9 perspectives)
    - ward-sentinel       # Security review
    - pattern-weaver      # Quality patterns (8 perspectives)
    - veil-piercer        # Truth-telling review
  conditional:
    - glyph-scribe        # Frontend — when frontend files changed
    - knowledge-keeper    # Docs — when docs changed (>= 10 lines)
    - codex-oracle        # Cross-model — when codex CLI available
max_agents: 9             # 7 built-in + 2 custom (settings.max_ashes)
state_file: "tmp/.rune-review-{id}.json"
signal_dir: "tmp/.rune-signals/rune-review-{id}"
readonly: true            # SEC-001: .readonly-active marker written
cleanup:
  grace_period_s: 15
  retry_delays_ms: [0, 5000, 10000]
monitoring:
  timeoutMs: 600000       # 10 min
  staleWarnMs: 300000     # 5 min
  autoReleaseMs: null     # Findings are non-fungible
  pollIntervalMs: 30000
  label: "Review"
```

### 2. `work`

Swarm work execution via rune-smith and trial-forger workers.

```yaml
preset: work
prefix: "rune-work"
default_mode: team
agents:
  dynamic:
    - name: rune-smith
      role: implementation
      count: "talisman.work.max_workers ?? 3"
    - name: trial-forger
      role: testing
      count: "derived from task decomposition"
max_agents: "talisman.work.max_workers ?? 3"
state_file: "tmp/.rune-work-{id}.json"
signal_dir: "tmp/.rune-signals/rune-work-{id}"
readonly: false
cleanup:
  grace_period_s: 15
  retry_delays_ms: [0, 5000, 10000]
monitoring:
  timeoutMs: 1800000      # 30 min
  staleWarnMs: 300000     # 5 min
  autoReleaseMs: 600000   # 10 min — tasks are fungible
  pollIntervalMs: 30000
  label: "Work"
  onCheckpoint: true      # Milestone reporting enabled
```

### 3. `plan`

Multi-agent research and planning via devise.

```yaml
preset: plan
prefix: "rune-plan"
default_mode: team
agents:
  always:
    - repo-surveyor       # Local: codebase structure analysis
    - echo-reader         # Local: Rune Echoes history
    - git-miner           # Local: git log analysis
  conditional:
    - practice-seeker     # External: best-practice research (Context7)
    - lore-scholar        # External: framework docs (Context7)
    - codex-researcher    # External: cross-model research (codex CLI)
  post_research:
    - flow-seer           # Spec validation (always, runs after research)
max_agents: 7
state_file: "tmp/.rune-plan-{id}.json"
signal_dir: "tmp/.rune-signals/rune-plan-{id}"
readonly: true            # Research agents are read-only
cleanup:
  grace_period_s: 15
  retry_delays_ms: [0, 5000, 10000]
monitoring:
  timeoutMs: null         # No timeout — runs until all tasks complete
  staleWarnMs: 300000     # 5 min
  autoReleaseMs: null     # Research is non-fungible
  pollIntervalMs: 30000
  label: "Plan Research"
```

### 4. `fix`

Wave-based finding resolution from TOME.

```yaml
preset: fix
prefix: "rune-mend"
default_mode: team
wave_based: true
wave_size: 5              # Max fixers per wave
agents:
  dynamic: true           # Agents determined at runtime from TOME findings
  role: mend-fixer
  count: "min(finding_count, wave_size)"
state_file: "tmp/.rune-mend-{id}.json"
signal_dir: "tmp/.rune-signals/rune-mend-{id}"
readonly: false
cleanup:
  grace_period_s: 15
  retry_delays_ms: [0, 5000, 10000]
monitoring:
  timeoutMs: 900000       # 15 min (overridable by arc --timeout)
  staleWarnMs: 300000     # 5 min
  autoReleaseMs: 600000   # 10 min — fix tasks are fungible
  pollIntervalMs: 30000
  label: "Mend"
```

**Wave scheduling**: When `wave_based: true`, the orchestrator calls `waitForCompletion()` once per wave with that wave's timeout allocation. Signal files are cleared between waves. See [wave-scheduling.md](../../roundtable-circle/references/wave-scheduling.md).

### 5. `debug`

ACH-based parallel hypothesis investigation.

```yaml
preset: debug
prefix: "rune-debug"
default_mode: team
agents:
  dynamic: true           # Agents determined at runtime from hypothesis generation
  name: hypothesis-investigator
  count: "min(hypothesis_count, 5)"
state_file: "tmp/.rune-debug-{id}.json"
signal_dir: "tmp/.rune-signals/rune-debug-{id}"
readonly: true            # Investigators are read-only
cleanup:
  grace_period_s: 15
  retry_delays_ms: [0, 5000, 10000]
monitoring:
  timeoutMs: 600000       # 10 min
  staleWarnMs: 300000     # 5 min
  autoReleaseMs: null     # Each hypothesis is unique
  pollIntervalMs: 30000
  label: "Debug"
```

### 6. `audit`

Full codebase audit — delegates to Roundtable Circle with audit scope.

```yaml
preset: audit
prefix: "rune-audit"
default_mode: team
agents:
  dynamic: true           # Agents determined by Forge Gaze file classification
  source: "roundtable-circle Rune Gaze phase"
  always:
    - ward-sentinel       # Security always included
    - pattern-weaver      # Quality always included
    - veil-piercer        # Truth-telling always included
  conditional:
    - forge-warden        # When backend files in scope
    - glyph-scribe        # When frontend files in scope
    - knowledge-keeper    # When docs in scope
    - codex-oracle        # When codex CLI available
max_agents: 9
state_file: "tmp/.rune-audit-{id}.json"
signal_dir: "tmp/.rune-signals/rune-audit-{id}"
readonly: true            # SEC-001: .readonly-active marker written
cleanup:
  grace_period_s: 15
  retry_delays_ms: [0, 5000, 10000]
monitoring:
  timeoutMs: 900000       # 15 min
  staleWarnMs: 300000     # 5 min
  autoReleaseMs: null     # Audit findings are non-fungible
  pollIntervalMs: 30000
  label: "Audit"
```

## Custom Presets

Users can define custom presets in `talisman.yml`:

```yaml
# talisman.yml
team:
  custom_presets:
    my-preset:
      prefix: "rune-custom"
      agents:
        always:
          - forge-warden
          - ward-sentinel
      cleanup:
        grace_period_s: 20
        retry_delays_ms: [0, 5000, 10000]
      monitoring:
        timeoutMs: 600000
        staleWarnMs: 300000
        pollIntervalMs: 30000
        label: "Custom"
```

### Custom Preset Rules

1. **prefix** is required — must match `^[a-zA-Z0-9_-]+$` (SEC-4)
2. **agents** must reference registered agent names from [agent-registry.md](../../../references/agent-registry.md)
3. **cleanup** inherits defaults if omitted: `grace_period_s: 15`, `retry_delays_ms: [0, 5000, 10000]`
4. **monitoring** inherits from the closest built-in preset when fields are omitted
5. Custom presets cannot set `readonly: true` — only built-in review/audit/debug presets enforce SEC-001

## Integration with createTeam()

The `resolvePreset()` function is called during `createTeam()`:

```
function resolvePreset(presetName, talisman) {
  // 1. Check explicit override (caller-provided full config)
  // 2. Check talisman custom presets
  const custom = talisman?.team?.custom_presets?.[presetName]
  if (custom) return mergeWithDefaults(custom)

  // 3. Check built-in presets
  const builtin = BUILTIN_PRESETS[presetName]
  if (builtin) return builtin

  // 4. Unknown preset
  error(`Unknown preset: ${presetName}. Available: ${Object.keys(BUILTIN_PRESETS).join(", ")}`)
}
```

### Preset Fields Used by createTeam()

| Field | Used By | Purpose |
|-------|---------|---------|
| `prefix` | Team name generation | `{prefix}-{identifier}` |
| `agents` | Agent spawning | Which agents to summon |
| `max_agents` | Cap enforcement | Limits total teammate count |
| `state_file` | Session isolation | State file path template |
| `signal_dir` | Event-driven monitoring | Signal directory path template |
| `readonly` | SEC-001 enforcement | Whether to write `.readonly-active` marker |
| `cleanup` | Team teardown | Grace period and retry config |
| `monitoring` | waitForCompletion() | Timeout, stale detection, polling config |
| `wave_based` | Wave scheduling | Whether to use per-wave execution |
| `wave_size` | Wave scheduling | Max agents per wave |

### Cross-References

- [engines.md](engines.md) — TeamEngine uses presets for agent composition
- [protocols.md](protocols.md) — Cleanup protocol references preset `cleanup` config
- [monitor-utility.md](../../roundtable-circle/references/monitor-utility.md) — Per-command monitoring config (source of truth for timeout values)
- [agent-registry.md](../../../references/agent-registry.md) — Registered agent names
- [configuration-guide.md](../../../references/configuration-guide.md) — talisman.yml schema
