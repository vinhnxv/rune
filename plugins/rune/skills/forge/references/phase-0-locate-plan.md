# Phase 0: Locate Plan + Arc Context Detection

## With Argument

```javascript
const planPath = args[0]

// Validate plan path: prevent shell injection in Bash cp/diff calls
if (!/^[a-zA-Z0-9._\/-]+$/.test(planPath)) {
  error(`Invalid plan path: ${planPath}. Path must contain only alphanumeric, dot, slash, hyphen, and underscore characters.`)
  return
}

if (!exists(planPath)) {
  error(`Plan not found: ${planPath}. Create one with /rune:devise first.`)
  return
}
```

## Auto-Detect

If no plan specified:
```bash
# Look for most recently modified plans
ls -t plans/*.md 2>/dev/null | head -5
```

If multiple found, ask user which to deepen:

```javascript
AskUserQuestion({
  questions: [{
    question: `Found ${count} recent plans:\n${planList}\n\nWhich plan should I deepen?`,
    header: "Select plan",
    options: recentPlans.map(p => ({
      label: p.name,
      description: `${p.date} — ${p.title}`
    })),
    multiSelect: false
  }]
})
```

If none found, suggest `/rune:devise` first.

## Arc Context Detection

When invoked as part of `/rune:arc` pipeline, forge detects arc context via plan path prefix.
This skips interactive phases (scope confirmation, post-enhancement options) since arc is automated.

```javascript
// Normalize "./" prefix — paths may arrive as "./tmp/arc/" or "tmp/arc/"
const isArcContext = planPath.replace(/^\.\//, '').startsWith("tmp/arc/")
```
