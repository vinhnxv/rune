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

- **tmux** — `brew install tmux` (macOS) or `apt install tmux` (Linux)
- **Claude Code** — must be on `$PATH`

## Installation

### Quick Install (curl)

```bash
# Install to ~/.local/bin (recommended)
curl -fsSL https://raw.githubusercontent.com/vinhnxv/rune/main/torrent/install.sh | bash

# Or install system-wide (may require sudo)
curl -fsSL https://raw.githubusercontent.com/vinhnxv/rune/main/torrent/install.sh | bash -s -- --system
```

**Platform support:**
| Platform | Pre-built binary | Fallback |
|----------|------------------|----------|
| macOS (Apple Silicon) | ✅ `torrent-arm64-apple-darwin.tar.gz` | — |
| macOS (Intel) | ✅ `torrent-x86_64-apple-darwin.tar.gz` | — |
| Linux (x86_64) | ❌ | Build from source (requires Rust) |
| Linux (ARM64) | ❌ | Build from source (requires Rust) |

After installation, ensure `~/.local/bin` is in your PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Build from Source

Requires [Rust](https://rustup.rs/):

```bash
cd torrent/
cargo build --release
```

Binary at `torrent/target/release/torrent`.

### Using Make (from repo root)

```bash
# Build release binary
make build

# Build debug binary (fast compile)
make dev

# Install to /usr/local/bin (may need sudo)
make install

# Install to ~/.local/bin (no sudo)
make install-local

# Create release tarballs
make dist

# Uninstall
make uninstall

# See all targets
make help
```

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
6. **Complete** — detect merge completion, wait grace period, kill tmux, start next plan

---

## CLI Tool: torrent-cli

In addition to the TUI, torrent includes a CLI tool for direct tmux session management:

```bash
# Build the CLI
cargo build --release --bin torrent-cli

# Create a new tmux session with Claude Code
./target/release/torrent-cli new-session --config-dir ~/.claude-work

# Send keys with the Ink autocomplete workaround
./target/release/torrent-cli send-keys --session rune-abc123 --text "/arc plans/my-plan.md"

# Capture pane output for debugging
./target/release/torrent-cli capture-pane --session rune-abc123 --lines 30

# List all torrent/rune sessions
./target/release/torrent-cli list

# Kill a session
./target/release/torrent-cli kill --session rune-abc123

# Full flow: create session, wait for Claude, send /arc
./target/release/torrent-cli run --config-dir ~/.claude --plan plans/my-plan.md --wait 15
```

---

## Configuration

### Grace Period

The grace period after merge detection before starting the next plan defaults to 240 seconds (4 minutes). Override via environment variable:

```bash
# Shorter grace period (2 minutes)
GRACE_PERIOD_SECS=120 ./torrent/target/release/torrent

# Longer grace period (10 minutes)
GRACE_PERIOD_SECS=600 ./torrent/target/release/torrent
```

---

## Troubleshooting

### "git checkout main failed — clean up working tree"

**Cause:** Uncommitted changes or unmerged files in the working tree.

**Solution:**
```bash
# Check status
git status

# Stash or discard changes
git stash
# or
git checkout -- .

# Remove untracked files if needed
git clean -fd
```

### "tmux failed: session already exists"

**Cause:** A previous torrent session wasn't cleaned up.

**Solution:**
```bash
# List sessions
tmux list-sessions

# Kill the orphan session
tmux kill-session -t rune-XXXXXX

# Or use torrent-cli
./target/release/torrent-cli kill --session rune-XXXXXX
```

### "Claude Code is ready" but /arc didn't execute

**Cause:** The Ink autocomplete workaround may need adjustment on your system.

**Solution:**
1. Attach to the tmux session: `tmux attach -t rune-XXXXXX`
2. Check if Claude Code is showing an error
3. Manually type `/arc plans/your-plan.md` and press Enter
4. The Escape+delay+Enter workaround may need tuning for slower systems

### Checkpoint discovery takes too long (>3 min)

**Cause:** Multiple arcs running concurrently, or the plan file path doesn't match.

**Solution:**
1. Check `.rune/arc/` for existing arc directories
2. Verify the plan file name matches exactly (case-sensitive)
3. Ensure `CLAUDE_CONFIG_DIR` is set correctly for non-default accounts

### Heartbeat shows "stale" (red indicator)

**Cause:** No activity for >5 minutes. The arc may be stuck or waiting for user input.

**Solution:**
1. Attach to the session: `tmux attach -t rune-XXXXXX`
2. Check for permission prompts or other blocking dialogs
3. Use `[k]` to kill and restart if necessary

---

## Security Notes

- **`--dangerously-skip-permissions`:** Torrent launches Claude Code with this flag to enable non-interactive execution. This bypasses all permission prompts. Only use torrent in trusted environments.
- **Session ID validation:** All tmux session names are validated to contain only alphanumeric characters, hyphens, and underscores to prevent command injection.
- **Shell escaping:** All paths sent to tmux are shell-escaped to prevent command injection via special characters.
