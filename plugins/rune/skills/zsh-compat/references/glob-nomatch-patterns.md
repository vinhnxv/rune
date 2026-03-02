# Glob NOMATCH Deep Dive

In bash, when a glob matches no files, it's passed through as a literal string. In zsh, the `NOMATCH` option (on by default) makes this a fatal error. This affects both `for` loops and command arguments.

**Inputs**: Shell commands containing glob patterns
**Outputs**: zsh-safe equivalents
**Preconditions**: Running on macOS with zsh as default shell

## The Problem

```bash
# BAD — fatal in zsh if no *.md files exist
for f in tmp/reviews/*.md; do
  echo "$f"
done
# zsh: no matches found: tmp/reviews/*.md

# BAD — same issue with command arguments
ls tmp/reviews/*-verdict.md 2>/dev/null
# zsh: no matches found: tmp/reviews/*-verdict.md (2>/dev/null doesn't help!)
```

## Fix — Three Options

**Option 1: `(N)` qualifier (preferred)** — zsh-native, scoped to one glob:
```bash
for f in tmp/reviews/*.md(N); do
  echo "$f"
done
# If no matches: loop body never executes (safe)
```

**Option 2: `setopt nullglob`** — affects all subsequent globs in the script:
```bash
setopt nullglob
for f in tmp/reviews/*.md; do
  echo "$f"
done
```

**Option 3: Existence check first** — most portable:
```bash
if [ -n "$(ls tmp/reviews/*.md 2>/dev/null)" ]; then
  for f in tmp/reviews/*.md; do
    echo "$f"
  done
fi
```

## Important: `2>/dev/null` Does NOT Help

In zsh, the NOMATCH error happens **before** the command runs — it's a glob expansion error at parse time, not a command error at runtime. Redirecting stderr does not suppress it.

## Unprotected Globs in Command Arguments (Pitfall 8)

The NOMATCH issue isn't limited to `for` loops. **Any** unmatched glob in zsh causes a fatal error — including in command arguments.

```bash
# BAD — fatal in zsh if no rune-* dirs exist
rm -rf "$CHOME/teams/rune-"* "$CHOME/tasks/rune-"* 2>/dev/null
# zsh: no matches found: /Users/me/.claude/teams/rune-*
# NOTE: 2>/dev/null does NOT help — the error is at parse time!

# GOOD — Option 1: use find (avoids shell globbing entirely)
find "$CHOME/teams/" -maxdepth 1 -type d -name "rune-*" -exec rm -rf {} + 2>/dev/null

# GOOD — Option 2: protect with nullglob
setopt nullglob; rm -rf "$CHOME/teams/rune-"* "$CHOME/tasks/rune-"* 2>/dev/null
```

## Parallel Sibling Calls Amplify the Failure

When Claude Code runs multiple Bash tool calls in parallel (siblings), **one ZSH NOMATCH failure aborts ALL siblings**:

```
⏺ Bash(rm -f tmp/.rune-forge-*.json 2>/dev/null && echo "ok")
  ⎿  Error: Exit code 1 — no matches found: tmp/.rune-forge-*.json

⏺ Bash(find "$CHOME/teams/" -maxdepth 1 -type d -name "rune-forge-*")
  ⎿  Error: Sibling tool call errored     ← SAFE command killed by sibling failure

⏺ Bash(date -u +%s)
  ⎿  Error: Sibling tool call errored     ← SAFE command killed by sibling failure
```

**Rule**: Never mix a glob-bearing Bash call with other parallel siblings. Use `Glob()` tool first, then `rm` per-file.

## Pseudocode Wildcard Rule

When skill pseudocode needs to discover and process files matching a pattern:

```javascript
// CORRECT — Glob() is a Claude tool, no shell expansion
const files = Glob("tmp/.rune-forge-*.json")
for (const f of files) {
  Bash(`rm -f "${f}"`)  // "${f}" is a resolved path — safe
}

// WRONG — raw glob in Bash, fatal in zsh when no files match
Bash(`rm -f tmp/.rune-forge-*.json 2>/dev/null`)
```

## Recommended Approaches

**For cleanup commands**: Prefer `find` over shell globs. `find -name "rune-*"` passes the pattern as a string argument — no shell expansion occurs.

**For quick one-liners**: Prepend `setopt nullglob;` to the command. This is scoped to the single Bash invocation.

**For pseudocode in SKILL.md/references**: Always use `Glob()` tool for wildcard resolution, then iterate resolved paths with `Bash("rm -f \"${path}\"")`. Never generate `Bash("rm -f pattern-*.json")`.
