# readTalisman() — Canonical Definition

Reads talisman configuration with project-first, global-second fallback.

## Implementation

```javascript
// readTalisman: SDK Read() with project→global fallback. See references/read-talisman.md
function readTalisman() {
  // 1. Try project-level talisman (primary)
  try {
    const content = Read(".rune/talisman.yml")
    if (content) return parseYaml(content)
  } catch (_) { /* not found — fall through */ }

  // 1b. Legacy fallback: .claude/talisman.yml
  try {
    const content = Read(".claude/talisman.yml")
    if (content) return parseYaml(content)
  } catch (_) { /* not found — fall through */ }

  // 2. Try global talisman (CHOME pattern)
  //    SDK Read() auto-resolves CLAUDE_CONFIG_DIR and ~.
  //    NEVER use Bash("cat ~/.claude/talisman.yml") — tilde does not expand in ZSH eval.
  try {
    const globalPath = `${CLAUDE_CONFIG_DIR ?? HOME + "/.claude"}/talisman.yml`
    const content = Read(globalPath)
    if (content) return parseYaml(content)
  } catch (_) { /* not found — fall through */ }

  // 3. Empty fallback
  return {}
}
```

## Fallback Order

1. **Project**: `.rune/talisman.yml` (relative — SDK resolves to project root)
2. **Legacy fallback**: `.claude/talisman.yml` (for backward compatibility during migration)
3. **Global**: `$CHOME/talisman.yml` where `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`
4. **Empty**: `{}` on any error (file missing, parse failure, permission denied)

## CHOME Resolution (Bash contexts only)

If you must reference the global talisman path in a Bash command (e.g., for existence checks in hook scripts), always resolve `CHOME` first:

```bash
CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Correct:
test -f "$CHOME/talisman.yml"
# NEVER:
test -f ~/.claude/talisman.yml    # ~ does not expand in ZSH eval
cat ~/.claude/talisman.yml        # same problem
```

## Anti-Patterns

| Pattern | Problem | Fix |
|---------|---------|-----|
| `Bash("cat ~/.claude/talisman.yml")` | `~` not expanded in ZSH eval | Use `Read()` with CHOME pattern |
| `Bash("test -f ~/.claude/talisman.yml")` | Same tilde expansion bug | Use `Read()` with try/catch |
| `Bash("cat $HOME/.claude/talisman.yml")` | Works but unnecessary shell roundtrip | Use `Read()` — it's faster and safer |
| Hardcoded `~/.claude/` in any Bash context | ZSH incompatible | Use `CHOME` pattern or SDK `Read()` |

---

# readTalismanSection(section) — Shard-Aware Config Access

Reads a single config section from pre-resolved JSON shards. Falls back to `readTalisman()` when shards are unavailable.

**Why**: `readTalisman()` loads the entire talisman.yml (~1,200 tokens). Most consumers need only 1-2 sections. `readTalismanSection()` reads a pre-resolved JSON shard (~50-100 tokens), reducing per-phase token cost by ~94%.

**Prerequisite**: The `talisman-resolve.sh` SessionStart hook must have run. It produces shards in one of two locations:
- **Project-level**: `tmp/.talisman-resolved/{section}.json` — when user has `.rune/talisman.yml` or global `${CHOME}/talisman.yml`
- **System-level**: `${CHOME}/.rune/talisman-resolved/{section}.json` — defaults-only cache (no user talisman files)

## Implementation

