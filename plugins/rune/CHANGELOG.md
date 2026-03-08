# Changelog

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