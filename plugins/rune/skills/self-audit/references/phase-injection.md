# Phase-Specific Echo Injection

## Overview

The Phase 3 Feedback Loop injects relevant meta-QA warnings into arc phase prompts
before each phase executes. This creates a closed loop: self-audit findings from past
runs influence future arc phases, reducing recurrence of known issues.

## Mechanism

### Where: `arc-phase-stop-hook.sh`

The injection occurs in the Stop hook that drives the arc phase loop. After rate limit
detection and before the final `printf/exit 2`, the hook:

1. Reads `.rune/echoes/meta-qa/MEMORY.md` (if it exists and is not a symlink)
2. Calls `_extract_phase_echoes()` to filter entries matching the next phase
3. Appends matching entries to `PHASE_PROMPT` under a `## Meta-QA Warnings` header

### Function: `_extract_phase_echoes(memory_file, target_phase)`

Parses the MEMORY.md echo file line by line, extracting entries that:

- Match the target phase via `phase_tags` metadata
- Are NOT in the `observations` or `traced` layers (too low-signal for injection)
- Respect the max entry budget (3 entries)

### Entry Format (expected in MEMORY.md)

```markdown
### [SA-RC-001] Code review consistently misses null safety

- **layer**: inscribed
- **phase_tags**: code_review, mend
- **recurrence**: 4/5 runs
- **pattern**: Reviewers flag style but miss null deref in error paths

**Recommendation**: Add null-safety check to ward-sentinel prompt injection.
```

## Budget Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max entries per phase | 3 | Avoid prompt bloat; focus on top issues |
| Max total chars | 2000 | Hard cap prevents oversized injection |
| Token estimate | ~500 | 2000 chars ≈ 500 tokens at 4 chars/token |

## Talisman Gating

The injection is gated by the existence of the meta-QA MEMORY.md file. No talisman
config is required — if the file doesn't exist (self-audit hasn't been run), the
injection is silently skipped.

Future: `self_audit.phase_injection` talisman key can disable injection if needed.

## Security

- Symlink rejection: `[[ ! -L "$_mqa_file" ]]` prevents symlink-based injection
- Size cap: `${#_meta_qa_echoes} -lt 2000` prevents oversized content
- Layer filtering: Excludes low-confidence `observations` and `traced` entries
- No shell expansion: Content is embedded via variable substitution, not eval
