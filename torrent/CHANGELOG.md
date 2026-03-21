# Changelog

All notable changes to Torrent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-03-21

### Added

- **Recovery mode distinction** — new `RecoveryMode` enum (Retry/Resume/Evaluate) distinguishes pre-arc failures (no checkpoint, fresh `/arc`), mid-arc crashes (checkpoint exists, `/arc --resume`), and post-arc completion (evaluate result, no restart)
- **Escalating cooldown** — restart cooldown scales with failure density: 1x base (normal), 2x (2+ restarts), 3x with 180s minimum (rapid failure). Base default increased from 30s to 60s
- **Rapid failure skip** — 3+ restarts within 30 seconds triggers immediate plan skip (tightened from 5-minute window that never caught real rapid failures)
- **QA phase timeout category** — `forge_qa`, `work_qa`, `gap_analysis_qa`, `code_review_qa`, `mend_qa`, `test_qa` phases now timeout at 15 minutes (was 60 minutes via default fallthrough). Override: `TORRENT_TIMEOUT_QA`
- **Analysis phase timeout category** — `gap_analysis`, `codex_gap_analysis`, `goldmask_verification`, `goldmask_correlation`, `semantic_verification`, `gap_remediation`, `plan_refine`, `verification`, `drift_review` phases now timeout at 20 minutes. Override: `TORRENT_TIMEOUT_ANALYSIS`
- **Checkpoint-aware initial launch** — `launch_next_plan()` detects existing checkpoints from previous torrent sessions and auto-resumes instead of starting fresh
- **Restart history tracking** — `RestartRecord` captures mode, phase, reason, and timestamp for each restart event; `ResumeState` tracks separate `retry_count` and `resume_count`
- **New env vars** — `TORRENT_MAX_RETRIES` (default: 3, pre-arc retry budget), `TORRENT_TIMEOUT_QA` (default: 15 min), `TORRENT_TIMEOUT_ANALYSIS` (default: 20 min)

### Fixed

- **Wrong recovery command after crash** — pre-arc failures no longer send `/arc --resume` (which fails without a checkpoint); they correctly send `/arc` for a fresh start
- **Rapid failure burn-through** — 3 restarts in <2 seconds no longer exhausts the retry budget silently; escalating cooldown and rapid-skip prevent wasted cycles
- **Restart state machine discriminant** — `check_restart_cooldown()` Phase 1/Phase 2 now uses a dedicated `session_recreated` flag instead of `run.arc.is_some()`, which failed for Retry mode (arc always None → infinite session recreation loop)
- **TOCTOU panic in cooldown countdown** — `Instant::now()` captured once before `duration_since` comparison, preventing underflow panic when deadline expires between two calls
- **Checkpoint matching false-positives** — `check_existing_checkpoint()` now uses filename-based `plans_match()` instead of bidirectional `contains()` which matched substrings (e.g., `auth.md` matched `oauth.md`)
- **Dual timestamp drift in restart recording** — `record_restart()` now owns the full recording lifecycle (counters + history + timestamp), eliminating separate `Utc::now()` calls for the same event

### Changed

- **Default `TORRENT_RESTART_COOLDOWN`** increased from 30s to 60s
- **`is_rapid_failure()` window** tightened from 300s (5 min) to 30s
- **`phase_category()` expanded** from 5 to 7 categories — all 32 arc phases now have explicit category mappings instead of 16 falling through to the "review" default
- **`PhaseTimeoutConfig::from_env()` behavior** — categories now always get explicit defaults (forge=30m, work=45m, qa=15m, analysis=20m, test=30m, review=30m, ship=20m) instead of falling through to `TORRENT_TIMEOUT_DEFAULT` (60m)
- **`send_arc_with_retry` / `send_arc_resume_with_retry`** consolidated into generic `send_with_retry()` helper

## [0.6.4] - 2026-03-21

### Fixed

- **Misleading "All plans completed" during inter-plan cooldown** — Checkpoint panel now shows "⏳ Waiting for next plan" with countdown timer and queue status when cooldown is active or plans are still queued, instead of incorrectly displaying the completion summary

## [0.6.3] - 2026-03-20

### Fixed

