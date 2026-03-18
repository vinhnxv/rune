# Arc Result Signal — Deterministic Completion Contract

Deterministic completion signal written by a PostToolUse hook at a well-known path after arc pipeline finishes.
External consumers (arc-batch, arc-issues stop hooks) read this signal instead of reverse-engineering checkpoint internals.

## Architecture (v1.109.2)

**Producer**: `scripts/arc-result-signal-writer.sh` — PostToolUse:Write|Edit hook
**Consumer**: `_read_arc_result_signal()` in `scripts/lib/stop-hook-common.sh`
**Trigger**: Every Write/Edit of a checkpoint file that has `ship` or `merge` phase completed

### Data Flow

```
Arc pipeline writes checkpoint.json (Write/Edit tool)
    ↓
PostToolUse:Write|Edit fires arc-result-signal-writer.sh
    ↓
Hook fast-path exits for non-checkpoint writes (< 5ms, grep check)
    ↓
Hook detects arc checkpoint pattern + ship/merge completed
    ↓
Hook writes tmp/arc-result-current.json atomically (mktemp + mv)
    ↓
Stop hooks read signal (primary) → checkpoint scan (fallback)
```

### Why Hook-Based (Not LLM-Instructed)

| Concern | LLM Instruction | PostToolUse Hook |
|---------|-----------------|------------------|
| Reliability | LLM may skip instruction | Deterministic — fires on every checkpoint write |
| Cost | Prompt tokens for instruction | Zero — shell script, no LLM involvement |
| Dual-writer risk | Two writers for same file | Single authoritative writer |
| Compaction survival | Instruction may be lost on compaction | Hook fires regardless of context state |
| Timing | Depends on LLM execution order | Fires immediately after Write/Edit completes |

## Signal Location

**Path**: `tmp/arc-result-current.json` (CWD-relative, overwritten each arc run)
**Session scoped**: Includes `owner_pid` and `config_dir` for multi-session safety

## Schema

```json
{
  "schema_version": 1,
  "arc_id": "arc-1772106447654",
  "plan_path": "plans/feat-deep-design.md",
  "status": "completed",
  "pr_url": "https://github.com/user/repo/pull/149",
  "completed_at": "2026-02-26T11:56:00Z",
  "phases_completed": 17,
  "phases_total": 26,
  "owner_pid": "36545",
  "config_dir": "/Users/user/.claude-custom"
}
```

## Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | yes | Always `1` |
| `arc_id` | string | yes | Arc run identifier |
| `plan_path` | string | yes | Relative path to plan file |
| `status` | string | yes | `"completed"` \| `"failed"`* \| `"partial"` |
| `pr_url` | string\|null | no | PR URL if ship phase completed |
| `completed_at` | string | yes | ISO-8601 timestamp |
| `phases_completed` | number | yes | Count of phases with status "completed" |
| `phases_total` | number | yes | Total phases in PHASE_ORDER |
| `owner_pid` | string | yes | `$PPID` of the Claude Code session |
| `config_dir` | string | yes | Resolved CLAUDE_CONFIG_DIR |

## Status Determination (in hook)

```
phases_failed > 0  →  "partial"
phases_failed == 0 →  "completed"
```

The `phases_failed` count is computed internally by the writer script and is **not emitted** in the signal JSON. Only the resulting `status` string (`"completed"` or `"partial"`) is written.

Note: The hook only fires when ship or merge phase is "completed" (Guard 5 in the script).
The "failed" status is never written by the hook — it's only possible via consumer fallback logic.

*`"failed"` is not produced by the hook; it exists only in consumer fallback logic when no signal is found.

## Consumer Contract

Stop hooks MUST:
1. Read `tmp/arc-result-current.json` FIRST (primary signal)
2. Verify `owner_pid == $PPID` (session isolation)
3. Verify `config_dir == $RUNE_CURRENT_CFG` (installation isolation)
4. Fall back to `_find_arc_checkpoint()` if signal file is missing/stale/wrong-session
5. **Delete the signal file after consumption** (`rm -f`) to prevent stale signal reuse across batch iterations. A signal from iteration N with `status: "completed"` must not bleed into iteration N+1 if that iteration fails before ship/merge.

**Note:** `arc-hierarchy-stop-hook.sh` does not consume this signal. Hierarchy completion
is determined by provides/requires contract verification (child plan dependency DAG),
not by individual arc status detection.

## Hook Guards (Fast-Path Design)

The hook fires on EVERY Write/Edit call. To minimize overhead:

| Guard | Check | Exit Time |
|-------|-------|-----------|
| 0 | `jq` available | < 1ms |
| 1 | stdin contains "checkpoint.json" (grep) | < 5ms |
| 2 | `tool_input.file_path` extractable | < 5ms |
| 3 | Path matches `*/.rune/arc/*/checkpoint.json` or `*/tmp/arc/*/checkpoint.json` | < 1ms |
| 4 | File exists and is not symlink | < 1ms |
| 5 | Ship or merge phase is "completed" | < 10ms (jq) |

99.9% of Write/Edit calls exit at Guard 1 (grep) in under 5ms.
