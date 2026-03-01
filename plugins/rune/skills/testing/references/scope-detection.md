# Scope Detection Algorithm — resolveTestScope()

Shared scope resolution used by both `/rune:test-browser` (standalone) and arc Phase 7.7 TEST.
Determines the set of changed files for diff-scoped test selection.

## Function Signature

```
resolveTestScope(input) → { files: string[], source: "pr" | "branch" | "current", label: string }
```

**Input**: raw string — may be a PR number, branch name, or empty.
**Output**: `files` array + `source` tag + human-readable `label` for the test report header.

## Detection Algorithm

```
resolveTestScope(input):
  input = input.trim()

  --- Base-case guard (Gap 2.1) ---
  if not inside a git repo:
    Bash(`git rev-parse --is-inside-work-tree 2>/dev/null`)
    if exit code != 0:
      WARN: "Not inside a git repository. Cannot scope tests."
      return { files: [], source: "current", label: "no-git-repo" }

  --- Case 1: PR number ---
  if input matches /^\d+$/:
    validate: input must be digits only (injection prevention)
    prNum = parseInt(input, 10)
    result = Bash(`gh pr view ${prNum} --json files --jq '.files[].path' 2>/dev/null`)
    files = result.trim().split("\n").filter(Boolean)

    --- Empty files guard (Gap G-1) ---
    if files is empty or result is blank:
      WARN: "PR #${prNum} returned no file list (may be closed/draft/merge-commit-only). Falling through to current branch."
      // Fall through to Case 3

    else:
      return {
        files,
        source: "pr",
        label: "PR #${prNum}"
      }

  --- Case 2: Branch name ---
  if input is non-empty and not a PR number:
    validate: input must match /^[a-zA-Z0-9._\/-]+$/ (no spaces, no shell metacharacters)
    if validation fails:
      WARN: "Invalid branch name '${input}'. Falling through to current branch."
      // Fall through to Case 3

    else:
      defaultBranch = resolveDefaultBranch()
      result = Bash(`git diff ${defaultBranch}...${input} --name-only 2>/dev/null`)
      files = result.trim().split("\n").filter(Boolean)
      if files is empty:
        WARN: "No diff found between ${defaultBranch} and ${input}. Falling through to current branch."
        // Fall through to Case 3
      else:
        return {
          files,
          source: "branch",
          label: "${input} vs ${defaultBranch}"
        }

  --- Case 3: Current branch (default) ---
  defaultBranch = resolveDefaultBranch()
  result = Bash(`git diff ${defaultBranch}...HEAD --name-only 2>/dev/null`)
  files = result.trim().split("\n").filter(Boolean)
  if files is empty:
    WARN: "No diff from ${defaultBranch} to HEAD. Running tests on full repo (no scoping)."
    return { files: [], source: "current", label: "HEAD (no diff)" }

  currentBranch = Bash(`git rev-parse --abbrev-ref HEAD 2>/dev/null`).trim() || "HEAD"
  return {
    files,
    source: "current",
    label: "${currentBranch} vs ${defaultBranch}"
  }
```

## Default Branch Detection

```
resolveDefaultBranch() → string

  // Strategy 1: remote HEAD ref (most reliable)
  ref = Bash(`git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`)
  if ref is non-empty:
    // "refs/remotes/origin/main" → "main"
    return ref.trim().replace("refs/remotes/origin/", "")

  // Strategy 2: check common names
  for candidate in ["main", "master", "trunk", "develop"]:
    exists = Bash(`git show-ref --verify --quiet refs/heads/${candidate} 2>/dev/null`)
    if exit code == 0:
      return candidate

  // Strategy 3: fallback
  WARN: "Could not detect default branch. Defaulting to 'main'."
  return "main"
```

## Security Notes

### Branch Name Quoting

All branch names received from user input MUST be validated before interpolation:

```bash
# Validate before shell use
if ! echo "$branch" | grep -qE '^[a-zA-Z0-9._/-]+$'; then
  echo "Invalid branch name" >&2
  exit 2
fi
# Safe to interpolate — only alphanumeric, dots, slashes, hyphens
git diff "origin/${branch}"...HEAD --name-only
```

Never allow: spaces, semicolons, backticks, `$`, `(`, `)`, `|`, `&`, `>`, `<`.

### PR Number Validation

PR numbers must be digit-only before passing to `gh`:

```bash
if ! echo "$pr_num" | grep -qE '^\d+$'; then
  echo "Invalid PR number" >&2
  exit 2
fi
gh pr view "$pr_num" --json files --jq '.files[].path'
```

### Empty Files Array (Gap G-1)

`gh pr view` can return an empty `files` array for:
- Draft PRs (not yet diffed by GitHub)
- PRs with only binary assets
- Closed/merged PRs where the diff has been GC'd
- Merge commits (empty diff against base)

Always check `files.length > 0` before proceeding. Fall through to Case 3 (current branch) rather than aborting.

### Recursive Fallback Guard (Gap 2.1)

The fall-through from Case 1 → Case 3 and Case 2 → Case 3 MUST NOT recurse.
Implement as sequential `if / else if / else` — never mutual calls.
The base-case git-repo guard MUST be the first check before any `git` command.

## Output Integration

The returned `files` array feeds directly into:

1. **Unit test discovery** (`test-discovery.md`): `resolveUnitTests(files)`
2. **Integration test discovery** (`test-discovery.md`): `resolveIntegrationTests(files)`
3. **E2E route discovery** (`test-discovery.md`): `resolveE2ERoutes(files)`
4. **Test report header**: `label` appears as the scope line in the Markdown report

If `files` is empty, all three tiers run without diff-scoping (full repo scan).
Emit a prominent WARN in the test report: `⚠ No diff scope — running full-repo test discovery`.

## Example Outputs

| Input | Detected case | Sample output |
|-------|--------------|---------------|
| `"42"` | PR #42 | `{ files: ["src/auth.ts", "tests/auth.test.ts"], source: "pr", label: "PR #42" }` |
| `"feature/login"` | Branch | `{ files: ["src/auth.ts"], source: "branch", label: "feature/login vs main" }` |
| `""` | Current branch | `{ files: ["src/auth.ts"], source: "current", label: "feature/login vs main" }` |
| `""` (on main) | No diff | `{ files: [], source: "current", label: "HEAD (no diff)" }` |
| `"42"` (empty PR) | PR fallback → current | `{ files: ["src/auth.ts"], source: "current", label: "feature/login vs main" }` |
