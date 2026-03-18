# Changelog

All notable changes to Torrent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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