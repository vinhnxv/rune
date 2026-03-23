---
name: rune:echoes
description: |
  Manage Rune Echoes — project-level agent memory stored in .rune/echoes/.
  View memory state, prune stale entries, reset all echoes, manage doc packs,
  or audit global echoes.

  <example>
  user: "/rune:echoes show"
  assistant: "Displaying echo state across all roles..."
  </example>

  <example>
  user: "/rune:echoes prune"
  assistant: "Calculating Echo Scores and pruning stale entries..."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

# /rune:echoes — Manage Rune Echoes

Manage the project-level agent memory stored in `.rune/echoes/`.

## Usage

```
/rune:echoes show                     # Display current echo state
/rune:echoes prune                    # Prune stale entries (with confirmation)
/rune:echoes reset                    # Clear all echoes (with confirmation)
/rune:echoes init                     # Initialize echo directories for this project
/rune:echoes promote                  # Promote echoes to Remembrance docs
/rune:echoes migrate                  # Migrate echo names after upgrade
/rune:echoes remembrance              # View Remembrance knowledge docs
/rune:echoes doc-packs install <stack> # Install a bundled doc pack to global echoes
/rune:echoes doc-packs list           # List available and installed doc packs
/rune:echoes doc-packs update <stack> # Update installed pack to latest bundled version
/rune:echoes doc-packs status         # Show staleness for installed packs
/rune:echoes audit                    # List all global echoes with provenance
```

## Execution

Load and execute the `rune-echoes` skill (`skills/rune-echoes/SKILL.md`) with all arguments passed through.
The skill contains echo lifecycle logic, scoring algorithms, and subcommand dispatch.

## Subcommands

### show — Display Echo State

Scan `.rune/echoes/` and display statistics per role.

```
# Find all MEMORY.md files
Glob(".rune/echoes/**/MEMORY.md")
```

**Output format:**

```
Rune Echoes — Memory State
══════════════════════════

Role: reviewer
  MEMORY.md: 45 lines, 12 entries
  knowledge.md: 120 lines (compressed)
  archive/: 3 files
  Layers: 2 etched, 7 inscribed, 3 traced

Role: team
  MEMORY.md: 18 lines, 5 entries
  Layers: 1 etched, 4 inscribed

Total: 17 entries across 2 roles
Oldest entry: 2026-02-01
Newest entry: 2026-02-11
```

If no echoes exist: "No echoes found. Run `/rune:appraise` or `/rune:echoes init` to start building memory."

### prune — Remove Stale Entries

Calculate Echo Score for each entry and archive low-scoring ones.

**Steps:**

1. Read all MEMORY.md files across roles
2. Parse entries and calculate Echo Score:
   ```
   Score = (Importance × 0.4) + (Relevance × 0.3) + (Recency × 0.3)
   ```
3. Display candidates for pruning:
   ```
   Prune candidates:

   reviewer/MEMORY.md:
     [0.15] [traced] [2026-01-05] Observation: Slow CI run
     [0.22] [traced] [2026-01-12] Observation: Flaky test in auth module

   auditor/MEMORY.md:
     [0.18] [inscribed] [2025-11-01] Pattern: Unused CSS classes

   3 entries would be archived. Proceed? (y/n)
   ```
4. On confirmation:
   - Backup: copy each MEMORY.md to `archive/MEMORY-{date}.md`
   - Remove low-scoring entries from MEMORY.md
   - Report: "Pruned 3 entries. Backups in archive/"

**Safety:**
- Etched entries are not candidates for pruning
- Always backup before any modification
- User must confirm before pruning proceeds

### reset — Clear All Echoes

Remove all echo data for this project.

**Steps:**

1. Warn: "This will delete ALL echoes for this project. This cannot be undone."
2. Require explicit confirmation: user must type "reset" or confirm
3. On confirmation:
   - Backup entire `.rune/echoes/` to `.rune/echoes-backup-{date}/`
   - Delete all MEMORY.md, knowledge.md, and findings files
   - Preserve directory structure (empty directories remain)
   - Report: "All echoes cleared. Backup at .rune/echoes-backup-{date}/"

### init — Initialize Echo Directories

Create the echo directory structure for a new project.

**Steps:**

1. Create directories:
   ```bash
   mkdir -p .rune/echoes/planner
   mkdir -p .rune/echoes/workers
   mkdir -p .rune/echoes/reviewer/archive
   mkdir -p .rune/echoes/auditor/archive
   mkdir -p .rune/echoes/team
   ```

2. Create initial MEMORY.md files with schema header:
   ```markdown
   <!-- echo-schema: v1 -->
   # {Role} Memory

   *No echoes yet. Run workflows to start building memory.*
   ```

