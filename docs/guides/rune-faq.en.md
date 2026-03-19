# Rune FAQ

Frequently asked questions for Rune users, written for quick practical answers.
This guide intentionally keeps some technical terms in English (`workflow`, `phase`, `checkpoint`, `quality gate`) for consistency.

Related guides:
- [Quick Cheat Sheet](rune-quick-cheat-sheet.en.md)
- [Getting Started](rune-getting-started.en.md)
- [Command Reference](rune-command-reference.en.md)
- [Troubleshooting Guide](rune-troubleshooting-and-optimization-guide.en.md)

## Getting Started and Core Commands

### 1) What is the difference between `/rune:plan` and `/rune:devise`?
`/rune:plan` is an alias for `/rune:devise`, focused on beginner UX.

### 2) What is the difference between `/rune:work` and `/rune:strive`?
`/rune:work` is an alias for `/rune:strive`, same implementation behavior.

### 3) What is the difference between `/rune:review` and `/rune:appraise`?
`/rune:review` is an alias for `/rune:appraise`, same review engine.

### 4) When should I use `/rune:audit` instead of `/rune:review`?
- Use `review` for your current `git diff`.
- Use `audit` for broader or deeper codebase scanning.

### 5) When should I use `/rune:arc`?
Use Arc (end-to-end pipeline) when you want full automation (plan -> work -> review -> Mend (auto-fix findings) -> test -> ship/merge).
If you need faster and cheaper iterations, run `/rune:plan -> /rune:work -> /rune:review`.

## Workflow Operations

### 6) What should I do if arc was interrupted mid-run?
Resume with:

```bash
/rune:arc plans/my-plan.md --resume
```

### 7) What if arc-batch was interrupted?
Resume with:

```bash
/rune:arc-batch --resume
```

### 8) How do I stop a running workflow?
Use the matching cancel command:
- `/rune:cancel-arc`
- `/rune:cancel-arc-batch`
- `/rune:cancel-review`
- `/rune:cancel-audit`

### 9) What is `/rune:tarnished`?
The Tarnished (orchestrator) is the unified entrypoint that routes natural language to the right workflow.

Examples:

```bash
/rune:tarnished review and fix
/rune:tarnished plan then work
```

## Configuration and Accuracy

### 10) Is `talisman.yml` required?
No, but strongly recommended for project-specific tuning.

### 11) When should I run `talisman init`, `audit`, and `update`?
- `init`: create a new config.
- `audit`: find missing or outdated sections.
- `update`: add missing sections to an existing file.

### 12) Why is my plan blocked as stale?
Freshness gate detected plan drift relative to current `HEAD`.
Typical fixes:
1. Regenerate the plan with `/rune:devise`.
2. Intentionally bypass with `--skip-freshness` if you accept the risk.

### 13) Custom Ash (review agent) is not running. What should I check first?
1. `trigger.extensions` matches changed files.
2. `trigger.paths` matches changed paths.
3. `workflows` includes the current workflow.
4. `settings.max_ashes` is not too low.

## Cost and Optimization

### 14) Why does Rune consume many tokens?
Rune runs multi-agent workflows, and each agent has its own context window.
That higher cost is the tradeoff for broader coverage and stronger quality control.

### 15) How can I reduce token usage?
1. Use `/rune:plan --quick` for small tasks.
2. Use `/rune:review` instead of `--deep` when deep coverage is unnecessary.
3. Use split workflow steps instead of always running `/rune:arc`.

### 16) When should I run `/rune:rest`?
When you want to clean `tmp/` artifacts from completed workflows.
It preserves active workflow state and keeps Echoes (persistent memory) at `.rune/echoes/`.

## Outputs and Fixes

### 17) Where is TOME (review report) generated?
- Review: `tmp/reviews/{id}/TOME.md`
- Audit: `tmp/audit/{id}/TOME.md`

### 18) How do I fix findings from TOME?

```bash
/rune:mend tmp/reviews/{id}/TOME.md
```

or

```bash
/rune:mend tmp/audit/{id}/TOME.md
```

### 19) What if mend introduces incorrect changes?
1. Ensure `ward_commands` include lint + typecheck + test.
2. Re-check low-confidence findings.
3. Enable `goldmask.mend.inject_context` to provide risk context to fixers.

### 20) Where can I read practical solution docs?
See Remembrance:
- [Remembrance (English)](../solutions/README.md)
- [Remembrance (Tiếng Việt)](../solutions/README.vi.md)

