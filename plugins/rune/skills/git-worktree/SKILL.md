---
name: git-worktree
description: |
  Use when running /rune:strive with --worktree flag or when
  work.worktree.enabled is set in talisman. Use when a worker's direct commit
  fails due to parallel isolation conflicts, when a merge conflict is detected
  during wave merge (merge broker escalation), or when branches from multiple
  workers need sequential merging into the feature branch.
  Covers: worktree lifecycle, wave-based execution, merge strategy,
  conflict resolution patterns, direct commit vs patch generation.
  Keywords: worktree, isolation, wave, merge broker, branch merge, conflict,
  parallel isolation, --worktree, direct commit.

  <example>
  Context: Orchestrator activating worktree mode for /rune:strive
  user: "/rune:strive plans/feat-api-plan.md --worktree"
  assistant: "Worktree mode active. Workers will operate in isolated worktrees with direct commit."
  </example>

  <example>
  Context: Merge conflict during wave merge
  user: (internal — merge broker detects conflict)
  assistant: "Conflict detected in src/api.ts during Wave 1 merge. Escalating to user."
  </example>
user-invocable: false
disable-model-invocation: false  # Intentional: model loads this skill when worktree mode detected
allowed-tools:
  - Read
  - Glob
  - Grep
---

# Git Worktree — Isolation Mode for /rune:strive

## Overview

Git worktree mode gives each swarm worker its own isolated working copy via
`isolation: "worktree"` on the Agent tool. Workers commit directly in their
worktrees instead of generating patches. After each wave of workers completes,
the orchestrator merges worktree branches back into the feature branch.

**Two execution modes** coexist in `/rune:strive`:

| Mode | Flag | Worker Behavior | Commit Strategy |
|------|------|----------------|-----------------|
| **Patch** (default) | `--patch` or no flag | Shared working tree | Patch -> commit broker |
| **Worktree** | `--worktree` | `isolation: "worktree"` | Direct commit -> merge broker |

Talisman override: `work.worktree.enabled: true` makes worktree mode the default.

## Worktree Lifecycle

Each worker's worktree follows a 6-phase lifecycle: CREATE (SDK creates worktree + branch), WORK (isolated implementation), COMMIT (direct commit, one per task), SEAL (report completion), MERGE (orchestrator merges after wave), CLEANUP (remove worktree + branch). Includes crash recovery protocol.

See [worktree-lifecycle.md](references/worktree-lifecycle.md) for the full 6-phase protocol and crash handling.

## Merge Strategy

Worktree mode uses **sequential merge with `--no-ff`** for clear, revertable history.

### Why Sequential (not Octopus)

| Strategy | Pros | Cons |
|----------|------|------|
| Sequential `--no-ff` | Conflict isolation, partial progress, revertable | Slower for many branches |
| Octopus merge | Single commit | All-or-nothing, no conflict resolution |
| Rebase | Linear history | Rewrites SHAs, harder to audit |
| Cherry-pick | Selective | Loses branch context |

**Decision**: Sequential `--no-ff` (ADR 4) because:
- Know exactly which two branches conflict
- 3 of 5 can merge cleanly even if 2 conflict
- Each merge is individually revertable via `git revert -m1`
- Deterministic history (sorted by task ID)

### Merge Broker Algorithm

See [worktree-merge.md](../strive/references/worktree-merge.md) for the
complete merge broker algorithm, including:
- Branch validation against `BRANCH_RE`
- Deduplication guard (`mergedBranches` Set)
- Empty branch detection (skip no-change workers)
- Pre-wave checkpoint tags
- Conflict escalation flow
- Cleanup procedures

## Conflict Resolution

**Critical rule (C1)**: No auto-resolution. On ANY merge conflict, escalate to user.

```
Conflict detected in {file}
  |
  v
AskUserQuestion: How to resolve?
  |
  +-- "Accept theirs" -> git checkout --theirs {file} && git add {file}
  +-- "Accept ours"   -> git checkout --ours {file} && git add {file}
  +-- "Manual resolve" -> pause pipeline, user edits, git add, continue
  +-- "Abort merge"   -> git merge --abort, mark NEEDS_MANUAL_MERGE
```

**Why no auto-resolve**: `git checkout --theirs` replaces the ENTIRE file with the
incoming version, discarding all "ours" changes. This is too destructive for automated use.
User must make an informed choice for each conflict.

## Wave-Based Execution

Tasks are grouped into waves by dependency depth. Wave 0 has no dependencies, Wave N depends only on Wave 0..N-1. Each wave runs workers in parallel, then merges all branches before proceeding. Includes DFS cycle detection and pre-wave checkpoint tags.

