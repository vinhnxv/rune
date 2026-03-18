---
name: elevate
description: |
  Promote a project echo to global scope with domain tagging.
  Use when a learning is valuable across multiple projects.
  Copies selected entries from project .rune/echoes/ to global echoes
  with domain classification and source provenance.

  Trigger keywords: elevate, promote to global, cross-project, share echo,
  global echo, elevate echo.

  <example>
  user: "/rune:elevate --scope backend"
  assistant: "Scanning project echoes... Found 12 entries. Select entries to elevate."
  </example>

  <example>
  user: "/rune:elevate --scope frontend"
  assistant: "Elevated 3 entries to global scope (domain: frontend)"
  </example>
user-invocable: true
argument-hint: "--scope <domain>"
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - AskUserQuestion
---

# /rune:elevate — Promote Echoes to Global Scope

Promote project-level echoes to the global echo store with domain tagging. Elevated echoes become available across all projects via `echo_search(query, scope="global")`.

> Elevation is a **copy**, not a move. The original project echo remains untouched. Access history stays in the project DB — global entries start fresh tracking.

## Prerequisites

- Project echoes must exist (`.rune/echoes/` with MEMORY.md files)
- `--scope <domain>` argument is **required** (no default — prevents accidental bleed)

## Allowed Domains

`backend`, `frontend`, `devops`, `database`, `testing`, `architecture`, `general`

Override via `talisman.yml` → `echoes.global.domains`.

## Elevation Flow

### Step 1: Parse and Validate Arguments

```
ARGUMENTS = $ARGUMENTS
if "--scope" not in ARGUMENTS:
    ERROR: "--scope <domain> is required. Valid domains: backend, frontend, devops, database, testing, architecture, general"
    EXIT

domain = extract value after --scope
Validate domain against allowed list
```

### Step 2: Resolve Paths (CHOME Pattern)

```
CHOME = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GLOBAL_MEMORY = "$CHOME/echoes/global/MEMORY.md"
GLOBAL_DIR = "$CHOME/echoes/global"
PROJECT_ECHOES = ".rune/echoes"
```

Never hardcode `~/.claude/`.

### Step 3: Scan Project Echoes

Read all MEMORY.md files in `.rune/echoes/*/MEMORY.md` via Glob.

For each file, parse entries using the header pattern:
```
## {Layer} — {Title} ({Date})
```

**Filters** (skip these entries):
- Entries with `source: elevated:*` — already elevated (EC-3.6: circular prevention)
- Entries with `source: doc-pack:*` — doc packs are managed separately
- Observations tier entries — too ephemeral for global scope

### Step 4: Present Candidates

Use `AskUserQuestion` to present entries as a numbered list:

```
Project echoes available for elevation to global (domain: backend):

1. [etched] Rate Limiting Best Practice (2026-03-11) — planner
2. [inscribed] N+1 Query Detection Pattern (2026-03-10) — reviewer
3. [inscribed] Error Boundary Conventions (2026-03-09) — reviewer
4. [notes] Always use UTC timestamps (2026-03-08) — notes

Enter entry numbers to elevate (comma-separated), or 'all', or 'cancel':
```

### Step 5: Dedup Check

For each selected entry, generate a content hash for dedup:

```
1. Strip metadata lines (**Source**:, **Category**:, **Domain**:, **Confidence**:)
2. Strip whitespace, lowercase remaining content
3. SHA-256 hash of cleaned content (full digest — SEC-P3-005)
4. Check against existing entries in GLOBAL_MEMORY
5. If hash matches existing entry: skip with message "Skipping '{title}' — already elevated"
```

### Step 6: Entry Count Guard (EC-3.3)

Before appending, count existing elevated entries in `GLOBAL_MEMORY` (non-doc-pack entries).

If count + new entries > 50:
```
WARNING: Global MEMORY.md has {count} entries (limit: 50).
Elevating {new} more would exceed the limit.
Oldest elevated entries should be archived first.
Proceed anyway? (y/n)
```

### Step 7: Append to Global MEMORY.md

For each entry passing dedup, append to `$CHOME/echoes/global/MEMORY.md`:

```markdown
## Inscribed — {Original Title} ({Today's Date})

**Source**: `elevated:{project-name}@{original-role}`
**Category**: {original-category}
**Domain**: {domain from --scope}

{Original content body}
```

**Rules:**
- Layer becomes `Inscribed` (regardless of original layer)
- Source format: `elevated:{project-basename}@{role}` for audit trail
- Domain comes from `--scope` argument
- Date becomes today's date (elevation date, not original date)

**Write safety** (SEC-P3-006):
- Create lock dir: `mkdir "$GLOBAL_DIR/.lock" 2>/dev/null` — retry 3 times with 1s sleep
- Append content
- Release lock: `rmdir "$GLOBAL_DIR/.lock"`

### Step 8: Signal and Confirm

1. Write dirty signal: `touch "$CHOME/echoes/global/.global-echo-dirty"`
2. Create global dir if needed: `mkdir -p "$GLOBAL_DIR"`
3. Confirm: "Elevated {N} entries to global scope (domain: {domain}). Skipped {M} duplicates."

## Security

- **SEC-P3-001**: Domain argument validated against allowlist
- **SEC-P3-003**: Source MEMORY.md paths validated with `realpath` containment — must be under `.rune/echoes/`
- **SEC-P3-006**: Concurrent write protection via `mkdir`-based locking
- **EC-3.6**: Entries with `source: elevated:*` or `source: doc-pack:*` are skipped (no circular elevation)
- **EC-3.3**: Max 50 elevated entries in global MEMORY.md (doc packs are separate files, exempt)
