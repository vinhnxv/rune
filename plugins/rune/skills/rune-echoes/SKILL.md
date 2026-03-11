---
name: rune-echoes
description: |
  Use when agents need to read or write project memory, when persisting learnings from
  reviews or audits, when managing echo lifecycle (prune, reset), when a user wants to
  remember something explicitly, or when a pattern keeps recurring across sessions.
  Stores knowledge in .claude/echoes/ with 5-tier lifecycle
  (Etched/Notes/Inscribed/Observations/Traced) and multi-factor pruning.

  <example>
  Context: After a review, Ash persist patterns to echoes
  user: "Review found repeated N+1 query pattern"
  assistant: "Pattern persisted to .claude/echoes/reviewer/MEMORY.md as Inscribed entry"
  </example>
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# Rune Echoes — Smart Memory Lifecycle

Project-level agent memory that compounds knowledge across sessions. Each workflow writes learnings to `.claude/echoes/`, and future workflows read them to avoid repeating mistakes.

> "The Tarnished collects runes to grow stronger. Each engineering session should do the same."

## Architecture

### Memory Directory Structure

```
.claude/echoes/
├── planner/
│   ├── MEMORY.md              # Active memory (150 line limit)
│   ├── knowledge.md           # Compressed learnings (on-demand load)
│   └── archive/               # Pruned memories (never auto-loaded)
├── workers/
│   └── MEMORY.md
├── reviewer/
│   ├── MEMORY.md
│   ├── knowledge.md
│   └── archive/
├── auditor/
│   └── MEMORY.md
├── notes/
│   └── MEMORY.md              # User-explicit memories (never auto-pruned)
├── observations/
│   └── MEMORY.md              # Agent-observed patterns (auto-promoted)
└── team/
    └── MEMORY.md              # Cross-role learnings (lead writes post-workflow)
```

### 5-Tier Lifecycle

| Tier | Rune Name | Weight | Max Age | Trigger | Pruning |
|------|-----------|--------|---------|---------|---------|
| Structural | **Etched** | 1.0 | Never expires | Manual only | User confirmation required |
| User-Explicit | **Notes** | 0.9 | Never expires | `/rune:echoes remember` | Never auto-pruned |
| Tactical | **Inscribed** | 0.7 | 90 days unreferenced | MEMORY.md > 150 lines | Multi-factor scoring, archive bottom 20% |
| Agent-Observed | **Observations** | 0.5 | 60 days last access | Agent echo-writer protocol | Auto-promoted to Inscribed after 3 references |
| Session | **Traced** | 0.3 | 30 days | MEMORY.md > 150 lines | Utility-based, compress middle 30% |

**Etched** entries are permanent project knowledge (architecture decisions, tech stack, key conventions). Only the user can add or remove them.

**Notes** entries are user-explicit memories created via `/rune:echoes remember <text>`. They represent things the user wants agents to remember across sessions. Weight=0.9 (highest after Etched). Never auto-pruned — only the user can remove them. Stored in `.claude/echoes/notes/MEMORY.md` with `role="notes"`.

**Inscribed** entries are tactical patterns discovered during reviews, audits, and work (e.g., "this codebase has N+1 query tendency in service layers"). They persist across sessions and get pruned when stale.

**Observations** entries are agent-observed patterns written via the echo-writer protocol. Weight=0.5. Auto-pruned when `days_since_last_access > 60` (EDGE-025). Auto-promoted to Inscribed after 3 access_count references in echo_access_log. Promotion rewrites the H2 header in the source MEMORY.md from `## Observations` to `## Inscribed` using atomic file rewrite (C3 concern: `os.replace()`). Stored in `.claude/echoes/observations/MEMORY.md` with `role="observations"`.

**Traced** entries are session-specific observations (e.g., "PR #42 had 3 unused imports"). They compress or archive quickly.

## Memory Entry Format

Every echo entry must include evidence-based metadata:

```markdown
### [YYYY-MM-DD] Pattern: {short description}
- **layer**: etched | notes | inscribed | observations | traced
- **source**: rune:{workflow} {context}
- **confidence**: 0.0-1.0
- **evidence**: `{file}:{lines}` — {what was found}
- **verified**: YYYY-MM-DD
- **supersedes**: {previous entry title} | none
- {The actual learning in 1-3 sentences}
```

### Example Entries

Full examples for all 5 tiers (Etched, Notes, Inscribed, Observations, Traced) with complete metadata format.

See [entry-examples.md](references/entry-examples.md) for the full set of examples.

