---
name: rune:rest
description: |
  Remove tmp/ output directories from completed Rune workflows (reviews, audits, plans, work, mend, inspect, arc).
  Preserves Rune Echoes (.claude/echoes/) and active workflow state files.
  Renamed from /rune:cleanup in v1.5.0 — "rest" as in a resting place for completed artifacts.

  <example>
  user: "/rune:rest"
  assistant: "Scanning for completed workflow artifacts in tmp/..."
  </example>
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - AskUserQuestion
---

# /rune:rest — Remove Workflow Artifacts

Remove ephemeral `tmp/` output directories from completed Rune workflows. Preserves Rune Echoes and active workflow state.

## What Gets Cleaned

| Directory | Contains | Cleaned? |
|-----------|----------|----------|
| `tmp/reviews/{id}/` | Review outputs, TOME.md, inscription.json | Yes (if completed) |
| `tmp/audit/{id}/` | Audit outputs, TOME.md | Yes (if completed) |
| `tmp/plans/{id}/` | Research findings, plan artifacts | Yes |
| `tmp/work/` | Work agent status files | Yes (if no active work team) |
| `tmp/scratch/` | Session scratch pads | Yes |
| `tmp/mend/{id}/` | Mend resolution reports, fixer outputs | Yes (if completed) |
| `tmp/inspect/{id}/` | Inspection outputs, VERDICT.md | Yes (if completed) |
| `tmp/arc/{id}/` | Arc pipeline artifacts (enriched plans, TOME, reports) | Yes (if completed) |
| `tmp/arc-batch/` | Batch progress, logs, config | Yes (if no active batch) |
| `tmp/gh-issues/` | GitHub Issues batch progress, issue list JSON | Yes (if no active arc-issues loop) |
| `tmp/gh-plans/` | Auto-generated plan files from GitHub Issues | Yes (if no active arc-issues loop) |
| `tmp/.talisman-resolved/` | Talisman shard resolver cache (JSON shards) | Yes (unconditional, regenerated at next SessionStart) |
| `tmp/.rune-signals/` | Event-driven signal files from Phase 2 hooks | Yes (unconditional, symlink-guarded) |
| `tmp/.rune-locks/` | Workflow lock directories (PID-guarded) | Yes (dead PIDs only; live PIDs preserved) |
| `~/.claude/teams/{rune-*/arc-*}/` (or `$CLAUDE_CONFIG_DIR/teams/` if set) | Orphaned team configs from crashed workflows | `--heal` only |
| `~/.claude/tasks/{rune-*/arc-*}/` (or `$CLAUDE_CONFIG_DIR/tasks/` if set) | Orphaned task lists from crashed workflows | `--heal` only |

**Note:** Per-agent artifact directories (`runs/` subdirectories containing `meta.json` and `input.md`) live inside workflow output directories (e.g., `tmp/plans/{id}/runs/`, `tmp/work/{id}/runs/`, `tmp/reviews/{id}/runs/`). They are cleaned implicitly when their parent workflow directory is removed — no separate cleanup entry is needed.

## What Is Preserved

| Path | Reason |
|------|--------|
| `.claude/echoes/` | Persistent project memory (Rune Echoes) |
| `.claude/arc/{id}/checkpoint.json` | Arc resume state (needed for --resume) |
| `tmp/.rune-review-*.json` (active) | Active workflow state |
| `tmp/.rune-audit-*.json` (active) | Active workflow state |
| `tmp/.rune-mend-*.json` (active) | Mend concurrency detection |
| `tmp/.rune-work-*.json` (active) | Active work workflow state |
| `tmp/.rune-inspect-*.json` (active) | Active inspect workflow state |
| `tmp/.rune-forge-*.json` (active) | Active forge workflow state |
| `tmp/.rune-batch-*.json` (active) | Active batch workflow state |
| `~/.claude/teams/{name}/` (active, < 30 min) | Teams referenced by active state files (`--heal` preserves these) |

