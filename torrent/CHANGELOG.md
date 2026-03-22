# Changelog

All notable changes to Torrent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.1] - 2026-03-22

### Fixed

- **Bridge View session guard** — `OpenBridge` now requires active session, not just `--channels` flag. Shows "No active session" if pressed before arc starts
- **SendFailed indicator** — messages that fail delivery across all transports (bridge, inbox, tmux) now shown as `"you (failed)"` in red instead of falsely appearing as sent
- **Unicode input cap** — message input limit changed from byte length to char count (`chars().count() < 2000`) for correct handling of Vietnamese, CJK, and other multi-byte input
- **Bridge View scrolling** — added Up/Down arrow keys to scroll through message history with yellow `"↓ N more"` indicator when scrolled up
- **Bridge log file reset** — `bridge_log_file` now properly reset when starting a new session, ensuring each session gets its own JSONL file
- **Arc completion color** — Bridge View now shows arc completion in red for failures, green for success (was always green)

### Added

- **Session separator** — `"── new session: rune-xyz ──"` marker inserted in Bridge View when starting a new arc execution
- **Scroll hint** — Bridge View input bar shows `[↑↓] scroll` alongside existing `[Enter] send` and `[Esc] back to arc`

## [0.10.0] - 2026-03-22

### Added

- **Bridge View** — dedicated full-screen TUI view for interacting with the torrent-bridge (`[b]` key from Running View, `--channels` only). Features:
  - Header with `torrent-bridge` title, connected/disconnected badge, session ID and port info
  - Message list showing up to 26 recent messages with color-coded labels (you/phase/arc/claude)
  - Text input bar for sending messages directly to Claude Code via bridge
  - Up/Down arrow scrolling with `"↓ N more"` indicator when scrolled up
  - Auto-scroll to bottom on new messages and on send
  - Hint bar: `[Enter] send  [↑↓] scroll  [Esc] back to arc`
- **Bridge health check** — `[h]` key in Running View pings the bridge and shows session identity (session ID, uptime). `--channels` only
- **Bridge-based command dispatch** — when `--channels` is active, `/arc` and `/arc --resume` commands are sent via HTTP POST to bridge `/msg` endpoint instead of tmux send-keys. Falls back to tmux automatically if bridge is unreachable
- **Message persistence** — all bridge messages (sent, received, heartbeats) persisted to `.torrent/sessions/{session_id}/messages.jsonl` (append-only JSONL, one JSON per line). Review with `cat .torrent/sessions/rune-*/messages.jsonl | jq .`
- **`SendFailed` message kind** — Bridge View shows `"you (failed)"` in red when message delivery fails across all transports
- **Session separator** — `"── new session: rune-xyz ──"` marker inserted in Bridge View when starting a new arc execution
- **Heartbeat dedup in display** — consecutive heartbeats replace each other in the display buffer (all still persisted to JSONL)
- **Arc completion color** — Bridge View shows arc completion in green (success) or red (failed)

### Changed

- **`send_message_to_claude()`** — now prefers bridge HTTP when `--channels` is active, with tmux as fallback. Previously always used tmux
- **`send_via_bridge_http()`** — no longer dead code; activated as primary transport in channels mode
- **`send_arc_with_retry()`** — new `send_arc_prefer_bridge()` wrapper attempts bridge dispatch first, falls back to tmux with retry
- **Message input cap** — changed from byte length to char count (`chars().count() < 2000`) for correct Unicode handling (Vietnamese, CJK)
- **`OpenBridge` guard** — requires both `channels_enabled` AND active session (`tmux_session_id.is_some()`). Shows "No active session" otherwise
- **Bridge log file reset** — `bridge_log_file` is reset to `None` when starting a new session, ensuring each session gets its own JSONL file

### Fixed

- **Bridge View accessible with no session** — previously allowed opening Bridge View before any arc started, leading to cryptic errors
- **Sent messages shown on failed delivery** — `send_message_to_claude()` now detects delivery failure and marks message as `SendFailed`
- **Bridge log file stale across sessions** — file handle was kept from previous session; now properly reset on new execution

## [0.9.0] - 2026-03-22

### Added

- **Channels API migration** — bridge now uses `notifications/claude/channel` (official Channels API) instead of `notifications/message` (logging, ignored by Claude). Claude natively receives and responds to messages from Torrent
- **Bun runtime** — bridge rewritten from `npx tsx` (Node) to Bun, matching the [fakechat](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/fakechat) reference pattern. ~50ms startup vs ~3-5s
- **`reply` tool** — Claude can send text responses back to Torrent/browser via new MCP tool. Events forwarded to both HTTP callback (Torrent TUI) and WebSocket (browser UI)
- **Browser chat UI** — real-time WebSocket chat interface at `http://127.0.0.1:<bridge_port>`. Send messages, see Claude's replies instantly
- **`/info` endpoint** — bridge exposes session identity JSON (`session_id`, `pid`, `uptime`) for port → session mapping
- **Auto port allocation** — port pairs (callback + bridge) auto-allocated from 9900–9998 range via `TcpListener::bind` collision check. No more hardcoded ports
- **Random session IDs** — `torrent-{8 hex chars}` instead of PID-based, preventing collisions across restarts
- **Session registry** — `tmp/torrent-sessions/{id}.meta` tracks all sessions (mode, ports, config, PID, timestamp)
- **Channels prompt auto-accept** — polls tmux pane content (up to 10s) to detect development channels confirmation prompt, sends Enter automatically. Replaces hardcoded 5s sleep
- **`--teammate-mode tmux`** flag added to Claude command when channels enabled
- **Channel port in TUI** — header shows `[ch:9901]` (cyan=healthy, yellow=unhealthy), session detail shows `CH: :9901`
- **`Reply` event type** — callback server handles `type: "reply"` events with `text` and `reply_to` fields (8192 char limit)
- **Makefile `PORT=` and `CONFIG=` variables** — `make run-channel PORT=9900`, `make run-cli-channel CONFIG=~/.claude-work`
- **`make run-cli-channel`** — new target for CLI session creation with channels
- **`make clean-sessions`** — clear session registry
- **`make preflight`** — now checks for Bun availability

