# Incremental Audit — State Schema & Persistence Layer

> Defines the JSON schemas, atomic write protocol, locking mechanism, and session isolation for the incremental audit state store.

## State Directory

```
.rune/audit-state/
├── manifest.json         # Codebase inventory (file metadata)
├── state.json            # Per-file audit records
├── workflows.json        # Cross-file workflow tracking (Tier 2)
├── apis.json             # Endpoint contract tracking (Tier 3)
├── checkpoint.json       # Crash resume support
├── coverage-report.md    # Human-readable dashboard
├── .lock/                # Advisory lock directory (mkdir-based)
│   └── meta.json         # Lock owner metadata
└── history/              # Per-session snapshots
    ├── audit-{id}.json
    └── archive/          # Compressed old snapshots
```

**Default**: `.rune/audit-state/` is gitignored. Set `talisman.audit.incremental.version_controlled: true` to track in git.

## manifest.json Schema

```json
{
  "schema_version": 1,
  "project_root": "/path/to/project",
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "last_commit_hash": "abc123",
  "total_files": 342,
  "files": {
    "src/auth/service.ts": {
      "path": "src/auth/service.ts",
      "size_bytes": 4250,
      "line_count": 142,
      "extension": ".ts",
      "category": "backend",
      "git": {
        "created_at": "ISO8601",
        "modified_at": "ISO8601",
        "current_hash": "a1b2c3d",
        "contributors": ["alice", "bob"],
        "contributor_count": 2,
        "commit_count_90d": 12,
        "churn_90d": 340
      },
      "status": "tracked"
    }
  }
}
```

**File status values**: `tracked`, `excluded`, `deleted`

### Manifest Diff Events

| Event | Detection | Action |
|-------|-----------|--------|
| File created | Path not in previous manifest | Add with `staleness = MAX` |
| File modified | `git_hash` differs from last audit | Invalidate audit, boost recency |
| File deleted | Path not in current filesystem | Mark `status: "deleted"` |
| File renamed | `git log --follow --diff-filter=R` | Transfer audit history |

## state.json Schema

```json
{
  "schema_version": 1,
  "project_root": "/path/to/project",
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "total_sessions": 5,
  "config_dir": "...",
  "owner_pid": "...",
  "session_id": "...",
  "files": {
    "src/auth/service.ts": {
      "last_audited": "ISO8601",
      "last_audit_id": "20260223-143000",
      "last_git_hash": "a1b2c3d",
      "changed_since_audit": false,
      "audit_count": 3,
      "audited_by": ["forge-warden", "ward-sentinel"],
      "findings": {
        "P1": 0, "P2": 1, "P3": 2,
        "total": 3,
        "last_tome_ref": "tmp/audit/20260223-143000/TOME.md"
      },
      "last_risk_tier": "HIGH",
      "coverage_gap_streak": 0,
      "consecutive_error_count": 0,
      "previous_paths": [],
      "status": "audited"
    }
  },
  "coverage_gaps": {
    "src/utils/parser.ts": {
      "gap_count": 3,
      "first_seen": "2026-02-20",
      "reason": "budget_exceeded",
      "last_attempted": "2026-02-22"
    }
  },
  "stats": {
    "total_auditable": 342,
    "total_audited": 189,
    "total_never_audited": 153,
    "coverage_pct": 55.3,
    "freshness_pct": 38.0,
    "avg_findings_per_file": 1.2,
    "avg_ashes_per_file": 2.4
  }
}
```

**File status values**: `audited`, `partial`, `stale`, `excluded`, `deleted`, `error`, `error_permanent`, `never_audited`

## checkpoint.json Schema

```json
{
  "audit_id": "20260223-143000",
  "started_at": "ISO8601",
  "batch": ["file1.ts", "file2.ts", "file3.ts"],
  "completed": ["file1.ts"],
  "current_file": "file2.ts",
  "team_name": "rune-audit-20260223-143000",
  "status": "active",
  "config_dir": "...",
  "owner_pid": "...",
  "session_id": "..."
}
```

## Session History Schema

```json
{
  "audit_id": "20260223-143000",
  "timestamp": "ISO8601",
  "mode": "incremental",
  "depth": "deep",
  "batch_size": 30,
  "files_planned": ["src/auth/service.ts"],
  "files_completed": ["src/auth/service.ts"],
  "files_failed": [],
  "total_findings": 24,
  "findings_by_severity": { "P1": 2, "P2": 8, "P3": 14 },
  "coverage_before": 52.1,
  "coverage_after": 55.3,
  "duration_seconds": 420,
  "config_dir": "...",
  "owner_pid": "...",
  "session_id": "..."
}
```

**History management**: Keep last 50 snapshots. Archive older ones.

## Atomic Write Protocol

All state file writes follow the 3-step atomic protocol:

```bash
# 1. Write to temp file
write_json(data, ".rune/audit-state/state.json.tmp")
# 2. fsync temp file (flush to disk)
sync  # or fsync on the temp file
# 3. Rename temp to target (atomic on POSIX)
mv ".rune/audit-state/state.json.tmp" ".rune/audit-state/state.json"
```

