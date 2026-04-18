# Arc State File Integrity Subsystem

Reference for the arc phase-loop state file reliability subsystem introduced in v2.53.0 and promoted to unconditional enforcement in v2.56.0. Documents the library contract, the integrity log schema, and the security invariants that gate every deletion and write.

Source plan: [/Users/vinhnx/Desktop/repos/rune/plans/2026-04-17-fix-arc-state-file-reliability-plan.md](/Users/vinhnx/Desktop/repos/rune/plans/2026-04-17-fix-arc-state-file-reliability-plan.md) (see §4.1–§4.3, §5.1, §6.2, §14, §16).

## Overview

**What.** The subsystem centralizes creation, refresh, and deletion decisions for `.rune/arc-${loop_kind}-loop.local.md` state files. Three collaborating components share one library — `scripts/lib/arc-loop-state.sh` — so the stop-hook loop, the init script, and the PostToolUse verifier never drift on deletion semantics, symlink handling, or atomic-write sequencing.

**Why.** Pre-v2.53.0 the stop hook deleted the state file on ambiguous stop reasons, then the next phase turn found no state and halted. The same code path had no audit trail, no symlink defense, and no way to distinguish "work complete" from "jq crashed mid-decode." The subsystem introduces one deletion rubric (plan §4.3), one integrity log (plan §14), and unconditional active-write semantics (v2.56.0+) that create and repair state files during PostToolUse verification.

**Status (v2.56.0+).** All state-file writes are unconditional. The PostToolUse verify hook actively creates, repairs, and logs state file operations for every `.rune/arc/*/checkpoint.json` write. The rollout history (v2.53.0 observation → v2.55.0 default-flip → v2.56.0 flag retirement) is preserved in `docs/canary-evidence/v2.55.0.md` as an audit artifact only — it has no runtime effect.

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
| `arc_state_integrity_log` | `arc_state_integrity_log action cause state_file [extra_json] [arc_id] [loop_kind] [checkpoint_path] [pending_str] [mtime_age_str]` → exit 0 | Append-only JSONL entry with atomic `>>` append under `PIPE_BUF`. Rotates the log under a `mkdir` lock (XM-4). Refuses symlinks (SEC-002). |
| `arc_state_touch` | `arc_state_touch state_file` → exit 0 | Mtime-only refresh, throttled by `RUNE_ARC_STATE_TOUCH_THROTTLE_SEC`. R27 invariant — NEVER rewrites content. |
| `arc_state_pending_phases` | `arc_state_pending_phases checkpoint_path` → stdout int count, -1 on error | Counts `.phases[] | select(.status=="pending" or .status=="in_progress")`. Returns -1 on any jq failure so callers defer deletion safely (XM-3 / AC-14). |
| `arc_state_should_delete` | `arc_state_should_delete state_file` → exit 0 delete \| 1 defer | 5-branch rubric (plan §4.3) collapsed into 3 high-level criteria — (a) **tooling availability** (jq + checkpoint present, branches 1+2); (b) **pending-phase count** (branch 3 — >0 defers); (c) **stop_reason allowlist** (branch 4 deletes on `completed \| cancelled \| context_limit`, branch 5 defers anything else). Defer is the safe default: jq missing, checkpoint missing, jq parse error, pending>0, or ambiguous stop_reason all return 1. |
| `arc_state_recover` | `arc_state_recover [kind]` → exit 0 on recreate \| 1 on no-checkpoint | Delegates to `rune-arc-init-state.sh create` in recovery mode. Library does not perform atomic write itself (AC-5). |

## Integrity Log Schema

Schema derived from plan §14.1 (base identity) + §14.4 (extended diagnostic). `.rune/arc-integrity-log.jsonl` — one JSON object per line. Rotated when file exceeds `RUNE_ARC_INTEG_LOG_MAX_BYTES` (5 MB default — override via environment variable; NOT read from talisman shard).

Status legend:
- **Shipped** — emitted by `arc_state_integrity_log` in v2.53.0.
- **Deferred** — specified in §14.4 but not yet populated; reserved as `null`/absent. Closes when plan AC-12 through AC-15 land (§4.3 forge enrichment).

