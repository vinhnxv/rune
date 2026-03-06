# Security + Integration Points

## Security

### Sensitive Data Filter

Before persisting any echo entry, reject if content matches:

```
Patterns to reject:
- API keys: /[A-Za-z0-9_-]{20,}/ in context suggesting key/token
- Passwords: /password\s*[:=]\s*\S+/i
- Tokens: /bearer\s+[A-Za-z0-9._-]+/i
- Connection strings: /[a-z]+:\/\/[^:]+:[^@]+@/
- Email addresses in evidence (unless the learning IS about email handling)
```

If a finding triggers the filter, persist the learning but strip the sensitive evidence.

### Default Exclusion

`.gitignore` excludes `.claude/echoes/` by default. Users opt-in to version control:

```yaml
# .claude/talisman.yml
echoes:
  version_controlled: true  # Remove .claude/echoes/ from .gitignore
```

## Integration Points

### After Review (`/rune:appraise`)

In Phase 7 (Cleanup), before presenting TOME.md:

```
1. Read TOME.md for high-confidence patterns (P1/P2 findings)
2. Convert recurring patterns to Inscribed entries
3. Write to .claude/echoes/reviewer/MEMORY.md via consolidation protocol
```

### After Audit (`/rune:audit`)

Same as review, writing to `.claude/echoes/auditor/MEMORY.md`.

### During Plan (`/rune:devise`, v1.0)

```
1. echo-reader agent reads .claude/echoes/planner/MEMORY.md + .claude/echoes/team/MEMORY.md
2. Surfaces relevant past learnings for current feature
3. After plan: persist architectural discoveries to .claude/echoes/planner/
```

### During Work (`/rune:strive`, v1.0)

```
1. Read .claude/echoes/workers/MEMORY.md for implementation patterns
2. After work: persist TDD patterns, gotchas to .claude/echoes/workers/
```