## Multi-Factor Pruning Algorithm

Echo Score = `(Importance × 0.4) + (Relevance × 0.3) + (Recency × 0.3)`. Etched/Notes never pruned. Inscribed archives at score < 0.3 + 90 days. Observations auto-prune at 60 days, auto-promote after 3 references. Traced archives at score < 0.2 + 30 days. Prune only between workflows. Active context compression at 300 lines in `knowledge.md`.

## Concurrent Write Protocol

Each Ash writes to `{agent-name}-findings.md` (unique per agent). Tarnished consolidates post-workflow into MEMORY.md. Cross-role learnings → `team/MEMORY.md` only.

See [pruning-and-write-protocol.md](references/pruning-and-write-protocol.md) for full scoring formula, pruning rules, compression algorithm, and write protocol steps.

## Security

Sensitive data filter rejects API keys, passwords, tokens, connection strings before persisting. `.gitignore` excludes `.claude/echoes/` by default — opt-in via `echoes.version_controlled: true`.

## Integration Points

Echoes integrate with all major workflows: appraise (P1/P2 → reviewer/), audit (→ auditor/), devise (echo-reader → planner/), strive (→ workers/).

See [security-and-integration.md](references/security-and-integration.md) for sensitive data patterns, exclusion config, and per-workflow integration protocols.

## Auto-Observation Recording (Automated)

The `TaskCompleted` hook automatically appends lightweight observation entries to the appropriate role `MEMORY.md` when Rune workflow tasks complete. This requires zero orchestrator involvement.

**Trigger**: Every `TaskCompleted` event for teams with prefix `rune-` or `arc-`.

**Guards**: Only fires when `.claude/echoes/` exists, the role `MEMORY.md` is present, and the task subject is not a meta task (shutdown/cleanup/aggregate/monitor).

**Role routing**: Inferred from team name (review/appraise/audit → `reviewer`, plan/devise → `planner`, work/strive/arc → `workers`, default → `orchestrator`).

**Dedup**: Signal file `tmp/.rune-signals/.obs-{TEAM_NAME}_{TASK_ID}` prevents duplicate entries for the same task.

**Tier**: Observations (weight=0.5) — NOT Inscribed. Auto-promotes to Inscribed after 3 access references.

See [auto-observation.md](references/auto-observation.md) for the full protocol, role detection table, and security details.

## Codex Echo Validation (Optional)

Before persisting a learning to `.claude/echoes/`, optionally ask Codex whether the insight is generalizable or context-specific. This prevents polluting echoes with one-off observations that don't transfer to future sessions. Gated by `talisman.codex.echo_validation.enabled`. Uses nonce-bounded prompt, codex-exec.sh wrapper, and non-JSON output guard.

See [codex-echo-validation.md](references/codex-echo-validation.md) for the full protocol.

## Echo Schema Versioning

MEMORY.md files include a version header:

```markdown
<!-- echo-schema: v1 -->
# {Role} Memory

{entries...}
```

This enables future schema migrations without breaking existing echoes.

## Remembrance Channel — Human-Facing Knowledge

Remembrance is a parallel knowledge axis alongside Echoes. While Echoes are agent-internal memory (`.claude/echoes/`), Remembrance documents are version-controlled solutions in `docs/solutions/` designed for human consumption. Promotion requires: problem-solution pair, high confidence or 2+ session references, human actionability. Security-category promotions require explicit human verification.

See [remembrance-promotion.md](references/remembrance-promotion.md) for the full promotion rules, directory structure, and decision tree.

### YAML Frontmatter Schema + Commands

Remembrance docs use structured YAML frontmatter with `echo_ref` cross-referencing (SHA-256 content hash). Commands: `remember` (Notes entry), `remembrance` (query), `promote` (echo → Remembrance), `migrate` (RENAME-2 stale name updates).

See [remembrance-commands.md](references/remembrance-commands.md) for full schema, command protocols, examples, and migration steps. See [remembrance-schema.md](references/remembrance-schema.md) for the complete YAML spec.

## Doc Packs — Curated Knowledge Bundles

Doc packs are pre-curated MEMORY.md files bundled with the Rune plugin. They contain opinionated patterns, common gotchas, and integration recipes for popular frameworks — knowledge that complements Context7's API reference docs.

### Directory Layout

```
~/.claude/echoes/global/              # CHOME pattern: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
├── doc-packs/
│   ├── shadcn-ui/MEMORY.md           # Installed pack
│   └── fastapi/MEMORY.md
├── manifests/
│   ├── shadcn-ui.json                # Install metadata + staleness
│   └── fastapi.json
└── MEMORY.md                         # User-elevated global echoes
```

