# Arc State File Integrity Subsystem

Canary reference for the arc phase-loop state file reliability subsystem introduced in v2.53.0. Documents the library contract, the integrity log schema, the flag lifecycle, and the security invariants that gate every deletion and write.

Source plan: [/Users/vinhnx/Desktop/repos/rune/plans/2026-04-17-fix-arc-state-file-reliability-plan.md](/Users/vinhnx/Desktop/repos/rune/plans/2026-04-17-fix-arc-state-file-reliability-plan.md) (see §4.1–§4.3, §5.1, §6.2, §14, §16).

## Overview

**What.** The subsystem centralizes creation, refresh, and deletion decisions for `.rune/arc-${loop_kind}-loop.local.md` state files. Three collaborating components share one library — `scripts/lib/arc-loop-state.sh` — so the stop-hook loop, the init script, and the PostToolUse verifier never drift on deletion semantics, symlink handling, or atomic-write sequencing.

**Why.** Pre-v2.53.0 the stop hook deleted the state file on ambiguous stop reasons, then the next phase turn found no state and halted. The same code path had no audit trail, no symlink defense, and no way to distinguish "work complete" from "jq crashed mid-decode." The canary introduces one deletion rubric (plan §4.3), one integrity log (plan §14), and one flag that gates enforced writes while observation-only dry-run entries accumulate evidence.

**Canary state (this patch).** Shipped as observation-only. The `arc.state_file.code_enforced_writes` talisman flag defaults to `false` — the PostToolUse verify hook emits `dry_run: true` log entries but does NOT write or mutate state files. Enforced writes activate on explicit flag flip after the log evidence is reviewed.

## Components

| File | Role | Lines |
|------|------|------:|
| [/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/lib/arc-loop-state.sh](/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/lib/arc-loop-state.sh) | Library: 7 public functions + trace wrapper + constants | 481 |
| [/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/rune-arc-init-state.sh](/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/rune-arc-init-state.sh) | Atomic initializer invoked by arc bootstrap and `arc_state_recover` | 464 |
| [/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/verify-arc-state-integrity.sh](/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/verify-arc-state-integrity.sh) | PostToolUse hook: observes + optionally repairs on `.rune/arc/*/checkpoint.json` writes | 178 |
| [/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/arc-phase-stop-hook.sh](/Users/vinhnx/Desktop/repos/rune/plugins/rune/scripts/arc-phase-stop-hook.sh) | Consumer: calls `arc_state_should_delete` before any deletion | n/a (existing) |
| `.rune/arc-integrity-log.jsonl` | Append-only JSONL log, rotated at 5 MB, 5 archives retained | runtime |
| `.rune/arc-${loop_kind}-loop.local.md` | The state file itself (phase \| batch \| hierarchy \| issues) | runtime |

## Library API

Every function is safe to call outside an arc context — missing inputs return a defer/no-op code with an integrity log entry if possible. All functions are Bash 3.2 portable.