See [wave-execution.md](references/wave-execution.md) for the full wave grouping, dependency depth calculation, and execution flow.

## Talisman Configuration

```yaml
work:
  worktree:
    enabled: false                    # Default: patch mode
    max_workers_per_wave: 3           # Max parallel workers per wave
    merge_strategy: "sequential"      # Only "sequential" supported
    auto_cleanup: true                # Remove worktrees after merge
    conflict_resolution: "escalate"   # "escalate" (ask user) | "abort"
    sparse_paths: []                  # empty = disabled; specify paths for cone-mode checkout
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `work.worktree.enabled` | boolean | `false` | Make worktree mode the default |
| `work.worktree.max_workers_per_wave` | number | `3` | Max parallel workers per wave |
| `work.worktree.merge_strategy` | string | `"sequential"` | Merge strategy (only sequential) |
| `work.worktree.auto_cleanup` | boolean | `true` | Auto-remove worktrees after merge |
| `work.worktree.conflict_resolution` | string | `"escalate"` | Conflict handling mode |
| `work.worktree.sparse_paths` | string[] | `[]` | Paths for cone-mode sparse checkout; empty = full checkout |

**Relationship to existing keys**:
- `work.max_workers` caps total workers across the session
- `work.worktree.max_workers_per_wave` caps per-wave concurrency
- Effective per-wave cap: `min(max_workers, max_workers_per_wave)`

## State File Extensions

When worktree mode is active, the state file (`tmp/.rune-work-{timestamp}.json`)
includes additional fields:

```javascript
{
  // ... existing fields ...
  worktree_mode: true,           // Absent in patch mode (falsy)
  waves: [[taskIds], [taskIds]], // Task IDs grouped by wave
  current_wave: 0,               // Currently executing wave index
  merged_branches: []             // Branches successfully merged
}
```

## Safety Notes

- **Blast radius reduction**: A rogue worker only damages its own worktree (primary benefit)
- **Disk usage**: Each worktree creates a full working copy (shared `.git` objects)
- **Dependency blindness**: Workers cannot see other workers' uncommitted changes
- **SDK canary**: Phase 0 validates `isolation: "worktree"` support before proceeding
- **Experimental**: Worktree mode is marked experimental in initial release

## Safety Net (Worktree Lifecycle Guard)

When Phase 6 cleanup is not reached (crash, session end, agent idle), three safety nets
ensure worktrees are eventually cleaned:

1. **Stop hook** (`on-session-stop.sh` Phase 4): Auto-cleans orphaned `rune-work-*` worktrees on session exit (capped at 3 for timeout budget)
2. **SessionStart** (`session-team-hygiene.sh`): Detects orphaned worktrees, reports to user
3. **`/rune:rest`**: Manual cleanup via standard mode or `--heal`

All three use the shared `scripts/lib/worktree-gc.sh` library with:
- PID liveness checks (never cleans live sessions' worktrees)
- `config_dir` isolation (cross-installation safety)
- `jq` dependency guard (fail-open if missing)
- Path traversal + symlink guards
- Salvage patches for uncommitted work (rest mode only)

## Known Limitations (Upstream)

| Issue | Impact | Workaround | Status |
|-------|--------|------------|--------|
| [#28041](https://github.com/anthropics/claude-code/issues/28041) | Worktrees don't include `.claude/` subdirs | `setup-worktree.sh` hook copies files | Active — hook mitigates |
| [#27436](https://github.com/anthropics/claude-code/issues/27436) | Bare repos hang during worktree creation | `setup-worktree.sh` emits post-creation advisory | Active — advisory only |
| [#29256](https://github.com/anthropics/claude-code/issues/29256) | `/resume` may not work in submodule worktrees | `setup-worktree.sh` emits submodule advisory | Active — advisory only |
| Model degradation | Worktree agents may lose project context | `WORKTREE_CONTEXT.md` reinforcement (~10% effective) | Mitigated |
| Disk space | Large repos can exhaust disk on worktree create | `setup-worktree.sh` pre-flight 2x safety check | Mitigated |
| Submodule false positive | `worktree-resolve.sh` misdetects submodule `.git` files | Fixed — checks `[[ -d .git ]]` not `[[ -e .git ]]` | Resolved |

## References

- [worktree-merge.md](../strive/references/worktree-merge.md) — Merge broker algorithm, conflict handling, cleanup
- [worker-prompts.md](../strive/references/worker-prompts.md) — Worker prompt templates (patch + worktree modes)
- [parse-plan.md](../strive/references/parse-plan.md) — Task extraction and dependency parsing