## Steps

### 1. Check for Active Workflows

```javascript
// Look for active state files (status != completed, cancelled)
// ZSH-SAFE: Use Glob() — never raw shell globs (ZSH NOMATCH kills `ls tmp/*.json`)
const stateFiles = Glob("tmp/.rune-{review,audit,mend,work,inspect,forge,batch}-*.json")
```

```bash
# Check for active arc sessions via checkpoint.json
# Arc uses .claude/arc/*/checkpoint.json instead of tmp/.rune-arc-*.json state files
for f in .claude/arc/*/checkpoint.json(N); do
  [ -f "$f" ] || continue
  if grep -q '"status"[[:space:]]*:[[:space:]]*"in_progress"' "$f" 2>/dev/null; then
    arc_id=$(basename "$(dirname "$f")")
    echo "SKIP: tmp/arc/${arc_id}/ — active arc session detected"
    # Mark this arc's tmp dir as active (skip in cleanup)
  fi
done
```

For each state file found, read and check status:
- `"status": "active"` → **SKIP** associated directory, warn user
- `"status": "partial"` → **SKIP** associated directory, warn user (mend had failures — artifacts may be needed)
- `"status": "completed"` or `"status": "cancelled"` → Safe to clean

### 2. Inventory Artifacts

```bash
# List all tmp/ directories with sizes
du -sh tmp/reviews/*/  tmp/audit/*/  tmp/plans/*/  tmp/work/  tmp/scratch/  tmp/mend/*/  tmp/inspect/*/  tmp/arc/*/ 2>/dev/null
```

### 3. Confirm with User

Display summary:

```
Cleanup Summary:
  Reviews:  3 directories (2.1 MB)
  Audits:   1 directory  (800 KB)
  Plans:    2 directories (400 KB)
  Mend:     1 directory  (200 KB)
  Arc:      1 directory  (1.5 MB)
  Scratch:  1 directory  (50 KB)
  Total:    ~5.1 MB

Active workflows (PRESERVED):
  - tmp/.rune-review-142.json (active)
  - .claude/arc/abc123/checkpoint.json (arc resume state)

Proceed? [Y/n]
```

### 4. Validate Paths

Before removing any directory, verify paths are within `tmp/`:

```bash
# Validate each path resolves inside tmp/ (prevents traversal and symlink attacks)
# Portable path resolution (macOS BSD coreutils lack `realpath -s`)
_resolve_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" 2>/dev/null && pwd -P)
  elif [[ -d "$(dirname "$p")" ]]; then
    echo "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")"
  else
    echo ""
  fi
}

validated_dirs=()
tmp_base=$(_resolve_path "tmp")
if [[ -z "$tmp_base" ]]; then
  echo "ERROR: cannot resolve tmp/ base directory"
else
for dir in "${dirs_to_remove[@]}"; do
  # Reject symlinks — do not follow them
  if [[ -L "$dir" ]]; then
    echo "SKIP: $dir is a symlink (not following)"
    continue
  fi
  resolved=$(_resolve_path "$dir")
  if [[ -z "$resolved" || "$resolved" != "$tmp_base"/* ]]; then
    echo "SKIP: $dir resolves outside tmp/ ($resolved)"
    continue
  fi
  validated_dirs+=("$dir")
done
fi
```

Any path that resolves outside `tmp/` or is a symlink is skipped with a warning.

### 5. Remove Artifacts

Remove only paths that passed validation in Step 4:

```bash
# Remove validated workflow directories — re-verify at deletion time (close TOCTOU window)
# _resolve_path defined in Step 4 above (portable macOS-compatible path resolution)
tmp_base=$(_resolve_path "tmp")
for dir in "${validated_dirs[@]}"; do
  # Re-verify immediately before deletion (mitigates TOCTOU race)
  [[ -L "$dir" ]] && { echo "SKIP: $dir became a symlink (TOCTOU detected)"; continue; }
  resolved=$(_resolve_path "$dir")
  if [[ -n "$resolved" && -n "$tmp_base" && "$resolved" == "$tmp_base"/* ]]; then
    rm -rf "$resolved"
  else
    echo "SKIP: $dir now resolves outside tmp/ (TOCTOU detected: $resolved)"
  fi
done

# Helper: validate and remove a tmp/ subdirectory with symlink + path traversal guard
# Uses _resolve_path from Step 4. Logs permission errors instead of suppressing them.
_safe_remove_tmp_dir() {
  local dir="$1"
  local label="$2"
  [[ -L "$dir" ]] && { echo "SKIP: $dir is a symlink (not following)"; return 0; }
  [[ -d "$dir" ]] || return 0  # Nothing to remove
  local resolved
  resolved=$(_resolve_path "$dir")
  if [[ -z "$resolved" || "$resolved" != "$tmp_base"/* ]]; then
    echo "SKIP: $dir resolves outside tmp/ ($resolved)"
    return 0
  fi
  # Re-verify at deletion time (TOCTOU mitigation)
  [[ -L "$dir" ]] && { echo "SKIP: $dir became a symlink (TOCTOU detected)"; return 0; }
  if ! rm -rf "$resolved" 2>&1; then
    echo "WARN: failed to remove ${label:-$dir} — check permissions"
  fi
}

# Remove plan research artifacts (unconditional — no state file)
_safe_remove_tmp_dir "tmp/plans" "plans"

# Remove work artifacts — conditional on no active work teams
# Check work state files for active status (consistent with review/audit/mend checks)
active_work=""
for f in tmp/.rune-work-*.json(N); do
  [ -f "$f" ] && grep -q '"status"[[:space:]]*:[[:space:]]*"active"' "$f" && active_work="$f"
done
if [ -z "$active_work" ]; then
  _safe_remove_tmp_dir "tmp/work" "work"
else
  echo "SKIP: tmp/work/ — active work team detected"
fi

# Remove inspect artifacts — conditional on no active inspect sessions
active_inspect=""
for f in tmp/.rune-inspect-*.json(N); do
  [ -f "$f" ] && grep -q '"status"[[:space:]]*:[[:space:]]*"active"' "$f" && active_inspect="$f"
done
if [ -z "$active_inspect" ]; then
  _safe_remove_tmp_dir "tmp/inspect" "inspect"
else
  echo "SKIP: tmp/inspect/ — active inspect session detected"
fi

# Remove arc artifacts — conditional on no active arc sessions
# Arc uses .claude/arc/*/checkpoint.json (not tmp/.rune-arc-*.json state files)
active_arc=""
for f in .claude/arc/*/checkpoint.json(N); do
  [ -f "$f" ] || continue
  if grep -q '"status"[[:space:]]*:[[:space:]]*"in_progress"' "$f" 2>/dev/null; then
    active_arc="$f"
    arc_id=$(basename "$(dirname "$f")")
    echo "SKIP: tmp/arc/${arc_id}/ — active arc session"
  fi
done
if [ -z "$active_arc" ]; then
  _safe_remove_tmp_dir "tmp/arc" "arc"
else
  echo "SKIP: tmp/arc/ — active arc session detected (see above)"
fi

# Remove batch artifacts (only if no active batch — check state files)
active_batch=""
for f in tmp/.rune-batch-*.json(N); do
  [ -f "$f" ] || continue
  if command -v jq >/dev/null 2>&1; then
    batch_st=$(jq -r '.status // "unknown"' "$f" 2>/dev/null)
    if [[ "$batch_st" == "active" ]]; then
      active_batch="$f"
      echo "SKIP: tmp/arc-batch/ — active batch detected ($f)"
      break
    fi
  fi
done
if [ -z "$active_batch" ]; then
  _safe_remove_tmp_dir "tmp/arc-batch" "arc-batch"
fi

# Remove arc result signal file (v1.109.2+)
# Overwritten per arc run but stale signals can confuse future arc-batch/arc-issues runs.
rm -f tmp/arc-result-current.json 2>/dev/null

# Remove arc-phase loop artifacts (only if no active arc-phase loop)
# State file is .claude/arc-phase-loop.local.md (not tmp/)
arc_phase_state=".claude/arc-phase-loop.local.md"
if [ -f "$arc_phase_state" ] && ! [[ -L "$arc_phase_state" ]]; then
  active_phase=$(grep "^active:" "$arc_phase_state" 2>/dev/null | head -1 | sed 's/^active:[[:space:]]*//' || echo "")
  if [[ "$active_phase" == "true" ]]; then
    echo "SKIP: .claude/arc-phase-loop.local.md — active arc-phase loop detected"
  else
    rm -f "$arc_phase_state"
  fi