| Function | Signature | Purpose |
|----------|-----------|---------|
| `arc_state_file_path` | `arc_state_file_path [kind]` → stdout path, exit 1 on invalid kind | Canonical path resolver. Rejects kinds outside `{phase, batch, hierarchy, issues}`. |
| `arc_state_flag_enabled` | `arc_state_flag_enabled` → exit 0 if `arc.state_file.code_enforced_writes=true` else 1 | Reads the resolved talisman shard (`tmp/.talisman-resolved/arc.json`). Never gates security checks — flag is OPERATIONAL only (plan §4.1). |
| `arc_state_integrity_log` | `arc_state_integrity_log action cause state_file [extra_json] [arc_id] [loop_kind] [checkpoint_path] [pending_str] [mtime_age_str]` → exit 0 | Append-only JSONL entry with atomic `>>` append under `PIPE_BUF`. Rotates the log under a `mkdir` lock (XM-4). Refuses symlinks (SEC-002). |
| `arc_state_touch` | `arc_state_touch state_file` → exit 0 | Mtime-only refresh, throttled by `RUNE_ARC_STATE_TOUCH_THROTTLE_SEC`. R27 invariant — NEVER rewrites content. |
| `arc_state_pending_phases` | `arc_state_pending_phases checkpoint_path` → stdout int count, -1 on error | Counts `.phases[] | select(.status=="pending" or .status=="in_progress")`. Returns -1 on any jq failure so callers defer deletion safely (XM-3 / AC-14). |
| `arc_state_should_delete` | `arc_state_should_delete state_file` → exit 0 delete \| 1 defer | 3-criterion rubric (plan §4.3): tooling availability, pending-phase count, stop_reason allowlist. Defer is the safe default — jq missing, checkpoint missing, jq parse error, pending phases > 0, or ambiguous stop_reason all return 1. Delete only on `stop_reason ∈ {completed, cancelled, context_limit}` with zero pending phases. |
| `arc_state_recover` | `arc_state_recover [kind]` → exit 0 on recreate \| 1 on no-checkpoint | Delegates to `rune-arc-init-state.sh create` in recovery mode. Library does not perform atomic write itself (AC-5). |

## Integrity Log Schema

Schema derived from plan §14.1 (base identity) + §14.4 (extended diagnostic). `.rune/arc-integrity-log.jsonl` — one JSON object per line. Rotated when file exceeds `RUNE_ARC_INTEG_LOG_MAX_BYTES` (10 MB default).

Status legend:
- **Shipped** — emitted by `arc_state_integrity_log` in v2.53.0.
- **Deferred** — specified in §14.4 but not yet populated; reserved as `null`/absent. Closes when plan AC-12 through AC-15 land (§4.3 forge enrichment).

| # | Field | Type | §-ref | Status | Notes |
|--:|-------|------|-------|--------|-------|
| 1 | `ts` | ISO-8601 UTC string | §14.1 | Shipped | `date -u +%Y-%m-%dT%H:%M:%SZ` |
| 2 | `session_id` | string | §14.1 | Shipped | `RUNE_SESSION_ID` → `CLAUDE_SESSION_ID` → `"unknown"`. SEC-4 sanitized. |
| 3 | `owner_pid` | string | §14.1 | Shipped | `$PPID`; coerced to `"0"` if non-numeric. |
| 4 | `config_dir` | string | §14.1 | Shipped | Resolved via `cd … && pwd -P` — physical, not symlink. |
| 5 | `action` | string | §14.1 | Shipped | One of: `recovered_mid_arc`, `recovered_post_checkpoint_write`, `symlink_rejected`, `flag_lookup_failed`, `deletion_deferred_*`, `legitimate_stale_delete`, `legitimate_completion_delete`, `recovery_failed_no_checkpoint`, `corrupted_write`, `failed_write`, `failed_verify`. |
| 6 | `cause` | string | §14.1 | Shipped | Freeform — caller supplies. |
| 7 | `source_script` | string | §14.1 | Shipped | `BASH_SOURCE[1]##*/`. |
| 8 | `state_file_path` | string | §14.1 | Shipped | Caller-supplied; may be empty. |
| 9 | `arc_id` | string \| "" | §14.1 | Shipped (v2.53.0) | Strict `^arc-[0-9]+$` post-check. Reject-to-empty on drift (CWE-22). |
| 10 | `loop_kind` | enum | §14.1 | Shipped (v2.53.0) | Allowlist: `phase \| batch \| hierarchy \| issues`. Default `phase` on drift. |
| 11 | `checkpoint_path` | string | §14.1 | Shipped (v2.53.0) | Absolute path. Blank when checkpoint missing. |
| 12 | `pending_phase_count` | int \| null | §14.1 | Shipped (v2.53.0) | `null` on parse error. Supplied by `arc_state_pending_phases`. |
| 13 | `mtime_age_sec` | int \| null | §14.1 | Shipped (v2.53.0) | `null` when `stat` unavailable or target missing. |
| 14 | `extra` | object | §14.1 (`details`) | Shipped | Free-form caller JSON. `try fromjson catch {}` — corrupt extra degrades to `{}`. |
| 15 | `severity` | enum | §14.4 | Shipped | `info \| warn \| error`. Derived from `action` via case table. |
| 16 | `event_class` | enum | §14.4 | Shipped | `lifecycle \| recovery \| deletion \| failure`. |
| 17 | `flag_enabled` | bool | §14.4 | Shipped | Snapshot of `arc_state_flag_enabled` at log time. |
| 18 | `dry_run` | bool | §14.4 | Shipped | `true` when flag is false but hook fired. |
| 19 | `plugin_version` | string | §14.4 | Shipped (v2.53.0) | `_RUNE_ARC_PLUGIN_VERSION` read at lib source time. |
| 20 | `current_phase` | string | §14.4 | Deferred | Requires checkpoint re-read at log time — deferred to AC-12. |
| 21 | `git_head` | string (short SHA) | §14.4 | Deferred | Requires safe `git rev-parse` without spawning per-entry. Deferred to AC-13. |
| 22 | `talisman_stale_multiplier` | number | §14.4 | Deferred | Requires config-stale detection; deferred to AC-15. |