- **Panic safety in event loop** — replace `.unwrap()` in `app.rs` after `check_restart_cooldown()` with graceful error handling
- **CLI graceful errors** — replace 9 `.expect()` panics in `torrent-cli.rs` with proper error propagation
- **Atomic lock acquisition** — `lock.rs` now uses `O_CREAT|O_EXCL` for TOCTOU-safe lock file creation
- **Non-atomic lock fallback removed** — `lock.rs` replaces `fs::write` fallback with error return for atomicity
- **JSON parsing safety** — `recovery.rs` replaces manual JSON string parsing with `serde_json`
- **Prompt detection false positives** — `monitor.rs` uses `starts_with` instead of `contains` for input prompt detection
- **BFS/DFS comment mismatch** — `resource.rs` `collect_descendants()` comment now matches actual traversal order

## [0.6.2] - 2026-03-20

### Fixed

- **Premature plan transition on ship completion** — `check_completion()` incorrectly returned `Shipped` when `ship: completed` but `merge: pending`, killing the arc tmux session while bot_review_wait, pr_comment_resolution, and merge phases were still running. Now only returns `Shipped` when merge is `"skipped"` (--no-merge) or absent (--no-pr)

### Added

- **Inter-plan cooldown** — 5-minute delay after successful merge/ship before launching next plan, preventing rapid transitions. Configurable via `TORRENT_INTER_PLAN_COOLDOWN` env var (default: 300s). Press `[s]` to skip. Set to `0` to disable

## [0.6.1] - 2026-03-20

### Fixed

- **False-positive PlanNotFound during active arc** — D4 diagnostic patterns `"no such file"` and `"file not found"` were too generic, matching normal tool output (e.g., Read errors during file probes) and incorrectly triggering SkipPlan mid-arc
- **Bootstrap-only patterns now skipped during runtime** — added `bootstrap_only` flag to D4 (plan_not_found) and D5 (plugin_missing) patterns; `check_runtime` skips these entirely since the plan is already loaded once arc is running

## [0.6.0] - 2026-03-19

### Added

- **Tmux pane diagnostic detection (F6)** — three-phase diagnostic pipeline (pre-arc health check, arc bootstrap check, runtime monitoring) covering 10+ diagnostic states (D1-D10, D17-D24) with pattern-based detection
- **Post-arc recovery (F6)** — branch-safe stash flows (D25/D26) using `Command::new("git")` for deterministic stash/branch operations; never drops stash on conflict, never force-checkouts
- **Severity-colored diagnostic banners** — diagnostic state displayed in TUI Running view with color-coded severity
- **Multi-signal activity state detection (F3)** — `ActivityState` enum with 6 states (Active, Slow, Stale, Idle, Stopped, WaitingInput) combining heartbeat freshness, pane output hash, CPU activity, and input prompt detection; informational only, does not trigger kill/restart
- **Activity state UI indicator** — color-coded icon in heartbeat section of Running view
- **Auto-resume on phase timeout (F5)** — automatic session restart with `/arc --resume` after phase timeout kill
- **Three retry strategies** — PhaseTimeout (30s cooldown, 3 max), ApiOverload (progressive 15m→4h, 6 max), TokenAuth (15m→30m, 3 max)
- **Resume state persistence** — `.torrent/state/{plan-hash}.json` survives torrent restarts
- **New env vars** — `TORRENT_MAX_RESUMES` (default: 3), `TORRENT_RESTART_COOLDOWN` (default: 30s)
- **Orphan cleanup on skip** — kills remaining tmux sessions and clears arc teams/tasks before next plan
- **Rapid failure detection** — logs warning when all retries exhaust in <5 minutes
- **Adaptive grace period (F4)** — grace duration computed from child process count and CPU activity using formula: `base + (children × 2) + (cpu% × 0.5)`, clamped to configurable min/max range
- **Grace countdown UI** — visible progress bar with color-coded urgency (green >50%, yellow 20-50%, red <20%) and child process context
- **Grace skip keybinding** — press `s` during grace period to skip (minimum 5s remaining enforced); contextual with existing `s` = skip plan
- **`TORRENT_GRACE_BASE/MIN/MAX`** — environment variables for adaptive grace formula (defaults: 30/10/120 seconds)
- **Structured run logs** — JSONL logging at `.torrent/logs/runs.jsonl` with per-plan entries (status, urgency, restarts, duration) and batch summary at exit
- **Log rotation** — automatic rotation at 10MB with max 5 archived files
- **`TORRENT_LOG_DIR`** — environment variable to override default log directory