else
  rm -f "$arc_phase_state" 2>/dev/null
fi

# Remove arc-issues artifacts (only if no active arc-issues loop)
# State file is .claude/arc-issues-loop.local.md (not tmp/)
arc_issues_state=".claude/arc-issues-loop.local.md"
if [ -f "$arc_issues_state" ] && ! [[ -L "$arc_issues_state" ]]; then
  active_issues=$(grep "^active:" "$arc_issues_state" 2>/dev/null | head -1 | sed 's/^active:[[:space:]]*//' || echo "")
  if [[ "$active_issues" == "true" ]]; then
    echo "SKIP: tmp/gh-issues/ tmp/gh-plans/ — active arc-issues loop detected"
  else
    _safe_remove_tmp_dir "tmp/gh-issues" "gh-issues"
    _safe_remove_tmp_dir "tmp/gh-plans" "gh-plans"
  fi
else
  _safe_remove_tmp_dir "tmp/gh-issues" "gh-issues"
  _safe_remove_tmp_dir "tmp/gh-plans" "gh-plans"
fi

# Remove scratch files (unconditional — no state file)
_safe_remove_tmp_dir "tmp/scratch" "scratch"

# Talisman resolver cache (regenerated at next SessionStart)
_safe_remove_tmp_dir "tmp/.talisman-resolved" "talisman-resolved"