```javascript
// readTalismanSection: shard-aware config. See references/read-talisman.md
function readTalismanSection(section) {
  // 1. Try project-level pre-resolved shard (fast path — user has talisman.yml)
  try {
    const shard = Read(`tmp/.talisman-resolved/${section}.json`)
    if (shard && shard.trim() !== '') return JSON.parse(shard)
  } catch (_) { /* shard missing or parse error — fall through */ }

  // 2. Try system-level pre-resolved shard (defaults-only cache)
  try {
    const chome = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
    const sysShard = Read(`${chome}/.rune/talisman-resolved/${section}.json`)
    if (sysShard && sysShard.trim() !== '') return JSON.parse(sysShard)
  } catch (_) { /* system shard missing — fall through */ }

  // 3. Fallback: read full talisman and extract section
  const full = readTalisman()

  // Composite shards: bundle multiple top-level keys
  if (section === "gates") {
    return {
      elicitation: full?.elicitation ?? {},
      horizon: full?.horizon ?? {},
      evidence: full?.evidence ?? {},
      doubt_seer: full?.doubt_seer ?? {}
    }
  }
  if (section === "settings") {
    return {
      version: full?.version,
      cost_tier: full?.cost_tier ?? "balanced",
      settings: full?.settings ?? {},
      defaults: full?.defaults ?? {},
      "rune-gaze": full?.["rune-gaze"] ?? {},
      ashes: full?.ashes ?? {},
      echoes: full?.echoes ?? {}
    }
  }
  if (section === "misc") {
    return {
      debug: full?.debug ?? {},
      mend: full?.mend ?? {},
      design_sync: full?.design_sync ?? {},
      stack_awareness: full?.stack_awareness ?? {},
      question_relay: full?.question_relay ?? {},
      file_todos: full?.file_todos ?? {},
      context_monitor: full?.context_monitor ?? {},
      context_weaving: full?.context_weaving ?? {},
      codex_review: full?.codex_review ?? {},
      teammate_lifecycle: full?.teammate_lifecycle ?? {},
      inner_flame: full?.inner_flame ?? {},
      solution_arena: full?.solution_arena ?? {},
      arc_hierarchy: full?.arc_hierarchy ?? {},
      schema_drift: full?.schema_drift ?? {},
      deployment_verification: full?.deployment_verification ?? {}
    }
  }

  // Direct sections: 1:1 mapping to top-level talisman key
  return full?.[section] ?? {}
}
```

## Section Names (13 total)

| Section | Top-level keys | Common consumers |
|---------|---------------|------------------|
| `arc` | arc.defaults, arc.ship, arc.pre_merge_checks, arc.timeouts, arc.sharding, arc.batch, arc.gap_analysis, arc.consistency | arc-checkpoint-init, arc-preflight, arc-phase-constants, gap-analysis |
| `codex` | codex.* | arc-codex-phases, goldmask, codex-review, solution-arena |
| `discipline` | discipline.* | validate-discipline-proofs, validate-context-isolation, work-loop-convergence, discipline-work-loop, pre-ship-validator |
| `review` | review.* | review-scope, parse-tome, appraise |
| `work` | work.* | strive, ship-phase, rune-smith, trial-forger |
| `goldmask` | goldmask.* | goldmask/SKILL.md |
| `plan` | plan.* | freshness-gate, verification-gate, ward-check |
| `gates` | elicitation, horizon, evidence, doubt_seer | ash-summoning, plan-review, brainstorm, deep-mode, tome-aggregation |
| `settings` | version, cost_tier, settings, defaults, rune-gaze, ashes, echoes | cost-tier-mapping, rune-gaze |
| `inspect` | inspect.* | inspect/SKILL.md |
| `testing` | testing.* | testing pipeline |
| `audit` | audit.* | audit/SKILL.md |
| `misc` | debug, mend, design_sync, stack_awareness, question_relay, file_todos, context_monitor, context_weaving, codex_review, teammate_lifecycle, inner_flame, solution_arena, arc_hierarchy, schema_drift, deployment_verification | debug, mend, design-sync, and other low-frequency consumers |

**Reserved**: `misc` is a reserved shard name for all low-frequency top-level keys that don't warrant individual shards.

## Composite Shards

Two sections bundle multiple top-level talisman keys:

- **`gates`** — Feature gates that control optional pipeline stages: `elicitation`, `horizon`, `evidence`, `doubt_seer`. These are frequently accessed as boolean checks (`?.enabled !== false`).
- **`misc`** — Low-frequency config sections: `debug`, `mend`, `design_sync`, `stack_awareness`, `question_relay`, `file_todos`, `context_monitor`, `context_weaving`, `codex_review`, `teammate_lifecycle`, `inner_flame`, `solution_arena`, `arc_hierarchy`, `schema_drift`, `deployment_verification`.

## Usage Examples

### Direct section (1:1 mapping)

```javascript
// readTalismanSection: "arc"
const arc = readTalismanSection("arc")
const noForge = arc?.defaults?.no_forge ?? false
const timeouts = arc?.timeouts ?? {}
```