### Stack Name Validation (SEC-P3-001)

All `<stack>` arguments MUST be validated before use in paths:
- Pattern: `^[a-zA-Z][a-zA-Z0-9_-]{1,63}$` (leading alpha required — blocks `--help` injection)
- After path construction: verify `realpath` stays within `$CHOME/echoes/global/`
- Reject with error message if validation fails

### `doc-packs install <stack>`

Install a bundled doc pack to the global echo store.

**Flow**:
1. Validate `<stack>` name against `^[a-zA-Z][a-zA-Z0-9_-]{1,63}$`
2. Read `${CLAUDE_PLUGIN_ROOT}/data/doc-packs/registry.json` — verify `<stack>` exists
3. Check if already installed: `$CHOME/echoes/global/doc-packs/<stack>/MEMORY.md`
   - If exists: overwrite (idempotent re-install)
4. Create directories: `mkdir -p "$CHOME/echoes/global/doc-packs/<stack>" "$CHOME/echoes/global/manifests"`
5. Copy pack: `cp "${CLAUDE_PLUGIN_ROOT}/data/doc-packs/<stack>/MEMORY.md" "$CHOME/echoes/global/doc-packs/<stack>/"`
6. Write manifest to `$CHOME/echoes/global/manifests/<stack>.json`:
   ```json
   {
     "name": "<stack>",
     "version": "<from registry>",
     "installed_at": "<ISO-8601 now>",
     "last_updated": "<from registry>",
     "source_version": "<from registry>",
     "domains": ["<from registry>"]
   }
   ```
7. Write dirty signal: `touch "$CHOME/echoes/global/.global-echo-dirty"`
8. Confirm: "Installed doc pack `<stack>` (v1.0.0) to global echoes. Run `echo_search(query, scope='global')` to search."

### `doc-packs list`

List available and installed doc packs.

**Flow**:
1. Read `${CLAUDE_PLUGIN_ROOT}/data/doc-packs/registry.json`
2. For each pack, check if manifest exists at `$CHOME/echoes/global/manifests/<name>.json`
3. Display table:
   ```
   Available doc packs:
     shadcn-ui     ✓ installed (v1.0.0, 2026-03-11)
     tailwind-v4   ✓ installed (v1.0.0, 2026-03-11)
     nextjs        ○ not installed
     fastapi       ○ not installed
     sqlalchemy    ○ not installed
     untitledui    ○ not installed
   ```

### `doc-packs update <stack>`

Update an installed pack to the latest bundled version.

**Flow**:
1. Validate `<stack>` name
2. Read installed manifest from `$CHOME/echoes/global/manifests/<stack>.json`
   - If not installed: error "Pack `<stack>` is not installed. Run `doc-packs install <stack>` first."
3. Read bundled registry version
4. Compare `manifest.source_version` with `registry.packs[stack].version`
   - Use string comparison (semver format, no `sort -V` — EC-3.7 macOS compat)
   - If same: "Already up to date (v1.0.0)"
   - If different: copy updated MEMORY.md, update manifest `source_version` + `last_updated`, write dirty signal

### `doc-packs status`

Show staleness status for installed packs.

**Flow**:
1. List all manifests in `$CHOME/echoes/global/manifests/`
2. For each manifest, calculate days since `installed_at`
3. Display with staleness indicator (threshold: 90 days from talisman `echoes.global.staleness_days`):
   ```
   Doc pack status:
     shadcn-ui     v1.0.0  installed 5 days ago      ✓ fresh
     tailwind-v4   v1.0.0  installed 93 days ago      ⚠ stale (> 90 days)
   ```

### `audit` — Global Echo Provenance

List all global echoes with their source and provenance.

**Flow**:
1. Read all manifests from `$CHOME/echoes/global/manifests/` for doc pack info
2. Parse `$CHOME/echoes/global/MEMORY.md` for elevated echoes (source prefix `elevated:`)
3. Count entries per pack/source
4. Display grouped report:
   ```
   Global echo audit:
     Doc packs:
       shadcn-ui     3 entries  frontend     installed 2026-03-11
       fastapi       3 entries  backend      installed 2026-03-11

     Elevated echoes:
       "Rate Limiting Best Practice"   backend    from rune-plugin (2026-03-11)
   ```

## Commands

See `/rune:echoes` command for user-facing echo management (show, prune, reset, remember, remembrance, promote, migrate, doc-packs, audit).