### Changed

- **Bridge is bidirectional** — was outbound-only (Claude → Torrent), now also inbound (Torrent → Claude) via Channels API
- **Bridge version** bumped to 0.2.0
- **`.mcp.json`** — `bun` command replaces `npx tsx`, removed hardcoded `env` block (ports inherited from shell)
- **`deliver()` function** — centralized channel notification dispatch with `void` (fire-and-forget) instead of `await`
- **Bridge `instructions`** — updated for `<channel source="torrent-bridge">` tag format and reply tool usage
- **Makefile** — `bridge-deps` uses `bun install` instead of `npm install`, `bridge-check` uses `bun build`
- **`run-channel` target** — auto port by default, explicit via `PORT=` variable
- **`cmd_run()`** — forwards `--channels` and `--callback-port` to `cmd_new_session()`

### Removed

- **`CLAUDE_SESSION_ID` dependency** — was always `"unknown"` (not an env var). All references replaced with `TORRENT_SESSION_ID`
- **`logging: {}` capability** — removed from bridge MCP server (using `claude/channel` instead)
- **Hardcoded port 9901** — removed from `.mcp.json` env block
- **`run-channel-custom` Makefile target** — merged into `run-channel` with `PORT=` variable

## [0.8.0] - 2026-03-22

### Added

- **Inbound messaging** — send messages to Claude Code from Torrent TUI (`[m]` key) or CLI (`torrent-cli send-msg`). 3-tier delivery cascade: bridge HTTP → file inbox → tmux send-keys
- **Bridge HTTP inbound server** — bridge now listens on `TORRENT_BRIDGE_PORT` for POST `/msg` requests, delivering messages to Claude via MCP `sendLoggingMessage()` notification
- **`check_inbox` MCP tool** — Claude can poll for queued messages from Torrent via filesystem-based inbox (fallback when HTTP notification fails)
- **Transport prefix** — all messages tagged with source: `[torrent:bridge]`, `[torrent:inbox]`, or `[torrent:tmux]` so Claude can identify delivery method
- **Transport indicator in TUI** — status bar shows `✉→bridge`, `✉→inbox`, or `✉→tmux` after sending, plus predicted transport in message input bar
- **Session-scoped inbox** — messages scoped to `tmp/bridge-inbox/{session_id}/` preventing cross-session message leaks
- **`torrent-cli send-msg`** — CLI command with `--via bridge|tmux|auto` delivery mode, `--session` targeting, and auto-detection
- **Makefile** — consolidated all targets into root Makefile: `make run-channel`, `make send-msg`, `make test-e2e`, `make test-all`, `make bridge-deps`
- **Channels bridge E2E tests** — 14 Rust unit tests for field validation + shell harness testing full MCP JSON-RPC pipeline (bridge init → tool call → callback POST)
- **Bridge GET `/ping`** health check endpoint and `bridge-port.txt` discovery file

### Fixed

- **SEC-011**: Drop channel events during init window when `expected_session` is `None`
- **SEC-012**: Prevent u16 overflow on `callback_port + 1` via `checked_add` with `saturating_sub` fallback; CLI port cap at 65534
- **SEC-013 / BACK-015**: Add per-field length limits for `session_id` (64), `event_type` (32), `result` (32), `error` (1024), `activity` (32), `current_tool` (128)
- **BACK-002**: Env var `TORRENT_CALLBACK_PORT` now range-validated (1–65534), matching CLI validation
- **BACK-016**: Validate `http:` or `https:` protocol scheme on callback URL
- **QUAL-001**: Align `session_id` limit to 64 chars across all modules (was 128 in callback, 64 in tmux/channel)
- **QUAL-003**: Tighten bridge hostname check to `127.0.0.1` only (was also accepting `localhost`)
- **QUAL-006**: Split `pr_url` compound validation into separate protocol and length checks
- **QUAL-009**: Remove duplicate `session_exists()` method, migrate callers to `has_session()`
- **SEC-002 (bridge)**: Add 64KB payload size guard before HTTP POST
- Zero compiler warnings (`cargo check`) and zero clippy issues

### Changed

- **Bridge loading** — replaced `--dangerously-load-development-channels` with `--mcp-config` inline JSON (no confirmation prompt, no "dangerously" warning)
- **Bridge env vars** — `TORRENT_CALLBACK_URL`, `TORRENT_BRIDGE_PORT`, `TORRENT_SESSION_ID` passed via MCP config `env` block (explicit, not inherited)
- **`start_from_env()`** — annotated as `#[allow(dead_code)]` with aligned port validation (1–65534)
- **Dead code cleanup** — removed `drain_events()` (BACK-017), annotated `is_stale()`/`since_last_event()` for future use (QUAL-007/008)

### Removed

- **`torrent/Makefile`** — consolidated into root Makefile
- **Tombstone comments** — removed "function removed" comments in favor of git history

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