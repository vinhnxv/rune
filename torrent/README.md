# Torrent — Tmux Arc Orchestrator

A standalone Rust TUI tool that manages `rune:arc` execution across multiple Claude Code
sessions using tmux. Runs plans **sequentially**, each in a **fresh tmux session** with
an independent Claude Code instance.

## Why

The existing `/rune:arc-batch` runs arcs sequentially within a single Claude Code session.
Torrent improves on this by:

- **Multi-config support** — use different `CLAUDE_CONFIG_DIR` accounts
- **tmux isolation** — each arc gets its own Claude Code instance with clean context
- **Independent monitoring** — observe arc progress via checkpoint/heartbeat files
- **Crash resilience** — tmux sessions survive if torrent exits

Torrent complements `arc-batch` (which handles smart-sort and dependency ordering).
Use torrent when you need config-dir rotation or tmux-based process isolation.

## Prerequisites

- **Rust** — install via [rustup](https://rustup.rs/)
- **tmux** — `brew install tmux` (macOS) or `apt install tmux` (Linux)
- **Claude Code** — must be on `$PATH`

## Build

```bash
cd torrent/
cargo build --release
```

Binary at `torrent/target/release/torrent`.

## Usage

```bash
# Run from the project root (where plans/ directory lives)
cd /path/to/project
./torrent/target/release/torrent
```

### Selection View

1. **Left panel** — choose a Claude config directory (`~/.claude`, `~/.claude-work`, etc.)
2. **Right panel** — toggle plans to run (selection order = execution order)
3. Press `r` to start sequential execution

### Running View

Torrent launches each plan in a fresh tmux session, monitors arc progress via
checkpoint and heartbeat JSON files, and automatically advances to the next plan
when an arc completes (merge phase done + 4 min grace period).

## Keybindings

### Selection View

| Key       | Action                            |
|-----------|-----------------------------------|
| `↑` / `↓` | Navigate within panel            |
| `Tab`     | Switch between config/plan panels |
| `Enter`   | Select config directory           |
| `Space`   | Toggle plan (ordered selection)   |
| `a`       | Toggle all plans                  |
| `r`       | Run selected plans sequentially   |
| `q`       | Quit                              |

### Running View

| Key | Action                                              |
|-----|-----------------------------------------------------|
| `a` | Attach to tmux session (Ctrl-B D to detach back)    |
| `s` | Skip current plan, advance to next                  |
| `k` | Kill tmux session, stop all execution               |
| `q` | Quit TUI (tmux session continues in background)     |

## Architecture

```
torrent (TUI)
├── scanner.rs      — discovers ~/.claude* dirs and plans/*.md files
├── app.rs          — application state, selection logic, quit summary
├── ui.rs           — ratatui rendering (selection + running views)
├── keybindings.rs  — input handling per view
├── tmux.rs         — tmux session lifecycle (create, send-keys, kill)
├── monitor.rs      — arc discovery + heartbeat/checkpoint polling
└── checkpoint.rs   — serde structs for checkpoint.json + heartbeat.json
```

### Data Flow

1. **Scan** — discover config dirs and plan files at startup
2. **Select** — user picks a config dir and orders plans
3. **Launch** — create tmux session, send `/arc <plan>` command
4. **Discover** — poll for matching checkpoint.json (up to 3 min)
5. **Monitor** — watch heartbeat.json for liveness, checkpoint.json for phase progress
6. **Complete** — detect merge completion, wait 4 min grace, kill tmux, start next plan
