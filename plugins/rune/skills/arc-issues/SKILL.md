---
name: arc-issues
description: |
  Use when processing GitHub Issues as the arc work queue — fetching issue details,
  auto-generating plans, running /rune:arc for each, then posting results back to
  the originating issues. Covers: label-driven batch (--label), file-based queue,
  inline issue numbers, resume mode (--resume), paging (--all), dry-run preview,
  cleanup of orphaned labels (--cleanup-labels).

  Use instead of arc-batch when your work queue lives in GitHub Issues, not plan files.
  Closes the loop: Issue → Plan → Arc → PR → Comment → Close (via Fixes #N).

  Keywords: arc-issues, github issues, issue queue, issue backlog, batch from issues,
  label-driven, rune:ready, --label, --all, --resume, --cleanup-labels, issue-to-plan.

  <example>
  Context: User has GitHub issues labeled "rune:ready" to implement
  user: "/rune:arc-issues --label \"rune:ready\""
  assistant: "Fetching issues with label rune:ready..."
  </example>

  <example>
  Context: User has a file with issue numbers
  user: "/rune:arc-issues issues-queue.txt"
  assistant: "Reading issue queue from issues-queue.txt..."
  </example>

  <example>
  Context: User wants to process specific issues
  user: "/rune:arc-issues 42 55 78"
  assistant: "Processing issues #42, #55, #78..."
  </example>

user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Skill
argument-hint: "[--label LABEL | issues-queue.txt | #N ...] [--resume] [--dry-run] [--all] [--force]"
---

# /rune:arc-issues — GitHub Issues-Driven Batch Arc Execution

Processes GitHub Issues as a work queue. For each issue: fetches content → generates plan in `tmp/gh-plans/` → runs `/rune:arc` → posts summary comment → closes issue via `Fixes #N` in PR body.

**Core loop**: Stop hook pattern (same as arc-batch). Each arc runs as a native Claude Code turn. Between arcs, the Stop hook reads `.rune/arc-issues-loop.local.md`, marks current issue completed, posts GitHub comment, updates labels, and re-injects the next arc prompt.

## Usage

```
/rune:arc-issues --label "rune:ready"               # All open issues with label (FIFO)
/rune:arc-issues --label "rune:ready" --all         # Page through ALL matching issues
/rune:arc-issues --label "bug" --milestone "Sprint 3" --limit 5
/rune:arc-issues issues-queue.txt                   # File-based queue (URLs, #N, bare numbers)
/rune:arc-issues 42 55 78                           # Inline issue numbers
/rune:arc-issues --resume                           # Resume from batch-progress.json
/rune:arc-issues --label "rune:ready" --dry-run     # Preview without running
/rune:arc-issues --cleanup-labels                   # Sweep orphaned rune:in-progress labels
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--label LABEL` | Fetch issues with this label | (required for label mode) |
| `--all` | Page through ALL matching issues (label-driven cursor) | Off |
| `--page-size N` | Issues per page when using `--all` | 10 |
| `--limit N` | Max issues to fetch (single batch mode) | 20 |
| `--milestone NAME` | Filter by milestone | (none) |
| `--no-merge` | Skip auto-merge in each arc run | Off (auto-merge enabled) |
| `--dry-run` | List issues and exit without running | Off |
| `--force` | Skip plan quality gate (body < 50 chars) | Off |
| `--resume` | Resume from `tmp/gh-issues/batch-progress.json` | Off |
| `--cleanup-labels` | Remove orphaned `rune:in-progress` labels (> 2h old) | Off |

## Rune Status Labels

| Label | Meaning | Re-process how? |
|-------|---------|-----------------|
| `rune:in-progress` | Currently being processed | Wait, or `--cleanup-labels` if orphaned (> 2h) |
| `rune:done` | Completed — PR linked via `Fixes #N` | Issue auto-closes when PR merges |
| `rune:failed` | Arc failed, needs human fix | Fix issue body → remove label → re-run |
| `rune:needs-review` | Plan quality low or conflicts | Add detail → remove label → re-run |

All 4 labels are automatically excluded from new fetches via `--search` filter. Re-running the same command resumes where it left off.

## Security Constants

```javascript
// SEC-DECREE-003: Disable gh interactive prompts in all automation contexts
const GH_ENV = 'GH_PROMPT_DISABLED=1'
```

This constant MUST be prepended to every `gh` CLI call in this skill.

## Algorithm

See [arc-issues-algorithm.md](references/arc-issues-algorithm.md) for full pseudocode.

## Workflow Lock (writer)

```javascript
const lockConflicts = Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_check_conflicts "writer"`)
if (lockConflicts.includes("CONFLICT")) {
  AskUserQuestion({ question: `Active workflow conflict:\n${lockConflicts}\nProceed anyway?` })
}
Bash(`cd "${CWD}" && source plugins/rune/scripts/lib/workflow-lock.sh && rune_acquire_lock "arc-issues" "writer"`)
```

## Phase Structure

```
Phase 0: Parse arguments (4 input methods + flags)
Phase 1: Pre-flight validation (arc-issues-preflight.sh)
Phase 2: Issue → Plan generation (sanitize, template, stub sections)
Phase 3: Dry run (if --dry-run)
Phase 4: Initialize batch-progress.json
Phase 5: Confirm batch with user
Phase 6: Write state file + invoke first arc (Stop hook handles rest)
(Stop hook: arc-issues-stop-hook.sh handles all subsequent issues + final summary)
```

## Orchestration

Phase 6 writes `.rune/arc-issues-loop.local.md` (state file) and invokes the first arc natively. The Stop hook (`scripts/arc-issues-stop-hook.sh`) handles all subsequent issues via self-invoking loop.

**How the loop works:**
1. Phase 6 invokes `/rune:arc` for the first issue's plan (native turn)
2. When arc completes, Claude's response ends → Stop event fires
3. `arc-issues-stop-hook.sh` reads `.rune/arc-issues-loop.local.md`
4. Posts GitHub comment + updates labels for the completed issue
5. Marks current issue completed/failed in `batch-progress.json`
6. Finds next pending issue
7. Re-injects arc prompt via `{"decision":"block","reason":"<prompt>"}`
8. Claude receives the re-injected prompt → runs next arc
9. Repeat until all issues done
10. On final iteration: removes state file, releases workflow lock, injects summary prompt

**Lock release**: The stop hook releases the workflow lock on the final iteration:
```bash
source "${CWD}/plugins/rune/scripts/lib/workflow-lock.sh" && rune_release_lock "arc-issues"
```

## Error Handling

| Error | Recovery |
|-------|----------|
| `gh` CLI not installed | Pre-flight check fails with actionable message: `brew install gh` or `apt install gh` |
| API rate limiting (`gh api` 403/429) | Exponential backoff (3 retries, 5s/15s/45s). After exhaustion, mark issue as `rune:failed` with rate-limit note |
| Issue not found (404) or already closed | Skip issue, log warning, mark as SKIPPED in `batch-progress.json` |
| Issue body too short (< 50 chars) | Block by default (plan quality gate). Override with `--force` flag |
| Stop hook timeout cascade (> 15s) | GH API calls deferred to beginning of next arc turn. If still timing out, state file persists for `--resume` |
| Crash recovery via `--resume` | Reads `tmp/gh-issues/batch-progress.json`, skips completed/failed issues, resumes from next pending |
| Orphaned `rune:in-progress` labels (> 2h) | Run `--cleanup-labels` to sweep stale labels from aborted runs |
| Concurrent session conflict | Session isolation guard in stop hook filters by `owner_pid`; second session skips state file belonging to first |
| Plan generation fails (issue body unparseable) | Mark issue as `rune:needs-review`, post error comment, continue to next issue |

## Known Limitations

1. **Sequential only**: No parallel arc execution (SDK one-team-per-session constraint).
2. **Label TOCTOU**: Adding `rune:in-progress` after fetching creates a narrow race window if two sessions run concurrently. Documented v1 limitation.
3. **Cross-repo labels**: Label mode queries current repo only. File mode supports cross-repo URLs but `Fixes org/repo#N` requires PR repo write access to issue repo.
4. **GH API timeout in Stop hook**: GH API calls moved to beginning of next arc turn (not in Stop hook) to avoid 15s timeout cascades.
