# CREATION-LOG: talisman

## Metadata
- **Created**: 2026-02-25
- **Author**: vinhnx
- **Version**: 1.0.0
- **Skill Type**: User-invocable configuration tool

## Purpose
Deep talisman.yml configuration expertise — initialize, audit, update, and guide
talisman configuration for any project. The missing skill that bridges the gap
between `talisman.example.yml` (950+ lines of possibilities) and a project's
actual `.claude/talisman.yml`.

## Design Decisions

### Why a dedicated skill (not part of tarnished)?
- Tarnished is a lightweight ROUTER — it delegates, doesn't implement
- Talisman operations require deep configuration knowledge (many sections, 100+ keys)
- Keeping it separate follows the single-responsibility principle
- Tarnished routes to `/rune:talisman` via fast-path keyword

### Why subcommands instead of separate skills?
- All operations work on the same artifact (talisman.yml)
- Shared context (read once, used across init/audit/update/guide)
- Natural UX: `/rune:talisman init` vs separate `/rune:talisman-init`

### Why stack detection in INIT?
- Different stacks need different `ward_commands`, `backend_extensions`, `dedup_hierarchy`
- Auto-detection reduces manual configuration by 80%+
- Fallback to generic template if no stack detected

### Single source of truth
- `talisman.example.yml` at plugin root is the canonical template
- AUDIT compares against it, INIT scaffolds from it
- No hardcoded defaults in the skill — always reads the example

## Files
- `SKILL.md` — Main skill (subcommand routing, 5 workflows)
- `references/talisman-sections.md` — Top-level sections with key descriptions
- `CREATION-LOG.md` — This file

## Dependencies
- `../../talisman.example.yml` — canonical template (read-only)
- `../../references/configuration-guide.md` — full schema reference
- `../../references/read-talisman.md` — readTalisman() pattern

## Routing
- Tarnished fast-path: `talisman` → `/rune:talisman`
- Vietnamese: `cấu hình` / `thiết lập` → `/rune:talisman`