### Changed

- **Grace period default** — reduced from fixed 300s (5 min) to adaptive 10-120s range (base 30s). `GRACE_PERIOD_SECS` is still respected as backward-compatible fallback when `TORRENT_GRACE_*` vars are not set

## [0.5.0] - 2026-03-19

### Added

- **Phase timeout detection and auto-kill** — multi-tick state machine detects stuck arc phases and gracefully kills them via `SIGTERM` + 15s grace period before hard `tmux kill-session`
- **PhaseTimeoutConfig** — session-scoped configuration parsed from `TORRENT_TIMEOUT_*` env vars with per-category overrides (forge, work, test, review, ship), defaults to 60 minutes
- **Timeout UI indicators** — color-coded remaining time display (green <50%, yellow 50-80%, red >80%) next to phase elapsed time, plus red warning banner when timeout kill is active
- **CLI `--phase-timeout` / `-t` flag** — per-phase timeout overrides from the command line with case-insensitive matching and 1-minute minimum clamp
- **`phase_category()` mapping** — groups 15+ phase names into 5 categories for grouped timeout configuration

### Fixed

- **SEC-002**: Check `libc::kill` return value — `ESRCH` skips grace period, `EPERM` warns
- **BACK-010**: Case-insensitive matching in `apply_overrides()` via `.to_lowercase()`
- **BACK-012**: Clamp timeout overrides to minimum 1 minute

## [0.4.1] - 2026-03-19

### Fixed

- **Orphan tmux session adoption** — when an arc session crashes and Claude restarts in the same tmux with a new PID, Torrent now adopts the state file instead of discarding it. Previously showed "(unknown config)" with no checkpoint info; now displays full phase progress, plan, config, and PR URL via `try_adopt_loop_state()`

## [0.4.0] - 2026-03-18

### Added

- **Scrollable lists with scrollbars** — all list views (Active Arcs, Config, Plans, Queue) now use stateful rendering with auto-scroll via `ratatui::ListState`. Visual scrollbar (`↑`/`↓` indicators, cyan thumb) appears only when content overflows the viewport
- **CLI argument parsing** — new `--config-dir` / `-c` flag for custom Claude config directories (can be specified multiple times), plus `--version` / `-V` and `--help` / `-h` flags with comprehensive usage documentation
- **`$CLAUDE_CONFIG_DIR` env support** — auto-includes the env var as a config source if set and valid
- **Version display in TUI header** — shows `torrent vX.Y.Z` across all views
- **Unit tests for config discovery** — tests for `resolve_path()`, extra dir handling, and deduplication logic

### Changed

- **Makefile consolidation** — merged `torrent/Makefile` into root `Makefile`. Single entry point with all targets: `dist`, `install-local`, `uninstall`, `fmt`, `preflight`, `loc`
- **Config dir discovery** — now accepts extra paths via CLI, deduplicates by canonical path, and labels sources (default/env/custom)
- **Session isolation** — orphan tmux sessions are filtered by CWD, preventing torrent instances in different directories from interfering with each other
- **tmux session creation** — now passes working directory via `-c` flag, ensuring Claude Code inherits correct CWD for session isolation

### Removed

- **`torrent/Makefile`** — consolidated into root Makefile

### Fixed

- **Cross-directory session interference** — `scan_active_arcs` now filters orphan sessions by canonical CWD comparison, fixing a bug where torrent in directory A would show sessions from torrent B

## [0.2.0] - 2026-03-17

### Added

- Initial TUI with config selection and plan queue management
- Active arcs view with monitoring capabilities
- tmux session management (create, attach, kill)
- Real-time heartbeat and checkpoint polling
- Queue editing during arc execution

## [0.1.0] - 2026-03-15

### Added

- Initial release
- Basic config directory scanning (`~/.claude/`, `~/.claude-*/`)
- Plan file discovery and selection
- tmux session lifecycle management