Plan §14.4 also enumerates `tool_use_n` as a diagnostic field. It is **not** currently emitted and not counted above; track under the same AC-12 follow-up.

## Flag Lifecycle

The `arc.state_file.code_enforced_writes` flag is intentionally opaque to security code — it controls whether the PostToolUse verify hook mutates state, not whether integrity checks run. See plan §4.1 and §5.1.

```
   Phase A (shipped)                 Phase B                    Phase C
   ───────────────────               ─────────                   ───────
   code_enforced_writes:            Operator flips flag         Flag stays true.
     false  (default)        ─▶     to true after log           PostToolUse verify
                                    review shows 0               actively writes /
                                    error-class entries.         repairs state files.
   PostToolUse verify:              PostToolUse verify
     DRY-RUN — log entries            writes + logs. Logs
     tagged `dry_run: true`.          become audit trail, not
     NEVER writes state.              observation-only.
```

**Trigger for flip.** Operator scans `.rune/arc-integrity-log.jsonl` across a rolling 7-day window and confirms:
- No `severity: error` entries.
- `deletion_deferred_*` rate is stable and expected (no drift toward 100%).
- Every `recovered_*` entry reconciled to a real checkpoint-write race.

**Rollback.** Set `arc.state_file.code_enforced_writes: false` in `talisman.yml`. Flag is read per-call via `arc_state_flag_enabled`, so rollback takes effect at the next state operation — no process restart required.

## Security Invariants

The subsystem must hold these invariants even when talisman, jq, or the checkpoint are unavailable. The flag does **not** gate any of them.

| ID | Concern | Location | Enforcement |
|----|---------|----------|-------------|
| CWE-22 (arc_id) | Path traversal via injected `arc_id` | `arc_state_integrity_log` | Strict allowlist: `^arc-[0-9]+$`. Any drift (`arc-../etc`, `arc-`, `arc-foo`) → empty string and entry still written for evidence. |
| CWE-61 (symlink) | Follow-symlink on log or state file | `arc_state_integrity_log`, `arc_state_touch` | Explicit `[ -L "$path" ] && return 0` BEFORE `mkdir -p` / `touch`. Double-check for TOCTOU between `mkdir -p` and `mv` during rotation. |
| CWE-93 (JSONL injection) | Newline/control chars in `cause`, `extra` | `arc_state_integrity_log` | All string fields routed through `jq --arg` (escapes embedded quotes + newlines). `extra` parsed via `try fromjson catch {}` — malformed JSON degrades to `{}`. |
| XM-1 (atomic write) | Partial state file from interrupted write | `rune-arc-init-state.sh` | Write to `…/arc-${kind}-loop.local.md.tmp.$$`, `sync`, `mv -f` into place. Library does not perform the atomic write itself (AC-5 — single code path). |
| XM-2 (hook-mode pid) | `$PPID` points at hook runner instead of Claude Code session | `arc_state_integrity_log`, ownership checks | Library never trusts `$PPID` alone — session identity is verified via `session_id` field + `config_dir` match. `$PPID` recorded for diagnostics, not gating. |
| XM-4 (log rotation race) | Concurrent rotation corrupts archive | `arc_state_integrity_log` | Rotation under `mkdir` lock (`${log}-rotate-lock.d`). EXIT trap preserves caller's prior trap (QUAL-FH-005). |