# Remove event-driven signal files with symlink guard (unconditional — ephemeral hook artifacts)
# Created by Phase 2 BRIDGE orchestrators when hooks are active. Safe no-op if absent.
# Note: _safe_remove_tmp_dir already includes symlink guard, but we keep the explicit
# check here for the find command that runs before removal.
if [[ ! -L "tmp/.rune-signals" ]] && [[ -d "tmp/.rune-signals" ]]; then
  # Remove .obs-* dedup files older than 7 days (on-task-observation.sh dedup keys)
  find tmp/.rune-signals -maxdepth 2 -name '.obs-*' -mtime +7 -delete 2>/dev/null || true
  _safe_remove_tmp_dir "tmp/.rune-signals" "rune-signals"
fi

# Clean up stale workflow lock directories (PID-guarded)
# Only remove locks whose owning PID is dead — live session locks are preserved.
if [[ ! -L "tmp/.rune-locks" ]] && [[ -d "tmp/.rune-locks" ]]; then
  for lock_dir in tmp/.rune-locks/*/; do
    [[ -d "$lock_dir" ]] || continue
    [[ -L "$lock_dir" ]] && continue  # skip symlinks
    if [[ -f "$lock_dir/meta.json" ]] && ! command -v jq >/dev/null 2>&1; then
      echo "  SKIP: $(basename "$lock_dir") — jq unavailable, cannot verify PID liveness"
      continue
    fi
    if [[ -f "$lock_dir/meta.json" ]] && command -v jq >/dev/null 2>&1; then
      stored_pid=$(jq -r '.pid // empty' "$lock_dir/meta.json" 2>/dev/null || true)
      if [[ -n "$stored_pid" && "$stored_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$stored_pid" 2>/dev/null; then
          echo "SKIP: $lock_dir — PID $stored_pid still alive"
          continue
        fi
      fi
    fi
    if ! rm -rf "$lock_dir" 2>&1; then
      echo "WARN: failed to remove $lock_dir — check permissions"
    fi
  done
  # Remove empty locks dir
  rmdir tmp/.rune-locks 2>/dev/null || true
fi

# Clean up stale git worktrees
# 1. Mend bisection worktrees (bisect-worktree)
git worktree list 2>/dev/null | grep 'bisect-worktree' | awk '{print $1}' | while read wt; do
  git worktree remove "$wt" --force 2>/dev/null
done

# 2. Strive worktrees (rune-work-*) — session-safe cleanup via shared GC library
#    WORKTREE-GC: Remove when SDK provides native worktree lifecycle management
if [[ -f "${CLAUDE_PLUGIN_ROOT}/scripts/lib/worktree-gc.sh" ]]; then
  source "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-session-identity.sh"
  source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/worktree-gc.sh"
  result=$(rune_worktree_gc "$(pwd)" "rest")
  [ -n "$result" ] && echo "$result"
else
  echo "NOTE: worktree-gc.sh not found — skipping rune-work-* cleanup"
fi

# 3. Final prune
git worktree prune 2>/dev/null

// Remove completed state files (per-file from earlier Glob discovery)
// ZSH-SAFE: iterate resolved paths — never use raw glob in Bash
for (const sf of completedStateFiles) {
  Bash(`rm -f "${sf}"`)  // "${sf}" is a resolved path — no shell glob
}
```

**Note:** `tmp/plans/` and `tmp/scratch/` are removed unconditionally (no active-state check). `tmp/work/` is conditionally removed — it checks for active work teams first (work proposals in `tmp/work/{timestamp}/proposals/` are needed during `--approve` mode). `tmp/mend/` directories follow the same active-state check as reviews and audits. `tmp/arc/` directories are checked via `.claude/arc/*/checkpoint.json` — if any phase has `in_progress` status, the associated `tmp/arc/{id}/` directory is preserved. Arc checkpoint state at `.claude/arc/` is not cleaned — it lives outside `tmp/` and is needed for `--resume`.

### 6. Cleanup Zombie tmux Sessions

Agent Teams workflows may leave orphaned tmux sessions (especially when teammates crash or are force-killed). Clean up any `claude-` prefixed sessions:

```bash
# Skip if tmux is not installed
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not installed — skipping zombie session cleanup."
else