3. Check `.gitignore` for `.rune/echoes/` exclusion:
   - If project has `.gitignore` and it doesn't exclude echoes: warn user
   - Suggest adding `.rune/echoes/` to `.gitignore`

4. Report:
   ```
   Rune Echoes initialized.

   Directories created:
   - .rune/echoes/planner/
   - .rune/echoes/workers/
   - .rune/echoes/reviewer/
   - .rune/echoes/auditor/
   - .rune/echoes/team/

   Run /rune:appraise or /rune:audit to start building memory.
   ```

### promote — Promote Echoes to Remembrance

Promote high-confidence echoes to human-readable knowledge docs in `docs/solutions/`.

**Steps:**

1. If no args: list all Etched and high-confidence Inscribed entries with their echo refs
2. If `--category <cat>`: filter by category (e.g., `performance`, `security`, `patterns`)
3. For each selected echo:
   - Convert to Remembrance format (see `rune-echoes` skill, Remembrance Commands section)
   - Write to `docs/solutions/{category}/{slug}.md`
   - Mark echo as promoted (add `promoted_to` field)
4. Report: "{count} echoes promoted to docs/solutions/"

### migrate — Migrate Echo Names

Migrate echo role names and schema versions after a Rune upgrade.

**Steps:**

1. Scan `.rune/echoes/` for directories and MEMORY.md files
2. Check schema version in `<!-- echo-schema: vN -->` headers
3. Rename directories if role names changed (e.g., legacy names to current convention)
4. Update schema headers to current version
5. Report: "{count} echoes migrated, {count} already current"

### remembrance — View Remembrance Docs

View and search Remembrance knowledge documents.

**Steps:**

1. If no args: list all docs in `docs/solutions/` with categories and titles
2. If `<category>`: list docs in `docs/solutions/{category}/`
3. If `<search>`: search across all Remembrance docs for keyword
4. Display matching documents with summaries

### doc-packs install — Install Bundled Doc Pack

Install a curated doc pack (framework patterns, gotchas, recipes) to the global echo store.

**Steps:**

1. Validate `<stack>` against `^[a-zA-Z][a-zA-Z0-9_-]{1,63}$` (SEC-P3-001)
2. Read registry: `${RUNE_PLUGIN_ROOT}/data/doc-packs/registry.json`
3. Verify `<stack>` exists in registry — error if not
4. Set `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`
5. Create dirs: `mkdir -p "$CHOME/echoes/global/doc-packs/<stack>" "$CHOME/echoes/global/manifests"`
6. Copy: `cp "${RUNE_PLUGIN_ROOT}/data/doc-packs/<stack>/MEMORY.md" "$CHOME/echoes/global/doc-packs/<stack>/"`
7. Write manifest JSON to `$CHOME/echoes/global/manifests/<stack>.json`
8. Write dirty signal: `touch "$CHOME/echoes/global/.global-echo-dirty"`
9. Report: "Installed `<stack>` (v1.0.0). Search with `echo_search(query, scope='global')`"

### doc-packs list — List Available Packs

Show all available doc packs and their install status.

**Steps:**

1. Read registry from `${RUNE_PLUGIN_ROOT}/data/doc-packs/registry.json`
2. For each pack, check `$CHOME/echoes/global/manifests/<name>.json`
3. Display: `✓ installed (version, date)` or `○ not installed`

### doc-packs update — Update Installed Pack

Update a doc pack to the latest bundled version.

**Steps:**

1. Read installed manifest and bundled registry version
2. Compare versions (string comparison — no `sort -V` for macOS compat)
3. If newer: copy MEMORY.md, update manifest, write dirty signal
4. If same: "Already up to date"

### doc-packs status — Staleness Report

Show install age and staleness for all installed packs.

**Steps:**

1. List manifests in `$CHOME/echoes/global/manifests/`
2. Calculate days since `installed_at`
3. Flag stale packs (> 90 days, configurable via `echoes.global.staleness_days`)

### audit — Global Echo Provenance

List all global echoes grouped by source type.

**Steps:**

1. Read manifests for doc pack metadata
2. Parse `$CHOME/echoes/global/MEMORY.md` for elevated echoes
3. Display grouped: doc packs (with entry counts, domains) + elevated echoes (with source project)

## Notes

- Echo data is project-local (`.rune/echoes/` in project root)
- Global echoes are user-level (`$CHOME/echoes/global/`)
- Excluded from git by default (security: may contain code patterns)
- Opt-in to version control via `.rune/talisman.yml`
- See `rune-echoes` skill for full lifecycle documentation