## Related Files

- **Plan**: [/Users/vinhnx/Desktop/repos/rune/plans/2026-04-17-fix-arc-state-file-reliability-plan.md](/Users/vinhnx/Desktop/repos/rune/plans/2026-04-17-fix-arc-state-file-reliability-plan.md)
  - §4.1 — Canary flag semantics
  - §4.2 — Post-write verify hook contract
  - §4.3 — Deletion rubric (5-criterion)
  - §5.1 — Atomic write protocol
  - §6.2 — Library function table (source of truth)
  - §14.1 / §14.4 — Integrity log schema
  - §16 / §16.9 — Security invariants (CWE-22/61/93, XM-1/2/4)
- **CHANGELOG**: [/Users/vinhnx/Desktop/repos/rune/plugins/rune/CHANGELOG.md](/Users/vinhnx/Desktop/repos/rune/plugins/rune/CHANGELOG.md) — v2.53.0 entry
- **Hook table**: [/Users/vinhnx/Desktop/repos/rune/plugins/rune/CLAUDE.md](/Users/vinhnx/Desktop/repos/rune/plugins/rune/CLAUDE.md) — `PostToolUse:Write|Edit` → `verify-arc-state-integrity.sh` row
- **Tests — DEFERRED**. Per plan AC-8, AC-10, AC-12, AC-13, AC-14, AC-15 the unit + property tests for the library, hook, and init script are scheduled for a follow-up patch. Current validation is manual and the JSONL audit trail. When tests land, expect:
  - `plugins/rune/scripts/tests/arc-loop-state-test.sh` — unit coverage of the 7 public functions and `arc_state_integrity_log` field shapes.
  - `plugins/rune/scripts/tests/verify-arc-state-integrity-test.sh` — hook exercise including dry-run vs enforced write.
  - `plugins/rune/scripts/tests/rune-arc-init-state-test.sh` — atomic write property tests (interrupted write, symlink poisoning, unknown kind rejection).

## Maintainer Notes

### Adding a new action

1. Add the action name to the `case "$_action"` table in `arc_state_integrity_log` (lines ~237-249). Pick a matching `severity` (`info`/`warn`/`error`) and `event_class` (`lifecycle`/`recovery`/`deletion`/`failure`).
2. Document the action in the plan's allowlist (§14 action registry) before emitting from callers.
3. If the action may fire during a deletion path, route through `arc_state_should_delete` first — never let callers bypass the 5-criterion rubric.

### Extending the log schema

1. Add a new field to the `jq -nc` invocation in `arc_state_integrity_log`. Use `--arg` for strings, `--argjson` for numbers/booleans/nulls.
2. Validate input Bash-3.2 style (`case` patterns) — never rely on `=~` or `${var,,}`.
3. Add the field to the table in this file with the shipped-or-deferred status, its source §-reference, and its coercion rule.
4. Bump the caution band of `arc_state_integrity_log` in any readers (`jq` consumers, dashboards) — absent fields must not break aggregation.

### Observability targets

A healthy canary sees:

- `severity: error` entries = 0 per week.
- `action: deletion_deferred_pending_phases` >> `action: deletion_deferred_jq_*` (real work dominates tooling fragility).
- `action: legitimate_completion_delete` monotonically increases with arc completions.
- No entries where `flag_enabled: true` and `dry_run: true` simultaneously — that is a logic error, not a data point.