# Only target claude-prefixed sessions (defense in depth — never kill user sessions)
zombie_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' || true)

if [ -n "$zombie_sessions" ]; then
  echo "Found zombie tmux sessions:"
  echo "$zombie_sessions" | while read -r sess; do
    echo "  - $sess"
  done

  # User already confirmed cleanup in Step 3 — proceed
  echo "$zombie_sessions" | while read -r sess; do
    tmux kill-session -t "$sess" 2>/dev/null || true
  done
  echo "Killed $(echo "$zombie_sessions" | wc -l | tr -d ' ') zombie tmux sessions."
else
  echo "No zombie tmux sessions found."
fi

fi  # end tmux availability check
```

**Safety**: Only sessions matching `claude-*` prefix are targeted. If `tmux` is not installed, the `command -v` check skips the entire block cleanly.

### 7. Report

```
Cleanup complete.
  Removed: 7 directories, ~3.4 MB freed
  Preserved: 1 active workflow (review #142)

Rune Echoes (.claude/echoes/) untouched.
```

## Flags

| Flag | Effect |
|------|--------|
| `--all` | Remove ALL tmp/ artifacts including active workflows. Still requires user confirmation (Step 3). |
| `--dry-run` | Show what would be removed without deleting. Combinable with `--all` and `--heal` to preview cleanup scope. |
| `--heal` | Recover orphaned resources from crashed workflows. Scans for stale state files and orphaned team/task dirs. Off by default. |

### --dry-run Example

```
[DRY RUN] Would remove:
  tmp/reviews/142/  (7 files, 1.2 MB)
  tmp/reviews/155/  (5 files, 900 KB)
  tmp/audit/20260211-103000/  (8 files, 800 KB)
  tmp/.rune-review-142.json  (completed)
  tmp/.rune-review-155.json  (completed)
  tmp/.rune-audit-20260211-103000.json  (cancelled)

Would preserve:
  .claude/echoes/  (persistent memory)
```

### --heal Mode

Recovers orphaned resources from crashed workflows. Unlike `--all` (which removes everything), `--heal` specifically targets stale state files and orphaned team/task directories that were left behind when a sub-command crashed before reaching its cleanup phase.

**Why `--heal` not `--force`**: `--force` implies "delete everything including active". `--heal` conveys "fix broken state" — specifically targets orphans while protecting genuinely active workflows.

#### Algorithm

```
// STEP 1: Partition active state files into stale vs active
const ORPHAN_STALE_THRESHOLD = 1_800_000  // 30 min (CC-6)
const staleStateFiles = []
const activeStateFiles = []  // CC-1 FIX: separate list for safety check

// See team-lifecycle-guard.md §Stale State File Scan Contract for canonical type list and threshold
for (const type of ["work", "review", "mend", "audit", "forge", "inspect", "batch"]) {  // CC-4: include forge, QUAL-003: include batch, v1.50.0: include inspect
  const files = Glob(`tmp/.rune-${type}-*.json`)
  for (const f of files) {
    try {
      const state = JSON.parse(Read(f))
      if (state.status !== "active") continue
      // isStale: age > threshold. NaN (missing/malformed started) → treat as stale.
      const age = Date.now() - new Date(state.started).getTime()
      if (Number.isNaN(age) || age > ORPHAN_STALE_THRESHOLD) {
        staleStateFiles.push({ file: f, state, type })
      } else {
        activeStateFiles.push({ file: f, state, type })  // CC-1 FIX: track active separately
      }
    } catch (e) {
      warn(`${f}: unreadable — skipping`)
    }
  }
}

// STEP 2: Scan teams dir for orphaned rune-prefixed team dirs
// CHOME pattern: resolve CLAUDE_CONFIG_DIR for multi-account support
const CHOME = Bash(`echo "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`).trim()
const RUNE_TEAM_PATTERN = /^(rune-work|rune-review|rune-mend|rune-audit|rune-plan|rune-forge|rune-inspect|arc-forge|arc-plan-review|arc-verify)-/
const teamDirsRaw = Bash(`find "${CHOME}/teams" -mindepth 1 -maxdepth 1 -type d 2>/dev/null`)  // CC-3: find not ls; -mindepth 1 excludes base dir
const teamDirs = teamDirsRaw.split('\n').filter(Boolean)
// BACK-003 FIX: Warn when teams directory is missing (matches error handling table promise)
if (teamDirs.length === 0 && !Bash(`test -d "${CHOME}/teams" && echo ok 2>/dev/null`).includes("ok")) {
  warn(`${CHOME}/teams/ not found — skipping team dir scan`)
}
const orphanedTeams = []

for (const dir of teamDirs) {
  const teamName = basename(dir)
  if (!RUNE_TEAM_PATTERN.test(teamName)) continue  // Not a rune team — skip
  if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) continue  // Invalid name — skip

  // Check if any ACTIVE state file references this team (CC-1 FIX: check active, not stale)
  const isReferenced = activeStateFiles.some(s =>
    s.state.team_name === teamName
  )
  if (isReferenced) continue  // Team is actively used — skip

  orphanedTeams.push(teamName)
}