### Composite section (gates)

```javascript
// readTalismanSection: "gates"
const gates = readTalismanSection("gates")
const elicitEnabled = gates?.elicitation?.enabled !== false
const horizonEnabled = gates?.horizon?.enabled !== false
const evidenceEnabled = gates?.evidence?.enabled !== false
const doubtSeerEnabled = gates?.doubt_seer?.enabled === true
```

### Cross-section access (multiple reads)

```javascript
// readTalismanSection: "arc", "work"
const arc = readTalismanSection("arc")
const work = readTalismanSection("work")
const arcDefaults = arc?.defaults
const coAuthors = work?.co_authors
```

### Composite section (misc)

```javascript
// readTalismanSection: "misc"
const misc = readTalismanSection("misc")
const debugConfig = misc?.debug
const designSyncEnabled = misc?.design_sync?.enabled
```

## Comment Annotation Convention

Every call site MUST include a comment annotation above the call listing the section(s) read. This enables `grep` audits:

```javascript
// readTalismanSection: "arc"
const arc = readTalismanSection("arc")

// readTalismanSection: "gates"
const gates = readTalismanSection("gates")

// readTalismanSection: "arc", "work"
const arc = readTalismanSection("arc")
const work = readTalismanSection("work")
```

**Audit command**: `grep -rn 'readTalismanSection' plugins/rune/` should list all shard consumers.

## Fallback Behavior

1. **Shard exists**: Read JSON from `tmp/.talisman-resolved/{section}.json` (fast, ~50-100 tokens)
2. **Shard missing**: Fall back to `readTalisman()` and extract the section (full ~1,200 tokens)
3. **Both fail**: Return `{}` (safe empty default)

Shards are regenerated on every `SessionStart` (startup, resume). If shards are stale or missing (e.g., mid-session talisman edit), the fallback path ensures correctness.

## Migration Pattern

When migrating from `readTalisman()` to `readTalismanSection()`:

```javascript
// BEFORE:
const talisman = readTalisman()
const enabled = talisman?.review?.diff_scope?.enabled

// AFTER:
// readTalismanSection: "review"
const review = readTalismanSection("review")
const enabled = review?.diff_scope?.enabled
```

For composite shards:
```javascript
// BEFORE:
const elicitEnabled = readTalisman()?.elicitation?.enabled !== false

// AFTER:
// readTalismanSection: "gates"
const gates = readTalismanSection("gates")
const elicitEnabled = gates?.elicitation?.enabled !== false
```

**Rules**:
1. Add comment annotation above each call
2. Eliminate duplicate reads within the same file
3. Check variable scope — if file uses multiple sections, make separate `readTalismanSection()` calls
4. Do NOT change any logic — only the read mechanism

## Companion File Merge

The resolver supports an optional 3-file split layout where configuration is distributed across companion files:

- `.rune/talisman.yml` — main config (always loaded)
- `.rune/talisman.ashes.yml` — agent registry sections (optional)
- `.rune/talisman.integrations.yml` — external tool sections (optional)

Companion files are discovered alongside their parent `talisman.yml` and merged into the same layer BEFORE the `defaults < global < project` merge. This means:

1. The shard layer sees a single unified JSON regardless of source file count
2. `readTalismanSection()` works identically whether config is in one file or three
3. No consumer code changes are needed — the abstraction boundary is at the resolver level

Companion files that don't exist are silently skipped. Empty companions are treated as `{}`. Duplicate top-level keys across main and companion files in the same layer produce an error (companion skipped, main preserved).

## Cross-References

- [chome-pattern skill](../skills/chome-pattern/SKILL.md) — full CLAUDE_CONFIG_DIR resolution guide
- [zsh-compat skill](../skills/zsh-compat/SKILL.md) — ZSH shell compatibility patterns
- [configuration-guide.md](configuration-guide.md) — talisman.yml schema and defaults
- [talisman-sections.md](../skills/talisman/references/talisman-sections.md) — section map and companion file layout
- `scripts/talisman-resolve.sh` — SessionStart hook that generates JSON shards
- `scripts/talisman-defaults.json` — Build-time defaults registry