| # | Field | Type | §-ref | Status | Notes |
|--:|-------|------|-------|--------|-------|
| 1 | `ts` | ISO-8601 UTC string | §14.1 | Shipped | `date -u +%Y-%m-%dT%H:%M:%SZ` |
| 2 | `session_id` | string | §14.1 | Shipped | `RUNE_SESSION_ID` → `CLAUDE_SESSION_ID` → `"unknown"`. SEC-4 sanitized. |
| 3 | `owner_pid` | string | §14.1 | Shipped | `$PPID`; coerced to `"0"` if non-numeric. |
| 4 | `config_dir` | string | §14.1 | Shipped | Resolved via `cd … && pwd -P` — physical, not symlink. |
| 5 | `action` | string | §14.1 | Shipped | One of: `recovered_mid_arc`, `recovered_post_checkpoint_write`, `symlink_rejected`, `flag_lookup_failed`, `deletion_deferred_*`, `legitimate_stale_delete`, `legitimate_completion_delete`, `recovery_failed_no_checkpoint`, `corrupted_write`, `failed_write`, `failed_verify`, `verified` (hook), `created` (init — skill bootstrap). Unknown actions fall through to `severity=info / event_class=lifecycle`. |
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
| 17 | `flag_enabled` | bool | §14.4 | Shipped (historical) | Always `true` since v2.56.0. Retained for JSONL schema backward-compat — consumers parsing legacy logs from v2.53.0–v2.55.0 may still observe `false`. |
| 18 | `dry_run` | bool | §14.4 | Shipped (historical) | Always `false` since v2.56.0. Retained for schema backward-compat — consumers parsing legacy logs may still observe `true` for Phase A entries. |
| 19 | `plugin_version` | string | §14.4 | Shipped (v2.53.0) | `_RUNE_ARC_PLUGIN_VERSION` read at lib source time. |
| 20 | `current_phase` | string | §14.4 | Deferred | Requires checkpoint re-read at log time — deferred to AC-12. |
| 21 | `git_head` | string (short SHA) | §14.4 | Deferred | Requires safe `git rev-parse` without spawning per-entry. Deferred to AC-13. |
| 22 | `talisman_stale_multiplier` | number | §14.4 | Deferred | Requires config-stale detection; deferred to AC-15. |

Plan §14.4 also enumerates `tool_use_n` as a diagnostic field. It is **not** currently emitted and not counted above; track under the same AC-12 follow-up.

## Rollout History (historical reference)

The subsystem was rolled out in three phases — all retired as of v2.56.0:

| Phase | Version | State |
|-------|---------|-------|
| Observation-only | v2.53.0 | PostToolUse verify logged diagnostic entries; never wrote state. |
| Default-flipped | v2.55.0 | Writes became authoritative; flag still user-disableable. |
| Flag retired | v2.56.0 | All writes unconditional; no opt-out; subsystem is permanent. |

The v2.55.0 rollout evidence lives at `docs/canary-evidence/v2.55.0.md`. There is no rollback path from v2.56.0 — the gating flag, dry-run branches, and conditional log fields were removed. Reintroducing opt-out would require re-implementation.

## Health Monitoring Queries

Operators run these `jq` queries against `.rune/arc-integrity-log.jsonl` (and rotated archives `.rune/arc-integrity-log-*.jsonl`) to monitor the subsystem's health:

```bash
# Volume + session coverage of successful verifications
jq -s '[.[] | select(.action == "verified")] | {events: length, sessions: ([.[].session_id] | unique | length)}' \
  .rune/arc-integrity-log*.jsonl

# Any failed_verify events in the prior 30 days (expected: 0)
jq --arg cutoff "$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  'select(.action == "failed_verify" and .ts >= $cutoff)' \
  .rune/arc-integrity-log*.jsonl

# Any recovery_failed_no_checkpoint events (expected: rare — only when state and checkpoint both missing)
jq 'select(.action == "recovery_failed_no_checkpoint")' \
  .rune/arc-integrity-log*.jsonl

# deletion_deferred_* rate — baseline ratio by cause
jq -s '[.[] | select(.action | startswith("deletion_deferred_"))] | group_by(.action) | map({action: .[0].action, count: length})' \
  .rune/arc-integrity-log*.jsonl
```

Historical `flag_enabled` / `dry_run` field queries against legacy v2.53.0–v2.55.0 logs remain valid — both fields are always `true`/`false` respectively in v2.56.0+ entries. See the schema table above for details.

## Security Invariants

The subsystem must hold these invariants even when talisman, jq, or the checkpoint are unavailable. No configuration flag gates any of them — they are structural.

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

A healthy subsystem exhibits:

- `severity: error` entries = 0 per week.
- `action: deletion_deferred_pending_phases` >> `action: deletion_deferred_jq_*` (real work dominates tooling fragility).
- `action: legitimate_completion_delete` monotonically increases with arc completions.
- `action: verified` is the dominant PostToolUse outcome; `recovered_post_checkpoint_write` fires only on genuine state loss.