// STEP 2.5: Scan for orphaned arc checkpoint directories (v1.110.0)
// Checkpoints in .claude/arc/ and tmp/arc/ with dead owner_pid are orphaned.
// Same ownership logic as session-team-hygiene.sh (Bug 2 fix).
const orphanedCheckpoints = []
const CHOME_RESOLVED = Bash(`cd "${CHOME}" 2>/dev/null && pwd -P`).trim()
for (const baseDir of [".claude/arc", "tmp/arc"]) {
  const checkpointFiles = Glob(`${baseDir}/*/checkpoint.json`)
  for (const ckptFile of checkpointFiles) {
    try {
      const ckpt = JSON.parse(Read(ckptFile))
      const ckptPid = ckpt.owner_pid
      const ckptCfg = ckpt.config_dir
      // Skip if no owner_pid (backward compat with pre-session-isolation checkpoints)
      if (!ckptPid) continue
      // Validate PID is numeric before shell interpolation (SEC-002)
      if (!/^\d+$/.test(String(ckptPid))) continue
      // Skip if different config_dir (different installation)
      if (ckptCfg && CHOME_RESOLVED && ckptCfg !== CHOME_RESOLVED) continue
      // Skip if owner is alive (another active session)
      const isAlive = Bash(`kill -0 ${ckptPid} 2>/dev/null && echo alive`).includes("alive")
      if (isAlive) continue
      // Dead owner — orphaned checkpoint
      orphanedCheckpoints.push(dirname(ckptFile))
    } catch (e) {
      warn(`${ckptFile}: unreadable — skipping`)
    }
  }
}

