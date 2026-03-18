# Remembrance Commands + YAML Schema + Echo Migration

## YAML Frontmatter Schema

Remembrance documents use structured YAML frontmatter. See [remembrance-schema.md](remembrance-schema.md) for the full schema specification.

**Required fields**: `title`, `category`, `tags`, `date`, `symptom`, `root_cause`, `solution_summary`, `confidence`, `verified_by`

**Key fields:**

```yaml
---
title: "Descriptive title of the problem and solution"
category: architecture        # one of the 8 categories
tags: [n-plus-one, eager-loading]
date: 2026-02-12
symptom: "User list endpoint takes 5+ seconds"
root_cause: "N+1 query pattern in user.posts association"
solution_summary: "Added includes(:posts) to User.list scope"
echo_ref: ".rune/echoes/reviewer/MEMORY.md#etched-004@sha256:a1b2c3..."  # cross-ref with content hash
confidence: high              # high | medium
verified_by: human            # human | agent — REQUIRED for security category
requires_human_approval: false
---
```

The `echo_ref` field uses format `{echo_path}#{entry_id}@sha256:{hash}` to cross-reference version-controlled Remembrance to non-version-controlled echoes. The promotion process MUST compute and store the SHA-256 hash.

## Remembrance Commands

The `/rune:echoes` command includes Notes and Remembrance subcommands:

```
/rune:echoes remember <text>                   # Create a Notes entry (user-explicit memory)
/rune:echoes remembrance [category|search]     # Query Remembrance documents
/rune:echoes promote <echo-ref> --category <cat>  # Promote echo to Remembrance
/rune:echoes migrate                           # Migrate echoes with old naming
```

**remember** — Create a Notes entry from user-provided text. Writes to `.rune/echoes/notes/MEMORY.md` (creates directory and file on demand). Notes are user-explicit memories that agents should always respect. They are never auto-pruned.

**Protocol:**
1. Read `.rune/echoes/notes/MEMORY.md` (or create with `<!-- echo-schema: v1 -->` header if missing)
2. Generate H2 entry: `## Notes — <title> (YYYY-MM-DD)` where title is extracted or summarized from user text
3. Add `**Source**: user:remember` metadata line
4. Append user-provided content as the entry body
5. Write back to `.rune/echoes/notes/MEMORY.md`
6. Confirm to user what was remembered

**Examples:**
```
/rune:echoes remember always use bun instead of npm
/rune:echoes remember the auth service requires Redis to be running locally
/rune:echoes remember PR reviews should check for N+1 queries in service layers
```

**remembrance** — Query existing Remembrance documents by category or search term. Returns matching documents with their frontmatter metadata.

**promote** — Promote an ETCHED echo to a Remembrance document. Validates promotion rules, computes content hash for `echo_ref`, checks for duplicates, and writes to `docs/solutions/{category}/`. For security category, prompts for human verification via `AskUserQuestion`.

**migrate** — Scans `.rune/echoes/` and updates old agent/concept names to current terminology (RENAME-2). Useful after version upgrades that rename agents or concepts.

## Echo Migration (RENAME-2)

When agent or concept names change across versions, existing echoes may reference stale names. The `migrate` subcommand handles this:

```
/rune:echoes migrate
```

**Steps:**
1. Scan all `.rune/echoes/**/*.md` files
2. Build a rename map from old names to new names
3. Apply renames to entry metadata (source, evidence references)
4. Report changes made

**Safety:**
- Backup all modified files before renaming
- Only rename in metadata fields, not in learning content
- Report all changes for user review