**Pre-flight cleanup**: On startup, delete any leftover `.tmp` files:

```bash
for tmpFile in .rune/audit-state/*.tmp; do
  [ -f "$tmpFile" ] && rm -f "$tmpFile"
done
```

Never recover from `.tmp` files — always treat them as potentially corrupt.

## Locking Protocol (TOCTOU-Hardened)

Uses `mkdir` as an atomic lock primitive (POSIX-atomic create-or-fail):

```
Lock directory: .rune/audit-state/.lock/
Lock metadata:  .rune/audit-state/.lock/meta.json

acquireLock():
  1. mkdir .lock/ (atomic — fails if exists)
  2. If EEXIST:
     a. Read meta.json
     b. If config_dir mismatch → SKIP (different installation)
     c. If PID alive (kill -0) AND process is node/claude → SKIP (active session)
     d. Otherwise → stale lock, rm -rf .lock/, retry mkdir once
  3. Write meta.json: { pid, config_dir, started_at, session_id, heartbeat_at }
  4. Return ACQUIRED

releaseLock():
  1. Read meta.json
  2. If pid matches $PPID → rm -rf .lock/
  3. Otherwise → skip (not our lock)
```

**PID verification**: Check `ps -p PID -o comm=` for `node` (Claude Code runs as node, not "claude").

**Heartbeat**: Update `heartbeat_at` field periodically. Stale if `heartbeat_at > 5 minutes`.

## Schema Migration

State files include `schema_version` for non-breaking evolution:

```
loadState(path):
  1. Read file, validate JSON
  2. If empty/corrupt → backup + initFreshState()
  3. If schema_version < CURRENT → backup + run migrations + atomicWrite
  4. Return state

Migrations are additive-only (add fields with defaults, never remove).
CURRENT_VERSION = 1 at launch.
```

## State Rebuild from History

If `state.json` is corrupted, rebuild by replaying history files:

```
rebuildFromHistory():
  1. Init fresh state
  2. Sort history files chronologically
  3. For each session: merge completed files into state
  4. Recompute stats
  5. Fields NOT reconstructable: coverage_gap_streak (reset to 0), changed_since_audit (recompute via git)
```

## Manifest-State Reconciliation

After manifest diff, reconcile with state.json:

1. Path in manifest NOT in state → add as `never_audited`
2. Path in state NOT in manifest → mark `deleted` or migrate (rename)
3. Recompute all derived stats; warn if stored vs computed differ by >1%

## Coverage Gap Lifecycle

- **Created**: File is skipped in batch (budget_exceeded, error)
- **Incremented**: Each session the file is eligible but skipped
- **Evicted**: File is successfully audited OR `gap_count > 10` (chronic skip)
- **Cap**: Maximum 100 active gaps; lowest-priority evicted first

## Extension Point Contract

The incremental layer inserts between Phase 0 and Phase 0.5 with 8 sub-phases:

```
Phase 0:     all_files = find(.)                          # Existing
Phase 0.0:   statusOnlyExit(flags)                        # NEW - report only (--status)
Phase 0.0.5: resetIfRequested(flags)                      # NEW - state reset (--reset)
Phase 0.1:   acquireLock + initStateDir                   # NEW - TOCTOU-hardened lock
Phase 0.1.5: resumeCheck(flags)                           # NEW - crash resume (--resume)
Phase 0.2:   manifest = buildManifest(all_files)          # NEW - file inventory
Phase 0.3:   diffManifest + reconcileState                # NEW - state reconciliation
Phase 0.3.5: scored = priorityScore(manifest, state)      # NEW - 6-factor composite scoring
Phase 0.4:   batch = selectBatch(scored, config)          # NEW - top-N selection, Tier 2/3 integration
Phase 0.5:   Lore Layer (operates on batch, not all)      # Existing (scoped)

Input:  all_files: string[]
Output: batch: string[] (filtered all_files array passed to orchestration)
Side effect: state.json updated with manifest diff
```

**Non-incremental early return**: `if (!flags['--incremental']) return { batch: allFiles }` — zero overhead when flag not set.

## Error Handling

| Error | Severity | Recovery |
|-------|----------|----------|
| State file corrupted | DEGRADED | Rebuild from history/ |
| State file locked (dead PID) | TRANSIENT | Detect dead PID, remove lock |
| Git not available | DEGRADED | mtime-based scoring (no rename, no Lore) |
| File unreadable during audit | TRANSIENT | Mark `error`, re-queue next batch |
| Audit interrupted | TRANSIENT | Resume from checkpoint |
| Concurrent audit sessions | TRANSIENT | Second session warns, skips incremental |
| Manifest too large (>10k) | DEGRADED | Split by top-level directory |
| Lore Layer unavailable | DEGRADED | Score with risk = 5.0 (MEDIUM default) |
| PID reuse on lock | TRANSIENT | Secondary check process name |
| Error file infinite re-queue | DEGRADED | 1st re-queue, 2nd skip-one, 3rd+ permanent |
| Disk full | FATAL | Pre-flight check: skip if <10MB available |