// STEP 3: Present and confirm
if (staleStateFiles.length === 0 && orphanedTeams.length === 0 && orphanedCheckpoints.length === 0) {
  log("No orphaned resources found. System is clean.")
  return
}

AskUserQuestion({
  questions: [{
    question: `Found ${staleStateFiles.length} stale state files, ${orphanedTeams.length} orphaned teams, and ${orphanedCheckpoints.length} orphaned checkpoints. Clean up?`,
    header: "Heal",
    options: [
      { label: "Clean all (Recommended)", description: "Remove orphaned teams + reset stale state files" },
      { label: "Dry run", description: "Show what would be cleaned without removing" },
      { label: "Cancel", description: "Leave everything as-is" }
    ]
  }]
})

// STEP 4: Execute cleanup
for (const teamName of orphanedTeams) {
  // Inline rm -rf pattern (TeamDelete skipped — orphaned teams have no active session)
  // Defense-in-depth: re-validate name AND path (SEC-009)
  if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) continue
  // Validate resolved paths stay inside CHOME (path traversal guard)
  const teamsTarget = `${CHOME}/teams/${teamName}/`
  const tasksTarget = `${CHOME}/tasks/${teamName}/`
  const resolvedTeams = Bash(`cd "${CHOME}/teams/${teamName}" 2>/dev/null && pwd -P || echo ""`).trim()
  const resolvedTasks = Bash(`cd "${CHOME}/tasks/${teamName}" 2>/dev/null && pwd -P || echo ""`).trim()
  if (resolvedTeams && !resolvedTeams.startsWith(CHOME_RESOLVED + "/teams/")) {
    warn(`SKIP: ${teamsTarget} resolves outside expected dir (${resolvedTeams})`)
    continue
  }
  if (resolvedTasks && !resolvedTasks.startsWith(CHOME_RESOLVED + "/tasks/")) {
    warn(`SKIP: ${tasksTarget} resolves outside expected dir (${resolvedTasks})`)
    continue
  }
  // Surface permission errors instead of suppressing them (VEIL-008)
  const result = Bash(`rm -rf "${CHOME}/teams/${teamName}/" "${CHOME}/tasks/${teamName}/" 2>&1`)
  if (result) warn(`Heal cleanup warning for team ${teamName}: ${result}`)
}

for (const { file, state } of staleStateFiles) {
  state.status = "completed"
  state.completed = new Date().toISOString()
  state.crash_recovered = true
  Write(file, JSON.stringify(state))
}

// STEP 5: Clean orphaned signal directories
// BACK-006 FIX: Also match teams from staleStateFiles (their team dirs may already be gone
// but signal dirs can persist if the team dir was manually deleted)
const staleTeamNames = staleStateFiles.map(s => s.state.team_name).filter(Boolean)
const signalDirs = Glob("tmp/.rune-signals/*/")
for (const dir of signalDirs) {
  const teamName = basename(dir)
  if (!/^[a-zA-Z0-9_-]+$/.test(teamName)) continue  // SEC-009: validate dir name
  if (orphanedTeams.includes(teamName) || staleTeamNames.includes(teamName)) {
    // Validate path stays inside tmp/.rune-signals/ (SEC-009)
    const resolved = Bash(`cd "${dir}" 2>/dev/null && pwd -P || echo ""`).trim()
    if (!resolved || !resolved.includes("/tmp/.rune-signals/")) {
      warn(`SKIP: ${dir} resolves outside expected dir (${resolved})`)
      continue
    }
    const result = Bash(`rm -rf "${dir}" 2>&1`)  // VEIL-008: surface errors
    if (result) warn(`Signal dir cleanup warning: ${result}`)
  }
}

// STEP 5.5: Remove orphaned arc checkpoint directories (v1.110.0)
// Discovered in STEP 2.5 — execute cleanup here alongside other removals.
for (const dir of orphanedCheckpoints) {
  // SEC-009: validate resolved path stays inside expected base dirs
  const resolved = Bash(`cd "${dir}" 2>/dev/null && pwd -P || echo ""`).trim()
  if (!resolved || (!resolved.includes("/.claude/arc/") && !resolved.includes("/tmp/arc/"))) {
    warn(`SKIP: ${dir} resolves outside expected dir (${resolved})`)
    continue
  }
  const result = Bash(`rm -rf "${dir}" 2>&1`)  // VEIL-008: surface errors
  if (result) warn(`Checkpoint cleanup warning: ${result}`)
}

// STEP 6: Report
log(`Heal complete.`)
log(`  Stale state files reset: ${staleStateFiles.length}`)
log(`  Orphaned teams removed: ${orphanedTeams.length}`)
log(`  Orphaned checkpoints removed: ${orphanedCheckpoints.length}`)
```

**Staleness heuristic**: A state file is considered stale if `status === "active"` AND `started` is older than 30 minutes. This is 2x the longest inner timeout (15 min), providing margin for slow workflows while still catching genuine crashes.

**Safety guarantees**:
- Active state files (< 30 min, status "active") are never touched
- Team dirs referenced by active state files are preserved
- User confirmation required before any cleanup
- Team name validated with `/^[a-zA-Z0-9_-]+$/` before any `rm -rf`
- Uses `find` instead of `ls` for team dir scanning (SEC-007 compliance)
- All cleanup targets validated via path resolution before removal (SEC-009 compliance)
- Permission errors surfaced as warnings, never silently suppressed (VEIL-008 compliance)

## Error Handling

| Error | Recovery |
|-------|----------|
| `tmp/` doesn't exist | Report "Nothing to clean" |
| State file unreadable (corrupt JSON) | Treat associated directory as active (skip) |
| Path resolves outside `tmp/` | Skip with warning, do not delete |
| Permission denied on remove | Report which directories failed, continue with rest |
| `~/.claude/teams/` not accessible (`--heal`) | Report warning, skip team dir scan, still process stale state files |
| Team dir removal failed (`--heal`) | Log team name and error, continue with remaining orphans |
| State file update failed (`--heal`) | Log file path, skip to next stale file (do not halt) |

## Notes

- This command is safe to run at any time — active workflows are detected and preserved
- Rune Echoes are not touched by cleanup (they live in `.claude/echoes/`, not `tmp/`)
- Completed/cancelled state files are removed along with their output directories
- If `tmp/` directory doesn't exist, reports "Nothing to clean"
- Stale git worktrees from mend bisection are cleaned up (`git worktree prune`)
